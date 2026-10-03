#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

%group SPKDisableScrollingReelsHooks

%hook IGUnifiedVideoCollectionView
- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"DisableScrollingReels.didMoveToWindow");

    if ([SPKUtils getBoolPref:@"reels_disable_scrolling"]) {
        SPKLog(@"General", @"[Sparkle] Disabling scrolling reels");

        self.scrollEnabled = false;
    }
}

- (void)setScrollEnabled:(BOOL)arg1 {
    if ([SPKUtils getBoolPref:@"reels_disable_scrolling"]) {
        SPKLog(@"General", @"[Sparkle] Disabling scrolling reels");

        return %orig(NO);
    }

    return %orig;
}
%end

// Disable auto-scrolling reels
%hook _TtC19IGSundialAutoScroll19IGSundialAutoScroll
- (void)setIsEnabled:(BOOL)enabled {
    if ([SPKUtils getBoolPref:@"reels_disable_scrolling"]) {
        %orig(NO);
    } else {
        %orig(enabled);
    }
}

// 448+ made isEnabled computed; the user's choice goes through this setter.
- (void)setUserEnabled:(BOOL)enabled {
    %orig([SPKUtils getBoolPref:@"reels_disable_scrolling"] ? NO : enabled);
}
%end

%end

void SPKInstallDisableScrollingReelsHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"reels_disable_scrolling"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDisableScrollingReelsHooks);
    });
}
