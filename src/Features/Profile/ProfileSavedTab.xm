#import "SPKStrings.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// Re-adds a Saved tab to the signed-in user's own profile.
//
// Instagram identifies profile tabs by NSNumber tab types (0 grid, 1 tagged,
// 2 reels, 3 fan club). An unknown type is accepted by both the tab strip and
// the page pager, so the tab is one extra identifier plus a segment for the
// strip. The page itself is Instagram's own IGSavedMediaCollectionsViewController,
// which still conforms to IGProfileTabViewController from when Saved was a
// profile tab, so header collapse and content insets come from Instagram.
//
// Newer builds pick the tab types and segments in a Swift plugin class whose
// class methods are hooked. Older builds without the plugin fill the profile
// controller's identifier list and the pager's page list before handing the
// segments to the tab strip, so both lists are extended at that point.
//
// In both cases the profile controller answers unknown types with a nil page,
// so the page is supplied from its page lookup and registered in its tab map,
// which is where insets and refresh tint are driven from.

static NSString *const kSPKProfileSavedTabPrefKey = @"profile_saved_tab";
static const NSInteger kSPKProfileSavedTabType = 1000;
// Placeholder shown while the page loads; Tagged's is a plain grid placeholder.
static const NSInteger kSPKProfileSavedTabPlaceholderSourceType = 1;

// Tabs are keyed by NSNumber types until 448 and by NSString tab IDs from 449.
static NSString *const kSPKProfileSavedTabID = @"spk_saved";
static id sSPKProfileSavedTabIdentifier;

static id SPKProfileSavedTabIdentifier(void) {
    return sSPKProfileSavedTabIdentifier ?: @(kSPKProfileSavedTabType);
}

static BOOL SPKProfileSavedTabEnabled(void) {
    return [SPKUtils getBoolPref:kSPKProfileSavedTabPrefKey];
}

static BOOL SPKIsProfileSavedTabIdentifier(id identifier) {
    return identifier && [identifier isEqual:SPKProfileSavedTabIdentifier()];
}

#pragma mark - Segment

@interface SPKProfileSavedTabSegment : NSObject
@end

@implementation SPKProfileSavedTabSegment

- (NSString *)title {
    return SPKL(@"PROFILE_SAVED_TAB_SEGMENT_TITLE");
}

- (NSString *)accessibilityLabel {
    return SPKL(@"PROFILE_SAVED_TAB_SEGMENT_TITLE");
}

- (NSString *)accessibilityIdentifier {
    return @"spk_profile_saved_tab";
}

- (long long)rightAccessoryType {
    return 0;
}

- (long long)rightAccessoryCount {
    return 0;
}

- (UIImage *)fallbackIcon {
    return [SPKAssetUtils instagramIconNamed:@"save" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIImage *)fallbackPrismActiveIcon {
    return [SPKAssetUtils instagramIconNamed:@"save_filled" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:[SPKProfileSavedTabSegment class]];
}

- (NSUInteger)hash {
    return (NSUInteger)kSPKProfileSavedTabType;
}

@end

#pragma mark - Tabs plugin

static id sSPKProfileSavedTabPlaceholderSourceID;

static id (*orig_eligibleTabIdentifiers)(id, SEL, id, id, BOOL, id, BOOL, BOOL, BOOL);
static id hooked_eligibleTabIdentifiers(id self, SEL _cmd, id user, id userSession, BOOL isCurrentUser, id configuration, BOOL showReelsOnboardingTab, BOOL hideClipsTab, BOOL hasClipsDrafts) {
    id identifiers = orig_eligibleTabIdentifiers(self, _cmd, user, userSession, isCurrentUser, configuration, showReelsOnboardingTab, hideClipsTab, hasClipsDrafts);
    if (!isCurrentUser || ![identifiers isKindOfClass:[NSArray class]] || !SPKProfileSavedTabEnabled())
        return identifiers;
    if ([identifiers containsObject:SPKProfileSavedTabIdentifier()])
        return identifiers;
    return [identifiers arrayByAddingObject:SPKProfileSavedTabIdentifier()];
}

static id (*orig_segmentsForTabIdentifiers)(id, SEL, id, id);
static id hooked_segmentsForTabIdentifiers(id self, SEL _cmd, id identifiers, id badge) {
    if (![identifiers isKindOfClass:[NSArray class]])
        return orig_segmentsForTabIdentifiers(self, _cmd, identifiers, badge);

    NSUInteger savedIndex = [identifiers indexOfObject:SPKProfileSavedTabIdentifier()];
    if (savedIndex == NSNotFound)
        return orig_segmentsForTabIdentifiers(self, _cmd, identifiers, badge);

    NSMutableArray *nativeIdentifiers = [identifiers mutableCopy];
    [nativeIdentifiers removeObjectAtIndex:savedIndex];
    id segments = orig_segmentsForTabIdentifiers(self, _cmd, nativeIdentifiers, badge);
    if (![segments isKindOfClass:[NSArray class]])
        return segments;

    // Segments map to identifiers by position, so a count mismatch means Instagram
    // dropped or merged a tab and inserting would shift every tab after it.
    NSArray *nativeSegments = segments;
    if (nativeSegments.count != nativeIdentifiers.count) {
        SPKLog(@"ProfileSavedTab", @"Segment count %lu does not match identifiers %lu; skipping", (unsigned long)nativeSegments.count, (unsigned long)nativeIdentifiers.count);
        return segments;
    }

    NSMutableArray *result = [nativeSegments mutableCopy];
    [result insertObject:[SPKProfileSavedTabSegment new] atIndex:MIN(savedIndex, result.count)];
    return result;
}

static long long (*orig_placeholderStyleForTabIdentifier)(id, SEL, id);
static long long hooked_placeholderStyleForTabIdentifier(id self, SEL _cmd, id identifier) {
    if (SPKIsProfileSavedTabIdentifier(identifier))
        identifier = sSPKProfileSavedTabPlaceholderSourceID;
    return orig_placeholderStyleForTabIdentifier(self, _cmd, identifier);
}

#pragma mark - Page

static UIViewController *SPKMakeProfileSavedTabPage(IGProfileViewController *profileController) {
    IGUserSession *userSession = [SPKUtils getIvarForObj:profileController name:"_userSession"];
    IGUser *user = [userSession isKindOfClass:NSClassFromString(@"IGUserSession")] ? userSession.user : nil;
    Class configurationClass = NSClassFromString(@"IGSavedMediaCollectionsOwnerDataSourceConfiguration");
    Class pageClass = NSClassFromString(@"IGSavedMediaCollectionsViewController");
    if (!userSession || !user || !configurationClass || !pageClass)
        return nil;

    if (![configurationClass instancesRespondToSelector:@selector(initWithUser:andLauncherSet:showOnlyPublicCollections:)]) {
        SPKLog(@"ProfileSavedTab", @"Saved collections configuration initializer unavailable");
        return nil;
    }
    IGSavedMediaCollectionsOwnerDataSourceConfiguration *configuration =
        [[configurationClass alloc] initWithUser:user andLauncherSet:userSession showOnlyPublicCollections:NO];

    // Edge insets are left nil: the profile page drives the insets through
    // -updateContentInsets once the page is registered in its tab map.
    IGSavedMediaCollectionsViewController *page = nil;
    if ([pageClass instancesRespondToSelector:@selector(initWithUserSession:dataSourceConfiguration:preferredEdgeInsets:disableFeedPreview:type:)]) {
        page = [[pageClass alloc] initWithUserSession:userSession
                              dataSourceConfiguration:configuration
                                  preferredEdgeInsets:nil
                                   disableFeedPreview:NO
                                                 type:0];
    } else if ([pageClass instancesRespondToSelector:@selector(initWithUserSession:dataSourceConfiguration:enableAddPlaceholder:entryModule:preferredEdgeInsets:disableFeedPreview:type:)]) {
        page = [[pageClass alloc] initWithUserSession:userSession
                              dataSourceConfiguration:configuration
                                 enableAddPlaceholder:NO
                                          entryModule:@"self_profile"
                                  preferredEdgeInsets:nil
                                   disableFeedPreview:NO
                                                 type:0];
    } else {
        SPKLog(@"ProfileSavedTab", @"Saved page initializer unavailable");
    }
    if (!page)
        return nil;

    if ([page respondsToSelector:@selector(setProfileTabDelegate:)])
        page.profileTabDelegate = (id)profileController;
    return page;
}

// Set while the Saved selection is being put back after a strip rebuild.
static BOOL sSPKProfileSavedTabRestoring = NO;

static BOOL SPKProfileSavedTabIsSelected(id profileController) {
    id page = [SPKUtils getIvarForObj:profileController name:"_currentPageViewController"];
    return [page isKindOfClass:NSClassFromString(@"IGSavedMediaCollectionsViewController")];
}

static BOOL SPKProfileSavedTabControlSelectsSaved(id profileController, id control) {
    if (![control respondsToSelector:@selector(selectedIndex)])
        return NO;
    NSArray *identifiers = [SPKUtils getIvarForObj:profileController name:"_tabViewControllerIdentifiers"];
    long long index = ((long long (*)(id, SEL))objc_msgSend)(control, @selector(selectedIndex));
    return [identifiers isKindOfClass:[NSArray class]] && index >= 0 && (NSUInteger)index < identifiers.count &&
           SPKIsProfileSavedTabIdentifier(identifiers[(NSUInteger)index]);
}

// Scrolls the Saved page so the profile header is fully collapsed and the strip
// sits right under the navigation bar, the way re-tapping a native tab does: the
// offset is set inside a short view animation so the header moves with it, and
// the content is not padded, so a short page settles back once it is touched.
static void SPKProfileSavedTabScrollToFullScreen(IGProfileViewController *profileController) {
    id page = [SPKUtils getIvarForObj:profileController name:"_currentPageViewController"];
    UIScrollView *scrollView = [page respondsToSelector:@selector(scrollView)] ? [page scrollView] : nil;
    if (![scrollView isKindOfClass:[UIScrollView class]] || scrollView.isTracking || scrollView.isDragging || !profileController.isViewLoaded)
        return;

    SEL obstructingSelector = @selector(profileTabViewControllerAdditionalTopObstructingContentInset:);
    if (![profileController respondsToSelector:obstructingSelector])
        return;
    CGFloat obstructing = ((double (*)(id, SEL, id))objc_msgSend)(profileController, obstructingSelector, page);
    CGFloat stripHeight = 0;
    Ivar stripHeightIvar = class_getInstanceVariable(object_getClass(profileController), "_profileContentFilterControlHeight");
    if (stripHeightIvar && strcmp(ivar_getTypeEncoding(stripHeightIvar) ?: "", @encode(double)) == 0)
        stripHeight = *(double *)((char *)(__bridge void *)profileController + ivar_getOffset(stripHeightIvar));
    CGFloat safeTop = profileController.view.safeAreaInsets.top;
    CGFloat target = -(safeTop + obstructing + stripHeight);

    SPKLog(@"ProfileSavedTab", @"Re-tap: safe %.1f obstructing %.1f strip %.1f target %.1f offset %.1f", safeTop, obstructing, stripHeight, target,
           scrollView.contentOffset.y);
    if (stripHeight <= 0 || fabs(scrollView.contentOffset.y - target) < 1.0)
        return;
    [UIView animateWithDuration:0.3
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, target) animated:NO];
                     }
                     completion:nil];
}

// The profile gives its native pages a bottom inset that keeps the last row clear
// of the tab bar, but the Saved page recomputes its own insets from its (empty)
// preferred edge insets and drops it. Copy the bottom inset from a native page.
static void SPKProfileSavedTabSyncBottomInset(IGSavedMediaCollectionsViewController *page) {
    id profileController = page.profileTabDelegate;
    if (![profileController isKindOfClass:NSClassFromString(@"IGProfileViewController")] || !page.isViewLoaded)
        return;
    NSDictionary *pages = [SPKUtils getIvarForObj:profileController name:"_tabViewControllersForIdentifiers"];
    if (![pages isKindOfClass:[NSDictionary class]] || pages[SPKProfileSavedTabIdentifier()] != page)
        return;
    UIScrollView *scrollView = [page respondsToSelector:@selector(scrollView)] ? [page scrollView] : nil;
    if (![scrollView isKindOfClass:[UIScrollView class]])
        return;

    UIScrollView *nativeScrollView = nil;
    for (id identifier in pages) {
        UIViewController *nativePage = pages[identifier];
        if (SPKIsProfileSavedTabIdentifier(identifier) || ![nativePage respondsToSelector:@selector(scrollView)] || !nativePage.isViewLoaded)
            continue;
        UIScrollView *candidate = [(id)nativePage scrollView];
        if ([candidate isKindOfClass:[UIScrollView class]]) {
            nativeScrollView = candidate;
            break;
        }
    }
    if (!nativeScrollView)
        return;

    CGFloat bottom = nativeScrollView.contentInset.bottom;
    UIEdgeInsets insets = scrollView.contentInset;
    if (fabs(insets.bottom - bottom) >= 0.5) {
        insets.bottom = bottom;
        scrollView.contentInset = insets;
    }
    UIEdgeInsets indicatorInsets = scrollView.verticalScrollIndicatorInsets;
    CGFloat indicatorBottom = nativeScrollView.verticalScrollIndicatorInsets.bottom;
    if (fabs(indicatorInsets.bottom - indicatorBottom) >= 0.5) {
        indicatorInsets.bottom = indicatorBottom;
        scrollView.verticalScrollIndicatorInsets = indicatorInsets;
    }
}

%group SPKProfileSavedTabPageHooks

%hook IGProfileViewController

- (id)dynamicPageViewController:(id)pageController viewControllerForPageWithIdentifier:(id)identifier {
    if (!SPKIsProfileSavedTabIdentifier(identifier))
        return %orig;

    NSMutableDictionary *pages = [SPKUtils getIvarForObj:self name:"_tabViewControllersForIdentifiers"];
    UIViewController *page = [pages isKindOfClass:[NSMutableDictionary class]] ? pages[identifier] : nil;
    if (![page isKindOfClass:NSClassFromString(@"IGSavedMediaCollectionsViewController")]) {
        page = SPKMakeProfileSavedTabPage(self);
        if (!page)
            return %orig;
        if ([pages isKindOfClass:[NSMutableDictionary class]])
            pages[identifier] = page;

        UIColor *background = self.isViewLoaded ? self.view.backgroundColor : nil;
        if (background && [page respondsToSelector:@selector(setRefreshControlBackgroundColor:)])
            [(id)page setRefreshControlBackgroundColor:background];
    }

    if ([page respondsToSelector:@selector(updateContentInsets)])
        [(id)page updateContentInsets];
    return page;
}

// Tapping the tab that is already showing runs Instagram's per-tab-type handling,
// which traps on the Saved type on older builds and scrolls to the wrong place on
// newer ones. The re-tap on Saved scrolls the header away here instead.
- (void)_tabControlValueChanged:(id)control {
    if (!sSPKProfileSavedTabRestoring && SPKProfileSavedTabIsSelected(self) && SPKProfileSavedTabControlSelectsSaved(self, control)) {
        SPKProfileSavedTabScrollToFullScreen(self);
        return;
    }
    %orig;
}

%end

%hook IGSavedMediaCollectionsViewController

- (void)updateContentInsets {
    %orig;
    SPKProfileSavedTabSyncBottomInset(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    SPKProfileSavedTabSyncBottomInset(self);
}

%end

%end

#pragma mark - Builds without the tabs plugin

static NSString *SPKProfileSavedTabUserPK(id user) {
    if (![user respondsToSelector:@selector(pk)])
        return nil;
    id pk = [user performSelector:@selector(pk)];
    if ([pk isKindOfClass:[NSNumber class]])
        return [pk stringValue];
    return [pk isKindOfClass:[NSString class]] ? pk : nil;
}

static BOOL SPKProfileSavedTabIsOwnProfile(IGProfileViewController *profileController) {
    IGUserSession *userSession = [SPKUtils getIvarForObj:profileController name:"_userSession"];
    IGUser *sessionUser = [userSession isKindOfClass:NSClassFromString(@"IGUserSession")] ? userSession.user : nil;
    id profileUser = [profileController respondsToSelector:@selector(user)] ? [profileController user] : nil;
    if (!sessionUser || !profileUser)
        return NO;
    if (sessionUser == profileUser)
        return YES;
    NSString *sessionPK = SPKProfileSavedTabUserPK(sessionUser);
    return sessionPK.length > 0 && [sessionPK isEqualToString:SPKProfileSavedTabUserPK(profileUser)];
}

static NSArray *SPKProfileSavedTabAppendIdentifier(NSArray *identifiers) {
    if (![identifiers isKindOfClass:[NSArray class]] || [identifiers containsObject:SPKProfileSavedTabIdentifier()])
        return identifiers;
    return [identifiers arrayByAddingObject:SPKProfileSavedTabIdentifier()];
}

static BOOL SPKProfileSavedTabIsNativeSavedSegment(id segment) {
    Ivar ivar = segment ? class_getInstanceVariable(object_getClass(segment), "_tabType") : NULL;
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar) ?: "", @encode(long long)) != 0)
        return NO;
    return *(long long *)((char *)(__bridge void *)segment + ivar_getOffset(ivar)) == kSPKProfileSavedTabType;
}

// Every rebuild writes the pager's page list without Saved first, which resets
// the pager to its first page while the profile still has the Saved page as its
// current page. When that happens the Saved selection is put back right after
// the strip hook appends Saved again, before the frame is drawn.
static UICollectionView *SPKProfileSavedTabPagerCollectionView(id profileController) {
    IGDynamicPageViewController *pager = [SPKUtils getIvarForObj:profileController name:"_dynamicPageViewController"];
    if (![pager isKindOfClass:NSClassFromString(@"IGDynamicPageViewController")] || ![pager respondsToSelector:@selector(collectionView)])
        return nil;
    UICollectionView *collectionView = pager.collectionView;
    return [collectionView isKindOfClass:[UICollectionView class]] ? collectionView : nil;
}

static void SPKProfileSavedTabRestoreSelection(IGProfileViewController *profileController, IGSegmentedTabControl *control) {
    if (sSPKProfileSavedTabRestoring || !profileController || ![control isKindOfClass:NSClassFromString(@"IGSegmentedTabControl")])
        return;
    if (!SPKProfileSavedTabEnabled() || !SPKProfileSavedTabIsSelected(profileController) || ![profileController respondsToSelector:@selector(_tabControlValueChanged:)])
        return;
    NSArray *identifiers = [SPKUtils getIvarForObj:profileController name:"_tabViewControllerIdentifiers"];
    NSUInteger savedIndex = [identifiers isKindOfClass:[NSArray class]] ? [identifiers indexOfObject:SPKProfileSavedTabIdentifier()] : NSNotFound;
    if (savedIndex == NSNotFound || savedIndex >= control.segments.count)
        return;

    // Leave a swipe in progress alone; the page only becomes current once it settles.
    UICollectionView *collectionView = SPKProfileSavedTabPagerCollectionView(profileController);
    if (collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating)
        return;
    CGFloat width = CGRectGetWidth(collectionView.bounds);
    CGFloat savedOffset = width * savedIndex;
    BOOL pagerOnSaved = !collectionView || width < 1.0 || fabs(collectionView.contentOffset.x - savedOffset) < 1.0;
    if (control.selectedIndex == (long long)savedIndex && pagerOnSaved)
        return;

    control.selectedIndex = (long long)savedIndex;
    sSPKProfileSavedTabRestoring = YES;
    [profileController _tabControlValueChanged:control];
    sSPKProfileSavedTabRestoring = NO;

    if (collectionView && width >= 1.0 && fabs(collectionView.contentOffset.x - savedOffset) >= 1.0 && (NSInteger)savedIndex < collectionView.numberOfSections)
        [collectionView setContentOffset:CGPointMake(savedOffset, collectionView.contentOffset.y) animated:NO];
}

static void SPKProfileSavedTabScheduleRestore(IGProfileViewController *profileController, IGSegmentedTabControl *control) {
    SPKProfileSavedTabRestoreSelection(profileController, control);
    // Instagram can move the strip selection again later in the same pass.
    __weak IGProfileViewController *weakProfile = profileController;
    __weak IGSegmentedTabControl *weakControl = control;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKProfileSavedTabRestoreSelection(weakProfile, weakControl);
    });
}

%group SPKProfileSavedTabLegacyHooks

%hook IGSegmentedTabControl

// The profile controller fills its identifier list and the pager's page list
// before creating one segment per identifier, so by the time the segments reach
// the strip both lists match them position for position. The Saved identifier
// is appended to both and its segment to the strip.
- (void)setSegments:(NSArray *)segments {
    id delegate = self.delegate;
    if (![segments isKindOfClass:[NSArray class]] || ![delegate isKindOfClass:NSClassFromString(@"IGProfileViewController")] || !SPKProfileSavedTabEnabled()) {
        %orig;
        return;
    }
    if (!SPKProfileSavedTabIsOwnProfile(delegate)) {
        %orig;
        return;
    }

    // Once the identifier list carries Saved, Instagram's later rebuilds create
    // their own blank segment for it. Swap that one for ours instead of adding.
    NSMutableArray *nativeSegments = [NSMutableArray arrayWithCapacity:segments.count];
    for (id segment in segments) {
        if ([segment isKindOfClass:[SPKProfileSavedTabSegment class]] || SPKProfileSavedTabIsNativeSavedSegment(segment))
            continue;
        [nativeSegments addObject:segment];
    }

    NSArray *identifiers = [SPKUtils getIvarForObj:delegate name:"_tabViewControllerIdentifiers"];
    id pager = [SPKUtils getIvarForObj:delegate name:"_dynamicPageViewController"];
    NSArray *pageIdentifiers = pager ? [SPKUtils getIvarForObj:pager name:"_pageIdentifiers"] : nil;
    NSUInteger nativeCount = nativeSegments.count;
    BOOL identifiersMatch = [identifiers isKindOfClass:[NSArray class]] &&
                            (identifiers.count == nativeCount || (identifiers.count == nativeCount + 1 && SPKIsProfileSavedTabIdentifier(identifiers.lastObject)));
    BOOL pagesMatch = [pageIdentifiers isKindOfClass:[NSArray class]] &&
                      (pageIdentifiers.count == nativeCount || (pageIdentifiers.count == nativeCount + 1 && SPKIsProfileSavedTabIdentifier(pageIdentifiers.lastObject)));
    if (!identifiersMatch || !pagesMatch) {
        SPKLog(@"ProfileSavedTab", @"Segments %lu vs identifiers %@ / pages %@; not inserting", (unsigned long)nativeCount,
               [identifiers valueForKey:@"description"], [pageIdentifiers valueForKey:@"description"]);
        %orig;
        return;
    }

    Ivar identifiersIvar = class_getInstanceVariable(object_getClass(delegate), "_tabViewControllerIdentifiers");
    Ivar pagesIvar = class_getInstanceVariable(object_getClass(pager), "_pageIdentifiers");
    if (!identifiersIvar || !pagesIvar) {
        %orig;
        return;
    }
    object_setIvar(delegate, identifiersIvar, SPKProfileSavedTabAppendIdentifier(identifiers));
    BOOL pagesChanged = pageIdentifiers.count == nativeCount;
    if (pagesChanged)
        object_setIvar(pager, pagesIvar, SPKProfileSavedTabAppendIdentifier(pageIdentifiers));

    [nativeSegments addObject:[SPKProfileSavedTabSegment new]];
    %orig([nativeSegments copy]);

    // The pager may already have laid out its pages from the shorter list.
    if (pagesChanged) {
        id listAdapter = [SPKUtils getIvarForObj:pager name:"_listAdapter"];
        SEL performUpdates = NSSelectorFromString(@"performUpdatesAnimated:completion:");
        if ([listAdapter respondsToSelector:performUpdates])
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(listAdapter, performUpdates, NO, nil);
    }

    SPKProfileSavedTabScheduleRestore(delegate, self);
}

%end

%hook IGDynamicPageViewController

// Pages are listed from the page identifiers; keep Saved listed if the list was
// rebuilt after the strip was last updated.
- (NSArray *)objectsForListAdapter:(id)listAdapter {
    NSArray *objects = %orig;
    id dataSource = self.dataSource;
    if (![dataSource isKindOfClass:NSClassFromString(@"IGProfileViewController")] || [objects containsObject:SPKProfileSavedTabIdentifier()])
        return objects;
    NSArray *identifiers = [SPKUtils getIvarForObj:dataSource name:"_tabViewControllerIdentifiers"];
    if (![identifiers isKindOfClass:[NSArray class]] || ![identifiers containsObject:SPKProfileSavedTabIdentifier()] || identifiers.count != objects.count + 1)
        return objects;
    return SPKProfileSavedTabAppendIdentifier(objects);
}

%end

%hook IGProfileViewController

- (BOOL)dynamicPageViewController:(id)pageController canDisplayPlaceholderViewForPageWithIdentifier:(id)identifier {
    return SPKIsProfileSavedTabIdentifier(identifier) ? NO : %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKProfileSavedTabScheduleRestore(self, [SPKUtils getIvarForObj:self name:"_profileContentFilterControl"]);
}

%end

%end

#pragma mark - Install

static void SPKHookProfileTabsPluginClassMethod(Class metaClass, SEL selector, IMP replacement, IMP *original) {
    if (!class_getInstanceMethod(metaClass, selector)) {
        SPKLog(@"ProfileSavedTab", @"Missing +%@", NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(metaClass, selector, replacement, original);
}

extern "C" void SPKInstallProfileSavedTabHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!NSClassFromString(@"IGSavedMediaCollectionsViewController") || !NSClassFromString(@"IGProfileViewController")) {
            SPKLog(@"ProfileSavedTab", @"Saved page unavailable; Saved tab not installed");
            return;
        }

        Class plugin = objc_getClass("_TtC19IGProfileTabsPlugin19IGProfileTabsPlugin");
        if (plugin) {
            Protocol *segmentProtocol = objc_getProtocol("IGTabControlSegmentProviding");
            if (!segmentProtocol) {
                SPKLog(@"ProfileSavedTab", @"Tab segment protocol unavailable; Saved tab not installed");
                return;
            }
            // Swift checks the tab segment with a protocol cast, so the conformance
            // has to be the app's registered protocol object.
            class_addProtocol([SPKProfileSavedTabSegment class], segmentProtocol);

            // The hooks only rewrite the identifier list and segments, so the same
            // implementations serve both identifier generations.
            Class metaClass = object_getClass(plugin);
            BOOL usesTabIDs = [plugin respondsToSelector:@selector(segmentsForTabIDs:badge:)];
            if (usesTabIDs) {
                id taggedTabID = [plugin respondsToSelector:@selector(taggedTabID)] ? ((id (*)(id, SEL))objc_msgSend)(plugin, @selector(taggedTabID)) : nil;
                if (![taggedTabID isKindOfClass:[NSString class]]) {
                    SPKLog(@"ProfileSavedTab", @"Tagged tab ID unavailable; Saved tab not installed");
                    return;
                }
                sSPKProfileSavedTabIdentifier = kSPKProfileSavedTabID;
                sSPKProfileSavedTabPlaceholderSourceID = taggedTabID;
            } else {
                sSPKProfileSavedTabPlaceholderSourceID = @(kSPKProfileSavedTabPlaceholderSourceType);
            }
            SPKHookProfileTabsPluginClassMethod(metaClass,
                                                usesTabIDs ? @selector(eligibleTabIDsWithUser:userSession:isCurrentUser:configuration:shouldShowReelsOnboardingTab:hideClipsTab:hasClipsDrafts:)
                                                           : @selector(eligibleLegacyTabIdentifiersWithUser:userSession:isCurrentUser:configuration:shouldShowReelsOnboardingTab:hideClipsTab:hasClipsDrafts:),
                                                (IMP)hooked_eligibleTabIdentifiers,
                                                (IMP *)&orig_eligibleTabIdentifiers);
            SPKHookProfileTabsPluginClassMethod(metaClass,
                                                usesTabIDs ? @selector(segmentsForTabIDs:badge:) : @selector(segmentsForLegacyTabIdentifiers:badge:),
                                                (IMP)hooked_segmentsForTabIdentifiers,
                                                (IMP *)&orig_segmentsForTabIdentifiers);
            SPKHookProfileTabsPluginClassMethod(metaClass,
                                                usesTabIDs ? @selector(placeholderStyleForTabID:) : @selector(placeholderStyleForLegacyTabIdentifier:),
                                                (IMP)hooked_placeholderStyleForTabIdentifier,
                                                (IMP *)&orig_placeholderStyleForTabIdentifier);
        } else {
            Protocol *segmentProtocol = objc_getProtocol("IGTabControlSegment");
            if (!segmentProtocol || !NSClassFromString(@"IGSegmentedTabControl") || !NSClassFromString(@"IGDynamicPageViewController")) {
                SPKLog(@"ProfileSavedTab", @"Profile tab strip unavailable; Saved tab not installed");
                return;
            }
            class_addProtocol([SPKProfileSavedTabSegment class], segmentProtocol);
            %init(SPKProfileSavedTabLegacyHooks);
        }
        %init(SPKProfileSavedTabPageHooks);
    });
}
