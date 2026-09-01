#import "SPKPresenceTracking.h"
#import "SPKStrings.h"

#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../AutoSave/SPKAutoSaveFilter.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKUserListViewController.h"
#import "SPKDirectHiddenChats.h"
#import "SPKDirectSeenContext.h"
#import "../../Features/Messages/AccurateActiveStatus.h"
#import "SPKDirectUserResolver.h"

#import "../../InstagramHeaders.h"
#import "../Account/SPKAccountManager.h"

#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kSPKPresenceEnabledKey = @"msgs_presence_notifications";
static NSString *const kSPKPresenceNotifyOnlineKey = @"msgs_presence_notify_online";
static NSString *const kSPKPresenceNotifyOfflineKey = @"msgs_presence_notify_offline";
static NSString *const kSPKPresenceNotifyTypingKey = @"msgs_presence_notify_typing";
static NSString *const kSPKPresenceNotifyReadKey = @"msgs_presence_notify_read";
static NSString *const kSPKPresenceMirrorKey = @"msgs_presence_mirror_notification_center";

// Marks a notification as ours so the foreground presentation hook can let it
// through without having to match on title text.
NSString *const kSPKPresenceNotificationMarker = @"SPKPresenceActivityNotification";
static NSString *const kSPKPresenceCooldownKey = @"msgs_presence_cooldown";
static NSString *const kSPKPresenceListMigrationOwnerKey = @"msgs_presence_account_list_migration_owner_v1";

// A user going online then straight back offline is normal on a weak connection, so
// every transition is rate-limited per user. Deliberately generous: the point of the
// feature is "they came online", not a second-accurate activity log.
static const NSTimeInterval kSPKPresenceDefaultCooldown = 60.0;

// IG replays the presence it already knows shortly after launch and after a realtime
// reconnect. Inside this window a first sighting is treated as catching up on existing
// state and only seeds; outside it, a first sighting is a real event and notifies.
//
// This is the difference between the feature working and staying silent: IG pushes
// presence rarely, so a blanket "first sighting never notifies" rule swallows the only
// update most sessions ever deliver, rather than suppressing a burst.
static const NSTimeInterval kSPKPresenceSnapshotGrace = 15.0;

// A typing status carries its own timestamp. Anything older than this is state IG is
// re-applying rather than something happening right now, which matters because the
// dictionary is rewritten wholesale on every change, including changes to other
// threads.
static const NSTimeInterval kSPKPresenceTypingMaxAge = 15.0;
static const NSTimeInterval kSPKPresenceReadEventMaxAge = 20.0;
static const NSTimeInterval kSPKPresenceReadCooldown = 5.0;

// Set when the hook installs and refreshed on foreground, since both are followed by
// a replay of already-known state.
static NSTimeInterval SPKPresenceStreamStartedAt = 0;
static __weak id sSPKPresenceDirectApplicator = nil;
static NSString *sSPKPresenceDirectApplicatorOwnerPK = nil;

void SPKPresenceNoteStreamStarted(void) {
    SPKPresenceStreamStartedAt = [NSDate date].timeIntervalSince1970;
}

static BOOL SPKPresenceWithinSnapshotGrace(void) {
    if (SPKPresenceStreamStartedAt <= 0)
        return NO;
    return ([NSDate date].timeIntervalSince1970 - SPKPresenceStreamStartedAt) < kSPKPresenceSnapshotGrace;
}

#pragma mark - Filter

static void SPKPresenceMigrateLegacySharedListIfNeeded(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kSPKPresenceListMigrationOwnerKey] != nil)
        return;
    NSString *pk = [SPKAccountManager preferenceNamespacePK];
    if (pk.length == 0)
        return;
    for (NSString *baseKey in @[ @"msgs_presence_included", @"msgs_presence_excluded" ]) {
        NSString *accountKey = [NSString stringWithFormat:@"u_%@_%@", pk, baseKey];
        id legacy = [defaults objectForKey:baseKey];
        if ([defaults objectForKey:accountKey] == nil && [legacy isKindOfClass:NSArray.class])
            [defaults setObject:legacy forKey:accountKey];
    }
    [defaults setObject:pk forKey:kSPKPresenceListMigrationOwnerKey];
}

SPKAutoSaveFilterConfig *SPKPresenceFilterConfig(void) {
    static SPKAutoSaveFilterConfig *config = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [SPKAutoSaveFilterConfig new];
        config.enabledKey = kSPKPresenceEnabledKey;
        config.filterModeKey = @"msgs_presence_filter_mode";
        config.excludedKey = @"msgs_presence_excluded";
        config.includedKey = @"msgs_presence_included";
        config.identityField = @"pk";
        config.sortField = @"username";
        config.subjectPlural = SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_USERS_TEXT");
        config.ruleNotificationIdentifier = kSPKNotificationPresenceUserRule;
        config.alwaysAccountScopedLists = YES;
    });
    SPKPresenceMigrateLegacySharedListIfNeeded();
    return config;
}

BOOL SPKPresenceNotificationsEnabled(void) {
    return [SPKUtils getBoolPref:kSPKPresenceEnabledKey];
}

BOOL SPKPresenceAllUsersMode(void) {
    return SPKAutoSaveFilterAllMode(SPKPresenceFilterConfig());
}

NSString *SPKPresenceListTitle(void) {
    return SPKL(@"MESSAGES_ACTIVITY_TRACKED_USERS_TITLE");
}

NSArray<NSDictionary *> *SPKPresenceUserList(void) {
    return SPKAutoSaveFilterList(SPKPresenceFilterConfig());
}

BOOL SPKPresenceListContainsUser(NSString *pk) {
    return SPKAutoSaveFilterListContains(SPKPresenceFilterConfig(), pk);
}

BOOL SPKPresenceAppliesToUser(NSString *pk) {
    return SPKAutoSaveFilterApplies(SPKPresenceFilterConfig(), pk);
}

NSString *SPKPresenceSettingsSummary(void) {
    if (!SPKPresenceNotificationsEnabled())
        return SPKL(@"MENU_OFF");
    NSUInteger count = SPKPresenceUserList().count;
    return [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_SUMMARY_TRACKED_COUNT"), (unsigned long)count];
}

void SPKPresenceToggleForPK(NSString *pk, NSString *username, NSString *fullName, NSString *profilePicUrl) {
    if (pk.length == 0)
        return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"pk"] = pk;
    entry[@"username"] = SPKAutoSaveFilterNormalizedUsername(username) ?: @"";
    entry[@"fullName"] = fullName ?: @"";
    if (profilePicUrl.length > 0)
        entry[@"profilePicUrl"] = profilePicUrl;
    entry[@"addedAt"] = @([NSDate date].timeIntervalSince1970);
    SPKAutoSaveFilterToggleEntry(SPKPresenceFilterConfig(), entry);
    SPKPresenceResetState();
}

#pragma mark - Display names

// The tracked entry already carries the name captured when the user was added, so a
// notification never needs to hit IG's user store on the realtime path. The resolver
// is only a fallback for entries added before a name resolved.
static NSString *SPKPresenceDisplayNameForPK(NSString *pk) {
    for (NSDictionary *entry in SPKPresenceUserList()) {
        if (![entry isKindOfClass:NSDictionary.class])
            continue;
        if (![SPKStringFromValue(entry[@"pk"]) isEqualToString:pk])
            continue;
        NSString *username = SPKStringFromValue(entry[@"username"]);
        if (username.length > 0)
            return [@"@" stringByAppendingString:username];
        NSString *fullName = SPKStringFromValue(entry[@"fullName"]);
        if (fullName.length > 0)
            return fullName;
        break;
    }
    NSString *resolved = spkDirectUserResolverUsernameForPK(pk);
    return resolved.length > 0 ? [@"@" stringByAppendingString:resolved] : SPKL(@"MESSAGES_ACTIVITY_FALLBACK_NAME");
}

// The pill says "@user is online" as one short line, but a system notification is
// laid out as a name on top and the event underneath, the way Instagram's own are.
// That top line is a person, so the real name wins here and the handle is the
// fallback, which is the opposite of the pill's preference.
static NSString *SPKPresenceNotificationNameForPK(NSString *pk) {
    for (NSDictionary *entry in SPKPresenceUserList()) {
        if (![entry isKindOfClass:NSDictionary.class])
            continue;
        if (![SPKStringFromValue(entry[@"pk"]) isEqualToString:pk])
            continue;
        NSString *fullName = SPKStringFromValue(entry[@"fullName"]);
        if (fullName.length > 0)
            return fullName;
        NSString *username = SPKStringFromValue(entry[@"username"]);
        if (username.length > 0)
            return [@"@" stringByAppendingString:username];
        break;
    }
    NSString *resolved = spkDirectUserResolverUsernameForPK(pk);
    return resolved.length > 0 ? [@"@" stringByAppendingString:resolved] : SPKL(@"MESSAGES_ACTIVITY_FALLBACK_NAME");
}

#pragma mark - Notification delivery

static void SPKPresenceResolveThreadContext(NSString *threadID,
                                            id applicator,
                                            void (^completion)(SPKDirectThreadContext *context));

void SPKPresenceRequestNotificationAuthorization(void) {
    UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:options
                      completionHandler:^(BOOL granted, NSError *error) {
                          if (!granted) {
                              SPKLog(@"Messages", @"[Sparkle Presence] Local notification authorization denied error=%@", error);
                          }
                      }];
}

// The pill covers the case where Instagram is in front, so a system notification is
// only posted when it is not: filing a second copy of something the user just watched
// slide across the screen only clutters Notification Center. There is no background
// keepalive, so this covers the window before iOS suspends IG rather than indefinitely.
static void SPKPresencePostLocalNotification(NSString *title,
                                             NSString *subtitle,
                                             NSString *body,
                                             NSString *threadID) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    if (subtitle.length > 0)
        content.subtitle = subtitle;
    content.body = body ?: @"";
    content.userInfo = @{kSPKPresenceNotificationMarker : @YES};
    content.sound = UNNotificationSound.defaultSound;
    if (threadID.length > 0)
        content.threadIdentifier = threadID;

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString
                                                                         content:content
                                                                         trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
                                                        withCompletionHandler:^(NSError *error) {
                                                            if (error) {
                                                                SPKLog(@"Messages", @"[Sparkle Presence] Local notification failed error=%@", error);
                                                            }
                                                        }];
}

static NSString *SPKPresenceGroupName(SPKDirectThreadContext *context) {
    if (!context.isGroup)
        return nil;
    NSString *name = SPKDirectDisplayNameForThreadContext(context);
    return name.length > 0 ? name : SPKL(@"MESSAGES_ACTIVITY_GROUP_CHAT_FALLBACK_NAME");
}

static void SPKPresenceNotifyTyping(NSString *pk, NSString *threadID) {
    NSString *pillTitle = [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_TYPING_PILL_TITLE"), SPKPresenceDisplayNameForPK(pk)];
    NSString *name = SPKPresenceNotificationNameForPK(pk);
    NSString *body = SPKL(@"MESSAGES_ACTIVITY_TYPING_NOTIFICATION_BODY");

    dispatch_async(dispatch_get_main_queue(), ^{
        SPKPresenceResolveThreadContext(threadID, nil, ^(SPKDirectThreadContext *context) {
            NSString *groupName = SPKPresenceGroupName(context);
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                SPKNotify(kSPKNotificationPresenceTyping, pillTitle, groupName, @"keyboard", SPKNotificationToneInfo);
                return;
            }
            if ([SPKUtils getBoolPref:kSPKPresenceMirrorKey])
                SPKPresencePostLocalNotification(name, groupName, body, context.isGroup ? threadID : nil);
        });
    });
}

static void SPKPresenceNotifyRead(NSString *pk, NSString *threadID, id applicator) {
    NSString *pillTitle = [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_READ_PILL_TITLE"), SPKPresenceDisplayNameForPK(pk)];
    NSString *name = SPKPresenceNotificationNameForPK(pk);

    dispatch_async(dispatch_get_main_queue(), ^{
        SPKPresenceResolveThreadContext(threadID, applicator, ^(SPKDirectThreadContext *context) {
            NSString *groupName = SPKPresenceGroupName(context);
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                SPKNotify(kSPKNotificationPresenceRead, pillTitle, groupName, @"eye", SPKNotificationToneInfo);
                return;
            }
            if ([SPKUtils getBoolPref:kSPKPresenceMirrorKey])
                SPKPresencePostLocalNotification(name, groupName, SPKL(@"MESSAGES_ACTIVITY_READ_NOTIFICATION_BODY"), context.isGroup ? threadID : nil);
        });
    });
}

static void SPKPresenceNotify(NSString *pk, BOOL isActive) {
    NSString *displayName = SPKPresenceDisplayNameForPK(pk);
    NSString *pillTitle = isActive ? [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_ONLINE_PILL_TITLE"), displayName]
                                   : [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_OFFLINE_PILL_TITLE"), displayName];
    NSString *name = SPKPresenceNotificationNameForPK(pk);
    NSString *body = isActive ? SPKL(@"MESSAGES_ACTIVITY_ONLINE_NOTIFICATION_BODY") : SPKL(@"MESSAGES_ACTIVITY_OFFLINE_NOTIFICATION_BODY");
    NSString *identifier = isActive ? kSPKNotificationPresenceOnline : kSPKNotificationPresenceOffline;
    NSString *icon = isActive ? @"circle_check_filled" : @"circle_xmark_filled";

    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            SPKNotify(identifier, pillTitle, nil, icon, SPKNotificationToneInfo);
            return;
        }
        if ([SPKUtils getBoolPref:kSPKPresenceMirrorKey])
            SPKPresencePostLocalNotification(name, nil, body, nil);
    });
}

#pragma mark - Instagram's own view of presence

// The green dot is not drawn from the realtime callback, it is drawn from the store,
// and the store has more writers than the one callback we hook. Reading it back is
// what keeps a notification from claiming something the rest of the UI disagrees with.
static NSDictionary *SPKPresenceIGStates(void) {
    id session = [SPKUtils activeUserSession];
    if (![session respondsToSelector:@selector(presenceManager)])
        return nil;
    id manager = [session presenceManager];
    if (![manager respondsToSelector:@selector(presenceStatesByUserPk)])
        return nil;
    id states = [manager presenceStatesByUserPk];
    return [states isKindOfClass:NSDictionary.class] ? states : nil;
}

// IGPresenceState is a value object whose accessors are synthesized at runtime, so it
// has no ivars to read and no header to trust. KVC does reach the generated getters,
// but the property name is not contractual, hence the candidate list and the one-shot
// dump of an actual instance to the log when none of them match.
static id SPKPresenceValueForCandidateKeys(id state, NSArray<NSString *> *keys) {
    if (!state)
        return nil;
    for (NSString *key in keys) {
        @try {
            id value = [state valueForKey:key];
            if (value && value != NSNull.null)
                return value;
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

static NSNumber *SPKPresenceActiveFlagFromState(id state) {
    static NSArray<NSString *> *candidates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = @[ @"isActive", @"active", @"isActiveNow", @"isUserActive" ];
    });
    id value = SPKPresenceValueForCandidateKeys(state, candidates);
    if ([value isKindOfClass:NSNumber.class])
        return @([value boolValue]);
    static dispatch_once_t dumpToken;
    dispatch_once(&dumpToken, ^{
        SPKLog(@"Presence", @"[Sparkle Presence] unreadable presence state, shape=%@", [state description]);
    });
    return nil;
}

NSNumber *SPKPresenceIGActiveStateForPK(NSString *pk) {
    if (pk.length == 0)
        return nil;
    NSDictionary *states = SPKPresenceIGStates();
    if (!states)
        return nil;
    // The store has been keyed by both the string and the boxed number form.
    id state = states[pk] ?: states[@(pk.longLongValue)];
    return SPKPresenceActiveFlagFromState(state);
}

#pragma mark - Update funnel

// Two maps, deliberately. `actual` tracks what IG last told us, so a repeat of the
// same state is discarded without ever consulting the notify side. `notified` tracks
// what the user last saw, so a state that was suppressed (by cooldown, or by the
// per-direction toggles) doesn't leave us believing they were told about it.
static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceActualStates(void) {
    static NSMutableDictionary *states = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = [NSMutableDictionary dictionary];
    });
    return states;
}

static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceNotifiedStates(void) {
    static NSMutableDictionary *states = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = [NSMutableDictionary dictionary];
    });
    return states;
}

static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceLastNotifyTimes(void) {
    static NSMutableDictionary *times = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        times = [NSMutableDictionary dictionary];
    });
    return times;
}

static NSString *SPKPresenceNotifyCooldownKey(NSString *pk, BOOL isActive) {
    return [NSString stringWithFormat:@"%@:%@", pk, isActive ? @"online" : @"offline"];
}

// Typing keeps its own pair of maps rather than sharing the online/offline ones. A
// user can start typing while already known to be online, and each event has to be
// rate limited on its own clock or one kind would keep swallowing the other.
static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceTypingStates(void) {
    static NSMutableDictionary *states = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = [NSMutableDictionary dictionary];
    });
    return states;
}

static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceTypingNotifyTimes(void) {
    static NSMutableDictionary *times = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        times = [NSMutableDictionary dictionary];
    });
    return times;
}

static NSMutableDictionary<NSString *, NSString *> *SPKPresenceReadCursors(void) {
    static NSMutableDictionary *cursors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cursors = [NSMutableDictionary dictionary];
    });
    return cursors;
}

static NSMutableDictionary<NSString *, NSNumber *> *SPKPresenceReadNotifyTimes(void) {
    static NSMutableDictionary *times = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        times = [NSMutableDictionary dictionary];
    });
    return times;
}

// The Direct client-state cache is not guaranteed to retain the message object a
// seen watermark points at. Keep a small session ledger of server ids for messages
// we observed Instagram insert/replace with the owning account as sender.
static NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *SPKPresenceOwnerMessageIDs(void) {
    static NSMutableDictionary *messageIDs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        messageIDs = [NSMutableDictionary dictionary];
    });
    return messageIDs;
}

static dispatch_queue_t SPKPresenceQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.sparkle.presence", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void SPKPresenceResetState(void) {
    dispatch_async(SPKPresenceQueue(), ^{
        [SPKPresenceActualStates() removeAllObjects];
        [SPKPresenceNotifiedStates() removeAllObjects];
        [SPKPresenceLastNotifyTimes() removeAllObjects];
        [SPKPresenceTypingStates() removeAllObjects];
        [SPKPresenceTypingNotifyTimes() removeAllObjects];
        [SPKPresenceReadCursors() removeAllObjects];
        [SPKPresenceReadNotifyTimes() removeAllObjects];
        [SPKPresenceOwnerMessageIDs() removeAllObjects];
    });
}

static NSTimeInterval SPKPresenceCooldown(void) {
    double configured = [SPKUtils getDoublePref:kSPKPresenceCooldownKey];
    return configured > 0 ? configured : kSPKPresenceDefaultCooldown;
}

void SPKPresenceHandleUpdate(NSString *pk, BOOL isActive, __unused double lastActivityAtMs, NSNumber *igPriorActive) {
    if (pk.length == 0)
        return;
    // Checked before hopping queues: this fires for every user IG streams presence
    // for, most of whom are untracked.
    if (!SPKPresenceNotificationsEnabled()) {
        SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=feature-disabled", pk);
        return;
    }
    // Your own presence is streamed alongside everyone else's; notifying yourself that
    // you came online is never useful, and All Users mode would do exactly that.
    NSString *currentPK = [SPKUtils currentUserPK];
    if (currentPK.length > 0 && [pk isEqualToString:currentPK]) {
        SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=self", pk);
        return;
    }
    if (!SPKPresenceAppliesToUser(pk)) {
        SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=not-tracked allMode=%d listCount=%lu",
               pk, SPKPresenceAllUsersMode(), (unsigned long)SPKPresenceUserList().count);
        return;
    }

    dispatch_async(SPKPresenceQueue(), ^{
        NSMutableDictionary *actual = SPKPresenceActualStates();
        NSNumber *previous = actual[pk];
        actual[pk] = @(isActive);

        // A first sighting is only news if it actually changes something. Instagram's
        // own store answers that directly: it was sampled before the update was
        // applied, so if it already said the same thing, this update changed nothing
        // the user could see and must not produce a notification. Presence is written
        // by more paths than the one callback that got us here, so this is also what
        // stops a notification from contradicting the green dot.
        if (previous == nil && igPriorActive != nil) {
            if (igPriorActive.boolValue == isActive) {
                SPKLog(@"Presence", @"[Sparkle Presence] seed pk=%@ isActive=%d (matches IG's stored state)", pk, isActive);
                return;
            }
            SPKLog(@"Presence", @"[Sparkle Presence] first sighting pk=%@ isActive=%d (IG had %d, real transition)",
                   pk, isActive, igPriorActive.boolValue);
        } else if (previous == nil && SPKPresenceWithinSnapshotGrace()) {
            // Fallback for when the store cannot be read: inside the post-launch replay
            // window a first sighting is assumed to be existing state.
            SPKLog(@"Presence", @"[Sparkle Presence] seed pk=%@ isActive=%d (startup replay, no notification)", pk, isActive);
            return;
        }
        if (previous != nil && previous.boolValue == isActive) {
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=unchanged isActive=%d", pk, isActive);
            return;
        }

        NSMutableDictionary *notified = SPKPresenceNotifiedStates();
        NSNumber *lastNotified = notified[pk];
        if (lastNotified != nil && lastNotified.boolValue == isActive) {
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=already-notified isActive=%d", pk, isActive);
            return;
        }

        // A direction the user switched off is still a direction they know about, so
        // record it before bailing. Leaving it unrecorded makes the next transition
        // back look like a repeat of the last one that was reported, which silences
        // the enabled direction from its second occurrence onwards -- with offline
        // notifications off, a user would come online exactly once per session.
        if (isActive && ![SPKUtils getBoolPref:kSPKPresenceNotifyOnlineKey]) {
            notified[pk] = @(isActive);
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=online-toggle-off", pk);
            return;
        }
        if (!isActive && ![SPKUtils getBoolPref:kSPKPresenceNotifyOfflineKey]) {
            notified[pk] = @(isActive);
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=offline-toggle-off", pk);
            return;
        }

        NSMutableDictionary *times = SPKPresenceLastNotifyTimes();
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        // Rate-limit repeated reports of the same state, not the transition in
        // the opposite direction. Otherwise a legitimate offline event arriving
        // seconds after an online event is swallowed by the online cooldown.
        NSString *cooldownKey = SPKPresenceNotifyCooldownKey(pk, isActive);
        NSNumber *last = times[cooldownKey];
        if (last != nil && (now - last.doubleValue) < SPKPresenceCooldown()) {
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=cooldown isActive=%d remaining=%.0fs",
                   pk, isActive, SPKPresenceCooldown() - (now - last.doubleValue));
            return;
        }

        notified[pk] = @(isActive);
        if (SPKDirectHiddenChatsSuppressesNotification(nil, pk)) {
            SPKLog(@"Presence", @"[Sparkle Presence] drop pk=%@ reason=hidden-chat", pk);
            return;
        }
        times[cooldownKey] = @(now);
        SPKLog(@"Presence", @"[Sparkle Presence] notify pk=%@ isActive=%d", pk, isActive);
        SPKPresenceNotify(pk, isActive);
    });
}

// Runs on every rewrite of the typing dictionary, which is frequent, so the cheap
// pref checks come before the queue hop.
void SPKPresenceHandleTypingSnapshot(NSDictionary<NSString *, NSDictionary *> *activeByThreadAndPK) {
    if (!SPKPresenceNotificationsEnabled())
        return;
    if (![SPKUtils getBoolPref:kSPKPresenceNotifyTypingKey])
        return;

    NSDictionary *snapshot = [activeByThreadAndPK isKindOfClass:NSDictionary.class] ? [activeByThreadAndPK copy] : @{};
    NSString *currentPK = [SPKUtils currentUserPK];

    dispatch_async(SPKPresenceQueue(), ^{
        NSMutableDictionary *states = SPKPresenceTypingStates();

        // Anyone we had marked as typing who is no longer in the snapshot has
        // stopped. Clearing them here is what lets their next burst read as a rising
        // edge instead of a repeat.
        for (NSString *known in states.allKeys) {
            if (snapshot[known] == nil)
                [states removeObjectForKey:known];
        }

        [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *eventKey, NSDictionary *event, __unused BOOL *stop) {
            if (![event isKindOfClass:NSDictionary.class])
                return;
            NSString *pk = SPKStringFromValue(event[@"pk"]);
            NSString *threadID = SPKStringFromValue(event[@"threadId"]);
            NSDate *sentDate = [event[@"sentDate"] isKindOfClass:NSDate.class] ? event[@"sentDate"] : nil;
            if (![pk isKindOfClass:NSString.class] || pk.length == 0)
                return;
            // Your own outgoing typing status is written into the same store as
            // everyone else's, so it arrives here too.
            if (currentPK.length > 0 && [pk isEqualToString:currentPK])
                return;
            if (!SPKPresenceAppliesToUser(pk))
                return;

            NSNumber *previous = states[eventKey];
            states[eventKey] = @(YES);
            if (previous != nil) {
                SPKLog(@"Presence", @"[Sparkle Presence] typing drop pk=%@ thread=%@ reason=already-typing",
                       pk, threadID ?: @"unknown");
                return;
            }

            // Guards IG re-applying a status that was already live before the hook
            // installed, which would otherwise read as a fresh burst.
            if ([sentDate isKindOfClass:NSDate.class]) {
                NSTimeInterval age = -[sentDate timeIntervalSinceNow];
                if (age > kSPKPresenceTypingMaxAge) {
                    SPKLog(@"Presence", @"[Sparkle Presence] typing drop pk=%@ thread=%@ reason=stale age=%.1fs",
                           pk, threadID ?: @"unknown", age);
                    return;
                }
            }

            NSMutableDictionary *times = SPKPresenceTypingNotifyTimes();
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            NSNumber *last = times[eventKey];
            if (last != nil && (now - last.doubleValue) < SPKPresenceCooldown()) {
                SPKLog(@"Presence", @"[Sparkle Presence] typing drop pk=%@ thread=%@ reason=cooldown remaining=%.0fs",
                       pk, threadID ?: @"unknown", SPKPresenceCooldown() - (now - last.doubleValue));
                return;
            }

            if (SPKDirectHiddenChatsSuppressesNotification(threadID, pk)) {
                SPKLog(@"Presence", @"[Sparkle Presence] typing drop pk=%@ thread=%@ reason=hidden-chat",
                       pk, threadID ?: @"unknown");
                return;
            }
            times[eventKey] = @(now);
            SPKLog(@"Presence", @"[Sparkle Presence] typing notify pk=%@ thread=%@", pk, threadID ?: @"unknown");
            SPKPresenceNotifyTyping(pk, threadID);
        }];
    });
}

#pragma mark - Read receipts

static id SPKPresenceObjectIvar(id object, const char *name) {
    if (!object || !name)
        return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar)
        return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKPresenceValue(id object, NSString *key, const char *ivarName) {
    if (!object)
        return nil;
    @try {
        id value = [object valueForKey:key];
        if (value && value != NSNull.null)
            return value;
    } @catch (__unused NSException *exception) {
    }
    return SPKPresenceObjectIvar(object, ivarName);
}

static SPKDirectThreadContext *SPKPresenceMatchingThreadContext(id source, NSString *threadID) {
    if (!source || threadID.length == 0)
        return nil;
    SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(source);
    return [context.threadId isEqualToString:threadID] ? context : nil;
}

static id SPKPresenceDirectCacheFromApplicator(id applicator) {
    return SPKPresenceObjectIvar(applicator, "_cache");
}

static id SPKPresenceDirectCacheFromActiveSession(void) {
    id session = [SPKUtils activeUserSession];
    SEL repoSelector = NSSelectorFromString(@"directRepo");
    if (![session respondsToSelector:repoSelector])
        return nil;
    @try {
        id repo = ((id (*)(id, SEL))objc_msgSend)(session, repoSelector);
        return SPKPresenceObjectIvar(repo, "_directCache");
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKPresencePublishedThread(id cache, NSString *threadID) {
    SEL selector = NSSelectorFromString(@"publishedThreadSet");
    id threadSet = nil;
    @try {
        if ([cache respondsToSelector:selector])
            threadSet = ((id (*)(id, SEL))objc_msgSend)(cache, selector);
    } @catch (__unused NSException *exception) {
    }
    if (!threadSet) {
        id memoryCache = SPKPresenceObjectIvar(cache, "_memoryCache");
        threadSet = SPKPresenceObjectIvar(memoryCache, "_threadsSet");
    }
    NSDictionary *threads = SPKPresenceObjectIvar(threadSet, "_threadsByThreadId");
    if (![threads isKindOfClass:NSDictionary.class])
        return nil;
    return threads[threadID] ?: threads[@(threadID.longLongValue)];
}

static id SPKPresenceThreadClientState(id cache, NSString *threadID) {
    SEL selector = NSSelectorFromString(@"threadClientStateForThreadId:");
    @try {
        if ([cache respondsToSelector:selector])
            return ((id (*)(id, SEL, id))objc_msgSend)(cache, selector, threadID);
    } @catch (__unused NSException *exception) {
    }

    // IG 410 exposes the same state through its memory-cache dictionary instead
    // of the convenience selector newer releases added to IGDirectCache.
    id memoryCache = SPKPresenceObjectIvar(cache, "_memoryCache");
    NSDictionary *states = SPKPresenceObjectIvar(memoryCache, "_threadClientStateByThreadIds");
    if (![states isKindOfClass:NSDictionary.class])
        return nil;
    return states[threadID] ?: states[@(threadID.longLongValue)];
}

// Group-aware activity copy is resolved only when an event is actually going to
// be shown. First try the open thread, then Direct's memory cache, then its normal
// cache fetch. A short fallback prevents notification delivery from depending on
// a private completion handler that could change in a future Instagram version.
static void SPKPresenceResolveThreadContext(NSString *threadID,
                                            id applicator,
                                            void (^completion)(SPKDirectThreadContext *context)) {
    if (!completion)
        return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKPresenceResolveThreadContext(threadID, applicator, completion);
        });
        return;
    }
    if (threadID.length == 0) {
        completion(nil);
        return;
    }

    SPKDirectThreadContext *active = SPKDirectActiveThreadContext();
    if ([active.threadId isEqualToString:threadID]) {
        completion(active);
        return;
    }

    id resolvedApplicator = applicator;
    if (!resolvedApplicator) {
        @synchronized(SPKPresenceQueue()) {
            NSString *currentPK = [SPKUtils currentUserPK];
            if (currentPK.length > 0 && [currentPK isEqualToString:sSPKPresenceDirectApplicatorOwnerPK])
                resolvedApplicator = sSPKPresenceDirectApplicator;
        }
    }
    id cache = SPKPresenceDirectCacheFromApplicator(resolvedApplicator);
    if (!cache)
        cache = SPKPresenceDirectCacheFromActiveSession();
    if (!cache) {
        SPKLog(@"Presence", @"[Sparkle Presence] notification context thread=%@ result=no-cache", threadID);
        completion(nil);
        return;
    }

    SPKDirectThreadContext *publishedContext = SPKPresenceMatchingThreadContext(SPKPresencePublishedThread(cache, threadID), threadID);
    if (publishedContext) {
        SPKLog(@"Presence", @"[Sparkle Presence] notification context thread=%@ result=published group=%d title=%@",
               threadID, publishedContext.isGroup, SPKDirectDisplayNameForThreadContext(publishedContext) ?: @"");
        completion(publishedContext);
        return;
    }

    SPKDirectThreadContext *cachedContext = SPKPresenceMatchingThreadContext(SPKPresenceThreadClientState(cache, threadID), threadID);
    if (cachedContext) {
        SPKLog(@"Presence", @"[Sparkle Presence] notification context thread=%@ result=client-state group=%d title=%@",
               threadID, cachedContext.isGroup, SPKDirectDisplayNameForThreadContext(cachedContext) ?: @"");
        completion(cachedContext);
        return;
    }

    SEL fetchSelector = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
    if (![cache respondsToSelector:fetchSelector])
        fetchSelector = NSSelectorFromString(@"_fetchThreadFromCacheWithThreadId:completion:");
    if (![cache respondsToSelector:fetchSelector]) {
        completion(nil);
        return;
    }

    __block BOOL finished = NO;
    void (^finish)(SPKDirectThreadContext *) = ^(SPKDirectThreadContext *context) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished)
                return;
            finished = YES;
            SPKLog(@"Presence", @"[Sparkle Presence] notification context thread=%@ result=fetch group=%d title=%@",
                   threadID, context.isGroup, SPKDirectDisplayNameForThreadContext(context) ?: @"");
            completion(context);
        });
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cache, fetchSelector, threadID, ^(id fetchedThread) {
            finish(SPKPresenceMatchingThreadContext(fetchedThread, threadID));
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (!finished) {
                               finished = YES;
                               SPKLog(@"Presence", @"[Sparkle Presence] notification context thread=%@ result=timeout", threadID);
                               completion(nil);
                           }
                       });
    } @catch (__unused NSException *exception) {
        completion(nil);
    }
}

static NSArray *SPKPresenceThreadUpdates(id cacheUpdate) {
    id updates = SPKPresenceValue(cacheUpdate, @"threadUpdates", "_threadUpdates");
    if ([updates isKindOfClass:NSArray.class])
        return updates;
    id single = SPKPresenceObjectIvar(cacheUpdate, "_threadUpdate");
    return single ? @[ single ] : @[];
}

static NSArray<NSDictionary *> *SPKPresenceReadEvents(id updates) {
    if (![updates isKindOfClass:NSArray.class])
        return @[];
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    for (id cacheUpdate in (NSArray *)updates) {
        NSString *threadID = SPKStringFromValue(SPKPresenceValue(cacheUpdate, @"threadId", "_threadId"));
        if (threadID.length == 0)
            continue;
        for (id threadUpdate in SPKPresenceThreadUpdates(cacheUpdate)) {
            id metadata = SPKPresenceValue(threadUpdate, @"threadMetadataUpdate", "_threadMetadataUpdate");
            if (!metadata)
                continue;
            NSString *readerPK = SPKStringFromValue(SPKPresenceObjectIvar(metadata, "_markSeenThreadWatermark_userPk"));
            NSString *messageID = SPKStringFromValue(SPKPresenceObjectIvar(metadata, "_markSeenThreadWatermark_messageId"));
            if (readerPK.length == 0 || messageID.length == 0)
                continue;
            id seenAt = SPKPresenceObjectIvar(metadata, "_markSeenThreadWatermark_seenAtTimestamp");
            NSMutableDictionary *event = [@{ @"threadId" : threadID,
                                             @"readerPk" : readerPK,
                                             @"messageId" : messageID } mutableCopy];
            if ([seenAt isKindOfClass:NSDate.class])
                event[@"seenAt"] = seenAt;
            [events addObject:event];
        }
    }
    return events;
}

// Instagram's server message ids are decimal cursors. Keep a conservative fallback
// for a future opaque id shape: equality still works, but we do not invent ordering.
static NSComparisonResult SPKPresenceCompareMessageIDs(NSString *left, NSString *right, BOOL *ordered) {
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    BOOL decimal = left.length > 0 && right.length > 0 &&
                   [left rangeOfCharacterFromSet:nonDigits].location == NSNotFound &&
                   [right rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
    if (!decimal) {
        if (ordered)
            *ordered = NO;
        return [left isEqualToString:right] ? NSOrderedSame : NSOrderedAscending;
    }
    if (ordered)
        *ordered = YES;
    NSString *a = left;
    NSString *b = right;
    if (a.length != b.length)
        return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
    return [a compare:b options:NSLiteralSearch];
}

static NSString *SPKPresenceMessageID(id message, id dictionaryKey) {
    NSString *messageID = SPKStringFromValue(dictionaryKey);
    if (messageID.length > 0)
        return messageID;
    id metadata = SPKPresenceValue(message, @"metadata", "_metadata");
    messageID = SPKStringFromValue(SPKPresenceValue(metadata, @"serverId", "_serverId"));
    if (messageID.length == 0)
        messageID = SPKStringFromValue(SPKPresenceValue(metadata, @"messageId", "_messageServerId"));
    return messageID;
}

static NSString *SPKPresenceMessageSenderPK(id message) {
    id metadata = SPKPresenceValue(message, @"metadata", "_metadata");
    NSString *senderPK = SPKStringFromValue(SPKPresenceValue(metadata, @"senderPk", "_senderPk"));
    return senderPK.length > 0 ? senderPK : SPKStringFromValue(SPKPresenceValue(message, @"senderPk", "_senderPk"));
}

static NSArray<NSDictionary *> *SPKPresenceOwnerMessagesFromUpdates(id updates, NSString *ownerPK) {
    if (![updates isKindOfClass:NSArray.class] || ownerPK.length == 0)
        return @[];
    NSMutableArray<NSDictionary *> *captured = [NSMutableArray array];
    for (id cacheUpdate in (NSArray *)updates) {
        NSString *threadID = SPKStringFromValue(SPKPresenceValue(cacheUpdate, @"threadId", "_threadId"));
        if (threadID.length == 0)
            continue;
        for (id threadUpdate in SPKPresenceThreadUpdates(cacheUpdate)) {
            id messageUpdate = SPKPresenceValue(threadUpdate, @"messageUpdate", "_messageUpdate");
            if (!messageUpdate)
                continue;
            NSArray *inserts = SPKPresenceValue(messageUpdate, @"insertMessages", "_insertMessages");
            NSArray *replacements = SPKPresenceValue(messageUpdate, @"replaceMessages", "_replaceMessages_messages");
            for (id collection in @[ inserts ?: @[], replacements ?: @[] ]) {
                if (![collection isKindOfClass:NSArray.class])
                    continue;
                for (id message in (NSArray *)collection) {
                    NSString *senderPK = SPKPresenceMessageSenderPK(message);
                    if (![senderPK isEqualToString:ownerPK])
                        continue;
                    NSString *messageID = SPKPresenceMessageID(message, nil);
                    if (messageID.length > 0)
                        [captured addObject:@{ @"threadId" : threadID, @"messageId" : messageID }];
                }
            }
        }
    }
    return captured;
}

static NSString *SPKPresenceOwnerMessagesKey(NSString *ownerPK, NSString *threadID) {
    return [NSString stringWithFormat:@"%@:%@", ownerPK, threadID];
}

static void SPKPresenceRecordOwnerMessages(NSArray<NSDictionary *> *messages, NSString *ownerPK) {
    for (NSDictionary *message in messages) {
        NSString *threadID = message[@"threadId"];
        NSString *messageID = message[@"messageId"];
        NSString *key = SPKPresenceOwnerMessagesKey(ownerPK, threadID);
        NSMutableOrderedSet<NSString *> *ids = SPKPresenceOwnerMessageIDs()[key];
        if (!ids) {
            ids = [NSMutableOrderedSet orderedSet];
            SPKPresenceOwnerMessageIDs()[key] = ids;
        }
        [ids addObject:messageID];
        while (ids.count > 200)
            [ids removeObjectAtIndex:0];
        SPKLog(@"Presence", @"[Sparkle Presence] read ledger owner=%@ thread=%@ message=%@", ownerPK, threadID, messageID);
    }
}

static NSDictionary *SPKPresenceMessagesForThread(id applicator, NSString *threadID) {
    id cache = SPKPresenceObjectIvar(applicator, "_cache");
    SEL selector = NSSelectorFromString(@"threadClientStateForThreadId:");
    if (!cache || ![cache respondsToSelector:selector])
        return nil;
    @try {
        id state = ((id (*)(id, SEL, id))objc_msgSend)(cache, selector, threadID);
        id messages = SPKPresenceObjectIvar(state, "_messagesByServerId");
        return [messages isKindOfClass:NSDictionary.class] ? messages : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SPKPresenceCursorCrossedOwnerMessage(id applicator,
                                                 NSString *threadID,
                                                 NSString *ownerPK,
                                                 NSString *previousID,
                                                 NSString *messageID) {
    NSDictionary *messages = SPKPresenceMessagesForThread(applicator, threadID);
    for (id key in messages) {
        id message = messages[key];
        if (![(SPKPresenceMessageSenderPK(message) ?: @"") isEqualToString:ownerPK])
            continue;
        NSString *candidateID = SPKPresenceMessageID(message, key);
        if (candidateID.length == 0)
            continue;
        BOOL upperOrdered = NO;
        NSComparisonResult upper = SPKPresenceCompareMessageIDs(candidateID, messageID, &upperOrdered);
        if ((!upperOrdered && upper != NSOrderedSame) || (upperOrdered && upper == NSOrderedDescending))
            continue;
        if (previousID.length == 0)
            return YES;
        BOOL lowerOrdered = NO;
        NSComparisonResult lower = SPKPresenceCompareMessageIDs(candidateID, previousID, &lowerOrdered);
        if ((lowerOrdered && lower == NSOrderedDescending) || (!lowerOrdered && [candidateID isEqualToString:messageID]))
            return YES;
    }

    NSOrderedSet<NSString *> *knownIDs = SPKPresenceOwnerMessageIDs()[SPKPresenceOwnerMessagesKey(ownerPK, threadID)];
    for (NSString *candidateID in knownIDs) {
        BOOL upperOrdered = NO;
        NSComparisonResult upper = SPKPresenceCompareMessageIDs(candidateID, messageID, &upperOrdered);
        if ((!upperOrdered && upper != NSOrderedSame) || (upperOrdered && upper == NSOrderedDescending))
            continue;
        if (previousID.length == 0)
            return YES;
        BOOL lowerOrdered = NO;
        NSComparisonResult lower = SPKPresenceCompareMessageIDs(candidateID, previousID, &lowerOrdered);
        if ((lowerOrdered && lower == NSOrderedDescending) || (!lowerOrdered && [candidateID isEqualToString:messageID]))
            return YES;
    }
    return NO;
}

void SPKPresenceHandleDirectThreadUpdates(id applicator, id updates, NSString *ownerPK) {
    if (applicator && ownerPK.length > 0) {
        @synchronized(SPKPresenceQueue()) {
            sSPKPresenceDirectApplicator = applicator;
            sSPKPresenceDirectApplicatorOwnerPK = [ownerPK copy];
        }
    }
    if (!SPKPresenceNotificationsEnabled() || ownerPK.length == 0)
        return;
    NSArray<NSDictionary *> *ownerMessages = SPKPresenceOwnerMessagesFromUpdates(updates, ownerPK);
    NSArray<NSDictionary *> *events = SPKPresenceReadEvents(updates);
    if (ownerMessages.count == 0 && events.count == 0)
        return;

    dispatch_async(SPKPresenceQueue(), ^{
        SPKPresenceRecordOwnerMessages(ownerMessages, ownerPK);
        for (NSDictionary *event in events) {
            NSString *threadID = event[@"threadId"];
            NSString *readerPK = event[@"readerPk"];
            NSString *messageID = event[@"messageId"];
            NSString *cursorKey = [NSString stringWithFormat:@"%@:%@:%@", ownerPK, threadID, readerPK];
            NSMutableDictionary *cursors = SPKPresenceReadCursors();
            NSString *previousID = cursors[cursorKey];

            SPKLog(@"Presence", @"[Sparkle Presence] raw read watermark owner=%@ thread=%@ reader=%@ message=%@ prior=%@",
                   ownerPK, threadID, readerPK, messageID, previousID ?: @"unknown");

            BOOL ordered = NO;
            NSComparisonResult advance = previousID.length > 0
                                             ? SPKPresenceCompareMessageIDs(messageID, previousID, &ordered)
                                             : NSOrderedDescending;
            if (previousID.length > 0 && ((ordered && advance != NSOrderedDescending) ||
                                           (!ordered && advance == NSOrderedSame)))
                continue;
            cursors[cursorKey] = messageID;

            NSString *activeOwnerPK = [SPKUtils currentUserPK];
            if (activeOwnerPK.length > 0 && ![activeOwnerPK isEqualToString:ownerPK]) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=inactive-owner active=%@ owner=%@",
                       threadID, readerPK, activeOwnerPK, ownerPK);
                continue;
            }
            if ([readerPK isEqualToString:ownerPK]) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=self", threadID, readerPK);
                continue;
            }
            if (![SPKUtils getBoolPref:kSPKPresenceNotifyReadKey]) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=read-toggle-off", threadID, readerPK);
                continue;
            }
            if (!SPKPresenceAppliesToUser(readerPK)) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=not-tracked allMode=%d listCount=%lu",
                       threadID, readerPK, SPKPresenceAllUsersMode(), (unsigned long)SPKPresenceUserList().count);
                continue;
            }

            // A first cursor can be an inbox snapshot. Only treat it as an event when
            // Instagram says the read itself just happened; subsequent advances are
            // already distinguished from replay by the stored cursor.
            if (previousID.length == 0) {
                NSDate *seenAt = event[@"seenAt"];
                NSTimeInterval age = [seenAt isKindOfClass:NSDate.class] ? -seenAt.timeIntervalSinceNow : DBL_MAX;
                if (age < -5.0 || age > kSPKPresenceReadEventMaxAge) {
                    SPKLog(@"Presence", @"[Sparkle Presence] read seed thread=%@ reader=%@ message=%@", threadID, readerPK, messageID);
                    continue;
                }
            }

            if (!SPKPresenceCursorCrossedOwnerMessage(applicator, threadID, ownerPK, previousID, messageID)) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=no-owner-message", threadID, readerPK);
                continue;
            }

            NSMutableDictionary *times = SPKPresenceReadNotifyTimes();
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            NSNumber *last = times[cursorKey];
            if (last && now - last.doubleValue < kSPKPresenceReadCooldown) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=cooldown", threadID, readerPK);
                continue;
            }
            if (SPKDirectHiddenChatsSuppressesNotification(threadID, readerPK)) {
                SPKLog(@"Presence", @"[Sparkle Presence] read drop thread=%@ reader=%@ reason=hidden-chat", threadID, readerPK);
                continue;
            }
            times[cursorKey] = @(now);
            SPKLog(@"Presence", @"[Sparkle Presence] read notify thread=%@ reader=%@ message=%@", threadID, readerPK, messageID);
            SPKPresenceNotifyRead(readerPK, threadID, applicator);
        }
    });
}

#pragma mark - Diagnostics

// IGPresenceState is an opaque value object with no usable public surface, so its
// contents are read by ivar reflection. This is diagnostics-only: nothing on the
// notification path depends on it, so a shape change here degrades to a less useful
// report rather than breaking the feature.
static NSString *SPKPresenceDescribeState(id state) {
    if (!state)
        return @"(no state)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (Class cls = [state class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *rawName = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!rawName || !type)
                continue;
            NSString *name = @(rawName);
            @try {
                if (type[0] == '@') {
                    id value = object_getIvar(state, ivars[i]);
                    [parts addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
                } else if (type[0] == 'B' || type[0] == 'c') {
                    ptrdiff_t offset = ivar_getOffset(ivars[i]);
                    BOOL value = *(BOOL *)((__bridge void *)state + offset);
                    [parts addObject:[NSString stringWithFormat:@"%@=%d", name, value]];
                } else if (type[0] == 'd') {
                    ptrdiff_t offset = ivar_getOffset(ivars[i]);
                    double value = *(double *)((__bridge void *)state + offset);
                    // Presence timestamps are ms since epoch; a bare number is
                    // unreadable in a report, so render anything plausibly a date.
                    if (value > 1e12) {
                        NSDate *date = [NSDate dateWithTimeIntervalSince1970:value / 1000.0];
                        [parts addObject:[NSString stringWithFormat:@"%@=%.0f (%.0fs ago)", name, value,
                                                                   -date.timeIntervalSinceNow]];
                    } else {
                        [parts addObject:[NSString stringWithFormat:@"%@=%.0f", name, value]];
                    }
                } else if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'i' || type[0] == 'I') {
                    ptrdiff_t offset = ivar_getOffset(ivars[i]);
                    long long value = *(long long *)((__bridge void *)state + offset);
                    [parts addObject:[NSString stringWithFormat:@"%@=%lld", name, value]];
                }
            } @catch (__unused NSException *e) {
            }
        }
        free(ivars);
    }
    // Value objects synthesize their accessors and carry no ivars, so the walk above
    // finds nothing for them and their own description is the only readable shape.
    if (parts.count == 0)
        return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([state class]), [state description]];
    return [parts componentsJoinedByString:@" "];
}

static NSString *SPKPresenceReadableState(id state) {
    if (!state)
        return @"Status: NO DATA\n  Instagram has no presence record for this user";

    NSNumber *active = SPKPresenceActiveFlagFromState(state);
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Status: %@", active ? (active.boolValue ? @"ONLINE" : @"OFFLINE") : @"UNKNOWN"]];

    static NSArray<NSString *> *timestampKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timestampKeys = @[ @"lastActivityAtMs", @"lastActivityAt", @"lastActiveAtMs", @"lastActiveTime" ];
    });
    id timestampValue = SPKPresenceValueForCandidateKeys(state, timestampKeys);
    if ([timestampValue respondsToSelector:@selector(doubleValue)]) {
        double timestamp = [timestampValue doubleValue];
        if (timestamp > 0) {
            // Instagram's presence model normally uses milliseconds, while a few
            // older paths use seconds. Normalize both before presenting the age.
            NSTimeInterval seconds = timestamp > 1e11 ? timestamp / 1000.0 : timestamp;
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds];
            NSTimeInterval age = MAX(0, -date.timeIntervalSinceNow);
            [lines addObject:[NSString stringWithFormat:@"Last activity: %.0fs ago", age]];
        }
    }

    [lines addObject:[NSString stringWithFormat:@"Raw: %@", SPKPresenceDescribeState(state)]];
    return [lines componentsJoinedByString:@"\n  "];
}

NSString *SPKPresenceDiagnosticsText(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    NSString *currentPK = [SPKUtils currentUserPK];
    [lines addObject:[NSString stringWithFormat:@"Account pk: %@", currentPK.length ? currentPK : @"(unresolved)"]];
    [lines addObject:[NSString stringWithFormat:@"Enabled: %d  Mode: %@",
                                                SPKPresenceNotificationsEnabled(),
                                                SPKPresenceAllUsersMode() ? @"All Users (legacy)" : @"Tracked Users"]];

    NSArray<NSDictionary *> *tracked = SPKPresenceUserList();
    [lines addObject:[NSString stringWithFormat:@"Tracked users: %lu", (unsigned long)tracked.count]];
    [lines addObject:SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_FOOTER")];
    [lines addObject:[NSString stringWithFormat:@"\n%@", SPKAccurateActiveStatusDiagnosticsText()]];

    id session = [SPKUtils activeUserSession];
    if (!session) {
        [lines addObject:@"\nNo active session, cannot reach the presence store."];
        return [lines componentsJoinedByString:@"\n"];
    }
    if (![session respondsToSelector:@selector(presenceManager)]) {
        [lines addObject:@"\nSession has no presenceManager (IG shape changed)."];
        return [lines componentsJoinedByString:@"\n"];
    }

    id manager = [session presenceManager];
    if (!manager) {
        [lines addObject:@"\nSession returned no presence manager."];
        return [lines componentsJoinedByString:@"\n"];
    }
    if (![manager respondsToSelector:@selector(presenceStatesByUserPk)]) {
        [lines addObject:@"\nPresence manager cannot report states (IG shape changed)."];
        return [lines componentsJoinedByString:@"\n"];
    }

    id rawStates = [manager presenceStatesByUserPk];
    if (![rawStates isKindOfClass:NSDictionary.class]) {
        [lines addObject:[NSString stringWithFormat:@"\nUnexpected states payload: %@", rawStates]];
        return [lines componentsJoinedByString:@"\n"];
    }

    NSDictionary *states = (NSDictionary *)rawStates;
    // The headline number: if IG knows about nobody, the feature has nothing to work
    // with and no amount of tuning on our side changes that.
    [lines addObject:[NSString stringWithFormat:@"IG knows presence for: %lu users", (unsigned long)states.count]];

    if (tracked.count > 0) {
        [lines addObject:@"\nTracked:"];
        for (NSDictionary *entry in tracked) {
            NSString *pk = SPKStringFromValue(entry[@"pk"]);
            NSString *username = SPKStringFromValue(entry[@"username"]);
            id state = states[pk] ?: states[@(pk.longLongValue)];
            [lines addObject:[NSString stringWithFormat:@"@%@ (%@)\n  %@",
                                                       username.length ? username : @"?", pk,
                                                       SPKPresenceReadableState(state)]];
        }
    }

    // Everything else IG holds, so it is obvious whether the store is populated at
    // all versus populated but missing the tracked user specifically.
    NSMutableArray<NSString *> *untracked = [NSMutableArray array];
    for (id key in states) {
        NSString *pk = SPKStringFromValue(key);
        if (SPKPresenceListContainsUser(pk))
            continue;
        [untracked addObject:[NSString stringWithFormat:@"%@\n  %@", pk, SPKPresenceReadableState(states[key])]];
    }
    if (untracked.count > 0) {
        [lines addObject:[NSString stringWithFormat:@"\nOther users IG knows (%lu):", (unsigned long)untracked.count]];
        [lines addObjectsFromArray:untracked];
    }

    return [lines componentsJoinedByString:@"\n"];
}

@interface _SPKPresenceDiagnosticsViewController : UIViewController
@end

@implementation _SPKPresenceDiagnosticsViewController {
    UITextView *_textView;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    self.title = SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_TITLE");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _textView.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(16.0, 14.0, 16.0, 14.0);
    _textView.layer.cornerRadius = 14.0;
    [self.view addSubview:_textView];

    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0]
    ]];

    UIBarButtonItem *refreshItem = SPKMediaChromeTopBarButtonItem(@"arrow_ccw", self, @selector(refreshTapped));
    refreshItem.accessibilityLabel = SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_REFRESH_ACCESSIBILITY_LABEL");
    UIBarButtonItem *copyItem = SPKMediaChromeTopBarButtonItem(@"copy", self, @selector(copyTapped));
    copyItem.accessibilityLabel = SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_COPY_ACCESSIBILITY_LABEL");
    UIBarButtonItem *clearItem = SPKMediaChromeTopBarButtonItem(@"trash", self, @selector(clearTapped));
    clearItem.accessibilityLabel = SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_CLEAR_ACCESSIBILITY_LABEL");
    clearItem.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ clearItem, copyItem, refreshItem ]);
}

// Re-read on every appearance: the report is a live snapshot of what IG holds, and a
// stale one is worse than none when the whole point is checking whether activity is
// arriving.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadContent];
}

- (void)reloadContent {
    NSString *text = SPKPresenceDiagnosticsText();
    SPKLog(@"Presence", @"[Sparkle Presence] diagnostics\n%@", text);
    _textView.text = text;
}

- (void)refreshTapped {
    [self reloadContent];
    SPKNotify(kSPKNotificationPresenceUserRule, SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_REFRESHED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

- (void)copyTapped {
    if (_textView.text.length == 0)
        return;
    UIPasteboard.generalPasteboard.string = _textView.text;
    SPKNotify(kSPKNotificationPresenceUserRule, SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_COPIED_TOAST"), nil, @"copy_filled", SPKNotificationToneSuccess);
}

- (void)clearTapped {
    SPKPresenceResetState();
    [self reloadContent];
    SPKNotify(kSPKNotificationPresenceUserRule,
              SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_CLEARED_TOAST_TITLE"),
              SPKL(@"MESSAGES_ACTIVITY_DIAGNOSTICS_CLEARED_TOAST_MESSAGE"),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
}

@end

UIViewController *SPKPresenceDiagnosticsViewController(void) {
    return [_SPKPresenceDiagnosticsViewController new];
}

#pragma mark - Current-chat rule

// Presence is per user, so only a 1:1 offers the toggle. IG's stored roster normally
// excludes the current user, but not every path guarantees it, so self is filtered out
// explicitly rather than trusting the count.
static NSDictionary *SPKPresencePartnerForContext(SPKDirectThreadContext *context) {
    if (!context || context.isGroup)
        return nil;
    NSString *currentPK = [SPKUtils currentUserPK];
    NSMutableArray<NSDictionary *> *others = [NSMutableArray array];
    for (NSDictionary *user in context.users) {
        if (![user isKindOfClass:NSDictionary.class])
            continue;
        NSString *pk = SPKStringFromValue(user[@"pk"]);
        if (pk.length == 0)
            continue;
        if (currentPK.length > 0 && [pk isEqualToString:currentPK])
            continue;
        [others addObject:user];
    }
    return others.count == 1 ? others.firstObject : nil;
}

NSString *SPKPresenceCurrentChatActionTitle(SPKDirectThreadContext *context) {
    NSDictionary *partner = SPKPresencePartnerForContext(context);
    if (!partner)
        return nil;
    NSString *pk = SPKStringFromValue(partner[@"pk"]);
    return SPKPresenceAppliesToUser(pk) ? SPKL(@"MESSAGES_ACTIVITY_STOP_TRACKING_TITLE") : SPKL(@"MESSAGES_ACTIVITY_TRACK_TITLE");
}

void SPKPresencePresentChatRuleToggle(SPKDirectThreadContext *context) {
    NSDictionary *partner = SPKPresencePartnerForContext(context);
    if (!partner) {
        SPKNotify(kSPKNotificationPresenceUserRule, SPKL(@"MESSAGES_ACTIVITY_USER_NOT_FOUND_TOAST"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }

    NSString *pk = SPKStringFromValue(partner[@"pk"]);
    NSString *username = SPKStringFromValue(partner[@"username"]);
    NSString *fullName = SPKStringFromValue(partner[@"fullName"]);
    NSString *profilePicUrl = SPKStringFromValue(partner[@"profilePicUrl"]);
    NSString *name = username.length > 0 ? [@"@" stringByAppendingString:username]
                                         : (fullName.length > 0 ? fullName : SPKL(@"MESSAGES_ACTIVITY_FALLBACK_PARTNER_NAME"));

    BOOL trackedBefore = SPKPresenceAppliesToUser(pk);
    NSString *title = trackedBefore ? SPKL(@"MESSAGES_ACTIVITY_STOP_TRACKING_TITLE") : SPKL(@"MESSAGES_ACTIVITY_TRACK_TITLE");
    NSString *message = trackedBefore
                            ? [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_STOP_CONFIRM_MESSAGE"), name]
                            : [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_START_CONFIRM_MESSAGE"), name];

    [SPKUtils
        showConfirmation:^{
            SPKPresenceToggleForPK(pk, username, fullName, profilePicUrl);
            SPKNotify(kSPKNotificationPresenceUserRule,
                      trackedBefore ? [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_TRACKING_OFF_TOAST"), name]
                                    : [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_TRACKING_ON_TOAST"), name],
                      SPKPresenceListTitle(),
                      @"circle_check_filled",
                      SPKNotificationToneSuccess);
        }
                   title:title
                 message:message];
}

#pragma mark - Tracked users list

@interface SPKPresenceUsersViewController : SPKAutoSaveFilterListViewController
@end

@implementation SPKPresenceUsersViewController

- (instancetype)init {
    if ((self = [super initWithConfig:SPKPresenceFilterConfig()])) {
        self.showsAddButton = YES;
        self.title = SPKL(@"MESSAGES_ACTIVITY_TRACKED_USERS_TITLE");
        self.infoText = SPKL(@"MESSAGES_ACTIVITY_LIST_INFO_TEXT");
        self.emptyTitle = SPKL(@"MESSAGES_ACTIVITY_EMPTY_TITLE");
        self.emptySubtitle = SPKL(@"MESSAGES_ACTIVITY_EMPTY_SUBTITLE");
    }
    return self;
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
    self.title = count == 0 ? SPKL(@"MESSAGES_ACTIVITY_TRACKED_USERS_TITLE")
                            : [NSString stringWithFormat:SPKL(@"MESSAGES_ACTIVITY_TRACKED_USERS_COUNT_TITLE"), (unsigned long)count, count == 1 ? SPKL(@"MESSAGES_ACTIVITY_UNIT_USER_SINGULAR") : SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_USERS_TEXT")];
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    NSString *username = SPKStringFromValue(entry[@"username"]);
    return username.length > 0 ? [@"@" stringByAppendingString:username] : nil;
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in SPKPresenceUserList()) {
        NSString *pk = SPKStringFromValue(entry[@"pk"]);
        NSString *username = SPKStringFromValue(entry[@"username"]);
        NSString *fullName = SPKStringFromValue(entry[@"fullName"]);
        NSString *profilePicUrl = SPKStringFromValue(entry[@"profilePicUrl"]);
        if (profilePicUrl.length == 0 && pk.length > 0)
            profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

        SPKUserListItem *item = [SPKUserListItem new];
        item.pk = pk;
        item.title = username.length ? [@"@" stringByAppendingString:username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
        item.subtitle = fullName.length ? fullName : nil;
        item.avatarURLString = profilePicUrl;
        item.representedObject = entry;
        [items addObject:item];
    }
    return items;
}

- (void)presentError:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_UNABLE_ADD_USER_TEXT")
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleCancel handler:nil] ]];
}

- (void)didTapAdd {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                           title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADD_USER_TEXT")
                                                         message:SPKL(@"MESSAGES_ACTIVITY_ADD_USER_PROMPT_MESSAGE")
                                                     placeholder:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USERNAME_TEXT")
                                                     initialText:nil
                                                 autocapitalized:NO
                                                    confirmTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        [weakSelf lookupUsername:text];
                                                    }
                                                     cancelBlock:nil];
}

- (void)lookupUsername:(NSString *)rawUsername {
    NSString *username = SPKAutoSaveFilterNormalizedUsername(rawUsername);
    if (username.length == 0)
        return;
    NSString *encodedUsername = [username stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    if (encodedUsername.length == 0)
        return;

    __weak typeof(self) weakSelf = self;
    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/web_profile_info/?username=%@", encodedUsername]
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
                                    __strong typeof(weakSelf) strongSelf = weakSelf;
                                    if (!strongSelf)
                                        return;
                                    NSDictionary *user = response[@"data"][@"user"];
                                    if (![user isKindOfClass:NSDictionary.class])
                                        user = response[@"user"];
                                    if (![user isKindOfClass:NSDictionary.class] || error) {
                                        [strongSelf presentError:[NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USER_VALUE_NOT_FOUND_FORMAT"), username]];
                                        return;
                                    }

                                    NSString *pk = SPKStringFromValue(user[@"id"] ?: user[@"pk"]);
                                    if (pk.length == 0) {
                                        [strongSelf presentError:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_COULD_NOT_RESOLVE_USER_S_INSTAGRAM_ID_TEXT")];
                                        return;
                                    }
                                    NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: username;
                                    NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"";
                                    NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);

                                    NSString *message = fullName.length > 0
                                                            ? [NSString stringWithFormat:@"@%@ (%@)", resolvedUsername, fullName]
                                                            : [@"@" stringByAppendingString:resolvedUsername];

                                    [SPKIGAlertPresenter presentAlertFromViewController:strongSelf
                                                                                  title:SPKL(@"MESSAGES_ACTIVITY_TRACK_ACTIVITY_CONFIRM_TITLE")
                                                                                message:message
                                                                                actions:@[
                                                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                style:SPKIGAlertActionStyleCancel
                                                                                                              handler:nil],
                                                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD")
                                                                                                                style:SPKIGAlertActionStyleDefault
                                                                                                              handler:^{
                                                                                                                  [strongSelf addResolvedUserPK:pk
                                                                                                                                       username:resolvedUsername
                                                                                                                                       fullName:fullName
                                                                                                                                  profilePicUrl:profilePicUrl];
                                                                                                              }],
                                                                                ]];
                                }];
}

- (void)addResolvedUserPK:(NSString *)pk username:(NSString *)username fullName:(NSString *)fullName profilePicUrl:(NSString *)profilePicUrl {
    if (SPKPresenceListContainsUser(pk))
        return;
    SPKPresenceToggleForPK(pk, username, fullName, profilePicUrl);
    SPKNotify(kSPKNotificationPresenceUserRule,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKPresenceListTitle(),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKPresenceListViewController(void) {
    return [[SPKPresenceUsersViewController alloc] init];
}
