#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SPKStrings.h"
#import "../../InstagramHeaders.h"
#import "../../AssetUtils.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"

// Pin people in the main search. Holding a person in search toggles their pin. Pinned
// people get their own section above the recent searches, in the order they were
// pinned, with no limit, and are left out of the recent list so nobody appears twice.
//
// The pins live in Sparkle's own store rather than in Instagram's recents, which are
// capped, expire, sync from the server and are emptied by Clear All. Rows are built by
// Instagram's own search row factory from the person's user model, so a pinned row
// looks and taps exactly like a recent one.

static NSString *const kSPKSearchPinsEnabledKey = @"interface_search_pins";
// Per account, most recently pinned first. Each entry keeps enough of the profile to
// draw the row when Instagram has not loaded the person this launch.
static NSString *const kSPKSearchPinnedKey = @"interface_search_pinned";
static NSString *const kSPKSearchPinPKKey = @"pk";
static NSString *const kSPKSearchPinUsernameKey = @"username";
static NSString *const kSPKSearchPinFullNameKey = @"full_name";
static NSString *const kSPKSearchPinPictureKey = @"profile_pic_url";
static NSString *const kSPKSearchPinVerifiedKey = @"is_verified";
static NSString *const kSPKSearchPinUpdatedKey = @"updated";

// Profile picture links are signed and expire, so a stored one is only handed to
// Instagram while it is fresh; an older one would replace a working picture with a
// broken one.
static const NSTimeInterval kSPKSearchPinPictureMaxAge = 2.0 * 24.0 * 60.0 * 60.0;
// A changed picture link alone is rewritten at most this often, since every fetch
// signs the same picture under a new link.
static const NSTimeInterval kSPKSearchPinPictureRefreshInterval = 12.0 * 60.0 * 60.0;

static BOOL SPKSearchPinsEnabled(void) {
    return [SPKUtils getBoolPref:kSPKSearchPinsEnabledKey];
}

#pragma mark - Storage

static NSString *SPKSearchPinPKForEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]])
        return nil;
    id pk = entry[kSPKSearchPinPKKey];
    return [pk isKindOfClass:[NSString class]] && [pk length] > 0 ? pk : nil;
}

static NSArray<NSDictionary *> *SPKSearchPinEntries(void) {
    id stored = SPKPreferenceObjectForKey(kSPKSearchPinnedKey);
    if (![stored isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:[stored count]];
    for (id entry in (NSArray *)stored) {
        if (SPKSearchPinPKForEntry(entry))
            [entries addObject:entry];
    }
    return entries;
}

// The search list reads the pins on every update, so they are cached per effective
// key: the key changes with the active account, and any write drops the cache.
static NSArray<NSDictionary *> *SPKSearchCachedPinEntries;
static NSString *SPKSearchCachedPinsKey;

static NSArray<NSDictionary *> *SPKSearchCachedEntries(void) {
    NSString *effectiveKey = SPKEffectivePreferenceKey(kSPKSearchPinnedKey);
    if (SPKSearchCachedPinEntries && [SPKSearchCachedPinsKey isEqualToString:effectiveKey])
        return SPKSearchCachedPinEntries;
    SPKSearchCachedPinEntries = [SPKSearchPinEntries() copy];
    SPKSearchCachedPinsKey = [effectiveKey copy];
    return SPKSearchCachedPinEntries;
}

static void SPKSearchSaveEntries(NSArray<NSDictionary *> *entries) {
    SPKPreferenceSetObject(entries, kSPKSearchPinnedKey);
    SPKSearchCachedPinEntries = nil;
}

static NSSet<NSString *> *SPKSearchPinnedPKs(NSArray<NSDictionary *> *entries) {
    NSMutableSet<NSString *> *pks = [NSMutableSet setWithCapacity:entries.count];
    for (NSDictionary *entry in entries)
        [pks addObject:SPKSearchPinPKForEntry(entry)];
    return pks;
}

#pragma mark - Users

static NSString *SPKSearchStringValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector])
        return nil;
    id value = nil;
    @try {
        value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if ([value isKindOfClass:[NSURL class]])
        value = [(NSURL *)value absoluteString];
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

static BOOL SPKSearchBoolValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector])
        return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    const char *type = signature.methodReturnType;
    if (!type || (type[0] != 'B' && type[0] != 'c'))
        return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id SPKSearchUserForViewModel(id viewModel) {
    if (![viewModel respondsToSelector:@selector(searchableItem)])
        return nil;
    id item = nil;
    @try {
        item = ((id (*)(id, SEL))objc_msgSend)(viewModel, @selector(searchableItem));
    } @catch (__unused NSException *exception) {
        return nil;
    }
    Class userClass = objc_getClass("IGUser");
    return userClass && [item isKindOfClass:userClass] ? item : nil;
}

static NSDictionary *SPKSearchEntryForUser(id user, NSString *pk) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:pk forKey:kSPKSearchPinPKKey];
    entry[kSPKSearchPinUsernameKey] = SPKSearchStringValue(user, @"username") ?: @"";
    entry[kSPKSearchPinFullNameKey] = SPKSearchStringValue(user, @"fullName") ?: @"";
    entry[kSPKSearchPinPictureKey] = SPKSearchStringValue(user, @"profilePicURL") ?: @"";
    entry[kSPKSearchPinVerifiedKey] = @(SPKSearchBoolValue(user, @"isVerified"));
    entry[kSPKSearchPinUpdatedKey] = @([NSDate date].timeIntervalSince1970);
    return entry;
}

/// The stored entry refreshed from a loaded user, or nil when nothing worth a write
/// has changed.
static NSDictionary *SPKSearchRefreshedEntry(NSDictionary *entry, id user) {
    NSDictionary *fresh = SPKSearchEntryForUser(user, SPKSearchPinPKForEntry(entry));
    BOOL namesChanged = ![fresh[kSPKSearchPinUsernameKey] isEqual:entry[kSPKSearchPinUsernameKey] ?: @""] ||
                        ![fresh[kSPKSearchPinFullNameKey] isEqual:entry[kSPKSearchPinFullNameKey] ?: @""] ||
                        ![fresh[kSPKSearchPinVerifiedKey] isEqual:entry[kSPKSearchPinVerifiedKey] ?: @NO];
    NSTimeInterval updated = [entry[kSPKSearchPinUpdatedKey] doubleValue];
    BOOL pictureStale = [fresh[kSPKSearchPinPictureKey] length] > 0 &&
                        ![fresh[kSPKSearchPinPictureKey] isEqual:entry[kSPKSearchPinPictureKey] ?: @""] &&
                        [NSDate date].timeIntervalSince1970 - updated > kSPKSearchPinPictureRefreshInterval;
    return namesChanged || pictureStale ? fresh : nil;
}

static id SPKSearchUserMap(id session) {
    @try {
        if ([session respondsToSelector:@selector(userMap)])
            return [session valueForKey:@"userMap"];
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

/// The person Instagram already has in memory, or one rebuilt from the stored entry.
/// Rebuilding goes through the user map, which merges onto the canonical instance
/// for a person it already knows.
static id SPKSearchLoadUserForEntry(NSDictionary *entry, id session) {
    NSString *pk = SPKSearchPinPKForEntry(entry);
    id userMap = SPKSearchUserMap(session);
    if (!pk || !userMap)
        return nil;

    SEL lookup = NSSelectorFromString(@"userWithPK:");
    if ([userMap respondsToSelector:lookup]) {
        @try {
            id user = ((id (*)(id, SEL, id))objc_msgSend)(userMap, lookup, pk);
            if (SPKSearchStringValue(user, @"username"))
                return user;
        } @catch (__unused NSException *exception) {
        }
    }

    if (![userMap respondsToSelector:@selector(userWithDict:)])
        return nil;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:pk forKey:@"pk"];
    for (NSString *key in @[ kSPKSearchPinUsernameKey, kSPKSearchPinFullNameKey ]) {
        NSString *value = entry[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0)
            dict[key] = value;
    }
    if (dict[kSPKSearchPinUsernameKey] == nil)
        return nil;
    NSString *picture = entry[kSPKSearchPinPictureKey];
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - [entry[kSPKSearchPinUpdatedKey] doubleValue];
    if ([picture isKindOfClass:[NSString class]] && picture.length > 0 && age < kSPKSearchPinPictureMaxAge)
        dict[kSPKSearchPinPictureKey] = picture;
    if ([entry[kSPKSearchPinVerifiedKey] boolValue])
        dict[kSPKSearchPinVerifiedKey] = @YES;
    @try {
        return [userMap performSelector:@selector(userWithDict:) withObject:dict];
    } @catch (NSException *exception) {
        SPKLog(@"General", @"[Sparkle SearchPins] userWithDict: threw: %@", exception);
        return nil;
    }
}

// The user map hands back its canonical instance, which Instagram keeps current in
// place, so a person resolved once is reused instead of rebuilt on every list update.
// Keyed like the pins, so switching accounts starts over.
static NSMutableDictionary<NSString *, id> *SPKSearchResolvedUsers;
static NSString *SPKSearchResolvedUsersKey;

static id SPKSearchUserForEntry(NSDictionary *entry, id session) {
    NSString *pk = SPKSearchPinPKForEntry(entry);
    if (!pk)
        return nil;
    NSString *effectiveKey = SPKEffectivePreferenceKey(kSPKSearchPinnedKey);
    if (!SPKSearchResolvedUsers || ![SPKSearchResolvedUsersKey isEqualToString:effectiveKey]) {
        SPKSearchResolvedUsers = [NSMutableDictionary dictionary];
        SPKSearchResolvedUsersKey = [effectiveKey copy];
    }
    id user = SPKSearchResolvedUsers[pk];
    if (!user) {
        user = SPKSearchLoadUserForEntry(entry, session);
        if (user)
            SPKSearchResolvedUsers[pk] = user;
    }
    return user;
}

#pragma mark - Instagram search models

static Class SPKSearchResultViewModelClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGSearchViewModels.IGSearchResultViewModel", @"IGSearchResultViewModel");
    });
    return cls;
}

static Class SPKSearchHorizontalRecentsClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGSearchViewModels.IGSearchRecentSearchesHorizontalViewModel", nil);
    });
    return cls;
}

static NSString *SPKSearchClientSectionType(NSString *selectorName, NSString *fallback) {
    Class cls = SPKResolveIGClass(@"IGSearchViewModels.IGSearchResultClientSectionType", @"IGSearchResultClientSectionType");
    SEL selector = NSSelectorFromString(selectorName);
    if (cls && [cls respondsToSelector:selector]) {
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
            if ([value isKindOfClass:[NSString class]])
                return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return fallback;
}

/// The section type Instagram stamps on its recent search rows.
static NSString *SPKSearchRecentSectionType(void) {
    static NSString *type;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        type = SPKSearchClientSectionType(@"recent", @"RECENT");
    });
    return type;
}

/// The section type pinned rows carry. Not the recent one, so Instagram does not
/// treat them as removable history.
static NSString *SPKSearchPinnedSectionType(void) {
    static NSString *type;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        type = SPKSearchClientSectionType(@"none", @"");
    });
    return type;
}

static BOOL SPKSearchIsResultViewModel(id object) {
    Class cls = SPKSearchResultViewModelClass();
    return cls && [object isKindOfClass:cls];
}

static BOOL SPKSearchIsRecentRow(id object) {
    if (!SPKSearchIsResultViewModel(object) || ![object respondsToSelector:@selector(sectionType)])
        return NO;
    id sectionType = ((id (*)(id, SEL))objc_msgSend)(object, @selector(sectionType));
    return [sectionType isKindOfClass:[NSString class]] && [sectionType caseInsensitiveCompare:SPKSearchRecentSectionType()] == NSOrderedSame;
}

static BOOL SPKSearchIsHorizontalRecents(id object) {
    Class cls = SPKSearchHorizontalRecentsClass();
    return cls && [object isKindOfClass:cls];
}

static NSArray *SPKSearchHorizontalItems(id viewModel) {
    if (![viewModel respondsToSelector:@selector(items)])
        return nil;
    id items = ((id (*)(id, SEL))objc_msgSend)(viewModel, @selector(items));
    return [items isKindOfClass:[NSArray class]] ? items : nil;
}

#pragma mark - Pinned header

@interface SPKSearchPinsHeaderModel : NSObject
@end

@implementation SPKSearchPinsHeaderModel

- (id<NSObject>)diffIdentifier {
    return @"spk_search_pins_header";
}

- (BOOL)isEqualToDiffableObject:(id)object {
    return [object isKindOfClass:[SPKSearchPinsHeaderModel class]];
}

@end

@interface SPKSearchPinsHeaderCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *reorderButton;
@property (nonatomic, copy) void (^onReorder)(void);
@property (nonatomic, copy) void (^onLeaveWindow)(void);
- (void)setReordering:(BOOL)reordering available:(BOOL)available;
@end

@implementation SPKSearchPinsHeaderCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
        _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        _titleLabel.text = SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_SECTION_TITLE");
        _titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
        [self.contentView addSubview:_titleLabel];

        _reorderButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _reorderButton.translatesAutoresizingMaskIntoConstraints = NO;
        _reorderButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [_reorderButton setTitleColor:[SPKUtils SPKColor_InstagramBlue] forState:UIControlStateNormal];
        [_reorderButton addTarget:self action:@selector(reorderTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_reorderButton];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_reorderButton.leadingAnchor constant:-8.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_reorderButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
            [_reorderButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setReordering:(BOOL)reordering available:(BOOL)available {
    NSString *title = reordering ? SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_REORDER_DONE_BUTTON")
                                 : SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_REORDER_BUTTON");
    [UIView performWithoutAnimation:^{
        [self.reorderButton setTitle:title forState:UIControlStateNormal];
        [self.reorderButton layoutIfNeeded];
    }];
    self.reorderButton.hidden = !reordering && !available;
}

- (void)reorderTapped {
    if (self.onReorder)
        self.onReorder();
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && self.onLeaveWindow)
        self.onLeaveWindow();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onReorder = nil;
    self.onLeaveWindow = nil;
}

@end

static SPKSearchPinsHeaderModel *SPKSearchPinsHeader(void) {
    static SPKSearchPinsHeaderModel *header;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        header = [SPKSearchPinsHeaderModel new];
        Protocol *diffable = objc_getProtocol("IGListDiffable");
        if (diffable)
            class_addProtocol([SPKSearchPinsHeaderModel class], diffable);
    });
    return header;
}

#pragma mark - Pinned rows

// The row context Instagram used for its recent rows, reused for pinned rows so their
// taps are attributed the same way. Kept from the last list that had recents.
static NSString *SPKSearchLastModule;
// The recent rows the last null state hid behind a pin, by pk, so an unpinned
// person's row can take its recent look back before the list moves it.
static NSDictionary<NSString *, id> *SPKSearchHiddenRecentRows;
static unsigned long long SPKSearchLastSourceType;

static id SPKSearchRowForUser(id user, NSString *pk, id session) {
    Class dataModelClass = SPKResolveIGClass(@"IGSearchViewModels.IGSearchResultDataModel", @"IGSearchResultDataModel");
    Class providerClass = SPKResolveIGClass(@"IGSearchDataSources.IGSearchTypeaheadSearchResultViewModelDefaultProvider",
                                            @"IGSearchTypeaheadSearchResultViewModelDefaultProvider");
    if (!dataModelClass || !providerClass || !user || !session)
        return nil;

    static id provider;
    if (![provider isKindOfClass:providerClass])
        provider = [providerClass new];

    NSString *module = SPKSearchLastModule.length > 0 ? SPKSearchLastModule : @"blended_search";
    NSString *identifier = [@"spk_search_pin_" stringByAppendingString:pk];
    @try {
        id dataModel = [[dataModelClass alloc] initWithSearchableItem:user sectionType:SPKSearchPinnedSectionType() subtitle:nil];
        if (!dataModel)
            return nil;
        SEL current = NSSelectorFromString(@"viewModelWithDataModel:sourceType:userSession:analyticsModule:searchText:isPersisting:identifier:rankToken:");
        SEL legacy = NSSelectorFromString(@"viewModelWithDataModel:sourceType:userSession:analyticsModule:searchText:isPersisting:identifier:");
        id row = nil;
        if ([provider respondsToSelector:current])
            row = ((id (*)(id, SEL, id, unsigned long long, id, id, id, BOOL, id, id))objc_msgSend)(provider, current, dataModel, SPKSearchLastSourceType, session, module, @"", NO, identifier, @"");
        else if ([provider respondsToSelector:legacy])
            row = ((id (*)(id, SEL, id, unsigned long long, id, id, id, BOOL, id))objc_msgSend)(provider, legacy, dataModel, SPKSearchLastSourceType, session, module, @"", NO, identifier);
        return SPKSearchIsResultViewModel(row) ? row : nil;
    } @catch (NSException *exception) {
        SPKLog(@"General", @"[Sparkle SearchPins] building the row for %@ threw: %@", pk, exception);
        return nil;
    }
}

#pragma mark - Null state

// The kinds of search whose null state lists people. A null-state source is created
// for one search type; the type is learned from the first null state that shows a
// recent person and kept, so the pinned section stays once the recents are cleared,
// across launches, without hard-coding Instagram's enum values.
static NSString *const kSPKSearchPinsListTypesKey = @"interface_search_pins_list_types";

static NSNumber *SPKSearchTypeOfNullStateSource(id source) {
    if (!source)
        return nil;
    // Swift stores the Int-backed search type under its property name, the
    // Objective-C class under the underscored ivar; both are eight bytes.
    for (Class cls = [source class]; cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, "searchType") ?: class_getInstanceVariable(cls, "_searchType");
        if (ivar) {
            long long value = *(long long *)((char *)(__bridge void *)source + ivar_getOffset(ivar));
            return @(value);
        }
    }
    return nil;
}

static NSArray<NSNumber *> *SPKSearchLearnedListTypes(void) {
    id stored = SPKPreferenceObjectForKey(kSPKSearchPinsListTypesKey);
    return [stored isKindOfClass:[NSArray class]] ? stored : @[];
}

static void SPKSearchLearnListType(NSNumber *type) {
    NSArray<NSNumber *> *known = SPKSearchLearnedListTypes();
    if (!type || [known containsObject:type])
        return;
    SPKPreferenceSetObject([known arrayByAddingObject:type], kSPKSearchPinsListTypesKey);
    SPKLog(@"General", @"[Sparkle SearchPins] learned people search type %@", type);
}

/// Rebuilds Instagram's null state with the pinned section above the recent searches
/// and the pinned people taken out of them. `owner` is the null-state source producing
/// the list, nil when the caller already knows the list is the people search.
static NSArray *SPKSearchApplyPins(NSArray *models, id owner, BOOL knownEligible) {
    if (!SPKSearchPinsEnabled() || ![models isKindOfClass:[NSArray class]])
        return models;
    if ([models containsObject:SPKSearchPinsHeader()])
        return models;
    NSArray<NSDictionary *> *entries = SPKSearchCachedEntries();
    NSSet<NSString *> *pinnedPKs = SPKSearchPinnedPKs(entries);

    // Pass one: find the recent section and the pinned people in it.
    NSUInteger firstRecentIndex = NSNotFound;
    NSUInteger recentCount = 0;
    BOOL hasRecentPerson = NO;
    NSMutableDictionary<NSString *, id> *recentUsers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < models.count; index++) {
        id object = models[index];
        NSArray *rows = nil;
        if (SPKSearchIsRecentRow(object))
            rows = @[ object ];
        else if (SPKSearchIsHorizontalRecents(object))
            rows = SPKSearchHorizontalItems(object);
        if (!rows)
            continue;
        if (firstRecentIndex == NSNotFound)
            firstRecentIndex = index;
        for (id row in rows) {
            recentCount++;
            id user = SPKSearchUserForViewModel(row);
            NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
            if (!pk)
                continue;
            hasRecentPerson = YES;
            if ([pinnedPKs containsObject:pk])
                recentUsers[pk] = user;
            if ([row respondsToSelector:@selector(module)]) {
                id module = ((id (*)(id, SEL))objc_msgSend)(row, @selector(module));
                if ([module isKindOfClass:[NSString class]] && [module length] > 0)
                    SPKSearchLastModule = [module copy];
            }
            if ([row respondsToSelector:@selector(sourceType)])
                SPKSearchLastSourceType = ((unsigned long long (*)(id, SEL))objc_msgSend)(row, @selector(sourceType));
        }
    }

    NSNumber *searchType = SPKSearchTypeOfNullStateSource(owner);
    if (hasRecentPerson)
        SPKSearchLearnListType(searchType);
    BOOL eligible = knownEligible || hasRecentPerson || (searchType && [SPKSearchLearnedListTypes() containsObject:searchType]);
    if (!eligible || entries.count == 0)
        return models;

    // Instagram heads its recent rows with a header, the object right before them.
    NSUInteger recentHeaderIndex = NSNotFound;
    if (firstRecentIndex != NSNotFound && firstRecentIndex > 0) {
        id previous = models[firstRecentIndex - 1];
        if (!SPKSearchIsResultViewModel(previous) && !SPKSearchIsHorizontalRecents(previous))
            recentHeaderIndex = firstRecentIndex - 1;
    }

    // Pass two: drop the pinned people from the recent rows.
    NSUInteger removedCount = 0;
    NSMutableArray *rest = [NSMutableArray arrayWithCapacity:models.count];
    NSMutableDictionary<NSString *, id> *hiddenRows = [NSMutableDictionary dictionary];
    for (id model in models) {
        id object = model;
        if (SPKSearchIsRecentRow(object)) {
            NSString *pk = [SPKUtils pkFromIGUser:SPKSearchUserForViewModel(object)];
            if (pk && [pinnedPKs containsObject:pk]) {
                hiddenRows[pk] = object;
                removedCount++;
                continue;
            }
        } else if (SPKSearchIsHorizontalRecents(object) && [object respondsToSelector:@selector(initWithItems:)]) {
            NSArray *items = SPKSearchHorizontalItems(object);
            NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
            for (id item in items) {
                NSString *pk = [SPKUtils pkFromIGUser:SPKSearchUserForViewModel(item)];
                if (pk && [pinnedPKs containsObject:pk])
                    removedCount++;
                else
                    [kept addObject:item];
            }
            if (kept.count != items.count) {
                if (kept.count == 0)
                    continue;
                id rebuilt = [[[object class] alloc] initWithItems:kept];
                if ([object respondsToSelector:@selector(contentOffsetX)] && [rebuilt respondsToSelector:@selector(setContentOffsetX:)]) {
                    double offset = ((double (*)(id, SEL))objc_msgSend)(object, @selector(contentOffsetX));
                    ((void (*)(id, SEL, double))objc_msgSend)(rebuilt, @selector(setContentOffsetX:), offset);
                }
                object = rebuilt ?: object;
            }
        }
        [rest addObject:object];
    }

    SPKSearchHiddenRecentRows = [hiddenRows copy];

    // A recent header left with no rows goes too.
    id recentHeader = recentHeaderIndex != NSNotFound ? models[recentHeaderIndex] : nil;
    if (recentHeader && recentCount > 0 && removedCount == recentCount)
        [rest removeObjectIdenticalTo:recentHeader];

    // The pinned rows, in pin order.
    id session = [SPKUtils activeUserSession];
    NSMutableArray *pinnedRows = [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableArray<NSDictionary *> *refreshedEntries = nil;
    for (NSUInteger index = 0; index < entries.count; index++) {
        NSDictionary *entry = entries[index];
        NSString *pk = SPKSearchPinPKForEntry(entry);
        id user = recentUsers[pk] ?: SPKSearchUserForEntry(entry, session);
        NSDictionary *refreshed = user ? SPKSearchRefreshedEntry(entry, user) : nil;
        if (refreshed) {
            if (!refreshedEntries)
                refreshedEntries = [entries mutableCopy];
            refreshedEntries[index] = refreshed;
        }
        id row = SPKSearchRowForUser(user, pk, session);
        if (row)
            [pinnedRows addObject:row];
    }
    if (refreshedEntries)
        SPKSearchSaveEntries(refreshedEntries);
    static NSInteger lastLoggedRows = -1;
    if ((NSInteger)pinnedRows.count != lastLoggedRows) {
        lastLoggedRows = pinnedRows.count;
        SPKLog(@"General", @"[Sparkle SearchPins] %lu of %lu pinned rows built (%lu recent, %lu hidden, owner %@)",
               (unsigned long)pinnedRows.count, (unsigned long)entries.count, (unsigned long)recentCount,
               (unsigned long)removedCount, NSStringFromClass([owner class]));
    }
    if (pinnedRows.count == 0)
        return rest;

    NSUInteger insertionIndex = 0;
    if (recentHeader && [rest indexOfObjectIdenticalTo:recentHeader] != NSNotFound)
        insertionIndex = [rest indexOfObjectIdenticalTo:recentHeader];
    else if (firstRecentIndex != NSNotFound)
        insertionIndex = MIN(firstRecentIndex - (recentHeaderIndex != NSNotFound ? 1 : 0), rest.count);
    [pinnedRows insertObject:SPKSearchPinsHeader() atIndex:0];
    [rest insertObjects:pinnedRows atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertionIndex, pinnedRows.count)]];
    return rest;
}

#pragma mark - Toggling

/// The search screens a hold pins from: the main search on current builds, and the
/// typeahead with its results list on older ones.
static BOOL SPKSearchIsPinnableController(UIViewController *controller) {
    static NSArray<Class> *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<Class> *classes = [NSMutableArray array];
        Class current = SPKResolveIGClass(@"IGSearchTypeahead.IGSearchNewTypeaheadViewController", nil);
        Class legacy = objc_getClass("IGSearchTypeaheadViewController");
        if (current)
            [classes addObject:current];
        if (legacy)
            [classes addObject:legacy];
        hosts = [classes copy];
    });
    for (UIViewController *current = controller; current; current = current.parentViewController) {
        for (Class host in hosts) {
            if ([current isKindOfClass:host])
                return YES;
        }
    }
    return NO;
}

// The visible cell a section controller's next dequeue hands back instead of a new
// one, so a build whose cell has no configure method still binds it in place.
static __weak UICollectionViewCell *SPKSearchForcedCell;

/// Configures the visible cell showing a person with another row of theirs.
static void SPKSearchRebindVisibleCell(IGListAdapter *adapter, NSString *pk, id row) {
    UICollectionView *collectionView = adapter.collectionView;
    SEL configure = NSSelectorFromString(@"configureWithUserSession:viewModel:options:");
    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        if (![cell respondsToSelector:@selector(viewModel)])
            continue;
        id current = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(viewModel));
        if (![[SPKUtils pkFromIGUser:SPKSearchUserForViewModel(current)] isEqualToString:pk])
            continue;

        void (^bind)(void) = nil;
        Ivar optionsIvar = class_getInstanceVariable([cell class], "options");
        if ([cell respondsToSelector:configure] && optionsIvar) {
            unsigned long long options = *(unsigned long long *)((uint8_t *)(__bridge void *)cell + ivar_getOffset(optionsIvar));
            id session = [SPKUtils activeUserSession];
            bind = ^{
                ((void (*)(id, SEL, id, id, unsigned long long))objc_msgSend)(cell, configure, session, row, options);
            };
        } else {
            // Older builds configure the cell inside the section controller's own
            // cellForItemAtIndex:, so run that against the cell on screen.
            NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
            SEL sectionSelector = NSSelectorFromString(@"sectionControllerForSection:");
            if (!indexPath || ![adapter respondsToSelector:sectionSelector])
                return;
            IGListSectionController *sectionController = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, sectionSelector, indexPath.section);
            if (![sectionController respondsToSelector:@selector(didUpdateToObject:)])
                return;
            bind = ^{
                [(id)sectionController didUpdateToObject:row];
                SPKSearchForcedCell = cell;
                @try {
                    [sectionController cellForItemAtIndex:indexPath.item];
                } @finally {
                    SPKSearchForcedCell = nil;
                }
            };
        }
        [UIView transitionWithView:cell
                          duration:0.25
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:^{
                            bind();
                            [cell setNeedsLayout];
                            [cell layoutIfNeeded];
                        }
                        completion:nil];
        return;
    }
}

static void SPKSearchTogglePin(id user, id adapter) {
    NSString *pk = [SPKUtils pkFromIGUser:user];
    if (pk.length == 0)
        return;
    NSMutableArray<NSDictionary *> *entries = [SPKSearchPinEntries() mutableCopy];
    NSUInteger existing = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, __unused NSUInteger idx, __unused BOOL *stop) {
        return [SPKSearchPinPKForEntry(entry) isEqualToString:pk];
    }];
    BOOL pinned = existing == NSNotFound;
    if (pinned)
        [entries insertObject:SPKSearchEntryForUser(user, pk) atIndex:0];
    else
        [entries removeObjectAtIndex:existing];
    SPKSearchSaveEntries(entries);

    NSString *username = SPKSearchStringValue(user, @"username");
    SPKLog(@"General", @"[Sparkle SearchPins] %@ %@", pinned ? @"pinned" : @"unpinned", pk);
    SPKNotify(kSPKNotificationSearchPin,
              pinned ? SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_TOAST_PINNED") : SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_TOAST_UNPINNED"),
              username.length > 0 ? [@"@" stringByAppendingString:username] : nil,
              pinned ? @"pin_filled" : @"pin_off",
              SPKNotificationToneInfo);

    if (![adapter isKindOfClass:objc_getClass("IGListAdapter")])
        return;
    IGListAdapter *listAdapter = adapter;
    // The header is the same list object whatever the pin count, so the list never
    // rebinds it; show or hide its reorder button directly.
    for (UICollectionViewCell *cell in listAdapter.collectionView.visibleCells) {
        if ([cell isKindOfClass:[SPKSearchPinsHeaderCell class]])
            [(SPKSearchPinsHeaderCell *)cell setReordering:NO available:entries.count > 1];
    }
    // A row moving between Recent and Pinned keeps its diff identity, so the list
    // slides the same cell over without binding the new row, and the remove-from-
    // history button would keep its old state. Bind the row the cell is about to
    // show now, fading over the slide.
    id row = pinned ? SPKSearchRowForUser(user, pk, [SPKUtils activeUserSession]) : SPKSearchHiddenRecentRows[pk];
    if (row)
        SPKSearchRebindVisibleCell(listAdapter, pk, row);
    [listAdapter performUpdatesAnimated:YES completion:nil];
}

#pragma mark - Pin gesture

static const void *kSPKSearchPinGestureKey = &kSPKSearchPinGestureKey;


// Instagram's search rows have no hold action of their own on current builds: the
// cell reports touches and button taps only. So the hold is recognised on the list.
@interface SPKSearchPinGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UICollectionView *collectionView;
@property (nonatomic, weak) id adapter;
/// Reorder mode, entered from the pinned header: a hold drags a pinned row
/// instead of unpinning it.
@property (nonatomic) BOOL reordering;
@property (nonatomic) BOOL dragging;
@property (nonatomic) BOOL scrollWasEnabled;
@property (nonatomic, copy) NSString *dragPK;
@property (nonatomic, strong) UIView *dragSnapshot;
@property (nonatomic) CGFloat dragOffsetY;
/// The pinned rows as they stood when the drag began, as [pk, frame, cell]; the
/// list is left alone until the drop, so these stay true throughout.
@property (nonatomic, copy) NSArray<NSArray *> *dragSlots;
@property (nonatomic) NSUInteger dragFromIndex;
@property (nonatomic) NSUInteger dragToIndex;
@end

/// Whether a list object is one of the pinned rows, not a recent row of a pinned person.
static BOOL SPKSearchIsPinnedRow(id object) {
    if (!SPKSearchIsResultViewModel(object) || SPKSearchIsRecentRow(object))
        return NO;
    NSString *pk = [SPKUtils pkFromIGUser:SPKSearchUserForViewModel(object)];
    return pk && [SPKSearchPinnedPKs(SPKSearchCachedEntries()) containsObject:pk];
}

#pragma mark - Reorder grabber

static const void *kSPKSearchGrabberKey = &kSPKSearchGrabberKey;
static const CGFloat kSPKSearchGrabberBoxSize = 32.0;
static const CGFloat kSPKSearchGrabberGlyphSize = 12.0;
// The trailing inset of Instagram's remove-from-history button on a recent row,
// measured from one on screen so the grabber takes exactly its place.
static CGFloat SPKSearchDismissTrailingInset = -1.0;

static UIView *SPKSearchFindDismissButton(UIView *view, UIView *cell) {
    for (UIView *subview in view.subviews) {
        if (!subview.hidden && subview.alpha > 0.01 && [NSStringFromClass([subview class]) containsString:@"TapButton"]) {
            CGRect frame = [subview convertRect:subview.bounds toView:cell];
            if (frame.size.width > 0.0 && frame.size.width <= 44.0 && CGRectGetMinX(frame) > CGRectGetWidth(cell.bounds) / 2.0)
                return subview;
        }
        UIView *found = SPKSearchFindDismissButton(subview, cell);
        if (found)
            return found;
    }
    return nil;
}

static void SPKSearchMeasureDismissButton(UICollectionViewCell *cell) {
    if (SPKSearchDismissTrailingInset >= 0.0)
        return;
    UIView *button = SPKSearchFindDismissButton(cell.contentView, cell);
    if (!button)
        return;
    CGRect frame = [button convertRect:button.bounds toView:cell];
    // The grabber's box is centred where the button's is.
    SPKSearchDismissTrailingInset = MAX(0.0, CGRectGetWidth(cell.bounds) - CGRectGetMidX(frame) - kSPKSearchGrabberBoxSize / 2.0);
}

static void SPKSearchSetGrabberShown(UICollectionViewCell *cell, BOOL shown, BOOL animated) {
    UIImageView *grabber = objc_getAssociatedObject(cell, kSPKSearchGrabberKey);
    if (!shown && !grabber)
        return;
    if (!grabber) {
        grabber = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"hamburger" pointSize:kSPKSearchGrabberGlyphSize]];
        grabber.contentMode = UIViewContentModeCenter;
        grabber.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        grabber.userInteractionEnabled = NO;
        grabber.isAccessibilityElement = NO;
        grabber.alpha = 0.0;
        grabber.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(cell, kSPKSearchGrabberKey, grabber, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (shown) {
        CGFloat inset = SPKSearchDismissTrailingInset >= 0.0 ? SPKSearchDismissTrailingInset : 8.0;
        CGRect bounds = cell.contentView.bounds;
        grabber.frame = CGRectMake(CGRectGetWidth(bounds) - inset - kSPKSearchGrabberBoxSize,
                                   (CGRectGetHeight(bounds) - kSPKSearchGrabberBoxSize) / 2.0, kSPKSearchGrabberBoxSize,
                                   kSPKSearchGrabberBoxSize);
        if (grabber.superview != cell.contentView)
            [cell.contentView addSubview:grabber];
        [cell.contentView bringSubviewToFront:grabber];
    }
    CGFloat alpha = shown ? 1.0 : 0.0;
    if (grabber.alpha == alpha)
        return;
    if (animated)
        [UIView animateWithDuration:0.2
                         animations:^{
                             grabber.alpha = alpha;
                         }];
    else
        grabber.alpha = alpha;
}

@implementation SPKSearchPinGestureTarget

- (void)setReordering:(BOOL)reordering {
    _reordering = reordering;
    [self updateGrabbersAnimated:YES];
}

/// Shows the grabber on the pinned rows on screen while reordering, and hides it
/// everywhere else.
- (void)updateGrabbersAnimated:(BOOL)animated {
    UICollectionView *collectionView = self.collectionView;
    NSArray<UICollectionViewCell *> *cells = collectionView.visibleCells;
    for (UICollectionViewCell *cell in cells) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (indexPath && SPKSearchIsRecentRow([self objectAtSection:indexPath.section]))
            SPKSearchMeasureDismissButton(cell);
    }
    for (UICollectionViewCell *cell in cells) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        BOOL shown = self.reordering && indexPath && SPKSearchIsPinnedRow([self objectAtSection:indexPath.section]);
        SPKSearchSetGrabberShown(cell, shown, animated);
    }
}

- (id)objectAtSection:(NSInteger)section {
    id adapter = self.adapter;
    if (![adapter respondsToSelector:@selector(objectAtSection:)])
        return nil;
    @try {
        return ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, @selector(objectAtSection:), section);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSIndexPath *)pinnedIndexPathForRecognizer:(UIGestureRecognizer *)recognizer {
    UICollectionView *collectionView = self.collectionView;
    NSIndexPath *indexPath = [collectionView indexPathForItemAtPoint:[recognizer locationInView:collectionView]];
    return indexPath && SPKSearchIsPinnedRow([self objectAtSection:indexPath.section]) ? indexPath : nil;
}

- (NSString *)pkAtSection:(NSInteger)section {
    id object = [self objectAtSection:section];
    return SPKSearchIsPinnedRow(object) ? [SPKUtils pkFromIGUser:SPKSearchUserForViewModel(object)] : nil;
}

/// The pinned rows in list order, as [pk, frame, cell or NSNull].
- (NSArray<NSArray *> *)pinnedSlots {
    UICollectionView *collectionView = self.collectionView;
    NSMutableArray<NSArray *> *slots = [NSMutableArray array];
    for (NSInteger section = 0; section < collectionView.numberOfSections; section++) {
        NSString *pk = [self pkAtSection:section];
        if (!pk || [collectionView numberOfItemsInSection:section] == 0)
            continue;
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:section];
        UICollectionViewLayoutAttributes *attributes = [collectionView layoutAttributesForItemAtIndexPath:indexPath];
        if (attributes)
            [slots addObject:@[ pk, [NSValue valueWithCGRect:attributes.frame], [collectionView cellForItemAtIndexPath:indexPath] ?: NSNull.null ]];
    }
    return slots;
}

/// Slides the rows between where the dragged row started and where it would land
/// into the gap it leaves, the way a native reorder previews the drop.
- (void)layoutDragPreview {
    NSArray<NSArray *> *slots = self.dragSlots;
    NSUInteger from = self.dragFromIndex, to = self.dragToIndex;
    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         for (NSUInteger index = 0; index < slots.count; index++) {
                             UICollectionViewCell *cell = slots[index][2];
                             if (![cell isKindOfClass:[UICollectionViewCell class]] || index == from)
                                 continue;
                             NSInteger neighbour = index;
                             if (from < to && index > from && index <= to)
                                 neighbour = index - 1;
                             else if (from > to && index >= to && index < from)
                                 neighbour = index + 1;
                             CGFloat shift = CGRectGetMinY([slots[neighbour][1] CGRectValue]) - CGRectGetMinY([slots[index][1] CGRectValue]);
                             cell.transform = CGAffineTransformMakeTranslation(0.0, shift);
                         }
                     }
                     completion:nil];
}

/// Puts every cell of the list back to normal, including any the drag touched that
/// have since gone to the reuse pool.
- (void)resetDraggedCells {
    for (UIView *view in self.collectionView.subviews) {
        if (![view isKindOfClass:[UICollectionViewCell class]])
            continue;
        view.transform = CGAffineTransformIdentity;
        view.alpha = 1.0;
    }
}

- (void)finishDragCommitting:(BOOL)commit {
    UICollectionView *collectionView = self.collectionView;
    NSArray<NSArray *> *slots = self.dragSlots;
    NSUInteger from = self.dragFromIndex;
    NSUInteger to = commit ? self.dragToIndex : from;
    UIView *snapshot = self.dragSnapshot;
    NSString *pk = self.dragPK;
    self.dragging = NO;
    self.dragSnapshot = nil;
    self.dragPK = nil;
    self.dragSlots = nil;
    collectionView.scrollEnabled = self.scrollWasEnabled;
    if (!commit) {
        self.dragToIndex = from;
        self.dragSlots = slots;
        [self layoutDragPreview];
        self.dragSlots = nil;
    }

    CGRect landing = to < slots.count ? [slots[to][1] CGRectValue] : snapshot.frame;
    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.2
        animations:^{
            snapshot.transform = CGAffineTransformIdentity;
            snapshot.frame = landing;
            snapshot.layer.shadowOpacity = 0.0;
        }
        completion:^(__unused BOOL finished) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (commit && to != from && to < slots.count)
                [strongSelf savePK:pk beforeOrAfterPK:slots[to][0] movingDown:to > from];
            void (^cleanUp)(void) = ^{
                [UIView performWithoutAnimation:^{
                    [strongSelf resetDraggedCells];
                }];
                [snapshot removeFromSuperview];
            };
            id adapter = strongSelf.adapter;
            if (!commit || to == from || ![adapter isKindOfClass:objc_getClass("IGListAdapter")]) {
                cleanUp();
                return;
            }
            // The saved order already matches what is on screen, so the list update runs
            // without animation, and the drag visuals stay until it has landed so the
            // old order never shows for a frame.
            [(IGListAdapter *)adapter performUpdatesAnimated:NO
                                                  completion:^(__unused BOOL updated) {
                                                      cleanUp();
                                                  }];
        }];
}

/// Moves the dragged pin to the position the pin it was dropped on held.
- (void)savePK:(NSString *)pk beforeOrAfterPK:(NSString *)targetPK movingDown:(BOOL)movingDown {
    NSMutableArray<NSDictionary *> *entries = [SPKSearchPinEntries() mutableCopy];
    NSUInteger from = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, __unused NSUInteger idx, __unused BOOL *stop) {
        return [SPKSearchPinPKForEntry(entry) isEqualToString:pk];
    }];
    if (from == NSNotFound)
        return;
    NSDictionary *entry = entries[from];
    [entries removeObjectAtIndex:from];
    NSUInteger target = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, __unused NSUInteger idx, __unused BOOL *stop) {
        return [SPKSearchPinPKForEntry(candidate) isEqualToString:targetPK];
    }];
    if (target == NSNotFound)
        return;
    [entries insertObject:entry atIndex:movingDown ? target + 1 : target];
    SPKSearchSaveEntries(entries);
    SPKLog(@"General", @"[Sparkle SearchPins] reordered pins, %@ moved", pk);
}

- (void)handleDrag:(UILongPressGestureRecognizer *)recognizer {
    UICollectionView *collectionView = self.collectionView;
    CGPoint location = [recognizer locationInView:collectionView];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *indexPath = [self pinnedIndexPathForRecognizer:recognizer];
            NSString *pk = indexPath ? [self pkAtSection:indexPath.section] : nil;
            NSArray<NSArray *> *slots = [self pinnedSlots];
            NSUInteger from = [slots indexOfObjectPassingTest:^BOOL(NSArray *slot, __unused NSUInteger idx, __unused BOOL *stop) {
                return [slot[0] isEqualToString:pk];
            }];
            UICollectionViewCell *cell = from != NSNotFound ? slots[from][2] : nil;
            UIView *snapshot = [cell isKindOfClass:[UICollectionViewCell class]] ? [cell snapshotViewAfterScreenUpdates:NO] : nil;
            if (!snapshot)
                return;
            self.dragging = YES;
            self.dragPK = pk;
            self.dragSlots = slots;
            self.dragFromIndex = from;
            self.dragToIndex = from;
            self.dragOffsetY = location.y - cell.center.y;
            self.scrollWasEnabled = collectionView.scrollEnabled;
            collectionView.scrollEnabled = NO;

            snapshot.frame = cell.frame;
            snapshot.layer.shadowColor = UIColor.blackColor.CGColor;
            snapshot.layer.shadowOpacity = 0.18;
            snapshot.layer.shadowRadius = 10.0;
            snapshot.layer.shadowOffset = CGSizeMake(0.0, 4.0);
            [collectionView addSubview:snapshot];
            self.dragSnapshot = snapshot;
            cell.alpha = 0.0;
            [UIView animateWithDuration:0.2
                             animations:^{
                                 snapshot.transform = CGAffineTransformMakeScale(1.03, 1.03);
                             }];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            NSArray<NSArray *> *slots = self.dragSlots;
            if (!self.dragging || slots.count == 0)
                return;
            // The snapshot stays between the first and last pinned rows.
            CGFloat minY = CGRectGetMidY([slots.firstObject[1] CGRectValue]);
            CGFloat maxY = CGRectGetMidY([slots.lastObject[1] CGRectValue]);
            CGFloat centerY = MIN(MAX(location.y - self.dragOffsetY, minY), maxY);
            self.dragSnapshot.center = CGPointMake(self.dragSnapshot.center.x, centerY);
            [collectionView bringSubviewToFront:self.dragSnapshot];

            NSUInteger target = self.dragToIndex;
            CGFloat bestDistance = CGFLOAT_MAX;
            for (NSUInteger index = 0; index < slots.count; index++) {
                CGFloat distance = fabs(CGRectGetMidY([slots[index][1] CGRectValue]) - centerY);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    target = index;
                }
            }
            if (target != self.dragToIndex) {
                self.dragToIndex = target;
                [self layoutDragPreview];
                [[UISelectionFeedbackGenerator new] selectionChanged];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (self.dragging)
                [self finishDragCommitting:YES];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (self.dragging)
                [self finishDragCommitting:NO];
            break;
        default:
            break;
    }
}

- (id)userForRecognizer:(UIGestureRecognizer *)recognizer {
    UICollectionView *collectionView = self.collectionView;
    NSIndexPath *indexPath = [collectionView indexPathForItemAtPoint:[recognizer locationInView:collectionView]];
    if (!indexPath)
        return nil;
    id object = [self objectAtSection:indexPath.section];
    return SPKSearchIsResultViewModel(object) ? SPKSearchUserForViewModel(object) : nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (!SPKSearchPinsEnabled())
        return NO;
    if (self.reordering)
        return [self pinnedIndexPathForRecognizer:recognizer] != nil;
    return [self userForRecognizer:recognizer] != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Scrolling keeps working; a press that starts moving fails on its own allowance.
    // A drag owns the touch.
    return !self.reordering;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (self.reordering || self.dragging) {
        [self handleDrag:recognizer];
        return;
    }
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    id user = [self userForRecognizer:recognizer];
    if (user)
        SPKSearchTogglePin(user, self.adapter);
}

@end

/// The pin gesture state of the list a section controller's context drives.
static SPKSearchPinGestureTarget *SPKSearchPinTargetForContext(id context) {
    if (![context respondsToSelector:@selector(collectionView)])
        return nil;
    UICollectionView *collectionView = ((id (*)(id, SEL))objc_msgSend)(context, @selector(collectionView));
    return collectionView ? objc_getAssociatedObject(collectionView, kSPKSearchPinGestureKey) : nil;
}

/// Attaches the pin hold to the list a search list adapter drives. Reached through
/// the adapter rather than the screen, since the screen hosting the main search
/// differs between builds while its list data source does not.
static void SPKSearchAttachPinGesture(id adapter) {
    if (![adapter respondsToSelector:@selector(collectionView)])
        return;
    UICollectionView *collectionView = ((id (*)(id, SEL))objc_msgSend)(adapter, @selector(collectionView));
    if (![collectionView isKindOfClass:[UICollectionView class]] || objc_getAssociatedObject(collectionView, kSPKSearchPinGestureKey))
        return;
    SPKSearchPinGestureTarget *target = [SPKSearchPinGestureTarget new];
    target.collectionView = collectionView;
    target.adapter = adapter;
    UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                            action:@selector(handleLongPress:)];
    recognizer.delegate = target;
    // The press that pins must not also land as a tap and open the profile.
    recognizer.cancelsTouchesInView = YES;
    [collectionView addGestureRecognizer:recognizer];
    // The recogniser holds its target weakly; the list keeps both alive.
    objc_setAssociatedObject(collectionView, kSPKSearchPinGestureKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKLog(@"General", @"[Sparkle SearchPins] pin gesture attached to %@", NSStringFromClass([collectionView class]));
}

#pragma mark - Hooks

@interface SPKSearchPinsHeaderSectionController : IGListSectionController
@end

%subclass SPKSearchPinsHeaderSectionController : IGListSectionController

- (NSInteger)numberOfItems {
    return 1;
}

- (CGSize)sizeForItemAtIndex:(NSInteger)index {
    return CGSizeMake(self.collectionContext.containerSize.width, 44.0);
}

- (UICollectionViewCell *)cellForItemAtIndex:(NSInteger)index {
    SPKSearchPinsHeaderCell *cell = [self.collectionContext dequeueReusableCellOfClass:[SPKSearchPinsHeaderCell class]
                                                                  forSectionController:self
                                                                               atIndex:index];
    SPKSearchPinGestureTarget *target = SPKSearchPinTargetForContext(self.collectionContext);
    BOOL available = target && SPKSearchCachedEntries().count > 1;
    [cell setReordering:target.reordering available:available];
    __weak SPKSearchPinsHeaderCell *weakCell = cell;
    cell.onReorder = ^{
        target.reordering = !target.reordering;
        [weakCell setReordering:target.reordering available:SPKSearchCachedEntries().count > 1];
    };
    // Leaving the screen ends reorder mode, so the next visit starts out normal.
    cell.onLeaveWindow = ^{
        if (!target.dragging)
            target.reordering = NO;
    };
    return cell;
}

- (BOOL)shouldSelectItemAtIndex:(NSInteger)index {
    return NO;
}

%end

// Rows bound while reordering, scrolled in or rebuilt, get the grabber as well.
static id (*orig_resultCellForItem)(id, SEL, NSInteger);
static id replaced_resultCellForItem(id self, SEL _cmd, NSInteger index) {
    UICollectionViewCell *cell = orig_resultCellForItem(self, _cmd, index);
    if (![cell isKindOfClass:[UICollectionViewCell class]] || (!objc_getAssociatedObject(cell, kSPKSearchGrabberKey) && !SPKSearchPinsEnabled()))
        return cell;
    IGListSectionController *sectionController = self;
    SPKSearchPinGestureTarget *target = SPKSearchPinTargetForContext(sectionController.collectionContext);
    BOOL shown = NO;
    if (target.reordering && [(id)target.adapter respondsToSelector:@selector(objectForSectionController:)]) {
        id object = ((id (*)(id, SEL, id))objc_msgSend)(target.adapter, @selector(objectForSectionController:), self);
        shown = SPKSearchIsPinnedRow(object);
    }
    SPKSearchSetGrabberShown(cell, shown, NO);
    return cell;
}

static id SPKSearchSectionControllerForObject(id object) {
    if (![object isKindOfClass:[SPKSearchPinsHeaderModel class]])
        return nil;
    return [%c(SPKSearchPinsHeaderSectionController) new];
}

static id (*orig_listKitSectionControllerForObject)(id, SEL, id, id);
static id replaced_listKitSectionControllerForObject(id self, SEL _cmd, id adapter, id object) {
    if (SPKSearchPinsEnabled())
        SPKSearchAttachPinGesture(adapter);
    return SPKSearchSectionControllerForObject(object) ?: orig_listKitSectionControllerForObject(self, _cmd, adapter, object);
}

static id (*orig_typeaheadSectionControllerForObject)(id, SEL, id, id);
static id replaced_typeaheadSectionControllerForObject(id self, SEL _cmd, id adapter, id object) {
    if (SPKSearchPinsEnabled())
        SPKSearchAttachPinGesture(adapter);
    return SPKSearchSectionControllerForObject(object) ?: orig_typeaheadSectionControllerForObject(self, _cmd, adapter, object);
}

// Older builds, where the main search's null state comes straight from here.
static id (*orig_nullStateModels)(id, SEL);
static id replaced_nullStateModels(id self, SEL _cmd) {
    return SPKSearchApplyPins(orig_nullStateModels(self, _cmd), self, NO);
}

// Current builds call the null-state source natively from Swift, past any hook on it,
// but the list itself asks the search screen through Objective-C. An empty search
// field is the null state.
static id (*orig_typeaheadViewModels)(id, SEL, id);
static id replaced_typeaheadViewModels(id self, SEL _cmd, id dataSource) {
    id models = orig_typeaheadViewModels(self, _cmd, dataSource);
    if (!SPKSearchPinsEnabled() || ![self respondsToSelector:@selector(searchBarWithCancel)])
        return models;
    IGSearchBarWithCancel *bar = ((id (*)(id, SEL))objc_msgSend)(self, @selector(searchBarWithCancel));
    NSString *text = [bar respondsToSelector:@selector(searchBar)] ? bar.searchBar.text : nil;
    if ([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0)
        return models;
    return SPKSearchApplyPins(models, nil, YES);
}

// Builds that still report a hold on a row through here leave it to the pin gesture,
// so one press never toggles twice.
static void (*orig_searchRowLongPress)(id, SEL, id, id);
static void replaced_searchRowLongPress(id self, SEL _cmd, id cell, id viewModel) {
    if (SPKSearchPinsEnabled() && [self isKindOfClass:objc_getClass("IGListSectionController")]) {
        IGListSectionController *sectionController = self;
        if (SPKSearchUserForViewModel(viewModel) && SPKSearchIsPinnableController(sectionController.viewController))
            return;
    }
    orig_searchRowLongPress(self, _cmd, cell, viewModel);
}

static id (*orig_adapterDequeueCell)(id, SEL, Class, id, NSInteger);
static id replaced_adapterDequeueCell(id self, SEL _cmd, Class cellClass, id sectionController, NSInteger index) {
    UICollectionViewCell *forced = SPKSearchForcedCell;
    if (forced && [forced isKindOfClass:cellClass])
        return forced;
    return orig_adapterDequeueCell(self, _cmd, cellClass, sectionController, index);
}

static BOOL SPKSearchHook(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;
    MSHookMessageEx(cls, selector, replacement, original);
    return YES;
}

// Installed unconditionally: the toggle and the pins are per account, so both are
// read at call time instead of deciding the install.
void SPKInstallSearchPinsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!objc_getClass("IGListSectionController"))
            return;
        %init;

        Class listKit = SPKResolveIGClass(@"IGGenericSearch.IGSearchListKitDataSource", @"IGSearchListKitDataSource");
        Class nullState = SPKResolveIGClass(@"IGGenericSearch.IGSearchNullStateDataSource", @"IGSearchNullStateDataSource");
        Class typeahead = SPKResolveIGClass(@"IGSearchTypeahead.IGSearchNewTypeaheadViewController", nil);
        Class resultSection = SPKResolveIGClass(@"IGSearchViewCells.IGSearchResultSectionController", @"IGSearchResultSectionController");

        BOOL listKitHooked = SPKSearchHook(listKit, @"listAdapter:sectionControllerForObject:",
                                           (IMP)replaced_listKitSectionControllerForObject, (IMP *)&orig_listKitSectionControllerForObject);
        BOOL typeaheadSectionsHooked = SPKSearchHook(typeahead, @"listAdapter:sectionControllerForObject:",
                                                     (IMP)replaced_typeaheadSectionControllerForObject, (IMP *)&orig_typeaheadSectionControllerForObject);
        // Rows are only added where a section controller can be handed out for the header.
        BOOL nullStateHooked = NO, typeaheadModelsHooked = NO;
        if (listKitHooked || typeaheadSectionsHooked) {
            nullStateHooked = SPKSearchHook(nullState, @"nullStateModels", (IMP)replaced_nullStateModels, (IMP *)&orig_nullStateModels);
            typeaheadModelsHooked = SPKSearchHook(typeahead, @"viewModelsForSearchListKitDataSource:",
                                                  (IMP)replaced_typeaheadViewModels, (IMP *)&orig_typeaheadViewModels);
        }
        SPKSearchHook(objc_getClass("IGListAdapter"), @"dequeueReusableCellOfClass:forSectionController:atIndex:",
                      (IMP)replaced_adapterDequeueCell, (IMP *)&orig_adapterDequeueCell);
        SPKSearchHook(resultSection, @"cellForItemAtIndex:", (IMP)replaced_resultCellForItem, (IMP *)&orig_resultCellForItem);
        BOOL longPressHooked = SPKSearchHook(resultSection, @"searchCollectionViewCellDidLongPressCell:viewModel:",
                                             (IMP)replaced_searchRowLongPress, (IMP *)&orig_searchRowLongPress);

        SPKLog(@"General", @"[Sparkle SearchPins] hooks listKit=%d typeaheadSections=%d nullState=%d typeaheadModels=%d longPress=%d recentType=%@",
               listKitHooked, typeaheadSectionsHooked, nullStateHooked, typeaheadModelsHooked, longPressHooked, SPKSearchRecentSectionType());
    });
}
