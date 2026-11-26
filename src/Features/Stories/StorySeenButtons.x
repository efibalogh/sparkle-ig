#import <objc/message.h>
#import "SPKStrings.h"
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Shared/Stories/SPKStoryButtonPlacement.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/Stories/SPKStoryDynamicRange.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"
#ifdef __cplusplus
extern "C" {
#endif
void SPKApplyButtonStyle(UIButton *button, NSInteger source);
BOOL SPKActionButtonMenuIsTransitioning(UIView *button);
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif
void SPKUpdateStoryMentionsButton(UIView *overlayView, CGFloat x, CGFloat y, CGFloat size);
void SPKRemoveStoryMentionsButton(UIView *overlayView);
#ifdef __cplusplus
}
#endif

static NSString *const kSPKSeenMessagesBarIconResource = @"eye";
static NSInteger const kSPKActionButtonSourceDirect = 4;
static NSInteger const kSPKStorySeenButtonTag = 926001;
static NSInteger const kSPKStoryMentionsButtonTag = 926002;
static NSInteger const kSPKStoriesActionButtonTag = 921343;
static const void *kSPKStoryOverlayObservedFooterAssocKey = &kSPKStoryOverlayObservedFooterAssocKey;
static const void *kSPKStoryOverlayHasObserverAssocKey = &kSPKStoryOverlayHasObserverAssocKey;
static void *kSPKStoryOverlayAlphaObserverContext = &kSPKStoryOverlayAlphaObserverContext;
static __weak UIView *SPKActiveStoryOverlayView = nil;

static id SPKObjectForSelector(id target, NSString *selectorName);
void SPKMarkStoryAsSeenForViewWithAdvancePref(UIView *view, NSString *advancePrefKey);

static inline BOOL SPKManualStorySeenEnabled(void) {
    return SPKStoryManualSeenEnabled();
}
static inline BOOL SPKStorySeenHooksNeeded(void) {
    return SPKStoryManualSeenEnabled() ||
           SPKStoryManualSeenUserList(NO).count > 0 ||
           [SPKUtils getBoolPref:@"stories_mentions_btn"] ||
           [SPKUtils getBoolPref:@"stories_mark_seen_on_reply"] ||
           [SPKUtils getBoolPref:@"stories_advance_on_reply_seen"];
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
static BOOL SPKOverlayIsDirectVisualOverlay(UIView *overlayView) {
    static Class directViewerClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        directViewerClass = NSClassFromString(@"IGDirectVisualMessageViewerController");
    });
    if (!directViewerClass)
        return NO;
    UIViewController *nearestVC = [SPKUtils nearestViewControllerForView:overlayView];
    return [nearestVC isKindOfClass:directViewerClass];
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
    SPKStoryApplyDynamicRangeToButton(button);
}

static UIView *SPKStoryFooterContainerFromOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    UIView *footerContainer = [SPKUtils getIvarForObj:overlayView name:"_footerContainerView"];
    if (![footerContainer isKindOfClass:[UIView class]]) {
        id selectorFooter = SPKObjectForSelector(overlayView, @"footerContainerView");
        footerContainer = [selectorFooter isKindOfClass:[UIView class]] ? (UIView *)selectorFooter : nil;
    }
    return footerContainer;
}

static void SPKUpdateStoryButtonsAlpha(UIView *overlayView, CGFloat alpha) {
    if (!overlayView)
        return;

    // Our buttons are added directly to the overlay, so a single non-recursive
    // pass over the immediate subviews avoids three full-subtree -viewWithTag:
    // searches. This runs on every cross-fade frame via the footer alpha KVO,
    // so keeping it cheap matters during story-to-story transitions.
    for (UIView *subview in overlayView.subviews) {
        NSInteger tag = subview.tag;
        if (tag == kSPKStoriesActionButtonTag || tag == kSPKStorySeenButtonTag || tag == kSPKStoryMentionsButtonTag) {
            // The action button's menu morph owns its alpha until it completes.
            if (tag == kSPKStoriesActionButtonTag && SPKActionButtonMenuIsTransitioning(subview))
                continue;
            if (ABS(subview.alpha - alpha) > 0.001)
                subview.alpha = alpha;
        }
    }
}

static void SPKRemoveStoryOverlayAlphaObserverIfNeeded(UIView *overlayView) {
    UIView *observedFooter = objc_getAssociatedObject(overlayView, kSPKStoryOverlayObservedFooterAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(overlayView, kSPKStoryOverlayHasObserverAssocKey) boolValue];
    if (observedFooter && hasObserver) {
        [observedFooter removeObserver:overlayView forKeyPath:@"alpha" context:kSPKStoryOverlayAlphaObserverContext];
    }

    objc_setAssociatedObject(overlayView, kSPKStoryOverlayObservedFooterAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlayView, kSPKStoryOverlayHasObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKEnsureStoryOverlayAlphaObserver(UIView *overlayView) {
    if (!overlayView)
        return;

    UIView *footerContainer = SPKStoryFooterContainerFromOverlay(overlayView);
    UIView *observedFooter = objc_getAssociatedObject(overlayView, kSPKStoryOverlayObservedFooterAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(overlayView, kSPKStoryOverlayHasObserverAssocKey) boolValue];
    if (observedFooter && observedFooter != footerContainer && hasObserver) {
        [observedFooter removeObserver:overlayView forKeyPath:@"alpha" context:kSPKStoryOverlayAlphaObserverContext];
        objc_setAssociatedObject(overlayView, kSPKStoryOverlayHasObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hasObserver = NO;
    }

    if (observedFooter != footerContainer) {
        objc_setAssociatedObject(overlayView, kSPKStoryOverlayObservedFooterAssocKey, footerContainer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (footerContainer && !hasObserver) {
        [footerContainer addObserver:overlayView
                          forKeyPath:@"alpha"
                             options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                             context:kSPKStoryOverlayAlphaObserverContext];
        objc_setAssociatedObject(overlayView, kSPKStoryOverlayHasObserverAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static CGRect SPKStorySeenBaseFrame(UIView *overlayView) {
    // Match the SPKChromeButton diameter (44) and the stories action button size so
    // the seen/mentions buttons keep the same size and trailing anchor whether or not
    // the action button is present.
    return SPKStoryFloatingButtonFrame(overlayView, 44.0);
}

// Forward declaration — implemented in StoryMentions.x
extern void SPKPresentStoryMentionsSheet(UIView *overlayView);

static void SPKMarkCurrentStoryAsSeenFromOverlayWithAdvancePref(UIView *overlayView, NSString *advancePrefKey) {
    if (!overlayView)
        return;

    SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(overlayView);
    if (!SPKStoryMarkContextAsSeen(sharedContext)) {
        SPKNotify(kSPKNotificationStoryMarkSeen, SPKL(@"STORY_ERROR_MARK_SEEN_FAILED"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }
    SPKStoryAdvanceContextIfNeeded(sharedContext, advancePrefKey);
    SPKNotify(kSPKNotificationStoryMarkSeen, SPKL(@"STORIES_STORY_SEEN_BUTTONS_MARKED_STORY_SEEN_TEXT"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

static void SPKMarkCurrentStoryAsSeenFromOverlay(UIView *overlayView) {
    SPKMarkCurrentStoryAsSeenFromOverlayWithAdvancePref(overlayView, @"stories_advance_on_manual_seen");
}

static const void *kSPKStorySeenButtonLastIconAssocKey = &kSPKStorySeenButtonLastIconAssocKey;

/// The eye is plain until toggle mode turns seen receipts on, then crossed out
/// to show that tapping again stops them.
static void SPKUpdateStorySeenButtonIcon(UIButton *button) {
    if (!button)
        return;
    BOOL crossedOut = SPKStorySeenReceiptsSessionEnabled();
    NSNumber *lastIcon = objc_getAssociatedObject(button, kSPKStorySeenButtonLastIconAssocKey);
    if (lastIcon && lastIcon.boolValue == crossedOut)
        return;
    objc_setAssociatedObject(button, kSPKStorySeenButtonLastIconAssocKey, @(crossedOut), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *image = [SPKAssetUtils instagramIconNamed:(crossedOut ? @"eye_off" : kSPKSeenMessagesBarIconResource) pointSize:24.0];
    void (^applyImage)(void) = ^{
        SPKSetSeenButtonImage(button, image, @"Story seen icon updated");
        // Setting the image resets the tint to SDR white.
        SPKApplyStorySeenButtonStyle(button);
    };

    UIImageView *iconView = [button isKindOfClass:SPKChromeButton.class] ? ((SPKChromeButton *)button).iconView : nil;
    // The first assignment after the button appears is not a state change.
    if (!lastIcon || !iconView) {
        applyImage();
        return;
    }

    iconView.transform = CGAffineTransformMakeScale(0.78, 0.78);
    iconView.alpha = 0.65;
    [UIView transitionWithView:iconView
                      duration:0.16
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionBeginFromCurrentState |
                               UIViewAnimationOptionAllowAnimatedContent
                    animations:applyImage
                    completion:nil];
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.70
          initialSpringVelocity:0.55
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         iconView.transform = CGAffineTransformIdentity;
                         iconView.alpha = 1.0;
                     }
                     completion:nil];
}

static UIViewController *SPKStoryViewerControllerForOverlay(UIView *overlayView) {
    Class viewerClass = NSClassFromString(@"IGStoryViewerViewController");
    for (UIResponder *responder = overlayView; responder; responder = responder.nextResponder) {
        if (viewerClass && [responder isKindOfClass:viewerClass])
            return (UIViewController *)responder;
    }
    return nil;
}

static void SPKToggleStorySeenReceiptsFromOverlay(UIView *overlayView) {
    BOOL enable = !SPKStorySeenReceiptsSessionEnabled();
    __weak UIView *weakOverlay = overlayView;
    void (^apply)(void) = ^{
        UIView *overlay = weakOverlay;
        if (enable) {
            // The session ends when this viewer disappears, like the story audio toggle.
            UIViewController *viewer = SPKStoryViewerControllerForOverlay(overlay);
            if (!viewer) {
                SPKLog(@"Stories", @"[Sparkle StorySeen] No story viewer found for the seen receipts toggle");
                return;
            }
            SPKStorySetSeenReceiptsSessionViewer(viewer);
            // IG already skipped reporting the story on screen, so send it now.
            SPKStoryContext *context = SPKStoryContextFromOverlay(overlay);
            if (context && SPKStoryManualSeenAppliesToContext(context) && !SPKStoryMarkContextAsSeen(context)) {
                SPKLog(@"Stories", @"[Sparkle StorySeen] Seen receipts on, but the current story could not be marked");
            }
            SPKNotify(kSPKNotificationStoryMarkSeen, SPKL(@"STORIES_STORY_SEEN_BUTTONS_RECEIPTS_ON_TEXT"), SPKL(@"STORIES_STORY_SEEN_BUTTONS_RECEIPTS_ON_SUBTITLE"), @"eye", SPKNotificationToneSuccess);
        } else {
            SPKStorySetSeenReceiptsSessionViewer(nil);
            SPKNotify(kSPKNotificationStoryMarkSeen, SPKL(@"STORIES_STORY_SEEN_BUTTONS_RECEIPTS_OFF_TEXT"), nil, @"eye_off", SPKNotificationToneSuccess);
        }
        SPKUpdateStorySeenButtonIcon((UIButton *)[overlay viewWithTag:kSPKStorySeenButtonTag]);
    [overlay setNeedsLayout];
    };

    if (enable && [SPKUtils getBoolPref:@"stories_confirm_mark_seen"]) {
        [SPKUtils showConfirmation:apply
                             title:SPKL(@"STORIES_STORY_SEEN_BUTTONS_CONFIRM_RECEIPTS_ON_TITLE")
                           message:SPKL(@"STORIES_STORY_SEEN_BUTTONS_CONFIRM_RECEIPTS_ON_MESSAGE")];
        return;
    }
    apply();
}

void SPKMarkStoryAsSeenForViewWithAdvancePref(UIView *view, NSString *advancePrefKey) {
    UIView *walker = view;
    for (NSInteger depth = 0; walker && depth < 24; depth++, walker = walker.superview) {
        if ([walker isKindOfClass:%c(IGStoryFullscreenOverlayView)]) {
            SPKMarkCurrentStoryAsSeenFromOverlayWithAdvancePref(walker, advancePrefKey);
            return;
        }
    }
}

UIView *SPKActiveStoryOverlayForInteractions(void) {
    return SPKStoryActiveOverlay() ?: SPKActiveStoryOverlayView;
}

%group SPKStorySeenButtonHooks

%hook IGStoryFullscreenOverlayView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StorySeenButtons.layoutSubviews");

    UIView *overlayView = (UIView *)self;
    SPKActiveStoryOverlayView = overlayView;
    SPKStorySetActiveOverlay(overlayView);
    SPKEnsureStoryOverlayAlphaObserver(overlayView);

    UIButton *seenButton = (UIButton *)[(UIView *)self viewWithTag:kSPKStorySeenButtonTag];
    if (SPKOverlayIsDirectVisualOverlay((UIView *)self)) {
        [seenButton removeFromSuperview];
        SPKRemoveStoryMentionsButton(overlayView);
        UIView *footerContainer = SPKStoryFooterContainerFromOverlay(overlayView);
        if (footerContainer) {
            SPKUpdateStoryButtonsAlpha(overlayView, footerContainer.alpha);
        }
        return;
    }

    SPKStoryContext *storyContext = SPKStoryContextFromOverlay(overlayView);
    BOOL showSeenButton = SPKStoryManualSeenAppliesToContext(storyContext);
    if (!showSeenButton && SPKManualStorySeenEnabled() && SPKStoryManualSeenListContainsUser(SPKStoryUserPKFromMediaObject(storyContext.media), YES)) {
        static NSMutableSet<NSString *> *autoSeenMarked;
        static dispatch_once_t autoSeenOnceToken;
        dispatch_once(&autoSeenOnceToken, ^{
            autoSeenMarked = [NSMutableSet set];
        });
        NSString *mediaIdentifier = SPKStoryMediaIdentifierForContext(storyContext);
        if (mediaIdentifier.length > 0 && ![autoSeenMarked containsObject:mediaIdentifier]) {
            [autoSeenMarked addObject:mediaIdentifier];
            SPKStoryMarkContextAsSeen(storyContext);
        }
    }
    if (!showSeenButton) {
        [seenButton removeFromSuperview];
        UIView *footerContainer = SPKStoryFooterContainerFromOverlay(overlayView);
        if (footerContainer) {
            SPKUpdateStoryButtonsAlpha(overlayView, footerContainer.alpha);
        }
    }

    if (showSeenButton && !seenButton) {
        seenButton = SPKStorySeenButtonWithTag((UIView *)self, kSPKStorySeenButtonTag);
        [seenButton addTarget:self action:@selector(spk_storySeenButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(spk_storySeenButtonLongPressed:)];
        longPress.minimumPressDuration = 0.5;
        [seenButton addGestureRecognizer:longPress];

        UIImage *seenImage = [SPKAssetUtils instagramIconNamed:kSPKSeenMessagesBarIconResource pointSize:24.0];
        SPKSetSeenButtonImage(seenButton, seenImage, @"Story seen custom icon assigned");
    }
    if (showSeenButton) {
        SPKApplyStorySeenButtonStyle(seenButton);
        SPKUpdateStorySeenButtonIcon(seenButton);
    }

    // The row is placed from the shared trailing frame, the same one the
    // action button uses, rather than from the action button's current frame:
    // that one is updated from other layout passes, and while its menu morphs
    // UIKit hides it, so copying it left the row a pass behind or jumping into
    // the action button's slot.
    UIButton *storyActionButton = (UIButton *)[overlayView viewWithTag:kSPKStoriesActionButtonTag];
    BOOL actionVisible = [storyActionButton isKindOfClass:[UIButton class]] && storyActionButton.superview == overlayView &&
                         (!storyActionButton.hidden || SPKActionButtonMenuIsTransitioning(storyActionButton));
    CGRect baseFrame = SPKStorySeenBaseFrame(overlayView);
    CGFloat size = CGRectGetWidth(baseFrame);
    if (size <= 0.0)
        size = 44.0;

    CGFloat spacingReduction = 2.0;
    CGFloat y = CGRectGetMinY(baseFrame);
    CGFloat nextX = actionVisible
                        ? (CGRectGetMinX(baseFrame) - size + spacingReduction)
                        : CGRectGetMinX(baseFrame);

    if (showSeenButton && seenButton) {
        seenButton.frame = CGRectMake(nextX, y, size, size);
        [overlayView bringSubviewToFront:seenButton];
        nextX -= (size - spacingReduction);
    } else if (seenButton) {
        [seenButton removeFromSuperview];
        seenButton = nil;
    }

    SPKUpdateStoryMentionsButton(overlayView, nextX, y, size);

    UIView *footerContainer = SPKStoryFooterContainerFromOverlay(overlayView);
    if (footerContainer) {
        SPKUpdateStoryButtonsAlpha(overlayView, footerContainer.alpha);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context == kSPKStoryOverlayAlphaObserverContext && [keyPath isEqualToString:@"alpha"]) {
        CGFloat alpha = 1.0;
        id newAlphaValue = change[NSKeyValueChangeNewKey];
        if ([newAlphaValue respondsToSelector:@selector(floatValue)]) {
            alpha = [newAlphaValue floatValue];
        } else if ([object isKindOfClass:[UIView class]]) {
            alpha = ((UIView *)object).alpha;
        }
        SPKUpdateStoryButtonsAlpha((UIView *)self, alpha);
        return;
    }

    %orig(keyPath, object, change, context);
}

- (void)dealloc {
    SPKRemoveStoryOverlayAlphaObserverIfNeeded((UIView *)self);
    if (SPKStoryActiveOverlay() == (UIView *)self) {
        SPKStorySetActiveOverlay(nil);
    }
    if (SPKActiveStoryOverlayView == (UIView *)self) {
        SPKActiveStoryOverlayView = nil;
    }
    %orig;
}

%new - (void)spk_storySeenButtonTapped:(UIButton *)sender {
(void)sender;
SPKPlayButtonTappedHaptic();
if (SPKStoryEyeButtonTogglesSeenReceipts()) {
    SPKToggleStorySeenReceiptsFromOverlay((UIView *)self);
    return;
}
if (![SPKUtils getBoolPref:@"stories_confirm_mark_seen"]) {
    SPKMarkCurrentStoryAsSeenFromOverlay((UIView *)self);
    return;
}
// Resolve the overlay weakly: the viewer can advance or close while the alert is up.
__weak UIView *weakOverlay = (UIView *)self;
[SPKUtils
    showConfirmation:^{
        SPKMarkCurrentStoryAsSeenFromOverlay(weakOverlay);
    }
               title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_MARK_SEEN_TITLE")
             message:SPKL(@"STORIES_STORY_SEEN_BUTTONS_CONFIRM_MARK_SEEN_MESSAGE")];
}

%new - (void)spk_storySeenButtonLongPressed:(UILongPressGestureRecognizer *)gesture {
if (gesture.state != UIGestureRecognizerStateBegan)
    return;
SPKPlayButtonTappedHaptic();
SPKStoryContext *context = SPKStoryContextFromOverlay((UIView *)self);
NSString *title = SPKStoryCurrentUserRuleConfirmationTitle(context);
NSString *message = SPKStoryCurrentUserRuleConfirmationMessage(context);
if (title.length == 0 || message.length == 0) {
    SPKNotify(kSPKNotificationStorySeenUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
    return;
}
[SPKUtils
    showConfirmation:^{
        NSString *notificationTitle = nil;
        NSString *notificationSubtitle = nil;
        if (!SPKStoryToggleCurrentUserRule(context, &notificationTitle, &notificationSubtitle)) {
            SPKNotify(kSPKNotificationStorySeenUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return;
        }
        SPKNotify(kSPKNotificationStorySeenUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
        [(UIView *)self setNeedsLayout];
    }
               title:title
             message:message];
}

%end

void SPKInstallStorySeenButtonHooksIfNeeded(void) {
    if (!SPKStorySeenHooksNeeded())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKStorySeenButtonHooks);
    });
}
