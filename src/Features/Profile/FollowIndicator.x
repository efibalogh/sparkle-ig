#import "SPKStrings.h"
// Shows whether the current profile user follows you.
//
// The badge is rendered from the stat container's own `layoutSubviews` and
// pinned with Auto Layout (leading + bottom), so it tracks IG's header layout
// on every version instead of fighting it with manual frames from the profile
// controller — the latter only held up on iOS 26's scroll-driven collapsing
// header and was flaky on iOS 16.

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import "FollowIndicator.h"
#import <objc/runtime.h>
#import "../../App/SPKPerfMeter.h"

NSNotificationName const SPKFollowIndicatorDidChangeNotification = @"SPKFollowIndicatorDidChangeNotification";

static NSInteger const kSPKFollowBadgeTag = 99788;
static const void *kSPKFollowStatusAssocKey = &kSPKFollowStatusAssocKey;
static const void *kSPKFollowProfilePKAssocKey = &kSPKFollowProfilePKAssocKey;
static const void *kSPKFollowFetchPKAssocKey = &kSPKFollowFetchPKAssocKey;
static const void *kSPKFollowBadgeSpecAssocKey = &kSPKFollowBadgeSpecAssocKey;

// Mode is a string pref ("off" | "text" | "icon" | "icontext"). It is
// intentionally NOT registered with a default so that, until the user picks a
// mode, we can fall back to the legacy on/off bool (`profile_follow_indicator`)
// and preserve the look for people who enabled the indicator before the mode
// menu existed. This fallback works across every pref namespace (global +
// per-account) without a migration write.
static NSString *SPKFollowIndicatorMode(void) {
    NSString *mode = [SPKUtils getStringPref:@"profile_follow_indicator_mode"];
    if (mode.length > 0)
        return mode;
    return [SPKUtils getBoolPref:@"profile_follow_indicator"] ? @"text" : @"off";
}

static BOOL SPKFollowIndicatorEnabled(void) {
    return ![SPKFollowIndicatorMode() isEqualToString:@"off"];
}

static BOOL SPKFollowIndicatorShowsIcon(void) {
    NSString *mode = SPKFollowIndicatorMode();
    return [mode isEqualToString:@"icon"] || [mode isEqualToString:@"icontext"];
}

static BOOL SPKFollowIndicatorShowsText(void) {
    NSString *mode = SPKFollowIndicatorMode();
    return [mode isEqualToString:@"text"] || [mode isEqualToString:@"icontext"];
}

// Colorful (green/red) is off by default: the indicator is native gray unless
// the user opts in. Like the mode key, no default is registered so a never-set
// value can fall back to the legacy bool — anyone who had the indicator enabled
// before this menu existed keeps their original colored look (text + colorful).
static BOOL SPKFollowIndicatorColorful(void) {
    id value = SPKPreferenceObjectForKey(@"profile_follow_indicator_colorful");
    if (value == nil)
        return [SPKUtils getBoolPref:@"profile_follow_indicator"];
    return [value boolValue];
}

// Colored green/red when opted in; otherwise Instagram's native gray for both.
static UIColor *SPKFollowIndicatorColor(BOOL followsYou) {
    if (!SPKFollowIndicatorColorful())
        return [SPKUtils SPKColor_InstagramSecondaryText];
    return followsYou ? [UIColor colorWithRed:0.30 green:0.75 blue:0.40 alpha:1.0]
                      : [UIColor colorWithRed:0.85 green:0.30 blue:0.30 alpha:1.0];
}

// A cached answer is shown immediately but only trusted for this long; after
// that the next profile entry revalidates it in the background. Keeps repeated
// entries off the throttled /friendships/ endpoint without pinning an answer
// for the whole process lifetime.
static NSTimeInterval const kSPKFollowStatusFreshInterval = 60.0;

// "Follows you" is a fact about a (viewer, profile) pair, so the viewing
// account is part of the key: the same profile seen from two accounts must
// never share an answer.
static NSString *SPKFollowStatusKey(NSString *viewerPK, NSString *profilePK) {
    return [NSString stringWithFormat:@"%@|%@", viewerPK, profilePK];
}

// Follow status memoised per (viewer, profile) key, so re-entering a profile
// (or IG recycling the controller) renders at once instead of waiting on the
// network. Fetch times live beside it to age the entries out.
static NSMutableDictionary<NSString *, NSNumber *> *SPKFollowStatusCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSMutableDictionary<NSString *, NSDate *> *SPKFollowStatusFetchDates(void) {
    static NSMutableDictionary *dates;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dates = [NSMutableDictionary dictionary];
    });
    return dates;
}

static BOOL SPKFollowStatusIsFresh(NSString *key) {
    NSDate *fetched = SPKFollowStatusFetchDates()[key];
    return fetched && -fetched.timeIntervalSinceNow < kSPKFollowStatusFreshInterval;
}

// Maps a live profile controller to the stat container it last laid out in, so
// an async status arrival (or a settings change) can nudge that container to
// re-render without walking the view tree. Weak on both sides: the cache keeps
// nothing alive and stale entries zero out.
static NSMapTable *SPKFollowContainerForController(void) {
    static NSMapTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSMapTable weakToWeakObjectsMapTable];
    });
    return table;
}

static NSNumber *SPKGetFollowStatus(id controller) {
    return objc_getAssociatedObject(controller, kSPKFollowStatusAssocKey);
}

static void SPKSetFollowStatus(id controller, NSNumber *status) {
    objc_setAssociatedObject(controller, kSPKFollowStatusAssocKey, status, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *SPKGetFollowProfilePK(id controller) {
    return objc_getAssociatedObject(controller, kSPKFollowProfilePKAssocKey);
}

static void SPKSetFollowProfilePK(id controller, NSString *pk) {
    objc_setAssociatedObject(controller, kSPKFollowProfilePKAssocKey, pk, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSString *SPKGetFollowFetchPK(id controller) {
    return objc_getAssociatedObject(controller, kSPKFollowFetchPKAssocKey);
}

static void SPKSetFollowFetchPK(id controller, NSString *pk) {
    objc_setAssociatedObject(controller, kSPKFollowFetchPKAssocKey, pk, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static id SPKProfileUser(UIViewController *controller) {
    @try {
        return [(id)controller valueForKey:@"user"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Everything that changes what the badge looks like. Stored on the badge so a
// layout pass can tell "same badge, leave it" from "rebuild it" and avoid
// tearing down and re-adding the view on every pass.
static NSString *SPKFollowBadgeSpec(BOOL followsYou) {
    return [NSString stringWithFormat:@"%@|%d|%d",
                                      SPKFollowIndicatorMode(),
                                      followsYou ? 1 : 0,
                                      SPKFollowIndicatorColorful() ? 1 : 0];
}

static void SPKCollectStatLabels(UIView *view, UIView *badge, NSMutableArray<UILabel *> *labels) {
    for (UIView *subview in view.subviews) {
        if (subview == badge || subview.hidden)
            continue;
        if ([subview isKindOfClass:[UILabel class]])
            [labels addObject:(UILabel *)subview];
        else
            SPKCollectStatLabels(subview, badge, labels);
    }
}

// Keeps the badge clear of the stat labels. The container's bottom edge alone is
// not a reliable reference: when the profile name wraps, IG tightens the space
// under the counts and a fixed bottom inset lands the badge on top of them. Each
// visible label gets a required "badge below label" constraint; constraints on
// labels that leave the hierarchy are dropped by UIKit automatically.
static void SPKAnchorFollowBadgeBelowStats(UIView *badge, UIView *container) {
    static const void *kAnchoredLabelsKey = &kAnchoredLabelsKey;
    NSHashTable *anchored = objc_getAssociatedObject(badge, kAnchoredLabelsKey);
    if (!anchored) {
        anchored = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(badge, kAnchoredLabelsKey, anchored, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SPKCollectStatLabels(container, badge, labels);

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    for (UILabel *label in labels) {
        if ([anchored containsObject:label])
            continue;
        [anchored addObject:label];
        // 2pt: a stat label's frame already includes its descender space, and at
        // larger text sizes Instagram's counts grow into the gap below them, so
        // any more pushes the badge past the container's bottom edge.
        [constraints addObject:[badge.topAnchor constraintGreaterThanOrEqualToAnchor:label.bottomAnchor constant:2.0]];
    }
    if (constraints.count > 0)
        [NSLayoutConstraint activateConstraints:constraints];
}

static void SPKRenderFollowBadge(UIViewController *controller, UIView *container) {
    if (!container)
        return;

    UIView *existing = [container viewWithTag:kSPKFollowBadgeTag];
    NSNumber *status = SPKGetFollowStatus(controller);

    // No status yet, or the feature was turned off from settings: clear the
    // badge (if any) and stop.
    if (!status || !SPKFollowIndicatorEnabled()) {
        [existing removeFromSuperview];
        return;
    }

    BOOL followsYou = status.boolValue;
    NSString *spec = SPKFollowBadgeSpec(followsYou);
    if (existing) {
        NSString *existingSpec = objc_getAssociatedObject(existing, kSPKFollowBadgeSpecAssocKey);
        if ([existingSpec isEqualToString:spec]) {
            // Identical badge already installed; only pick up stat labels IG rebuilt.
            SPKAnchorFollowBadgeBelowStats(existing, container);
            return;
        }
        [existing removeFromSuperview];
    }

    UIColor *accent = SPKFollowIndicatorColor(followsYou);

    UIImage *icon = nil;
    if (SPKFollowIndicatorShowsIcon()) {
        NSString *iconName = followsYou ? @"circle_check" : @"circle_xmark";
        UIImage *raw = [SPKAssetUtils instagramIconNamed:iconName
                                               pointSize:12.0
                                           renderingMode:UIImageRenderingModeAlwaysTemplate];
        // A missing glyph would become a zero-sized image, leaving a stray gap
        // in "icon + text" or an invisible badge in "icon".
        if (raw && raw.size.width > 0.0 && raw.size.height > 0.0)
            icon = raw;
    }

    NSString *text = nil;
    if (SPKFollowIndicatorShowsText())
        text = followsYou ? SPKL(@"PROFILE_FOLLOW_INDICATOR_FOLLOWING_TEXT") : SPKL(@"PROFILE_FOLLOW_INDICATOR_NOT_FOLLOWING_TEXT");

    if (!icon && text.length == 0)
        return;

    SPKChromeLabel *badge = [[SPKChromeLabel alloc] initWithText:text
                                                           icon:icon
                                                           font:[UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium] // spk-font-fixed: fits the gap Instagram leaves under the stats, which does not grow
                                                          color:accent];
    badge.tag = kSPKFollowBadgeTag;
    objc_setAssociatedObject(badge, kSPKFollowBadgeSpecAssocKey, spec, OBJC_ASSOCIATION_COPY_NONATOMIC);

    [container addSubview:badge];
    // Small bottom margin so the badge doesn't sit flush against the edge. It is
    // only a preference: the stat-label constraints win when space is tight.
    NSLayoutConstraint *bottom = [badge.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0];
    bottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        bottom
    ]];
    SPKAnchorFollowBadgeBelowStats(badge, container);
}

// Ask the controller's last-known stat container to re-render, e.g. after an
// async status arrival that produced no layout pass of its own. Only nudges a
// container that is still on screen: after IG rebuilds the profile header the
// map can point at a torn-down container, and re-rendering into that produced
// the "badge shows on some opens but not others" flakiness on iOS 16. A live
// container gets a real layout pass; a stale one is left for the current
// container's own natural layout to handle.
static void SPKNudgeFollowIndicator(UIViewController *controller) {
    UIView *container = [SPKFollowContainerForController() objectForKey:controller];
    if (container.window)
        [container setNeedsLayout];
}

// `key` is the (viewer, profile) key the request was issued for. It guards the
// response as well as the cache slot: a reply that lands after an account
// switch belongs to the previous viewer and must not reach the controller.
static void SPKFetchFollowStatus(UIViewController *controller, NSString *profilePK, NSString *key) {
    SPKSetFollowFetchPK(controller, key);

    __weak UIViewController *weakController = controller;
    NSString *requestedPK = key.copy;
    NSString *path = [NSString stringWithFormat:@"friendships/show/%@/", profilePK];

    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:path
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        UIViewController *strongController = weakController;
                                        if (!strongController)
                                            return;

                                        // Drop the result if a newer fetch superseded this one.
                                        if (![SPKGetFollowFetchPK(strongController) isEqualToString:requestedPK])
                                            return;
                                        SPKSetFollowFetchPK(strongController, nil);

                                        // ...or the profile changed under us before we returned.
                                        if (error || !response ||
                                            ![SPKGetFollowProfilePK(strongController) isEqualToString:requestedPK])
                                            return;

                                        NSNumber *followsYou = @([response[@"followed_by"] boolValue]);
                                        SPKFollowStatusCache()[requestedPK] = followsYou;
                                        SPKFollowStatusFetchDates()[requestedPK] = [NSDate date];
                                        SPKSetFollowStatus(strongController, followsYou);
                                        SPKNudgeFollowIndicator(strongController);
                                    });
                                }];
}

// Resolve who the profile belongs to and make sure `status` reflects that user,
// fetching once if needed. Cheap and idempotent — safe to call from setUser: and
// viewDidAppear:.
static void SPKRefreshFollowIndicator(UIViewController *controller) {
    // Clears are deliberately lazy: update state but do NOT force a re-render.
    // During a pull-to-refresh IG briefly sets the profile user to nil and back,
    // and proactively removing the badge on that transient nil (then re-adding
    // it a beat later) is exactly what made the indicator flicker on iOS 16. The
    // stale badge is instead left in place for the next natural layout pass,
    // which by then sees the restored status and keeps it. A genuine change
    // (own profile / real navigation) still clears the badge on that next pass.
    if (!SPKFollowIndicatorEnabled())
        return;

    NSString *profilePK = [SPKUtils pkFromIGUser:SPKProfileUser(controller)];
    NSString *currentPK = [SPKUtils currentUserPK];

    // Own profile, or PKs unavailable: nothing to show (cleared lazily, see above).
    if (profilePK.length == 0 || currentPK.length == 0 || [profilePK isEqualToString:currentPK]) {
        SPKSetFollowProfilePK(controller, nil);
        SPKSetFollowStatus(controller, nil);
        return;
    }

    NSString *key = SPKFollowStatusKey(currentPK, profilePK);

    // A different profile, or the same one seen from another account: whatever
    // the controller holds answers a different question.
    if (![SPKGetFollowProfilePK(controller) isEqualToString:key]) {
        SPKSetFollowProfilePK(controller, key);
        SPKSetFollowStatus(controller, nil);
    }

    // Show the cached answer straight away, even when it is due a revalidation,
    // so the badge never blinks out while the request is in flight.
    NSNumber *cached = SPKFollowStatusCache()[key];
    if (cached && ![SPKGetFollowStatus(controller) isEqual:cached]) {
        SPKSetFollowStatus(controller, cached);
        SPKNudgeFollowIndicator(controller);
    }

    if (cached && SPKFollowStatusIsFresh(key))
        return;

    if (![SPKGetFollowFetchPK(controller) isEqualToString:key])
        SPKFetchFollowStatus(controller, profilePK, key);
}

%group SPKFollowIndicatorHooks

%hook IGProfileViewController

- (void)setUser:(id)user {
    %orig;
    if (!SPKFollowIndicatorEnabled())
        return;
    // setUser: can land before the view exists, and IG reuses controllers, so
    // defer and re-resolve against whatever profile is now loaded.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf)
            SPKRefreshFollowIndicator((UIViewController *)weakSelf);
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (SPKFollowIndicatorEnabled())
        SPKRefreshFollowIndicator((UIViewController *)self);
}

%end

// The stats container lays itself out with the buttons already placed, so this
// is where the badge is (re)rendered and constrained — no view-tree search and
// no dependency on the profile controller getting another layout pass.
%hook _TtC23IGProfileHeaderIdentity38IGProfileHeaderStatButtonContainerView

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"FollowIndicator.layoutSubviews");

    UIViewController *controller = [SPKUtils nearestViewControllerForView:(UIView *)self];
    if (![controller isKindOfClass:%c(IGProfileViewController)])
        return;

    [SPKFollowContainerForController() setObject:(UIView *)self forKey:controller];
    SPKRenderFollowBadge(controller, (UIView *)self);
}

%end

%end

void SPKInstallFollowIndicatorHooksIfEnabled(void) {
    if (!SPKFollowIndicatorEnabled())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKFollowIndicatorHooks);

        // Entries are keyed by viewer, so a switch cannot leak an answer; this
        // only stops the previous account's entries piling up.
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            [SPKFollowStatusCache() removeAllObjects];
            [SPKFollowStatusFetchDates() removeAllObjects];
        }];

        // Refresh visible profiles in place when the look changes from settings.
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKFollowIndicatorDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            NSMapTable *map = SPKFollowContainerForController();
            for (UIViewController *controller in [[map keyEnumerator] allObjects]) {
                UIView *container = [map objectForKey:controller];
                SPKRenderFollowBadge(controller, container);
            }
        }];
    });
}
