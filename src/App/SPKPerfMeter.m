#import "SPKPerfMeter.h"
#import "SPKStrings.h"

#if SPK_DEV

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <os/lock.h>
#import <pthread.h>
#import <sys/utsname.h>

#import "../Tweak.h"
#import "../Utils.h"

NSString *const kSPKPerfMeterEnabledKey = @"tools_perf_meter";
NSString *const kSPKPerfMeterHUDKey = @"tools_perf_hud";

// One frame at 60Hz. Anything the main thread spends beyond this between two
// pings is time a frame could not be drawn in.
static const CFTimeInterval kSPKPerfFrameBudget = 1.0 / 60.0;
// A ping every frame would itself be main-thread work; every other frame is
// enough resolution to catch a stall while staying close to free.
static const CFTimeInterval kSPKPerfPingInterval = 0.032;
// Blocked time above this is worth calling out separately: a stall this long is
// a visible freeze rather than a dropped frame.
static const CFTimeInterval kSPKPerfLongStall = 0.25;
static const CFTimeInterval kSPKPerfRecentWindow = 3.0;

// MARK: - State

// Statistics are only ever mutated on the main thread (the ping block runs
// there), so they need no lock. The counters dictionary is the exception: it is
// written from wherever a caller drops a SPKPerfMeterCount().
static CFTimeInterval spkPerfWindowStart = 0;
static CFTimeInterval spkPerfBlocked = 0;
static CFTimeInterval spkPerfWorst = 0;
static NSUInteger spkPerfStalls = 0;
static NSUInteger spkPerfLongStalls = 0;
static NSUInteger spkPerfSamples = 0;

// [timestamp, blockedSeconds] pairs inside the recent window, for the HUD.
static NSMutableArray<NSArray<NSNumber *> *> *spkPerfRecent = nil;

static dispatch_source_t spkPerfTimer = nil;
static volatile BOOL spkPerfPingInFlight = NO;
static BOOL spkPerfEnabled = NO;

static os_unfair_lock spkPerfCounterLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *spkPerfCounters = nil;
// Scope name -> seconds spent inside, and scope name -> times entered. Two flat
// dictionaries rather than one of boxed structs: this is written from layout
// paths and has to stay cheap.
static NSMutableDictionary<NSString *, NSNumber *> *spkPerfScopeTime = nil;
static NSMutableDictionary<NSString *, NSNumber *> *spkPerfScopeCalls = nil;

// The log is far more useful as a timeline than as a single dump, and tapping
// "Log Snapshot" mid-navigation is exactly when the app is least tappable.
static const CFTimeInterval kSPKPerfAutoLogInterval = 15.0;
static CFTimeInterval spkPerfLastAutoLog = 0;

static NSArray<NSString *> *SPKPerfScopeNamesByCost(NSDictionary *scopeTime);

// MARK: - Stall stack sampling
//
// The scope timers only see hooks someone thought to instrument. This sees
// everything: when a ping has been outstanding long enough to count as a freeze,
// the main thread is suspended just long enough to copy its frame-pointer chain,
// and the resulting stacks are tallied. The stack that shows up under most
// stalls is the cause, instrumented or not.
//
// Nothing between thread_suspend and thread_resume may allocate: the suspended
// thread can be holding the malloc lock, and taking it here would deadlock the
// app. Frames are copied into a fixed buffer and symbolicated after resuming.

// Sample once a ping has been outstanding this long. Below a quarter second a
// stall is a dropped frame, not a freeze worth a stack.
static const CFTimeInterval kSPKPerfStallSampleThreshold = 0.25;
#define kSPKPerfMaxFrames 40

static thread_t spkPerfMainThread = MACH_PORT_NULL;
static CFTimeInterval spkPerfPingSentAt = 0;
static BOOL spkPerfSampledThisStall = NO;
static NSMutableDictionary<NSString *, NSNumber *> *spkPerfStallStacks = nil;

// Reads the frame-pointer chain of a suspended thread. Async-signal-safe:
// no allocation, no ObjC.
static int SPKPerfCaptureFrames(thread_t thread, uintptr_t *frames, int maxFrames) {
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS)
        return 0;

    // The app is built arm64, but strip the top byte anyway so a pointer-signed
    // or tagged frame address cannot walk us off into garbage.
    const uintptr_t mask = 0x0000000fffffffffUL;
    int depth = 0;
    frames[depth++] = (uintptr_t)__darwin_arm_thread_state64_get_pc(state) & mask;
    frames[depth++] = (uintptr_t)__darwin_arm_thread_state64_get_lr(state) & mask;

    uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(state) & mask;
    while (depth < maxFrames && fp > 0x1000 && (fp & 0xf) == 0) {
        uintptr_t next = ((uintptr_t *)fp)[0] & mask;
        uintptr_t ret = ((uintptr_t *)fp)[1] & mask;
        if (ret <= 0x1000 || next <= fp)
            break;
        frames[depth++] = ret;
        fp = next;
    }
    return depth;
#else
    return 0;
#endif
}

// Sparkle's own frames are what we are hunting, so they are kept verbatim;
// everything else collapses to its module name to keep stacks comparable.
static NSString *SPKPerfSymbolicate(uintptr_t *frames, int depth) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (int i = 0; i < depth; i++) {
        Dl_info info;
        if (dladdr((const void *)frames[i], &info) == 0 || !info.dli_sname) {
            [parts addObject:@"???"];
            continue;
        }
        NSString *image = info.dli_fname
                              ? [@(info.dli_fname) lastPathComponent]
                              : @"?";
        NSString *symbol = @(info.dli_sname);
        if ([image hasPrefix:@"Sparkle"] || [symbol hasPrefix:@"SPK"] ||
            [symbol containsString:@"spk_"] || [symbol containsString:@"logos"]) {
            [parts addObject:[NSString stringWithFormat:@"*%@", symbol]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%@`%@", image, symbol]];
        }
    }
    return [parts componentsJoinedByString:@" < "];
}

static void SPKPerfSampleStalledMainThread(void) {
    if (spkPerfMainThread == MACH_PORT_NULL)
        return;

    uintptr_t frames[kSPKPerfMaxFrames];
    int depth = 0;
    if (thread_suspend(spkPerfMainThread) != KERN_SUCCESS)
        return;
    depth = SPKPerfCaptureFrames(spkPerfMainThread, frames, kSPKPerfMaxFrames);
    thread_resume(spkPerfMainThread);

    if (depth <= 0)
        return;

    NSString *stack = SPKPerfSymbolicate(frames, depth);
    os_unfair_lock_lock(&spkPerfCounterLock);
    if (!spkPerfStallStacks)
        spkPerfStallStacks = [NSMutableDictionary dictionary];
    spkPerfStallStacks[stack] = @(spkPerfStallStacks[stack].integerValue + 1);
    os_unfair_lock_unlock(&spkPerfCounterLock);
}

// MARK: - Sampling

static void SPKPerfRecordLatency(CFTimeInterval latency) {
    spkPerfSamples++;

    CFTimeInterval sampledAt = CACurrentMediaTime();
    if (sampledAt - spkPerfLastAutoLog >= kSPKPerfAutoLogInterval) {
        spkPerfLastAutoLog = sampledAt;
        SPKPerfMeterLogSnapshot(@"auto");
    }

    CFTimeInterval blocked = latency - kSPKPerfFrameBudget;
    if (blocked <= 0)
        return;

    spkPerfBlocked += blocked;
    spkPerfStalls++;
    if (blocked > kSPKPerfLongStall)
        spkPerfLongStalls++;
    if (blocked > spkPerfWorst)
        spkPerfWorst = blocked;

    CFTimeInterval now = CACurrentMediaTime();
    [spkPerfRecent addObject:@[ @(now), @(blocked) ]];
    while (spkPerfRecent.count > 0 &&
           now - spkPerfRecent.firstObject.firstObject.doubleValue > kSPKPerfRecentWindow) {
        [spkPerfRecent removeObjectAtIndex:0];
    }
}

static CFTimeInterval SPKPerfRecentBlocked(void) {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval total = 0;
    for (NSArray<NSNumber *> *entry in spkPerfRecent) {
        if (now - entry.firstObject.doubleValue <= kSPKPerfRecentWindow)
            total += entry.lastObject.doubleValue;
    }
    return total;
}

// MARK: - Hierarchy probe

static UIWindow *SPKPerfKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow)
                return window;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static void SPKPerfWalkViews(UIView *view, NSUInteger *views, NSUInteger *recognizers) {
    if (!view)
        return;
    (*views)++;
    *recognizers += view.gestureRecognizers.count;
    for (UIView *subview in view.subviews)
        SPKPerfWalkViews(subview, views, recognizers);
}

// Counts every view controller reachable from the window's root, following
// children and presentations. A nav stack that grows without popping - the
// usual cause of "it gets worse the deeper I go" - shows up both in the total
// and in the deepest stack.
//
// Two traps here, both of which produced counts in the tens of thousands for a
// hierarchy holding a few hundred views:
//
//  - -presentedViewController returns the controller presented by the receiver
//    *or by any of its ancestors*, so every controller in the tree reports the
//    same modal and the walk re-enters that subtree once per node. Only follow
//    it from the controller that actually did the presenting.
//  - A controller can be reachable by more than one path (a child that is also
//    a nav-stack member), so nodes have to be de-duplicated by identity.
static void SPKPerfWalkControllers(UIViewController *controller,
                                   NSMutableSet<NSValue *> *seen,
                                   NSUInteger *count,
                                   NSUInteger *deepestStack) {
    if (!controller)
        return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([seen containsObject:identity])
        return;
    [seen addObject:identity];

    (*count)++;
    if ([controller isKindOfClass:UINavigationController.class]) {
        NSUInteger depth = ((UINavigationController *)controller).viewControllers.count;
        if (depth > *deepestStack)
            *deepestStack = depth;
    }
    for (UIViewController *child in controller.childViewControllers)
        SPKPerfWalkControllers(child, seen, count, deepestStack);

    UIViewController *presented = controller.presentedViewController;
    if (presented.presentingViewController == controller)
        SPKPerfWalkControllers(presented, seen, count, deepestStack);
}

// Walking every view in the window is not free, and the HUD ticks twice a
// second. Reuse a recent walk so the instrument stays well below the noise
// floor of what it is measuring.
static const CFTimeInterval kSPKPerfHierarchyTTL = 2.0;
static NSDictionary *spkPerfHierarchyCache = nil;
static CFTimeInterval spkPerfHierarchyCachedAt = 0;

static NSDictionary *SPKPerfHierarchySnapshot(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (spkPerfHierarchyCache && now - spkPerfHierarchyCachedAt < kSPKPerfHierarchyTTL)
        return spkPerfHierarchyCache;

    UIWindow *window = SPKPerfKeyWindow();
    NSUInteger views = 0, recognizers = 0, controllers = 0, deepest = 0;
    SPKPerfWalkViews(window, &views, &recognizers);
    SPKPerfWalkControllers(window.rootViewController,
                           [NSMutableSet set],
                           &controllers,
                           &deepest);
    spkPerfHierarchyCachedAt = now;
    spkPerfHierarchyCache = @{
        @"views" : @(views),
        @"gestureRecognizers" : @(recognizers),
        @"viewControllers" : @(controllers),
        @"deepestNavStack" : @(deepest),
        @"windows" : @(UIApplication.sharedApplication.windows.count),
    };
    return spkPerfHierarchyCache;
}

// MARK: - HUD

// Passes every touch through: the HUD has to be watchable while navigating.
@interface SPKPerfHUDWindow : UIWindow
@end

@implementation SPKPerfHUDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
@end

static SPKPerfHUDWindow *spkPerfHUDWindow = nil;
static UILabel *spkPerfHUDLabel = nil;
static NSTimer *spkPerfHUDTimer = nil;

static void SPKPerfUpdateHUD(void) {
    if (!spkPerfHUDLabel)
        return;
    NSDictionary *hierarchy = SPKPerfHierarchySnapshot();
    CFTimeInterval recent = SPKPerfRecentBlocked();
    CFTimeInterval elapsed = MAX(CACurrentMediaTime() - spkPerfWindowStart, 0.001);

    // The two worst scopes, so the culprit can be read off the screen while
    // navigating instead of reconstructed from the log afterwards.
    NSMutableString *worstScopes = [NSMutableString string];
    os_unfair_lock_lock(&spkPerfCounterLock);
    NSDictionary *scopeTime = [spkPerfScopeTime copy];
    NSDictionary *scopeCalls = [spkPerfScopeCalls copy];
    os_unfair_lock_unlock(&spkPerfCounterLock);
    NSArray<NSString *> *ranked = SPKPerfScopeNamesByCost(scopeTime);
    for (NSUInteger i = 0; i < MIN((NSUInteger)2, ranked.count); i++) {
        NSString *key = ranked[i];
        [worstScopes appendFormat:@"\n%@ %.0fms x%@",
                                  key,
                                  [scopeTime[key] doubleValue] * 1000.0,
                                  scopeCalls[key]];
    }

    spkPerfHUDLabel.text = [NSString stringWithFormat:
                                         @"stall %.0fms/3s  max %.0fms\n"
                                         @"total %.1fs/%.0fs  %.1f%%\n"
                                         @"vc %@  views %@  gr %@  depth %@%@",
                                         recent * 1000.0,
                                         spkPerfWorst * 1000.0,
                                         spkPerfBlocked,
                                         elapsed,
                                         spkPerfBlocked / elapsed * 100.0,
                                         hierarchy[@"viewControllers"],
                                         hierarchy[@"views"],
                                         hierarchy[@"gestureRecognizers"],
                                         hierarchy[@"deepestNavStack"],
                                         worstScopes];
    // Red once a third of the last three seconds was spent blocked, which is
    // roughly where scrolling stops feeling attached to your finger.
    spkPerfHUDLabel.textColor = recent > kSPKPerfRecentWindow / 3.0 ? UIColor.systemRedColor
                                                                    : UIColor.whiteColor;
    [spkPerfHUDLabel sizeToFit];
    CGRect frame = spkPerfHUDLabel.frame;
    frame.size.width += 12;
    frame.size.height += 8;
    spkPerfHUDWindow.frame = CGRectMake(8, 64, frame.size.width, frame.size.height);
    spkPerfHUDLabel.frame = CGRectMake(6, 4, frame.size.width - 12, frame.size.height - 8);
}

static void SPKPerfTeardownHUD(void) {
    [spkPerfHUDTimer invalidate];
    spkPerfHUDTimer = nil;
    spkPerfHUDWindow.hidden = YES;
    spkPerfHUDWindow = nil;
    spkPerfHUDLabel = nil;
}

BOOL SPKPerfMeterHUDIsVisible(void) {
    return spkPerfHUDWindow != nil;
}

void SPKPerfMeterSetHUDVisible(BOOL visible) {
    dispatch_block_t work = ^{
        if (!visible) {
            SPKPerfTeardownHUD();
            return;
        }
        if (spkPerfHUDWindow)
            return;
        UIWindowScene *scene = (UIWindowScene *)SPKPerfKeyWindow().windowScene;
        if (!scene) {
            SPKWarnLog(@"Perf", @"No window scene yet; HUD not shown");
            return;
        }
        spkPerfHUDWindow = [[SPKPerfHUDWindow alloc] initWithWindowScene:scene];
        spkPerfHUDWindow.windowLevel = UIWindowLevelAlert + 200.0;
        spkPerfHUDWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        spkPerfHUDWindow.layer.cornerRadius = 8;
        spkPerfHUDWindow.layer.masksToBounds = YES;
        spkPerfHUDWindow.rootViewController = [UIViewController new];

        spkPerfHUDLabel = [UILabel new];
        spkPerfHUDLabel.numberOfLines = 0;
        spkPerfHUDLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        spkPerfHUDLabel.textColor = UIColor.whiteColor;
        [spkPerfHUDWindow.rootViewController.view addSubview:spkPerfHUDLabel];
        spkPerfHUDWindow.hidden = NO;

        SPKPerfUpdateHUD();
        spkPerfHUDTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(__unused NSTimer *timer) {
                                                                SPKPerfUpdateHUD();
                                                            }];
    };
    if (NSThread.isMainThread)
        work();
    else
        dispatch_async(dispatch_get_main_queue(), work);
}

// MARK: - Lifecycle

BOOL SPKPerfMeterIsEnabled(void) {
    return spkPerfEnabled;
}

void SPKPerfMeterSetEnabled(BOOL enabled) {
    if (enabled == spkPerfEnabled)
        return;
    spkPerfEnabled = enabled;

    if (!enabled) {
        if (spkPerfTimer)
            dispatch_source_cancel(spkPerfTimer);
        spkPerfTimer = nil;
        SPKPerfMeterSetHUDVisible(NO);
        SPKLog(@"Perf", @"Meter stopped. %@", SPKPerfMeterSummary());
        return;
    }

    SPKPerfMeterReset();

    // Hold a send right to the main thread so stalls can be sampled from the
    // timer queue. Taken once; the meter outlives the app's main thread only at
    // termination.
    if (spkPerfMainThread == MACH_PORT_NULL) {
        dispatch_block_t capture = ^{
            spkPerfMainThread = mach_thread_self();
        };
        if (NSThread.isMainThread)
            capture();
        else
            dispatch_sync(dispatch_get_main_queue(), capture);
    }

    dispatch_queue_t queue = dispatch_queue_create("com.sparkle.perfmeter", DISPATCH_QUEUE_SERIAL);
    spkPerfTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(spkPerfTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kSPKPerfPingInterval * NSEC_PER_SEC),
                              (uint64_t)(0.004 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(spkPerfTimer, ^{
        // Only one ping in flight: while the main thread is blocked the timer
        // keeps firing, and queueing more pings would count the same stall
        // several times over.
        if (spkPerfPingInFlight) {
            // The ping is overdue, so the main thread is stuck right now - the
            // one moment its stack is worth reading. Once per stall.
            if (!spkPerfSampledThisStall &&
                CACurrentMediaTime() - spkPerfPingSentAt > kSPKPerfStallSampleThreshold) {
                spkPerfSampledThisStall = YES;
                SPKPerfSampleStalledMainThread();
            }
            return;
        }
        spkPerfPingInFlight = YES;
        spkPerfSampledThisStall = NO;
        CFTimeInterval sentAt = CACurrentMediaTime();
        spkPerfPingSentAt = sentAt;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKPerfRecordLatency(CACurrentMediaTime() - sentAt);
            spkPerfPingInFlight = NO;
        });
    });
    dispatch_resume(spkPerfTimer);
    SPKLog(@"Perf", @"Meter started");
}

void SPKPerfMeterStartIfEnabled(void) {
    if (![SPKUtils getBoolPref:kSPKPerfMeterEnabledKey])
        return;
    SPKPerfMeterSetEnabled(YES);
    if ([SPKUtils getBoolPref:kSPKPerfMeterHUDKey])
        SPKPerfMeterSetHUDVisible(YES);
}

void SPKPerfMeterReset(void) {
    dispatch_block_t work = ^{
        spkPerfWindowStart = CACurrentMediaTime();
        spkPerfBlocked = 0;
        spkPerfWorst = 0;
        spkPerfStalls = 0;
        spkPerfLongStalls = 0;
        spkPerfSamples = 0;
        spkPerfRecent = [NSMutableArray array];
        spkPerfLastAutoLog = spkPerfWindowStart;
        os_unfair_lock_lock(&spkPerfCounterLock);
        spkPerfCounters = [NSMutableDictionary dictionary];
        spkPerfScopeTime = [NSMutableDictionary dictionary];
        spkPerfScopeCalls = [NSMutableDictionary dictionary];
        spkPerfStallStacks = [NSMutableDictionary dictionary];
        os_unfair_lock_unlock(&spkPerfCounterLock);
    };
    if (NSThread.isMainThread)
        work();
    else
        dispatch_sync(dispatch_get_main_queue(), work);
}

// MARK: - Reporting

NSDictionary *SPKPerfMeterSnapshot(void) {
    CFTimeInterval elapsed = MAX(CACurrentMediaTime() - spkPerfWindowStart, 0.001);
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{
        @"elapsed" : @(elapsed),
        @"blockedMs" : @(spkPerfBlocked * 1000.0),
        @"blockedPercent" : @(spkPerfBlocked / elapsed * 100.0),
        @"worstMs" : @(spkPerfWorst * 1000.0),
        @"stalls" : @(spkPerfStalls),
        @"longStalls" : @(spkPerfLongStalls),
        @"samples" : @(spkPerfSamples),
    }];
    [snapshot addEntriesFromDictionary:SPKPerfHierarchySnapshot()];

    os_unfair_lock_lock(&spkPerfCounterLock);
    snapshot[@"counters"] = [spkPerfCounters copy] ?: @{};
    snapshot[@"scopeTime"] = [spkPerfScopeTime copy] ?: @{};
    snapshot[@"scopeCalls"] = [spkPerfScopeCalls copy] ?: @{};
    os_unfair_lock_unlock(&spkPerfCounterLock);
    return snapshot;
}

// Scope names ordered by total time spent inside them, worst first.
static NSArray<NSString *> *SPKPerfScopeNamesByCost(NSDictionary *scopeTime) {
    return [scopeTime keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
}

NSString *SPKPerfMeterSummary(void) {
    if (!spkPerfEnabled)
        return SPKL(@"MENU_OFF");
    NSDictionary *snapshot = SPKPerfMeterSnapshot();
    return [NSString stringWithFormat:@"%.1fs blocked over %.0fs (%.1f%%), worst %.0fms",
                                      [snapshot[@"blockedMs"] doubleValue] / 1000.0,
                                      [snapshot[@"elapsed"] doubleValue],
                                      [snapshot[@"blockedPercent"] doubleValue],
                                      [snapshot[@"worstMs"] doubleValue]];
}

NSString *SPKPerfMeterWorstScopeSummary(void) {
    os_unfair_lock_lock(&spkPerfCounterLock);
    NSDictionary *scopeTime = [spkPerfScopeTime copy];
    NSDictionary *scopeCalls = [spkPerfScopeCalls copy];
    os_unfair_lock_unlock(&spkPerfCounterLock);

    NSString *worst = SPKPerfScopeNamesByCost(scopeTime).firstObject;
    if (!worst)
        return spkPerfEnabled ? @"Nothing recorded yet" : @"Off";
    return [NSString stringWithFormat:@"%@ - %.1fs over %@ calls",
                                      worst,
                                      [scopeTime[worst] doubleValue],
                                      scopeCalls[worst]];
}

static NSString *SPKPerfDeviceMachine(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) != 0)
        return UIDevice.currentDevice.model ?: @"unknown";
    return [NSString stringWithUTF8String:systemInfo.machine] ?: UIDevice.currentDevice.model ?: @"unknown";
}

static NSString *SPKPerfReportTimestamp(void) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:[NSDate date]] ?: @"unknown";
}

NSString *SPKPerfMeterTextReport(void) {
    NSDictionary *snapshot = SPKPerfMeterSnapshot();
    NSDictionary *scopeTime = snapshot[@"scopeTime"] ?: @{};
    NSDictionary *scopeCalls = snapshot[@"scopeCalls"] ?: @{};
    NSDictionary *counters = snapshot[@"counters"] ?: @{};

    os_unfair_lock_lock(&spkPerfCounterLock);
    NSDictionary *stacks = [spkPerfStallStacks copy] ?: @{};
    os_unfair_lock_unlock(&spkPerfCounterLock);

    NSDictionary *appInfo = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *instagramVersion = [SPKUtils IGVersionString] ?: @"unknown";
    NSString *instagramBuild = [appInfo[@"CFBundleVersion"] description] ?: @"unknown";
    UIDevice *device = UIDevice.currentDevice;

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Sparkle Performance Report\n"];
    [report appendFormat:@"Generated: %@\n", SPKPerfReportTimestamp()];
    [report appendFormat:@"Sparkle: %@ (developer diagnostics)\n", SPKVersionString ?: @"unknown"];
    [report appendFormat:@"Instagram: %@ (%@)\n", instagramVersion, instagramBuild];
    [report appendFormat:@"OS: %@ %@\n", device.systemName ?: @"iOS", device.systemVersion ?: @"unknown"];
    [report appendFormat:@"Device: %@\n", SPKPerfDeviceMachine()];
    [report appendString:@"Privacy: no usernames, account identifiers, or media URLs are included.\n\n"];

    [report appendString:@"Measurement\n"];
    [report appendFormat:@"Elapsed: %.3fs\n", [snapshot[@"elapsed"] doubleValue]];
    [report appendFormat:@"Blocked: %.3fs (%.2f%%)\n",
                         [snapshot[@"blockedMs"] doubleValue] / 1000.0,
                         [snapshot[@"blockedPercent"] doubleValue]];
    [report appendFormat:@"Worst stall: %.0fms\n", [snapshot[@"worstMs"] doubleValue]];
    [report appendFormat:@"Stalls: %@\n", snapshot[@"stalls"] ?: @0];
    [report appendFormat:@"Long stalls: %@\n", snapshot[@"longStalls"] ?: @0];
    [report appendFormat:@"Samples: %@\n\n", snapshot[@"samples"] ?: @0];

    [report appendString:@"UI hierarchy\n"];
    [report appendFormat:@"Windows: %@\n", snapshot[@"windows"] ?: @0];
    [report appendFormat:@"View controllers: %@\n", snapshot[@"viewControllers"] ?: @0];
    [report appendFormat:@"Views: %@\n", snapshot[@"views"] ?: @0];
    [report appendFormat:@"Gesture recognizers: %@\n", snapshot[@"gestureRecognizers"] ?: @0];
    [report appendFormat:@"Deepest navigation stack: %@\n\n", snapshot[@"deepestNavStack"] ?: @0];

    [report appendString:@"Timed scopes\n"];
    NSArray<NSString *> *rankedScopes = SPKPerfScopeNamesByCost(scopeTime);
    if (rankedScopes.count == 0) {
        [report appendString:@"(none)\n"];
    } else {
        for (NSString *key in rankedScopes) {
            double seconds = [scopeTime[key] doubleValue];
            NSInteger calls = [scopeCalls[key] integerValue];
            [report appendFormat:@"%@ | %.3fs total | %ld calls | %.3fms average\n",
                                 key,
                                 seconds,
                                 (long)calls,
                                 calls > 0 ? seconds * 1000.0 / calls : 0.0];
        }
    }

    [report appendString:@"\nCounters\n"];
    NSArray<NSString *> *rankedCounters =
        [counters keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [b compare:a];
        }];
    if (rankedCounters.count == 0) {
        [report appendString:@"(none)\n"];
    } else {
        for (NSString *key in rankedCounters)
            [report appendFormat:@"%@ = %@\n", key, counters[key]];
    }

    [report appendString:@"\nSampled main-thread freeze stacks\n"];
    NSArray<NSString *> *rankedStacks =
        [stacks keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [b compare:a];
        }];
    if (rankedStacks.count == 0) {
        [report appendString:@"(none captured)\n"];
    } else {
        NSUInteger shown = 0;
        for (NSString *stack in rankedStacks) {
            if (shown++ >= 5)
                break;
            [report appendFormat:@"x%@ %@\n", stacks[stack], stack];
        }
    }
    return report;
}

void SPKPerfMeterLogSnapshot(NSString *label) {
    NSDictionary *snapshot = SPKPerfMeterSnapshot();
    SPKLog(@"Perf", @"[%@] %@ | vc=%@ views=%@ gestures=%@ deepestStack=%@ windows=%@ stalls=%@ long=%@",
           label ?: @"snapshot",
           SPKPerfMeterSummary(),
           snapshot[@"viewControllers"],
           snapshot[@"views"],
           snapshot[@"gestureRecognizers"],
           snapshot[@"deepestNavStack"],
           snapshot[@"windows"],
           snapshot[@"stalls"],
           snapshot[@"longStalls"]);
    NSDictionary *scopeTime = snapshot[@"scopeTime"];
    NSDictionary *scopeCalls = snapshot[@"scopeCalls"];
    CFTimeInterval elapsed = [snapshot[@"elapsed"] doubleValue];
    for (NSString *key in SPKPerfScopeNamesByCost(scopeTime)) {
        double seconds = [scopeTime[key] doubleValue];
        NSInteger calls = [scopeCalls[key] integerValue];
        NSMutableString *paddedKey = [key mutableCopy];
        while (paddedKey.length < 38)
            [paddedKey appendString:@" "];
        SPKLog(@"Perf", @"  cost %@ %7.0fms  %6ld calls  %6.3fms avg  %4.1f%% of wall",
               paddedKey,
               seconds * 1000.0,
               (long)calls,
               calls > 0 ? seconds * 1000.0 / calls : 0.0,
               elapsed > 0 ? seconds / elapsed * 100.0 : 0.0);
    }

    NSDictionary *counters = snapshot[@"counters"];
    for (NSString *key in [counters keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator)
        SPKLog(@"Perf", @"  counter %@ = %@", key, counters[key]);

    // The freeze stacks, most frequent first. Frames prefixed with * are ours.
    os_unfair_lock_lock(&spkPerfCounterLock);
    NSDictionary *stacks = [spkPerfStallStacks copy] ?: @{};
    os_unfair_lock_unlock(&spkPerfCounterLock);
    NSArray<NSString *> *ranked =
        [stacks keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [b compare:a];
        }];
    NSUInteger shown = 0;
    for (NSString *stack in ranked) {
        if (shown++ >= 5)
            break;
        SPKLog(@"Perf", @"  stall x%@ %@", stacks[stack], stack);
    }
}

// MARK: - Counters

void SPKPerfMeterCountBy(NSString *key, NSInteger amount) {
    if (!spkPerfEnabled || key.length == 0)
        return;
    os_unfair_lock_lock(&spkPerfCounterLock);
    if (!spkPerfCounters)
        spkPerfCounters = [NSMutableDictionary dictionary];
    spkPerfCounters[key] = @(spkPerfCounters[key].integerValue + amount);
    os_unfair_lock_unlock(&spkPerfCounterLock);
}

void SPKPerfMeterCount(NSString *key) {
    SPKPerfMeterCountBy(key, 1);
}

// MARK: - Scopes

SPKPerfScope SPKPerfScopeBegin(NSString *key) {
    // A disabled meter must cost a branch and nothing else: these sit in layout
    // paths that run every frame.
    if (!spkPerfEnabled || key.length == 0)
        return (SPKPerfScope){.key = nil, .start = 0};
    return (SPKPerfScope){.key = key, .start = CACurrentMediaTime()};
}

void SPKPerfScopeEnd(SPKPerfScope *scope) {
    if (!scope || !scope->key)
        return;
    CFTimeInterval elapsed = CACurrentMediaTime() - scope->start;
    NSString *key = scope->key;
    scope->key = nil;

    os_unfair_lock_lock(&spkPerfCounterLock);
    if (!spkPerfScopeTime) {
        spkPerfScopeTime = [NSMutableDictionary dictionary];
        spkPerfScopeCalls = [NSMutableDictionary dictionary];
    }
    spkPerfScopeTime[key] = @(spkPerfScopeTime[key].doubleValue + elapsed);
    spkPerfScopeCalls[key] = @(spkPerfScopeCalls[key].integerValue + 1);
    os_unfair_lock_unlock(&spkPerfCounterLock);
}

#endif // SPK_DEV
