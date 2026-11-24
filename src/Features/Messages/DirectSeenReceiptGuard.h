#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Second lock behind Manually Mark Seen: stops any read receipt for a chat that
/// manual seen covers unless Sparkle itself is sending it.
void SPKInstallDirectSeenReceiptGuardIfNeeded(void);

/// Sparkle is about to send a read receipt for this chat on purpose (the eye
/// button, Mark Seen On). Lets receipts for it through for a moment. A nil chat
/// lets any chat through.
void SPKDirectSeenReceiptGuardAllow(NSString *_Nullable threadId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
