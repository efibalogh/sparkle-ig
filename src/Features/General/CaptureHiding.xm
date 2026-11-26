#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import "CaptureHiding.h"
#import "../../App/SPKPerfMeter.h"

static const void *kSPKCaptureFieldKey = &kSPKCaptureFieldKey;
static const void *kSPKCaptureCanvasKey = &kSPKCaptureCanvasKey;

const NSInteger kSPKCaptureFollowIndicatorTag = 926003;

// All capture tags fall within [921341, 926003]. A fast integer range check lets
// the vast majority of views (tag == 0) exit without boxing an NSNumber or
// touching the NSSet.
#define SPK_CAPTURE_TAG_MIN 921341
#define SPK_CAPTURE_TAG_MAX 926003

static inline BOOL SPKCaptureTagMayMatch(NSInteger tag) {
    return tag >= SPK_CAPTURE_TAG_MIN && tag <= SPK_CAPTURE_TAG_MAX;
}

static NSSet<NSNumber *> *SPKCaptureHiddenTags(void) {
    static NSSet<NSNumber *> *tags;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tags = [NSSet setWithArray:@[
            @921341, @921342, @921343, @921344, @921345,
            @921399, @921400,
            @926001, @926002,
            @(kSPKCaptureFollowIndicatorTag)
        ]];
    });
    return tags;
}

static inline Class SPKChromeButtonClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"SPKChromeButton");
    });
    return cls;
}

static UIView *SPKFindCanvasView(UIView *root, int depth) {
    if (!root || depth > 4)
        return nil;
    for (UIView *sub in root.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"CanvasView"] ||
            [cls containsString:@"TextLayoutCanvas"]) {
            return sub;
        }
        UIView *found = SPKFindCanvasView(sub, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

static NSString *SPKCaptureSubviewSummary(UIView *view) {
    if (!view)
        return @"(nil)";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        [parts addObject:[NSString stringWithFormat:@"%@<%p> tag=%ld hidden=%@ alpha=%.2f",
                                                    NSStringFromClass(subview.class),
                                                    subview,
                                                    (long)subview.tag,
                                                    subview.hidden ? @"YES" : @"NO",
                                                    subview.alpha]];
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : @"(none)";
}

static void SPKEnsureSecureCanvas(UIView *button) {
    if (!button || !button.window)
        return;
    if ([button isKindOfClass:NSClassFromString(@"SPKChromeButton")])
        return;
    if (![SPKUtils getBoolPref:@"interface_hide_ui_on_capture"])
        return;

    // Check if secure field already exists
    UITextField *field = objc_getAssociatedObject(button, kSPKCaptureFieldKey);
    if (field)
        return;

    SPKLog(@"Capture", @"Creating secure canvas for tag=%ld class=%@",
           (long)button.tag, NSStringFromClass([button class]));

    // 1. Create secure text field
    field = [UITextField new];
    // Marked before it turns secure: the Instants screenshot bypass would
    // otherwise switch it off, and the eye and action buttons in the Instants
    // viewer would show in screenshots.
    SPKChromeMarkSecureFieldOwned(field);
    field.secureTextEntry = YES;
    field.userInteractionEnabled = NO;
    field.backgroundColor = [UIColor clearColor];
    field.borderStyle = UITextBorderStyleNone;
    field.textColor = [UIColor clearColor];
    field.tintColor = [UIColor clearColor];
    field.translatesAutoresizingMaskIntoConstraints = NO;

    // Associate it BEFORE adding as subview so the addSubview: hook recognizes it
    objc_setAssociatedObject(button, kSPKCaptureFieldKey, field, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 2. Snapshot existing children (if any were added before didMoveToWindow)
    NSMutableArray<UIView *> *existing = [NSMutableArray array];
    for (UIView *child in button.subviews) {
        if (child != field) {
            [existing addObject:child];
        }
    }

    // 3. Add secure field to button
    [button addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:button.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:button.bottomAnchor]
    ]];
    [field setNeedsLayout];
    [field layoutIfNeeded];

    // 4. Locate CanvasView
    UIView *canvas = SPKFindCanvasView(field, 0);
    if (!canvas) {
        SPKWarnLog(@"Capture", @"CanvasView not found for tag=%ld", (long)button.tag);
        [field removeFromSuperview];
        objc_setAssociatedObject(button, kSPKCaptureFieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // 5. Configure Canvas
    canvas.userInteractionEnabled = YES;
    canvas.clipsToBounds = NO;
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:field.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:field.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:field.bottomAnchor]
    ]];

    objc_setAssociatedObject(button, kSPKCaptureCanvasKey, canvas, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 6. Migrate pre-existing subviews to canvas
    for (UIView *child in existing) {
        [child removeFromSuperview];
        [canvas addSubview:child];
    }

    SPKLog(@"Capture", @"Secure canvas successfully applied to tag=%ld (%lu pre-existing children moved)",
           (long)button.tag, (unsigned long)existing.count);
    SPKLog(@"Capture", @"button=%@<%p> subviews=%@",
           NSStringFromClass(button.class), button, SPKCaptureSubviewSummary(button));
    if ([button isKindOfClass:UIButton.class]) {
        UIButton *uiButton = (UIButton *)button;
        SPKLog(@"Capture", @"imageView=%@<%p> imageSuperview=%@<%p>",
               NSStringFromClass(uiButton.imageView.class),
               uiButton.imageView,
               NSStringFromClass(uiButton.imageView.superview.class),
               uiButton.imageView.superview);
    }
    SPKLog(@"Capture", @"canvas=%@<%p> canvasSubviews=%@",
           NSStringFromClass(canvas.class), canvas, SPKCaptureSubviewSummary(canvas));
}

%group SPKCaptureHidingHooks

%hook UIView

- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"CaptureHiding.didMoveToWindow");
    // Fast path: 99.9% of views have tag 0 — exit without any ObjC messaging.
    if (!SPKCaptureTagMayMatch(self.tag))
        return;
    if (self.window &&
        ![self isKindOfClass:SPKChromeButtonClass()] &&
        [SPKCaptureHiddenTags() containsObject:@(self.tag)]) {
        SPKEnsureSecureCanvas(self);
    }
}

- (void)addSubview:(UIView *)view {
    // Deliberately unscoped: this hooks every UIView in the process, so a scope
    // spanning %orig bills UIKit's own addSubview: work to Sparkle. Our share is
    // the two integer compares below, and measuring those would cost more than
    // they do. The redirect branch, which is the only part that does real work,
    // is scoped instead.
    if (!SPKCaptureTagMayMatch(self.tag)) {
        %orig;
        return;
    }
    SPK_PERF_SCOPE(@"CaptureHiding.redirect");
    if (![self isKindOfClass:SPKChromeButtonClass()] &&
        [SPKCaptureHiddenTags() containsObject:@(self.tag)]) {
        // If this is the secure field itself, let it pass
        UITextField *secureField = objc_getAssociatedObject(self, kSPKCaptureFieldKey);
        if (view == secureField) {
            %orig;
            return;
        }

        // Ensure canvas is instantiated
        SPKEnsureSecureCanvas(self);

        UIView *canvas = objc_getAssociatedObject(self, kSPKCaptureCanvasKey);
        if (canvas) {
            // Intercept and redirect the subview into the secure canvas
            [canvas addSubview:view];
            SPKLog(@"Capture", @"Redirected subview class=%@ tag=%ld into secure canvas",
                   NSStringFromClass([view class]), (long)self.tag);
        } else {
            // Fallback
            %orig;
        }
    } else {
        %orig;
    }
}

%end

%end

extern "C" void SPKInstallCaptureHidingHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKLog(@"Capture", @"Installing capture hiding hooks...");
        %init(SPKCaptureHidingHooks);
    });
}
