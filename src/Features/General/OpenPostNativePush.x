// Opening a saved post from the Gallery without losing your place.
//
// Instagram's router builds the single-post page itself: handing it
// instagram://media?id=<mediaPK>_<userPK> makes it push an IGSingleFeedViewController
// onto the feed tab's IGNavigationController, roughly 70-90ms later. That is the
// right page, but it lands on a stack behind the Gallery, so the old behaviour had
// to dismiss the Gallery to reveal it -- and dismissing is what loses your place.
//
// So we let the router do all the construction (nothing here knows how to build a
// feed page, and IG keeps that working across versions), then intercept the push
// and redirect the finished view controller onto the same invisible host stack the
// profile push uses. The result is a page that arrives with IG's own transition and
// pops back to the Gallery exactly where you left it.
//
// The interception window is armed immediately before the router is invoked and
// disarmed on the first capture, so the push hook is inert during normal browsing.

#import "../../Utils.h"

#import <UIKit/UIKit.h>

// How long to wait for the router's push. Measured at 68-88ms on IG 440; this is
// generous enough for a slow launch without leaving the hook live if IG changes
// and no push ever arrives.
static const NSTimeInterval kSPKOpenPostCaptureWindow = 2.5;

static void (^spk_openPostOnDismiss)(void) = nil;
static NSDate *spk_openPostWindowExpiry = nil;
static __weak UIViewController *spk_openPostPresenter = nil;
static void (^spk_openPostFallback)(void) = nil;
// Separate from the expiry: the window closing is what stops the hook acting on a
// stale push, but the fallback has to be able to run *because* the window closed.
static BOOL spk_openPostPending = NO;
// The redirect lives in a feature hook, so the master kill switch (and safe mode)
// leaves it uninstalled. Arming anyway would strand the caller: no hook means no
// capture, so the post would open behind the Gallery and sit there until the
// window lapsed seconds later. Without the hook we must not arm at all.
static BOOL spk_openPostHooksInstalled = NO;

static BOOL SPKOpenPostWindowIsArmed(void) {
    return spk_openPostPending && spk_openPostWindowExpiry != nil && spk_openPostWindowExpiry.timeIntervalSinceNow > 0;
}

static void SPKOpenPostDisarm(void) {
    spk_openPostPending = NO;
    spk_openPostWindowExpiry = nil;
    spk_openPostPresenter = nil;
    spk_openPostFallback = nil;
    spk_openPostOnDismiss = nil;
}

// Runs the caller's fallback (the legacy "dismiss the Gallery so the post behind it
// is visible") when the router pushed something we did not recognise, or nothing.
static void SPKOpenPostFallbackIfStillArmed(void) {
    if (!spk_openPostPending)
        return;
    void (^fallback)(void) = spk_openPostFallback;
    SPKLog(@"OpenPost", @"no single-feed push captured within %.1fs, falling back", kSPKOpenPostCaptureWindow);
    SPKOpenPostDisarm();
    if (fallback)
        fallback();
}

BOOL SPKOpenPostPushMediaURL(NSURL *url, UIViewController *presentingVC, void (^fallback)(void), void (^onDismiss)(void)) {
    if (!url || !presentingVC) {
        return NO;
    }
    // Only the authenticated in-app route pushes a page we can catch. A web
    // permalink resolves through continueUserActivity: into the main feed instead,
    // so it has nothing to redirect and must keep the legacy behaviour.
    if (![url.scheme.lowercaseString isEqualToString:@"instagram"] ||
        ![url.host.lowercaseString isEqualToString:@"media"]) {
        return NO;
    }
    if (!objc_getClass("IGSingleFeedViewController")) {
        return NO;
    }
    if (!spk_openPostHooksInstalled) {
        return NO;
    }
    spk_openPostPresenter = presentingVC;
    spk_openPostFallback = [fallback copy];
    spk_openPostOnDismiss = [onDismiss copy];
    spk_openPostWindowExpiry = [NSDate dateWithTimeIntervalSinceNow:kSPKOpenPostCaptureWindow];
    spk_openPostPending = YES;

    // Presented UI stays up: the push we are about to intercept never becomes
    // visible, so there is nothing to reveal.
    BOOL routed = [SPKUtils openInstagramMediaURL:url dismissingPresentedViewControllers:NO];
    if (!routed) {
        SPKOpenPostDisarm();
        return NO;
    }

    // Fires slightly after the window closes. Scheduling it exactly on the expiry
    // raced with the expiry itself: the timer found the window already lapsed, so
    // the fallback silently never ran.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kSPKOpenPostCaptureWindow + 0.3) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       SPKOpenPostFallbackIfStillArmed();
                   });
    return YES;
}

%group SPKOpenPostNativePush

// Hooked on UINavigationController, not IGNavigationController. IGNavigationController
// inherits pushViewController:animated: rather than implementing it, and hooking a
// method a class only inherits does not reliably bind -- an earlier build hooked the
// subclass and the hook never fired once, while the same push showed up immediately
// on the superclass.
%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!SPKOpenPostWindowIsArmed()) {
        %orig;
        return;
    }
    if (![viewController isKindOfClass:objc_getClass("IGSingleFeedViewController")]) {
        %orig;
        return;
    }

    UIViewController *presenter = spk_openPostPresenter;
    void (^onDismiss)(void) = spk_openPostOnDismiss;
    if (!presenter || !presenter.view.window) {
        // The Gallery went away underneath us; let IG have its push so the post
        // is not simply swallowed.
        SPKLog(@"OpenPost", @"presenter gone, letting IG push through");
        SPKOpenPostDisarm();
        %orig;
        return;
    }

    // Suppressing %orig is the whole point: the page must not land on the feed
    // stack, where it would sit behind the Gallery and strand the back button.
    SPKOpenPostDisarm();

    // Out of the router's call stack before presenting. Doing it inline reenters
    // UIKit navigation from inside a push it still believes it is performing.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![SPKUtils pushViewControllerOnNativeHost:viewController
                                  fromViewController:presenter
                                           onDismiss:onDismiss]) {
            SPKLog(@"OpenPost", @"native host unavailable, presenting captured page directly");
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:viewController];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [presenter presentViewController:nav animated:YES completion:nil];
        }
    });
}

%end

// Instagram's router clears the way before it navigates: ~3ms after the deep link is
// handed over it dismisses whatever is presented, which is our Gallery, and it does
// so from inside Instagram code with no hook of our own involved. That dismissal is
// what used to make the Gallery vanish, and it lands well before the push we want to
// catch (~65ms), so by capture time there was no presenter left to push onto.
//
// While the window is armed we therefore hold our own modal open. The scope is
// deliberately narrow: only inside the window, and only when the thing being
// dismissed belongs to Sparkle. Instagram is dismissing it purely to expose the
// stack it is about to push onto, and we are about to take that push away from it,
// so there is nothing left for the dismissal to accomplish.
// Identity, not class name: the only modal worth holding open is the one the
// pending redirect is going to push onto. Matching on a "SPK" prefix would have
// suppressed the dismissal of any Sparkle modal that happened to be up.
//
// Searched downwards through children *and* further presentations, because the
// presenter is not always a direct child of the modal being dismissed: the
// full-screen player sits inside its own navigation controller presented on top of
// the Gallery's, so walking up parentViewController from the player stopped at that
// inner stack and never reached the modal IG was dismissing.
static BOOL SPKOpenPostViewControllerContains(UIViewController *root, UIViewController *target) {
    if (!root || !target)
        return NO;
    if (root == target)
        return YES;
    for (UIViewController *child in root.childViewControllers) {
        if (SPKOpenPostViewControllerContains(child, target))
            return YES;
    }
    // Only from the actual presenter: -presentedViewController also answers for
    // ancestors, so following it from every node re-walks the same modal subtree
    // once per node.
    UIViewController *presented = root.presentedViewController;
    if (presented.presentingViewController != root)
        return NO;
    return SPKOpenPostViewControllerContains(presented, target);
}

static BOOL SPKOpenPostPresentsPendingPresenter(UIViewController *presented) {
    return SPKOpenPostViewControllerContains(presented, spk_openPostPresenter);
}

%hook UIViewController

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (SPKOpenPostWindowIsArmed() && SPKOpenPostPresentsPendingPresenter(self.presentedViewController)) {
        // Instagram may sequence the rest of the route off this completion, so it
        // still has to run -- it just runs without the dismissal behind it.
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }
    %orig;
}

%end

%end

// On IG 410 the media route first takes you "home": it focuses the tab bar, which
// scrolls the feed to the top when Home is the current tab, then re-selects Home
// as a tab bar action, which reaches this handler with every argument nil and
// clears injected posts, scrolls again and runs a Home-button refresh. The post
// then opens over a feed that was reset behind it, which only shows once you go
// back. Inside the armed window both are ours, not the user's, so both are
// dropped. Newer builds route media links without either call, and a real tap is
// never inside the window.
%group SPKOpenPostHomeTapGuard

%hook IGMainFeedViewController

- (void)handleTapOnHomeTabWithHoistedMediaID:(id)mediaID hoistedMediaShortcode:(id)shortcode deeplinkURL:(id)url {
    if (SPKOpenPostWindowIsArmed()) {
        SPKLog(@"OpenPost", @"dropping the router's home tab tap while a post push is pending");
        return;
    }
    %orig;
}

- (void)scrollToTopAnimated:(BOOL)animated {
    if (SPKOpenPostWindowIsArmed()) {
        SPKLog(@"OpenPost", @"dropping the router's feed scroll to top while a post push is pending");
        return;
    }
    %orig;
}

%end

%end

void SPKInstallOpenPostNativePushHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (objc_getClass("IGNavigationController")) {
            %init(SPKOpenPostNativePush);
            spk_openPostHooksInstalled = YES;
        } else {
            SPKLog(@"OpenPost", @"IGNavigationController missing, open post keeps the legacy route");
        }
        Class legacyFeed = objc_getClass("IGMainFeedViewController");
        if (spk_openPostHooksInstalled && legacyFeed &&
            class_getInstanceMethod(legacyFeed, @selector(handleTapOnHomeTabWithHoistedMediaID:hoistedMediaShortcode:deeplinkURL:)) &&
            class_getInstanceMethod(legacyFeed, @selector(scrollToTopAnimated:))) {
            %init(SPKOpenPostHomeTapGuard);
        }
    });
}
