#import "SPKDirectHiddenChatsLockManager.h"

#import "SPKStrings.h"

@implementation SPKDirectHiddenChatsLockManager

+ (instancetype)sharedManager {
    static SPKDirectHiddenChatsLockManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPKDirectHiddenChatsLockManager alloc] init];
    });
    return instance;
}

- (NSString *)lockEnabledDefaultsKey {
    return @"msgs_hidden_chats_lock";
}

- (NSString *)keychainService {
    return @"com.sparkle.sparkle.hiddenchats.passcode";
}

- (NSString *)protectedContentName {
    return SPKL(@"MESSAGES_HIDDEN_CHATS_HEADER");
}

- (BOOL)requiresAuthentication {
    return self.isLockEnabled && !self.isUnlocked;
}

@end
