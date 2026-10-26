#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../Shared/Messages/SPKDirectInboxMenu.h"
#import <objc/runtime.h>

// "Message Preview" (peek a DM thread from the inbox without sending read receipts)
// is an Instagram Plus feature. Overriding these classes allows unlocking it.
//
// These classes are Swift; their runtime names are the mangled _TtC form and do
// not exist on IG 410 (iOS 15) where Instagram Plus is absent, so %hook binds
// nothing there.

static inline BOOL SPKUnlockMessagePreviewEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_unlock_preview"];
}

static UIMenu *SPKMessagePreviewMenuByRemovingUpsell(UIMenu *menu) {
    NSMutableArray<UIMenuElement *> *filteredChildren = [menu.children mutableCopy];
    NSMutableArray<UIAction *> *subtitledActions = [NSMutableArray array];
    for (UIMenuElement *element in menu.children ?: @[]) {
        if ([element isKindOfClass:[UIAction class]] && ((UIAction *)element).subtitle.length > 0)
            [subtitledActions addObject:(UIAction *)element];
    }

    // Instagram does not expose a stable identifier for the subscription row:
    // its identifier is regenerated and its copy is localized. The inbox menu
    // currently gives only that direct action a subtitle. Remove it only while
    // the custom preview is enabled and only when the structure is unambiguous.
    if (subtitledActions.count != 1)
        return menu;

    [filteredChildren removeObjectIdenticalTo:subtitledActions.firstObject];
    return [menu menuByReplacingChildren:filteredChildren];
}

// IG 448 turned bypassSeenStateUpdate from an @objc property into a plain Swift
// stored property, so the setter is gone but the ivar (a one-byte Swift.Bool) is
// still registered with the runtime under its bare name. Without it the preview
// marks the thread seen.
static void SPKMessagePreviewBypassSeenState(id preview) {
    if ([preview respondsToSelector:@selector(setBypassSeenStateUpdate:)]) {
        [preview setBypassSeenStateUpdate:YES];
        return;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(preview), "bypassSeenStateUpdate");
    if (!ivar) {
        SPKLog(@"Messages", @"[Sparkle MessagePreview] bypassSeenStateUpdate not found; preview may mark the thread seen");
        return;
    }
    *((uint8_t *)(__bridge void *)preview + ivar_getOffset(ivar)) = 1;
}

/// The receipt-free preview controller, or nil to let Instagram build its own.
static id SPKMessagePreviewController(id threadId, id session) {
    if (!SPKUnlockMessagePreviewEnabled())
        return nil;

    Class previewClass = NSClassFromString(@"_TtC39IGDirectLightweightThreadViewController39IGDirectLightweightThreadViewController");
    SEL initializer = @selector(initWithUserSession:threadId:onLoadCompletion:);
    if (!previewClass || ![previewClass instancesRespondToSelector:initializer])
        return nil;

    id preview = [[previewClass alloc] initWithUserSession:session
                                                  threadId:threadId
                                           onLoadCompletion:nil];
    if (!preview)
        return nil;

    if ([preview respondsToSelector:@selector(setShouldHideHeader:)])
        [preview setShouldHideHeader:YES];
    SPKMessagePreviewBypassSeenState(preview);
    if ([preview respondsToSelector:@selector(setShouldSkipScrollToNewMessagesSeparator:)])
        [preview setShouldSkipScrollToNewMessagesSeparator:YES];
    return preview;
}

%group SPKUnlockMessagePreviewHooks

%hook _TtC29IGConsumerSubsDirectChatPeeks35IGDirectInboxChatPeekPreviewHandler

- (id)previewViewControllerForThreadId:(id)threadId userSession:(id)session containerWidth:(double)width {
    return SPKMessagePreviewController(threadId, session) ?: %orig;
}

// IG 452 added a trailing experience argument. Each build defines only one of the
// two selectors, so the other hook binds nothing.
- (id)previewViewControllerForThreadId:(id)threadId userSession:(id)session containerWidth:(double)width experience:(id)experience {
    return SPKMessagePreviewController(threadId, session) ?: %orig;
}

%end

// Demangled: IGConsumerSubsDirectChatPeeks.IGConsumerSubsDirectChatPeekEligibility
%hook _TtC29IGConsumerSubsDirectChatPeeks39IGConsumerSubsDirectChatPeekEligibility

+ (BOOL)isChatPeekFeatureEligibleWithLauncherSet:(id)set consumerSubsService:(id)service {
    if (SPKUnlockMessagePreviewEnabled()) {
        return YES;
    }
    return %orig;
}

// IG 453 replaced the launcher set and service arguments with session and experience.
+ (BOOL)isChatPeekFeatureEligibleWithSession:(id)session experience:(id)experience {
    if (SPKUnlockMessagePreviewEnabled()) {
        return YES;
    }
    return %orig;
}

+ (BOOL)isUpsellEligibleWithLauncherSet:(id)set consumerSubsService:(id)service {
    if (SPKUnlockMessagePreviewEnabled()) {
        return NO;
    }
    return %orig;
}

// IG 442 replaced the launcher set and service arguments with a single session argument. Older
// builds do not define this selector, so the hook binds nothing there.
+ (BOOL)isUpsellEligibleWithSession:(id)session {
    if (SPKUnlockMessagePreviewEnabled()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isThreadEligibleForPreview:(id)preview {
    if (SPKUnlockMessagePreviewEnabled()) {
        return YES;
    }
    return %orig;
}

%end

// Demangled: IGConsumerSubsDirectChatPeeks.IGConsumerSubsDirectChatPeekNuxHelper
%hook _TtC29IGConsumerSubsDirectChatPeeks37IGConsumerSubsDirectChatPeekNuxHelper

+ (BOOL)shouldShowNuxOnTapWithLauncherSet:(id)set userSession:(id)session {
    if (SPKUnlockMessagePreviewEnabled()) {
        return NO;
    }
    return %orig;
}

%end

// Objective-C class managing direct inbox features
%hook IGDirectInboxFeatureManager

- (BOOL)_isChatPeekEligibleForThreadId:(id)threadId {
    if (SPKUnlockMessagePreviewEnabled()) {
        return YES;
    }
    return %orig;
}

// IG 453 added a trailing experience argument.
- (BOOL)_isChatPeekEligibleForThreadId:(id)threadId experience:(id)experience {
    if (SPKUnlockMessagePreviewEnabled()) {
        return YES;
    }
    return %orig;
}

%end

%end

void SPKInstallUnlockMessagePreviewHooksIfEnabled(void) {
    // Check if the eligibility class exists in the current Instagram runtime
    if (NSClassFromString(@"_TtC29IGConsumerSubsDirectChatPeeks39IGConsumerSubsDirectChatPeekEligibility") == nil) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKUnlockMessagePreviewHooks);
        SPKDirectInboxMenuRegisterTransformer(@"message_preview", 0, ^UIMenu *(SPKDirectThreadContext *context, id viewModel, UIMenu *menu) {
            (void)context;
            (void)viewModel;
            return SPKUnlockMessagePreviewEnabled() ? SPKMessagePreviewMenuByRemovingUpsell(menu) : menu;
        });
        SPKDirectInboxMenuInstallHooksIfNeeded();
    });
}
