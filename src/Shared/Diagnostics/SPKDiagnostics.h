#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT NSString *const kSPKPrefToolsDebugButton;

// The debug button's reports.
FOUNDATION_EXPORT NSString *SPKDiagnosticsScreenReport(BOOL includeText);
FOUNDATION_EXPORT NSString *SPKDiagnosticsHierarchyReport(BOOL includeText);
// point is in the screen's coordinate space.
FOUNDATION_EXPORT NSString *SPKDiagnosticsInspectReport(CGPoint point, BOOL includeText, UIView *_Nullable *_Nullable selectedView);
#if SPK_DEV
// Backgrounds on screen and in the keyboard, grouped by resolved value.
FOUNDATION_EXPORT NSString *SPKDiagnosticsColorReport(void);
#endif

// Shows or removes the floating debug button to match the preference.
FOUNDATION_EXPORT void SPKDebugButtonRefresh(void);
FOUNDATION_EXPORT BOOL SPKDebugButtonOwnsWindow(UIWindow *window);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
