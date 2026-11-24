#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

#import "../../Shared/Messages/SPKDirectLocalSeen.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Utils.h"
#import "DirectLocalSeen.h"

// Keep Seen Locally for chats. Manually Mark Seen keeps blocking the receipt;
// this file only makes a chat read on this device, by answering Instagram's own
// read state from the SPKDirectLocalSeen record:
//   - IGDirectPublishedThread isUnread.
//   - IGDirectThreadMetadata lastSeenMessageIdsForUserIds: the account's own entry
//     is "read up to this message". Pointing it at the newest message makes
//     Instagram build the inbox row as read itself (snippet, dot and fonts).
// The metadata does not know its chat, so IGDirectPublishedThread metadata tags it
// with the chat, the account and the chat's newest messages. After a sync, the
// updated chats are fetched again so their metadata is tagged before the inbox
// rebuilds the rows.
//
// A chat counts as read while it is open and the app is in the foreground, the
// same moment Instagram would have sent the receipt.

static const void *kSPKDirectLocalSeenTagKey = &kSPKDirectLocalSeenTagKey;
static const void *kSPKDirectLocalSeenScanKey = &kSPKDirectLocalSeenScanKey;
static const void *kSPKDirectLocalSeenFakeKey = &kSPKDirectLocalSeenFakeKey;

static NSMapTable<NSString *, id> *SPKDirectLocalSeenThreads = nil;
static NSLock *SPKDirectLocalSeenThreadsLock = nil;
static BOOL SPKDirectLocalSeenAppActive = YES;

// The newest messages of one thread version.
@interface SPKDirectLocalSeenScan : NSObject
@property (nonatomic, copy) NSString *accountPK;
@property (nonatomic, strong) NSDate *incomingDate;
@property (nonatomic, copy) NSString *incomingId;
@property (nonatomic, strong) NSDate *anyDate;
@property (nonatomic, copy) NSString *anyId;
@end

@implementation SPKDirectLocalSeenScan
@end

// What the metadata getter needs to know about the thread it belongs to.
@interface SPKDirectLocalSeenTag : NSObject
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, copy) NSString *accountPK;
// The chat's latest activity: the snippet message, else the inbox sort date.
@property (nonatomic, strong) NSDate *latestDate;
@property (nonatomic, strong) SPKDirectLocalSeenScan *scan;
@end

@implementation SPKDirectLocalSeenTag
@end

static void SPKDirectLocalSeenLogOnce(SPKDirectLocalSeenTag *tag, NSString *event, NSDate *local);

static id SPKDirectLocalSeenValue(id target, NSString *selectorName, const char *ivarName) {
    if (!target)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    @try {
        if ([target respondsToSelector:selector])
            return ((id (*)(id, SEL))objc_msgSend)(target, selector);
        if (ivarName)
            return [SPKUtils getIvarForObj:target name:ivarName];
    } @catch (__unused id exception) {
    }
    return nil;
}

static NSString *SPKDirectLocalSeenString(id target, NSString *selectorName, const char *ivarName) {
    id value = SPKDirectLocalSeenValue(target, selectorName, ivarName);
    if ([value isKindOfClass:NSNumber.class])
        value = [value stringValue];
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static NSDate *SPKDirectLocalSeenDateValue(id target, NSString *selectorName, const char *ivarName) {
    id date = SPKDirectLocalSeenValue(target, selectorName, ivarName);
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

static NSDate *SPKDirectLocalSeenLater(NSDate *a, NSDate *b) {
    if (!a)
        return b;
    if (!b)
        return a;
    return [a compare:b] == NSOrderedDescending ? a : b;
}

static NSDate *SPKDirectLocalSeenThreadLatestDate(id thread) {
    id message = [SPKUtils getIvarForObj:thread name:"_latestMessageEligibleForInboxSnippet"];
    NSDate *date = SPKDirectLocalSeenDateValue(SPKDirectLocalSeenValue(message, @"metadata", "_metadata"), @"serverTimestamp", "_serverTimestamp");
    return date ?: SPKDirectLocalSeenDateValue(thread, @"primarySortingDate", "_primarySortingDate");
}

static id SPKDirectLocalSeenThreadMessages(id thread) {
    for (NSString *name in @[ @"publishedMessagesInCurrentThreadRange", @"allMessages", @"messages" ]) {
        id messages = SPKDirectLocalSeenValue(thread, name, NULL);
        if ([messages conformsToProtocol:@protocol(NSFastEnumeration)])
            return messages;
    }
    return nil;
}

// Newest incoming message and newest message of any sender. Thread versions share
// their message collections, so the result is kept on the collection.
static SPKDirectLocalSeenScan *SPKDirectLocalSeenScanThread(id thread, NSString *accountPK) {
    id messages = SPKDirectLocalSeenThreadMessages(thread);
    if (!messages)
        return nil;
    SPKDirectLocalSeenScan *scan = objc_getAssociatedObject(messages, kSPKDirectLocalSeenScanKey);
    if (scan && [scan.accountPK isEqualToString:accountPK])
        return scan;

    scan = [SPKDirectLocalSeenScan new];
    scan.accountPK = accountPK;
    @try {
        for (id message in (id<NSFastEnumeration>)messages) {
            id metadata = SPKDirectLocalSeenValue(message, @"metadata", "_metadata");
            NSDate *date = SPKDirectLocalSeenDateValue(metadata, @"serverTimestamp", "_serverTimestamp");
            NSString *messageId = SPKDirectLocalSeenString(metadata, @"serverId", "_serverId") ?: SPKDirectLocalSeenString(metadata, @"messageId", "_messageId");
            if (!date || !messageId)
                continue;
            if (!scan.anyDate || [date compare:scan.anyDate] == NSOrderedDescending) {
                scan.anyDate = date;
                scan.anyId = messageId;
            }
            NSString *sender = SPKDirectLocalSeenString(metadata, @"senderPk", "_senderPk");
            if (sender && ![sender isEqualToString:accountPK] && (!scan.incomingDate || [date compare:scan.incomingDate] == NSOrderedDescending)) {
                scan.incomingDate = date;
                scan.incomingId = messageId;
            }
        }
    } @catch (__unused id exception) {
        return nil;
    }
    objc_setAssociatedObject(messages, kSPKDirectLocalSeenScanKey, scan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return scan;
}

// Both sides of a chat between two accounts on this device share its thread id,
// and every signed-in account keeps its own copy of the chat. So a chat is always
// looked up and treated as open together with its account.
static NSString *SPKDirectLocalSeenThreadKey(NSString *accountPK, NSString *threadId) {
    if (accountPK.length == 0 || threadId.length == 0)
        return nil;
    return [NSString stringWithFormat:@"%@|%@", accountPK, threadId];
}

static void SPKDirectLocalSeenRememberThread(NSString *accountPK, NSString *threadId, id thread) {
    NSString *key = SPKDirectLocalSeenThreadKey(accountPK, threadId);
    if (!key || !thread)
        return;
    [SPKDirectLocalSeenThreadsLock lock];
    [SPKDirectLocalSeenThreads setObject:thread forKey:key];
    [SPKDirectLocalSeenThreadsLock unlock];
}

static id SPKDirectLocalSeenRememberedThread(NSString *accountPK, NSString *threadId) {
    NSString *key = SPKDirectLocalSeenThreadKey(accountPK, threadId);
    if (!key)
        return nil;
    [SPKDirectLocalSeenThreadsLock lock];
    id thread = [SPKDirectLocalSeenThreads objectForKey:key];
    [SPKDirectLocalSeenThreadsLock unlock];
    return thread;
}

// Open on screen for this account. The other account's copy of the same chat
// keeps syncing in the background and must not be read along with it.
static BOOL SPKDirectLocalSeenThreadIsOpen(NSString *accountPK, NSString *threadId) {
    if (!SPKDirectLocalSeenAppActive || threadId.length == 0 || accountPK.length == 0)
        return NO;
    return [SPKDirectActiveThreadContext().threadId isEqualToString:threadId] && [[SPKUtils currentUserPK] isEqualToString:accountPK];
}

// Everything the open chat shows has been read.
static NSDate *SPKDirectLocalSeenReadUpTo(SPKDirectLocalSeenTag *tag) {
    return SPKDirectLocalSeenLater(tag.latestDate, SPKDirectLocalSeenLater(tag.scan.anyDate, tag.scan.incomingDate));
}

// Ties the metadata to its thread. Records the chat as read while it is open.
static SPKDirectLocalSeenTag *SPKDirectLocalSeenTagThread(id thread) {
    NSString *threadId = SPKDirectLocalSeenString(thread, @"threadId", "_threadId");
    NSString *accountPK = SPKDirectLocalSeenString(thread, @"viewerId", "_viewerId");
    if (!threadId || !accountPK)
        return nil;

    SPKDirectLocalSeenTag *tag = [SPKDirectLocalSeenTag new];
    tag.threadId = threadId;
    tag.accountPK = accountPK;
    tag.latestDate = SPKDirectLocalSeenThreadLatestDate(thread);
    tag.scan = SPKDirectLocalSeenScanThread(thread, accountPK);

    id metadata = [SPKUtils getIvarForObj:thread name:"_metadata"];
    if (metadata)
        objc_setAssociatedObject(metadata, kSPKDirectLocalSeenTagKey, tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKDirectLocalSeenRememberThread(accountPK, threadId, thread);

    if (SPKDirectLocalSeenThreadIsOpen(accountPK, threadId)) {
        NSDate *readUpTo = SPKDirectLocalSeenReadUpTo(tag);
        if (readUpTo) {
            SPKDirectLocalSeenLogOnce(tag, @"open thread read", readUpTo);
            SPKDirectLocalSeenRecord(accountPK, threadId, readUpTo);
        }
    }
    return tag;
}

// One line per chat, newest message and outcome; the getters run for every row.
static void SPKDirectLocalSeenLogOnce(SPKDirectLocalSeenTag *tag, NSString *event, NSDate *local) {
    static NSMutableSet<NSString *> *logged;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logged = [NSMutableSet set];
        lock = [NSLock new];
    });
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@", event, tag.accountPK, tag.threadId, tag.scan.anyId, local];
    [lock lock];
    BOOL fresh = ![logged containsObject:key];
    if (fresh)
        [logged addObject:key];
    [lock unlock];
    if (!fresh)
        return;
    SPKLog(@"Messages", @"[Sparkle LocalSeen] %@ thread=%@ account=%@ latest=%@ incoming=%@ any=%@ (%@) local=%@", event, tag.threadId, tag.accountPK, tag.latestDate,
           tag.scan.incomingDate, tag.scan.anyDate, tag.scan.anyId, local ?: SPKDirectLocalSeenDate(tag.accountPK, tag.threadId));
}

// The local read time for a chat this feature applies to, or nil.
static NSDate *SPKDirectLocalSeenLocalDate(SPKDirectLocalSeenTag *tag) {
    if (!tag || !SPKDirectLocalSeenAppliesToThreadId(tag.threadId) || SPKDirectLocalSeenSuspended(tag.threadId))
        return nil;
    return SPKDirectLocalSeenDate(tag.accountPK, tag.threadId);
}

// Same one second of slack as the record's timestamps, which lose precision.
static BOOL SPKDirectLocalSeenDateCovered(NSDate *date, NSDate *local) {
    return date && local && date.timeIntervalSince1970 <= local.timeIntervalSince1970 + 1.0;
}

void SPKDirectLocalSeenNoteThreadViewed(NSString *threadId) {
    if (!SPKDirectLocalSeenEnabled())
        return;
    NSString *accountPK = [SPKUtils currentUserPK];
    if (!SPKDirectLocalSeenThreadIsOpen(accountPK, threadId)) {
        SPKLog(@"Messages", @"[Sparkle LocalSeen] View ignored thread=%@ active=%@ appActive=%d", threadId, SPKDirectActiveThreadContext().threadId, SPKDirectLocalSeenAppActive);
        return;
    }
    id thread = SPKDirectLocalSeenRememberedThread(accountPK, threadId);
    SPKDirectLocalSeenTag *tag = thread ? SPKDirectLocalSeenTagThread(thread) : nil;
    // A chat opened from a notification may not have been read from the cache yet:
    // everything up to now was read.
    NSDate *date = SPKDirectLocalSeenReadUpTo(tag) ?: NSDate.date;
    SPKDirectLocalSeenRecord(accountPK, threadId, date);
}

void SPKDirectLocalSeenWillSendReceipt(NSString *threadId) {
    SPKDirectLocalSeenSuspend(threadId);
}

void SPKDirectLocalSeenDidSendReceipt(NSString *threadId) {
    NSString *accountPK = [SPKUtils currentUserPK];
    id thread = SPKDirectLocalSeenRememberedThread(accountPK, threadId);
    SPKDirectLocalSeenTag *tag = thread ? SPKDirectLocalSeenTagThread(thread) : nil;
    SPKDirectLocalSeenRecordSent(accountPK, threadId, SPKDirectLocalSeenReadUpTo(tag) ?: SPKDirectLocalSeenDate(accountPK, threadId) ?: NSDate.date);
}

// The account's own entry as Instagram's server has it: the receipt state.
static void SPKDirectLocalSeenSeedSent(SPKDirectLocalSeenTag *tag, NSDictionary *lastSeen) {
    id mine = lastSeen[tag.accountPK];
    if (!mine || [objc_getAssociatedObject(mine, kSPKDirectLocalSeenFakeKey) boolValue])
        return;
    NSDate *sent = SPKDirectLocalSeenDateValue(mine, @"sentTimestamp", "_sentTimestamp");
    if (sent)
        SPKDirectLocalSeenRecordSent(tag.accountPK, tag.threadId, sent);
}

static id SPKDirectLocalSeenMakeLastSeen(id mine, NSString *messageId, NSDate *sentDate, NSDate *seenDate) {
    Class infoClass = NSClassFromString(@"IGDirectLastSeenMessageInfo");
    SEL initSelector = NSSelectorFromString(@"initWithMessageId:seenAtTimestamp:sentTimestamp:shhMessageSeenInfo:afterViewDisappearingMessageSeenInfo:");
    if (![infoClass instancesRespondToSelector:initSelector])
        return nil;
    id info = nil;
    @try {
        id shhInfo = SPKDirectLocalSeenValue(mine, @"shhMessageSeenInfo", "_shhMessageSeenInfo");
        id disappearingInfo = SPKDirectLocalSeenValue(mine, @"afterViewDisappearingMessageSeenInfo", "_afterViewDisappearingMessageSeenInfo");
        info = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)([infoClass alloc], initSelector, messageId, seenDate, sentDate, shhInfo, disappearingInfo);
    } @catch (NSException *exception) {
        SPKLog(@"Messages", @"[Sparkle LocalSeen] Building the read entry failed exception=%@", exception);
        return nil;
    }
    if (info)
        objc_setAssociatedObject(info, kSPKDirectLocalSeenFakeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return info;
}

// After a sync, fetch the updated chats again so their metadata is tagged and the
// server's receipt state is recorded before the inbox rebuilds their rows.
static void SPKDirectLocalSeenRefreshThreads(id applicator, id updates) {
    if (!SPKDirectLocalSeenEnabled() || ![updates conformsToProtocol:@protocol(NSFastEnumeration)])
        return;
    NSMutableOrderedSet<NSString *> *threadIds = [NSMutableOrderedSet orderedSet];
    @try {
        for (id update in (id<NSFastEnumeration>)updates) {
            NSString *threadId = SPKDirectLocalSeenString(update, @"threadId", "_threadId");
            if (threadId)
                [threadIds addObject:threadId];
        }
    } @catch (__unused id exception) {
        return;
    }
    if (threadIds.count == 0)
        return;
    id cache = [SPKUtils getIvarForObj:applicator name:"_cache"];
    SEL fetch = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
    if (![cache respondsToSelector:fetch])
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *threadId in threadIds) {
            ((void (*)(id, SEL, id, void (^)(id)))objc_msgSend)(cache, fetch, threadId, ^(id thread) {
                if (!thread)
                    return;
                SPKDirectLocalSeenTag *tag = SPKDirectLocalSeenTagThread(thread);
                id metadata = [SPKUtils getIvarForObj:thread name:"_metadata"];
                NSDictionary *lastSeen = [SPKUtils getIvarForObj:metadata name:"_lastSeenMessageIdsForUserIds"];
                if (tag && [lastSeen isKindOfClass:NSDictionary.class])
                    SPKDirectLocalSeenSeedSent(tag, lastSeen);
            });
        }
    });
}

static void (*SPKDirectLocalSeenOrigApplyUpdates)(id, SEL, id, id, id) = NULL;

static void SPKDirectLocalSeenApplyUpdates(id self, SEL _cmd, id updates, id completion, id access) {
    SPKDirectLocalSeenOrigApplyUpdates(self, _cmd, updates, completion, access);
    SPKDirectLocalSeenRefreshThreads(self, updates);
}

%group SPKDirectLocalSeenHooks

%hook IGDirectPublishedThread
- (BOOL)isUnread {
    BOOL unread = %orig;
    if (!unread || !SPKDirectLocalSeenEnabled())
        return unread;
    SPKDirectLocalSeenTag *tag = SPKDirectLocalSeenTagThread(self);
    NSDate *local = SPKDirectLocalSeenLocalDate(tag);
    BOOL covered = SPKDirectLocalSeenDateCovered(tag.latestDate, local);
    SPKDirectLocalSeenLogOnce(tag, covered ? @"isUnread covered" : @"isUnread kept", local);
    return !covered;
}

- (id)metadata {
    id metadata = %orig;
    if (metadata && SPKDirectLocalSeenEnabled())
        SPKDirectLocalSeenTagThread(self);
    return metadata;
}
%end

%hook IGDirectThreadMetadata
- (NSDictionary *)lastSeenMessageIdsForUserIds {
    NSDictionary *original = %orig;
    if (!SPKDirectLocalSeenEnabled() || ![original isKindOfClass:NSDictionary.class])
        return original;
    SPKDirectLocalSeenTag *tag = objc_getAssociatedObject(self, kSPKDirectLocalSeenTagKey);
    if (!tag)
        return original;
    SPKDirectLocalSeenSeedSent(tag, original);

    // Read on this device up to the newest incoming message: the own entry moves to
    // the newest message of the chat, unless the server's entry already covers it.
    NSDate *local = SPKDirectLocalSeenLocalDate(tag);
    SPKDirectLocalSeenScan *scan = tag.scan;
    if (!scan.incomingDate || scan.anyId.length == 0 || !SPKDirectLocalSeenDateCovered(scan.incomingDate, local))
        return original;
    id mine = original[tag.accountPK];
    NSDate *sent = SPKDirectLocalSeenDateValue(mine, @"sentTimestamp", "_sentTimestamp");
    if (sent && sent.timeIntervalSince1970 + 1.0 >= scan.anyDate.timeIntervalSince1970)
        return original;

    NSDictionary *cached = objc_getAssociatedObject(self, kSPKDirectLocalSeenFakeKey);
    if ([SPKDirectLocalSeenString(cached[tag.accountPK], @"messageId", "_messageId") isEqualToString:scan.anyId])
        return cached;

    id info = SPKDirectLocalSeenMakeLastSeen(mine, scan.anyId, scan.anyDate, local);
    if (!info)
        return original;
    SPKDirectLocalSeenLogOnce(tag, @"lastSeen replaced", local);
    NSMutableDictionary *result = [original mutableCopy];
    result[tag.accountPK] = info;
    cached = [result copy];
    objc_setAssociatedObject(self, kSPKDirectLocalSeenFakeKey, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cached;
}
%end

%end

void SPKInstallDirectLocalSeenHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class threadClass = NSClassFromString(@"IGDirectPublishedThread");
        Class metadataClass = NSClassFromString(@"IGDirectThreadMetadata");
        if (!threadClass || !metadataClass) {
            SPKLog(@"Messages", @"[Sparkle LocalSeen] Not installed thread=%@ metadata=%@", threadClass, metadataClass);
            return;
        }

        SPKDirectLocalSeenThreads = [NSMapTable strongToWeakObjectsMapTable];
        SPKDirectLocalSeenThreadsLock = [NSLock new];
        SPKDirectLocalSeenAppActive = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            SPKDirectLocalSeenAppActive = YES;
            // Reading resumed in the chat that was left open.
            NSString *threadId = SPKDirectActiveThreadContext().threadId;
            if (threadId.length > 0)
                SPKDirectLocalSeenNoteThreadViewed(threadId);
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            SPKDirectLocalSeenAppActive = NO;
        }];

        %init(SPKDirectLocalSeenHooks, IGDirectPublishedThread = threadClass, IGDirectThreadMetadata = metadataClass);

        Class applicatorClass = NSClassFromString(@"IGDirectCacheUpdatesApplicator");
        SEL applySelector = NSSelectorFromString(@"_applyThreadUpdates:completion:userAccess:");
        BOOL refreshHooked = applicatorClass && class_getInstanceMethod(applicatorClass, applySelector);
        if (refreshHooked)
            MSHookMessageEx(applicatorClass, applySelector, (IMP)SPKDirectLocalSeenApplyUpdates, (IMP *)&SPKDirectLocalSeenOrigApplyUpdates);
        SPKLog(@"Messages", @"[Sparkle LocalSeen] Installed enabled=%d refresh=%d", SPKDirectLocalSeenEnabled(), refreshHooked);
    });
}
