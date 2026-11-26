#import "SPKProfileAnalyzerAutoRefresh.h"
#import "SPKStrings.h"
#import <UIKit/UIKit.h>

#import "../../../App/SPKStabilityGuard.h"
#import "../../../Shared/Account/SPKAccountManager.h"
#import "../../../Shared/UI/SPKNotificationCenter.h"
#import "../../../Utils.h"
#import "SPKProfileAnalyzerModels.h"
#import "SPKProfileAnalyzerService.h"
#import "SPKProfileAnalyzerStorage.h"
#import "SPKProfileAnalyzerViewController.h"

NSString *const kSPKPrefProfileAnalyzerAutoRefreshHours = @"profile_analyzer_auto_refresh_hours";

// Internal bookkeeping keyed by account PK, not a preference.
static NSString *const kSPKPAAutoAttemptsKey = @"spk_profile_analyzer_auto_refresh_attempts";

static const NSTimeInterval kSPKPALaunchStableDelay = 3.0;
static const NSTimeInterval kSPKPAForegroundDelay = 3.0;
// An account switch is announced before Instagram swaps the session over.
static const NSTimeInterval kSPKPAAccountSwitchDelay = 8.0;
// A failed scan is not retried sooner than this, so reopening the app cannot hammer
// the friendships endpoints.
static const NSTimeInterval kSPKPARetryInterval = 60.0 * 60.0;

@implementation SPKProfileAnalyzerAutoRefresh

+ (NSArray<NSNumber *> *)intervalChoices {
    return @[ @0, @24, @72, @168, @336 ];
}

+ (NSString *)titleForIntervalHours:(NSInteger)hours {
    switch (hours) {
    case 0:
        return SPKL(@"MENU_OFF");
    case 24:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_EVERY_DAY_TEXT");
    case 72:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_3_DAYS_TEXT");
    case 168:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_EVERY_WEEK_TEXT");
    case 336:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_2_WEEKS_TEXT");
    default:
        return [NSString stringWithFormat:@"%ldh", (long)hours];
    }
}

+ (NSInteger)intervalHours {
    return MAX(0, (NSInteger)[SPKUtils getDoublePref:kSPKPrefProfileAnalyzerAutoRefreshHours]);
}

+ (void)setIntervalHours:(NSInteger)hours {
    SPKPreferenceSetObject(@(MAX(0, hours)), kSPKPrefProfileAnalyzerAutoRefreshHours);
    [self checkIfDue];
}

#pragma mark - Attempt bookkeeping

+ (nullable NSDate *)lastAttemptForPK:(NSString *)pk {
    NSDictionary *attempts = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKPAAutoAttemptsKey];
    id value = attempts[pk];
    return [value isKindOfClass:[NSDate class]] ? value : nil;
}

+ (void)recordAttemptForPK:(NSString *)pk {
    NSMutableDictionary *attempts = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKPAAutoAttemptsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    attempts[pk] = [NSDate date];
    [[NSUserDefaults standardUserDefaults] setObject:attempts forKey:kSPKPAAutoAttemptsKey];
}

#pragma mark - Scheduling

+ (void)checkAfterDelay:(NSTimeInterval)delay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkIfDue) object:nil];
    [self performSelector:@selector(checkIfDue) withObject:nil afterDelay:delay];
}

+ (void)appDidBecomeActive:(NSNotification *)note {
    [self checkAfterDelay:kSPKPAForegroundDelay];
}

+ (void)launchDidStabilize:(NSNotification *)note {
    [self checkAfterDelay:kSPKPALaunchStableDelay];
}

+ (void)accountDidChange:(NSNotification *)note {
    [self checkAfterDelay:kSPKPAAccountSwitchDelay];
}

+ (void)checkIfDue {
    NSInteger hours = [self intervalHours];
    if (hours <= 0)
        return;
    // A scan is heavy network work; keep it out of a launch that may still crash or hang.
    if (!SPKStabilityGuardIsLaunchStable())
        return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return;
    if ([NSProcessInfo processInfo].isLowPowerModeEnabled)
        return;
    SPKProfileAnalyzerService *service = [SPKProfileAnalyzerService sharedService];
    if (service.isRunning)
        return;

    NSString *pk = [SPKUtils currentUserPK];
    if (!pk.length)
        return;

    // The first scan stays a manual choice.
    SPKProfileAnalyzerSnapshot *current = [SPKProfileAnalyzerStorage currentSnapshotForUserPK:pk];
    if (!current.scanDate)
        return;

    NSTimeInterval interval = (NSTimeInterval)hours * 60.0 * 60.0;
    NSDate *now = [NSDate date];
    if ([now timeIntervalSinceDate:current.scanDate] < interval)
        return;
    NSDate *lastAttempt = [self lastAttemptForPK:pk];
    if (lastAttempt && [now timeIntervalSinceDate:lastAttempt] < MIN(interval, kSPKPARetryInterval))
        return;

    [self runForPK:pk];
}

+ (void)runForPK:(NSString *)pk {
    [self recordAttemptForPK:pk];
    SPKLog(@"ProfileAnalyzer", @"Auto refresh started for %@", pk);
    SPKNotifyTappable(kSPKNotificationProfileAnalyzerComplete,
                      SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_STARTED_TEXT"),
                      nil,
                      @"info_filled",
                      SPKNotificationToneInfo,
                      ^{
                          [SPKProfileAnalyzerViewController presentFromTop];
                      });

    // Covers a short trip to the background; past that the scan fails and the retry interval applies.
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^endTask)(void) = ^{
        if (task == UIBackgroundTaskInvalid)
            return;
        [UIApplication.sharedApplication endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    };
    task = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SPKProfileAnalyzerAutoRefresh" expirationHandler:endTask];

    [[SPKProfileAnalyzerService sharedService]
        runForSelfWithHeaderInfo:nil
                        progress:nil
                      completion:^(SPKProfileAnalyzerSnapshot *snapshot, NSError *error) {
                          endTask();
                          if (error || !snapshot) {
                              SPKLog(@"ProfileAnalyzer", @"Auto refresh failed: %@", error.localizedDescription);
                              return;
                          }
                          SPKLog(@"ProfileAnalyzer", @"Auto refresh finished for %@", snapshot.selfPK);
                          [self announceChangesForPK:snapshot.selfPK];
                      }];
}

+ (void)announceChangesForPK:(NSString *)pk {
    if (!pk.length)
        return;
    SPKProfileAnalyzerReport *report =
        [SPKProfileAnalyzerReport reportFromCurrent:[SPKProfileAnalyzerStorage currentSnapshotForUserPK:pk]
                                           previous:[SPKProfileAnalyzerStorage previousSnapshotForUserPK:pk]];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    void (^add)(NSString *, NSUInteger) = ^(NSString *title, NSUInteger count) {
        if (count > 0)
            [parts addObject:[NSString stringWithFormat:@"%@: %lu", title, (unsigned long)count]];
    };
    add(SPKL(@"PROFILE_PROFILE_ANALYZER_NEW_FOLLOWERS_TEXT"), report.recentFollowers.count);
    add(SPKL(@"PROFILE_PROFILE_ANALYZER_LOST_FOLLOWERS_TEXT"), report.lostFollowers.count);
    add(SPKL(@"PROFILE_PROFILE_ANALYZER_PROFILE_UPDATES_TEXT"), report.profileUpdates.count);
    if (!parts.count)
        return;

    SPKNotifyTappable(kSPKNotificationProfileAnalyzerComplete,
                      SPKL(@"PROFILE_PROFILE_ANALYZER_AUTO_REFRESH_FOUND_CHANGES_TEXT"),
                      [parts componentsJoinedByString:@" · "],
                      @"circle_check_filled",
                      SPKNotificationToneSuccess,
                      ^{
                          [SPKProfileAnalyzerViewController presentFromTop];
                      });
}

@end

void SPKInstallProfileAnalyzerAutoRefreshIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Installed whatever the interval: it is per account, so it is only read once the session resolves.
        Class cls = [SPKProfileAnalyzerAutoRefresh class];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:cls selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:cls selector:@selector(accountDidChange:) name:SPKAccountDidChangeNotification object:nil];
        [center addObserver:cls selector:@selector(launchDidStabilize:) name:SPKStabilityGuardLaunchDidStabilizeNotification object:nil];
        if (SPKStabilityGuardIsLaunchStable())
            [SPKProfileAnalyzerAutoRefresh checkAfterDelay:kSPKPALaunchStableDelay];
    });
}
