// Disable feed/reels retap refresh on newer Instagram versions, and disable
// background feed refresh intervals.

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

static BOOL spkDisableBgRefresh(void) {
    return [SPKUtils getBoolPref:@"feed_disable_bg_refresh"];
}

static BOOL spkDisableHomeRefresh(void) {
    return [SPKUtils getBoolPref:@"feed_disable_home_refresh"];
}

static BOOL spkDisableReelsRefresh(void) {
    return [SPKUtils getBoolPref:@"reels_disable_tab_refresh"];
}

// Returns a very large interval when disabled, -1 to keep Instagram's value.
static double spkOverrideInterval(void) {
    if (spkDisableBgRefresh())
        return 999999.0;
    return -1.0;
}

// MARK: - Refresh utility class-method overrides
// Newer IG versions recompute these values dynamically.

static double (*orig_wsRefresh)(id, SEL, id, id);
static double new_wsRefresh(id self, SEL _cmd, id config, id store) {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : orig_wsRefresh(self, _cmd, config, store);
}

static double (*orig_wsBgRefresh)(id, SEL, id, id);
static double new_wsBgRefresh(id self, SEL _cmd, id config, id store) {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : orig_wsBgRefresh(self, _cmd, config, store);
}

static double (*orig_peakWsRefresh)(id, SEL, double, id, id);
static double new_peakWsRefresh(id self, SEL _cmd, double interval, id config, id store) {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : orig_peakWsRefresh(self, _cmd, interval, config, store);
}

static double (*orig_peakWsBgRefresh)(id, SEL, id, id);
static double new_peakWsBgRefresh(id self, SEL _cmd, id config, id store) {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : orig_peakWsBgRefresh(self, _cmd, config, store);
}

// IG 448 renamed the launcherSet: argument to mobileConfig: with the same
// shape, so each hook takes whichever of the two names the build ships.
static void SPKHookRefreshUtilityMethod(Class metaClass, NSString *legacyName, NSString *currentName, IMP replacement, IMP *original) {
    for (NSString *name in @[ currentName, legacyName ]) {
        SEL sel = NSSelectorFromString(name);
        if (class_getInstanceMethod(metaClass, sel)) {
            MSHookMessageEx(metaClass, sel, replacement, original);
            return;
        }
    }
}

static void SPKInstallRefreshUtilityHooks(void) {
    Class refreshUtilityClass = NSClassFromString(@"IGMainFeedViewModelUtility.IGMainFeedRefreshUtility");
    if (refreshUtilityClass) {
        Class metaClass = object_getClass(refreshUtilityClass);

        SPKHookRefreshUtilityMethod(metaClass,
                                    @"warmStartRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:",
                                    @"warmStartRefreshIntervalWithMobileConfig:feedRefreshInstructionsStore:",
                                    (IMP)new_wsRefresh, (IMP *)&orig_wsRefresh);
        SPKHookRefreshUtilityMethod(metaClass,
                                    @"warmStartBackgroundRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:",
                                    @"warmStartBackgroundRefreshIntervalWithMobileConfig:feedRefreshInstructionsStore:",
                                    (IMP)new_wsBgRefresh, (IMP *)&orig_wsBgRefresh);
        SPKHookRefreshUtilityMethod(metaClass,
                                    @"onPeakWarmStartRefreshIntervalWithWarmStartFetchInterval:launcherSet:feedRefreshInstructionsStore:",
                                    @"onPeakWarmStartRefreshIntervalWithWarmStartFetchInterval:mobileConfig:feedRefreshInstructionsStore:",
                                    (IMP)new_peakWsRefresh, (IMP *)&orig_peakWsRefresh);
        SPKHookRefreshUtilityMethod(metaClass,
                                    @"onPeakWarmStartBackgroundRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:",
                                    @"onPeakWarmStartBackgroundRefreshIntervalWithMobileConfig:feedRefreshInstructionsStore:",
                                    (IMP)new_peakWsBgRefresh, (IMP *)&orig_peakWsBgRefresh);
    }
}

// MARK: - Background refresh network source hooks
// NOTE: On IG 437+ this initializer and the interval getters are gone (init is
// now initWithPosts:...). Kept for older IG (≤410) compatibility; harmless when
// the selector is absent. The real gate on modern IG is the refresh-utility
// class methods above.

%group SPKBackgroundRefreshHooks

%hook IGMainFeedNetworkSource

- (instancetype)initWithDeps:(id)a1
                                       posts:(id)a2
                                   nextMaxID:(id)a3
                     initialPaginationSource:(id)a4
                          contentCoordinator:(id)a5
        dataSourceSupplementaryItemsProvider:(id)a6
                     disableAutomaticRefresh:(BOOL)disable
                        disableSerialization:(BOOL)a8
                                   sessionId:(id)a9
                             analyticsModule:(id)a10
                         serializationSuffix:(id)a11
                         disableFlashFeedTLI:(BOOL)a12
                 disableFlashFeedOnColdStart:(BOOL)a13
                     disableResponseDeferral:(BOOL)a14
                            hidesStoriesTray:(BOOL)a15
                             isSecondaryFeed:(BOOL)a16
       collectionViewBackgroundColorOverride:(id)a17
                   minWarmStartFetchInterval:(double)a18
               peakMinWarmStartFetchInterval:(double)a19
        minimumWarmStartBackgroundedInterval:(double)a20
    peakMinimumWarmStartBackgroundedInterval:(double)a21
              supplementalFeedHoistedMediaID:(id)a22
                         headerTitleOverride:(id)a23
                            isInFollowingTab:(BOOL)a24
          useShimmerLoadingWhenNoStoriesTray:(BOOL)a25 {

    double override = spkOverrideInterval();
    if (spkDisableBgRefresh())
        disable = YES;
    if (override > 0.0) {
        a18 = override;
        a19 = override;
        a20 = override;
        a21 = override;
    }

    return %orig(a1, a2, a3, a4, a5, a6, disable, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25);
}

- (double)minWarmStartFetchInterval {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : %orig;
}

- (double)peakMinWarmStartFetchInterval {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : %orig;
}

- (double)minimumWarmStartBackgroundedInterval {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : %orig;
}

- (double)peakMinimumWarmStartBackgroundedInterval {
    double override = spkOverrideInterval();
    return override > 0.0 ? override : %orig;
}

%end

%hook IGMainFeedViewController

- (void)hotStartRefresh {
    if (spkDisableBgRefresh())
        return;
    %orig;
}

%end

// Implemented in FeedRefreshConfirm.x.
BOOL SPKFeedConfirmHomeTabRefresh(UIViewController *feedController);

// The feed controller when the Home tab is re-tapped on the feed itself, nil
// when the tap switches tabs or pops a pushed screen.
static UIViewController *spkHomeTabFeedController(id tabBarController) {
    UIViewController *selected = nil;
    if ([tabBarController respondsToSelector:@selector(selectedViewController)]) {
        selected = [tabBarController valueForKey:@"selectedViewController"];
    }

    UIViewController *top = [selected isKindOfClass:[UINavigationController class]]
                                ? [(UINavigationController *)selected topViewController]
                                : selected;
    return top && [NSStringFromClass([top class]) containsString:@"MainFeed"] ? top : nil;
}

static void spkScrollFeedToTop(UIViewController *feedController) {
    NSMutableArray *queue = [NSMutableArray array];
    if (feedController.view)
        [queue addObject:feedController.view];
    NSInteger scanned = 0;
    while (queue.count > 0 && scanned < 40) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        scanned++;

        if ([current isKindOfClass:[UICollectionView class]]) {
            UIScrollView *scrollView = (UIScrollView *)current;
            CGPoint topOffset = CGPointMake(0.0, -scrollView.adjustedContentInset.top);
            [scrollView setContentOffset:topOffset animated:YES];
            return;
        }

        [queue addObjectsFromArray:current.subviews];
    }
}

// MARK: - Tab retap handling (newer IG)

%hook IGTabBarController

- (void)_timelineButtonPressed {
    BOOL disableRefresh = spkDisableHomeRefresh();
    if (!disableRefresh && ![SPKUtils getBoolPref:@"feed_confirm_refresh"]) {
        %orig;
        return;
    }

    UIViewController *top = spkHomeTabFeedController(self);
    if (!top) {
        %orig;
        return;
    }

    // Confirm Feed Refresh scrolls up, shows the spinner and asks. Without a
    // refresh control to drive it only scrolls up, so nothing refreshes unasked.
    if (disableRefresh || !SPKFeedConfirmHomeTabRefresh(top))
        spkScrollFeedToTop(top);
}

- (void)_discoverVideoButtonPressed {
    if (!spkDisableReelsRefresh()) {
        %orig;
        return;
    }

    UIViewController *selected = nil;
    if ([self respondsToSelector:@selector(selectedViewController)]) {
        selected = [self valueForKey:@"selectedViewController"];
    }

    UIViewController *top = [selected isKindOfClass:[UINavigationController class]]
                                ? [(UINavigationController *)selected topViewController]
                                : selected;
    NSString *topClass = top ? NSStringFromClass([top class]) : @"";
    BOOL onReelsTab = [topClass containsString:@"Sundial"] ||
                      [topClass containsString:@"Reels"] ||
                      [topClass containsString:@"DiscoverVideo"];
    if (!onReelsTab) {
        %orig;
        return;
    }
}

%end

%end

// Install everything at dylib load, unconditionally. The old approach gated
// installation behind the current pref state and ran on a post-launch timer, so
// hooks were never installed if all prefs were off at launch (breaking live
// toggling) and could miss early refresh scheduling. The refresh-utility class
// methods are the only surviving gate on modern IG (437+) — the network-source
// init/getter hooks are dead there — and every override re-checks the pref at
// call time, so installing early and unconditionally is both correct and cheap.
%ctor {
    SPKInstallRefreshUtilityHooks();
    %init(SPKBackgroundRefreshHooks);
}

// Kept for SPKStartupHooks.m registry compat — now a no-op since the refresh
// hooks install at %ctor / dylib load.
void SPKInstallBackgroundRefreshHooksIfEnabled(void) {
    // Intentionally empty — hooks installed in %ctor above.
}
