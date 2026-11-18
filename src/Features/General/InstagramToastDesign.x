#import <objc/runtime.h>
#import <substrate.h>
#import "../../Utils.h"
#import "../../Shared/UI/SPKNotificationCenter.h"

// Instagram's toast redesign rounds its confirmation toasts into pills. It is a server
// gate, -isToastM2Enabled on Instagram's design-system config (450+), which each toast
// view reads once when it is built. The redesign draws its background with Liquid Glass
// and has no fallback material, so before iOS 26 a toast built with it shows its text
// and icon over nothing: the setting is only offered from iOS 26.
//
// Default leaves the server's answer alone; On and Off override it, and only while the
// Instagram notification style is chosen, the only style its row shows in. Read on every call,
// so toasts built after a change follow it; a toast Instagram already built and keeps
// for reuse changes on the next launch.

NSString *const kSPKPrefInstagramToastDesign = @"notifs_instagram_toast_design";

static BOOL (*SPKOrigLauncherConfigToastM2)(id, SEL);
static BOOL (*SPKOrigSwiftConfigToastM2)(id, SEL);

static BOOL SPKToastDesignOverride(BOOL serverValue) {
    if (!SPKNotificationUsesInstagramStyle())
        return serverValue;
    NSString *mode = [SPKUtils getStringPref:kSPKPrefInstagramToastDesign];
    if ([mode isEqualToString:@"on"])
        return YES;
    if ([mode isEqualToString:@"off"])
        return NO;
    return serverValue;
}

static BOOL SPKLauncherConfigToastM2(id self, SEL _cmd) {
    return SPKToastDesignOverride(SPKOrigLauncherConfigToastM2(self, _cmd));
}

static BOOL SPKSwiftConfigToastM2(id self, SEL _cmd) {
    return SPKToastDesignOverride(SPKOrigSwiftConfigToastM2(self, _cmd));
}

static void SPKHookToastM2Getter(NSString *className, IMP replacement, BOOL (**original)(id, SEL)) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(@"isToastM2Enabled");
    // class_getInstanceMethod also finds an inherited method; only a class that
    // implements the getter itself is hooked, so a shared superclass is never touched.
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getImplementation(method) == class_getMethodImplementation(class_getSuperclass(cls), selector)) {
        SPKLog(@"Notify", @"Toast design getter missing on %@", className);
        return;
    }
    MSHookMessageEx(cls, selector, replacement, (IMP *)original);
}

void SPKInstallInstagramToastDesignHooksIfNeeded(void) {
    if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0"))
        return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The Objective-C config and its Swift twin, which answers the same question
        // for Swift callers.
        SPKHookToastM2Getter(@"IGDSLauncherConfig", (IMP)SPKLauncherConfigToastM2, &SPKOrigLauncherConfigToastM2);
        SPKHookToastM2Getter(@"_TtC11BSLDSConfig11BSLDSConfig", (IMP)SPKSwiftConfigToastM2, &SPKOrigSwiftConfigToastM2);
    });
}
