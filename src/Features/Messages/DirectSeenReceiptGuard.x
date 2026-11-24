#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

#import "../../Shared/Messages/SPKDirectLocalSeen.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import "DirectSeenReceiptGuard.h"

// Manually Mark Seen keeps read receipts back where the chat decides to mark
// itself seen. If Instagram gains another path to that decision, a receipt would
// go out while Sparkle still shows the chat as not seen by the sender, and with
// Keep Seen Locally the chat already looks read, so nothing would give it away.
//
// Every read receipt leaves through IGDirectOutgoingUpdateService as an update
// action whose mark-seen field is set, both for one message and for a batch.
// This guard sits there: a receipt for a chat that manual seen covers is dropped
// unless Sparkle opened a window for it just before (the eye button and the
// Mark Seen On options do). A dropped receipt is logged with its caller and
// shown once, so a broken first lock is visible straight away.

static const NSTimeInterval kSPKSeenReceiptGuardAllowDuration = 2.0;
static const NSTimeInterval kSPKSeenReceiptGuardNotifyInterval = 60.0;
static NSString *const kSPKSeenReceiptGuardAnyThread = @"*";

static os_unfair_lock SPKSeenReceiptGuardLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime SPKSeenReceiptGuardAllowedUntil = 0;
static NSString *SPKSeenReceiptGuardAllowedThreadId = nil;
static NSMutableDictionary<NSString *, NSNumber *> *SPKSeenReceiptGuardLastNotified = nil;

// The window covers every chat: the receipt's chat id is read off Instagram's
// thread key, and a mismatch with the chat Sparkle resolved must never block the
// eye button. A mismatch is only logged.
void SPKDirectSeenReceiptGuardAllow(NSString *threadId) {
    os_unfair_lock_lock(&SPKSeenReceiptGuardLock);
    SPKSeenReceiptGuardAllowedUntil = CFAbsoluteTimeGetCurrent() + kSPKSeenReceiptGuardAllowDuration;
    SPKSeenReceiptGuardAllowedThreadId = [threadId copy];
    os_unfair_lock_unlock(&SPKSeenReceiptGuardLock);
}

static BOOL SPKSeenReceiptGuardIsAllowed(NSString *threadId) {
    os_unfair_lock_lock(&SPKSeenReceiptGuardLock);
    BOOL allowed = SPKSeenReceiptGuardAllowedUntil > CFAbsoluteTimeGetCurrent();
    NSString *expected = SPKSeenReceiptGuardAllowedThreadId;
    os_unfair_lock_unlock(&SPKSeenReceiptGuardLock);
    if (allowed && expected.length > 0 && threadId.length > 0 && ![expected isEqualToString:threadId])
        SPKLog(@"Messages", @"[Sparkle SeenGuard] Allowed receipt for another chat expected=%@ thread=%@", expected, threadId);
    return allowed;
}

// The update action's mark-seen field: set for a read receipt, nil for reactions,
// unsends and the other message updates that share this path.
static BOOL SPKSeenReceiptGuardIsReceipt(id update) {
    return [SPKUtils getIvarForObj:update name:"_markSeen_type"] != nil;
}

// IGDirectThreadKey → IGDirectDjangoThreadIdentifier → server thread id.
static NSString *SPKSeenReceiptGuardThreadId(id threadKey) {
    id identifier = [SPKUtils getIvarForObj:threadKey name:"_djangoThread_identifier"];
    id threadId = [SPKUtils getIvarForObj:identifier name:"_serverThread_threadId"];
    if ([threadId isKindOfClass:NSString.class] && [threadId length] > 0)
        return threadId;
    SEL selector = NSSelectorFromString(@"threadId");
    if ([threadKey respondsToSelector:selector]) {
        threadId = ((id (*)(id, SEL))objc_msgSend)(threadKey, selector);
        if ([threadId isKindOfClass:NSString.class] && [threadId length] > 0)
            return threadId;
    }
    return nil;
}

// YES when the receipt must not leave.
static BOOL SPKSeenReceiptGuardShouldBlock(id update, id threadKey, NSString *path) {
    if (!SPKSeenReceiptGuardIsReceipt(update))
        return NO;
    NSString *threadId = SPKSeenReceiptGuardThreadId(threadKey);
    // Without a chat id the global setting decides, as for any chat not listed.
    if (!SPKDirectLocalSeenAppliesToThreadId(threadId)) {
        SPKLog(@"Messages", @"[Sparkle SeenGuard] Receipt passed, manual seen off for chat path=%@ thread=%@ account=%@ manualSeen=%d", path,
               threadId ?: @"(unknown)", [SPKUtils currentUserPK] ?: @"(none)", [SPKUtils getBoolPref:@"msgs_manual_seen"]);
        return NO;
    }
    if (SPKSeenReceiptGuardIsAllowed(threadId)) {
        SPKLog(@"Messages", @"[Sparkle SeenGuard] Receipt sent by Sparkle path=%@ thread=%@", path, threadId ?: @"(unknown)");
        return NO;
    }

    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    SPKLog(@"Messages", @"[Sparkle SeenGuard] BLOCKED receipt path=%@ thread=%@ key=%@ caller=%@", path, threadId ?: @"(unknown)",
           NSStringFromClass([threadKey class]), [[stack subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, stack.count))] componentsJoinedByString:@" | "]);

    NSString *notifyKey = threadId ?: kSPKSeenReceiptGuardAnyThread;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&SPKSeenReceiptGuardLock);
    if (!SPKSeenReceiptGuardLastNotified)
        SPKSeenReceiptGuardLastNotified = [NSMutableDictionary dictionary];
    BOOL notify = now - [SPKSeenReceiptGuardLastNotified[notifyKey] doubleValue] > kSPKSeenReceiptGuardNotifyInterval;
    if (notify)
        SPKSeenReceiptGuardLastNotified[notifyKey] = @(now);
    os_unfair_lock_unlock(&SPKSeenReceiptGuardLock);
    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKNotify(kSPKNotificationDirectSeenReceiptBlocked, SPKL(@"MESSAGES_SEEN_GUARD_BLOCKED_TITLE"), SPKL(@"MESSAGES_SEEN_GUARD_BLOCKED_SUBTITLE"),
                      @"eye_off", SPKNotificationToneError);
        });
    }
    return YES;
}

static id (*SPKSeenReceiptGuardOrigSendUpdate)(id, SEL, id, id, id, id, id, long long, id, id, BOOL, BOOL, BOOL) = NULL;

static id SPKSeenReceiptGuardSendUpdate(id self, SEL _cmd, id update, id messageId, id threadKey, id clientContext, id sentDate, long long productType,
                                        id foaLogger, id igdLogger, BOOL isTAMMessage, BOOL isInstamadillo, BOOL isInstamadilloTTLC) {
    if (SPKSeenReceiptGuardShouldBlock(update, threadKey, @"single"))
        return nil;
    return SPKSeenReceiptGuardOrigSendUpdate(self, _cmd, update, messageId, threadKey, clientContext, sentDate, productType, foaLogger, igdLogger, isTAMMessage,
                                             isInstamadillo, isInstamadilloTTLC);
}

static id (*SPKSeenReceiptGuardOrigSendBatch)(id, SEL, id, id, id, id) = NULL;

static id SPKSeenReceiptGuardSendBatch(id self, SEL _cmd, id update, id messageIds, id threadKey, id clientContexts) {
    if (SPKSeenReceiptGuardShouldBlock(update, threadKey, @"batch"))
        return nil;
    return SPKSeenReceiptGuardOrigSendBatch(self, _cmd, update, messageIds, threadKey, clientContexts);
}

void SPKInstallDirectSeenReceiptGuardIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class service = NSClassFromString(@"IGDirectOutgoingUpdateService");
        // One literal per selector so the version diff can match it.
        SEL single = NSSelectorFromString(@"sendMessageUpdate:messageId:threadKey:originalMessageClientContext:sentDate:productType:foaS2SLogger:igdS2SLogger:isTAMMessage:isInstamadillo:isInstamadilloTTLC:");
        SEL batch = NSSelectorFromString(@"sendBatchMessageUpdate:messageIds:threadKey:messageClientContexts:");
        BOOL singleHooked = service && class_getInstanceMethod(service, single);
        BOOL batchHooked = service && class_getInstanceMethod(service, batch);
        if (singleHooked)
            MSHookMessageEx(service, single, (IMP)SPKSeenReceiptGuardSendUpdate, (IMP *)&SPKSeenReceiptGuardOrigSendUpdate);
        if (batchHooked)
            MSHookMessageEx(service, batch, (IMP)SPKSeenReceiptGuardSendBatch, (IMP *)&SPKSeenReceiptGuardOrigSendBatch);

        // What the guard reads off each send, so an Instagram update that moves it
        // shows up here instead of letting receipts through unnoticed.
        Class action = NSClassFromString(@"IGDirectMessageOutgoingUpdateAction");
        Class threadKey = NSClassFromString(@"IGDirectThreadKey");
        Class identifier = NSClassFromString(@"IGDirectDjangoThreadIdentifier");
        BOOL markSeenField = action && class_getInstanceVariable(action, "_markSeen_type");
        BOOL threadKeyField = threadKey && class_getInstanceVariable(threadKey, "_djangoThread_identifier");
        BOOL threadIdField = identifier && class_getInstanceVariable(identifier, "_serverThread_threadId");
        SPKLog(@"Messages", @"[Sparkle SeenGuard] Installed single=%d batch=%d markSeen=%d threadKey=%d threadId=%d", singleHooked, batchHooked, markSeenField,
               threadKeyField, threadIdField);
    });
}
