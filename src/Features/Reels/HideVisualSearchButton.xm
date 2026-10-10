#import "../../InstagramHeaders.h"
#import "../../Utils.h"

static inline BOOL SPKHideReelsVisualSearchEnabled(void) {
    return [SPKUtils getBoolPref:@"reels_hide_visual_search_btn"];
}

// The reels column decides visibility inside its own Swift layout, so the view
// model answer alone does not keep the button out. Hiding the lazy view before
// layout runs lets the column close the gap by itself.
static void SPKHideReelsVisualSearchButton(UIView *ufi) {
    if (!SPKHideReelsVisualSearchEnabled())
        return;

    for (NSString *ivarName in @[ @"lazyVisualSearchButton", @"_lazyVisualSearchButton" ]) {
        id lazyView = [SPKUtils getIvarForObj:ufi name:ivarName.UTF8String];
        if (![lazyView respondsToSelector:@selector(hide)])
            continue;

        [lazyView hide];
        return;
    }
}

%group SPKHideVisualSearchReelsColumnHooks

%hook IGSundialViewerVerticalUFI
- (void)configureWithViewModel:(id)model {
    %orig;
    SPKHideReelsVisualSearchButton(self);
}
- (void)configureWithMedia:(id)media interactionCountVisibilityHelper:(id)helper {
    %orig;
    SPKHideReelsVisualSearchButton(self);
}
- (void)layoutSubviews {
    SPKHideReelsVisualSearchButton(self);
    %orig;
}
%end

%end

%group SPKHideVisualSearchButtonHooks

%hook IGSundialViewerUFIViewModel
- (BOOL)shouldShowVisualSearchButton {
    if (SPKHideReelsVisualSearchEnabled()) {
        return NO;
    }

    return %orig;
}
%end

%end

extern "C" void SPKInstallHideVisualSearchButtonHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKHideVisualSearchButtonHooks);

        Class ufiClass = SPKReelsVerticalUFIClass();
        if (ufiClass) {
            %init(SPKHideVisualSearchReelsColumnHooks, IGSundialViewerVerticalUFI = ufiClass);
        }
    });
}
