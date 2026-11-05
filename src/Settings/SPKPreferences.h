#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// "follow" lets Instagram decide, "on" and "off" force Liquid Glass either way.
FOUNDATION_EXPORT NSString *const kSPKPrefInterfaceLiquidGlassMode;
FOUNDATION_EXPORT NSString *const kSPKPrefInterfaceLiquidGlassTabBarMode;
FOUNDATION_EXPORT NSString *const kSPKPrefInterfaceScrollEdgeStyle;
/// Posted after the scroll edge style changes so on-screen views re-apply it.
FOUNDATION_EXPORT NSNotificationName const SPKScrollEdgeStyleDidChangeNotification;
FOUNDATION_EXPORT NSString *const kSPKPrefInstantsDisableCameraControl;

#ifdef __cplusplus
extern "C" {
#endif

NSString *SPKPrefActionButtonConfigKey(NSString *topicKey);
NSString *SPKPrefActionButtonDefaultActionKey(NSString *topicKey);
NSString *SPKPrefActionButtonBulkDownloadKey(NSString *topicKey);
NSString *SPKPrefActionButtonBulkCopyKey(NSString *topicKey);
NSString *SPKPrefNotificationKey(NSString *identifier);
NSString *SPKPrefNotificationHapticKey(NSString *identifier);

/// YES on iPhone models that have the hardware Camera Control button
/// (iPhone 16/17 families, excluding iPhone 16e which lacks it).
BOOL SPKDeviceHasCameraControl(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
