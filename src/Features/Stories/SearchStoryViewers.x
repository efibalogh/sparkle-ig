#import "SPKStrings.h"
#import "../../AssetUtils.h"
#import "../../Shared/Stories/SPKStoryViewersSearchViewController.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import "../../App/SPKPerfMeter.h"

// Sparkle-native "Search Viewer List". Instagram Plus's own viewer search is
// server-enforced (the GraphQL search rejects non-subscribers), so instead of
// unlocking it we add our own search entry point to your story's viewer list.
// Tapping it fetches the full viewer list via the private list_reel_media_viewer
// endpoint (see SPKStoryViewersFetcher) and opens a searchable/filterable sheet.
//
// The entry point is a magnifying-glass button pinned to the trailing edge of
// the "Who viewed this story" section header (an IGLabelSupplementaryView),
// vertically in line with the trash / reply buttons on the right. Living inside
// that header keeps it native and scrolls it with the list instead of floating
// over the viewer rows. We scope the injection to headers whose enclosing VC is
// an IGStoryViewersListViewController and keep a single button per VC.

static char kSPKSearchButtonKey;

@interface IGStoryViewersListViewController (SPKSearchViewerList)
- (void)spk_openViewerSearch;
@end

@interface IGLabelSupplementaryView (SPKSearchViewerList)
- (void)spk_maybeAddViewerSearchButton;
@end

static inline BOOL SPKSearchViewerListEnabled(void) {
    return [SPKUtils getBoolPref:@"stories_search_viewer_list"];
}

// Walks the responder chain from a view up to its enclosing viewers-list VC.
static UIViewController *SPKViewersListVCForView(UIView *view) {
    UIResponder *responder = view;
    NSInteger hops = 0;
    while (responder && hops++ < 30) {
        if ([responder isKindOfClass:%c(IGStoryViewersListViewController)])
            return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

// Resolves the numeric media pk (no `_userid` suffix) from a story item object.
static NSString *SPKViewerMediaIDFromItem(id item) {
    if (!item)
        return nil;
    NSArray *hosts = @[ item ];
    @try {
        for (NSString *nested in @[ @"media", @"storyItem", @"item" ]) {
            if ([item respondsToSelector:NSSelectorFromString(nested)]) {
                id sub = [item valueForKey:nested];
                if (sub)
                    hosts = [hosts arrayByAddingObject:sub];
            }
        }
    } @catch (__unused NSException *e) {
    }
    for (id host in hosts) {
        for (NSString *sel in @[ @"pk", @"mediaID", @"mediaId", @"id", @"mediaIdentifier" ]) {
            @try {
                if (![host respondsToSelector:NSSelectorFromString(sel)])
                    continue;
                id value = [host valueForKey:sel];
                NSString *str = nil;
                if ([value isKindOfClass:[NSString class]])
                    str = value;
                else if ([value respondsToSelector:@selector(stringValue)])
                    str = [value stringValue];
                if (str.length > 0)
                    return [str componentsSeparatedByString:@"_"].firstObject ?: str;
            } @catch (__unused NSException *e) {
            }
        }
    }
    return nil;
}

// Returns YES when any visible control other than `ignored` lives under `view`.
static BOOL SPKViewHasVisibleControl(UIView *view, UIView *ignored, NSInteger depth) {
    for (UIView *sub in view.subviews) {
        if (sub == ignored || sub.hidden || sub.alpha < 0.01)
            continue;
        if ([sub isKindOfClass:[UIControl class]] && sub.userInteractionEnabled)
            return YES;
        if (depth < 4 && SPKViewHasVisibleControl(sub, ignored, depth + 1))
            return YES;
    }
    return NO;
}

// The viewers list can show several label headers (comments, replies, viewers).
// Only the viewer header is a bare title; the others carry a trailing accessory
// such as "See all". Detect that structurally so the check does not depend on
// localized header text.
static BOOL SPKHeaderCanHostSearchButton(UIView *header, UIView *button) {
    @try {
        UIView *rightView = [header valueForKey:@"_rightView"];
        if ([rightView isKindOfClass:[UIView class]] && rightView != button && !rightView.hidden && rightView.alpha > 0.01 &&
            rightView.superview)
            return NO;
    } @catch (__unused NSException *e) {
    }
    return !SPKViewHasVisibleControl(header, button, 0);
}

%group SPKSearchViewerListHooks

%hook IGLabelSupplementaryView

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"SearchStoryViewers.layoutSubviews");
    if (!SPKSearchViewerListEnabled())
        return;
    [self spk_maybeAddViewerSearchButton];
}

%new
- (void)spk_maybeAddViewerSearchButton {
    UIViewController *vc = SPKViewersListVCForView(self);
    if (!vc)
        return; // not a story viewer list header

    SPKChromeButton *button = objc_getAssociatedObject(vc, &kSPKSearchButtonKey);
    if (!SPKHeaderCanHostSearchButton(self, button)) {
        // A header with its own trailing control (the comments section's
        // "See all") would sit under the glyph. Evict the button if a reused
        // header turned into one of those.
        if (button.superview == self) {
            [button removeFromSuperview];
            SPKLog(@"ViewerSearch", @"[Sparkle] Moved search button off a header with its own accessory");
        }
        return;
    }
    if (button.superview && button.superview != self && button.window)
        return; // already placed on another eligible header

    if (!button) {
        // SPKChromeButton keeps the glyph inside a secure canvas so it stays
        // visible/tappable normally but is redacted from screenshots/recordings
        // when "Hide UI on Capture" is on (same primitive as the seen buttons).
        button = [[SPKChromeButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:44.0];
        button.bubbleColor = UIColor.clearColor;
        button.iconTint = [SPKUtils SPKColor_InstagramPrimaryText];
        UIImage *icon = [SPKAssetUtils instagramIconNamed:@"search" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate]
                            ?: [UIImage systemImageNamed:@"magnifyingglass"];
        button.iconView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        // Box sits flush to the trailing edge; nudge the glyph in so it lines up
        // with the trash / reply column instead of hugging the screen edge.
        button.iconOffset = UIOffsetMake(-6.0, 0.0);
        button.accessibilityLabel = SPKL(@"STORIES_SEARCH_STORY_VIEWERS_SEARCH_VIEWERS_TEXT");
        [button addTarget:vc action:@selector(spk_openViewerSearch) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(vc, &kSPKSearchButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // The header lays out with frames and we run inside its layoutSubviews, so
    // constraints added here would not resolve until some later layout pass (the
    // glyph sat at the top-left until a screenshot or tap forced one). Position
    // the button by frame on every pass instead: flush to the trailing edge and
    // vertically centered with the right-hand button column.
    if (button.superview != self) {
        [self addSubview:button];
        SPKLog(@"ViewerSearch", @"[Sparkle] Pinned search button to viewers header");
    }
    button.translatesAutoresizingMaskIntoConstraints = YES;
    CGRect bounds = self.bounds;
    button.frame = CGRectMake(CGRectGetMaxX(bounds) - 44.0, CGRectGetMidY(bounds) - 22.0, 44.0, 44.0);
    [self bringSubviewToFront:button];
}

%end

%hook IGStoryViewersListViewController

%new
- (void)spk_openViewerSearch {
    id item = nil;
    @try {
        item = [self valueForKey:@"item"]; // maps to the _item ivar
    } @catch (__unused NSException *e) {
    }
    NSString *mediaID = SPKViewerMediaIDFromItem(item);
    if (mediaID.length == 0) {
        SPKLog(@"ViewerSearch", @"[Sparkle] Could not resolve media id from viewer list item");
        return;
    }
    [SPKStoryViewersSearchViewController presentForMediaID:mediaID title:SPKL(@"STORIES_SEARCH_STORY_VIEWERS_STORY_VIEWERS_TEXT")];
}

%end

%end

void SPKInstallSearchStoryViewersHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKSearchViewerListHooks);
    });
}
