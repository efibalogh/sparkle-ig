#import "SPKSideColumn.h"

#import <objc/runtime.h>

#import "SPKChrome.h"
#import "SPKChromeGlassMirror.h"

static const CGFloat kSPKSideColumnGap = 10.0;
static const CGFloat kSPKSideColumnSlot = 48.0; // a vertical bar item's footprint
const CGFloat SPKSideColumnButtonSide = 48.0;
static const void *kSPKSideColumnDockFrameKey = &kSPKSideColumnDockFrameKey;

// Private Swift and UIKit classes, matched by name.
static BOOL SPKSideColumnClassContains(UIView *view, NSString *needle) {
    return [NSStringFromClass(view.class) containsString:needle];
}

UIView *SPKSideColumnItemContainer(UIView *view) {
    if (!view.window)
        return nil;
    for (UIView *current = view; current; current = current.superview) {
        if (SPKSideColumnClassContains(current, @"VerticalBarButtonContainer"))
            return current;
    }
    return nil;
}

CGRect SPKSideColumnGroupFrame(UIView *container, UIView *host, CGFloat *alpha) {
    if (!container.window || container.window != host.window)
        return CGRectNull;
    // The group's glass is the nearest glass interaction ancestor; without one
    // (renamed class) the item itself stands in for its group.
    CGRect group = [host convertRect:container.bounds fromView:container];
    BOOL foundGlass = NO;
    CGFloat opacity = 1.0;
    for (UIView *view = container; view && view != host; view = view.superview) {
        if (view.hidden)
            return CGRectNull;
        opacity *= view.alpha;
        if (!foundGlass && SPKSideColumnClassContains(view, @"GlassInteractionView")) {
            CGRect frame = [host convertRect:view.bounds fromView:view];
            if (CGRectGetWidth(frame) < kSPKSideColumnSlot * 1.6) {
                group = CGRectUnion(group, frame);
                foundGlass = YES;
            }
        }
    }
    if (alpha)
        *alpha = opacity;
    return group;
}

// A bar item's view is in the column when Instagram wrapped it for the column,
// or when it sits inside the window's side inset that the column occupies.
static BOOL SPKSideColumnViewIsInColumn(UIView *view, UIView *host) {
    if (SPKSideColumnItemContainer(view))
        return YES;
    CGRect frame = [host convertRect:view.bounds fromView:view];
    UIEdgeInsets insets = host.safeAreaInsets;
    if (insets.right > 20.0 && CGRectGetMinX(frame) >= CGRectGetWidth(host.bounds) - insets.right - 8.0)
        return YES;
    return insets.left > 20.0 && CGRectGetMaxX(frame) <= insets.left + 8.0;
}

CGRect SPKSideColumnLowestGroup(UINavigationItem *navigationItem, UIView *host, CGFloat *alpha) {
    CGRect lowest = CGRectNull;
    CGFloat lowestAlpha = 1.0;
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    [items addObjectsFromArray:navigationItem.leftBarButtonItems ?: @[]];
    [items addObjectsFromArray:navigationItem.rightBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items) {
        UIView *custom = item.customView;
        if (!custom.window || !SPKSideColumnViewIsInColumn(custom, host))
            continue;
        CGFloat groupAlpha = 1.0;
        CGRect group = SPKSideColumnGroupFrame(custom, host, &groupAlpha);
        if (CGRectIsNull(group))
            continue;
        if (CGRectIsNull(lowest) || CGRectGetMaxY(group) > CGRectGetMaxY(lowest)) {
            lowest = group;
            lowestAlpha = groupAlpha;
        }
    }
    if (alpha)
        *alpha = lowestAlpha;
    return lowest;
}

BOOL SPKSideColumnHoldsItems(UINavigationItem *navigationItem) {
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    [items addObjectsFromArray:navigationItem.leftBarButtonItems ?: @[]];
    [items addObjectsFromArray:navigationItem.rightBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items) {
        if (SPKSideColumnClassContains(item.customView, @"VerticalBarButtonContainer"))
            return YES;
    }
    return NO;
}

// UIKit's floating bar containers hold the navigation item groups, the column's
// among them (a split view adds its own for a pane's buttons; the tabs live in
// the tab bar). Remembered per window, looked up again once one goes away.
static NSArray<UIView *> *SPKSideColumnFloatingBarContainersRefreshing(UIView *root, BOOL refresh) {
    static NSHashTable<UIView *> *cached;
    static __weak UIWindow *cachedWindow;
    static CGSize cachedWindowSize;
    // A size change (unfolding, for one) builds a new container while the old one
    // stays in the window, so the window's size is part of the cache key.
    BOOL valid = cached.count > 0 && cachedWindow == root.window && CGSizeEqualToSize(cachedWindowSize, root.window.bounds.size);
    for (UIView *container in cached.allObjects) {
        if (container.window != root.window)
            valid = NO;
    }
    if (!valid || refresh) {
        cached = [NSHashTable weakObjectsHashTable];
        cachedWindow = root.window;
        cachedWindowSize = root.window.bounds.size;
        NSMutableArray<UIView *> *queue = root.window ? [NSMutableArray arrayWithObject:root.window] : [NSMutableArray array];
        for (NSUInteger i = 0; i < queue.count && i < 3000; i++) {
            if (SPKSideColumnClassContains(queue[i], @"FloatingBarContainerView")) {
                [cached addObject:queue[i]];
                continue;
            }
            [queue addObjectsFromArray:queue[i].subviews];
        }
    }
    NSMutableArray<UIView *> *inRoot = [NSMutableArray array];
    for (UIView *container in cached.allObjects) {
        if (container == root || [container isDescendantOfView:root])
            [inRoot addObject:container];
    }
    return inRoot;
}

static NSArray<UIView *> *SPKSideColumnFloatingBarContainers(UIView *root) {
    return SPKSideColumnFloatingBarContainersRefreshing(root, NO);
}

UIView *SPKSideColumnHostForView(UIView *view) {
    UIWindow *window = view.window;
    if (!window)
        return nil;
    // A pane's own floating bar shares a nearer ancestor with the view than the
    // column does, so the outermost common ancestor wins.
    UIView *host = nil;
    for (UIView *container in SPKSideColumnFloatingBarContainers(window)) {
        for (UIView *ancestor = container.superview; ancestor && ancestor != window; ancestor = ancestor.superview) {
            if (![view isDescendantOfView:ancestor])
                continue;
            if (!host || [host isDescendantOfView:ancestor])
                host = ancestor;
            break;
        }
    }
    return host;
}

static CGRect SPKSideColumnLowestVisibleGroupRefreshing(UIView *host, CGFloat *alpha, BOOL refresh) {
    CGRect lowest = CGRectNull;
    CGFloat lowestAlpha = 1.0;
    if (!host.window)
        return lowest;
    // The tab group can share a container with the navigation items; it is not one.
    UIView *platter = SPKSideColumnTabPlatter(host);
    CGRect platterFrame = platter ? [host convertRect:platter.bounds fromView:platter] : CGRectNull;
    NSMutableArray<UIView *> *queue = [SPKSideColumnFloatingBarContainersRefreshing(host, refresh) mutableCopy];
    for (NSUInteger i = 0; i < queue.count && i < 600; i++) {
        UIView *view = queue[i];
        if (view.hidden || view.alpha < 0.01)
            continue;
        if (!SPKSideColumnClassContains(view, @"GlassInteractionView")) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        CGRect frame = [host convertRect:view.bounds fromView:view];
        if (CGRectGetWidth(frame) >= kSPKSideColumnSlot * 1.6 || CGRectGetHeight(frame) < 8.0 || !SPKSideColumnViewIsInColumn(view, host))
            continue;
        if (!CGRectIsNull(platterFrame) && CGRectIntersectsRect(frame, platterFrame))
            continue;
        CGFloat opacity = 1.0;
        BOOL shown = YES;
        for (UIView *current = view; current && current != host; current = current.superview) {
            if (current.hidden) {
                shown = NO;
                break;
            }
            opacity *= current.alpha;
        }
        if (!shown || opacity < 0.01)
            continue;
        if (CGRectIsNull(lowest) || CGRectGetMaxY(frame) > CGRectGetMaxY(lowest)) {
            lowest = frame;
            lowestAlpha = opacity;
        }
    }
    if (alpha)
        *alpha = lowestAlpha;
    return lowest;
}

CGRect SPKSideColumnLowestVisibleGroup(UIView *host, CGFloat *alpha) {
    CGRect group = SPKSideColumnLowestVisibleGroupRefreshing(host, alpha, NO);
    // The remembered containers can predate a column UIKit is still building
    // (after unfolding, the old one stays in the window), so an empty answer
    // looks through the window again before it is trusted.
    if (CGRectIsNull(group))
        group = SPKSideColumnLowestVisibleGroupRefreshing(host, alpha, YES);
    return group;
}

UIView *SPKSideColumnTabPlatter(UIView *root) {
    static __weak UIView *cachedPlatter;
    UIView *platter = cachedPlatter;
    if (!platter || !platter.window || platter.window != root.window) {
        platter = nil;
        NSMutableArray<UIView *> *queue = root ? [NSMutableArray arrayWithObject:root] : [NSMutableArray array];
        for (NSUInteger i = 0; i < queue.count && i < 600; i++) {
            if (SPKSideColumnClassContains(queue[i], @"TabBarItemPlatterView")) {
                platter = queue[i];
                break;
            }
            [queue addObjectsFromArray:queue[i].subviews];
        }
        cachedPlatter = platter;
    }
    // A pushed screen can hide the whole tab bar while its platter stays as is.
    for (UIView *view = platter; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01)
            return nil;
    }
    if (!platter)
        return nil;
    CGSize size = platter.bounds.size;
    return size.height > size.width * 2.0 ? platter : nil;
}

void SPKSideColumnResetDock(UIButton *button) {
    if (button)
        objc_setAssociatedObject(button, kSPKSideColumnDockFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL SPKSideColumnDockButton(UIButton *button, UIView *glassView, UIView *host, CGRect group, CGFloat alpha) {
    if (!button || !host || CGRectIsNull(group) || alpha <= 0.01)
        return NO;

    CGFloat side = SPKSideColumnButtonSide;
    CGRect frame = CGRectMake(floor(CGRectGetMidX(group) - side / 2.0), floor(CGRectGetMaxY(group) + kSPKSideColumnGap), side, side);
    UIView *platter = SPKSideColumnTabPlatter(host);
    if (platter) {
        CGRect platterFrame = [host convertRect:platter.bounds fromView:platter];
        if (CGRectIntersectsRect(CGRectInset(frame, 0.0, -kSPKSideColumnGap / 2.0), platterFrame))
            return NO;
    }
    if (CGRectGetMaxY(frame) > CGRectGetHeight(host.bounds) - host.safeAreaInsets.bottom)
        return NO;

    SPKSideColumnPlaceButton(button, glassView, host, frame, alpha);
    return YES;
}

void SPKSideColumnSizeButton(UIButton *button, CGFloat side) {
    if (![button isKindOfClass:[SPKChromeButton class]])
        return;
    SPKChromeButton *chromeButton = (SPKChromeButton *)button;
    if (!CGSizeEqualToSize(chromeButton.customSize, CGSizeMake(side, side)))
        chromeButton.customSize = CGSizeMake(side, side);
}

void SPKSideColumnPlaceButton(UIButton *button, UIView *glassView, UIView *host, CGRect frame, CGFloat alpha) {
    // Placed by frame in a host without constraints.
    if (!button.translatesAutoresizingMaskIntoConstraints)
        button.translatesAutoresizingMaskIntoConstraints = YES;
    SPKSideColumnSizeButton(button, CGRectGetWidth(frame));
    button.hidden = NO;
    if (button.alpha != alpha)
        button.alpha = alpha;

    // System glass to match the column's own groups; there is no Instagram bubble
    // beside it to mirror. Every pass: the capture canvas sizes its host lazily, so
    // an attach right after a frame change can still see zero bounds.
    if (glassView)
        SPKChromeGlassMirrorUseSystemGlass(glassView, button);

    NSValue *last = objc_getAssociatedObject(button, kSPKSideColumnDockFrameKey);
    if (button.superview == host && last && CGRectEqualToRect(frame, last.CGRectValue))
        return;

    if (button.superview != host)
        [host addSubview:button];
    button.frame = frame;
    objc_setAssociatedObject(button, kSPKSideColumnDockFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host bringSubviewToFront:button];
    [button layoutIfNeeded];
    if (glassView)
        SPKChromeGlassMirrorAttach(glassView, button);
}
