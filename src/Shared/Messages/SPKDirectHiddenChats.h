#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "SPKDirectSeenContext.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted when the hidden-chat list or the reveal state changes, so an inbox that
/// is already on screen can rebuild instead of waiting for its next natural update.
FOUNDATION_EXPORT NSNotificationName const SPKDirectHiddenChatsDidChangeNotification;

/// How long a reveal survives. Stored as a string pref so the settings picker can
/// name the modes; unknown values fall back to leaving the inbox.
typedef NS_ENUM(NSInteger, SPKDirectHiddenChatsRevealReset) {
    SPKDirectHiddenChatsRevealResetLeavingInbox = 0,
    SPKDirectHiddenChatsRevealResetBackgrounded,
    SPKDirectHiddenChatsRevealResetNever,
};

#ifdef __cplusplus
extern "C" {
#endif

BOOL SPKDirectHiddenChatsEnabled(void);

/// Stored entries, newest first. Same dictionary shape as the manual-seen list
/// (`threadId`, `threadName`, `isGroup`, `users`, `groupPhotoUrl`, `addedAt`), so a
/// thread captured by either feature reads identically in both lists.
NSArray<NSDictionary *> *SPKDirectHiddenChatList(void);
NSUInteger SPKDirectHiddenChatCount(void);

/// Membership test used on the inbox hot path. Matches the stored thread id first
/// and falls back to the participant PKs, since a thread id can change under the
/// same conversation (a request being accepted, a group being re-created).
BOOL SPKDirectHiddenChatListContainsThreadId(NSString *_Nullable threadId);
BOOL SPKDirectHiddenChatListContainsContext(SPKDirectThreadContext *_Nullable context);

/// YES when any stored entry's participant set matches `userPKs` exactly. A 1:1 and
/// a group are only ever compared against their own kind, so a group containing one
/// hidden partner does not itself go hidden.
BOOL SPKDirectHiddenChatListContainsParticipants(NSArray<NSString *> *_Nullable userPKs, BOOL isGroup);

void SPKDirectHideThreadWithContext(SPKDirectThreadContext *context);
void SPKDirectUnhideThreadId(NSString *threadId);

/// YES when Sparkle's own notifications about this thread or user should be swallowed
/// because the chat is hidden right now. Pass whichever identifier the caller holds;
/// a bare user PK only matches a hidden 1:1, never a group they happen to be in.
BOOL SPKDirectHiddenChatsSuppressesNotification(NSString *_Nullable threadId, NSString *_Nullable userPK);

/// Applies (or lifts) the account-level thread mute for every hidden chat, for when
/// the "Mute Notifications" preference is toggled with chats already hidden. Only
/// threads Sparkle muted are unmuted.
void SPKDirectHiddenChatsSyncNativeMute(BOOL mute);

/// Reveal state. Never persisted: a reveal that survived a relaunch would defeat the
/// point of hiding, and the "never re-hide" mode only means "until toggled off".
BOOL SPKDirectHiddenChatsRevealed(void);
void SPKDirectSetHiddenChatsRevealed(BOOL revealed);
void SPKDirectToggleHiddenChatsRevealed(void);
SPKDirectHiddenChatsRevealReset SPKDirectHiddenChatsRevealResetMode(void);

/// Called by the inbox hooks on the events that can end a reveal. No-ops when the
/// current reset mode does not care about that event.
void SPKDirectHiddenChatsNoteLeftInbox(void);
void SPKDirectHiddenChatsNoteBackgrounded(void);

/// YES while hidden threads should be filtered out of the inbox: the feature is on,
/// something is hidden, and the list is not currently revealed.
BOOL SPKDirectHiddenChatsShouldFilterInbox(void);

/// Title/handler for the inbox menu row, or nil when the thread cannot be resolved.
NSString *_Nullable SPKDirectHiddenChatsMenuActionTitle(SPKDirectThreadContext *_Nullable context);
void SPKDirectHiddenChatsToggleThread(SPKDirectThreadContext *_Nullable context, UIViewController *_Nullable presenter);

/// Runs `completion` once the hidden chat lock has been satisfied, immediately when
/// no lock is set. Biometrics are tried first, with the passcode keypad as the
/// fallback; a cancelled prompt reports NO.
void SPKDirectHiddenChatsAuthenticate(UIViewController *_Nullable presenter, void (^completion)(BOOL granted));

UIViewController *SPKDirectHiddenChatsListViewController(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
