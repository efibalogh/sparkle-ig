//  SPKLanguagePackUpdater.m

#import "SPKLanguagePackUpdater.h"
#import "SPKLanguagePack.h"
#import "SPKLanguagePackCatalog.h"
#import "SPKLanguagePackURLImporter.h"
#import "SPKStrings.h"
#import "../UI/SPKNotificationCenter.h"
#import "../../Tweak.h"
#import "../../Utils.h"

NSString *const kSPKLanguagePackAutoUpdateKey = @"language_pack_auto_update";
static NSString *const kSPKLastUpdateCheckKey = @"language_pack_last_update_check";
// Separate from the last SUCCESSFUL check: without it, a device that simply has no network would
// re-attempt the whole fetch on every single launch, because nothing would ever have been recorded.
static NSString *const kSPKLastUpdateAttemptKey = @"language_pack_last_update_attempt";
// The Sparkle version whose packs are already on disk. Stamped only after a check completes, so an
// update installed while offline stays pending across launches instead of being marked done.
static NSString *const kSPKSyncedVersionKey = @"language_pack_synced_version";

// Held off the very first moments of launch: the check is background work competing with the feed,
// and nothing about it is urgent.
static const NSTimeInterval kSPKUpdateCheckLaunchDelay = 12.0;
// How long a failed attempt is left alone. Long enough that being offline costs one attempt an hour
// rather than one per launch, short enough that connectivity coming back is noticed the same day.
static const NSTimeInterval kSPKUpdateRetryInterval = 60 * 60;

@implementation SPKLanguagePackUpdater

+ (BOOL)autoUpdateEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Registered as a bootstrap default, but a pack can be installed before that runs on a first
    // launch, so an absent value means on rather than off.
    id value = [defaults objectForKey:kSPKLanguagePackAutoUpdateKey];
    return value == nil ? YES : [defaults boolForKey:kSPKLanguagePackAutoUpdateKey];
}

+ (void)setAutoUpdateEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSPKLanguagePackAutoUpdateKey];
}

+ (nullable NSDate *)lastCheckDate {
    NSTimeInterval stamp = [NSUserDefaults.standardUserDefaults doubleForKey:kSPKLastUpdateCheckKey];
    return stamp > 0 ? [NSDate dateWithTimeIntervalSince1970:stamp] : nil;
}

/// Installed packs that name a published build, as code → recorded sha256. A pack imported from a
/// file has no recorded hash and is deliberately left alone: the user put it there by hand, possibly
/// as a translation they are working on, and replacing it from a release would throw that away.
+ (NSDictionary<NSString *, NSString *> *)trackedPacks {
    NSMutableDictionary<NSString *, NSString *> *tracked = [NSMutableDictionary dictionary];
    for (NSString *code in SPKInstalledLanguagePackCodes()) {
        NSString *sha = SPKLanguagePackRecordedSHA256(code);
        if (sha.length)
            tracked[code] = sha;
    }
    return tracked;
}

+ (BOOL)hasTrackedPacks {
    return [self trackedPacks].count > 0;
}

+ (BOOL)packsAreBehindTheInstalledVersion {
    id synced = [NSUserDefaults.standardUserDefaults objectForKey:kSPKSyncedVersionKey];
    // A missing stamp means packs installed before this became version-driven. Treating that as
    // pending costs one check and puts every existing user on the same footing as a new one.
    return ![synced isKindOfClass:[NSString class]] || ![synced isEqualToString:SPKVersionString];
}

+ (void)checkForUpdatesIfDue {
    if (![self autoUpdateEnabled])
        return;
    if ([self trackedPacks].count == 0) {
        // Nothing installed that tracks a release, so there is no reason to touch the network. A date
        // left from when one was installed (a pack later retired because its language now ships with
        // Sparkle) would otherwise describe a check that can no longer run, so it goes too.
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kSPKLastUpdateCheckKey];
        return;
    }
    // Each pack is an asset of a published release, so its contents cannot change between releases.
    // Polling on a timer would spend a request a day to be told that; the version moving is the only
    // event that can make a pack stale, and it is also what keeps a pack and the binary reading it in
    // step, so a pack never describes strings this build does not have.
    if (![self packsAreBehindTheInstalledVersion])
        return;
    // Back off after a failure instead of retrying on every launch.
    NSTimeInterval lastAttempt = [NSUserDefaults.standardUserDefaults doubleForKey:kSPKLastUpdateAttemptKey];
    if (lastAttempt > 0 && NSDate.date.timeIntervalSince1970 - lastAttempt < kSPKUpdateRetryInterval)
        return;
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kSPKLastUpdateAttemptKey];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKUpdateCheckLaunchDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self performCheck];
    });
}

+ (void)checkForUpdatesNow:(nullable void (^)(NSInteger refreshed, NSError *_Nullable error))completion {
    // Deliberately ignores the version stamp and the retry backoff: this runs because the user asked,
    // and the case it exists for is a pack republished under a release that is already installed.
    [self performCheckWithCompletion:completion];
}

+ (void)performCheck {
    [self performCheckWithCompletion:nil];
}

+ (void)performCheckWithCompletion:(nullable void (^)(NSInteger, NSError *_Nullable))completion {
    void (^report)(NSInteger, NSError *_Nullable) = ^(NSInteger refreshed, NSError *_Nullable failure) {
        if (!completion)
            return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(refreshed, failure); });
    };

    NSDictionary<NSString *, NSString *> *tracked = [self trackedPacks];
    if (tracked.count == 0) {
        report(0, nil);
        return;
    }

    [SPKLanguagePackCatalog fetchEntriesWithCompletion:^(NSArray<SPKLanguageCatalogEntry *> *entries, NSError *error) {
        if (!entries) {
            SPKLog(@"i18n", @"[LangPackUpdate] catalog unavailable, leaving packs as they are");
            report(0, error);
            return;
        }
        // Only rows naming a language already installed, and only where the published hash differs
        // from the one on disk. A row without a hash cannot be compared, so it is left alone rather
        // than re-downloaded on every check.
        NSMutableArray<SPKLanguageCatalogEntry *> *stale = [NSMutableArray array];
        for (SPKLanguageCatalogEntry *entry in entries) {
            NSString *installedSHA = tracked[entry.code];
            if (!installedSHA) {
                for (NSString *code in tracked) {  // catalog casing need not match the folder's
                    if ([code caseInsensitiveCompare:entry.code] == NSOrderedSame) {
                        installedSHA = tracked[code];
                        break;
                    }
                }
            }
            if (installedSHA.length && entry.sha256.length && ![entry.sha256 isEqualToString:installedSHA])
                [stale addObject:entry];
        }
        [NSUserDefaults.standardUserDefaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kSPKLastUpdateCheckKey];
        // Reaching the catalog is what the stamp records, not finding work in it. Stamping only on a
        // refresh would leave a user whose packs were already current re-checking on every launch.
        [NSUserDefaults.standardUserDefaults setObject:SPKVersionString forKey:kSPKSyncedVersionKey];
        if (stale.count == 0) {
            SPKLog(@"i18n", @"[LangPackUpdate] %lu tracked pack(s), all current", (unsigned long)tracked.count);
            report(0, nil);
            return;
        }
        SPKLog(@"i18n", @"[LangPackUpdate] %lu pack(s) out of date", (unsigned long)stale.count);
        [self installSequentially:stale index:0 updated:[NSMutableArray array] completion:report];
    }];
}

/// One at a time: each install rewrites a directory the string layer reads, and the whole point is
/// that this is invisible, so there is nothing to gain from racing several downloads at launch.
+ (void)installSequentially:(NSArray<SPKLanguageCatalogEntry *> *)entries
                      index:(NSUInteger)index
                    updated:(NSMutableArray<NSString *> *)updated
                 completion:(void (^)(NSInteger, NSError *_Nullable))completion {
    if (index >= entries.count) {
        if (updated.count > 0) {
            [SPKStrings languagePacksDidChange];
            [self announceUpdated:updated];
        }
        completion((NSInteger)updated.count, nil);
        return;
    }
    SPKLanguageCatalogEntry *entry = entries[index];
    [SPKLanguagePackURLImporter importFromURL:entry.url
                               expectedSHA256:entry.sha256
                                     progress:nil
                                   completion:^(SPKLanguagePack *pack, NSError *error) {
        if (pack) {
            SPKLog(@"i18n", @"[LangPackUpdate] refreshed %@ (%lu strings)", pack.code, (unsigned long)pack.stringCount);
            [updated addObject:entry.displayName];
        } else {
            // A failed refresh leaves the older pack in place, which still renders the app. Retrying
            // now would only spend the user's data on the same failure, so the next check gets it.
            SPKWarnLog(@"i18n", @"[LangPackUpdate] could not refresh %@: %@", entry.code, error.localizedDescription);
        }
        [self installSequentially:entries index:index + 1 updated:updated completion:completion];
    }];
}

+ (void)announceUpdated:(NSArray<NSString *> *)names {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The languages are named in the subtitle, so the title carries no count and needs no plural.
        NSString *subtitle = [names componentsJoinedByString:SPKL(@"COMMON_LIST_SEPARATOR")];
        SPKNotify(kSPKNotificationLanguagePackUpdate,
                  SPKL(@"LANGUAGE_PACK_UPDATED_TOAST"),
                  subtitle,
                  @"translate",
                  SPKNotificationToneForIconResource(@"translate"));
    });
}

@end
