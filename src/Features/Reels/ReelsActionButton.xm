#import <objc/message.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static NSInteger const kSPKReelsActionButtonTag = 921342;
static const void *kSPKReelsActionButtonMediaKey = &kSPKReelsActionButtonMediaKey;
static const void *kSPKReelsActionButtonCarouselIndexKey = &kSPKReelsActionButtonCarouselIndexKey;
static CGFloat const kSPKReelsActionButtonSize = 44.0;
static CGFloat const kSPKReelsActionButtonBottomOffset = -5.0;

// Instagram changes the native reel-UFI tint when the current media enters or
// leaves HDR/EDR. Reuse that tint instead of pinning Sparkle's icon to white.
static UIColor *SPKReelsNativeUFIColor(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return UIColor.whiteColor;

    id likeButton = nil;
    SEL selector = @selector(ufiLikeButton);
    if ([verticalUFIView respondsToSelector:selector]) {
        likeButton = ((id (*)(id, SEL))objc_msgSend)(verticalUFIView, selector);
    }

    if (![likeButton isKindOfClass:[UIButton class]])
        return UIColor.whiteColor;

    UIButton *like = (UIButton *)likeButton;
    UIColor *tint = like.imageView.tintColor ?: like.tintColor;
    return tint ?: UIColor.whiteColor;
}

static void SPKApplyReelsNativeUFIColor(UIButton *button, UIColor *color) {
    if (![button isKindOfClass:[UIButton class]])
        return;

    color = color ?: UIColor.whiteColor;
    // Instagram's UFI icon is EDR-capable. Sparkle's icon is nested inside
    // SPKChromeCanvas, so opt the custom layers into the same compositing path.
    SPKChromeEnableExtendedDynamicRangeContent(button);
    button.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
    button.tintColor = color;

    UIImageView *buttonImageView = button.imageView;
    if (buttonImageView) {

        buttonImageView.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        buttonImageView.tintColor = color;
        UIImage *image = buttonImageView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
            buttonImageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    // Sparkle action buttons use a private icon view so bundled Instagram icons
    // and SF Symbols share the same chrome. Keep that path in sync as well.
    if ([button isKindOfClass:[SPKChromeButton class]]) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        chromeButton.iconTint = color;

        chromeButton.iconView.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        chromeButton.iconView.tintColor = color;
        UIImage *image = chromeButton.iconView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
            chromeButton.iconView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

// The UFI casts one shadow from its whole subtree. The button lives beside the
// UFI, so it misses that shadow; copy it onto the icon so both columns match,
// including when Instagram changes the shadow for EDR reels. When the UFI casts
// none, the style's default glyph shadow stays.
static void SPKMirrorReelsUFIShadow(UIButton *button, UIView *verticalUFIView) {
    if (![button isKindOfClass:[SPKChromeButton class]] || !verticalUFIView)
        return;
    CALayer *source = verticalUFIView.layer;
    if (source.shadowOpacity <= 0.0 || !source.shadowColor)
        return;

    CALayer *target = ((SPKChromeButton *)button).iconView.layer;
    if (target.shadowOpacity != source.shadowOpacity)
        target.shadowOpacity = source.shadowOpacity;
    if (target.shadowRadius != source.shadowRadius)
        target.shadowRadius = source.shadowRadius;
    if (!CGSizeEqualToSize(target.shadowOffset, source.shadowOffset))
        target.shadowOffset = source.shadowOffset;
    if (!CGColorEqualToColor(target.shadowColor, source.shadowColor))
        target.shadowColor = source.shadowColor;
}

// MARK: - View hierarchy helpers

// MARK: - Deterministic resolution from IGUnifiedVideoCollectionView (Layer 2)

/// Walk up from `view` to find the paging collection view that holds all reel cells.
static UICollectionView *SPKReelsFindPagingCollectionView(UIView *view) {
    Class pagingClass = NSClassFromString(@"IGUnifiedVideoCollectionView");
    if (!pagingClass)
        return nil;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 30; depth++) {
        if ([current isKindOfClass:pagingClass])
            return (UICollectionView *)current;
        current = current.superview;
    }
    return nil;
}

/// Given the paging collection view, find the currently visible reel cell
/// using contentOffset + cell height. Returns a UICollectionViewCell that is
/// an IGSundialViewerVideoCell, CarouselCell, or PhotoCell.
static UICollectionViewCell *SPKReelsCurrentCellFromPagingView(UICollectionView *pagingView) {
    if (!pagingView)
        return nil;

    CGFloat pageHeight = pagingView.bounds.size.height;
    if (pageHeight <= 0)
        return nil;

    // Center-point heuristic: find the cell whose center is closest to the
    // collection view's visible center.
    CGFloat centerY = pagingView.contentOffset.y + pageHeight / 2.0;

    NSArray<UICollectionViewCell *> *visibleCells = pagingView.visibleCells;
    UICollectionViewCell *bestCell = nil;
    CGFloat bestDistance = CGFLOAT_MAX;

    for (UICollectionViewCell *cell in visibleCells) {
        CGFloat cellCenterY = CGRectGetMidY(cell.frame);
        CGFloat distance = ABS(cellCenterY - centerY);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestCell = cell;
        }
    }

    return bestCell;
}

/// Read the cell's media passthrough ivar (VideoCell and CarouselCell).
/// Falls back to scanning all object-typed ivars for IGMedia.
static id SPKReelsMediaFromCell(UICollectionViewCell *cell) {
    if (!cell)
        return nil;

    id passthrough = SPKSundialCellMedia(cell);
    if (passthrough)
        return passthrough;

    // Fallback: scan ivars for IGMedia
    Class mediaClass = NSClassFromString(@"IGMedia");
    if (!mediaClass)
        return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([cell class], &count);
    id found = nil;
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@')
            continue;
        @try {
            id value = object_getIvar(cell, ivars[i]);
            if (value && [value isKindOfClass:mediaClass]) {
                found = value;
                break;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (ivars)
        free(ivars);
    return found;
}

// MARK: - Carousel helpers

static NSArray *SPKReelsCarouselChildren(id parentMedia) {
    return SPKActionButtonCarouselChildren(parentMedia);
}

/// Read the carousel's current page index from a **specific** carousel cell.
/// Only reads ivars from the cell we deterministically found — never from a BFS result.
static NSInteger SPKReelsCarouselCurrentIndex(UICollectionViewCell *carouselCell, id parentMedia) {
    if (!carouselCell || !parentMedia)
        return -1;

    NSArray *children = SPKReelsCarouselChildren(parentMedia);
    if (children.count == 0)
        return -1;
    if (children.count == 1)
        return 0;

    NSInteger currentIdx = 0;
    Ivar idxIvar = class_getInstanceVariable([carouselCell class], "_currentIndex");
    if (idxIvar) {
        ptrdiff_t offset = ivar_getOffset(idxIvar);
        currentIdx = *(NSInteger *)((char *)(__bridge void *)carouselCell + offset);
    }

    if (!idxIvar || currentIdx == 0) {
        Ivar fracIvar = class_getInstanceVariable([carouselCell class], "_currentFractionalIndex");
        if (fracIvar) {
            ptrdiff_t offset = ivar_getOffset(fracIvar);
            double fractionalIndex = *(double *)((char *)(__bridge void *)carouselCell + offset);
            NSInteger roundedIdx = (NSInteger)round(fractionalIndex);
            if (roundedIdx > 0)
                currentIdx = roundedIdx;
        }
    }

    Ivar collectionViewIvar = class_getInstanceVariable([carouselCell class], "_collectionView");
    if (collectionViewIvar) {
        UICollectionView *cv = object_getIvar(carouselCell, collectionViewIvar);
        if (cv) {
            CGFloat pageWidth = cv.bounds.size.width;
            if (pageWidth > 0) {
                NSInteger cvIdx = (NSInteger)round(cv.contentOffset.x / pageWidth);
                if (cvIdx > currentIdx)
                    currentIdx = cvIdx;
            }
        }
    }

    if (currentIdx < 0)
        return 0;
    if ((NSUInteger)currentIdx >= children.count)
        return (NSInteger)children.count - 1;

    return currentIdx;
}

// MARK: - Media resolution (deterministic, with BFS fallback)

/// Walk UP the superview chain to find the cell that actually CONTAINS this UFI/button.
/// This is the cell the button belongs to — independent of which cell is currently
/// centered, so it doesn't drift with scroll timing.
static UICollectionViewCell *SPKReelsOwnEnclosingCell(UIView *view) {
    Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
    Class videoCellClass = NSClassFromString(@"IGSundialViewerVideoCell");
    Class photoCellClass = NSClassFromString(@"IGSundialViewerPhotoCell");
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 25; depth++) {
        if ((carouselClass && [current isKindOfClass:carouselClass]) ||
            (videoCellClass && [current isKindOfClass:videoCellClass]) ||
            (photoCellClass && [current isKindOfClass:photoCellClass])) {
            return (UICollectionViewCell *)current;
        }
        current = current.superview;
    }
    return nil;
}

/// Primary resolution: the UFI's OWN enclosing cell (per-button correct, timing-independent).
/// Fallback: globally-centered cell via the paging collection view, then the delegate chain.
static id SPKReelsMediaProvider(UIView *sourceView) {
    // --- PRIMARY: resolve THIS UFI's own enclosing cell ---
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id media = SPKReelsMediaFromCell(ownCell);
        if (media) {
            return media; // carousel parent returned as-is; currentIndexResolver picks the child
        }
    }

    // --- FALLBACK: globally-centered cell via IGUnifiedVideoCollectionView ---
    UICollectionView *pagingView = SPKReelsFindPagingCollectionView(sourceView);
    if (pagingView) {
        UICollectionViewCell *currentCell = SPKReelsCurrentCellFromPagingView(pagingView);
        if (currentCell) {
            id media = SPKReelsMediaFromCell(currentCell);
            if (media) {
                return media;
            }
        }
    }

    // Last resort: delegate chain
    id delegate = SPKObjectForSelector(sourceView, @"delegate");
    id media = SPKObjectForSelector(delegate, @"media");
    if (!media)
        media = SPKKVCObject(delegate, @"media");
    return media;
}

static id SPKReelsBulkMediaProvider(UIView *sourceView) {
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id media = SPKReelsMediaFromCell(ownCell);
        Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
        if (media && carouselClass && [ownCell isKindOfClass:carouselClass]) {
            NSArray *children = SPKReelsCarouselChildren(media);
            if (children.count > 1)
                return media;
        }
    }
    return SPKReelsMediaProvider(sourceView);
}

// MARK: - Current index resolution

static NSInteger SPKReelsCurrentIndexFromVerticalUFI(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return -1;

    for (NSString *selectorName in @[ @"pageIndicator", @"pagingControl" ]) {
        id indicator = SPKObjectForSelector(verticalUFIView, selectorName);
        if ([indicator isKindOfClass:[UIPageControl class]])
            return (NSInteger)((UIPageControl *)indicator).currentPage;
        NSNumber *currentPageNumber = [SPKUtils numericValueForObj:indicator selectorName:@"currentPage"];
        if (currentPageNumber)
            return currentPageNumber.integerValue;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:verticalUFIView];
    while (queue.count > 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([candidate isKindOfClass:[UIPageControl class]])
            return (NSInteger)((UIPageControl *)candidate).currentPage;
        for (UIView *subview in candidate.subviews)
            [queue addObject:subview];
    }

    return -1;
}

static NSInteger SPKReelsCurrentIndexForContext(UIView *sourceView) {
    // PRIMARY: this UFI's own enclosing carousel cell.
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id parentMedia = SPKReelsMediaFromCell(ownCell);
        Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
        if (carouselClass && [ownCell isKindOfClass:carouselClass] && parentMedia) {
            NSInteger carouselIndex = SPKReelsCarouselCurrentIndex(ownCell, parentMedia);
            if (carouselIndex >= 0)
                return carouselIndex;
        }
    }

    // Fallback: UFI page indicator
    NSInteger ufiIndex = SPKReelsCurrentIndexFromVerticalUFI(sourceView);
    return ufiIndex >= 0 ? ufiIndex : 0;
}

// MARK: - Caption & repost

static NSString *SPKReelsCaptionForContext(SPKActionButtonContext *context, id media, NSArray *entries, NSInteger currentIndex) {
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

static BOOL SPKReelsTriggerRepost(SPKActionButtonContext *context) {
    if (!context.view)
        return NO;

    // IG 436+ renamed these to drop the leading underscore (`didTapRepostButton`);
    // older versions used `_didTapRepostButton` / `_didTapRepostButton:`. Try every
    // known variant so the action button's repost works across versions.
    NSArray<NSString *> *noArgSelectors = @[ @"didTapRepostButton", @"_didTapRepostButton" ];
    for (NSString *selectorName in noArgSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([context.view respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(context.view, selector);
            return YES;
        }
    }

    NSArray<NSString *> *oneArgSelectors = @[ @"didTapRepostButton:", @"_didTapRepostButton:" ];
    for (NSString *selectorName in oneArgSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([context.view respondsToSelector:selector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(context.view, selector, nil);
            return YES;
        }
    }

    return NO;
}

// MARK: - Action context

static SPKActionButtonContext *SPKReelsActionContext(UIView *verticalUFIView) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    context.source = SPKActionButtonSourceReels;
    context.view = verticalUFIView;
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceReels);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceReels);
    context.mediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKReelsMediaProvider(resolvedContext.view);
    };
    context.bulkMediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKReelsBulkMediaProvider(resolvedContext.view);
    };
    context.currentIndexResolver = ^NSInteger(SPKActionButtonContext *resolvedContext) {
        return SPKReelsCurrentIndexForContext(resolvedContext.view);
    };
    context.captionResolver = ^NSString *(SPKActionButtonContext *resolvedContext, id media, NSArray *entries, NSInteger currentIndex) {
        return SPKReelsCaptionForContext(resolvedContext, media, entries, currentIndex);
    };
    context.repostHandler = ^BOOL(SPKActionButtonContext *resolvedContext) {
        return SPKReelsTriggerRepost(resolvedContext);
    };
    return context;
}

// MARK: - Layout

// The button used to be positioned with four required constraints, one of them
// cross-view: its bottom edge pinned above the UFI's top anchor. That put a view
// hanging outside the UFI into Instagram's own container as a required part of
// the layout, and any container whose height the engine derives from its subtree
// grew by the button's overhang, which pushed the reel's content upwards on the
// next full layout pass (cell reuse after a scroll). The button's position is
// fully determined without the engine, so it is placed by frame instead and the
// constraint system never sees it.
static CGRect SPKReelsActionButtonFrame(UIView *host, UIView *verticalUFIView) {
    CGRect ufiFrame = [host convertRect:verticalUFIView.bounds fromView:verticalUFIView];
    if (CGRectIsEmpty(ufiFrame) && CGRectIsEmpty(verticalUFIView.bounds))
        return CGRectZero;

    CGFloat bottom = CGRectGetMinY(ufiFrame) + kSPKReelsActionButtonBottomOffset;
    return CGRectMake(CGRectGetMidX(ufiFrame) - kSPKReelsActionButtonSize / 2.0,
                      bottom - kSPKReelsActionButtonSize,
                      kSPKReelsActionButtonSize,
                      kSPKReelsActionButtonSize);
}

static void SPKApplyReelsActionButtonFrame(UIButton *button, UIView *host, UIView *verticalUFIView) {
    if (!button || !host || !verticalUFIView)
        return;

    CGRect frame = SPKReelsActionButtonFrame(host, verticalUFIView);
    if (CGRectIsEmpty(frame))
        return;
    if (!CGRectEqualToRect(button.frame, frame))
        button.frame = frame;
}

static UIButton *SPKReelsHostedActionButton(UIView *verticalUFIView);

// The button used to live in IGSundialViewerControlsOverlayContainerView, the
// same container whose chrome Instagram measures when it positions the media.
// Hosting it one level further out, beside the overlay's Metal layer view, keeps
// it clear of that measurement; it is where Instagram puts its own media buttons.
static UIView *SPKReelsActionButtonHost(UIView *verticalUFIView) {
    UIView *node = verticalUFIView.superview;
    for (NSInteger depth = 0; node && depth < 4; depth++) {
        if ([NSStringFromClass(node.class) containsString:@"MetalLayerView"] && node.superview)
            return node.superview;
        node = node.superview;
    }
    return verticalUFIView.superview ?: verticalUFIView;
}

// Moving a view's origin does not call its own layoutSubviews, only a size
// change does. The UFI's layoutSubviews was the sole trigger for placing the
// button, so when Instagram slid the overlay up by frame during the interactive
// dismissal the button stayed behind. Constraints used to ride that out, since
// the engine re-solved against the UFI's new frame in the same pass. This is the
// frame-based equivalent: reposition from the UFI's own position setters, which
// also means that inside an animation block the button animates with it.
static void SPKReelsRepositionActionButton(UIView *verticalUFIView) {
    UIView *host = SPKReelsActionButtonHost(verticalUFIView);
    if (!host)
        return;

    UIButton *button = SPKReelsHostedActionButton(verticalUFIView);
    if (!button)
        return;

    SPKApplyReelsActionButtonFrame(button, host, verticalUFIView);
}

static BOOL SPKReelsActionButtonLayoutIsCurrent(UIButton *button) {
    return [button isKindOfClass:[UIButton class]] && !button.hidden && button.superview != nil;
}

// MARK: - Visibility

static UIButton *SPKReelsHostedActionButton(UIView *verticalUFIView) {
    for (UIView *subview in SPKReelsActionButtonHost(verticalUFIView).subviews) {
        if (subview.tag == kSPKReelsActionButtonTag && [subview isKindOfClass:[UIButton class]])
            return (UIButton *)subview;
    }
    return nil;
}

// The button is a sibling of the UFI, so it must follow the UFI's fades itself.
// Called from the UFI's alpha/hidden setters so the change lands in the same
// call and inside the same animation block, never a stale mid-fade value. The
// controls overlay also fades every subview of its container, ours included, and
// only restores its own controls; the alpha source makes those writes follow the
// UFI instead of stranding the button at zero until the next layout pass.
static void SPKReelsSyncActionButtonVisibility(UIView *verticalUFIView) {
    UIButton *button = SPKReelsHostedActionButton(verticalUFIView);
    if (!button)
        return;
    if ([button isKindOfClass:[SPKActionMenuButton class]] && ((SPKActionMenuButton *)button).spk_alphaSource != verticalUFIView)
        ((SPKActionMenuButton *)button).spk_alphaSource = verticalUFIView;
    CGFloat alpha = verticalUFIView.hidden ? 0.0 : verticalUFIView.alpha;
    if (ABS(button.alpha - alpha) > 0.001)
        button.alpha = alpha;
}

// MARK: - UFI EDR

// The UFI layer rasterizes, and its cache clamps to SDR unless the layer itself
// wants EDR, so Instagram's glyphs and counts rendered their HDR tint dim until
// a touch or a cell reuse redrew them. The action button used to set this by
// living inside the UFI (the icon's ancestor walk reached the UFI layer); now
// that it lives beside it, set it directly.
static void SPKEnableReelsUFIEDR(UIView *verticalUFIView) {
    CALayer *layer = verticalUFIView.layer;
    SEL getter = NSSelectorFromString(@"wantsExtendedDynamicRangeContent");
    SEL setter = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    if (![layer respondsToSelector:getter] || ![layer respondsToSelector:setter])
        return;
    if (((BOOL (*)(id, SEL))objc_msgSend)(layer, getter))
        return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setter, YES);
}

// MARK: - Installer (with media-change gate — Layer 1)

void SPKInstallReelsActionButton(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return;

    // Host the button beside the UFI, not inside it. The UFI layer rasterizes and
    // casts a shadow from its whole subtree, so as a sublayer the button's
    // silhouette became an opaque black shape whenever UIKit re-rendered it for
    // the touch highlight and the context-menu morph. The UFI's bounds also do
    // not contain the button, which sits above its top edge.
    UIView *host = SPKReelsActionButtonHost(verticalUFIView);
    // Older builds hosted the button inside the UFI, and then inside the overlay
    // container. Clear both so a stale one cannot linger beside the new host.
    for (UIView *previousHost in @[ verticalUFIView, verticalUFIView.superview ?: verticalUFIView ]) {
        if (previousHost == host)
            continue;
        UIView *stale = [previousHost viewWithTag:kSPKReelsActionButtonTag];
        if (stale)
            [stale removeFromSuperview];
    }

    UIButton *button = SPKReelsHostedActionButton(verticalUFIView);
    if (![SPKUtils getBoolPref:@"reels_action_btn"]) {
        [button removeFromSuperview];
        return;
    }

    SPKEnableReelsUFIEDR(verticalUFIView);
    SPKReelsSyncActionButtonVisibility(verticalUFIView);
    // Siblings are added and reordered on cell reuse; keep the button on top.
    if (button && host.subviews.lastObject != button)
        [host bringSubviewToFront:button];

    // This must run before the layout/media early return: HDR/EDR changes can
    // update Instagram's like tint without changing the reel or our tracked state.
    // The frame belongs here for the same reason: the UFI moves on layout passes
    // that change neither the media nor the carousel index, and nothing else
    // repositions the button now that it is placed by frame.
    if (button) {
        SPKApplyReelsNativeUFIColor(button, SPKReelsNativeUFIColor(verticalUFIView));
        SPKMirrorReelsUFIShadow(button, verticalUFIView);
        SPKApplyReelsActionButtonFrame(button, host, verticalUFIView);
    }

    // Resolve current media to detect whether we need to reconfigure
    id currentMedia = SPKReelsMediaProvider(verticalUFIView);
    NSInteger currentCarouselIdx = SPKReelsCurrentIndexForContext(verticalUFIView);
    id lastMedia = button ? objc_getAssociatedObject(button, kSPKReelsActionButtonMediaKey) : nil;
    NSNumber *lastCarouselIdx = button ? objc_getAssociatedObject(button, kSPKReelsActionButtonCarouselIndexKey) : nil;

    BOOL mediaChanged = (lastMedia != currentMedia) ||
                        (lastCarouselIdx && lastCarouselIdx.integerValue != currentCarouselIdx);

    if (SPKReelsActionButtonLayoutIsCurrent(button) && !mediaChanged) {
        return;
    }

    button = button ?: SPKActionButtonWithTag(host, kSPKReelsActionButtonTag);
    SPKReelsSyncActionButtonVisibility(verticalUFIView);
    SPKConfigureActionButton(button, SPKReelsActionContext(verticalUFIView));

    // Store the resolved media + carousel index for change detection on next call
    objc_setAssociatedObject(button, kSPKReelsActionButtonMediaKey, currentMedia, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKReelsActionButtonCarouselIndexKey, @(currentCarouselIdx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (button.hidden)
        return;

    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.autoresizingMask = UIViewAutoresizingNone;
    SPKApplyReelsActionButtonFrame(button, host, verticalUFIView);

    [host bringSubviewToFront:button];
    SPKApplyButtonStyle(button, SPKActionButtonSourceReels);
    SPKApplyReelsNativeUFIColor(button, SPKReelsNativeUFIColor(verticalUFIView));
    SPKMirrorReelsUFIShadow(button, verticalUFIView);
}

%group SPKReelsActionButtonHooks

%hook IGSundialViewerVerticalUFI
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ReelsActionButton.layoutSubviews");
    SPKInstallReelsActionButton((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    SPKReelsRepositionActionButton((UIView *)self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    SPKReelsRepositionActionButton((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}

- (void)didMoveToSuperview {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}
%end

%end

extern "C" void SPKInstallReelsActionButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"reels_action_btn"])
        return;

    // IG 436+ renamed the Reels UFI class to a Swift-mangled symbol; resolve it at
    // runtime and bind the hook group to it. Bail (without burning the once token)
    // if the class isn't registered yet so a later pass can retry.
    Class ufiClass = SPKReelsVerticalUFIClass();
    if (!ufiClass)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKReelsActionButtonHooks, IGSundialViewerVerticalUFI = ufiClass);
    });
}
