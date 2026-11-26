#import "SPKMediaEditorChrome.h"
#import "SPKMediaChrome.h"
#import "../../Utils.h"
#import "SPKIGAlertPresenter.h"
#import "SPKStrings.h"

#pragma mark - Crossfade

// Editors opened from an editor replace its content in place, so the push is a
// crossfade rather than the sideways slide that would read as navigation.
@interface SPKMediaEditorFadeAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@end

@implementation SPKMediaEditorFadeAnimator

- (NSTimeInterval)transitionDuration:(__unused id<UIViewControllerContextTransitioning>)context {
    return 0.25;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIView *container = context.containerView;
    UIView *fromView = [context viewForKey:UITransitionContextFromViewKey];
    UIView *toView = [context viewForKey:UITransitionContextToViewKey];
    UIViewController *toController = [context viewControllerForKey:UITransitionContextToViewControllerKey];
    if (!toView) {
        [context completeTransition:!context.transitionWasCancelled];
        return;
    }
    toView.frame = [context finalFrameForViewController:toController];
    toView.alpha = 0.0;
    [container addSubview:toView];
    [UIView animateWithDuration:[self transitionDuration:context]
        delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut
        animations:^{
            toView.alpha = 1.0;
            fromView.alpha = 0.0;
        }
        completion:^(__unused BOOL finished) {
            fromView.alpha = 1.0;
            [context completeTransition:!context.transitionWasCancelled];
        }];
}

@end

#pragma mark - Navigation controller

@interface SPKMediaEditorNavigationController () <UINavigationControllerDelegate>
@end

@implementation SPKMediaEditorNavigationController

- (instancetype)initWithRootViewController:(UIViewController *)rootViewController {
    self = [super initWithRootViewController:rootViewController];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        // Always dark, like Photos: black canvas, light controls, regardless of
        // the system appearance.
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.delegate = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    SPKMediaChromeConfigureBottomToolbar(self.toolbar);
    // An edge swipe would fight the crop handles and the trim handles at the
    // screen edges; every editor has an explicit close button.
    self.interactivePopGestureRecognizer.enabled = NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(__unused UINavigationController *)navigationController
                                  animationControllerForOperation:(UINavigationControllerOperation)operation
                                               fromViewController:(__unused UIViewController *)fromVC
                                                 toViewController:(__unused UIViewController *)toVC {
    if (operation == UINavigationControllerOperationNone)
        return nil;
    return [SPKMediaEditorFadeAnimator new];
}

@end

#pragma mark - Opening and closing

void SPKMediaEditorPresent(UIViewController *editor, UIViewController *presenter) {
    if (!editor || !presenter)
        return;
    // Presenting onto a controller still finishing a dismissal is silently
    // refused by UIKit, so go to whatever is actually frontmost.
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    SPKMediaEditorNavigationController *nav = [[SPKMediaEditorNavigationController alloc] initWithRootViewController:editor];
    [presenter presentViewController:nav animated:YES completion:nil];
}

void SPKMediaEditorOpenFromEditor(UIViewController *editor, UIViewController *host) {
    if (!editor || !host)
        return;
    UINavigationController *nav = host.navigationController;
    if ([nav isKindOfClass:[SPKMediaEditorNavigationController class]] && nav.topViewController == host) {
        editor.navigationItem.hidesBackButton = YES;
        [nav pushViewController:editor animated:YES];
        return;
    }
    SPKMediaEditorPresent(editor, host);
}

void SPKMediaEditorClose(UIViewController *editor, void (^completion)(void)) {
    UINavigationController *nav = editor.navigationController;
    if (nav && nav.viewControllers.count > 1 && nav.viewControllers.firstObject != editor) {
        [nav popViewControllerAnimated:YES];
        if (completion)
            completion();
        return;
    }
    UIViewController *target = nav ?: editor;
    [target dismissViewControllerAnimated:YES completion:completion];
}

#pragma mark - Cancel

BOOL SPKMediaEditorIsPushed(UIViewController *editor) {
    UINavigationController *nav = editor.navigationController;
    return nav && nav.viewControllers.count > 1 && nav.viewControllers.firstObject != editor;
}

void SPKMediaEditorConfigureCancelItem(UIBarButtonItem *item, UIViewController *editor) {
    if (!item || !editor)
        return;
    BOOL pushed = SPKMediaEditorIsPushed(editor);
    item.image = SPKMediaChromeTopBarIcon(pushed ? @"chevron_left" : @"close");
    item.accessibilityLabel = pushed ? SPKL(@"MEDIA_EDITOR_BACK_ACCESSIBILITY_LABEL") : SPKL(@"ALERT_ACTION_CANCEL");
}

void SPKMediaEditorConfirmDiscard(UIViewController *editor, BOOL hasChanges, void (^discard)(void)) {
    if (!discard)
        return;
    if (!hasChanges || !editor) {
        discard();
        return;
    }
    [SPKIGAlertPresenter presentAlertFromViewController:editor
                                                  title:SPKL(@"MEDIA_EDITOR_DISCARD_CHANGES_TITLE")
                                                message:SPKL(@"MEDIA_EDITOR_DISCARD_CHANGES_MESSAGE")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DISCARD")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:discard],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_KEEP_EDITING")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                ]];
}

#pragma mark - Switch items

void SPKMediaEditorSetSwitchItemSelected(UIBarButtonItem *item, BOOL selected) {
    if (!item)
        return;
    item.tintColor = selected ? [SPKUtils SPKColor_InstagramBlue]
                              : ([SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor]);
    item.accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}

#pragma mark - Layout

BOOL SPKMediaEditorPrefersSideControls(UITraitCollection *traits, CGSize size) {
    if (traits.verticalSizeClass == UIUserInterfaceSizeClassCompact)
        return YES;
    // Regular width alone is not enough: an iPad in portrait has plenty of room
    // under the media. Side controls only when the display is also wide.
    return traits.horizontalSizeClass == UIUserInterfaceSizeClassRegular && size.width > size.height;
}
