#import "SPKPreferenceMigrations.h"

#import "../Utils.h"

NSString *const SPKPreferenceMigrationsCompletedKey = @"app_preference_migrations";

/// Converts a legacy value for the new key. Returning nil drops the value.
typedef id _Nullable (^SPKPreferenceMigrationTransform)(id legacyValue);
/// Folds every stored copy of a key (global first when present) into one global
/// value. Returning nil leaves the global key unset.
typedef id _Nullable (^SPKPreferenceMigrationMerge)(NSArray *values);

@interface SPKPreferenceMigration : NSObject
/// Stable identifier recorded once the migration has run. Never reuse or rename one.
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *legacyKey;
/// nil removes the legacy key without carrying its value anywhere.
@property (nonatomic, copy, nullable) NSString *replacementKey;
/// nil copies the value unchanged.
@property (nonatomic, copy, nullable) SPKPreferenceMigrationTransform transform;
/// Copies the value to `replacementKey` and leaves the legacy key in place, for a
/// new setting that splits off from one that keeps existing.
@property (nonatomic, assign) BOOL keepsLegacyKey;
/// Per-migration completion flag written before the shared ledger existed.
@property (nonatomic, copy, nullable) NSString *legacyCompletionFlag;
/// Set when a per-account key becomes device-global: every per-account copy of
/// `legacyKey` is merged into the global key and removed. `replacementKey` and
/// `transform` are unused.
@property (nonatomic, copy, nullable) SPKPreferenceMigrationMerge globalMerge;
@end

@implementation SPKPreferenceMigration
@end

static SPKPreferenceMigration *SPKMigration(NSString *identifier, NSString *legacyKey, NSString *_Nullable replacementKey, SPKPreferenceMigrationTransform _Nullable transform) {
    SPKPreferenceMigration *migration = [SPKPreferenceMigration new];
    migration.identifier = identifier;
    migration.legacyKey = legacyKey;
    migration.replacementKey = replacementKey;
    migration.transform = transform;
    return migration;
}

/// Every preference migration, oldest first. Append new entries at the end; later
/// entries see the results of earlier ones, so chained renames work.
static NSArray<SPKPreferenceMigration *> *SPKPreferenceMigrationList(void) {
    static NSArray<SPKPreferenceMigration *> *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The Instants upload button and the saved-instants button became one
        // button with a menu.
        SPKPreferenceMigration *instantsCameraButton = SPKMigration(@"instants_camera_btn", @"instants_upload_from_gallery", @"instants_camera_btn", nil);
        instantsCameraButton.legacyCompletionFlag = @"instants_camera_btn_migrated";

        // Terminology rename.
        SPKPreferenceMigration *hideRecentSearches = SPKMigration(@"general_hide_recent_searches", @"general_no_recent_searches", @"general_hide_recent_searches", nil);
        hideRecentSearches.legacyCompletionFlag = @"general_hide_recent_searches_migrated";

        // The Progressive Blur toggle became the scroll edge style menu. On forced
        // the soft blur; off installed nothing.
        SPKPreferenceMigration *scrollEdgeStyle = SPKMigration(@"interface_scroll_edge_style", @"interface_progressive_blur", @"interface_scroll_edge_style", ^id(id value) {
            if (![value respondsToSelector:@selector(boolValue)])
                return nil;
            return [value boolValue] ? @"soft" : @"off";
        });

        // The Manually Mark Seen switch for stories became a menu that adds a
        // mode where the eye button toggles seen receipts.
        SPKPreferenceMigration *storyManualSeenMode = SPKMigration(@"stories_manual_seen_mode", @"stories_manual_seen", @"stories_manual_seen_mode", ^id(id value) {
            if (![value respondsToSelector:@selector(boolValue)])
                return nil;
            return [value boolValue] ? @"tap" : @"off";
        });

        // Start Reels Muted became device-global: Instagram keeps one sound state for
        // the whole app and the hooks install once per launch. It is an opt-in, so an
        // account that had it on turns it on for everyone.
        SPKPreferenceMigration *reelsStartMutedGlobal = SPKMigration(@"reels_disable_auto_unmute_global", @"reels_disable_auto_unmute", nil, nil);
        reelsStartMutedGlobal.globalMerge = ^id(NSArray *values) {
            for (id value in values) {
                if ([value respondsToSelector:@selector(boolValue)] && [value boolValue])
                    return @YES;
            }
            return nil;
        };

        // Meta's own-product promotions in the feed were hidden by Hide Suggested
        // Threads before getting their own switch. Anyone who had it on keeps them
        // hidden.
        SPKPreferenceMigration *feedMetaPromotions = SPKMigration(@"feed_hide_meta_promotions", @"feed_hide_suggested_threads", @"feed_hide_meta_promotions", ^id(id value) {
            if (![value respondsToSelector:@selector(boolValue)] || ![value boolValue])
                return nil;
            return @YES;
        });
        feedMetaPromotions.keepsLegacyKey = YES;

        list = @[ instantsCameraButton, hideRecentSearches, scrollEdgeStyle, storyManualSeenMode, reelsStartMutedGlobal, feedMetaPromotions ];
    });
    return list;
}

/// The namespace prefix of a stored copy of `baseKey`: @"" for the global value,
/// @"u_<pk>_" for a per-account one, nil when `key` is not a copy of `baseKey`.
static NSString *SPKPreferenceNamespacePrefix(NSString *key, NSString *baseKey) {
    if ([key isEqualToString:baseKey])
        return @"";
    if (![key hasPrefix:@"u_"] || key.length <= baseKey.length + 3 || ![key hasSuffix:baseKey])
        return nil;
    NSUInteger prefixLength = key.length - baseKey.length;
    if ([key characterAtIndex:prefixLength - 1] != '_')
        return nil;
    NSString *pk = [key substringWithRange:NSMakeRange(2, prefixLength - 3)];
    if (pk.length == 0 || [pk rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
        return nil;
    return [key substringToIndex:prefixLength];
}

/// Applies one migration to `state`, reporting each write through `write` (nil
/// value = remove). A value already stored under the new key always wins.
static void SPKApplyGlobalPromotion(SPKPreferenceMigration *migration, NSMutableDictionary<NSString *, id> *state, void (^_Nullable write)(NSString *key, id _Nullable value)) {
    NSString *globalKey = migration.legacyKey;
    NSMutableArray *values = [NSMutableArray array];
    if (state[globalKey])
        [values addObject:state[globalKey]];
    for (NSString *key in state.allKeys) {
        NSString *prefix = SPKPreferenceNamespacePrefix(key, globalKey);
        if (prefix.length == 0)
            continue;
        [values addObject:state[key]];
        [state removeObjectForKey:key];
        if (write)
            write(key, nil);
    }

    id merged = values.count > 0 ? migration.globalMerge(values) : nil;
    if (merged && ![merged isEqual:state[globalKey]]) {
        state[globalKey] = merged;
        if (write)
            write(globalKey, merged);
    }
}

static void SPKApplyPreferenceMigration(SPKPreferenceMigration *migration, NSMutableDictionary<NSString *, id> *state, void (^_Nullable write)(NSString *key, id _Nullable value)) {
    if (migration.globalMerge) {
        SPKApplyGlobalPromotion(migration, state, write);
        return;
    }
    for (NSString *key in state.allKeys) {
        NSString *prefix = SPKPreferenceNamespacePrefix(key, migration.legacyKey);
        if (!prefix)
            continue;
        id value = state[key];
        if (migration.replacementKey.length > 0) {
            id converted = migration.transform ? migration.transform(value) : value;
            NSString *target = [prefix stringByAppendingString:migration.replacementKey];
            if (converted && !state[target]) {
                state[target] = converted;
                if (write)
                    write(target, converted);
            }
        }
        if (migration.keepsLegacyKey)
            continue;
        [state removeObjectForKey:key];
        if (write)
            write(key, nil);
    }
}

void SPKRunPendingPreferenceMigrations(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSArray *stored = [defaults arrayForKey:SPKPreferenceMigrationsCompletedKey];
        NSMutableOrderedSet<NSString *> *completed = [NSMutableOrderedSet orderedSetWithArray:stored ?: @[]];
        NSUInteger completedCount = completed.count;

        NSMutableArray<SPKPreferenceMigration *> *pending = [NSMutableArray array];
        for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
            if ([completed containsObject:migration.identifier])
                continue;
            if (migration.legacyCompletionFlag.length > 0 && [defaults boolForKey:migration.legacyCompletionFlag]) {
                [completed addObject:migration.identifier];
                continue;
            }
            [pending addObject:migration];
        }

        if (pending.count > 0) {
            // Snapshot once; the working copy carries earlier results into later
            // migrations while every change is mirrored to defaults.
            NSMutableDictionary<NSString *, id> *state = [[defaults dictionaryRepresentation] mutableCopy];
            for (SPKPreferenceMigration *migration in pending) {
                SPKApplyPreferenceMigration(migration, state, ^(NSString *key, id value) {
                    if (value)
                        [defaults setObject:value forKey:key];
                    else
                        [defaults removeObjectForKey:key];
                });
                [completed addObject:migration.identifier];
                SPKLog(@"Preferences", @"Ran preference migration %@", migration.identifier);
            }
        }

        for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
            if (migration.legacyCompletionFlag.length > 0)
                [defaults removeObjectForKey:migration.legacyCompletionFlag];
        }
        if (completed.count != completedCount)
            [defaults setObject:completed.array forKey:SPKPreferenceMigrationsCompletedKey];
    });
}

NSDictionary<NSString *, id> *SPKPreferenceMigrationsAppliedToDictionary(NSDictionary<NSString *, id> *preferences) {
    NSMutableDictionary<NSString *, id> *state = [preferences mutableCopy];
    for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
        SPKApplyPreferenceMigration(migration, state, nil);
    }
    [state removeObjectForKey:SPKPreferenceMigrationsCompletedKey];
    return state;
}
