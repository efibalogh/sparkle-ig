#import "SPKPreferenceAvailability.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../App/SPKFlexLoader.h"
#import "../Shared/MediaPreview/SPKFullScreenImageViewController.h"
#import "SPKPreferences.h"

static BOOL SPKIsIOSVersionAtLeast(NSString *version) {
    return [[[UIDevice currentDevice] systemVersion] compare:version options:NSNumericSearch] != NSOrderedAscending;
}

BOOL SPKPrefIsAvailable(NSString *key) {
    if (key.length == 0)
        return YES;

    // The Liquid Glass pref and its tab bar mode also back the pre-iOS 26
    // "Pill-Shaped Tab Bar" toggle — the tab bar experiment gates reshape the
    // bar into the floating pill on any iOS, only the glass material is 26+.
    if ([key isEqualToString:kSPKPrefInterfaceLiquidGlassMode] ||
        [key isEqualToString:kSPKPrefInterfaceLiquidGlassTabBarMode]) {
        return YES;
    }

    // The scroll edge style relies on UIScrollEdgeEffect, which only exists on iOS 26+.
    if ([key isEqualToString:kSPKPrefInterfaceScrollEdgeStyle]) {
        return SPKIsIOSVersionAtLeast(@"26.0");
    }

    // Liquid Glass, and so its OLED tint choice, only exists on iOS 26+.
    if ([key isEqualToString:@"interface_oled_black_glass"]) {
        return SPKIsIOSVersionAtLeast(@"26.0");
    }

    // Instagram's native UITabBarController tab bar exists from 451 on and is a
    // Liquid Glass system bar, so it needs iOS 26 and a build that ships it.
    if ([key isEqualToString:kSPKPrefInterfaceNativeTabBar]) {
        static BOOL available;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class controllerClass = NSClassFromString(@"IGTabBarController");
            available = SPKIsIOSVersionAtLeast(@"26.0") && controllerClass &&
                        class_getInstanceVariable(controllerClass, "_usesNativeTabBarController") &&
                        [controllerClass instancesRespondToSelector:NSSelectorFromString(@"_nativeTopologyIsSupportedWithExpandedSurfaces:compactSurfaces:")];
        });
        return available;
    }

    if ([key isEqualToString:@"notifs_pill_liquid_glass"]) {
        return SPKIsIOSVersionAtLeast(@"26.0");
    }

    // Live Text needs VisionKit's image analyzer: iOS 16+ on supported hardware.
    if ([key isEqualToString:@"general_preview_live_text"]) {
        return SPKLiveTextIsSupported();
    }

    if ([key isEqualToString:kSPKPrefInstantsDisableCameraControl]) {
        return SPKDeviceHasCameraControl();
    }

    if ([key hasPrefix:@"tools_flex_"]) {
        return SPKFlexIsBundled();
    }

    return YES;
}
