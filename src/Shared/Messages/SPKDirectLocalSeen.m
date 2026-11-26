#import "SPKDirectLocalSeen.h"
#import "SPKDirectSeenContext.h"

#import <os/lock.h>

#import "SPKStrings.h"

#import "../../Settings/SPKSetting.h"
#import "../../Utils.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKUserListViewController.h"

// Keep Seen Locally for chats never touches Instagram's receipt path: the receipt
// stays blocked by Manually Mark Seen exactly as before. Instead every chat read on
// this device records the server time of its newest message, and the hooks in
// DirectLocalSeen.x make Instagram's own unread getters answer from that record.
//
// Each record also keeps the newest time Instagram has a receipt for, so the eye
// button can show that the sender has not been told yet.
//
// Records are keyed by account: every participant of a chat sees the same thread
// id, so two accounts on one device would otherwise share a read state.

NSNotificationName const SPKDirectLocalSeenDidChangeNotification = @"SPKDirectLocalSeenDidChangeNotification";

static NSString *const kSPKDirectLocalSeenRecordsKey = @"msgs_local_seen_threads";
static NSString *const kSPKDirectLocalSeenLocalKey = @"local";
static NSString *const kSPKDirectLocalSeenSentKey = @"sent";
static NSString *const kSPKDirectLocalSeenUpdatedKey = @"updatedAt";
// Who the chat is with, for the list of chats seen locally.
static NSString *const kSPKDirectLocalSeenChatKey = @"chat";
// A chat untouched for this long has been replaced by newer messages many times
// over, or abandoned; its record no longer decides anything.
static const NSTimeInterval kSPKDirectLocalSeenRecordLifetime = 60 * 24 * 60 * 60;
static const NSTimeInterval kSPKDirectLocalSeenSuspendDuration = 2.0;

static os_unfair_lock SPKDirectLocalSeenLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *SPKDirectLocalSeenRecords = nil;
static NSMutableDictionary<NSString *, NSNumber *> *SPKDirectLocalSeenSuspendedUntil = nil;
static BOOL SPKDirectLocalSeenSaveScheduled = NO;

BOOL SPKDirectLocalSeenEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_manual_seen"] && [SPKUtils getBoolPref:@"msgs_manual_seen_keep_local"];
}

BOOL SPKDirectLocalSeenAppliesToThreadId(NSString *threadId) {
    BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"msgs_manual_seen"];
    if (threadId.length == 0 || SPKDirectManualSeenThreadCount(manualSeenEnabled) == 0)
        return manualSeenEnabled;
    BOOL listed = SPKDirectManualSeenListContainsThreadId(threadId, manualSeenEnabled);
    return manualSeenEnabled ? !listed : listed;
}

static NSString *SPKDirectLocalSeenKey(NSString *accountPK, NSString *threadId) {
    if (accountPK.length == 0 || threadId.length == 0)
        return nil;
    return [NSString stringWithFormat:@"%@|%@", accountPK, threadId];
}

// Caller holds the lock.
static void SPKDirectLocalSeenLoadLocked(void) {
    if (SPKDirectLocalSeenRecords)
        return;
    SPKDirectLocalSeenRecords = [NSMutableDictionary dictionary];
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSPKDirectLocalSeenRecordsKey];
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - kSPKDirectLocalSeenRecordLifetime;
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, __unused BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || ![record isKindOfClass:NSDictionary.class])
            return;
        if ([record[kSPKDirectLocalSeenUpdatedKey] doubleValue] < cutoff)
            return;
        SPKDirectLocalSeenRecords[key] = [record mutableCopy];
    }];
}

// Caller holds the lock. Writes are coalesced: the unread getters run for every
// inbox row, and a chat that stays open records on every update.
static void SPKDirectLocalSeenScheduleSaveLocked(void) {
    if (SPKDirectLocalSeenSaveScheduled)
        return;
    SPKDirectLocalSeenSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&SPKDirectLocalSeenLock);
        SPKDirectLocalSeenSaveScheduled = NO;
        NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithCapacity:SPKDirectLocalSeenRecords.count];
        [SPKDirectLocalSeenRecords enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *record, __unused BOOL *stop) {
            snapshot[key] = [record copy];
        }];
        os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
        [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kSPKDirectLocalSeenRecordsKey];
    });
}

static void SPKDirectLocalSeenPostChange(NSString *threadId) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SPKDirectLocalSeenDidChangeNotification
                                                          object:nil
                                                        userInfo:@{@"threadId" : threadId}];
    });
}

static void SPKDirectLocalSeenAdvance(NSString *accountPK, NSString *threadId, NSDate *date, NSString *field) {
    NSString *key = SPKDirectLocalSeenKey(accountPK, threadId);
    if (!key || ![date isKindOfClass:NSDate.class])
        return;
    NSTimeInterval ts = date.timeIntervalSince1970;
    if (ts <= 0)
        return;
    // A chat is read while it is open, so the open chat's context names it. That
    // context lives on the main thread.
    NSDictionary *chat = nil;
    if (NSThread.isMainThread) {
        SPKDirectThreadContext *active = SPKDirectActiveThreadContext();
        if ([active.threadId isEqualToString:threadId])
            chat = SPKDirectThreadEntryFromContext(active);
    }

    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    SPKDirectLocalSeenLoadLocked();
    NSMutableDictionary *record = SPKDirectLocalSeenRecords[key];
    BOOL changed = NO;
    if (!record) {
        record = [NSMutableDictionary dictionary];
        SPKDirectLocalSeenRecords[key] = record;
    }
    if ([record[field] doubleValue] < ts) {
        record[field] = @(ts);
        changed = YES;
    }
    if (chat && ![record[kSPKDirectLocalSeenChatKey] isEqual:chat]) {
        record[kSPKDirectLocalSeenChatKey] = chat;
        changed = YES;
    }
    // A receipt Instagram has also covers this device.
    if ([field isEqualToString:kSPKDirectLocalSeenSentKey] && [record[kSPKDirectLocalSeenLocalKey] doubleValue] < ts) {
        record[kSPKDirectLocalSeenLocalKey] = @(ts);
        changed = YES;
    }
    if (changed) {
        record[kSPKDirectLocalSeenUpdatedKey] = @(NSDate.date.timeIntervalSince1970);
        SPKDirectLocalSeenScheduleSaveLocked();
    }
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);

    if (changed)
        SPKDirectLocalSeenPostChange(threadId);
}

void SPKDirectLocalSeenRecord(NSString *accountPK, NSString *threadId, NSDate *date) {
    SPKDirectLocalSeenAdvance(accountPK, threadId, date, kSPKDirectLocalSeenLocalKey);
}

void SPKDirectLocalSeenRecordSent(NSString *accountPK, NSString *threadId, NSDate *date) {
    SPKDirectLocalSeenAdvance(accountPK, threadId, date, kSPKDirectLocalSeenSentKey);
}

static NSTimeInterval SPKDirectLocalSeenValue(NSString *accountPK, NSString *threadId, NSString *field) {
    NSString *key = SPKDirectLocalSeenKey(accountPK, threadId);
    if (!key)
        return 0;
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    SPKDirectLocalSeenLoadLocked();
    NSTimeInterval value = [SPKDirectLocalSeenRecords[key][field] doubleValue];
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
    return value;
}

NSDate *SPKDirectLocalSeenDate(NSString *accountPK, NSString *threadId) {
    NSTimeInterval ts = SPKDirectLocalSeenValue(accountPK, threadId, kSPKDirectLocalSeenLocalKey);
    return ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;
}

BOOL SPKDirectLocalSeenReceiptPending(NSString *accountPK, NSString *threadId) {
    NSTimeInterval local = SPKDirectLocalSeenValue(accountPK, threadId, kSPKDirectLocalSeenLocalKey);
    NSTimeInterval sent = SPKDirectLocalSeenValue(accountPK, threadId, kSPKDirectLocalSeenSentKey);
    return local > 0 && local > sent;
}

// Caller holds the lock. Keys of this account's chats that read as seen here
// without a receipt, newest first.
static NSArray<NSString *> *SPKDirectLocalSeenPendingKeysLocked(NSString *accountPK) {
    if (accountPK.length == 0)
        return @[];
    NSString *prefix = [accountPK stringByAppendingString:@"|"];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    [SPKDirectLocalSeenRecords enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *record, __unused BOOL *stop) {
        if ([key hasPrefix:prefix] && [record[kSPKDirectLocalSeenLocalKey] doubleValue] > [record[kSPKDirectLocalSeenSentKey] doubleValue])
            [keys addObject:key];
    }];
    [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [SPKDirectLocalSeenRecords[b][kSPKDirectLocalSeenUpdatedKey] compare:SPKDirectLocalSeenRecords[a][kSPKDirectLocalSeenUpdatedKey]];
    }];
    return keys;
}

NSUInteger SPKDirectLocalSeenPendingCount(NSString *accountPK) {
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    SPKDirectLocalSeenLoadLocked();
    NSUInteger count = SPKDirectLocalSeenPendingKeysLocked(accountPK).count;
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
    return count;
}

// Thread entries of the chats seen locally, newest first. A chat recorded before
// its name was kept only has its thread id.
static NSArray<NSDictionary *> *SPKDirectLocalSeenPendingChats(NSString *accountPK) {
    NSMutableArray<NSDictionary *> *chats = [NSMutableArray array];
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    SPKDirectLocalSeenLoadLocked();
    for (NSString *key in SPKDirectLocalSeenPendingKeysLocked(accountPK)) {
        NSString *threadId = [key substringFromIndex:accountPK.length + 1];
        NSDictionary *chat = SPKDirectLocalSeenRecords[key][kSPKDirectLocalSeenChatKey];
        [chats addObject:[chat isKindOfClass:NSDictionary.class] ? chat : @{@"threadId" : threadId}];
    }
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
    return chats;
}

// Forgets the local read state of these chats: they show Instagram's own read
// state again. Receipts already sent are not affected.
static void SPKDirectLocalSeenClearThreads(NSString *accountPK, NSArray<NSString *> *_Nullable threadIds) {
    if (accountPK.length == 0)
        return;
    NSString *prefix = [accountPK stringByAppendingString:@"|"];
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    SPKDirectLocalSeenLoadLocked();
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (threadIds) {
        for (NSString *threadId in threadIds)
            [keys addObject:[prefix stringByAppendingString:threadId]];
    } else {
        for (NSString *key in SPKDirectLocalSeenRecords)
            if ([key hasPrefix:prefix])
                [keys addObject:key];
    }
    [SPKDirectLocalSeenRecords removeObjectsForKeys:keys];
    if (keys.count > 0)
        SPKDirectLocalSeenScheduleSaveLocked();
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
    SPKLog(@"Messages", @"[Sparkle LocalSeen] Reset %lu chats account=%@", (unsigned long)keys.count, accountPK);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SPKDirectLocalSeenDidChangeNotification object:nil userInfo:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:SPKSettingAccessoryTextDidChangeNotification object:nil];
    });
}

void SPKDirectLocalSeenSuspend(NSString *threadId) {
    if (threadId.length == 0)
        return;
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    if (!SPKDirectLocalSeenSuspendedUntil)
        SPKDirectLocalSeenSuspendedUntil = [NSMutableDictionary dictionary];
    SPKDirectLocalSeenSuspendedUntil[threadId] = @(CFAbsoluteTimeGetCurrent() + kSPKDirectLocalSeenSuspendDuration);
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
}

BOOL SPKDirectLocalSeenSuspended(NSString *threadId) {
    if (threadId.length == 0)
        return NO;
    os_unfair_lock_lock(&SPKDirectLocalSeenLock);
    NSNumber *until = SPKDirectLocalSeenSuspendedUntil[threadId];
    BOOL suspended = until && until.doubleValue > CFAbsoluteTimeGetCurrent();
    if (until && !suspended)
        [SPKDirectLocalSeenSuspendedUntil removeObjectForKey:threadId];
    os_unfair_lock_unlock(&SPKDirectLocalSeenLock);
    return suspended;
}

#pragma mark - List

@interface SPKDirectLocalSeenThreadsViewController : SPKUserListViewController
@property (nonatomic, strong) UIBarButtonItem *resetAllItem;
@end

@implementation SPKDirectLocalSeenThreadsViewController

- (instancetype)init {
    if ((self = [super init])) {
        self.title = SPKL(@"MESSAGES_MESSAGING_LOCALLY_SEEN_TITLE");
        self.emptyTitle = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_NO_CHATS_YET_TEXT");
        self.emptySubtitle = SPKL(@"MESSAGES_MESSAGING_LOCALLY_SEEN_EMPTY_SUBTITLE");
        self.emptyIconName = @"empty";
    }
    return self;
}

- (NSArray<UIBarButtonItem *> *)additionalTrailingBarItems {
    self.resetAllItem = SPKMediaChromeTopBarButtonItemWithTint(@"trash", self, @selector(spk_resetAllTapped), [SPKUtils SPKColor_InstagramDestructive],
                                                               SPKL(@"MESSAGES_MESSAGING_RESET_LOCAL_SEEN_TITLE"));
    return @[ self.resetAllItem ];
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *chat in SPKDirectLocalSeenPendingChats([SPKUtils currentUserPK]))
        [items addObject:SPKDirectUserListItemForThreadEntry(chat)];
    return items;
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
    self.resetAllItem.enabled = count > 0;
}

- (void)didSelectItem:(SPKUserListItem *)item {
    SPKDirectOpenProfileForThreadEntry(item.representedObject);
}

// Swiping a chat away makes just that chat unread again.
- (void)didDeleteItem:(SPKUserListItem *)item {
    NSString *threadId = [item.representedObject[@"threadId"] isKindOfClass:NSString.class] ? item.representedObject[@"threadId"] : nil;
    if (threadId.length > 0)
        SPKDirectLocalSeenClearThreads([SPKUtils currentUserPK], @[ threadId ]);
    [self reloadItems];
}

- (void)spk_resetAllTapped {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"MESSAGES_MESSAGING_RESET_LOCAL_SEEN_TITLE")
                                                message:SPKL(@"MESSAGES_MESSAGING_RESET_LOCAL_SEEN_CONFIRM")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:SPKIGAlertActionStyleCancel handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_RESET")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  SPKDirectLocalSeenClearThreads([SPKUtils currentUserPK], nil);
                                                                                  [weakSelf reloadItems];
                                                                                  SPKNotify(kSPKNotificationLocalSeenReset, SPKL(@"MESSAGES_MESSAGING_LOCAL_SEEN_RESET_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

@end

UIViewController *SPKDirectLocalSeenListViewController(void) {
    return [[SPKDirectLocalSeenThreadsViewController alloc] init];
}
