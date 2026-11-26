#import "SPKChromeGlassMirror.h"

#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"
#import "SPKChrome.h"

// IG's bubble class is a Swift private type, so it is matched by name suffix.
static NSString *const kSPKChromeGlassIGBubbleClassFragment = @"TouchForwardingVisualEffectView";

static void SPKChromeGlassHookBubbleSetAlphaIfNeeded(UIView *bubble);

#pragma mark - Registered chrome

// Every chrome view that mirrors a bubble, held weakly. IG animating one of its own
// bubbles marks the enclosing chrome for layout, which is what re-runs the mirror —
// see SPKChromeGlassHookedSetAlpha.
static NSHashTable<UIView *> *SPKChromeGlassRegisteredChrome(void) {
    static NSHashTable *chrome;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chrome = [NSHashTable weakObjectsHashTable];
    });
    return chrome;
}

#pragma mark - Bubble lookup

static void SPKChromeGlassAccumulate(UIView *view, UIVisualEffectView **best, CGFloat *maxAlpha) {
    if (!view)
        return;
    // Ordered cheapest-first: this walks the whole chrome on every layout pass, so
    // only the handful of nodes that are already visual effect views pay for the
    // class-name and identifier checks. Sparkle's own bubbles are a different class
    // and so wouldn't match anyway; the identifier guard is belt-and-braces against
    // sampling ourselves.
    if ([view isKindOfClass:[UIVisualEffectView class]] &&
        [NSStringFromClass([view class]) containsString:kSPKChromeGlassIGBubbleClassFragment] &&
        ![view.accessibilityIdentifier hasPrefix:@"sparkle-"]) {
        CGFloat alpha = view.alpha;
        if (alpha > *maxAlpha) {
            *maxAlpha = alpha;
            *best = (UIVisualEffectView *)view;
        }
        SPKChromeGlassHookBubbleSetAlphaIfNeeded(view);
    }
    for (UIView *subview in view.subviews) {
        SPKChromeGlassAccumulate(subview, best, maxAlpha);
    }
}

#pragma mark - Staying in sync with IG's fade

// IG fades its bubbles by animating their alpha, and that doesn't always re-run the
// enclosing header's layoutSubviews (the profile header's scroll-collapse and the
// feed header's status-bar-tap scroll-to-top both skip it). Hooking setAlpha: lets
// the chrome mark itself for layout, so our mirrored bubble tracks IG's continuously
// without anything having to poll per frame.
static void (*orig_bubbleSetAlpha)(id, SEL, CGFloat);
static void SPKChromeGlassHookedSetAlpha(id self, SEL _cmd, CGFloat alpha) {
    if (orig_bubbleSetAlpha)
        orig_bubbleSetAlpha(self, _cmd, alpha);

    NSHashTable<UIView *> *registered = SPKChromeGlassRegisteredChrome();
    if (registered.count == 0)
        return;
    for (UIView *ancestor = [(UIView *)self superview]; ancestor; ancestor = ancestor.superview) {
        if ([registered containsObject:ancestor]) {
            [ancestor setNeedsLayout];
            return;
        }
    }
}

static BOOL sBubbleSetAlphaHooked = NO;
static void SPKChromeGlassHookBubbleSetAlphaIfNeeded(UIView *bubble) {
    if (sBubbleSetAlphaHooked)
        return;
    sBubbleSetAlphaHooked = YES;

    Class cls = [bubble class];
    SEL sel = @selector(setAlpha:);
    if (!class_getInstanceMethod(cls, sel))
        return;
    MSHookMessageEx(cls, sel, (IMP)SPKChromeGlassHookedSetAlpha, (IMP *)&orig_bubbleSetAlpha);
    SPKLog(@"ChromeGlass", @"[Sparkle] Hooked setAlpha: on %@ for glass sync", NSStringFromClass(cls));
}

#pragma mark - Public

UIView *SPKChromeGlassMirrorMakeBubble(NSString *accessibilityIdentifier) {
    // Presence of UIGlassEffect is the capability gate (iOS 26+), but we deliberately
    // don't build one: the bubble starts effect-less and gets IG's own effect from the
    // first sync. Approximating the material only ever produced a mismatch, and an
    // effect-less view renders nothing, so there's no flash before the first sync (and
    // nothing at all if IG's chrome has no bubble to sample, which is the honest
    // outcome — a bare icon, same as pre-26).
    if (!NSClassFromString(@"UIGlassEffect"))
        return nil;

    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:nil];
    glassView.userInteractionEnabled = NO;
    glassView.clipsToBounds = YES;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.accessibilityIdentifier = accessibilityIdentifier;
    return glassView;
}

void SPKChromeGlassMirrorAttach(UIView *glassView, UIButton *button) {
    if (!glassView || !button)
        return;

    // Hosted inside the chrome canvas (the same secure CanvasView the icon lives in)
    // so "hide UI on capture" redacts the bubble too. iconView.superview is that
    // content container; fall back to the button before the canvas attaches.
    UIView *host = button;
    if ([button isKindOfClass:[SPKChromeButton class]]) {
        host = ((SPKChromeButton *)button).iconView.superview ?: button;
    }

    if (glassView.superview != host) {
        [host insertSubview:glassView atIndex:0];
    }
    [host sendSubviewToBack:glassView]; // stay behind the icon

    CGRect bounds = host.bounds;
    if (!CGRectEqualToRect(glassView.frame, bounds)) {
        glassView.frame = bounds;
    }
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) / 2.0;
    if (glassView.layer.cornerRadius != radius) {
        glassView.layer.cornerRadius = radius;
    }

    CGFloat buttonRadius = MIN(button.bounds.size.width, button.bounds.size.height) / 2.0;
    if (button.layer.cornerRadius != buttonRadius) {
        button.layer.cornerRadius = buttonRadius;
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

void SPKChromeGlassMirrorUseSystemGlass(UIView *glassView, UIButton *button) {
    static const void *kSystemGlassEffectKey = &kSystemGlassEffectKey;
    if ([glassView isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *bubble = (UIVisualEffectView *)glassView;
        UIVisualEffect *effect = objc_getAssociatedObject(bubble, kSystemGlassEffectKey);
        if (!effect) {
            effect = [[NSClassFromString(@"UIGlassEffect") alloc] init];
            if (effect)
                objc_setAssociatedObject(bubble, kSystemGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (effect && bubble.effect != effect)
            bubble.effect = effect;
        if (bubble.layer.borderWidth != 0.0)
            bubble.layer.borderWidth = 0.0;
        if (bubble.alpha != 1.0)
            bubble.alpha = 1.0;
    }
    SPKChromeGlassMirrorAttach(glassView, button);
}

CGFloat SPKChromeGlassMirrorSync(UIView *glassView, UIView *chromeView) {
    if (chromeView) {
        [SPKChromeGlassRegisteredChrome() addObject:chromeView];
    }

    UIVisualEffectView *igBubble = nil;
    CGFloat alpha = -1.0;
    SPKChromeGlassAccumulate(chromeView, &igBubble, &alpha);

    UIVisualEffectView *bubbleView = [glassView isKindOfClass:[UIVisualEffectView class]]
                                         ? (UIVisualEffectView *)glassView
                                         : nil;
    if (bubbleView && igBubble) {
        // Adopt IG's live effect object outright: same material, tint colour and
        // opacity as its neighbouring buttons, whatever IG changes it to. Only
        // reassign on change, since setting `effect` rebuilds the backdrop and this
        // runs every layout pass.
        UIVisualEffect *igEffect = igBubble.effect;
        if (igEffect && bubbleView.effect != igEffect) {
            bubbleView.effect = igEffect;
        }
        // The hairline ring is drawn on IG's layer, not by the effect. Write-guarded
        // like the effect: an unconditional CALayer write dirties the layer even when
        // the value is unchanged.
        CGFloat borderWidth = igBubble.layer.borderWidth;
        if (bubbleView.layer.borderWidth != borderWidth) {
            bubbleView.layer.borderWidth = borderWidth;
        }
        CGColorRef borderColor = igBubble.layer.borderColor;
        CGColorRef currentColor = bubbleView.layer.borderColor;
        if (currentColor != borderColor &&
            !(currentColor && borderColor && CGColorEqualToColor(currentColor, borderColor))) {
            bubbleView.layer.borderColor = borderColor;
        }
    }

    if (glassView) {
        CGFloat targetAlpha = alpha > 0.0 ? MIN(alpha, 1.0) : 0.0;
        if (glassView.alpha != targetAlpha) {
            glassView.alpha = targetAlpha;
        }
    }
    return alpha;
}
