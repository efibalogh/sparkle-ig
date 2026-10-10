// Sharing from the Edits app into a re-signed Instagram.
//
// Edits renders the video into a container both apps reach through a Meta app
// group, then opens instagram://basel_share naming that file. A sideload signer
// remaps every app group to its own team, so this process is denied the read and
// Instagram's handler gives up without any UI. Nothing can make the file readable
// from here, so this only replaces the silent failure with an explanation. A
// handoff that is readable (stock entitlements) is left alone.

#import "../../InstagramHeaders.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

#import <UIKit/UIKit.h>

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

// A cold launch can deliver the same URL through both hooks.
static BOOL spk_editsShareAlertPending = NO;

// The URL names the file but not where it lives, and asking NSFileManager for the
// group container proves nothing: the sideload shim answers that with a private
// stand-in directory. What decides the read is the entitlement this process was
// actually signed with.
static BOOL SPKEditsShareHandoffIsReadable(void) {
    static BOOL entitled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task)
            return;
        id groups = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL));
        CFRelease(task);
        entitled = [groups isKindOfClass:[NSArray class]] && [(NSArray *)groups containsObject:@"group.com.facebook.family"];
    });
    return entitled;
}

static void SPKEditsSharePresentAlert(void) {
    // On a cold launch the URL arrives before there is anything to present from.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKEditsSharePresentAlert();
        });
        return;
    }
    spk_editsShareAlertPending = NO;
    [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                  title:SPKL(@"GENERAL_EDITS_SHARE_UNAVAILABLE_TITLE")
                                                message:SPKL(@"GENERAL_EDITS_SHARE_UNAVAILABLE_MESSAGE")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                style:SPKIGAlertActionStyleDefault
                                                                              handler:nil],
                                                ]];
}

// YES when the URL is an Edits handoff this process cannot read.
static BOOL SPKEditsShareInterceptURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] ||
        ![url.scheme.lowercaseString isEqualToString:@"instagram"] ||
        ![url.host.lowercaseString isEqualToString:@"basel_share"] ||
        SPKEditsShareHandoffIsReadable()) {
        return NO;
    }
    if (!spk_editsShareAlertPending) {
        spk_editsShareAlertPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKEditsSharePresentAlert();
        });
    }
    return YES;
}

%group SPKEditsShareFallback

%hook IGAppCoordinator

// Warm opens: the scene delegate forwards its URL contexts here.
- (BOOL)application:(id)application openURL:(NSURL *)url options:(id)options {
    if (SPKEditsShareInterceptURL(url))
        return YES;
    return %orig;
}

- (void)scene:(UIScene *)scene willConnectToSession:(id)session options:(UISceneConnectionOptions *)options window:(id)window {
    %orig;
    if (![options isKindOfClass:[UISceneConnectionOptions class]])
        return;
    for (UIOpenURLContext *context in options.URLContexts) {
        SPKEditsShareInterceptURL(context.URL);
    }
}

%end

%end

void SPKInstallEditsShareFallbackHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (objc_getClass("IGAppCoordinator")) {
            %init(SPKEditsShareFallback);
        }
    });
}
