#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a chat's local or sent read state moves.
/// userInfo carries @"threadId".
FOUNDATION_EXPORT NSNotificationName const SPKDirectLocalSeenDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif

/// Keep Seen Locally for chats: Manually Mark Seen is on and the sub-option is on.
BOOL SPKDirectLocalSeenEnabled(void);

/// Whether manual seen applies to this chat (the Excluded/Included list).
BOOL SPKDirectLocalSeenAppliesToThreadId(NSString *_Nullable threadId);

/// The chat was read on this device up to `date` (server time of its newest message).
/// Only moves forward.
void SPKDirectLocalSeenRecord(NSString *_Nullable accountPK, NSString *_Nullable threadId, NSDate *_Nullable date);

/// The chat's read receipt reached Instagram up to `date`. Only moves forward.
void SPKDirectLocalSeenRecordSent(NSString *_Nullable accountPK, NSString *_Nullable threadId, NSDate *_Nullable date);

/// Local read time for the chat, or nil.
NSDate *_Nullable SPKDirectLocalSeenDate(NSString *_Nullable accountPK, NSString *_Nullable threadId);

/// YES when the chat reads as seen here but the sender has no receipt for it yet.
BOOL SPKDirectLocalSeenReceiptPending(NSString *_Nullable accountPK, NSString *_Nullable threadId);

/// Chats of this account that read as seen here without a receipt for it.
NSUInteger SPKDirectLocalSeenPendingCount(NSString *_Nullable accountPK);

/// Lists those chats. Swiping a chat or the trash button makes it unread again;
/// receipts already sent are not affected.
UIViewController *SPKDirectLocalSeenListViewController(void);

/// Instagram's own read state is left alone for a moment while the eye button
/// sends a receipt, so its mark sees the chat as unread and sends it.
void SPKDirectLocalSeenSuspend(NSString *_Nullable threadId);
BOOL SPKDirectLocalSeenSuspended(NSString *_Nullable threadId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
