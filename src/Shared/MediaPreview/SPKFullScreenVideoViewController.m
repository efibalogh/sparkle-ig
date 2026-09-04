#import "SPKStrings.h"
#import "SPKFullScreenVideoViewController.h"
#import "SPKTransformZoomController.h"
#import "../../Utils.h"
#import "../Gallery/SPKGalleryFile.h"
#import "SPKMediaCacheManager.h"
#import "SPKMediaItem.h"
#import <AVFoundation/AVFoundation.h>

// Tag on the audio artwork overlay so we never install it twice.
static NSInteger const kSPKAudioArtworkOverlayTag = 0x5A0D;

static NSTimeInterval const kPlayerControlOverlayInsetAnimationDuration = 0.25;

// Private AVKit SPI (present iOS 16.3 → 26.1, verified via class-dump): lets us
// stop the embedded player from ever entering its own full-screen presentation.
@interface AVPlayerViewController (SPKFullScreenSuppression)
- (void)setAllowsEnteringFullScreen:(BOOL)allowsEnteringFullScreen;
- (void)setEntersFullScreenWhenTapped:(BOOL)entersFullScreenWhenTapped;
@end

@class SPKTransformZoomController;

@interface SPKFullScreenVideoViewController () <AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVPlayerViewController *playerViewController;
@property (nonatomic, strong) SPKTransformZoomController *zoomController;
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UITapGestureRecognizer *singleTapGesture;
@property (nonatomic, strong) NSURL *preparedPlaybackURL;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL hasPreparedPlayer;
@property (nonatomic, assign) BOOL hasStartedPlayback;
@property (nonatomic, assign) BOOL isLoadingThumbnail;
@property (nonatomic, assign) BOOL isObservingPlayerItemStatus;
@property (nonatomic, assign) UIEdgeInsets playerControlOverlayInsets;
@property (nonatomic, strong) NSLayoutConstraint *playerTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *playerBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *thumbnailTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *thumbnailBottomConstraint;
@property (nonatomic, assign) NSInteger loadGeneration;
@property (nonatomic, assign) BOOL lastReportedZoomState;
@property (nonatomic, assign) BOOL wasPlayingBeforeBackground;

@end

@implementation SPKFullScreenVideoViewController

- (instancetype)initWithMediaItem:(SPKMediaItem *)item {
    self = [super init];
    if (self) {
        _mediaItem = item;
        _playerControlOverlayInsets = UIEdgeInsetsZero;
    }
    return self;
}

- (void)dealloc {
    [_zoomController invalidate];
    [self tearDownPlayer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self setupThumbnailView];
    [self setupLoadingIndicator];
    [self setupTapGesture];
    // Add the AVPlayerViewController as a child now, before the appearance cycle,
    // so it gets a proper viewWillAppear/viewDidAppear transition and builds its
    // controls overlay. When it was created lazily in prepareForDisplay (run from
    // viewDidAppear) on the first page, it was added too late and its controls
    // never initialized until a page transition forced an appearance cycle — the
    // player still received taps (center play/pause worked) but the chrome never
    // showed. The player content is assigned later in startPlayback.
    [self ensurePlayerViewControllerIfNeeded];
    [self installAudioArtworkOverlayIfNeeded];
    if (self.mediaItem.thumbnail) {
        self.thumbnailView.image = self.mediaItem.thumbnail;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

// For audio items, AVPlayerViewController shows its generic (QuickTime-looking)
// audio placeholder. Cover the content region with the same crisp white EQ-bar
// artwork the trim editor / gallery use, so expanded audio matches the tweak's
// look. Added to the player's contentOverlayView (above the content, below the
// transport controls, which stay tappable).
- (void)installAudioArtworkOverlayIfNeeded {
    if (self.mediaItem.mediaType != SPKMediaItemTypeAudio)
        return;
    UIView *overlay = self.playerViewController.contentOverlayView;
    if (!overlay || [overlay viewWithTag:kSPKAudioArtworkOverlayTag])
        return;

    UIView *backing = [[UIView alloc] init];
    backing.tag = kSPKAudioArtworkOverlayTag;
    backing.translatesAutoresizingMaskIntoConstraints = NO;
    backing.backgroundColor = [UIColor blackColor];
    backing.userInteractionEnabled = NO;
    [overlay addSubview:backing];

    UIImageView *art = [[UIImageView alloc] initWithImage:[SPKGalleryFile audioGlyphImageWithBarColor:[UIColor whiteColor]]];
    art.translatesAutoresizingMaskIntoConstraints = NO;
    art.contentMode = UIViewContentModeScaleAspectFit;
    [backing addSubview:art];

    [NSLayoutConstraint activateConstraints:@[
        [backing.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [backing.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [backing.topAnchor constraintEqualToAnchor:overlay.topAnchor],
        [backing.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
        [art.centerXAnchor constraintEqualToAnchor:backing.centerXAnchor],
        [art.centerYAnchor constraintEqualToAnchor:backing.centerYAnchor],
        [art.widthAnchor constraintEqualToConstant:150.0],
        [art.heightAnchor constraintEqualToConstant:150.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self prepareForDisplay];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_zoomController layoutZoomHelper];
}

- (UIView *)contentOverlayView {
    return _playerViewController.contentOverlayView;
}

#pragma mark - Setup

- (void)ensurePlayerViewControllerIfNeeded {
    if (_playerViewController)
        return;

    _playerViewController = [[AVPlayerViewController alloc] init];
    _playerViewController.showsPlaybackControls = YES;
    _playerViewController.allowsPictureInPicturePlayback = NO;
    _playerViewController.delegate = self;
    _playerViewController.view.backgroundColor = [UIColor clearColor];

    // Stop AVKit from ever entering its own full-screen presentation. We provide
    // our own chrome (close button + toolbars), and AVKit's full-screen state was
    // being triggered by its expand button and by our partial dismiss-swipe
    // reparenting the player — it then kept its own close (X) on return, leaving
    // two X's. `allowsEnteringFullScreen` is private AVKit SPI confirmed on
    // iOS 16.3–26.1; guarded so it's a no-op if the selector ever goes away.
    if ([_playerViewController respondsToSelector:@selector(setAllowsEnteringFullScreen:)]) {
        [_playerViewController setAllowsEnteringFullScreen:NO];
    }
    if ([_playerViewController respondsToSelector:@selector(setEntersFullScreenWhenTapped:)]) {
        [_playerViewController setEntersFullScreenWhenTapped:NO];
    }

    [self addChildViewController:_playerViewController];
    _playerViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:_playerViewController.view atIndex:0];
    [_playerViewController didMoveToParentViewController:self];
    _playerViewController.additionalSafeAreaInsets = self.playerControlOverlayInsets;

    // Pinned full-bleed by default; the host media player pushes fixed insets
    // (applyMediaContentInsets:) on non-notched devices so the player sits
    // between the bars. Fixed insets mean toggling the chrome fades the bars
    // over stationary content rather than animating a jarring resize.
    _playerTopConstraint =
        [_playerViewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    _playerBottomConstraint =
        [_playerViewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        _playerTopConstraint,
        _playerBottomConstraint,
        [_playerViewController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_playerViewController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    _zoomController = [[SPKTransformZoomController alloc] initWithTargetView:_playerViewController.view containerView:self.view];
    _zoomController.zoomStateChangedBlock = ^(BOOL isZoomed) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf spk_syncControlsForZoomState];
        [strongSelf notifyZoomStateIfChanged];
    };
}

- (void)setupThumbnailView {
    _thumbnailView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbnailView.contentMode = UIViewContentModeScaleAspectFit;
    _thumbnailView.clipsToBounds = YES;
    _thumbnailView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_thumbnailView];

    // Match the player's inset behaviour so the thumbnail (shown until playback
    // starts) lines up with the video.
    _thumbnailTopConstraint =
        [_thumbnailView.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    _thumbnailBottomConstraint =
        [_thumbnailView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        _thumbnailTopConstraint,
        _thumbnailBottomConstraint,
        [_thumbnailView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_thumbnailView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)applyMediaContentInsets:(UIEdgeInsets)insets {
    BOOL changed = NO;
    if (_playerTopConstraint.constant != insets.top ||
        _playerBottomConstraint.constant != -insets.bottom) {
        _playerTopConstraint.constant = insets.top;
        _playerBottomConstraint.constant = -insets.bottom;
        changed = YES;
    }
    if (_thumbnailTopConstraint.constant != insets.top ||
        _thumbnailBottomConstraint.constant != -insets.bottom) {
        _thumbnailTopConstraint.constant = insets.top;
        _thumbnailBottomConstraint.constant = -insets.bottom;
        changed = YES;
    }
    if (changed) {
        [self.view layoutIfNeeded];
    }
}

#pragma mark - Zoom

- (BOOL)isZoomed {
    return [_zoomController isZoomed];
}

- (void)resetZoomIfNeeded {
    [_zoomController resetZoomAnimated:NO];
}

- (void)spk_syncControlsForZoomState {
    BOOL zoomed = [self isZoomed];
    if (_playerViewController.showsPlaybackControls == !zoomed)
        return;
    _playerViewController.showsPlaybackControls = !zoomed;
}

- (void)notifyZoomStateIfChanged {
    BOOL zoomed = [self isZoomed];
    if (zoomed == _lastReportedZoomState)
        return;
    _lastReportedZoomState = zoomed;
    if ([self.delegate respondsToSelector:@selector(mediaContent:didChangeZoomState:)]) {
        [self.delegate mediaContent:self didChangeZoomState:zoomed];
    }
}

- (void)setPlayerControlOverlayInsets:(UIEdgeInsets)insets animated:(BOOL)animated {
    if (UIEdgeInsetsEqualToEdgeInsets(_playerControlOverlayInsets, insets) &&
        (!_playerViewController || UIEdgeInsetsEqualToEdgeInsets(_playerViewController.additionalSafeAreaInsets, insets))) {
        return;
    }

    _playerControlOverlayInsets = insets;
    if (!_playerViewController) {
        return;
    }

    _playerViewController.additionalSafeAreaInsets = insets;

    void (^layout)(void) = ^{
        [self->_playerViewController.view layoutIfNeeded];
    };
    if (animated && self.isViewLoaded && _playerViewController) {
        [UIView animateWithDuration:kPlayerControlOverlayInsetAnimationDuration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:layout
                         completion:nil];
    } else {
        layout();
    }
}

- (void)synchronizePlayerControlsToBottomBoundaryInset:(CGFloat)bottomInset
                                              animated:(BOOL)animated {
    if (!_playerViewController)
        return;

    // additionalSafeAreaInsets is additive. Subtract our previous contribution
    // from AVKit's effective safe area to recover what UIKit currently
    // propagates, then provide only the missing distance to the toolbar. This
    // also removes our inset if a later appearance cycle starts propagating the
    // complete safe area on its own.
    UIEdgeInsets currentAdditional =
        _playerViewController.additionalSafeAreaInsets;
    CGFloat inheritedBottom =
        MAX(0.0, _playerViewController.view.safeAreaInsets.bottom -
                     currentAdditional.bottom);
    UIEdgeInsets required = UIEdgeInsetsZero;
    required.bottom = MAX(0.0, bottomInset - inheritedBottom);
    [self setPlayerControlOverlayInsets:required animated:animated];
}

- (void)setupLoadingIndicator {
    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.color = [UIColor whiteColor];
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)setupTapGesture {
    _singleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    _singleTapGesture.cancelsTouchesInView = NO;
    _singleTapGesture.delegate = self;
    [self.view addGestureRecognizer:_singleTapGesture];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != _singleTapGesture) {
        return YES;
    }

    // Yield touches inside the embedded player to AVKit when unzoomed so its
    // transport controls operate normally. When zoomed, AVKit's controls are hidden,
    // so we handle the tap ourselves to toggle the toolbars.
    if (![self isZoomed] && _playerViewController.isViewLoaded && [touch.view isDescendantOfView:_playerViewController.view]) {
        return NO;
    }

    UIView *view = touch.view;
    while (view) {
        if ([view isKindOfClass:[UIControl class]]) {
            return NO;
        }
        if (view == self.view) {
            break;
        }
        view = view.superview;
    }
    return YES;
}

#pragma mark - Thumbnail

- (void)preloadThumbnailIfNeeded {
    if (self.mediaItem.thumbnail) {
        _thumbnailView.image = self.mediaItem.thumbnail;
        return;
    }
    if (self.isLoadingThumbnail)
        return;

    self.isLoadingThumbnail = YES;
    __weak typeof(self) weakSelf = self;
    [[SPKMediaCacheManager sharedManager] loadThumbnailForVideoItem:self.mediaItem
                                                         completion:^(UIImage *_Nullable thumb) {
                                                             __strong typeof(weakSelf) strongSelf = weakSelf;
                                                             if (!strongSelf)
                                                                 return;

                                                             strongSelf.isLoadingThumbnail = NO;
                                                             if (thumb && !strongSelf.hasStartedPlayback) {
                                                                 strongSelf.thumbnailView.image = thumb;
                                                             }
                                                         }];
}

#pragma mark - Player Preparation

- (void)preparePlayerWithURL:(NSURL *)url {
    if (!url)
        return;
    if (_hasPreparedPlayer && [self.preparedPlaybackURL isEqual:url])
        return;

    [self tearDownPlayer];
    _hasPreparedPlayer = YES;
    self.preparedPlaybackURL = url;
    self.mediaItem.resolvedFileURL = url;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    _playerItem = item;
    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = [SPKUtils getBoolPref:@"feed_expanded_vid_start_muted"];

    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    self.isObservingPlayerItemStatus = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
}

#pragma mark - Preload & Playback

- (void)preloadContent {
    [self preloadThumbnailIfNeeded];
    [[SPKMediaCacheManager sharedManager] prefetchItem:self.mediaItem];
}

- (void)prepareForDisplay {
    [self preloadThumbnailIfNeeded];
    [self ensurePlayerViewControllerIfNeeded];

    NSURL *resolvedURL = [[SPKMediaCacheManager sharedManager] bestAvailableFileURLForItem:self.mediaItem];
    if (_player && _hasPreparedPlayer && resolvedURL && [self.preparedPlaybackURL isEqual:resolvedURL]) {
        [self.loadingIndicator stopAnimating];
        if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
            _thumbnailView.hidden = YES;
            _thumbnailView.alpha = 0.0;
        }
        if (!_isPlaying) {
            [self play];
        }
        return;
    }

    [self.loadingIndicator startAnimating];

    NSInteger generation = self.loadGeneration + 1;
    self.loadGeneration = generation;

    __weak typeof(self) weakSelf = self;
    [[SPKMediaCacheManager sharedManager] fetchLocalFileURLForItem:self.mediaItem
                                                        completion:^(NSURL *_Nullable localURL, NSError *_Nullable error) {
                                                            __strong typeof(weakSelf) strongSelf = weakSelf;
                                                            if (!strongSelf || strongSelf.loadGeneration != generation)
                                                                return;

                                                            if (!localURL || error) {
                                                                [strongSelf.loadingIndicator stopAnimating];
                                                                if ([strongSelf.delegate respondsToSelector:@selector(mediaContent:didFailWithError:)]) {
                                                                    NSError *resolvedError = error ?: [NSError errorWithDomain:@"SPKFullScreenVideoViewController"
                                                                                                                          code:-2
                                                                                                                      userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_PLAYBACK_FAILED_ERROR")}];
                                                                    [strongSelf.delegate mediaContent:strongSelf didFailWithError:resolvedError];
                                                                }
                                                                return;
                                                            }

                                                            if (strongSelf->_player && strongSelf->_hasPreparedPlayer && [strongSelf.preparedPlaybackURL isEqual:localURL]) {
                                                                [strongSelf.loadingIndicator stopAnimating];
                                                                if (strongSelf->_playerItem.status == AVPlayerItemStatusReadyToPlay) {
                                                                    strongSelf->_thumbnailView.hidden = YES;
                                                                    strongSelf->_thumbnailView.alpha = 0.0;
                                                                }
                                                                if (!strongSelf->_isPlaying) {
                                                                    [strongSelf play];
                                                                }
                                                                return;
                                                            }

                                                            [strongSelf preparePlayerWithURL:localURL];
                                                            if (strongSelf->_playerItem && !strongSelf->_hasStartedPlayback) {
                                                                [strongSelf startPlayback];
                                                            } else if (strongSelf->_player && !strongSelf->_isPlaying) {
                                                                [strongSelf play];
                                                            }
                                                        }];
}

- (void)startPlayback {
    if (_hasStartedPlayback)
        return;
    _hasStartedPlayback = YES;

    NSError *audioErr = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&audioErr];
    [session setActive:YES error:&audioErr];

    _playerViewController.player = _player;
    [_player play];
    _isPlaying = YES;

    [self hideThumbnailWhenReady];
}

- (void)hideThumbnailWhenReady {
    if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
        [self doHideThumbnail];
    }
}

- (void)doHideThumbnail {
    [_loadingIndicator stopAnimating];

    if (_thumbnailView.hidden)
        return;

    [UIView animateWithDuration:0.2
        animations:^{
            self->_thumbnailView.alpha = 0;
        }
        completion:^(__unused BOOL finished) {
            self->_thumbnailView.hidden = YES;
        }];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"status"] && object == _playerItem) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_playerItem.status == AVPlayerItemStatusReadyToPlay) {
                [self doHideThumbnail];
            } else if (self->_playerItem.status == AVPlayerItemStatusFailed) {
                [self->_loadingIndicator stopAnimating];
                if ([self.delegate respondsToSelector:@selector(mediaContent:didFailWithError:)]) {
                    NSError *err = self->_playerItem.error ?: [NSError errorWithDomain:@"SPKFullScreenVideoViewController"
                                                                                  code:-1
                                                                              userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_PLAYBACK_FAILED_ERROR")}];
                    [self.delegate mediaContent:self didFailWithError:err];
                }
            }
        });
    }
}

#pragma mark - Notifications

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    _isPlaying = NO;
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    self.wasPlayingBeforeBackground = self.isPlaying;
    [self pause];
}

- (void)appDidBecomeActive:(NSNotification *)notification {
    if (self.wasPlayingBeforeBackground) {
        self.wasPlayingBeforeBackground = NO;
        [self play];
    }
}

#pragma mark - Controls

- (void)handleSingleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded)
        return;
    if ([self.delegate respondsToSelector:@selector(mediaContentDidTap:)]) {
        [self.delegate mediaContentDidTap:self];
    }
}

- (void)play {
    if (_player) {
        [_player play];
        _isPlaying = YES;
        return;
    }
    [self prepareForDisplay];
}

- (void)pause {
    [_player pause];
    _isPlaying = NO;
}

#pragma mark - Cleanup

- (void)tearDownPlayer {
    if (self.playerItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:self.playerItem];
    }
    if (self.isObservingPlayerItemStatus && self.playerItem) {
        [self.playerItem removeObserver:self forKeyPath:@"status" context:nil];
        self.isObservingPlayerItemStatus = NO;
    }

    [_player pause];
    _playerViewController.player = nil;
    _player = nil;
    _playerItem = nil;
    _preparedPlaybackURL = nil;
    _hasPreparedPlayer = NO;
    _hasStartedPlayback = NO;
    _isPlaying = NO;
}

- (void)reloadWithFileURL:(NSURL *)url {
    if (!url)
        return;
    // Bump the load generation first so any in-flight fetch from a prior
    // prepareForDisplay is discarded, then rebuild the player from the new file.
    self.loadGeneration++;
    [self tearDownPlayer];
    self.mediaItem.resolvedFileURL = nil;
    [self preparePlayerWithURL:url];
    [self startPlayback];
}

- (void)cleanup {
    self.loadGeneration++;
    [self tearDownPlayer];
    [_loadingIndicator stopAnimating];
    [_zoomController invalidate];
    [_zoomController resetZoomAnimated:NO];
    _playerViewController.showsPlaybackControls = YES;
    _thumbnailView.hidden = NO;
    _thumbnailView.alpha = 1.0;
    _thumbnailView.image = self.mediaItem.thumbnail;
}

@end
