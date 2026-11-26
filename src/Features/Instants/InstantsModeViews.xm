#import "InstantsModeViews.h"
#import "InstantsHeaderItems.h"
#import "../../App/SPKPerfMeter.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

static const char *const kSPKInstantsSnapViewClassName = "_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView";
static const char *const kSPKInstantsCreationViewClassName = "_TtC29IGQuickSnapCreationController23IGQuickSnapCreationView";
static const char *const kSPKInstantsHeaderViewClassName = "_TtC45IGQuickSnapNavigationV3HeaderButtonController39IGQuickSnapNavigationV3HeaderButtonView";

typedef NS_ENUM(NSInteger, SPKInstantsModeViewKind) {
    SPKInstantsModeViewKindSnap = 0,
    SPKInstantsModeViewKindCreation,
    SPKInstantsModeViewKindHeader,
    SPKInstantsModeViewKindCount,
};

static Class sKindClasses[SPKInstantsModeViewKindCount];
static NSHashTable<UIView *> *sKindViews[SPKInstantsModeViewKindCount];
/// Windows whose existing views have been swept once. The hooks only see views that enter a
/// window after they are installed, so each window is walked a single time to pick up anything
/// that was already there.
static NSHashTable<UIWindow *> *sSeededWindows = nil;
/// NO when any of the three classes could not be hooked (a rename in a future build). The
/// registry would then miss views, so queries fall back to walking the window.
static BOOL sRegistryLive = NO;

BOOL SPKInstantsModeViewIsVisible(UIView *view) {
    return view && view.window && !view.hidden && view.alpha >= 0.05 &&
           view.bounds.size.width > 1.0 && view.bounds.size.height > 1.0;
}

static void SPKInstantsModeViewsRegister(UIView *view) {
    for (NSInteger kind = 0; kind < SPKInstantsModeViewKindCount; kind++) {
        if (sKindClasses[kind] && [view isKindOfClass:sKindClasses[kind]]) {
            [sKindViews[kind] addObject:view];
            return;
        }
    }
}

/// Breadth-first walk with an index cursor. Removing from the front of an NSMutableArray is
/// O(n), which made the older walks quadratic in the window's view count.
static void SPKInstantsModeViewsWalk(UIWindow *window, BOOL (^visitor)(UIView *view)) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    for (NSUInteger idx = 0; idx < queue.count; idx++) {
        UIView *view = queue[idx];
        if (visitor(view))
            return;
        [queue addObjectsFromArray:view.subviews];
    }
}

static void SPKInstantsModeViewsSeedWindow(UIWindow *window) {
    if (!window || [sSeededWindows containsObject:window])
        return;
    SPK_PERF_SCOPE(@"InstantsModeViews.seedWindow");
    [sSeededWindows addObject:window];
    SPKInstantsModeViewsWalk(window, ^BOOL(UIView *view) {
        SPKInstantsModeViewsRegister(view);
        return NO;
    });
}

static UIView *SPKInstantsModeViewsFindVisible(SPKInstantsModeViewKind kind, UIWindow *window) {
    if (!window)
        return nil;
    if (sRegistryLive) {
        SPKInstantsModeViewsSeedWindow(window);
        for (UIView *view in sKindViews[kind]) {
            if (view.window == window && SPKInstantsModeViewIsVisible(view))
                return view;
        }
        return nil;
    }
    SPK_PERF_SCOPE(@"InstantsModeViews.fallbackWalk");
    static NSString *const kFallbackNames[SPKInstantsModeViewKindCount] = {
        @"IGQuickSnapImmersiveViewerSingleSnapView",
        @"IGQuickSnapCreationView",
        @"IGQuickSnapNavigationV3HeaderButtonView",
    };
    __block UIView *found = nil;
    SPKInstantsModeViewsWalk(window, ^BOOL(UIView *view) {
        if (SPKInstantsModeViewIsVisible(view) &&
            [NSStringFromClass(view.class) containsString:kFallbackNames[kind]]) {
            found = view;
            return YES;
        }
        return NO;
    });
    return found;
}

BOOL SPKInstantsWindowShowsSnapView(UIWindow *window) {
    return SPKInstantsModeViewsFindVisible(SPKInstantsModeViewKindSnap, window) != nil;
}

BOOL SPKInstantsWindowShowsCreationView(UIWindow *window) {
    return SPKInstantsModeViewsFindVisible(SPKInstantsModeViewKindCreation, window) != nil;
}

UIView *SPKInstantsVisibleHeaderInWindow(UIWindow *window) {
    return SPKInstantsModeViewsFindVisible(SPKInstantsModeViewKindHeader, window);
}

// MARK: - Hooks

typedef void (*SPKInstantsDidMoveToWindowIMP)(id, SEL);
static SPKInstantsDidMoveToWindowIMP orig_didMoveToWindow[SPKInstantsModeViewKindCount];

static void SPKInstantsModeViewDidMoveToWindow(SPKInstantsModeViewKind kind, id self, SEL _cmd) {
    if (orig_didMoveToWindow[kind])
        orig_didMoveToWindow[kind](self, _cmd);
    // Recorded whether the view arrived or left. A departed view simply fails the window match
    // at query time, and the table holds it weakly, so nothing needs removing here.
    [sKindViews[kind] addObject:(UIView *)self];
    // A snap or camera page coming or going changes which Sparkle items the navigation
    // bar header shows; the header view variant re-checks in its own layout pass.
    if (kind != SPKInstantsModeViewKindHeader)
        SPKInstantsNavigationBarItemsSetNeedsUpdate();
}

static void replaced_snapViewDidMoveToWindow(id self, SEL _cmd) {
    SPKInstantsModeViewDidMoveToWindow(SPKInstantsModeViewKindSnap, self, _cmd);
}

static void replaced_creationViewDidMoveToWindow(id self, SEL _cmd) {
    SPKInstantsModeViewDidMoveToWindow(SPKInstantsModeViewKindCreation, self, _cmd);
}

static void replaced_headerViewDidMoveToWindow(id self, SEL _cmd) {
    SPKInstantsModeViewDidMoveToWindow(SPKInstantsModeViewKindHeader, self, _cmd);
}

void SPKInstallInstantsModeViewHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *names[SPKInstantsModeViewKindCount] = {
            kSPKInstantsSnapViewClassName,
            kSPKInstantsCreationViewClassName,
            kSPKInstantsHeaderViewClassName,
        };
        IMP replacements[SPKInstantsModeViewKindCount] = {
            (IMP)replaced_snapViewDidMoveToWindow,
            (IMP)replaced_creationViewDidMoveToWindow,
            (IMP)replaced_headerViewDidMoveToWindow,
        };
        sSeededWindows = [NSHashTable weakObjectsHashTable];
        BOOL allHooked = YES;
        for (NSInteger kind = 0; kind < SPKInstantsModeViewKindCount; kind++) {
            sKindViews[kind] = [NSHashTable weakObjectsHashTable];
            Class cls = objc_getClass(names[kind]);
            if (!cls || !class_getInstanceMethod(cls, @selector(didMoveToWindow))) {
                SPKLog(@"Instants", @"[Sparkle] Mode view class missing %s; header mode checks will walk the window", names[kind]);
                allHooked = NO;
                continue;
            }
            sKindClasses[kind] = cls;
            MSHookMessageEx(cls, @selector(didMoveToWindow), replacements[kind], (IMP *)&orig_didMoveToWindow[kind]);
        }
        sRegistryLive = allHooked;
    });
}
