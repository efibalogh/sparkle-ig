#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../../App/SPKPerfMeter.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"

static NSString *const kSPKInstantsAllowScreenshotPref = @"instants_allow_screenshot";

static BOOL SPKInstantsAllowScreenshotEnabled(void) {
    return [SPKUtils getBoolPref:kSPKInstantsAllowScreenshotPref];
}

// class_getName + strstr rather than NSStringFromClass + containsString:. This
// runs once per view controller per walk, and the NSString version allocated and
// did a locale-aware search every time.
static inline BOOL SPKInstantsClassIsQuickSnap(Class cls) {
    const char *name = cls ? class_getName(cls) : NULL;
    return name && strstr(name, "QuickSnap") != NULL;
}

// -presentedViewController returns the controller presented by the receiver *or
// by any of its ancestors*, so recursing into it from every node re-walks the
// same modal subtree once per node - exponential in nav depth. Follow it only
// from the controller that actually presented it.
static BOOL SPKInstantsViewControllerTreeContainsQuickSnap(UIViewController *controller) {
    if (!controller)
        return NO;
    if (SPKInstantsClassIsQuickSnap(controller.class))
        return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (SPKInstantsViewControllerTreeContainsQuickSnap(child))
            return YES;
    }
    UIViewController *presented = controller.presentedViewController;
    if (presented.presentingViewController != controller)
        return NO;
    return SPKInstantsViewControllerTreeContainsQuickSnap(presented);
}

// The bypass check sits behind hooks on NSNotificationCenter and UIScreen, both
// of which are hit thousands of times a second, so the answer is cached for a
// fraction of a second. An Instant cannot appear and be screenshotted inside that
// window, and the walk touches UIKit - which means it must not run off the main
// thread at all, and notifications are posted from every thread there is.
static const CFTimeInterval kSPKInstantsBypassTTL = 0.2;
static BOOL spkInstantsBypassCached = NO;
static CFTimeInterval spkInstantsBypassCachedAt = 0;

static BOOL SPKInstantsScreenshotBypassComputeOnMain(void) {
    SPK_PERF_SCOPE(@"InstantsAllowScreenshot.treeWalk");
    if (!SPKInstantsAllowScreenshotEnabled())
        return NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (SPKInstantsViewControllerTreeContainsQuickSnap(window.rootViewController)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL SPKInstantsScreenshotBypassActive(void) {
    if (!NSThread.isMainThread)
        return spkInstantsBypassCached;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - spkInstantsBypassCachedAt < kSPKInstantsBypassTTL)
        return spkInstantsBypassCached;

    spkInstantsBypassCachedAt = now;
    spkInstantsBypassCached = SPKInstantsScreenshotBypassComputeOnMain();
    return spkInstantsBypassCached;
}

static BOOL SPKInstantsIsScreenshotCoverText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0)
        return NO;
    NSString *lower = text.lowercaseString;
    return [lower containsString:@"screenshot or record"] ||
           [lower containsString:@"only meant to be viewed once"] ||
           [lower containsString:@"only meant to be replayed once"];
}

static UIView *SPKInstantsTopAncestorBelowWindow(UIView *view) {
    UIView *current = view;
    while (current.superview && ![current.superview isKindOfClass:UIWindow.class]) {
        current = current.superview;
    }
    return current.superview ? current : nil;
}

static UITextField *SPKInstantsSecureTextFieldAncestor(UIView *view) {
    UIView *parent = view.superview;
    while (parent) {
        if ([parent isKindOfClass:UITextField.class])
            return (UITextField *)parent;
        parent = parent.superview;
    }
    return nil;
}

%group SPKInstantsAllowScreenshotHooks

%hook UIScreen
- (BOOL)isCaptured {
    if (SPKInstantsScreenshotBypassActive())
        return NO;
    return %orig;
}
%end

%hook NSNotificationCenter

// Name first, always. This hook sees every notification the app posts, and the
// bypass check walks the view-controller tree - testing it first made every
// notification in Instagram pay for a full tree walk, which is quadratic against
// navigation depth and froze the app after a few screens.
- (void)postNotificationName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo {
    if ([name isEqualToString:UIApplicationUserDidTakeScreenshotNotification] &&
        SPKInstantsScreenshotBypassActive())
        return;
    %orig;
}

- (void)postNotificationName:(NSNotificationName)name object:(id)object {
    if ([name isEqualToString:UIApplicationUserDidTakeScreenshotNotification] &&
        SPKInstantsScreenshotBypassActive())
        return;
    %orig;
}
%end

%hook UITextField
- (void)setSecureTextEntry:(BOOL)secureTextEntry {
    if (secureTextEntry && SPKInstantsScreenshotBypassActive() && !SPKChromeCanvasOwnsSecureField((UITextField *)self)) {
        %orig(NO);
        return;
    }
    %orig;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    // Text check first (cheap string scan, almost always false) — avoids the
    // expensive pref read + VC-tree walk for every label in the app.
    if (!SPKInstantsIsScreenshotCoverText(text) || !SPKInstantsScreenshotBypassActive())
        return;
    UILabel *label = (UILabel *)self;
    UIView *cover = SPKInstantsTopAncestorBelowWindow(label) ?: label.superview ?
                                                                                : label;
    cover.hidden = YES;
    cover.alpha = 0.0;
    label.hidden = YES;
    label.alpha = 0.0;

    UITextField *secureField = SPKInstantsSecureTextFieldAncestor(cover);
    if (secureField.secureTextEntry && !SPKChromeCanvasOwnsSecureField(secureField)) {
        secureField.secureTextEntry = NO;
    }
}
%end

%end

extern "C" void SPKInstallInstantsAllowScreenshotHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKInstantsAllowScreenshotHooks);
        SPKLog(@"Instants", @"[Sparkle] Instants allow screenshot hooks installed");
    });
}
