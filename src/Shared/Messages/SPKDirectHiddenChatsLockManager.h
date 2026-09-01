#import "../Gallery/SPKGalleryManager.h"

NS_ASSUME_NONNULL_BEGIN

/// Independent passcode/biometric lock guarding the hidden chat list, backed by its
/// own keychain record so it never shares a passcode with the gallery or settings
/// locks. Device wide rather than per account: it protects the act of revealing,
/// which the account switcher cannot be trusted to scope.
@interface SPKDirectHiddenChatsLockManager : SPKGalleryManager

+ (instancetype)sharedManager;

/// YES when a reveal has to pass authentication first.
- (BOOL)requiresAuthentication;

@end

NS_ASSUME_NONNULL_END
