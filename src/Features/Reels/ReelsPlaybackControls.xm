#import <objc/message.h>
#import <objc/runtime.h>

#import "../../App/SPKPerfMeter.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"
#import "../../Shared/Playback/SPKPlaybackPanel.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

static NSString *const kSPKReelsMoreButtonIdentifier = @"more-options-button";
static NSInteger const kSPKReelsSpeedBadgeTag = 926012;
// Sparkle's Reels action button; the speed text sits above it when present.
static NSInteger const kSPKReelsActionButtonTag = 921342;
static const void *kSPKReelsMoreLongPressAssocKey = &kSPKReelsMoreLongPressAssocKey;
static const void *kSPKReelsSpeedLabelAssocKey = &kSPKReelsSpeedLabelAssocKey;

// Set while Sparkle drives the cell, so the hooks below can tell its own calls
// from Instagram's.
static BOOL sSPKReelsPlaybackApplyingSpeed = NO;
static BOOL sSPKReelsPlaybackTogglingPlayback = NO;

// Instagram's playback reason codes are an unexported enum that differs between
// versions. Reusing the codes Instagram itself last passed to the cell keeps a
// Sparkle pause/play indistinguishable from the app's own.
static long long sSPKReelsLastPauseReason = 0;
static long long sSPKReelsLastPlayReason = 0;
static const void *kSPKReelsPausedByPanelAssocKey = &kSPKReelsPausedByPanelAssocKey;

static BOOL SPKReelsPlaybackEnabled(void) {
    return SPKPlaybackControlsEnabled(SPKPlaybackSurfaceReels);
}

static id SPKReelsPlaybackSend(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static double SPKReelsPlaybackReadDouble(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return 0.0;
    @try {
        return ((double (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

static NSHashTable<UIView *> *SPKReelsPlaybackLiveUFIs(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// MARK: - Cell access

/// The reel cell that contains `view`, resolved by walking up from the UFI rather
/// than picking the centered cell, which drifts while the feed scrolls.
static UICollectionViewCell *SPKReelsPlaybackVideoCellForView(UIView *view) {
    Class videoCellClass = NSClassFromString(@"IGSundialViewerVideoCell");
    if (!videoCellClass)
        return nil;
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 25; depth++) {
        if ([current isKindOfClass:videoCellClass])
            return (UICollectionViewCell *)current;
        current = current.superview;
    }
    return nil;
}

static id SPKReelsPlaybackVideoView(UICollectionViewCell *cell) {
    id videoView = SPKReelsPlaybackSend(cell, @"videoView");
    return [videoView respondsToSelector:NSSelectorFromString(@"totalPlaybackTime")] ? videoView : nil;
}

static id SPKReelsPlaybackItem(UICollectionViewCell *cell) {
    if (!cell)
        return nil;
    return SPKSundialCellMedia(cell) ?: SPKReelsPlaybackSend(cell, @"video");
}

static BOOL SPKReelsPlaybackCellIsOnScreen(UICollectionViewCell *cell) {
    UIWindow *window = cell.window;
    if (!window || cell.hidden)
        return NO;
    CGRect frame = [cell convertRect:cell.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(frame);
    CGFloat midX = CGRectGetMidX(frame);
    return CGRectContainsPoint(window.bounds, CGPointMake(midX, midY));
}

static void SPKReelsPlaybackApplySpeed(UICollectionViewCell *cell, double speed) {
    SEL selector = NSSelectorFromString(@"setPlaybackSpeed:");
    if (![cell respondsToSelector:selector])
        return;
    sSPKReelsPlaybackApplyingSpeed = YES;
    @try {
        ((void (*)(id, SEL, float))objc_msgSend)(cell, selector, (float)speed);
    } @catch (__unused NSException *exception) {
    }
    sSPKReelsPlaybackApplyingSpeed = NO;
}

static BOOL SPKReelsPlaybackIsPlaying(UICollectionViewCell *cell) {
    SEL selector = @selector(isPlaying);
    if (![cell respondsToSelector:selector])
        return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(cell, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void SPKReelsPlaybackSendReason(UICollectionViewCell *cell, NSString *selectorName, long long reason) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![cell respondsToSelector:selector])
        return;
    sSPKReelsPlaybackTogglingPlayback = YES;
    @try {
        ((void (*)(id, SEL, long long))objc_msgSend)(cell, selector, reason);
    } @catch (__unused NSException *exception) {
    }
    sSPKReelsPlaybackTogglingPlayback = NO;
}

/// The cell's media gesture controller. IG 452 rewrote the cell in Swift and made
/// it a lazy var, so its storage ivar lost the plain `_gestureController` name.
static id SPKReelsPlaybackGestureController(UICollectionViewCell *cell) {
    return [SPKUtils getIvarForObj:cell name:"_gestureController"]
               ?: [SPKUtils getIvarForObj:cell name:"$__lazy_storage_$_gestureController"];
}

/// The cell's own single-tap recognizer, which Instagram's tap handler expects.
static UIGestureRecognizer *SPKReelsPlaybackSingleTapRecognizer(id gestureController) {
    // A Swift stored property on current versions, an Objective-C ivar on older ones.
    for (NSString *name in @[ @"singleTapRecognizer", @"_singleTapRecognizer" ]) {
        id recognizer = [SPKUtils getIvarForObj:gestureController name:name.UTF8String];
        if ([recognizer isKindOfClass:[UIGestureRecognizer class]])
            return recognizer;
    }
    return nil;
}

/// Toggles playback the way a tap on the reel does when Instagram's tap-to-pause
/// is on. Instagram then owns the pause: its paused overlay, indicator and resume
/// tap all stay in step with the panel. Returns NO when the tap does something
/// else on this version or account (such as muting), or the pieces are missing.
static BOOL SPKReelsPlaybackToggleThroughTap(UICollectionViewCell *cell) {
    id sectionController = SPKReelsPlaybackSend(cell, @"delegate");
    id configuration = SPKReelsPlaybackSend(sectionController, @"playbackControlsTestConfiguration")
                           ?: [SPKUtils getIvarForObj:sectionController name:"_playbackControlsTestConfiguration"];
    SEL tapToPauseEnabled = NSSelectorFromString(@"tapToPauseEnabled");
    if (![configuration respondsToSelector:tapToPauseEnabled] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(configuration, tapToPauseEnabled))
        return NO;

    id gestureController = SPKReelsPlaybackGestureController(cell);
    UIGestureRecognizer *recognizer = SPKReelsPlaybackSingleTapRecognizer(gestureController);
    SEL singleTap = @selector(gestureController:didObserveSingleTap:);
    if (!gestureController || !recognizer || ![cell respondsToSelector:singleTap])
        return NO;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cell, singleTap, gestureController, recognizer);
    } @catch (NSException *exception) {
        SPKLog(@"ReelsPlayback", @"Tap toggle failed: %@", exception);
        return NO;
    }
    return YES;
}

static SPKPlaybackTarget *SPKReelsPlaybackTargetForCell(UICollectionViewCell *cell) {
    __weak UICollectionViewCell *weakCell = cell;
    SPKPlaybackTarget *target = [SPKPlaybackTarget new];
    target.isAvailable = ^BOOL {
        UICollectionViewCell *strongCell = weakCell;
        return SPKReelsPlaybackEnabled() && SPKReelsPlaybackCellIsOnScreen(strongCell) && SPKReelsPlaybackVideoView(strongCell) != nil;
    };
    target.currentTime = ^double {
        return SPKReelsPlaybackReadDouble(SPKReelsPlaybackVideoView(weakCell), @"currentPlaybackTime");
    };
    target.duration = ^double {
        return SPKReelsPlaybackReadDouble(SPKReelsPlaybackVideoView(weakCell), @"totalPlaybackTime");
    };
    target.isPlaying = ^BOOL {
        return SPKReelsPlaybackIsPlaying(weakCell);
    };
    target.seek = ^(double time, void (^completion)(void)) {
        UICollectionViewCell *strongCell = weakCell;
        SEL cellSeek = NSSelectorFromString(@"seekToTime:preciseTime:trigger:isSeekingOnTap:completionHandler:");
        SEL viewSeek = NSSelectorFromString(@"seekToTime:preciseTime:trigger:completionHandler:");
        // The handler's arguments differ between versions and are not needed.
        id handler = ^{
            completion();
        };
        @try {
            if ([strongCell respondsToSelector:cellSeek]) {
                ((void (*)(id, SEL, double, BOOL, long long, BOOL, id))objc_msgSend)(strongCell, cellSeek, time, YES, 0, NO, handler);
                return;
            }
            id videoView = SPKReelsPlaybackVideoView(strongCell);
            if ([videoView respondsToSelector:viewSeek]) {
                ((void (*)(id, SEL, double, BOOL, long long, id))objc_msgSend)(videoView, viewSeek, time, YES, 0, handler);
                return;
            }
        } @catch (__unused NSException *exception) {
        }
        completion();
    };
    target.togglePlayback = ^{
        UICollectionViewCell *strongCell = weakCell;
        BOOL pausing = SPKReelsPlaybackIsPlaying(strongCell);
        if (!objc_getAssociatedObject(strongCell, kSPKReelsPausedByPanelAssocKey) && SPKReelsPlaybackToggleThroughTap(strongCell))
            return;
        if (pausing)
            SPKReelsPlaybackSendReason(strongCell, @"pauseWithReason:", sSPKReelsLastPauseReason);
        else
            SPKReelsPlaybackSendReason(strongCell, @"playWithReason:", sSPKReelsLastPlayReason);
        // Instagram's own tap handler doesn't recognise a pause it didn't start,
        // so remember it and let the next tap on the reel resume.
        objc_setAssociatedObject(strongCell, kSPKReelsPausedByPanelAssocKey, pausing ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    target.resumeAfterSeek = ^{
        UICollectionViewCell *strongCell = weakCell;
        // A pause the panel holds is intentional; only a stalled player is restarted.
        if (objc_getAssociatedObject(strongCell, kSPKReelsPausedByPanelAssocKey))
            return;
        SPKLog(@"ReelsPlayback", @"Restarting playback stalled after seek");
        SPKReelsPlaybackSendReason(strongCell, @"playWithReason:", sSPKReelsLastPlayReason);
    };
    target.speedItem = ^id {
        return SPKReelsPlaybackItem(weakCell);
    };
    target.applySpeed = ^(double speed) {
        SPKReelsPlaybackApplySpeed(weakCell, speed);
    };
    return target;
}

/// The speed to pass on for a speed Instagram sets on `view` (the reel cell or its
/// video view). Instagram resets reels to 1x after its hold-for-2x gesture, on
/// reuse and when a reel starts; those resets keep the chosen speed instead, while
/// its own 2x passes through untouched.
static float SPKReelsPlaybackIncomingSpeed(UIView *view, float speed) {
    if (sSPKReelsPlaybackApplyingSpeed || !SPKPlaybackSpeedIsNormal(speed) || !SPKReelsPlaybackEnabled())
        return speed;
    UICollectionViewCell *cell = SPKReelsPlaybackVideoCellForView(view);
    if (!cell)
        return speed;
    double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem(cell));
    if (SPKPlaybackSpeedIsNormal(wanted))
        return speed;
    SPKLog(@"ReelsPlayback", @"Kept %.2fx over a 1x reset on %@", wanted, NSStringFromClass(view.class));
    return (float)wanted;
}

static void SPKReelsPlaybackSyncSpeed(UICollectionViewCell *cell) {
    if (!SPKReelsPlaybackEnabled() || !cell)
        return;
    double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem(cell));
    // The cell reports its speed as a boxed number that can be nil before playback.
    id reported = SPKReelsPlaybackSend(cell, @"playbackSpeed");
    double current = [reported respondsToSelector:@selector(doubleValue)] ? [reported doubleValue] : 1.0;
    if (fabs(current - wanted) > 0.001)
        SPKReelsPlaybackApplySpeed(cell, wanted);
}

// MARK: - More button + badge

static UIView *SPKReelsSearchMoreButton(UIView *root, NSUInteger depth) {
    if (!root)
        return nil;
    if ([root.accessibilityIdentifier hasSuffix:kSPKReelsMoreButtonIdentifier])
        return root;
    if (depth >= 5)
        return nil;
    for (UIView *subview in root.subviews) {
        UIView *found = SPKReelsSearchMoreButton(subview, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

/// The reel's more button. It is a UIControl (not a UIButton) exposed by the
/// vertical UFI on every supported version; the identifier search is a fallback.
static UIView *SPKReelsFindMoreButton(UIView *verticalUFI) {
    id button = SPKReelsPlaybackSend(verticalUFI, @"moreOptionsButton");
    if ([button isKindOfClass:[UIView class]])
        return (UIView *)button;
    return SPKReelsSearchMoreButton(verticalUFI, 0);
}

@interface SPKReelsPlaybackGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
- (void)handleBadgeTap:(UIButton *)badge;
@end

static void SPKReelsPresentPanel(UIView *anchor, UIView *source) {
    UICollectionViewCell *cell = SPKReelsPlaybackVideoCellForView(anchor);
    if (!SPKReelsPlaybackEnabled() || !SPKReelsPlaybackVideoView(cell)) {
        SPKLog(@"ReelsPlayback", @"Panel unavailable: enabled=%d cell=%@ videoView=%@",
               SPKReelsPlaybackEnabled(), NSStringFromClass(cell.class),
               NSStringFromClass([SPKReelsPlaybackSend(cell, @"videoView") class]));
        return;
    }
    [[UISelectionFeedbackGenerator new] selectionChanged];
    SPKPlaybackPanelPresentFromSource(anchor, source, SPKPlaybackSurfaceReels, SPKReelsPlaybackTargetForCell(cell));
}

@implementation SPKReelsPlaybackGestureHandler

+ (instancetype)shared {
    static SPKReelsPlaybackGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [SPKReelsPlaybackGestureHandler new];
    });
    return handler;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    SPKReelsPresentPanel(recognizer.view, recognizer.view);
}

- (void)handleBadgeTap:(UIButton *)badge {
    // Grow out of the speed text, but tie the panel's lifetime to the more button:
    // the text disappears as soon as the speed returns to 1x, which would take the
    // panel down with it.
    UIView *moreButton = SPKReelsFindMoreButton(badge.superview);
    SPKReelsPresentPanel(moreButton.window ? moreButton : badge, badge);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return SPKReelsPlaybackEnabled();
}

// Win against Instagram's own recognizers on the button and the UFI column (such
// as its hold-for-2x gesture), so a long press opens the panel and nothing else.
// The feed's scroll pan is left alone so a swipe starting on the button still
// scrolls immediately.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return ![otherGestureRecognizer.view isKindOfClass:[UIScrollView class]];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}
@end

/// The speed text inside the indicator. It lives in an SPKChromeCanvas rather
/// than being the button's own title, so "Hide UI on Capture" redacts it.
static UILabel *SPKReelsSpeedIndicatorLabel(UIButton *indicator) {
    return objc_getAssociatedObject(indicator, kSPKReelsSpeedLabelAssocKey);
}

static UIButton *SPKReelsSpeedIndicator(UIView *verticalUFI) {
    UIView *existing = [verticalUFI viewWithTag:kSPKReelsSpeedBadgeTag];
    if ([existing isKindOfClass:[UIButton class]])
        return (UIButton *)existing;

    // The button stays the tap target; only the visible text is redacted.
    UIButton *indicator = [UIButton buttonWithType:UIButtonTypeCustom];
    indicator.tag = kSPKReelsSpeedBadgeTag;
    indicator.adjustsImageWhenHighlighted = NO;
    indicator.accessibilityLabel = SPKL(@"PLAYBACK_PANEL_OPEN_ACCESSIBILITY_LABEL");
    [indicator addTarget:[SPKReelsPlaybackGestureHandler shared]
                  action:@selector(handleBadgeTap:)
        forControlEvents:UIControlEventTouchUpInside];

    SPKChromeCanvas *canvas = [[SPKChromeCanvas alloc] init];
    canvas.userInteractionEnabled = NO;
    [indicator addSubview:canvas];

    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:16.0 weight:UIFontWeightBold];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    // Matches the shadow Instagram puts under the UFI glyphs over bright video.
    label.layer.shadowColor = UIColor.blackColor.CGColor;
    label.layer.shadowOpacity = 0.24;
    label.layer.shadowRadius = 1.8;
    label.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    label.layer.masksToBounds = NO;
    [canvas.contentContainer addSubview:label];

    // Pinned to the canvas itself, never to contentContainer: the canvas
    // re-parents its children once the secure layer materialises.
    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:indicator.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:indicator.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:indicator.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:indicator.bottomAnchor],
        [label.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:canvas.centerYAnchor],
    ]];
    objc_setAssociatedObject(indicator, kSPKReelsSpeedLabelAssocKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [verticalUFI addSubview:indicator];
    return indicator;
}

/// The Reels UFI glyph tint, which Instagram lifts into extended range on HDR reels.
static UIColor *SPKReelsNativeUFITint(UIView *verticalUFI) {
    id likeButton = SPKReelsPlaybackSend(verticalUFI, @"ufiLikeButton");
    if (![likeButton isKindOfClass:[UIButton class]])
        return UIColor.whiteColor;
    UIButton *like = (UIButton *)likeButton;
    return like.imageView.tintColor ?: like.tintColor ?: UIColor.whiteColor;
}

/// Copies the action button's glyph shadow, which itself mirrors the UFI's, so
/// the speed text and the button read as one column.
static void SPKReelsMirrorShadow(CALayer *source, CALayer *target) {
    if (!source || !target || !source.shadowColor)
        return;
    if (target.shadowOpacity != source.shadowOpacity)
        target.shadowOpacity = source.shadowOpacity;
    if (target.shadowRadius != source.shadowRadius)
        target.shadowRadius = source.shadowRadius;
    if (!CGSizeEqualToSize(target.shadowOffset, source.shadowOffset))
        target.shadowOffset = source.shadowOffset;
    if (!CGColorEqualToColor(target.shadowColor, source.shadowColor))
        target.shadowColor = source.shadowColor;
}

/// The topmost element of the action column the indicator sits above: Sparkle's
/// action button when it is shown, otherwise Instagram's like button.
static UIView *SPKReelsIndicatorAnchor(UIView *verticalUFI) {
    // The action button is hosted outside the UFI, in an ancestor a few levels
    // up (beside the overlay's Metal layer view), so search the ancestors'
    // direct children rather than only the UFI's siblings.
    UIView *actionButton = nil;
    UIView *ancestor = verticalUFI.superview;
    for (NSInteger depth = 0; ancestor && !actionButton && depth < 5; depth++) {
        for (UIView *subview in ancestor.subviews) {
            if (subview.tag == kSPKReelsActionButtonTag) {
                actionButton = subview;
                break;
            }
        }
        ancestor = ancestor.superview;
    }
    // Alpha is deliberately ignored: the button follows the UFI's fades, and a
    // layout pass at the start of a fade-in would otherwise anchor to the like
    // button and overlap the action button until the next pass.
    if (actionButton && !actionButton.hidden)
        return actionButton;
    id likeButton = SPKReelsPlaybackSend(verticalUFI, @"ufiLikeButton");
    return [likeButton isKindOfClass:[UIView class]] ? (UIView *)likeButton : nil;
}

/// Plain speed text over the action column, tinted and EDR-composited like the
/// column's glyphs.
static void SPKReelsUpdateSpeedBadge(UIView *verticalUFI, UIView *moreButton) {
    UICollectionViewCell *cell = SPKReelsPlaybackVideoCellForView(verticalUFI);
    double speed = cell ? SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem(cell)) : 1.0;
    UIView *existing = [verticalUFI viewWithTag:kSPKReelsSpeedBadgeTag];
    UIView *anchor = SPKReelsIndicatorAnchor(verticalUFI);
    if (!SPKReelsPlaybackEnabled() || !cell || !anchor || SPKPlaybackSpeedIsNormal(speed)) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *indicator = SPKReelsSpeedIndicator(verticalUFI);
    UILabel *textLabel = SPKReelsSpeedIndicatorLabel(indicator);
    NSString *label = SPKPlaybackSpeedLabel(speed);
    if (![textLabel.text isEqualToString:label]) {
        [UIView performWithoutAnimation:^{
            textLabel.text = label;
            [indicator layoutIfNeeded];
        }];
    }
    indicator.accessibilityValue = label;

    textLabel.textColor = SPKReelsNativeUFITint(verticalUFI);
    if ([anchor isKindOfClass:[SPKChromeButton class]])
        SPKReelsMirrorShadow(((SPKChromeButton *)anchor).iconView.layer, textLabel.layer);
    SPKChromeEnableExtendedDynamicRangeContent(indicator);
    SPKChromeEnableExtendedDynamicRangeContent(textLabel);
    // The UFI rasterizes. With an EDR sublayer but no EDR on the UFI layer
    // itself, its cache clamps Instagram's HDR glyphs until something redraws it.
    SPKChromeEnableExtendedDynamicRangeContent(verticalUFI);

    CGSize size = [textLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 28.0)];
    size.width = MAX(size.width, 44.0);
    size.height = 28.0;
    CGRect anchorFrame = [anchor convertRect:anchor.bounds toView:verticalUFI];
    CGRect frame = CGRectMake(round(CGRectGetMidX(anchorFrame) - size.width / 2.0),
                              CGRectGetMinY(anchorFrame) - size.height - 2.0,
                              size.width,
                              size.height);
    if (!CGRectEqualToRect(indicator.frame, frame))
        indicator.frame = frame;
    indicator.alpha = moreButton ? moreButton.alpha : 1.0;
    [verticalUFI bringSubviewToFront:indicator];
    if (moreButton)
        SPKPlaybackPanelAdoptSource(moreButton, indicator);
}

static void SPKReelsInstallPlaybackControls(UIView *verticalUFI) {
    if (!verticalUFI)
        return;

    [SPKReelsPlaybackLiveUFIs() addObject:verticalUFI];
    UIView *moreButton = SPKReelsFindMoreButton(verticalUFI);
    if (!moreButton && SPKReelsPlaybackEnabled())
        SPKLog(@"ReelsPlayback", @"No more button in %@", NSStringFromClass(verticalUFI.class));
    if (moreButton && !objc_getAssociatedObject(moreButton, kSPKReelsMoreLongPressAssocKey)) {
        SPKReelsPlaybackGestureHandler *handler = [SPKReelsPlaybackGestureHandler shared];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                                 action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.4;
        longPress.delegate = handler;
        [moreButton addGestureRecognizer:longPress];
        objc_setAssociatedObject(moreButton, kSPKReelsMoreLongPressAssocKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    verticalUFI.clipsToBounds = NO;
    SPKReelsUpdateSpeedBadge(verticalUFI, moreButton);
}

static void SPKReelsRefreshAllPlaybackControls(void) {
    for (UIView *verticalUFI in SPKReelsPlaybackLiveUFIs().allObjects) {
        SPKReelsInstallPlaybackControls(verticalUFI);
        SPKReelsPlaybackSyncSpeed(SPKReelsPlaybackVideoCellForView(verticalUFI));
    }
}

// MARK: - Hooks

%group SPKReelsPlaybackControlsUFIHooks

%hook IGSundialViewerVerticalUFI
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ReelsPlaybackControls.layoutSubviews");
    SPKReelsInstallPlaybackControls((UIView *)self);
}
%end

%end

// The speed and play choke points sit on the reel's video view. Every speed and
// play the cell forwards reaches it through an Objective-C protocol, but since
// IG 452 rewrote the cell in Swift, Instagram's own calls into the cell no longer
// pass through the cell's Objective-C methods. One group per video view class.
%group SPKReelsPlaybackVideoViewHooks
%hook SPKReelsPlaybackVideoViewClass
- (void)setPlaybackSpeed:(float)speed {
    %orig(SPKReelsPlaybackIncomingSpeed((UIView *)self, speed));
}

- (void)playWithReason:(long long)reason {
    %orig(reason);
    if (SPKReelsPlaybackEnabled())
        SPKReelsPlaybackSyncSpeed(SPKReelsPlaybackVideoCellForView((UIView *)self));
}
%end
%end

%group SPKReelsPlaybackModernVideoViewHooks
%hook SPKReelsPlaybackModernVideoViewClass
- (void)setPlaybackSpeed:(float)speed {
    %orig(SPKReelsPlaybackIncomingSpeed((UIView *)self, speed));
}

- (void)playWithReason:(long long)reason {
    %orig(reason);
    if (SPKReelsPlaybackEnabled())
        SPKReelsPlaybackSyncSpeed(SPKReelsPlaybackVideoCellForView((UIView *)self));
}
%end
%end

// Fallback when neither video view class resolves.
%group SPKReelsPlaybackCellSpeedHooks
%hook IGSundialViewerVideoCell
- (void)setPlaybackSpeed:(float)speed {
    %orig(SPKReelsPlaybackIncomingSpeed((UIView *)self, speed));
}
%end
%end

%group SPKReelsPlaybackControlsHooks

%hook IGSundialViewerVideoCell
- (void)gestureController:(id)controller didObserveSingleTap:(id)tap {
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if ([objc_getAssociatedObject(cell, kSPKReelsPausedByPanelAssocKey) boolValue]) {
        objc_setAssociatedObject(cell, kSPKReelsPausedByPanelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!SPKReelsPlaybackIsPlaying(cell)) {
            SPKReelsPlaybackSendReason(cell, @"playWithReason:", sSPKReelsLastPlayReason);
            return;
        }
    }
    %orig(controller, tap);
}

- (void)playWithReason:(long long)reason {
    if (!sSPKReelsPlaybackTogglingPlayback) {
        sSPKReelsLastPlayReason = reason;
        objc_setAssociatedObject(self, kSPKReelsPausedByPanelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(reason);
    SPKReelsPlaybackSyncSpeed((UICollectionViewCell *)self);
}

- (void)pauseWithReason:(long long)reason {
    if (!sSPKReelsPlaybackTogglingPlayback)
        sSPKReelsLastPauseReason = reason;
    %orig(reason);
}
%end

%hook IGSundialFeedViewController
- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    SPKPlaybackPanelDismiss(NO);
    if (SPKPlaybackSpeedCurrentScope(SPKPlaybackSurfaceReels) != SPKPlaybackSpeedScopeAlways)
        SPKPlaybackSpeedEndSession(SPKPlaybackSurfaceReels);
}
%end

%end

extern "C" void SPKInstallReelsPlaybackControlsHooksIfEnabled(void) {
    // IG 436+ registers the Reels UFI under a Swift-mangled name; bail without
    // burning the once token so a later surface pass can retry.
    Class ufiClass = SPKReelsVerticalUFIClass();
    if (!ufiClass)
        return;

    // Installed regardless of the preference so it can be toggled while Reels is
    // open; every hook re-checks the preference at call time.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKPlaybackSpeedDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
                                                          if ([notification.object integerValue] == SPKPlaybackSurfaceReels)
                                                              SPKReelsRefreshAllPlaybackControls();
                                                      }];
        %init(SPKReelsPlaybackControlsUFIHooks, IGSundialViewerVerticalUFI = ufiClass);
        if (!NSClassFromString(@"IGSundialViewerVideoCell"))
            return;
        %init(SPKReelsPlaybackControlsHooks);

        Class videoViewClass = SPKResolveIGClass(@"IGSundialCommonUIVideoPlayback.IGSundialVideoPlaybackView",
                                                 @"IGSundialVideoPlaybackView");
        Class modernVideoViewClass = SPKResolveIGClass(@"IGSundialCommonUIVideoPlayback.IGSundialModernVideoPlaybackView",
                                                       @"IGSundialModernVideoPlaybackView");
        if (videoViewClass) {
            %init(SPKReelsPlaybackVideoViewHooks, SPKReelsPlaybackVideoViewClass = videoViewClass);
        }
        if (modernVideoViewClass) {
            %init(SPKReelsPlaybackModernVideoViewHooks, SPKReelsPlaybackModernVideoViewClass = modernVideoViewClass);
        }
        if (!videoViewClass && !modernVideoViewClass) {
            %init(SPKReelsPlaybackCellSpeedHooks);
        }
    });
}
