#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void SPKStabilityGuardBeginLaunch(void);
FOUNDATION_EXPORT void SPKStabilityGuardMarkHooksFinished(void);
// This launch has been marked stable. Posted once per process, on the main queue.
FOUNDATION_EXPORT NSNotificationName const SPKStabilityGuardLaunchDidStabilizeNotification;
FOUNDATION_EXPORT BOOL SPKStabilityGuardIsLaunchStable(void);
FOUNDATION_EXPORT BOOL SPKStabilityGuardIsSafeStartupMode(void);
FOUNDATION_EXPORT void SPKStabilityGuardReset(void);

// Explains safe startup mode to the user and offers to turn it off. No-op when
// safe mode is inactive. Must be called on the main thread, once the app is
// active — safe mode otherwise looks like Sparkle silently doing nothing.
FOUNDATION_EXPORT void SPKStabilityGuardPresentSafeModeAlertIfNeeded(void);

NS_ASSUME_NONNULL_END
