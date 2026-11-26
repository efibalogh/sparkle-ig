#import "SPKVideoCropViewController.h"
#import "SPKStrings.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Crop/SPKCropCanvasView.h"
#import "../Crop/SPKCropControlsView.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKMediaEditorChrome.h"
#import "SPKVideoCropContentView.h"

#import <AVFoundation/AVFoundation.h>

// Width of the controls column when they sit beside the video.
static const CGFloat kSPKVideoCropSideControlsWidth = 300.0;

#pragma mark - Controller

@interface SPKVideoCropViewController () <SPKChipBarDelegate>
@property (nonatomic, copy) NSURL *videoURL;
@property (nonatomic, assign) CGFloat lockedAspectRatio;
@property (nonatomic, copy, nullable) SPKTrimCrop *initialCrop;
@property (nonatomic, copy) void (^completion)(SPKTrimCrop *_Nullable);

@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) SPKCropCanvasView *canvas;
@property (nonatomic, strong) SPKVideoCropContentView *contentView;
@property (nonatomic, strong) SPKCropControlsView *controls;
@property (nonatomic, strong) SPKChipBar *aspectChips;
@property (nonatomic, strong) SPKStraightenRulerView *ruler;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *bottomLayout;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *sideLayout;
@property (nonatomic, assign) BOOL usesSideLayout;
@property (nonatomic, assign) CGSize orientedSize;
@property (nonatomic, assign) NSInteger rotationQuarters;
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, assign) CGFloat straightenDegrees;
@property (nonatomic, strong) UIBarButtonItem *cancelItem;
@property (nonatomic, assign) NSTimeInterval startSeconds;
@property (nonatomic, assign) NSTimeInterval endSeconds; // <= start: the whole clip
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, strong) UIImageView *playOverlay;
@end

@implementation SPKVideoCropViewController

+ (void)presentForVideoURL:(NSURL *)videoURL
         lockedAspectRatio:(CGFloat)lockedAspectRatio
               initialCrop:(SPKTrimCrop *)initialCrop
                     title:(NSString *)title
                      from:(UIViewController *)presenter
                completion:(void (^)(SPKTrimCrop *_Nullable))completion {
    [self presentForVideoURL:videoURL
                startSeconds:0.0
                  endSeconds:0.0
           lockedAspectRatio:lockedAspectRatio
                 initialCrop:initialCrop
                       title:title
                        from:presenter
                  completion:completion];
}

+ (void)presentForVideoURL:(NSURL *)videoURL
              startSeconds:(NSTimeInterval)startSeconds
                endSeconds:(NSTimeInterval)endSeconds
         lockedAspectRatio:(CGFloat)lockedAspectRatio
               initialCrop:(SPKTrimCrop *)initialCrop
                     title:(NSString *)title
                      from:(UIViewController *)presenter
                completion:(void (^)(SPKTrimCrop *_Nullable))completion {
    if (!videoURL || !presenter) {
        SPKLog(@"Crop", @"[Sparkle] crop editor not presented (url=%d presenter=%d)", videoURL != nil, presenter != nil);
        if (completion)
            completion(nil);
        return;
    }
    SPKVideoCropViewController *editor = [[self alloc] init];
    editor.videoURL = videoURL;
    editor.lockedAspectRatio = lockedAspectRatio;
    editor.initialCrop = initialCrop;
    editor.completion = completion;
    editor.startSeconds = MAX(0.0, startSeconds);
    editor.endSeconds = endSeconds;
    editor.title = title.length > 0 ? title : SPKL(@"MEDIA_TRIM_TRIM_EDITOR_CROP_TEXT");
    SPKMediaEditorOpenFromEditor(editor, presenter);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground] ?: [UIColor blackColor];
    _rotationQuarters = self.initialCrop.rotationQuarters;
    _mirrored = self.initialCrop.mirrored;
    _straightenDegrees = self.initialCrop.straightenDegrees;

    [self setupChrome];
    [self setupCanvas];
    [self setupControls];
    [self setupLayouts];
    [self loadAsset];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:NO];
    SPKMediaEditorConfigureCancelItem(self.cancelItem, self);
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    BOOL side = SPKMediaEditorPrefersSideControls(self.traitCollection, self.view.bounds.size);
    if (side == self.usesSideLayout)
        return;
    self.usesSideLayout = side;
    [NSLayoutConstraint deactivateConstraints:side ? self.bottomLayout : self.sideLayout];
    [NSLayoutConstraint activateConstraints:side ? self.sideLayout : self.bottomLayout];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
}

#pragma mark - Setup

- (void)setupChrome {
    UIBarButtonItem *cancelItem = SPKMediaChromeTopBarButtonItem(@"close", self, @selector(cancelTapped));
    cancelItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
    self.cancelItem = cancelItem;
    // Plain and untinted: confirming here returns the framing to the trim
    // editor, whose own Done is the one that commits the edit.
    UIBarButtonItem *doneItem = SPKMediaChromeTopBarButtonItem(@"check", self, @selector(confirmTapped));
    doneItem.accessibilityLabel = SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT");
    self.navigationItem.hidesBackButton = YES;
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ doneItem ]);
}

- (void)setupCanvas {
    _canvas = [[SPKCropCanvasView alloc] initWithFrame:CGRectZero];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.aspectMode = self.lockedAspectRatio > 0.0 ? SPKCropAspectModeLocked : SPKCropAspectModeFreeform;
    _canvas.lockedAspectRatio = self.lockedAspectRatio > 0.0 ? self.lockedAspectRatio : 1.0;
    _canvas.aspect = SPKCropAspectFreeform;
    [self.view addSubview:_canvas];
}

- (void)setupControls {
    _controls = [[SPKCropControlsView alloc] initWithAspectChips:(self.lockedAspectRatio <= 0.0)];
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_controls];
    _aspectChips = _controls.aspectChips;
    _aspectChips.delegate = self;
    _ruler = _controls.ruler;
    _ruler.value = _straightenDegrees;
    [_ruler addTarget:self action:@selector(rulerChanged) forControlEvents:UIControlEventValueChanged];
    [_ruler addTarget:self action:@selector(rulerBegan) forControlEvents:UIControlEventEditingDidBegin];
    [_ruler addTarget:self action:@selector(rulerEnded) forControlEvents:UIControlEventEditingDidEnd];
    // Reopening a straightened crop starts on the ruler, where the edit is.
    if (fabs(_straightenDegrees) >= SPKTrimCropStraightenEpsilon)
        _controls.panel = SPKCropControlsPanelStraighten;

    // Every tool is a glyph in the native toolbar: on iPhone Duo the toolbar
    // becomes a vertical column, which only lays out icon items.
    NSArray<UIBarButtonItem *> *tools = SPKCropMakeToolBarItems(self, @selector(rotateLeftTapped), @selector(flipTapped),
                                                                 @selector(rotateRightTapped));
    UIBarButtonItem *reset = SPKMediaChromeBottomBarButtonItem(@"arrow_ccw", SPKL(@"ALERT_ACTION_RESET"), self, @selector(resetTapped));
    NSMutableArray<NSArray<UIBarButtonItem *> *> *groups = [NSMutableArray array];
    if (_controls.switchItem)
        [groups addObject:@[ _controls.switchItem ]];
    [groups addObject:tools];
    [groups addObject:@[ reset ]];
    self.toolbarItems = SPKMediaChromeBottomToolbarItemsWithGroups(groups);
}

// Under the video on a tall display, in a column beside it on a short or wide
// one (landscape, iPhone Duo).
- (void)setupLayouts {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    ]];
    self.bottomLayout = @[
        [_canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:_controls.topAnchor constant:-8.0],
        [_controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
    ];
    self.sideLayout = @[
        [_canvas.trailingAnchor constraintEqualToAnchor:_controls.leadingAnchor constant:-12.0],
        [_canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [_controls.widthAnchor constraintEqualToConstant:kSPKVideoCropSideControlsWidth],
        [_controls.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    ];
    self.usesSideLayout = SPKMediaEditorPrefersSideControls(self.traitCollection, self.view.bounds.size);
    [NSLayoutConstraint activateConstraints:self.usesSideLayout ? self.sideLayout : self.bottomLayout];
}

#pragma mark - Asset

- (void)loadAsset {
    _asset = [AVURLAsset URLAssetWithURL:self.videoURL options:nil];
    __weak typeof(self) weakSelf = self;
    [_asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                          completionHandler:^{
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  [weakSelf assetTracksLoaded];
                              });
                          }];
}

- (void)assetTracksLoaded {
    NSError *error = nil;
    AVKeyValueStatus status = [self.asset statusOfValueForKey:@"tracks" error:&error];
    AVAssetTrack *videoTrack = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!videoTrack) {
        SPKLog(@"Crop", @"[Sparkle] crop editor closing: no video track (status=%ld err=%@ url=%@)", (long)status,
               error.localizedDescription, self.videoURL.lastPathComponent);
        [self closeWithoutSaving];
        return;
    }
    CGSize rendered = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
    _orientedSize = CGSizeMake(fabs(rendered.width), fabs(rendered.height));
    if (_orientedSize.width <= 0.0 || _orientedSize.height <= 0.0) {
        SPKLog(@"Crop", @"[Sparkle] crop editor closing: bad oriented size %@ (natural %@)",
               NSStringFromCGSize(_orientedSize), NSStringFromCGSize(videoTrack.naturalSize));
        [self closeWithoutSaving];
        return;
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:self.asset];
    // Playback stops at the end of the trimmed range (posting did-play-to-end,
    // which loops it back to the start).
    if (self.endSeconds > self.startSeconds)
        item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(self.endSeconds, 600);
    _player = [AVPlayer playerWithPlayerItem:item];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    // Framing is a silent job, and staying muted keeps us out of the app's audio
    // session entirely (IG is often mid-playback behind this screen).
    _player.muted = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    _contentView = [[SPKVideoCropContentView alloc] initWithPlayer:_player orientedSize:_orientedSize];
    _contentView.rotationQuarters = _rotationQuarters;
    _contentView.mirrored = _mirrored;
    _contentView.straightenDegrees = _straightenDegrees;
    [_canvas setContentView:_contentView contentSize:[self currentContentSize]];
    if (self.initialCrop && !self.initialCrop.isIdentity) {
        [_canvas restoreNormalizedCropRect:self.initialCrop.normalizedRect];
    }
    // Opens paused on the first frame of the clip being kept, which is what
    // the framing is for; a tap on the picture plays it.
    [_player seekToTime:CMTimeMakeWithSeconds(self.startSeconds, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(contentTapped:)];
    [_contentView addGestureRecognizer:tap];
    _contentView.isAccessibilityElement = YES;
    _contentView.accessibilityTraits = UIAccessibilityTraitButton;
    [self updatePlaybackUI];
}

- (CGSize)currentContentSize {
    if (_rotationQuarters % 2 == 1)
        return CGSizeMake(_orientedSize.height, _orientedSize.width);
    return _orientedSize;
}

- (void)playerItemDidReachEnd:(__unused NSNotification *)note {
    [self.player seekToTime:CMTimeMakeWithSeconds(self.startSeconds, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    if (self.playing)
        [self.player play];
}

#pragma mark - Playback

// A tap only fires when the finger lifts without moving, so it never competes
// with panning or pinching the picture, and the grabbers sit outside the
// content with their own drags.
- (void)contentTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded || !self.player)
        return;
    self.playing = !self.playing;
    if (self.playing)
        [self.player play];
    else
        [self.player pause];
    [self updatePlaybackUI];
}

- (BOOL)accessibilityPerformMagicTap {
    [self contentTapped:nil];
    return YES;
}

// The same centred play glyph as the trimmer: shown while paused, gone while
// playing.
- (void)updatePlaybackUI {
    if (!self.playOverlay) {
        self.playOverlay = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"video-play"
                                                                                     pointSize:64.0
                                                                                 renderingMode:UIImageRenderingModeAlwaysOriginal]];
        self.playOverlay.translatesAutoresizingMaskIntoConstraints = NO;
        self.playOverlay.contentMode = UIViewContentModeScaleAspectFit;
        self.playOverlay.userInteractionEnabled = NO;
        self.playOverlay.alpha = 0.0;
        [self.view addSubview:self.playOverlay];
        [NSLayoutConstraint activateConstraints:@[
            [self.playOverlay.centerXAnchor constraintEqualToAnchor:_canvas.centerXAnchor],
            [self.playOverlay.centerYAnchor constraintEqualToAnchor:_canvas.centerYAnchor],
            [self.playOverlay.widthAnchor constraintEqualToConstant:64.0],
            [self.playOverlay.heightAnchor constraintEqualToConstant:64.0],
        ]];
    }
    _contentView.accessibilityLabel = self.playing ? SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PAUSE_TEXT") : SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PLAY_TEXT");
    CGFloat alpha = self.playing ? 0.0 : 1.0;
    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         self.playOverlay.alpha = alpha;
                         self.playOverlay.transform = self.playing ? CGAffineTransformMakeScale(1.15, 1.15) : CGAffineTransformIdentity;
                     }
                     completion:nil];
}

#pragma mark - Straighten

- (void)rulerBegan {
    [_canvas setGridVisible:YES];
}

- (void)rulerChanged {
    _straightenDegrees = _ruler.value;
    _contentView.straightenDegrees = _straightenDegrees;
}

- (void)rulerEnded {
    [_canvas setGridVisible:NO];
}

#pragma mark - Rotate / flip / reset

- (void)rotateLeftTapped {
    [self applyOrientationChange:^{
        self.rotationQuarters = self.rotationQuarters - 1;
    }];
}

- (void)rotateRightTapped {
    [self applyOrientationChange:^{
        self.rotationQuarters = self.rotationQuarters + 1;
    }];
}

- (void)flipTapped {
    [self applyOrientationChange:^{
        self.mirrored = !self.mirrored;
    }];
}

- (void)applyOrientationChange:(void (^)(void))mutate {
    mutate();
    _rotationQuarters = ((_rotationQuarters % 4) + 4) % 4;
    _contentView.rotationQuarters = _rotationQuarters;
    _contentView.mirrored = _mirrored;
    // A quarter turn swaps the frame's axes, so the canvas re-fits its crop around
    // the new dimensions (same contract the photo editor uses after re-baking).
    [_canvas setContentSize:[self currentContentSize]];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)resetTapped {
    _rotationQuarters = 0;
    _mirrored = NO;
    _straightenDegrees = 0.0;
    _ruler.value = 0.0;
    _contentView.rotationQuarters = 0;
    _contentView.mirrored = NO;
    _contentView.straightenDegrees = 0.0;
    if (_aspectChips) {
        _aspectChips.selectedIndex = 0;
        _canvas.aspect = SPKCropAspectFreeform;
    }
    [_canvas setContentSize:[self currentContentSize]];
    [_canvas resetCrop];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

#pragma mark - SPKChipBarDelegate (aspect)

- (void)chipBar:(__unused SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    if (index < 0 || index >= SPKCropAspectPresetCount())
        return;
    _canvas.aspect = SPKCropAspectPresetAtIndex(index);
}

#pragma mark - Confirm / cancel

// Anything different from how the editor opened: the framing it was handed, or
// none.
- (BOOL)hasChanges {
    SPKTrimCrop *initial = self.initialCrop;
    return _canvas.userAdjusted || (_aspectChips && _canvas.aspect != SPKCropAspectFreeform) ||
           _rotationQuarters != initial.rotationQuarters || _mirrored != initial.mirrored ||
           fabs(_straightenDegrees - initial.straightenDegrees) >= SPKTrimCropStraightenEpsilon;
}

- (void)cancelTapped {
    __weak typeof(self) weakSelf = self;
    SPKMediaEditorConfirmDiscard(self, [self hasChanges], ^{
        [weakSelf closeWithoutSaving];
    });
}

- (void)closeWithoutSaving {
    [self.player pause];
    void (^completion)(SPKTrimCrop *) = [self.completion copy];
    self.completion = nil;
    SPKMediaEditorClose(self, ^{
        if (completion)
            completion(nil);
    });
}

- (void)confirmTapped {
    [self.player pause];
    CGRect normalized = _canvas.normalizedCropRect;
    SPKTrimCrop *crop = [SPKTrimCrop cropWithNormalizedRect:normalized
                                          rotationQuarters:_rotationQuarters
                                                  mirrored:_mirrored
                                         straightenDegrees:_straightenDegrees];
    void (^completion)(SPKTrimCrop *) = [self.completion copy];
    self.completion = nil;
    SPKMediaEditorClose(self, ^{
        if (completion)
            completion(crop.isIdentity ? nil : crop);
    });
}

@end
