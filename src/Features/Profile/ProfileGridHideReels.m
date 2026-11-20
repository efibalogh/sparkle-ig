#import "SPKStrings.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// Posts tab filter
// The first profile tab (legacy tab type 0) mixes photo and carousel posts with
// reels that were also shared to the grid. Each profile has a filter mode, All
// or Posts Only. Posts Only drops reels from the grid and from the feed opened
// by tapping a grid post. The Reels tab has its own source and is untouched.
//
// Preference profile_grid_filter: off (stock), all or posts. Either on value
// adds a chevron to the posts tab that switches the mode for the profile on
// screen; the value is the mode each profile opens with.
//
// Grid. The posts tab is IGProfileUserGridFeedViewController, which overrides
// objectsForListAdapter: (Swift on newer builds, Objective-C on 410.1.0).
// Grid objects are IGMedia or a grid item wrapping one (`media`); anything that
// resolves to no media (highlights, cards, spinner) is kept. Only the displayed
// objects change, so the feed source keeps every post and pagination stays
// Instagram's.
//
// Auto-load. A reel-heavy page can leave almost nothing to scroll, and the next
// page only loads near the bottom. While Posts Only is filtering and less than
// a screen of content remains below the visible area, the controller's own
// near-bottom handler is called, as Instagram does after its manual check. A
// per-profile budget stops an account made almost entirely of reels from paging
// through its whole history.
//
// Tapped feed. Tapping a grid post opens a contextual feed backed by
// IGProfileContextualFeedServiceProvider over the same network source. The mode
// is stamped on that source by the grid, so the service's reads and the feed
// controller's service callbacks are filtered for that source only.
//
// Chevron. The grid segment reports shouldShowChevron (added to the Swift
// segment class, which lacks it), so the tab cell draws Instagram's chevron.
// Its tap reaches the profile's chevron delegate, which for the grid presents
// the same IGDSMenu the Reels sort uses: plain title items, the selected one
// carrying Instagram's template checkmark as its accessory image, presented at
// the same point with direction 5: the tab cell's horizontal center, 8pt below
// the cell.

static NSString *const kSPKProfileGridFilterPrefKey = @"profile_grid_filter";
static const long long kSPKProfileGridTabType = 0;
static const NSUInteger kSPKProfileGridAutoLoadBudget = 12;

typedef NS_ENUM(NSInteger, SPKProfileGridMode) {
    SPKProfileGridModeAll = 0,
    SPKProfileGridModePostsOnly = 1,
};

static const void *kSPKProfileGridModeKey = &kSPKProfileGridModeKey;
static const void *kSPKProfileGridSourceModeKey = &kSPKProfileGridSourceModeKey;
static const void *kSPKProfileGridAutoLoadCountKey = &kSPKProfileGridAutoLoadCountKey;
static const void *kSPKProfileGridAutoLoadPendingKey = &kSPKProfileGridAutoLoadPendingKey;
static const void *kSPKProfileGridAutoLoadObjectsKey = &kSPKProfileGridAutoLoadObjectsKey;

static NSString *SPKProfileGridFilterPref(void) {
    return [SPKUtils getStringPref:kSPKProfileGridFilterPrefKey] ?: @"off";
}

static BOOL SPKProfileGridHideReelsDefault(void) {
    return [SPKProfileGridFilterPref() isEqualToString:@"posts"];
}

static BOOL SPKProfileGridFilterMenuEnabled(void) {
    NSString *mode = SPKProfileGridFilterPref();
    return [mode isEqualToString:@"all"] || [mode isEqualToString:@"posts"];
}

#pragma mark - Media

static id SPKProfileGridMediaForObject(id object) {
    static Class mediaClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaClass = NSClassFromString(@"IGMedia");
    });
    if (!object || !mediaClass)
        return nil;
    if ([object isKindOfClass:mediaClass])
        return object;
    if (![object respondsToSelector:@selector(media)])
        return nil;
    id media = nil;
    @try {
        media = ((id (*)(id, SEL))objc_msgSend)(object, @selector(media));
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return [media isKindOfClass:mediaClass] ? media : nil;
}

static BOOL SPKProfileGridObjectIsReel(id object) {
    id media = SPKProfileGridMediaForObject(object);
    if (!media || ![media respondsToSelector:@selector(isClipsMedia)])
        return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isClipsMedia));
}

static NSArray *SPKProfileGridFilteredObjects(NSArray *objects, NSUInteger *outRemoved) {
    if (outRemoved)
        *outRemoved = 0;
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0)
        return objects;
    NSIndexSet *reels = [objects indexesOfObjectsPassingTest:^BOOL(id object, __unused NSUInteger index, __unused BOOL *stop) {
        return SPKProfileGridObjectIsReel(object);
    }];
    if (reels.count == 0)
        return objects;
    if (outRemoved)
        *outRemoved = reels.count;
    NSMutableArray *filtered = [objects mutableCopy];
    [filtered removeObjectsAtIndexes:reels];
    return filtered;
}

#pragma mark - Ivars

static id SPKProfileGridObjectIvar(id object, const char *const *names) {
    if (!object)
        return nil;
    for (const char *const *name = names; *name; name++) {
        Ivar ivar = class_getInstanceVariable(object_getClass(object), *name);
        if (ivar)
            return object_getIvar(object, ivar);
    }
    return nil;
}

static BOOL SPKProfileGridReadIntegerIvar(id object, const char *name, long long *outValue) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    if (!ivar)
        return NO;
    *outValue = *(long long *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
    return YES;
}

static BOOL SPKProfileGridIsPostsTab(id controller) {
    if (![controller respondsToSelector:@selector(tabType)])
        return NO;
    return ((long long (*)(id, SEL))objc_msgSend)(controller, @selector(tabType)) == kSPKProfileGridTabType;
}

#pragma mark - Mode

static UIViewController *SPKProfileGridProfileControllerForController(UIViewController *controller) {
    static Class profileClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        profileClass = NSClassFromString(@"IGProfileViewController");
    });
    for (UIViewController *candidate = controller; candidate; candidate = candidate.parentViewController) {
        if (profileClass && [candidate isKindOfClass:profileClass])
            return candidate;
    }
    return nil;
}

static UIViewController *SPKProfileGridProfileControllerForView(UIView *view) {
    UIViewController *controller = [SPKUtils viewControllerForAncestralView:view];
    return SPKProfileGridProfileControllerForController(controller);
}

// The mode lives on the profile screen so it lasts for that visit; a profile
// opened later starts from the preference again.
static SPKProfileGridMode SPKProfileGridModeForProfile(UIViewController *profile) {
    if (!SPKProfileGridFilterMenuEnabled())
        return SPKProfileGridModeAll;
    NSNumber *stored = profile ? objc_getAssociatedObject(profile, kSPKProfileGridModeKey) : nil;
    if (stored)
        return (SPKProfileGridMode)stored.integerValue;
    return SPKProfileGridHideReelsDefault() ? SPKProfileGridModePostsOnly : SPKProfileGridModeAll;
}

static id SPKProfileGridFeedSourceForController(id controller) {
    id profileFeedSource = nil;
    @try {
        profileFeedSource = [controller valueForKey:@"profileFeedSource"];
    } @catch (__unused NSException *exception) {
    }
    static const char *const names[] = {"_feedSource", "feedSource", NULL};
    return SPKProfileGridObjectIvar(profileFeedSource, names);
}

static BOOL SPKProfileGridSourceIsPostsOnly(id feedSource) {
    NSNumber *mode = feedSource ? objc_getAssociatedObject(feedSource, kSPKProfileGridSourceModeKey) : nil;
    return mode.integerValue == SPKProfileGridModePostsOnly;
}

#pragma mark - Auto-load

static BOOL SPKProfileGridSourceCanLoadMore(id feedSource) {
    if (!feedSource)
        return NO;
    BOOL more = [feedSource respondsToSelector:@selector(moreAvailable)] && ((BOOL (*)(id, SEL))objc_msgSend)(feedSource, @selector(moreAvailable));
    BOOL loading = [feedSource respondsToSelector:@selector(isLoading)] && ((BOOL (*)(id, SEL))objc_msgSend)(feedSource, @selector(isLoading));
    return more && !loading;
}

static void SPKProfileGridAutoLoadIfNeeded(UIViewController *controller, id feedSource, NSUInteger objectCount, NSUInteger removed) {
    if (removed == 0 || [objc_getAssociatedObject(controller, kSPKProfileGridAutoLoadPendingKey) boolValue])
        return;
    // One request per page: the grid is asked for objects several times while
    // a page is pending, before the source reports that it is loading.
    NSNumber *lastObjects = objc_getAssociatedObject(controller, kSPKProfileGridAutoLoadObjectsKey);
    if (lastObjects && lastObjects.unsignedIntegerValue >= objectCount)
        return;
    NSUInteger count = [objc_getAssociatedObject(controller, kSPKProfileGridAutoLoadCountKey) unsignedIntegerValue];
    if (count >= kSPKProfileGridAutoLoadBudget)
        return;
    objc_setAssociatedObject(controller, kSPKProfileGridAutoLoadPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    __weak id weakSource = feedSource;
    // Runs after the list adapter has applied the update, so content size
    // reflects the filtered grid.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController)
            return;
        objc_setAssociatedObject(strongController, kSPKProfileGridAutoLoadPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!strongController.viewIfLoaded.window || !SPKProfileGridSourceCanLoadMore(weakSource))
            return;
        UIScrollView *scrollView = [strongController respondsToSelector:@selector(scrollView)] ? ((id (*)(id, SEL))objc_msgSend)(strongController, @selector(scrollView)) : nil;
        if (![scrollView isKindOfClass:[UIScrollView class]])
            return;
        CGFloat visibleBottom = scrollView.contentOffset.y + CGRectGetHeight(scrollView.bounds);
        CGFloat remaining = scrollView.contentSize.height - visibleBottom;
        if (remaining > CGRectGetHeight(scrollView.bounds))
            return;
        SEL nearBottom = @selector(scrollViewWillScrollNearBottom:triggeredByManualCheck:);
        if (![strongController respondsToSelector:nearBottom])
            return;
        objc_setAssociatedObject(strongController, kSPKProfileGridAutoLoadObjectsKey, @(objectCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSUInteger used = [objc_getAssociatedObject(strongController, kSPKProfileGridAutoLoadCountKey) unsignedIntegerValue] + 1;
        objc_setAssociatedObject(strongController, kSPKProfileGridAutoLoadCountKey, @(used), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(strongController, nearBottom, scrollView, YES);
    });
}

#pragma mark - Grid

static id SPKProfileGridProcessObjects(UIViewController *controller, id objects) {
    if (!SPKProfileGridIsPostsTab(controller))
        return objects;
    UIViewController *profile = SPKProfileGridProfileControllerForController(controller);
    SPKProfileGridMode mode = SPKProfileGridModeForProfile(profile);
    id feedSource = SPKProfileGridFeedSourceForController(controller);
    if (feedSource)
        objc_setAssociatedObject(feedSource, kSPKProfileGridSourceModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (mode != SPKProfileGridModePostsOnly)
        return objects;
    NSUInteger removed = 0;
    NSArray *filtered = SPKProfileGridFilteredObjects(objects, &removed);
    SPKProfileGridAutoLoadIfNeeded(controller, feedSource, [objects count], removed);
    return filtered;
}

static id (*orig_userGridObjects)(id, SEL, id);
static id hooked_userGridObjects(id self, SEL _cmd, id adapter) {
    return SPKProfileGridProcessObjects(self, orig_userGridObjects(self, _cmd, adapter));
}

static void SPKProfileGridReloadPostsTab(UIViewController *profile) {
    id controllers = nil;
    @try {
        controllers = [profile respondsToSelector:@selector(tabViewControllersForIdentifiers)] ? ((id (*)(id, SEL))objc_msgSend)(profile, @selector(tabViewControllersForIdentifiers)) : nil;
    } @catch (__unused NSException *exception) {
    }
    NSArray *candidates = [controllers isKindOfClass:[NSDictionary class]] ? [controllers allValues] : nil;
    for (UIViewController *controller in candidates) {
        if (![controller isKindOfClass:[UIViewController class]] || !SPKProfileGridIsPostsTab(controller))
            continue;
        objc_setAssociatedObject(controller, kSPKProfileGridAutoLoadCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kSPKProfileGridAutoLoadObjectsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIScrollView *scrollView = [controller respondsToSelector:@selector(scrollView)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(scrollView)) : nil;
        id adapter = [scrollView isKindOfClass:[UICollectionView class]] ? ((UICollectionView *)scrollView).dataSource : nil;
        if ([adapter respondsToSelector:@selector(performUpdatesAnimated:completion:)])
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, @selector(performUpdatesAnimated:completion:), YES, nil);
    }
}

#pragma mark - Tapped feed

static id SPKProfileGridServiceFeedSource(id service) {
    static const char *const names[] = {"_feedNetworkSource", "feedNetworkSource", NULL};
    return SPKProfileGridObjectIvar(service, names);
}

static BOOL SPKProfileGridServiceFilters(id service) {
    static Class serviceClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        serviceClass = SPKResolveIGClass(@"IGProfileContextualFeed.IGProfileContextualFeedServiceProvider", @"IGProfileContextualFeedServiceProvider");
    });
    if (!serviceClass || ![service isKindOfClass:serviceClass])
        return NO;
    return SPKProfileGridSourceIsPostsOnly(SPKProfileGridServiceFeedSource(service));
}

static id SPKProfileGridServiceFiltered(id service, id objects) {
    if (!SPKProfileGridServiceFilters(service))
        return objects;
    return SPKProfileGridFilteredObjects(objects, NULL);
}

static id (*orig_servicePosts)(id, SEL);
static id hooked_servicePosts(id self, SEL _cmd) {
    return SPKProfileGridServiceFiltered(self, orig_servicePosts(self, _cmd));
}

static unsigned long long (*orig_serviceItemCount)(id, SEL);
static unsigned long long hooked_serviceItemCount(id self, SEL _cmd) {
    if (!SPKProfileGridServiceFilters(self))
        return orig_serviceItemCount(self, _cmd);
    id posts = [self respondsToSelector:@selector(posts)] ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(posts)) : nil;
    return [posts isKindOfClass:[NSArray class]] ? [posts count] : orig_serviceItemCount(self, _cmd);
}

static id (*orig_serviceItemsAfter)(id, SEL, id);
static id hooked_serviceItemsAfter(id self, SEL _cmd, id after) {
    return SPKProfileGridServiceFiltered(self, orig_serviceItemsAfter(self, _cmd, after));
}

static void (*orig_feedDidFinishLoading)(id, SEL, id, id, BOOL);
static void hooked_feedDidFinishLoading(id self, SEL _cmd, id service, id objects, BOOL loadMore) {
    orig_feedDidFinishLoading(self, _cmd, service, SPKProfileGridServiceFiltered(service, objects), loadMore);
}

static void (*orig_feedDidChange)(id, SEL, id, id);
static void hooked_feedDidChange(id self, SEL _cmd, id service, id objects) {
    orig_feedDidChange(self, _cmd, service, SPKProfileGridServiceFiltered(service, objects));
}

#pragma mark - Chevron

static BOOL SPKProfileGridIsGridSegment(id segment) {
    static Class gridSegmentClass;
    static Class legacySegmentClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gridSegmentClass = objc_getClass("_TtC15IGProfilePluginP33_8E4C0B5300E00051E8F92B34A684A10523IGProfileGridTabSegment");
        legacySegmentClass = objc_getClass("IGProfileTabControlSegment");
    });
    if (!segment)
        return NO;
    if (gridSegmentClass && [segment isKindOfClass:gridSegmentClass])
        return YES;
    long long tabType = -1;
    return legacySegmentClass && [segment isKindOfClass:legacySegmentClass] && SPKProfileGridReadIntegerIvar(segment, "_tabType", &tabType) && tabType == kSPKProfileGridTabType;
}

static BOOL hooked_gridSegmentShouldShowChevron(id self, SEL _cmd) {
    return SPKProfileGridFilterMenuEnabled();
}

static BOOL (*orig_legacySegmentShouldShowChevron)(id, SEL);
static BOOL hooked_legacySegmentShouldShowChevron(id self, SEL _cmd) {
    if (SPKProfileGridFilterMenuEnabled() && SPKProfileGridIsGridSegment(self)) {
        return YES;
    }
    return orig_legacySegmentShouldShowChevron ? orig_legacySegmentShouldShowChevron(self, _cmd) : NO;
}

// Instagram's checkmark, as the Reels sort menu marks its selected option.
static UIImage *SPKProfileGridCheckmarkImage(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typedef UIImage *(*SPKIconAssetsImageFn)(uint32_t, void *);
        SPKIconAssetsImageFn iconAssetsImage = (SPKIconAssetsImageFn)dlsym(RTLD_DEFAULT, "IGIconAssetsImage");
        UIImage *icon = iconAssetsImage ? iconAssetsImage(0xf795b2c9, NULL) : nil;
        if (!icon)
            icon = [SPKAssetUtils instagramIconNamed:@"ig_icon_check_outline_24"];
        SEL templateSelector = NSSelectorFromString(@"ig_templateImage");
        if ([icon respondsToSelector:templateSelector])
            image = ((id (*)(id, SEL))objc_msgSend)(icon, templateSelector);
        image = image ?: [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

static UICollectionViewCell *SPKProfileGridTabCellForControl(id control, long long index) {
    static const char *const collectionNames[] = {"_collectionView", NULL};
    UICollectionView *collectionView = SPKProfileGridObjectIvar(control, collectionNames);
    if (![collectionView isKindOfClass:[UICollectionView class]] || index < 0)
        return nil;
    return [collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
}

static void SPKProfileGridSetChevronSelected(UICollectionViewCell *cell, BOOL selected) {
    if ([cell respondsToSelector:@selector(setChevronSelected:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cell, @selector(setChevronSelected:), selected);
}

@interface SPKProfileGridMenuDelegate : NSObject
@property (nonatomic, weak) UICollectionViewCell *cell;
@property (nonatomic, strong) id menu;
@end

@implementation SPKProfileGridMenuDelegate

- (void)menuDidDismiss {
    SPKProfileGridSetChevronSelected(self.cell, NO);
    self.menu = nil;
}

@end

static SPKProfileGridMenuDelegate *sSPKProfileGridMenuDelegate;

static id SPKProfileGridMenuItem(NSString *title, BOOL selected, void (^handler)(void)) {
    Class itemClass = NSClassFromString(@"IGDSMenuItem");
    SEL initSelector = @selector(initWithTitle:image:handler:);
    if (!itemClass || ![itemClass instancesRespondToSelector:initSelector])
        return nil;
    void (^itemHandler)(id) = ^(__unused id item) {
        handler();
    };
    id item = ((id (*)(id, SEL, id, id, id))objc_msgSend)([itemClass alloc], initSelector, title, nil, itemHandler);
    if (selected && [item respondsToSelector:@selector(setAccessoryImage:)])
        ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setAccessoryImage:), SPKProfileGridCheckmarkImage());
    return item;
}

// The menu is laid out around the anchor's x, so a menu under the first tab
// can run past the screen edge when the tab is narrower than the menu (the
// full-width tab strip without pills). Its width is measured from the menu view
// Instagram already built, and the anchor moves in just far enough to keep the
// whole menu inside the margins.
static const CGFloat kSPKProfileGridMenuMargin = 16.0;

static UIView *SPKProfileGridMenuContentView(id menu) {
    static const char *const prismNames[] = {"_prismMenu", NULL};
    static const char *const legacyNames[] = {"_menuView", NULL};
    id prism = SPKProfileGridObjectIvar(menu, prismNames);
    UIView *view = [prism respondsToSelector:@selector(menuView)] ? ((id (*)(id, SEL))objc_msgSend)(prism, @selector(menuView)) : nil;
    if (![view isKindOfClass:[UIView class]])
        view = SPKProfileGridObjectIvar(menu, legacyNames);
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

// Widest menu seen on screen this session. The pre-present measurement can come
// back short, and once the anchor sits too close to an edge Instagram narrows
// the menu instead of moving it, so the measured and the observed widths are
// both kept and the larger one wins.
static CGFloat sSPKProfileGridObservedMenuWidth;

static CGFloat SPKProfileGridMeasuredMenuWidth(id menu, CGFloat available) {
    UIView *view = SPKProfileGridMenuContentView(menu);
    CGFloat width = sSPKProfileGridObservedMenuWidth;
    if (view) {
        width = MAX(width, [view sizeThatFits:CGSizeMake(available, CGFLOAT_MAX)].width);
        if ([view respondsToSelector:@selector(menuSize)])
            width = MAX(width, ((CGSize (*)(id, SEL))objc_msgSend)(view, @selector(menuSize)).width);
    }
    return width;
}

static CGFloat SPKProfileGridClampedMenuX(CGFloat width, CGFloat x, CGFloat screenWidth) {
    CGFloat available = screenWidth - 2.0 * kSPKProfileGridMenuMargin;
    if (width <= 0.0 || available <= 0.0)
        return x;
    CGFloat half = MIN(width, available) / 2.0;
    return MIN(MAX(x, kSPKProfileGridMenuMargin + half), screenWidth - kSPKProfileGridMenuMargin - half);
}

static BOOL SPKProfileGridPresentFilterMenu(UIViewController *profile, id control, long long index) {
    Class menuClass = NSClassFromString(@"IGDSMenu");
    SEL presentSelector = @selector(presentAtPointInWindowCoordinates:direction:);
    if (!profile || !menuClass || ![menuClass instancesRespondToSelector:@selector(initWithMenuItems:)])
        return NO;

    SPKProfileGridMode current = SPKProfileGridModeForProfile(profile);
    __weak UIViewController *weakProfile = profile;
    id (^option)(NSString *, SPKProfileGridMode) = ^id(NSString *title, SPKProfileGridMode mode) {
        return SPKProfileGridMenuItem(title, current == mode, ^{
            UIViewController *target = weakProfile;
            if (!target || SPKProfileGridModeForProfile(target) == mode)
                return;
            objc_setAssociatedObject(target, kSPKProfileGridModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SPKProfileGridReloadPostsTab(target);
        });
    };
    id allItem = option(SPKL(@"PROFILE_GRID_FILTER_MENU_ALL_ACTION"), SPKProfileGridModeAll);
    id postsItem = option(SPKL(@"PROFILE_GRID_FILTER_MENU_POSTS_ONLY_ACTION"), SPKProfileGridModePostsOnly);
    if (!allItem || !postsItem)
        return NO;

    id menu = ((id (*)(id, SEL, id))objc_msgSend)([menuClass alloc], @selector(initWithMenuItems:), @[ allItem, postsItem ]);
    if (!menu)
        return NO;

    // 410.1.0's IGDSMenu has no point-based present; the prism menu it builds
    // for its items does, and still reports dismissal back through IGDSMenu.
    static const char *const prismNames[] = {"_prismMenu", NULL};
    id presenter = [menu respondsToSelector:presentSelector] ? menu : nil;
    long long direction = 5;
    if (!presenter) {
        id prism = SPKProfileGridObjectIvar(menu, prismNames);
        if ([prism respondsToSelector:presentSelector]) {
            presenter = prism;
            SEL mapDirection = NSSelectorFromString(@"_prismDirectionFromDirection:");
            if ([menu respondsToSelector:mapDirection])
                direction = ((long long (*)(id, SEL, long long))objc_msgSend)(menu, mapDirection, 5);
        }
        if (!presenter)
            return NO;
    }

    // Same anchor as the Reels sort menu: the tab cell's horizontal center,
    // 8pt below the cell.
    UICollectionViewCell *cell = SPKProfileGridTabCellForControl(control, index);
    UIView *anchor = cell ?: ([control isKindOfClass:[UIView class]] ? control : profile.view);
    CGRect frame = [anchor convertRect:anchor.bounds toView:nil];
    CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMaxY(frame) + 8.0);
    UIWindow *window = anchor.window;
    CGFloat screenWidth = CGRectGetWidth(window ? window.bounds : UIScreen.mainScreen.bounds);
    CGFloat measuredWidth = SPKProfileGridMeasuredMenuWidth(menu, screenWidth - 2.0 * kSPKProfileGridMenuMargin);
    point.x = SPKProfileGridClampedMenuX(measuredWidth, point.x, screenWidth);

    if (!sSPKProfileGridMenuDelegate)
        sSPKProfileGridMenuDelegate = [SPKProfileGridMenuDelegate new];
    sSPKProfileGridMenuDelegate.cell = cell;
    sSPKProfileGridMenuDelegate.menu = menu;
    if ([menu respondsToSelector:@selector(setDelegate:)])
        ((void (*)(id, SEL, id))objc_msgSend)(menu, @selector(setDelegate:), sSPKProfileGridMenuDelegate);

    SPKProfileGridSetChevronSelected(cell, YES);
    ((void (*)(id, SEL, CGPoint, long long))objc_msgSend)(presenter, presentSelector, point, direction);
    // Remember the real width for the next menu, in case this one was measured
    // short.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *content = SPKProfileGridMenuContentView(menu);
        CGFloat shown = content.window ? CGRectGetWidth([content convertRect:content.bounds toView:nil]) : 0.0;
        sSPKProfileGridObservedMenuWidth = MAX(sSPKProfileGridObservedMenuWidth, shown);
    });
    return YES;
}

// The grid tab's chevron opens the filter menu; Instagram's handler only knows
// the Reels sort.
static void (*orig_profileDidTapChevron)(id, SEL, id, long long);
static void hooked_profileDidTapChevron(id self, SEL _cmd, id control, long long index) {
    NSArray *segments = [control respondsToSelector:@selector(segments)] ? ((id (*)(id, SEL))objc_msgSend)(control, @selector(segments)) : nil;
    id segment = ([segments isKindOfClass:[NSArray class]] && index >= 0 && index < (long long)segments.count) ? segments[index] : nil;
    if (SPKProfileGridFilterMenuEnabled() && SPKProfileGridIsGridSegment(segment)) {
        if (!SPKProfileGridPresentFilterMenu(self, control, index))
            SPKWarnLog(@"ProfileGrid", @"filter menu unavailable: IGDSMenu API missing");
        return;
    }
    orig_profileDidTapChevron(self, _cmd, control, index);
}

// Re-tapping the selected posts tab works like the Reels tab: Instagram first
// scrolls the tab strip to the top, and a tap that finds it already there opens
// the filter menu. Instagram's re-tap scroll sets the grid's offset at once
// (inside an animation block), so an unchanged offset means it was already at
// the top.
static void (*orig_profileTabControlValueChanged)(id, SEL, id);
static void hooked_profileTabControlValueChanged(id self, SEL _cmd, id control) {
    if (!SPKProfileGridFilterMenuEnabled() || ![control respondsToSelector:@selector(selectedIndex)] || ![control respondsToSelector:@selector(segments)]) {
        orig_profileTabControlValueChanged(self, _cmd, control);
        return;
    }
    long long index = ((long long (*)(id, SEL))objc_msgSend)(control, @selector(selectedIndex));
    NSArray *segments = ((id (*)(id, SEL))objc_msgSend)(control, @selector(segments));
    id segment = ([segments isKindOfClass:[NSArray class]] && index >= 0 && index < (long long)segments.count) ? segments[index] : nil;
    UIViewController *current = [self respondsToSelector:@selector(currentPageViewController)] ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(currentPageViewController)) : nil;
    if (!SPKProfileGridIsGridSegment(segment) || ![current isKindOfClass:[UIViewController class]] || !SPKProfileGridIsPostsTab(current)) {
        orig_profileTabControlValueChanged(self, _cmd, control);
        return;
    }
    UIScrollView *scrollView = [current respondsToSelector:@selector(scrollView)] ? ((id (*)(id, SEL))objc_msgSend)(current, @selector(scrollView)) : nil;
    CGFloat before = [scrollView isKindOfClass:[UIScrollView class]] ? scrollView.contentOffset.y : NAN;
    orig_profileTabControlValueChanged(self, _cmd, control);
    if (isnan(before) || fabs(scrollView.contentOffset.y - before) > 0.5)
        return;
    SPKProfileGridPresentFilterMenu(self, control, index);
}

#pragma mark - Install

static BOOL SPKProfileGridHook(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    if (cls && class_getInstanceMethod(cls, selector)) {
        MSHookMessageEx(cls, selector, replacement, original);
        return YES;
    }
    return NO;
}

// Newer builds register the Swift class under its mangled name; 410.1.0 only
// has the bare Objective-C name. Prefer the mangled one when it exists.
static const char *SPKProfileGridClassName(const char *mangled, const char *bare) {
    return objc_getClass(mangled) ? mangled : bare;
}

FOUNDATION_EXPORT void SPKInstallProfileGridHideReelsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Posts tab grid.
        SPKProfileGridHook(SPKProfileGridClassName("_TtC9IGProfile35IGProfileUserGridFeedViewController", "IGProfileUserGridFeedViewController"),
                           @selector(objectsForListAdapter:), (IMP)hooked_userGridObjects, (IMP *)&orig_userGridObjects);

        // Feed opened from a grid post.
        const char *service = SPKProfileGridClassName("_TtC23IGProfileContextualFeed38IGProfileContextualFeedServiceProvider", "IGProfileContextualFeedServiceProvider");
        SPKProfileGridHook(service, @selector(posts), (IMP)hooked_servicePosts, (IMP *)&orig_servicePosts);
        SPKProfileGridHook(service, @selector(itemCount), (IMP)hooked_serviceItemCount, (IMP *)&orig_serviceItemCount);
        SPKProfileGridHook(service, @selector(allItemsVisibleAfter:), (IMP)hooked_serviceItemsAfter, (IMP *)&orig_serviceItemsAfter);
        const char *feedController = SPKProfileGridClassName("_TtC30IGContextualFeedViewController30IGContextualFeedViewController", "IGContextualFeedViewController");
        SPKProfileGridHook(feedController, @selector(contextualFeedService:didFinishLoadingWithObjects:isLoadMoreFetch:),
                           (IMP)hooked_feedDidFinishLoading, (IMP *)&orig_feedDidFinishLoading);
        SPKProfileGridHook(feedController, @selector(contextualFeedService:didChangeToObjects:),
                           (IMP)hooked_feedDidChange, (IMP *)&orig_feedDidChange);

        // Chevron on the posts tab.
        Class gridSegment = objc_getClass("_TtC15IGProfilePluginP33_8E4C0B5300E00051E8F92B34A684A10523IGProfileGridTabSegment");
        if (gridSegment) {
            SEL chevron = @selector(shouldShowChevron);
            if (class_getInstanceMethod(gridSegment, chevron))
                MSHookMessageEx(gridSegment, chevron, (IMP)hooked_gridSegmentShouldShowChevron, NULL);
            else
                class_addMethod(gridSegment, chevron, (IMP)hooked_gridSegmentShouldShowChevron, "B@:");
        }
        SPKProfileGridHook("IGProfileTabControlSegment", @selector(shouldShowChevron),
                           (IMP)hooked_legacySegmentShouldShowChevron, (IMP *)&orig_legacySegmentShouldShowChevron);
        SPKProfileGridHook("IGProfileViewController", @selector(segmentedTabControl:didTapChevronAtIndex:),
                           (IMP)hooked_profileDidTapChevron, (IMP *)&orig_profileDidTapChevron);
        SPKProfileGridHook("IGProfileViewController", @selector(_tabControlValueChanged:),
                           (IMP)hooked_profileTabControlValueChanged, (IMP *)&orig_profileTabControlValueChanged);
    });
}
