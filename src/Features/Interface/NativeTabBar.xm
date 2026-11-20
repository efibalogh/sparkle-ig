#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../App/SPKStabilityGuard.h"
#import "../../InstagramHeaders.h"
#import "../../Settings/SPKPreferenceAvailability.h"
#import "../../Settings/SPKPreferences.h"
#import "SPKNativeTabBar.h"
#import "../../Shared/UI/SPKReplayedLongPressGesture.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

// Instagram 451+ ships a second tab bar implementation: a real UITabBarController
// (UITab based, system Liquid Glass) driven by IGNativeTabBarControllerCoordinator.
// -[IGTabBarController initWithUserSession:accountSwitcherPresenter:initMode:]
// only turns it on for foldables on new systems (454.1: iOS 27.1+, isFoldable and
// isSafeAreaAwareResponderGeometryReady), so every other iPhone gets the custom
// bar. When it does turn it on, init asks the controller for its regular and
// compact tab orders, validates them, stores them, and then never creates the
// swipe coordinator. Everything after init reads _usesNativeTabBarController at
// call time.
//
// This repeats that branch through Instagram's own ordering and validation
// methods instead of spoofing the device checks: the foldable answer is used by
// other layout code too, and is cached for the whole process. It has to land
// before -_initializeViewControllers, which init itself calls for the normal
// launch mode and which builds either the custom bar or the native one from
// the flag. Doing it after init leaves the custom bar and its swipe container
// already built.

static NSString *const kSPKNativeTabBarLogCategory = @"NativeTabBar";

static Ivar SPKNativeTabBarIvar(id object, const char *name) {
    return object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
}

static BOOL SPKNativeTabBarIvarIsBool(Ivar ivar) {
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && (type[0] == 'B' || type[0] == 'c');
}

BOOL SPKNativeTabBarIsActive(id controller) {
    Ivar ivar = SPKNativeTabBarIvar(controller, "_usesNativeTabBarController");
    if (!SPKNativeTabBarIvarIsBool(ivar))
        return NO;
    return *((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar)) != 0;
}

static BOOL SPKNativeTabBarPreferenceEnabled(void) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return NO;
    if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0"))
        return NO;
    return [SPKUtils getBoolPref:kSPKPrefInterfaceNativeTabBar];
}

static void SPKForceNativeTabBar(id controller) {
    if (!controller || SPKNativeTabBarIsActive(controller))
        return;

    Ivar flag = SPKNativeTabBarIvar(controller, "_usesNativeTabBarController");
    Ivar expandedIvar = SPKNativeTabBarIvar(controller, "_tabBarSurfaces");
    Ivar compactIvar = SPKNativeTabBarIvar(controller, "_nativeCompactTabBarSurfaces");
    SEL orderedSelector = @selector(_nativeOrderedSurfacesForHorizontalSizeClass:);
    SEL topologySelector = @selector(_nativeTopologyIsSupportedWithExpandedSurfaces:compactSurfaces:);
    if (!SPKNativeTabBarIvarIsBool(flag) || !expandedIvar || !compactIvar ||
        ![controller respondsToSelector:orderedSelector] || ![controller respondsToSelector:topologySelector]) {
        SPKLog(kSPKNativeTabBarLogCategory, @"native path unavailable on this build");
        return;
    }

    NSArray *expanded = nil;
    NSArray *compact = nil;
    BOOL supported = NO;
    @try {
        expanded = ((id (*)(id, SEL, NSInteger))objc_msgSend)(controller, orderedSelector, UIUserInterfaceSizeClassRegular);
        compact = ((id (*)(id, SEL, NSInteger))objc_msgSend)(controller, orderedSelector, UIUserInterfaceSizeClassCompact);
        if ([expanded isKindOfClass:[NSArray class]] && [compact isKindOfClass:[NSArray class]] &&
            expanded.count > 0 && compact.count > 0) {
            supported = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(controller, topologySelector, expanded, compact);
        }
    } @catch (NSException *exception) {
        SPKLog(kSPKNativeTabBarLogCategory, @"topology query threw %@", exception.reason);
        return;
    }
    if (!supported) {
        SPKLog(kSPKNativeTabBarLogCategory, @"topology rejected expanded=%lu compact=%lu",
               (unsigned long)expanded.count, (unsigned long)compact.count);
        return;
    }

    object_setIvarWithStrongDefault(controller, expandedIvar, [expanded copy]);
    object_setIvarWithStrongDefault(controller, compactIvar, [compact copy]);
    *((uint8_t *)(__bridge void *)controller + ivar_getOffset(flag)) = 1;

    // The native branch never builds a swipe coordinator or the custom bar's
    // appearance manager. A swipe coordinator left over from the custom-bar
    // branch would install its paging scroll view over the native controller
    // and switch off appearance forwarding.
    for (const char *name : {"_swipeCoordinator", "_appearanceManager"}) {
        Ivar ivar = SPKNativeTabBarIvar(controller, name);
        if (ivar)
            object_setIvarWithStrongDefault(controller, ivar, nil);
    }

    SPKLog(kSPKNativeTabBarLogCategory, @"forced native tab bar expanded=%lu compact=%lu",
           (unsigned long)expanded.count, (unsigned long)compact.count);
}

static void (*orig_initializeViewControllers)(id, SEL);
static void hook_initializeViewControllers(id self, SEL _cmd) {
    Ivar done = SPKNativeTabBarIvar(self, "_didInitializeViewControllers");
    BOOL alreadyInitialized = SPKNativeTabBarIvarIsBool(done) && *((uint8_t *)(__bridge void *)self + ivar_getOffset(done)) != 0;
    if (!alreadyInitialized && SPKNativeTabBarPreferenceEnabled())
        SPKForceNativeTabBar(self);
    orig_initializeViewControllers(self, _cmd);
}

// MARK: - Live answer

// Containment only: the tab bar controller is never inside a presentation, and
// walking presented controllers from every child re-walks the same subtree.
static id SPKNativeTabBarFindController(UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 12)
        return nil;
    if ([controller isKindOfClass:objc_getClass("IGTabBarController")])
        return controller;
    for (UIViewController *child in controller.childViewControllers) {
        id match = SPKNativeTabBarFindController(child, depth + 1);
        if (match)
            return match;
    }
    return nil;
}

static id SPKNativeTabBarLiveController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id controller = SPKNativeTabBarFindController(window.rootViewController, 0);
            if (controller)
                return controller;
        }
    }
    return nil;
}

// Instagram's regular-width order includes the Activity (subtype 4) and Create
// (subtype 3) launchers only where its header items cannot move into the side
// column, so this is asked of Instagram's own ordering, never of the OS.
BOOL SPKSystemTabBarRegularWidthAddsInstagramTabs(void) {
    id controller = SPKNativeTabBarLiveController();
    SEL ordered = NSSelectorFromString(@"_nativeOrderedSurfacesForHorizontalSizeClass:");
    if (!SPKNativeTabBarIsActive(controller) || ![controller respondsToSelector:ordered])
        return NO;
    NSArray *surfaces = ((id (*)(id, SEL, NSInteger))objc_msgSend)(controller, ordered, UIUserInterfaceSizeClassRegular);
    if (![surfaces isKindOfClass:[NSArray class]])
        return NO;
    for (id surface in surfaces) {
        @try {
            NSUInteger subtype = [[surface valueForKey:@"_subtype"] unsignedIntegerValue];
            if (subtype == 3 || subtype == 4)
                return YES;
        } @catch (__unused NSException *exception) {
        }
    }
    return NO;
}

// Whether the last tab bar Instagram built was the system one. Instagram picks
// it on its own on some devices, and launch code that runs before the tab bar
// controller exists (the tab ordering read) still needs that answer.
static NSString *const kSPKSystemTabBarLastSeenKey = @"spk_system_tab_bar_last_seen";

static void SPKRememberSystemTabBarInUse(BOOL inUse) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kSPKSystemTabBarLastSeenKey] != inUse)
        [defaults setBool:inUse forKey:kSPKSystemTabBarLastSeenKey];
}

// Whether the system tab bar stands as a column down a side of the window, the
// shape a foldable iPhone gets. Read from the live tab group's proportions;
// before it exists, from the last one seen.
static NSString *const kSPKSystemTabBarColumnLastSeenKey = @"spk_system_tab_bar_column_last_seen";

BOOL SPKSystemTabBarRunsAsColumn(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    UIViewController *controller = SPKNativeTabBarLiveController();
    if (!controller)
        return [defaults boolForKey:kSPKSystemTabBarColumnLastSeenKey];
    if (!SPKNativeTabBarIsActive(controller)) {
        if ([defaults boolForKey:kSPKSystemTabBarColumnLastSeenKey])
            [defaults setBool:NO forKey:kSPKSystemTabBarColumnLastSeenKey];
        return NO;
    }
    UIView *platter = nil;
    NSMutableArray<UIView *> *queue = controller.isViewLoaded ? [NSMutableArray arrayWithObject:controller.view] : [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count && i < 800; i++) {
        if ([NSStringFromClass(queue[i].class) containsString:@"TabBarItemPlatterView"]) {
            platter = queue[i];
            break;
        }
        [queue addObjectsFromArray:queue[i].subviews];
    }
    if (!platter || CGRectIsEmpty(platter.bounds))
        return [defaults boolForKey:kSPKSystemTabBarColumnLastSeenKey];
    BOOL column = CGRectGetHeight(platter.bounds) > CGRectGetWidth(platter.bounds) * 2.0;
    if ([defaults boolForKey:kSPKSystemTabBarColumnLastSeenKey] != column)
        [defaults setBool:column forKey:kSPKSystemTabBarColumnLastSeenKey];
    return column;
}

BOOL SPKSystemTabBarInUse(void) {
    id controller = SPKNativeTabBarLiveController();
    if (controller) {
        BOOL inUse = SPKNativeTabBarIsActive(controller);
        SPKRememberSystemTabBarInUse(inUse);
        return inUse;
    }
    if (SPKPrefIsAvailable(kSPKPrefInterfaceNativeTabBar) && SPKNativeTabBarPreferenceEnabled())
        return YES;
    return [NSUserDefaults.standardUserDefaults boolForKey:kSPKSystemTabBarLastSeenKey];
}

// MARK: - Surfaces and tabs
//
// The native path builds its UITabs from _tabBarSurfaces (regular width) and
// _nativeCompactTabBarSurfaces (compact width) each time it installs or updates
// the bar, so Navigation filters and orders both lists first, then relabels the
// Saved tab, whose UITab title comes from the surface rather than the button.

extern "C" void SPKNavigationPrepareNativeTabBarSurfaces(id controller);
extern "C" void SPKNavigationDecorateNativeTabs(id controller);
extern "C" BOOL SPKNavigationSingleTabHidesTabBar(void);
extern "C" BOOL SPKNavigationProfileTabCarriesSaved(void);

// MARK: - Tab hold feel
//
// Every hold on the native bar goes through one recognizer the coordinator
// owns, and the system bar's own press-and-slide selection competes with it:
// a finger that drifts a little hands the touch to the selection lens and the
// hold never fires. The custom bar avoids that by making every other gesture
// on a tab button wait for its hold to fail. This gives the native bar the
// same feel: the custom bar's hold duration, and the bar's other gestures wait
// for the hold to fail first. A tap still selects the tab, because the hold
// fails the moment the finger lifts.

static const void *kSPKNativeTabHoldTunedKey = &kSPKNativeTabHoldTunedKey;
static const void *kSPKNativeTabHoldWaitsKey = &kSPKNativeTabHoldWaitsKey;
static const NSTimeInterval kSPKNativeTabHoldDuration = 0.5;

static void SPKNativeTabBarCollectGestures(UIView *view, NSMutableArray<UIGestureRecognizer *> *gestures, NSUInteger depth) {
    if (!view || depth > 10)
        return;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers)
        [gestures addObject:gesture];
    for (UIView *subview in view.subviews)
        SPKNativeTabBarCollectGestures(subview, gestures, depth + 1);
}

static void SPKNativeTabBarTuneHold(id controller) {
    if (!controller || SPKStabilityGuardIsSafeStartupMode() || !SPKNativeTabBarIsActive(controller))
        return;
    id coordinator = [SPKUtils getIvarForObj:controller name:"_nativeTabBarControllerCoordinator"];
    if (!coordinator)
        return;
    id recognizer = [SPKUtils getIvarForObj:coordinator name:"longPressRecognizer"];
    if (![recognizer isKindOfClass:[UILongPressGestureRecognizer class]])
        return;
    UILongPressGestureRecognizer *hold = (UILongPressGestureRecognizer *)recognizer;

    if (!objc_getAssociatedObject(hold, kSPKNativeTabHoldTunedKey)) {
        SPKLog(kSPKNativeTabBarLogCategory, @"tab hold: duration %.2f movement %.1f view %@", hold.minimumPressDuration, hold.allowableMovement,
               NSStringFromClass([hold.view class]));
        hold.minimumPressDuration = kSPKNativeTabHoldDuration;
        objc_setAssociatedObject(hold, kSPKNativeTabHoldTunedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Only the bar itself: the hold may be attached to the controller's whole
    // view, and content gestures must not wait on it.
    id tabBarController = [SPKUtils getIvarForObj:coordinator name:"tabBarController"];
    if (![tabBarController isKindOfClass:[UITabBarController class]])
        return;
    UITabBar *tabBar = ((UITabBarController *)tabBarController).tabBar;
    NSMutableArray<UIGestureRecognizer *> *gestures = [NSMutableArray array];
    SPKNativeTabBarCollectGestures(tabBar, gestures, 0);
    for (UIGestureRecognizer *gesture in gestures) {
        if (gesture == hold || objc_getAssociatedObject(gesture, kSPKNativeTabHoldWaitsKey) == hold)
            continue;
        // Pointer hover and click never compete with a finger, and a hold that
        // no finger ever touches would keep them waiting.
        if ([gesture isKindOfClass:[UIHoverGestureRecognizer class]] ||
            ![gesture.allowedTouchTypes containsObject:@(UITouchTypeDirect)])
            continue;
        [gesture requireGestureRecognizerToFail:hold];
        objc_setAssociatedObject(gesture, kSPKNativeTabHoldWaitsKey, hold, OBJC_ASSOCIATION_ASSIGN);
        SPKLog(kSPKNativeTabBarLogCategory, @"tab hold: %@ waits for the hold", NSStringFromClass([gesture class]));
    }
}

// The bar builds its tab views lazily, so the pass runs again on the next turn.
static void SPKNativeTabBarScheduleHoldTuning(id controller) {
    SPKNativeTabBarTuneHold(controller);
    __weak id weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKNativeTabBarTuneHold(weakController);
    });
}

static BOOL (*orig_installOrUpdateNative)(id, SEL);
static BOOL hook_installOrUpdateNative(id self, SEL _cmd) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return orig_installOrUpdateNative(self, _cmd);
    SPKRememberSystemTabBarInUse(SPKNativeTabBarIsActive(self));
    SPKNavigationPrepareNativeTabBarSurfaces(self);
    BOOL result = orig_installOrUpdateNative(self, _cmd);
    SPKNavigationDecorateNativeTabs(self);
    SPKNativeTabBarScheduleHoldTuning(self);
    return result;
}

// The coordinator also rebuilds its UITabs without the controller when the
// width class changes (the compact projection on fold and unfold) and when
// Instagram swaps descriptors, so the Saved title is put back after those too.
static void (*orig_setUsesCompactProjection)(id, SEL, BOOL, id);
static BOOL hook_setUsesCompactProjection(id self, SEL _cmd, BOOL compact, id fallback) {
    BOOL result = ((BOOL (*)(id, SEL, BOOL, id))orig_setUsesCompactProjection)(self, _cmd, compact, fallback);
    if (!SPKStabilityGuardIsSafeStartupMode()) {
        SPKNavigationDecorateNativeTabs(SPKNativeTabBarLiveController());
        SPKNativeTabBarScheduleHoldTuning(SPKNativeTabBarLiveController());
    }
    return result;
}

static void (*orig_replaceDescriptors)(id, SEL, id, id);
static BOOL hook_replaceDescriptors(id self, SEL _cmd, id descriptors, id fallback) {
    BOOL result = ((BOOL (*)(id, SEL, id, id))orig_replaceDescriptors)(self, _cmd, descriptors, fallback);
    if (!SPKStabilityGuardIsSafeStartupMode())
        SPKNavigationDecorateNativeTabs(SPKNativeTabBarLiveController());
    return result;
}

// The profile tab draws the account photo over its glyph. While that slot
// carries Saved the photo would cover the Saved glyph, so it is not fetched.
static void (*orig_updateNativeProfileTabPhoto)(id, SEL);
static void hook_updateNativeProfileTabPhoto(id self, SEL _cmd) {
    if (!SPKStabilityGuardIsSafeStartupMode() && SPKNavigationProfileTabCarriesSaved())
        return;
    orig_updateNativeProfileTabPhoto(self, _cmd);
}

// MARK: - Visibility
//
// Two reasons to keep the bar down, both answered here so one hook owns the
// setter. Single-tab mode hides the bar for good: hiding the bar view alone
// leaves UIKit's floating tab up, and Instagram asks to show it again after
// every pop. And chrome helpers on the native style turn their "show the bar"
// state into -setTabBarVisibilityHidden:NO even while the visible screen hides
// the bar (a reel opened from Direct or from a feed post). Instagram drops that
// request itself only behind IGAdaptivePresentation.isEnabled, which only
// foldables turn on, so it is dropped here with Instagram's own predicate.

static BOOL SPKNativeTabBarContentHidesBar(id controller) {
    if (![controller respondsToSelector:@selector(selectedViewController)] ||
        ![controller respondsToSelector:@selector(_shouldTabBarBeHiddenForController:)])
        return NO;
    id selected = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(selectedViewController));
    return selected && ((BOOL (*)(id, SEL, id))objc_msgSend)(controller, @selector(_shouldTabBarBeHiddenForController:), selected);
}

static void (*orig_setTabBarVisibilityHidden)(id, SEL, BOOL, BOOL);
static void hook_setTabBarVisibilityHidden(id self, SEL _cmd, BOOL hidden, BOOL animated) {
    if (!hidden && !SPKStabilityGuardIsSafeStartupMode()) {
        if (SPKNavigationSingleTabHidesTabBar())
            hidden = YES;
        else if (SPKNativeTabBarIsActive(self) && SPKNativeTabBarContentHidesBar(self))
            return;
    }
    orig_setTabBarVisibilityHidden(self, _cmd, hidden, animated);
}

// MARK: - Tab holds
//
// The native bar draws system tabs, so the gestures Sparkle and Instagram put
// on the custom bar's buttons never see a touch. The coordinator only attaches
// a hold to tabs whose descriptor names a long-press action (Instagram's own:
// Home and Profile), asks the controller whether a tab can be held, and then
// reports the press phases. Two Sparkle holds ride on that: the Settings and
// Gallery shortcuts on their host tabs, which take precedence as they do on
// the custom bar, and the Explore hold (search, plus the clipboard link and
// username shortcuts that hook the custom bar's Explore handler), replayed
// into that handler with a stand-in recognizer.

extern "C" NSInteger SPKNativeTabShortcutForSurface(id controller, id surface);
extern "C" NSString *SPKNativeTabShortcutActionName(NSInteger shortcut);
extern "C" void SPKPerformNativeTabShortcut(id controller, NSInteger shortcut);

static id SPKNativeTabBarSurfaceForIdentifier(id controller, id identifier) {
    if (!identifier || ![controller respondsToSelector:@selector(_surfaceForNativeIdentifier:)])
        return nil;
    return [controller _surfaceForNativeIdentifier:identifier];
}

static BOOL SPKNativeTabBarSurfaceIsExplore(id controller, id surface) {
    if (!surface || ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)] ||
        ![controller respondsToSelector:@selector(_exploreButtonLongPressed:)])
        return NO;
    id explore = [SPKUtils getIvarForObj:controller name:"_exploreButton"];
    return explore && [controller _buttonForTabBarSurface:surface] == explore;
}

// Foldables get the native bar from Instagram itself, with no Sparkle pref
// involved, so the hold is offered whenever something Sparkle owns wants it:
// the forced bar (to keep search on hold) or the clipboard link shortcut.
static BOOL SPKNativeTabBarExploreHoldWanted(void) {
    return SPKNativeTabBarPreferenceEnabled() || [SPKUtils getBoolPref:@"interface_open_clipboard_link"];
}

typedef NS_ENUM(NSInteger, SPKNativeTabHold) {
    SPKNativeTabHoldInstagram = 0,
    SPKNativeTabHoldShortcut,
    SPKNativeTabHoldExplore,
};

static SPKNativeTabHold SPKNativeTabHoldForSurface(id controller, id surface, NSInteger *shortcut) {
    if (!surface || SPKStabilityGuardIsSafeStartupMode() || !SPKNativeTabBarIsActive(controller))
        return SPKNativeTabHoldInstagram;
    NSInteger found = SPKNativeTabShortcutForSurface(controller, surface);
    if (found != 0) {
        if (shortcut)
            *shortcut = found;
        return SPKNativeTabHoldShortcut;
    }
    if (SPKNativeTabBarExploreHoldWanted() && SPKNativeTabBarSurfaceIsExplore(controller, surface))
        return SPKNativeTabHoldExplore;
    return SPKNativeTabHoldInstagram;
}

// Coordinator long-press phases, as Instagram's own handler reads them.
static UIGestureRecognizerState SPKNativeTabBarGestureStateForPhase(NSInteger phase) {
    switch (phase) {
    case 0:
        return UIGestureRecognizerStateBegan;
    case 1:
        return UIGestureRecognizerStateChanged;
    case 2:
        return UIGestureRecognizerStateEnded;
    case 3:
        return UIGestureRecognizerStateCancelled;
    default:
        return UIGestureRecognizerStateFailed;
    }
}

static NSString *(*orig_longPressActionName)(id, SEL, id);
static NSString *hook_longPressActionName(id self, SEL _cmd, id surface) {
    NSInteger shortcut = 0;
    switch (SPKNativeTabHoldForSurface(self, surface, &shortcut)) {
    case SPKNativeTabHoldShortcut:
        return SPKNativeTabShortcutActionName(shortcut);
    case SPKNativeTabHoldExplore: {
        NSString *name = orig_longPressActionName(self, _cmd, surface);
        return name.length > 0 ? name : SPKL(@"INTERFACE_NATIVE_TAB_BAR_EXPLORE_HOLD_ACCESSIBILITY_ACTION");
    }
    case SPKNativeTabHoldInstagram:
        break;
    }
    return orig_longPressActionName(self, _cmd, surface);
}

static BOOL (*orig_canLongPress)(id, SEL, id, id);
static BOOL hook_canLongPress(id self, SEL _cmd, id coordinator, id identifier) {
    if (SPKNativeTabHoldForSurface(self, SPKNativeTabBarSurfaceForIdentifier(self, identifier), NULL) != SPKNativeTabHoldInstagram)
        return YES;
    return orig_canLongPress(self, _cmd, coordinator, identifier);
}

static void (*orig_didUpdateLongPress)(id, SEL, id, id, NSInteger);
static void hook_didUpdateLongPress(id self, SEL _cmd, id coordinator, id identifier, NSInteger phase) {
    NSInteger shortcut = 0;
    switch (SPKNativeTabHoldForSurface(self, SPKNativeTabBarSurfaceForIdentifier(self, identifier), &shortcut)) {
    case SPKNativeTabHoldShortcut:
        // The press belongs to Sparkle, so the tab's own hold action (the
        // account switcher on Profile) never sees any of its phases. Phase 0 is
        // the press being recognized; the later ones belong to the same press.
        if (phase == 0)
            SPKPerformNativeTabShortcut(self, shortcut);
        return;
    case SPKNativeTabHoldExplore: {
        SPKReplayedLongPressGesture *gesture = [[SPKReplayedLongPressGesture alloc] initWithTarget:nil action:NULL];
        gesture.spk_state = SPKNativeTabBarGestureStateForPhase(phase);
        [self _exploreButtonLongPressed:gesture];
        return;
    }
    case SPKNativeTabHoldInstagram:
        break;
    }
    orig_didUpdateLongPress(self, _cmd, coordinator, identifier, phase);
}

static void (*orig_fallBackToLegacy)(id, SEL);
static void hook_fallBackToLegacy(id self, SEL _cmd) {
    SPKLog(kSPKNativeTabBarLogCategory, @"native coordinator failed, Instagram fell back to its own tab bar");
    orig_fallBackToLegacy(self, _cmd);
}

// MARK: - Installers

static void SPKNativeTabBarHookIfPresent(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(selectorName);
    if (class_getInstanceMethod(cls, selector))
        MSHookMessageEx(cls, selector, replacement, original);
}

void SPKInstallNativeTabBarCoordinatorHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // IG 410 and every build before the native path stop here: nothing
        // below exists there, and the custom bar's own hooks cover it.
        Class controllerClass = objc_getClass("IGTabBarController");
        if (!controllerClass || !class_getInstanceVariable(controllerClass, "_usesNativeTabBarController"))
            return;

        SPKNativeTabBarHookIfPresent(controllerClass, @"_installOrUpdateNativeTabBarController", (IMP)hook_installOrUpdateNative,
                                     (IMP *)&orig_installOrUpdateNative);
        SPKNativeTabBarHookIfPresent(controllerClass, @"_updateNativeProfileTabPhoto", (IMP)hook_updateNativeProfileTabPhoto,
                                     (IMP *)&orig_updateNativeProfileTabPhoto);
        SPKNativeTabBarHookIfPresent(controllerClass, @"setTabBarVisibilityHidden:animated:", (IMP)hook_setTabBarVisibilityHidden,
                                     (IMP *)&orig_setTabBarVisibilityHidden);
        SPKNativeTabBarHookIfPresent(controllerClass, @"_fallBackToLegacyTabBarAfterNativeCoordinatorFailure", (IMP)hook_fallBackToLegacy,
                                     (IMP *)&orig_fallBackToLegacy);

        Class coordinatorClass = objc_getClass("_TtC35IGNativeTabBarControllerCoordinator35IGNativeTabBarControllerCoordinator");
        if (coordinatorClass) {
            SPKNativeTabBarHookIfPresent(coordinatorClass, @"setUsesCompactTabProjection:fallbackSelectedIdentifier:",
                                         (IMP)hook_setUsesCompactProjection, (IMP *)&orig_setUsesCompactProjection);
            SPKNativeTabBarHookIfPresent(coordinatorClass, @"replaceDescriptors:fallbackSelectedIdentifier:", (IMP)hook_replaceDescriptors,
                                         (IMP *)&orig_replaceDescriptors);
        }

        SEL actionName = @selector(_nativeLongPressAccessibilityActionNameForSurface:);
        SEL canLongPress = @selector(nativeTabBarControllerCoordinator:canLongPressIdentifier:);
        SEL didUpdate = @selector(nativeTabBarControllerCoordinator:didUpdateLongPressIdentifier:phase:);
        if (class_getInstanceMethod(controllerClass, actionName) && class_getInstanceMethod(controllerClass, canLongPress) &&
            class_getInstanceMethod(controllerClass, didUpdate) &&
            class_getInstanceMethod(controllerClass, @selector(_surfaceForNativeIdentifier:))) {
            MSHookMessageEx(controllerClass, actionName, (IMP)hook_longPressActionName, (IMP *)&orig_longPressActionName);
            MSHookMessageEx(controllerClass, canLongPress, (IMP)hook_canLongPress, (IMP *)&orig_canLongPress);
            MSHookMessageEx(controllerClass, didUpdate, (IMP)hook_didUpdateLongPress, (IMP *)&orig_didUpdateLongPress);
        }
    });
}

// iOS 27 UIKit API the native path messages from Objective-C. iOS 26 lacks it,
// and there is nothing to update there, so it answers with a no-op.
static void SPKNoOpUpdateVerticalBarConfiguration(__unused id self, __unused SEL _cmd) {}

// System Tab Bar: forces the native bar where Instagram would not pick it.
// The controller is built once during launch, so the choice needs a restart.
extern "C" void SPKInstallNativeTabBarHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!SPKNativeTabBarPreferenceEnabled())
            return;
        Class controllerClass = objc_getClass("IGTabBarController");
        SEL initializeSelector = NSSelectorFromString(@"_initializeViewControllers");
        if (!controllerClass || !class_getInstanceMethod(controllerClass, initializeSelector) ||
            !class_getInstanceVariable(controllerClass, "_usesNativeTabBarController")) {
            SPKLog(kSPKNativeTabBarLogCategory, @"IGTabBarController has no native path");
            return;
        }

        SEL verticalBarSelector = NSSelectorFromString(@"setNeedsUpdateOfVerticalBarConfiguration");
        if (![UIViewController instancesRespondToSelector:verticalBarSelector])
            class_addMethod([UIViewController class], verticalBarSelector, (IMP)SPKNoOpUpdateVerticalBarConfiguration, "v@:");

        MSHookMessageEx(controllerClass, initializeSelector, (IMP)hook_initializeViewControllers, (IMP *)&orig_initializeViewControllers);
    });
}
