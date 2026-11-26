#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Instagram's second tab bar implementation: a UIKit UITabBarController driven
// by IGNativeTabBarControllerCoordinator. Instagram turns it on by itself on
// foldables, and the System Tab Bar preference forces it elsewhere.

/// Whether this IGTabBarController runs the native tab bar.
FOUNDATION_EXPORT BOOL SPKNativeTabBarIsActive(id _Nullable controller);

/// Whether the system tab bar is in use right now. Answered from the live
/// IGTabBarController; before one exists, from the System Tab Bar preference.
/// Settings use it to grey out what cannot reach the system bar.
FOUNDATION_EXPORT BOOL SPKSystemTabBarInUse(void);

/// Whether Instagram turned the system tab bar on by itself (the foldable
/// iPhone), as opposed to Sparkle's System Tab Bar switch forcing it. Recorded
/// when the tab bar controller first builds its tabs; NO before that.
FOUNDATION_EXPORT BOOL SPKSystemTabBarChosenByInstagram(void);

/// Whether the system tab bar stands as a column down a side of the window (a
/// foldable iPhone's layout), where Classic cannot apply. Remembered from the
/// last tab bar seen for launch code that runs before one exists.
FOUNDATION_EXPORT BOOL SPKSystemTabBarRunsAsColumn(void);

/// Whether Instagram's regular-width system bar carries its own Activity and
/// Create tabs (it does where header items cannot move into the side column).
/// Asked of the live controller's own ordering; NO before one exists.
FOUNDATION_EXPORT BOOL SPKSystemTabBarRegularWidthAddsInstagramTabs(void);

/// Rebuilds the live system bar's tabs from Instagram's own descriptors. The
/// coordinator only attaches a hold to tabs whose descriptor names a hold
/// action, and names are read when the descriptors are built, so a hold set on
/// a tab Instagram gives none would otherwise wait for a restart. No-op on the
/// custom bar.
FOUNDATION_EXPORT void SPKNativeTabBarRebuildTabs(void);

/// Coordinator hooks (surface lists, Saved tab, visibility, tab holds). Part of
/// the essential install set, so the Settings hold keeps working under the
/// kill switch. Every hook re-checks its preferences at call time.
FOUNDATION_EXPORT void SPKInstallNativeTabBarCoordinatorHooks(void);

NS_ASSUME_NONNULL_END
