#import "SPKStrings.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

extern void SPKMarkStoryAsSeenForViewWithAdvancePref(UIView *view, NSString *advancePrefKey);
extern UIView *SPKActiveStoryOverlayForInteractions(void);

static inline BOOL SPKStoryMarkSeenOnLikeEnabled(void) {
    return [SPKUtils getBoolPref:@"stories_mark_seen_on_like"];
}

static inline BOOL SPKStoryMarkSeenOnReplyEnabled(void) {
    return [SPKUtils getBoolPref:@"stories_mark_seen_on_reply"];
}

static inline BOOL SPKStoryQuickReactionConfirmEnabled(void) {
    return [SPKUtils getBoolPref:@"stories_confirm_quick_reaction"];
}

static inline BOOL SPKStoryInteractionHooksNeeded(void) {
    return [SPKUtils getBoolPref:@"stories_confirm_like"] ||
           SPKStoryMarkSeenOnLikeEnabled() ||
           SPKStoryMarkSeenOnReplyEnabled() ||
           [SPKUtils getBoolPref:@"stories_advance_on_like_seen"] ||
           [SPKUtils getBoolPref:@"stories_advance_on_reply_seen"] ||
           SPKStoryQuickReactionConfirmEnabled();
}

static inline id SPKObjectForSelectorIfAvailable(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL SPKBoolValueForSelector(id target, NSString *selectorName, BOOL *resolved) {
    if (resolved)
        *resolved = NO;
    if (!target || !selectorName.length)
        return NO;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const char *returnType = signature.methodReturnType;
    if (!returnType || !returnType[0])
        return NO;

    if (returnType[0] == '@') {
        id value = ((id (*)(id, SEL))objc_msgSend)(target, selector);
        if (!value)
            return NO;
        if ([value respondsToSelector:@selector(boolValue)]) {
            if (resolved)
                *resolved = YES;
            return ((BOOL (*)(id, SEL))objc_msgSend)(value, @selector(boolValue));
        }
        if ([value respondsToSelector:@selector(doubleValue)]) {
            if (resolved)
                *resolved = YES;
            return ((double (*)(id, SEL))objc_msgSend)(value, @selector(doubleValue)) != 0.0;
        }
        if ([value respondsToSelector:@selector(integerValue)]) {
            if (resolved)
                *resolved = YES;
            return ((NSInteger (*)(id, SEL))objc_msgSend)(value, @selector(integerValue)) != 0;
        }
        return NO;
    }

    NSNumber *number = [SPKUtils numericValueForObj:target selectorName:selectorName];
    if (!number)
        return NO;
    if (resolved)
        *resolved = YES;
    return [number boolValue];
}

static BOOL SPKLikeStateFromControl(id control, BOOL *resolved) {
    if (resolved)
        *resolved = NO;
    if (!control)
        return NO;
    // The reels heart (IGSundialLikeButton) keeps its state in isLiked, not selected.
    BOOL likedResolved = NO;
    BOOL liked = SPKBoolValueForSelector(control, @"isLiked", &likedResolved);
    if (likedResolved) {
        if (resolved)
            *resolved = YES;
        return liked;
    }
    if ([control isKindOfClass:[UIControl class]]) {
        if (resolved)
            *resolved = YES;
        return ((UIControl *)control).selected;
    }
    return NO;
}

static BOOL SPKLikeStateFromModel(id model, BOOL *resolved) {
    if (resolved)
        *resolved = NO;
    if (!model)
        return NO;

    for (NSString *selectorName in @[
             @"hasLiked",
             @"isLiked",
             @"isLikedByCurrentUser",
             @"viewerHasLiked",
             @"isLikedByViewer",
             @"liked"
         ]) {
        BOOL found = NO;
        BOOL liked = SPKBoolValueForSelector(model, selectorName, &found);
        if (found) {
            if (resolved)
                *resolved = YES;
            return liked;
        }
    }
    return NO;
}

static void SPKPresentLikeToggleConfirmation(BOOL isUnlike,
                                             NSString *likeTitle,
                                             NSString *likeMessage,
                                             NSString *unlikeTitle,
                                             NSString *unlikeMessage,
                                             void (^handler)(void)) {
    [SPKUtils showConfirmation:handler
                         title:(isUnlike ? unlikeTitle : likeTitle)
                         message:(isUnlike ? unlikeMessage : likeMessage)];
}

static id SPKLikeButtonFromContext(id context) {
    if (!context)
        return nil;
    id button = SPKObjectForSelectorIfAvailable(context, @"likeButton");
    if (button)
        return button;

    id ufiView = [SPKUtils getIvarForObj:context name:"_ufiButtonBarView"];
    if (!ufiView)
        ufiView = SPKObjectForSelectorIfAvailable(context, @"ufiButtonBarView");
    if (!ufiView)
        return nil;

    return SPKObjectForSelectorIfAvailable(ufiView, @"likeButton");
}

static id SPKMediaFromContext(id context) {
    if (!context)
        return nil;
    id media = [SPKUtils getIvarForObj:context name:"_media"];
    if (media)
        return media;

    media = SPKObjectForSelectorIfAvailable(context, @"media");
    if (media)
        return media;

    id viewModel = [SPKUtils getIvarForObj:context name:"_cellViewModel_DO_NOT_USE"];
    if (!viewModel)
        viewModel = SPKObjectForSelectorIfAvailable(context, @"cellViewModel");
    if (!viewModel)
        return nil;

    return SPKObjectForSelectorIfAvailable(viewModel, @"media");
}

static id SPKCommentFromContext(id context) {
    if (!context)
        return nil;
    id comment = [SPKUtils getIvarForObj:context name:"_commentModel"];
    if (comment)
        return comment;

    comment = [SPKUtils getIvarForObj:context name:"_comment"];
    if (comment)
        return comment;

    comment = SPKObjectForSelectorIfAvailable(context, @"commentModel");
    if (comment)
        return comment;

    return SPKObjectForSelectorIfAvailable(context, @"comment");
}

static BOOL SPKFeedLikeIsUnlike(id button, id context) {
    BOOL resolved = NO;
    BOOL liked = SPKLikeStateFromControl(button, &resolved);
    if (!resolved) {
        id likeButton = SPKLikeButtonFromContext(context);
        liked = SPKLikeStateFromControl(likeButton, &resolved);
    }
    if (!resolved) {
        id media = SPKMediaFromContext(context);
        liked = SPKLikeStateFromModel(media, &resolved);
    }
    return resolved && liked;
}

static BOOL SPKCommentLikeIsUnlike(id button, id context) {
    BOOL resolved = NO;
    BOOL liked = SPKLikeStateFromControl(button, &resolved);
    if (!resolved) {
        id likeButton = SPKLikeButtonFromContext(context);
        liked = SPKLikeStateFromControl(likeButton, &resolved);
    }
    if (!resolved) {
        id comment = SPKCommentFromContext(context);
        liked = SPKLikeStateFromModel(comment, &resolved);
    }
    return resolved && liked;
}

static void SPKStoryMarkSeenForInteractionView(UIView *view, NSString *advancePrefKey) {
    if (!view)
        return;
    SPKMarkStoryAsSeenForViewWithAdvancePref(view, advancePrefKey);
}

static void SPKStoryReplySideEffects(void) {
    if (!SPKStoryMarkSeenOnReplyEnabled())
        return;
    UIView *overlay = SPKActiveStoryOverlayForInteractions();
    if (!overlay)
        return;
    SPKStoryMarkSeenForInteractionView(overlay, @"stories_advance_on_reply_seen");
}

///////////////////////////////////////////////////////////

// Confirmation handlers

// Runs `block` with `flag` raised. A confirmed like re-enters the hooked chain
// (IG forwards one tap through several hooked methods), and the raised flag lets
// those forwarded calls through instead of prompting again.
static void SPKRunWithLikeConfirmBypass(BOOL *flag, void (^block)(void)) {
    BOOL previous = *flag;
    *flag = YES;
    @try {
        block();
    } @finally {
        *flag = previous;
    }
}

// Shows the like or unlike prompt and, on Confirm, runs `proceed` with `bypass`
// raised.
static void SPKPresentLikeConfirmation(BOOL isUnlike,
                                       NSString *likeTitle,
                                       NSString *likeMessage,
                                       NSString *unlikeTitle,
                                       NSString *unlikeMessage,
                                       BOOL *bypass,
                                       void (^proceed)(void)) {
    void (^confirmed)(void) = [proceed copy];
    SPKPresentLikeToggleConfirmation(isUnlike, likeTitle, likeMessage, unlikeTitle, unlikeMessage, ^{
        SPKRunWithLikeConfirmBypass(bypass, confirmed);
    });
}

static BOOL SPKBypassFeedPostLikeConfirm = NO;

// The reels heart's touch-up-inside action can reach a hooked cell method
// (controlsOverlayControllerDidTapLikeButton:) after the button hook already
// confirmed it, so the confirmed run must pass through untouched.
static BOOL SPKBypassReelsLikeConfirm = NO;

// A single comment like tap fans out through a forwarding chain: the Swift
// IGCommentCell handler forwards to IGCommentCellController (and the combined
// like/dislike variants forward to the plain ones). Each link is hooked, so
// without the bypass the user sees a second prompt after confirming the first.
static BOOL SPKBypassCommentLikeConfirm = NO;

// The confirm-like pref must never affect the dislike button. Its state update
// enum (dislikeUpdate) is unreliable across builds, so we key off the tapped
// button's accessibility identifier ("comment-dislike-button") / label instead.
static BOOL SPKCommentButtonIsDislike(id button) {
    if (![button isKindOfClass:[UIView class]])
        return NO;
    UIView *view = (UIView *)button;
    NSString *identifier = view.accessibilityIdentifier.lowercaseString;
    if ([identifier containsString:@"dislike"])
        return YES;
    NSString *label = view.accessibilityLabel.lowercaseString;
    if ([label containsString:@"dislike"])
        return YES;
    return NO;
}

static void SPKConfirmFeedPostLike(id context, id button, void (^proceed)(void)) {
    if (SPKBypassFeedPostLikeConfirm || ![SPKUtils getBoolPref:@"feed_confirm_post_like"]) {
        proceed();
        return;
    }

    BOOL isUnlike = SPKFeedLikeIsUnlike(button, context);
    SPKLog(@"General", @"[Sparkle] Confirm feed post %@ triggered", isUnlike ? @"unlike" : @"like");
    SPKPresentLikeConfirmation(isUnlike,
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_POST_LIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_LIKE_POST_CONFIRMATION_MESSAGE"),
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_POST_UNLIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_POST_CONFIRMATION_MESSAGE"),
                               &SPKBypassFeedPostLikeConfirm,
                               proceed);
}

// A double tap forwards into the hooked like-button path. It always runs with
// the post-like bypass raised so the button confirmation never stacks on top of
// (or substitutes for) the double-tap one.
static void SPKConfirmFeedDoubleTapLike(id context, void (^proceed)(void)) {
    if (![SPKUtils getBoolPref:@"feed_confirm_double_tap_like"]) {
        SPKRunWithLikeConfirmBypass(&SPKBypassFeedPostLikeConfirm, proceed);
        return;
    }

    BOOL isUnlike = SPKFeedLikeIsUnlike(nil, context);
    SPKLog(@"General", @"[Sparkle] Confirm feed double-tap %@ triggered", isUnlike ? @"unlike" : @"like");
    SPKPresentLikeConfirmation(isUnlike,
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_POST_LIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_LIKE_POST_CONFIRMATION_MESSAGE"),
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_POST_UNLIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_POST_CONFIRMATION_MESSAGE"),
                               &SPKBypassFeedPostLikeConfirm,
                               proceed);
}

static void SPKConfirmCommentLike(id context, id button, void (^proceed)(void)) {
    if (SPKBypassCommentLikeConfirm || SPKCommentButtonIsDislike(button) ||
        ![SPKUtils getBoolPref:@"general_comments_confirm_like"]) {
        proceed();
        return;
    }

    BOOL isUnlike = SPKCommentLikeIsUnlike(button, context);
    SPKLog(@"General", @"[Sparkle] Confirm comment %@ triggered", isUnlike ? @"unlike" : @"like");
    SPKPresentLikeConfirmation(isUnlike,
                               SPKL(@"GENERAL_COMMENTS_CONFIRM_COMMENT_LIKE_TITLE"),
                               SPKL(@"FEED_LIKE_CONFIRM_LIKE_COMMENT_CONFIRMATION_MESSAGE"),
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_COMMENT_UNLIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_COMMENT_CONFIRMATION_MESSAGE"),
                               &SPKBypassCommentLikeConfirm,
                               proceed);
}

// The combined like/dislike handlers fire for BOTH the like and the dislike
// button. A nonzero `dislikeUpdate` is a secondary signal that the dislike
// button was tapped (the button-identifier check in SPKConfirmCommentLike is the
// primary one); either way the confirm-like pref must not apply.
static void SPKConfirmCommentLikeOrDislike(id context, id button, long long dislikeUpdate, void (^proceed)(void)) {
    if (dislikeUpdate != 0) {
        proceed();
        return;
    }
    SPKConfirmCommentLike(context, button, proceed);
}

static void SPKConfirmReelLike(id context, id button, void (^proceed)(void)) {
    if (SPKBypassReelsLikeConfirm || ![SPKUtils getBoolPref:@"reels_confirm_like"]) {
        proceed();
        return;
    }

    BOOL isUnlike = SPKFeedLikeIsUnlike(button, context);
    SPKLog(@"General", @"[Sparkle] Confirm reels %@ triggered", isUnlike ? @"unlike" : @"like");
    SPKPresentLikeConfirmation(isUnlike,
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_REEL_LIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_LIKE_REEL_CONFIRMATION_MESSAGE"),
                               SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_REEL_UNLIKE_TEXT"),
                               SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_REEL_CONFIRMATION_MESSAGE"),
                               &SPKBypassReelsLikeConfirm,
                               proceed);
}

static void SPKConfirmReelDoubleTapLike(id context, void (^proceed)(void)) {
    if (![SPKUtils getBoolPref:@"reels_confirm_double_tap_like"]) {
        proceed();
        return;
    }

    BOOL isUnlike = SPKFeedLikeIsUnlike(nil, context);
    SPKLog(@"General", @"[Sparkle] Confirm reels double-tap %@ triggered", isUnlike ? @"unlike" : @"like");
    SPKPresentLikeToggleConfirmation(isUnlike,
                                     SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_REEL_LIKE_TEXT"),
                                     SPKL(@"FEED_LIKE_CONFIRM_LIKE_REEL_CONFIRMATION_MESSAGE"),
                                     SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_REEL_UNLIKE_TEXT"),
                                     SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_REEL_CONFIRMATION_MESSAGE"),
                                     [proceed copy]);
}

///////////////////////////////////////////////////////////

// Liking posts
%group SPKLikeConfirmHooks

%hook IGUFIButtonBarView
- (void)_onLikeButtonPressed {
    SPKConfirmFeedPostLike(self, nil, ^{ %orig; });
}
- (void)_onLikeButtonPressed:(id)arg1 {
    SPKConfirmFeedPostLike(self, arg1, ^{ %orig; });
}
%end
%hook IGFeedItemUFICell
- (void)UFIButtonBarDidTapOnLike:(id)arg1 {
    SPKConfirmFeedPostLike(self, arg1, ^{ %orig; });
}
%end
%hook IGFeedItemUFICellConfigurableDelegateImpl
- (void)feedItemUFICellDidTapLikeButton:(id)arg1 {
    SPKConfirmFeedPostLike(self, arg1, ^{ %orig; });
}
- (void)_performSingleTapLikeToggle {
    SPKConfirmFeedPostLike(self, nil, ^{ %orig; });
}
%end
%hook IGFeedPhotoView
- (void)_onDoubleTap {
    SPKConfirmFeedDoubleTapLike(self, ^{ %orig; });
}
- (void)_onDoubleTap:(id)arg1 {
    SPKConfirmFeedDoubleTapLike(self, ^{ %orig; });
}
%end
%hook IGVideoPlayerOverlayContainerView
- (void)_handleDoubleTapGesture:(id)arg1 {
    SPKConfirmFeedDoubleTapLike(self, ^{ %orig; });
}
// IG 436+ : the Swift-rewritten IGModernFeedVideoOverlays.IGVideoPlayerOverlayContainerView
// dropped the leading underscore from this selector.
- (void)handleDoubleTapGesture:(id)arg1 {
    SPKConfirmFeedDoubleTapLike(self, ^{ %orig; });
}
%end

// Liking reels
%hook IGSundialViewerVideoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    SPKConfirmReelLike(self, arg1, ^{ %orig; });
}
- (void)controlsOverlayControllerDidLongPressLikeButton:(id)arg1 gestureRecognizer:(id)arg2 {
    SPKConfirmReelLike(self, arg1, ^{ %orig; });
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    SPKConfirmReelDoubleTapLike(self, ^{ %orig; });
}
%end
%hook IGSundialViewerPhotoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    SPKConfirmReelLike(self, arg1, ^{ %orig; });
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    SPKConfirmReelDoubleTapLike(self, ^{ %orig; });
}
- (void)swift_photoCell:(id)arg1 didObserveDoubleTapWithLocationInfo:(id)arg2 gestureRecognizer:(id)arg3 {
    SPKConfirmReelDoubleTapLike(self, ^{ %orig; });
}
%end
%hook IGSundialViewerCarouselCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    SPKConfirmReelLike(self, arg1, ^{ %orig; });
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    SPKConfirmReelDoubleTapLike(self, ^{ %orig; });
}
- (void)carouselCell:(id)arg1 didObserveDoubleTapWithLocationInfo:(id)arg2 gestureRecognizer:(id)arg3 {
    SPKConfirmReelDoubleTapLike(self, ^{ %orig; });
}
%end

// Liking comments
%hook IGCommentCellController
- (void)commentCell:(id)arg1 didTapLikeButton:(id)arg2 {
    SPKConfirmCommentLike(arg1, arg2, ^{ %orig; });
}
// IG 436+ (comment dislikes): like taps route through this combined handler.
- (void)commentCell:(id)arg1 didTapLikeOrDislikeButton:(id)arg2 likeButton:(id)arg3 dislikeUpdate:(long long)arg4 {
    // arg2 is the button that was actually tapped (like or dislike); check it so
    // the dislike button is filtered by identifier, not just by dislikeUpdate.
    SPKConfirmCommentLikeOrDislike(arg1, arg2, arg4, ^{ %orig; });
}
- (void)commentCell:(id)arg1 didTapLikedByButtonForUser:(id)arg2 {
    SPKConfirmCommentLike(nil, nil, ^{ %orig; });
}
- (void)commentCellDidLongPressOnLikeButton:(id)arg1 {
    SPKConfirmCommentLike(nil, arg1, ^{ %orig; });
}
- (void)commentCellDidEndLongPressOnLikeButton:(id)arg1 {
    SPKConfirmCommentLike(nil, arg1, ^{ %orig; });
}
- (void)commentCellDidDoubleTap:(id)arg1 {
    SPKConfirmCommentLike(arg1, nil, ^{ %orig; });
}
%end
%hook IGFeedItemPreviewCommentCell
- (void)_didTapLikeButton {
    SPKConfirmCommentLike(self, nil, ^{ %orig; });
}
%end
// IG 436+ : in the comment thread/detail view the like (and like/dislike) tap
// lands on the Swift comment cell (IGCommentCells.IGCommentCell) before it
// forwards to its UFI delegate (IGCommentCellController). Both links are hooked
// so gating works whichever fires; the SPKBypassCommentLikeConfirm guard keeps
// the forwarded call from surfacing a second prompt after the first is confirmed.
%hook IGCommentCell
- (void)contentViewDidTapLike:(id)arg1 {
    SPKConfirmCommentLike(self, arg1, ^{ %orig; });
}
// Combined like/dislike handler. Unlike the controller variant, this method has
// NO tapped-button parameter — it always receives both the dislike button (arg1)
// and the like button (arg2), whichever was tapped — and `dislikeUpdate` is
// unreliable across builds. So we can't tell here whether the user liked or
// disliked. Pass it straight through: a *like* tap fans out to the plain
// contentViewDidTapLike: above (which confirms with the unambiguous like button),
// while a *dislike* tap fans out to an unhooked dislike handler and never
// surfaces the like-confirm prompt.
- (void)contentViewDidTapLikeOrDislikeButtonWithDislikeButton:(id)arg1 likeButton:(id)arg2 dislikeUpdate:(long long)arg3 {
    return %orig;
}
%end

// Liking stories (newer Instagram builds)
static void (*orig_spkStoryLikeTap)(id, SEL, id);
static void new_spkStoryLikeTap(id self, SEL _cmd, id button) {
    if (![SPKUtils getBoolPref:@"stories_confirm_like"]) {
        orig_spkStoryLikeTap(self, _cmd, button);
        if (SPKStoryMarkSeenOnLikeEnabled() && [button isKindOfClass:[UIView class]]) {
            SPKStoryMarkSeenForInteractionView((UIView *)button, @"stories_advance_on_like_seen");
        }
        return;
    }

    BOOL isSelected = [button isKindOfClass:[UIButton class]] ? [(UIButton *)button isSelected] : NO;
    BOOL isUnlike = !isSelected;

    UIButton *btn = [button isKindOfClass:[UIButton class]] ? (UIButton *)button : nil;
    SEL setLikedSel = NSSelectorFromString(@"setIsLiked:animated:");

    [SPKUtils
        showConfirmation:^{
            if (btn) {
                [btn setSelected:isSelected];
                if ([btn respondsToSelector:setLikedSel]) {
                    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(btn, setLikedSel, isSelected, YES);
                }
            }
            orig_spkStoryLikeTap(self, _cmd, button);
            if (!isUnlike && SPKStoryMarkSeenOnLikeEnabled() && [button isKindOfClass:[UIView class]]) {
                SPKStoryMarkSeenForInteractionView((UIView *)button, @"stories_advance_on_like_seen");
            }
        }
                   title:(isUnlike ? SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_STORY_UNLIKE_TEXT") : SPKL(@"FEED_LIKE_CONFIRM_CONFIRM_STORY_LIKE_TEXT"))
                   message:(isUnlike ? SPKL(@"FEED_LIKE_CONFIRM_UNLIKE_STORY_CONFIRMATION_MESSAGE") : SPKL(@"FEED_LIKE_CONFIRM_LIKE_STORY_CONFIRMATION_MESSAGE"))];

    if (btn) {
        [UIView performWithoutAnimation:^{
            [btn setSelected:!isSelected];
            if ([btn respondsToSelector:setLikedSel]) {
                ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(btn, setLikedSel, !isSelected, NO);
            }
        }];
    }
}

static void SPKInstallStoryLikeConfirmHookIfNeeded(void) {
    if (!SPKStoryInteractionHooksNeeded()) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"_TtC22IGStoryLikesController38IGStoryLikesInteractionControllingImpl");
        if (!cls)
            cls = NSClassFromString(@"IGStoryLikesInteractionControllingImpl");
        if (!cls)
            return;

        SEL sel = NSSelectorFromString(@"handleStoryLikeTapWith:");
        if (!class_getInstanceMethod(cls, sel)) {
            sel = NSSelectorFromString(@"handleStoryLikeTapWithButton:");
        }
        if (!class_getInstanceMethod(cls, sel))
            return;

        MSHookMessageEx(cls, sel, (IMP)new_spkStoryLikeTap, (IMP *)&orig_spkStoryLikeTap);
    });
}

%hook IGDirectComposer
- (void)_didTapSend {
    %orig;
    SPKStoryReplySideEffects();
}

- (void)_didTapSend:(id)arg {
    %orig;
    SPKStoryReplySideEffects();
}

- (void)_send {
    %orig;
    SPKStoryReplySideEffects();
}

- (void)_didTapEmojiQuickReactionButton:(id)button {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                %orig;
                if (SPKActiveStoryOverlayForInteractions())
                    SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (SPKActiveStoryOverlayForInteractions()) {
        %orig;
        SPKStoryReplySideEffects();
        return;
    }
    %orig;
}

- (void)_didTapEmojiReactionButton:(id)button {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                %orig;
                if (SPKActiveStoryOverlayForInteractions())
                    SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (SPKActiveStoryOverlayForInteractions()) {
        %orig;
        SPKStoryReplySideEffects();
        return;
    }
    %orig;
}
%end

static void (*orig_storyFooterEmojiQuick)(id, SEL, id, id);
static void SPKHookedStoryFooterEmojiQuick(id self, SEL _cmd, id inputView, id button) {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                if (orig_storyFooterEmojiQuick)
                    orig_storyFooterEmojiQuick(self, _cmd, inputView, button);
                SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (orig_storyFooterEmojiQuick)
        orig_storyFooterEmojiQuick(self, _cmd, inputView, button);
    SPKStoryReplySideEffects();
}

static void (*orig_storyFooterEmojiReaction)(id, SEL, id, id);
static void SPKHookedStoryFooterEmojiReaction(id self, SEL _cmd, id inputView, id button) {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                if (orig_storyFooterEmojiReaction)
                    orig_storyFooterEmojiReaction(self, _cmd, inputView, button);
                SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (orig_storyFooterEmojiReaction)
        orig_storyFooterEmojiReaction(self, _cmd, inputView, button);
    SPKStoryReplySideEffects();
}

static void (*orig_storyQuickReaction)(id, SEL, id, id, id);
static void SPKHookedStoryQuickReaction(id self, SEL _cmd, id view, id sourceButton, id emoji) {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                if (orig_storyQuickReaction)
                    orig_storyQuickReaction(self, _cmd, view, sourceButton, emoji);
                SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (orig_storyQuickReaction)
        orig_storyQuickReaction(self, _cmd, view, sourceButton, emoji);
    SPKStoryReplySideEffects();
}

static void (*orig_storyPrivateEmojiQuick)(id, SEL, id);
static void SPKHookedStoryPrivateEmojiQuick(id self, SEL _cmd, id button) {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                if (orig_storyPrivateEmojiQuick)
                    orig_storyPrivateEmojiQuick(self, _cmd, button);
                SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (orig_storyPrivateEmojiQuick)
        orig_storyPrivateEmojiQuick(self, _cmd, button);
    SPKStoryReplySideEffects();
}

static void (*orig_directReshareQuickReaction)(id, SEL, id);
static void SPKHookedDirectReshareQuickReaction(id self, SEL _cmd, id arg) {
    if (SPKStoryQuickReactionConfirmEnabled()) {
        [SPKUtils
            showConfirmation:^{
                if (orig_directReshareQuickReaction)
                    orig_directReshareQuickReaction(self, _cmd, arg);
                SPKStoryReplySideEffects();
            }
                       title:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                     message:SPKL(@"FEED_LIKE_CONFIRM_SEND_EMOJI_REACTION_CONFIRMATION_MESSAGE")];
        return;
    }
    if (orig_directReshareQuickReaction)
        orig_directReshareQuickReaction(self, _cmd, arg);
    SPKStoryReplySideEffects();
}

static Class SPKStoryReplyFooterClass(void) {
    for (NSString *className in @[
             @"IGStoryDefaultFooter.IGStoryFullscreenDefaultFooterView",
             @"IGStoryFullscreenDefaultFooterView"
         ]) {
        Class cls = NSClassFromString(className);
        if (cls)
            return cls;
    }
    return Nil;
}

static void SPKInstallStoryReplyHooksIfNeeded(void) {
    if (!SPKStoryInteractionHooksNeeded())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class footerClass = SPKStoryReplyFooterClass();
        SEL quickSelector = NSSelectorFromString(@"inputView:didTapEmojiQuickReactionButton:");
        if (footerClass && class_getInstanceMethod(footerClass, quickSelector)) {
            MSHookMessageEx(footerClass, quickSelector, (IMP)SPKHookedStoryFooterEmojiQuick, (IMP *)&orig_storyFooterEmojiQuick);
        }

        SEL reactionSelector = NSSelectorFromString(@"inputView:didTapEmojiReactionButton:");
        if (footerClass && class_getInstanceMethod(footerClass, reactionSelector)) {
            MSHookMessageEx(footerClass, reactionSelector, (IMP)SPKHookedStoryFooterEmojiReaction, (IMP *)&orig_storyFooterEmojiReaction);
        }

        Class quickReactionClass = NSClassFromString(@"IGStoryQuickReactions.IGStoryQuickReactionsController");
        if (!quickReactionClass)
            quickReactionClass = NSClassFromString(@"IGStoryQuickReactionsController");
        SEL quickReactionSelector = NSSelectorFromString(@"quickReactionsView:sourceEmojiButton:didTapEmoji:");
        if (quickReactionClass && class_getInstanceMethod(quickReactionClass, quickReactionSelector)) {
            MSHookMessageEx(quickReactionClass, quickReactionSelector, (IMP)SPKHookedStoryQuickReaction, (IMP *)&orig_storyQuickReaction);
        }

        SEL privateQuickSelector = NSSelectorFromString(@"_didTapEmojiQuickReactionButton:");
        if (footerClass && class_getInstanceMethod(footerClass, privateQuickSelector)) {
            MSHookMessageEx(footerClass, privateQuickSelector, (IMP)SPKHookedStoryPrivateEmojiQuick, (IMP *)&orig_storyPrivateEmojiQuick);
        }

        Class quickReactionDelegateClass = NSClassFromString(@"_TtC29IGStoryQuickReactionsDelegate33IGStoryQuickReactionsDelegateImpl");
        if (!quickReactionDelegateClass)
            quickReactionDelegateClass = NSClassFromString(@"IGStoryQuickReactionsDelegateImpl");
        SEL directReshareSelector = NSSelectorFromString(@"directReshareMediaReplyFooterViewDidTapQuickReactionEmoji:");
        if (quickReactionDelegateClass && class_getInstanceMethod(quickReactionDelegateClass, directReshareSelector)) {
            MSHookMessageEx(quickReactionDelegateClass, directReshareSelector, (IMP)SPKHookedDirectReshareQuickReaction, (IMP *)&orig_directReshareQuickReaction);
        }
    });
}

// DM like button (seems to be hidden)
%hook IGDirectThreadViewController
- (void)_didTapLikeButton {
    %orig;
}
- (void)_didTapLikeButton:(id)arg1 {
    %orig;
}
%end

%end

// The reels heart is a UIControl (IGSundialLikeButton). On recent IG builds it
// reaches the like handler through Swift direct calls, which skip the cell
// hooks above (still the live path on 410), so the reliable choke point is the
// button's own target-action dispatch. Only
// the touch-up-inside action toggles the like; touch-down actions (bounce,
// haptics) pass straight through.
static IMP SPKReelsLikeButtonSuperSendAction = NULL;

// One heart tap sends its touch-up-inside action more than once (device logs
// show two sends a few ms apart). Actions that arrive while the prompt is up
// join it, so the user sees one alert and Confirm runs them all together.
static NSMutableArray<void (^)(void)> *SPKPendingReelLikeActions = nil;

static void SPKRunPendingReelLikeActions(BOOL confirmed) {
    NSArray<void (^)(void)> *actions = SPKPendingReelLikeActions;
    SPKPendingReelLikeActions = nil;
    if (!confirmed)
        return;
    SPKRunWithLikeConfirmBypass(&SPKBypassReelsLikeConfirm, ^{
        for (void (^action)(void) in actions)
            action();
    });
}

static void spkReelsLikeButtonSendAction(UIControl *self, SEL _cmd, SEL action, id target, UIEvent *event) {
    void (*superSend)(id, SEL, SEL, id, UIEvent *) = (void (*)(id, SEL, SEL, id, UIEvent *))SPKReelsLikeButtonSuperSendAction;
    if (!superSend)
        return;

    NSArray<NSString *> *tapActions = target ? [self actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] : nil;
    BOOL isLikeTap = action && [tapActions containsObject:NSStringFromSelector(action)];
    if (!isLikeTap || SPKBypassReelsLikeConfirm || ![SPKUtils getBoolPref:@"reels_confirm_like"]) {
        superSend(self, _cmd, action, target, event);
        return;
    }

    __strong UIControl *button = self;
    __strong id strongTarget = target;
    __strong UIEvent *strongEvent = event;
    void (^send)(void) = ^{
        superSend(button, _cmd, action, strongTarget, strongEvent);
    };

    if (SPKPendingReelLikeActions) {
        SPKLog(@"General", @"[Sparkle] Reels like extra action %@ joined the open prompt", NSStringFromSelector(action));
        [SPKPendingReelLikeActions addObject:[send copy]];
        return;
    }
    SPKPendingReelLikeActions = [NSMutableArray arrayWithObject:[send copy]];

    BOOL isUnlike = SPKFeedLikeIsUnlike(button, nil);
    SPKLog(@"General", @"[Sparkle] Reels like button confirm %@ (%@)", isUnlike ? @"unlike" : @"like", NSStringFromSelector(action));
    [SPKUtils showConfirmation:^{
        SPKRunPendingReelLikeActions(YES);
    }
        cancelHandler:^{
            SPKRunPendingReelLikeActions(NO);
        }
        title:SPKL(isUnlike ? @"FEED_LIKE_CONFIRM_CONFIRM_REEL_UNLIKE_TEXT" : @"FEED_LIKE_CONFIRM_CONFIRM_REEL_LIKE_TEXT")
        message:SPKL(isUnlike ? @"FEED_LIKE_CONFIRM_UNLIKE_REEL_CONFIRMATION_MESSAGE" : @"FEED_LIKE_CONFIRM_LIKE_REEL_CONFIRMATION_MESSAGE")];
}

static void SPKInstallReelsLikeButtonHook(void) {
    Class cls = SPKResolveIGClass(@"IGSundialViewerUFI.IGSundialLikeButton", nil);
    if (!cls)
        cls = SPKResolveIGClass(@"IGSundialCommonUISwift.IGSundialLikeButton", nil);
    SPKLog(@"General", @"[Sparkle] Reels like button class %@", cls ? NSStringFromClass(cls) : @"MISSING");
    if (!cls || ![cls isSubclassOfClass:[UIControl class]])
        return;

    SEL sel = @selector(sendAction:to:forEvent:);
    Method own = class_getInstanceMethod(cls, sel);
    Method inherited = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (!own || !inherited)
        return;

    if (method_getImplementation(own) == method_getImplementation(inherited)) {
        // Inherited from UIControl: add an override that forwards to super.
        SPKReelsLikeButtonSuperSendAction = method_getImplementation(inherited);
        class_addMethod(cls, sel, (IMP)spkReelsLikeButtonSendAction, method_getTypeEncoding(inherited));
    } else {
        MSHookMessageEx(cls, sel, (IMP)spkReelsLikeButtonSendAction, &SPKReelsLikeButtonSuperSendAction);
    }
}

static void SPKInstallReelsLikeButtonHookIfNeeded(void) {
    if (![SPKUtils getBoolPref:@"reels_confirm_like"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKInstallReelsLikeButtonHook();
    });
}

void SPKInstallLikeConfirmHooksIfNeeded(void) {
    if (![SPKUtils getBoolPref:@"feed_confirm_post_like"] &&
        ![SPKUtils getBoolPref:@"feed_confirm_double_tap_like"] &&
        ![SPKUtils getBoolPref:@"general_comments_confirm_like"] &&
        ![SPKUtils getBoolPref:@"reels_confirm_like"] &&
        ![SPKUtils getBoolPref:@"reels_confirm_double_tap_like"] &&
        !SPKStoryInteractionHooksNeeded()) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKLikeConfirmHooks,
                       IGVideoPlayerOverlayContainerView = SPKResolveIGClass(@"IGModernFeedVideoOverlays.IGVideoPlayerOverlayContainerView", @"IGVideoPlayerOverlayContainerView"),
                       IGCommentCell = SPKResolveIGClass(@"IGCommentCells.IGCommentCell", @"IGCommentCell"));
    });

    SPKInstallStoryLikeConfirmHookIfNeeded();
    SPKInstallStoryReplyHooksIfNeeded();
    SPKInstallReelsLikeButtonHookIfNeeded();
}
