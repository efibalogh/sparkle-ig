#import "SPKStrings.h"
#import "../../Utils.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"

#ifdef __cplusplus
extern "C" {
#endif
void SPKMarkDirectThreadSeenAfterReaction(id source);
#ifdef __cplusplus
}
#endif

#pragma mark - Hook group

%group SPKDMInteractionConfirmHooks

// ─── Double-tap like ────────────────────────────────────────────────

%hook IGDirectMessageSectionController

- (void)messageCellDidDoubleTap:(id)cell {
    if (![SPKUtils getBoolPref:@"msgs_confirm_double_tap"]) {
        %orig;
        SPKMarkDirectThreadSeenAfterReaction(self);
        return;
    }

    [SPKUtils
        showConfirmation:^{
            %orig;
            SPKMarkDirectThreadSeenAfterReaction(self);
        }
                   title:SPKL(@"MESSAGES_DMINTERACTION_CONFIRM_CONFIRM_MESSAGE_DOUBLE_TAP_MESSAGE")
                 message:SPKL(@"MESSAGES_DMINTERACTION_CONFIRM_DOUBLE_TAP_MESSAGE_CONFIRMATION_MESSAGE")];
}

%end

// ─── Emoji reaction picker ──────────────────────────────────────────
// When the user long-presses a message and picks an emoji, the call
// chain is:
//
//   IGDirectMessageReactionSelectionViewController
//       -reactionContainerView:didSelectEmojiAtIndex:       ← we hook HERE
//           → internally delegates to IGDirectMessageReactionController
//               -messageReactionSelectionViewController:didToggleEmoji:...
//
// We ONLY hook the picker VC entry point. Hooking the delegate too
// causes a double-prompt because %orig on the picker method cascades
// into the delegate.

%hook IGDirectMessageReactionSelectionViewController

- (void)reactionContainerView:(id)containerView didSelectEmojiAtIndex:(NSInteger)index {
    if (![SPKUtils getBoolPref:@"msgs_confirm_reaction"]) {
        %orig;
        SPKMarkDirectThreadSeenAfterReaction(self);
        return;
    }

    [SPKUtils
        showConfirmation:^{
            %orig;
            SPKMarkDirectThreadSeenAfterReaction(self);
        }
                   title:SPKL(@"MESSAGES_DMINTERACTION_CONFIRM_CONFIRM_MESSAGE_REACTION_MESSAGE")
                 message:SPKL(@"MESSAGES_DMINTERACTION_CONFIRM_REACT_MESSAGE_CONFIRMATION_MESSAGE")];
}

%end

// ─── Reel viewer "Send to group/chat" button ────────────────────────
// The reels viewer opened from a DM thread shows a quick send button
// once the user scrolls past the shared reel. It sends the active reel
// to the thread with a single tap. It is reachable through two paths:
// the standalone button target and the button tray delegate. The tray
// path may forward into the button handler, so a reentrancy flag keeps
// one tap to one prompt.

static BOOL sSPKReelSendToThreadConfirmed = NO;

static id SPKReelSendKVC(id object, NSString *key) {
    if (!object)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused id e) {
        return nil;
    }
}

static NSString *SPKReelSendString(id value) {
    if ([value isKindOfClass:NSString.class])
        return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:NSNumber.class])
        return [value stringValue];
    return nil;
}

// The thread the viewer was opened from sits beneath it, either in the same
// navigation stack or as the presenter. Only that controller carries the
// roster, so its context is accepted only when its thread id matches the
// viewer's own.
static SPKDirectThreadContext *SPKReelSendThreadContext(UIViewController *viewer, NSString *threadId) {
    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    for (UIViewController *vc in viewer.navigationController.viewControllers.reverseObjectEnumerator) {
        if (vc != viewer)
            [candidates addObject:vc];
    }
    UIViewController *presenter = viewer.navigationController.presentingViewController ?: viewer.presentingViewController;
    if ([presenter isKindOfClass:UINavigationController.class]) {
        for (UIViewController *vc in ((UINavigationController *)presenter).viewControllers.reverseObjectEnumerator)
            [candidates addObject:vc];
    } else if (presenter) {
        [candidates addObject:presenter];
    }

    Class threadClass = NSClassFromString(@"IGDirectThreadViewController");
    for (UIViewController *vc in candidates) {
        if (threadClass && ![vc isKindOfClass:threadClass])
            continue;
        SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(vc);
        if (context.threadId.length && (!threadId.length || [context.threadId isEqualToString:threadId]))
            return context;
    }
    return nil;
}

// "@username" for a 1:1 chat, the group's title for a group. Nil when neither
// can be resolved, so the prompt falls back to the generic copy. outIsGroup
// picks the format: only a group title is quoted, a handle already reads as one.
static NSString *SPKReelSendTargetName(UIViewController *viewer, BOOL *outIsGroup) {
    *outIsGroup = NO;
    NSString *threadId = SPKReelSendString([SPKUtils getIvarForObj:viewer name:"_threadId"]);
    BOOL isGroup = [SPKReelSendKVC(viewer, @"isGroup") boolValue];

    SPKDirectThreadContext *context = SPKReelSendThreadContext(viewer, threadId);
    if (context) {
        NSString *name = SPKDirectHandleNameForThreadContext(context);
        if (name.length && (context.isGroup || [name hasPrefix:@"@"])) {
            *outIsGroup = context.isGroup;
            return name;
        }
        isGroup = isGroup || context.isGroup;
    }

    if (isGroup) {
        *outIsGroup = YES;
        return SPKReelSendString(SPKReelSendKVC(viewer, @"threadName"));
    }

    // 1:1 fallback: the reel's sharer is the partner unless it was you.
    id sender = [SPKUtils getIvarForObj:viewer name:"_sender"];
    NSString *senderPk = SPKReelSendString(SPKReelSendKVC(sender, @"pk"));
    NSString *username = SPKReelSendString(SPKReelSendKVC(sender, @"username"));
    NSString *currentPk = [SPKUtils currentUserPK];
    if (username.length && senderPk.length && currentPk.length && ![senderPk isEqualToString:currentPk])
        return [@"@" stringByAppendingString:username];
    return nil;
}

static void SPKConfirmReelSendToThread(UIViewController *viewer, void (^send)(void)) {
    if (sSPKReelSendToThreadConfirmed || ![SPKUtils getBoolPref:@"msgs_confirm_reel_send_to_thread"]) {
        send();
        return;
    }

    BOOL isGroup = NO;
    NSString *target = SPKReelSendTargetName(viewer, &isGroup);
    NSString *message = SPKL(@"MESSAGES_REEL_SEND_TO_THREAD_CONFIRM_MESSAGE");
    if (target.length) {
        NSString *format = isGroup ? SPKL(@"MESSAGES_REEL_SEND_TO_THREAD_CONFIRM_GROUP_FORMAT")
                                   : SPKL(@"MESSAGES_REEL_SEND_TO_THREAD_CONFIRM_USER_FORMAT");
        message = [NSString stringWithFormat:format, target];
    }

    [SPKUtils
        showConfirmation:^{
            sSPKReelSendToThreadConfirmed = YES;
            send();
            sSPKReelSendToThreadConfirmed = NO;
        }
                   title:SPKL(@"MESSAGES_REEL_SEND_TO_THREAD_CONFIRM_TITLE")
                 message:message];
}

%hook IGDirectReplySundialFeedViewController

- (void)_handleShareButtonTap {
    SPKConfirmReelSendToThread((UIViewController *)self, ^{
        %orig;
    });
}

- (void)directReplySundialButtonTrayDidTapShareToThreadButton {
    SPKConfirmReelSendToThread((UIViewController *)self, ^{
        %orig;
    });
}

%end

%end // group SPKDMInteractionConfirmHooks

#pragma mark - Entry point

extern "C" void SPKInstallDMInteractionConfirmHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDMInteractionConfirmHooks);
    });
}
