#import "../../Utils.h"

#import <objc/message.h>
#import <objc/runtime.h>

// Horizontal swipe to close the comments sheet, driven through Instagram's own
// interactive dismissal so the drag, dimming, commit threshold and spring are
// exactly those of a vertical drag.
//
// How the sheet works: IGDSDefaultPartialModalSheetViewController is its own
// transitioning delegate and interaction controller. Its vertical pan
// (_verticalPanGesture, an IGDirectionalPanGestureRecognizer) targets _didPan:,
// which starts an interactive dismissal on began and scrubs it from per-frame
// translation deltas (translationInView: then setTranslation:(0,0)),
// velocityInView: and state. startInteractiveTransition: only stays interactive
// while _verticalPanGesture is active; for any other gesture it runs a plain
// animated close straight away.
//
// So the swipe gesture is a runtime subclass of IG's directional pan that
// activates horizontally but reports its horizontal travel as a downward drag,
// and it stands in as _verticalPanGesture for the length of one swipe.
//
// A swipe that starts on an Expanded sheet can close it completely: the
// sheet's own skip-partial flag is raised for that swipe, with a dismiss from
// Partial as the fallback when the sheet still settles there.

static char kSPKSwipeCloseCommentsInstalledKey;
static char kSPKSwipeCloseCommentsControllerKey;
static char kSPKSwipeCloseCommentsSignKey;
static char kSPKSwipeCloseCommentsConsumedKey;
static char kSPKSwipeCloseCommentsActiveKey;

static NSString *const kSPKSwipeCloseCommentsDirectionKey = @"general_comments_swipe_close_direction";
static NSString *const kSPKSwipeCloseCommentsDirectionLeft = @"left";
static NSString *const kSPKSwipeCloseCommentsDirectionRight = @"right";
static NSString *const kSPKSwipeCloseCommentsDirectionBoth = @"both";
static NSString *const kSPKSwipeCloseCommentsFullyKey = @"general_comments_swipe_close_fully";

typedef NS_OPTIONS(NSUInteger, SPKSwipeCloseCommentsDirection) {
    SPKSwipeCloseCommentsDirectionLeft = 1 << 0,
    SPKSwipeCloseCommentsDirectionRight = 1 << 1,
};

// IGDirectionalPanGestureRecognizer activation directions. The sheet's own pan
// allows up|down (12) and reports down (8) while dragging toward closed.
static unsigned long long const kSPKDirectionalPanLeft = 1;
static unsigned long long const kSPKDirectionalPanRight = 2;
static unsigned long long const kSPKDirectionalPanDown = 8;

static SPKSwipeCloseCommentsDirection SPKSwipeCloseCommentsDirectionFromPref(void) {
    NSString *value = [SPKUtils getStringPref:kSPKSwipeCloseCommentsDirectionKey];
    if ([value isEqualToString:kSPKSwipeCloseCommentsDirectionLeft]) {
        return SPKSwipeCloseCommentsDirectionLeft;
    }
    if ([value isEqualToString:kSPKSwipeCloseCommentsDirectionRight]) {
        return SPKSwipeCloseCommentsDirectionRight;
    }
    if ([value isEqualToString:kSPKSwipeCloseCommentsDirectionBoth]) {
        return SPKSwipeCloseCommentsDirectionLeft | SPKSwipeCloseCommentsDirectionRight;
    }
    return SPKSwipeCloseCommentsDirectionLeft | SPKSwipeCloseCommentsDirectionRight;
}

static NSString *SPKCommentsSwipeDescribe(id object) {
    if (!object)
        return @"nil";
    return [NSString stringWithFormat:@"%@<%p>", NSStringFromClass([object class]), object];
}

#pragma mark - Sheet detection

static BOOL SPKCommentsSwipeStringLooksCommentRelated(NSString *value) {
    // Messaging nil yields location 0, which would match every untitled sheet.
    return value.length > 0 && [value rangeOfString:@"comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL SPKCommentsSwipeStringLooksShareRelated(NSString *value) {
    if (value.length == 0)
        return NO;
    // "Shared" is a common module/component word (IGCommentSharedComponents), not a share surface.
    value = [value stringByReplacingOccurrencesOfString:@"shared" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, value.length)];
    NSArray<NSString *> *patterns = @[
        @"share",
        @"IGExternalShare",
        @"ShareSheet",
        @"Copy link",
        @"WhatsApp",
        @"Add to story"
    ];
    for (NSString *pattern in patterns) {
        if ([value rangeOfString:pattern options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL SPKCommentsSwipeViewTreeMatches(UIView *view, BOOL (*matcher)(NSString *), NSUInteger depth, NSUInteger *visitedCount, NSString **reason) {
    if (!view || depth > 8 || *visitedCount > 180) {
        return NO;
    }
    *visitedCount += 1;

    NSString *className = NSStringFromClass([view class]);
    if (matcher(className)) {
        if (reason)
            *reason = [NSString stringWithFormat:@"view class %@", className];
        return YES;
    }

    NSString *identifier = view.accessibilityIdentifier;
    if (matcher(identifier)) {
        if (reason)
            *reason = [NSString stringWithFormat:@"view accessibilityIdentifier %@", identifier];
        return YES;
    }

    NSString *label = view.accessibilityLabel;
    if (matcher(label)) {
        if (reason)
            *reason = [NSString stringWithFormat:@"view accessibilityLabel %@", label];
        return YES;
    }

    UIResponder *responder = view.nextResponder;
    if (responder && matcher(NSStringFromClass([responder class]))) {
        if (reason)
            *reason = [NSString stringWithFormat:@"nextResponder %@", NSStringFromClass([responder class])];
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if (SPKCommentsSwipeViewTreeMatches(subview, matcher, depth + 1, visitedCount, reason)) {
            return YES;
        }
    }

    return NO;
}

static BOOL SPKCommentsSwipeControllerTreeMatches(UIViewController *controller, BOOL (*matcher)(NSString *), NSUInteger depth, NSString **reason) {
    if (!controller || depth > 5) {
        return NO;
    }

    NSString *className = NSStringFromClass([controller class]);
    if (matcher(className)) {
        if (reason)
            *reason = [NSString stringWithFormat:@"controller class %@", className];
        return YES;
    }

    NSString *title = controller.title;
    if (matcher(title)) {
        if (reason)
            *reason = [NSString stringWithFormat:@"controller title %@", title];
        return YES;
    }

    for (UIViewController *child in controller.childViewControllers) {
        if (SPKCommentsSwipeControllerTreeMatches(child, matcher, depth + 1, reason)) {
            return YES;
        }
    }

    UIViewController *presented = controller.presentedViewController;
    if (presented && presented != controller) {
        if (SPKCommentsSwipeControllerTreeMatches(presented, matcher, depth + 1, reason)) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Swipe gesture class

// IG's directional pan: a Swift class on current builds, plain ObjC on 410.
static Class SPKCommentsSwipeDirectionalPanClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"_TtC12IGGestureKit33IGDirectionalPanGestureRecognizer")
                  ?: NSClassFromString(@"IGGestureKit.IGDirectionalPanGestureRecognizer")
                  ?: NSClassFromString(@"IGDirectionalPanGestureRecognizer");
    });
    return cls;
}

// Remapping applies only once the delegate has accepted a swipe. Before that,
// IG's own activation logic reads translationInView: on this recognizer and
// must see the real horizontal travel, or a swipe can never start.
static BOOL SPKCommentsSwipeIsActive(UIPanGestureRecognizer *pan) {
    return [objc_getAssociatedObject(pan, &kSPKSwipeCloseCommentsActiveKey) boolValue];
}

static void SPKCommentsSwipeSetActive(UIPanGestureRecognizer *pan, BOOL active) {
    objc_setAssociatedObject(pan, &kSPKSwipeCloseCommentsActiveKey, active ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat SPKCommentsSwipeSign(UIPanGestureRecognizer *pan) {
    NSNumber *sign = objc_getAssociatedObject(pan, &kSPKSwipeCloseCommentsSignKey);
    return sign ? sign.doubleValue : 1.0;
}

// Horizontal travel as measured by IG's directional pan itself.
static CGPoint SPKCommentsSwipeRawTranslation(UIPanGestureRecognizer *pan, UIView *view) {
    struct objc_super sup = {pan, SPKCommentsSwipeDirectionalPanClass()};
    return ((CGPoint(*)(struct objc_super *, SEL, UIView *))objc_msgSendSuper)(&sup, @selector(translationInView:), view);
}

// Distance already handed to the sheet toward closed during this swipe. The
// sheet consumes translation as per-frame deltas, so this is the only record
// of where the drag stands relative to its starting height.
static CGFloat SPKCommentsSwipeConsumed(UIPanGestureRecognizer *pan) {
    return [objc_getAssociatedObject(pan, &kSPKSwipeCloseCommentsConsumedKey) doubleValue];
}

static void SPKCommentsSwipeSetConsumed(UIPanGestureRecognizer *pan, CGFloat consumed) {
    objc_setAssociatedObject(pan, &kSPKSwipeCloseCommentsConsumedKey, @(consumed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// This frame's downward delta, never letting the drag rise above where it
// started. Reversing past the start would otherwise read as an upward drag and
// expand the sheet, which a sideways swipe should never do.
static CGFloat SPKCommentsSwipeClampedDelta(UIPanGestureRecognizer *pan, UIView *view) {
    CGFloat delta = SPKCommentsSwipeSign(pan) * SPKCommentsSwipeRawTranslation(pan, view).x;
    return MAX(delta, -SPKCommentsSwipeConsumed(pan));
}

static CGPoint SPKCommentsSwipeTranslationInView(UIPanGestureRecognizer *pan, SEL _cmd, UIView *view) {
    if (!SPKCommentsSwipeIsActive(pan))
        return SPKCommentsSwipeRawTranslation(pan, view);
    return CGPointMake(0.0, SPKCommentsSwipeClampedDelta(pan, view));
}

static CGPoint SPKCommentsSwipeVelocityInView(UIPanGestureRecognizer *pan, SEL _cmd, UIView *view) {
    struct objc_super sup = {pan, SPKCommentsSwipeDirectionalPanClass()};
    CGPoint raw = ((CGPoint(*)(struct objc_super *, SEL, UIView *))objc_msgSendSuper)(&sup, _cmd, view);
    if (!SPKCommentsSwipeIsActive(pan))
        return raw;
    CGFloat velocity = SPKCommentsSwipeSign(pan) * raw.x;
    // Back at the starting height, an upward velocity would flick the sheet open.
    if (velocity < 0.0 && SPKCommentsSwipeConsumed(pan) + SPKCommentsSwipeClampedDelta(pan, view) <= 0.5) {
        velocity = 0.0;
    }
    return CGPointMake(0.0, velocity);
}

// The sheet resets translation in its own vertical space after consuming it;
// record what it consumed, then map the reset back onto x.
static void SPKCommentsSwipeSetTranslation(UIPanGestureRecognizer *pan, SEL _cmd, CGPoint translation, UIView *view) {
    if (!SPKCommentsSwipeIsActive(pan)) {
        struct objc_super sup = {pan, SPKCommentsSwipeDirectionalPanClass()};
        ((void (*)(struct objc_super *, SEL, CGPoint, UIView *))objc_msgSendSuper)(&sup, _cmd, translation, view);
        return;
    }
    CGFloat consumed = SPKCommentsSwipeConsumed(pan) + SPKCommentsSwipeClampedDelta(pan, view) - translation.y;
    SPKCommentsSwipeSetConsumed(pan, MAX(consumed, 0.0));

    struct objc_super sup = {pan, SPKCommentsSwipeDirectionalPanClass()};
    CGPoint mapped = CGPointMake(SPKCommentsSwipeSign(pan) * translation.y, 0.0);
    ((void (*)(struct objc_super *, SEL, CGPoint, UIView *))objc_msgSendSuper)(&sup, _cmd, mapped, view);
}

// Report the activation the sheet expects from its own pan: a downward drag.
static unsigned long long SPKCommentsSwipeActivatedDirection(UIPanGestureRecognizer *pan, SEL _cmd) {
    Class superclass = SPKCommentsSwipeDirectionalPanClass();
    if (class_respondsToSelector(superclass, _cmd)) {
        struct objc_super sup = {pan, superclass};
        unsigned long long real = ((unsigned long long (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
        if (!SPKCommentsSwipeIsActive(pan))
            return real;
        return real ? kSPKDirectionalPanDown : 0;
    }
    UIGestureRecognizerState state = pan.state;
    BOOL dragging = state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
    return (SPKCommentsSwipeIsActive(pan) && dragging) ? kSPKDirectionalPanDown : 0;
}

static Class SPKCommentsSwipePanClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class superclass = SPKCommentsSwipeDirectionalPanClass();
        if (!superclass) {
            SPKWarnLog(@"General", @"[Sparkle CommentsSwipe] IGDirectionalPanGestureRecognizer not found");
            return;
        }
        Class subclass = objc_allocateClassPair(superclass, "SPKCommentsSwipePanGestureRecognizer", 0);
        if (!subclass) {
            cls = NSClassFromString(@"SPKCommentsSwipePanGestureRecognizer");
            return;
        }
        class_addMethod(subclass, @selector(translationInView:), (IMP)SPKCommentsSwipeTranslationInView, "{CGPoint=dd}@:@");
        class_addMethod(subclass, @selector(velocityInView:), (IMP)SPKCommentsSwipeVelocityInView, "{CGPoint=dd}@:@");
        class_addMethod(subclass, @selector(setTranslation:inView:), (IMP)SPKCommentsSwipeSetTranslation, "v@:{CGPoint=dd}@");
        class_addMethod(subclass, @selector(activatedDirection), (IMP)SPKCommentsSwipeActivatedDirection, "Q@:");
        objc_registerClassPair(subclass);
        cls = subclass;
    });
    return cls;
}

static void SPKCommentsSwipeSetActivationDirections(UIPanGestureRecognizer *pan, unsigned long long directions) {
    SEL setter = NSSelectorFromString(@"setPermissableActivationDirections:");
    if ([pan respondsToSelector:setter]) {
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(pan, setter, directions);
        return;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(pan), "_permissableActivationDirections");
    if (ivar) {
        *(unsigned long long *)((uint8_t *)(__bridge void *)pan + ivar_getOffset(ivar)) = directions;
    }
}

#pragma mark - Touch filtering

static BOOL SPKCommentsSwipeViewIsInsideCommentCell(UIView *view, UIView *stopView) {
    for (UIView *current = view; current && current != stopView; current = current.superview) {
        if ([current isKindOfClass:[UICollectionViewCell class]] || [current isKindOfClass:[UITableViewCell class]]) {
            return SPKCommentsSwipeStringLooksCommentRelated(NSStringFromClass([current class]));
        }
    }
    return NO;
}

// Views whose own interaction a sideways swipe would break.
static BOOL SPKCommentsSwipeViewKeepsTouch(UIView *view) {
    if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UISlider class]] || [view isKindOfClass:[UISwitch class]] ||
        [view isKindOfClass:[UIStepper class]] || [view isKindOfClass:[UISegmentedControl class]] || [view isKindOfClass:[UIDatePicker class]]) {
        return YES;
    }
    return [view isKindOfClass:[UITextView class]] && ((UITextView *)view).isEditable;
}

#pragma mark - Sheet state

// IGDSPartialModalSheetViewController sheet states.
static unsigned long long const kSPKCommentsSheetStatePartial = 1;
static unsigned long long const kSPKCommentsSheetStateExpanded = 2;
static unsigned long long const kSPKCommentsSheetStateUnknown = NSUIntegerMax;

static unsigned long long SPKCommentsSheetTargetState(UIViewController *sheet) {
    if ([sheet respondsToSelector:@selector(targetSheetState)]) {
        return ((IGDSDefaultPartialModalSheetViewController *)sheet).targetSheetState;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(sheet), "_targetSheetState");
    return ivar ? *(unsigned long long *)((uint8_t *)(__bridge void *)sheet + ivar_getOffset(ivar)) : kSPKCommentsSheetStateUnknown;
}

// The sheet's own "skip partial on pan" switch makes a released drag from
// Expanded settle at Closed instead of Partial. The ivar is written directly
// because 410 has no setter.
static _Bool *SPKCommentsSheetSkipPartialFlag(UIViewController *sheet) {
    Ivar ivar = sheet ? class_getInstanceVariable(object_getClass(sheet), "_skipPartialStateOnPan") : NULL;
    return ivar ? (_Bool *)((uint8_t *)(__bridge void *)sheet + ivar_getOffset(ivar)) : NULL;
}

#pragma mark - Controller

@interface SPKSwipeCloseCommentsController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *sheet;
@property (nonatomic, strong) UIPanGestureRecognizer *swappedOutPan;
// Set for a swipe that starts on an Expanded sheet with Close Fully on.
@property (nonatomic) BOOL closingFully;
@property (nonatomic) BOOL savedSkipPartial;
@end

@implementation SPKSwipeCloseCommentsController

- (Ivar)verticalPanIvar {
    UIViewController *sheet = self.sheet;
    return sheet ? class_getInstanceVariable(object_getClass(sheet), "_verticalPanGesture") : NULL;
}

// Stand in as the sheet's own pan so startInteractiveTransition: keeps the
// dismissal interactive. The real pan is held here and put back afterwards.
- (void)swapInPan:(UIPanGestureRecognizer *)pan {
    Ivar ivar = [self verticalPanIvar];
    if (!ivar || self.swappedOutPan)
        return;
    UIPanGestureRecognizer *original = object_getIvar(self.sheet, ivar);
    if (!original || original == pan)
        return;
    self.swappedOutPan = original;
    object_setIvar(self.sheet, ivar, pan);
}

- (void)restoreOriginalPan {
    UIPanGestureRecognizer *original = self.swappedOutPan;
    if (!original)
        return;
    Ivar ivar = [self verticalPanIvar];
    if (ivar)
        object_setIvar(self.sheet, ivar, original);
    self.swappedOutPan = nil;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    IGDSDefaultPartialModalSheetViewController *sheet = (IGDSDefaultPartialModalSheetViewController *)self.sheet;
    if (!sheet) {
        [self restoreOriginalPan];
        SPKCommentsSwipeSetActive(pan, NO);
        return;
    }

    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        [self swapInPan:pan];
        [self beginClosingFullyIfNeeded];
    }

    [sheet _didPan:pan];

    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        [self restoreOriginalPan];
        SPKCommentsSwipeSetActive(pan, NO);
        [self finishClosingFullyAfterRelease:state == UIGestureRecognizerStateEnded];
    }
}

- (void)beginClosingFullyIfNeeded {
    UIViewController *sheet = self.sheet;
    self.closingFully = NO;
    if (![SPKUtils getBoolPref:kSPKSwipeCloseCommentsFullyKey] || SPKCommentsSheetTargetState(sheet) != kSPKCommentsSheetStateExpanded) {
        return;
    }
    self.closingFully = YES;
    _Bool *skipPartial = SPKCommentsSheetSkipPartialFlag(sheet);
    if (skipPartial) {
        self.savedSkipPartial = *skipPartial;
        *skipPartial = true;
    }
}

// The sheet settles a release on the next turns of the run loop, so the
// outcome is read after it. If it still chose Partial (no skip flag on this
// build, or the flag ignored for this sheet), close it from there.
- (void)finishClosingFullyAfterRelease:(BOOL)released {
    if (!self.closingFully)
        return;
    self.closingFully = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKSwipeCloseCommentsController *strongSelf = weakSelf;
        UIViewController *sheet = strongSelf.sheet;
        if (!strongSelf || !sheet)
            return;
        _Bool *skipPartial = SPKCommentsSheetSkipPartialFlag(sheet);
        if (skipPartial) {
            *skipPartial = strongSelf.savedSkipPartial;
        }
        if (released && SPKCommentsSheetTargetState(sheet) == kSPKCommentsSheetStatePartial && sheet.presentingViewController &&
            !sheet.isBeingDismissed) {
            SPKLog(@"General", @"[Sparkle CommentsSwipe] Expanded release settled at Partial; closing");
            [sheet dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

// Comment rows put their buttons (like, reply, view replies) across most of
// the row, the like column right at the edge a swipe starts from. A swipe may
// start over those: the pan only begins once the finger travels sideways, and
// beginning cancels the button's touch, so a tap still works and a swipe never
// also triggers the button. Controls outside comment rows (composer, header)
// and controls that track a horizontal drag or take text keep their touches.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *hostView = gestureRecognizer.view;
    for (UIView *view = touch.view; view; view = view.superview) {
        if (SPKCommentsSwipeViewKeepsTouch(view)) {
            return NO;
        }
        if ([view isKindOfClass:[UIControl class]] && !SPKCommentsSwipeViewIsInsideCommentCell(view, hostView)) {
            return NO;
        }
    }
    return YES;
}

// Comment cells have their own horizontal swipe actions, which claim a swipe
// that starts on a row before ours can begin. Those wait for the close swipe to
// fail instead. It fails straight away for a direction the preference excludes,
// so row actions still work there. Other scroll views (lists, emoji and GIF
// rows) keep priority so scrolling them never closes the sheet.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    UIView *hostView = gestureRecognizer.view;
    UIView *otherView = otherGestureRecognizer.view;
    if (![otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] || !otherView || otherView == hostView ||
        ![otherView isDescendantOfView:hostView]) {
        return NO;
    }
    if ([otherView isKindOfClass:[UIScrollView class]] && otherGestureRecognizer == ((UIScrollView *)otherView).panGestureRecognizer) {
        return SPKCommentsSwipeViewIsInsideCommentCell(otherView, hostView);
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] || ![SPKUtils getBoolPref:@"general_comments_swipe_close"]) {
        return NO;
    }

    IGDSDefaultPartialModalSheetViewController *sheet = (IGDSDefaultPartialModalSheetViewController *)self.sheet;
    if (!sheet || self.swappedOutPan) {
        return NO;
    }
    if (([sheet respondsToSelector:@selector(disablePanToClose)] && sheet.disablePanToClose) ||
        ([sheet respondsToSelector:@selector(disableVerticalPan)] && sheet.disableVerticalPan)) {
        return NO;
    }

    // IG's pan already enforces a horizontal activation; this only applies the
    // direction preference and fixes which way counts as "down" for this swipe.
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGFloat dx = SPKCommentsSwipeRawTranslation(pan, pan.view).x;
    if (dx == 0.0) {
        struct objc_super sup = {pan, SPKCommentsSwipeDirectionalPanClass()};
        dx = ((CGPoint(*)(struct objc_super *, SEL, UIView *))objc_msgSendSuper)(&sup, @selector(velocityInView:), pan.view).x;
    }
    if (dx == 0.0) {
        return NO;
    }

    SPKSwipeCloseCommentsDirection allowed = SPKSwipeCloseCommentsDirectionFromPref();
    BOOL leftward = dx < 0.0;
    BOOL directionAllowed = leftward ? (allowed & SPKSwipeCloseCommentsDirectionLeft) != 0 : (allowed & SPKSwipeCloseCommentsDirectionRight) != 0;
    if (!directionAllowed) {
        return NO;
    }

    objc_setAssociatedObject(pan, &kSPKSwipeCloseCommentsSignKey, @(leftward ? -1.0 : 1.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKCommentsSwipeSetConsumed(pan, 0.0);
    SPKCommentsSwipeSetActive(pan, YES);
    return YES;
}

@end

#pragma mark - Install

static void SPKInstallSwipeCloseCommentsGesture(UIViewController *controller) {
    if (![SPKUtils getBoolPref:@"general_comments_swipe_close"]) {
        return;
    }
    if (![controller respondsToSelector:@selector(_didPan:)]) {
        SPKWarnLog(@"General", @"[Sparkle CommentsSwipe] Skipping %@: no _didPan:", SPKCommentsSwipeDescribe(controller));
        return;
    }

    Ivar verticalPanIvar = class_getInstanceVariable(object_getClass(controller), "_verticalPanGesture");
    UIPanGestureRecognizer *verticalPan = verticalPanIvar ? object_getIvar(controller, verticalPanIvar) : nil;
    UIView *hostView = verticalPan.view;
    if (!hostView) {
        return; // not laid out yet; the delayed retry installs it
    }

    if ([objc_getAssociatedObject(hostView, &kSPKSwipeCloseCommentsInstalledKey) boolValue]) {
        return;
    }

    // Controller classes are the strong signal; the view scan is only a fallback
    // when no controller names the surface, since a comments sheet's view tree
    // can hold share-looking controls (a share button, shared components).
    NSString *reason = nil;
    if (SPKCommentsSwipeControllerTreeMatches(controller, SPKCommentsSwipeStringLooksShareRelated, 0, &reason)) {
        SPKLog(@"General", @"[Sparkle CommentsSwipe] Skipping %@: share sheet (%@)", SPKCommentsSwipeDescribe(controller), reason);
        return;
    }
    if (!SPKCommentsSwipeControllerTreeMatches(controller, SPKCommentsSwipeStringLooksCommentRelated, 0, &reason)) {
        NSUInteger visitedCount = 0;
        if (SPKCommentsSwipeViewTreeMatches(hostView, SPKCommentsSwipeStringLooksShareRelated, 0, &visitedCount, &reason)) {
            SPKLog(@"General", @"[Sparkle CommentsSwipe] Skipping %@: share sheet (%@)", SPKCommentsSwipeDescribe(controller), reason);
            return;
        }
        visitedCount = 0;
        if (!SPKCommentsSwipeViewTreeMatches(hostView, SPKCommentsSwipeStringLooksCommentRelated, 0, &visitedCount, &reason)) {
            return;
        }
    }

    Class panClass = SPKCommentsSwipePanClass();
    if (!panClass) {
        return;
    }

    SPKSwipeCloseCommentsController *swipeController = [[SPKSwipeCloseCommentsController alloc] init];
    swipeController.sheet = controller;

    UIPanGestureRecognizer *pan = [[panClass alloc] initWithTarget:swipeController action:@selector(handlePan:)];
    SPKCommentsSwipeSetActivationDirections(pan, kSPKDirectionalPanLeft | kSPKDirectionalPanRight);
    pan.maximumNumberOfTouches = 1;
    pan.delegate = swipeController;
    [hostView addGestureRecognizer:pan];

    // Gesture targets and delegates are weak; the host view keeps the controller alive.
    objc_setAssociatedObject(hostView, &kSPKSwipeCloseCommentsControllerKey, swipeController, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(hostView, &kSPKSwipeCloseCommentsInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SPKLog(@"General", @"[Sparkle CommentsSwipe] Installed on %@ host=%@ reason=%@",
           SPKCommentsSwipeDescribe(controller),
           SPKCommentsSwipeDescribe(hostView),
           reason ?: @"unknown");
}

%group SPKSwipeCloseCommentsHooks

%hook IGDSDefaultPartialModalSheetViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKInstallSwipeCloseCommentsGesture((UIViewController *)self);

    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller) {
            SPKInstallSwipeCloseCommentsGesture(controller);
        }
    });
}

%end

%end

extern "C" void SPKInstallSwipeCloseCommentsHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"general_comments_swipe_close"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKLog(@"General", @"[Sparkle CommentsSwipe] Installing hooks");
        %init(SPKSwipeCloseCommentsHooks);
    });
}
