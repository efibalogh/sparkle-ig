#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../App/SPKStabilityGuard.h"
#import "../../InstagramHeaders.h"
#import "../../Settings/SPKPreferences.h"
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

// MARK: - Visibility
//
// Chrome helpers on the native style turn their "show the bar" state into
// -setTabBarVisibilityHidden:NO. Instagram drops that request while the visible
// screen hides the bar (a reel opened from Direct or from a feed post), but
// only behind IGAdaptivePresentation.isEnabled, which only foldables turn on,
// so it is dropped here with Instagram's own predicate.

static BOOL SPKNativeTabBarContentHidesBar(id controller) {
    if (![controller respondsToSelector:@selector(selectedViewController)] ||
        ![controller respondsToSelector:@selector(_shouldTabBarBeHiddenForController:)])
        return NO;
    id selected = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(selectedViewController));
    return selected && ((BOOL (*)(id, SEL, id))objc_msgSend)(controller, @selector(_shouldTabBarBeHiddenForController:), selected);
}

static void (*orig_setTabBarVisibilityHidden)(id, SEL, BOOL, BOOL);
static void hook_setTabBarVisibilityHidden(id self, SEL _cmd, BOOL hidden, BOOL animated) {
    if (!hidden && SPKNativeTabBarIsActive(self) && SPKNativeTabBarContentHidesBar(self))
        return;
    orig_setTabBarVisibilityHidden(self, _cmd, hidden, animated);
}

// MARK: - Explore hold
//
// The custom bar's Explore button carries a long press (search, and the
// clipboard link and username shortcuts that hook the same handler). The
// native bar only attaches a hold to tabs whose descriptor names a long-press
// action, and Explore has none outside a server gate, so it gets one here and
// the coordinator's phases drive the custom bar's handler with a stand-in
// recognizer.

static BOOL SPKNativeTabBarSurfaceIsExplore(id controller, id surface) {
    if (!surface || ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)])
        return NO;
    id explore = [SPKUtils getIvarForObj:controller name:"_exploreButton"];
    return explore && [controller _buttonForTabBarSurface:surface] == explore;
}

// Foldables get the native bar from Instagram itself, with no Sparkle pref
// involved, so the hold is offered whenever the bar is native and something
// Sparkle owns wants it: the forced bar (to keep search on hold) or the
// clipboard link shortcut.
static BOOL SPKNativeTabBarExploreHoldWanted(id controller) {
    if (!SPKNativeTabBarIsActive(controller))
        return NO;
    return SPKNativeTabBarPreferenceEnabled() || [SPKUtils getBoolPref:@"interface_open_clipboard_link"];
}

static BOOL SPKNativeTabBarIdentifierIsExplore(id controller, id identifier) {
    if (!identifier || ![controller respondsToSelector:@selector(_surfaceForNativeIdentifier:)])
        return NO;
    return SPKNativeTabBarSurfaceIsExplore(controller, [controller _surfaceForNativeIdentifier:identifier]);
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
    NSString *name = orig_longPressActionName(self, _cmd, surface);
    if (name.length == 0 && SPKNativeTabBarExploreHoldWanted(self) && SPKNativeTabBarSurfaceIsExplore(self, surface))
        return SPKL(@"INTERFACE_NATIVE_TAB_BAR_EXPLORE_HOLD_ACCESSIBILITY_ACTION");
    return name;
}

static BOOL (*orig_canLongPress)(id, SEL, id, id);
static BOOL hook_canLongPress(id self, SEL _cmd, id coordinator, id identifier) {
    if (SPKNativeTabBarExploreHoldWanted(self) && SPKNativeTabBarIdentifierIsExplore(self, identifier))
        return YES;
    return orig_canLongPress(self, _cmd, coordinator, identifier);
}

static void (*orig_didUpdateLongPress)(id, SEL, id, id, NSInteger);
static void hook_didUpdateLongPress(id self, SEL _cmd, id coordinator, id identifier, NSInteger phase) {
    if (!SPKNativeTabBarExploreHoldWanted(self) || !SPKNativeTabBarIdentifierIsExplore(self, identifier) ||
        ![self respondsToSelector:@selector(_exploreButtonLongPressed:)]) {
        orig_didUpdateLongPress(self, _cmd, coordinator, identifier, phase);
        return;
    }
    SPKReplayedLongPressGesture *gesture = [[SPKReplayedLongPressGesture alloc] initWithTarget:nil action:NULL];
    gesture.spk_state = SPKNativeTabBarGestureStateForPhase(phase);
    [self _exploreButtonLongPressed:gesture];
}

static void SPKInstallNativeTabBarExploreHoldHooks(Class controllerClass) {
    SEL actionName = @selector(_nativeLongPressAccessibilityActionNameForSurface:);
    SEL canLongPress = @selector(nativeTabBarControllerCoordinator:canLongPressIdentifier:);
    SEL didUpdate = @selector(nativeTabBarControllerCoordinator:didUpdateLongPressIdentifier:phase:);
    if (!class_getInstanceMethod(controllerClass, actionName) || !class_getInstanceMethod(controllerClass, canLongPress) ||
        !class_getInstanceMethod(controllerClass, didUpdate) || !class_getInstanceMethod(controllerClass, @selector(_surfaceForNativeIdentifier:)) ||
        !class_getInstanceMethod(controllerClass, @selector(_exploreButtonLongPressed:)))
        return;
    MSHookMessageEx(controllerClass, actionName, (IMP)hook_longPressActionName, (IMP *)&orig_longPressActionName);
    MSHookMessageEx(controllerClass, canLongPress, (IMP)hook_canLongPress, (IMP *)&orig_canLongPress);
    MSHookMessageEx(controllerClass, didUpdate, (IMP)hook_didUpdateLongPress, (IMP *)&orig_didUpdateLongPress);
}

static void (*orig_fallBackToLegacy)(id, SEL);
static void hook_fallBackToLegacy(id self, SEL _cmd) {
    SPKLog(kSPKNativeTabBarLogCategory, @"native coordinator failed, Instagram fell back to its own tab bar");
    orig_fallBackToLegacy(self, _cmd);
}

static void SPKInstallNativeTabBarVisibilityHooks(Class controllerClass) {
    SEL setHidden = NSSelectorFromString(@"setTabBarVisibilityHidden:animated:");
    if (class_getInstanceMethod(controllerClass, setHidden))
        MSHookMessageEx(controllerClass, setHidden, (IMP)hook_setTabBarVisibilityHidden, (IMP *)&orig_setTabBarVisibilityHidden);
    SEL fallback = NSSelectorFromString(@"_fallBackToLegacyTabBarAfterNativeCoordinatorFailure");
    if (class_getInstanceMethod(controllerClass, fallback))
        MSHookMessageEx(controllerClass, fallback, (IMP)hook_fallBackToLegacy, (IMP *)&orig_fallBackToLegacy);
}

// iOS 27 UIKit API the native path messages from Objective-C. iOS 26 lacks it,
// and there is nothing to update there, so it answers with a no-op.
static void SPKNoOpUpdateVerticalBarConfiguration(__unused id self, __unused SEL _cmd) {}

extern "C" void SPKInstallNativeTabBarHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controllerClass = objc_getClass("IGTabBarController");
        // Installed whatever the pref says: foldables run the native bar on
        // their own, and the hold re-checks its prefs at call time.
        if (controllerClass && !SPKStabilityGuardIsSafeStartupMode())
            SPKInstallNativeTabBarExploreHoldHooks(controllerClass);
        // The controller is built once during launch, so the choice needs a restart.
        if (!SPKNativeTabBarPreferenceEnabled())
            return;
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
        SPKInstallNativeTabBarVisibilityHooks(controllerClass);
    });
}
