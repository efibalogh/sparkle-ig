#import "SPKStrings.h"
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/Gallery/SPKGalleryFile.h"
#import "../../Shared/Gallery/SPKGalleryOriginController.h"
#import "../../Shared/Gallery/SPKGallerySaveMetadata.h"
#import "../../Shared/MediaPreview/SPKMediaItem.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

extern "C" void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

static NSInteger const kSPKFeedActionButtonTag = 921341;
static const void *kSPKFeedExpandLongPressMarkerAssocKey = &kSPKFeedExpandLongPressMarkerAssocKey;
static const void *kSPKFeedExpandLongPressDelegateAssocKey = &kSPKFeedExpandLongPressDelegateAssocKey;
// Tracks which post the button was last configured for, so a recycled bar
// showing a NEW post triggers a reconfigure even though its layout is unchanged.
static const void *kSPKFeedConfiguredMediaAssocKey = &kSPKFeedConfiguredMediaAssocKey;

@interface IGFeedItemPageVideoCell : UICollectionViewCell
@end

static id SPKFeedMediaForZoomFromView(UIView *view);
static BOOL SPKFeedLongPressExpandEnabled(void);
static BOOL SPKFeedMediaHasExpandableAsset(id media);
static BOOL SPKFeedViewHasExpandableAsset(UIView *view);
static BOOL SPKFeedShouldSuppressNativeLongPress(UIGestureRecognizer *gestureRecognizer);
static BOOL SPKFeedShouldSuppressNativeLongPressFromHandler(id handler, UIGestureRecognizer *gestureRecognizer);

@interface SPKFeedExpandLongPressDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SPKFeedExpandLongPressDelegate
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return SPKFeedShouldSuppressNativeLongPress(gestureRecognizer);
}

// Reels shown in feed draw their author header (avatar, username, follow) inside
// the cell the expand recognizer is attached to. Without this the 0.3s expand
// press wins over the avatar's own long press, so story peek and profile photo
// zoom never fire there. Leave touches that land on such targets to their owners.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *host = gestureRecognizer.view;
    CGFloat hostArea = CGRectGetWidth(host.bounds) * CGRectGetHeight(host.bounds);
    for (UIView *view = touch.view; view && view != host; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]])
            return NO;

        NSString *className = NSStringFromClass([view class]);
        for (NSString *fragment in @[ @"Avatar", @"ProfilePic", @"StoryRing", @"Header" ]) {
            if ([className rangeOfString:fragment].location != NSNotFound)
                return NO;
        }

        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (hostArea <= 0 || area >= hostArea * 0.25)
            continue;
        for (UIGestureRecognizer *other in view.gestureRecognizers) {
            if (other.enabled && [other isKindOfClass:[UILongPressGestureRecognizer class]])
                return NO;
        }
    }
    return YES;
}
@end

static BOOL SPKFeedLongPressExpandEnabled(void) {
    return [SPKUtils getBoolPref:@"feed_long_press_expand"];
}

static UIPageControl *SPKPageControlInViewHierarchy(UIView *view) {
    if (!view)
        return nil;
    if ([view isKindOfClass:[UIPageControl class]])
        return (UIPageControl *)view;
    for (UIView *subview in view.subviews) {
        UIPageControl *pageControl = SPKPageControlInViewHierarchy(subview);
        if (pageControl)
            return pageControl;
    }
    return nil;
}

static NSInteger SPKIndexFromPageIndicatorObject(id indicator) {
    if (!indicator)
        return -1;
    if ([indicator isKindOfClass:[UIPageControl class]]) {
        return (NSInteger)((UIPageControl *)indicator).currentPage;
    }

    NSNumber *currentPageNumber = [SPKUtils numericValueForObj:indicator selectorName:@"currentPage"];
    if (currentPageNumber)
        return currentPageNumber.integerValue;

    id currentPage = SPKKVCObject(indicator, @"currentPage");
    NSString *pageString = SPKStringFromValue(currentPage);
    return pageString.length > 0 ? pageString.integerValue : -1;
}

static NSInteger SPKFeedCurrentIndexFromBarView(UIView *barView) {
    if (!barView)
        return -1;

    id delegate = SPKObjectForSelector(barView, @"delegate");
    id nestedDelegate = SPKObjectForSelector(delegate, @"delegate");
    id target = nestedDelegate ?: delegate;

    id pageCellState = [SPKUtils getIvarForObj:target name:"_pageCellState"];
    NSNumber *stateIndex = [SPKUtils numericValueForObj:pageCellState selectorName:@"currentPageIndex"];
    if (stateIndex && stateIndex.integerValue >= 0)
        return stateIndex.integerValue;
    stateIndex = [SPKUtils numericValueForObj:pageCellState selectorName:@"currentIndex"];
    if (stateIndex && stateIndex.integerValue >= 0)
        return stateIndex.integerValue;

    NSNumber *delegatePage = [SPKUtils numericValueForObj:delegate selectorName:@"pageControlCurrentPage"];
    if (delegatePage && delegatePage.integerValue >= 0)
        return delegatePage.integerValue;

    NSInteger pageControlIdx = SPKIndexFromPageIndicatorObject(SPKObjectForSelector(delegate, @"pageControl"));
    if (pageControlIdx >= 0)
        return pageControlIdx;

    for (NSString *selectorName in @[ @"pageControl", @"pageIndicator", @"carouselPageControl" ]) {
        NSInteger idx = SPKIndexFromPageIndicatorObject(SPKObjectForSelector(barView, selectorName));
        if (idx >= 0)
            return idx;
    }

    UIPageControl *localPageControl = SPKPageControlInViewHierarchy(barView);
    if (localPageControl)
        return (NSInteger)localPageControl.currentPage;

    UIPageControl *superPageControl = SPKPageControlInViewHierarchy(barView.superview);
    return superPageControl ? (NSInteger)superPageControl.currentPage : -1;
}

static id SPKFeedMediaFromBarView(UIView *barView) {
    if (!barView)
        return nil;

    id delegate = SPKObjectForSelector(barView, @"delegate");
    id nestedDelegate = SPKObjectForSelector(delegate, @"delegate");
    id target = nestedDelegate ?: delegate;

    id media = [SPKUtils getIvarForObj:target name:"_media"];
    if (!media)
        media = SPKObjectForSelector(target, @"media");
    if (!media)
        media = SPKKVCObject(target, @"media");

    id hierarchyMedia = SPKFeedMediaForZoomFromView(barView);
    if (SPKActionButtonCarouselChildren(hierarchyMedia).count > 0)
        return hierarchyMedia;
    if (SPKActionButtonCarouselChildren(media).count > 0)
        return media;
    return media ?: hierarchyMedia;
}

// Cheap, allocation-free proxy for "which post is this bar showing" — the
// delegate's `_media` pointer. Used only for identity comparison (never
// dereferenced), so a recycled bar that swaps to a new post is detected without
// paying for the full media/entries resolution on every layout pass.
static id SPKFeedBarMediaSignal(UIView *barView) {
    if (!barView)
        return nil;
    id delegate = SPKObjectForSelector(barView, @"delegate");
    id nestedDelegate = SPKObjectForSelector(delegate, @"delegate");
    id target = nestedDelegate ?: delegate;
    id media = [SPKUtils getIvarForObj:target name:"_media"];
    if (!media)
        media = SPKObjectForSelector(target, @"media");
    return media;
}

static UIView *SPKFeedAnyButtonFromBarView(UIView *barView) {
    if (!barView)
        return nil;

    id saveIvar = [SPKUtils getIvarForObj:barView name:"_saveButton"];
    if ([saveIvar isKindOfClass:[UIView class]])
        return (UIView *)saveIvar;

    for (NSString *selectorName in @[ @"sendButton", @"commentButton", @"likeButton", @"saveButton" ]) {
        id candidate = SPKObjectForSelector(barView, selectorName);
        if ([candidate isKindOfClass:[UIView class]])
            return (UIView *)candidate;
    }

    return nil;
}

static CGRect SPKFeedAnyButtonFrameFromBarView(UIView *barView) {
    UIView *anyButton = SPKFeedAnyButtonFromBarView(barView);
    return anyButton ? anyButton.frame : CGRectMake(0.0, 0.0, 40.0, 48.0);
}

static UIView *SPKFeedFirstRightButtonFromBarView(UIView *barView) {
    if (!barView)
        return nil;

    for (NSString *selectorName in @[ @"visualSearchButton", @"saveButton" ]) {
        id candidate = SPKObjectForSelector(barView, selectorName);
        if ([candidate isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)candidate;
            if (!view.hidden && view.superview)
                return view;
        }
    }

    for (NSString *ivarName in @[ @"_visualSearchButton", @"_saveButton" ]) {
        id candidate = [SPKUtils getIvarForObj:barView name:ivarName.UTF8String];
        if ([candidate isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)candidate;
            if (!view.hidden && view.superview)
                return view;
        }
    }

    return nil;
}

static UIView *SPKFeedCellAncestorForView(UIView *view) {
    UIView *walker = view;
    NSInteger depth = 0;
    while (walker && depth < 16) {
        for (NSString *className in @[ @"IGFeedItemMediaCell", @"IGFeedItemPageCell", @"IGModernFeedVideoCell", @"IGModernFeedVideoCell.IGModernFeedVideoCell" ]) {
            Class cls = NSClassFromString(className);
            if (cls && [walker isKindOfClass:cls])
                return walker;
        }
        walker = walker.superview;
        depth++;
    }
    return nil;
}

static UICollectionView *SPKFeedOuterCollectionView(UIView *view) {
    UIView *walker = view;
    NSInteger depth = 0;
    while (walker && depth < 16) {
        if ([walker isKindOfClass:[UICollectionView class]]) {
            NSString *className = NSStringFromClass([walker class]);
            if (![className containsString:@"Carousel"] && ![className containsString:@"Page"]) {
                return (UICollectionView *)walker;
            }
        }
        walker = walker.superview;
        depth++;
    }
    return nil;
}

static NSInteger SPKFeedSectionForViewInCollection(UIView *view, UICollectionView *collectionView) {
    if (!view || !collectionView)
        return -1;
    UIView *walker = view;
    NSInteger depth = 0;
    while (walker && depth < 16) {
        if ([walker isKindOfClass:[UICollectionViewCell class]]) {
            NSIndexPath *indexPath = [collectionView indexPathForCell:(UICollectionViewCell *)walker];
            if (indexPath)
                return indexPath.section;
        }
        walker = walker.superview;
        depth++;
    }
    return -1;
}

static id SPKFeedMediaFromCellByIntrospection(UICollectionViewCell *cell, Class mediaClass) {
    if (!cell || !mediaClass)
        return nil;

    unsigned int count = 0;
    Class currentClass = object_getClass(cell);
    while (currentClass && currentClass != [UICollectionViewCell class]) {
        Ivar *ivars = class_copyIvarList(currentClass, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@')
                continue;
            @try {
                id value = object_getIvar(cell, ivars[i]);
                if (value && [value isKindOfClass:mediaClass]) {
                    if (ivars)
                        free(ivars);
                    return value;
                }
            } @catch (__unused NSException *exception) {
            }
        }
        if (ivars)
            free(ivars);
        currentClass = class_getSuperclass(currentClass);
    }

    if ([cell respondsToSelector:@selector(mediaCellFeedItem)]) {
        id media = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(mediaCellFeedItem));
        if (media && [media isKindOfClass:mediaClass])
            return media;
    }

    for (NSString *selectorName in @[ @"post", @"pagePhotoPost", @"pageVideoPost", @"media" ]) {
        id media = SPKObjectForSelector(cell, selectorName);
        if (media && [media isKindOfClass:mediaClass])
            return media;
    }

    return nil;
}

static id SPKFeedMediaForZoomFromView(UIView *view) {
    Class mediaClass = NSClassFromString(@"IGMedia");
    if (!view || !mediaClass)
        return nil;

    UICollectionView *collectionView = SPKFeedOuterCollectionView(view);
    if (!collectionView)
        return nil;

    NSInteger section = SPKFeedSectionForViewInCollection(view, collectionView);
    if (section < 0)
        return nil;

    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (!indexPath || indexPath.section != section)
            continue;

        NSString *className = NSStringFromClass([cell class]);
        if (![className containsString:@"Photo"] &&
            ![className containsString:@"Video"] &&
            ![className containsString:@"Media"] &&
            ![className containsString:@"Page"]) {
            continue;
        }

        id media = SPKFeedMediaFromCellByIntrospection(cell, mediaClass);
        if (media)
            return media;
    }

    return nil;
}

static NSInteger SPKFeedCarouselPageIndexFromView(UIView *view) {
    UICollectionView *collectionView = SPKFeedOuterCollectionView(view);
    if (!collectionView)
        return 0;

    NSInteger section = SPKFeedSectionForViewInCollection(view, collectionView);
    if (section < 0)
        return 0;

    for (UICollectionViewCell *cell in collectionView.visibleCells) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (!indexPath || indexPath.section != section)
            continue;
        if (![NSStringFromClass([cell class]) containsString:@"Page"])
            continue;

        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
        NSInteger scanned = 0;
        while (queue.count > 0 && scanned < 100) {
            UIView *current = queue.firstObject;
            [queue removeObjectAtIndex:0];
            scanned++;

            if ([current isKindOfClass:[UIScrollView class]] && current != collectionView) {
                UIScrollView *scrollView = (UIScrollView *)current;
                CGFloat pageWidth = scrollView.bounds.size.width;
                if (pageWidth > 100.0 && scrollView.contentSize.width > pageWidth * 1.5) {
                    return (NSInteger)llround(scrollView.contentOffset.x / pageWidth);
                }
            }

            for (UIView *subview in current.subviews) {
                [queue addObject:subview];
            }
        }
    }

    return 0;
}

static NSArray *SPKFeedCarouselChildren(id media) {
    return SPKActionButtonCarouselChildren(media);
}

static BOOL SPKFeedIsCarouselMedia(id media) {
    if (!media)
        return NO;

    if ([media respondsToSelector:@selector(isCarousel)]) {
        @try {
            if (((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isCarousel))) {
                return YES;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    if ([media respondsToSelector:@selector(mediaType)]) {
        @try {
            if (((NSInteger (*)(id, SEL))objc_msgSend)(media, @selector(mediaType)) == 8) {
                return YES;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return SPKFeedCarouselChildren(media).count > 0;
}

static BOOL SPKFeedMediaHasExpandableAsset(id media) {
    if (!media)
        return NO;

    if (SPKFeedIsCarouselMedia(media)) {
        for (id child in SPKFeedCarouselChildren(media)) {
            NSURL *videoURL = [SPKUtils getVideoUrlForMedia:(IGMedia *)child];
            NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:(IGMedia *)child];
            if (videoURL || photoURL)
                return YES;
        }
    }

    NSURL *videoURL = [SPKUtils getVideoUrlForMedia:(IGMedia *)media];
    NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:(IGMedia *)media];
    return videoURL || photoURL;
}

static BOOL SPKFeedViewHasExpandableAsset(UIView *view) {
    if (!view.window)
        return NO;
    id media = SPKFeedMediaForZoomFromView(view);
    return SPKFeedMediaHasExpandableAsset(media);
}

static BOOL SPKFeedShouldSuppressNativeLongPress(UIGestureRecognizer *gestureRecognizer) {
    if (!SPKFeedLongPressExpandEnabled() || !gestureRecognizer)
        return NO;
    return SPKFeedViewHasExpandableAsset(gestureRecognizer.view);
}

static BOOL SPKFeedShouldSuppressNativeLongPressFromHandler(id handler, UIGestureRecognizer *gestureRecognizer) {
    if (SPKFeedShouldSuppressNativeLongPress(gestureRecognizer))
        return YES;
    if (!SPKFeedLongPressExpandEnabled() || !handler)
        return NO;

    for (NSString *ivarName in @[ @"eligibleView", @"cell", @"_eligibleView", @"_cell" ]) {
        id candidate = [SPKUtils getIvarForObj:handler name:ivarName.UTF8String];
        if ([candidate isKindOfClass:[UIView class]] &&
            SPKFeedViewHasExpandableAsset((UIView *)candidate)) {
            return YES;
        }
    }
    return NO;
}

static SPKGallerySaveMetadata *SPKFeedMetadataForMedia(id media) {
    SPKGallerySaveMetadata *metadata = [[SPKGallerySaveMetadata alloc] init];
    metadata.source = (int16_t)SPKGallerySourceFeed;
    [SPKGalleryOriginController populateMetadata:metadata fromMedia:media];
    return metadata;
}

static SPKGallerySaveMetadata *SPKFeedMetadataForMediaWithUsernameFallback(id media, NSString *username) {
    SPKGallerySaveMetadata *metadata = SPKFeedMetadataForMedia(media);
    if (metadata.sourceUsername.length == 0 && username.length > 0) {
        metadata.sourceUsername = username;
        [SPKGalleryOriginController populateProfileMetadata:metadata username:username user:nil];
    }
    return metadata;
}

static id SPKFeedPostObjectFromFeedCell(UIView *feedCell) {
    if (!feedCell)
        return nil;
    id post = SPKObjectForSelector(feedCell, @"post");
    if (post)
        return post;
    post = SPKObjectForSelector(feedCell, @"mediaCellFeedItem");
    if (post)
        return post;
    post = SPKObjectForSelector(feedCell, @"media");
    if (post)
        return post;
    return [SPKUtils getIvarForObj:feedCell name:"_post"];
}

static NSString *SPKFeedCaptionForContext(SPKActionButtonContext *context, id media, NSArray *entries, NSInteger currentIndex) {
    NSString *caption = SPKCaptionFromMediaObject(media);
    if (caption.length > 0)
        return caption;
    NSInteger idx = MAX(0, MIN((NSInteger)entries.count - 1, currentIndex));
    if (entries.count > 0) {
        id entryMedia = [entries[idx] valueForKey:@"mediaObject"];
        caption = SPKCaptionFromMediaObject(entryMedia);
    }
    return caption;
}

static BOOL SPKFeedTriggerRepost(SPKActionButtonContext *context) {
    UIView *barView = context.view;
    UIResponder *responder = barView;
    Class feedCellClass = NSClassFromString(@"IGFeedItemUFICell");
    while (responder && !(feedCellClass && [responder isKindOfClass:feedCellClass])) {
        responder = [responder nextResponder];
    }
    if (!responder || ![responder respondsToSelector:@selector(UFIButtonBarDidTapOnRepost:)]) {
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(responder, @selector(UFIButtonBarDidTapOnRepost:), barView);
    return YES;
}

static SPKActionButtonContext *SPKFeedActionContext(UIView *barView) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    context.source = SPKActionButtonSourceFeed;
    context.view = barView;
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceFeed);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceFeed);
    context.mediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKFeedMediaFromBarView(resolvedContext.view);
    };
    context.bulkMediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKFeedMediaFromBarView(resolvedContext.view);
    };
    context.currentIndexResolver = ^NSInteger(SPKActionButtonContext *resolvedContext) {
        // Prefer the carousel's scroll-offset page index — the same signal the
        // Expand path uses, which reliably tracks the visible slide. Fall back to
        // the bar/page-control state only when the scroll index is 0 (either
        // genuinely page 0 or no inner carousel found).
        NSInteger scrollIndex = SPKFeedCarouselPageIndexFromView(resolvedContext.view);
        if (scrollIndex > 0)
            return scrollIndex;
        NSInteger barIndex = SPKFeedCurrentIndexFromBarView(resolvedContext.view);
        return barIndex >= 0 ? barIndex : scrollIndex;
    };
    context.captionResolver = ^NSString *(SPKActionButtonContext *resolvedContext, id media, NSArray *entries, NSInteger currentIndex) {
        return SPKFeedCaptionForContext(resolvedContext, media, entries, currentIndex);
    };
    context.repostHandler = ^BOOL(SPKActionButtonContext *resolvedContext) {
        return SPKFeedTriggerRepost(resolvedContext);
    };
    return context;
}

static BOOL SPKFeedActionFrameMatches(UIButton *button, CGRect frame) {
    if (![button isKindOfClass:[UIButton class]] || button.hidden || !button.superview)
        return NO;
    return ABS(CGRectGetMinX(button.frame) - CGRectGetMinX(frame)) < 0.5 &&
           ABS(CGRectGetMinY(button.frame) - CGRectGetMinY(frame)) < 0.5 &&
           ABS(CGRectGetWidth(button.frame) - CGRectGetWidth(frame)) < 0.5 &&
           ABS(CGRectGetHeight(button.frame) - CGRectGetHeight(frame)) < 0.5;
}

static void SPKInstallFeedActionButton(UIView *barView) {
    if (!barView)
        return;

    UIButton *button = (UIButton *)[barView viewWithTag:kSPKFeedActionButtonTag];
    if (![SPKUtils getBoolPref:@"feed_action_btn"]) {
        [button removeFromSuperview];
        return;
    }

    UIView *anyButton = SPKFeedAnyButtonFromBarView(barView);
    UIView *firstRightButton = SPKFeedFirstRightButtonFromBarView(barView);
    if (!anyButton || !firstRightButton) {
        [button removeFromSuperview];
        return;
    }

    BOOL isCountsView = [barView isKindOfClass:NSClassFromString(@"IGUFIInteractionCountsView")];
    CGFloat width = 40.0;
    CGRect expectedFrame;

    if (isCountsView) {
        CGRect anyFrame = anyButton.frame;
        width = CGRectGetWidth(anyFrame) > 0.0 ? CGRectGetWidth(anyFrame) : 40.0;
        expectedFrame = CGRectMake(CGRectGetMinX(firstRightButton.frame) - width,
                                   CGRectGetMinY(anyFrame) + 2.0,
                                   width,
                                   CGRectGetHeight(anyFrame));
    } else {
        UIView *anyColumnView = (anyButton.superview == barView) ? anyButton : anyButton.superview;
        UIView *rightColumnView = (firstRightButton.superview == barView) ? firstRightButton : firstRightButton.superview;

        CGRect anyColumnFrame = [anyColumnView.superview convertRect:anyColumnView.frame toView:barView];
        CGRect rightColumnFrame = [rightColumnView.superview convertRect:rightColumnView.frame toView:barView];

        width = CGRectGetWidth(anyColumnFrame) > 0.0 ? CGRectGetWidth(anyColumnFrame) : 40.0;
        expectedFrame = CGRectMake(CGRectGetMinX(rightColumnFrame) - width,
                                   CGRectGetMinY(anyColumnFrame),
                                   width,
                                   CGRectGetHeight(anyColumnFrame));
    }
    // Reconfigure when EITHER the layout OR the resolved post changed. Gating on
    // the frame alone left a recycled bar (same layout, new post) showing the
    // previous post's menu — the actual cause of "video shows photo actions": the
    // menu was simply never rebuilt for the new item. The post-change check is a
    // cheap pointer compare; SPKConfigureActionButton still has its own
    // signature short-circuit for the genuinely-unchanged case.
    id barMedia = SPKFeedBarMediaSignal(barView);
    id lastConfiguredMedia = objc_getAssociatedObject(button, kSPKFeedConfiguredMediaAssocKey);
    if (button && SPKFeedActionFrameMatches(button, expectedFrame) && barMedia == lastConfiguredMedia)
        return;

    button = SPKActionButtonWithTag(barView, kSPKFeedActionButtonTag);
    button.translatesAutoresizingMaskIntoConstraints = YES;
    SPKConfigureActionButton(button, SPKFeedActionContext(barView));
    objc_setAssociatedObject(button, kSPKFeedConfiguredMediaAssocKey, barMedia, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (button.hidden)
        return;

    button.frame = expectedFrame;
    SPKApplyButtonStyle(button, SPKActionButtonSourceFeed);
}

static BOOL SPKFeedViewIsNearbyMediaContainer(UIView *candidate, UIView *sourceView) {
    if (!candidate || !sourceView)
        return NO;
    if (candidate == sourceView)
        return YES;

    NSString *className = NSStringFromClass([candidate class]);
    for (NSString *fragment in @[ @"Feed", @"Media", @"Photo", @"Video", @"Page", @"Carousel" ]) {
        if ([className containsString:fragment])
            return YES;
    }
    return NO;
}

static void SPKRequireNativeLongPressRecognizersToFail(UIView *view, UILongPressGestureRecognizer *spkLongPress) {
    if (!view || !spkLongPress)
        return;

    UIView *walker = view;
    NSInteger depth = 0;
    while (walker && depth < 10) {
        if (SPKFeedViewIsNearbyMediaContainer(walker, view)) {
            for (UIGestureRecognizer *gesture in walker.gestureRecognizers) {
                if (gesture == spkLongPress)
                    continue;
                if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
                    continue;
                if (objc_getAssociatedObject(gesture, kSPKFeedExpandLongPressMarkerAssocKey))
                    continue;
                [gesture requireGestureRecognizerToFail:spkLongPress];
            }
        }

        if ([walker isKindOfClass:[UICollectionView class]] || [walker isKindOfClass:[UITableView class]]) {
            break;
        }
        walker = walker.superview;
        depth++;
    }
}

static void SPKAddFeedExpandLongPressIfNeeded(UIView *view, SEL action) {
    if (!SPKFeedLongPressExpandEnabled() || !view || !action)
        return;

    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]] &&
            objc_getAssociatedObject(gesture, kSPKFeedExpandLongPressMarkerAssocKey)) {
            SPKRequireNativeLongPressRecognizersToFail(view, (UILongPressGestureRecognizer *)gesture);
            return;
        }
    }

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:view action:action];
    longPress.minimumPressDuration = 0.3;
    longPress.cancelsTouchesInView = NO;
    SPKFeedExpandLongPressDelegate *delegate = [[SPKFeedExpandLongPressDelegate alloc] init];
    longPress.delegate = delegate;
    [view addGestureRecognizer:longPress];
    objc_setAssociatedObject(longPress, kSPKFeedExpandLongPressMarkerAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(longPress, kSPKFeedExpandLongPressDelegateAssocKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKRequireNativeLongPressRecognizersToFail(view, longPress);
}

static void SPKHandleFeedExpandLongPress(UIView *view, UILongPressGestureRecognizer *sender) {
    if (!SPKFeedLongPressExpandEnabled() || !view || !sender || sender.state != UIGestureRecognizerStateBegan || !view.window)
        return;

    id media = SPKFeedMediaForZoomFromView(view);
    if (!media)
        return;

    NSString *username = SPKUsernameFromMediaObject(media);
    SPKGallerySaveMetadata *metadata = SPKFeedMetadataForMediaWithUsernameFallback(media, username);

    if (SPKFeedIsCarouselMedia(media)) {
        NSArray *children = SPKFeedCarouselChildren(media);
        NSMutableArray<SPKMediaItem *> *items = [NSMutableArray array];
        NSInteger index = 0;
        for (id child in children) {
            NSURL *videoURL = [SPKUtils getVideoUrlForMedia:(IGMedia *)child];
            NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:(IGMedia *)child];
            if (!videoURL && !photoURL) {
                index++;
                continue;
            }

            SPKMediaItem *item = [SPKMediaItem itemWithFileURL:(videoURL ?: photoURL)];
            item.mediaType = videoURL ? SPKMediaItemTypeVideo : SPKMediaItemTypeImage;
            item.gallerySaveSource = SPKGallerySourceFeed;
            item.galleryMetadata = SPKFeedMetadataForMediaWithUsernameFallback(child, username);
            if (child != media) {
                [SPKGalleryOriginController populateMetadata:item.galleryMetadata fromMedia:media];
                if (children.count > 1) {
                    item.galleryMetadata.sourceMediaURLString = [SPKUtils appendImgIndex:index toURLString:item.galleryMetadata.sourceMediaURLString];
                }
            }
            item.sourceMediaObject = child;
            if (username.length > 0)
                item.title = username;
            [items addObject:item];
            index++;
        }

        if (items.count > 0) {
            NSInteger index = SPKFeedCarouselPageIndexFromView(view);
            if (index < 0 || index >= (NSInteger)items.count)
                index = 0;
            // The long press is felt, not announced: the viewer opening is the confirmation.
            SPKNotificationTriggerHaptic(kSPKActionExpand, SPKNotificationToneInfo);
            [SPKFullScreenMediaPlayer showMediaItems:items
                                     startingAtIndex:index
                                            metadata:metadata
                                      playbackSource:SPKFullScreenPlaybackSourceFeed
                                          sourceView:view
                                          controller:[SPKUtils viewControllerForAncestralView:view]
                                       pausePlayback:nil
                                      resumePlayback:nil];
            return;
        }
    }

    NSURL *videoURL = [SPKUtils getVideoUrlForMedia:(IGMedia *)media];
    NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:(IGMedia *)media];
    if (!videoURL && !photoURL)
        return;

    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:(videoURL ?: photoURL)];
    item.mediaType = videoURL ? SPKMediaItemTypeVideo : SPKMediaItemTypeImage;
    item.gallerySaveSource = SPKGallerySourceFeed;
    item.galleryMetadata = metadata;
    item.sourceMediaObject = media;
    if (username.length > 0)
        item.title = username;

    SPKNotificationTriggerHaptic(kSPKActionExpand, SPKNotificationToneInfo);
    [SPKFullScreenMediaPlayer showMediaItems:@[ item ]
                             startingAtIndex:0
                                    metadata:metadata
                              playbackSource:SPKFullScreenPlaybackSourceFeed
                                  sourceView:view
                                  controller:[SPKUtils viewControllerForAncestralView:view]
                               pausePlayback:nil
                              resumePlayback:nil];
}

static void SPKExpandFeedLongPressAction(id self, SEL _cmd, UILongPressGestureRecognizer *sender) {
    SPKHandleFeedExpandLongPress((UIView *)self, sender);
}

static void (*orig_singleFeedMoreMenuLongPress)(id, SEL, UIGestureRecognizer *);
static void SPKHookedSingleFeedMoreMenuLongPress(id self, SEL _cmd, UIGestureRecognizer *gestureRecognizer) {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan &&
        SPKFeedShouldSuppressNativeLongPressFromHandler(self, gestureRecognizer)) {
        return;
    }
    if (orig_singleFeedMoreMenuLongPress) {
        orig_singleFeedMoreMenuLongPress(self, _cmd, gestureRecognizer);
    }
}

static void SPKInstallNativeFeedLongPressSuppressionHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class singleFeedHandler = objc_getClass("IGFeedLongPressOrchestrator.IGSingleFeedMoreMenuLongPressHandler");
        SEL handleLongPress = @selector(handleLongPress:);
        if (singleFeedHandler && class_getInstanceMethod(singleFeedHandler, handleLongPress)) {
            MSHookMessageEx(singleFeedHandler,
                            handleLongPress,
                            (IMP)SPKHookedSingleFeedMoreMenuLongPress,
                            (IMP *)&orig_singleFeedMoreMenuLongPress);
        }
    });
}

static void (*orig_swiftModernFeedVideo_didMove)(id, SEL);
static void (*orig_swiftModernFeedVideo_layout)(id, SEL);

static void SPKHookSwiftModernFeedVideoDidMove(id self, SEL _cmd) {
    if (orig_swiftModernFeedVideo_didMove)
        orig_swiftModernFeedVideo_didMove(self, _cmd);
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

static void SPKHookSwiftModernFeedVideoLayout(id self, SEL _cmd) {
    if (orig_swiftModernFeedVideo_layout)
        orig_swiftModernFeedVideo_layout(self, _cmd);
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%group SPKFeedActionButtonHooks

%hook IGFeedPhotoView
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGFeedItemVideoView
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGFeedItemMediaCell
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_mediaCell_handleExpandLongPress:));
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"FeedActionButton.layoutSubviews");
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_mediaCell_handleExpandLongPress:));
}

%new - (void)spk_mediaCell_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGModernFeedVideoCell
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"FeedActionButton.layoutSubviews2");
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGPageMediaView
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGFeedItemPagePhotoCell
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGFeedItemPageVideoCell
- (void)didMoveToSuperview {
    %orig;
    SPKAddFeedExpandLongPressIfNeeded((UIView *)self, @selector(spk_handleExpandLongPress:));
}

%new - (void)spk_handleExpandLongPress:(UILongPressGestureRecognizer *)sender {
SPKHandleFeedExpandLongPress((UIView *)self, sender);
}
%end

%hook IGUFIButtonBarView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"FeedActionButton.layoutSubviews3");
    SPKInstallFeedActionButton((UIView *)self);
}
%end

%hook IGUFIInteractionCountsView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"FeedActionButton.layoutSubviews4");
    SPKInstallFeedActionButton((UIView *)self);
}
%end

%end

extern "C" void SPKInstallFeedActionButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"feed_action_btn"] &&
        ![SPKUtils getBoolPref:@"feed_long_press_expand"]) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKFeedActionButtonHooks,
                       IGPageMediaView = SPKResolveIGClass(@"IGFeedItemPageCell.IGPageMediaView", @"IGPageMediaView"),
                       IGFeedItemPagePhotoCell = SPKResolveIGClass(@"IGFeedItemPageCell.IGFeedItemPagePhotoCell", @"IGFeedItemPagePhotoCell"));
        SPKInstallNativeFeedLongPressSuppressionHooks();

        Class modernObjCName = objc_getClass("IGModernFeedVideoCell");
        Class modernSwiftRuntime = objc_getClass("IGModernFeedVideoCell.IGModernFeedVideoCell");
        if (modernSwiftRuntime && modernSwiftRuntime != modernObjCName) {
            class_addMethod(modernSwiftRuntime, @selector(spk_handleExpandLongPress:), (IMP)SPKExpandFeedLongPressAction, "v@:@");
            MSHookMessageEx(modernSwiftRuntime, @selector(didMoveToSuperview), (IMP)SPKHookSwiftModernFeedVideoDidMove, (IMP *)&orig_swiftModernFeedVideo_didMove);
            MSHookMessageEx(modernSwiftRuntime, @selector(layoutSubviews), (IMP)SPKHookSwiftModernFeedVideoLayout, (IMP *)&orig_swiftModernFeedVideo_layout);
        }
    });
}
