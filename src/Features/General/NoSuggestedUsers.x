#import "../../InstagramHeaders.h"
#import "../../Utils.h"

FOUNDATION_EXPORT BOOL SPKProfileSuggestionsShouldDropChainingModel(id header, id model);

static inline BOOL SPKHideFeedSuggestedUsers(void) {
    return [SPKUtils getBoolPref:@"general_hide_suggested_users_feed"];
}

static inline BOOL SPKHideProfileSuggestedUsers(void) {
    return [SPKUtils getBoolPref:@"general_hide_suggested_users_profile"];
}

static inline BOOL SPKHideActivitySuggestedUsers(void) {
    return [SPKUtils getBoolPref:@"general_hide_suggested_users_activity"];
}

static inline BOOL SPKHideFollowListSuggestedUsers(void) {
    return [SPKUtils getBoolPref:@"general_hide_suggested_users_follow_lists"];
}

static inline BOOL SPKHideSubscriptionSuggestedUsers(void) {
    return [SPKUtils getBoolPref:@"general_hide_suggested_users_subscriptions"];
}

%group SPKNoSuggestedUsersHooks

// "Welcome to instagram" suggested users in feed
%hook IGSuggestedUnitViewModel
- (id)initWithAYMFModel:(id)arg1 headerViewModel:(id)arg2 {
    if (SPKHideFeedSuggestedUsers()) {
        SPKLog(@"General", @"[Sparkle] Hiding suggested users: main feed welcome section");

        return nil;
    }

    return %orig;
}
%end

%hook IGSuggestionsUnitViewModel
- (id)initWithAYMFModel:(id)arg1 headerViewModel:(id)arg2 {
    if (SPKHideFeedSuggestedUsers()) {
        SPKLog(@"General", @"[Sparkle] Hiding suggested users: main feed welcome section");

        return nil;
    }

    return %orig;
}
%end

// Suggested users in profile header
%hook IGProfileHeaderView
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if ([obj isKindOfClass:%c(IGProfileChainingModel)] && SPKProfileSuggestionsShouldDropChainingModel(self, obj)) {
            SPKLog(@"General", @"[Sparkle] Hiding suggested users: profile header");

            shouldHide = YES;
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

// Notifications/activity feed
%hook IGActivityFeedViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Section header
        if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {
            // Suggested for you
            if ([[obj valueForKey:@"tag"] intValue] == 2) { // 2 == Suggested Users
                if (SPKHideActivitySuggestedUsers()) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested users (header: activity feed)");

                    shouldHide = YES;
                }
            }
        }

        // Suggested user
        else if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)]) {
            if (SPKHideActivitySuggestedUsers()) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: (user: activity feed)");

                shouldHide = YES;
            }
        }

        // "See all" button
        else if ([obj isKindOfClass:%c(IGSeeAllItemConfiguration)]) {
            if (SPKHideActivitySuggestedUsers()) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: (see all: activity feed)");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

// Profile "following" and "followers" tabs
%hook IGFollowListViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig(arg1);
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (IGStoryTrayViewModel *obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideFollowListSuggestedUsers()) {

            // Suggested user
            if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: follow list suggested user");

                shouldHide = YES;
            }

            // Section header
            else if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {

                // "Suggested for you" search results header
                if ([[obj valueForKey:@"labelTitle"] isEqualToString:@"Suggested for you"]) {
                    shouldHide = YES;
                }

            }

            // See all suggested users
            else if ([obj isKindOfClass:%c(IGSeeAllItemConfiguration)] && ((IGSeeAllItemConfiguration *)obj).destination == 4) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: follow list suggested user");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

%hook IGSegmentedTabControl
- (void)setSegments:(id)segments {
    NSArray *originalObjs = segments;
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (IGStoryTrayViewModel *obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideFollowListSuggestedUsers()) {
            if ([obj isKindOfClass:%c(IGFindUsersViewController)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: find users segmented tab");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return %orig([filteredObjs copy]);
}
%end

// Suggested subscriptions
%hook IGFanClubSuggestedUsersDataSource
- (id)initWithUserSession:(id)arg1 delegate:(id)arg2 {
    if (SPKHideSubscriptionSuggestedUsers()) {
        return nil;
    }

    return %orig(arg1, arg2);
}
%end

// Follow request/discover section (accessed through notifications page)
// Demangled name: IGFriendingCenter.IGFriendingCenterViewController
%hook _TtC17IGFriendingCenter31IGFriendingCenterViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig(arg1);
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (IGStoryTrayViewModel *obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideActivitySuggestedUsers()) {

            // Suggested user
            if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: follow list suggested user");

                shouldHide = YES;
            }

            // Section header
            else if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {

                // "Suggested for you" search results header
                if ([[obj valueForKey:@"labelTitle"] isEqualToString:@"Suggested for you"]) {
                    shouldHide = YES;
                }
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

%end

void SPKInstallNoSuggestedUsersHooksIfEnabled(void) {
    if (!SPKHideFeedSuggestedUsers() &&
        !SPKHideProfileSuggestedUsers() &&
        !SPKHideActivitySuggestedUsers() &&
        !SPKHideFollowListSuggestedUsers() &&
        !SPKHideSubscriptionSuggestedUsers()) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKNoSuggestedUsersHooks,
                       IGSuggestionsUnitViewModel = SPKResolveIGClass(@"IGSuggestionsUnit.IGSuggestionsUnitViewModel", @"IGSuggestionsUnitViewModel"),
                       IGProfileHeaderView = SPKResolveIGClass(@"IGProfileHeader.IGProfileHeaderView", @"IGProfileHeaderView"));
    });
}
