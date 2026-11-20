// Confirm Feed Refresh: asks before the home feed reloads from a pull, a Home
// tab re-tap, or a status bar tap.
//
// The pull is gated where the refresh control sends ValueChanged as it starts
// loading, before any of its targets hear about it. The controller's own refresh
// entry points are Swift on newer builds and may be called directly, so they are
// only a second line: they wait for an answer already being asked for, pass
// through while a confirmed refresh runs, and gate on their own when they are
// the first to arrive. One pull therefore asks exactly once. The Pull to Tune
// feed (logo spinner) is the exception: it is gated at -pullToTuneExecuteRefresh,
// see the Pull to Tune section.
//
// A status bar tap never touches the refresh control: the feed refreshes from
// inside the system scroll-to-top, which first asks the feed's scroll delegate
// -scrollViewShouldScrollToTop:. The system scroll is declined; Sparkle scrolls
// up itself and starts the control loading, which turns the tap into a pull
// that is already waiting for its answer. A Home tab re-tap on the feed takes
// the same path, through the tab bar hook in DisableBackgroundRefresh.x.

#import "../../InstagramHeaders.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// A refresh confirmed from a re-tap may start the control's loading animation a
// moment later, which sends ValueChanged again. That send is part of the
// refresh the user already accepted.
static CFTimeInterval const kSPKFeedConfirmedRefreshGrace = 2.0;

static BOOL sSPKFeedRunningConfirmedRefresh = NO;
static CFTimeInterval sSPKFeedConfirmedRefreshUntil = 0;
static BOOL sSPKFeedRefreshPromptPending = NO;
static NSMutableArray<dispatch_block_t> *sSPKFeedDeferredRefreshCalls = nil;
// Set when the control's own ValueChanged was held back by a pending prompt.
static BOOL sSPKFeedValueChangedDeferred = NO;
// The control whose spinner stays up while the prompt is pending. The feed ends
// a loading state it did not start (a tap's spinner has no fetch behind it), so
// -finishLoading on this control is ignored until the prompt is answered.
static __weak IGRefreshControl *sSPKFeedHeldControl = nil;

static BOOL SPKFeedShouldConfirmRefresh(void) {
    return [SPKUtils getBoolPref:@"feed_confirm_refresh"];
}

static BOOL SPKFeedIsMainFeedController(id object) {
    if (!object)
        return NO;
    // Covers 410's IGMainFeedViewController and the 445+ ObjC/Swift twins
    // (IGMainFeedViewController_objc, IGMainFeedSwift.IGMainFeedViewController_swift).
    return [NSStringFromClass([object class]) containsString:@"MainFeedViewController"];
}

static BOOL SPKFeedPassesThrough(void) {
    return sSPKFeedRunningConfirmedRefresh || CACurrentMediaTime() < sSPKFeedConfirmedRefreshUntil;
}

static void SPKFeedRunConfirmed(dispatch_block_t orig) {
    sSPKFeedRunningConfirmedRefresh = YES;
    sSPKFeedConfirmedRefreshUntil = CACurrentMediaTime() + kSPKFeedConfirmedRefreshGrace;
    if (orig)
        orig();
    NSArray<dispatch_block_t> *deferred = [sSPKFeedDeferredRefreshCalls copy];
    [sSPKFeedDeferredRefreshCalls removeAllObjects];
    for (dispatch_block_t call in deferred)
        call();
    sSPKFeedRunningConfirmedRefresh = NO;
}

// Returns YES when the call was consumed: it runs once the prompt is answered,
// or never if it is cancelled.
static BOOL SPKFeedDeferIfPromptPending(dispatch_block_t orig) {
    if (SPKFeedPassesThrough() || !sSPKFeedRefreshPromptPending)
        return NO;
    if (!sSPKFeedDeferredRefreshCalls)
        sSPKFeedDeferredRefreshCalls = [NSMutableArray array];
    [sSPKFeedDeferredRefreshCalls addObject:[orig copy]];
    return YES;
}

static void SPKFeedPresentPrompt(dispatch_block_t orig, dispatch_block_t cancel) {
    sSPKFeedRefreshPromptPending = YES;
    sSPKFeedValueChangedDeferred = NO;
    [SPKUtils
        showConfirmation:^(void) {
            sSPKFeedRefreshPromptPending = NO;
            sSPKFeedHeldControl = nil;
            SPKFeedRunConfirmed(orig);
        }
        cancelHandler:^(void) {
            sSPKFeedRefreshPromptPending = NO;
            sSPKFeedHeldControl = nil;
            [sSPKFeedDeferredRefreshCalls removeAllObjects];
            if (cancel)
                cancel();
        }
        title:SPKL(@"FEED_REFRESH_CONFIRM_PROMPT_TITLE")
        message:SPKL(@"FEED_REFRESH_CONFIRM_PROMPT_MESSAGE")];
}

static IGRefreshControl *SPKFeedRefreshControlForController(id controller) {
    id control = nil;
    if ([controller respondsToSelector:@selector(refreshControl)])
        control = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(refreshControl));
    if (!control)
        control = [SPKUtils getIvarForObj:controller name:"_refreshControl"];
    return [control isKindOfClass:objc_getClass("IGRefreshControl")] ? control : nil;
}

// The controller never heard of a cancelled pull, so ending the control's own
// loading state is enough to collapse the spinner and restore the inset.
static void SPKFeedFinishCancelledPull(IGRefreshControl *control) {
    if ([control respondsToSelector:@selector(finishLoading)])
        [control finishLoading];
}

// MARK: - Pull to Tune

// Some accounts get a home feed where a pull past the trigger point can open the
// feed tuning screen instead of refreshing (an Instagram logo replaces the
// spinner). There the control's ValueChanged and the controller's PTR entry
// point only mark a refresh as pending; the coordinator decides on release and
// then asks the controller to -pullToTuneExecuteRefresh, which is what fetches.
// Holding the earlier steps desynchronises the coordinator (the release arrives
// after it has already seen the drag end, so it never executes the refresh and
// the spinner is left in a half state), so on that feed the gate sits on the
// execute call alone.
static BOOL sSPKFeedPullToTuneGateInstalled = NO;

static BOOL SPKFeedUsesPullToTune(id controller) {
    if (!sSPKFeedPullToTuneGateInstalled || ![controller respondsToSelector:@selector(pullToTuneExecuteRefresh)] ||
        ![controller respondsToSelector:@selector(pullToTuneIsEnabled)])
        return NO;
    return [(IGMainFeedViewController_objc *)controller pullToTuneIsEnabled];
}

static void SPKFeedHandlePullRefresh(id controller, IGRefreshControl *control, dispatch_block_t orig) {
    if (!SPKFeedShouldConfirmRefresh() || SPKFeedPassesThrough()) {
        orig();
        return;
    }
    if (SPKFeedDeferIfPromptPending(orig))
        return;
    // Only marks the refresh pending on the Pull to Tune feed; the execute call
    // asks instead.
    if (SPKFeedUsesPullToTune(controller)) {
        orig();
        return;
    }

    IGRefreshControl *refreshControl = control ?: SPKFeedRefreshControlForController(controller);
    SPKLog(@"Feed", @"Asking before feed refresh (%@)", NSStringFromClass([controller class]));
    SPKFeedPresentPrompt(orig, ^{
        SPKFeedFinishCancelledPull(refreshControl);
    });
    sSPKFeedHeldControl = refreshControl;
}

// MARK: - Pull gate

static IMP sSPKFeedOrigRefreshControlSendActions = NULL;

static id SPKFeedControllerForRefreshControl(UIControl *control) {
    id delegate = [control respondsToSelector:@selector(delegate)] ? ((id (*)(id, SEL))objc_msgSend)(control, @selector(delegate)) : nil;
    if (SPKFeedIsMainFeedController(delegate))
        return delegate;
    for (id target in control.allTargets) {
        if (SPKFeedIsMainFeedController(target))
            return target;
    }
    return nil;
}

static void SPKFeedRefreshControlSendActions(UIControl *self, SEL _cmd, UIControlEvents events) {
    void (^orig)(void) = ^{
        ((void (*)(id, SEL, UIControlEvents))sSPKFeedOrigRefreshControlSendActions)(self, _cmd, events);
    };
    if (!(events & UIControlEventValueChanged) || !SPKFeedShouldConfirmRefresh()) {
        orig();
        return;
    }
    id controller = SPKFeedControllerForRefreshControl(self);
    if (!controller) {
        orig();
        return;
    }
    if (sSPKFeedRefreshPromptPending && !SPKFeedPassesThrough())
        sSPKFeedValueChangedDeferred = YES;
    SPKFeedHandlePullRefresh(controller, (IGRefreshControl *)self, orig);
}

// UIControl owns -sendActionsForControlEvents:, so the override is added to
// IGRefreshControl alone. Another Sparkle gate may already have added one; that
// implementation then becomes this gate's original, so both run in turn.
static void SPKFeedInstallRefreshControlGate(void) {
    Class cls = objc_getClass("IGRefreshControl");
    SEL sel = @selector(sendActionsForControlEvents:);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method)
        return;
    IMP inherited = method_getImplementation(method);
    if (class_addMethod(cls, sel, (IMP)SPKFeedRefreshControlSendActions, method_getTypeEncoding(method)))
        sSPKFeedOrigRefreshControlSendActions = inherited;
    else
        sSPKFeedOrigRefreshControlSendActions = method_setImplementation(method, (IMP)SPKFeedRefreshControlSendActions);
}

static void (*orig_SPKFeedFinishLoading)(id, SEL);
static void SPKFeedFinishLoading(IGRefreshControl *self, SEL _cmd) {
    if (sSPKFeedRefreshPromptPending && self == sSPKFeedHeldControl) {
        SPKLog(@"Feed", @"Keeping the refresh spinner up while the prompt is pending");
        return;
    }
    orig_SPKFeedFinishLoading(self, _cmd);
}

// MARK: - Controller entry points

static BOOL SPKFeedClassOwnsMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count && !found; i++)
        found = method_getName(methods[i]) == sel;
    free(methods);
    return found;
}

// Pull-to-refresh entry point: -_refreshWhenPTR (410, ObjC twin) or
// -refreshWhenPTR (Swift twin).
static void SPKFeedHookPullEntryPoint(Class cls, SEL sel) {
    if (!cls || !SPKFeedClassOwnsMethod(cls, sel))
        return;
    __block IMP orig = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self) {
        SPKFeedHandlePullRefresh(self, nil, ^{
            ((void (*)(id, SEL))orig)(self, sel);
        });
    });
    MSHookMessageEx(cls, sel, replacement, &orig);
}

static IGRefreshControl *SPKFeedPullToTuneRefreshControl(id controller) {
    id control = nil;
    if ([controller respondsToSelector:@selector(pullToTuneRefreshControl)])
        control = [(IGMainFeedViewController_objc *)controller pullToTuneRefreshControl];
    if (![control isKindOfClass:objc_getClass("IGRefreshControl")])
        control = SPKFeedRefreshControlForController(controller);
    return control;
}

// Ending the control's loading state runs IG's own teardown (the logo shrinks
// and the coordinator hears -refreshDidFinish through the control's delegate).
// If the coordinator still believes a refresh is in flight once the control is
// idle again, it is told directly so the next pull is not swallowed.
static void SPKFeedFinishCancelledPullToTune(id controller, IGRefreshControl *control) {
    SPKFeedFinishCancelledPull(control);
    __weak id weakController = controller;
    __weak IGRefreshControl *weakControl = control;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongController = weakController;
        IGRefreshControl *strongControl = weakControl;
        if (!strongController || sSPKFeedRefreshPromptPending)
            return;
        if (strongControl && [strongControl respondsToSelector:@selector(refreshState)] && strongControl.refreshState != 0)
            return;
        id coordinator = [strongController respondsToSelector:@selector(pullToTuneCoordinator)]
                             ? [(IGMainFeedViewController_objc *)strongController pullToTuneCoordinator]
                             : nil;
        SEL inFlightSel = NSSelectorFromString(@"isRefreshInFlight");
        SEL finishSel = NSSelectorFromString(@"refreshDidFinish");
        if (![coordinator respondsToSelector:inFlightSel] || ![coordinator respondsToSelector:finishSel])
            return;
        if (((BOOL (*)(id, SEL))objc_msgSend)(coordinator, inFlightSel)) {
            SPKLog(@"Feed", @"Pull to Tune still in flight after cancel, finishing it");
            ((void (*)(id, SEL))objc_msgSend)(coordinator, finishSel);
        }
    });
}

static void SPKFeedHookPullToTuneExecute(Class cls) {
    SEL sel = @selector(pullToTuneExecuteRefresh);
    if (!cls || !SPKFeedClassOwnsMethod(cls, sel))
        return;
    __block IMP orig = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self) {
        dispatch_block_t call = ^{
            ((void (*)(id, SEL))orig)(self, sel);
        };
        if (!SPKFeedShouldConfirmRefresh() || SPKFeedPassesThrough()) {
            call();
            return;
        }
        if (SPKFeedDeferIfPromptPending(call))
            return;

        IGRefreshControl *control = SPKFeedPullToTuneRefreshControl(self);
        SPKLog(@"Feed", @"Asking before Pull to Tune feed refresh (%@)", NSStringFromClass([self class]));
        __weak id weakSelf = self;
        SPKFeedPresentPrompt(call, ^{
            SPKFeedFinishCancelledPullToTune(weakSelf, control);
        });
        sSPKFeedHeldControl = control;
    });
    MSHookMessageEx(cls, sel, replacement, &orig);
    sSPKFeedPullToTuneGateInstalled = YES;
}

// The release callback can start the refresh on older builds, so it waits for
// a pending prompt instead of racing it.
static void SPKFeedHookReleaseCallback(Class cls) {
    SEL sel = @selector(refreshControl:didReleaseWithRefreshControlState:);
    if (!cls || !SPKFeedClassOwnsMethod(cls, sel))
        return;
    __block IMP orig = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self, id control, long long state) {
        dispatch_block_t call = ^{
            ((void (*)(id, SEL, id, long long))orig)(self, sel, control, state);
        };
        if (SPKFeedDeferIfPromptPending(call))
            return;
        call();
    });
    MSHookMessageEx(cls, sel, replacement, &orig);
}

// MARK: - Status bar tap and Home tab re-tap

static BOOL SPKFeedScrollViewIsAtTop(UIScrollView *scrollView) {
    return scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1.0;
}

static void SPKFeedScrollToTopWithoutRefresh(UIScrollView *scrollView) {
    CGPoint topOffset = CGPointMake(scrollView.contentOffset.x, -scrollView.adjustedContentInset.top);
    if (!CGPointEqualToPoint(scrollView.contentOffset, topOffset))
        [scrollView setContentOffset:topOffset animated:YES];
}

// The feed's control is normally a subview of its scroll view; when it is hosted
// elsewhere, the feed controller up the responder chain still owns it.
static IGRefreshControl *SPKFeedRefreshControlForScrollView(UIScrollView *scrollView) {
    Class controlClass = objc_getClass("IGRefreshControl");
    if (!controlClass)
        return nil;
    for (UIView *subview in scrollView.subviews) {
        if ([subview isKindOfClass:controlClass])
            return (IGRefreshControl *)subview;
    }
    for (UIResponder *responder = scrollView.nextResponder; responder; responder = responder.nextResponder) {
        if (SPKFeedIsMainFeedController(responder))
            return SPKFeedRefreshControlForController(responder);
    }
    return nil;
}

// Bumped by every tap prompt so a late spinner start belonging to an answered
// prompt does nothing. Only one prompt is ever up, so one started flag is enough.
static NSUInteger sSPKFeedTapPromptToken = 0;
static BOOL sSPKFeedTapSpinnerStarted = NO;

// Starting the spinner mid-scroll lets the scroll events tear it down again, so
// it waits for the feed to arrive at the top (or gives up waiting after a while
// and starts anyway).
static void SPKFeedStartSpinnerWhenAtTop(UIScrollView *scrollView, IGRefreshControl *control, NSUInteger token, NSInteger attemptsLeft) {
    if (token != sSPKFeedTapPromptToken || !sSPKFeedRefreshPromptPending || !scrollView || !control)
        return;
    BOOL settled = SPKFeedScrollViewIsAtTop(scrollView) && !scrollView.isDecelerating;
    if (!settled && attemptsLeft > 0) {
        __weak UIScrollView *weakScrollView = scrollView;
        __weak IGRefreshControl *weakControl = control;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKFeedStartSpinnerWhenAtTop(weakScrollView, weakControl, token, attemptsLeft - 1);
        });
        return;
    }
    if (![control respondsToSelector:@selector(startLoadingAnimated:)])
        return;
    sSPKFeedTapSpinnerStarted = YES;
    sSPKFeedHeldControl = control;
    [control startLoadingAnimated:YES];
}

// The tap scrolls up straight away and the control starts loading as for a
// pull, but the prompt is already pending, so everything the control sets off
// (ValueChanged, the release callback, the controller's refresh entry point)
// waits for the answer. Confirming lets those run, or sends ValueChanged itself
// when starting the spinner sent nothing. Cancelling ends the spinner.
// On the Pull to Tune feed a tap refresh is run by the feed's own tap handling
// (the Home tab press or the status bar scroll-to-top): it starts the control
// loading and drives the coordinator itself, with no ValueChanged in between,
// and -pullToTuneDidStartRefresh only reports a fetch already sent. Starting the
// control alone shows the logo but never fetches. So IG's tap runs untouched
// (it scrolls up and the logo animates, as for a pull), and the prompt sits on
// the feed view model's head-load fetch, which then waits for the answer while
// the logo keeps going. Only a fetch armed by a tap Sparkle saw is asked about,
// since IG fetches the feed on its own for other reasons (launch, hot start).
static CFTimeInterval const kSPKFeedPullToTuneTapArmWindow = 1.5;
static CFTimeInterval sSPKFeedPullToTuneTapArmedUntil = 0;
static __weak id sSPKFeedPullToTuneTapController = nil;
static __weak IGRefreshControl *sSPKFeedPullToTuneTapControl = nil;
// A status bar tap hands the scroll to the system's scroll-to-top, which can run
// for a while from far down; IG starts the logo straight away there instead of
// waiting for the top, so Sparkle does too.
static BOOL sSPKFeedPullToTuneTapWaitsForTop = YES;

static void SPKFeedArmPullToTuneTap(IGRefreshControl *control, BOOL waitForTop) {
    sSPKFeedPullToTuneTapArmedUntil = CACurrentMediaTime() + kSPKFeedPullToTuneTapArmWindow;
    sSPKFeedPullToTuneTapWaitsForTop = waitForTop;
    sSPKFeedPullToTuneTapControl = control;
    sSPKFeedPullToTuneTapController = SPKFeedControllerForRefreshControl(control);
}

static void SPKFeedSendCoordinator(id controller, NSString *selectorName) {
    id coordinator = [controller respondsToSelector:@selector(pullToTuneCoordinator)]
                         ? [(IGMainFeedViewController_objc *)controller pullToTuneCoordinator]
                         : nil;
    SEL sel = NSSelectorFromString(selectorName);
    if ([coordinator respondsToSelector:sel])
        ((void (*)(id, SEL))objc_msgSend)(coordinator, sel);
}

// IG's tap shows the logo only after the fetch call returns as started
// (-startLoadingAnimated:, then the coordinator's refresh chrome), and it reads
// that from the fetch actually running, so a held fetch leaves the feed without
// a logo. Sparkle starts both itself once the feed is at the top, while the
// prompt is still pending.
static void SPKFeedStartPullToTuneTapLogo(id controller, IGRefreshControl *control, NSUInteger token, NSInteger attemptsLeft) {
    if (token != sSPKFeedTapPromptToken || !sSPKFeedRefreshPromptPending || !control || sSPKFeedTapSpinnerStarted)
        return;
    id scrollView = [SPKUtils getIvarForObj:control name:"_scrollView"];
    BOOL settled = ![scrollView isKindOfClass:[UIScrollView class]] ||
                   (SPKFeedScrollViewIsAtTop(scrollView) && ![(UIScrollView *)scrollView isDecelerating]);
    if (!settled && attemptsLeft > 0) {
        __weak id weakController = controller;
        __weak IGRefreshControl *weakControl = control;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKFeedStartPullToTuneTapLogo(weakController, weakControl, token, attemptsLeft - 1);
        });
        return;
    }
    if (control.refreshState != 0 || ![control respondsToSelector:@selector(startLoadingAnimated:)])
        return;
    sSPKFeedTapSpinnerStarted = YES;
    [control startLoadingAnimated:YES];
    SPKFeedSendCoordinator(controller, @"startRefreshChrome");
}

typedef BOOL (*SPKFeedViewModelFetchIMP)(id, SEL, long long, id, id, id, BOOL, id, id);

static void SPKFeedHookViewModelFetch(void) {
    Class cls = objc_getClass("IGMainFeedViewModel");
    SEL sel = NSSelectorFromString(@"fetchDataWithMainFeedFetchReason:hoistedMediaID:hoistedMediaShortcode:"
                                   @"deeplinkURL:isAppStartNonFeedSurface:requestCancellationBlock:cachedMediaIDs:");
    if (!cls || !SPKFeedClassOwnsMethod(cls, sel))
        return;
    __block IMP orig = NULL;
    IMP replacement = imp_implementationWithBlock(^BOOL(id self, long long reason, id mediaID, id shortcode, id url,
                                                        BOOL appStartNonFeed, id cancellationBlock, id cachedIDs) {
        dispatch_block_t call = ^{
            ((SPKFeedViewModelFetchIMP)orig)(self, sel, reason, mediaID, shortcode, url, appStartNonFeed, cancellationBlock, cachedIDs);
        };
        BOOL armed = CACurrentMediaTime() < sSPKFeedPullToTuneTapArmedUntil;
        if (!armed || !SPKFeedShouldConfirmRefresh() || SPKFeedPassesThrough())
            return ((SPKFeedViewModelFetchIMP)orig)(self, sel, reason, mediaID, shortcode, url, appStartNonFeed, cancellationBlock, cachedIDs);
        sSPKFeedPullToTuneTapArmedUntil = 0;
        // A YES keeps the caller treating the refresh as started; the fetch
        // itself runs once the answer is Confirm.
        if (SPKFeedDeferIfPromptPending(call))
            return YES;

        id controller = sSPKFeedPullToTuneTapController;
        IGRefreshControl *control = sSPKFeedPullToTuneTapControl;
        SPKLog(@"Feed", @"Asking before Pull to Tune tap refresh (reason %lld)", reason);
        __weak id weakController = controller;
        __weak IGRefreshControl *weakControl = control;
        NSUInteger token = ++sSPKFeedTapPromptToken;
        NSInteger attempts = sSPKFeedPullToTuneTapWaitsForTop ? 40 : 0;
        sSPKFeedTapSpinnerStarted = NO;
        SPKFeedPresentPrompt(^{
            // Confirmed before the logo got going: show it now, as IG would have.
            id strongController = weakController;
            IGRefreshControl *strongControl = weakControl;
            if (!sSPKFeedTapSpinnerStarted && strongControl && strongControl.refreshState == 0) {
                sSPKFeedTapSpinnerStarted = YES;
                [strongControl startLoadingAnimated:YES];
                SPKFeedSendCoordinator(strongController, @"startRefreshChrome");
            }
            call();
            if ([strongController respondsToSelector:@selector(pullToTuneDidStartRefresh)])
                ((void (*)(id, SEL))objc_msgSend)(strongController, @selector(pullToTuneDidStartRefresh));
        }, ^{
            if (sSPKFeedTapSpinnerStarted)
                SPKFeedFinishCancelledPullToTune(weakController, weakControl);
        });
        sSPKFeedHeldControl = control;
        // After IG's tap handler returns, so its own scroll to the top has begun.
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKFeedStartPullToTuneTapLogo(weakController, weakControl, token, attempts);
        });
        return YES;
    });
    MSHookMessageEx(cls, sel, replacement, &orig);
}

static void SPKFeedConfirmTapRefresh(UIScrollView *scrollView, IGRefreshControl *control) {
    NSUInteger token = ++sSPKFeedTapPromptToken;
    __weak IGRefreshControl *weakControl = control;
    sSPKFeedTapSpinnerStarted = NO;
    SPKFeedPresentPrompt(^{
        IGRefreshControl *strongControl = weakControl;
        if (strongControl && !sSPKFeedValueChangedDeferred)
            [strongControl sendActionsForControlEvents:UIControlEventValueChanged];
    }, ^{
        if (sSPKFeedTapSpinnerStarted)
            SPKFeedFinishCancelledPull(weakControl);
    });

    SPKFeedScrollToTopWithoutRefresh(scrollView);
    SPKFeedStartSpinnerWhenAtTop(scrollView, control, token, 40);
}

// The Home tab's top screen is not always the feed controller itself (newer
// builds wrap it in a container), so the feed's scroll view is found by walking
// the tab's views for the scroll view that hosts the feed's refresh control,
// the same lookup a status bar tap uses.
static UIScrollView *SPKFeedScrollViewWithRefreshControl(UIViewController *root, IGRefreshControl **controlOut) {
    IGRefreshControl *direct = SPKFeedRefreshControlForController(root);
    id directScrollView = direct ? [SPKUtils getIvarForObj:direct name:"_scrollView"] : nil;
    if ([directScrollView isKindOfClass:[UIScrollView class]]) {
        *controlOut = direct;
        return directScrollView;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    if (root.isViewLoaded && root.view)
        [queue addObject:root.view];
    NSInteger scanned = 0;
    while (queue.count > 0 && scanned < 300) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        scanned++;
        if ([current isKindOfClass:[UICollectionView class]]) {
            IGRefreshControl *control = SPKFeedRefreshControlForScrollView((UIScrollView *)current);
            id controlScrollView = control ? [SPKUtils getIvarForObj:control name:"_scrollView"] : nil;
            if (control && (!controlScrollView || controlScrollView == current)) {
                *controlOut = control;
                return (UIScrollView *)current;
            }
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return nil;
}

// Called by the IGTabBarController -_timelineButtonPressed hook when the Home tab
// is re-tapped on the feed with Confirm Feed Refresh on. Returns NO when there is
// no refresh control to drive; the caller then only scrolls to the top.
// `replay` runs IG's own re-tap handling; it is used on the Pull to Tune feed.
BOOL SPKFeedConfirmHomeTabRefresh(UIViewController *feedController, dispatch_block_t replay) {
    if (sSPKFeedRefreshPromptPending)
        return YES;
    IGRefreshControl *control = nil;
    UIScrollView *scrollView = SPKFeedScrollViewWithRefreshControl(feedController, &control);
    if (!scrollView || !control) {
        SPKLog(@"Feed", @"No refresh control for Home tab re-tap (%@)", NSStringFromClass([feedController class]));
        return NO;
    }
    SPKLog(@"Feed", @"Asking before Home tab feed refresh (%@, %@)", NSStringFromClass([feedController class]), NSStringFromClass([scrollView class]));
    if (replay && SPKFeedUsesPullToTune(SPKFeedControllerForRefreshControl(control))) {
        SPKFeedArmPullToTuneTap(control, YES);
        replay();
    } else {
        SPKFeedConfirmTapRefresh(scrollView, control);
    }
    return YES;
}

static void SPKFeedHookStatusBarScrollToTop(Class cls) {
    SEL sel = @selector(scrollViewShouldScrollToTop:);
    if (!cls || !SPKFeedClassOwnsMethod(cls, sel))
        return;
    __block IMP orig = NULL;
    IMP replacement = imp_implementationWithBlock(^BOOL(id self, UIScrollView *scrollView) {
        // Disable Home Tab Refresh has its own answer: scroll without refreshing.
        if (!SPKFeedShouldConfirmRefresh() || [SPKUtils getBoolPref:@"feed_disable_home_refresh"] ||
            SPKFeedPassesThrough() || ![scrollView isKindOfClass:[UIScrollView class]])
            return ((BOOL (*)(id, SEL, UIScrollView *))orig)(self, sel, scrollView);
        if (sSPKFeedRefreshPromptPending)
            return NO;

        IGRefreshControl *control = SPKFeedRefreshControlForScrollView(scrollView);
        if (!control) {
            // No control to drive: scroll up and leave the feed as it is.
            SPKLog(@"Feed", @"No refresh control for status bar tap (%@), scrolling without refresh", NSStringFromClass([self class]));
            SPKFeedScrollToTopWithoutRefresh(scrollView);
            return NO;
        }

        if (SPKFeedUsesPullToTune(SPKFeedControllerForRefreshControl(control))) {
            // IG's own tap runs; the prompt comes from -pullToTuneDidStartRefresh.
            SPKFeedArmPullToTuneTap(control, NO);
            return ((BOOL (*)(id, SEL, UIScrollView *))orig)(self, sel, scrollView);
        }
        SPKLog(@"Feed", @"Asking before status bar feed refresh (%@)", NSStringFromClass([self class]));
        SPKFeedConfirmTapRefresh(scrollView, control);
        return NO;
    });
    MSHookMessageEx(cls, sel, replacement, &orig);
}

// Installed regardless of the pref so the toggle applies live: every hook
// re-checks it at call time and is a pass-through when it is off.
void SPKInstallFeedRefreshConfirmHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKFeedInstallRefreshControlGate();
        SPKFeedHookViewModelFetch();
        Class controlClass = objc_getClass("IGRefreshControl");
        if (controlClass && class_getInstanceMethod(controlClass, @selector(finishLoading)))
            MSHookMessageEx(controlClass, @selector(finishLoading), (IMP)SPKFeedFinishLoading, (IMP *)&orig_SPKFeedFinishLoading);

        NSArray<NSString *> *classNames = @[
            @"IGMainFeedViewController",
            @"IGMainFeedViewController_objc",
            @"_TtC15IGMainFeedSwift30IGMainFeedViewController_swift",
        ];
        for (NSString *name in classNames) {
            Class cls = objc_getClass(name.UTF8String);
            if (!cls)
                continue;
            SPKFeedHookPullEntryPoint(cls, NSSelectorFromString(@"_refreshWhenPTR"));
            SPKFeedHookPullEntryPoint(cls, NSSelectorFromString(@"refreshWhenPTR"));
            SPKFeedHookReleaseCallback(cls);
            SPKFeedHookPullToTuneExecute(cls);
        }

        // The feed scroll view's delegate (410 and later) and the Swift scroll
        // orchestrator some home feed builds route the same callback through.
        SPKFeedHookStatusBarScrollToTop(objc_getClass("IGMainFeedScrollViewDelegateDistributor"));
        SPKFeedHookStatusBarScrollToTop(objc_getClass("_TtC35IGHomeSundialFeedScrollOrchestrator35IGHomeSundialFeedScrollOrchestrator"));
    });
}
