#import "SPKStrings.h"
#import "SPKAutoSaveFilter.h"

#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../UI/SPKNotificationCenter.h"

@implementation SPKAutoSaveFilterConfig
@end

#pragma mark - Filter mode

NSString *SPKAutoSaveFilterNormalizedUsername(NSString *username) {
    NSString *trimmed = [SPKStringFromValue(username) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if ([trimmed hasPrefix:@"@"])
        trimmed = [trimmed substringFromIndex:1];
    return trimmed;
}

BOOL SPKAutoSaveFilterEnabled(SPKAutoSaveFilterConfig *config) {
    return [SPKUtils getBoolPref:config.enabledKey];
}

BOOL SPKAutoSaveFilterAllMode(SPKAutoSaveFilterConfig *config) {
    if (config.allModeProvider)
        return config.allModeProvider();
    NSString *mode = [SPKUtils getStringPref:config.filterModeKey];
    // Default "all": enabling auto-save should just work without curating a list first.
    return mode.length == 0 || [mode isEqualToString:@"all"];
}

NSString *SPKAutoSaveFilterListTitle(SPKAutoSaveFilterConfig *config) {
    if (config.listTitleProvider)
        return config.listTitleProvider();
    return [NSString stringWithFormat:@"%@ %@",
                                      SPKAutoSaveFilterAllMode(config) ? SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_EXCLUDED_TEXT") : SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_SELECTED_TEXT"),
                                      config.subjectPlural];
}

static NSString *SPKAutoSaveFilterActiveListKey(SPKAutoSaveFilterConfig *config) {
    return SPKAutoSaveFilterAllMode(config) ? config.excludedKey : config.includedKey;
}

#pragma mark - List storage

// A username identity is normalized on both write and read, so entries stay comparable
// no matter how they were typed in.
static BOOL SPKAutoSaveFilterIdentityIsUsername(SPKAutoSaveFilterConfig *config) {
    return [config.identityField isEqualToString:@"username"];
}

static NSString *SPKAutoSaveFilterNormalizedIdentity(SPKAutoSaveFilterConfig *config, NSString *identity) {
    return SPKAutoSaveFilterIdentityIsUsername(config) ? SPKAutoSaveFilterNormalizedUsername(identity)
                                                       : SPKStringFromValue(identity);
}

static NSArray<NSDictionary *> *SPKAutoSaveFilterEntriesFromRawValue(SPKAutoSaveFilterConfig *config, id rawStored) {
    if (![rawStored isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentities = [NSMutableSet set];

    for (id value in (NSArray *)rawStored) {
        if (![value isKindOfClass:[NSDictionary class]])
            continue;
        NSDictionary *dict = (NSDictionary *)value;

        NSMutableDictionary *entry = [dict mutableCopy];
        // Normalize before the identity is read, so a username identity dedupes on its
        // normalized form.
        NSString *username = SPKAutoSaveFilterNormalizedUsername(dict[@"username"]);
        if (username.length > 0)
            entry[@"username"] = username;

        NSString *identity = SPKAutoSaveFilterNormalizedIdentity(config, entry[config.identityField]);
        if (identity.length == 0 || [seenIdentities containsObject:identity])
            continue;
        [seenIdentities addObject:identity];

        if (!entry[@"fullName"])
            entry[@"fullName"] = @"";
        [entries addObject:entry.copy];
    }
    return entries.copy;
}

static NSString *SPKAutoSaveFilterResolvedListKey(SPKAutoSaveFilterConfig *config, NSString *key) {
    if (!config.alwaysAccountScopedLists)
        return SPKEffectivePreferenceKey(key);
    NSString *pk = [SPKAccountManager preferenceNamespacePK];
    return pk.length > 0 ? [NSString stringWithFormat:@"u_%@_%@", pk, key] : nil;
}

NSArray<NSDictionary *> *SPKAutoSaveFilterList(SPKAutoSaveFilterConfig *config) {
    NSString *baseKey = SPKAutoSaveFilterActiveListKey(config);
    if (!config.alwaysAccountScopedLists)
        return SPKAutoSaveFilterEntriesFromRawValue(config, SPKPreferenceObjectForKey(baseKey));
    NSString *resolvedKey = SPKAutoSaveFilterResolvedListKey(config, baseKey);
    id raw = resolvedKey.length > 0 ? [NSUserDefaults.standardUserDefaults objectForKey:resolvedKey] : nil;
    return SPKAutoSaveFilterEntriesFromRawValue(config, raw);
}

void SPKAutoSaveFilterSetList(SPKAutoSaveFilterConfig *config, NSArray<NSDictionary *> *entries) {
    NSArray *normalized = SPKAutoSaveFilterEntriesFromRawValue(config, entries);
    NSString *baseKey = SPKAutoSaveFilterActiveListKey(config);
    if (!config.alwaysAccountScopedLists) {
        SPKPreferenceSetObject(normalized, baseKey);
        return;
    }
    NSString *resolvedKey = SPKAutoSaveFilterResolvedListKey(config, baseKey);
    if (resolvedKey.length > 0)
        [NSUserDefaults.standardUserDefaults setObject:normalized forKey:resolvedKey];
}

BOOL SPKAutoSaveFilterListContains(SPKAutoSaveFilterConfig *config, NSString *identity) {
    NSString *needle = SPKAutoSaveFilterNormalizedIdentity(config, identity);
    if (needle.length == 0)
        return NO;
    for (NSDictionary *entry in SPKAutoSaveFilterList(config)) {
        NSString *value = SPKStringFromValue(entry[config.identityField]);
        if (value.length > 0 && [needle isEqualToString:value])
            return YES;
    }
    return NO;
}

BOOL SPKAutoSaveFilterApplies(SPKAutoSaveFilterConfig *config, NSString *identity) {
    BOOL listed = SPKAutoSaveFilterListContains(config, identity);
    // All -> the list excludes; Selected -> the list includes.
    return SPKAutoSaveFilterAllMode(config) ? !listed : listed;
}

BOOL SPKAutoSaveFilterToggleEntry(SPKAutoSaveFilterConfig *config, NSDictionary *entry) {
    NSString *identity = SPKAutoSaveFilterNormalizedIdentity(config, entry[config.identityField]);
    if (identity.length == 0)
        return NO;

    NSMutableArray<NSDictionary *> *entries = [SPKAutoSaveFilterList(config) mutableCopy];
    for (NSInteger idx = 0; idx < (NSInteger)entries.count; idx++) {
        NSString *value = SPKStringFromValue(entries[idx][config.identityField]);
        if (value.length > 0 && [identity isEqualToString:value]) {
            [entries removeObjectAtIndex:idx];
            SPKAutoSaveFilterSetList(config, entries.copy);
            return NO;
        }
    }

    NSMutableDictionary *added = [entry mutableCopy];
    added[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);
    [entries addObject:added.copy];
    NSString *sortField = config.sortField;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [SPKStringFromValue(a[sortField]) localizedCaseInsensitiveCompare:SPKStringFromValue(b[sortField])];
    }];
    SPKAutoSaveFilterSetList(config, entries.copy);
    return YES;
}

void SPKAutoSaveFilterRemoveIdentity(SPKAutoSaveFilterConfig *config, NSString *identity) {
    NSString *needle = SPKAutoSaveFilterNormalizedIdentity(config, identity);
    if (needle.length == 0)
        return;
    NSMutableArray<NSDictionary *> *entries = [SPKAutoSaveFilterList(config) mutableCopy];
    for (NSUInteger idx = 0; idx < entries.count; idx++) {
        NSString *value = SPKStringFromValue(entries[idx][config.identityField]);
        if (value.length > 0 && [needle isEqualToString:value]) {
            [entries removeObjectAtIndex:idx];
            break;
        }
    }
    SPKAutoSaveFilterSetList(config, entries.copy);
}

NSString *SPKAutoSaveFilterSummary(SPKAutoSaveFilterConfig *config) {
    if (!SPKAutoSaveFilterEnabled(config))
        return SPKL(@"MENU_OFF");
    NSUInteger count = SPKAutoSaveFilterList(config).count;
    if (SPKAutoSaveFilterAllMode(config)) {
        return count == 0 ? [NSString stringWithFormat:@"All %@", config.subjectPlural]
                          : [NSString stringWithFormat:SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_VALUE_EXCLUDED_FORMAT"), (unsigned long)count];
    }
    return count == 0 ? SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_NONE_SELECTED_TEXT") : [NSString stringWithFormat:SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_VALUE_SELECTED_FORMAT"), (unsigned long)count];
}

#pragma mark - List screen

static NSInteger SPKAutoSaveFilterVisibleListCount = 0;

BOOL SPKAutoSaveFilterListUIVisible(void) {
    return SPKAutoSaveFilterVisibleListCount > 0;
}

@implementation SPKAutoSaveFilterListViewController

- (instancetype)initWithConfig:(SPKAutoSaveFilterConfig *)config {
    if ((self = [super init])) {
        _config = config;
        self.title = SPKAutoSaveFilterListTitle(config);
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    SPKAutoSaveFilterVisibleListCount++;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    SPKAutoSaveFilterVisibleListCount = MAX(0, SPKAutoSaveFilterVisibleListCount - 1);
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    return nil;
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
    NSString *modeTitle = SPKAutoSaveFilterAllMode(self.config) ? SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_EXCLUDED_TEXT") : SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_SELECTED_TEXT");
    self.title = count > 0 ? [NSString stringWithFormat:@"%lu %@", (unsigned long)count, modeTitle]
                           : SPKAutoSaveFilterListTitle(self.config);
}

- (void)didDeleteItem:(SPKUserListItem *)item {
    NSDictionary *entry = item.representedObject;
    if (![entry isKindOfClass:[NSDictionary class]])
        return;
    NSString *identity = SPKStringFromValue(entry[self.config.identityField]);
    if (identity.length == 0)
        return;

    SPKAutoSaveFilterRemoveIdentity(self.config, identity);

    NSString *name = [self removalDisplayNameForEntry:entry];
    SPKNotify(self.config.ruleNotificationIdentifier,
              name.length > 0 ? [NSString stringWithFormat:SPKL(@"COMMON_REMOVED_VALUE_FORMAT"), name] : SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_REMOVED_ENTRY_TEXT"),
              SPKAutoSaveFilterListTitle(self.config),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end
