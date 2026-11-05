// Following feed mode, adapted from InstaSane by Edoardo (@n3d1117).
// https://github.com/n3d1117/InstaSane

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"

// IGHomeFeedPickerMenuItem enum value (stable across 410→436).
static NSInteger const IGHomeFeedPickerMenuItemFollowing = 5;

static BOOL SPKFollowingFeedEnabled(void) {
    return [[SPKUtils getStringPref:@"feed_mode"] isEqualToString:@"following"];
}

// IGUserSession's Following feed model accessor was renamed between versions:
// `_followingMainFeedViewModel` (≤436) → `followingLaneMainFeedViewModel` (454).
// Messaging the missing one raises an unrecognized-selector crash, so probe first.
static id SPKFollowingMainFeedViewModel(id session) {
    static SEL const candidates[] = {
        @selector(followingLaneMainFeedViewModel),
        @selector(_followingMainFeedViewModel),
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if ([session respondsToSelector:candidates[i]])
            return ((id (*)(id, SEL))objc_msgSend)(session, candidates[i]);
    }
    return nil;
}

static void SPKForceFollowingPagination(NSString **paginationSource, BOOL *isInFollowingTab) {
    if (!SPKFollowingFeedEnabled())
        return;
    *paginationSource = @"following";
    if (isInFollowingTab)
        *isInFollowingTab = YES;
}

%group SPKFollowingFeedHooks

#pragma mark - Picker dropdown order

%hook IGHomeFeedPickerMenuController

- (id)initWithUserSession:(id)userSession
                     menuItems:(NSArray *)menuItems
             homeFeedViewModel:(id)homeViewModel
               analyticsModule:(id)analyticsModule
          navigationController:(id)navigationController
    isForYouContentLaneEnabled:(BOOL)forYouEnabled {
    if (!SPKFollowingFeedEnabled() || ![menuItems isKindOfClass:[NSArray class]])
        return %orig;
    // Surface "Following" at the top of the picker dropdown.
    NSMutableArray *items = menuItems.mutableCopy;
    [items removeObject:@(IGHomeFeedPickerMenuItemFollowing)];
    [items insertObject:@(IGHomeFeedPickerMenuItemFollowing) atIndex:0];
    return %orig(userSession, items, homeViewModel, analyticsModule, navigationController, forYouEnabled);
}

%end

#pragma mark - Selected feed (drives the model used for the main surface)

%hook IGUserSession

- (id)selectedMainFeedViewModel {
    if (SPKFollowingFeedEnabled()) {
        id following = SPKFollowingMainFeedViewModel(self);
        if (following)
            return following;
    }
    return %orig;
}

%end

#pragma mark - Content forcing

%hook IGDSAGatingManager

// Persisted "preferred content lane" (EU DSA): returning 1 = Following. Kept for
// versions/paths that read it (not always called on 436).
- (NSInteger)feedStickyContentLaneSelection {
    if (!SPKFollowingFeedEnabled())
        return %orig;
    return 1;
}

%end

%hook IGMainFeedViewModel

- (id)initWithDeps:(id)deps
                                       posts:(id)posts
                                   nextMaxID:(id)nextMaxID
                     initialPaginationSource:(NSString *)paginationSource
                          contentCoordinator:(id)coordinator
        dataSourceSupplementaryItemsProvider:(id)supplementaryProvider
                     disableAutomaticRefresh:(BOOL)disableRefresh
                        disableSerialization:(BOOL)disableSerialization
                                   sessionId:(id)sessionId
                             analyticsModule:(id)analyticsModule
                         disableFlashFeedTLI:(BOOL)disableFlashFeedTLI
                 disableFlashFeedOnColdStart:(BOOL)disableColdStart
                     disableResponseDeferral:(BOOL)disableResponseDeferral
                            hidesStoriesTray:(BOOL)hidesStoriesTray
           shouldRegisterAsStoryDataListener:(BOOL)shouldRegisterAsStoryDataListener
                             isSecondaryFeed:(BOOL)isSecondaryFeed
       collectionViewBackgroundColorOverride:(id)backgroundColor
                   minWarmStartFetchInterval:(double)minWarmStart
               peakMinWarmStartFetchInterval:(double)peakMinWarmStart
        minimumWarmStartBackgroundedInterval:(double)backgroundedMinWarmStart
    peakMinimumWarmStartBackgroundedInterval:(double)peakBackgroundedMinWarmStart
              supplementalFeedHoistedMediaID:(id)hoistedMediaId
                         headerTitleOverride:(id)headerTitle
                            isInFollowingTab:(BOOL)isInFollowingTab
          useShimmerLoadingWhenNoStoriesTray:(BOOL)useShimmer
                         mainFeedDataFetcher:(id)dataFetcher {
    SPKForceFollowingPagination(&paginationSource, &isInFollowingTab);
    return %orig;
}

// 454 appended backgroundPrefetchStore:; the selector above no longer exists there.
- (id)initWithDeps:(id)deps
                                       posts:(id)posts
                                   nextMaxID:(id)nextMaxID
                     initialPaginationSource:(NSString *)paginationSource
                          contentCoordinator:(id)coordinator
        dataSourceSupplementaryItemsProvider:(id)supplementaryProvider
                     disableAutomaticRefresh:(BOOL)disableRefresh
                        disableSerialization:(BOOL)disableSerialization
                                   sessionId:(id)sessionId
                             analyticsModule:(id)analyticsModule
                         disableFlashFeedTLI:(BOOL)disableFlashFeedTLI
                 disableFlashFeedOnColdStart:(BOOL)disableColdStart
                     disableResponseDeferral:(BOOL)disableResponseDeferral
                            hidesStoriesTray:(BOOL)hidesStoriesTray
           shouldRegisterAsStoryDataListener:(BOOL)shouldRegisterAsStoryDataListener
                             isSecondaryFeed:(BOOL)isSecondaryFeed
       collectionViewBackgroundColorOverride:(id)backgroundColor
                   minWarmStartFetchInterval:(double)minWarmStart
               peakMinWarmStartFetchInterval:(double)peakMinWarmStart
        minimumWarmStartBackgroundedInterval:(double)backgroundedMinWarmStart
    peakMinimumWarmStartBackgroundedInterval:(double)peakBackgroundedMinWarmStart
              supplementalFeedHoistedMediaID:(id)hoistedMediaId
                         headerTitleOverride:(id)headerTitle
                            isInFollowingTab:(BOOL)isInFollowingTab
          useShimmerLoadingWhenNoStoriesTray:(BOOL)useShimmer
                         mainFeedDataFetcher:(id)dataFetcher
                     backgroundPrefetchStore:(id)prefetchStore {
    SPKForceFollowingPagination(&paginationSource, &isInFollowingTab);
    return %orig;
}

%end

// IGMainFeedNetworkSource lost its instance methods in 436 (refactored to Swift);
// these only install on 410/428 and no-op elsewhere. Kept for back-compat.
%hook IGMainFeedNetworkSource

- (id)initWithPosts:(id)posts
                           nextMaxID:(id)nextMaxID
             initialPaginationSource:(NSString *)paginationSource
                           fetchPath:(id)fetchPath
                      responseParser:(id)responseParser
    mainFeedNetworkSourceSessionDeps:(id)deps
                      sessionTracker:(id)sessionTracker
                     analyticsModule:(id)analyticsModule
                       useNewUIGraph:(BOOL)useNewGraph {
    SPKForceFollowingPagination(&paginationSource, NULL);
    return %orig;
}

// 454 form: extra trailing BOOL.
- (id)initWithPosts:(id)posts
                               nextMaxID:(id)nextMaxID
                 initialPaginationSource:(NSString *)paginationSource
                               fetchPath:(id)fetchPath
                          responseParser:(id)responseParser
        mainFeedNetworkSourceSessionDeps:(id)deps
                          sessionTracker:(id)sessionTracker
                         analyticsModule:(id)analyticsModule
                           useNewUIGraph:(BOOL)useNewGraph
    isDeclarativeMediaConsumptionEnabled:(BOOL)declarativeMediaConsumption {
    SPKForceFollowingPagination(&paginationSource, NULL);
    return %orig;
}

- (void)updatePaginationSource:(id)paginationSource nextMaxID:(id)nextMaxID {
    if (SPKFollowingFeedEnabled())
        return %orig(@"following", nextMaxID);
    %orig;
}

// 454 renamed the updater to a private underscore form.
- (void)_updatePaginationSource:(id)paginationSource nextMaxID:(id)nextMaxID {
    if (SPKFollowingFeedEnabled())
        return %orig(@"following", nextMaxID);
    %orig;
}

%end

%hook IGMainFeedRequestConfigFactory

// When the pagination source is "following", use reason 3 so cold starts pull
// the chronological Following feed.
- (id)generateHeadLoadRequestConfigWithReason:(NSInteger)reason
                                 trackingWith:(id)tracking
                           cancelOngoingFetch:(BOOL)cancel
                               hoistedMediaID:(id)hoistedMediaID
                        hoistedMediaShortcode:(id)shortcode
                                  deeplinkURL:(id)deeplinkURL
                             isNonFeedSurface:(BOOL)isNonFeedSurface
                             additionalParams:(id)params
                                prewarmConfig:(id)prewarmConfig
                              containerModule:(id)containerModule
                             paginationSource:(id)paginationSource
                          secondaryFeedFilter:(id)secondaryFeedFilter
                                  vpvdSeenIds:(id)seenIds {
    if (SPKFollowingFeedEnabled() && [paginationSource isEqual:@"following"]) {
        reason = 3;
    }
    return %orig;
}

%end

// IG's Following feed shrinks the home story-tray avatars (module
// "feed_timeline_following", adjustment 10.0 vs For-You's). Restore the larger
// sizing, gated to the home-feed module so profile highlights ("self_profile")
// and other trays that share IGStoryTrayCellViewModel are left untouched.
%hook IGStoryTrayCellViewModel

- (double)avatarSizeAdjustment {
    if (SPKFollowingFeedEnabled()) {
        NSString *module = ((NSString * (*)(id, SEL)) objc_msgSend)(self, @selector(module));
        if ([module isKindOfClass:[NSString class]] && [module hasPrefix:@"feed_timeline"]) {
            return 28.5;
        }
    }
    return %orig;
}

%end

%end

extern "C" void SPKInstallFollowingFeedHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class picker = SPKResolveIGClass(@"IGHomeFeedPicker.IGHomeFeedPickerMenuController", @"IGHomeFeedPickerMenuController");
        Class dsa = SPKResolveIGClass(@"IGDSAShared.IGDSAGatingManager", @"IGDSAGatingManager");
        Class factory = SPKResolveIGClass(@"IGMainFeedDataFetcherKit.IGMainFeedRequestConfigFactory", @"IGMainFeedRequestConfigFactory");
        Class tray = SPKResolveIGClass(@"IGStoryTrayUIModels.IGStoryTrayCellViewModel", @"IGStoryTrayCellViewModel");

        SPKLog(@"FollowingFeed", @"installing hooks — picker=%@ dsa=%@ factory=%@ tray=%@ session=%@ viewModel=%@",
               picker ? @"OK" : @"NIL", dsa ? @"OK" : @"NIL", factory ? @"OK" : @"NIL",
               tray ? @"OK" : @"NIL",
               objc_getClass("IGUserSession") ? @"OK" : @"NIL",
               objc_getClass("IGMainFeedViewModel") ? @"OK" : @"NIL");

        %init(SPKFollowingFeedHooks,
                       IGHomeFeedPickerMenuController = picker,
                       IGDSAGatingManager = dsa,
                       IGMainFeedRequestConfigFactory = factory,
                       IGStoryTrayCellViewModel = tray);
    });
}
