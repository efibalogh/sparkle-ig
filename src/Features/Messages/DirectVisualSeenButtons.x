#import <objc/message.h>
#import "SPKStrings.h"
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"
#import "DirectSeenReceiptGuard.h"
#ifdef __cplusplus
extern "C" {
#endif
void SPKApplyButtonStyle(UIButton *button, NSInteger source);
#ifdef __cplusplus
}
#endif

static NSString *const kSPKSeenMessagesBarIconResource = @"eye";
static NSInteger const kSPKActionButtonSourceDirect = 4;
static NSInteger const kSPKDirectActionButtonTag = 921344;
static NSInteger const kSPKDirectSeenButtonTag = 921345;
static const void *kSPKDirectSeenBottomConstraintAssocKey = &kSPKDirectSeenBottomConstraintAssocKey;
static const void *kSPKDirectSeenTrailingOverlayConstraintAssocKey = &kSPKDirectSeenTrailingOverlayConstraintAssocKey;
static const void *kSPKDirectSeenTrailingActionConstraintAssocKey = &kSPKDirectSeenTrailingActionConstraintAssocKey;
static const void *kSPKDirectSeenCenterYActionConstraintAssocKey = &kSPKDirectSeenCenterYActionConstraintAssocKey;
static const void *kSPKDirectSeenWidthConstraintAssocKey = &kSPKDirectSeenWidthConstraintAssocKey;
static const void *kSPKDirectSeenHeightConstraintAssocKey = &kSPKDirectSeenHeightConstraintAssocKey;
static const void *kSPKDirectSeenAnchoredActionButtonAssocKey = &kSPKDirectSeenAnchoredActionButtonAssocKey;
static const void *kSPKDirectVisualObservedInputViewAssocKey = &kSPKDirectVisualObservedInputViewAssocKey;
static const void *kSPKDirectVisualHasInputObserverAssocKey = &kSPKDirectVisualHasInputObserverAssocKey;
static void *kSPKDirectVisualInputAlphaObserverContext = &kSPKDirectVisualInputAlphaObserverContext;

static id SPKKVCObject(id target, NSString *key);

static inline BOOL SPKDirectManualSeenRulesEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_manual_seen"] || SPKDirectManualSeenThreadCount(NO) > 0;
}

static inline BOOL SPKDirectSeenHooksNeeded(void) {
    return SPKDirectManualSeenRulesEnabled() ||
           [SPKUtils getBoolPref:@"msgs_manual_visual_seen"] ||
           [SPKUtils getBoolPref:@"msgs_advance_visual_on_seen"];
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
        NSMutableArray *array = [NSMutableArray array];
        for (id item in collection) {
            [array addObject:item];
        }
        return array;
    }

    return nil;
}

static id SPKKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;

    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKObjectForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static void SPKPlayButtonTappedHaptic(void) {
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}
static UIButton *SPKStorySeenButtonWithTag(UIView *container, NSInteger tag) {
    UIView *existing = [container viewWithTag:tag];
    if ([existing isKindOfClass:SPKChromeButton.class]) {
        return (UIButton *)existing;
    }
    [existing removeFromSuperview];

    SPKChromeButton *button = [[SPKChromeButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:44.0];
    button.tag = tag;
    button.adjustsImageWhenHighlighted = YES;
    button.showsMenuAsPrimaryAction = NO;
    button.clipsToBounds = NO;
    [container addSubview:button];
    return button;
}

static void SPKSetSeenButtonImage(UIButton *button, UIImage *image, NSString *logMessage) {
    UIImage *templatedImage = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if ([button isKindOfClass:SPKChromeButton.class]) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        chromeButton.iconView.image = templatedImage;
        chromeButton.iconTint = UIColor.whiteColor;
        [button setImage:nil forState:UIControlStateNormal];
    } else {
        [button setImage:templatedImage forState:UIControlStateNormal];
    }

    SPKLog(@"Capture", @"%@ tag=%ld button=%@<%p> subviews=%@ imageView=%@<%p> imageSuperview=%@<%p>",
           logMessage,
           (long)button.tag,
           NSStringFromClass(button.class),
           button,
           button.subviews,
           NSStringFromClass(button.imageView.class),
           button.imageView,
           NSStringFromClass(button.imageView.superview.class),
           button.imageView.superview);
}

static void SPKApplyStorySeenButtonStyle(UIButton *button) {
    if (!button)
        return;
    SPKApplyButtonStyle(button, kSPKActionButtonSourceDirect);
}

static UIView *SPKDirectOverlayViewFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id viewerContainer = [SPKUtils getIvarForObj:controller name:"_viewerContainerView"];
    if (!viewerContainer)
        viewerContainer = SPKKVCObject(controller, @"viewerContainerView");

    SEL overlaySelector = NSSelectorFromString(@"overlayView");
    if (![viewerContainer respondsToSelector:overlaySelector])
        return nil;
    id overlay = ((id (*)(id, SEL))objc_msgSend)(viewerContainer, overlaySelector);
    return [overlay isKindOfClass:[UIView class]] ? (UIView *)overlay : nil;
}

static id SPKDirectCurrentMessageFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    id message = [SPKUtils getIvarForObj:dataSource name:"_currentMessage"];
    if (!message)
        message = SPKKVCObject(dataSource, @"currentMessage");
    return message;
}

static NSInteger SPKDirectCurrentIndexFromController(UIViewController *controller) {
    if (!controller)
        return 0;

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (NSString *selectorName in @[ @"currentItemIndex", @"currentIndex", @"itemIndex" ]) {
        NSNumber *index = [SPKUtils numericValueForObj:dataSource selectorName:selectorName];
        if (index && index.integerValue >= 0)
            return index.integerValue;
    }

    for (NSString *key in @[ @"currentItemIndex", @"currentIndex", @"itemIndex" ]) {
        id value = SPKKVCObject(dataSource, key);
        if ([value respondsToSelector:@selector(integerValue)] && [value integerValue] >= 0) {
            return [value integerValue];
        }
    }

    return 0;
}

static CGFloat SPKHeightFromFrameLikeObject(id object) {
    if (!object)
        return 0.0;

    if ([object isKindOfClass:[UIView class]]) {
        return ((UIView *)object).frame.size.height;
    }

    @try {
        id frameValue = [object valueForKey:@"frame"];
        if ([frameValue isKindOfClass:[NSValue class]]) {
            return ((NSValue *)frameValue).CGRectValue.size.height;
        }
    } @catch (__unused NSException *exception) {
    }

    return 0.0;
}

static CGFloat SPKDirectBottomOffset(UIViewController *controller) {
    if (!controller)
        return 12.0;

    id inputView = [SPKUtils getIvarForObj:controller name:"_inputView"];
    CGFloat offset = controller.view.safeAreaInsets.bottom + 12.0;
    if (inputView) {
        offset += SPKHeightFromFrameLikeObject(inputView);
    }

    return offset;
}

static UIView *SPKDirectInputViewFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id inputView = [SPKUtils getIvarForObj:controller name:"_inputView"];
    if (![inputView isKindOfClass:[UIView class]]) {
        inputView = SPKKVCObject(controller, @"inputView");
    }
    return [inputView isKindOfClass:[UIView class]] ? (UIView *)inputView : nil;
}

static void SPKUpdateDirectVisualButtonsAlpha(UIViewController *controller, CGFloat alpha) {
    if (!controller)
        return;
    UIView *overlay = SPKDirectOverlayViewFromController(controller);
    if (!overlay)
        return;

    UIButton *actionButton = (UIButton *)[overlay viewWithTag:kSPKDirectActionButtonTag];
    if ([actionButton isKindOfClass:[UIButton class]]) {
        actionButton.alpha = alpha;
    }

    UIButton *seenButton = (UIButton *)[overlay viewWithTag:kSPKDirectSeenButtonTag];
    if ([seenButton isKindOfClass:[UIButton class]]) {
        seenButton.alpha = alpha;
    }
}

static void SPKRemoveDirectVisualInputAlphaObserverIfNeeded(UIViewController *controller) {
    UIView *observedInputView = objc_getAssociatedObject(controller, kSPKDirectVisualObservedInputViewAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(controller, kSPKDirectVisualHasInputObserverAssocKey) boolValue];
    if (observedInputView && hasObserver) {
        [observedInputView removeObserver:controller forKeyPath:@"alpha" context:kSPKDirectVisualInputAlphaObserverContext];
    }

    objc_setAssociatedObject(controller, kSPKDirectVisualObservedInputViewAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, kSPKDirectVisualHasInputObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKEnsureDirectVisualInputAlphaObserver(UIViewController *controller) {
    if (!controller)
        return;

    UIView *inputView = SPKDirectInputViewFromController(controller);
    UIView *observedInputView = objc_getAssociatedObject(controller, kSPKDirectVisualObservedInputViewAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(controller, kSPKDirectVisualHasInputObserverAssocKey) boolValue];
    if (observedInputView && observedInputView != inputView && hasObserver) {
        [observedInputView removeObserver:controller forKeyPath:@"alpha" context:kSPKDirectVisualInputAlphaObserverContext];
        objc_setAssociatedObject(controller, kSPKDirectVisualHasInputObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hasObserver = NO;
    }

    if (observedInputView != inputView) {
        objc_setAssociatedObject(controller, kSPKDirectVisualObservedInputViewAssocKey, inputView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (inputView && !hasObserver) {
        [inputView addObserver:controller
                    forKeyPath:@"alpha"
                       options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                       context:kSPKDirectVisualInputAlphaObserverContext];
        objc_setAssociatedObject(controller, kSPKDirectVisualHasInputObserverAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static inline BOOL SPKShouldShowDirectVisualSeenButton(void) {
    return [SPKUtils getBoolPref:@"msgs_manual_seen"] || [SPKUtils getBoolPref:@"msgs_manual_visual_seen"];
}

static BOOL SPKDirectInvokeNoArgSelector(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector])
        return NO;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
    return YES;
}

static BOOL SPKDirectInvokeObjectArgSelector(id object, SEL selector, id argument) {
    if (!object || !selector || ![object respondsToSelector:selector])
        return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
    return YES;
}

static BOOL SPKDirectInvokeIntegerArgSelector(id object, SEL selector, NSInteger argument) {
    if (!object || !selector || ![object respondsToSelector:selector])
        return NO;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, argument);
    return YES;
}

static BOOL SPKDirectInvokeDismissShowNextSelector(id object) {
    SEL selector = NSSelectorFromString(@"dismissWithShowNext:completion:");
    if (!object || ![object respondsToSelector:selector])
        return NO;
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(object, selector, YES, nil);
    return YES;
}

static NSArray *SPKDirectVisualAdvanceTargets(UIViewController *controller) {
    if (!controller)
        return @[];

    NSMutableArray *targets = [NSMutableArray array];
    NSArray<NSString *> *keys = @[
        @"_presentationManager",
        @"presentationManager",
        @"_viewerPresentationManager",
        @"viewerPresentationManager",
        @"_viewerContainerView",
        @"viewerContainerView",
        @"_viewerContainer",
        @"viewerContainer",
        @"_dataSource",
        @"dataSource",
        @"_delegate",
        @"delegate",
        @"_viewModel",
        @"viewModel"
    ];

    for (NSString *key in keys) {
        id target = [key hasPrefix:@"_"] ? [SPKUtils getIvarForObj:controller name:key.UTF8String] : SPKKVCObject(controller, key);
        if (target && ![targets containsObject:target]) {
            [targets addObject:target];
        }
    }

    if (![targets containsObject:controller]) {
        [targets addObject:controller];
    }

    return targets;
}

static BOOL SPKDirectAdvanceVisualViewer(UIViewController *controller) {
    if (!controller)
        return NO;

    SEL overlayTapSelector = NSSelectorFromString(@"fullscreenOverlay:didTapInRegion:");
    if ([controller respondsToSelector:overlayTapSelector]) {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(controller, overlayTapSelector, nil, 3);
        return YES;
    }

    NSArray *targets = SPKDirectVisualAdvanceTargets(controller);

    for (id target in targets) {
        if (SPKDirectInvokeDismissShowNextSelector(target))
            return YES;
    }

    NSArray<NSString *> *integerSelectors = @[
        @"advanceToNextItemWithNavigationAction:",
        @"advanceToNextItemWithNavigationType:",
        @"advanceToNextItemForNavigationAction:",
        @"moveToNextItemWithNavigationAction:",
        @"navigateToNextItemWithNavigationAction:"
    ];
    for (id target in targets) {
        for (NSString *selectorName in integerSelectors) {
            if (SPKDirectInvokeIntegerArgSelector(target, NSSelectorFromString(selectorName), 1))
                return YES;
        }
    }

    NSArray<NSString *> *noArgSelectors = @[
        @"_advanceToNextItem",
        @"advanceToNextItem",
        @"moveToNextItem",
        @"navigateToNextItem",
        @"displayNextItem",
        @"showNextItem",
        @"goToNextItem"
    ];
    for (id target in targets) {
        for (NSString *selectorName in noArgSelectors) {
            if (SPKDirectInvokeNoArgSelector(target, NSSelectorFromString(selectorName)))
                return YES;
        }
    }

    overlayTapSelector = NSSelectorFromString(@"expandOverlay:didTapInRegion:");
    if ([controller respondsToSelector:overlayTapSelector]) {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(controller, overlayTapSelector, nil, 3);
        return YES;
    }

    return SPKDirectInvokeObjectArgSelector(controller, NSSelectorFromString(@"_didTapHeaderViewDismissButton:"), nil);
}

static void SPKMarkDirectVisualMessageAsSeen(UIViewController *controller) {
    if (!controller)
        return;

    id message = SPKDirectCurrentMessageFromController(controller);
    if (!message) {
        SPKNotify(kSPKNotificationDirectVisualMarkSeen, SPKL(@"MESSAGES_DIRECT_VISUAL_SEEN_BUTTONS_MESSAGE_NOT_FOUND_MESSAGE"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }

    id responders = [SPKUtils getIvarForObj:controller name:"_eventResponders"];
    if (!responders)
        responders = SPKKVCObject(controller, @"eventResponders");

    SEL beginPlaybackSelector = NSSelectorFromString(@"visualMessageViewerController:didBeginPlaybackForVisualMessage:atIndex:");
    Class eventHandlerClass = NSClassFromString(@"IGDirectVisualMessageViewerEventHandler");
    NSArray *responderCollection = SPKArrayFromCollection(responders);
    NSMutableArray *orderedResponders = [NSMutableArray array];
    for (id responder in responderCollection ?: (responders ? @[ responders ] : @[])) {
        if (eventHandlerClass && [responder isKindOfClass:eventHandlerClass]) {
            [orderedResponders addObject:responder];
        }
    }
    for (id responder in responderCollection ?: (responders ? @[ responders ] : @[])) {
        if (![orderedResponders containsObject:responder]) {
            [orderedResponders addObject:responder];
        }
    }

    BOOL dispatched = NO;

    // Marking a visual message seen sends a read receipt for its chat, which the
    // receipt guard drops unless Sparkle announces it first. A nil chat id still
    // lets the receipt through.
    SPKDirectSeenReceiptGuardAllow(SPKDirectThreadContextFromSource(controller).threadId);
    SPKPendingDirectVisualMessageToMarkSeen = message;
    @try {
        for (id responder in orderedResponders) {
            if ([responder respondsToSelector:beginPlaybackSelector]) {
                dispatched = YES;
                ((void (*)(id, SEL, id, id, NSInteger))objc_msgSend)(responder, beginPlaybackSelector, controller, message, 0);
            }
        }
    } @finally {
        SPKPendingDirectVisualMessageToMarkSeen = nil;
    }
    if (!dispatched) {
        SPKNotify(kSPKNotificationDirectVisualMarkSeen, SPKL(@"MESSAGE_ERROR_MARK_SEEN_FAILED"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }

    if ([SPKUtils getBoolPref:@"msgs_advance_visual_on_seen"]) {
        __weak UIViewController *weakController = controller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKDirectAdvanceVisualViewer(weakController);
        });
    }

    SPKNotify(kSPKNotificationDirectVisualMarkSeen, SPKL(@"MESSAGES_DIRECT_VISUAL_SEEN_BUTTONS_MARKED_SEEN_TEXT"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

static void SPKInstallDirectSeenButton(UIViewController *controller) {
    UIView *overlay = SPKDirectOverlayViewFromController(controller);
    if (!overlay)
        return;

    UIButton *seenButton = (UIButton *)[overlay viewWithTag:kSPKDirectSeenButtonTag];
    if (!SPKShouldShowDirectVisualSeenButton()) {
        [seenButton removeFromSuperview];
        return;
    }

    if (![seenButton isKindOfClass:SPKChromeButton.class]) {
        [seenButton removeFromSuperview];
        seenButton = SPKStorySeenButtonWithTag(overlay, kSPKDirectSeenButtonTag);
        seenButton.tag = kSPKDirectSeenButtonTag;
        seenButton.adjustsImageWhenHighlighted = YES;
        UIImage *seenImage = [SPKAssetUtils instagramIconNamed:kSPKSeenMessagesBarIconResource pointSize:24.0];
        SPKSetSeenButtonImage(seenButton, seenImage, @"Direct seen custom icon assigned");
        [seenButton addTarget:controller action:@selector(spk_didTapDirectSeenButton:) forControlEvents:UIControlEventTouchUpInside];
    }

    seenButton.translatesAutoresizingMaskIntoConstraints = NO;
    SPKApplyStorySeenButtonStyle(seenButton);

    CGFloat size = 44.0;
    CGFloat bottomOffset = SPKDirectBottomOffset(controller);
    UIButton *actionButton = (UIButton *)[overlay viewWithTag:kSPKDirectActionButtonTag];
    BOOL actionVisible = [actionButton isKindOfClass:[UIButton class]] && !actionButton.hidden && actionButton.superview == overlay && CGRectGetWidth(actionButton.bounds) > 0.0 && CGRectGetHeight(actionButton.bounds) > 0.0;

    NSLayoutConstraint *bottomConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenBottomConstraintAssocKey);
    NSLayoutConstraint *trailingOverlayConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenTrailingOverlayConstraintAssocKey);
    NSLayoutConstraint *trailingActionConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenTrailingActionConstraintAssocKey);
    NSLayoutConstraint *centerYActionConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenCenterYActionConstraintAssocKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenWidthConstraintAssocKey);
    NSLayoutConstraint *heightConstraint = objc_getAssociatedObject(seenButton, kSPKDirectSeenHeightConstraintAssocKey);
    UIButton *anchoredActionButton = objc_getAssociatedObject(seenButton, kSPKDirectSeenAnchoredActionButtonAssocKey);

    if (!bottomConstraint || !trailingOverlayConstraint || !widthConstraint || !heightConstraint) {
        bottomConstraint = [seenButton.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor constant:-bottomOffset];
        trailingOverlayConstraint = [seenButton.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-10.0];
        widthConstraint = [seenButton.widthAnchor constraintEqualToConstant:size];
        heightConstraint = [seenButton.heightAnchor constraintEqualToConstant:size];

        [NSLayoutConstraint activateConstraints:@[
            bottomConstraint,
            trailingOverlayConstraint,
            widthConstraint,
            heightConstraint
        ]];

        objc_setAssociatedObject(seenButton, kSPKDirectSeenBottomConstraintAssocKey, bottomConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(seenButton, kSPKDirectSeenTrailingOverlayConstraintAssocKey, trailingOverlayConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(seenButton, kSPKDirectSeenWidthConstraintAssocKey, widthConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(seenButton, kSPKDirectSeenHeightConstraintAssocKey, heightConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (actionVisible && (!trailingActionConstraint || anchoredActionButton != actionButton)) {
        if (trailingActionConstraint) {
            trailingActionConstraint.active = NO;
        }
        trailingActionConstraint = [seenButton.trailingAnchor constraintEqualToAnchor:actionButton.leadingAnchor constant:-5.0];
        objc_setAssociatedObject(seenButton, kSPKDirectSeenTrailingActionConstraintAssocKey, trailingActionConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(seenButton, kSPKDirectSeenAnchoredActionButtonAssocKey, actionButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (actionVisible && (!centerYActionConstraint || anchoredActionButton != actionButton)) {
        if (centerYActionConstraint) {
            centerYActionConstraint.active = NO;
        }
        centerYActionConstraint = [seenButton.centerYAnchor constraintEqualToAnchor:actionButton.centerYAnchor];
        objc_setAssociatedObject(seenButton, kSPKDirectSeenCenterYActionConstraintAssocKey, centerYActionConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    bottomConstraint.constant = -bottomOffset;
    trailingOverlayConstraint.constant = -10.0;
    widthConstraint.constant = size;
    heightConstraint.constant = size;

    if (actionVisible && trailingActionConstraint) {
        bottomConstraint.active = NO;
        trailingOverlayConstraint.active = NO;
        trailingActionConstraint.active = YES;
        if (centerYActionConstraint)
            centerYActionConstraint.active = YES;
    } else {
        if (centerYActionConstraint)
            centerYActionConstraint.active = NO;
        if (trailingActionConstraint)
            trailingActionConstraint.active = NO;
        trailingOverlayConstraint.active = YES;
        bottomConstraint.active = YES;
    }

    [overlay bringSubviewToFront:seenButton];
}

%group SPKDirectVisualSeenButtonHooks

%hook IGDirectVisualMessageViewerController
- (void)viewDidLayoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"DirectVisualSeenButtons.viewDidLayoutSubviews");
    if (!SPKDirectSeenHooksNeeded())
        return;
    UIView *inputView = SPKDirectInputViewFromController((UIViewController *)self);
    SPKEnsureDirectVisualInputAlphaObserver((UIViewController *)self);
    SPKInstallDirectSeenButton((UIViewController *)self);
    SPKUpdateDirectVisualButtonsAlpha((UIViewController *)self, inputView ? inputView.alpha : 1.0);
    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController)
            return;
        UIView *strongInputView = SPKDirectInputViewFromController(strongController);
        SPKInstallDirectSeenButton(strongController);
        SPKUpdateDirectVisualButtonsAlpha(strongController, strongInputView ? strongInputView.alpha : 1.0);
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (!SPKDirectSeenHooksNeeded()) {
        %orig(keyPath, object, change, context);
        return;
    }
    if (context == kSPKDirectVisualInputAlphaObserverContext && [keyPath isEqualToString:@"alpha"]) {
        CGFloat alpha = 1.0;
        id newAlphaValue = change[NSKeyValueChangeNewKey];
        if ([newAlphaValue respondsToSelector:@selector(floatValue)]) {
            alpha = [newAlphaValue floatValue];
        } else if ([object isKindOfClass:[UIView class]]) {
            alpha = ((UIView *)object).alpha;
        }
        SPKUpdateDirectVisualButtonsAlpha((UIViewController *)self, alpha);
        return;
    }

    %orig(keyPath, object, change, context);
}

- (void)dealloc {
    SPKRemoveDirectVisualInputAlphaObserverIfNeeded((UIViewController *)self);
    %orig;
}

%new - (void)spk_didTapDirectSeenButton:(UIButton *)sender {
(void)sender;
SPKPlayButtonTappedHaptic();
SPKMarkDirectVisualMessageAsSeen((UIViewController *)self);
}
%end

%end

void SPKInstallDirectVisualSeenButtonHooksIfNeeded(void) {
    if (!SPKDirectSeenHooksNeeded())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDirectVisualSeenButtonHooks);
    });
}
