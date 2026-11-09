#import <objc/message.h>
#import <objc/runtime.h>

#import "../../App/SPKPerfMeter.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/Playback/SPKPlaybackPanel.h"
#import "../../Shared/Stories/SPKStoryButtonPlacement.h"
#import "../../Shared/Stories/SPKStoryDynamicRange.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

static NSInteger const kSPKStoryPlaybackButtonTag = 926011;
// The Story Audio Button's tag; the playback button sits beside it when shown.
static NSInteger const kSPKStoryAudioButtonTag = 926004;
static CGFloat const kSPKStoryPlaybackButtonSize = 44.0;
static CGFloat const kSPKStoryPlaybackButtonSpacing = 4.0;
static const void *kSPKStoryPlaybackSpeedLabelAssocKey = &kSPKStoryPlaybackSpeedLabelAssocKey;
static const void *kSPKStoryPlaybackFooterObserverAssocKey = &kSPKStoryPlaybackFooterObserverAssocKey;
static const void *kSPKStoryPlaybackPressPausedAssocKey = &kSPKStoryPlaybackPressPausedAssocKey;

// Set while Sparkle itself changes a player's speed, so the setter hook can tell
// its own writes from Instagram resetting the speed to 1x.
static BOOL sSPKStoryPlaybackApplyingSpeed = NO;

static BOOL SPKStoryPlaybackEnabled(void) {
    return SPKPlaybackControlsEnabled(SPKPlaybackSurfaceStories);
}

static id SPKStoryPlaybackSend(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSHashTable<UIView *> *SPKStoryPlaybackLiveOverlays(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// MARK: - Player access

/// Story video views (IGStoryVideoView, and IGStoryModernVideoView on older
/// Instagram) share one playback surface; photo views have a speed setter but no
/// clock, so the clock selectors are what identify a video.
static BOOL SPKStoryPlaybackIsVideoView(id view) {
    return [view isKindOfClass:[UIView class]] &&
           [view respondsToSelector:@selector(currentTime)] &&
           [view respondsToSelector:@selector(duration)] &&
           [view respondsToSelector:@selector(seekToTime:)] &&
           [view respondsToSelector:NSSelectorFromString(@"setPlaybackSpeed:")];
}

static UIView *SPKStoryPlaybackFindVideoView(UIView *root, NSUInteger depth) {
    if (!root)
        return nil;
    if (SPKStoryPlaybackIsVideoView(root))
        return root;
    if (depth >= 3)
        return nil;
    for (UIView *subview in root.subviews) {
        UIView *found = SPKStoryPlaybackFindVideoView(subview, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

static UIView *SPKStoryPlaybackVideoViewForOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    id mediaView = [SPKUtils getIvarForObj:overlayView name:"_mediaView"];
    if (![mediaView isKindOfClass:[UIView class]]) {
        id sectionController = SPKStoryPlaybackSend(overlayView, @"mediaOverlayDelegate");
        mediaView = SPKStoryPlaybackSend(sectionController, @"mediaView");
    }
    return [mediaView isKindOfClass:[UIView class]] ? SPKStoryPlaybackFindVideoView(mediaView, 0) : nil;
}

static id SPKStoryPlaybackItem(UIView *videoView) {
    return SPKStoryPlaybackSend(videoView, @"item");
}

static double SPKStoryPlaybackReadDouble(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector])
        return 0.0;
    @try {
        return ((double (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

static BOOL SPKStoryPlaybackIsPlaying(UIView *videoView) {
    SEL selector = @selector(isPlaying);
    if (![videoView respondsToSelector:selector])
        return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(videoView, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL SPKStoryPlaybackReachedEnd(UIView *videoView) {
    double duration = SPKStoryPlaybackReadDouble(videoView, @selector(duration));
    double current = SPKStoryPlaybackReadDouble(videoView, @selector(currentTime));
    // Players can still report playing for a beat after the last frame.
    return duration > 0.0 && current >= duration - 0.15;
}

static void SPKStoryPlaybackApplySpeed(UIView *videoView, double speed) {
    SEL selector = NSSelectorFromString(@"setPlaybackSpeed:");
    if (![videoView respondsToSelector:selector])
        return;
    sSPKStoryPlaybackApplyingSpeed = YES;
    @try {
        ((void (*)(id, SEL, double))objc_msgSend)(videoView, selector, speed);
    } @catch (__unused NSException *exception) {
    }
    sSPKStoryPlaybackApplyingSpeed = NO;
}

static void SPKStoryPlaybackSyncSpeed(UIView *videoView) {
    if (!SPKStoryPlaybackEnabled() || !SPKStoryPlaybackIsVideoView(videoView))
        return;
    double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceStories, SPKStoryPlaybackItem(videoView));
    double current = SPKStoryPlaybackReadDouble(videoView, NSSelectorFromString(@"playbackSpeed"));
    if (current <= 0.0 || fabs(current - wanted) > 0.001)
        SPKStoryPlaybackApplySpeed(videoView, wanted);
}

static id SPKStoryPlaybackSectionContext(UIView *overlayView) {
    return SPKStoryPlaybackSend(overlayView, @"currentSectionContext") ?: SPKStoryPlaybackSend(overlayView, @"sectionContext");
}

/// Instagram's story gesture executor, the class that turns a press on the story
/// into a pause and its release into a resume. Newer versions pick it per section
/// (ads use their own); older ones have a single executor class.
static Class SPKStoryPlaybackGestureExecutor(id sectionContext) {
    id executor = SPKStoryPlaybackSend(sectionContext, @"gestureExecutor");
    if (executor && object_isClass(executor))
        return (Class)executor;
    return SPKResolveIGClass(@"IGStoryGestureHandlerExecutor.IGStoryGestureHandlerExecutor", nil);
}

/// Pauses or resumes a story through the same executor calls a finger press
/// makes, so the progress bar, auto-advance timer and player all stay in step.
/// The viewer's own pause toggle is an empty stub on current versions.
static BOOL SPKStoryPlaybackSetPressedPause(UIView *overlayView, BOOL paused) {
    id sectionContext = SPKStoryPlaybackSectionContext(overlayView);
    Class executor = SPKStoryPlaybackGestureExecutor(sectionContext);
    if (!sectionContext || !executor)
        return NO;

    // Pausing goes through the long-press path, which on some Instagram builds
    // also fades the story chrome. The overlay hooks keep it visible while set.
    objc_setAssociatedObject(overlayView, kSPKStoryPlaybackPressPausedAssocKey, paused ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        if (paused) {
            SEL selector = NSSelectorFromString(@"performBeginPressing:region:gesture:tapPoint:");
            if (![executor respondsToSelector:selector])
                return NO;
            // The executor expects a live recognizer; a detached one satisfies it
            // without claiming any touch.
            UILongPressGestureRecognizer *gesture = [UILongPressGestureRecognizer new];
            CGPoint center = CGPointMake(CGRectGetMidX(overlayView.bounds), CGRectGetMidY(overlayView.bounds));
            ((void (*)(id, SEL, id, long long, id, CGPoint))objc_msgSend)(executor, selector, sectionContext, 0, gesture, center);
        } else {
            SEL selector = NSSelectorFromString(@"performDidEndPressing:");
            if (![executor respondsToSelector:selector])
                return NO;
            ((void (*)(id, SEL, id))objc_msgSend)(executor, selector, sectionContext);
        }
    } @catch (NSException *exception) {
        SPKLog(@"StoryPlayback", @"Executor %@ failed: %@", paused ? @"pause" : @"resume", exception);
        return NO;
    }
    return YES;
}

/// True while the panel holds the story paused. A pause released some other way
/// (a tap on the story, a story change) leaves the video playing, which clears it.
static BOOL SPKStoryPlaybackPressPauseActive(UIView *overlayView) {
    if (!objc_getAssociatedObject(overlayView, kSPKStoryPlaybackPressPausedAssocKey))
        return NO;
    UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlayView);
    if (videoView && SPKStoryPlaybackIsPlaying(videoView)) {
        objc_setAssociatedObject(overlayView, kSPKStoryPlaybackPressPausedAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    return YES;
}

static void SPKStoryPlaybackWaitForSeek(UIView *videoView, double time, NSUInteger attempt, void (^completion)(void)) {
    __weak UIView *weakVideoView = videoView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongVideoView = weakVideoView;
        double current = SPKStoryPlaybackReadDouble(strongVideoView, @selector(currentTime));
        if (!strongVideoView || fabs(current - time) < 0.5 || attempt >= 15) {
            completion();
            return;
        }
        SPKStoryPlaybackWaitForSeek(strongVideoView, time, attempt + 1, completion);
    });
}

static SPKPlaybackTarget *SPKStoryPlaybackTargetForOverlay(UIView *overlayView) {
    __weak UIView *weakOverlay = overlayView;
    SPKPlaybackTarget *target = [SPKPlaybackTarget new];
    target.isAvailable = ^BOOL {
        UIView *overlay = weakOverlay;
        return overlay.window && SPKStoryPlaybackEnabled() && SPKStoryPlaybackVideoViewForOverlay(overlay) != nil;
    };
    target.currentTime = ^double {
        return SPKStoryPlaybackReadDouble(SPKStoryPlaybackVideoViewForOverlay(weakOverlay), @selector(currentTime));
    };
    target.duration = ^double {
        return SPKStoryPlaybackReadDouble(SPKStoryPlaybackVideoViewForOverlay(weakOverlay), @selector(duration));
    };
    target.isPlaying = ^BOOL {
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(weakOverlay);
        return SPKStoryPlaybackIsPlaying(videoView) && !SPKStoryPlaybackReachedEnd(videoView);
    };
    target.seek = ^(double time, void (^completion)(void)) {
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(weakOverlay);
        SEL precise = @selector(seekToTime:shouldUsePreciseTime:trigger:);
        @try {
            if ([videoView respondsToSelector:precise]) {
                ((void (*)(id, SEL, double, BOOL, long long))objc_msgSend)(videoView, precise, time, YES, 0);
            } else if ([videoView respondsToSelector:@selector(seekToTime:)]) {
                ((void (*)(id, SEL, double))objc_msgSend)(videoView, @selector(seekToTime:), time);
            }
        } @catch (__unused NSException *exception) {
        }
        // The story view offers no seek callback, so watch the clock reach the target.
        SPKStoryPlaybackWaitForSeek(videoView, time, 0, completion);
    };
    target.togglePlayback = ^{
        UIView *overlay = weakOverlay;
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlay);
        if (SPKStoryPlaybackReachedEnd(videoView)) {
            // A finished story (auto-advance off) replays from the start.
            SPKStoryPlaybackSetPressedPause(overlay, NO);
            @try {
                if ([videoView respondsToSelector:@selector(seekToBeginning)])
                    ((void (*)(id, SEL))objc_msgSend)(videoView, @selector(seekToBeginning));
                if ([videoView respondsToSelector:@selector(play)])
                    ((void (*)(id, SEL))objc_msgSend)(videoView, @selector(play));
            } @catch (__unused NSException *exception) {
            }
            return;
        }
        BOOL playing = SPKStoryPlaybackIsPlaying(videoView);
        if (!SPKStoryPlaybackSetPressedPause(overlay, playing))
            SPKLog(@"StoryPlayback", @"No gesture executor for %@", NSStringFromClass([SPKStoryPlaybackSectionContext(overlay) class]));
    };
    target.resumeAfterSeek = ^{
        UIView *overlay = weakOverlay;
        // A pause the panel holds is intentional; only a stalled player is restarted.
        if (objc_getAssociatedObject(overlay, kSPKStoryPlaybackPressPausedAssocKey))
            return;
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlay);
        if (SPKStoryPlaybackReachedEnd(videoView) || ![videoView respondsToSelector:@selector(play)])
            return;
        SPKLog(@"StoryPlayback", @"Restarting playback stalled after seek");
        @try {
            ((void (*)(id, SEL))objc_msgSend)(videoView, @selector(play));
        } @catch (__unused NSException *exception) {
        }
    };
    target.speedItem = ^id {
        return SPKStoryPlaybackItem(SPKStoryPlaybackVideoViewForOverlay(weakOverlay));
    };
    target.applySpeed = ^(double speed) {
        SPKStoryPlaybackApplySpeed(SPKStoryPlaybackVideoViewForOverlay(weakOverlay), speed);
    };
    return target;
}

// MARK: - Button

@interface SPKStoryPlaybackFooterObserver : NSObject
@property (nonatomic, weak) UIView *overlayView;
@property (nonatomic, weak) UIView *footerView;
@end

@implementation SPKStoryPlaybackFooterObserver
- (void)observeFooter:(UIView *)footerView {
    if (self.footerView == footerView)
        return;
    [self stopObserving];
    if (!footerView)
        return;
    self.footerView = footerView;
    [footerView addObserver:self forKeyPath:@"alpha" options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)stopObserving {
    UIView *footerView = self.footerView;
    if (!footerView)
        return;
    @try {
        [footerView removeObserver:self forKeyPath:@"alpha"];
    } @catch (__unused NSException *exception) {
    }
    self.footerView = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    UIView *button = [self.overlayView viewWithTag:kSPKStoryPlaybackButtonTag];
    if (button && [object isKindOfClass:[UIView class]])
        button.alpha = ((UIView *)object).alpha;
}

- (void)dealloc {
    [self stopObserving];
}
@end

static UIImage *SPKStoryPlaybackGlyph(void) {
    return [SPKAssetUtils resolvedImageNamed:@"playback"
                          fallbackSystemName:@"speedometer"
                                   pointSize:24.0
                                      weight:UIImageSymbolWeightRegular
                                      source:SPKResolvedImageSourceInstagramIcon
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

static void SPKStoryPlaybackUpdateButtonContent(SPKChromeButton *button, UIView *videoView) {
    double speed = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceStories, SPKStoryPlaybackItem(videoView));
    BOOL normal = SPKPlaybackSpeedIsNormal(speed);

    UILabel *label = objc_getAssociatedObject(button, kSPKStoryPlaybackSpeedLabelAssocKey);
    if (!label) {
        label = [UILabel new];
        // Sized to sit with the neighbouring 24pt glyphs; longer values like
        // "1.25×" shrink to fit the 44pt button.
        label.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.6;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [button addChromeSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:button.chromeAnchorView.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:button.chromeAnchorView.centerYAnchor],
            [label.widthAnchor constraintLessThanOrEqualToAnchor:button.chromeAnchorView.widthAnchor constant:-4.0],
        ]];
        objc_setAssociatedObject(button, kSPKStoryPlaybackSpeedLabelAssocKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!button.iconView.image)
        button.iconView.image = SPKStoryPlaybackGlyph();
    button.iconView.hidden = !normal;
    label.hidden = normal;
    label.text = normal ? nil : SPKPlaybackSpeedLabel(speed);
    // Same tint as the glyph, EDR-lifted on HDR stories; the label's layer has to
    // opt in too or the extended-range white clamps to SDR.
    label.textColor = button.iconTint ?: UIColor.whiteColor;
    SPKChromeEnableExtendedDynamicRangeContent(label);
    // Mirror the glyph's drop shadow so the text stays legible over bright
    // stories and matches the neighbouring controls.
    CALayer *glyphLayer = button.iconView.layer;
    label.layer.shadowColor = glyphLayer.shadowColor;
    label.layer.shadowOpacity = glyphLayer.shadowOpacity;
    label.layer.shadowRadius = glyphLayer.shadowRadius;
    label.layer.shadowOffset = glyphLayer.shadowOffset;
    label.layer.masksToBounds = NO;
    button.accessibilityValue = SPKPlaybackSpeedLabel(speed);
}

static void SPKStoryPlaybackRemoveButton(UIView *overlayView) {
    UIView *button = [overlayView viewWithTag:kSPKStoryPlaybackButtonTag];
    if (!button)
        return;
    if (SPKPlaybackPanelIsPresentedForAnchor(button))
        SPKPlaybackPanelDismiss(YES);
    [button removeFromSuperview];
}

static CGRect SPKStoryPlaybackButtonFrame(UIView *overlayView) {
    CGRect floatingFrame = SPKStoryFloatingButtonFrame(overlayView, kSPKStoryPlaybackButtonSize);
    if (CGRectIsEmpty(floatingFrame))
        return CGRectZero;

    CGFloat x = MAX(6.0, overlayView.safeAreaInsets.left + 6.0);
    UIView *audioButton = [overlayView viewWithTag:kSPKStoryAudioButtonTag];
    if (audioButton && !audioButton.hidden && audioButton.superview == overlayView)
        x = CGRectGetMaxX(audioButton.frame) + kSPKStoryPlaybackButtonSpacing;
    return CGRectMake(x, CGRectGetMinY(floatingFrame), kSPKStoryPlaybackButtonSize, kSPKStoryPlaybackButtonSize);
}

static void SPKStoryPlaybackInstallButton(UIView *overlayView) {
    if (!overlayView)
        return;

    [SPKStoryPlaybackLiveOverlays() addObject:overlayView];
    UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlayView);
    if (!SPKStoryPlaybackEnabled() || !videoView || SPKIsDirectVisualViewerAncestor(overlayView)) {
        SPKStoryPlaybackRemoveButton(overlayView);
        return;
    }

    CGRect frame = SPKStoryPlaybackButtonFrame(overlayView);
    if (CGRectIsEmpty(frame))
        return;

    SPKChromeButton *button = (SPKChromeButton *)[overlayView viewWithTag:kSPKStoryPlaybackButtonTag];
    if (![button isKindOfClass:[SPKChromeButton class]]) {
        [button removeFromSuperview];
        button = [[SPKChromeButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:kSPKStoryPlaybackButtonSize];
        button.tag = kSPKStoryPlaybackButtonTag;
        button.adjustsImageWhenHighlighted = YES;
        button.showsMenuAsPrimaryAction = NO;
        button.clipsToBounds = NO;
        button.iconView.image = SPKStoryPlaybackGlyph();
        [button addTarget:overlayView action:@selector(spk_storyPlaybackButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [overlayView addSubview:button];
    }

    button.accessibilityLabel = SPKL(@"PLAYBACK_PANEL_OPEN_ACCESSIBILITY_LABEL");
    button.translatesAutoresizingMaskIntoConstraints = YES;
    if (!CGRectEqualToRect(button.frame, frame))
        button.frame = frame;
    SPKApplyButtonStyle(button, SPKActionButtonSourceDirect);
    SPKStoryApplyDynamicRangeToButton(button);
    SPKStoryPlaybackUpdateButtonContent(button, videoView);
    [overlayView bringSubviewToFront:button];

    SPKStoryPlaybackFooterObserver *observer = objc_getAssociatedObject(overlayView, kSPKStoryPlaybackFooterObserverAssocKey);
    if (!observer) {
        observer = [SPKStoryPlaybackFooterObserver new];
        observer.overlayView = overlayView;
        objc_setAssociatedObject(overlayView, kSPKStoryPlaybackFooterObserverAssocKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *footer = [SPKUtils getIvarForObj:overlayView name:"_footerContainerView"];
    footer = [footer isKindOfClass:[UIView class]] ? footer : nil;
    [observer observeFooter:footer];
    button.alpha = footer ? footer.alpha : 1.0;
}

static void SPKStoryPlaybackRefreshAllOverlays(void) {
    for (UIView *overlayView in SPKStoryPlaybackLiveOverlays().allObjects) {
        SPKStoryPlaybackInstallButton(overlayView);
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlayView);
        if (videoView)
            SPKStoryPlaybackSyncSpeed(videoView);
    }
}

static void SPKStoryPlaybackRefreshSectionOverlay(id sectionController) {
    UIView *overlayView = SPKStoryPlaybackSend(sectionController, @"overlayView");
    if (![overlayView isKindOfClass:[UIView class]])
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKStoryPlaybackInstallButton(overlayView);
        UIView *videoView = SPKStoryPlaybackVideoViewForOverlay(overlayView);
        if (videoView)
            SPKStoryPlaybackSyncSpeed(videoView);
    });
}

// MARK: - Hooks

static void SPKStoryPlaybackFilterIncomingSpeed(id videoView, double *speed) {
    // Instagram drops the player back to 1x when its hold-to-fast-forward ends
    // and when it reconfigures a reused view. Keep the chosen speed instead;
    // any other speed (its own 2x fast-forward) passes through untouched.
    if (sSPKStoryPlaybackApplyingSpeed || !SPKPlaybackSpeedIsNormal(*speed) || !SPKStoryPlaybackEnabled())
        return;
    double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceStories, SPKStoryPlaybackItem(videoView));
    if (!SPKPlaybackSpeedIsNormal(wanted))
        *speed = wanted;
}

%group SPKStoryVideoViewSpeedHooks

%hook IGStoryVideoView
- (void)setPlaybackSpeed:(double)speed {
    SPKStoryPlaybackFilterIncomingSpeed(self, &speed);
    %orig(speed);
}

- (void)play {
    %orig;
    SPKStoryPlaybackSyncSpeed((UIView *)self);
}
%end

%end

// Older Instagram versions render some stories with a separate modern video view
// class that is not a subclass of IGStoryVideoView.
%group SPKStoryModernVideoViewSpeedHooks

%hook IGStoryModernVideoView
- (void)setPlaybackSpeed:(double)speed {
    SPKStoryPlaybackFilterIncomingSpeed(self, &speed);
    %orig(speed);
}

- (void)play {
    %orig;
    SPKStoryPlaybackSyncSpeed((UIView *)self);
}
%end

%end

%group SPKStoryPlaybackControlsHooks

%hook IGStoryFullscreenOverlayView
- (void)setChromeHidden:(BOOL)hidden {
    if (hidden && SPKStoryPlaybackPressPauseActive((UIView *)self)) {
        SPKLog(@"StoryPlayback", @"Kept chrome visible during panel pause");
        return;
    }
    %orig(hidden);
}

- (void)hideOverlaysExcludingSponsoredStory:(BOOL)excludingSponsoredStory {
    if (SPKStoryPlaybackPressPauseActive((UIView *)self)) {
        SPKLog(@"StoryPlayback", @"Kept overlays visible during panel pause");
        return;
    }
    %orig(excludingSponsoredStory);
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoryPlaybackControls.layoutSubviews");
    SPKStoryPlaybackInstallButton((UIView *)self);
}

%new - (void)spk_storyPlaybackButtonTapped:(UIButton *)sender {
    UIView *overlayView = (UIView *)self;
    if (!SPKStoryPlaybackEnabled() || !SPKStoryPlaybackVideoViewForOverlay(overlayView))
        return;

    if (SPKPlaybackPanelIsPresentedForAnchor(sender)) {
        SPKPlaybackPanelDismiss(YES);
        return;
    }
    [[UISelectionFeedbackGenerator new] selectionChanged];
    SPKPlaybackPanelPresent(sender, SPKPlaybackSurfaceStories, SPKStoryPlaybackTargetForOverlay(overlayView));
}
%end

%hook IGStoryFullscreenSectionController
- (void)didUpdateToObject:(id)object {
    %orig(object);
    SPKStoryPlaybackRefreshSectionOverlay(self);
}

- (void)didSelectItemAtIndex:(long long)index {
    %orig(index);
    SPKStoryPlaybackRefreshSectionOverlay(self);
}
%end

%hook IGStoryViewerViewController
- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    UIViewController *controller = (UIViewController *)self;
    UIViewController *container = controller.navigationController ?: controller.parentViewController;
    // Only a real close ends the session; covering the viewer with a sheet or
    // pushing a profile over it does not.
    if (controller.isBeingDismissed || controller.isMovingFromParentViewController ||
        container.isBeingDismissed || container.isMovingFromParentViewController) {
        SPKPlaybackPanelDismiss(NO);
        if (SPKPlaybackSpeedCurrentScope(SPKPlaybackSurfaceStories) != SPKPlaybackSpeedScopeAlways)
            SPKPlaybackSpeedEndSession(SPKPlaybackSurfaceStories);
    }
}
%end

%end

extern "C" void SPKInstallStoryPlaybackControlsHooksIfEnabled(void) {
    // Installed regardless of the preference: Stories preferences can be
    // account-scoped and toggled while a viewer is already on screen, and every
    // hook re-checks the preference at call time.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKPlaybackSpeedDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
                                                          if ([notification.object integerValue] == SPKPlaybackSurfaceStories)
                                                              SPKStoryPlaybackRefreshAllOverlays();
                                                      }];
        if (NSClassFromString(@"IGStoryVideoView")) {
            %init(SPKStoryVideoViewSpeedHooks);
        }
        if (NSClassFromString(@"IGStoryModernVideoView")) {
            %init(SPKStoryModernVideoViewSpeedHooks);
        }
        %init(SPKStoryPlaybackControlsHooks, IGStoryFullscreenSectionController = SPKStoryFullscreenSectionControllerClass());
    });
}
