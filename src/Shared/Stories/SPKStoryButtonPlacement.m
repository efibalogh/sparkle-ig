#import "SPKStoryButtonPlacement.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"

static const void *kSPKStoryFloatingBarKey = &kSPKStoryFloatingBarKey;
static const void *kSPKStoryFloatingBarScanKey = &kSPKStoryFloatingBarScanKey;
static const void *kSPKStoryFloatingBarOnStorySinceKey = &kSPKStoryFloatingBarOnStorySinceKey;
static const void *kSPKStoryFoldedRowYKey = &kSPKStoryFoldedRowYKey;
static const void *kSPKStorySettleRelayoutKey = &kSPKStorySettleRelayoutKey;

// How long the floating bar has to stay over the story before the row climbs
// over it. On every story change Instagram lays the bar out over the story for
// a frame or two before handing its buttons to the side column.
static const CFTimeInterval kSPKStoryFloatingBarSettleDelay = 0.1;

// Instagram's flag for "the footer moved out of the overlay", set on a folded
// foldable where it shows a floating bar instead (send/like over the composer,
// or the viewer controls on your own story).
static Class SPKStoryOverlayClass(void) {
    static Class overlayClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlayClass = NSClassFromString(@"IGStoryFullscreenOverlayView");
    });
    return overlayClass;
}

static BOOL SPKStoryFooterMovedToFloatingBar(UIView *overlayView) {
    static Ivar ivar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class overlayClass = SPKStoryOverlayClass();
        Ivar candidate = overlayClass ? class_getInstanceVariable(overlayClass, "_isBottomBarExcludedForFoldedDuo") : NULL;
        const char *type = candidate ? ivar_getTypeEncoding(candidate) : NULL;
        if (candidate && (!type || type[0] == 'B' || type[0] == 'c'))
            ivar = candidate;
    });
    if (!ivar || ![overlayView isKindOfClass:SPKStoryOverlayClass()])
        return NO;
    return *((uint8_t *)(__bridge void *)overlayView + ivar_getOffset(ivar)) != 0;
}

// The floating bar's buttons, found by their module's class name. The result
// is remembered per overlay and a miss is only retried twice a second, since
// this runs on every layout.
static NSArray<UIView *> *SPKStoryFloatingBarButtons(UIView *overlayView) {
    if (!SPKStoryFooterMovedToFloatingBar(overlayView) || !overlayView.window)
        return @[];
    NSHashTable<UIView *> *cached = objc_getAssociatedObject(overlayView, kSPKStoryFloatingBarKey);
    BOOL valid = cached.count > 0;
    for (UIView *view in cached.allObjects) {
        if (view.window != overlayView.window)
            valid = NO;
    }
    if (!valid) {
        CFTimeInterval now = CACurrentMediaTime();
        NSNumber *lastScan = objc_getAssociatedObject(overlayView, kSPKStoryFloatingBarScanKey);
        if (lastScan && now - lastScan.doubleValue < 0.5)
            return @[];
        objc_setAssociatedObject(overlayView, kSPKStoryFloatingBarScanKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cached = [NSHashTable weakObjectsHashTable];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:overlayView.window];
        for (NSUInteger i = 0; i < queue.count && i < 6000; i++) {
            UIView *view = queue[i];
            if ([NSStringFromClass(view.class) containsString:@"StoryDuoVerticalBar"] &&
                [NSStringFromClass(view.class) containsString:@"ButtonTarget"]) {
                [cached addObject:view];
                continue;
            }
            [queue addObjectsFromArray:view.subviews];
        }
        objc_setAssociatedObject(overlayView, kSPKStoryFloatingBarKey, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Which buttons the bar holds depends on the story (no send on a close
    // friends story, for one), so only the ones drawn right now count.
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *view in cached.allObjects) {
        BOOL drawn = YES;
        for (UIView *walker = view; walker && walker != view.window; walker = walker.superview) {
            if (walker.hidden || walker.alpha < 0.01) {
                drawn = NO;
                break;
            }
        }
        if (drawn)
            [visible addObject:view];
    }
    return visible;
}

// Top edge, in the overlay's space, of the floating bar where it sits over
// this story (own stories), or NAN. Neighbours of a swipe have their own.
static CGFloat SPKStoryFloatingBarTop(UIView *overlayView) {
    CGFloat top = NAN;
    CGRect overlayBounds = overlayView.bounds;
    for (UIView *view in SPKStoryFloatingBarButtons(overlayView)) {
        CGRect frame = [overlayView convertRect:view.bounds fromView:view];
        if (!CGRectIntersectsRect(frame, overlayBounds))
            continue;
        top = isnan(top) ? CGRectGetMinY(frame) : MIN(top, CGRectGetMinY(frame));
    }
    if (isnan(top)) {
        objc_setAssociatedObject(overlayView, kSPKStoryFloatingBarOnStorySinceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NAN;
    }

    // Only a bar that stays over the story counts; one passing through on its
    // way to the side column would pull the row up for a frame.
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *since = objc_getAssociatedObject(overlayView, kSPKStoryFloatingBarOnStorySinceKey);
    if (!since) {
        objc_setAssociatedObject(overlayView, kSPKStoryFloatingBarOnStorySinceKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakOverlay = overlayView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kSPKStoryFloatingBarSettleDelay + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakOverlay setNeedsLayout];
        });
        return NAN;
    }
    return now - since.doubleValue >= kSPKStoryFloatingBarSettleDelay ? top : NAN;
}

// Vertical center, in the overlay's space, of the lowest visible floating bar
// button docked in the side column beside the story, or NAN.
static CGFloat SPKStoryColumnBarBottomButtonMidY(UIView *overlayView) {
    CGFloat midY = NAN;
    CGRect overlayBounds = overlayView.bounds;
    for (UIView *view in SPKStoryFloatingBarButtons(overlayView)) {
        CGRect frame = [overlayView convertRect:view.bounds fromView:view];
        if (CGRectIntersectsRect(frame, overlayBounds))
            continue;
        if (CGRectGetMaxY(frame) < CGRectGetMinY(overlayBounds) || CGRectGetMinY(frame) > CGRectGetMaxY(overlayBounds))
            continue;
        midY = isnan(midY) ? CGRectGetMidY(frame) : MAX(midY, CGRectGetMidY(frame));
    }
    return midY;
}

// Top edge, in the overlay's space, of whatever is actually drawn under root:
// the leaves of its visible subtree. A folded foldable keeps the footer
// container at full height even when its composer is hidden, so the
// container's own frame says nothing about what the buttons must clear.
static CGFloat SPKStoryVisibleContentTop(UIView *root, UIView *overlayView) {
    if (!root || root.hidden || root.alpha < 0.01 || !root.window)
        return NAN;
    CGFloat top = NAN;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        UIView *view = queue[i];
        if (view.hidden || view.alpha < 0.01)
            continue;
        if (view.subviews.count > 0) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        if (CGRectGetWidth(view.bounds) < 1.0 || CGRectGetHeight(view.bounds) < 1.0)
            continue;
        CGFloat minY = CGRectGetMinY([overlayView convertRect:view.bounds fromView:view]);
        top = isnan(top) ? minY : MIN(top, minY);
    }
    return top;
}

// Instagram has two story comment previews: the hype faceswarm (bubbles with
// avatars, in an ivar) and the classic preview that cycles through comment
// cells (no declared ivar). Every one seen inside an overlay is remembered on
// it by the hooks below.
static const void *kSPKStoryCommentsViewsKey = &kSPKStoryCommentsViewsKey;

static void SPKStoryRegisterCommentsView(UIView *overlayView, UIView *commentsView) {
    NSHashTable<UIView *> *views = objc_getAssociatedObject(overlayView, kSPKStoryCommentsViewsKey);
    if (!views) {
        views = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(overlayView, kSPKStoryCommentsViewsKey, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [views addObject:commentsView];
}

static NSArray<UIView *> *SPKStoryCommentsViews(UIView *overlayView) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    UIView *hype = [SPKUtils getIvarForObj:overlayView name:"_hypeFaceswarmView"];
    if ([hype isKindOfClass:[UIView class]])
        [result addObject:hype];
    NSHashTable<UIView *> *views = objc_getAssociatedObject(overlayView, kSPKStoryCommentsViewsKey);
    for (UIView *view in views.allObjects) {
        if (![result containsObject:view] && [view isDescendantOfView:overlayView])
            [result addObject:view];
    }
    return result;
}

// How many comments Instagram configured this story with, or -1 when the
// build does not say. The preview views keep fading in and out, with empty
// cells or bubbles, on stories that have none, so their visibility alone is
// not enough to tell.
static NSInteger SPKStoryCommentCount(UIView *overlayView) {
    static Ivar ivar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class overlayClass = SPKStoryOverlayClass();
        Ivar candidate = overlayClass ? class_getInstanceVariable(overlayClass, "_comments") : NULL;
        const char *type = candidate ? ivar_getTypeEncoding(candidate) : NULL;
        if (candidate && (!type || type[0] == '@'))
            ivar = candidate;
    });
    if (!ivar || ![overlayView isKindOfClass:SPKStoryOverlayClass()])
        return -1;
    id comments = object_getIvar(overlayView, ivar);
    if (!comments)
        return 0;
    return [comments isKindOfClass:[NSArray class]] ? (NSInteger)((NSArray *)comments).count : -1;
}

// Top edge, in the overlay's space, of whichever comment preview is drawn, or
// NAN. Bubbles bob while they play; a view's own top edge holds still and only
// gives way to a bubble reaching above it.
static CGFloat SPKStoryCommentsTop(UIView *overlayView) {
    if (SPKStoryCommentCount(overlayView) == 0)
        return NAN;
    CGFloat top = NAN;
    for (UIView *commentsView in SPKStoryCommentsViews(overlayView)) {
        CGFloat viewTop = SPKStoryVisibleContentTop(commentsView, overlayView);
        if (isnan(viewTop))
            continue;
        viewTop = floor(MIN(viewTop, CGRectGetMinY([overlayView convertRect:commentsView.bounds fromView:commentsView])));
        top = isnan(top) ? viewTop : MIN(top, viewTop);
    }
    return top;
}

// Whether the overlay sits flat and fully inside its window. While swiping
// between users the story turns like a cube, so geometry converted from the
// side column or the floating bar (window-level views shared by every story)
// lands in the wrong place, and the incoming story stops at a row far too
// high. The column and the bar only count once the overlay has settled; one
// more layout pass is asked for when it has.
static BOOL SPKStoryOverlayIsSettled(UIView *overlayView) {
    UIWindow *window = overlayView.window;
    if (!window)
        return NO;
    CGRect bounds = overlayView.bounds;
    CGRect rect = [overlayView convertRect:bounds toView:nil];
    CGRect windowBounds = window.bounds;
    return ABS(CGRectGetWidth(rect) - CGRectGetWidth(bounds)) < 1.0 &&
           ABS(CGRectGetHeight(rect) - CGRectGetHeight(bounds)) < 1.0 &&
           CGRectGetMinX(rect) > CGRectGetMinX(windowBounds) - 1.0 &&
           CGRectGetMaxX(rect) < CGRectGetMaxX(windowBounds) + 1.0;
}

static void SPKStoryScheduleSettleRelayout(UIView *overlayView) {
    if ([objc_getAssociatedObject(overlayView, kSPKStorySettleRelayoutKey) boolValue])
        return;
    objc_setAssociatedObject(overlayView, kSPKStorySettleRelayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakOverlay = overlayView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *overlay = weakOverlay;
        if (!overlay)
            return;
        objc_setAssociatedObject(overlay, kSPKStorySettleRelayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [overlay setNeedsLayout];
    });
}

// Folded foldable: the like and send buttons live in the floating bar, so the
// row sits on the media's bottom edge and only climbs over what is visible
// right now (the composer, the comments preview, the floating bar).
static CGFloat SPKStoryFoldedButtonY(UIView *overlayView, UIView *mediaView, UIView *footerContainer, CGFloat size) {
    // Holding a story to pause it fades the footer out. Keep the row where it
    // was instead of dropping it to the media's edge and back on release.
    NSMutableDictionary<NSNumber *, NSNumber *> *rowY = objc_getAssociatedObject(overlayView, kSPKStoryFoldedRowYKey);
    BOOL footerFaded = footerContainer && (footerContainer.hidden || footerContainer.alpha < 0.01);
    if (footerFaded && rowY[@(size)])
        return rowY[@(size)].doubleValue;

    // Line the row up with the lowest button of the column beside the story;
    // without one, inset a little further than the unfolded row does.
    CGFloat bottomLimit = mediaView ? CGRectGetMaxY(mediaView.frame) - 7.0 : CGRectGetHeight(overlayView.bounds) - 12.0;
    CGFloat y = bottomLimit - size - 14.0;

    BOOL settled = SPKStoryOverlayIsSettled(overlayView);
    if (!settled) {
        SPKStoryScheduleSettleRelayout(overlayView);
        NSNumber *held = rowY[@(size)];
        if (held)
            return held.doubleValue;
    }

    // The column's lowest button sits beside the media's bottom edge; one
    // reported far above it is mid-animation, not a place to line up with.
    CGFloat columnMidY = settled ? SPKStoryColumnBarBottomButtonMidY(overlayView) : NAN;
    if (!isnan(columnMidY) && columnMidY < bottomLimit - 3.0 * size)
        columnMidY = NAN;
    if (!isnan(columnMidY))
        y = MIN(columnMidY - size / 2.0, bottomLimit - size);

    CGFloat footerTop = SPKStoryVisibleContentTop(footerContainer, overlayView);
    if (!isnan(footerTop) && y + size > footerTop - 12.0)
        y = footerTop - 12.0 - size;

    CGFloat commentsTop = SPKStoryCommentsTop(overlayView);
    if (!isnan(commentsTop) && y + size > commentsTop - 2.0)
        y = commentsTop - 2.0 - size;

    CGFloat floatingBarTop = settled ? SPKStoryFloatingBarTop(overlayView) : NAN;
    if (!isnan(floatingBarTop) && y + size > floatingBarTop - 10.0)
        y = floatingBarTop - 10.0 - size;
    if (!footerFaded && settled) {
        if (!rowY) {
            rowY = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(overlayView, kSPKStoryFoldedRowYKey, rowY, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        rowY[@(size)] = @(y);
    }
    return y;
}

static CGFloat SPKStoryTrailingButtonX(UIView *overlayView, CGFloat size) {
    CGFloat width = CGRectGetWidth(overlayView.bounds);
    UIEdgeInsets safeInsets = overlayView.safeAreaInsets;

    CGFloat trailingInset = MAX(6.0, safeInsets.right + 6.0);
    return MAX(0.0, width - size - trailingInset);
}

CGRect SPKStoryFloatingButtonFrame(UIView *overlayView, CGFloat size) {
    if (!overlayView)
        return CGRectZero;

    if (size <= 0.0)
        size = 44.0;

    CGFloat y = 0.0;
    UIView *mediaView = [SPKUtils getIvarForObj:overlayView name:"_mediaView"];
    UIView *footerContainer = [SPKUtils getIvarForObj:overlayView name:"_footerContainerView"];
    if (![mediaView isKindOfClass:[UIView class]])
        mediaView = nil;
    if (![footerContainer isKindOfClass:[UIView class]])
        footerContainer = nil;

    if (SPKStoryFooterMovedToFloatingBar(overlayView))
        return CGRectMake(SPKStoryTrailingButtonX(overlayView, size), SPKStoryFoldedButtonY(overlayView, mediaView, footerContainer, size), size, size);

    if (mediaView) {
        CGRect mediaFrame = mediaView.frame;
        y = CGRectGetMaxY(mediaFrame) - size - 7.0;
        if (footerContainer && CGRectGetMinY(footerContainer.frame) < CGRectGetMaxY(mediaFrame)) {
            y -= 50.0;
        }
    } else if (footerContainer) {
        y = CGRectGetMinY(footerContainer.frame) - size - 12.0;
    } else {
        y = CGRectGetHeight(overlayView.bounds) - size - 12.0;
    }

    // Clear the comments preview while it is drawn. Instagram's own
    // showCommentsPreview flag describes the story, not what is on screen, so
    // it only decides where the preview view itself cannot be found.
    if (SPKStoryCommentsViews(overlayView).count > 0) {
        CGFloat commentsTop = SPKStoryCommentsTop(overlayView);
        if (!isnan(commentsTop) && y + size > commentsTop - 2.0)
            y = commentsTop - 2.0 - size;
    } else {
        NSNumber *showCommentsPreview = [SPKUtils numericValueForObj:overlayView selectorName:@"showCommentsPreview"];
        if (!showCommentsPreview)
            showCommentsPreview = [SPKUtils numericValueForObj:overlayView selectorName:@"isShowingCommentsPreview"];
        if (!showCommentsPreview) {
            id kvcShowComments = SPKKVCObject(overlayView, @"showCommentsPreview");
            if ([kvcShowComments respondsToSelector:@selector(boolValue)])
                showCommentsPreview = @([kvcShowComments boolValue]);
        }
        if (showCommentsPreview.boolValue)
            y -= 35.0;
    }

    return CGRectMake(SPKStoryTrailingButtonX(overlayView, size), y, size, size);
}

#pragma mark - Relayout triggers

// Instagram changes the footer and the comments preview without laying the
// overlay out again (always on a folded foldable, and when the comments fade
// out everywhere), so a row placed above a composer or comments would stay
// there on the next story. These calls mark the overlay
// dirty; the story buttons recompute their frames in its next layout pass.
extern void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

static void SPKStoryScheduleButtonRelayout(UIView *overlayView) {
    if (![overlayView isKindOfClass:[UIView class]])
        return;
    __weak UIView *weakOverlay = overlayView;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakOverlay setNeedsLayout];
    });
    // Comments and composer changes animate; place again once they settle.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakOverlay setNeedsLayout];
    });
}

static void (*SPKOrigStorySetBool)(id, SEL, BOOL);
static void (*SPKOrigStorySetFooterBottomBarItemHidden)(id, SEL, BOOL);
static void (*SPKOrigStorySetFoldedDuoActive)(id, SEL, BOOL);
static void (*SPKOrigStoryPrepareFooter)(id, SEL, BOOL);
static void (*SPKOrigStorySetComposing)(id, SEL, BOOL, BOOL);
static void (*SPKOrigStoryConfigureComments)(id, SEL, id, id, BOOL, BOOL);
static void (*SPKOrigStoryShowComments)(id, SEL);

static void SPKStorySetFooterHidden(id self, SEL _cmd, BOOL hidden) {
    SPKOrigStorySetBool(self, _cmd, hidden);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStorySetFooterBottomBarItemHidden(id self, SEL _cmd, BOOL hidden) {
    SPKOrigStorySetFooterBottomBarItemHidden(self, _cmd, hidden);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStorySetFoldedDuoActive(id self, SEL _cmd, BOOL active) {
    SPKOrigStorySetFoldedDuoActive(self, _cmd, active);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStoryPrepareFooter(id self, SEL _cmd, BOOL needed) {
    SPKOrigStoryPrepareFooter(self, _cmd, needed);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStorySetComposing(id self, SEL _cmd, BOOL composing, BOOL cover) {
    SPKOrigStorySetComposing(self, _cmd, composing, cover);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStoryConfigureComments(id self, SEL _cmd, id comments, id media, BOOL isSelfStory, BOOL latestFirst) {
    SPKOrigStoryConfigureComments(self, _cmd, comments, media, isSelfStory, latestFirst);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStoryShowComments(id self, SEL _cmd) {
    SPKOrigStoryShowComments(self, _cmd);
    SPKStoryScheduleButtonRelayout(self);
}

static void SPKStoryHookIfPresent(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(selectorName);
    if (class_getInstanceMethod(cls, selector))
        MSHookMessageEx(cls, selector, replacement, original);
}

// The comments preview fades its bubbles in on its own timer, after the calls
// above have run. Its own visibility and layout changes mark the overlay dirty,
// but only when the top the row has to clear actually moved, so the overlay's
// layout pass relaying the preview out cannot feed back into itself.
static const void *kSPKStoryCommentsTopKey = &kSPKStoryCommentsTopKey;

static void SPKStoryCommentsViewChanged(UIView *commentsView, SEL trigger) {
    Class overlayClass = SPKStoryOverlayClass();
    if (!overlayClass)
        return;
    UIView *overlayView = commentsView.superview;
    while (overlayView && ![overlayView isKindOfClass:overlayClass])
        overlayView = overlayView.superview;
    if (!overlayView)
        return;
    SPKStoryRegisterCommentsView(overlayView, commentsView);
    // A story without comments keeps its row clear of nothing; only a change
    // from the last story's comments needs a pass.
    NSNumber *previous = objc_getAssociatedObject(overlayView, kSPKStoryCommentsTopKey);
    if (SPKStoryCommentCount(overlayView) == 0 && previous && isnan(previous.doubleValue))
        return;
    CGFloat top = SPKStoryCommentsTop(overlayView);
    NSNumber *last = objc_getAssociatedObject(overlayView, kSPKStoryCommentsTopKey);
    BOOL changed = last ? (isnan(top) != isnan(last.doubleValue) || (!isnan(top) && ABS(top - last.doubleValue) > 0.5)) : YES;
    if (!changed)
        return;
    objc_setAssociatedObject(overlayView, kSPKStoryCommentsTopKey, @(top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakOverlay = overlayView;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakOverlay setNeedsLayout];
    });
}

// One set of originals per comments class: each may own or inherit these.
#define SPK_COMMENTS_HOOKS(tag)                                                   \
    static void (*SPKOrig##tag##SetHidden)(id, SEL, BOOL);                        \
    static void (*SPKOrig##tag##SetAlpha)(id, SEL, CGFloat);                      \
    static void (*SPKOrig##tag##LayoutSubviews)(id, SEL);                         \
    static void SPK##tag##SetHidden(UIView *self, SEL _cmd, BOOL hidden) {        \
        SPKOrig##tag##SetHidden(self, _cmd, hidden);                              \
        SPKStoryCommentsViewChanged(self, _cmd);                                  \
    }                                                                             \
    static void SPK##tag##SetAlpha(UIView *self, SEL _cmd, CGFloat alpha) {       \
        SPKOrig##tag##SetAlpha(self, _cmd, alpha);                                \
        SPKStoryCommentsViewChanged(self, _cmd);                                  \
    }                                                                             \
    static void SPK##tag##LayoutSubviews(UIView *self, SEL _cmd) {                \
        SPKOrig##tag##LayoutSubviews(self, _cmd);                                 \
        SPKStoryCommentsViewChanged(self, _cmd);                                  \
    }

SPK_COMMENTS_HOOKS(Faceswarm)
SPK_COMMENTS_HOOKS(CommentsPreview)

// Hooks a method the class may only inherit from UIView: an inherited one is
// added to this class alone, calling up to the superclass, so other views are
// left untouched.
static void SPKStoryHookOwnOrInherited(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return;
    Class superclass = class_getSuperclass(cls);
    if (superclass && class_getInstanceMethod(superclass, selector) == method) {
        *original = method_getImplementation(method);
        class_addMethod(cls, selector, replacement, method_getTypeEncoding(method));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

void SPKInstallStoryButtonRelayoutHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class overlayClass = SPKStoryOverlayClass();
        if (!overlayClass)
            return;
        SPKStoryHookIfPresent(overlayClass, @"setFooterContainerViewHidden:", (IMP)SPKStorySetFooterHidden, (IMP *)&SPKOrigStorySetBool);
        SPKStoryHookIfPresent(overlayClass, @"setFooterBottomBarItemHidden:", (IMP)SPKStorySetFooterBottomBarItemHidden, (IMP *)&SPKOrigStorySetFooterBottomBarItemHidden);
        SPKStoryHookIfPresent(overlayClass, @"setFoldedDuoVerticalBarActive:", (IMP)SPKStorySetFoldedDuoActive, (IMP *)&SPKOrigStorySetFoldedDuoActive);
        SPKStoryHookIfPresent(overlayClass, @"prepareFooterForReuseIfNeeded:", (IMP)SPKStoryPrepareFooter, (IMP *)&SPKOrigStoryPrepareFooter);
        SPKStoryHookIfPresent(overlayClass, @"setIsComposingMessage:shouldCoverUnderlyingItems:", (IMP)SPKStorySetComposing, (IMP *)&SPKOrigStorySetComposing);
        SPKStoryHookIfPresent(overlayClass, @"configureWithComments:media:isSelfStory:showLatestCommentFirst:", (IMP)SPKStoryConfigureComments, (IMP *)&SPKOrigStoryConfigureComments);
        SPKStoryHookIfPresent(overlayClass, @"_showCommentsPreviewView", (IMP)SPKStoryShowComments, (IMP *)&SPKOrigStoryShowComments);

        Class faceswarmClass = SPKResolveIGClass(@"IGStoryCommentsSwift.IGStoryCommentsFaceswarmView", @"IGStoryCommentsFaceswarmView");
        if (faceswarmClass) {
            SPKStoryHookOwnOrInherited(faceswarmClass, @selector(setHidden:), (IMP)SPKFaceswarmSetHidden, (IMP *)&SPKOrigFaceswarmSetHidden);
            SPKStoryHookOwnOrInherited(faceswarmClass, @selector(setAlpha:), (IMP)SPKFaceswarmSetAlpha, (IMP *)&SPKOrigFaceswarmSetAlpha);
            SPKStoryHookOwnOrInherited(faceswarmClass, @selector(layoutSubviews), (IMP)SPKFaceswarmLayoutSubviews, (IMP *)&SPKOrigFaceswarmLayoutSubviews);
        }
        Class previewClass = SPKResolveIGClass(@"IGStoryCommentsSwift.IGStoryCommentsPreviewView", @"IGStoryCommentsPreviewView");
        if (previewClass) {
            SPKStoryHookOwnOrInherited(previewClass, @selector(setHidden:), (IMP)SPKCommentsPreviewSetHidden, (IMP *)&SPKOrigCommentsPreviewSetHidden);
            SPKStoryHookOwnOrInherited(previewClass, @selector(setAlpha:), (IMP)SPKCommentsPreviewSetAlpha, (IMP *)&SPKOrigCommentsPreviewSetAlpha);
            SPKStoryHookOwnOrInherited(previewClass, @selector(layoutSubviews), (IMP)SPKCommentsPreviewLayoutSubviews, (IMP *)&SPKOrigCommentsPreviewLayoutSubviews);
        }
    });
}
