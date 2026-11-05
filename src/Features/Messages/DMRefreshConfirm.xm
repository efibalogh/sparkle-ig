#import <UIKit/UIKit.h>
#import "SPKStrings.h"
#import <objc/message.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

static void (*orig_inboxRefreshControlArg)(id, SEL, id) = NULL;
static void (*orig_networkingCoordinatorPullToRefreshIfPossible)(id, SEL) = NULL;
static BOOL (*orig_executePullToRefreshWithParams)(id, SEL, id, BOOL) = NULL;
static BOOL sSPKDMRefreshBypassing = NO;
static BOOL sSPKDMRefreshAlertVisible = NO;

// IG 437+ routes every inbox pull-to-refresh through an IGDirectInboxPullToRefreshCoordinator
// (Django + MDCore composite), whose selector carries a third handler argument. The coordinator
// is reached through an @objc protocol, so the swizzle fires no matter which inbox view
// controller (legacy ObjC or the Swift rewrite) is live.
typedef BOOL (*SPKExecutePTRIMP)(id, SEL, id, BOOL, id);

static struct {
    __unsafe_unretained Class cls;
    SPKExecutePTRIMP orig;
} sSPKExecutePTROrigs[4];
static NSUInteger sSPKExecutePTROrigCount = 0;

static SPKExecutePTRIMP SPKDMLookupExecutePTROrig(id self) {
    for (NSUInteger i = 0; i < sSPKExecutePTROrigCount; i++) {
        if ([self isKindOfClass:sSPKExecutePTROrigs[i].cls])
            return sSPKExecutePTROrigs[i].orig;
    }
    return NULL;
}

// Both the legacy ObjC inbox VC and its Swift replacement can be present in the same build, so
// every match gets its own trampoline slot instead of a single shared orig pointer.
typedef void (*SPKRefreshNoArgIMP)(id, SEL);

static struct {
    __unsafe_unretained Class cls;
    SEL sel;
    SPKRefreshNoArgIMP orig;
} sSPKRefreshNoArgOrigs[6];
static NSUInteger sSPKRefreshNoArgOrigCount = 0;

static SPKRefreshNoArgIMP SPKDMLookupRefreshNoArgOrig(id self, SEL _cmd) {
    for (NSUInteger i = 0; i < sSPKRefreshNoArgOrigCount; i++) {
        if (sSPKRefreshNoArgOrigs[i].sel == _cmd && [self isKindOfClass:sSPKRefreshNoArgOrigs[i].cls])
            return sSPKRefreshNoArgOrigs[i].orig;
    }
    return NULL;
}

// IGRefreshControl can be created with -initWithoutAddingAsASubviewOfScrollView:, so it is not
// reliably reachable from a view hierarchy or from a _refreshControl ivar. Tracking the instance
// that actually started spinning is the only dependable way to stop it again on cancel.
static __weak IGRefreshControl *sSPKLoadingRefreshControl = nil;
static void (*orig_refreshControlStartLoading)(id, SEL, BOOL) = NULL;
static void (*orig_refreshControlDidEndDragging)(id, SEL) = NULL;
static void (*orig_refreshControlDidScroll)(id, SEL) = NULL;

static long long SPKDMRefreshStateOf(IGRefreshControl *control) {
    if (![control respondsToSelector:@selector(refreshState)])
        return 0;
    return ((long long (*)(id, SEL))objc_msgSend)(control, @selector(refreshState));
}

// -startLoadingAnimated: only covers programmatic refreshes; a user drag drives the control
// through its scroll callbacks instead, so all three are tracked.
static void replaced_refreshControlStartLoading(id self, SEL _cmd, BOOL animated) {
    sSPKLoadingRefreshControl = (IGRefreshControl *)self;
    if (orig_refreshControlStartLoading)
        orig_refreshControlStartLoading(self, _cmd, animated);
}

static void replaced_refreshControlDidEndDragging(id self, SEL _cmd) {
    sSPKLoadingRefreshControl = (IGRefreshControl *)self;
    if (orig_refreshControlDidEndDragging)
        orig_refreshControlDidEndDragging(self, _cmd);
}

static void replaced_refreshControlDidScroll(id self, SEL _cmd) {
    sSPKLoadingRefreshControl = (IGRefreshControl *)self;
    if (orig_refreshControlDidScroll)
        orig_refreshControlDidScroll(self, _cmd);
}

static IGRefreshControl *SPKDMFindIGRefreshControl(id self, id arg) {
    // Check if arg is an IGRefreshControl
    Class igRefreshControlClass = NSClassFromString(@"IGRefreshControl");
    if (arg && igRefreshControlClass && [arg isKindOfClass:igRefreshControlClass])
        return (IGRefreshControl *)arg;

    // Try the view controller's own ivar. The legacy ObjC inbox VC names it _refreshControl;
    // the Swift rewrite (IG 440) names it refreshControl, with no underscore.
    if ([self isKindOfClass:[UIViewController class]]) {
        for (const char *ivarName : { "_refreshControl", "refreshControl" }) {
            Ivar ivar = class_getInstanceVariable([self class], ivarName);
            if (!ivar)
                continue;
            id control = object_getIvar(self, ivar);
            if (igRefreshControlClass && [control isKindOfClass:igRefreshControlClass])
                return (IGRefreshControl *)control;
        }
    }

    return nil;
}

static IGRefreshControl *SPKDMSearchIGRefreshControlInView(UIView *view, Class igRefreshControlClass, NSUInteger depth) {
    if (!view || depth > 12)
        return nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:igRefreshControlClass])
            return (IGRefreshControl *)subview;
        IGRefreshControl *found = SPKDMSearchIGRefreshControlInView(subview, igRefreshControlClass, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

// Coordinator-level hooks get no view controller to work from, so fall back to sweeping the
// foreground window for the live IGRefreshControl (it is a UIControl inside the inbox list).
static IGRefreshControl *SPKDMFindIGRefreshControlInWindows(void) {
    Class igRefreshControlClass = NSClassFromString(@"IGRefreshControl");
    if (!igRefreshControlClass)
        return nil;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            IGRefreshControl *found = SPKDMSearchIGRefreshControlInView(window, igRefreshControlClass, 0);
            if (found)
                return found;
        }
    }
    return nil;
}

// Instagram's own "the refresh is over" entry points. Cancelling lands in the middle of the
// control's release handshake, where -finishLoading alone can leave the scroll view's inset
// expanded, so the inbox view controller is driven through the same completion it would run at the
// end of a real fetch. The selector was renamed when the inbox moved to Swift, and 410 passes the
// coordinator, so all three shapes are tried.
static BOOL SPKDMNotifyInboxRefreshEnded(id target) {
    if (![target isKindOfClass:[UIViewController class]])
        return NO;

    SEL didFetch = NSSelectorFromString(@"pullToRefreshDidFetchInbox");
    if ([target respondsToSelector:didFetch]) {
        ((void (*)(id, SEL))objc_msgSend)(target, didFetch);
        return YES;
    }

    SEL legacyDidFetch = NSSelectorFromString(@"inboxPullToRefreshCoordinatorDidFetchInbox:");
    if ([target respondsToSelector:legacyDidFetch]) {
        id coordinator = nil;
        Ivar ivar = class_getInstanceVariable([target class], "_pullToRefreshCoordinator");
        if (ivar)
            coordinator = object_getIvar(target, ivar);
        ((void (*)(id, SEL, id))objc_msgSend)(target, legacyDidFetch, coordinator);
        return YES;
    }

    return NO;
}

// Last resort when the view controller offers no completion to drive: put the scroll view back on
// its idle inset by hand, the way the refresh control would have.
static void SPKDMRestoreIdleContentInset(IGRefreshControl *control, id owner) {
    UIScrollView *scrollView = nil;
    for (UIView *view = control.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UIScrollView class]]) {
            scrollView = (UIScrollView *)view;
            break;
        }
    }
    if (!scrollView)
        return;

    CGFloat idleInset = scrollView.contentInset.top;
    SEL idleSel = NSSelectorFromString(@"idleTopContentInsetForRefreshControl:");
    if ([owner respondsToSelector:idleSel])
        idleInset = ((CGFloat (*)(id, SEL, id))objc_msgSend)(owner, idleSel, control);

    [UIView animateWithDuration:0.25 animations:^{
        UIEdgeInsets insets = scrollView.contentInset;
        insets.top = idleInset;
        scrollView.contentInset = insets;

        CGPoint offset = scrollView.contentOffset;
        if (offset.y < -idleInset) {
            offset.y = -idleInset;
            scrollView.contentOffset = offset;
        }
    }];
}

// The spinner is torn down through the refresh control's own delegate contract: -finishLoading
// runs the disappear animation and hands control back with
// -refreshControlDidEndFinishLoadingAnimation:. It is a no-op when the control is already idle,
// but it can also land while the control is still animating into its loading state, so the state
// is re-checked once afterwards and the teardown repeated if nothing moved.
static void SPKDMFinishLoadingOnControl(IGRefreshControl *control, id owner) {
    if (!control)
        return;

    long long stateBefore = SPKDMRefreshStateOf(control);
    [control finishLoading];

    __weak id weakOwner = owner;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (SPKDMRefreshStateOf(control) != stateBefore)
            return;
        SPKLog(@"DMRefresh", @"refresh control still in state %lld after cancel, finishing again", stateBefore);
        [control finishLoading];
        if (!SPKDMNotifyInboxRefreshEnded(weakOwner))
            SPKDMRestoreIdleContentInset(control, weakOwner);
    });
}

static void SPKDMEndRefreshIfNeeded(id self, id arg) {
    // Coordinator-level hooks have no view controller to read an ivar from, so fall back to the
    // control the user was last dragging, then to a hierarchy sweep.
    IGRefreshControl *refreshControl = SPKDMFindIGRefreshControl(self, arg);
    if (!refreshControl)
        refreshControl = sSPKLoadingRefreshControl;
    if (!refreshControl)
        refreshControl = SPKDMFindIGRefreshControlInWindows();
    if (refreshControl) {
        // Instagram runs -pullToRefreshDidFetchInbox first and lets it drive -finishLoading, so the
        // same order is used here. The state is sampled before that, or it only ever reads back as
        // the torn-down value.
        long long state = SPKDMRefreshStateOf(refreshControl);
        BOOL notified = SPKDMNotifyInboxRefreshEnded(self);
        SPKLog(@"DMRefresh", @"cancelling refresh on %@ (state %lld, inbox notified %@)", refreshControl,
               state, notified ? @"yes" : @"no");
        SPKDMFinishLoadingOnControl(refreshControl, self);
        return;
    }

    // No control to drive, but the inbox itself may still own the teardown.
    if (SPKDMNotifyInboxRefreshEnded(self)) {
        SPKLog(@"DMRefresh", @"cancelled refresh through the inbox completion on %@", NSStringFromClass([self class]));
        return;
    }

    SPKWarnLog(@"DMRefresh", @"no IGRefreshControl found to cancel from %@", NSStringFromClass([self class]));

    // Fallback: try UIRefreshControl in view hierarchy (older IG versions)
    UIRefreshControl *uiRefreshControl = nil;
    if ([arg isKindOfClass:UIRefreshControl.class]) {
        uiRefreshControl = (UIRefreshControl *)arg;
    } else if ([self isKindOfClass:UIViewController.class]) {
        UIView *view = ((UIViewController *)self).view;
        if ([view respondsToSelector:@selector(refreshControl)]) {
            id rc = ((UIRefreshControl * (*)(id, SEL)) objc_msgSend)(view, @selector(refreshControl));
            if ([rc isKindOfClass:UIRefreshControl.class])
                uiRefreshControl = rc;
        }
    }
    if (!uiRefreshControl)
        return;

    if ([uiRefreshControl respondsToSelector:@selector(endRefreshing)])
        [uiRefreshControl endRefreshing];

    SEL didEnd = NSSelectorFromString(@"refreshControlDidEndFinishLoadingAnimation:");
    if ([self respondsToSelector:didEnd]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, didEnd, uiRefreshControl);
    }
}

static void SPKConfirmDMRefresh(id self, id arg, void (^confirmBlock)(void)) {
    if (sSPKDMRefreshBypassing || ![SPKUtils getBoolPref:@"msgs_confirm_refresh"]) {
        if (confirmBlock)
            confirmBlock();
        return;
    }
    if (sSPKDMRefreshAlertVisible)
        return;

    SPKLog(@"DMRefresh", @"intercepted pull-to-refresh on %@", NSStringFromClass([self class]));

    sSPKDMRefreshAlertVisible = YES;
    [SPKUtils
        showConfirmation:^{
            sSPKDMRefreshAlertVisible = NO;
            sSPKDMRefreshBypassing = YES;
            if (confirmBlock)
                confirmBlock();
            sSPKDMRefreshBypassing = NO;
        }
        cancelHandler:^{
            sSPKDMRefreshAlertVisible = NO;
            SPKDMEndRefreshIfNeeded(self, arg);
        }
        title:SPKL(@"MESSAGES_DELETED_MESSAGES_CONFIRM_INBOX_REFRESH_TITLE")
        message:SPKL(@"MESSAGES_DMREFRESH_CONFIRM_REFRESHING_INBOX_RELOADS_DIRECT_MESSAGES_SERVER_ANY_UNSENT_MESSAGES_MESSAGE")];
}

static void replaced_inboxRefreshControlArg(id self, SEL _cmd, id arg) {
    SPKConfirmDMRefresh(self, arg, ^{
        if (orig_inboxRefreshControlArg)
            orig_inboxRefreshControlArg(self, _cmd, arg);
    });
}

static void replaced_inboxRefreshNoArg(id self, SEL _cmd) {
    SPKRefreshNoArgIMP orig = SPKDMLookupRefreshNoArgOrig(self, _cmd);
    SPKConfirmDMRefresh(self, nil, ^{
        if (orig)
            orig(self, _cmd);
    });
}

static void replaced_networkingCoordinatorPullToRefreshIfPossible(id self, SEL _cmd) {
    SPKConfirmDMRefresh(self, nil, ^{
        if (orig_networkingCoordinatorPullToRefreshIfPossible)
            orig_networkingCoordinatorPullToRefreshIfPossible(self, _cmd);
    });
}

static BOOL replaced_executePullToRefreshWithParams(id self, SEL _cmd, id params, BOOL rightNow) {
    if (sSPKDMRefreshBypassing || ![SPKUtils getBoolPref:@"msgs_confirm_refresh"]) {
        return orig_executePullToRefreshWithParams ? orig_executePullToRefreshWithParams(self, _cmd, params, rightNow) : NO;
    }

    if (sSPKDMRefreshAlertVisible)
        return NO;

    sSPKDMRefreshAlertVisible = YES;
    [SPKUtils
        showConfirmation:^{
            sSPKDMRefreshAlertVisible = NO;
            sSPKDMRefreshBypassing = YES;
            if (orig_executePullToRefreshWithParams)
                orig_executePullToRefreshWithParams(self, _cmd, params, rightNow);
            sSPKDMRefreshBypassing = NO;
        }
        cancelHandler:^{
            sSPKDMRefreshAlertVisible = NO;
            SPKDMEndRefreshIfNeeded(self, nil);
        }
        title:SPKL(@"MESSAGES_DELETED_MESSAGES_CONFIRM_INBOX_REFRESH_TITLE")
        message:SPKL(@"MESSAGES_DMREFRESH_CONFIRM_REFRESHING_INBOX_RELOADS_DIRECT_MESSAGES_SERVER_ANY_UNSENT_MESSAGES_MESSAGE")];

    return NO;
}

static BOOL replaced_executePullToRefreshFull(id self, SEL _cmd, id params, BOOL rightNow, id handler) {
    SPKExecutePTRIMP orig = SPKDMLookupExecutePTROrig(self);

    if (sSPKDMRefreshBypassing || ![SPKUtils getBoolPref:@"msgs_confirm_refresh"])
        return orig ? orig(self, _cmd, params, rightNow, handler) : NO;

    if (sSPKDMRefreshAlertVisible)
        return NO;

    SPKLog(@"DMRefresh", @"intercepted pull-to-refresh on %@", NSStringFromClass([self class]));

    sSPKDMRefreshAlertVisible = YES;
    [SPKUtils
        showConfirmation:^{
            sSPKDMRefreshAlertVisible = NO;
            sSPKDMRefreshBypassing = YES;
            if (orig)
                orig(self, _cmd, params, rightNow, handler);
            sSPKDMRefreshBypassing = NO;
        }
        cancelHandler:^{
            sSPKDMRefreshAlertVisible = NO;
            SPKDMEndRefreshIfNeeded(self, nil);
        }
        title:SPKL(@"MESSAGES_DELETED_MESSAGES_CONFIRM_INBOX_REFRESH_TITLE")
        message:SPKL(@"MESSAGES_DMREFRESH_CONFIRM_REFRESHING_INBOX_RELOADS_DIRECT_MESSAGES_SERVER_ANY_UNSENT_MESSAGES_MESSAGE")];

    return NO;
}

static BOOL SPKHookExecutePullToRefreshFull(Class cls) {
    SEL selector = NSSelectorFromString(@"executePullToRefreshWithParams:rightNow:mdcoreThreadListRefreshHandler:");
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;
    if (sSPKExecutePTROrigCount >= sizeof(sSPKExecutePTROrigs) / sizeof(sSPKExecutePTROrigs[0]))
        return NO;

    NSUInteger slot = sSPKExecutePTROrigCount;
    sSPKExecutePTROrigs[slot].cls = cls;
    sSPKExecutePTROrigs[slot].orig = NULL;
    MSHookMessageEx(cls, selector, (IMP)replaced_executePullToRefreshFull, (IMP *)&sSPKExecutePTROrigs[slot].orig);
    sSPKExecutePTROrigCount = slot + 1;
    return YES;
}

static BOOL SPKHookDMRefreshArgSelector(Class cls, SEL selector) {
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;
    MSHookMessageEx(cls, selector, (IMP)replaced_inboxRefreshControlArg, (IMP *)&orig_inboxRefreshControlArg);
    return YES;
}

static BOOL SPKHookDMRefreshNoArgSelector(Class cls, SEL selector) {
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;
    if (sSPKRefreshNoArgOrigCount >= sizeof(sSPKRefreshNoArgOrigs) / sizeof(sSPKRefreshNoArgOrigs[0]))
        return NO;

    NSUInteger slot = sSPKRefreshNoArgOrigCount;
    sSPKRefreshNoArgOrigs[slot].cls = cls;
    sSPKRefreshNoArgOrigs[slot].sel = selector;
    sSPKRefreshNoArgOrigs[slot].orig = NULL;
    MSHookMessageEx(cls, selector, (IMP)replaced_inboxRefreshNoArg, (IMP *)&sSPKRefreshNoArgOrigs[slot].orig);
    sSPKRefreshNoArgOrigCount = slot + 1;
    return YES;
}

extern "C" void SPKInstallDMRefreshConfirmHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<Class> *classes = [NSMutableArray array];
        Class objcInbox = SPKDirectObjCInboxClass();
        if (objcInbox)
            [classes addObject:objcInbox];
        // IG 439+ rolls out a Swift rewrite of the inbox VC, the only one left on 452.
        Class swiftInbox = SPKDirectSwiftInboxClass();
        if (swiftInbox)
            [classes addObject:swiftInbox];
        for (NSString *className in @[ @"IGDirectInboxContainerViewController",
                                       @"IGDirectInboxListViewController",
                                       @"IGDirectInboxViewControllerImpl" ]) {
            Class cls = NSClassFromString(className);
            if (cls)
                [classes addObject:cls];
        }
        Class refreshControlClass = NSClassFromString(@"IGRefreshControl");
        NSUInteger hookedRefreshControl = 0;
        if (refreshControlClass) {
            SEL startLoading = NSSelectorFromString(@"startLoadingAnimated:");
            if (class_getInstanceMethod(refreshControlClass, startLoading)) {
                MSHookMessageEx(refreshControlClass, startLoading,
                                (IMP)replaced_refreshControlStartLoading,
                                (IMP *)&orig_refreshControlStartLoading);
                hookedRefreshControl++;
            }
            SEL didEndDragging = NSSelectorFromString(@"scrollViewDidEndDragging");
            if (class_getInstanceMethod(refreshControlClass, didEndDragging)) {
                MSHookMessageEx(refreshControlClass, didEndDragging,
                                (IMP)replaced_refreshControlDidEndDragging,
                                (IMP *)&orig_refreshControlDidEndDragging);
                hookedRefreshControl++;
            }
            SEL didScroll = NSSelectorFromString(@"scrollViewDidScroll");
            if (class_getInstanceMethod(refreshControlClass, didScroll)) {
                MSHookMessageEx(refreshControlClass, didScroll,
                                (IMP)replaced_refreshControlDidScroll,
                                (IMP *)&orig_refreshControlDidScroll);
                hookedRefreshControl++;
            }
        }

        NSUInteger hookedNoArg = 0;
        BOOL hookedArg = NO;
        for (Class cls in classes) {
            // Hook every inbox VC that is present: a build can ship both the legacy ObjC one and
            // the Swift rewrite, and only one of them is actually instantiated at runtime.
            if (SPKHookDMRefreshNoArgSelector(cls, NSSelectorFromString(@"pullToRefreshIfPossible")) ||
                SPKHookDMRefreshNoArgSelector(cls, NSSelectorFromString(@"_pullToRefreshIfPossible"))) {
                hookedNoArg++;
            }
            if (!hookedArg) {
                hookedArg = SPKHookDMRefreshArgSelector(cls, NSSelectorFromString(@"refreshControlDidRefresh:")) ||
                            SPKHookDMRefreshArgSelector(cls, NSSelectorFromString(@"refreshControlValueChanged:")) ||
                            SPKHookDMRefreshArgSelector(cls, NSSelectorFromString(@"_didPullToRefresh:"));
            }
        }

        Class networkingCoordinatorClass = NSClassFromString(@"_TtC23IGDirectInboxNetworking34IGDirectInboxNetworkingCoordinator");
        BOOL hookedNetworking = NO;
        if (networkingCoordinatorClass && class_getInstanceMethod(networkingCoordinatorClass, NSSelectorFromString(@"pullToRefreshIfPossible"))) {
            MSHookMessageEx(networkingCoordinatorClass,
                            NSSelectorFromString(@"pullToRefreshIfPossible"),
                            (IMP)replaced_networkingCoordinatorPullToRefreshIfPossible,
                            (IMP *)&orig_networkingCoordinatorPullToRefreshIfPossible);
            hookedNetworking = YES;
        }

        // The coordinators are the last common choke point before the fetch goes out, and they
        // are reached through an @objc protocol, so this catches the Swift inbox path too.
        NSUInteger hookedCoordinators = 0;
        for (NSString *className in @[ @"IGDirectMDCoreCompositePullToRefreshCoordinator",
                                       @"IGDirectInboxDjangoPullToRefreshCoordinator" ]) {
            if (SPKHookExecutePullToRefreshFull(NSClassFromString(className)))
                hookedCoordinators++;
        }

        // Pre-437 builds carry the two-argument variant instead.
        Class djangoCoordinatorClass = NSClassFromString(@"IGDirectInboxDjangoPullToRefreshCoordinator");
        if (hookedCoordinators == 0 && djangoCoordinatorClass &&
            class_getInstanceMethod(djangoCoordinatorClass, NSSelectorFromString(@"executePullToRefreshWithParams:rightNow:"))) {
            MSHookMessageEx(djangoCoordinatorClass,
                            NSSelectorFromString(@"executePullToRefreshWithParams:rightNow:"),
                            (IMP)replaced_executePullToRefreshWithParams,
                            (IMP *)&orig_executePullToRefreshWithParams);
            hookedCoordinators++;
        }

        SPKLog(@"DMRefresh",
               @"installed hooks: %lu inbox VCs, arg selector %@, networking coordinator %@, %lu PTR coordinators, %lu refresh control trackers",
               (unsigned long)hookedNoArg, hookedArg ? @"yes" : @"no", hookedNetworking ? @"yes" : @"no",
               (unsigned long)hookedCoordinators, (unsigned long)hookedRefreshControl);
    });
}
