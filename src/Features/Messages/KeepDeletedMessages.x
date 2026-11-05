#import "../../AssetUtils.h"
#import "SPKStrings.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Shared/Messages/SPKDirectUserResolver.h"
#import "../../Shared/Messages/SPKPresenceTracking.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "DeletedMessagesLog/SPKDeletedMessagesCapture.h"
#import "DeletedMessagesLog/SPKDeletedMessagesStorage.h"
#import "DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// Keep deleted messages — blocks unsend removal only.
// Reason 0 = unsend, reason 2 = delete-for-you.
// Lighter version: no class-list scan, uses the known remove mutation processor.

#define SPK_SENDER_MAP_MAX 3000
#define SPK_CONTENT_MAP_MAX 2500
#define SPK_PRESERVED_MAX 200
#define SPK_UNSENT_TOAST_DEDUPE_MAX 200
#define SPK_UNSENT_TOAST_DEDUPE_TTL 5.0
// Coalescing: collapse a burst of unsent toasts into one summary pill so a
// backlog sync after being away doesn't bombard the user with pills. We wait
// for a short quiet window (IDLE) after the last event, but never hold a pill
// longer than MAX after the first buffered event so a steady stream still
// resolves periodically.
#define SPK_UNSENT_COALESCE_IDLE 0.8
#define SPK_UNSENT_COALESCE_MAX 3.0
#define SPK_PRESERVED_IDS_KEY @"SPKPreservedMsgIdsByPk"
#define SPK_PRESERVED_LEGACY_KEY @"SPKPreservedMsgIds"
#define SPK_PRESERVED_TAG 1399

static NSMutableDictionary<NSString *, NSDate *> *spkDeleteForYouKeys;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *spkPreservedByPk;
static NSMutableDictionary<NSString *, NSString *> *spkSenderPkBySid;
static NSMutableDictionary<NSString *, NSString *> *spkSenderNameBySid;
static NSMutableDictionary<NSString *, NSString *> *spkContentClassBySid;
static NSMutableDictionary<NSString *, NSNumber *> *spkSentByOwnerBySid;
static NSMutableSet<NSString *> *spkPendingLocalSids;
static NSMutableDictionary<NSString *, NSDate *> *spkUnsentToastDedupe;
// Reaction unsend previews collected during a single _applyThreadUpdates pass,
// drained by new_applyUpdates to fire reaction toasts.
static NSMutableArray<NSDictionary *> *spkPendingReactionPreviews;
static char kSPKPreservedIndicatorOwnMessageKey;
static char kSPKPreservedIndicatorStyleKey;
// Per-cell reference to its live indicator badge (nil when none). Lets the hot
// layoutSubviews path skip the full re-evaluation for the common, non-preserved
// cell without a subtree viewWithTag: search or metadata resolution.
static char kSPKPreservedIndicatorBadgeKey;

static void spkUpdateCellIndicator(id cell);

static inline BOOL spkKeepDeletedEnabled(void) { return [SPKUtils getBoolPref:@"msgs_keep_deleted"]; }
static inline BOOL spkDeletedLogEnabled(void) { return [SPKUtils getBoolPref:@"msgs_deleted_log"]; }
static inline BOOL spkIndicatorEnabled(void) { return spkKeepDeletedEnabled(); }
static inline BOOL spkReactionLogEnabled(void) { return [SPKUtils getBoolPref:@"msgs_deleted_log_reactions"]; }

static BOOL spkThreadBlockedBySeenList(NSString *threadId) {
    if (![SPKUtils getBoolPref:@"msgs_deleted_log_respect_seen_list"])
        return NO;
    if (threadId.length == 0)
        return NO;
    return SPKDirectManualSeenListContainsThreadId(threadId, [SPKUtils getBoolPref:@"msgs_manual_seen"]);
}

static id spkIvar(id obj, const char *name) {
    if (!obj || !name)
        return nil;
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv)
        return nil;
    @try {
        return object_getIvar(obj, iv);
    } @catch (__unused id e) {
        return nil;
    }
}

static void spkSetIvar(id obj, const char *name, id value) {
    if (!obj || !name)
        return;
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv)
        return;
    @try {
        object_setIvar(obj, iv, value);
    } @catch (__unused id e) {
    }
}

// First non-nil object ivar among several candidate names. IG 434 turned
// IGDirectMessageCell into a Swift class, so several ivars lost their `_`
// prefix and lazy-stored ones gained a `$__lazy_storage_$` prefix.
static id spkIvarAny(id obj, NSArray<NSString *> *names) {
    for (NSString *n in names) {
        id v = spkIvar(obj, n.UTF8String);
        if (v)
            return v;
    }
    return nil;
}

static double spkDoubleIvarAny(id obj, NSArray<NSString *> *names, double fallback) {
    if (!obj)
        return fallback;
    for (NSString *n in names) {
        Ivar iv = class_getInstanceVariable([obj class], n.UTF8String);
        if (!iv)
            continue;
        @try {
            ptrdiff_t off = ivar_getOffset(iv);
            return *(double *)((char *)(__bridge void *)obj + off);
        } @catch (__unused id e) {
        }
    }
    return fallback;
}

// IGDirectMessageCell is an Obj-C class up to ~433 and a Swift class from 434
// (runtime name mangled as `_TtC<n>IGDirectMessageCell<n>IGDirectMessageCell`).
static Class spkDirectMessageCellClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"IGDirectMessageCell");
        if (!cls)
            cls = NSClassFromString(@"_TtC19IGDirectMessageCell19IGDirectMessageCell");
    });
    return cls;
}

static long long spkIntegerIvar(id obj, const char *name, long long fallback) {
    if (!obj || !name)
        return fallback;
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv)
        return fallback;
    @try {
        ptrdiff_t off = ivar_getOffset(iv);
        return *(long long *)((char *)(__bridge void *)obj + off);
    } @catch (__unused id e) {
        return fallback;
    }
}

static NSString *spkStringValue(id value) {
    if ([value isKindOfClass:NSString.class])
        return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:NSNumber.class])
        return [(NSNumber *)value stringValue];
    return nil;
}

static NSString *spkFirstStringIvar(id obj, const char **names, int count) {
    for (int i = 0; i < count; i++) {
        NSString *s = spkStringValue(spkIvar(obj, names[i]));
        if (s.length)
            return s;
    }
    return nil;
}

static NSString *spkServerIdFromKey(id key) {
    static const char *names[] = {"_messageServerId", "_serverId"};
    return spkFirstStringIvar(key, names, 2);
}

static NSString *spkServerIdFromMetadata(id meta) {
    static const char *names[] = {"_serverId", "_messageServerId"};
    NSString *sid = spkFirstStringIvar(meta, names, 2);
    if (sid.length)
        return sid;
    return spkServerIdFromKey(spkIvar(meta, "_key"));
}

static NSString *spkServerIdFromMessage(id message) {
    NSString *sid = spkServerIdFromMetadata(spkIvar(message, "_metadata"));
    if (sid.length)
        return sid;
    return spkServerIdFromMetadata(message);
}

static NSString *spkSenderPkFromMessage(id message) {
    id meta = spkIvar(message, "_metadata");
    NSString *pk = spkStringValue(spkIvar(meta, "_senderPk"));
    return pk.length ? pk : spkStringValue(spkIvar(message, "_senderPk"));
}

static void spkTrimMap(NSMutableDictionary *map, NSUInteger max) {
    if (map.count <= max)
        return;
    NSArray *keys = map.allKeys;
    NSUInteger removeCount = MAX((NSUInteger)1, keys.count / 10);
    for (NSUInteger i = 0; i < removeCount && i < keys.count; i++)
        [map removeObjectForKey:keys[i]];
}

static NSMutableDictionary<NSString *, NSString *> *spkSenderMap(void) {
    if (!spkSenderPkBySid)
        spkSenderPkBySid = NSMutableDictionary.dictionary;
    return spkSenderPkBySid;
}

static NSMutableDictionary<NSString *, NSString *> *spkSenderNameMap(void) {
    if (!spkSenderNameBySid)
        spkSenderNameBySid = NSMutableDictionary.dictionary;
    return spkSenderNameBySid;
}

static NSMutableDictionary<NSString *, NSString *> *spkContentMap(void) {
    if (!spkContentClassBySid)
        spkContentClassBySid = NSMutableDictionary.dictionary;
    return spkContentClassBySid;
}

static NSMutableDictionary<NSString *, NSNumber *> *spkSentByOwnerMap(void) {
    if (!spkSentByOwnerBySid)
        spkSentByOwnerBySid = NSMutableDictionary.dictionary;
    return spkSentByOwnerBySid;
}

static NSMutableSet<NSString *> *spkPendingLocalSet(void) {
    if (!spkPendingLocalSids)
        spkPendingLocalSids = NSMutableSet.set;
    return spkPendingLocalSids;
}

static void spkTrackSenderPk(NSString *sid, NSString *pk) {
    if (!sid.length || !pk.length)
        return;
    NSMutableDictionary *m = spkSenderMap();
    m[sid] = pk;
    spkTrimMap(m, SPK_SENDER_MAP_MAX);
}

static void spkTrackSenderName(NSString *sid, NSString *name) {
    if (!sid.length || !name.length)
        return;
    NSMutableDictionary *m = spkSenderNameMap();
    m[sid] = name;
    spkTrimMap(m, SPK_SENDER_MAP_MAX);
}

static void spkTrackContentClass(NSString *sid, NSString *cls) {
    if (!sid.length || !cls.length)
        return;
    NSMutableDictionary *m = spkContentMap();
    m[sid] = cls;
    spkTrimMap(m, SPK_CONTENT_MAP_MAX);
}

static void spkTrackSentByOwner(NSString *sid, BOOL sentByOwner) {
    if (!sid.length)
        return;
    NSMutableDictionary *m = spkSentByOwnerMap();
    m[sid] = @(sentByOwner);
    spkTrimMap(m, SPK_SENDER_MAP_MAX);
}

// Whether `sid` was sent by the account that owns the thread — i.e. a message
// the user unsent themselves. In IG a message's sender is its unsender, so
// these shouldn't fire an "unsent" toast. Returns NO when ownership is unknown
// so a genuine unsend by someone else still notifies.
static BOOL spkSidSentByOwner(NSString *sid, NSString *ownerPk) {
    if (!sid.length)
        return NO;
    NSNumber *flag = spkSentByOwnerMap()[sid];
    if (flag)
        return flag.boolValue;
    NSString *senderPk = spkSenderMap()[sid];
    return senderPk.length && ownerPk.length && [senderPk isEqualToString:ownerPk];
}

static BOOL spkIsReactionOrActionLog(NSString *sid) {
    NSString *cls = sid.length ? spkContentMap()[sid] : nil;
    if (!cls.length)
        return NO;
    return [cls localizedCaseInsensitiveContainsString:@"reaction"] || [cls localizedCaseInsensitiveContainsString:@"actionlog"];
}

static NSString *spkUserPKFromObject(id user) {
    return spkDirectUserResolverPKFromUser(user);
}

static NSString *spkOwningPkFromApplicator(id applicator) {
    return spkUserPKFromObject(spkIvar(applicator, "_user"));
}

static NSString *spkUsernameFromUserObject(id user) {
    if (!user)
        return nil;
    @try {
        id fc = spkIvar(user, "_fieldCache");
        if ([fc isKindOfClass:NSDictionary.class]) {
            NSString *un = spkStringValue(fc[@"username"]);
            if (un.length)
                return un;
        }
    } @catch (__unused id e) {
    }
    @
    try {
        NSString *un = spkStringValue([user valueForKey:@"username"]);
        if (un.length)
            return un;
    } @catch (__unused id e) {
    }
    return nil;
}

static NSString *spkOwnerUsernameFromApplicator(id applicator) {
    return spkUsernameFromUserObject(spkIvar(applicator, "_user"));
}

static NSString *spkCurrentUserPk(void) {
    @try {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            id session = nil;
            @try {
                session = [w valueForKey:@"userSession"];
            } @catch (__unused id e) {
            }
            id user = nil;
            @try {
                user = [session valueForKey:@"user"];
            } @catch (__unused id e) {
            }
            NSString *pk = spkUserPKFromObject(user);
            if (pk.length)
                return pk;
        }
    } @catch (__unused id e) {
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *spkPreservedStore(void) {
    if (spkPreservedByPk)
        return spkPreservedByPk;

    spkPreservedByPk = NSMutableDictionary.dictionary;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SPK_PRESERVED_IDS_KEY];

    if ([saved isKindOfClass:NSDictionary.class]) {
        for (NSString *pk in saved) {
            NSArray *arr = [saved[pk] isKindOfClass:NSArray.class] ? saved[pk] : nil;
            if (arr.count)
                spkPreservedByPk[pk] = [NSMutableSet setWithArray:arr];
        }
    }

    NSArray *legacy = [NSUserDefaults.standardUserDefaults arrayForKey:SPK_PRESERVED_LEGACY_KEY];
    NSString *currentPk = legacy.count ? spkCurrentUserPk() : nil;

    if (legacy.count && currentPk.length) {
        NSMutableSet *bucket = spkPreservedByPk[currentPk] ?: NSMutableSet.set;
        [bucket addObjectsFromArray:legacy];
        spkPreservedByPk[currentPk] = bucket;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPK_PRESERVED_LEGACY_KEY];
    }

    return spkPreservedByPk;
}

static NSMutableSet<NSString *> *spkBucketForPk(NSString *pk) {
    if (!pk.length)
        return nil;
    NSMutableDictionary *store = spkPreservedStore();
    NSMutableSet *bucket = store[pk];
    if (!bucket) {
        bucket = NSMutableSet.set;
        store[pk] = bucket;
    }
    return bucket;
}

NSMutableSet *spkGetPreservedIds(void) {
    NSString *pk = spkCurrentUserPk();
    return pk.length ? spkBucketForPk(pk) : NSMutableSet.set;
}

static void spkSavePreservedIds(void) {
    NSMutableDictionary *out = NSMutableDictionary.dictionary;

    for (NSString *pk in spkPreservedStore()) {
        NSMutableSet *set = spkPreservedByPk[pk];
        while (set.count > SPK_PRESERVED_MAX)
            [set removeObject:set.anyObject];
        if (set.count)
            out[pk] = set.allObjects;
    }

    if (out.count)
        [NSUserDefaults.standardUserDefaults setObject:out forKey:SPK_PRESERVED_IDS_KEY];
    else
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPK_PRESERVED_IDS_KEY];
}

void spkClearPreservedIds(void) {
    NSString *pk = spkCurrentUserPk();
    if (!pk.length)
        return;
    [spkPreservedStore() removeObjectForKey:pk];
    spkSavePreservedIds();
}

static void spkPruneDeleteForYouKeys(void) {
    if (!spkDeleteForYouKeys.count)
        return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-10.0];
    for (NSString *sid in spkDeleteForYouKeys.allKeys) {
        if ([spkDeleteForYouKeys[sid] compare:cutoff] == NSOrderedAscending)
            [spkDeleteForYouKeys removeObjectForKey:sid];
    }
}

static void spkCaptureMessage(id message) {
    NSString *sid = spkServerIdFromMessage(message);
    if (!sid.length)
        return;

    NSString *pk = spkSenderPkFromMessage(message);
    if (pk.length)
        spkTrackSenderPk(sid, pk);

    spkTrackContentClass(sid, NSStringFromClass([message class]));
}

static void spkCaptureMessagesFromUpdate(id update, NSString *ownerPk, NSString *threadId, SPKDMCandidateMode candidateMode) {
    NSArray *inserts = spkIvar(update, "_insertMessages");
    if ([inserts isKindOfClass:NSArray.class]) {
        for (id m in inserts) {
            spkCaptureMessage(m);
            spkDMCaptureNoteInsert(m, ownerPk, threadId, candidateMode);
        }
    }

    NSArray *replaces = spkIvar(update, "_replaceMessages_messages");
    if ([replaces isKindOfClass:NSArray.class]) {
        for (id m in replaces) {
            spkCaptureMessage(m);
            spkDMCaptureNoteInsert(m, ownerPk, threadId, candidateMode);
        }
    }
}

static BOOL spkKeysContainPendingLocalSid(NSArray *keys) {
    NSMutableSet *pending = spkPendingLocalSet();

    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (sid.length && [pending containsObject:sid])
            return YES;
    }

    return NO;
}

static void spkRemovePendingSidsForKeys(NSArray *keys) {
    NSMutableSet *pending = spkPendingLocalSet();

    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (sid.length)
            [pending removeObject:sid];
    }
}

static BOOL spkKeysContainDeleteForYouSid(NSArray *keys) {
    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (sid.length && spkDeleteForYouKeys[sid])
            return YES;
    }
    return NO;
}

static void spkRemoveDeleteForYouSids(NSArray *keys) {
    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (sid.length)
            [spkDeleteForYouKeys removeObjectForKey:sid];
    }
}

static void spkTrackDeleteForYouKeys(NSArray *keys) {
    if (!spkDeleteForYouKeys)
        spkDeleteForYouKeys = NSMutableDictionary.dictionary;
    NSDate *now = NSDate.date;

    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (sid.length)
            spkDeleteForYouKeys[sid] = now;
    }
}

static BOOL spkReactionNotifyEnabled(void) {
    // Active, not enabled: Haptic Only still needs the reaction detected.
    return SPKNotificationIsActive(kSPKNotificationUnsentReaction);
}

// Resolve the message a reaction targeted, for a preview. Best-effort: the
// in-memory weak cache, then the applicator's per-thread state.
static id spkReactionTargetMessage(NSString *messageId, id applicator, NSString *threadId) {
    if (!messageId.length)
        return nil;
    @try {
        Ivar iv = class_getInstanceVariable([applicator class], "_cache");
        id cache = iv ? object_getIvar(applicator, iv) : nil;
        SEL sel = NSSelectorFromString(@"threadClientStateForThreadId:");
        if (cache && threadId.length && [cache respondsToSelector:sel]) {
            id state = ((id (*)(id, SEL, id))objc_msgSend)(cache, sel, threadId);
            if (state) {
                for (Class c = [state class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
                    Ivar di = class_getInstanceVariable(c, "_messagesByServerId");
                    if (!di)
                        continue;
                    id dict = object_getIvar(state, di);
                    if ([dict isKindOfClass:NSDictionary.class])
                        return ((NSDictionary *)dict)[messageId];
                    break;
                }
            }
        }
    } @catch (__unused id e) {
    }
    return nil;
}

// Examine one content mutation; if it is an "unreact by another user" event,
// capture + collect a toast preview. Returns YES when a reaction was handled.
static BOOL spkHandleReactionMutation(id mutation, NSString *messageId, NSString *ownerPk, NSString *threadId, id applicator) {
    if (!mutation)
        return NO;

    // Only "unreact by other" — `_unreact_reaction` is set when someone removes
    // a reaction they placed. `_unreactSelf_reaction` is the owner's own removal.
    id reaction = spkIvar(mutation, "_unreact_reaction");
    if (!reaction)
        return NO;

    NSString *reactorPk = spkStringValue(spkIvar(mutation, "_unreact_userPk"));
    if (!reactorPk.length)
        reactorPk = spkStringValue(spkIvar(reaction, "_userBasedReaction_userId"));
    // Skip the owner removing their own reaction.
    if (reactorPk.length && ownerPk.length && [reactorPk isEqualToString:ownerPk])
        return NO;
    if (reactorPk.length && [SPKDeletedMessagesStorage isSenderBlocked:reactorPk ownerPK:ownerPk])
        return YES;

    BOOL logOn = spkReactionLogEnabled();
    BOOL notifyOn = spkReactionNotifyEnabled();
    if (!logOn && !notifyOn)
        return YES;

    id target = spkReactionTargetMessage(messageId, applicator, threadId);

    NSDictionary *info = nil;
    if (logOn) {
        info = spkDMCaptureNoteReactionUnsend(reaction, reactorPk, target, messageId, applicator, ownerPk, threadId);
    }
    if (notifyOn) {
        // Build a lightweight preview even when logging is off.
        NSMutableDictionary *preview = info ? [info mutableCopy] : [NSMutableDictionary dictionary];
        if (!preview[@"senderPk"] && reactorPk.length)
            preview[@"senderPk"] = reactorPk;
        if (!preview[@"emoji"]) {
            NSString *emoji = spkStringValue(spkIvar(reaction, "_userBasedReaction_emojiUnicode"));
            if (emoji.length)
                preview[@"emoji"] = emoji;
        }
        if (!preview[@"senderUsername"] && reactorPk.length) {
            NSString *uname = spkDirectUserResolverUsernameForPK(reactorPk);
            if (uname.length)
                preview[@"senderUsername"] = uname;
        }
        // When log capture is off, `info` is nil so the target message preview was
        // never resolved — do it here so the toast can show what was reacted to.
        if (![preview[@"targetPreview"] isKindOfClass:NSString.class] && messageId.length) {
            NSString *tp = spkDMCaptureReactionTargetPreview(messageId, applicator, threadId);
            if (tp.length)
                preview[@"targetPreview"] = tp;
        }
        if (preview.count) {
            if (!spkPendingReactionPreviews)
                spkPendingReactionPreviews = NSMutableArray.array;
            [spkPendingReactionPreviews addObject:preview.copy];
        }
    }
    return YES;
}

static void spkProcessReactionMutations(id update, NSString *ownerPk, NSString *threadId, id applicator) {
    if (!update)
        return;
    if (!spkReactionLogEnabled() && !spkReactionNotifyEnabled())
        return;

    // Single mutation.
    id singleMutation = spkIvar(update, "_mutateMessage_contentMutation");
    if (singleMutation) {
        NSString *mid = spkStringValue(spkIvar(update, "_mutateMessage_messageId"));
        spkHandleReactionMutation(singleMutation, mid, ownerPk, threadId, applicator);
    }

    // Multiple mutations — array of IGDirectMessageContentMutationPair (KVC).
    id multi = spkIvar(update, "_mutateMultipleMessages_contentMutations");
    if ([multi isKindOfClass:NSArray.class]) {
        for (id pair in (NSArray *)multi) {
            NSString *mid = nil;
            id mutation = nil;
            @try {
                mid = spkStringValue([pair valueForKey:@"messageId"]);
            } @catch (__unused id e) {
            }
            @
            try {
                mutation = [pair valueForKey:@"contentMutation"];
            } @catch (__unused id e) {
            }
            if (mutation)
                spkHandleReactionMutation(mutation, mid, ownerPk, threadId, applicator);
        }
    }
}

static BOOL spkProcessMessageUpdate(id update, NSString *ownerPk, NSString *threadId, id applicator, NSMutableSet<NSString *> *preserved, NSMutableSet<NSString *> *detected, NSMutableArray<NSDictionary *> *previews, BOOL loggingAllowed) {
    if (!update || !ownerPk.length)
        return NO;

    SPKDMCandidateMode candidateMode = SPKDMCandidateModeNone;
    if (loggingAllowed && spkDeletedLogEnabled())
        candidateMode = spkKeepDeletedEnabled() ? SPKDMCandidateModeExpiringMediaOnly : SPKDMCandidateModeAll;
    spkCaptureMessagesFromUpdate(update, ownerPk, threadId, candidateMode);
    if (loggingAllowed)
        spkProcessReactionMutations(update, ownerPk, threadId, applicator);

    NSArray *keys = spkIvar(update, "_removeMessages_messageKeys");
    if (![keys isKindOfClass:NSArray.class] || !keys.count)
        return NO;

    long long reason = spkIntegerIvar(update, "_removeMessages_reason", -1);

    if (reason == 2) {
        spkTrackDeleteForYouKeys(keys);
        return NO;
    }

    if (reason != 0)
        return NO;

    if (spkKeysContainPendingLocalSid(keys)) {
        spkRemovePendingSidsForKeys(keys);
        return NO;
    }

    if (spkKeysContainDeleteForYouSid(keys)) {
        spkRemoveDeleteForYouSids(keys);
        return NO;
    }

    NSMutableSet *bucket = spkBucketForPk(ownerPk);
    NSMutableArray *unsendKeys = NSMutableArray.array;
    BOOL keepOn = spkKeepDeletedEnabled();
    BOOL logOn = loggingAllowed && spkDeletedLogEnabled();
    BOOL didPreserve = NO;

    for (id key in keys) {
        NSString *sid = spkServerIdFromKey(key);
        if (!sid.length)
            continue;
        // Reaction removals also arrive here as an actionlog message-key removal.
        // They're handled separately by the reaction-mutation path, so never let
        // them flow into the message-unsend pipeline (else they double-notify as
        // "unsent a message" alongside the reaction toast).
        if (spkIsReactionOrActionLog(sid))
            continue;
        NSString *senderPk = spkSenderMap()[sid];
        if (senderPk.length && [SPKDeletedMessagesStorage isSenderBlocked:senderPk ownerPK:ownerPk])
            continue;
        if (senderPk.length)
            spkTrackSentByOwner(sid, [senderPk isEqualToString:ownerPk]);

        if (keepOn) {
            if (bucket)
                [bucket addObject:sid];
            [preserved addObject:sid];
            didPreserve = YES;
        }
        if (loggingAllowed)
            [detected addObject:sid];
        [unsendKeys addObject:key];
    }

    if (!unsendKeys.count)
        return NO;

    if (loggingAllowed && previews) {
        // The user's own unsends never show a toast, so don't resolve them.
        NSMutableArray *previewKeys = NSMutableArray.array;
        for (id key in unsendKeys) {
            if (!spkSidSentByOwner(spkServerIdFromKey(key), ownerPk))
                [previewKeys addObject:key];
        }
        spkDMCaptureQueuePreviewMetadataForKeys(previewKeys, applicator, ownerPk, threadId, previews);
    }
    if (logOn)
        spkDMCaptureNoteRemoveKeys(unsendKeys, applicator, ownerPk, threadId);
    if (keepOn && didPreserve)
        spkSetIvar(update, "_removeMessages_messageKeys", nil);

    return keepOn && didPreserve;
}

static id spkMessageUpdateFromThreadUpdate(id threadUpdate) {
    id msg = spkIvar(threadUpdate, "_messageUpdate");
    if (msg)
        return msg;

    @try {
        msg = [threadUpdate valueForKey:@"messageUpdate"];
        if (msg)
            return msg;
    } @catch (__unused id e) {
    }

    return nil;
}

static NSString *spkThreadIdFromCacheUpdate(id cacheUpdate) {
    NSString *tid = nil;

    @try {
        tid = spkStringValue([cacheUpdate valueForKey:@"threadId"]);
        if (tid.length)
            return tid;
    } @catch (__unused id e) {
    }

    tid = spkStringValue(spkIvar(cacheUpdate, "_threadId"));
    if (tid.length)
        return tid;

    id threadUpdate = spkIvar(cacheUpdate, "_threadUpdate");
    tid = spkStringValue(spkIvar(threadUpdate, "_removeThread_threadId"));

    return tid;
}

static NSArray *spkThreadUpdatesFromCacheUpdate(id cacheUpdate) {
    @try {
        id updates = [cacheUpdate valueForKey:@"threadUpdates"];
        if ([updates isKindOfClass:NSArray.class])
            return updates;
    } @catch (__unused id e) {
    }

    id single = spkIvar(cacheUpdate, "_threadUpdate");
    return single ? @[ single ] : nil;
}

static NSSet<NSString *> *spkProcessCacheUpdate(id cacheUpdate, NSString *ownerPk, id applicator, NSMutableSet<NSString *> *detected, NSMutableArray<NSDictionary *> *previews) {
    NSMutableSet *preserved = NSMutableSet.set;
    NSString *threadId = spkThreadIdFromCacheUpdate(cacheUpdate);

    if (!cacheUpdate || !threadId.length)
        return preserved;
    BOOL loggingAllowed = !spkThreadBlockedBySeenList(threadId);

    if (!spkDeleteForYouKeys)
        spkDeleteForYouKeys = NSMutableDictionary.dictionary;
    spkPruneDeleteForYouKeys();

    NSArray *threadUpdates = spkThreadUpdatesFromCacheUpdate(cacheUpdate);
    if (![threadUpdates isKindOfClass:NSArray.class])
        return preserved;

    for (id tu in threadUpdates) {
        id msgUpdate = spkMessageUpdateFromThreadUpdate(tu);
        if (msgUpdate)
            spkProcessMessageUpdate(msgUpdate, ownerPk, threadId, applicator, preserved, detected, previews, loggingAllowed);
    }

    return preserved;
}

static NSString *spkUnsentText(NSString *sender, NSString *deleter) {
    if (sender.length && deleter.length) {
        return [sender isEqualToString:deleter]
                   ? [NSString stringWithFormat:SPKL(@"MESSAGE_UNSENT_SENDER_FORMAT"), sender]
                   : [NSString stringWithFormat:SPKL(@"MESSAGE_UNSENT_FROM_FORMAT"), deleter, sender];
    }
    if (sender.length)
        return [NSString stringWithFormat:SPKL(@"MESSAGE_UNSENT_PASSIVE_FORMAT"), sender];
    if (deleter.length)
        return [NSString stringWithFormat:SPKL(@"MESSAGE_UNSENT_SENDER_FORMAT"), deleter];
    return SPKL(@"MESSAGE_UNSENT_ANONYMOUS");
}

static NSString *spkNotificationKindPhrase(SPKDeletedMessageKind kind) {
    switch (kind) {
    case SPKDeletedMessageKindPhoto:
        return @"photo";
    case SPKDeletedMessageKindVideo:
        return @"video";
    case SPKDeletedMessageKindVoice:
        return SPKL(@"MESSAGES_KEEP_DELETED_MESSAGES_VOICE_MESSAGE");
    case SPKDeletedMessageKindGif:
        return @"GIF";
    case SPKDeletedMessageKindSticker:
        return @"sticker";
    case SPKDeletedMessageKindShare:
        return @"share";
    case SPKDeletedMessageKindLink:
        return @"link";
    case SPKDeletedMessageKindAudioShare:
        return @"music share";
    case SPKDeletedMessageKindText:
    case SPKDeletedMessageKindUnknown:
    case SPKDeletedMessageKindOther:
    default:
        return @"message";
    }
}

static NSString *spkTrimmedSingleLinePreview(NSString *text) {
    if (![text isKindOfClass:NSString.class])
        return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length)
        return nil;
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([trimmed containsString:@"  "])
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (trimmed.length > 120)
        trimmed = [[trimmed substringToIndex:117] stringByAppendingString:@"..."];
    return trimmed;
}

static NSString *spkDisplayNameForPreview(NSDictionary *preview, NSString *fallback) {
    NSString *username = [preview[@"senderUsername"] isKindOfClass:NSString.class] ? preview[@"senderUsername"] : nil;
    if (username.length)
        return [username hasPrefix:@"@"] ? username : [@"@" stringByAppendingString:username];
    NSString *fullName = [preview[@"senderFullName"] isKindOfClass:NSString.class] ? preview[@"senderFullName"] : nil;
    if (fullName.length)
        return fullName;
    return fallback.length ? fallback : SPKL(@"MESSAGE_SENDER_UNKNOWN");
}

static NSString *spkUnsentToastDedupeComponent(NSString *value) {
    if (![value isKindOfClass:NSString.class])
        return @"";
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length)
        return @"";
    trimmed = [trimmed lowercaseString];
    if (trimmed.length > 160)
        trimmed = [trimmed substringToIndex:160];
    return trimmed;
}

static NSArray<NSString *> *spkUnsentToastDedupeKeys(NSDictionary *preview, NSString *fallbackSid, NSString *sender, SPKDeletedMessageKind kind, NSString *text) {
    NSMutableArray<NSString *> *keys = NSMutableArray.array;
    NSString *messageId = [preview[@"messageId"] isKindOfClass:NSString.class] ? preview[@"messageId"] : nil;
    if (!messageId.length)
        messageId = fallbackSid;
    NSString *threadId = [preview[@"threadId"] isKindOfClass:NSString.class] ? preview[@"threadId"] : nil;
    if (messageId.length) {
        NSString *cleanMessageId = spkUnsentToastDedupeComponent(messageId);
        [keys addObject:[NSString stringWithFormat:@"id|%@", cleanMessageId]];
        if (threadId.length) {
            [keys addObject:[NSString stringWithFormat:@"idthread|%@|%@", spkUnsentToastDedupeComponent(threadId), cleanMessageId]];
        }
        return keys;
    }
    [keys addObject:[NSString stringWithFormat:@"fallback|%ld|%@|%@",
                                               (long)kind,
                                               spkUnsentToastDedupeComponent(sender),
                                               spkUnsentToastDedupeComponent(text)]];
    return keys;
}

static BOOL spkShouldShowUnsentToast(NSArray<NSString *> *dedupeKeys) {
    if (!dedupeKeys.count)
        return YES;
    if (!spkUnsentToastDedupe)
        spkUnsentToastDedupe = NSMutableDictionary.dictionary;

    NSDate *now = NSDate.date;
    for (NSString *key in [spkUnsentToastDedupe.allKeys copy]) {
        NSDate *date = spkUnsentToastDedupe[key];
        if (![date isKindOfClass:NSDate.class] || [now timeIntervalSinceDate:date] > SPK_UNSENT_TOAST_DEDUPE_TTL) {
            [spkUnsentToastDedupe removeObjectForKey:key];
        }
    }

    for (NSString *dedupeKey in dedupeKeys) {
        NSDate *existing = spkUnsentToastDedupe[dedupeKey];
        if ([existing isKindOfClass:NSDate.class] && [now timeIntervalSinceDate:existing] <= SPK_UNSENT_TOAST_DEDUPE_TTL) {
            return NO;
        }
    }

    while (spkUnsentToastDedupe.count >= SPK_UNSENT_TOAST_DEDUPE_MAX) {
        NSString *oldestKey = nil;
        NSDate *oldestDate = nil;
        for (NSString *key in spkUnsentToastDedupe) {
            NSDate *date = spkUnsentToastDedupe[key];
            if (![date isKindOfClass:NSDate.class] || !oldestDate || [date compare:oldestDate] == NSOrderedAscending) {
                oldestDate = [date isKindOfClass:NSDate.class] ? date : nil;
                oldestKey = key;
            }
        }
        if (!oldestKey.length)
            break;
        [spkUnsentToastDedupe removeObjectForKey:oldestKey];
    }

    for (NSString *dedupeKey in dedupeKeys) {
        if (dedupeKey.length)
            spkUnsentToastDedupe[dedupeKey] = now;
    }
    return YES;
}

// Build a human-readable list of distinct senders, e.g. "@a", "@a & @b",
// "@a, @b & 2 others". Senders are passed in first-seen order.
static NSString *spkSenderSummary(NSArray<NSString *> *senders) {
    NSUInteger n = senders.count;
    if (n == 0)
        return nil;
    if (n == 1)
        return senders[0];
    if (n == 2)
        return [NSString stringWithFormat:SPKL(@"SENDER_LIST_TWO_FORMAT"), senders[0], senders[1]];
    NSUInteger others = n - 2;
    return [NSString stringWithFormat:SPKL(@"SENDER_LIST_MANY_FORMAT"),
                                      senders[0], senders[1], SPKLP(@"COMMON_OTHER_COUNT", (NSInteger)others)];
}

// A debounce buffer that collapses a burst of unsent/reaction toasts into one
// summary pill. A single buffered event renders the full per-event pill; two or
// more collapse to a sender-aware summary. One batcher instance per identifier.
@interface SPKUnsentToastBatcher : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *iconResource;
// Given the distinct senders (first-seen order) and total event count, returns
// @{ @"title": ..., @"subtitle": (optional) } for the collapsed summary pill.
@property (nonatomic, copy) NSDictionary * (^summaryBuilder)(NSArray<NSString *> *senders, NSUInteger count);
// Tap handler used for the collapsed summary pill (a burst spans threads, so it
// opens the whole log rather than one thread).
@property (nonatomic, copy) void (^summaryOnTap)(void);
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic, strong) NSDate *firstEventDate;
- (void)addEntrySender:(NSString *)sender
                 title:(NSString *)title
              subtitle:(nullable NSString *)subtitle
                 onTap:(nullable void (^)(void))onTap;
@end

@implementation SPKUnsentToastBatcher

- (instancetype)init {
    if ((self = [super init]))
        _entries = NSMutableArray.array;
    return self;
}

// Always called on the main thread (toasts are dispatched onto the main queue).
- (void)addEntrySender:(NSString *)sender
                 title:(NSString *)title
              subtitle:(NSString *)subtitle
                 onTap:(void (^)(void))onTap {
    NSMutableDictionary *entry = [@{
        @"sender" : sender.length ? sender : @"Someone",
        @"title" : title ?: @"",
        @"subtitle" : subtitle ?: @"",
    } mutableCopy];
    if (onTap)
        entry[@"onTap"] = [onTap copy];
    [self.entries addObject:entry];
    if (!self.firstEventDate)
        self.firstEventDate = NSDate.date;

    NSTimeInterval elapsed = -[self.firstEventDate timeIntervalSinceNow];
    NSTimeInterval remaining = SPK_UNSENT_COALESCE_MAX - elapsed;
    [self.flushTimer invalidate];
    if (remaining <= 0) {
        [self flush];
        return;
    }
    NSTimeInterval interval = MIN((NSTimeInterval)SPK_UNSENT_COALESCE_IDLE, remaining);
    __weak typeof(self) weakSelf = self;
    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                      repeats:NO
                                                        block:^(__unused NSTimer *t) {
                                                            [weakSelf flush];
                                                        }];
}

- (void)flush {
    [self.flushTimer invalidate];
    self.flushTimer = nil;
    self.firstEventDate = nil;
    NSArray<NSDictionary *> *batch = [self.entries copy];
    [self.entries removeAllObjects];
    if (!batch.count)
        return;

    if (batch.count == 1) {
        NSDictionary *entry = batch.firstObject;
        NSString *subtitle = [entry[@"subtitle"] length] ? entry[@"subtitle"] : nil;
        SPKNotifyTappable(self.identifier, entry[@"title"], subtitle, self.iconResource, SPKNotificationToneInfo, entry[@"onTap"]);
        return;
    }

    NSMutableArray<NSString *> *senders = NSMutableArray.array;
    for (NSDictionary *entry in batch) {
        NSString *sender = entry[@"sender"];
        if (sender.length && ![senders containsObject:sender])
            [senders addObject:sender];
    }
    NSDictionary *summary = self.summaryBuilder(senders, batch.count);
    NSString *subtitle = [summary[@"subtitle"] length] ? summary[@"subtitle"] : nil;
    SPKNotifyTappable(self.identifier, summary[@"title"], subtitle, self.iconResource, SPKNotificationToneInfo, self.summaryOnTap);
}

@end

static SPKUnsentToastBatcher *spkUnsentMessageBatcher(void) {
    static SPKUnsentToastBatcher *batcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        batcher = [SPKUnsentToastBatcher new];
        batcher.identifier = kSPKNotificationUnsentMessage;
        batcher.iconResource = @"undo_filled";
        batcher.summaryOnTap = ^{
            [SPKDeletedMessagesViewController presentFromViewController:nil];
        };
        batcher.summaryBuilder = ^NSDictionary *(NSArray<NSString *> *senders, NSUInteger count) {
            if (senders.count == 1) {
                return @{@"title" : [NSString stringWithFormat:SPKL(@"BATCH_UNSENT_MESSAGES_FORMAT"), senders[0], (unsigned long)count]};
            }
            return @{
                @"title" : [NSString stringWithFormat:SPKL(@"BATCH_UNSENT_COUNT_FORMAT"), (unsigned long)count],
                @"subtitle" : [NSString stringWithFormat:SPKL(@"BATCH_FROM_SENDERS_FORMAT"), spkSenderSummary(senders) ?: @""],
            };
        };
    });
    return batcher;
}

static SPKUnsentToastBatcher *spkUnsentReactionBatcher(void) {
    static SPKUnsentToastBatcher *batcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        batcher = [SPKUnsentToastBatcher new];
        batcher.identifier = kSPKNotificationUnsentReaction;
        batcher.iconResource = @"reactions";
        batcher.summaryBuilder = ^NSDictionary *(NSArray<NSString *> *senders, NSUInteger count) {
            if (senders.count == 1) {
                return @{@"title" : [NSString stringWithFormat:SPKL(@"MESSAGES_KEEP_DELETED_MESSAGES_VALUE_REMOVED_VALUE_REACTIONS_ACTION"), senders[0], (unsigned long)count]};
            }
            return @{
                @"title" : [NSString stringWithFormat:SPKL(@"BATCH_REACTIONS_REMOVED_FORMAT"), (unsigned long)count],
                @"subtitle" : [NSString stringWithFormat:SPKL(@"BATCH_FROM_SENDERS_FORMAT"), spkSenderSummary(senders) ?: @""],
            };
        };
    });
    return batcher;
}

static void spkShowUnsentToast(NSDictionary *preview, NSString *fallbackSender, NSString *fallbackSenderPk, NSString *fallbackThreadId, NSString *ownerAccount, NSString *fallbackSid) {
    NSString *sender = preview ? spkDisplayNameForPreview(preview, fallbackSender) : (fallbackSender.length ? fallbackSender : SPKL(@"MESSAGE_SENDER_UNKNOWN"));
    SPKDeletedMessageKind kind = [preview[@"kind"] isKindOfClass:NSNumber.class] ? (SPKDeletedMessageKind)[preview[@"kind"] integerValue] : SPKDeletedMessageKindUnknown;
    NSString *text = spkTrimmedSingleLinePreview(preview[@"previewText"] ?: preview[@"text"]);
    NSArray<NSString *> *dedupeKeys = spkUnsentToastDedupeKeys(preview, fallbackSid, sender, kind, text);
    if (!spkShouldShowUnsentToast(dedupeKeys))
        return;
    NSString *kindPhrase = spkNotificationKindPhrase(kind);
    // Name shared posts by their actual type (reel/post/story/...) in the toast too.
    if (kind == SPKDeletedMessageKindShare) {
        NSString *subtype = [preview[@"shareSubtype"] isKindOfClass:NSString.class] ? preview[@"shareSubtype"] : nil;
        kindPhrase = [SPKDeletedMessageShareSubtypeName(subtype) lowercaseString];
    }
    NSString *title = [NSString stringWithFormat:SPKL(@"MESSAGE_UNSENT_KIND_FORMAT"), sender, kindPhrase];
    NSString *subtitle = text.length ? [NSString stringWithFormat:@"\"%@\"", text] : nil;
    if (ownerAccount.length) {
        subtitle = subtitle.length ? [NSString stringWithFormat:@"%@ • %@", title, subtitle] : title;
        title = ownerAccount;
    }

    // Tapping the pill opens this thread's deleted-messages log (like the eye-menu
    // action). Prefer the message's own thread/sender, falling back to the pass's.
    NSString *threadId = [preview[@"threadId"] isKindOfClass:NSString.class] ? preview[@"threadId"] : fallbackThreadId;
    NSString *senderPk = [preview[@"senderPk"] isKindOfClass:NSString.class] ? preview[@"senderPk"] : fallbackSenderPk;
    void (^onTap)(void) = (threadId.length || senderPk.length) ? ^{
        [SPKDeletedMessagesViewController presentForThreadId:threadId senderPK:senderPk senderName:nil fromViewController:nil];
    }
                                                               : nil;
    [spkUnsentMessageBatcher() addEntrySender:sender title:title subtitle:subtitle onTap:onTap];
}

static void spkShowUnsentReactionToast(NSDictionary *preview, NSString *ownerAccount) {
    if (![preview isKindOfClass:NSDictionary.class])
        return;
    NSString *sender = spkDisplayNameForPreview(preview, SPKL(@"MESSAGE_SENDER_UNKNOWN"));
    NSString *emoji = [preview[@"emoji"] isKindOfClass:NSString.class] ? preview[@"emoji"] : nil;
    NSString *targetPreview = spkTrimmedSingleLinePreview(preview[@"targetPreview"]);

    // Dedupe on sender + emoji + target so rapid duplicate deltas don't spam.
    NSString *dedupeKey = [NSString stringWithFormat:@"reaction|%@|%@|%@",
                                                     spkUnsentToastDedupeComponent(sender),
                                                     spkUnsentToastDedupeComponent(emoji),
                                                     spkUnsentToastDedupeComponent(targetPreview)];
    if (!spkShouldShowUnsentToast(@[ dedupeKey ]))
        return;

    NSString *title = emoji.length
                          ? [NSString stringWithFormat:SPKL(@"MESSAGES_KEEP_DELETED_MESSAGES_VALUE_REMOVED_VALUE_REACTION_ACTION"), sender, emoji]
                          : [NSString stringWithFormat:SPKL(@"MESSAGES_KEEP_DELETED_MESSAGES_VALUE_REMOVED_REACTION_ACTION"), sender];
    NSString *subtitle = targetPreview.length ? [NSString stringWithFormat:SPKL(@"REACTION_CONTEXT_FORMAT"), targetPreview] : nil;
    if (ownerAccount.length) {
        subtitle = subtitle.length ? [NSString stringWithFormat:@"%@ • %@", title, subtitle] : title;
        title = ownerAccount;
    }
    [spkUnsentReactionBatcher() addEntrySender:sender title:title subtitle:subtitle onTap:nil];
}

static void spkRefreshVisibleCellIndicators(void) {
    if (!spkIndicatorEnabled())
        return;

    Class cellClass = spkDirectMessageCellClass();
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!cellClass || !window)
        return;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];

    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        if ([v isKindOfClass:cellClass]) {
            spkUpdateCellIndicator(v);
            continue;
        }

        for (UIView *sub in v.subviews)
            [stack addObject:sub];
    }
}

static void spkHandleApplyUpdates(id self, id updates, void (^invokeOriginal)(void)) {
    spkDirectUserResolverSetActiveApplicator(self);

    BOOL keepOn = spkKeepDeletedEnabled();
    BOOL logOn = spkDeletedLogEnabled();
    BOOL toastOn = SPKNotificationIsActive(kSPKNotificationUnsentMessage);
    BOOL reactionOn = spkReactionLogEnabled() || spkReactionNotifyEnabled();

    BOOL activityOn = SPKPresenceNotificationsEnabled();
    if (!keepOn && !logOn && !toastOn && !reactionOn && !activityOn) {
        invokeOriginal();
        return;
    }

    NSString *ownerPk = spkOwningPkFromApplicator(self);
    if (logOn && ownerPk.length)
        spkDMCaptureRetryPendingRemovals(self, ownerPk);
    NSMutableSet *preserved = NSMutableSet.set;
    NSMutableSet *detected = NSMutableSet.set;
    // Filled on the capture queue; only read it from spkDMCaptureAfterQueuedWork.
    NSMutableArray<NSDictionary *> *previews = toastOn ? NSMutableArray.array : nil;

    // Reaction previews accumulate into a global during processing; reset so we
    // only fire toasts for this pass.
    spkPendingReactionPreviews = NSMutableArray.array;

    if (ownerPk.length && [updates isKindOfClass:NSArray.class]) {
        for (id update in (NSArray *)updates) {
            @autoreleasepool {
                NSSet *set = spkProcessCacheUpdate(update, ownerPk, self, detected, previews);
                if (set.count)
                    [preserved unionSet:set];
            }
        }
    }

    if (preserved.count)
        spkSavePreservedIds();

    invokeOriginal();
    if (activityOn && ownerPk.length)
        SPKPresenceHandleDirectThreadUpdates(self, updates, ownerPk);
    if (logOn && ownerPk.length)
        spkDMCaptureRetryPendingRemovals(self, ownerPk);

    NSArray<NSDictionary *> *reactionPreviews = spkPendingReactionPreviews.count ? [spkPendingReactionPreviews copy] : nil;
    spkPendingReactionPreviews = nil;

    if (!preserved.count && !detected.count && !reactionPreviews.count)
        return;

    NSString *currentPk = spkCurrentUserPk();
    BOOL foreground = currentPk.length && [currentPk isEqualToString:ownerPk];
    NSString *ownerName = foreground ? nil : spkOwnerUsernameFromApplicator(self);

    NSString *toastSid = nil;
    for (NSString *d in detected) {
        if (spkSidSentByOwner(d, ownerPk))
            continue;
        toastSid = d;
        break;
    }
    NSString *toastSenderName = toastSid.length ? spkSenderNameMap()[toastSid] : nil;
    NSString *toastSenderPk = toastSid.length ? spkSenderMap()[toastSid] : nil;
    if (!toastSenderName.length && toastSenderPk.length) {
        toastSenderName = spkDirectUserResolverUsernameForPK(toastSenderPk);
        if (toastSenderName.length)
            spkTrackSenderName(toastSid, toastSenderName);
    }

    if (toastOn && detected.count) {
        spkDMCaptureAfterQueuedWork(^{
            NSArray<NSDictionary *> *resolvedPreviews = [previews copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                // Skip the user's own unsends: a self-unsend has the owner as its
                // sender and shouldn't notify. Preserve/log are unaffected.
                NSMutableArray<NSDictionary *> *toastPreviews = NSMutableArray.array;
                for (NSDictionary *preview in resolvedPreviews) {
                    NSString *psid = [preview[@"messageId"] isKindOfClass:NSString.class] ? preview[@"messageId"] : nil;
                    NSString *psender = [preview[@"senderPk"] isKindOfClass:NSString.class] ? preview[@"senderPk"] : nil;
                    BOOL ownUnsend = (psender.length && ownerPk.length && [psender isEqualToString:ownerPk]) || spkSidSentByOwner(psid, ownerPk);
                    if (!ownUnsend)
                        [toastPreviews addObject:preview];
                }
                if (toastPreviews.count) {
                    for (NSDictionary *preview in toastPreviews)
                        spkShowUnsentToast(preview, toastSenderName, toastSenderPk, nil, ownerName, toastSid);
                } else if (toastSid.length) {
                    spkShowUnsentToast(nil, toastSenderName, toastSenderPk, nil, ownerName, toastSid);
                }
            });
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (foreground)
            spkRefreshVisibleCellIndicators();
        if (reactionPreviews.count) {
            for (NSDictionary *preview in reactionPreviews)
                spkShowUnsentReactionToast(preview, ownerName);
        }
    });
}

static void (*orig_applyUpdatesUserAccess)(id, SEL, id, id, id);
static void new_applyUpdatesUserAccess(id self, SEL _cmd, id updates, id completion, id userAccess) {
    spkHandleApplyUpdates(self, updates, ^{
        orig_applyUpdatesUserAccess(self, _cmd, updates, completion, userAccess);
    });
}

static void (*orig_applyUpdatesCompletion)(id, SEL, id, id);
static void new_applyUpdatesCompletion(id self, SEL _cmd, id updates, id completion) {
    spkHandleApplyUpdates(self, updates, ^{
        orig_applyUpdatesCompletion(self, _cmd, updates, completion);
    });
}

static void (*orig_applyUpdatesOnly)(id, SEL, id);
static void new_applyUpdatesOnly(id self, SEL _cmd, id updates) {
    spkHandleApplyUpdates(self, updates, ^{
        orig_applyUpdatesOnly(self, _cmd, updates);
    });
}

static void (*orig_removeMutationExecute)(id, SEL, id, id);
static void new_removeMutationExecute(id self, SEL _cmd, id handler, id pkg) {
    NSArray *keys = spkIvar(self, "_messageKeys");
    long long reason = spkIntegerIvar(self, "_reason", -1);

    if ([keys isKindOfClass:NSArray.class]) {
        if (reason == 2) {
            spkTrackDeleteForYouKeys(keys);
        } else if (reason != 0) {
            for (id key in keys) {
                NSString *sid = spkServerIdFromKey(key);
                if (sid.length)
                    [spkPendingLocalSet() addObject:sid];
            }
        }
    }

    orig_removeMutationExecute(self, _cmd, handler, pkg);
}

static NSString *spkCellServerId(id cell) {
    id vm = spkIvar(cell, "_viewModel");

    if (!vm && [cell respondsToSelector:@selector(viewModel)]) {
        @try {
            vm = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(viewModel));
        } @catch (__unused id e) {
        }
    }

    if (!vm)
        return nil;

    id meta = nil;
    SEL metaSel = NSSelectorFromString(@"messageMetadata");

    if ([vm respondsToSelector:metaSel]) {
        @try {
            meta = ((id (*)(id, SEL))objc_msgSend)(vm, metaSel);
        } @catch (__unused id e) {
        }
    }

    return spkServerIdFromMetadata(meta);
}

static BOOL spkCellIsPreserved(id cell) {
    NSString *sid = spkCellServerId(cell);
    return sid.length && [spkGetPreservedIds() containsObject:sid];
}

static BOOL spkCellSenderIsCurrentUser(id cell) {
    NSString *sid = spkCellServerId(cell);
    if (!sid.length)
        return NO;
    NSNumber *sentByOwner = spkSentByOwnerMap()[sid];
    if ([sentByOwner isKindOfClass:NSNumber.class])
        return sentByOwner.boolValue;
    NSString *senderPk = spkSenderMap()[sid];
    NSString *currentPk = spkCurrentUserPk();
    return senderPk.length && currentPk.length && [senderPk isEqualToString:currentPk];
}

static UIView *spkAccessoryWrapper(UIView *view) {
    UIView *cur = view;

    while (cur && cur.superview) {
        CGSize s = cur.frame.size;
        if (s.width >= 32.0 && s.width <= 64.0 && fabs(s.width - s.height) < 6.0)
            return cur;
        cur = cur.superview;
    }

    return view;
}

static void spkSetTrailingAccessoriesHidden(id cell, BOOL hidden) {
    NSArray *views = spkIvarAny(cell, @[ @"_tappableAccessoryViews", @"tappableAccessoryViews" ]);
    if (![views isKindOfClass:NSArray.class])
        return;

    for (UIView *v in views) {
        if (![v isKindOfClass:UIView.class])
            continue;
        UIView *wrap = spkAccessoryWrapper(v);
        wrap.hidden = hidden;
        if (wrap != v)
            v.hidden = hidden;
    }
}

static CGRect spkMessageContentRectInHost(id cell, UIView *content, UIView *host) {
    if (!content || !host)
        return CGRectZero;
    CGRect rect = [host convertRect:content.bounds fromView:content];
    if (CGRectGetWidth(rect) > 1.0 && CGRectGetHeight(rect) > 1.0)
        return rect;

    CGSize size = CGSizeZero;
    if ([cell respondsToSelector:@selector(messageContentSize)]) {
        @try {
            size = ((CGSize (*)(id, SEL))objc_msgSend)(cell, @selector(messageContentSize));
        } @catch (__unused id e) {
        }
    }
    if (size.width <= 1.0 || size.height <= 1.0)
        return rect;

    CGFloat xOffset = spkDoubleIvarAny(cell, @[ @"_messageBubbleXOffset", @"messageBubbleXOffset" ], 0.0);

    CGRect hostBounds = host.bounds;
    CGFloat x = xOffset;
    if (x <= 0.0 || x > CGRectGetWidth(hostBounds))
        x = CGRectGetMinX(rect);
    CGFloat y = CGRectGetMidY(rect) - (size.height / 2.0);
    if (!isfinite(y) || y < 0.0 || y > CGRectGetHeight(hostBounds))
        y = CGRectGetMidY(hostBounds) - (size.height / 2.0);
    return CGRectMake(x, y, size.width, size.height);
}

static void spkPositionIndicatorBadge(UIView *badge, id cell, UIView *content, UIView *host, BOOL sentByCurrentUser) {
    if (!badge || !content || !host)
        return;
    CGRect contentRect = spkMessageContentRectInHost(cell, content, host);
    CGFloat frameSize = 44.0;
    CGFloat x = sentByCurrentUser ? CGRectGetMinX(contentRect) - frameSize : CGRectGetMaxX(contentRect);
    CGFloat y = CGRectGetMidY(contentRect) - (frameSize / 2.0);

    if (!isfinite(x) || !isfinite(y)) {
        badge.hidden = YES;
        return;
    }

    badge.hidden = NO;
    badge.frame = CGRectMake(x, y, frameSize, frameSize);
}

static void spkUpdateCellIndicator(id cell) {
    if (![cell isKindOfClass:UIView.class])
        return;

    UIView *view = (UIView *)cell;
    UIView *old = objc_getAssociatedObject(cell, &kSPKPreservedIndicatorBadgeKey) ?: [view viewWithTag:SPK_PRESERVED_TAG];

    if (!spkIndicatorEnabled()) {
        if (old)
            [old removeFromSuperview];
        objc_setAssociatedObject(cell, &kSPKPreservedIndicatorBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        spkSetTrailingAccessoriesHidden(cell, NO);
        return;
    }

    BOOL preserved = spkCellIsPreserved(cell);

    if (!preserved) {
        if (old)
            [old removeFromSuperview];
        objc_setAssociatedObject(cell, &kSPKPreservedIndicatorBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        spkSetTrailingAccessoriesHidden(cell, NO);
        return;
    }

    spkSetTrailingAccessoriesHidden(cell, YES);
    BOOL sentByCurrentUser = spkCellSenderIsCurrentUser(cell);
    NSNumber *oldDirection = old ? objc_getAssociatedObject(old, &kSPKPreservedIndicatorOwnMessageKey) : nil;
    NSString *oldStyle = old ? objc_getAssociatedObject(old, &kSPKPreservedIndicatorStyleKey) : nil;
    UIView *content = spkIvarAny(cell, @[ @"_messageContentContainerView",
                                          @"$__lazy_storage_$_messageContentContainerView" ])
                          ?: view;
    UIView *host = nil;
    if ([cell isKindOfClass:UICollectionViewCell.class])
        host = ((UICollectionViewCell *)cell).contentView;
    if (!host)
        host = view;

    if (old && [oldDirection isKindOfClass:NSNumber.class] && oldDirection.boolValue == sentByCurrentUser && [oldStyle isEqualToString:@"undo_filled_secondary_circle_44"] && old.superview == host) {
        spkPositionIndicatorBadge(old, cell, content, host, sentByCurrentUser);
        objc_setAssociatedObject(cell, &kSPKPreservedIndicatorBadgeKey, old, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (old)
        [old removeFromSuperview];

    UIView *badge = UIView.new;
    badge.tag = SPK_PRESERVED_TAG;
    badge.backgroundColor = UIColor.clearColor;
    badge.accessibilityLabel = SPKL(@"A11Y_BADGE_UNSENT");
    badge.userInteractionEnabled = NO;
    objc_setAssociatedObject(badge, &kSPKPreservedIndicatorOwnMessageKey, @(sentByCurrentUser), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kSPKPreservedIndicatorStyleKey, @"undo_filled_secondary_circle_44", OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *background = UIView.new;
    background.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    background.layer.cornerRadius = 16.0;
    background.layer.masksToBounds = YES;
    background.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:background];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"undo_filled"
                                                                                   pointSize:16.0
                                                                               renderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:icon];

    [host addSubview:badge];
    spkPositionIndicatorBadge(badge, cell, content, host, sentByCurrentUser);

    [NSLayoutConstraint activateConstraints:@[
        [background.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [background.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [background.widthAnchor constraintEqualToConstant:32.0],
        [background.heightAnchor constraintEqualToConstant:32.0],
        [icon.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16.0],
        [icon.heightAnchor constraintEqualToConstant:16.0],
    ]];

    objc_setAssociatedObject(cell, &kSPKPreservedIndicatorBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void (*orig_configureCell)(id, SEL, id, id, id);
static void new_configureCell(id self, SEL _cmd, id vm, id ringSpec, id config) {
    orig_configureCell(self, _cmd, vm, ringSpec, config);

    if (!spkIndicatorEnabled())
        return;

    NSString *sid = spkCellServerId(self);
    if (sid.length) {
        id meta = nil;
        SEL metaSel = NSSelectorFromString(@"messageMetadata");

        if ([vm respondsToSelector:metaSel]) {
            @try {
                meta = ((id (*)(id, SEL))objc_msgSend)(vm, metaSel);
            } @catch (__unused id e) {
            }
        }

        NSString *pk = spkStringValue(spkIvar(meta, "_senderPk"));
        if (pk.length) {
            spkTrackSenderPk(sid, pk);
            NSString *currentPk = spkCurrentUserPk();
            if (currentPk.length)
                spkTrackSentByOwner(sid, [pk isEqualToString:currentPk]);
        }
    }

    spkUpdateCellIndicator(self);
}

static void (*orig_cellLayoutSubviews)(id, SEL);
static void new_cellLayoutSubviews(id self, SEL _cmd) {
    orig_cellLayoutSubviews(self, _cmd);

    // Hot path: only cells that actually carry an indicator badge need work here,
    // and that work is a pure reposition. Add/remove decisions stay in
    // configureCell / spkRefreshVisibleCellIndicators. The common cell exits with
    // a single associated-object read — no pref read, no subtree search, no
    // metadata lookup.
    UIView *badge = objc_getAssociatedObject(self, &kSPKPreservedIndicatorBadgeKey);
    UIView *host = badge.superview;
    if (!badge || !host)
        return;
    if (!spkIndicatorEnabled())
        return;

    BOOL sentByCurrentUser = [objc_getAssociatedObject(badge, &kSPKPreservedIndicatorOwnMessageKey) boolValue];
    UIView *content = spkIvarAny(self, @[ @"_messageContentContainerView",
                                          @"$__lazy_storage_$_messageContentContainerView" ])
                          ?: (UIView *)self;
    spkPositionIndicatorBadge(badge, self, content, host, sentByCurrentUser);
}

static void (*orig_addAccessory)(id, SEL, id);
static void new_addAccessory(id self, SEL _cmd, id view) {
    orig_addAccessory(self, _cmd, view);

    if (!spkIndicatorEnabled() || !spkCellIsPreserved(self) || ![view isKindOfClass:UIView.class])
        return;

    UIView *wrap = spkAccessoryWrapper(view);
    wrap.hidden = YES;
    if (wrap != view)
        ((UIView *)view).hidden = YES;
}

static id (*orig_actionLogInit)(id, SEL, id, id, id, id, id, BOOL, BOOL, id);
static id new_actionLogInit(id self, SEL _cmd, id message, id title, id attrs, id parts, id type, BOOL collapsible, BOOL hidden, id genAI) {
    id result = orig_actionLogInit(self, _cmd, message, title, attrs, parts, type, collapsible, hidden, genAI);

    @try {
        SEL sel = @selector(messageId);
        if ([result respondsToSelector:sel]) {
            NSString *sid = spkStringValue(((id (*)(id, SEL))objc_msgSend)(result, sel));
            if (sid.length)
                spkTrackContentClass(sid, @"IGDirectThreadActionLog");
        }
    } @catch (__unused id e) {
    }

    return result;
}

static BOOL spkHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    if (!cls || !class_getInstanceMethod(cls, sel))
        return NO;
    MSHookMessageEx(cls, sel, imp, orig);
    return YES;
}

%ctor {
    Class cacheCls = NSClassFromString(@"IGDirectCacheUpdatesApplicator");
    if (!spkHook(cacheCls, NSSelectorFromString(@"_applyThreadUpdates:completion:userAccess:"), (IMP)new_applyUpdatesUserAccess, (IMP *)&orig_applyUpdatesUserAccess) && !spkHook(cacheCls, NSSelectorFromString(@"_applyThreadUpdates:completion:"), (IMP)new_applyUpdatesCompletion, (IMP *)&orig_applyUpdatesCompletion)) {
        spkHook(cacheCls, NSSelectorFromString(@"_applyThreadUpdates:"), (IMP)new_applyUpdatesOnly, (IMP *)&orig_applyUpdatesOnly);
    }

    Class removeCls = NSClassFromString(@"IGDirectMessageOutgoingUpdateRemoveMessagesMutationProcessor");
    spkHook(removeCls, NSSelectorFromString(@"executeWithResultHandler:accessoryPackage:"), (IMP)new_removeMutationExecute, (IMP *)&orig_removeMutationExecute);

    Class cellCls = spkDirectMessageCellClass();
    // IG 448 renamed the trailing launcherSet: argument to mobileConfig: with the same shape.
    if (!spkHook(cellCls, NSSelectorFromString(@"configureWithViewModel:ringViewSpecFactory:mobileConfig:"), (IMP)new_configureCell, (IMP *)&orig_configureCell)) {
        spkHook(cellCls, NSSelectorFromString(@"configureWithViewModel:ringViewSpecFactory:launcherSet:"), (IMP)new_configureCell, (IMP *)&orig_configureCell);
    }
    spkHook(cellCls, @selector(layoutSubviews), (IMP)new_cellLayoutSubviews, (IMP *)&orig_cellLayoutSubviews);
    spkHook(cellCls, NSSelectorFromString(@"_addTappableAccessoryView:"), (IMP)new_addAccessory, (IMP *)&orig_addAccessory);

    Class actionLogCls = NSClassFromString(@"IGDirectThreadActionLog");
    spkHook(actionLogCls, NSSelectorFromString(@"initWithMessage:title:textAttributes:textParts:actionLogType:collapsible:hidden:genAIMetadata:"), (IMP)new_actionLogInit, (IMP *)&orig_actionLogInit);

    if (!spkIndicatorEnabled()) {
        spkPreservedByPk = NSMutableDictionary.dictionary;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPK_PRESERVED_IDS_KEY];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPK_PRESERVED_LEGACY_KEY];
    }
}

void SPKInstallKeepDeletedMessagesHooksIfEnabled(void) {
    // Hooks are installed from %ctor so logging can observe inserts even when
    // keep-deleted itself is disabled.
}
