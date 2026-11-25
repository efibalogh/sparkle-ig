// Online/offline notifications for selected users.
//
// IG streams presence for everyone it knows about, so the work here is mostly
// deciding what NOT to surface: the raw feed repeats states, replays a full
// snapshot on every reconnect, and flaps online/offline on a weak connection.
// `SPKPresenceHandleUpdate` is the single funnel that turns that into the few
// transitions a user actually wants to see.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SPKAutoSaveFilterConfig, SPKDirectThreadContext;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Tracked-users filter: mode + dual lists, keyed by user pk.
///
/// Presence arrives per user, never per thread -- group chats have no presence at
/// all -- so the identity here is a pk even though the toggle is offered from
/// inside a chat.
SPKAutoSaveFilterConfig *SPKPresenceFilterConfig(void);

BOOL SPKPresenceNotificationsEnabled(void);
/// YES for a legacy all-users configuration, otherwise NO for the normal tracked-users list.
BOOL SPKPresenceAllUsersMode(void);
NSString *SPKPresenceListTitle(void);
NSArray<NSDictionary *> *SPKPresenceUserList(void);
BOOL SPKPresenceListContainsUser(NSString *_Nullable pk);
/// Resolves mode + list into the actual decision for `pk`.
BOOL SPKPresenceAppliesToUser(NSString *_Nullable pk);
/// YES when "All Users" is on or the tracked list is non-empty. Hot paths bail
/// out early when nobody could be notified.
BOOL SPKPresenceHasAnyTarget(void);
void SPKPresenceToggleForPK(NSString *pk, NSString *_Nullable username, NSString *_Nullable fullName, NSString *_Nullable profilePicUrl);
UIViewController *SPKPresenceListViewController(void);
/// One-line state for the Messages settings row ("Off", "3 Tracked").
NSString *SPKPresenceSettingsSummary(void);

/// What Instagram itself currently believes about `pk`, read out of its presence
/// store, or nil when it holds nothing readable for that user.
///
/// This is the value the green dot is drawn from, so comparing an incoming update
/// against it is the only way to tell a real transition from Instagram re-applying
/// state it already had.
NSNumber *_Nullable SPKPresenceIGActiveStateForPK(NSString *_Nullable pk);

/// Called from the `IGPresenceManager` hooks for every presence update IG receives.
/// Cheap no-op unless the feature is on and `pk` is tracked.
///
/// `igPriorActive` is `SPKPresenceIGActiveStateForPK` sampled *before* the original
/// implementation ran, so it still describes the state the user could see. Pass nil
/// when it could not be read; the funnel then falls back to a time window.
void SPKPresenceHandleUpdate(NSString *_Nullable pk, BOOL isActive, double lastActivityAtMs, NSNumber *_Nullable igPriorActive);

/// Called from the typing-status hook with everyone IG currently considers to be
/// typing. Each value carries the sender pk, thread id, and event timestamp; the
/// dictionary key uniquely identifies that user inside that thread.
///
/// A snapshot rather than a per-user edge, because IG signals "stopped typing" by
/// dropping the entry rather than by sending an inactive one: without the full set
/// there is no way to tell a burst that ended from one that is still running, and
/// the next real burst would be swallowed as a repeat.
///
/// Only the start of a burst is surfaced. The end of one is either a sent message
/// or a timeout, neither of which is worth a notification.
void SPKPresenceHandleTypingSnapshot(NSDictionary<NSString *, NSDictionary *> *_Nullable activeByThreadAndPK);

/// Called after Instagram applies a batch of Direct cache updates. Extracts remote
/// seen-watermark advances and only surfaces one when the cursor crossed a message
/// sent by the owning account. `applicator` and `updates` intentionally stay opaque
/// because their concrete types vary between supported Instagram versions.
void SPKPresenceHandleDirectThreadUpdates(id _Nullable applicator,
                                          id _Nullable updates,
                                          NSString *_Nullable ownerPK);

/// Drops the seed/cooldown state. Called when the tracked list changes, so a
/// freshly added user notifies on their next real transition rather than
/// inheriting a stale decision made while they were untracked.
void SPKPresenceResetState(void);

/// Marks the point after which presence updates are treated as real events rather
/// than IG replaying state it already had. Call when the hook installs and whenever
/// the app foregrounds.
void SPKPresenceNoteStreamStarted(void);

/// Asks for local-notification authorization, once, the first time the feature is
/// switched on. In-app pills work regardless; this only gates the banner shown
/// while IG is backgrounded.
void SPKPresenceRequestNotificationAuthorization(void);

/// Key set in a Sparkle activity notification's userInfo. Instagram's own foreground
/// presentation handler drops notifications it does not recognize, so the hook that
/// lets ours through needs a marker it can match on.
FOUNDATION_EXPORT NSString *const kSPKPresenceNotificationMarker;

#pragma mark - Diagnostics

/// Snapshot of what IG currently believes about presence, read straight from its
/// own store rather than from anything we accumulated. Answers the question the
/// realtime hook cannot: whether IG has presence for a user at all, versus having
/// it and simply never pushing an update for them.
NSString *SPKPresenceDiagnosticsText(void);

/// Scrollable read-only view of `SPKPresenceDiagnosticsText`, with a copy button.
/// A view controller rather than an alert because the report grows with the number
/// of users Instagram holds presence for, and an alert that outgrows the screen
/// pushes its own dismiss button out of reach.
UIViewController *SPKPresenceDiagnosticsViewController(void);

#pragma mark - Current-chat rule (eye button / action menus)

/// Dynamic menu title for the 1:1 partner of `context`, or nil for groups and
/// unresolved threads (nothing to track).
NSString *_Nullable SPKPresenceCurrentChatActionTitle(SPKDirectThreadContext *_Nullable context);
/// Runs the confirmation, toggles, and notifies. No-op when the partner doesn't resolve.
void SPKPresencePresentChatRuleToggle(SPKDirectThreadContext *_Nullable context);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
