#import "../InstagramHeaders.h"
#import "../Tweak.h"
#import "../Utils.h"
#import "SPKCore.h"
#import "SPKFlexLoader.h"
#import "SPKPerfMeter.h"
#import "SPKStabilityGuard.h"
#import "SPKStartupProfiler.h"
#import "../Shared/Navigation/SPKTabConfiguration.h"

static BOOL sSPKAppDidBecomeActive = NO;
static BOOL sSPKStagedHooksFinished = NO;
static BOOL sSPKStabilityCompletionScheduled = NO;
static BOOL sSPKSafeModeAlertScheduled = NO;

// Safe mode suppresses every feature hook, which is indistinguishable from
// Sparkle being broken unless we say so. Explain it once per launch, and keep
// explaining on later launches until the user turns it off — a missed alert
// otherwise leaves them stuck with a silently inert tweak.
static void SPKPresentSafeModeAlertIfNeeded(void) {
    if (sSPKSafeModeAlertScheduled || !SPKStabilityGuardIsSafeStartupMode()) {
        return;
    }
    sSPKSafeModeAlertScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStabilityGuardPresentSafeModeAlertIfNeeded();
    });
}

static void SPKMarkLaunchStableIfReady(void) {
    if (!sSPKAppDidBecomeActive || !sSPKStagedHooksFinished || sSPKStabilityCompletionScheduled) {
        return;
    }
    sSPKStabilityCompletionScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStabilityGuardMarkHooksFinished();
    });
}

static void SPKScheduleHookPhase(NSTimeInterval delay, NSString *name, dispatch_block_t block, BOOL finalPhase) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStartupMark([NSString stringWithFormat:@"%@ hooks begin", name]);
        if (block)
            block();
        SPKStartupMark([NSString stringWithFormat:@"%@ hooks installed", name]);
        if (finalPhase) {
            sSPKStagedHooksFinished = YES;
            SPKMarkLaunchStableIfReady();
        }
    });
}

// The surface Instagram opens on is built within a few hundred milliseconds of
// didFinishLaunching. Any of its hooks still waiting in the stagger by then miss
// the first render and any one-time setup, so that surface is installed ahead of
// the rest. Feed already sits at the front of the normal order. Search has no
// surface of its own (its hooks live in general UI) and Saved has no surface at
// all, so neither moves anything.
static BOOL SPKLaunchSurfaceForTab(NSString *identifier, SPKSurface *surface) {
    if ([identifier isEqualToString:SPKTabIdentifierDirect])
        *surface = SPKSurfaceMessages;
    else if ([identifier isEqualToString:SPKTabIdentifierClips])
        *surface = SPKSurfaceReels;
    else if ([identifier isEqualToString:SPKTabIdentifierProfile])
        *surface = SPKSurfaceProfile;
    else
        return NO;
    return YES;
}

static NSString *SPKHookPhaseName(SPKSurface surface) {
    switch (surface) {
    case SPKSurfaceGeneralUI: return @"general UI";
    case SPKSurfaceFeed: return @"feed";
    case SPKSurfaceStories: return @"stories";
    case SPKSurfaceReels: return @"reels";
    case SPKSurfaceMessages: return @"messages";
    case SPKSurfaceProfile: return @"profile";
    }
    return @"unknown";
}

static void SPKScheduleStagedFeatureHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSNumber *> *order = [@[
            @(SPKSurfaceGeneralUI), @(SPKSurfaceFeed), @(SPKSurfaceStories),
            @(SPKSurfaceReels), @(SPKSurfaceMessages), @(SPKSurfaceProfile)
        ] mutableCopy];
        NSTimeInterval delay = 0.25;

        SPKSurface launchSurface;
        NSString *launchTab = SPKEffectiveLaunchTabIdentifierFromPreferences();
        if (SPKLaunchSurfaceForTab(launchTab, &launchSurface)) {
            [order removeObject:@(launchSurface)];
            SPKScheduleHookPhase(0.10, SPKHookPhaseName(launchSurface), ^{
                SPKCoreInstallSurfaceHooks(launchSurface);
            },
                                 NO);
        }

        for (NSUInteger i = 0; i < order.count; i++) {
            SPKSurface surface = (SPKSurface)order[i].unsignedIntegerValue;
            SPKScheduleHookPhase(delay, SPKHookPhaseName(surface), ^{
                SPKCoreInstallSurfaceHooks(surface);
            },
                                 i == order.count - 1);
            delay += 0.10;
        }
    });
}

%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)arg2 {
    SPKStartupMark(@"willFinishLaunching begin");
    SPKCoreRegisterBootstrapDefaults();
    SPKStabilityGuardBeginLaunch();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    SPKLiquidGlassMode liquidGlassMode = [SPKUtils spk_liquidGlassMode];
    if (liquidGlassMode == SPKLiquidGlassModeFollow) {
        [defaults removeObjectForKey:@"instagram.override.project.lucent.navigation"];
    } else {
        [defaults setBool:liquidGlassMode == SPKLiquidGlassModeOn
                   forKey:@"instagram.override.project.lucent.navigation"];
    }
    [defaults removeObjectForKey:@"liquid_glass_override_enabled"];
    [defaults removeObjectForKey:@"IGLiquidGlassOverrideEnabled"];
    SPKCoreInstallLaunchCriticalHooks();
    SPKStartupMark(@"launch critical hooks installed");

    return %orig;
}

- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)arg2 {
    SPKStartupMark(@"didFinishLaunching begin");
    BOOL result = %orig;
    SPKStartupMark(@"didFinishLaunching orig returned");
    SPKScheduleStagedFeatureHooks();
    SPKPerfMeterStartIfEnabled();

    double openDelay = [SPKUtils getBoolPref:@"tools_open_settings_on_launch"] ? 0.0 : 5.0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(openDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (SPKCoreOnboardingPending() || SPKCoreWhatsNewPending() || [SPKUtils getBoolPref:@"tools_open_settings_on_launch"]) {
            SPKLog(@"Bootstrap", @"Intro sheet pending or launch-open enabled; presenting settings");
            SPKCoreShowSettingsIfNeeded([self window]);
        }
    });
    if ([SPKUtils getBoolPref:@"tools_flex_app_launch"]) {
        SPKFlexShowExplorer(@"launch");
    }

    return result;
}

- (void)applicationDidBecomeActive:(id)arg1 {
    %orig;
    sSPKAppDidBecomeActive = YES;
    SPKMarkLaunchStableIfReady();
    // The HUD needs a window scene, which is not guaranteed at didFinishLaunching.
    SPKPerfMeterStartIfEnabled();
    SPKPresentSafeModeAlertIfNeeded();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [SPKUtils evaluateAutomaticCacheClearIfNeeded];
    });

    if ([SPKUtils getBoolPref:@"tools_flex_app_start"]) {
        SPKFlexShowExplorer(@"focus");
    }
}
%end
