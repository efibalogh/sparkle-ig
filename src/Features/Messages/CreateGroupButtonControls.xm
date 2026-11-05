#import "SPKStrings.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import "../../App/SPKPerfMeter.h"

static NSString *const kSPKConfirmCreateGroupButtonPref = @"general_confirm_create_group";
static NSString *const kSPKHideCreateGroupButtonPref = @"general_hide_create_group";

static const void *kSPKGroupButtonBypassConfirmAssocKey = &kSPKGroupButtonBypassConfirmAssocKey;
static const void *kSPKGroupButtonPendingActionAssocKey = &kSPKGroupButtonPendingActionAssocKey;
static const void *kSPKGroupButtonPendingTargetAssocKey = &kSPKGroupButtonPendingTargetAssocKey;
static const void *kSPKCreateGroupButtonRemovedAssocKey = &kSPKCreateGroupButtonRemovedAssocKey;

@interface IGShareSheetCreateOrSendToGroupFacepileButton : UIControl
@end

static BOOL SPKShouldHideCreateGroupButton(void) {
    return [SPKUtils getBoolPref:kSPKHideCreateGroupButtonPref];
}

static BOOL SPKShouldConfirmCreateGroupButton(void) {
    return !SPKShouldHideCreateGroupButton() && [SPKUtils getBoolPref:kSPKConfirmCreateGroupButtonPref];
}

// IG 451 moved the share sheet's Swift module from IGShareSheet to IGDirectShareSheetUI.
static Class SPKResolveCreateGroupButtonClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGDirectShareSheetUI.IGShareSheetCreateOrSendToGroupFacepileButton", @"IGShareSheet.IGShareSheetCreateOrSendToGroupFacepileButton");
    });
    return cls;
}

static Class SPKResolveBottomButtonsViewClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGDirectShareSheetUI.IGSharesheetBottomButtonsView", @"IGShareSheet.IGSharesheetBottomButtonsView");
    });
    return cls;
}

static Class SPKResolveBottomButtonsContainerClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGDirectShareSheetUI.IGShareSheetBottomButtonsViewContainer", @"IGShareSheet.IGShareSheetBottomButtonsViewContainer");
    });
    return cls;
}

static BOOL SPKObjectIsKindOfResolvedClass(id object, Class cls) {
    return (object && cls) ? [object isKindOfClass:cls] : NO;
}

static void SPKCollapseConstraintForViewInArray(UIView *view, NSArray<NSLayoutConstraint *> *constraints) {
    for (NSLayoutConstraint *constraint in constraints) {
        BOOL referencesView = (constraint.firstItem == view || constraint.secondItem == view);
        if (!referencesView)
            continue;

        NSLayoutAttribute firstAttribute = constraint.firstAttribute;
        NSLayoutAttribute secondAttribute = constraint.secondAttribute;
        BOOL sizeConstraint = (firstAttribute == NSLayoutAttributeWidth || firstAttribute == NSLayoutAttributeHeight || secondAttribute == NSLayoutAttributeWidth || secondAttribute == NSLayoutAttributeHeight);
        if (!sizeConstraint)
            continue;

        constraint.constant = 0.0;
    }
}

static UIView *SPKFindCreateGroupButtonSubview(UIView *view) {
    if (!view)
        return nil;
    if (SPKObjectIsKindOfResolvedClass(view, SPKResolveCreateGroupButtonClass())) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *match = SPKFindCreateGroupButtonSubview(subview);
        if (match)
            return match;
    }
    return nil;
}

static CGFloat SPKVisibleSubviewMaxY(UIView *view) {
    CGFloat maxY = 0.0;
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.0)
            continue;
        CGFloat candidate = CGRectGetMaxY(subview.frame);
        if (candidate > maxY) {
            maxY = candidate;
        }
    }
    return maxY;
}

static void SPKApplyCreateGroupButtonVisibility(UIView *view) {
    if (!view)
        return;

    if (!SPKShouldHideCreateGroupButton()) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
        return;
    }

    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    [view invalidateIntrinsicContentSize];

    CGRect frame = view.frame;
    frame.size.width = 0.0;
    frame.size.height = 0.0;
    view.frame = frame;

    SPKCollapseConstraintForViewInArray(view, view.constraints);
    if (view.superview) {
        SPKCollapseConstraintForViewInArray(view, view.superview.constraints);
    }
}

static void SPKRemoveCreateGroupButtonFromHierarchyIfNeeded(UIView *rootView) {
    if (!SPKShouldHideCreateGroupButton() || !rootView)
        return;

    UIView *button = SPKFindCreateGroupButtonSubview(rootView);
    if (!button)
        return;
    if ([objc_getAssociatedObject(button, kSPKCreateGroupButtonRemovedAssocKey) boolValue])
        return;

    objc_setAssociatedObject(button, kSPKCreateGroupButtonRemovedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button removeFromSuperview];
}

static void SPKApplyBottomButtonsCollapse(UIView *view) {
    if (!SPKShouldHideCreateGroupButton() || !view)
        return;

    SPKRemoveCreateGroupButtonFromHierarchyIfNeeded(view);

    CGFloat maxY = SPKVisibleSubviewMaxY(view);
    if (maxY > 0.0) {
        CGRect frame = view.frame;
        frame.size.height = ceil(maxY);
        view.frame = frame;
        SPKCollapseConstraintForViewInArray(view, view.constraints);
        if (view.superview) {
            for (NSLayoutConstraint *constraint in view.superview.constraints) {
                if ((constraint.firstItem == view || constraint.secondItem == view) && (constraint.firstAttribute == NSLayoutAttributeHeight || constraint.secondAttribute == NSLayoutAttributeHeight)) {
                    constraint.constant = ceil(maxY);
                }
            }
        }
    }
}

%group SPKCreateGroupButtonControls

%hook SPKCreateGroupButtonClass

- (void)didMoveToSuperview {
    %orig;
    SPKApplyCreateGroupButtonVisibility(self);
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"CreateGroupButtonControls.layoutSubviews");
    if (SPKShouldHideCreateGroupButton()) {
        SPKApplyCreateGroupButtonVisibility(self);
    }
}

- (CGSize)intrinsicContentSize {
    if (SPKShouldHideCreateGroupButton()) {
        return CGSizeZero;
    }
    return %orig;
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (SPKShouldHideCreateGroupButton()) {
        return CGSizeZero;
    }
    return %orig(size);
}

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (!SPKShouldConfirmCreateGroupButton() || !action || !target) {
        %orig(action, target, event);
        return;
    }

    NSNumber *bypassConfirm = objc_getAssociatedObject(self, kSPKGroupButtonBypassConfirmAssocKey);
    if (bypassConfirm.boolValue) {
        objc_setAssociatedObject(self, kSPKGroupButtonBypassConfirmAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kSPKGroupButtonPendingActionAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kSPKGroupButtonPendingTargetAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(action, target, event);
        return;
    }

    objc_setAssociatedObject(self, kSPKGroupButtonPendingActionAssocKey, NSStringFromSelector(action), OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kSPKGroupButtonPendingTargetAssocKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak __typeof__(self) weakSelf = self;
    [SPKUtils
        showConfirmation:^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf)
                return;

            NSString *pendingActionName = objc_getAssociatedObject(strongSelf, kSPKGroupButtonPendingActionAssocKey);
            id pendingTarget = objc_getAssociatedObject(strongSelf, kSPKGroupButtonPendingTargetAssocKey);
            if (pendingActionName.length == 0 || !pendingTarget) {
                return;
            }

            objc_setAssociatedObject(strongSelf, kSPKGroupButtonBypassConfirmAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [strongSelf sendAction:NSSelectorFromString(pendingActionName) to:pendingTarget forEvent:nil];
        }
        cancelHandler:^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf)
                return;

            objc_setAssociatedObject(strongSelf, kSPKGroupButtonPendingActionAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(strongSelf, kSPKGroupButtonPendingTargetAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        title:SPKL(@"MESSAGES_CREATE_GROUP_BUTTON_CONTROLS_CONFIRM_GROUP_CREATION_TEXT")
        message:SPKL(@"MESSAGES_CREATE_GROUP_BUTTON_CONTROLS_CREATE_SEND_GROUP_SELECTED_RECIPIENTS_CONFIRMATION_MESSAGE")];
}

%end

%hook SPKBottomButtonsViewClass

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"CreateGroupButtonControls.layoutSubviews2");
    SPKApplyBottomButtonsCollapse(self);
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize original = %orig(size);
    if (!SPKShouldHideCreateGroupButton()) {
        return original;
    }
    CGFloat collapsedHeight = SPKVisibleSubviewMaxY(self);
    if (collapsedHeight > 0.0 && SPKFindCreateGroupButtonSubview(self)) {
        original.height = ceil(collapsedHeight);
    }
    return original;
}

- (CGSize)intrinsicContentSize {
    CGSize original = %orig;
    if (!SPKShouldHideCreateGroupButton()) {
        return original;
    }
    CGFloat collapsedHeight = SPKVisibleSubviewMaxY(self);
    if (collapsedHeight > 0.0 && SPKFindCreateGroupButtonSubview(self)) {
        original.height = ceil(collapsedHeight);
    }
    return original;
}

%end

%hook SPKBottomButtonsContainerClass

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"CreateGroupButtonControls.layoutSubviews3");
    if (!SPKShouldHideCreateGroupButton())
        return;

    UIView *view = (UIView *)self;
    UIView *bottomButtonsView = SPKFindCreateGroupButtonSubview(self) ? self : nil;
    if (!bottomButtonsView) {
        for (UIView *subview in view.subviews) {
            if (SPKObjectIsKindOfResolvedClass(subview, SPKResolveBottomButtonsViewClass())) {
                bottomButtonsView = subview;
                break;
            }
        }
    }
    if (!bottomButtonsView)
        return;

    SPKApplyBottomButtonsCollapse(bottomButtonsView);
    CGFloat height = CGRectGetHeight(bottomButtonsView.frame);
    if (height > 0.0) {
        CGRect frame = view.frame;
        frame.size.height = height;
        view.frame = frame;
        SPKCollapseConstraintForViewInArray(view, view.constraints);
        if (view.superview) {
            for (NSLayoutConstraint *constraint in view.superview.constraints) {
                if ((constraint.firstItem == view || constraint.secondItem == view) && (constraint.firstAttribute == NSLayoutAttributeHeight || constraint.secondAttribute == NSLayoutAttributeHeight)) {
                    constraint.constant = height;
                }
            }
        }
    }
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize original = %orig(size);
    if (!SPKShouldHideCreateGroupButton()) {
        return original;
    }
    UIView *view = (UIView *)self;
    for (UIView *subview in view.subviews) {
        if (SPKObjectIsKindOfResolvedClass(subview, SPKResolveBottomButtonsViewClass())) {
            CGFloat height = SPKVisibleSubviewMaxY(subview);
            if (height > 0.0) {
                original.height = ceil(height);
            }
            break;
        }
    }
    return original;
}

- (CGSize)intrinsicContentSize {
    CGSize original = %orig;
    if (!SPKShouldHideCreateGroupButton()) {
        return original;
    }
    UIView *view = (UIView *)self;
    for (UIView *subview in view.subviews) {
        if (SPKObjectIsKindOfResolvedClass(subview, SPKResolveBottomButtonsViewClass())) {
            CGFloat height = SPKVisibleSubviewMaxY(subview);
            if (height > 0.0) {
                original.height = ceil(height);
            }
            break;
        }
    }
    return original;
}

%end

%end

extern "C" void SPKInstallCreateGroupButtonControlHooksIfEnabled(void) {
    if (!SPKShouldHideCreateGroupButton() && !SPKShouldConfirmCreateGroupButton())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class createGroupButtonClass = SPKResolveCreateGroupButtonClass();
        Class bottomButtonsViewClass = SPKResolveBottomButtonsViewClass();
        Class bottomButtonsContainerClass = SPKResolveBottomButtonsContainerClass();

        if (createGroupButtonClass && bottomButtonsViewClass && bottomButtonsContainerClass) {
            %init(SPKCreateGroupButtonControls,
                           SPKCreateGroupButtonClass = createGroupButtonClass,
                           SPKBottomButtonsViewClass = bottomButtonsViewClass,
                           SPKBottomButtonsContainerClass = bottomButtonsContainerClass);
        }
    });
}
