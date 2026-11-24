#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "SPKSearchRows.h"

// Instagram can show a person in search as an account keyword: a search-term row with
// the person's name that opens a results page, so reaching the profile takes two taps,
// and opening it leaves a keyword entry in Recent. Each account keyword is replaced by
// Instagram's own person row in the same place, or dropped when the person is already
// listed. Ordinary keyword suggestions (topics, places) are left alone.
//
// The request flag that asks for account keywords is deliberately left on: the server
// ranks the person keyword first, so converting it puts the account at the top, while
// with the flag off the account lands below the keyword suggestions, and some people
// still come back as keywords anyway.

static NSString *const kSPKRestoreAccountSearchKey = @"interface_restore_account_search";
static NSString *const kSPKRestoreAccountSearchRowPrefix = @"spk_account_search_";

static BOOL SPKRestoreAccountSearchEnabled(void) {
    return [SPKUtils getBoolPref:kSPKRestoreAccountSearchKey];
}

#pragma mark - Rows

static id SPKRestoreAccountSearchValue(id object, SEL selector) {
    if (![object respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static Class SPKRestoreAccountSearchResultClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGSearchViewModels.IGSearchResultViewModel", @"IGSearchResultViewModel");
    });
    return cls;
}

static BOOL SPKRestoreAccountSearchIsResultRow(id object) {
    Class cls = SPKRestoreAccountSearchResultClass();
    return cls && [object isKindOfClass:cls];
}

/// The person an account keyword row stands for, nil for any other row.
static id SPKRestoreAccountSearchKeywordUser(id row) {
    static Class keywordClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywordClass = SPKResolveIGClass(@"IGSearchModels.IGKeywordSearchModel", @"IGKeywordSearchModel");
    });
    if (!keywordClass || !SPKRestoreAccountSearchIsResultRow(row))
        return nil;
    id keyword = SPKRestoreAccountSearchValue(row, @selector(searchableItem));
    if (![keyword isKindOfClass:keywordClass])
        return nil;
    id user = SPKRestoreAccountSearchValue(keyword, @selector(user));
    return [SPKUtils pkFromIGUser:user] ? user : nil;
}

static NSString *SPKRestoreAccountSearchPersonPK(id row) {
    if (!SPKRestoreAccountSearchIsResultRow(row))
        return nil;
    id item = SPKRestoreAccountSearchValue(row, @selector(searchableItem));
    Class userClass = objc_getClass("IGUser");
    return userClass && [item isKindOfClass:userClass] ? [SPKUtils pkFromIGUser:item] : nil;
}

#pragma mark - Remove button

// The row's designated initializer, found by shape so a renamed argument on another
// build just leaves the remove button off instead of crashing.
static SEL SPKRestoreAccountSearchRowInitializer(Class cls) {
    static SEL selector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"initWithTitle:"] && [name containsString:@"buttonViewModel:"]) {
                selector = method_getName(methods[i]);
                break;
            }
        }
        free(methods);
    });
    return selector;
}

static NSString *SPKRestoreAccountSearchGetterName(NSString *part) {
    if ([part hasPrefix:@"initWith"]) {
        part = [part substringFromIndex:8];
        part = [[[part substringToIndex:1] lowercaseString] stringByAppendingString:[part substringFromIndex:1]];
    }
    return part;
}

/// A copy of `person` with the keyword row's button, so a recent keeps its remove button.
/// Built through the initializer, never by writing into the Swift object: that leaves its
/// reference counts unbalanced and crashes when the row is freed.
static id SPKRestoreAccountSearchWithButton(id person, id keywordRow) {
    Class cls = [person class];
    SEL initializer = SPKRestoreAccountSearchRowInitializer(cls);
    if (!initializer || !SPKRestoreAccountSearchValue(keywordRow, @selector(buttonViewModel)))
        return person;
    @try {
        NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:initializer];
        NSArray<NSString *> *parts = [NSStringFromSelector(initializer) componentsSeparatedByString:@":"];
        if (!signature || signature.numberOfArguments != parts.count + 1)
            return person;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.selector = initializer;
        for (NSUInteger index = 0; index + 1 < parts.count; index++) {
            NSString *getterName = SPKRestoreAccountSearchGetterName(parts[index]);
            id source = [getterName isEqualToString:@"buttonViewModel"] ? keywordRow : person;
            SEL getter = NSSelectorFromString(getterName);
            NSMethodSignature *getterSignature = [source methodSignatureForSelector:getter];
            const char *argumentType = [signature getArgumentTypeAtIndex:index + 2];
            if (!getterSignature || strcmp(getterSignature.methodReturnType, argumentType) != 0)
                return person;
            NSUInteger size = 0;
            NSGetSizeAndAlignment(argumentType, &size, NULL);
            NSInvocation *read = [NSInvocation invocationWithMethodSignature:getterSignature];
            read.selector = getter;
            [read invokeWithTarget:source];
            void *buffer = calloc(1, MAX(size, (NSUInteger)16));
            [read getReturnValue:buffer];
            [invocation setArgument:buffer atIndex:index + 2];
            free(buffer);
        }
        // init consumes the +1 from alloc and returns its own +1, which ARC cannot see
        // through NSInvocation: hold the alloc reference by hand and take the result over.
        void *allocated = (__bridge_retained void *)[cls alloc];
        [invocation invokeWithTarget:(__bridge id)allocated];
        void *result = NULL;
        [invocation getReturnValue:&result];
        id owned = result ? (__bridge_transfer id)result : nil;
        return owned ?: person;
    } @catch (NSException *exception) {
        SPKLog(@"General", @"[Sparkle RestoreAccountSearch] copying the remove button threw: %@", exception);
        return person;
    }
}

// Recent entries live on the server as the keyword, so removing a converted row has to
// remove the keyword. Keyed by person pk.
static NSMutableDictionary<NSString *, id> *SPKRestoreAccountSearchOriginals(void) {
    static NSMutableDictionary *originals;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        originals = [NSMutableDictionary dictionary];
    });
    return originals;
}

// People whose keyword was removed this session: their rows stay out of every list,
// and the keyword the server was told to hide maps back to the row actually on screen.
static NSMutableSet<NSString *> *SPKRestoreAccountSearchHiddenPKs(void) {
    static NSMutableSet *hidden;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hidden = [NSMutableSet set];
    });
    return hidden;
}

static NSMapTable *SPKRestoreAccountSearchShownForHidden(void) {
    static NSMapTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSMapTable strongToStrongObjectsMapTable];
    });
    return table;
}

#pragma mark - Conversion

/// A person row in the keyword row's place: same section, analytics module and source.
static id SPKRestoreAccountSearchPersonRowFor(id keywordRow, id user, NSString *pk) {
    id session = [SPKUtils activeUserSession];
    if (!session)
        return nil;
    NSString *sectionType = SPKRestoreAccountSearchValue(keywordRow, @selector(sectionType));
    NSString *module = SPKRestoreAccountSearchValue(keywordRow, @selector(module));
    unsigned long long sourceType = 0;
    if ([keywordRow respondsToSelector:@selector(sourceType)])
        sourceType = ((unsigned long long (*)(id, SEL))objc_msgSend)(keywordRow, @selector(sourceType));
    id person = SPKSearchPersonRow(user, [sectionType isKindOfClass:[NSString class]] ? sectionType : nil,
                                   [module isKindOfClass:[NSString class]] && module.length > 0 ? module : @"blended_search",
                                   sourceType, [kSPKRestoreAccountSearchRowPrefix stringByAppendingString:pk], session);
    if (!person)
        return nil;
    person = SPKRestoreAccountSearchWithButton(person, keywordRow);
    SPKRestoreAccountSearchOriginals()[pk] = keywordRow;
    return person;
}

typedef struct {
    NSUInteger replaced;
    NSUInteger dropped;
    NSUInteger kept;
} SPKRestoreAccountSearchStats;

/// Rows with every account keyword replaced by the person's row, or dropped when the
/// person is already listed. Nil when nothing changed.
static NSArray *SPKRestoreAccountSearchConvertedRows(NSArray *rows, NSMutableSet<NSString *> *listedPKs, SPKRestoreAccountSearchStats *stats) {
    NSMutableArray *out = nil;
    for (NSUInteger index = 0; index < rows.count; index++) {
        id row = rows[index];
        id user = SPKRestoreAccountSearchKeywordUser(row);
        if (!user) {
            [out addObject:row];
            continue;
        }
        if (!out)
            out = [[rows subarrayWithRange:NSMakeRange(0, index)] mutableCopy];
        NSString *pk = [SPKUtils pkFromIGUser:user];
        if ([listedPKs containsObject:pk] || [SPKRestoreAccountSearchHiddenPKs() containsObject:pk]) {
            stats->dropped++;
            continue;
        }
        id person = SPKRestoreAccountSearchPersonRowFor(row, user, pk);
        if (person) {
            [listedPKs addObject:pk];
            [out addObject:person];
            stats->replaced++;
        } else {
            [out addObject:row]; // no factory on this build: better the keyword than nothing
            stats->kept++;
        }
    }
    return out;
}

static Class SPKRestoreAccountSearchHorizontalRecentsClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGSearchViewModels.IGSearchRecentSearchesHorizontalViewModel", @"IGSearchRecentSearchesHorizontalViewModel");
    });
    return cls;
}

static id SPKRestoreAccountSearchApply(id models) {
    if (!SPKRestoreAccountSearchEnabled() || ![models isKindOfClass:[NSArray class]] || [models count] == 0)
        return models;
    NSArray *list = models;

    // People already listed as themselves, so a keyword for them is a duplicate.
    NSMutableSet<NSString *> *listedPKs = [NSMutableSet set];
    Class horizontal = SPKRestoreAccountSearchHorizontalRecentsClass();
    for (id object in list) {
        NSArray *rows = horizontal && [object isKindOfClass:horizontal] ? SPKRestoreAccountSearchValue(object, @selector(items)) : @[ object ];
        if (![rows isKindOfClass:[NSArray class]])
            continue;
        for (id row in rows) {
            NSString *pk = SPKRestoreAccountSearchPersonPK(row);
            if (pk)
                [listedPKs addObject:pk];
        }
    }

    BOOL changed = NO;
    SPKRestoreAccountSearchStats stats = {0, 0, 0};
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:list.count];
    for (id object in list) {
        if (horizontal && [object isKindOfClass:horizontal] && [object respondsToSelector:@selector(initWithItems:)]) {
            NSArray *items = SPKRestoreAccountSearchValue(object, @selector(items));
            NSArray *converted = [items isKindOfClass:[NSArray class]] ? SPKRestoreAccountSearchConvertedRows(items, listedPKs, &stats) : nil;
            if (converted) {
                changed = YES;
                if (converted.count == 0)
                    continue;
                id rebuilt = [[[object class] alloc] initWithItems:converted];
                [out addObject:rebuilt ?: object];
                continue;
            }
            [out addObject:object];
            continue;
        }
        NSArray *converted = SPKRestoreAccountSearchConvertedRows(@[ object ], listedPKs, &stats);
        if (converted) {
            changed = YES;
            [out addObjectsFromArray:converted];
        } else {
            [out addObject:object];
        }
    }
    if (!changed)
        return models;

    // IG rebuilds these lists on every keystroke and layout pass, and several hooked layers
    // hand the same rows along, so only log when the outcome differs from the last one.
    static NSString *lastSummary;
    NSString *summary = [NSString stringWithFormat:@"%lu replaced, %lu duplicates dropped, %lu kept as keywords (%lu rows to %lu)",
                                                   (unsigned long)stats.replaced, (unsigned long)stats.dropped, (unsigned long)stats.kept,
                                                   (unsigned long)list.count, (unsigned long)out.count];
    if (![summary isEqualToString:lastSummary]) {
        lastSummary = summary;
        SPKLog(@"General", @"[Sparkle RestoreAccountSearch] account keywords: %@", summary);
    }
    return out;
}

#pragma mark - Hooks

// The lists the search screens draw from: results, the null state (Recent) and the
// "See all" recent searches screen.
static id (*orig_typeaheadObjects)(id, SEL, id);
static id replaced_typeaheadObjects(id self, SEL _cmd, id adapter) {
    return SPKRestoreAccountSearchApply(orig_typeaheadObjects(self, _cmd, adapter));
}

static id (*orig_typeaheadViewModels)(id, SEL, id);
static id replaced_typeaheadViewModels(id self, SEL _cmd, id dataSource) {
    return SPKRestoreAccountSearchApply(orig_typeaheadViewModels(self, _cmd, dataSource));
}

static id (*orig_nullStateModels)(id, SEL);
static id replaced_nullStateModels(id self, SEL _cmd) {
    return SPKRestoreAccountSearchApply(orig_nullStateModels(self, _cmd));
}

static id (*orig_mainTypeaheadModels)(id, SEL);
static id replaced_mainTypeaheadModels(id self, SEL _cmd) {
    return SPKRestoreAccountSearchApply(orig_mainTypeaheadModels(self, _cmd));
}

static id (*orig_legacyTypeaheadModels)(id, SEL);
static id replaced_legacyTypeaheadModels(id self, SEL _cmd) {
    return SPKRestoreAccountSearchApply(orig_legacyTypeaheadModels(self, _cmd));
}

static id (*orig_editHistoryObjects)(id, SEL, id);
static id replaced_editHistoryObjects(id self, SEL _cmd, id adapter) {
    return SPKRestoreAccountSearchApply(orig_editHistoryObjects(self, _cmd, adapter));
}

// The remove button hides the item through this helper. A converted row is swapped back
// for its keyword, which is what the server stores.
static void (*orig_hideItem)(id, SEL, id, long long);
static void replaced_hideItem(id self, SEL _cmd, id item, long long position) {
    id original = nil;
    if (SPKRestoreAccountSearchEnabled()) {
        // A converted row still holds the very user object taken from its keyword, which
        // tells it apart from a real person recent of the same account. Some builds hand
        // over the row, others its item.
        id user = SPKRestoreAccountSearchIsResultRow(item) ? SPKRestoreAccountSearchValue(item, @selector(searchableItem)) : item;
        NSString *pk = [SPKUtils pkFromIGUser:user];
        id keywordRow = pk ? SPKRestoreAccountSearchOriginals()[pk] : nil;
        id keyword = SPKRestoreAccountSearchValue(keywordRow, @selector(searchableItem));
        if (keyword && SPKRestoreAccountSearchValue(keyword, @selector(user)) == user) {
            original = SPKRestoreAccountSearchIsResultRow(item) ? keywordRow : keyword;
            [SPKRestoreAccountSearchHiddenPKs() addObject:pk];
            [SPKRestoreAccountSearchShownForHidden() setObject:item forKey:original];
            SPKLog(@"General", @"[Sparkle RestoreAccountSearch] removing the keyword behind a converted row");
        }
    }
    orig_hideItem(self, _cmd, original ?: item, position);
}

// When the hide succeeds the screen is told which item went, and removes it from what it
// shows. That item is the keyword, while the screen shows the converted row, so the
// screen is also told about the row it actually has.
#define SPK_RESTORE_DID_HIDE(name)                                                         \
    static void (*orig_didHide_##name)(id, SEL, id);                                       \
    static void replaced_didHide_##name(id self, SEL _cmd, id item) {                      \
        orig_didHide_##name(self, _cmd, item);                                             \
        id shown = item ? [SPKRestoreAccountSearchShownForHidden() objectForKey:item] : nil; \
        if (shown && shown != item) {                                                      \
            [SPKRestoreAccountSearchShownForHidden() removeObjectForKey:item];             \
            orig_didHide_##name(self, _cmd, shown);                                        \
        }                                                                                  \
    }

SPK_RESTORE_DID_HIDE(typeahead)
SPK_RESTORE_DID_HIDE(seeAll)
SPK_RESTORE_DID_HIDE(mainList)
SPK_RESTORE_DID_HIDE(results)

#pragma mark - Install

static BOOL SPKRestoreAccountSearchHook(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;
    MSHookMessageEx(cls, selector, replacement, original);
    return YES;
}

// Installed unconditionally: the setting can be per account, so it is read at call time.
void SPKInstallRestoreAccountSearchHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class typeahead = SPKResolveIGClass(@"IGSearchTypeahead.IGSearchNewTypeaheadViewController", nil);
        Class nullState = SPKResolveIGClass(@"IGGenericSearch.IGSearchNullStateDataSource", @"IGSearchNullStateDataSource");
        BOOL objects = SPKRestoreAccountSearchHook(typeahead, @"objectsForListAdapter:", (IMP)replaced_typeaheadObjects, (IMP *)&orig_typeaheadObjects);
        BOOL viewModels = SPKRestoreAccountSearchHook(typeahead, @"viewModelsForSearchListKitDataSource:",
                                                      (IMP)replaced_typeaheadViewModels, (IMP *)&orig_typeaheadViewModels);
        BOOL nullModels = SPKRestoreAccountSearchHook(nullState, @"nullStateModels", (IMP)replaced_nullStateModels, (IMP *)&orig_nullStateModels);
        BOOL mainModels = SPKRestoreAccountSearchHook(objc_getClass("IGSearchMainTypeaheadDataSource"), @"models",
                                                      (IMP)replaced_mainTypeaheadModels, (IMP *)&orig_mainTypeaheadModels);
        BOOL legacyModels = SPKRestoreAccountSearchHook(objc_getClass("IGSearchTypeaheadDataSource"), @"models",
                                                        (IMP)replaced_legacyTypeaheadModels, (IMP *)&orig_legacyTypeaheadModels);
        BOOL seeAll = SPKRestoreAccountSearchHook(SPKResolveIGClass(@"IGSearchEditHistory.IGEditSearchResultViewController", @"IGEditSearchResultViewController"), @"objectsForListAdapter:",
                                                  (IMP)replaced_editHistoryObjects, (IMP *)&orig_editHistoryObjects);
        BOOL hide = SPKRestoreAccountSearchHook(SPKResolveIGClass(@"IGSearchKit.IGSearchHideHelper", @"IGSearchHideHelper"), @"hideItem:itemPosition:",
                                                (IMP)replaced_hideItem, (IMP *)&orig_hideItem);
        Class seeAllClass = SPKResolveIGClass(@"IGSearchEditHistory.IGEditSearchResultViewController", @"IGEditSearchResultViewController");
        NSString *didHide = @"searchHideHelperDidHideItem:";
        int hideCallbacks = SPKRestoreAccountSearchHook(typeahead, didHide, (IMP)replaced_didHide_typeahead, (IMP *)&orig_didHide_typeahead) +
                            SPKRestoreAccountSearchHook(seeAllClass, didHide, (IMP)replaced_didHide_seeAll, (IMP *)&orig_didHide_seeAll) +
                            SPKRestoreAccountSearchHook(objc_getClass("IGSearchMainTypeaheadListViewController"), didHide, (IMP)replaced_didHide_mainList,
                                                        (IMP *)&orig_didHide_mainList) +
                            SPKRestoreAccountSearchHook(objc_getClass("IGSearchResultsViewController"), didHide, (IMP)replaced_didHide_results,
                                                        (IMP *)&orig_didHide_results);
        BOOL buttonInit = SPKRestoreAccountSearchRowInitializer(SPKRestoreAccountSearchResultClass()) != NULL;

        SPKLog(@"General", @"[Sparkle RestoreAccountSearch] hooks objects=%d viewModels=%d nullState=%d main=%d legacy=%d seeAll=%d hide=%d hideCallbacks=%d buttonInit=%d",
               objects, viewModels, nullModels, mainModels, legacyModels, seeAll, hide, hideCallbacks, buttonInit);
    });
}
