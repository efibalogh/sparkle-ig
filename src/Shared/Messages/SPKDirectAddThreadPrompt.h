#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Copy for the "add a chat by username" prompt. Every DM thread list wants the same
/// three-step flow (ask for a username, resolve the user, resolve the 1:1 thread behind
/// them) but names the thing it is adding differently, so the wording is passed in and
/// the flow is not duplicated per list.
@interface SPKDirectAddThreadPromptCopy : NSObject
@property (nonatomic, copy) NSString *promptTitle;         // "Add Chat"
@property (nonatomic, copy) NSString *promptMessage;       // what can and cannot be added
@property (nonatomic, copy) NSString *confirmTitle;        // "Hide this chat?"
@property (nonatomic, copy) NSString *errorTitle;          // "Unable to Add Chat"
@property (nonatomic, copy) NSString *userNotFoundFormat;  // takes the username
@property (nonatomic, copy) NSString *noThreadFormat;      // takes the username
@property (nonatomic, copy) NSString *unresolvedUserText;  // user found, no usable id
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Presents the prompt from `host` and calls `completion` with a thread entry in the
/// shape the DM thread lists store, once the user has confirmed. Never called on
/// cancellation or failure: those present their own alert.
void SPKDirectPresentAddThreadPrompt(UIViewController *host,
                                     SPKDirectAddThreadPromptCopy *copy,
                                     void (^completion)(NSDictionary *entry, NSString *username));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
