#import "../../App/SPKPerfMeter.h"
#import "../../Shared/UI/SPKChromeGlassMirror.h"
#import "../../Utils.h"
#import "InstantsHeaderItems.h"
#import "InstantsManualSeen.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// * Instants navigation bar header
// On accounts with ig_ios_instants_native_header, Instagram builds the Instants
// header as a system navigation bar: a QuickSnap navigation bar controller fills
// the screen's navigation item with bar button items whose custom views are its
// private "chrome host" views (dismiss on the leading side; archive and the
// camera/viewer switcher on the trailing side). There is no header view to add
// subviews to, so Sparkle's buttons become bar button items of their own, placed
// on the leading side of Instagram's trailing items whenever Instagram sets them.
// The controller resets its items as the screen changes state, so the items are
// re-added on every set rather than once. Which of them shows follows the same
// rules as the header view variant, through the item's hidden flag.

static const char *const kSPKInstantsChromeHostPrefix = "_TtC46IGQuickSnapNavigationV3NavigationBarController";
static const char *const kSPKInstantsChromeButtonHostClass =
    "_TtC46IGQuickSnapNavigationV3NavigationBarControllerP33_BABC63A6A10B0E28950318F5C2BE680639IGQuickSnapNavigationV3ChromeButtonHost";
static const char *const kSPKInstantsChromeSwitcherHostClass =
    "_TtC46IGQuickSnapNavigationV3NavigationBarControllerP33_BABC63A6A10B0E28950318F5C2BE680641IGQuickSnapNavigationV3ChromeSwitcherHost";

static const void *kSPKInstantsBarItemsKey = &kSPKInstantsBarItemsKey;

typedef NS_ENUM(NSUInteger, SPKInstantsBarItemSlot) {
    SPKInstantsBarItemSlotAction = 0,
    SPKInstantsBarItemSlotMarkSeen,
    SPKInstantsBarItemSlotGallery,
    SPKInstantsBarItemSlotCount,
};

/// Navigation items that currently carry Sparkle items. Weak, so a closed Instants
/// screen drops out on its own.
static NSHashTable<UINavigationItem *> *sTrackedNavigationItems = nil;
/// Set while Sparkle calls back into a setter, so its own write is not augmented again.
static BOOL sApplyingItems = NO;
static BOOL sUpdateScheduled = NO;

// MARK: - Host detection

/// The chrome host views are private Swift classes of Instagram's QuickSnap navigation
/// bar controller module; matching the module prefix survives a renamed host subclass.
static BOOL SPKInstantsIsChromeHost(UIView *view) {
    if (!view)
        return NO;
    return strncmp(class_getName(view.class), kSPKInstantsChromeHostPrefix, strlen(kSPKInstantsChromeHostPrefix)) == 0;
}

static BOOL SPKInstantsItemIsChromeHost(UIBarButtonItem *item) {
    return [item isKindOfClass:UIBarButtonItem.class] && SPKInstantsIsChromeHost(item.customView);
}

static NSArray<UIBarButtonItem *> *SPKInstantsSparkleItems(UINavigationItem *navigationItem) {
    return objc_getAssociatedObject(navigationItem, kSPKInstantsBarItemsKey);
}

static BOOL SPKInstantsIsSparkleItem(UINavigationItem *navigationItem, UIBarButtonItem *item) {
    // Checked for nil first: a message to a nil array returns 0, not NSNotFound.
    NSArray<UIBarButtonItem *> *ours = SPKInstantsSparkleItems(navigationItem);
    return item && ours && [ours indexOfObjectIdenticalTo:item] != NSNotFound;
}

// MARK: - Items

static UIView *SPKInstantsSizedBarView(UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *width = [view.widthAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *height = [view.heightAnchor constraintEqualToConstant:44.0];
    width.priority = UILayoutPriorityRequired - 1;
    height.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[ width, height ]];
    return view;
}

static NSArray<UIBarButtonItem *> *SPKInstantsEnsureSparkleItems(UINavigationItem *navigationItem) {
    NSArray<UIBarButtonItem *> *items = SPKInstantsSparkleItems(navigationItem);
    if (items.count == SPKInstantsBarItemSlotCount)
        return items;

    UIView *views[SPKInstantsBarItemSlotCount] = {
        SPKInstantsSizedBarView(SPKInstantsNewActionButton()),
        SPKInstantsSizedBarView(SPKInstantsNewMarkSeenButton()),
        SPKInstantsSizedBarView(SPKInstantsNewGalleryButtonHost()),
    };
    NSMutableArray<UIBarButtonItem *> *built = [NSMutableArray arrayWithCapacity:SPKInstantsBarItemSlotCount];
    for (NSUInteger slot = 0; slot < SPKInstantsBarItemSlotCount; slot++) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:views[slot]];
        // Shown by the first update once the screen's state is known.
        if (@available(iOS 16.0, *))
            item.hidden = YES;
        else
            views[slot].hidden = YES;
        [built addObject:item];
    }
    built[SPKInstantsBarItemSlotMarkSeen].accessibilityLabel = views[SPKInstantsBarItemSlotMarkSeen].accessibilityLabel;
    objc_setAssociatedObject(navigationItem, kSPKInstantsBarItemsKey, built, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return built;
}

/// Instagram's trailing items each sit in their own glass capsule or share one; ours
/// follow whichever choice it made for the item they sit next to.
static void SPKInstantsMatchSharedBackground(NSArray<UIBarButtonItem *> *ours, UIBarButtonItem *neighbour) {
    SEL getter = NSSelectorFromString(@"hidesSharedBackground");
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    if (![neighbour respondsToSelector:getter])
        return;
    BOOL hides = ((BOOL (*)(id, SEL))objc_msgSend)(neighbour, getter);
    for (UIBarButtonItem *item in ours) {
        if ([item respondsToSelector:setter])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, hides);
    }
}

// MARK: - Column order

static const void *kSPKInstantsInColumnKey = &kSPKInstantsInColumnKey;

/// Whether the screen's items stand in a vertical column (a foldable's side bar)
/// rather than a horizontal header, as last measured.
static BOOL SPKInstantsItemsInColumn(UINavigationItem *navigationItem) {
    return [objc_getAssociatedObject(navigationItem, kSPKInstantsInColumnKey) boolValue];
}

static void SPKInstantsCollectHostViews(NSArray<UIBarButtonItem *> *items, NSMutableArray<UIView *> *hosts) {
    for (UIBarButtonItem *item in items) {
        if (SPKInstantsItemIsChromeHost(item) && item.customView.window && !item.customView.hidden)
            [hosts addObject:item.customView];
    }
}

/// Measured from Instagram's own items: in a column they share one x and stack,
/// in a header they share one y. Unknown (-1) until two of them are on screen.
static NSInteger SPKInstantsMeasureColumn(UINavigationItem *navigationItem) {
    NSMutableArray<UIView *> *hosts = [NSMutableArray array];
    SPKInstantsCollectHostViews(navigationItem.leftBarButtonItems, hosts);
    SPKInstantsCollectHostViews(navigationItem.rightBarButtonItems, hosts);
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in navigationItem.leadingItemGroups)
            SPKInstantsCollectHostViews(group.barButtonItems, hosts);
        for (UIBarButtonItemGroup *group in navigationItem.trailingItemGroups)
            SPKInstantsCollectHostViews(group.barButtonItems, hosts);
    }
    if (hosts.count < 2)
        return -1;
    UIWindow *window = hosts.firstObject.window;
    CGRect first = [window convertRect:hosts[0].bounds fromView:hosts[0]];
    for (NSUInteger i = 1; i < hosts.count; i++) {
        if (hosts[i].window != window)
            continue;
        CGRect other = [window convertRect:hosts[i].bounds fromView:hosts[i]];
        CGFloat dx = fabs(CGRectGetMidX(other) - CGRectGetMidX(first));
        CGFloat dy = fabs(CGRectGetMidY(other) - CGRectGetMidY(first));
        if (dx < 4.0 && dy > 20.0)
            return 1;
        if (dy < 4.0 && dx > 20.0)
            return 0;
    }
    return -1;
}

/// `rightBarButtonItems` runs from the trailing edge inwards, so Sparkle's items go after
/// the last Instagram host: action next to it, then mark seen. The gallery item shares
/// the action item's slot (they never show together), so it goes last.
/// In a column UIKit stacks the items leading to trailing from the top, so there they
/// go before Instagram's instead: under its buttons, the action item above mark seen.
static NSArray<UIBarButtonItem *> *SPKInstantsAugmentedRightItems(UINavigationItem *navigationItem,
                                                                  NSArray<UIBarButtonItem *> *items) {
    NSMutableArray<UIBarButtonItem *> *stripped = [NSMutableArray arrayWithCapacity:items.count + 3];
    NSInteger lastHost = -1;
    for (UIBarButtonItem *item in items) {
        if (SPKInstantsIsSparkleItem(navigationItem, item))
            continue;
        if (SPKInstantsItemIsChromeHost(item))
            lastHost = (NSInteger)stripped.count;
        [stripped addObject:item];
    }
    if (lastHost < 0)
        return nil;
    NSArray<UIBarButtonItem *> *ours = SPKInstantsEnsureSparkleItems(navigationItem);
    SPKInstantsMatchSharedBackground(ours, stripped[lastHost]);
    if (SPKInstantsItemsInColumn(navigationItem)) {
        NSInteger firstHost = 0;
        while (firstHost < (NSInteger)stripped.count && !SPKInstantsItemIsChromeHost(stripped[firstHost]))
            firstHost++;
        NSArray<UIBarButtonItem *> *columnOrder = @[
            ours[SPKInstantsBarItemSlotMarkSeen], ours[SPKInstantsBarItemSlotAction], ours[SPKInstantsBarItemSlotGallery]
        ];
        [stripped insertObjects:columnOrder atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(firstHost, columnOrder.count)]];
        return stripped;
    }
    [stripped insertObjects:ours atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(lastHost + 1, ours.count)]];
    return stripped;
}

/// `trailingItemGroups` run from the leading edge, so Sparkle's group goes just before
/// the first group holding an Instagram host, with its items in leading-to-trailing order.
API_AVAILABLE(ios(16.0))
static NSArray<UIBarButtonItemGroup *> *SPKInstantsAugmentedTrailingGroups(UINavigationItem *navigationItem,
                                                                          NSArray<UIBarButtonItemGroup *> *groups) {
    NSMutableArray<UIBarButtonItemGroup *> *stripped = [NSMutableArray arrayWithCapacity:groups.count + 1];
    NSInteger firstHost = -1;
    NSInteger lastHost = -1;
    UIBarButtonItem *neighbour = nil;
    for (UIBarButtonItemGroup *group in groups) {
        BOOL isOurs = NO;
        for (UIBarButtonItem *item in group.barButtonItems) {
            if (SPKInstantsIsSparkleItem(navigationItem, item)) {
                isOurs = YES;
                break;
            }
        }
        if (isOurs)
            continue;
        for (UIBarButtonItem *item in group.barButtonItems) {
            if (SPKInstantsItemIsChromeHost(item)) {
                if (firstHost < 0) {
                    firstHost = (NSInteger)stripped.count;
                    neighbour = item;
                }
                lastHost = (NSInteger)stripped.count;
                break;
            }
        }
        [stripped addObject:group];
    }
    if (firstHost < 0)
        return nil;
    NSArray<UIBarButtonItem *> *ours = SPKInstantsEnsureSparkleItems(navigationItem);
    SPKInstantsMatchSharedBackground(ours, neighbour);
    if (SPKInstantsItemsInColumn(navigationItem)) {
        // Under Instagram's buttons in a column (see SPKInstantsAugmentedRightItems).
        NSArray<UIBarButtonItem *> *columnOrder = @[
            ours[SPKInstantsBarItemSlotGallery], ours[SPKInstantsBarItemSlotAction], ours[SPKInstantsBarItemSlotMarkSeen]
        ];
        [stripped insertObject:[UIBarButtonItemGroup fixedGroupWithRepresentativeItem:nil items:columnOrder]
                       atIndex:(NSUInteger)lastHost + 1];
        return stripped;
    }
    NSArray<UIBarButtonItem *> *leadingToTrailing = [[ours reverseObjectEnumerator] allObjects];
    [stripped insertObject:[UIBarButtonItemGroup fixedGroupWithRepresentativeItem:nil items:leadingToTrailing]
                   atIndex:(NSUInteger)firstHost];
    return stripped;
}

// MARK: - Glass

static const void *kSPKInstantsBarGlassKey = &kSPKInstantsBarGlassKey;

/// The glass behind one of Instagram's own header buttons. Its media icon buttons draw
/// their own glass circle rather than relying on the bar's shared background, and only
/// in some configurations (none at all in others), so the live view is the reference.
static UIVisualEffectView *SPKInstantsFindHostGlass(UIView *view, NSUInteger depth) {
    static Class glassClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        glassClass = NSClassFromString(@"IGDSMediaButtonGlassBackgroundView");
    });
    if (!glassClass || depth > 4)
        return nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:glassClass])
            return (UIVisualEffectView *)subview;
        UIVisualEffectView *found = SPKInstantsFindHostGlass(subview, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

/// Gives each Sparkle item the same glass circle Instagram's items have, or none when
/// theirs have none. Placement and the menu-shaping radius come from the shared chrome
/// glass helper (as for the feed and profile header buttons), so a menu opens from the
/// whole circle; the effect instance is Instagram's own, so the look follows theirs.
static void SPKInstantsSyncItemGlass(NSArray<UIBarButtonItem *> *items, UIView *host) {
    UIVisualEffectView *reference = SPKInstantsFindHostGlass(host, 0);
    UIVisualEffect *effect = (reference && !reference.hidden && reference.alpha > 0.01) ? reference.effect : nil;
    for (UIBarButtonItem *item in items) {
        UIButton *button = SPKInstantsGalleryButtonInHost(item.customView);
        if (!button && [item.customView isKindOfClass:UIButton.class])
            button = (UIButton *)item.customView;
        if (!button)
            continue;
        UIVisualEffectView *glass = objc_getAssociatedObject(button, kSPKInstantsBarGlassKey);
        if (!effect) {
            if (glass) {
                [glass removeFromSuperview];
                objc_setAssociatedObject(button, kSPKInstantsBarGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            continue;
        }
        if (!glass) {
            glass = (UIVisualEffectView *)SPKChromeGlassMirrorMakeBubble(@"sparkle-instants-bar-glass");
            if (!glass)
                continue;
            glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            objc_setAssociatedObject(button, kSPKInstantsBarGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        SPKChromeGlassMirrorAttach(glass, button);
        // Setting the effect rebuilds the backdrop, so only on a real change.
        if (glass.effect != effect)
            glass.effect = effect;
    }
}

// MARK: - Visibility

static void SPKInstantsSetItemShown(UIBarButtonItem *item, BOOL shown) {
    if (@available(iOS 16.0, *)) {
        if (item.hidden == shown)
            item.hidden = !shown;
    } else if (item.customView.hidden == shown) {
        item.customView.hidden = !shown;
    }
}

/// Any of Instagram's host views in this navigation item, for its window.
static UIView *SPKInstantsHostViewForNavigationItem(UINavigationItem *navigationItem) {
    for (UIBarButtonItem *item in navigationItem.rightBarButtonItems) {
        if (SPKInstantsItemIsChromeHost(item) && item.customView.window)
            return item.customView;
    }
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in navigationItem.trailingItemGroups) {
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (SPKInstantsItemIsChromeHost(item) && item.customView.window)
                    return item.customView;
            }
        }
    }
    return nil;
}

/// Re-places Sparkle's items when the screen moves between a header and a column
/// (folding or unfolding with Instants open), since the two take opposite orders.
static void SPKInstantsSyncColumnOrder(UINavigationItem *navigationItem) {
    NSInteger measured = SPKInstantsMeasureColumn(navigationItem);
    if (measured < 0 || (BOOL)measured == SPKInstantsItemsInColumn(navigationItem) || sApplyingItems)
        return;
    objc_setAssociatedObject(navigationItem, kSPKInstantsInColumnKey, @(measured == 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL wasApplying = sApplyingItems;
    sApplyingItems = YES;
    NSArray *augmented = SPKInstantsAugmentedRightItems(navigationItem, navigationItem.rightBarButtonItems);
    if (augmented) {
        [navigationItem setRightBarButtonItems:augmented animated:NO];
    } else if (@available(iOS 16.0, *)) {
        NSArray *groups = SPKInstantsAugmentedTrailingGroups(navigationItem, navigationItem.trailingItemGroups);
        if (groups)
            navigationItem.trailingItemGroups = groups;
    }
    sApplyingItems = wasApplying;
    SPKLog(@"Instants", @"Navigation bar header: items now in %@ order", measured == 1 ? @"column" : @"header");
}

static void SPKInstantsUpdateNavigationItem(UINavigationItem *navigationItem) {
    NSArray<UIBarButtonItem *> *items = SPKInstantsSparkleItems(navigationItem);
    if (items.count != SPKInstantsBarItemSlotCount)
        return;
    SPKInstantsSyncColumnOrder(navigationItem);
    UIView *host = SPKInstantsHostViewForNavigationItem(navigationItem);
    UIWindow *window = host.window;
    if (host)
        SPKInstantsSyncItemGlass(items, host);

    BOOL consuming = window && SPKInstantsWindowIsConsuming(window);
    BOOL showAction = consuming && [SPKUtils getBoolPref:@"instants_action_btn"];
    if (consuming)
        SPKInstantsManualSeenRegisterEyeButtonHost(host);
    BOOL showMarkSeen = consuming && SPKInstantsManualSeenShouldShowEyeButton();
    BOOL showGallery = window && [SPKUtils getBoolPref:@"instants_camera_btn"] &&
                       SPKInstantsWindowWantsGalleryButton(window);

    UIBarButtonItem *actionItem = items[SPKInstantsBarItemSlotAction];
    UIButton *actionButton = (UIButton *)actionItem.customView;
    if (showAction) {
        SPKInstantsConfigureActionButtonIfNeeded(actionButton, host);
    } else if (!consuming && actionButton.menu) {
        // The header view variant drops its button when the viewer closes, so each viewing
        // session starts with a fresh menu; do the same here.
        actionButton.menu = nil;
    }
    SPKInstantsSetItemShown(actionItem, showAction);
    SPKInstantsSetItemShown(items[SPKInstantsBarItemSlotMarkSeen], showMarkSeen);

    UIBarButtonItem *galleryItem = items[SPKInstantsBarItemSlotGallery];
    if (showGallery)
        SPKInstantsRefreshGalleryButtonHost(galleryItem.customView);
    SPKInstantsSetItemShown(galleryItem, showGallery);

    NSUInteger state = (window ? 1 : 0) | (consuming ? 2 : 0) | (showAction ? 4 : 0) | (showMarkSeen ? 8 : 0) |
                       (showGallery ? 16 : 0);
    static const void *kSPKInstantsBarStateKey = &kSPKInstantsBarStateKey;
    NSNumber *previous = objc_getAssociatedObject(navigationItem, kSPKInstantsBarStateKey);
    if (!previous || previous.unsignedIntegerValue != state) {
        objc_setAssociatedObject(navigationItem, kSPKInstantsBarStateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SPKLog(@"Instants", @"Navigation bar header: window=%d consuming=%d action=%d markSeen=%d gallery=%d",
               window != nil, consuming, showAction, showMarkSeen, showGallery);
    }
}

static void SPKInstantsUpdateAllNavigationItems(void) {
    SPK_PERF_SCOPE(@"InstantsNavigationBarItems.update");
    for (UINavigationItem *navigationItem in sTrackedNavigationItems.allObjects)
        SPKInstantsUpdateNavigationItem(navigationItem);
}

void SPKInstantsNavigationBarItemsSetNeedsUpdate(void) {
    // Cheap no-op for the header view variant: nothing is ever tracked there.
    if (sTrackedNavigationItems.count == 0 || sUpdateScheduled)
        return;
    sUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sUpdateScheduled = NO;
        SPKInstantsUpdateAllNavigationItems();
    });
}

static void SPKInstantsTrack(UINavigationItem *navigationItem, BOOL tracked, NSString *via) {
    if (!sTrackedNavigationItems)
        sTrackedNavigationItems = [NSHashTable weakObjectsHashTable];
    BOOL wasTracked = [sTrackedNavigationItems containsObject:navigationItem];
    if (tracked)
        [sTrackedNavigationItems addObject:navigationItem];
    else
        [sTrackedNavigationItems removeObject:navigationItem];
    if (wasTracked != tracked)
        SPKLog(@"Instants", @"Navigation bar header: Sparkle items %@ via %@ (%p)", tracked ? @"added" : @"removed", via,
               navigationItem);
}

// MARK: - Hooks

static void (*orig_setRightBarButtonItemsAnimated)(UINavigationItem *, SEL, NSArray *, BOOL) = NULL;
static void (*orig_setRightBarButtonItems)(UINavigationItem *, SEL, NSArray *) = NULL;
static void (*orig_setRightBarButtonItemAnimated)(UINavigationItem *, SEL, UIBarButtonItem *, BOOL) = NULL;
static void (*orig_setRightBarButtonItem)(UINavigationItem *, SEL, UIBarButtonItem *) = NULL;
static void (*orig_setTrailingItemGroups)(UINavigationItem *, SEL, NSArray *) = NULL;

/// Shared by every right/trailing setter. Returns the array to hand to the original, or
/// nil to pass the caller's value through untouched (not an Instants header).
static NSArray *SPKInstantsRewriteRightItems(UINavigationItem *self, NSArray *items) {
    if (sApplyingItems || ![items isKindOfClass:NSArray.class])
        return nil;
    NSArray *augmented = SPKInstantsAugmentedRightItems(self, items);
    if (!augmented && SPKInstantsSparkleItems(self)) {
        // Instagram moved off its host items (another screen reusing this item): drop ours.
        NSMutableArray *stripped = [NSMutableArray arrayWithCapacity:items.count];
        for (UIBarButtonItem *item in items) {
            if (!SPKInstantsIsSparkleItem(self, item))
                [stripped addObject:item];
        }
        SPKInstantsTrack(self, NO, @"rightBarButtonItems");
        return stripped;
    }
    if (augmented)
        SPKInstantsTrack(self, YES, @"rightBarButtonItems");
    return augmented;
}

static void SPKInstantsAfterSet(UINavigationItem *self) {
    if ([sTrackedNavigationItems containsObject:self])
        SPKInstantsUpdateNavigationItem(self);
}

static void replaced_setRightBarButtonItemsAnimated(UINavigationItem *self, SEL _cmd, NSArray *items, BOOL animated) {
    NSArray *rewritten = SPKInstantsRewriteRightItems(self, items);
    BOOL wasApplying = sApplyingItems;
    sApplyingItems = YES;
    orig_setRightBarButtonItemsAnimated(self, _cmd, rewritten ?: items, animated);
    sApplyingItems = wasApplying;
    if (!wasApplying)
        SPKInstantsAfterSet(self);
}

static void replaced_setRightBarButtonItems(UINavigationItem *self, SEL _cmd, NSArray *items) {
    NSArray *rewritten = SPKInstantsRewriteRightItems(self, items);
    BOOL wasApplying = sApplyingItems;
    sApplyingItems = YES;
    orig_setRightBarButtonItems(self, _cmd, rewritten ?: items);
    sApplyingItems = wasApplying;
    if (!wasApplying)
        SPKInstantsAfterSet(self);
}

/// A single host item becomes a list so Sparkle's items can join it.
static void replaced_setRightBarButtonItemAnimated(UINavigationItem *self, SEL _cmd, UIBarButtonItem *item, BOOL animated) {
    if (!sApplyingItems && (SPKInstantsItemIsChromeHost(item) || SPKInstantsSparkleItems(self))) {
        [self setRightBarButtonItems:(item ? @[ item ] : @[]) animated:animated];
        return;
    }
    orig_setRightBarButtonItemAnimated(self, _cmd, item, animated);
}

static void replaced_setRightBarButtonItem(UINavigationItem *self, SEL _cmd, UIBarButtonItem *item) {
    if (!sApplyingItems && (SPKInstantsItemIsChromeHost(item) || SPKInstantsSparkleItems(self))) {
        [self setRightBarButtonItems:(item ? @[ item ] : @[]) animated:NO];
        return;
    }
    orig_setRightBarButtonItem(self, _cmd, item);
}

API_AVAILABLE(ios(16.0))
static void replaced_setTrailingItemGroups(UINavigationItem *self, SEL _cmd, NSArray *groups) {
    NSArray *rewritten = nil;
    if (!sApplyingItems && [groups isKindOfClass:NSArray.class]) {
        rewritten = SPKInstantsAugmentedTrailingGroups(self, groups);
        if (rewritten)
            SPKInstantsTrack(self, YES, @"trailingItemGroups");
    }
    BOOL wasApplying = sApplyingItems;
    sApplyingItems = YES;
    orig_setTrailingItemGroups(self, _cmd, rewritten ?: groups);
    sApplyingItems = wasApplying;
    if (!wasApplying)
        SPKInstantsAfterSet(self);
}

/// The hosts lay out whenever the bar changes state (the switcher swaps between camera
/// and viewer), which is also when Sparkle's items may need to change.
static void (*orig_buttonHostLayoutSubviews)(UIView *, SEL) = NULL;
static void (*orig_switcherHostLayoutSubviews)(UIView *, SEL) = NULL;

static BOOL SPKInstantsArrayHoldsCustomView(NSArray<UIBarButtonItem *> *items, UIView *view) {
    for (UIBarButtonItem *item in items) {
        if ([item isKindOfClass:UIBarButtonItem.class] && item.customView == view)
            return YES;
    }
    return NO;
}

/// Where a navigation item keeps the host, if it does: 1 = right items, 2 = trailing groups.
static NSInteger SPKInstantsNavigationItemHoldsHost(UINavigationItem *navigationItem, UIView *host) {
    if (SPKInstantsArrayHoldsCustomView(navigationItem.rightBarButtonItems, host))
        return 1;
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in navigationItem.trailingItemGroups) {
            if (SPKInstantsArrayHoldsCustomView(group.barButtonItems, host))
                return 2;
        }
    }
    return 0;
}

/// Instagram can fill the navigation item before Sparkle's setter hooks exist (the
/// Instants screen is built early) or through a path that skips them, so the hosts'
/// layout pass, which runs whenever the bar does, adopts the item directly: it finds the
/// navigation item holding this host and re-sets its items through the hooked setter when
/// Sparkle's are missing. Instagram replacing its items later is caught the same way.
static void SPKInstantsAdoptNavigationItemForHost(UIView *host) {
    if (!host.window || sApplyingItems)
        return;
    UINavigationBar *bar = nil;
    for (UIView *view = host.superview; view; view = view.superview) {
        if ([view isKindOfClass:UINavigationBar.class]) {
            bar = (UINavigationBar *)view;
            break;
        }
    }
    if (!bar)
        return;

    NSMutableArray<UINavigationItem *> *candidates = [NSMutableArray array];
    if (bar.topItem)
        [candidates addObject:bar.topItem];
    for (UINavigationItem *item in bar.items.reverseObjectEnumerator) {
        if (item != bar.topItem)
            [candidates addObject:item];
    }
    for (UINavigationItem *navigationItem in candidates) {
        NSInteger where = SPKInstantsNavigationItemHoldsHost(navigationItem, host);
        if (!where)
            continue;
        UIBarButtonItem *actionItem = SPKInstantsSparkleItems(navigationItem).firstObject;
        BOOL present = actionItem && (where == 1 ? SPKInstantsArrayHoldsCustomView(navigationItem.rightBarButtonItems,
                                                                                  actionItem.customView)
                                                 : SPKInstantsNavigationItemHoldsHost(navigationItem, actionItem.customView) == 2);
        if (present)
            return;
        // Applied directly rather than through the hooked setter: the screen's navigation
        // item can be a subclass that overrides the setters, which a UINavigationItem hook
        // never sees.
        BOOL wasApplying = sApplyingItems;
        sApplyingItems = YES;
        BOOL applied = NO;
        if (where == 1) {
            NSArray *augmented = SPKInstantsAugmentedRightItems(navigationItem, navigationItem.rightBarButtonItems);
            if (augmented) {
                [navigationItem setRightBarButtonItems:augmented animated:NO];
                applied = YES;
            }
        } else if (@available(iOS 16.0, *)) {
            NSArray *augmented = SPKInstantsAugmentedTrailingGroups(navigationItem, navigationItem.trailingItemGroups);
            if (augmented) {
                navigationItem.trailingItemGroups = augmented;
                applied = YES;
            }
        }
        sApplyingItems = wasApplying;
        SPKLog(@"Instants", @"Navigation bar header: adopting %s items from %s layout (%@, applied=%d, now %lu right items)",
               class_getName(navigationItem.class), class_getName(host.class),
               where == 1 ? @"rightBarButtonItems" : @"trailingItemGroups", applied,
               (unsigned long)navigationItem.rightBarButtonItems.count);
        if (applied) {
            SPKInstantsTrack(navigationItem, YES, @"layout adoption");
            SPKInstantsUpdateNavigationItem(navigationItem);
        }
        return;
    }
}

static void replaced_buttonHostLayoutSubviews(UIView *self, SEL _cmd) {
    orig_buttonHostLayoutSubviews(self, _cmd);
    SPKInstantsAdoptNavigationItemForHost(self);
    SPKInstantsNavigationBarItemsSetNeedsUpdate();
}

static void replaced_switcherHostLayoutSubviews(UIView *self, SEL _cmd) {
    orig_switcherHostLayoutSubviews(self, _cmd);
    SPKInstantsAdoptNavigationItemForHost(self);
    SPKInstantsNavigationBarItemsSetNeedsUpdate();
}

static void SPKInstantsHookIfPresent(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !class_getInstanceMethod(cls, selector)) {
        SPKLog(@"Instants", @"[Sparkle] Navigation bar hook target missing %s %@", cls ? class_getName(cls) : "(nil)",
               NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

extern "C" void SPKInstallInstantsNavigationBarItemsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // No navigation bar header in this build (IG 410 and older): nothing to support.
        Class buttonHost = objc_getClass(kSPKInstantsChromeButtonHostClass);
        Class switcherHost = objc_getClass(kSPKInstantsChromeSwitcherHostClass);
        if (!buttonHost && !switcherHost && !objc_getClass("_TtC46IGQuickSnapNavigationV3NavigationBarController46IGQuickSnapNavigationV3NavigationBarController"))
            return;

        Class navigationItem = UINavigationItem.class;
        SPKInstantsHookIfPresent(navigationItem, @selector(setRightBarButtonItems:animated:),
                                 (IMP)replaced_setRightBarButtonItemsAnimated, (IMP *)&orig_setRightBarButtonItemsAnimated);
        SPKInstantsHookIfPresent(navigationItem, @selector(setRightBarButtonItems:),
                                 (IMP)replaced_setRightBarButtonItems, (IMP *)&orig_setRightBarButtonItems);
        SPKInstantsHookIfPresent(navigationItem, @selector(setRightBarButtonItem:animated:),
                                 (IMP)replaced_setRightBarButtonItemAnimated, (IMP *)&orig_setRightBarButtonItemAnimated);
        SPKInstantsHookIfPresent(navigationItem, @selector(setRightBarButtonItem:),
                                 (IMP)replaced_setRightBarButtonItem, (IMP *)&orig_setRightBarButtonItem);
        if (@available(iOS 16.0, *)) {
            SPKInstantsHookIfPresent(navigationItem, @selector(setTrailingItemGroups:),
                                     (IMP)replaced_setTrailingItemGroups, (IMP *)&orig_setTrailingItemGroups);
        }
        SPKInstantsHookIfPresent(buttonHost, @selector(layoutSubviews), (IMP)replaced_buttonHostLayoutSubviews,
                                 (IMP *)&orig_buttonHostLayoutSubviews);
        SPKInstantsHookIfPresent(switcherHost, @selector(layoutSubviews), (IMP)replaced_switcherHostLayoutSubviews,
                                 (IMP *)&orig_switcherHostLayoutSubviews);
        SPKLog(@"Instants", @"Navigation bar header hooks installed (button host %d, switcher host %d)",
               buttonHost != Nil, switcherHost != Nil);
    });
}
