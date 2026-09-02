#import "SPKStrings.h"
#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SPKFeedFilterSurface) {
    SPKFeedFilterSurfaceFeed,
    SPKFeedFilterSurfaceReels,
    SPKFeedFilterSurfaceExplore,
    SPKFeedFilterSurfaceOther,
};

static BOOL SPKShouldHideAdsForSurface(SPKFeedFilterSurface surface) {
    switch (surface) {
    case SPKFeedFilterSurfaceFeed:
    case SPKFeedFilterSurfaceOther:
        return [SPKUtils getBoolPref:@"general_hide_ads_feed"];
    case SPKFeedFilterSurfaceReels:
        return [SPKUtils getBoolPref:@"general_hide_ads_reels"];
    case SPKFeedFilterSurfaceExplore:
        return [SPKUtils getBoolPref:@"general_hide_ads_explore"];
    }
    return NO;
}

static BOOL SPKShouldHideSuggestedAccountsForSurface(SPKFeedFilterSurface surface) {
    switch (surface) {
    case SPKFeedFilterSurfaceFeed:
        return [SPKUtils getBoolPref:@"general_hide_suggested_users_feed"];
    case SPKFeedFilterSurfaceReels:
        return [SPKUtils getBoolPref:@"general_hide_suggested_users_reels"];
    case SPKFeedFilterSurfaceExplore:
    case SPKFeedFilterSurfaceOther:
        return NO;
    }
    return NO;
}

static BOOL SPKShouldHideStoryAds(void) {
    return [SPKUtils getBoolPref:@"general_hide_ads_stories"];
}

// IG 436+ moved this model into the IGInFeedStories Swift module (mangled runtime
// name), so a bare %c() resolves to nil. Resolve across versions, cached.
static Class SPKInFeedStoriesTrayModelClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = SPKResolveIGClass(@"IGInFeedStories.IGInFeedStoriesTrayModel", @"IGInFeedStoriesTrayModel");
    });
    return cls;
}

static void SPKStoryAdBlockingLogClassAvailability(void) {
    for (NSString *className in @[
             @"IGStoryAdPool",
             @"IGStoryAdsManager",
             @"IGStoryAdsFetcher",
             @"IGStoryAdsResponseParser",
             @"IGStoryAdsOptInTextView"
         ]) {
        SPKLog(@"Ads", @"Story ad hook target %@ %@", className, NSClassFromString(className) ? @"available" : @"missing");
    }
}

static NSArray *removeItemsInList(NSArray *list, SPKFeedFilterSurface surface) {
    BOOL isFeed = surface == SPKFeedFilterSurfaceFeed;
    NSArray *originalObjs = list;
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        // Remove suggested posts
        if (isFeed && [SPKUtils getBoolPref:@"feed_hide_suggested_posts"]) {

            // Posts
            if (
                ([obj isKindOfClass:%c(IGMedia)] && [((IGMedia *)obj).explorePostInFeed isEqual:@YES]) || ([obj isKindOfClass:%c(IGFeedGroupHeaderViewModel)] && [[obj title] isEqualToString:@"Suggested Posts"])) {
                SPKLog(@"General", @"[Sparkle] Removing suggested posts");

                continue;
            }

            // Suggested stories (carousel)
            if ([obj isKindOfClass:SPKInFeedStoriesTrayModelClass()]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested stories carousel");

                continue;
            }
        }

        // Remove suggested reels (carousel)
        if (isFeed && [SPKUtils getBoolPref:@"feed_hide_suggested_reels"]) {
            if ([obj isKindOfClass:%c(IGFeedScrollableClipsModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested reels carousel");

                continue;
            }
        }

        // Remove suggested for you (accounts)
        if (SPKShouldHideSuggestedAccountsForSurface(surface)) {

            // Feed
            if (isFeed && [obj isKindOfClass:%c(IGHScrollAYMFModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding accounts suggested for you (feed)");

                continue;
            }

            // Reels
            if ([obj isKindOfClass:%c(IGSuggestedUserInReelsModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding accounts suggested for you (reels)");

                continue;
            }
        }

        // Remove suggested threads posts
        if ([SPKUtils getBoolPref:@"feed_hide_suggested_threads"]) {

            // Feed (carousel)
            if (isFeed) {
                if ([obj isKindOfClass:%c(IGBloksFeedUnitModel)] || [obj isKindOfClass:objc_getClass("IGThreadsInFeedModels.IGThreadsInFeedModel")]) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested threads posts (carousel)");

                    continue;
                }
            }

            // Reels
            if ([obj isKindOfClass:%c(IGSundialNetegoItem)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested threads posts (reels)");

                continue;
            }
        }

        // Remove story tray
        if (isFeed && [SPKUtils getBoolPref:@"feed_hide_stories_tray"]) {
            if ([obj isKindOfClass:%c(IGStoryDataController)]) {
                SPKLog(@"General", @"[Sparkle] Hiding stories tray");

                continue;
            }
        }

        // Hide entire feed
        if (isFeed && [SPKUtils getBoolPref:@"feed_hide_entire_feed"]) {
            if ([obj isKindOfClass:%c(IGPostCreationManager)] || [obj isKindOfClass:%c(IGMedia)] || [obj isKindOfClass:%c(IGEndOfFeedDemarcatorModel)] || [obj isKindOfClass:%c(IGSpinnerLabelViewModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding entire feed");

                continue;
            }
        }

        // Remove ads
        if (SPKShouldHideAdsForSurface(surface)) {
            if (
                ([obj isKindOfClass:%c(IGFeedItem)] && ([obj isSponsored] || [obj isSponsoredApp])) || ([obj isKindOfClass:%c(IGDiscoveryGridItem)] && [[obj model] isKindOfClass:%c(IGAdItem)]) || [obj isKindOfClass:%c(IGAdItem)]) {
                SPKLog(@"General", @"[Sparkle] Removing ads");

                continue;
            }
        }

        [filteredObjs addObject:obj];
    }

    return [filteredObjs copy];
}

%group SPKFeedFilteringHooks

// Suggested posts/reels
%hook IGMainFeedListAdapterDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    // Preserve native loading items even when the feed is initially empty or short.
    return removeItemsInList(%orig, SPKFeedFilterSurfaceFeed);
}
%end

%end

%group SPKFeedFilteringDeferredHooks

static id SPKSundialObjectIvar(id object, const char *name) {
    if (!object || !name)
        return nil;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar)
            return object_getIvar(object, ivar);
    }

    return nil;
}

static BOOL SPKSundialBoolForSelector(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector])
        return NO;

    IMP implementation = [object methodForSelector:selector];
    return implementation ? ((BOOL (*)(id, SEL))implementation)(object, selector) : NO;
}

static BOOL SPKSundialIsReelsHomeOrTab(id dataSource) {
    id networkSource = SPKSundialObjectIvar(dataSource, "_networkSource");

    if (!networkSource) {
        id context = SPKSundialObjectIvar(dataSource, "context");
        if (!context)
            context = SPKSundialObjectIvar(dataSource, "_context");

        if ([context respondsToSelector:@selector(networkSource)]) {
            IMP implementation = [context methodForSelector:@selector(networkSource)];
            if (implementation)
                networkSource = ((id (*)(id, SEL))implementation)(context, @selector(networkSource));
        }
    }

    return SPKSundialBoolForSelector(networkSource, @selector(isReelsHomeOrTab));
}

static NSArray *spkSundialFilterAndLimit(NSArray *list, id dataSource) {
    NSArray *filteredList = removeItemsInList(list, SPKFeedFilterSurfaceReels);

    if ([SPKUtils getBoolPref:@"reels_prevent_doom_scroll"] && SPKSundialIsReelsHomeOrTab(dataSource)) {
        NSUInteger reelCount = (NSUInteger)[SPKUtils getDoublePref:@"reels_doom_scroll_limit"];
        return [filteredList subarrayWithRange:NSMakeRange(0, MIN(reelCount, filteredList.count))];
    }

    return filteredList;
}

%hook IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    return spkSundialFilterAndLimit(%orig, self);
}
%end

// Demangled name: IGSundialFeed.IGSundialFeedDataSource (IG <= 433)
%hook _TtC13IGSundialFeed23IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    return spkSundialFilterAndLimit(%orig, self);
}
%end

// Demangled name: IGSundialFeedDataSource.IGSundialFeedDataSource (IG 434+, class moved module)
%hook _TtC23IGSundialFeedDataSource23IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    return spkSundialFilterAndLimit(%orig, self);
}
%end

%end

%group SPKAdBlockingEarlyHooks

%hook IGContextualFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_feed"]) {
        return removeItemsInList(%orig, SPKFeedFilterSurfaceOther);
    }

    return %orig;
}
%end
%hook IGVideoFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_feed"]) {
        return removeItemsInList(%orig, SPKFeedFilterSurfaceOther);
    }

    return %orig;
}
%end
%hook IGChainingFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_feed"]) {
        return removeItemsInList(%orig, SPKFeedFilterSurfaceOther);
    }

    return %orig;
}
%end
%hook IGSundialAdsResponseParser
- (id)parsedObjectFromResponse:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_reels"]) {
        SPKLog(@"General", @"[Sparkle] Removing ads");

        return nil;
    }

    return %orig;
}
- (id)initWithMediaStore:(id)arg1 userStore:(id)arg2 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_reels"]) {
        SPKLog(@"General", @"[Sparkle] Removing ads");

        return nil;
    }

    return %orig;
}
%end
// "Sponsored" posts on discover/search page
%hook IGExploreListKitDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_explore"]) {
        return removeItemsInList(%orig, SPKFeedFilterSurfaceExplore);
    }

    return %orig;
}
%end
// Demangled name: IGExploreViewControllerSwift.IGExploreListKitDataSource
%hook _TtC28IGExploreViewControllerSwift26IGExploreListKitDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_ads_explore"]) {
        return removeItemsInList(%orig, SPKFeedFilterSurfaceExplore);
    }

    return %orig;
}
%end

// Hide shopping carousel in reel comments
// Demangled name: IGCommentThreadCommerceCarouselPill.IGCommentThreadCommerceCarousel
%hook _TtC35IGCommentThreadCommerceCarouselPill31IGCommentThreadCommerceCarousel
- (id)initWithFrame:(CGRect)frame pillText:(id)text pillStyle:(NSInteger)style {
    if ([SPKUtils getBoolPref:@"general_comments_hide_shopping"]) {
        return nil;
    }

    return %orig(frame, text, style);
}
%end

// Hide suggested search/shopping on reels

// Demangled name: IGShoppableEverythingCommon.IGRapEntrypointResolver
%hook _TtC27IGShoppableEverythingCommon23IGRapEntrypointResolver
- (id)initWithLauncherSet:(id)arg1 {
    if ([SPKUtils getBoolPref:@"general_hide_reels_shopping_cta"]) {
        return nil;
    }

    return %orig(arg1);
}
%end
// Demangled name: IGSundialOrganicCTAContainerView.IGSundialOrganicCTAContainerView
%hook _TtC32IGSundialOrganicCTAContainerView32IGSundialOrganicCTAContainerView
- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"HideFeedItems.didMoveToWindow");

    if ([SPKUtils getBoolPref:@"general_hide_reels_shopping_cta"]) {
        [self removeFromSuperview];
    }
}
%end

%end

%group SPKStoryAdBlockingHooks

%hook IGStoryAdPool
- (id)initWithUserSession:(id)arg1 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdPool initWithUserSession:");
        return nil;
    }

    return %orig;
}
%end

%hook IGStoryAdsManager
- (id)initWithUserSession:(id)arg1 storyViewerLoggingContext:(id)arg2 storyFullscreenSectionLoggingContext:(id)arg3 viewController:(id)arg4 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdsManager initWithUserSession:storyViewerLoggingContext:storyFullscreenSectionLoggingContext:viewController:");
        return nil;
    }

    return %orig;
}
%end

%hook IGStoryAdsFetcher
- (id)initWithUserSession:(id)arg1 delegate:(id)arg2 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdsFetcher initWithUserSession:delegate:");
        return nil;
    }

    return %orig;
}
%end

// IG 148.0
%hook IGStoryAdsResponseParser
- (id)parsedObjectFromResponse:(id)arg1 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdsResponseParser parsedObjectFromResponse:");
        return nil;
    }

    return %orig;
}
- (id)initWithReelStore:(id)arg1 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdsResponseParser initWithReelStore:");
        return nil;
    }

    return %orig;
}
%end

%hook IGStoryAdsOptInTextView
- (id)initWithBrandedContentStyledString:(id)arg1 sponsoredPostLabel:(id)arg2 {
    if (SPKShouldHideStoryAds()) {
        SPKLog(@"Ads", @"Story ad hook fired: IGStoryAdsOptInTextView initWithBrandedContentStyledString:sponsoredPostLabel:");
        return nil;
    }

    return %orig;
}
%end

%end

%group SPKFeedEndDemarcatorHooks

// Hide "suggested for you" text at end of feed
%hook IGEndOfFeedDemarcatorCellTopOfFeed
- (void)configureWithViewConfig:(id)arg1 {
    %orig;

    if ([SPKUtils getBoolPref:@"feed_hide_suggested_posts"]) {
        SPKLog(@"General", @"[Sparkle] Hiding end of feed message");

        // Hide suggested for you text
        UILabel *_titleLabel = MSHookIvar<UILabel *>(self, "_titleLabel");

        if (_titleLabel != nil) {
            [_titleLabel setText:@""];
        }
    }

    return;
}
%end

%end

static BOOL SPKAnyFeedFilteringPrefEnabled(void) {
    for (NSString *key in @[
             @"general_hide_ads_feed",
             @"general_hide_ads_reels",
             @"general_hide_ads_explore",
             @"feed_hide_suggested_posts",
             @"feed_hide_suggested_reels",
             @"general_hide_suggested_users_feed",
             @"general_hide_suggested_users_reels",
             @"feed_hide_suggested_threads",
             @"feed_hide_stories_tray",
             @"feed_hide_entire_feed",
             @"reels_prevent_doom_scroll"
         ]) {
        if ([SPKUtils getBoolPref:key]) {
            return YES;
        }
    }

    return NO;
}

extern "C" void SPKInstallFeedFilteringFeedHooksIfEnabled(void) {
    if (!SPKAnyFeedFilteringPrefEnabled()) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKFeedFilteringHooks);
    });
}

extern "C" void SPKInstallFeedFilteringHooksIfEnabled(void) {
    if (!SPKAnyFeedFilteringPrefEnabled()) {
        return;
    }

    SPKInstallFeedFilteringFeedHooksIfEnabled();

    static dispatch_once_t deferredOnceToken;
    dispatch_once(&deferredOnceToken, ^{
        %init(SPKFeedFilteringDeferredHooks);
        %init(SPKFeedEndDemarcatorHooks);
    });
}

extern "C" void SPKInstallAdBlockingEarlyHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"general_hide_ads_feed"] &&
        ![SPKUtils getBoolPref:@"general_hide_ads_reels"] &&
        ![SPKUtils getBoolPref:@"general_hide_ads_explore"] &&
        ![SPKUtils getBoolPref:@"general_comments_hide_shopping"] &&
        ![SPKUtils getBoolPref:@"general_hide_reels_shopping_cta"]) {
        return;
    }

    static dispatch_once_t earlyAdsOnceToken;
    dispatch_once(&earlyAdsOnceToken, ^{
        %init(SPKAdBlockingEarlyHooks,
                       IGContextualFeedViewController = SPKResolveIGClass(@"IGContextualFeedViewController.IGContextualFeedViewController", @"IGContextualFeedViewController"),
                       IGChainingFeedViewController = SPKResolveIGClass(@"IGPostChainingFeed.IGChainingFeedViewController", @"IGChainingFeedViewController"));
    });
}

extern "C" void SPKInstallStoryAdBlockingHooksIfEnabled(void) {
    if (!SPKShouldHideStoryAds()) {
        return;
    }

    SPKStoryAdBlockingLogClassAvailability();

    static dispatch_once_t storyAdsOnceToken;
    dispatch_once(&storyAdsOnceToken, ^{
        %init(SPKStoryAdBlockingHooks,
                       IGStoryAdsManager = SPKResolveIGClass(@"IGStoryAdsManager.IGStoryAdsManager", @"IGStoryAdsManager"),
                       IGStoryAdsOptInTextView = SPKResolveIGClass(@"IGStoryAdsUI.IGStoryAdsOptInTextView", @"IGStoryAdsOptInTextView"));
    });
}
