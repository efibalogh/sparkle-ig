#import "SPKStrings.h"
// SPKStabilityGuard — a launch failsafe.
//
// Each launch records a start timestamp. If a launch never reaches the "stable"
// mark (set ~5s after the app is active and all staged hooks installed) and the
// next launch starts within kSPKStabilityRecentLaunchWindow, it's counted as an
// incomplete launch. After kSPKStabilityFailureThreshold consecutive incomplete
// launches the tweak enters *safe startup mode*: feature hooks are suppressed
// (only Settings access remains) and Liquid Glass is disabled, so a hook that
// crashes Instagram on launch can't lock the user out permanently. The user can
// clear this from Tools > "Reset Safe Startup Mode" (SPKStabilityGuardReset).
//
// A launch the user leaves before it is marked stable (app switcher, home
// gesture, swiping it away) is not counted: a launch crash never gets far enough
// to resign active, so only launches that end without the user leaving count.
#import "SPKStabilityGuard.h"

#import <UIKit/UIKit.h>

#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Utils.h"

static NSString *const kSPKStabilityLaunchStartedAtKey = @"app_launch_started_at";
static NSString *const kSPKStabilityLaunchCompletedAtKey = @"app_launch_completed_at";
static NSString *const kSPKStabilityFailedLaunchCountKey = @"app_failed_launch_count";
static NSString *const kSPKStabilityLaunchLeftByUserKey = @"app_launch_left_by_user";
static NSString *const kSPKSafeStartupModeKey = @"app_safe_startup";
static NSString *const kSPKSafeStartupReasonKey = @"app_safe_startup_reason";

static NSTimeInterval const kSPKStabilityRecentLaunchWindow = 300.0;
static NSInteger const kSPKStabilityFailureThreshold = 2;

static NSTimeInterval SPKNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

void SPKStabilityGuardBeginLaunch(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSTimeInterval now = SPKNow();
    NSTimeInterval previousStart = [defaults doubleForKey:kSPKStabilityLaunchStartedAtKey];
    NSInteger failedLaunches = [defaults integerForKey:kSPKStabilityFailedLaunchCountKey];
    BOOL previousLaunchLeftByUser = [defaults boolForKey:kSPKStabilityLaunchLeftByUserKey];
    [defaults removeObjectForKey:kSPKStabilityLaunchLeftByUserKey];

    if (previousStart > 0.0 && previousLaunchLeftByUser) {
        SPKLog(@"Stability", @"Previous launch was left by the user before it finished; not counted");
    } else if (previousStart > 0.0) {
        BOOL recentIncompleteLaunch = (now - previousStart) <= kSPKStabilityRecentLaunchWindow;
        failedLaunches = recentIncompleteLaunch ? failedLaunches + 1 : 0;
        [defaults setInteger:failedLaunches forKey:kSPKStabilityFailedLaunchCountKey];

        if (recentIncompleteLaunch && failedLaunches >= kSPKStabilityFailureThreshold) {
            [defaults setBool:YES forKey:kSPKSafeStartupModeKey];
            [defaults setObject:@"Repeated incomplete launches" forKey:kSPKSafeStartupReasonKey];
            SPKWarnLog(@"Stability", @"Entering safe startup mode after %ld incomplete launches", (long)failedLaunches);
        } else if (recentIncompleteLaunch) {
            SPKWarnLog(@"Stability", @"Detected incomplete previous launch; count=%ld", (long)failedLaunches);
        }
    }

    [defaults setDouble:now forKey:kSPKStabilityLaunchStartedAtKey];

    if ([defaults boolForKey:kSPKSafeStartupModeKey]) {
        NSString *reason = [defaults stringForKey:kSPKSafeStartupReasonKey] ?: @"unknown";
        SPKWarnLog(@"Stability", @"Safe startup mode active: %@", reason);
    } else {
        SPKLog(@"Stability", @"Launch guard armed");
    }
    [defaults synchronize];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          NSUserDefaults *launchDefaults = [NSUserDefaults standardUserDefaults];
                                                          if ([launchDefaults doubleForKey:kSPKStabilityLaunchStartedAtKey] <= 0.0 ||
                                                              [launchDefaults boolForKey:kSPKStabilityLaunchLeftByUserKey]) {
                                                              return;
                                                          }
                                                          // The process can be killed straight from the app switcher, so persist now.
                                                          [launchDefaults setBool:YES forKey:kSPKStabilityLaunchLeftByUserKey];
                                                          [launchDefaults synchronize];
                                                      }];
    });
}

void SPKStabilityGuardMarkHooksFinished(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kSPKStabilityLaunchStartedAtKey];
    [defaults removeObjectForKey:kSPKStabilityLaunchLeftByUserKey];
    [defaults setInteger:0 forKey:kSPKStabilityFailedLaunchCountKey];
    [defaults setDouble:SPKNow() forKey:kSPKStabilityLaunchCompletedAtKey];
    [defaults synchronize];
    SPKLog(@"Stability", @"Launch marked stable");
}

BOOL SPKStabilityGuardIsSafeStartupMode(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSPKSafeStartupModeKey];
}

void SPKStabilityGuardPresentSafeModeAlertIfNeeded(void) {
    if (!SPKStabilityGuardIsSafeStartupMode()) {
        return;
    }

    NSString *reason = [[NSUserDefaults standardUserDefaults] stringForKey:kSPKSafeStartupReasonKey] ?: @"unknown";
    SPKLog(@"Stability", @"Presenting safe startup alert (reason: %@)", reason);

    [SPKIGAlertPresenter presentAlertFromViewController:nil
                                                 title:SPKL(@"APP_STABILITY_GUARD_SPARKLE_SAFE_MODE_TEXT")
                                               message:SPKL(@"APP_STABILITY_GUARD_INSTAGRAM_CLOSED_BEFORE_FINISHING_LAUNCH_SEVERAL_TIMES_ROW_SO_TEXT")
                                               actions:@[
                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_TURN_OFF_SAFE_MODE")
                                                                               style:SPKIGAlertActionStyleDefault
                                                                             handler:^{
                                                                                 SPKStabilityGuardReset();
                                                                                 [SPKUtils showRestartConfirmation];
                                                                             }],
                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OPEN_SPARKLE_SETTINGS")
                                                                               style:SPKIGAlertActionStyleDefault
                                                                             handler:^{
                                                                                 [SPKUtils showSettingsForTopicTitle:@"Tools"];
                                                                             }],
                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_NOT_NOW")
                                                                               style:SPKIGAlertActionStyleCancel
                                                                             handler:nil],
                                               ]];
}

void SPKStabilityGuardReset(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kSPKStabilityLaunchStartedAtKey];
    [defaults removeObjectForKey:kSPKStabilityFailedLaunchCountKey];
    [defaults removeObjectForKey:kSPKStabilityLaunchLeftByUserKey];
    [defaults removeObjectForKey:kSPKSafeStartupModeKey];
    [defaults removeObjectForKey:kSPKSafeStartupReasonKey];
    [defaults removeObjectForKey:kSPKStabilityLaunchCompletedAtKey];
    [defaults synchronize];
    SPKLog(@"Stability", @"Safe startup state reset");
}
