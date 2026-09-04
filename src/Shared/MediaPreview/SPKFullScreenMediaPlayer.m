#import "SPKStrings.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#include <UIKit/UIKit.h>

#import "../../AssetUtils.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonCore.h"
#import "../ActionButton/SPKActionDescriptor.h"
#import "../ActionButton/SPKBulkMediaSelectionViewController.h"
#import "../Downloads/SPKDownloadHelpers.h"
#import "../Gallery/SPKGalleryCoreDataStack.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGalleryManager.h"
#import "../Gallery/SPKGalleryOriginController.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../MediaDownload/SPKMediaQualityManager.h"
#import "../MediaTrim/SPKTrimConfiguration.h"
#import "../MediaTrim/SPKTrimEditorViewController.h"
#import "../MediaTrim/SPKTrimResult.h"
#import "../MediaTrim/SPKTrimSaveCoordinator.h"
#import "../PhotoEdit/SPKPhotoEditEntry.h"
#import "../PhotoEdit/SPKPhotoEditorViewController.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKFullScreenImageViewController.h"
#import "SPKFullScreenMediaPlayer.h"
#import "SPKFullScreenVideoViewController.h"
#import "SPKMediaCacheManager.h"
#import "SPKMediaItem.h"
#import "SPKMediaPreviewInfoOverlay.h"

static CGFloat const kDismissAxisLockSlop = 20.0;
static CGFloat const kDismissDistanceRatio = 50.0 / 667.0;
static CGFloat const kDismissMaximumDuration = 0.45;
static CGFloat const kDismissReturnVelocityAnimationRatio = 0.00007;
static CGFloat const kDismissMinimumVelocity = 1.0;
static CGFloat const kDismissMinimumDuration = 0.12;
static CGFloat const kDismissFinalBackdropAlpha = 0.1;
static NSTimeInterval const kPresentationFadeDuration = 0.22;
static NSTimeInterval const kDismissFadeDuration = 0.18;

// Absolute medium-style date ("8 Jul 2026") for the preview metadata overlay.
static NSString *SPKPreviewMediumDateString(NSDate *date) {
    return [SPKUtils spk_formattedDate:date includingYear:YES];
}
static UIImage *SPKGalleryPreviewMenuIcon(NSString *resourceName) {
    // menuIconNamed: avoids the UIGraphicsImageRenderer downscale that iOS 16's
    // UIMenu renders blank for vector-backed (.svg) glyphs. See SPKAssetUtils.
    return [SPKAssetUtils menuIconNamed:(resourceName.length > 0 ? resourceName : @"more")];
}

static SPKActionButtonSource SPKActionButtonSourceForPlaybackSource(
    SPKFullScreenPlaybackSource playbackSource) {
    switch (playbackSource) {
    case SPKFullScreenPlaybackSourceFeed:
        return SPKActionButtonSourceFeed;
    case SPKFullScreenPlaybackSourceReels:
        return SPKActionButtonSourceReels;
    case SPKFullScreenPlaybackSourceStories:
        return SPKActionButtonSourceStories;
    case SPKFullScreenPlaybackSourceDirect:
        return SPKActionButtonSourceDirect;
    case SPKFullScreenPlaybackSourceProfile:
        return SPKActionButtonSourceProfile;
    case SPKFullScreenPlaybackSourceInstants:
        return SPKActionButtonSourceInstants;
    case SPKFullScreenPlaybackSourceUnknown:
    default:
        return SPKActionButtonSourceFeed;
    }
}

static SPKDownloadSourceSurface SPKDownloadSurfaceForPlaybackSource(
    SPKFullScreenPlaybackSource playbackSource) {
    return [SPKDownloadHelpers
        sourceSurfaceForActionButtonSource:SPKActionButtonSourceForPlaybackSource(
                                               playbackSource)];
}

static SPKGallerySource SPKGallerySourceForPlaybackSource(
    SPKFullScreenPlaybackSource playbackSource) {
    switch (playbackSource) {
    case SPKFullScreenPlaybackSourceFeed:
        return SPKGallerySourceFeed;
    case SPKFullScreenPlaybackSourceReels:
        return SPKGallerySourceReels;
    case SPKFullScreenPlaybackSourceStories:
        return SPKGallerySourceStories;
    case SPKFullScreenPlaybackSourceDirect:
        return SPKGallerySourceDMs;
    case SPKFullScreenPlaybackSourceProfile:
        return SPKGallerySourceProfile;
    case SPKFullScreenPlaybackSourceInstants:
        return SPKGallerySourceInstants;
    case SPKFullScreenPlaybackSourceUnknown:
    default:
        return SPKGallerySourceOther;
    }
}

static NSString *SPKCopiedDownloadURLTitleForPlaybackSource(
    SPKFullScreenPlaybackSource playbackSource, BOOL plural) {
    NSString *noun = nil;
    switch (playbackSource) {
    case SPKFullScreenPlaybackSourceStories:
        noun = SPKL(@"COMMON_MEDIA_TYPE_STORY");
        break;
    case SPKFullScreenPlaybackSourceReels:
        noun = SPKL(@"COMMON_MEDIA_TYPE_REEL");
        break;
    case SPKFullScreenPlaybackSourceFeed:
    case SPKFullScreenPlaybackSourceProfile:
        noun = SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_POST_TEXT");
        break;
    case SPKFullScreenPlaybackSourceDirect:
    case SPKFullScreenPlaybackSourceInstants:
    case SPKFullScreenPlaybackSourceUnknown:
    default:
        noun = nil;
        break;
    }

    NSString *urlWord = plural ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_URLS_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_URL_TEXT");
    return noun.length > 0
               ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_SOURCE_DOWNLOAD_URL_COPIED_FORMAT"), noun, urlWord]
               : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_DOWNLOAD_URL_COPIED_FORMAT"), urlWord];
}

static UIViewController *
SPKPreviewPresenterForContext(SPKFullScreenPlaybackSource playbackSource,
                              UIViewController *sourceController) {
    if ((playbackSource == SPKFullScreenPlaybackSourceStories ||
         playbackSource == SPKFullScreenPlaybackSourceDirect) &&
        sourceController.view.window) {
        return sourceController;
    }

    return topMostController();
}

static CGPoint SPKCenterForBounds(CGRect bounds) {
    return CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}

@interface SPKFullScreenMediaPlayer () <
    UIPageViewControllerDataSource, UIPageViewControllerDelegate,
    UIGestureRecognizerDelegate, UIViewControllerTransitioningDelegate,
    UIViewControllerAnimatedTransitioning,
    UIViewControllerInteractiveTransitioning, SPKFullScreenContentDelegate>

// Eager item list. Every entry point except the gallery hands us a small,
// already-built array (a carousel, a story tray, one file), so those keep using
// it directly.
@property (nonatomic, strong) NSArray<SPKMediaItem *> *items;
// Gallery browsing spans the whole current scope, which with flat browsing on is
// the entire gallery -- thousands of files. Building an SPKMediaItem per file up
// front cost a stat() and a full Core Data fault each, on the main thread, before
// the first page could even be shown. Hold the files instead and build items on
// demand around the visible page (-itemAtIndex:), so opening a photo is O(1).
@property (nonatomic, strong, nullable) NSArray<SPKGalleryFile *> *galleryFiles;
// index -> item, populated by -itemAtIndex: and trimmed with the controller cache.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, SPKMediaItem *> *lazyItems;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong)
    NSMutableDictionary<NSNumber *, UIViewController *> *controllerCache;

@property (nonatomic, strong) UIPageViewController *pageViewController;

@property (nonatomic, strong) UIBarButtonItem *topFavoriteItem;

@property (nonatomic, strong) UIBarButtonItem *savePhotosItem;
@property (nonatomic, strong) UIBarButtonItem *saveGalleryItem;
@property (nonatomic, strong) UIBarButtonItem *deleteGalleryItem;
@property (nonatomic, strong) UIBarButtonItem *shareItem;
@property (nonatomic, strong) UIBarButtonItem *clipboardItem;
@property (nonatomic, strong) UIBarButtonItem *downloadURLItem;
@property (nonatomic, strong) UIBarButtonItem *bulkActionsItem;
@property (nonatomic, strong) UIBarButtonItem *galleryOriginItem;
@property (nonatomic, strong) UIBarButtonItem *trimItem;
@property (nonatomic, strong) UIBarButtonItem *editItem;

- (void)syncItemFileURLToGalleryFile:(SPKMediaItem *)item;
@property (nonatomic, assign) BOOL bulkActionsItemVisible;
@property (nonatomic, assign) BOOL galleryOriginItemVisible;

@property (nonatomic, assign) BOOL isToolbarVisible;
@property (nonatomic, assign) BOOL isSingleItemMode;
// Bare local-file preview: no bottom action toolbar, no metadata/remote resolution.
@property (nonatomic, assign) BOOL previewOnly;

@property (nonatomic, assign) BOOL dismissPanDecided;
@property (nonatomic, assign) BOOL dismissPanIsVertical;
@property (nonatomic, weak) UIScrollView *pageScrollView;
@property (nonatomic, assign) BOOL interactiveDismissalInProgress;
@property (nonatomic, assign) CGPoint interactiveDismissAnchorPoint;
@property (nonatomic, strong, nullable) id<UIViewControllerContextTransitioning>
    interactiveDismissTransitionContext;
@property (nonatomic, assign) BOOL presentingTransition;

- (void)presentBulkSelectionForItems:(NSArray<SPKDownloadItemRequest *> *)bulkItems
                         identifiers:(NSArray<NSString *> *)identifiers
                       sourceSurface:(SPKDownloadSourceSurface)surface;

@property (nonatomic, assign) SPKFullScreenPlaybackSource playbackSource;
@property (nonatomic, weak, nullable) UIView *playbackSourceView;
@property (nonatomic, weak, nullable) UIViewController *playbackSourceController;
@property (nonatomic, copy, nullable)
    SPKMediaPreviewPlaybackBlock pausePlaybackBlock;
@property (nonatomic, copy, nullable)
    SPKMediaPreviewPlaybackBlock resumePlaybackBlock;
@property (nonatomic, assign) BOOL explicitPlaybackPauseActive;
/// Set when playback was paused for a screen pushed over this player, so returning resumes it.
@property (nonatomic, assign) BOOL pausedForNavigationAway;

/// Opaque black behind page content (letterboxing); alpha fades during
/// interactive dismiss.
@property (nonatomic, strong) UIView *presentationBackdropView;

/// Fixed insets (top/bottom bar heights) applied to media content on
/// non-notched devices so it sits between the bars. Captured only while the
/// chrome is visible so the value survives a chrome toggle.
@property (nonatomic, assign) UIEdgeInsets mediaContentBarInsets;

/// The content insets actually applied right now: the bar heights while the
/// chrome is visible, zero (full-screen) while it's hidden. Animated alongside
/// the bar fade in toggleToolbar so the media expands/contracts smoothly.
@property (nonatomic, assign) UIEdgeInsets currentContentInsets;

/// Suppresses safe-area-driven inset recomputation while a chrome toggle
/// animation is running (the toggle drives the insets explicitly).
@property (nonatomic, assign) BOOL chromeToggleInProgress;

/// Overlay showing author/date on the live media preview (photos only).
/// Non-interactive; its visibility tracks the chrome (fades with the bars on tap).
@property (nonatomic, strong, nullable) SPKMediaPreviewInfoOverlay *infoOverlay;
/// Bottom pin for the overlay, frozen to the toolbar-visible position so the overlay
/// fades in place rather than sliding as the chrome (and its safe-area inset) moves.
@property (nonatomic, strong, nullable) NSLayoutConstraint *infoOverlayBottomConstraint;
/// Live Text is highlighting recognized text on the visible photo. VisionKit draws
/// its "Copy All" quick action over the bottom of the image, from inside the page's
/// own view hierarchy, so it lands underneath the info overlay in the exact same
/// spot. Both cannot be readable at once; the info overlay yields.
@property (nonatomic, assign) BOOL liveTextHighlightActive;
/// Distance from the bottom of the player's view to the top of the action toolbar,
/// captured while the chrome is visible. Pages anchor their own floating controls to
/// it so they stay put when the chrome toggles instead of riding the safe area.
@property (nonatomic, assign) CGFloat chromeBottomLimit;
@property (nonatomic, assign) BOOL hasChromeBottomLimit;

@end

@implementation SPKFullScreenMediaPlayer

#pragma mark - Convenience Factories

+ (void)showFileURL:(NSURL *)fileURL {
    [self showFileURL:fileURL fromGallery:NO];
}

+ (void)showFileURL:(NSURL *)fileURL
           metadata:(SPKGallerySaveMetadata *)metadata {
    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:fileURL];
    item.isFromGallery = NO;
    item.galleryMetadata = metadata;

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.isFromGallery = NO;

    UIViewController *presenter = topMostController();
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

+ (void)showFileURL:(NSURL *)fileURL fromGallery:(BOOL)fromGallery {
    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:fileURL];
    item.isFromGallery = fromGallery;

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.isFromGallery = fromGallery;

    UIViewController *presenter = topMostController();
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

+ (void)showLocalFilePreview:(NSURL *)fileURL mediaType:(SPKMediaItemType)mediaType {
    // A read-only look at a local file (Files-import queue): just the media, close button,
    // and pinch/zoom. Pre-resolve the on-disk URL so the video path never falls through the cache
    // manager to its "Missing remote media URL" branch (there is no remote for an import preview).
    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:fileURL];
    // Trust the caller's type over the extension: Regram stores audio in .mp4, which would
    // otherwise play as a black video with no audio artwork overlay.
    item.mediaType = mediaType;
    item.resolvedFileURL = fileURL;
    item.isFromGallery = NO;

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.isFromGallery = NO;
    player.previewOnly = YES;

    UIViewController *presenter = topMostController();
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

+ (void)showGalleryFiles:(NSArray<SPKGalleryFile *> *)files
         startingAtIndex:(NSInteger)index
      fromViewController:(UIViewController *)presenter {
    if (files.count == 0)
        return;

    // No existence pre-pass here: it cost one stat() plus a fired Core Data fault
    // per file, on the main thread, which is what made opening a photo in a large
    // gallery take seconds. A file that went missing behind the gallery's back is
    // rare and its page already shows the load-failure state, so let the page that
    // actually gets displayed discover it.
    NSInteger adjustedIndex = MAX(0, MIN(index, (NSInteger)files.count - 1));
    SPKNotify(kSPKNotificationMediaPreviewOpenGallery, SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_OPENED_GALLERY_MEDIA_TEXT"),
              nil, @"media", SPKNotificationToneInfo);

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.isFromGallery = YES;
    [player playGalleryFiles:files
             startingAtIndex:adjustedIndex
          fromViewController:presenter];
}

+ (void)showPhotoURLs:(NSArray<NSURL *> *)urls initialIndex:(NSInteger)index {
    [self showPhotoURLs:urls initialIndex:index metadata:nil];
}

+ (void)showPhotoURLs:(NSArray<NSURL *> *)urls
         initialIndex:(NSInteger)index
             metadata:(SPKGallerySaveMetadata *)metadata {
    if (urls.count == 0)
        return;

    NSMutableArray<SPKMediaItem *> *items =
        [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        SPKMediaItem *item = [SPKMediaItem itemWithFileURL:url];
        item.galleryMetadata = metadata;
        [items addObject:item];
    }

    NSInteger adjustedIndex = MAX(0, MIN(index, (NSInteger)items.count - 1));

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    UIViewController *presenter = topMostController();
    [player playItems:items
           startingAtIndex:adjustedIndex
        fromViewController:presenter];
}

+ (void)showMediaItems:(NSArray<SPKMediaItem *> *)items
       startingAtIndex:(NSInteger)index
              metadata:(SPKGallerySaveMetadata *)metadata {
    [self showMediaItems:items
         startingAtIndex:index
                metadata:metadata
          playbackSource:SPKFullScreenPlaybackSourceUnknown
              sourceView:nil
              controller:nil
           pausePlayback:nil
          resumePlayback:nil];
}

+ (void)showMediaItems:(NSArray<SPKMediaItem *> *)items
       startingAtIndex:(NSInteger)index
              metadata:(SPKGallerySaveMetadata *)metadata
        playbackSource:(SPKFullScreenPlaybackSource)playbackSource
            sourceView:(UIView *)sourceView
            controller:(UIViewController *)controller
         pausePlayback:(SPKMediaPreviewPlaybackBlock)pausePlayback
        resumePlayback:(SPKMediaPreviewPlaybackBlock)resumePlayback {
    if (items.count == 0)
        return;

    if (metadata) {
        for (SPKMediaItem *item in items) {
            if (item && !item.galleryMetadata) {
                item.galleryMetadata = metadata;
            }
        }
    }

    NSInteger adjustedIndex = MAX(0, MIN(index, (NSInteger)items.count - 1));

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.isFromGallery = NO;
    [player configurePlaybackContextWithSource:playbackSource
                                    sourceView:sourceView
                                    controller:controller
                                 pausePlayback:pausePlayback
                                resumePlayback:resumePlayback];
    UIViewController *presenter =
        SPKPreviewPresenterForContext(playbackSource, controller);
    [player playItems:items
           startingAtIndex:adjustedIndex
        fromViewController:presenter];
}

+ (void)showImage:(UIImage *)image {
    [self showImage:image metadata:nil];
}

+ (void)showImage:(UIImage *)image metadata:(SPKGallerySaveMetadata *)metadata {
    [self showImage:image
              metadata:metadata
        playbackSource:SPKFullScreenPlaybackSourceUnknown
            sourceView:nil
            controller:nil
         pausePlayback:nil
        resumePlayback:nil];
}

+ (void)showImage:(UIImage *)image
          metadata:(SPKGallerySaveMetadata *)metadata
    playbackSource:(SPKFullScreenPlaybackSource)playbackSource
        sourceView:(UIView *)sourceView
        controller:(UIViewController *)controller
     pausePlayback:(SPKMediaPreviewPlaybackBlock)pausePlayback
    resumePlayback:(SPKMediaPreviewPlaybackBlock)resumePlayback {
    if (!image)
        return;
    SPKMediaItem *item = [SPKMediaItem itemWithImage:image];
    item.galleryMetadata = metadata;
    if (metadata.sourceUsername.length > 0) {
        item.title = metadata.sourceUsername;
    }
    item.gallerySaveSource = metadata ? (NSInteger)metadata.source : -1;

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    [player configurePlaybackContextWithSource:playbackSource
                                    sourceView:sourceView
                                    controller:controller
                                 pausePlayback:pausePlayback
                                resumePlayback:resumePlayback];
    UIViewController *presenter =
        SPKPreviewPresenterForContext(playbackSource, controller);
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

+ (void)showRemoteImageURL:(NSURL *)url {
    [self showRemoteImageURL:url metadata:nil];
}

+ (void)showRemoteImageURL:(NSURL *)url
                  metadata:(SPKGallerySaveMetadata *)metadata {
    [self showRemoteImageURL:url
                    metadata:metadata
              playbackSource:SPKFullScreenPlaybackSourceUnknown
                  sourceView:nil
                  controller:nil
               pausePlayback:nil
              resumePlayback:nil];
}

+ (void)showRemoteImageURL:(NSURL *)url
                  metadata:(SPKGallerySaveMetadata *)metadata
            playbackSource:(SPKFullScreenPlaybackSource)playbackSource
                sourceView:(UIView *)sourceView
                controller:(UIViewController *)controller
             pausePlayback:(SPKMediaPreviewPlaybackBlock)pausePlayback
            resumePlayback:(SPKMediaPreviewPlaybackBlock)resumePlayback {
    if (!url)
        return;

    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:url];
    item.galleryMetadata = metadata;
    if (metadata.sourceUsername.length > 0) {
        item.title = metadata.sourceUsername;
    }
    item.gallerySaveSource = metadata ? (NSInteger)metadata.source : -1;

    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    [player configurePlaybackContextWithSource:playbackSource
                                    sourceView:sourceView
                                    controller:controller
                                 pausePlayback:pausePlayback
                                resumePlayback:resumePlayback];
    UIViewController *presenter =
        SPKPreviewPresenterForContext(playbackSource, controller);
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

+ (void)showRemoteImageURL:(NSURL *)url profileUsername:(NSString *)username {
    if (!url)
        return;
    SPKGallerySaveMetadata *meta = [[SPKGallerySaveMetadata alloc] init];
    meta.source = (int16_t)SPKGallerySourceProfile;
    [SPKGalleryOriginController populateProfileMetadata:meta
                                               username:username
                                                   user:nil];
    [self showRemoteImageURL:url metadata:meta];
}

+ (void)showRemoteImageURLPreview:(NSURL *)url {
    if (!url)
        return;
    SPKMediaItem *item = [SPKMediaItem itemWithFileURL:url];
    SPKFullScreenMediaPlayer *player = [[SPKFullScreenMediaPlayer alloc] init];
    player.previewOnly = YES;
    UIViewController *presenter = topMostController();
    [player playItems:@[ item ] startingAtIndex:0 fromViewController:presenter];
}

#pragma mark - Playback Context

- (void)configurePlaybackContextWithSource:
            (SPKFullScreenPlaybackSource)playbackSource
                                sourceView:(UIView *)sourceView
                                controller:(UIViewController *)controller
                             pausePlayback:
                                 (SPKMediaPreviewPlaybackBlock)pausePlayback
                            resumePlayback:
                                (SPKMediaPreviewPlaybackBlock)resumePlayback {
    self.playbackSource = playbackSource;
    self.playbackSourceView = sourceView;
    self.playbackSourceController = controller;
    self.pausePlaybackBlock = pausePlayback;
    self.resumePlaybackBlock = resumePlayback;
    self.explicitPlaybackPauseActive = NO;
}

#pragma mark - Present

- (void)playItems:(NSArray<SPKMediaItem *> *)items
       startingAtIndex:(NSInteger)index
    fromViewController:(UIViewController *)presenter {
    _items = [items copy];
    [self prepareForPresentationAtIndex:index];
    [self presentFromViewController:presenter];
}

- (void)playGalleryFiles:(NSArray<SPKGalleryFile *> *)files
         startingAtIndex:(NSInteger)index
      fromViewController:(UIViewController *)presenter {
    _galleryFiles = [files copy];
    [self prepareForPresentationAtIndex:index];
    [self presentFromViewController:presenter];
}

- (void)prepareForPresentationAtIndex:(NSInteger)index {
    _lazyItems = [NSMutableDictionary dictionary];
    _currentIndex = MAX(0, MIN(index, [self itemCount] - 1));
    _controllerCache = [NSMutableDictionary dictionary];
    _isSingleItemMode = ([self itemCount] <= 1);
    _isToolbarVisible = YES;
}

- (void)presentFromViewController:(UIViewController *)presenter {
    [self beginPreviewPlaybackSuppressionIfNeeded];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:self];
    navigationController.navigationBar.prefersLargeTitles = NO;
    navigationController.navigationBar.tintColor =
        [SPKUtils SPKColor_InstagramPrimaryText];
    navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigationController.modalPresentationStyle =
        [self shouldUseLifecycleSuppressingPresentation]
            ? UIModalPresentationFullScreen
            : UIModalPresentationOverFullScreen;
    navigationController.modalPresentationCapturesStatusBarAppearance = YES;
    navigationController.transitioningDelegate = self;
    [presenter presentViewController:navigationController
                            animated:YES
                          completion:nil];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.view.backgroundColor = [UIColor clearColor];
    [self setupPresentationBackdrop];

    [self setupTopNavigationItems];
    [self setupBottomBar];
    [self setupPageViewController];
    [self setupInfoOverlay];
    [self setupDismissGesture];
    [self updateUI];
}

// Metadata overlay over the media: author + subtitle (post date, or full name for
// profile pictures; source + both dates in the gallery). Shown for the live
// action-button preview path and the gallery — not the bare local-file preview — and
// only when the corresponding pref is enabled.
//
// PHOTOS ONLY: on video the bottom is occupied by AVPlayerViewController's scrubber
// and the top-right by its route/cast button, so there is no non-colliding spot; we
// skip the overlay for video pages entirely (see refreshInfoOverlay).
//
// Anchored to the bottom, but its bottom constraint is frozen at the toolbar-visible
// position (updateInfoOverlayPositionIfNeeded) so it fades in place instead of
// sliding as the chrome and its safe-area inset move.
- (void)setupInfoOverlay {
    if (_previewOnly)
        return;
    NSString *prefKey = _isFromGallery ? @"gallery_preview_show_metadata"
                                       : @"general_preview_show_metadata";
    if (![SPKUtils getBoolPref:prefKey])
        return;

    _infoOverlay = [[SPKMediaPreviewInfoOverlay alloc] initWithFrame:CGRectZero];
    _infoOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _infoOverlay.alpha = [self infoOverlayVisibleAlpha];
    [self.view addSubview:_infoOverlay];
    _infoOverlayBottomConstraint =
        [_infoOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_infoOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_infoOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        _infoOverlayBottomConstraint,
    ]];
    [self refreshInfoOverlay];
}

// Freeze the overlay just above the action toolbar. Only recompute while the chrome
// is visible and not mid-toggle, so the position is captured once from the
// toolbar-visible layout and never shifts as the toolbar animates away.
- (void)updateInfoOverlayPositionIfNeeded {
    if (!_infoOverlayBottomConstraint)
        return;
    if (!_isToolbarVisible || self.chromeToggleInProgress)
        return;

    UIToolbar *toolbar = self.navigationController.toolbar;
    CGFloat toolbarTopInView;
    if (toolbar && !toolbar.hidden && toolbar.window) {
        CGRect frameInView = [self.view convertRect:toolbar.bounds fromView:toolbar];
        toolbarTopInView = CGRectGetMinY(frameInView);
    } else {
        toolbarTopInView =
            CGRectGetMaxY(self.view.bounds) - self.view.safeAreaInsets.bottom;
    }

    CGFloat newConstant = (toolbarTopInView - 6.0) - CGRectGetHeight(self.view.bounds);
    if (ABS(newConstant - _infoOverlayBottomConstraint.constant) > 0.5) {
        _infoOverlayBottomConstraint.constant = newConstant;
    }
}

// Same frozen measurement the info overlay uses, handed to the pages so their own
// floating controls (the Live Text button) sit at a fixed height. Recomputed only
// while the chrome is visible and settled, so toggling it never moves anything.
- (void)updateChromeBottomLimitIfNeeded {
    if (!_isToolbarVisible || self.chromeToggleInProgress)
        return;

    UIToolbar *toolbar = self.navigationController.toolbar;
    CGFloat toolbarTopInView;
    if (toolbar && !toolbar.hidden && toolbar.window) {
        CGRect frameInView = [self.view convertRect:toolbar.bounds fromView:toolbar];
        toolbarTopInView = CGRectGetMinY(frameInView);
    } else {
        toolbarTopInView =
            CGRectGetMaxY(self.view.bounds) - self.view.safeAreaInsets.bottom;
    }

    CGFloat limit = MAX(0.0, CGRectGetMaxY(self.view.bounds) - toolbarTopInView);
    if (_hasChromeBottomLimit && ABS(limit - _chromeBottomLimit) < 0.5)
        return;
    _chromeBottomLimit = limit;
    _hasChromeBottomLimit = YES;
    for (UIViewController *controller in self.pageViewController.viewControllers) {
        [self applyChromeBottomLimitToController:controller];
    }
}

- (void)applyChromeBottomLimitToController:(UIViewController *)controller {
    if (!_hasChromeBottomLimit)
        return;
    if ([controller respondsToSelector:@selector(applyChromeBottomLimit:)]) {
        [(id)controller applyChromeBottomLimit:_chromeBottomLimit];
    }
}

// The overlay is visible only while the chrome is and Live Text is not drawing its
// own quick action over the same corner.
- (CGFloat)infoOverlayVisibleAlpha {
    return (_isToolbarVisible && !_liveTextHighlightActive) ? 1.0 : 0.0;
}

- (void)refreshInfoOverlay {
    if (!_infoOverlay)
        return;
    // A new page carries no highlight of its own; the page left behind keeps its
    // VisionKit state but is no longer on screen.
    if (_liveTextHighlightActive) {
        _liveTextHighlightActive = NO;
        _infoOverlay.alpha = [self infoOverlayVisibleAlpha];
    }

    SPKMediaItem *item = [self currentItem];
    // Photos only — the video transport bar has no free space for it.
    if (item.mediaType != SPKMediaItemTypeImage) {
        _infoOverlay.hidden = YES;
        return;
    }

    SPKGallerySaveMetadata *meta = [self metadataForMediaItem:item];
    NSString *username = meta.sourceUsername;
    NSString *handle = username.length > 0 ? [@"@" stringByAppendingString:username] : nil;

    NSString *title = nil;
    NSString *subtitle = nil;

    if (self.isFromGallery) {
        // Gallery: "@user · Feed" (or just the source when there's no username),
        // subtitle "Posted <date> · Saved <date>".
        SPKGalleryFile *file = item.galleryFile;
        NSString *sourceLabel =
            [SPKGalleryFile labelForSource:(SPKGallerySource)meta.source];
        if (handle.length > 0 && sourceLabel.length > 0) {
            title = [NSString stringWithFormat:@"%@ · %@", handle, sourceLabel];
        } else {
            title = handle.length > 0 ? handle : sourceLabel;
        }

        NSDate *savedDate = file.dateAdded;
        // The posted date isn't persisted, but Sparkle filenames encode it as a
        // trailing compact segment — recover it with the shared parser.
        SPKGallerySaveMetadata *parsed = [[SPKGallerySaveMetadata alloc] init];
        SPKGalleryApplyImportHeuristicsFromFilename(file.relativePath, parsed);
        NSDate *postedDate = parsed.importPostedDate;

        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        // Only surface "Posted" when it meaningfully differs from "Saved" (the
        // generator writes posted == saved when IG exposed no taken_at).
        if (postedDate &&
            (!savedDate || ABS([postedDate timeIntervalSinceDate:savedDate]) > 120.0)) {
            [parts addObject:[NSString stringWithFormat:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_POSTED_VALUE_FORMAT"),
                                                        SPKPreviewMediumDateString(postedDate)]];
        }
        if (savedDate) {
            [parts addObject:[NSString stringWithFormat:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_SAVED_VALUE_FORMAT"),
                                                        SPKPreviewMediumDateString(savedDate)]];
        }
        subtitle = [parts componentsJoinedByString:@" · "];
    } else {
        // Live preview: "@user"; subtitle = post date + time (hour), or full name for profile pics.
        title = handle;
        subtitle = [SPKUtils spk_formattedDateHeader:meta.importPostedDate];
        if (subtitle.length == 0) {
            subtitle = meta.sourceFullName;
        }
    }

    BOOL hasContent = [_infoOverlay configureWithTitle:title subtitle:subtitle];
    _infoOverlay.hidden = !hasContent;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self prepareViewControllerForDisplay:self.pageViewController.viewControllers
                                              .firstObject];
    [self prepareAdjacentViewControllersAroundIndex:self.currentIndex];
}

// Called when a screen pushed over this player is closed. It cannot be done in
// -viewDidAppear:, which never fires again: the pushed screen is presented *over*
// the player, so the player never disappears in the first place.
- (void)resumeAfterNavigationBack {
    if (!self.pausedForNavigationAway)
        return;
    self.pausedForNavigationAway = NO;
    [[self currentVideoViewController] play];
}

// Pauses the preview for a screen pushed over it, remembering that it was us, so
// -viewDidAppear: knows whether resuming is correct.
- (void)pauseForNavigationAway {
    SPKFullScreenVideoViewController *video = [self currentVideoViewController];
    if (!video)
        return;
    self.pausedForNavigationAway = YES;
    [video pause];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateMediaContentBarInsetsIfNeeded];
    [self updateInfoOverlayPositionIfNeeded];
    [self updateChromeBottomLimitIfNeeded];
    [self updateCurrentVideoPlayerControlInsetsAnimated:NO];
}

// On non-notched devices the opaque top/bottom bars overlap edge-to-edge media,
// so we inset the content between them while the chrome is visible. The bar
// heights are captured only while the chrome is visible; the chrome toggle then
// animates the applied inset between those heights and zero (full-screen).
- (void)updateMediaContentBarInsetsIfNeeded {
    if (!SPKFullScreenPreviewShouldInsetMediaBetweenBars())
        return;
    if (self.chromeToggleInProgress)
        return;
    if (!_isToolbarVisible)
        return;

    UIEdgeInsets insets = UIEdgeInsetsMake(self.view.safeAreaInsets.top, 0.0,
                                           self.view.safeAreaInsets.bottom, 0.0);
    if (UIEdgeInsetsEqualToEdgeInsets(insets, self.mediaContentBarInsets) &&
        UIEdgeInsetsEqualToEdgeInsets(insets, self.currentContentInsets))
        return;

    self.mediaContentBarInsets = insets;
    self.currentContentInsets = insets;
    for (UIViewController *controller in self.pageViewController.viewControllers) {
        [self applyMediaContentBarInsetsToController:controller];
    }
}

- (void)applyMediaContentBarInsetsToController:(UIViewController *)controller {
    if (!SPKFullScreenPreviewShouldInsetMediaBetweenBars())
        return;
    if ([controller respondsToSelector:@selector(applyMediaContentInsets:)]) {
        [(id)controller applyMediaContentInsets:self.currentContentInsets];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // NSCache sheds its own entries under pressure, but the images parked on the
    // items are strong references it cannot reach. Drop the pages outside the
    // usual window, then the images of everything but the page on screen and the
    // two it can be swiped onto.
    [self trimControllerCacheAroundIndex:_currentIndex];
    for (NSNumber *builtIndex in self.lazyItems.allKeys.copy) {
        if (ABS(builtIndex.integerValue - _currentIndex) <= 1)
            continue;
        [self releaseImageForItem:self.lazyItems[builtIndex]];
    }
    if (!_galleryFiles) {
        for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
            if (ABS(i - _currentIndex) <= 1)
                continue;
            [self releaseImageForItem:_items[(NSUInteger)i]];
        }
    }
}

- (BOOL)prefersStatusBarHidden {
    return !self.isToolbarVisible;
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)setupPresentationBackdrop {
    _presentationBackdropView = [[UIView alloc] initWithFrame:CGRectZero];
    _presentationBackdropView.backgroundColor = [UIColor blackColor];
    _presentationBackdropView.translatesAutoresizingMaskIntoConstraints = NO;
    _presentationBackdropView.alpha = 1.0;
    [self.view addSubview:_presentationBackdropView];
    [NSLayoutConstraint activateConstraints:@[
        [_presentationBackdropView.topAnchor
            constraintEqualToAnchor:self.view.topAnchor],
        [_presentationBackdropView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [_presentationBackdropView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [_presentationBackdropView.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self.view sendSubviewToBack:_presentationBackdropView];
}

#pragma mark - Top Navigation

- (void)setupTopNavigationItems {
    UIBarButtonItem *closeItem = SPKMediaChromeTopBarButtonItemWithTint(
        @"xmark", self, @selector(closeTapped), [UIColor labelColor], SPKL(@"COMMON_ACTION_CLOSE"));
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ closeItem ]);

    if (_isFromGallery) {
        _topFavoriteItem = SPKMediaChromeTopBarButtonItemWithTint(
            @"heart", self, @selector(favoriteTapped), [UIColor labelColor],
            SPKL(@"GALLERY_GALLERY_FAVORITE_TEXT"));
    } else {
        _topFavoriteItem = nil;
    }
    [self updateFavoriteButton];
}

#pragma mark - Bottom Bar

- (void)setupBottomBar {
    UINavigationController *nav = self.navigationController;
    if (_previewOnly) {
        // No action toolbar in bare preview mode — keep it hidden and skip item setup.
        [nav setToolbarHidden:YES animated:NO];
        SPKMediaChromeSetBarsMaterialActive(nav, NO);
        return;
    }
    SPKMediaChromeConfigureBottomToolbar(nav.toolbar);

    _savePhotosItem = SPKMediaChromeBottomBarButtonItem(
        @"download", SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT"), self, @selector(saveToPhotos));
    _shareItem = SPKMediaChromeBottomBarButtonItem(@"share", SPKL(@"ALERT_ACTION_SHARE"), self,
                                                   @selector(shareMedia));
    _clipboardItem = SPKMediaChromeBottomBarButtonItem(@"copy", SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT"), self,
                                                       @selector(copyMedia));
    _trimItem = SPKMediaChromeBottomBarButtonItem(@"trim", SPKL(@"ALERT_ACTION_TRIM"), self,
                                                  @selector(trimCurrentItem));
    _editItem = SPKMediaChromeBottomBarButtonItem(@"crop", SPKL(@"ALERT_ACTION_EDIT"), self,
                                                  @selector(editCurrentItem));

    if (!_isFromGallery && [self itemCount] > 1) {
        _bulkActionsItem =
            SPKMediaChromeBottomBarButtonItem(@"more", SPKActionButtonTitleForIdentifier(kSPKActionDownloadAll), nil, nil);
    }

    if (_isFromGallery) {
        _galleryOriginItem =
            SPKMediaChromeBottomBarButtonItem(@"more", SPKL(@"COMMON_MORE_ACCESSIBILITY_LABEL"), nil, nil);

        _deleteGalleryItem = SPKMediaChromeBottomBarButtonItem(
            @"trash", SPKL(@"GALLERY_GALLERY_DELETE_GALLERY_TEXT"), self, @selector(deleteFromGallery));
        _deleteGalleryItem.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    } else {
        _saveGalleryItem = SPKMediaChromeBottomBarButtonItem(
            @"sparkle_gallery", SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT"), self, @selector(saveToGallery));
        _downloadURLItem = SPKMediaChromeBottomBarButtonItem(
            @"link", SPKL(@"FEED_COMMENT_ACTIONS_COPY_DOWNLOAD_URL_TEXT"), self,
            @selector(copyDownloadURLForCurrentItem));
    }

    [self rebuildBottomToolbarItems];
    [nav setToolbarHidden:NO animated:NO];

    // Start with transparent bars (letterboxed content). On iOS <= 18 we switch
    // to a material backing when the image is zoomed in behind the bars.
    SPKMediaChromeSetBarsMaterialActive(nav, NO);
}

- (void)rebuildBottomToolbarItems {
    NSMutableArray<UIBarButtonItem *> *primary = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *trailing = [NSMutableArray array];
    [primary addObject:_savePhotosItem];
    [primary addObject:_shareItem];
    [primary addObject:_clipboardItem];

    // Trim (video or audio) breaks out into its own trailing capsule so it reads
    // as a distinct action rather than crowding the save/share group.
    SPKMediaItemType currentType = [self currentItem].mediaType;
    if (_trimItem && (currentType == SPKMediaItemTypeVideo ||
                      currentType == SPKMediaItemTypeAudio)) {
        [trailing addObject:_trimItem];
    }
    // Photos get an Edit (crop / rotate / flip) action in the same trailing
    // capsule the video/audio Trim uses — both Gallery items (Replace / Copy) and
    // expanded Instagram photos (destination menu), mirroring Trim's availability.
    if (_editItem && currentType == SPKMediaItemTypeImage) {
        [trailing addObject:_editItem];
    }

    if (_isFromGallery) {
        // Delete stays in the primary group; "more" breaks out into its own
        // trailing capsule, sitting after the trash icon.
        if (_deleteGalleryItem) {
            [primary addObject:_deleteGalleryItem];
        }
        if (_galleryOriginItem && _galleryOriginItemVisible) {
            [trailing addObject:_galleryOriginItem];
        }
    } else {
        if (_saveGalleryItem) {
            [primary addObject:_saveGalleryItem];
        }
        // Copy Download URL is the last action in the primary (first) group.
        if (_downloadURLItem) {
            [primary addObject:_downloadURLItem];
        }
        // "Download all" / bulk actions overflow gets its own trailing capsule.
        if (_bulkActionsItem && _bulkActionsItemVisible) {
            [trailing addObject:_bulkActionsItem];
        }
    }

    self.toolbarItems =
        SPKMediaChromeBottomToolbarItemsWithTrailingGroup(primary, trailing);
}

/// Anchor view for popovers/action sheets presented from the bottom toolbar.
- (UIView *)bottomBarAnchorView {
    return self.navigationController.toolbar ?: self.view;
}

#pragma mark - Page View Controller

- (void)setupPageViewController {
    _pageViewController = [[UIPageViewController alloc]
        initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
          navigationOrientation:
              UIPageViewControllerNavigationOrientationHorizontal
                        options:nil];
    _pageViewController.dataSource = self;
    _pageViewController.delegate = self;

    [self addChildViewController:_pageViewController];
    _pageViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:_pageViewController.view
                aboveSubview:_presentationBackdropView];
    [_pageViewController didMoveToParentViewController:self];

    [NSLayoutConstraint activateConstraints:@[
        [_pageViewController.view.topAnchor
            constraintEqualToAnchor:self.view.topAnchor],
        [_pageViewController.view.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
        [_pageViewController.view.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [_pageViewController.view.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    for (UIView *subview in _pageViewController.view.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            _pageScrollView = (UIScrollView *)subview;
            break;
        }
    }

    // The video page (and the embedded AVPlayerViewController transport controls)
    // live inside this paging scroll view. With delaysContentTouches = YES (the
    // default) the scroll view withholds touch-began from those controls while it
    // decides whether a scroll is starting, which on iOS 18 and lower leaves the
    // player controls unresponsive to taps. Deliver touches immediately; paging
    // still works because canCancelContentTouches stays on for actual drags.
    _pageScrollView.delaysContentTouches = NO;

    UIViewController *initialVC = [self viewControllerForIndex:_currentIndex];
    if (initialVC) {
        [_pageViewController
            setViewControllers:@[ initialVC ]
                     direction:UIPageViewControllerNavigationDirectionForward
                      animated:NO
                    completion:nil];
    }
}

#pragma mark - Items

- (NSInteger)itemCount {
    return _galleryFiles ? (NSInteger)_galleryFiles.count : (NSInteger)_items.count;
}

/// The item for `index`, built on first use when browsing the gallery. Items stay
/// cached for as long as their page controller does, so paging back and forth
/// across the same few pages doesn't rebuild them.
- (SPKMediaItem *)itemAtIndex:(NSInteger)index {
    if (index < 0 || index >= [self itemCount])
        return nil;
    if (!_galleryFiles)
        return _items[(NSUInteger)index];

    NSNumber *key = @(index);
    SPKMediaItem *cached = _lazyItems[key];
    if (cached)
        return cached;

    SPKMediaItem *item =
        [SPKMediaItem itemWithGalleryFile:_galleryFiles[(NSUInteger)index]];
    _lazyItems[key] = item;
    return item;
}

- (NSInteger)indexOfItem:(SPKMediaItem *)item {
    if (!item)
        return NSNotFound;
    if (!_galleryFiles)
        return [_items indexOfObjectIdenticalTo:item];

    // Built items are trimmed in lockstep with the controller cache, so any page
    // that can ask for its index still has its item here (a handful of entries).
    for (NSNumber *key in _lazyItems) {
        if (_lazyItems[key] == item)
            return key.integerValue;
    }
    return NSNotFound;
}

/// Drops the full-size image an item is holding. Only safe for items that can
/// reload it from disk -- an item created straight from a UIImage (no file behind
/// it) would lose its only copy.
- (void)releaseImageForItem:(SPKMediaItem *)item {
    if (item.fileURL || item.resolvedFileURL) {
        item.image = nil;
    }
}

- (UIViewController *)createViewControllerForIndex:(NSInteger)index {
    SPKMediaItem *item = [self itemAtIndex:index];
    if (!item)
        return nil;

    if (item.mediaType == SPKMediaItemTypeVideo ||
        item.mediaType == SPKMediaItemTypeAudio) {
        SPKFullScreenVideoViewController *vc =
            [[SPKFullScreenVideoViewController alloc] initWithMediaItem:item];
        vc.delegate = self;
        return vc;
    }

    SPKFullScreenImageViewController *vc =
        [[SPKFullScreenImageViewController alloc] initWithMediaItem:item];
    vc.delegate = self;
    return vc;
}

- (UIViewController *)viewControllerForIndex:(NSInteger)index {
    if (index < 0 || index >= [self itemCount])
        return nil;

    NSNumber *cacheKey = @(index);
    UIViewController *cachedController = self.controllerCache[cacheKey];
    if (cachedController) {
        return cachedController;
    }

    UIViewController *controller = [self createViewControllerForIndex:index];
    if (controller) {
        self.controllerCache[cacheKey] = controller;
    }
    return controller;
}

- (NSInteger)indexOfViewController:(UIViewController *)vc {
    SPKMediaItem *item = nil;
    if ([vc isKindOfClass:[SPKFullScreenImageViewController class]]) {
        item = ((SPKFullScreenImageViewController *)vc).mediaItem;
    } else if ([vc isKindOfClass:[SPKFullScreenVideoViewController class]]) {
        item = ((SPKFullScreenVideoViewController *)vc).mediaItem;
    }
    return [self indexOfItem:item];
}

- (void)prepareViewControllerForDisplay:(UIViewController *)controller {
    SPKMediaItem *item = nil;
    if ([controller isKindOfClass:[SPKFullScreenImageViewController class]]) {
        item = ((SPKFullScreenImageViewController *)controller).mediaItem;
    } else if ([controller
                   isKindOfClass:[SPKFullScreenVideoViewController class]]) {
        item = ((SPKFullScreenVideoViewController *)controller).mediaItem;
    }
    if (item) {
        [[SPKMediaCacheManager sharedManager] prefetchItem:item];
    }

    if ([controller isKindOfClass:[SPKFullScreenVideoViewController class]]) {
        [self updatePlayerControlInsetsForVideoController:
                  (SPKFullScreenVideoViewController *)controller
                                                 animated:NO];
        [(SPKFullScreenVideoViewController *)controller prepareForDisplay];
    } else if ([controller
                   isKindOfClass:[SPKFullScreenImageViewController class]]) {
        [(SPKFullScreenImageViewController *)controller preloadContent];
    }

    // Keep the fixed between-bars inset applied to whatever page is shown.
    [controller loadViewIfNeeded];
    [self applyMediaContentBarInsetsToController:controller];
    [self applyChromeBottomLimitToController:controller];
}

- (void)prepareAdjacentViewControllersAroundIndex:(NSInteger)index {
    for (NSInteger resolvedIndex = index - 2; resolvedIndex <= index + 2;
         resolvedIndex++) {
        if (resolvedIndex == index)
            continue;
        SPKMediaItem *adjacentItem = [self itemAtIndex:resolvedIndex];
        if (!adjacentItem)
            continue;

        [[SPKMediaCacheManager sharedManager] prefetchItem:adjacentItem];
        UIViewController *controller = [self viewControllerForIndex:resolvedIndex];
        if ([controller isKindOfClass:[SPKFullScreenVideoViewController class]]) {
            [(SPKFullScreenVideoViewController *)controller preloadContent];
        } else if ([controller
                       isKindOfClass:[SPKFullScreenImageViewController class]]) {
            [(SPKFullScreenImageViewController *)controller preloadContent];
        }
        // Pre-apply the inset so paging onto this page shows content already
        // fitted between the bars (no full-bleed flash on arrival).
        [controller loadViewIfNeeded];
        [self applyMediaContentBarInsetsToController:controller];
    }

    [self trimControllerCacheAroundIndex:index];
}

- (void)trimControllerCacheAroundIndex:(NSInteger)index {
    NSArray<NSNumber *> *cachedIndexes = self.controllerCache.allKeys.copy;
    for (NSNumber *cachedIndex in cachedIndexes) {
        NSInteger value = cachedIndex.integerValue;
        if (ABS(value - index) <= 2)
            continue;

        UIViewController *controller = self.controllerCache[cachedIndex];
        if ([controller respondsToSelector:@selector(cleanup)]) {
            [(id)controller cleanup];
        }
        [self.controllerCache removeObjectForKey:cachedIndex];
    }

    // Built items go with their page. They must be trimmed on exactly the same
    // window as the controllers, because -indexOfItem: resolves a page back to
    // its index through this dictionary.
    NSArray<NSNumber *> *builtIndexes = self.lazyItems.allKeys.copy;
    for (NSNumber *builtIndex in builtIndexes) {
        if (ABS(builtIndex.integerValue - index) <= 2)
            continue;
        [self releaseImageForItem:self.lazyItems[builtIndex]];
        [self.lazyItems removeObjectForKey:builtIndex];
    }
}

- (SPKFullScreenVideoViewController *)currentVideoViewController {
    UIViewController *currentVC =
        self.pageViewController.viewControllers.firstObject;
    return [currentVC isKindOfClass:[SPKFullScreenVideoViewController class]]
               ? (SPKFullScreenVideoViewController *)currentVC
               : nil;
}

/// Whether the currently visible page (image or video) is zoomed in. Used to
/// suppress paging/dismiss and drive the bar material.
- (BOOL)isViewControllerZoomed:(UIViewController *)vc {
    if ([vc isKindOfClass:[SPKFullScreenImageViewController class]]) {
        return ((SPKFullScreenImageViewController *)vc).isZoomed;
    }
    if ([vc isKindOfClass:[SPKFullScreenVideoViewController class]]) {
        return ((SPKFullScreenVideoViewController *)vc).isZoomed;
    }
    return NO;
}

- (void)updatePlayerControlInsetsForVideoController:
            (SPKFullScreenVideoViewController *)videoController
                                           animated:(BOOL)animated {
    CGFloat bottomBoundaryInset = 0.0;
    BOOL usesLegacyToolbar = YES;
    if (@available(iOS 26.0, *)) {
        usesLegacyToolbar = NO;
    }
    if (usesLegacyToolbar && self.isToolbarVisible && !self.previewOnly &&
        !SPKFullScreenPreviewShouldInsetMediaBetweenBars()) {
        UIToolbar *toolbar = self.navigationController.toolbar;
        if (toolbar && !toolbar.hidden && toolbar.window) {
            CGRect toolbarFrame = [self.view convertRect:toolbar.bounds
                                                 fromView:toolbar];
            bottomBoundaryInset =
                MAX(0.0, CGRectGetMaxY(self.view.bounds) -
                             CGRectGetMinY(toolbarFrame));
        } else if (self.hasChromeBottomLimit) {
            bottomBoundaryInset = self.chromeBottomLimit;
        }
    }
    [videoController synchronizePlayerControlsToBottomBoundaryInset:
                         bottomBoundaryInset
                                                          animated:animated];
}

- (void)updateCurrentVideoPlayerControlInsetsAnimated:(BOOL)animated {
    SPKFullScreenVideoViewController *videoController =
        [self currentVideoViewController];
    if (!videoController)
        return;
    [self updatePlayerControlInsetsForVideoController:videoController
                                             animated:animated];
}

#pragma mark - UIPageViewControllerDataSource

- (UIViewController *)pageViewController:
                          (UIPageViewController *)pageViewController
      viewControllerBeforeViewController:(UIViewController *)viewController {
    NSInteger index = [self indexOfViewController:viewController];
    if (index == NSNotFound || index == 0)
        return nil;
    return [self viewControllerForIndex:index - 1];
}

- (UIViewController *)pageViewController:
                          (UIPageViewController *)pageViewController
       viewControllerAfterViewController:(UIViewController *)viewController {
    NSInteger index = [self indexOfViewController:viewController];
    if (index == NSNotFound || index >= [self itemCount] - 1)
        return nil;
    return [self viewControllerForIndex:index + 1];
}

#pragma mark - UIPageViewControllerDelegate

- (void)pageViewController:(UIPageViewController *)pageViewController
         didFinishAnimating:(BOOL)finished
    previousViewControllers:
        (NSArray<UIViewController *> *)previousViewControllers
        transitionCompleted:(BOOL)completed {
    if (!completed)
        return;

    UIViewController *currentVC = pageViewController.viewControllers.firstObject;
    NSInteger newIndex = [self indexOfViewController:currentVC];
    if (newIndex == NSNotFound)
        return;

    _currentIndex = newIndex;
    [self updateUI];
    [self prepareViewControllerForDisplay:currentVC];
    [self prepareAdjacentViewControllersAroundIndex:newIndex];

    // Match the bar material to the newly visible page's zoom state.
    BOOL zoomed = [self isViewControllerZoomed:currentVC];
    SPKMediaChromeSetBarsMaterialActive(self.navigationController, zoomed);

    for (UIViewController *prevVC in previousViewControllers) {
        if ([prevVC isKindOfClass:[SPKFullScreenVideoViewController class]]) {
            [(SPKFullScreenVideoViewController *)prevVC pause];
        }
    }
}

#pragma mark - SPKFullScreenContentDelegate

- (void)mediaContentDidTap:(UIViewController *)controller {
    [self toggleToolbar];
}

- (void)mediaContent:(UIViewController *)controller
    didFailWithError:(NSError *)error {
}

- (void)mediaContent:(UIViewController *)controller
    didChangeZoomState:(BOOL)isZoomed {
    // Only adapt for the visible page.
    if (controller != self.pageViewController.viewControllers.firstObject)
        return;
    SPKMediaChromeSetBarsMaterialActive(self.navigationController, isZoomed);
    _pageScrollView.scrollEnabled = !isZoomed;
}

- (void)mediaContent:(UIViewController *)controller
    didChangeLiveTextHighlight:(BOOL)highlighted {
    // Only the visible page owns the chrome; a page being torn down or preloaded
    // off screen must not fade the overlay for the photo the user is looking at.
    if (controller != self.pageViewController.viewControllers.firstObject)
        return;
    if (_liveTextHighlightActive == highlighted)
        return;
    _liveTextHighlightActive = highlighted;
    if (!_infoOverlay || _infoOverlay.hidden)
        return;
    // Match the chrome toggle so the two never look like separate events.
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         self.infoOverlay.alpha = [self infoOverlayVisibleAlpha];
                     }
                     completion:nil];
}

#pragma mark - UI Updates

- (void)updateUI {
    [self updateCounter];
    [self updateFavoriteButton];
    [self updateGalleryOriginButton];
    [self refreshInfoOverlay];
    if (self.bulkActionsItem) {
        UIMenu *menu = [self bulkActionsMenu];
        self.bulkActionsItem.menu = menu;
        self.bulkActionsItemVisible = (menu != nil);
        [self rebuildBottomToolbarItems];
    }
}

- (void)updateCounter {
    if (_isSingleItemMode) {
        self.title = nil;
        return;
    }
    self.title =
        [NSString stringWithFormat:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_VALUE_VALUE_FORMAT"), (long)_currentIndex + 1,
                                   (unsigned long)[self itemCount]];
}

- (void)updateFavoriteButton {
    if (!_topFavoriteItem)
        return;

    SPKMediaItem *item = [self currentItem];
    BOOL isFav = item.galleryFile.isFavorite;
    UIImage *img = isFav ? SPKMediaChromeTopBarIcon(@"heart_filled")
                         : SPKMediaChromeTopBarIcon(@"heart");

    if (!item.galleryFile) {
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[]);
        return;
    }

    _topFavoriteItem.image = img;
    _topFavoriteItem.tintColor =
        isFav ? [UIColor systemPinkColor] : [UIColor labelColor];
    _topFavoriteItem.accessibilityLabel = isFav ? SPKL(@"GALLERY_GALLERY_UNFAVORITE_TEXT") : SPKL(@"GALLERY_GALLERY_FAVORITE_TEXT");
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem,
                                         @[ _topFavoriteItem ]);
}

- (void)showGalleryOpenFailureMessage:(NSString *)title
                     actionIdentifier:(NSString *)actionIdentifier {
    SPKNotify(actionIdentifier, title,
              SPKL(@"COMMON_ORIGINAL_CONTENT_UNAVAILABLE_TOAST"), @"error_filled",
              SPKNotificationToneError);
}

- (void)dismissGalleryFlowForOriginOpenWithCompletion:
    (void (^)(void))completion {
    UIViewController *previewContainer = self.navigationController ?: self;
    UIViewController *galleryPresenter =
        previewContainer.presentingViewController;
    UIViewController *galleryContainer =
        galleryPresenter.navigationController ?: galleryPresenter;

    if (self.isFromGallery && galleryContainer) {
        [self cleanupAll];
        [self restorePreviewPlaybackIfNeeded];
        if ([SPKGalleryManager sharedManager].isLockEnabled) {
            [[SPKGalleryManager sharedManager] lockGallery];
        }
        [previewContainer
            dismissViewControllerAnimated:NO
                               completion:^{
                                   [galleryContainer
                                       dismissViewControllerAnimated:YES
                                                          completion:^{
                                                              if ([self.delegate
                                                                      respondsToSelector:
                                                                          @selector(fullScreenMediaPlayerDidDismiss)]) {
                                                                  [self.delegate
                                                                          fullScreenMediaPlayerDidDismiss];
                                                              }
                                                              if (completion) {
                                                                  completion();
                                                              }
                                                          }];
                               }];
        return;
    }

    [previewContainer
        dismissViewControllerAnimated:YES
                           completion:^{
                               [self cleanupAll];
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   [self restorePreviewPlaybackIfNeeded];
                               });
                               if ([self.delegate
                                       respondsToSelector:@selector(fullScreenMediaPlayerDidDismiss)]) {
                                   [self.delegate fullScreenMediaPlayerDidDismiss];
                               }
                               if (completion) {
                                   completion();
                               }
                           }];
}

- (void)openOriginalPostForCurrentGalleryItem {
    SPKGalleryFile *file = self.currentItem.galleryFile;
    __weak __typeof(self) weakSelf = self;
    // The post is pushed over the player rather than replacing it, so the preview
    // stays alive behind it and would otherwise keep playing audio under the post.
    [self pauseForNavigationAway];
    // Pushed over the player, so closing the post comes back to it. See the note
    // in -openOriginalPostForFile:.
    if ([SPKGalleryOriginController openOriginalPostForGalleryFile:file
                                               fromViewController:self
                                                   legacyFallback:^{
                                                       [weakSelf dismissGalleryFlowForOriginOpenWithCompletion:^{
                                                           SPKNotify(kSPKNotificationGalleryOpenOriginal, SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_OPENED_ORIGINAL_POST_TEXT"),
                                                                     nil, @"external_link",
                                                                     SPKNotificationToneForIconResource(@"external_link"));
                                                       }];
                                                   }
                                                        onDismiss:^{
                                                            [weakSelf resumeAfterNavigationBack];
                                                        }]) {
        // Nothing to announce: the post is on screen.
    } else {
        [self showGalleryOpenFailureMessage:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_UNABLE_OPEN_ORIGINAL_POST_TEXT")
                           actionIdentifier:kSPKNotificationGalleryOpenOriginal];
    }
}

- (void)openProfileForCurrentGalleryItem {
    SPKGalleryFile *file = self.currentItem.galleryFile;
    // Completion, not the return value: see the note in -openProfileForFile:.
    __weak __typeof(self) weakSelf = self;
    // The profile is pushed over the player, which stays alive behind it, so its
    // audio has to be stopped explicitly.
    [self pauseForNavigationAway];
    [SPKGalleryOriginController openProfileForGalleryFile:file
                                      fromViewController:self
                                              completion:^(BOOL success, BOOL didLink) {
                                                  if (success) {
                                                      // Quiet when a link was just made: that toast already said it.
                                                      if (!didLink)
                                                          SPKNotify(kSPKNotificationGalleryOpenProfile, SPKL(@"COMMON_OPENED_PROFILE_TOAST"), nil,
                                                                    @"user_circle",
                                                                    SPKNotificationToneForIconResource(@"user_circle"));
                                                  } else {
                                                      [weakSelf showGalleryOpenFailureMessage:SPKL(@"COMMON_UNABLE_OPEN_PROFILE_TOAST")
                                                                             actionIdentifier:kSPKNotificationGalleryOpenProfile];
                                                  }
                                              }];
}

- (UIMenu *)galleryOriginMenuForCurrentItem {
    SPKGalleryFile *file = self.currentItem.galleryFile;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;

    if (file.hasOpenableOriginalMedia) {
        [actions addObject:[UIAction
                               actionWithTitle:SPKL(@"ALERT_ACTION_OPEN_ORIGINAL_POST")
                                         image:SPKGalleryPreviewMenuIcon(
                                                   @"external_link")
                                    identifier:nil
                                       handler:^(__unused UIAction *action) {
                                           [weakSelf
                                               openOriginalPostForCurrentGalleryItem];
                                       }]];
    }

    if (file.hasOpenableProfile) {
        [actions
            addObject:[UIAction
                          actionWithTitle:SPKL(@"ALERT_ACTION_OPEN_PROFILE")
                                    image:SPKGalleryPreviewMenuIcon(@"user_circle")
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                                      [weakSelf openProfileForCurrentGalleryItem];
                                  }]];
    }

    if (actions.count == 0) {
        UIAction *empty = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_NO_ORIGIN_ACTIONS_AVAILABLE")
                                              image:nil
                                         identifier:nil
                                            handler:^(__unused UIAction *action){
                                            }];
        empty.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:empty];
    }

    return [UIMenu menuWithTitle:@"" children:actions];
}

- (void)performSingleGalleryOriginAction {
    SPKGalleryFile *file = self.currentItem.galleryFile;
    if (file.hasOpenableProfile && !file.hasOpenableOriginalMedia) {
        [self openProfileForCurrentGalleryItem];
        return;
    }
    if (file.hasOpenableOriginalMedia && !file.hasOpenableProfile) {
        [self openOriginalPostForCurrentGalleryItem];
    }
}

#pragma mark - Trim

- (void)trimCurrentItem {
    SPKMediaItem *item = [self currentItem];
    BOOL isAudio = (item.mediaType == SPKMediaItemTypeAudio);
    if (!item || (item.mediaType != SPKMediaItemTypeVideo && !isAudio)) {
        return;
    }
    NSURL *url = item.resolvedFileURL ?: item.fileURL;
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        SPKNotify(@"spk.trim.preview", SPKL(@"MEDIA_TRIM_CANNOT_TRIM_TOAST"),
                  SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_MEDIA_FILE_UNAVAILABLE_TEXT"), @"error_filled",
                  SPKNotificationToneError);
        return;
    }
    // Pause the preview's playback so its audio stops while the editor is open.
    [[self currentVideoViewController] pause];

    SPKTrimConfiguration *config = isAudio
                                       ? [SPKTrimConfiguration configurationWithAudioURL:url]
                                       : [SPKTrimConfiguration configurationWithVideoURL:url];

    // Gallery-origin files keep the Replace / Save-as-Copy flow (handled after
    // dismiss). Expanded Instagram media (stories, feed, reels, DMs) instead pick
    // a destination in-editor — Photos / Gallery / Share / Copy — exactly like the
    // "Trim & Save" action button, so it no longer silently dumps a copy into the
    // Gallery (and carries source attribution so the filename isn't media_other_...).
    BOOL fromGallery = (item.galleryFile != nil);
    if (!fromGallery) {
        NSMutableArray<SPKTrimDoneOption *> *options = [NSMutableArray array];
        // Photos can't hold an audio file, so for audio offer "Save Audio to Files"
        // (broadly available for audio) in its place.
        if (isAudio) {
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES") identifier:@"files" iconName:@"audio_download"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SHARE_AUDIO") identifier:@"share" iconName:@"share"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_COPY_AUDIO_TEXT") identifier:@"clipboard" iconName:@"copy"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY") identifier:@"gallery" iconName:@"sparkle_gallery"]];
        } else {
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT") identifier:@"photos" iconName:@"download"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SHARE") identifier:@"share" iconName:@"share"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT") identifier:@"clipboard" iconName:@"copy"]];
            [options addObject:[SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT") identifier:@"gallery" iconName:@"sparkle_gallery"]];
        }
        config.doneOptions = options;
    }

    __weak typeof(self) weakSelf = self;
    [SPKTrimEditorViewController presentWithConfiguration:config
                                                     from:self
                                               completion:^(SPKTrimResult *result) {
                                                   if (!result) {
                                                       return; // Cancelled.
                                                   }
                                                   if (fromGallery) {
                                                       [weakSelf saveTrimResultToGallery:result fromItem:item];
                                                   } else {
                                                       [SPKTrimSaveCoordinator routeResult:result
                                                                             toDestination:(result.destinationTag ?: @"gallery")
                                                                                           metadata:item.galleryMetadata
                                                                                 presenter:weakSelf
                                                                              existingPill:nil
                                                                                completion:nil];
                                                   }
                                               }];
}

#pragma mark - Edit (photo)

- (void)editCurrentItem {
    SPKMediaItem *item = [self currentItem];
    if (!item || item.mediaType != SPKMediaItemTypeImage) {
        return;
    }

    BOOL fromGallery = (item.galleryFile != nil);

    // Resolve a source image. Gallery items decode from disk (freshest after an
    // in-place Replace). Expanded Instagram photos (feed/stories/DMs) reuse the
    // bitmap already on screen; if that's somehow missing, hand off to the
    // download+edit entry (which fetches the remote original).
    UIImage *source = nil;
    if (fromGallery) {
        NSURL *url = [item.galleryFile fileURL];
        source = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    } else {
        // Reuse the bitmap that's already been fetched for display (the cache
        // manager keeps a local copy) so we don't re-download what's on screen.
        source = item.image;
        if (!source) {
            NSURL *cached = [[SPKMediaCacheManager sharedManager] bestAvailableFileURLForItem:item];
            NSURL *url = cached ?: item.resolvedFileURL ?
                                                        : item.fileURL;
            if (url.isFileURL)
                source = [UIImage imageWithContentsOfFile:url.path];
        }
    }

    if (!source) {
        if (!fromGallery) {
            [SPKPhotoEditEntry beginEditAndSaveForMediaObject:item.sourceMediaObject
                                                     photoURL:(item.resolvedFileURL ?: item.fileURL)
                                                              metadata:item.galleryMetadata
                                                    presenter:self];
            return;
        }
        SPKNotify(@"spk.photoedit.load", SPKL(@"GALLERY_GALLERY_CANNOT_EDIT_TEXT"),
                  SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_IMAGE_FILE_UNAVAILABLE_TEXT"), @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (fromGallery) {
        // Gallery origin: edit, then offer Replace / Save-as-Copy and re-display.
        [SPKPhotoEditorViewController presentWithSourceImage:source
                                               configuration:[SPKPhotoEditorConfiguration freeformConfiguration]
                                                        from:self
                                                  completion:^(UIImage *edited) {
                                                      if (!edited)
                                                          return;
                                                      [SPKTrimSaveCoordinator saveEditedImage:edited
                                                                                   originFile:item.galleryFile
                                                                               fallbackSource:(SPKGallerySource)item.gallerySaveSource
                                                                                   folderPath:nil
                                                                                    presenter:weakSelf
                                                                                   completion:^(BOOL didChange) {
                                                                                       // On a Replace, the current item's media changed on disk; re-display it so
                                                                                       // the preview shows the edit without needing to reopen the viewer. (On a
                                                                                       // Copy the media is unchanged, so this harmlessly re-shows the original.)
                                                                                       if (didChange)
                                                                                           [weakSelf refreshDisplayedImageForItem:item];
                                                                                   }];
                                                  }];
        return;
    }

    // Non-gallery expanded media: pick a destination in-editor (Photos / Gallery /
    // Share / Copy), mirroring the "Edit & Save" action button and the non-gallery
    // trim flow — no silent Gallery dump.
    SPKPhotoEditorConfiguration *config = [SPKPhotoEditorConfiguration freeformConfiguration];
    config.doneOptions = @[
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT")
                                       identifier:@"photos"
                                         iconName:@"download"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SHARE")
                                       identifier:@"share"
                                         iconName:@"share"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT")
                                       identifier:@"clipboard"
                                         iconName:@"copy"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT")
                                       identifier:@"gallery"
                                         iconName:@"sparkle_gallery"],
    ];
    [SPKPhotoEditorViewController presentWithSourceImage:source
                                           configuration:config
                                                    from:self
                                   destinationCompletion:^(UIImage *edited, NSString *destinationTag) {
                                       if (!edited)
                                           return;
                                       [SPKTrimSaveCoordinator routeEditedImage:edited
                                                                  toDestination:(destinationTag ?: @"gallery")
                                                                                metadata:item.galleryMetadata
                                                                      presenter:weakSelf
                                                                     completion:nil];
                                   }];
}

// Re-decodes the item's media straight from disk (bypassing the in-memory /
// cached image, which the edit made stale) and re-displays it in the current
// image page.
- (void)refreshDisplayedImageForItem:(SPKMediaItem *)item {
    if (!item)
        return;
    NSURL *url = item.galleryFile ? [item.galleryFile fileURL] : (item.resolvedFileURL ?: item.fileURL);
    UIImage *fresh = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    if (!fresh)
        return;
    [self syncItemFileURLToGalleryFile:item];
    item.image = fresh;
    UIViewController *currentVC = self.pageViewController.viewControllers.firstObject;
    if ([currentVC isKindOfClass:[SPKFullScreenImageViewController class]] &&
        ((SPKFullScreenImageViewController *)currentVC).mediaItem == item) {
        [(SPKFullScreenImageViewController *)currentVC preloadContent];
    }
}

- (void)saveTrimResultToGallery:(SPKTrimResult *)result
                       fromItem:(SPKMediaItem *)item {
    // When the trimmed video came from the Gallery, the coordinator may offer to
    // replace the original in place; otherwise it saves a new copy.
    __weak typeof(self) weakSelf = self;
    [SPKTrimSaveCoordinator saveResult:result
                            originFile:item.galleryFile
                        fallbackSource:(SPKGallerySource)item.gallerySaveSource
                            folderPath:nil
                             presenter:self
                            completion:^(BOOL didChange) {
                                // A Replace renames the file on disk; resync the item's canonical URL so a
                                // follow-up Trim/Edit doesn't resolve the stale (deleted) original path, and
                                // reload the live player so it stops playing the now-replaced original.
                                if (didChange) {
                                    [weakSelf syncItemFileURLToGalleryFile:item];
                                    [weakSelf refreshDisplayedVideoForItem:item];
                                }
                            }];
}

// Rebuilds the on-screen video/audio player from the item's live Gallery path
// after an in-place Replace (the AVPlayer otherwise keeps the old asset until
// the page is re-prepared). Mirrors refreshDisplayedImageForItem: for stills.
- (void)refreshDisplayedVideoForItem:(SPKMediaItem *)item {
    if (!item.galleryFile)
        return;
    NSURL *url = [item.galleryFile fileURL];
    if (!url)
        return;
    SPKFullScreenVideoViewController *videoVC = [self currentVideoViewController];
    if (videoVC && videoVC.mediaItem == item) {
        [videoVC reloadWithFileURL:url];
    }
}

// After an in-place Gallery Replace the media is renamed on disk, leaving
// item.fileURL pointing at the deleted original. Repoint it at the live gallery
// path so subsequent Edit/Trim/save actions resolve the new file.
- (void)syncItemFileURLToGalleryFile:(SPKMediaItem *)item {
    if (!item.galleryFile)
        return;
    NSURL *url = [item.galleryFile fileURL];
    if (!url)
        return;
    item.fileURL = url;
    item.resolvedFileURL = nil;
}

- (void)updateGalleryOriginButton {
    if (!_galleryOriginItem)
        return;

    SPKGalleryFile *file = self.currentItem.galleryFile;
    BOOL hasOriginal = file.hasOpenableOriginalMedia;
    BOOL hasProfile = file.hasOpenableProfile;
    NSInteger actionCount = (hasOriginal ? 1 : 0) + (hasProfile ? 1 : 0);

    _galleryOriginItemVisible = (file != nil);
    _galleryOriginItem.target = nil;
    _galleryOriginItem.action = nil;

    if (actionCount <= 0) {
        _galleryOriginItem.image = SPKMediaChromeBottomBarIcon(@"more");
        _galleryOriginItem.accessibilityLabel = SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT");
        _galleryOriginItem.enabled = NO;
        _galleryOriginItem.menu = nil;
        [self rebuildBottomToolbarItems];
        return;
    }

    _galleryOriginItem.enabled = YES;

    if (actionCount == 1) {
        NSString *resourceName = hasProfile ? @"user_circle" : @"external_link";
        NSString *label = hasProfile ? SPKL(@"ALERT_ACTION_OPEN_PROFILE") : SPKL(@"ALERT_ACTION_OPEN_ORIGINAL_POST");
        _galleryOriginItem.image = SPKMediaChromeBottomBarIcon(resourceName);
        _galleryOriginItem.accessibilityLabel = label;
        _galleryOriginItem.menu = nil;
        _galleryOriginItem.target = self;
        _galleryOriginItem.action = @selector(performSingleGalleryOriginAction);
        [self rebuildBottomToolbarItems];
        return;
    }

    _galleryOriginItem.image = SPKMediaChromeBottomBarIcon(@"more");
    _galleryOriginItem.accessibilityLabel = SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT");
    _galleryOriginItem.menu = [self galleryOriginMenuForCurrentItem];
    [self rebuildBottomToolbarItems];
}

#pragma mark - Toolbar Toggle

- (void)toggleToolbar {
    _isToolbarVisible = !_isToolbarVisible;
    UINavigationController *navigationController = self.navigationController;
    BOOL visible = _isToolbarVisible;

    navigationController.navigationBar.userInteractionEnabled = visible;
    navigationController.toolbar.userInteractionEnabled = visible;
    [self updateCurrentVideoPlayerControlInsetsAnimated:YES];

    // Expand the media to full-screen when hiding the chrome, or back between the
    // bars when showing it. The inset is decoupled from the safe area (driven by
    // explicit constraint constants), so it animates smoothly in lockstep with
    // the bars below.
    self.chromeToggleInProgress = YES;
    self.currentContentInsets =
        visible ? self.mediaContentBarInsets : UIEdgeInsetsZero;

    // Slide the bars in/out via the navigation controller's own hide transition.
    // This is OS-agnostic: it works identically on every version, including iOS
    // 26's floating glass toolbar (which ignores alpha), so there's no per-OS
    // special-casing. Content resize runs at the matching system bar duration.
    navigationController.navigationBar.alpha = 1.0;
    navigationController.toolbar.alpha = 1.0;
    [navigationController setNavigationBarHidden:!visible animated:YES];
    // Preview mode never has a bottom toolbar; keep it hidden when toggling chrome.
    [navigationController setToolbarHidden:(_previewOnly ? YES : !visible) animated:YES];

    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration
        delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut |
                UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            [self setNeedsStatusBarAppearanceUpdate];
            [navigationController setNeedsStatusBarAppearanceUpdate];
            self.infoOverlay.alpha =
                (visible && !self.liveTextHighlightActive) ? 1.0 : 0.0;
            for (UIViewController *controller in self.pageViewController
                     .viewControllers) {
                [self applyMediaContentBarInsetsToController:controller];
            }
        }
        completion:^(__unused BOOL finished) {
            self.chromeToggleInProgress = NO;
            [self updateCurrentVideoPlayerControlInsetsAnimated:NO];
        }];
}

#pragma mark - Current Item

- (SPKMediaItem *)currentItem {
    return [self itemAtIndex:_currentIndex];
}

- (NSURL *)currentFileURL {
    SPKMediaItem *item = [self currentItem];
    NSURL *bestURL =
        [[SPKMediaCacheManager sharedManager] bestAvailableFileURLForItem:item];
    return bestURL ?: item.fileURL;
}

- (NSURL *)currentOperationURL {
    SPKMediaItem *item = [self currentItem];
    if (item.fileURL && !item.fileURL.isFileURL) {
        return item.fileURL;
    }
    return [self currentFileURL];
}

- (SPKGallerySaveMetadata *)metadataForMediaItem:(SPKMediaItem *)item {
    if (item.galleryMetadata) {
        if (item.sourceMediaObject && !item.galleryMetadata.importPostedDate) {
            NSString *preservedURL = [item.galleryMetadata.sourceMediaURLString copy];
            [SPKGalleryOriginController populateMetadata:item.galleryMetadata
                                               fromMedia:item.sourceMediaObject];
            if (preservedURL.length > 0 && [preservedURL containsString:@"img_index"]) {
                item.galleryMetadata.sourceMediaURLString = preservedURL;
            }
        }
        return item.galleryMetadata;
    }

    if (item.title.length == 0 && item.gallerySaveSource < 0) {
        return nil;
    }

    SPKGallerySaveMetadata *meta = [[SPKGallerySaveMetadata alloc] init];
    SPKGallerySource fallbackSource =
        SPKGallerySourceForPlaybackSource(self.playbackSource);
    meta.source = item.gallerySaveSource >= 0 ? (int16_t)item.gallerySaveSource
                                              : (int16_t)fallbackSource;
    if (item.title.length > 0) {
        meta.sourceUsername = item.title;
    }
    if (item.sourceMediaObject) {
        [SPKGalleryOriginController populateMetadata:meta
                                           fromMedia:item.sourceMediaObject];
    }
    return meta;
}

- (SPKGallerySaveMetadata *)metadataForCurrentItem {
    return [self metadataForMediaItem:[self currentItem]];
}

- (void)showCompletedPillForActionIdentifier:(NSString *)identifier
                                       title:(NSString *)title
                                    subtitle:(NSString *)subtitle
                                completedTap:(void (^)(void))completedTap {
    SPKNotificationPillView *pill = SPKNotifyProgress(identifier, title, nil);
    if (!pill) {
        SPKNotificationTriggerHaptic(identifier, SPKNotificationToneSuccess);
        return;
    }
    [pill setProgress:1.0f animated:NO];
    [pill showSuccessWithTitle:title subtitle:subtitle icon:nil];
    pill.onTapWhenCompleted = completedTap;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(SPKNotificationPillDuration() * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [pill dismiss];
        });
}

// Cleanup of `fileURL` is deliberately not ours, even when the caller just staged it: the
// submission is asynchronous (a duplicate prompt can hold it up indefinitely), and the
// download scheduler consumes a job's local source file and clears it with the job.
- (void)saveLocalFileURLToPhotos:(NSURL *)fileURL {
    if (!fileURL)
        return;

    SPKMediaItem *item = [self currentItem];
    SPKGallerySaveMetadata *meta = [self metadataForCurrentItem];
    NSString *ext =
        fileURL.pathExtension.length
            ? fileURL.pathExtension
            : (item.mediaType == SPKMediaItemTypeVideo ? @"mp4" : @"jpg");
    [SPKDownloadHelpers
        submitLocalFileURL:fileURL
                 extension:ext
               destination:SPKDownloadDestinationPhotos
                  metadata:meta
            notificationID:kSPKNotificationMediaPreviewSavePhotos
                 presenter:self
                anchorView:[self bottomBarAnchorView]
             sourceSurface:SPKDownloadSurfaceForPlaybackSource(
                               self.playbackSource)];
}

#pragma mark - Playback Suppression

- (BOOL)shouldUseLifecycleSuppressingPresentation {
    if (self.isFromGallery) {
        return YES;
    }

    switch (self.playbackSource) {
    case SPKFullScreenPlaybackSourceFeed:
    case SPKFullScreenPlaybackSourceReels:
    case SPKFullScreenPlaybackSourceProfile:
    case SPKFullScreenPlaybackSourceStories:
    case SPKFullScreenPlaybackSourceDirect:
    case SPKFullScreenPlaybackSourceInstants:
        return YES;
    case SPKFullScreenPlaybackSourceUnknown:
    default:
        return NO;
    }
}

- (BOOL)shouldUseExplicitPlaybackCallbacks {
    switch (self.playbackSource) {
    case SPKFullScreenPlaybackSourceStories:
    case SPKFullScreenPlaybackSourceDirect:
    case SPKFullScreenPlaybackSourceInstants:
        return YES;
    case SPKFullScreenPlaybackSourceFeed:
    case SPKFullScreenPlaybackSourceReels:
    case SPKFullScreenPlaybackSourceProfile:
    case SPKFullScreenPlaybackSourceUnknown:
    default:
        return NO;
    }
}

- (void)beginPreviewPlaybackSuppressionIfNeeded {
    if ([self shouldUseExplicitPlaybackCallbacks] && self.pausePlaybackBlock &&
        !self.explicitPlaybackPauseActive) {
        self.pausePlaybackBlock();
        self.explicitPlaybackPauseActive = YES;
    }
}

- (void)restorePreviewPlaybackIfNeeded {
    if (self.explicitPlaybackPauseActive && self.resumePlaybackBlock) {
        self.resumePlaybackBlock();
    }
    self.explicitPlaybackPauseActive = NO;
}

#pragma mark - Actions

- (void)closeTapped {
    UIViewController *dismissTarget = self.navigationController ?: self;
    [dismissTarget
        dismissViewControllerAnimated:YES
                           completion:^{
                               [self cleanupAll];
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   [self restorePreviewPlaybackIfNeeded];
                               });
                               if ([self.delegate
                                       respondsToSelector:@selector(fullScreenMediaPlayerDidDismiss)]) {
                                   [self.delegate fullScreenMediaPlayerDidDismiss];
                               }
                           }];
}

- (void)favoriteTapped {
    SPKMediaItem *item = [self currentItem];
    if (!item.galleryFile)
        return;

    item.galleryFile.isFavorite = !item.galleryFile.isFavorite;
    [[SPKGalleryCoreDataStack shared] saveContext];
    [self updateFavoriteButton];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

// Bulk actions ("Download All") only exist off the gallery -- the gallery grid has
// its own selection mode -- so these walk the eager item list directly. Gallery
// playback leaves `items` nil and builds pages lazily instead (see -itemAtIndex:).
- (NSArray<SPKDownloadItemRequest *> *)bulkDownloadItemsForPreview {
    NSMutableArray<SPKDownloadItemRequest *> *items = [NSMutableArray array];
    NSInteger index = 0;
    for (SPKMediaItem *mediaItem in self.items) {
        SPKDownloadMediaKind kind = (mediaItem.mediaType == SPKMediaItemTypeVideo)
                                        ? SPKDownloadMediaKindVideo
                                        : SPKDownloadMediaKindImage;
        SPKGallerySaveMetadata *metadata = [self metadataForMediaItem:mediaItem];
        if (mediaItem.image && !mediaItem.fileURL) {
            NSString *staged =
                [SPKDownloadHelpers stageImageForDownload:mediaItem.image];
            if (staged) {
                SPKDownloadItemRequest *req = [SPKDownloadItemRequest
                    itemWithLocalPath:staged
                            mediaKind:SPKDownloadMediaKindImage];
                req.preferredFileExtension = @"png";
                req.metadata = metadata;
                req.index = index;
                req.expectedFilenameStem = [[SPKDownloadHelpers
                    preferredFilenameForURL:[NSURL fileURLWithPath:staged]
                                  mediaKind:SPKDownloadMediaKindImage
                                   metadata:metadata]
                    stringByDeletingPathExtension];
                [items addObject:req];
            }
            index++;
            continue;
        }
        NSURL *resolvedURL = [[SPKMediaCacheManager sharedManager]
                                 bestAvailableFileURLForItem:mediaItem]
                                 ?: mediaItem.fileURL;
        if (!resolvedURL) {
            index++;
            continue;
        }
        NSString *extension =
            resolvedURL.pathExtension.length > 0
                ? resolvedURL.pathExtension
                : (kind == SPKDownloadMediaKindVideo ? @"mp4" : @"jpg");
        SPKDownloadItemRequest *req =
            resolvedURL.isFileURL
                ? [SPKDownloadItemRequest itemWithLocalPath:resolvedURL.path
                                                  mediaKind:kind]
                : [SPKDownloadItemRequest itemWithRemoteURL:resolvedURL
                                                  mediaKind:kind];
        req.preferredFileExtension = extension;
        req.metadata = metadata;
        req.index = index;
        req.linkString = mediaItem.fileURL.absoluteString.length
                             ? mediaItem.fileURL.absoluteString
                             : resolvedURL.absoluteString;
        req.expectedFilenameStem = [[SPKDownloadHelpers
            preferredFilenameForURL:resolvedURL
                          mediaKind:kind
                           metadata:metadata]
            stringByDeletingPathExtension];
        [items addObject:req];
        index++;
    }
    return items;
}

- (NSArray<NSString *> *)bulkDownloadLinksForPreview {
    NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
    for (SPKMediaItem *item in self.items) {
        NSString *linkString = item.fileURL.absoluteString;
        if (linkString.length == 0) {
            NSURL *resolvedURL = [[SPKMediaCacheManager sharedManager]
                bestAvailableFileURLForItem:item];
            linkString = resolvedURL.absoluteString;
        }
        if (linkString.length > 0) {
            [links addObject:linkString];
        }
    }
    return links.array;
}

- (void)copyAllDownloadLinks {
    [self copyDownloadLinks:[self bulkDownloadLinksForPreview]];
}

- (void)copyDownloadLinksForItems:(NSArray<SPKDownloadItemRequest *> *)items {
    NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
    for (SPKDownloadItemRequest *req in items) {
        if (req.linkString.length > 0) {
            [links addObject:req.linkString];
        }
    }
    [self copyDownloadLinks:links.array];
}

- (void)copyDownloadLinks:(NSArray<NSString *> *)links {
    if (links.count == 0) {
        SPKNotify(kSPKActionCopyDownloadLink, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_LINKS_AVAILABLE_TEXT"), nil,
                  @"error_filled", SPKNotificationToneError);
        return;
    }

    [UIPasteboard generalPasteboard].string =
        [links componentsJoinedByString:@"\n"];
    SPKNotify(
        kSPKActionCopyDownloadLink,
        SPKCopiedDownloadURLTitleForPlaybackSource(self.playbackSource, YES),
        SPKLP(@"COMMON_ITEM_COUNT", (NSInteger)links.count),
        @"circle_check_filled", SPKNotificationToneSuccess);
}

- (void)copyDownloadURLForCurrentItem {
    SPKMediaItem *item = [self currentItem];
    NSString *linkString = item.fileURL.absoluteString;
    if (linkString.length == 0) {
        NSURL *resolvedURL = [[SPKMediaCacheManager sharedManager]
            bestAvailableFileURLForItem:item];
        linkString = resolvedURL.absoluteString;
    }
    [self copyDownloadLinks:linkString.length > 0 ? @[ linkString ] : @[]];
}

- (UIMenu *)bulkActionsMenu {
    NSArray<SPKDownloadItemRequest *> *bulkItems =
        [self bulkDownloadItemsForPreview];
    if (bulkItems.count < 2)
        return nil;

    SPKActionButtonSource source =
        SPKActionButtonSourceForPlaybackSource(self.playbackSource);
    NSArray<NSString *> *identifiers =
        SPKConfiguredBulkActionIdentifiersForSource(source);
    if (identifiers.count == 0)
        return nil;

    SPKDownloadSourceSurface surface =
        SPKDownloadSurfaceForPlaybackSource(self.playbackSource);
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        NSString *title = SPKActionButtonTitleForIdentifier(identifier);
        UIImage *image = SPKActionButtonMenuIconForIdentifier(identifier, 22.0);
        UIAction *action = [UIAction
            actionWithTitle:title
                      image:image
                 identifier:nil
                    handler:^(__unused UIAction *a) {
                        typeof(self) strongSelf = weakSelf;
                        if (!strongSelf)
                            return;
                        if (![SPKDownloadHelpers
                                performBulkDownloadIdentifier:identifier
                                                        items:bulkItems
                                                    presenter:strongSelf
                                                   anchorView:[strongSelf
                                                                  bottomBarAnchorView]
                                                sourceSurface:surface]) {
                            if ([identifier
                                    isEqualToString:kSPKActionDownloadAllLinks]) {
                                [strongSelf copyAllDownloadLinks];
                            }
                        }
                    }];
        [children addObject:action];
    }

    // Mirror the action-button bulk menu: let the user hand-pick a subset.
    UIAction *selectMediaAction = [UIAction
        actionWithTitle:[NSString stringWithFormat:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_SELECT_MEDIA_VALUE_FORMAT"),
                                                   (unsigned long)bulkItems.count]
                  image:[SPKAssetUtils menuIconNamed:@"carousel"]
             identifier:nil
                handler:^(__unused UIAction *a) {
                    typeof(self) strongSelf = weakSelf;
                    if (strongSelf)
                        [strongSelf presentBulkSelectionForItems:bulkItems
                                                     identifiers:identifiers
                                                   sourceSurface:surface];
                }];
    UIMenu *selectGroup = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:@[ selectMediaAction ]];
    UIMenu *destinationGroup = [UIMenu menuWithTitle:@""
                                               image:nil
                                          identifier:nil
                                             options:UIMenuOptionsDisplayInline
                                            children:children];
    return [UIMenu menuWithTitle:@"" children:@[ destinationGroup, selectGroup ]];
}

- (void)presentBulkSelectionForItems:(NSArray<SPKDownloadItemRequest *> *)bulkItems
                         identifiers:(NSArray<NSString *> *)identifiers
                       sourceSurface:(SPKDownloadSourceSurface)surface {
    // Build the destination buttons and selection thumbnails 1:1 with bulkItems.
    // The picker's bottom toolbar uses a fixed order matching the preview screen's
    // own toolbar (download, share, copy, gallery, url), independent of the user's
    // configured bulk-action order; only the actually-available destinations show.
    NSArray<NSString *> *selectMediaOrder = @[
        kSPKActionDownloadAllLibrary, kSPKActionDownloadAllShare,
        kSPKActionDownloadAllClipboard, kSPKActionDownloadAllGallery,
        kSPKActionDownloadAllLinks
    ];
    NSMutableArray<SPKBulkSelectionDestination *> *destinations =
        [NSMutableArray array];
    for (NSString *identifier in selectMediaOrder) {
        if (![identifiers containsObject:identifier])
            continue;
        [destinations
            addObject:[SPKBulkSelectionDestination
                          destinationWithIdentifier:identifier
                                              title:SPKActionButtonTitleForIdentifier(
                                                        identifier)
                                           iconName:SPKActionDescriptorIconName(
                                                        identifier)]];
    }

    NSMutableArray<SPKBulkSelectionItem *> *selectionItems =
        [NSMutableArray array];
    for (SPKDownloadItemRequest *req in bulkItems) {
        BOOL isVideo = (req.mediaKind == SPKDownloadMediaKindVideo);
        SPKMediaItem *mediaItem = [self itemAtIndex:req.index];
        UIImage *thumb = mediaItem.thumbnail ?: mediaItem.image;
        if (thumb) {
            [selectionItems
                addObject:[SPKBulkSelectionItem itemWithThumbnailImage:thumb
                                                               isVideo:isVideo]];
        } else {
            NSURL *thumbURL = mediaItem.resolvedFileURL ?: mediaItem.fileURL;
            [selectionItems
                addObject:[SPKBulkSelectionItem itemWithThumbnailURL:thumbURL
                                                             isVideo:isVideo]];
        }
    }

    __weak typeof(self) weakSelf = self;
    [SPKBulkMediaSelectionViewController
        presentFromViewController:self
                            items:selectionItems
                     destinations:destinations
                       completion:^(NSIndexSet *selectedIndexes,
                                    NSString *destinationIdentifier) {
                           typeof(self) strongSelf = weakSelf;
                           if (!strongSelf || selectedIndexes.count == 0)
                               return;
                           NSArray<SPKDownloadItemRequest *> *selected =
                               [bulkItems objectsAtIndexes:selectedIndexes];
                           if ([SPKDownloadHelpers
                                   performBulkDownloadIdentifier:destinationIdentifier
                                                           items:selected
                                                       presenter:strongSelf
                                                      anchorView:
                                                          [strongSelf
                                                              bottomBarAnchorView]
                                                   sourceSurface:surface]) {
                               return;
                           }
                           if ([destinationIdentifier
                                   isEqualToString:kSPKActionDownloadAllLinks]) {
                               [strongSelf copyDownloadLinksForItems:selected];
                           }
                       }];
}

- (void)saveToPhotos {
    if ([self handleRemoteOperationWithAction:SPKDownloadDestinationPhotos
                           feedbackIdentifier:
                               kSPKNotificationMediaPreviewSavePhotos]) {
        return;
    }

    NSURL *url = [self currentOperationURL];
    SPKMediaItem *item = [self currentItem];
    if (!url && !item.image)
        return;

    if (url.isFileURL) {
        [self saveLocalFileURLToPhotos:url];
        return;
    }

    if (!url && item.image) {
        NSData *jpegData = UIImageJPEGRepresentation(item.image, 0.85);
        if (jpegData) {
            SPKGallerySaveMetadata *meta = [self metadataForCurrentItem];
            NSString *fileName =
                SPKFileNameForMedia([NSURL fileURLWithPath:@"preview.jpg"],
                                    SPKGalleryMediaTypeImage, meta);
            NSURL *tempURL =
                [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                           stringByAppendingPathComponent:fileName]];
            if ([jpegData writeToURL:tempURL atomically:YES]) {
                [self saveLocalFileURLToPhotos:tempURL];
                return;
            }
        }
        return;
    }

    NSString *ext = url.pathExtension;
    if (ext.length == 0)
        ext = item.mediaType == SPKMediaItemTypeVideo ? @"mp4" : @"jpg";

    [SPKDownloadHelpers
           downloadURL:url
             extension:ext
           destination:SPKDownloadDestinationPhotos
              metadata:[self metadataForCurrentItem]
        notificationID:kSPKNotificationMediaPreviewSavePhotos
             presenter:self
         sourceSurface:SPKDownloadSurfaceForPlaybackSource(self.playbackSource)];
}

- (void)showSaveResult:(BOOL)success error:(NSError *)error {
    if (success) {
        SPKNotify(kSPKNotificationMediaPreviewSavePhotos, SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SAVED_PHOTOS_TEXT"), nil,
                  @"circle_check_filled", SPKNotificationToneSuccess);
    } else {
        SPKNotify(kSPKNotificationMediaPreviewSavePhotos, SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_FAILED_SAVE_TEXT"),
                  error.localizedDescription, @"error_filled",
                  SPKNotificationToneError);
    }
}

// The 4K web candidates are fetched lazily, once per post, by whoever needs them
// first — and the action button only does so for its own download/copy actions.
// A download or copy started from inside the preview reaches
// SPKMediaQualityManager directly, bypassing that fetch, so unless the action
// button happened to fetch them for this post already, "Max" quality would
// silently fall back to the mobile-sized variant. Fetch them here too.
//
// Returns YES when a fetch was started; `retry` re-runs the operation once the
// candidates have landed (or the request failed, which is marked so it is not
// retried on every tap).
- (BOOL)beginFetching4KCandidatesForItem:(SPKMediaItem *)item
                              identifier:(NSString *)identifier
                                   retry:(void (^)(void))retry {
    if (item.mediaType != SPKMediaItemTypeImage)
        return NO;
    if (![SPKUtils getBoolPref:@"downloads_fetch_4k_images"])
        return NO;

    // Same gate the action button applies: the candidates only change the result
    // for quality modes that can pick them.
    NSString *photoQuality = [SPKUtils getStringPref:@"downloads_photo_quality"] ?: @"high";
    if (![photoQuality isEqualToString:@"max"] && ![photoQuality isEqualToString:@"always_ask"])
        return NO;

    // For a carousel child this is the parent post's PK (the metadata is
    // populated from the top-level media), which is what the web media endpoint
    // expects — a child PK does not resolve there.
    NSString *mediaPK = [self metadataForCurrentItem].sourceMediaPK;
    if (mediaPK.length == 0)
        return NO;
    if ([SPKMediaQualityManager hasWebPhotoCandidatesFetchedForPK:mediaPK])
        return NO;

    if (identifier.length > 0 && SPKNotificationIsEnabled(identifier)) {
        [[SPKNotificationCenter shared] beginTransientProgressWithTitle:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_FETCHING_4K_CANDIDATES_TEXT")
                                                               onCancel:nil];
    }
    [SPKInstagramAPI fetchWebMediaInfoForPK:mediaPK
                                 completion:^(NSDictionary *response, NSError *error) {
                                     [SPKMediaQualityManager markWebPhotoCandidatesFetchedForPK:mediaPK];
                                     if (response) {
                                         [SPKMediaQualityManager cacheWebCandidatesFromResponse:response];
                                     }
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         if (retry)
                                             retry();
                                     });
                                 }];
    return YES;
}

- (BOOL)handleRemoteOperationWithAction:(SPKDownloadDestination)destination
                     feedbackIdentifier:(NSString *)feedbackIdentifier {
    SPKMediaItem *item = [self currentItem];
    NSURL *url = [self currentOperationURL];
    if (!item.sourceMediaObject || !item.fileURL || item.fileURL.isFileURL) {
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    if ([self beginFetching4KCandidatesForItem:item
                                    identifier:feedbackIdentifier
                                         retry:^{
                                             [weakSelf handleRemoteOperationWithAction:destination
                                                                    feedbackIdentifier:feedbackIdentifier];
                                         }]) {
        return YES;
    }

    NSURL *sourceURL = item.fileURL ?: url;
    NSURL *photoURL = item.mediaType == SPKMediaItemTypeImage ? sourceURL : nil;
    NSURL *videoURL = item.mediaType == SPKMediaItemTypeVideo ? sourceURL : nil;
    BOOL showProgress = SPKNotificationIsEnabled(feedbackIdentifier);
    return [SPKMediaQualityManager
        handleDownloadDestination:destination
                       identifier:feedbackIdentifier
                        presenter:self
                       sourceView:[self bottomBarAnchorView]
                      mediaObject:item.sourceMediaObject
                         photoURL:photoURL
                         videoURL:videoURL
                  galleryMetadata:[self metadataForCurrentItem]
                     showProgress:showProgress
                    sourceSurface:SPKDownloadSurfaceForPlaybackSource(
                                      self.playbackSource)];
}

- (BOOL)handleRemoteCopyOperation {
    SPKMediaItem *item = [self currentItem];
    if (!item.sourceMediaObject || !item.fileURL || item.fileURL.isFileURL) {
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    if ([self beginFetching4KCandidatesForItem:item
                                    identifier:kSPKNotificationMediaPreviewCopy
                                         retry:^{
                                             [weakSelf handleRemoteCopyOperation];
                                         }]) {
        return YES;
    }

    NSURL *sourceURL = item.fileURL;
    BOOL showProgress =
        SPKNotificationIsEnabled(kSPKNotificationMediaPreviewCopy);
    return [SPKMediaQualityManager
        handleCopyActionWithIdentifier:kSPKNotificationMediaPreviewCopy
                             presenter:self
                            sourceView:[self bottomBarAnchorView]
                           mediaObject:item.sourceMediaObject
                              photoURL:(item.mediaType == SPKMediaItemTypeImage
                                            ? sourceURL
                                            : nil)
                              videoURL:(item.mediaType == SPKMediaItemTypeVideo
                                            ? sourceURL
                                            : nil)
                       galleryMetadata:[self metadataForCurrentItem]
                          showProgress:showProgress
                         sourceSurface:SPKDownloadSurfaceForPlaybackSource(
                                           self.playbackSource)];
}

- (void)saveToGallery {
    if ([self handleRemoteOperationWithAction:SPKDownloadDestinationGallery
                           feedbackIdentifier:
                               kSPKNotificationMediaPreviewSaveGallery]) {
        return;
    }

    NSURL *targetURL = [self currentOperationURL];
    SPKMediaItem *item = [self currentItem];

    if (!targetURL && !item.image) {
        SPKNotify(kSPKNotificationMediaPreviewSaveGallery, SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_NO_MEDIA_SAVE_TEXT"), nil,
                  @"media", SPKNotificationToneError);
        return;
    }

    SPKGalleryMediaType galleryType =
        (item.mediaType == SPKMediaItemTypeVideo && targetURL)
            ? SPKGalleryMediaTypeVideo
            : SPKGalleryMediaTypeImage;

    if (targetURL.isFileURL &&
        [[NSFileManager defaultManager] fileExistsAtPath:targetURL.path]) {
        [self gallerySaveLocalFile:targetURL mediaType:galleryType];
        return;
    } else if (!targetURL && item.image) {
        NSData *jpegData = UIImageJPEGRepresentation(item.image, 0.85);
        if (jpegData) {
            NSString *tempPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:
                    [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"jpg"]];
            NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
            [jpegData writeToURL:tempURL atomically:YES];
            // No delete here: submitting is asynchronous (a duplicate prompt can sit in
            // front of the copy for as long as the user leaves it there), and the download
            // scheduler owns a job's local source file — it consumes it on finalize and
            // clears it when the job leaves history.
            [self gallerySaveLocalFile:tempURL mediaType:SPKGalleryMediaTypeImage];
            return;
        }
    }

    NSString *ext = targetURL.pathExtension;
    if (ext.length == 0)
        ext = galleryType == SPKGalleryMediaTypeVideo ? @"mp4" : @"jpg";

    SPKGallerySaveMetadata *meta = [self metadataForCurrentItem];

    [SPKDownloadHelpers
           downloadURL:targetURL
             extension:ext
           destination:SPKDownloadDestinationGallery
              metadata:meta
        notificationID:kSPKNotificationMediaPreviewSaveGallery
             presenter:self
         sourceSurface:SPKDownloadSurfaceForPlaybackSource(self.playbackSource)];
}

- (void)gallerySaveLocalFile:(NSURL *)localURL
                   mediaType:(SPKGalleryMediaType)galleryType {
    SPKGallerySaveMetadata *meta = [self metadataForCurrentItem];
    NSString *ext =
        localURL.pathExtension.length
            ? localURL.pathExtension
            : (galleryType == SPKGalleryMediaTypeVideo ? @"mp4" : @"jpg");
    [SPKDownloadHelpers
        submitLocalFileURL:localURL
                 extension:ext
               destination:SPKDownloadDestinationGallery
                  metadata:meta
            notificationID:kSPKNotificationMediaPreviewSaveGallery
                 presenter:self
                anchorView:[self bottomBarAnchorView]
             sourceSurface:SPKDownloadSurfaceForPlaybackSource(
                               self.playbackSource)];
}

- (void)shareMedia {
    if ([self
            handleRemoteOperationWithAction:SPKDownloadDestinationShare
                         feedbackIdentifier:kSPKNotificationMediaPreviewShare]) {
        return;
    }

    NSURL *url = [self currentOperationURL];
    SPKMediaItem *item = [self currentItem];
    if (!url && !item.image)
        return;

    if (url.isFileURL || (!url && item.image)) {
        id activityItem = url;
        SPKGallerySaveMetadata *meta = [self metadataForCurrentItem];
        if (url.isFileURL) {
            SPKGalleryMediaType mediaType = (item.mediaType == SPKMediaItemTypeVideo)
                                                ? SPKGalleryMediaTypeVideo
                                                : SPKGalleryMediaTypeImage;
            NSString *fileName = SPKFileNameForMedia(url, mediaType, meta);
            if (![url.lastPathComponent isEqualToString:fileName]) {
                NSURL *targetURL = [NSURL
                    fileURLWithPath:[NSTemporaryDirectory()
                                        stringByAppendingPathComponent:fileName]];
                [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
                if ([[NSFileManager defaultManager] copyItemAtURL:url
                                                            toURL:targetURL
                                                            error:nil]) {
                    activityItem = targetURL;
                }
            }
        } else if (item.image) {
            NSData *jpegData = UIImageJPEGRepresentation(item.image, 0.85);
            NSString *fileName =
                SPKFileNameForMedia([NSURL fileURLWithPath:@"preview.jpg"],
                                    SPKGalleryMediaTypeImage, meta);
            NSURL *targetURL =
                [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                           stringByAppendingPathComponent:fileName]];
            [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
            if (jpegData && [jpegData writeToURL:targetURL atomically:YES]) {
                activityItem = targetURL;
            } else {
                activityItem = item.image;
            }
        }
        SPKNotify(kSPKNotificationMediaPreviewShare, SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_OPENED_SHARE_SHEET_TEXT"), nil,
                  @"share", SPKNotificationToneInfo);
        UIActivityViewController *acVC = [[UIActivityViewController alloc]
            initWithActivityItems:@[ activityItem ]
            applicationActivities:nil];
        if ([UIDevice currentDevice].userInterfaceIdiom ==
            UIUserInterfaceIdiomPad) {
            UIView *anchor = [self bottomBarAnchorView];
            acVC.popoverPresentationController.sourceView = anchor;
            acVC.popoverPresentationController.sourceRect = anchor.bounds;
        }
        [self presentViewController:acVC animated:YES completion:nil];
        return;
    }

    NSString *ext = url.pathExtension;
    if (ext.length == 0)
        ext = item.mediaType == SPKMediaItemTypeVideo ? @"mp4" : @"jpg";

    [SPKDownloadHelpers
           downloadURL:url
             extension:ext
           destination:SPKDownloadDestinationShare
              metadata:[self metadataForCurrentItem]
        notificationID:kSPKNotificationMediaPreviewShare
             presenter:self
         sourceSurface:SPKDownloadSurfaceForPlaybackSource(self.playbackSource)];
}

- (void)copyMedia {
    if ([self handleRemoteCopyOperation]) {
        return;
    }

    SPKMediaItem *item = [self currentItem];
    NSURL *url = [self currentFileURL];
    if (!url && !item.image)
        return;

    if (item.mediaType == SPKMediaItemTypeImage || (!url && item.image)) {
        NSData *imageData = url ? [NSData dataWithContentsOfURL:url] : nil;
        UIImage *image = item.image ?: [UIImage imageWithData:imageData];
        if (image) {
            [[UIPasteboard generalPasteboard] setImage:image];
            SPKNotify(kSPKNotificationMediaPreviewCopy, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_PHOTO_CLIPBOARD_TEXT"),
                      nil, @"circle_check_filled", SPKNotificationToneSuccess);
        }
    } else {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data) {
            [[UIPasteboard generalPasteboard] setData:data
                                    forPasteboardType:@"public.mpeg-4"];
            SPKNotify(kSPKNotificationMediaPreviewCopy, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_VIDEO_CLIPBOARD_TEXT"),
                      nil, @"circle_check_filled", SPKNotificationToneSuccess);
        }
    }
}

- (void)deleteFromGallery {
    SPKMediaItem *item = [self currentItem];
    if (!item.galleryFile)
        return;

    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter
        presentAlertFromViewController:self
                                 title:SPKL(@"GALLERY_GALLERY_DELETE_GALLERY_TEXT")
                               message:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_PERMANENTLY_REMOVE_FILE_TEXT")
                               actions:@[
                                   [SPKIGAlertAction
                                       actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                 style:SPKIGAlertActionStyleCancel
                                               handler:nil],
                                   [SPKIGAlertAction
                                       actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                 style:
                                                     SPKIGAlertActionStyleDestructive
                                               handler:^{
                                                   [weakSelf
                                                       performDeleteCurrentItem];
                                               }],
                               ]];
}

- (void)performDeleteCurrentItem {
    SPKMediaItem *item = [self currentItem];
    if (!item.galleryFile)
        return;

    NSInteger deletedIndex = _currentIndex;
    NSError *err;
    [item.galleryFile removeWithError:&err];
    if (err) {
        SPKNotify(kSPKNotificationMediaPreviewDeleteGallery, SPKL(@"COMMON_DELETE_FAILED_TOAST"),
                  err.localizedDescription, @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    if (_galleryFiles) {
        NSMutableArray *mutableFiles = [_galleryFiles mutableCopy];
        [mutableFiles removeObjectAtIndex:deletedIndex];
        _galleryFiles = [mutableFiles copy];
    } else {
        NSMutableArray *mutableItems = [_items mutableCopy];
        [mutableItems removeObjectAtIndex:deletedIndex];
        _items = [mutableItems copy];
    }
    _isSingleItemMode = ([self itemCount] <= 1);

    if ([self.delegate respondsToSelector:@selector(fullScreenMediaPlayerDidDeleteFileAtIndex:)]) {
        [self.delegate fullScreenMediaPlayerDidDeleteFileAtIndex:deletedIndex];
    }

    if ([self itemCount] == 0) {
        SPKNotify(kSPKNotificationMediaPreviewDeleteGallery,
                  SPKL(@"GALLERY_DELETED_FROM_GALLERY_TOAST"), nil, @"circle_check_filled",
                  SPKNotificationToneSuccess);
        [self closeTapped];
        return;
    }

    for (UIViewController *controller in self.controllerCache.allValues) {
        if ([controller respondsToSelector:@selector(cleanup)]) {
            [(id)controller cleanup];
        }
    }
    [self.controllerCache removeAllObjects];
    // Removing a file shifts every index after it, so the built items no longer
    // line up with their keys -- drop them all and let them rebuild.
    [self.lazyItems removeAllObjects];

    _currentIndex = MIN(deletedIndex, [self itemCount] - 1);
    UIViewController *newVC = [self viewControllerForIndex:_currentIndex];
    if (newVC) {
        [_pageViewController
            setViewControllers:@[ newVC ]
                     direction:UIPageViewControllerNavigationDirectionForward
                      animated:YES
                    completion:nil];
    }
    [self prepareViewControllerForDisplay:newVC];
    [self prepareAdjacentViewControllersAroundIndex:_currentIndex];
    [self updateUI];
    SPKNotify(kSPKNotificationMediaPreviewDeleteGallery, SPKL(@"GALLERY_DELETED_FROM_GALLERY_TOAST"),
              nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

#pragma mark - Swipe to Dismiss

- (void)setupDismissGesture {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handlePanDismiss:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    UIViewController *currentVC = _pageViewController.viewControllers.firstObject;
    if ([self isViewControllerZoomed:currentVC]) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handlePanDismiss:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    CGPoint velocity = [pan velocityInView:self.view];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dismissPanDecided = NO;
        _dismissPanIsVertical = NO;
        _pageScrollView.scrollEnabled = YES;
        return;
    }

    CGFloat tx = translation.x;
    CGFloat ty = translation.y;

    if (!_dismissPanDecided) {
        CGFloat mag = hypot(tx, ty);
        if (mag < kDismissAxisLockSlop) {
            if (pan.state == UIGestureRecognizerStateEnded ||
                pan.state == UIGestureRecognizerStateCancelled) {
                [self resetDismissInteractiveStateAnimated:NO];
            }
            return;
        }
        _dismissPanDecided = YES;
        _dismissPanIsVertical = fabs(ty) >= fabs(tx);
        _pageScrollView.scrollEnabled = !_dismissPanIsVertical;
    }

    if (!_dismissPanIsVertical) {
        if (pan.state == UIGestureRecognizerStateEnded ||
            pan.state == UIGestureRecognizerStateCancelled) {
            [self resetDismissInteractiveStateAnimated:NO];
        }
        return;
    }

    [self beginInteractiveDismissalIfNeeded];
    if (!self.interactiveDismissTransitionContext)
        return;

    CGFloat dy = ty;
    CGFloat absDy = fabs(dy);
    CGFloat maximumBackdropDelta =
        MAX(1.0, CGRectGetHeight(self.view.bounds) / 2.0);
    CGFloat deltaRatio = MIN(1.0, absDy / maximumBackdropDelta);
    CGFloat backdropAlpha =
        1.0 - (deltaRatio * (1.0 - kDismissFinalBackdropAlpha));

    switch (pan.state) {
    case UIGestureRecognizerStateChanged: {
        [self updateInteractiveDismissalWithVerticalDelta:dy
                                            backdropAlpha:backdropAlpha];
        break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: {
        CGFloat dismissDistance =
            kDismissDistanceRatio * CGRectGetHeight(self.view.bounds);
        BOOL commit = pan.state != UIGestureRecognizerStateCancelled &&
                      absDy > dismissDistance;
        if (commit) {
            CGFloat direction = dy >= 0.0 ? 1.0 : -1.0;
            CGFloat finalCenterY = self.interactiveDismissAnchorPoint.y +
                                   direction * CGRectGetHeight(self.view.bounds);
            CGFloat vy = MAX(fabs(velocity.y), kDismissMinimumVelocity);
            CGFloat duration =
                fabs(finalCenterY - _pageViewController.view.center.y) / vy;
            duration = MIN(duration, kDismissMaximumDuration);
            duration = MAX(kDismissMinimumDuration, duration);

            // iOS 26's glass toolbar ignores alpha; hide its platter directly
            // so it doesn't linger over the dismissing content.
            if (@available(iOS 26.0, *)) {
                [self.navigationController setToolbarHidden:YES animated:YES];
            }

            [UIView animateWithDuration:duration
                delay:0
                options:UIViewAnimationOptionCurveEaseOut |
                        UIViewAnimationOptionBeginFromCurrentState
                animations:^{
                    self->_pageViewController.view.center =
                        CGPointMake(self.interactiveDismissAnchorPoint.x, finalCenterY);
                    self.presentationBackdropView.alpha = 0.0;
                    self.navigationController.navigationBar.alpha = 0.0;
                    self.navigationController.toolbar.alpha = 0.0;
                    self.infoOverlay.transform = CGAffineTransformMakeTranslation(
                        0.0, finalCenterY - self.interactiveDismissAnchorPoint.y);
                    self.infoOverlay.alpha = 0.0;
                }
                completion:^(BOOL finished) {
                    [self finishInteractiveDismissal];
                }];
        } else {
            CGFloat duration =
                fabs(velocity.y) * kDismissReturnVelocityAnimationRatio + 0.2;
            [self removeTransitionToViewForCancelledInteractiveDismissalIfNeeded];
            [UIView animateWithDuration:duration
                delay:0
                options:UIViewAnimationOptionCurveEaseOut |
                        UIViewAnimationOptionBeginFromCurrentState
                animations:^{
                    self->_pageViewController.view.center =
                        self.interactiveDismissAnchorPoint;
                    self.presentationBackdropView.alpha = 1.0;
                    CGFloat alpha = self->_isToolbarVisible ? 1.0 : 0.0;
                    self.navigationController.navigationBar.alpha = alpha;
                    self.navigationController.toolbar.alpha = alpha;
                    self.infoOverlay.transform = CGAffineTransformIdentity;
                    self.infoOverlay.alpha = [self infoOverlayVisibleAlpha];
                }
                completion:^(BOOL finished) {
                    UIViewController *currentVC =
                        self->_pageViewController.viewControllers.firstObject;
                    if ([currentVC
                            isKindOfClass:[SPKFullScreenImageViewController class]]) {
                        [(SPKFullScreenImageViewController *)currentVC resetZoomIfNeeded];
                    } else if ([currentVC
                                   isKindOfClass:[SPKFullScreenVideoViewController class]]) {
                        [(SPKFullScreenVideoViewController *)currentVC resetZoomIfNeeded];
                    }
                    [self cancelInteractiveDismissal];
                }];
        }
        _dismissPanDecided = NO;
        _pageScrollView.scrollEnabled = YES;
        break;
    }
    case UIGestureRecognizerStateFailed: {
        if (self.interactiveDismissTransitionContext) {
            [self removeTransitionToViewForCancelledInteractiveDismissalIfNeeded];
            [self cancelInteractiveDismissal];
        } else if (_dismissPanDecided && _dismissPanIsVertical) {
            [self resetDismissInteractiveStateAnimated:YES];
        }
        _dismissPanDecided = NO;
        _dismissPanIsVertical = NO;
        _pageScrollView.scrollEnabled = YES;
        break;
    }
    default:
        break;
    }
}

- (void)resetDismissInteractiveStateAnimated:(BOOL)animated {
    _dismissPanDecided = NO;
    _dismissPanIsVertical = NO;
    _pageScrollView.scrollEnabled = YES;
    void (^animations)(void) = ^{
        self->_pageViewController.view.transform = CGAffineTransformIdentity;
        self->_pageViewController.view.center =
            SPKCenterForBounds(self.view.bounds);
        self.presentationBackdropView.alpha = 1.0;
        CGFloat alpha = self->_isToolbarVisible ? 1.0 : 0.0;
        self.navigationController.navigationBar.alpha = alpha;
        self.navigationController.toolbar.alpha = alpha;
        self.infoOverlay.transform = CGAffineTransformIdentity;
        self.infoOverlay.alpha = [self infoOverlayVisibleAlpha];
    };
    if (animated) {
        [UIView animateWithDuration:0.25 animations:animations];
    } else {
        animations();
    }
}

#pragma mark - Interactive Dismissal Transition

- (void)beginInteractiveDismissalIfNeeded {
    if (self.interactiveDismissalInProgress)
        return;

    self.interactiveDismissalInProgress = YES;
    self.interactiveDismissAnchorPoint = self.pageViewController.view.center;
    UIViewController *dismissTarget = self.navigationController ?: self;
    [dismissTarget dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateInteractiveDismissalWithVerticalDelta:(CGFloat)verticalDelta
                                      backdropAlpha:(CGFloat)backdropAlpha {
    id<UIViewControllerContextTransitioning> transitionContext =
        self.interactiveDismissTransitionContext;
    UIView *fromView =
        [transitionContext viewForKey:UITransitionContextFromViewKey];
    UIView *toView = [transitionContext viewForKey:UITransitionContextToViewKey];

    if (toView && !toView.superview) {
        UIViewController *toViewController = [transitionContext
            viewControllerForKey:UITransitionContextToViewControllerKey];
        toView.frame =
            [transitionContext finalFrameForViewController:toViewController];
        if (![toView isDescendantOfView:transitionContext.containerView]) {
            [transitionContext.containerView addSubview:toView];
        }
        [transitionContext.containerView bringSubviewToFront:fromView ?: self.view];
    }

    self.pageViewController.view.center =
        CGPointMake(self.interactiveDismissAnchorPoint.x,
                    self.interactiveDismissAnchorPoint.y + verticalDelta);
    self.presentationBackdropView.alpha = backdropAlpha;
    CGFloat fade = (self.isToolbarVisible ? 1.0 : 0.0) * backdropAlpha;
    self.navigationController.navigationBar.alpha = MAX(0.0, fade);
    self.navigationController.toolbar.alpha = MAX(0.0, fade);
    // Keep the info overlay attached to the media: translate with it and fade
    // together with the chrome.
    self.infoOverlay.transform = CGAffineTransformMakeTranslation(0.0, verticalDelta);
    self.infoOverlay.alpha = MAX(0.0, fade) * [self infoOverlayVisibleAlpha];
}

- (void)removeTransitionToViewForCancelledInteractiveDismissalIfNeeded {
    id<UIViewControllerContextTransitioning> transitionContext =
        self.interactiveDismissTransitionContext;
    if (transitionContext.presentationStyle != UIModalPresentationFullScreen)
        return;

    UIView *toView = [transitionContext viewForKey:UITransitionContextToViewKey];
    [toView removeFromSuperview];
}

- (void)finishInteractiveDismissal {
    id<UIViewControllerContextTransitioning> transitionContext =
        self.interactiveDismissTransitionContext;
    [transitionContext finishInteractiveTransition];
    [transitionContext
        completeTransition:!transitionContext.transitionWasCancelled];
    self.interactiveDismissTransitionContext = nil;
    self.interactiveDismissalInProgress = NO;

    [self cleanupAll];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restorePreviewPlaybackIfNeeded];
    });
    if ([self.delegate
            respondsToSelector:@selector(fullScreenMediaPlayerDidDismiss)]) {
        [self.delegate fullScreenMediaPlayerDidDismiss];
    }
}

- (void)cancelInteractiveDismissal {
    id<UIViewControllerContextTransitioning> transitionContext =
        self.interactiveDismissTransitionContext;
    [transitionContext cancelInteractiveTransition];
    [transitionContext completeTransition:NO];
    self.interactiveDismissTransitionContext = nil;
    self.interactiveDismissalInProgress = NO;
    self.pageViewController.view.transform = CGAffineTransformIdentity;
    self.pageViewController.view.center = SPKCenterForBounds(self.view.bounds);
    self.infoOverlay.transform = CGAffineTransformIdentity;
    self.infoOverlay.alpha = [self infoOverlayVisibleAlpha];
}

- (id<UIViewControllerAnimatedTransitioning>)
    animationControllerForPresentedController:(UIViewController *)presented
                         presentingController:(UIViewController *)presenting
                             sourceController:(UIViewController *)source {
    self.presentingTransition = YES;
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)
    animationControllerForDismissedController:(UIViewController *)dismissed {
    self.presentingTransition = NO;
    return self;
}

- (id<UIViewControllerInteractiveTransitioning>)
    interactionControllerForDismissal:
        (id<UIViewControllerAnimatedTransitioning>)animator {
    return self.interactiveDismissalInProgress ? self : nil;
}

- (NSTimeInterval)transitionDuration:
    (id<UIViewControllerContextTransitioning>)transitionContext {
    return self.presentingTransition ? kPresentationFadeDuration
                                     : kDismissFadeDuration;
}

- (void)animateTransition:
    (id<UIViewControllerContextTransitioning>)transitionContext {
    if (self.presentingTransition) {
        UIView *toView =
            [transitionContext viewForKey:UITransitionContextToViewKey];
        UIViewController *toViewController = [transitionContext
            viewControllerForKey:UITransitionContextToViewControllerKey];
        toView.frame =
            [transitionContext finalFrameForViewController:toViewController];
        toView.alpha = 0.0;
        [transitionContext.containerView addSubview:toView];

        [UIView animateWithDuration:kPresentationFadeDuration
            delay:0
            options:UIViewAnimationOptionCurveEaseOut
            animations:^{
                toView.alpha = 1.0;
            }
            completion:^(__unused BOOL finished) {
                [transitionContext
                    completeTransition:!transitionContext.transitionWasCancelled];
            }];
        return;
    }

    UIView *fromView =
        [transitionContext viewForKey:UITransitionContextFromViewKey];
    UIView *toView = [transitionContext viewForKey:UITransitionContextToViewKey];

    // Reveal the real screen behind the preview during the tap-X fade. The blind
    // fade (fromView.alpha = 0) faded the whole opaque preview as one unit: under
    // UIModalPresentationFullScreen the presenting screen is no longer in the
    // hierarchy, so it faded through black and snapped. Drop the real screen
    // behind the preview into the transition container, then fade the page
    // content and black backdrop out so the underlying screen is progressively
    // revealed (a cross-fade rather than a black flash) while keeping content in
    // place — no slide.
    if (toView && !toView.superview) {
        UIViewController *toViewController = [transitionContext
            viewControllerForKey:UITransitionContextToViewControllerKey];
        toView.frame =
            [transitionContext finalFrameForViewController:toViewController];
        if (![toView isDescendantOfView:transitionContext.containerView]) {
            [transitionContext.containerView addSubview:toView];
        }
        [transitionContext.containerView bringSubviewToFront:fromView ?: self.view];
    }

    // iOS 26's glass toolbar ignores alpha; hide its platter directly so it
    // doesn't linger over the dismissing content.
    if (@available(iOS 26.0, *)) {
        [self.navigationController setToolbarHidden:YES animated:YES];
    }

    [UIView animateWithDuration:kDismissFadeDuration
        delay:0
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
            self.pageViewController.view.alpha = 0.0;
            self.presentationBackdropView.alpha = 0.0;
            self.navigationController.navigationBar.alpha = 0.0;
            self.navigationController.toolbar.alpha = 0.0;
            self.infoOverlay.alpha = 0.0;
        }
        completion:^(__unused BOOL finished) {
            BOOL completed = !transitionContext.transitionWasCancelled;
            if (!completed) {
                self.pageViewController.view.alpha = 1.0;
                self.presentationBackdropView.alpha = 1.0;
                self.infoOverlay.alpha = [self infoOverlayVisibleAlpha];
                [toView removeFromSuperview];
            }
            [transitionContext completeTransition:completed];
        }];
}

- (void)startInteractiveTransition:
    (id<UIViewControllerContextTransitioning>)transitionContext {
    self.interactiveDismissTransitionContext = transitionContext;
}

#pragma mark - Cleanup

- (void)cleanupAll {
    for (UIViewController *controller in self.controllerCache.allValues) {
        if ([controller respondsToSelector:@selector(cleanup)]) {
            [(id)controller cleanup];
        }
    }
    [self.controllerCache removeAllObjects];
}

@end
