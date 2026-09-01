#import "SPKStrings.h"
#import "SPKDirectHiddenChats.h"

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Shared/UI/SPKUserListViewController.h"
#import "../../Utils.h"
#import "SPKDirectAddThreadPrompt.h"
#import "SPKDirectHiddenChatsLockManager.h"
#import "SPKDirectUserResolver.h"

#import "../../Networking/SPKInstagramAPI.h"

#import "../Gallery/SPKGalleryLockViewController.h"

NSNotificationName const SPKDirectHiddenChatsDidChangeNotification = @"SPKDirectHiddenChatsDidChangeNotification";

static NSString *const kSPKHiddenChatsListKey = @"msgs_hidden_chats_list";

// Cached list plus a membership set for the inbox filter, which runs once per
// thread on every list diff. Rebuilt whenever the effective (account-namespaced)
// key changes, so switching accounts cannot leak one account's list into another.
static NSArray<NSDictionary *> *SPKHiddenChatsCache;
static NSSet<NSString *> *SPKHiddenChatIdsCache;
static NSString *SPKHiddenChatsCachedKey;
static BOOL SPKHiddenChatsRevealed = NO;

#pragma mark - Value helpers

static NSString *SPKHiddenChatsString(id value) {
    if ([value isKindOfClass:[NSString class]])
        return (NSString *)value;
    if ([value isKindOfClass:[NSNumber class]])
        return [(NSNumber *)value stringValue];
    return nil;
}

static NSArray<NSString *> *SPKHiddenChatsUserPKs(NSArray *users) {
    if (![users isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<NSString *> *pks = [NSMutableArray array];
    for (id user in users) {
        NSString *pk = [user isKindOfClass:[NSDictionary class]] ? SPKHiddenChatsString(((NSDictionary *)user)[@"pk"]) : nil;
        if (pk.length > 0 && ![pks containsObject:pk])
            [pks addObject:pk];
    }
    return [pks sortedArrayUsingSelector:@selector(compare:)];
}

BOOL SPKDirectHiddenChatsEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_hidden_chats"];
}

#pragma mark - Store

static NSArray<NSDictionary *> *SPKHiddenChatListFromRawValue(id rawStored) {
    NSArray *stored = [rawStored isKindOfClass:[NSArray class]] ? rawStored : nil;
    NSMutableArray<NSDictionary *> *threads = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (id value in stored ?: @[]) {
        NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
        NSString *threadId = SPKHiddenChatsString(dict[@"threadId"]);
        if (threadId.length == 0 || [seen containsObject:threadId])
            continue;
        [seen addObject:threadId];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"threadId"] = threadId;
        entry[@"threadName"] = SPKHiddenChatsString(dict[@"threadName"]) ?: @"";
        entry[@"isGroup"] = @([dict[@"isGroup"] respondsToSelector:@selector(boolValue)] ? [dict[@"isGroup"] boolValue] : NO);
        entry[@"users"] = [dict[@"users"] isKindOfClass:[NSArray class]] ? dict[@"users"] : @[];
        if (dict[@"addedAt"])
            entry[@"addedAt"] = dict[@"addedAt"];
        NSString *groupPhotoUrl = SPKHiddenChatsString(dict[@"groupPhotoUrl"]);
        if (groupPhotoUrl.length)
            entry[@"groupPhotoUrl"] = groupPhotoUrl;
        // Set only when Sparkle is the one that muted the thread, so unhiding never
        // unmutes a chat the user had muted themselves before hiding it. Messages and
        // calls are separate server states and are tracked separately.
        for (NSString *flagKey in @[ @"spk_muted", @"spk_muted_calls" ]) {
            if ([dict[flagKey] respondsToSelector:@selector(boolValue)] && [dict[flagKey] boolValue])
                entry[flagKey] = @(YES);
        }
        [threads addObject:entry.copy];
    }

    return threads.copy;
}

static void SPKHiddenChatsUpdateCaches(NSArray<NSDictionary *> *threads) {
    SPKHiddenChatsCache = [threads copy] ?: @[];
    NSMutableSet<NSString *> *threadIds = [NSMutableSet set];
    for (NSDictionary *entry in SPKHiddenChatsCache) {
        NSString *threadId = SPKHiddenChatsString(entry[@"threadId"]);
        if (threadId.length > 0)
            [threadIds addObject:threadId];
    }
    SPKHiddenChatIdsCache = threadIds.copy;
}

NSArray<NSDictionary *> *SPKDirectHiddenChatList(void) {
    NSString *effectiveKey = SPKEffectivePreferenceKey(kSPKHiddenChatsListKey);
    if (!SPKHiddenChatsCache || ![effectiveKey isEqualToString:SPKHiddenChatsCachedKey]) {
        SPKHiddenChatsCachedKey = effectiveKey;
        SPKHiddenChatsUpdateCaches(SPKHiddenChatListFromRawValue(SPKPreferenceObjectForKey(kSPKHiddenChatsListKey)));
    }
    return SPKHiddenChatsCache;
}

NSUInteger SPKDirectHiddenChatCount(void) {
    return SPKDirectHiddenChatList().count;
}

static void SPKHiddenChatSetList(NSArray<NSDictionary *> *threads) {
    NSArray *normalized = SPKHiddenChatListFromRawValue(threads);
    SPKPreferenceSetObject(normalized, kSPKHiddenChatsListKey);
    SPKHiddenChatsCachedKey = SPKEffectivePreferenceKey(kSPKHiddenChatsListKey);
    SPKHiddenChatsUpdateCaches(normalized);
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKDirectHiddenChatsDidChangeNotification object:nil];
}

BOOL SPKDirectHiddenChatListContainsThreadId(NSString *threadId) {
    NSString *normalized = SPKHiddenChatsString(threadId);
    if (normalized.length == 0)
        return NO;
    // Always go through the list (cheap once cached) so membership matches the
    // current account rather than whichever one was last read.
    (void)SPKDirectHiddenChatList();
    return [SPKHiddenChatIdsCache containsObject:normalized];
}

BOOL SPKDirectHiddenChatListContainsParticipants(NSArray<NSString *> *userPKs, BOOL isGroup) {
    if (userPKs.count == 0)
        return NO;
    NSArray<NSString *> *sorted = [userPKs sortedArrayUsingSelector:@selector(compare:)];
    for (NSDictionary *entry in SPKDirectHiddenChatList()) {
        if ([entry[@"isGroup"] boolValue] != isGroup)
            continue;
        NSArray<NSString *> *storedPKs = SPKHiddenChatsUserPKs(entry[@"users"]);
        if (storedPKs.count > 0 && [storedPKs isEqualToArray:sorted])
            return YES;
    }
    return NO;
}

BOOL SPKDirectHiddenChatListContainsContext(SPKDirectThreadContext *context) {
    if (!context)
        return NO;
    if (SPKDirectHiddenChatListContainsThreadId(context.threadId))
        return YES;
    // Thread ids are not stable for the life of a conversation: accepting a
    // request or re-creating a group hands the same people a new id. Matching the
    // participant set keeps a chat hidden across that, which matters because the
    // user cannot re-hide a chat they never see reappear.
    return SPKDirectHiddenChatListContainsParticipants(SPKHiddenChatsUserPKs(context.users), context.isGroup);
}

#pragma mark - Native mute

// Hiding a chat only takes it out of the inbox. A push for it is handed to iOS by the
// server, and once iOS has an alert nothing in the app can take the banner or the
// vibration back, so silencing a hidden chat has to happen on the account. Instagram's
// own mute sheet writes three independent states; the two that stop a device waking up
// are muted messages and muted calls, and both are set here. The third, "Hide message
// previews", only empties the banner and still delivers the push, so it is no use for
// this and is left alone.

static NSString *const kSPKHiddenChatsMutedFlagKey = @"spk_muted";
static NSString *const kSPKHiddenChatsCallsMutedFlagKey = @"spk_muted_calls";

static BOOL SPKHiddenChatsNativeMuteEnabled(void) {
    return SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_mute_notifications"];
}

// Records which of the two mutes Sparkle is the one holding. Unhiding restores only
// what it muted, so a chat the user had already muted stays muted afterwards.
static void SPKHiddenChatsSetMutedFlag(NSString *threadId, NSString *flagKey, BOOL muted) {
    NSMutableArray<NSDictionary *> *threads = [SPKDirectHiddenChatList() mutableCopy];
    for (NSUInteger index = 0; index < threads.count; index++) {
        if (![threads[index][@"threadId"] isEqualToString:threadId])
            continue;
        if ([threads[index][flagKey] boolValue] == muted)
            return;
        NSMutableDictionary *entry = [threads[index] mutableCopy];
        if (muted)
            entry[flagKey] = @(YES);
        else
            [entry removeObjectForKey:flagKey];
        threads[index] = entry.copy;
        SPKHiddenChatSetList(threads);
        return;
    }
}

static BOOL SPKHiddenChatsRequestSucceeded(NSDictionary *response, NSError *error) {
    if (error)
        return NO;
    id status = response[@"status"];
    return ![status isKindOfClass:[NSString class]] || ![(NSString *)status isEqualToString:@"fail"];
}

static void SPKHiddenChatsUnmuteThreadId(NSString *threadId, BOOL messages, BOOL calls) {
    if (threadId.length == 0)
        return;
    if (messages)
        [SPKInstagramAPI setThreadMuted:NO
                               threadId:threadId
                             completion:^(NSDictionary *response, NSError *error) {
                                 SPKLog(@"Messages", @"[Sparkle HiddenChats] Unmute messages threadId=%@ ok=%d", threadId,
                                        SPKHiddenChatsRequestSucceeded(response, error));
                             }];
    if (calls)
        [SPKInstagramAPI setThreadCallsMuted:NO
                                    threadId:threadId
                                  completion:^(NSDictionary *response, NSError *error) {
                                      SPKLog(@"Messages", @"[Sparkle HiddenChats] Unmute calls threadId=%@ ok=%d", threadId,
                                             SPKHiddenChatsRequestSucceeded(response, error));
                                  }];
}

// Muting calls is not simply the messages call with another action name: the endpoint
// answers OK whether or not anything moved, so the write is read back and the flag only
// recorded once the server agrees. Failing is logged and left alone rather than pilled,
// since messages are the part of a hidden chat that actually goes off.
static void SPKHiddenChatsMuteCallsThreadId(NSString *threadId) {
    [SPKInstagramAPI
        setThreadCallsMuted:YES
                   threadId:threadId
                 completion:^(NSDictionary *response, NSError *callError) {
                     if (!SPKHiddenChatsRequestSucceeded(response, callError)) {
                         SPKLog(@"Messages", @"[Sparkle HiddenChats] Call mute rejected threadId=%@ error=%@",
                                threadId, callError.localizedDescription ?: @"(server)");
                         return;
                     }
                     [SPKInstagramAPI fetchThreadMuteStateForThreadId:threadId
                                                           completion:^(NSNumber *recheckedMessages, NSNumber *recheckedCalls, NSError *recheckError) {
                                                               (void)recheckedMessages;
                                                               (void)recheckError;
                                                               BOOL applied = recheckedCalls != nil && recheckedCalls.boolValue;
                                                               SPKLog(@"Messages", @"[Sparkle HiddenChats] Call mute threadId=%@ calls=%@ applied=%d",
                                                                      threadId, recheckedCalls ?: @"(unknown)", applied);
                                                               if (applied)
                                                                   SPKHiddenChatsSetMutedFlag(threadId, kSPKHiddenChatsCallsMutedFlagKey, YES);
                                                           }];
                 }];
}

static void SPKHiddenChatsMuteThreadId(NSString *threadId) {
    if (threadId.length == 0 || !SPKHiddenChatsNativeMuteEnabled())
        return;
    [SPKInstagramAPI
        fetchThreadMuteStateForThreadId:threadId
                             completion:^(NSNumber *messagesMuted, NSNumber *callsMuted, NSError *error) {
                                 SPKLog(@"Messages", @"[Sparkle HiddenChats] Mute state threadId=%@ messages=%@ calls=%@ error=%@",
                                        threadId, messagesMuted ?: @"(unknown)", callsMuted ?: @"(unknown)",
                                        error.localizedDescription ?: @"(none)");

                                 // Already muted by the user: leave it, and leave the flag
                                 // unset so unhiding does not turn their own mute off.
                                 if (!(messagesMuted != nil && messagesMuted.boolValue)) {
                                     [SPKInstagramAPI
                                         setThreadMuted:YES
                                               threadId:threadId
                                             completion:^(NSDictionary *response, NSError *muteError) {
                                                 if (!SPKHiddenChatsRequestSucceeded(response, muteError)) {
                                                     SPKLog(@"Messages", @"[Sparkle HiddenChats] Mute failed threadId=%@ error=%@",
                                                            threadId, muteError.localizedDescription ?: @"(server)");
                                                     // Worth saying out loud: the chat is out of
                                                     // the inbox but its pushes still arrive,
                                                     // which looks like the hide itself failed.
                                                     SPKNotify(kSPKNotificationDirectHiddenChat,
                                                               SPKL(@"MESSAGES_HIDDEN_CHATS_MUTE_FAILED_TITLE"),
                                                               SPKL(@"MESSAGES_HIDDEN_CHATS_MUTE_FAILED_SUBTITLE"),
                                                               @"error_filled",
                                                               SPKNotificationToneError);
                                                     return;
                                                 }
                                                 SPKHiddenChatsSetMutedFlag(threadId, kSPKHiddenChatsMutedFlagKey, YES);
                                             }];
                                 }

                                 if (callsMuted != nil && callsMuted.boolValue)
                                     return;
                                 // A call rings and vibrates on its own, so muting messages
                                 // alone would leave the loudest way in wide open.
                                 SPKHiddenChatsMuteCallsThreadId(threadId);
                             }];
}

BOOL SPKDirectHiddenChatsSuppressesNotification(NSString *threadId, NSString *userPK) {
    // Same switch as the account mute: hiding a chat is a statement about not hearing
    // from it, and Sparkle announcing that the person is typing would walk straight
    // through a mute the user set for exactly that reason.
    if (!SPKHiddenChatsNativeMuteEnabled() || SPKDirectHiddenChatsRevealed())
        return NO;
    if (SPKDirectHiddenChatListContainsThreadId(threadId))
        return YES;
    NSString *pk = SPKHiddenChatsString(userPK);
    // Matched as a whole participant set, so a member of a hidden group whose own
    // 1:1 is visible keeps their notifications.
    return pk.length > 0 && SPKDirectHiddenChatListContainsParticipants(@[ pk ], NO);
}

void SPKDirectHiddenChatsSyncNativeMute(BOOL mute) {
    for (NSDictionary *entry in SPKDirectHiddenChatList()) {
        NSString *threadId = SPKHiddenChatsString(entry[@"threadId"]);
        if (threadId.length == 0)
            continue;
        if (mute) {
            SPKHiddenChatsMuteThreadId(threadId);
            continue;
        }
        BOOL messages = [entry[kSPKHiddenChatsMutedFlagKey] boolValue];
        BOOL calls = [entry[kSPKHiddenChatsCallsMutedFlagKey] boolValue];
        if (!messages && !calls)
            continue;
        SPKHiddenChatsUnmuteThreadId(threadId, messages, calls);
        SPKHiddenChatsSetMutedFlag(threadId, kSPKHiddenChatsMutedFlagKey, NO);
        SPKHiddenChatsSetMutedFlag(threadId, kSPKHiddenChatsCallsMutedFlagKey, NO);
    }
}

// Entry-shaped hide, shared by the inbox menu and the list's own add button so both
// land in the same store and pick up the same mute.
static void SPKHiddenChatsHideThreadEntry(NSDictionary *entry) {
    NSString *threadId = SPKHiddenChatsString(entry[@"threadId"]);
    if (threadId.length == 0)
        return;

    NSMutableArray<NSDictionary *> *threads = [SPKDirectHiddenChatList() mutableCopy];
    NSMutableDictionary *merged = [entry mutableCopy];
    merged[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);

    NSInteger existingIndex = -1;
    for (NSInteger idx = 0; idx < (NSInteger)threads.count; idx++) {
        if ([threads[idx][@"threadId"] isEqualToString:threadId]) {
            existingIndex = idx;
            break;
        }
    }
    if (existingIndex >= 0) {
        threads[existingIndex] = merged.copy;
    } else {
        [threads addObject:merged.copy];
    }
    SPKHiddenChatSetList(threads);
    SPKHiddenChatsMuteThreadId(threadId);
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Hid thread threadId=%@ name=%@ isGroup=%d count=%lu",
           threadId,
           merged[@"threadName"] ?: @"",
           [merged[@"isGroup"] boolValue],
           (unsigned long)threads.count);
}

void SPKDirectHideThreadWithContext(SPKDirectThreadContext *context) {
    NSDictionary *entry = SPKDirectThreadEntryFromContext(context);
    if (SPKHiddenChatsString(entry[@"threadId"]).length == 0) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Ignored hide: missing threadId context=%@", context);
        return;
    }
    SPKHiddenChatsHideThreadEntry(entry);
}

void SPKDirectUnhideThreadId(NSString *threadId) {
    NSString *normalized = SPKHiddenChatsString(threadId);
    if (normalized.length == 0)
        return;
    NSMutableArray<NSDictionary *> *threads = [SPKDirectHiddenChatList() mutableCopy];
    NSUInteger before = threads.count;
    BOOL restoresMessageMute = NO;
    BOOL restoresCallMute = NO;
    for (NSDictionary *entry in threads) {
        if (![entry[@"threadId"] isEqualToString:normalized])
            continue;
        restoresMessageMute = [entry[kSPKHiddenChatsMutedFlagKey] boolValue];
        restoresCallMute = [entry[kSPKHiddenChatsCallsMutedFlagKey] boolValue];
    }
    [threads filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
                 (void)bindings;
                 return ![entry[@"threadId"] isEqualToString:normalized];
             }]];
    SPKHiddenChatSetList(threads);
    if (restoresMessageMute || restoresCallMute)
        SPKHiddenChatsUnmuteThreadId(normalized, restoresMessageMute, restoresCallMute);
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Unhid thread threadId=%@ before=%lu after=%lu",
           normalized,
           (unsigned long)before,
           (unsigned long)threads.count);
}

#pragma mark - Reveal state

SPKDirectHiddenChatsRevealReset SPKDirectHiddenChatsRevealResetMode(void) {
    NSString *mode = [SPKUtils getStringPref:@"msgs_hidden_chats_reveal_reset"];
    if ([mode isEqualToString:@"background"])
        return SPKDirectHiddenChatsRevealResetBackgrounded;
    if ([mode isEqualToString:@"never"])
        return SPKDirectHiddenChatsRevealResetNever;
    return SPKDirectHiddenChatsRevealResetLeavingInbox;
}

BOOL SPKDirectHiddenChatsRevealed(void) {
    return SPKHiddenChatsRevealed;
}

void SPKDirectSetHiddenChatsRevealed(BOOL revealed) {
    if (SPKHiddenChatsRevealed == revealed)
        return;
    SPKHiddenChatsRevealed = revealed;
    if (!revealed) {
        // Every way a reveal ends comes through here, so this is the one place that
        // has to re-arm the lock; leaving it unlocked would make the next reveal
        // free for as long as the app stayed alive.
        [[SPKDirectHiddenChatsLockManager sharedManager] lockContent];
    }
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Reveal state changed revealed=%d count=%lu",
           revealed,
           (unsigned long)SPKDirectHiddenChatCount());
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKDirectHiddenChatsDidChangeNotification object:nil];
}

void SPKDirectToggleHiddenChatsRevealed(void) {
    SPKDirectSetHiddenChatsRevealed(!SPKHiddenChatsRevealed);
}

void SPKDirectHiddenChatsNoteLeftInbox(void) {
    if (SPKDirectHiddenChatsRevealResetMode() == SPKDirectHiddenChatsRevealResetLeavingInbox)
        SPKDirectSetHiddenChatsRevealed(NO);
}

void SPKDirectHiddenChatsNoteBackgrounded(void) {
    // Backgrounding ends a reveal in both timed modes; only "never" survives it.
    if (SPKDirectHiddenChatsRevealResetMode() != SPKDirectHiddenChatsRevealResetNever)
        SPKDirectSetHiddenChatsRevealed(NO);
}

BOOL SPKDirectHiddenChatsShouldFilterInbox(void) {
    if (!SPKDirectHiddenChatsEnabled() || SPKHiddenChatsRevealed)
        return NO;
    return SPKDirectHiddenChatCount() > 0;
}

#pragma mark - Menu action

NSString *SPKDirectHiddenChatsMenuActionTitle(SPKDirectThreadContext *context) {
    if (context.threadId.length == 0)
        return nil;
    return SPKDirectHiddenChatListContainsContext(context)
               ? SPKL(@"MESSAGES_HIDDEN_CHATS_MENU_UNHIDE_ACTION")
               : SPKL(@"MESSAGES_HIDDEN_CHATS_MENU_HIDE_ACTION");
}

static void SPKHiddenChatsNotifyToggle(SPKDirectThreadContext *context, BOOL hidden) {
    NSString *name = SPKDirectHandleNameForThreadContext(context) ?: SPKL(@"MESSAGES_HIDDEN_CHATS_UNKNOWN_CHAT_TEXT");
    SPKNotify(kSPKNotificationDirectHiddenChat,
              hidden ? [NSString stringWithFormat:SPKL(@"MESSAGES_HIDDEN_CHATS_HIDDEN_FORMAT"), name]
                     : [NSString stringWithFormat:SPKL(@"MESSAGES_HIDDEN_CHATS_UNHIDDEN_FORMAT"), name],
              hidden ? SPKL(@"MESSAGES_HIDDEN_CHATS_HIDDEN_SUBTITLE") : nil,
              hidden ? @"messages_off" : @"messages",
              SPKNotificationToneInfo);
}

void SPKDirectHiddenChatsToggleThread(SPKDirectThreadContext *context, UIViewController *presenter) {
    (void)presenter;
    if (context.threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Toggle skipped: no thread context");
        return;
    }

    // Both directions confirm. Either one silently rearranges the inbox from a
    // context menu the user may have opened by accident, and unhiding puts a chat
    // back in a list other people can see over the user's shoulder.
    BOOL hidden = SPKDirectHiddenChatListContainsContext(context);
    NSString *name = SPKDirectHandleNameForThreadContext(context) ?: SPKL(@"MESSAGES_HIDDEN_CHATS_UNKNOWN_CHAT_TEXT");
    NSString *threadId = context.threadId;

    void (^toggle)(void) = ^{
        if (hidden)
            SPKDirectUnhideThreadId(threadId);
        else
            SPKDirectHideThreadWithContext(context);
        SPKHiddenChatsNotifyToggle(context, !hidden);
    };

    NSString *title = hidden ? SPKL(@"MESSAGES_HIDDEN_CHATS_CONFIRM_UNHIDE_TITLE")
                             : SPKL(@"MESSAGES_HIDDEN_CHATS_CONFIRM_HIDE_TITLE");
    NSString *format = hidden ? SPKL(@"MESSAGES_HIDDEN_CHATS_CONFIRM_UNHIDE_MESSAGE_FORMAT")
                              : SPKL(@"MESSAGES_HIDDEN_CHATS_CONFIRM_HIDE_MESSAGE_FORMAT");
    [SPKUtils showConfirmation:toggle title:title message:[NSString stringWithFormat:format, name]];
}

#pragma mark - Hidden chats list

@interface SPKDirectHiddenChatsViewController : SPKUserListViewController
@property (nonatomic, assign) BOOL spk_locked;
@property (nonatomic, assign) BOOL spk_promptShown;
@end

@implementation SPKDirectHiddenChatsViewController

- (instancetype)init {
    if ((self = [super init])) {
        self.title = SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_TITLE");
        self.infoText = SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_INFO");
        self.showsAddButton = YES;
        // The list is the other way into the hidden chats, so it answers to the same
        // lock the reveal does. Locked state is decided at init and the rows are
        // withheld until it clears, rather than drawn and then covered.
        _spk_locked = [[SPKDirectHiddenChatsLockManager sharedManager] requiresAuthentication];
        [self spk_applyEmptyState];
    }
    return self;
}

/// Leaving the list re-arms the lock, for the same reason a reveal ending does: the
/// unlock it was granted would otherwise make the next reveal free. Only when the list
/// is actually going away, so pushing a profile from a row and coming back does not
/// leave the user looking at rows the lock now considers hidden.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.isMovingFromParentViewController && !self.isBeingDismissed)
        return;
    if (SPKDirectHiddenChatsRevealed())
        return;
    [[SPKDirectHiddenChatsLockManager sharedManager] lockContent];
}

- (void)spk_applyEmptyState {
    self.emptyTitle = self.spk_locked ? SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_LOCKED_TITLE")
                                      : SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_EMPTY_TITLE");
    self.emptySubtitle = self.spk_locked ? SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_LOCKED_SUBTITLE")
                                         : SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_EMPTY_SUBTITLE");
}

/// The locked state is decided at init, which can be well before the screen is shown.
/// An unlock granted in between (the settings row authenticates before pushing) has to
/// be picked up here, or the list would sit on its locked empty state.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.spk_locked || [[SPKDirectHiddenChatsLockManager sharedManager] requiresAuthentication])
        return;
    self.spk_locked = NO;
    [self spk_applyEmptyState];
    [self reloadItems];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.spk_locked || self.spk_promptShown)
        return;
    self.spk_promptShown = YES;
    __weak __typeof(self) weakSelf = self;
    SPKDirectHiddenChatsAuthenticate(self, ^(BOOL granted) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        if (!granted) {
            // Cancelled or failed: leave rather than sit on an empty page that looks
            // like the list itself is empty.
            if (strongSelf.navigationController.viewControllers.firstObject != strongSelf)
                [strongSelf.navigationController popViewControllerAnimated:YES];
            else
                [strongSelf dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        strongSelf.spk_locked = NO;
        [strongSelf spk_applyEmptyState];
        [strongSelf reloadItems];
    });
}

- (NSString *)displayNameForEntry:(NSDictionary *)entry {
    return SPKDirectDisplayNameForThreadEntry(entry) ?: SPKL(@"MESSAGES_HIDDEN_CHATS_UNKNOWN_CHAT_TEXT");
}

- (NSString *)handleNameForEntry:(NSDictionary *)entry {
    return SPKDirectHandleNameForThreadEntry(entry) ?: [self displayNameForEntry:entry];
}

- (NSArray<SPKUserListItem *> *)buildItems {
    if (self.spk_locked)
        return @[];
    NSArray<NSDictionary *> *threads = [SPKDirectHiddenChatList() sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSNumber *aAdded = [a[@"addedAt"] respondsToSelector:@selector(compare:)] ? a[@"addedAt"] : @0;
        NSNumber *bAdded = [b[@"addedAt"] respondsToSelector:@selector(compare:)] ? b[@"addedAt"] : @0;
        return [bAdded compare:aAdded];
    }];

    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in threads) {
        SPKUserListItem *item = [SPKUserListItem new];
        item.representedObject = entry;

        if ([entry[@"isGroup"] boolValue]) {
            item.isGroup = YES;
            item.title = [self displayNameForEntry:entry];
            item.subtitle = SPKDirectParticipantSubtitleForThreadEntry(entry);
            NSString *threadId = [entry[@"threadId"] isKindOfClass:[NSString class]] ? entry[@"threadId"] : nil;
            NSString *groupPhotoUrl = [entry[@"groupPhotoUrl"] isKindOfClass:[NSString class]] ? entry[@"groupPhotoUrl"] : nil;
            // Same synthetic key the other DM thread lists use, so a group photo
            // fetched by one of them is reused here.
            if (threadId.length)
                item.pk = [@"grp_" stringByAppendingString:threadId];
            item.avatarURLString = groupPhotoUrl;
        } else {
            NSArray *users = [entry[@"users"] isKindOfClass:[NSArray class]] ? entry[@"users"] : @[];
            NSString *pk = nil, *username = nil, *fullName = nil, *profilePicUrl = nil;
            for (NSDictionary *user in users) {
                if (!pk.length && [user[@"pk"] isKindOfClass:[NSString class]])
                    pk = user[@"pk"];
                if (!username.length && [user[@"username"] isKindOfClass:[NSString class]])
                    username = user[@"username"];
                if (!fullName.length && [user[@"fullName"] isKindOfClass:[NSString class]])
                    fullName = user[@"fullName"];
                if (!profilePicUrl.length && [user[@"profilePicUrl"] isKindOfClass:[NSString class]])
                    profilePicUrl = user[@"profilePicUrl"];
                if (pk.length && username.length && fullName.length && profilePicUrl.length)
                    break;
            }
            if (!profilePicUrl.length && pk.length)
                profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);
            item.title = username.length ? [@"@" stringByAppendingString:username] : [self displayNameForEntry:entry];
            item.subtitle = username.length ? (fullName.length ? fullName : nil) : nil;
            item.pk = pk;
            item.avatarURLString = profilePicUrl;
        }
        [items addObject:item];
    }
    return items;
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
    if (self.spk_locked) {
        self.title = SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_TITLE");
        return;
    }
    self.title = count > 0
                     ? [NSString stringWithFormat:@"%lu %@", (unsigned long)count, SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_TITLE")]
                     : SPKL(@"MESSAGES_HIDDEN_CHATS_LIST_TITLE");
}

- (void)didSelectItem:(SPKUserListItem *)item {
    SPKDirectOpenProfileForThreadEntry(item.representedObject);
}

- (void)didTapAdd {
    SPKDirectAddThreadPromptCopy *copy = [SPKDirectAddThreadPromptCopy new];
    copy.promptTitle = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_TITLE");
    copy.promptMessage = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_MESSAGE");
    copy.confirmTitle = SPKL(@"MESSAGES_HIDDEN_CHATS_CONFIRM_HIDE_TITLE");
    copy.errorTitle = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_ERROR_TITLE");
    copy.userNotFoundFormat = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_USER_NOT_FOUND_FORMAT");
    copy.noThreadFormat = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_NO_THREAD_FORMAT");
    copy.unresolvedUserText = SPKL(@"MESSAGES_HIDDEN_CHATS_ADD_CHAT_NO_USER_ID_TEXT");

    __weak __typeof(self) weakSelf = self;
    SPKDirectPresentAddThreadPrompt(self, copy, ^(NSDictionary *entry, NSString *username) {
        NSString *threadId = SPKHiddenChatsString(entry[@"threadId"]);
        if (SPKDirectHiddenChatListContainsThreadId(threadId)) {
            SPKNotify(kSPKNotificationDirectHiddenChat,
                      [NSString stringWithFormat:SPKL(@"MESSAGES_HIDDEN_CHATS_ALREADY_HIDDEN_FORMAT"),
                                                 [@"@" stringByAppendingString:username]],
                      nil,
                      @"messages_off",
                      SPKNotificationToneInfo);
            return;
        }
        SPKHiddenChatsHideThreadEntry(entry);
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  [NSString stringWithFormat:SPKL(@"MESSAGES_HIDDEN_CHATS_HIDDEN_FORMAT"), [@"@" stringByAppendingString:username]],
                  SPKL(@"MESSAGES_HIDDEN_CHATS_HIDDEN_SUBTITLE"),
                  @"messages_off",
                  SPKNotificationToneInfo);
        [weakSelf reloadItems];
    });
}

- (void)didDeleteItem:(SPKUserListItem *)item {
    NSDictionary *entry = item.representedObject;
    NSString *threadId = [entry[@"threadId"] isKindOfClass:[NSString class]] ? entry[@"threadId"] : nil;
    if (threadId.length == 0)
        return;
    NSString *name = [self handleNameForEntry:entry];
    SPKDirectUnhideThreadId(threadId);
    SPKNotify(kSPKNotificationDirectHiddenChat,
              [NSString stringWithFormat:SPKL(@"MESSAGES_HIDDEN_CHATS_UNHIDDEN_FORMAT"), name],
              nil,
              @"messages",
              SPKNotificationToneInfo);
    [self reloadItems];
}

@end

void SPKDirectHiddenChatsAuthenticate(UIViewController *presenter, void (^completion)(BOOL granted)) {
    if (!completion)
        return;
    SPKDirectHiddenChatsLockManager *manager = [SPKDirectHiddenChatsLockManager sharedManager];
    if (![manager requiresAuthentication]) {
        completion(YES);
        return;
    }
    UIViewController *host = presenter ?: topMostController();
    if (!host) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Unlock skipped: no view controller to present from");
        completion(NO);
        return;
    }
    // Biometrics first, keypad only on a real failure. Cancelling leaves the list
    // hidden rather than falling through.
    [SPKGalleryLockViewController presentUnlockForManager:manager
                                       fromViewController:host
                                               completion:^(BOOL success) {
                                                   completion(success);
                                               }];
}

UIViewController *SPKDirectHiddenChatsListViewController(void) {
    return [SPKDirectHiddenChatsViewController new];
}
