#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

void SPKInstallDirectLocalSeenHooksIfNeeded(void);

/// Instagram wanted to mark the open chat seen and manual seen held it back.
void SPKDirectLocalSeenNoteThreadViewed(NSString *_Nullable threadId);

/// Bracket the eye button's mark: Instagram's own read state is shown while it
/// decides what to send, then the chat is recorded as sent.
void SPKDirectLocalSeenWillSendReceipt(NSString *_Nullable threadId);
void SPKDirectLocalSeenDidSendReceipt(NSString *_Nullable threadId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
