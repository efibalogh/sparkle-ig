// Reads and writes Instagram's own account privacy booleans.
//
// These two settings are not local preferences: Instagram stores them on the
// account, so every device and every client sees the change. The tweak simply
// calls the same Pando GraphQL builders Instagram's own settings screens use,
// which keeps request signing, client context and error mapping inside IG.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKAccountPrivacySetting) {
    /// Hides both the follower and the following list of the signed-in account.
    SPKAccountPrivacySettingFollowLists = 0,
    /// Removes the signed-in account from other people's follower and following lists.
    SPKAccountPrivacySettingSelfInLists = 1,
};

/// `value` is the value the server reports back. On success `error` is nil.
/// `value` may be nil after a successful write if the server did not echo one
/// back; callers should fall back to the value they asked for.
typedef void (^SPKAccountPrivacyResult)(NSNumber *_Nullable value, NSError *_Nullable error);

FOUNDATION_EXPORT NSString *const SPKAccountPrivacyErrorDomain;
/// userInfo key holding Instagram's own user-facing reason, when the server sent one.
FOUNDATION_EXPORT NSString *const SPKAccountPrivacyServerMessageKey;

/// Error codes in SPKAccountPrivacyErrorDomain. The descriptions are technical
/// and only meant for the log; callers pick localized copy from the code.
typedef NS_ENUM(NSInteger, SPKAccountPrivacyErrorCode) {
    /// This Instagram build lacks the builders or the GraphQL service.
    SPKAccountPrivacyErrorUnsupported = 1,
    /// The request could not be built or sent, or failed in transport.
    SPKAccountPrivacyErrorRequestFailed = 2,
    /// The server answered with an error, for example an account outside the rollout.
    SPKAccountPrivacyErrorServerRefused = 3,
    /// The server answered without a readable value.
    SPKAccountPrivacyErrorNoValue = 4,
};

@interface SPKAccountPrivacyService : NSObject

/// NO when this Instagram build lacks the settings builders or the Pando
/// service, in which case every call fails immediately without a request.
+ (BOOL)isSupported;

/// Reads the current value from the server.
+ (void)fetchSetting:(SPKAccountPrivacySetting)setting completion:(SPKAccountPrivacyResult)completion;

/// Writes the value to the server.
+ (void)setSetting:(SPKAccountPrivacySetting)setting value:(BOOL)value completion:(SPKAccountPrivacyResult)completion;

@end

NS_ASSUME_NONNULL_END
