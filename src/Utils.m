#import "SPKStrings.h"
#import "Utils.h"
#import "App/SPKCore.h"
#import "App/SPKStabilityGuard.h"
#import "AssetUtils.h"
#import "Settings/SPKPreferenceAvailability.h"
#import "Settings/SPKPreferences.h"
#import "Shared/Account/SPKAccountManager.h"
#import "Shared/Gallery/SPKGalleryLockViewController.h"
#import "Shared/Gallery/SPKGalleryPaths.h"
#import "Shared/MediaPreview/SPKMediaCacheManager.h"
#import "Shared/Settings/SPKSettingsLockManager.h"
#import "Shared/UI/SPKIGAlertPresenter.h"
#import "Shared/Messages/SPKDirectUserResolver.h"
#import "Shared/UI/SPKMediaChrome.h"
#import "Networking/SPKInstagramAPI.h"
#import "Shared/UI/SPKNotificationCenter.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSString *const kSPKPrefPerAccountSettings = @"general_per_account_settings";
NSNotificationName const SPKHideExploreGridPreferenceDidChangeNotification = @"SPKHideExploreGridPreferenceDidChangeNotification";

// A full screen modal always slides up from the bottom, which reads as "new
// sheet" rather than "went deeper". This animates it in from the trailing edge
// exactly the way UINavigationController animates a push, so opening a profile
// from a list feels like the push it conceptually is.
//
// The numbers below are not tuned by eye -- they were read off a real IG push by
// logging the CAAnimations UIKit installs (~/dev/frida/nav-push-timing.js).
// UIKit uses a spring, not a timing curve, which is why an eased version always
// felt slower and softer no matter how the duration was adjusted.
static const NSTimeInterval kSPKProfilePushDuration = 0.3508;
static const CGFloat kSPKProfilePushMass = 2.21;
static const CGFloat kSPKProfilePushStiffness = 1532.0;
static const CGFloat kSPKProfilePushDamping = 500.0;
// Measured but deliberately unused: UIKit slides the outgoing view a fixed 50pt
// (identical at 375pt and 402pt screen widths) and fades a dim over it. We do
// neither, because the surface underneath a presentation is not ours to move --
// see the note in interruptibleAnimatorForTransition:. Kept as a record in case
// the snapshot-based version is ever built.
//   parallax distance: 50.0pt      dim alpha: ~0.12
// The back swipe is NOT edge limited, because IG's is not either. IG installs
// IGTransitionAnimationPanInteractiveDriver on the view controller's own view --
// two IGDirectionalPanGestureRecognizers (permissableActivationDirections 1 and
// 2, left and right) covering the whole screen, no UIScreenEdgePan anywhere. A
// drag activates once it has moved this far, and then only if it is horizontal:
//
//   if (max(|dx|, |dy|) < 10) return;                 // not yet a gesture
//   horizontal = maxDegrees > 0 ? |dx| * tan(maxDegrees) > |dy|
//                               : |dx| > |dy|;        // plain axis dominance
//
// (from -[IGDirectionalPanGestureRecognizer touchesMoved:withEvent:], 440.0.0).
// The degrees variant is opt-in per screen via the navExtras key
// kPushNavigationPanMaxHorizontalDegreesProvider; the default path is the plain
// dominance test, which is what we do. A UIPanGestureRecognizer already waits
// for ~10pt on its own, so only the dominance test has to be reimplemented.
static const CGFloat kSPKProfilePanActivationDistance = 10.0;

// Releasing an interactive drag does NOT reuse the push spring. UIKit settles
// with a critically damped one (damping == 2*sqrt(stiffness*mass)) that carries
// the fling velocity, which is why a released swipe feels snappier than a
// tapped back button. Measured off a real interactive pop.
static const CGFloat kSPKProfileReleaseMass = 1.0;
static const CGFloat kSPKProfileReleaseStiffness = 1082.7113;
static const CGFloat kSPKProfileReleaseDamping = 65.8092;

// An empty stack slot below the profile, so the profile can be a real push onto
// a real IGNavigationController rather than a modal root pretending to be one.
//
// It draws nothing at all. The whole host stack is presented over the live
// screen, so what shows through this controller IS the screen you came from,
// still running. An earlier version put a window snapshot here to give IG's
// animator something to parallax; that bought the depth cue at the price of a
// frozen image sitting where a live screen should be, which was the worse trade.
// The surface behind a presentation is not ours to move, so with nothing to
// parallax the push simply slides the profile in over a stationary backdrop.
@interface SPKProfilePushHostViewController : UIViewController
@property (nonatomic, assign) BOOL didPush;
/// Runs once the host has torn itself down, i.e. the pushed screen was popped and
/// the screen underneath is live again. The presenter never receives appearance
/// callbacks of its own here, because the host is presented over it rather than in
/// place of it, so this is the only signal that the trip is over.
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@end

@implementation SPKProfilePushHostViewController

// IG asks the top view controller this; a bar over a see-through controller
// would be a second bar floating above the real screen's own.
- (BOOL)prefersNavigationBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
}

// Reached only by popping the profile off, since nothing else can make this the
// top view controller. Leaving without animation is invisible: the live screen
// underneath has been there the whole time.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didPush && self.navigationController.viewControllers.count == 1) {
        void (^onDismiss)(void) = self.onDismiss;
        self.onDismiss = nil;
        [self.presentingViewController dismissViewControllerAnimated:NO
                                                          completion:^{
                                                              if (onDismiss)
                                                                  onDismiss();
                                                          }];
    }
}

@end

// IGViewController overrides the modalPresentationStyle GETTER to consult its own
// adaptive presentation context, so assigning a style to an IGNavigationController
// is not reliably honoured. Presenting over the live screen instead of replacing
// it is the entire point here, so the style is pinned in a subclass rather than
// merely requested. Built at runtime because the superclass only exists inside
// the host app.
static Class SPKProfilePushNavigationClass(void) {
    static Class navClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = objc_getClass("IGNavigationController");
        if (!base)
            return;
        navClass = objc_allocateClassPair(base, "SPKProfilePushNavigationController", 0);
        if (!navClass) {
            // Already registered by an earlier load; reuse it.
            navClass = objc_getClass("SPKProfilePushNavigationController");
            return;
        }
        IMP style = imp_implementationWithBlock(^NSInteger(id _self) {
            return UIModalPresentationOverFullScreen;
        });
        class_addMethod(navClass, @selector(modalPresentationStyle), style, "q@:");
        objc_registerClassPair(navClass);
    });
    return navClass;
}

@interface SPKProfileSlideTransition : NSObject <UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning, UIViewControllerInteractiveTransitioning, UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL presenting;
@property (nonatomic, weak) UINavigationController *host;
@property (nonatomic, assign) BOOL interactive;
@property (nonatomic, strong) id<UIViewControllerContextTransitioning> interactiveContext;
@property (nonatomic, strong) UIViewPropertyAnimator *runningAnimator;
@end

@implementation SPKProfileSlideTransition

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source {
    self.presenting = YES;
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    self.presenting = NO;
    return self;
}

// Non-nil only while a finger is down, which is what makes the dismissal track
// the drag instead of playing back after the lift. We drive the interaction
// ourselves rather than using UIPercentDrivenInteractiveTransition, because that
// class finishes on a timing curve and gives no way to settle on the measured
// release spring.
- (id<UIViewControllerInteractiveTransitioning>)interactionControllerForDismissal:(id<UIViewControllerAnimatedTransitioning>)animator {
    return self.interactive ? self : nil;
}

- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)transitionContext {
    self.interactiveContext = transitionContext;
    UIViewPropertyAnimator *animator = (UIViewPropertyAnimator *)[self interruptibleAnimatorForTransition:transitionContext];
    // Paused, the animator becomes a scrubbable timeline for the drag.
    [animator pauseAnimation];
    [transitionContext updateInteractiveTransition:0];
}

// UIKit normalises the fling as "remaining distance per second", so a flick that
// would cover the rest of the travel in one second arrives as 1.0.
- (UISpringTimingParameters *)spk_releaseSpringForVelocity:(CGFloat)velocity remainingDistance:(CGFloat)distance {
    CGFloat normalised = distance > 1.0 ? fabs(velocity) / distance : 0.0;
    return [[UISpringTimingParameters alloc] initWithMass:kSPKProfileReleaseMass
                                                stiffness:kSPKProfileReleaseStiffness
                                                  damping:kSPKProfileReleaseDamping
                                          initialVelocity:CGVectorMake(normalised, 0)];
}

// ---------------------------------------------------------------- edge drag

- (void)attachTo:(UINavigationController *)nav {
    if (!nav)
        return;
    self.host = nav;
    // A plain pan rather than UIScreenEdgePanGestureRecognizer, and deliberately
    // not limited to the leading edge -- see kSPKProfilePanActivationDistance.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(spk_handleBackPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [nav.view addGestureRecognizer:pan];
}

- (void)spk_handleBackPan:(UIPanGestureRecognizer *)gesture {
    UINavigationController *nav = self.host;
    if (!nav)
        return;
    CGFloat width = MAX(nav.view.bounds.size.width, 1.0);
    CGFloat progress = MIN(MAX([gesture translationInView:nav.view].x / width, 0.0), 1.0);

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            // Kick off a real dismissal; startInteractiveTransition: then pauses
            // the animator so the drag can scrub it.
            self.interactive = YES;
            [nav dismissViewControllerAnimated:YES completion:nil];
            break;
        case UIGestureRecognizerStateChanged:
            self.runningAnimator.fractionComplete = progress;
            [self.interactiveContext updateInteractiveTransition:progress];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [gesture velocityInView:nav.view].x;
            BOOL commit = (gesture.state == UIGestureRecognizerStateEnded) && (progress > 0.33 || velocity > 800.0);
            UIViewPropertyAnimator *animator = self.runningAnimator;
            id<UIViewControllerContextTransitioning> context = self.interactiveContext;

            // Distance still to travel, so the fling can be normalised the way
            // UIKit does it. Committing runs to the end; cancelling reverses.
            CGFloat remaining = (commit ? (1.0 - progress) : progress) * width;
            UISpringTimingParameters *spring = [self spk_releaseSpringForVelocity:velocity remainingDistance:remaining];

            if (commit)
                [context finishInteractiveTransition];
            else
                [context cancelInteractiveTransition];

            animator.reversed = !commit;
            // durationFactor 0 lets the spring's own settling time decide.
            [animator continueAnimationWithTimingParameters:spring durationFactor:0];

            self.interactive = NO;
            self.interactiveContext = nil;
            break;
        }
        default:
            break;
    }
}

// A horizontal pager under the finger gets to page first, and only hands the
// drag over once it has nothing left to scroll. That is what makes a right swipe
// on the profile's posts/reels/reposts pager change tab on tabs 2 and 3 but go
// back on tab 1, without special casing either.
static BOOL SPKPagerWantsRightwardDrag(UIView *root, CGPoint point) {
    UIView *hit = [root hitTest:point withEvent:nil];
    while (hit && hit != root) {
        if ([hit isKindOfClass:[UIScrollView class]]) {
            UIScrollView *scroll = (UIScrollView *)hit;
            BOOL scrollsHorizontally = scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0;
            // Rightward means moving towards the content's leading edge, so it is
            // only the pager's drag while it still has content to the left.
            CGFloat leading = -scroll.adjustedContentInset.left;
            if (scrollsHorizontally && scroll.contentOffset.x > leading + 1.0)
                return YES;
        }
        hit = hit.superview;
    }
    return NO;
}

// Only drive the dismiss at the root; once IG has pushed something of its own
// the standard interactive pop owns the gesture. Beyond that this is IG's own
// test: anywhere on screen, activate on a drag that is more horizontal than
// vertical and heading right, leaving vertical scrolling alone.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (self.host.viewControllers.count > 1)
        return NO;

    UIView *view = self.host.view;
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]])
        return YES;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint translation = [pan translationInView:view];
    if (MAX(fabs(translation.x), fabs(translation.y)) < kSPKProfilePanActivationDistance)
        return NO;
    if (translation.x <= 0 || fabs(translation.x) <= fabs(translation.y))
        return NO;

    return !SPKPagerWantsRightwardDrag(view, [pan locationInView:view]);
}

// Having already yielded to a pager that can still scroll, never fail for one
// that cannot -- otherwise a swipe anywhere over the grid would be swallowed
// instead of going back.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext {
    return kSPKProfilePushDuration;
}

// Only runs for a non-interactive transition: a present, or a dismissal from the
// back button. The measured push spring is the right one here -- the snappier
// release spring is applied in the gesture handler instead.
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext {
    [[self interruptibleAnimatorForTransition:transitionContext] startAnimation];
}

// UIViewPropertyAnimator with UISpringTimingParameters takes UIKit's own
// mass/stiffness/damping, so this reproduces the push curve rather than
// approximating it. Returning an interruptible animator also lets the percent
// driven interaction scrub it; scrubsLinearly (on by default) keeps the drag
// linear while still springing on release.
- (id<UIViewImplicitlyAnimating>)interruptibleAnimatorForTransition:(id<UIViewControllerContextTransitioning>)transitionContext {
    if (self.runningAnimator)
        return self.runningAnimator;

    UIView *container = transitionContext.containerView;
    // Views UIKit hands us are ours to move, resize and reparent. Under
    // UIModalPresentationFullScreen it often vends nil for the outgoing side, in
    // which case we fall back to the view controller's view purely to animate it
    // -- never to reframe or reparent it. Doing that to a host we do not own
    // resized the story mentions sheet to full screen and detached it from its
    // own presentation container, leaving an empty dimmed backdrop behind.
    UIView *vendedTo = [transitionContext viewForKey:UITransitionContextToViewKey];
    UIView *vendedFrom = [transitionContext viewForKey:UITransitionContextFromViewKey];
    UIView *toView = vendedTo ?: [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey].view;
    UIView *fromView = vendedFrom ?: [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey].view;

    CGFloat width = container.bounds.size.width;

    // No parallax, no dim on the surface underneath. UIKit gets to move the
    // outgoing view during a push because both views belong to the same stack
    // and it owns them. Here the surface underneath is a host we do not own --
    // a sheet with its own presentation controller, or a presenting view that
    // UIKit yanks out of the window once the transition completes -- so
    // transforming it fights UIKit's bookkeeping instead of reading as depth.
    // Faking it convincingly would mean animating a snapshot inside the
    // container rather than the live view; until then the incoming slide, which
    // is measured and correct, carries the transition on its own.

    UIView *incoming = self.presenting ? toView : fromView;
    UIView *outgoing = self.presenting ? fromView : toView;
    // YES only when the surface being revealed is one UIKit gave us to place.
    BOOL outgoingIsOurs = self.presenting ? (vendedFrom != nil) : (vendedTo != nil);
    if (!incoming) {
        [transitionContext completeTransition:YES];
        return nil;
    }

    if (self.presenting) {
        toView.frame = container.bounds;
        [container addSubview:toView];
        toView.transform = CGAffineTransformMakeTranslation(width, 0);
    } else if (outgoing && outgoingIsOurs) {
        // Placing a view UIKit vended is required; it has none of the hazards of
        // transforming a host we do not own.
        outgoing.frame = container.bounds;
        [container insertSubview:outgoing belowSubview:incoming];
    }

    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithMass:kSPKProfilePushMass
                                                                            stiffness:kSPKProfilePushStiffness
                                                                              damping:kSPKProfilePushDamping
                                                                      initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:kSPKProfilePushDuration
                                                                       timingParameters:spring];

    // Only the incoming view is animated; the host underneath is left untouched.
    BOOL presenting = self.presenting;
    [animator addAnimations:^{
        incoming.transform = presenting ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(width, 0);
    }];

    __weak typeof(self) weakSelf = self;
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        // A cancelled interactive dismissal leaves the view mid-slide.
        incoming.transform = CGAffineTransformIdentity;
        [transitionContext completeTransition:!transitionContext.transitionWasCancelled];
        weakSelf.runningAnimator = nil;
    }];

    self.runningAnimator = animator;
    return animator;
}

- (void)animationEnded:(BOOL)transitionCompleted {
    self.runningAnimator = nil;
}

@end

Class SPKReelsVerticalUFIClass(void) {
    // IG 436+ : Swift-mangled name (module + class both "IGSundialViewerVerticalUFI").
    Class cls = objc_getClass("_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI");
    // IG <=435 : class exposed to ObjC under its plain name.
    if (!cls)
        cls = objc_getClass("IGSundialViewerVerticalUFI");
    // Defensive: demangled "Module.Class" form some runtimes report.
    if (!cls)
        cls = objc_getClass("IGSundialViewerVerticalUFI.IGSundialViewerVerticalUFI");
    return cls;
}

Class SPKResolveIGClass(NSString *qualified, NSString *legacy) {
    Class c = Nil;
    if (qualified.length) {
        // NSClassFromString demangles a Swift "Module.Class" spelling (IG 436+).
        c = NSClassFromString(qualified);
        if (!c) {
            // Fall back to building the mangled _TtC<len><Module><len><Class> symbol.
            NSArray<NSString *> *p = [qualified componentsSeparatedByString:@"."];
            if (p.count == 2) {
                NSString *m = p[0], *n = p[1];
                NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@",
                                                               (unsigned long)m.length, m, (unsigned long)n.length, n];
                c = objc_getClass(mangled.UTF8String);
            }
        }
    }
    // IG <=435 : plain ObjC name.
    if (!c && legacy.length)
        c = NSClassFromString(legacy);
    return c;
}

static NSString *SPKTrimmedLogBody(NSString *body) {
    return [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SPKNormalizedLogBody(NSString *category, NSString *body, NSString **outCategory) {
    NSString *resolvedCategory = category.length ? category : @"General";
    NSString *resolvedBody = body ?: @"";
    NSArray<NSDictionary<NSString *, NSString *> *> *legacyPrefixes = @[
        @{@"prefix" : @"[Sparkle][startup]", @"category" : @"Startup"},
        @{@"prefix" : @"[Sparkle Gallery]", @"category" : @"Gallery"},
        @{@"prefix" : @"[Sparkle BulkDownload]", @"category" : @"BulkDownload"},
        @{@"prefix" : @"[Sparkle]", @"category" : resolvedCategory},
    ];

    for (NSDictionary<NSString *, NSString *> *entry in legacyPrefixes) {
        NSString *prefix = entry[@"prefix"];
        if ([resolvedBody hasPrefix:prefix]) {
            resolvedCategory = entry[@"category"] ?: resolvedCategory;
            resolvedBody = SPKTrimmedLogBody([resolvedBody substringFromIndex:prefix.length]);
            break;
        }
    }

    if (outCategory) {
        *outCategory = resolvedCategory;
    }
    return resolvedBody;
}

void SPKLogMessage(NSString *category, os_log_type_t type, NSString *format, ...) {
    NSString *body = @"";
    if (format.length > 0) {
        va_list args;
        va_start(args, format);
        body = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
    }

    NSString *resolvedCategory = nil;
    NSString *resolvedBody = SPKNormalizedLogBody(category, body ?: @"", &resolvedCategory);
    NSString *line = [NSString stringWithFormat:@"[Sparkle %@]: %@", resolvedCategory ?: @"General", resolvedBody ?: @""];
    os_log_with_type(OS_LOG_DEFAULT, type, "%{public}s", line.UTF8String);
}

static NSNumber *SPKNumericValueForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const char *returnType = signature.methodReturnType;
    if (!returnType || !returnType[0])
        return nil;

    switch (returnType[0]) {
    case '@': {
        id value = ((id (*)(id, SEL))objc_msgSend)(target, selector);
        if ([value respondsToSelector:@selector(doubleValue)]) {
            return @([value doubleValue]);
        }
        if ([value respondsToSelector:@selector(integerValue)]) {
            return @(((NSInteger (*)(id, SEL))objc_msgSend)(value, @selector(integerValue)));
        }
        return nil;
    }
    case 'd':
        return @(((double (*)(id, SEL))objc_msgSend)(target, selector));
    case 'f':
        return @((double)((float (*)(id, SEL))objc_msgSend)(target, selector));
    case 'q':
        return @((double)((long long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'Q':
        return @((double)((unsigned long long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'i':
        return @((double)((int (*)(id, SEL))objc_msgSend)(target, selector));
    case 'I':
        return @((double)((unsigned int (*)(id, SEL))objc_msgSend)(target, selector));
    case 'l':
        return @((double)((long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'L':
        return @((double)((unsigned long (*)(id, SEL))objc_msgSend)(target, selector));
    case 's':
        return @((double)((short (*)(id, SEL))objc_msgSend)(target, selector));
    case 'S':
        return @((double)((unsigned short (*)(id, SEL))objc_msgSend)(target, selector));
    case 'c':
        return @((double)((char (*)(id, SEL))objc_msgSend)(target, selector));
    case 'C':
        return @((double)((unsigned char (*)(id, SEL))objc_msgSend)(target, selector));
    case 'B':
        return @((double)((BOOL (*)(id, SEL))objc_msgSend)(target, selector));
    default:
        return nil;
    }
}

static id SPKObjectForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id SPKKVCObject(id target, NSString *key) {
    if (!target || !key.length)
        return nil;

    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSURL *SPKURLFromStringOrURL(id value) {
    if (!value)
        return nil;

    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }

    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return [NSURL URLWithString:(NSString *)value];
    }

    return nil;
}

static double SPKDoubleValue(id value) {
    if (!value)
        return 0.0;

    if ([value respondsToSelector:@selector(doubleValue)]) {
        return [value doubleValue];
    }

    return 0.0;
}

static NSInteger SPKIntegerValue(id value) {
    if (!value)
        return 0;

    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }

    return 0;
}

static NSArray *SPKArrayFromCollection(id collection) {
    if (!collection ||
        [collection isKindOfClass:[NSDictionary class]] ||
        [collection isKindOfClass:[NSString class]] ||
        [collection isKindOfClass:[NSURL class]]) {
        return nil;
    }

    if ([collection isKindOfClass:[NSArray class]]) {
        return collection;
    }

    if ([collection isKindOfClass:[NSOrderedSet class]]) {
        return [(NSOrderedSet *)collection array];
    }

    if ([collection isKindOfClass:[NSSet class]]) {
        return [(NSSet *)collection allObjects];
    }

    if ([collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in collection) {
            [items addObject:item];
        }
        return items;
    }

    return nil;
}

static NSString *const kSPKCacheAutoClearModeKey = @"general_cache_auto_clear";
static NSString *const kSPKCacheLastClearedAtKey = @"general_cache_last_cleared_at";

static UIColor *SPKDynamicInstagramColor(CGFloat lightRed,
                                         CGFloat lightGreen,
                                         CGFloat lightBlue,
                                         CGFloat darkRed,
                                         CGFloat darkGreen,
                                         CGFloat darkBlue) {
    return [UIColor colorWithDynamicProvider:^UIColor *_Nonnull(UITraitCollection *_Nonnull traitCollection) {
        BOOL dark = traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        CGFloat red = dark ? darkRed : lightRed;
        CGFloat green = dark ? darkGreen : lightGreen;
        CGFloat blue = dark ? darkBlue : lightBlue;
        return [UIColor colorWithRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:1.0];
    }];
}

static UIColor *SPKInstagramColorFromClassSelector(NSString *className, SEL selector) {
    Class colorClass = NSClassFromString(className);
    if (!colorClass || ![colorClass respondsToSelector:selector])
        return nil;

    id color = ((id (*)(id, SEL))objc_msgSend)(colorClass, selector);
    return [color isKindOfClass:[UIColor class]] ? color : nil;
}

static UIColor *SPKInstagramPrimaryAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *_Nonnull(UITraitCollection *_Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.408 green:0.557 blue:1.032 alpha:1.0];
        } else {
            return [UIColor colorWithRed:0.270 green:0.367 blue:1.013 alpha:1.0];
        }
    }];
}

static UIColor *SPKInstagramDestructiveColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *_Nonnull(UITraitCollection *_Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.957 green:0.357 blue:0.420 alpha:1.0];
        } else {
            return [UIColor colorWithRed:0.867 green:0.082 blue:0.208 alpha:1.0];
        }
    }];
}

static NSArray *SPKImageVersionsFromPhoto(IGPhoto *photo) {
    if (!photo)
        return nil;

    NSArray *versions = SPKArrayFromCollection(SPKObjectForSelector(photo, @"imageVersions"));
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection([SPKUtils getIvarForObj:photo name:"_originalImageVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection(SPKObjectForSelector(photo, @"imageVersionDictionaries"));
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection([SPKUtils getIvarForObj:photo name:"_imageVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection([SPKUtils getIvarForObj:photo name:"_imageVersionDictionaries"]);
    return versions.count > 0 ? versions : nil;
}

static NSArray *SPKVideoVersionsFromVideo(IGVideo *video) {
    if (!video)
        return nil;

    NSArray *versions = SPKArrayFromCollection(SPKObjectForSelector(video, @"videoVersions"));
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection(SPKObjectForSelector(video, @"videoVersionDictionaries"));
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection([SPKUtils getIvarForObj:video name:"_videoVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKArrayFromCollection([SPKUtils getIvarForObj:video name:"_videoVersionDictionaries"]);
    return versions.count > 0 ? versions : nil;
}

static NSArray<NSDictionary *> *SPKSortedMediaVariantsFromVersions(NSArray *versions) {
    if (![versions isKindOfClass:[NSArray class]] || versions.count == 0) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    for (id version in versions) {
        id rawURL = nil;
        id widthValue = nil;
        id heightValue = nil;
        id bandwidthValue = nil;

        if ([version isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)version;
            rawURL = dict[@"url"] ?: dict[@"urlString"];
            widthValue = dict[@"width"];
            heightValue = dict[@"height"];
            bandwidthValue = dict[@"bandwidth"];
        } else {
            rawURL = SPKObjectForSelector(version, @"url");
            if (!rawURL) {
                rawURL = SPKObjectForSelector(version, @"urlString");
            }
            widthValue = SPKNumericValueForSelector(version, @"width");
            heightValue = SPKNumericValueForSelector(version, @"height");
            bandwidthValue = SPKNumericValueForSelector(version, @"bandwidth");
        }

        NSURL *url = SPKURLFromStringOrURL(rawURL);
        if (!url)
            continue;

        NSString *absolute = url.absoluteString;
        if (absolute.length == 0 || [seenURLs containsObject:absolute]) {
            continue;
        }
        [seenURLs addObject:absolute];

        [variants addObject:@{
            @"url" : url,
            @"width" : @(SPKDoubleValue(widthValue)),
            @"height" : @(SPKDoubleValue(heightValue)),
            @"bandwidth" : @(SPKIntegerValue(bandwidthValue))
        }];
    }

    [variants sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        double lhsArea = [lhs[@"width"] doubleValue] * [lhs[@"height"] doubleValue];
        double rhsArea = [rhs[@"width"] doubleValue] * [rhs[@"height"] doubleValue];

        if (lhsArea > rhsArea)
            return NSOrderedAscending;
        if (lhsArea < rhsArea)
            return NSOrderedDescending;

        NSInteger lhsBandwidth = [lhs[@"bandwidth"] integerValue];
        NSInteger rhsBandwidth = [rhs[@"bandwidth"] integerValue];
        if (lhsBandwidth > rhsBandwidth)
            return NSOrderedAscending;
        if (lhsBandwidth < rhsBandwidth)
            return NSOrderedDescending;

        return NSOrderedSame;
    }];

    return variants;
}

static NSURL *SPKHighestQualityURLFromVersions(NSArray *versions) {
    NSArray<NSDictionary *> *variants = SPKSortedMediaVariantsFromVersions(versions);
    if (variants.count == 0)
        return nil;

    id value = variants.firstObject[@"url"];
    return [value isKindOfClass:[NSURL class]] ? value : nil;
}

static NSURL *SPKURLFromVideoURLCollection(id collection) {
    if (!collection)
        return nil;

    NSArray *items = SPKArrayFromCollection(collection);

    if (!items) {
        return SPKURLFromStringOrURL(collection);
    }

    for (id item in items) {
        NSURL *url = nil;

        if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)item;
            url = SPKURLFromStringOrURL(dict[@"url"] ?: dict[@"urlString"]);
        } else {
            url = SPKURLFromStringOrURL(item);
        }

        if (url)
            return url;
    }

    return nil;
}

static NSURL *SPKProfilePictureURLFromInfo(id info) {
    if (!info)
        return nil;

    NSURL *url = SPKURLFromStringOrURL(SPKObjectForSelector(info, @"url"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(info, @"urlString"));
    if (url)
        return url;

    if ([info isKindOfClass:[NSDictionary class]]) {
        NSDictionary *infoDictionary = (NSDictionary *)info;
        url = SPKURLFromStringOrURL(infoDictionary[@"url"] ?: infoDictionary[@"urlString"]);
        if (url)
            return url;
    }

    return nil;
}

static NSURL *SPKHDProfilePicURL(id user) {
    if (!user)
        return nil;

    NSURL *url = SPKProfilePictureURLFromInfo(SPKObjectForSelector(user, @"hdProfilePicUrlInfo"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"HDProfilePicURL"));
    if (url)
        return url;

    url = SPKProfilePictureURLFromInfo(SPKObjectForSelector(user, @"_private_hdProfilePicUrlInfo"));
    if (url)
        return url;

    url = SPKProfilePictureURLFromInfo(SPKObjectForSelector(user, @"HDProfilePicURLInfo"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"profile_pic_url_hd"));
    if (url)
        return url;

    return SPKURLFromStringOrURL(SPKKVCObject(user, @"profile_pic_url_hd"));
}

static NSURL *SPKThumbProfilePicURL(id user) {
    if (!user)
        return nil;

    NSURL *url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"derivedProfilePicURL"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"profilePicURLString"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"profilePicURL"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"_private_profilePicURLString"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"_private_profilePicUrl"));
    if (url)
        return url;

    url = SPKURLFromStringOrURL(SPKObjectForSelector(user, @"profile_pic_url"));
    if (url)
        return url;

    return SPKURLFromStringOrURL(SPKKVCObject(user, @"profile_pic_url"));
}

static BOOL SPKInstagramHostMatchesCanonical(NSString *host) {
    if (host.length == 0)
        return NO;
    NSString *lower = host.lowercaseString;
    return [lower isEqualToString:@"instagram.com"] || [lower isEqualToString:@"www.instagram.com"] || [lower isEqualToString:@"instagr.am"] || [lower hasSuffix:@".instagram.com"];
}

static BOOL SPKInstagramPathUsesSharePrefix(NSArray<NSString *> *segments) {
    if (segments.count < 2)
        return NO;
    NSString *candidate = segments[1].lowercaseString;
    return [candidate isEqualToString:@"p"] || [candidate isEqualToString:@"reel"] || [candidate isEqualToString:@"reels"] || [candidate isEqualToString:@"tv"];
}

static NSArray<NSString *> *SPKSanitizedInstagramPathSegments(NSArray<NSString *> *segments) {
    if (segments.count >= 3 && SPKInstagramPathUsesSharePrefix(segments)) {
        return [segments subarrayWithRange:NSMakeRange(1, segments.count - 1)];
    }
    return segments;
}

static NSArray<NSURLQueryItem *> *SPKSanitizedInstagramQueryItems(NSArray<NSURLQueryItem *> *items) {
    if (items.count == 0)
        return nil;

    static NSSet<NSString *> *blockedKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blockedKeys = [NSSet setWithArray:@[
            @"igsh", @"igshid", @"igsi", @"ig_rid", @"ig_mid",
            @"utm_source", @"utm_medium", @"utm_campaign", @"utm_term", @"utm_content",
            @"fbclid"
        ]];
    });

    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in items) {
        if (![blockedKeys containsObject:item.name.lowercaseString]) {
            [kept addObject:item];
        }
    }
    return kept.count > 0 ? kept : nil;
}

@interface SPKSettingsNavigationController : SPKChromeNavigationController
@end

@implementation SPKSettingsNavigationController

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.presentingViewController == nil) {
        [[SPKSettingsLockManager sharedManager] lockSettings];
    }
}

@end

static void SPKPresentSettingsAfterUnlock(UIViewController *presenter, dispatch_block_t presentation) {
    SPKSettingsLockManager *manager = [SPKSettingsLockManager sharedManager];
    if (manager.isLockEnabled && !manager.isUnlocked) {
        [SPKGalleryLockViewController presentUnlockForManager:manager
                                           fromViewController:presenter
                                                   completion:^(BOOL success) {
                                                       if (success && presentation)
                                                           presentation();
                                                   }];
        return;
    }
    if (presentation)
        presentation();
}

@implementation SPKUtils

// Master kill switch overlay: when "Disable All Settings" is on, runtime
// reads of feature prefs return the registered default instead of the user's
// stored value. The toggles themselves still display the saved state because
// the settings UI reads NSUserDefaults directly (boolForKey:), not these
// accessors.
//
// A handful of keys must bypass the overlay so the kill switch and the
// settings shortcut keep working. They're enumerated here.
static NSSet<NSString *> *SPKMasterDisableBypassKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"tools_disable_all",
            @"tools_settings_shortcut",
            @"gallery_quick_access_tab",
            @"tools_open_settings_on_launch",
            @"app_first_run",
        ]];
    });
    return keys;
}

static BOOL SPKMasterDisableActive(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"tools_disable_all"];
}

#pragma mark - Per-account preference namespacing

// Read directly (never through the namespacing accessors) to avoid recursion;
// the toggle itself is global.
static BOOL SPKPrefPerAccountEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSPKPrefPerAccountSettings];
}

// Keys that must never be per-account: physically single (app icon), device/app
// wide (master kill switch, safe mode), appearance/Liquid Glass, download
// encoding params, and all gallery view/lock/folder prefs.
static BOOL SPKPrefIsGlobalKey(NSString *key) {
    static NSSet<NSString *> *globalExact;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        globalExact = [NSSet setWithArray:@[
            kSPKPrefPerAccountSettings,
            @"general_app_icon_identifier",
            @"tools_disable_all",
            // Notification delivery is install-wide, not per-account.
            @"tools_fix_duplicate_notifications",
            @"app_first_run",
            @"app_safe_startup",
            @"app_startup_profiling",
            // The app font is resolved by the very first view Instagram builds, from
            // hooks installed in %ctor -- long before any account session exists. A
            // per-account key would read the global default on every cold launch.
            @"interface_custom_font",
            @"interface_language",
            @"interface_liquid_glass",
            @"interface_liquid_glass_tabbar_mode",
            @"interface_progressive_blur",
            @"interface_hide_ui_on_capture",
            @"downloads_adv_encoding",
            // Tab/launch layout is configured once at launch and can't re-apply
            // on a live account switch, so it stays global (maintainer's call).
            @"interface_nav_order",
            @"interface_custom_tab_order",
            @"interface_swipe_tabs",
            @"interface_launch_tab",
            // The rest of the tab bar configuration goes with the layout for the
            // same reason, and it has to: the bar is assembled during early
            // launch, so on the launches where the session has not resolved yet a
            // per-account key silently reads the global value instead. That made
            // hidden tabs come and go between launches and account switches.
            @"interface_hide_feed_tab",
            @"interface_hide_reels_tab",
            @"interface_hide_msgs_tab",
            @"interface_hide_explore_tab",
            @"interface_hide_profile_tab",
            @"interface_hide_create_tab",
            @"interface_hide_tab_bar_in_messages_only",
            @"interface_saved_tab_carrier",
            // The Settings quick-access long-press is attached to tab-bar buttons
            // as they're built during early launch — before the account session
            // resolves — so a per-account effective key resolves against the
            // wrong PK and the gesture sticks to whatever account owned the bar at
            // launch. Kept global so it's reliable and matches the (global)
            // gallery quick-access shortcut.
            @"tools_settings_shortcut",
            // Suppressing the TestFlight popup runs early in %ctor before the account
            // session resolves, and is inherently an application/install-wide setting.
            @"tools_hide_testflight_popup",
            // Main feed mode (For You / Following) is read during early feed
            // setup before the account resolves, so it stays global.
            @"feed_mode",
            // The feed playback strategy is created during early launch, before
            // the account session resolves (currentUserPK == nil), so a
            // per-account effective key would resolve against the wrong PK and
            // miss the value. Read the plain global key — no session dependency.
            @"feed_disable_autoplay",
            // Reels doom scroll and limits are application-wide behavioral controls,
            // and must resolve early/reliably regardless of account session state.
            @"reels_prevent_doom_scroll",
            @"reels_doom_scroll_limit",
            @"reels_disable_scrolling",
        ]];
    });
    if ([globalExact containsObject:key])
        return YES;
    if ([key hasPrefix:@"downloads_encoding_"])
        return YES;
#if SPK_DEV
    // Hook-bisect skip flags: read during hook installation (before the session
    // PK resolves) and meaningless per-account — a bisect must behave the same
    // whichever account is live.
    if ([key hasPrefix:@"tools_bisect_"])
        return YES;
    // Performance meter: a diagnostic instrument, not a per-account preference.
    if ([key hasPrefix:@"tools_perf_"])
        return YES;
#endif
    if ([key hasPrefix:@"gallery_"])
        return YES;
    return NO;
}

BOOL SPKPerAccountModeActive(void) {
    return SPKPrefPerAccountEnabled() && [SPKAccountManager currentAccountPK].length > 0;
}

BOOL SPKPreferenceKeyIsGlobal(NSString *key) {
    return SPKPrefIsGlobalKey(key);
}

NSString *SPKEffectivePreferenceKey(NSString *key) {
    if (key.length == 0)
        return key;
    if (!SPKPrefPerAccountEnabled())
        return key;
    if (SPKPrefIsGlobalKey(key))
        return key;
    // Use the best-effort namespace PK: during the early-launch window the live
    // session isn't resolved yet (currentAccountPK == nil), so this falls back
    // to the last-active account from the roster. Without it, hooks that fire
    // early (e.g. feed autoplay strategy creation) read the global default
    // instead of the per-account value the user actually set.
    NSString *pk = [SPKAccountManager preferenceNamespacePK];
    if (pk.length == 0)
        return key; // no known account → use global
    return [NSString stringWithFormat:@"u_%@_%@", pk, key];
}

// Namespaced direct-defaults access for callers that read/write NSUserDefaults
// outside the SPKUtils getXPref accessors (action-button config, manual-seen
// list, etc.). Mirrors the accessor's per-account → global inheritance.
id SPKPreferenceObjectForKey(NSString *key) {
    if (key.length == 0)
        return nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *effectiveKey = SPKEffectivePreferenceKey(key);
    if (![effectiveKey isEqualToString:key]) {
        id perAccountValue = [defaults objectForKey:effectiveKey];
        if (perAccountValue != nil)
            return perAccountValue;
    }
    return [defaults objectForKey:key];
}

void SPKPreferenceSetObject(id value, NSString *key) {
    if (key.length == 0)
        return;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:SPKEffectivePreferenceKey(key)];
}

static id SPKPrefValueWithMasterOverlay(NSString *key) {
    if (key.length == 0)
        return nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (SPKMasterDisableActive() && ![SPKMasterDisableBypassKeys() containsObject:key]) {
        return SPKCoreRegisteredDefaults()[key];
    }
    NSString *effectiveKey = SPKEffectivePreferenceKey(key);
    if (![effectiveKey isEqualToString:key]) {
        id perAccountValue = [defaults objectForKey:effectiveKey];
        // Inherit the global value (and its registered default) until this
        // account overrides the key.
        if (perAccountValue != nil)
            return perAccountValue;
    }
    return [defaults objectForKey:key];
}

+ (BOOL)getBoolPref:(NSString *)key {
    if (![key length])
        return NO;
    if (!SPKPrefIsAvailable(key))
        return NO;
    id value = SPKPrefValueWithMasterOverlay(key);
    if ([value respondsToSelector:@selector(boolValue)])
        return [value boolValue];
    return NO;
}
+ (double)getDoublePref:(NSString *)key {
    if (![key length])
        return 0;
    id value = SPKPrefValueWithMasterOverlay(key);
    if ([value respondsToSelector:@selector(doubleValue)])
        return [value doubleValue];
    return 0;
}
+ (NSString *)getStringPref:(NSString *)key {
    if (![key length])
        return @"";
    id value = SPKPrefValueWithMasterOverlay(key);
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

// MARK: Misc
+ (BOOL)tabOrderSetTo:(NSString *)ordering {
    return [[[NSUserDefaults standardUserDefaults] stringForKey:@"interface_nav_order"] isEqualToString:ordering];
};

+ (NSString *)IGVersionString {
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
};

+ (_Bool)spk_liquidGlassLauncherPrefKey:(NSString *)key orig:(_Bool)fallback {
    return [SPKUtils spk_isLiquidGlassEffectivelyEnabled] ? YES : fallback;
}

+ (BOOL)spk_isLiquidGlassEffectivelyEnabled {
    return [SPKUtils getBoolPref:kSPKPrefInterfaceLiquidGlass] &&
           !SPKStabilityGuardIsSafeStartupMode();
}

// MARK: Session / user
+ (id)activeUserSession {
    @try {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]])
                continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                id session = nil;
                @try {
                    if ([window respondsToSelector:@selector(userSession)]) {
                        session = [window valueForKey:@"userSession"];
                    }
                } @catch (__unused NSException *e) {
                }
                if (session)
                    return session;
            }
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

+ (NSString *)pkFromIGUser:(id)user {
    if (!user)
        return nil;
    // Prefer the public accessor — robust even when the backing ivar is renamed
    // or absent (Swift-bridged classes). IGUser exposes `pk` as a readonly
    // property; the raw `_pk` ivar isn't reliable across IG versions.
    @try {
        if ([user respondsToSelector:@selector(pk)]) {
            id pk = ((id (*)(id, SEL))objc_msgSend)(user, @selector(pk));
            if ([pk isKindOfClass:[NSString class]] && [(NSString *)pk length])
                return pk;
            if ([pk respondsToSelector:@selector(stringValue)]) {
                NSString *s = [pk stringValue];
                if (s.length)
                    return s;
            }
            if (pk) {
                NSString *d = [pk description];
                if (d.length)
                    return d;
            }
        }
    } @catch (__unused NSException *e) {
    }

    // Fallback: read the _pk ivar directly.
    Ivar pkIvar = NULL;
    for (Class cls = [user class]; cls && !pkIvar; cls = class_getSuperclass(cls)) {
        pkIvar = class_getInstanceVariable(cls, "_pk");
    }
    if (!pkIvar)
        return nil;
    @try {
        id pk = object_getIvar(user, pkIvar);
        if ([pk isKindOfClass:[NSString class]] && [(NSString *)pk length])
            return pk;
        if (pk)
            return [pk description];
    } @catch (__unused NSException *e) {
    }
    return nil;
}

+ (NSString *)currentUserPK {
    id session = [self activeUserSession];
    if (!session)
        return nil;
    @try {
        id user = [session valueForKey:@"user"];
        return [self pkFromIGUser:user];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (NSDictionary<NSString *, NSString *> *)currentUserIdentity {
    id session = [self activeUserSession];
    if (!session)
        return nil;
    id user = nil;
    @try {
        user = [session valueForKey:@"user"];
    } @catch (__unused NSException *e) {
    }
    if (!user)
        return nil;

    NSMutableDictionary<NSString *, NSString *> *info = [NSMutableDictionary dictionary];
    NSString *pk = [self pkFromIGUser:user];
    if (pk.length)
        info[@"pk"] = pk;

    id username = SPKObjectForSelector(user, @"username");
    if ([username isKindOfClass:[NSString class]] && [(NSString *)username length])
        info[@"username"] = username;

    id fullName = SPKObjectForSelector(user, @"fullName");
    if (![fullName isKindOfClass:[NSString class]] || ![(NSString *)fullName length])
        fullName = SPKObjectForSelector(user, @"full_name");
    if ([fullName isKindOfClass:[NSString class]] && [(NSString *)fullName length])
        info[@"full_name"] = fullName;

    NSURL *picURL = [self getBestProfilePictureURLForUser:user];
    if (picURL.absoluteString.length)
        info[@"profile_pic_url"] = picURL.absoluteString;

    return info.count ? info : nil;
}

+ (void)cleanCache {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSError *> *deletionErrors = [NSMutableArray array];

    // Temp folder
    // * disabled bc app crashed trying to delete certain files inside it
    // todo: remove the above disclaimer if this new code doesn't cause crashing
    NSArray *tempFolderContents = [fileManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:NSTemporaryDirectory()] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];

    for (NSURL *fileURL in tempFolderContents) {
        NSError *cacheItemDeletionError;
        [fileManager removeItemAtURL:fileURL error:&cacheItemDeletionError];

        if (cacheItemDeletionError)
            [deletionErrors addObject:cacheItemDeletionError];
    }

    // Analytics folder
    NSString *analyticsFolder = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"Application Support/com.burbn.instagram/analytics"];
    NSArray *analyticsFolderContents = [fileManager contentsOfDirectoryAtURL:[[NSURL alloc] initFileURLWithPath:analyticsFolder] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];

    for (NSURL *fileURL in analyticsFolderContents) {
        NSError *cacheItemDeletionError;
        [fileManager removeItemAtURL:fileURL error:&cacheItemDeletionError];

        if (cacheItemDeletionError)
            [deletionErrors addObject:cacheItemDeletionError];
    }

    // Caches folder
    NSString *cachesFolder = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"Caches"];
    NSArray *cachesFolderContents = [fileManager contentsOfDirectoryAtURL:[[NSURL alloc] initFileURLWithPath:cachesFolder] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];

    for (NSURL *fileURL in cachesFolderContents) {
        NSError *cacheItemDeletionError;
        [fileManager removeItemAtURL:fileURL error:&cacheItemDeletionError];

        if (cacheItemDeletionError)
            [deletionErrors addObject:cacheItemDeletionError];
    }

    NSURL *previewCacheURL = [[[SPKMediaCacheManager sharedManager] valueForKey:@"cacheRootURL"] copy];
    if (previewCacheURL) {
        NSError *previewCacheDeletionError = nil;
        [fileManager removeItemAtURL:previewCacheURL error:&previewCacheDeletionError];
        if (previewCacheDeletionError)
            [deletionErrors addObject:previewCacheDeletionError];
    }

    // Log errors
    if (deletionErrors.count > 1) {

        for (NSError *error in deletionErrors) {
            SPKLog(@"General", @"[Sparkle] File Deletion Error: %@", error);
        }
    }

    [SPKUtils markCacheClearedNow];
}

+ (unsigned long long)cleanCacheReturningFreedBytes {
    unsigned long long bytesBefore = [self cacheSizeBytes];
    [self cleanCache];
    unsigned long long bytesAfter = [self cacheSizeBytes];
    return bytesBefore > bytesAfter ? bytesBefore - bytesAfter : 0;
}

+ (unsigned long long)cacheSizeBytes {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *libraryFolder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSArray<NSURL *> *folders = @[
        [NSURL fileURLWithPath:NSTemporaryDirectory()
                   isDirectory:YES],
        [NSURL fileURLWithPath:[libraryFolder stringByAppendingPathComponent:@"Application Support/com.burbn.instagram/analytics"]
                   isDirectory:YES],
        [NSURL fileURLWithPath:[libraryFolder stringByAppendingPathComponent:@"Caches"]
                   isDirectory:YES]
    ];
    NSArray<NSURLResourceKey> *resourceKeys = @[ NSURLIsRegularFileKey, NSURLFileSizeKey ];
    unsigned long long totalBytes = 0;

    for (NSURL *folderURL in folders) {
        NSArray<NSURL *> *folderContents = [fileManager contentsOfDirectoryAtURL:folderURL
                                                      includingPropertiesForKeys:resourceKeys
                                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                           error:nil];
        for (NSURL *itemURL in folderContents) {
            NSDictionary<NSURLResourceKey, id> *values = [itemURL resourceValuesForKeys:resourceKeys error:nil];
            if ([values[NSURLIsRegularFileKey] boolValue]) {
                totalBytes += [values[NSURLFileSizeKey] unsignedLongLongValue];
            }

            NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:itemURL
                                                           includingPropertiesForKeys:resourceKeys
                                                                              options:0
                                                                         errorHandler:nil];
            for (NSURL *fileURL in enumerator) {
                values = [fileURL resourceValuesForKeys:resourceKeys error:nil];
                if ([values[NSURLIsRegularFileKey] boolValue]) {
                    totalBytes += [values[NSURLFileSizeKey] unsignedLongLongValue];
                }
            }
        }
    }

    return totalBytes;
}

+ (NSString *)formattedCacheSize {
    return [NSByteCountFormatter stringFromByteCount:(long long)[self cacheSizeBytes]
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

+ (NSLocale *)spk_activeFormattingLocale {
    NSString *override = [SPKStrings languageOverride];
    if (override.length > 0) {
        return [NSLocale localeWithLocaleIdentifier:[SPKStrings activeLanguage]];
    }

    NSString *active = [SPKStrings activeLanguage];
    NSMutableOrderedSet<NSString *> *preferences = [NSMutableOrderedSet orderedSet];
    [preferences addObjectsFromArray:NSBundle.mainBundle.preferredLocalizations ?: @[]];
    [preferences addObjectsFromArray:NSLocale.preferredLanguages ?: @[]];
    for (NSString *identifier in preferences) {
        NSString *match = [SPKStrings matchAvailable:identifier];
        if ([match isEqualToString:active]) {
            return [NSLocale localeWithLocaleIdentifier:identifier];
        }
    }
    return [NSLocale localeWithLocaleIdentifier:active.length > 0 ? active : @"en"];
}

+ (nullable NSString *)spk_stringFromDate:(nullable NSDate *)date template:(NSString *)template {
    if (!date || template.length == 0)
        return nil;
    NSLocale *locale = [self spk_activeFormattingLocale];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = locale;
    formatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:template options:0 locale:locale];
    return [formatter stringFromDate:date];
}

+ (NSString *)spk_timeSkeleton {
    NSString *devicePattern = [NSDateFormatter dateFormatFromTemplate:@"jmm"
                                                              options:0
                                                               locale:NSLocale.currentLocale];
    BOOL uses24HourClock = devicePattern.length == 0 || [devicePattern rangeOfString:@"a"].location == NSNotFound;
    return uses24HourClock ? @"HHmm" : @"hmm";
}

+ (nullable NSString *)spk_formattedTime:(nullable NSDate *)date {
    return [self spk_stringFromDate:date template:[self spk_timeSkeleton]];
}

+ (nullable NSString *)spk_formattedDate:(nullable NSDate *)date includingYear:(BOOL)includeYear {
    return [self spk_stringFromDate:date template:(includeYear ? @"yMMMd" : @"MMMd")];
}

+ (nullable NSString *)spk_formattedDateTime:(nullable NSDate *)date includingYear:(BOOL)includeYear {
    NSString *dateSkeleton = includeYear ? @"yMMMd" : @"MMMd";
    return [self spk_stringFromDate:date
                           template:[dateSkeleton stringByAppendingString:[self spk_timeSkeleton]]];
}

static double SPKTimestampFromValue(id value) {
    if (!value || [value isKindOfClass:[NSNull class]])
        return 0.0;
    if ([value isKindOfClass:[NSDate class]])
        return [(NSDate *)value timeIntervalSince1970];

    double raw = 0.0;
    if ([value respondsToSelector:@selector(doubleValue)]) {
        raw = [value doubleValue];
    }
    if (raw <= 0.0)
        return 0.0;
    if (raw > 1e15)
        raw /= 1000000.0;
    else if (raw > 1e12)
        raw /= 1000.0;
    return raw;
}

static NSDate *SPKDateFromTimestampValue(id value) {
    NSTimeInterval timestamp = SPKTimestampFromValue(value);
    if (timestamp <= 0.0)
        return nil;
    return [NSDate dateWithTimeIntervalSince1970:timestamp];
}

// Guard for the loosely-named keys below (`timestamp`, `sentAt`, ...): those names
// are also used for playback positions, durations and cache ages, which decode into
// absurd dates. Anything outside "Instagram existed and it isn't tomorrow" is not a
// posted date.
static BOOL SPKDateIsPlausiblePostedDate(NSDate *date) {
    if (!date)
        return NO;
    NSTimeInterval t = date.timeIntervalSince1970;
    return t > 1262304000.0 /* 2010-01-01 */ && t < [NSDate date].timeIntervalSince1970 + 86400.0;
}

static id SPKFieldCacheValue(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    id fieldCache = SPKKVCObject(target, @"_fieldCache");
    if ([fieldCache isKindOfClass:[NSDictionary class]]) {
        return fieldCache[key];
    }
    return nil;
}

static NSDate *SPKRecursiveDateForKeys(id target, NSArray<NSString *> *keys, NSInteger depth) {
    if (!target || depth > 3)
        return nil;

    for (NSString *key in keys) {
        id value = SPKObjectForSelector(target, key);
        if (!value)
            value = SPKKVCObject(target, key);
        if (!value)
            value = SPKFieldCacheValue(target, key);
        NSDate *date = SPKDateFromTimestampValue(value);
        if (SPKDateIsPlausiblePostedDate(date))
            return date;
    }

    // `message` / `metadata` / `visualMediaInfo` reach the DM envelope: a direct
    // story reply or view-once visual message (IGDirectVisualMessage) carries no
    // date of its own, only its IGDirectUIMessage envelope does.
    for (NSString *selectorName in @[ @"media", @"item", @"storyItem", @"visualMessage", @"explorePostInFeed", @"rootItem", @"clipsItem", @"clipsMedia", @"post", @"message", @"metadata", @"visualMediaInfo" ]) {
        id nested = SPKObjectForSelector(target, selectorName);
        if (!nested)
            nested = SPKKVCObject(target, selectorName);
        if (!nested || nested == target)
            continue;
        NSDate *date = SPKRecursiveDateForKeys(nested, keys, depth + 1);
        if (date)
            return date;
    }

    return nil;
}

// Does this key name look like it holds a send/post time? Used both to rank the
// known-key list and to drive the last-resort property scan below.
static BOOL SPKKeyNameLooksLikePostedDate(NSString *name) {
    if (name.length == 0)
        return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *needle in @[ @"timestamp", @"takenat", @"sentdate", @"senttime", @"sentat", @"senddate", @"createdat", @"createdtime", @"createddate", @"publishtime", @"publishedtime", @"uploadtime" ]) {
        if ([lower containsString:needle])
            return YES;
    }
    return NO;
}

// Last resort for objects whose date field we don't know by name — notably IG's
// devirtualized value objects (IGDirectUIMessage and friends), whose fields are
// generated per build and change names between IG versions. Only object/number
// properties declared by the class itself are read, and every candidate still has
// to pass the plausibility guard, so a stray "timestamp" duration can't win.
static NSDate *SPKScanObjectForPostedDate(id target, NSInteger depth) {
    if (!target || depth > 2)
        return nil;

    id fieldCache = SPKKVCObject(target, @"_fieldCache");
    if ([fieldCache isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)fieldCache) {
            if (![key isKindOfClass:[NSString class]] || !SPKKeyNameLooksLikePostedDate(key))
                continue;
            NSDate *date = SPKDateFromTimestampValue(((NSDictionary *)fieldCache)[key]);
            if (SPKDateIsPlausiblePostedDate(date))
                return date;
        }
    }

    for (Class cls = object_getClass(target); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        NSDate *found = nil;
        for (unsigned int i = 0; i < count && !found; i++) {
            NSString *name = @(property_getName(properties[i]));
            if (!SPKKeyNameLooksLikePostedDate(name))
                continue;

            // Object, integer and floating-point properties only: reading a struct
            // or C-pointer getter through KVC/objc_msgSend would misinterpret it.
            char *type = property_copyAttributeValue(properties[i], "T");
            BOOL readable = type && (type[0] == '@' || type[0] == 'q' || type[0] == 'Q' ||
                                     type[0] == 'i' || type[0] == 'I' || type[0] == 'l' ||
                                     type[0] == 'L' || type[0] == 'd' || type[0] == 'f');
            free(type);
            if (!readable)
                continue;

            id value = SPKKVCObject(target, name);
            NSDate *date = SPKDateFromTimestampValue(value);
            if (SPKDateIsPlausiblePostedDate(date))
                found = date;
        }
        free(properties);
        if (found)
            return found;
    }

    // The interesting object is often not the one handed to us: IGDirectUIMessage
    // declares no properties at all, and the date sits on its `metadata`.
    for (NSString *selectorName in @[ @"message", @"metadata", @"visualMediaInfo", @"media", @"item" ]) {
        id nested = SPKObjectForSelector(target, selectorName) ?: SPKKVCObject(target, selectorName);
        if (!nested || nested == target)
            continue;
        NSDate *date = SPKScanObjectForPostedDate(nested, depth + 1);
        if (date)
            return date;
    }

    return nil;
}

+ (nullable NSDate *)postedDateFromMediaObject:(nullable id)media {
    if (!media)
        return nil;

    id backingMedia = SPKObjectForSelector(media, @"backingMedia");
    if (!backingMedia)
        backingMedia = SPKKVCObject(media, @"backingMedia");
    if (backingMedia && backingMedia != media)
        media = backingMedia;

    NSDate *date = SPKRecursiveDateForKeys(media, @[
        @"taken_at", @"takenAt", @"takenAtDate", @"device_timestamp", @"deviceTimestamp",
        @"created_at", @"createdAt", @"upload_time", @"uploadTime", @"published_time", @"publishedTime",
        // DM envelopes: the "posted" date of a story reply / visual message is when it
        // was sent. `sentDate` is the live one on IG 440 — IGDirectVisualMessage.message
        // (IGDirectUIMessage) declares nothing itself, its `.metadata`
        // (IGDirectUIMessageMetadata) holds the NSDate. `timestamp` covers
        // IGDirectAggregatedMedia in the aggregated viewer.
        @"sentDate", @"timestamp", @"timestampInMicroseconds", @"timestampUs", @"timestampMs", @"timestampInMs",
        @"timestampSeconds", @"timestampInSec", @"serverTimestamp", @"sentAt", @"sentTime"
    ],
                                           0);
    if (date)
        return date;

    return SPKScanObjectForPostedDate(media, 0);
}

+ (nullable NSString *)spk_formattedDateHeader:(nullable NSDate *)date {
    return [self spk_formattedDateTime:date includingYear:YES];
}


+ (NSString *)cacheAutoClearMode {
    NSString *mode = [SPKUtils getStringPref:kSPKCacheAutoClearModeKey];
    return mode.length > 0 ? mode : @"never";
}

+ (BOOL)shouldAutomaticallyClearCacheNow {
    NSString *mode = [self cacheAutoClearMode];
    if ([mode isEqualToString:@"never"])
        return NO;
    if ([mode isEqualToString:@"always"])
        return YES;

    NSDate *lastClearedAt = [[NSUserDefaults standardUserDefaults] objectForKey:kSPKCacheLastClearedAtKey];
    if (![lastClearedAt isKindOfClass:[NSDate class]])
        return YES;

    NSTimeInterval interval = 0.0;
    if ([mode isEqualToString:@"daily"])
        interval = 24.0 * 60.0 * 60.0;
    else if ([mode isEqualToString:@"weekly"])
        interval = 7.0 * 24.0 * 60.0 * 60.0;
    else if ([mode isEqualToString:@"monthly"])
        interval = 30.0 * 24.0 * 60.0 * 60.0;
    else
        return NO;

    return [[NSDate date] timeIntervalSinceDate:lastClearedAt] >= interval;
}

+ (void)markCacheClearedNow {
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kSPKCacheLastClearedAtKey];
}

+ (void)evaluateAutomaticCacheClearIfNeeded {
    if (![self shouldAutomaticallyClearCacheNow])
        return;
    SPKLog(@"General", @"[Sparkle] Automatically clearing cache...");
    [self cleanCache];
}

// MARK: Display View Controllers
+ (void)showShareVC:(id)item {
    UIActivityViewController *acVC = [[UIActivityViewController alloc] initWithActivityItems:@[ item ] applicationActivities:nil];
    if (is_iPad()) {
        acVC.popoverPresentationController.sourceView = topMostController().view;
        acVC.popoverPresentationController.sourceRect = CGRectMake(topMostController().view.bounds.size.width / 2.0, topMostController().view.bounds.size.height / 2.0, 1.0, 1.0);
    }
    [topMostController() presentViewController:acVC animated:true completion:nil];
}
+ (void)showSettingsVC:(UIWindow *)window {
    UIViewController *rootController = [window rootViewController];
    SPKPresentSettingsAfterUnlock(rootController, ^{
        SPKSettingsViewController *settingsViewController = [SPKSettingsViewController new];
        UINavigationController *navigationController = [[SPKSettingsNavigationController alloc] initWithRootViewController:settingsViewController];
        navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
        [rootController presentViewController:navigationController animated:YES completion:nil];
    });
}

+ (void)showSettingsForTopicTitle:(NSString *)title {
    NSArray *rootSections = [SPKTweakSettings sections];
    SPKSetting *matchedRow = nil;
    for (NSDictionary *section in rootSections) {
        NSArray *rows = section[@"rows"];
        for (SPKSetting *row in rows) {
            if (![row isKindOfClass:[SPKSetting class]])
                continue;
            if ([row.title isEqualToString:title]) {
                matchedRow = row;
                break;
            }
        }
        if (matchedRow)
            break;
    }

    UIViewController *settingsViewController = nil;
    if (matchedRow) {
        if (matchedRow.navViewController) {
            settingsViewController = matchedRow.navViewController;
        } else if (matchedRow.navSections.count > 0) {
            settingsViewController = [[SPKSettingsViewController alloc] initWithTitle:title sections:matchedRow.navSections reduceMargin:NO];
            settingsViewController.title = title;
        }
    }

    if (!settingsViewController) {
        settingsViewController = [SPKSettingsViewController new];
    }

    UIViewController *presenter = topMostController();
    SPKPresentSettingsAfterUnlock(presenter, ^{
        UINavigationController *navigationController = [[SPKSettingsNavigationController alloc] initWithRootViewController:settingsViewController];
        navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
        UIUserInterfaceStyle interfaceStyle = presenter.view.window.traitCollection.userInterfaceStyle;
        if (interfaceStyle == UIUserInterfaceStyleUnspecified) {
            interfaceStyle = presenter.traitCollection.userInterfaceStyle;
        }
        if (interfaceStyle != UIUserInterfaceStyleUnspecified) {
            navigationController.overrideUserInterfaceStyle = interfaceStyle;
            settingsViewController.overrideUserInterfaceStyle = interfaceStyle;
        }
        UISheetPresentationController *sheet = navigationController.sheetPresentationController;
        sheet.detents = @[
            [UISheetPresentationControllerDetent mediumDetent],
            [UISheetPresentationControllerDetent largeDetent]
        ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;

        [presenter presentViewController:navigationController animated:YES completion:nil];
    });
}

+ (void)presentViewControllerInSheet:(UIViewController *)vc {
    if (!vc)
        return;
    UIViewController *presenter = topMostController();
    SPKPresentSettingsAfterUnlock(presenter, ^{
        UINavigationController *navigationController = [[SPKSettingsNavigationController alloc] initWithRootViewController:vc];
        navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
        UIUserInterfaceStyle interfaceStyle = presenter.view.window.traitCollection.userInterfaceStyle;
        if (interfaceStyle == UIUserInterfaceStyleUnspecified) {
            interfaceStyle = presenter.traitCollection.userInterfaceStyle;
        }
        if (interfaceStyle != UIUserInterfaceStyleUnspecified) {
            navigationController.overrideUserInterfaceStyle = interfaceStyle;
            vc.overrideUserInterfaceStyle = interfaceStyle;
        }
        UISheetPresentationController *sheet = navigationController.sheetPresentationController;
        sheet.detents = @[
            [UISheetPresentationControllerDetent mediumDetent],
            [UISheetPresentationControllerDetent largeDetent]
        ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;

        [presenter presentViewController:navigationController animated:YES completion:nil];
    });
}

// MARK: Colours
+ (UIColor *)SPKColor_InstagramBlue {
    return SPKInstagramPrimaryAccentColor();
}

+ (UIColor *)SPKColor_InstagramBackground {
    return SPKDynamicInstagramColor(255.0, 255.0, 255.0, 11.0, 16.0, 20.0);
}

+ (UIColor *)SPKColor_InstagramSecondaryBackground {
    return SPKDynamicInstagramColor(240.0, 241.0, 245.0, 42.0, 48.0, 55.0);
}

+ (UIColor *)SPKColor_InstagramTertiaryBackground {
    return SPKDynamicInstagramColor(232.0, 234.0, 238.0, 58.0, 64.0, 72.0);
}

+ (UIColor *)SPKColor_InstagramGroupedBackground {
    return [self SPKColor_InstagramBackground];
}

+ (UIColor *)SPKColor_InstagramPrimaryText {
    return SPKDynamicInstagramColor(15.0, 20.0, 25.0, 244.0, 247.0, 251.0);
}

+ (UIColor *)SPKColor_InstagramSecondaryText {
    return SPKDynamicInstagramColor(99.0, 108.0, 118.0, 177.0, 185.0, 194.0);
}

+ (UIColor *)SPKColor_InstagramTertiaryText {
    return SPKDynamicInstagramColor(130.0, 138.0, 147.0, 130.0, 138.0, 147.0);
}

+ (UIColor *)SPKColor_InstagramSeparator {
    return SPKDynamicInstagramColor(220.0, 223.0, 228.0, 52.0, 59.0, 67.0);
}

+ (UIColor *)SPKColor_InstagramFavorite {
    return [UIColor colorWithRed:255.0 / 255.0 green:48.0 / 255.0 blue:64.0 / 255.0 alpha:1.0];
}

+ (UIColor *)SPKColor_InstagramDestructive {
    return SPKInstagramDestructiveColor();
}

+ (UIColor *)SPKColor_InstagramPressedBackground {
    return SPKDynamicInstagramColor(232.0, 233.0, 238.0, 51.0, 60.0, 69.0);
}

+ (UIColor *)SPKColor_ListRowPressedOverlay {
    // Subtle text-tinted overlay used by the Sparkle Gallery list rows. Shared by
    // the other custom list UIs (deleted messages, profile analyzer, downloads
    // history) so their tap feedback matches the gallery rather than the heavier
    // settings-cell pressed background.
    return [[SPKUtils SPKColor_InstagramPrimaryText] colorWithAlphaComponent:0.06];
}

+ (UIColor *)SPKColor_SettingsSwitchOnTintForTraitCollection:(UITraitCollection *)traitCollection {
    BOOL isDark = traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return isDark ? UIColor.whiteColor : UIColor.blackColor;
}

+ (UIColor *)SPKColor_SettingsSwitchThumbTintForTraitCollection:(UITraitCollection *)traitCollection {
    BOOL isDark = traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return isDark ? UIColor.blackColor : UIColor.whiteColor;
}

// MARK: Errors
+ (NSError *)errorWithDescription:(NSString *)errorDesc {
    return [self errorWithDescription:errorDesc code:1];
}
+ (NSError *)errorWithDescription:(NSString *)errorDesc code:(NSInteger)errorCode {
    NSError *error = [NSError errorWithDomain:@"com.sparkle.sparkle" code:errorCode userInfo:@{NSLocalizedDescriptionKey : errorDesc}];
    return error;
}
+ (BOOL)openURL:(NSURL *)url {
    if (!url)
        return NO;
    UIApplication *application = [UIApplication sharedApplication];
    // canOpenURL: answers NO for any scheme the host app has not declared in
    // LSApplicationQueriesSchemes even when openURL: would still succeed, so it
    // is only a safe pre-check for web URLs. Custom schemes go straight through
    // and report their real outcome via the completion handler.
    NSString *scheme = url.scheme.lowercaseString;
    BOOL isWebURL = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    if (isWebURL && ![application canOpenURL:url]) {
        SPKLog(@"General", @"External URL rejected by UIApplication host=%@", url.host ?: @"(none)");
        return NO;
    }
    [application openURL:url options:@{} completionHandler:^(BOOL success) {
        SPKLog(@"General", @"External URL handoff %@ host=%@", success ? @"accepted" : @"failed", url.host ?: @"(none)");
    }];
    return YES;
}

+ (BOOL)openURLThroughApplicationDelegate:(NSURL *)url {
    if (!url)
        return NO;
    UIApplication *application = [UIApplication sharedApplication];
    id<UIApplicationDelegate> delegate = application.delegate;
    if ([delegate respondsToSelector:@selector(application:openURL:options:)]) {
        [delegate application:application openURL:url options:@{}];
        return YES;
    }
    return NO;
}

+ (void)dismissPresentedViewControllers {
    UIViewController *rootVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    rootVC = window.rootViewController;
                    break;
                }
            }
        }
        if (rootVC)
            break;
    }
    if (!rootVC) {
        rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    }
    if (!rootVC)
        return;

    Class galleryManagerClass = NSClassFromString(@"SPKGalleryManager");
    if (galleryManagerClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id manager = [galleryManagerClass performSelector:@selector(sharedManager)];
#pragma clang diagnostic pop
        if (manager) {
            BOOL isLockEnabled = NO;
            @try {
                isLockEnabled = [[manager valueForKey:@"isLockEnabled"] boolValue];
            } @catch (NSException *exception) {
            }
            if (isLockEnabled) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [manager performSelector:@selector(lockGallery)];
#pragma clang diagnostic pop
            }
        }
    }

    if (rootVC.presentedViewController) {
        [rootVC dismissViewControllerAnimated:YES completion:nil];
    }
}

+ (id)spk_createRefWithTarget:(id)target selector:(SEL)sel argument:(id)arg {
    if (!target || !sel || !arg || ![target respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv setArgument:&arg atIndex:2];
        [inv invoke];
        void *rawPtr = NULL;
        [inv getReturnValue:&rawPtr];
        if (!rawPtr) return nil;
        return (__bridge id)rawPtr;
    } @catch (NSException *e) {
        return nil;
    }
}

// IGUserReference is an FB sum type with no ObjC constructor, so the only route
// is ivar injection. _subtype is the case index over the ivar declaration order
// -- _usernameFuture(0), _objectFuture(1), _user(2), _fbidFuture(3) -- so the
// "we have a real IGUser" case is 2. Device-verified on IG 440: at any other
// value -pk / -username / -user all read back nil and IG ends up fetching
// users/null/info/, which is the "User not found" toast.
static const unsigned long long kSPKUserReferenceSubtypeUser = 2;

+ (id)spk_userReferenceForUser:(id)user username:(NSString *)username pk:(NSString *)pk {
    Class userRefClass = objc_getClass("IGUserReference");
    if (!userRefClass || !user)
        return nil;

    Ivar userIvar = class_getInstanceVariable(userRefClass, "_user");
    Ivar subtypeIvar = class_getInstanceVariable(userRefClass, "_subtype");
    if (!userIvar || !subtypeIvar) {
        SPKLog(@"OpenProfile", @"IGUserReference ivars missing (_user=%p _subtype=%p)", userIvar, subtypeIvar);
        return nil;
    }

    id ref = nil;
    @try {
        ref = [[userRefClass alloc] init];
    } @catch (NSException *e) {
        SPKLog(@"OpenProfile", @"IGUserReference init threw: %@", e);
        return nil;
    }
    if (!ref)
        return nil;

    object_setIvar(ref, userIvar, user);
    *(unsigned long long *)((char *)(__bridge void *)ref + ivar_getOffset(subtypeIvar)) = kSPKUserReferenceSubtypeUser;

    // The reference is worthless if the case did not take, and handing a blank
    // one to IGProfileConfig is what produces the "Something went wrong" sheet.
    NSString *readBackPK = nil;
    @try {
        if ([ref respondsToSelector:@selector(pk)])
            readBackPK = [ref performSelector:@selector(pk)];
    } @catch (NSException *e) {}
    if (readBackPK.length == 0) {
        SPKLog(@"OpenProfile", @"userRef did not take (pk nil after injection) for pk=%@ username=%@", pk, username);
        return nil;
    }

    SPKLog(@"OpenProfile", @"userRef ok (subtype %llu) pk=%@ username=%@", kSPKUserReferenceSubtypeUser, readBackPK, username);
    return ref;
}

// userWithDict: is an IGUserMap instance method, not an IGUser class method.
// Passing both keys matters: the map merges onto the canonical instance for a
// pk it already knows, but a user IG has never loaded needs the username too.
+ (id)spk_canonicalUserForPK:(NSString *)pk username:(NSString *)username session:(id)session {
    if (pk.length == 0 || !session)
        return nil;

    id userMap = nil;
    @try {
        if ([session respondsToSelector:@selector(userMap)])
            userMap = [session valueForKey:@"userMap"];
        if (!userMap && [session respondsToSelector:@selector(userStore)])
            userMap = [session valueForKey:@"userStore"];
    } @catch (NSException *e) {}
    if (!userMap || ![userMap respondsToSelector:@selector(userWithDict:)])
        return nil;

    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:pk forKey:@"pk"];
    if (username.length > 0)
        dict[@"username"] = username;

    @try {
        return [userMap performSelector:@selector(userWithDict:) withObject:dict];
    } @catch (NSException *e) {
        SPKLog(@"OpenProfile", @"userWithDict: threw: %@", e);
        return nil;
    }
}

// IGUserReference -> IGProfileConfig -> IGProfileViewController. Every step is
// guarded: IG moves these between versions, and a nil here just means we fall
// back to the URL handler rather than crash.
+ (UIViewController *)spk_nativeProfileViewControllerForUser:(id)user session:(id)session {
    Class configClass = objc_getClass("IGProfileConfig");
    Class profileVCClass = objc_getClass("IGProfileViewController");
    if (!user || !session || !configClass || !profileVCClass)
        return nil;

    @try {
        id ref = [self spk_userReferenceForUser:user username:nil pk:nil];
        if (!ref)
            return nil;

        id config = nil;
        if ([configClass instancesRespondToSelector:@selector(initWithUserReference:userSession:)])
            config = [[configClass alloc] initWithUserReference:ref userSession:session];
        else if ([configClass instancesRespondToSelector:@selector(initWithUserReference:userSession:previousAnalyticsModule:)])
            config = [[configClass alloc] initWithUserReference:ref userSession:session previousAnalyticsModule:@"profile"];
        if (!config)
            return nil;

        if (![profileVCClass instancesRespondToSelector:@selector(initWithConfiguration:accountSwitcherPresenter:isMainProfileSurface:)])
            return nil;
        id vc = [[profileVCClass alloc] initWithConfiguration:config accountSwitcherPresenter:nil isMainProfileSurface:NO];
        return [vc isKindOfClass:[UIViewController class]] ? vc : nil;
    } @catch (NSException *e) {
        SPKLog(@"OpenProfile", @"native profile VC threw: %@", e);
        return nil;
    }
}

// The profile is presented off a thin {pk, username} user, so the header starts
// sparse. Refetching and re-feeding the map updates the same canonical instance
// in place, keeping the network round trip off the critical path.
+ (BOOL)pushViewControllerOnNativeHost:(UIViewController *)viewController
                    fromViewController:(UIViewController *)presentingVC {
    return [self pushViewControllerOnNativeHost:viewController fromViewController:presentingVC onDismiss:nil];
}

+ (BOOL)pushViewControllerOnNativeHost:(UIViewController *)viewController
                    fromViewController:(UIViewController *)presentingVC
                             onDismiss:(void (^)(void))onDismiss {
    if (!viewController || !presentingVC)
        return NO;

    Class igNavClass = SPKProfilePushNavigationClass();
    if (!igNavClass || ![igNavClass instancesRespondToSelector:@selector(initWithRootViewController:)])
        return NO;

    SPKProfilePushHostViewController *host = [SPKProfilePushHostViewController new];
    host.onDismiss = onDismiss;
    UINavigationController *nav = [[igNavClass alloc] initWithRootViewController:host];
    if (!nav)
        return NO;

    // The subclass pins this; assigning it too keeps the intent readable
    // and covers any path that reads the stored value directly.
    nav.modalPresentationStyle = UIModalPresentationOverFullScreen;
    nav.view.backgroundColor = UIColor.clearColor;
    nav.view.opaque = NO;
    // Presented without animation, and invisible when it lands: the host
    // draws nothing and the screen behind is left in place. The push that
    // follows is the whole transition, and it is IG's own.
    [presentingVC presentViewController:nav
                              animated:NO
                            completion:^{
                                host.didPush = YES;
                                [nav pushViewController:viewController animated:YES];
                            }];
    return YES;
}

+ (void)spk_hydrateCanonicalUserForPK:(NSString *)pk session:(id)session {
    if (pk.length == 0 || !session)
        return;
    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/%@/info/", pk]
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
                                    NSDictionary *user = [response[@"user"] isKindOfClass:[NSDictionary class]] ? response[@"user"] : nil;
                                    if (!user)
                                        return;
                                    NSMutableDictionary *dict = [user mutableCopy];
                                    dict[@"pk"] = pk;
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        id userMap = nil;
                                        @try {
                                            if ([session respondsToSelector:@selector(userMap)])
                                                userMap = [session valueForKey:@"userMap"];
                                        } @catch (NSException *e) {}
                                        if (!userMap || ![userMap respondsToSelector:@selector(userWithDict:)])
                                            return;
                                        @try {
                                            [userMap performSelector:@selector(userWithDict:) withObject:dict];
                                        } @catch (NSException *e) {}
                                    });
                                }];
}

// Target for the injected back button. The class object is a stable target, so
// nothing has to be kept alive alongside the bar button item.
+ (void)spk_closeProfileSheet:(id)sender {
    UIViewController *top = topMostController();
    [top dismissViewControllerAnimated:YES completion:nil];
}

+ (NSString *)sanitizedInstagramUsername:(NSString *)rawUsername {
    if (!rawUsername || ![rawUsername isKindOfClass:[NSString class]])
        return nil;
    NSString *clean = [[rawUsername stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    while ([clean hasPrefix:@"@"]) {
        clean = [clean substringFromIndex:1];
    }
    if (clean.length == 0 || clean.length > 30)
        return nil;

    static NSSet<NSString *> *dummyUsernames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dummyUsernames = [NSSet setWithArray:@[
            @"audio", @"audio_page", @"thumbnail", @"unknown", @"null", @"nil", @"undefined",
            @"none", @"file details", @"original audio", @"system", @"instagram"
        ]];
    });

    if ([dummyUsernames containsObject:clean])
        return nil;

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._"];
    if ([[clean stringByTrimmingCharactersInSet:allowed] length] > 0)
        return nil;

    return clean;
}

// Memo of username -> pk for the openInstagramProfile... path. Main thread only,
// which every caller already is by the time it is consulted. Deliberately not
// persisted: it is a within-session shortcut, not a source of truth.
static NSMutableDictionary<NSString *, NSString *> *SPKUsernamePKCache(void) {
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *SPKResolvedPKForUsername(NSString *username) {
    return username.length ? SPKUsernamePKCache()[username.lowercaseString] : nil;
}

static void SPKSetResolvedPKForUsername(NSString *username, NSString *pk) {
    if (username.length == 0 || pk.length == 0)
        return;
    SPKUsernamePKCache()[username.lowercaseString] = pk;
}

+ (void)resolvePKForUsername:(NSString *)username
                  completion:(void (^)(NSString *_Nullable pk, NSString *_Nullable fullName))completion {
    NSString *clean = [self sanitizedInstagramUsername:username] ?: username;
    if (clean.length == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }

    NSString *memoised = SPKResolvedPKForUsername(clean);
    if (memoised.length > 0) {
        if (completion)
            completion(memoised, nil);
        return;
    }

    // Nothing changes on screen until this lands, so say that something is
    // happening. Transient, like the 4K candidate fetch: preparatory work before
    // the real flow, cleared on both outcomes.
    [[SPKNotificationCenter shared] beginTransientProgressWithTitle:SPKL(@"GENERAL_UTILS_OPENING_PROFILE_TEXT") onCancel:nil];
    [SPKInstagramAPI resolveUserForUsername:clean
                                 completion:^(NSDictionary *userDict, NSError *error) {
                                     NSString *resolvedPK = [userDict[@"pk"] description];
                                     NSString *resolvedName = [userDict[@"full_name"] description];
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         [[SPKNotificationCenter shared] dismissTransientProgressPill];
                                         if (resolvedPK.length > 0)
                                             SPKSetResolvedPKForUsername(clean, resolvedPK);
                                         if (completion)
                                             completion(resolvedPK.length > 0 ? resolvedPK : nil,
                                                        resolvedName.length > 0 ? resolvedName : nil);
                                     });
                                 }];
}

+ (BOOL)openInstagramProfileForUser:(id)user pk:(NSString *)pk username:(NSString *)username fromViewController:(UIViewController *)presentingVC {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self openInstagramProfileForUser:user pk:pk username:username fromViewController:presentingVC];
        });
        return result;
    }

    username = [self sanitizedInstagramUsername:username];

    if (!user && pk.length == 0 && username.length == 0)
        return NO;

    id session = [self activeUserSession];
    if (!session) {
        SPKLog(@"OpenProfile", @"No activeUserSession found!");
        return NO;
    }

    // A pk is mandatory from here on -- everything downstream keys on it, and a
    // user object without one is the shell that makes IG fetch users/null/info/.
    if (pk.length == 0 && user)
        pk = [self pkFromIGUser:user];

    // Username only: resolve to a pk first, then re-enter. The URL handler is
    // the last resort, not a co-equal path, because it re-routes the whole app.
    //
    // Nothing appears on screen until that lookup returns, so a caller holding a
    // pk should always pass it. This memo makes the cost fall on the first open
    // of a given username only; usernames are stable enough for a session, and a
    // stale one resolves to a pk whose profile then 404s the same way the fresh
    // lookup would have.
    if (pk.length == 0 && username.length > 0)
        pk = SPKResolvedPKForUsername(username);

    if (pk.length == 0) {
        if (username.length == 0)
            return NO;
        NSString *resolvedUsername = username;
        UIViewController *weakTarget = presentingVC;
        [self resolvePKForUsername:resolvedUsername
                        completion:^(NSString *resolvedPK, __unused NSString *fullName) {
                            if (resolvedPK.length > 0) {
                                [SPKUtils openInstagramProfileForUser:nil pk:resolvedPK username:resolvedUsername fromViewController:weakTarget];
                            } else {
                                SPKLog(@"OpenProfile", @"could not resolve pk for %@, falling back to URL handler", resolvedUsername);
                                [SPKUtils spk_openProfileViaURLHandlerForUsername:resolvedUsername session:session];
                            }
                        }];
        return YES;
    }

    if (!user)
        user = spkDirectUserResolverUserForPK(pk);
    if (!user)
        user = [self spk_canonicalUserForPK:pk username:username session:session];

    UIViewController *targetVC = presentingVC ?: topMostController();
    UIViewController *profileVC = [self spk_nativeProfileViewControllerForUser:user session:session];
    if (!profileVC) {
        SPKLog(@"OpenProfile", @"native profile VC unavailable for pk=%@, falling back to URL handler", pk);
        return [self spk_openProfileViaURLHandlerForUsername:username session:session];
    }

    if (!targetVC)
        return NO;

    // Never pushed onto the CALLER's stack: a host like the story mentions sheet
    // is sized to its own content, so a pushed profile inherits a detent-height
    // viewport and is unusable. Instead the profile is pushed onto a stack of our
    // own, presented full screen.
    //
    // That stack is a real IGNavigationController, and the profile is a real
    // push onto it, because IG's navigation feel is not UIKit's and cannot be
    // reproduced from outside: IGNavigationController owns an
    // IGNavigationControllerTransitionHandler which vends
    // IGNavigationControllerInteractiveAnimator (a UIViewPropertyAnimator driven
    // by the server-configured spring in _IGNavigationControllerDefaultExperimentTraits)
    // and installs IGTransitionAnimationPanInteractiveDriver -- the full-screen
    // directional pan that is why IG pops from anywhere, not just the bezel. All
    // of that engages ONLY for a push/pop on the stack. Presenting the profile as
    // the stack's root, as we used to, ran none of it, which is exactly why the
    // hand-rolled imitation never felt right.
    // Resuming falls to the presenter: a player underneath keeps running audio
    // while the profile is up, and gets no appearance callback when it closes.
    void (^onDismiss)(void) = nil;
    if ([targetVC respondsToSelector:@selector(resumeAfterNavigationBack)]) {
        __weak UIViewController *weakTarget = targetVC;
        onDismiss = ^{
            [(id)weakTarget resumeAfterNavigationBack];
        };
    }
    if ([self pushViewControllerOnNativeHost:profileVC fromViewController:targetVC onDismiss:onDismiss]) {
        [self spk_hydrateCanonicalUserForPK:pk session:session];
        SPKLog(@"OpenProfile", @"pushed native profile for pk=%@ username=%@ from %@", pk, username, targetVC);
        return YES;
    }

    // Fallback for a build where IGNavigationController is missing or refuses to
    // construct: present the profile as the root of a plain stack and imitate the
    // push with SPKProfileSlideTransition. Visibly not the real thing, but it
    // still opens the profile rather than dropping the tap.
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:profileVC];
    if (!nav)
        return NO;

    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    SPKProfileSlideTransition *slide = [SPKProfileSlideTransition new];
    nav.transitioningDelegate = slide;
    // transitioningDelegate is weak; the nav has to own the animator.
    objc_setAssociatedObject(nav, @selector(transitioningDelegate), slide, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [slide attachTo:nav];

    // No stack below it here, so there is no real back button to inherit.
    if (!profileVC.navigationItem.leftBarButtonItem && profileVC.navigationItem.leftBarButtonItems.count == 0) {
        profileVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                                                                                      style:UIBarButtonItemStylePlain
                                                                                     target:[SPKUtils class]
                                                                                     action:@selector(spk_closeProfileSheet:)];
    }

    [targetVC presentViewController:nav animated:YES completion:nil];
    [self spk_hydrateCanonicalUserForPK:pk session:session];
    SPKLog(@"OpenProfile", @"presented native profile for pk=%@ username=%@ from %@", pk, username, targetVC);
    return YES;
}

// Last-resort route: hand the username to IG's own URL engine, which resolves
// it server side. It re-routes the app rather than presenting over the current
// stack, so it is only used when the native path could not be built.
+ (BOOL)spk_openProfileViaURLHandlerForUsername:(NSString *)username session:(id)session {
    if (username.length == 0)
        return NO;
    NSURL *profileURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://instagram.com/%@", username]];
    Class urlHandlerClass = objc_getClass("IGURLHandler");
    if (!profileURL || !urlHandlerClass)
        return NO;

    if ([urlHandlerClass respondsToSelector:@selector(openInternalURL:presentationConfig:controller:animated:userSession:annotation:)]) {
        typedef BOOL (*OpenURLFunc)(Class, SEL, id, id, id, BOOL, id, id);
        OpenURLFunc fn = (OpenURLFunc)objc_msgSend;
        if (fn(urlHandlerClass, @selector(openInternalURL:presentationConfig:controller:animated:userSession:annotation:), profileURL, nil, topMostController(), YES, session, nil))
            return YES;
    }
    if ([urlHandlerClass respondsToSelector:@selector(openURL:userSession:completionHandler:)]) {
        [urlHandlerClass openURL:profileURL userSession:session completionHandler:nil];
        return YES;
    }
    return NO;
}

+ (BOOL)openInstagramProfileForUsername:(NSString *)username {
    return [self openInstagramProfileForUsername:username fromViewController:nil];
}

+ (BOOL)openInstagramProfileForUsername:(NSString *)username fromViewController:(UIViewController *)presentingVC {
    return [self openInstagramProfileForUser:nil pk:nil username:username fromViewController:presentingVC];
}

+ (BOOL)openInstagramMediaURL:(NSURL *)url {
    return [self openInstagramMediaURL:url dismissingPresentedViewControllers:YES];
}

+ (BOOL)openInstagramMediaURL:(NSURL *)url dismissingPresentedViewControllers:(BOOL)dismiss {
    if (!url)
        return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    UIApplication *application = [UIApplication sharedApplication];
    id<UIApplicationDelegate> delegate = application.delegate;

    // Callers that intend to keep their own UI on screen (the Gallery redirecting
    // the router's push onto a native host) pass NO. Everything else clears the
    // way first, because the router pushes onto a tab stack that a modal hides.
    if (dismiss)
        [self dismissPresentedViewControllers];

    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
        activity.webpageURL = url;
        SEL continueSelector = @selector(application:continueUserActivity:restorationHandler:);
        if ([delegate respondsToSelector:continueSelector]) {
            BOOL handled = [delegate application:application
                            continueUserActivity:activity
                              restorationHandler:^(__unused NSArray<id<UIUserActivityRestoring>> *restorableObjects){
                              }];
            if (handled)
                return YES;
        }
        if ([self openURLThroughApplicationDelegate:url])
            return YES;
    } else if ([scheme isEqualToString:@"instagram"]) {
        if ([self openURLThroughApplicationDelegate:url])
            return YES;
    }

    return [self openURL:url];
}

// Returns a cleaned canonical Instagram URL, or `nil` when there is nothing to
// sanitize (the input isn't an http/https Instagram URL). Callers MUST treat
// nil as "leave the original untouched": `+URLWithString:` on iOS 17+ leniently
// percent-encodes arbitrary text (captions, etc.) into a URL, so returning that
// input back would mangle plain-text clipboard writes into %20/%E2%80%A2 noise.
+ (NSURL *)sanitizedInstagramShareURL:(NSURL *)url {
    if (!url)
        return nil;
    if (![url isKindOfClass:[NSURL class]])
        return nil;

    if (![url.scheme.lowercaseString isEqualToString:@"http"] && ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        return nil;
    }
    if (!SPKInstagramHostMatchesCanonical(url.host)) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return nil;
    }

    NSArray<NSString *> *rawSegments = [components.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in rawSegments) {
        if (segment.length > 0) {
            [segments addObject:segment];
        }
    }

    NSArray<NSString *> *sanitizedSegments = SPKSanitizedInstagramPathSegments(segments);
    NSString *path = sanitizedSegments.count > 0 ? [@"/" stringByAppendingString:[sanitizedSegments componentsJoinedByString:@"/"]] : @"/";
    if (![path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:@"/"];
    }

    components.scheme = @"https";
    components.host = @"www.instagram.com";
    components.path = path;
    components.queryItems = SPKSanitizedInstagramQueryItems(components.queryItems);
    components.fragment = nil;

    return components.URL ?: url;
}

+ (NSString *)appendImgIndex:(NSInteger)imgIndex toURLString:(NSString *)urlString {
    if (urlString.length == 0 || imgIndex <= 0)
        return urlString;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return urlString;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components)
        return urlString;

    NSMutableArray<NSURLQueryItem *> *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    for (NSURLQueryItem *item in [queryItems copy]) {
        if ([item.name isEqualToString:@"img_index"]) {
            [queryItems removeObject:item];
        }
    }
    [queryItems addObject:[NSURLQueryItem queryItemWithName:@"img_index" value:[NSString stringWithFormat:@"%ld", (long)imgIndex]]];
    components.queryItems = queryItems;
    return components.URL.absoluteString ?: urlString;
}

+ (NSString *)instagramShortcodeForMediaPK:(NSString *)mediaPK {
    if (mediaPK.length == 0)
        return nil;

    // Media pk may arrive as "<pk>" or "<pk>_<userpk>"; only the leading id matters.
    NSString *identifier = [mediaPK componentsSeparatedByString:@"_"].firstObject ?: mediaPK;
    if (identifier.length == 0)
        return nil;
    if ([identifier rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
        return nil;

    unsigned long long value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:identifier];
    if (![scanner scanUnsignedLongLong:&value] || !scanner.isAtEnd || value == 0)
        return nil;

    static NSString *alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSMutableString *shortcode = [NSMutableString string];
    while (value > 0) {
        NSUInteger index = (NSUInteger)(value % 64);
        unichar character = [alphabet characterAtIndex:index];
        [shortcode insertString:[NSString stringWithCharacters:&character length:1] atIndex:0];
        value /= 64;
    }
    return shortcode.length > 0 ? shortcode : nil;
}

+ (BOOL)openPhotosApp {
    NSURL *url = [NSURL URLWithString:@"photos-redirect://"];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        return [self openURL:url];
    }
    return NO;
}

// MARK: Media
+ (NSURL *)getPhotoUrl:(IGPhoto *)photo {
    if (!photo)
        return nil;

    NSURL *photoUrl = SPKHighestQualityURLFromVersions(SPKImageVersionsFromPhoto(photo));
    if (photoUrl)
        return photoUrl;

    if ([photo respondsToSelector:@selector(imageURLForWidth:)]) {
        photoUrl = [photo imageURLForWidth:100000.00];
        if (photoUrl)
            return photoUrl;
    }

    photoUrl = SPKURLFromStringOrURL(SPKObjectForSelector(photo, @"thumbnailURL"));

    return photoUrl;
}
+ (NSURL *)getPhotoUrlForMedia:(IGMedia *)media {
    if (!media)
        return nil;

    IGPhoto *photo = SPKObjectForSelector(media, @"photo");
    if (!photo)
        return nil;

    return [SPKUtils getPhotoUrl:photo];
}
+ (NSURL *)getBestProfilePictureURLForUser:(id)user {
    return SPKHDProfilePicURL(user) ?: SPKThumbProfilePicURL(user);
}
+ (NSURL *)getVideoUrl:(IGVideo *)video {
    if (!video)
        return nil;

    NSURL *videoURL = SPKHighestQualityURLFromVersions(SPKVideoVersionsFromVideo(video));
    if (videoURL)
        return videoURL;

    // The past (pre v398)
    if ([video respondsToSelector:@selector(sortedVideoURLsBySize)]) {
        id sorted = [video sortedVideoURLsBySize];
        videoURL = SPKURLFromVideoURLCollection(sorted);
        if (videoURL)
            return videoURL;
    }

    // The present (post v398)
    if ([video respondsToSelector:@selector(allVideoURLs)]) {
        videoURL = SPKURLFromVideoURLCollection([video allVideoURLs]);
        if (videoURL)
            return videoURL;
    }

    return nil;
}
+ (NSURL *)getVideoUrlForMedia:(IGMedia *)media {
    if (!media)
        return nil;

    IGVideo *video = SPKObjectForSelector(media, @"video");
    if (!video)
        return nil;

    return [SPKUtils getVideoUrl:video];
}

// MARK: View Controller Helpers
+ (UIViewController *)viewControllerForView:(UIView *)view {
    NSString *viewDelegate = @"viewDelegate";
    if ([view respondsToSelector:NSSelectorFromString(viewDelegate)]) {
        return [view valueForKey:viewDelegate];
    }

    return nil;
}

+ (UIViewController *)viewControllerForAncestralView:(UIView *)view {
    NSString *_viewControllerForAncestor = @"_viewControllerForAncestor";
    if ([view respondsToSelector:NSSelectorFromString(_viewControllerForAncestor)]) {
        return [view valueForKey:_viewControllerForAncestor];
    }

    return nil;
}

+ (UIViewController *)nearestViewControllerForView:(UIView *)view {
    return [self viewControllerForView:view] ?: [self viewControllerForAncestralView:view];
}

// Functions

// MARK: Alerts
+ (BOOL)showConfirmation:(void (^)(void))okHandler title:(NSString *)title {
    return [self showConfirmation:okHandler cancelHandler:nil title:title message:nil];
};
+ (BOOL)showConfirmation:(void (^)(void))okHandler title:(NSString *)title message:(NSString *)message {
    return [self showConfirmation:okHandler cancelHandler:nil title:title message:message];
};
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler title:(NSString *)title {
    return [self showConfirmation:okHandler cancelHandler:cancelHandler title:title message:nil];
};
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler title:(NSString *)title message:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                  title:title ?: SPKL(@"GENERAL_UTILS_CONFIRM_ACTION")
                                                message:message ?: SPKL(@"GENERAL_UTILS_CONTINUE_CONFIRMATION_MESSAGE")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:^{
                                                                                  if (cancelHandler)
                                                                                      cancelHandler();
                                                                              }],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CONFIRM")
                                                                                style:SPKIGAlertActionStyleDefault
                                                                              handler:^{
                                                                                  if (okHandler)
                                                                                      okHandler();
                                                                              }],
                                                ]];
    return YES;
};
+ (BOOL)showConfirmation:(void (^)(void))okHandler {
    return [self showConfirmation:okHandler title:nil];
};
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler {
    return [self showConfirmation:okHandler cancelHandler:cancelHandler title:nil];
}
+ (void)showRestartConfirmation {
    [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                  title:SPKL(@"GENERAL_UTILS_RESTART_REQUIRED_TEXT")
                                                message:SPKL(@"GENERAL_UTILS_MUST_RESTART_APP_APPLY_CHANGE_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_LATER")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_RESTART")
                                                                                style:SPKIGAlertActionStyleDefault
                                                                              handler:^{
                                                                                  exit(0);
                                                                              }],
                                                ]];
};

// MARK: Math
+ (NSUInteger)decimalPlacesInDouble:(double)value {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    [formatter setMaximumFractionDigits:15]; // Allow enough digits for double precision
    [formatter setMinimumFractionDigits:0];
    [formatter setDecimalSeparator:@"."]; // Force dot for internal logic, then respect locale for final display if needed

    NSString *stringValue = [formatter stringFromNumber:@(value)];

    // Find decimal separator
    NSRange decimalRange = [stringValue rangeOfString:formatter.decimalSeparator];

    if (decimalRange.location == NSNotFound) {
        return 0;
    } else {
        return stringValue.length - (decimalRange.location + decimalRange.length);
    }
}

// Ivars
+ (NSNumber *)numericValueForObj:(id)obj selectorName:(NSString *)selectorName {
    return SPKNumericValueForSelector(obj, selectorName);
}

+ (id)getIvarForObj:(id)obj name:(const char *)name {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar)
        return nil;

    return object_getIvar(obj, ivar);
}
+ (void)setIvarForObj:(id)obj name:(const char *)name value:(id)value {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar)
        return;

    object_setIvarWithStrongDefault(obj, ivar, value);
}

+ (NSString *)igImageNameForImage:(UIImage *)image {
    if (![image isKindOfClass:UIImage.class])
        return nil;
    // IG tags loaded images with their asset name on the ig_imageName property.
    SEL sel = NSSelectorFromString(@"ig_imageName");
    if (![image respondsToSelector:sel])
        return nil;
    @try {
        id name = [image valueForKey:@"ig_imageName"];
        return [name isKindOfClass:NSString.class] ? name : nil;
    }
    @catch (NSException *exception) {
        return nil;
    }
}

+ (BOOL)control:(UIControl *)control hasTapActionContaining:(NSString *)needle {
    if (![control isKindOfClass:UIControl.class] || needle.length == 0)
        return NO;
    @try {
        for (id target in [control allTargets]) {
            id realTarget = (target == [NSNull null]) ? nil : target;
            NSArray<NSString *> *actions = [control actionsForTarget:realTarget
                                                     forControlEvent:UIControlEventTouchUpInside];
            for (NSString *action in actions) {
                if ([action rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    return YES;
                }
            }
        }
    }
    @catch (NSException *exception) {
    }
    return NO;
}

@end
