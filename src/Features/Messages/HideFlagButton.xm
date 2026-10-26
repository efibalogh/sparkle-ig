#import "../../Utils.h"

// IG 453 rewrote the flag controller in Swift: its flag button argument is
// non-optional and its ivar lost the leading underscore.
static BOOL SPKFlagControllerIsSwift = NO;

%group SPKHideFlagButtonHooks

%hook IGDirectThreadLabelButtonComponent

- (id)makeLabelButtonWithTintColor:(id)color {
    if ([SPKUtils getBoolPref:@"msgs_hide_flag_btn"]) {
        return nil;
    }
    return %orig;
}

%end

%hook IGDirectThreadViewRightBarButtonsFeatureController

- (id)labelButtonWithTintColor:(id)color {
    if ([SPKUtils getBoolPref:@"msgs_hide_flag_btn"]) {
        return nil;
    }
    return %orig;
}

%end

%hook IGDirectThreadFlagController

- (id)initWithUserSession:(id)session threadId:(id)threadId threadIsFlagged:(_Bool)flagged flagButton:(id)button presentingViewController:(id)controller {
    if ([SPKUtils getBoolPref:@"msgs_hide_flag_btn"]) {
        if ([button isKindOfClass:[UIView class]]) {
            ((UIView *)button).hidden = YES;
        } else if ([button isKindOfClass:[UIBarButtonItem class]]) {
            ((UIBarButtonItem *)button).customView.hidden = YES;
        }
        return %orig(session, threadId, flagged, SPKFlagControllerIsSwift ? button : nil, controller);
    }
    return %orig;
}

- (void)updateThreadIsFlagged:(_Bool)flagged {
    %orig;
    if ([SPKUtils getBoolPref:@"msgs_hide_flag_btn"]) {
        id barBtn = [SPKUtils getIvarForObj:self name:"_flagBarButtonItem"] ?: [SPKUtils getIvarForObj:self name:"flagBarButtonItem"];
        if ([barBtn isKindOfClass:[UIBarButtonItem class]]) {
            ((UIBarButtonItem *)barBtn).customView.hidden = YES;
        }
    }
}

%end

%end

extern "C" void SPKInstallHideFlagButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"msgs_hide_flag_btn"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swift class from 453, where only the mangled name is guaranteed.
        Class flagController = objc_getClass("IGDirectThreadFlagController");
        if (!flagController) {
            flagController = objc_getClass("_TtC28IGDirectThreadFlagController28IGDirectThreadFlagController");
            SPKFlagControllerIsSwift = flagController != Nil;
        }
        %init(SPKHideFlagButtonHooks, IGDirectThreadFlagController = flagController);
    });
}
