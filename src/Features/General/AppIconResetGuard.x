// * Keep the chosen app icon
// Instagram runs a job a few seconds after launch that sets the alternate icon
// back to the default when it decides the account may not use it. Its custom
// icons (Throwback, Ricky, ...) are tied to a subscription, so an icon picked
// in Sparkle is reset on the next launch where the job runs. The decision is
// made inside Instagram's Swift code; forcing its ObjC availability check does
// not stop it, so the guard sits on the UIKit setter instead.
//
// The job only ever resets to the default. So once the user has picked an
// alternate icon in Sparkle, a reset to the default that Sparkle did not make
// is dropped, and the caller's completion reports success so it does not
// retry. A change to another alternate icon (Instagram's own picker, for a
// subscriber) goes through and becomes the stored pick, so a later reset keeps
// that one instead. Users who never picked one, or picked the default, are
// left alone.

#import "../../Utils.h"
#import "../../Settings/SPKAppIconCatalog.h"

static BOOL SPKAppIconResetGuardShouldBlockReset(void) {
    NSString *stored = [SPKAppIconCatalog storedSelectedIdentifier];
    if (stored.length == 0)
        return NO;

    // A stored icon this build no longer ships cannot be kept anyway.
    SPKAppIconItem *item = [SPKAppIconCatalog appIconWithIdentifier:stored];
    return item != nil && !item.isPrimary;
}

%group SPKAppIconResetGuardHooks

%hook UIApplication
- (void)setAlternateIconName:(NSString *)alternateIconName completionHandler:(void (^)(NSError *))completionHandler {
    if ([SPKAppIconCatalog isPerformingOwnedIconWrite]) {
        %orig;
        return;
    }

    // A change to another alternate icon: let it through and follow it.
    if (alternateIconName.length > 0) {
        NSString *name = [alternateIconName copy];
        void (^completion)(NSError *) = [completionHandler copy];
        void (^followed)(NSError *) = ^(NSError *error) {
            if (!error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [SPKAppIconCatalog setStoredSelectedIdentifier:name];
                });
            }
            if (completion)
                completion(error);
        };
        %orig(alternateIconName, followed);
        return;
    }

    if (!SPKAppIconResetGuardShouldBlockReset()) {
        %orig;
        return;
    }

    SPKLog(@"AppIcon", @"Kept '%@'; dropped an outside reset to the default",
           [SPKAppIconCatalog storedSelectedIdentifier]);
    if (completionHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(nil);
        });
    }
}
%end

%end

void SPKInstallAppIconResetGuardHooksIfNeeded(void) {
    // Installed regardless of any pick: the stored icon is read on every call,
    // so a pick made later in the session is protected too.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKAppIconResetGuardHooks);
    });
}
