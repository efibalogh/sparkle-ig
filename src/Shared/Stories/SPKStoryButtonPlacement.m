#import "SPKStoryButtonPlacement.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"

static const void *kSPKStoryFloatingBarKey = &kSPKStoryFloatingBarKey;
static const void *kSPKStoryFloatingBarScanKey = &kSPKStoryFloatingBarScanKey;

// Instagram's flag for "the footer moved out of the overlay", set on a folded
// foldable where it shows a floating bar instead (send/like over the composer,
// or the viewer controls on your own story).
static BOOL SPKStoryFooterMovedToFloatingBar(UIView *overlayView) {
    static Ivar ivar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class overlayClass = NSClassFromString(@"IGStoryFullscreenOverlayView");
        Ivar candidate = overlayClass ? class_getInstanceVariable(overlayClass, "_isBottomBarExcludedForFoldedDuo") : NULL;
        const char *type = candidate ? ivar_getTypeEncoding(candidate) : NULL;
        if (candidate && (!type || type[0] == 'B' || type[0] == 'c'))
            ivar = candidate;
    });
    if (!ivar || ![overlayView isKindOfClass:NSClassFromString(@"IGStoryFullscreenOverlayView")])
        return NO;
    return *((uint8_t *)(__bridge void *)overlayView + ivar_getOffset(ivar)) != 0;
}

// Top edge, in the overlay's space, of that floating bar, or NAN. Its buttons
// are found by their module's class name; the result is remembered per overlay
// and a miss is only retried twice a second, since this runs on every layout.
static CGFloat SPKStoryFloatingBarTop(UIView *overlayView) {
    if (!SPKStoryFooterMovedToFloatingBar(overlayView) || !overlayView.window)
        return NAN;
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
            return NAN;
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
    CGFloat top = NAN;
    CGRect overlayBounds = overlayView.bounds;
    for (UIView *view in cached.allObjects) {
        if (view.hidden || view.alpha < 0.01)
            continue;
        CGRect frame = [overlayView convertRect:view.bounds fromView:view];
        // Only this story's bar: the neighbours of a swipe have their own.
        if (!CGRectIntersectsRect(frame, overlayBounds))
            continue;
        top = isnan(top) ? CGRectGetMinY(frame) : MIN(top, CGRectGetMinY(frame));
    }
    return top;
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

    NSNumber *showCommentsPreview = [SPKUtils numericValueForObj:overlayView selectorName:@"showCommentsPreview"];
    if (!showCommentsPreview) {
        showCommentsPreview = [SPKUtils numericValueForObj:overlayView selectorName:@"isShowingCommentsPreview"];
    }
    if (!showCommentsPreview) {
        id kvcShowComments = SPKKVCObject(overlayView, @"showCommentsPreview");
        if ([kvcShowComments respondsToSelector:@selector(boolValue)]) {
            showCommentsPreview = @([kvcShowComments boolValue]);
        }
    }
    if (showCommentsPreview.boolValue) {
        UIView *hypeFaceswarmView = [SPKUtils getIvarForObj:overlayView name:"_hypeFaceswarmView"];
        if ([hypeFaceswarmView isKindOfClass:[UIView class]] && (y + size) > CGRectGetMinY(hypeFaceswarmView.frame)) {
            y = CGRectGetMinY(hypeFaceswarmView.frame) - size - 2.0;
        } else {
            y -= 35.0;
        }
    }

    // Clear the floating bar as well: its glass reaches a few points past its
    // buttons, and the comments preview pushes it up just like the footer.
    // In that layout the composer stays in the footer, which reaches higher than
    // the regular footer offset assumes; keep the row clear of it.
    if (footerContainer && !footerContainer.hidden && SPKStoryFooterMovedToFloatingBar(overlayView)) {
        CGFloat footerTop = CGRectGetMinY([overlayView convertRect:footerContainer.bounds fromView:footerContainer]);
        if (y + size > footerTop - 4.0)
            y = footerTop - 4.0 - size;
    }
    CGFloat floatingBarTop = SPKStoryFloatingBarTop(overlayView);
    if (!isnan(floatingBarTop) && y + size > floatingBarTop - 10.0)
        y = floatingBarTop - 10.0 - size;

    return CGRectMake(SPKStoryTrailingButtonX(overlayView, size), y, size, size);
}
