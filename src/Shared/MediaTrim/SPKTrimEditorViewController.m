#import "SPKStrings.h"
#import "SPKTrimEditorViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../PhotoEdit/SPKPhotoEditorViewController.h"
#import "../UI/SPKChipBar.h"
#import "../UI/SPKMediaChrome.h"
#import "SPKTrimScrubberView.h"
#import "SPKVideoCropContentView.h"
#import "SPKVideoCropViewController.h"

#import <AVFoundation/AVFoundation.h>
#import "../UI/SPKFont.h"

// Player-control glyphs use the host app's own IG assets (video-play-small /
// video-pause) so they match Instagram's player exactly, falling back to known
// ig_icon glyphs if those raster assets are unavailable (see AssetUtils.m).
static UIImage *SPKTrimPlayerIcon(NSString *name, CGFloat pointSize) {
    return [SPKAssetUtils instagramIconNamed:name
                                   pointSize:pointSize
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *SPKTrimFormatTime(NSTimeInterval seconds) {
    if (seconds < 0.0 || !isfinite(seconds))
        seconds = 0.0;
    NSInteger total = (NSInteger)llround(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

@interface SPKTrimEditorViewController () <SPKTrimScrubberViewDelegate, SPKChipBarDelegate>
@property (nonatomic, strong) SPKTrimConfiguration *configuration;
@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) id timeObserver;

@property (nonatomic, strong) UIView *playerContainer;
@property (nonatomic, strong) UIImageView *audioArtworkView;
@property (nonatomic, assign) BOOL waveformLoaded;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *editFrameButton;            // shown in Frame Only mode, in the play/pause slot
@property (nonatomic, strong) UIButton *revertFrameButton;          // shown while an edit is locked in, to discard it
@property (nonatomic, strong) UIImageView *editedFramePreview;      // covers the pane with the edited still
@property (nonatomic, copy, nullable) NSURL *pendingEditedFrameURL; // set once the user edits the current frame
@property (nonatomic, strong) UIView *bottomContent;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) SPKTrimScrubberView *scrubber;
@property (nonatomic, strong) SPKChipBar *modeChips;
@property (nonatomic, copy) NSArray<NSNumber *> *availableModes;
@property (nonatomic, strong) UIBarButtonItem *doneMenuItem;
@property (nonatomic, strong) UIBarButtonItem *cropItem;
@property (nonatomic, strong) UIBarButtonItem *doneItem;
@property (nonatomic, copy, nullable) SPKTrimCrop *pendingCrop; // framing edit carried onto the result
@property (nonatomic, assign) BOOL seedingLockedCrop;          // re-entry guard for the locked-ratio default
@property (nonatomic, strong) UIView *cropPreviewHost;                  // clips the preview to the crop rect
@property (nonatomic, strong) SPKVideoCropContentView *cropPreviewContent;
@property (nonatomic, assign) CGSize orientedSize;

@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL playerReady;
@property (nonatomic, assign) BOOL scrubberInteracting;
@property (nonatomic, assign) BOOL finished;
@end

@implementation SPKTrimEditorViewController

- (instancetype)initWithConfiguration:(SPKTrimConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        self.title = configuration.title.length > 0 ? configuration.title : SPKL(@"ALERT_ACTION_TRIM");
    }
    return self;
}

+ (void)presentWithConfiguration:(SPKTrimConfiguration *)configuration
                            from:(UIViewController *)presenter
                      completion:(void (^)(SPKTrimResult *_Nullable))completion {
    if (!configuration.sourceURL || !presenter) {
        if (completion)
            completion(nil);
        return;
    }
    SPKTrimEditorViewController *editor = [[self alloc] initWithConfiguration:configuration];
    editor.completion = completion;
    // Hosted in a navigation controller so the top bar and bottom toolbar are
    // native components — they render as Liquid Glass on iOS 26 and as standard
    // translucent bars on earlier systems, with no custom material code.
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    // Media editor is always dark (like Photos), so its black background and
    // light controls read correctly regardless of the system appearance — in
    // light mode the label-colored controls would otherwise vanish on black.
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)dealloc {
    if (_timeObserver && _player) {
        [_player removeTimeObserver:_timeObserver];
    }
    // Remove a stashed edit that was never confirmed (ownership is transferred to
    // the result on finish, which nils this out first).
    if (_pendingEditedFrameURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_pendingEditedFrameURL error:NULL];
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground] ?: [UIColor blackColor];

    NSMutableArray<NSNumber *> *modes = [NSMutableArray array];
    if (_configuration.mediaKind == SPKTrimMediaKindVideo) {
        [modes addObject:@(SPKTrimResultModeTrimmedVideo)];
        if (_configuration.allowsFrameOnly) {
            [modes addObject:@(SPKTrimResultModeFrameOnly)];
        }
        // A video can also be cut down to just its audio track — the selected
        // range is exported as an .m4a, discarding the picture (renderer +
        // save/route coordinators already handle SPKTrimResultModeTrimmedAudio).
        // A silent video simply surfaces a render error, mirroring frame only,
        // which likewise doesn't pre-validate the source.
        if (_configuration.allowsAudioOnly) {
            [modes addObject:@(SPKTrimResultModeTrimmedAudio)];
        }
    } else if (_configuration.mediaKind == SPKTrimMediaKindAudio) {
        [modes addObject:@(SPKTrimResultModeTrimmedAudio)];
    }
    _availableModes = [modes copy];

    [self setupChrome];
    [self setupPlayerContainer];
    [self setupBottomContent];
    [self loadAsset];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The mode picker is an in-content chip bar (see setupBottomContent), so the
    // native bottom toolbar stays hidden.
    [self.navigationController setToolbarHidden:YES animated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.playerLayer.frame = self.playerContainer.bounds;
    [self layoutCropPreview];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
}

#pragma mark - Setup

- (void)setupChrome {
    UIBarButtonItem *cancelItem = SPKMediaChromeTopBarButtonItem(@"close", self, @selector(cancelTapped));
    cancelItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");

    // When the caller supplies destinations, Done is a menu (pick where to save
    // without dismissing first); otherwise it's a plain confirm.
    UIBarButtonItem *doneItem;
    if (_configuration.doneOptions.count > 0) {
        // Keep this as a native menu-backed bar item so it participates in the
        // navigation bar's iOS 26 group and fixed-space separator layout.
        doneItem = [[UIBarButtonItem alloc] initWithImage:SPKMediaChromeTopBarIcon(@"check")
                                                    menu:[self buildDoneMenu]];
        doneItem.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
        doneItem.accessibilityLabel = SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT");
        if (@available(iOS 16.0, *)) {
            doneItem.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
        }
        self.doneMenuItem = doneItem;
    } else {
        doneItem = SPKMediaChromeTopBarButtonItemWithStyle(@"check", self, @selector(doneTapped), UIBarButtonItemStyleDone, [SPKUtils SPKColor_InstagramBlue], SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT"));
    }
    self.doneItem = doneItem;
    if (_configuration.mediaKind == SPKTrimMediaKindVideo && _configuration.allowsCrop) {
        // Framing lives on its own screen (like Frame Only's editor) so the trim
        // controls keep the whole bottom of the display.
        self.cropItem = SPKMediaChromeTopBarButtonItem(@"crop", self, @selector(cropTapped));
        self.cropItem.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_CROP_TEXT");
    }
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    [self refreshTrailingTopBarItems];
}

// Crop only has meaning for a trimmed *video*: a single frame is cropped by the
// photo editor behind Edit Frame, and Audio Only has no picture. The button is
// therefore added and removed with the mode, in its own group so iOS 26 renders
// it as a separate glass bubble beside Save rather than merging the two.
- (void)refreshTrailingTopBarItems {
    if (!self.doneItem)
        return;
    BOOL cropApplies = (self.cropItem != nil && [self currentSelectedMode] == SPKTrimResultModeTrimmedVideo);
    if (cropApplies) {
        SPKMediaChromeSetTrailingTopBarItemGroups(self.navigationItem, @[ @[ self.cropItem ], @[ self.doneItem ] ]);
    } else {
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ self.doneItem ]);
    }
}

#pragma mark - Crop

// Opens the framing editor on the source clip. The crop is only recorded here —
// it is applied by the renderer in the same pass as the trim.
- (void)cropTapped {
    [self.player pause];
    self.isPlaying = NO;
    [self updatePlaybackControls];
    __weak typeof(self) weakSelf = self;
    [SPKVideoCropViewController presentForVideoURL:self.configuration.sourceURL
                                 lockedAspectRatio:self.configuration.lockedCropAspectRatio
                                       initialCrop:self.pendingCrop
                                             title:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_CROP_TEXT")
                                              from:self
                                        completion:^(SPKTrimCrop *crop) {
                                            [weakSelf applyCrop:crop];
                                        }];
}

/// With a locked ratio the destination's shape is not negotiable, so start from
/// the largest centred crop at that ratio. Without this, confirming the editor
/// without touching the crop would render the source's own aspect and leave the
/// destination to pad it with black bars.
- (void)seedLockedAspectCropIfNeeded {
    CGFloat ratio = self.configuration.lockedCropAspectRatio;
    if (ratio <= 0.0 || self.pendingCrop || !self.configuration.allowsCrop || self.seedingLockedCrop)
        return;
    CGSize oriented = self.orientedSize;
    if (oriented.width <= 0.0 || oriented.height <= 0.0)
        return;

    CGSize box = (oriented.width / oriented.height > ratio)
                     ? CGSizeMake(oriented.height * ratio, oriented.height)
                     : CGSizeMake(oriented.width, oriented.width / ratio);
    CGRect normalized = CGRectMake((oriented.width - box.width) / 2.0 / oriented.width,
                                   (oriented.height - box.height) / 2.0 / oriented.height,
                                   box.width / oriented.width,
                                   box.height / oriented.height);
    SPKTrimCrop *seed = [SPKTrimCrop cropWithNormalizedRect:normalized rotationQuarters:0 mirrored:NO];
    // A source already at the locked ratio needs no crop at all, and applying an
    // identity one would bounce straight back here through applyCrop:.
    if (seed.isIdentity)
        return;
    self.seedingLockedCrop = YES;
    [self applyCrop:seed];
    self.seedingLockedCrop = NO;
}

- (void)applyCrop:(SPKTrimCrop *)crop {
    self.pendingCrop = (crop && !crop.isIdentity) ? crop : nil;
    // Cancelling the crop editor must not drop a locked ratio back to the
    // source's shape; fall back to the centred default instead of no crop.
    if (!self.pendingCrop && self.configuration.lockedCropAspectRatio > 0.0) {
        [self seedLockedAspectCropIfNeeded];
        return;
    }
    // Tint the button while a crop is active, so the state is legible even when
    // the framing change itself is subtle.
    UIColor *tint = self.pendingCrop ? [SPKUtils SPKColor_InstagramBlue]
                                     : ([SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor]);
    self.cropItem.tintColor = tint;
    UIView *custom = self.cropItem.customView;
    if ([custom isKindOfClass:[UIButton class]]) {
        ((UIButton *)custom).tintColor = tint;
    }
    [self updateCropPreview];
}

// Shows the confirmed framing in the player pane: the pane stops being a plain
// aspect-fit of the source and becomes exactly what the render will produce.
// An AVPlayer drives one AVPlayerLayer at a time, so the player is handed over
// rather than left attached to both layers.
- (void)updateCropPreview {
    SPKTrimCrop *crop = self.pendingCrop;
    BOOL active = (crop != nil && self.orientedSize.width > 0.0 && self.orientedSize.height > 0.0 &&
                   [self currentSelectedMode] == SPKTrimResultModeTrimmedVideo);

    if (!active) {
        self.cropPreviewHost.hidden = YES;
        self.cropPreviewContent.playerLayer.player = nil;
        self.playerLayer.player = self.player;
        self.playerLayer.hidden = ([self currentSelectedMode] == SPKTrimResultModeTrimmedAudio ||
                                   self.configuration.mediaKind == SPKTrimMediaKindAudio);
        return;
    }

    if (!self.cropPreviewHost) {
        self.cropPreviewHost = [[UIView alloc] init];
        self.cropPreviewHost.backgroundColor = [UIColor blackColor];
        self.cropPreviewHost.clipsToBounds = YES;
        [self.playerContainer insertSubview:self.cropPreviewHost atIndex:0];
        self.cropPreviewContent = [[SPKVideoCropContentView alloc] initWithPlayer:nil
                                                                     orientedSize:self.orientedSize];
        [self.cropPreviewHost addSubview:self.cropPreviewContent];
    }
    self.cropPreviewContent.rotationQuarters = crop.rotationQuarters;
    self.cropPreviewContent.mirrored = crop.mirrored;
    self.playerLayer.player = nil;
    self.playerLayer.hidden = YES;
    self.cropPreviewContent.playerLayer.player = self.player;
    self.cropPreviewHost.hidden = NO;
    [self layoutCropPreview];
}

- (void)layoutCropPreview {
    SPKTrimCrop *crop = self.pendingCrop;
    if (!crop || self.cropPreviewHost.hidden)
        return;
    CGRect pane = self.playerContainer.bounds;
    CGRect pixels = [crop pixelRectForOrientedSize:self.orientedSize];
    CGSize rotated = [crop rotatedSizeForOrientedSize:self.orientedSize];
    if (pixels.size.width <= 0.0 || pixels.size.height <= 0.0 ||
        pane.size.width <= 0.0 || pane.size.height <= 0.0) {
        return;
    }

    // Aspect-fit the *cropped* rectangle in the pane, then place the whole
    // rotated picture behind it so the kept region lands exactly on the box.
    CGFloat scale = MIN(pane.size.width / pixels.size.width, pane.size.height / pixels.size.height);
    CGSize box = CGSizeMake(pixels.size.width * scale, pixels.size.height * scale);
    self.cropPreviewHost.frame = CGRectMake(CGRectGetMidX(pane) - box.width / 2.0,
                                            CGRectGetMidY(pane) - box.height / 2.0,
                                            box.width, box.height);
    self.cropPreviewContent.frame = CGRectMake(-pixels.origin.x * scale,
                                               -pixels.origin.y * scale,
                                               rotated.width * scale,
                                               rotated.height * scale);
}

- (void)setupPlayerContainer {
    // Photos-style: the video sits in its own pane between the nav bar and the
    // controls — aspect-fit, on black, with nothing overlaid. Bottom is pinned
    // to the controls in setupBottomContent.
    _playerContainer = [[UIView alloc] init];
    _playerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _playerContainer.backgroundColor = [SPKUtils SPKColor_InstagramBackground] ?: [UIColor blackColor];
    [self.view addSubview:_playerContainer];

    [NSLayoutConstraint activateConstraints:@[
        [_playerContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_playerContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_playerContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // While a frame edit is locked in, this covers the live picture with the
    // edited still so the pane matches what will be saved.
    _editedFramePreview = [[UIImageView alloc] init];
    _editedFramePreview.translatesAutoresizingMaskIntoConstraints = NO;
    _editedFramePreview.contentMode = UIViewContentModeScaleAspectFit;
    _editedFramePreview.backgroundColor = [UIColor blackColor];
    _editedFramePreview.hidden = YES;
    [_playerContainer addSubview:_editedFramePreview];
    [NSLayoutConstraint activateConstraints:@[
        [_editedFramePreview.topAnchor constraintEqualToAnchor:_playerContainer.topAnchor],
        [_editedFramePreview.bottomAnchor constraintEqualToAnchor:_playerContainer.bottomAnchor],
        [_editedFramePreview.leadingAnchor constraintEqualToAnchor:_playerContainer.leadingAnchor],
        [_editedFramePreview.trailingAnchor constraintEqualToAnchor:_playerContainer.trailingAnchor],
    ]];
}

- (void)setupBottomContent {
    _bottomContent = [[UIView alloc] init];
    _bottomContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_bottomContent];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText] ?: [UIColor whiteColor];
    [SPKFont apply:[SPKFont monospacedDigitFontForStyle:SPKFontStyleFootnote weight:UIFontWeightMedium] to:_timeLabel];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    [_bottomContent addSubview:_timeLabel];

    // Play/pause to the left of the filmstrip (Photos-style), not overlaid.
    _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    _playPauseButton.tintColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    [_playPauseButton setImage:SPKTrimPlayerIcon(@"video_play", 36.0) forState:UIControlStateNormal];
    [_playPauseButton addTarget:self action:@selector(togglePlayback) forControlEvents:UIControlEventTouchUpInside];
    _playPauseButton.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PLAY_TEXT");
    [_bottomContent addSubview:_playPauseButton];

    // In Frame Only mode playback is meaningless, so the play/pause slot becomes
    // an Edit button that opens the photo editor on the chosen frame.
    _editFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _editFrameButton.translatesAutoresizingMaskIntoConstraints = NO;
    _editFrameButton.tintColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    [_editFrameButton setImage:SPKTrimPlayerIcon(@"crop", 24.0) forState:UIControlStateNormal];
    [_editFrameButton addTarget:self action:@selector(editFrameTapped) forControlEvents:UIControlEventTouchUpInside];
    _editFrameButton.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_EDIT_FRAME_TEXT");
    _editFrameButton.hidden = YES;
    [_bottomContent addSubview:_editFrameButton];

    // Shown in place of the scrubber once a frame edit is locked in: discards the
    // edit and unlocks frame selection again.
    _revertFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _revertFrameButton.translatesAutoresizingMaskIntoConstraints = NO;
    _revertFrameButton.tintColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    [_revertFrameButton setImage:SPKTrimPlayerIcon(@"arrow_ccw", 24.0) forState:UIControlStateNormal];
    [_revertFrameButton addTarget:self action:@selector(revertFrameTapped) forControlEvents:UIControlEventTouchUpInside];
    _revertFrameButton.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_REVERT_EDIT_TEXT");
    _revertFrameButton.hidden = YES;
    [_bottomContent addSubview:_revertFrameButton];

    _scrubber = [[SPKTrimScrubberView alloc] init];
    _scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    _scrubber.minimumDuration = _configuration.minimumDuration;
    _scrubber.maximumDuration = _configuration.maximumDuration;
    _scrubber.delegate = self;
    [_bottomContent addSubview:_scrubber];

    [NSLayoutConstraint activateConstraints:@[
        [_bottomContent.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                     constant:14.0],
        [_bottomContent.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                      constant:-14.0],
        [_bottomContent.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-8.0],

        [_timeLabel.topAnchor constraintEqualToAnchor:_bottomContent.topAnchor],
        [_timeLabel.centerXAnchor constraintEqualToAnchor:_bottomContent.centerXAnchor],

        [_playPauseButton.leadingAnchor constraintEqualToAnchor:_bottomContent.leadingAnchor],
        [_playPauseButton.centerYAnchor constraintEqualToAnchor:_scrubber.centerYAnchor],
        [_playPauseButton.widthAnchor constraintEqualToConstant:40.0],
        [_playPauseButton.heightAnchor constraintEqualToConstant:40.0],

        [_editFrameButton.leadingAnchor constraintEqualToAnchor:_playPauseButton.leadingAnchor],
        [_editFrameButton.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],
        [_editFrameButton.widthAnchor constraintEqualToAnchor:_playPauseButton.widthAnchor],
        [_editFrameButton.heightAnchor constraintEqualToAnchor:_playPauseButton.heightAnchor],

        [_revertFrameButton.trailingAnchor constraintEqualToAnchor:_bottomContent.trailingAnchor],
        [_revertFrameButton.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],

        [_scrubber.topAnchor constraintEqualToAnchor:_timeLabel.bottomAnchor
                                            constant:10.0],
        [_scrubber.leadingAnchor constraintEqualToAnchor:_playPauseButton.trailingAnchor
                                                constant:10.0],
        [_scrubber.trailingAnchor constraintEqualToAnchor:_bottomContent.trailingAnchor],
        [_scrubber.heightAnchor constraintEqualToConstant:52.0],
        [_scrubber.bottomAnchor constraintEqualToAnchor:_bottomContent.bottomAnchor],
    ]];

    // The mode picker is a chip bar sitting above the controls (replacing the
    // old segmented control). It is only shown when there is more than one mode.
    // The chips fill the width equally and never scroll (distributesToFit), so all
    // modes stay visible even on narrow screens.
    if (self.availableModes.count > 1) {
        _modeChips = [[SPKChipBar alloc] init];
        _modeChips.translatesAutoresizingMaskIntoConstraints = NO;
        _modeChips.delegate = self;
        _modeChips.distributesToFit = YES;
        [self rebuildModeChipItems];
        _modeChips.selectedIndex = 0;
        [self.view addSubview:_modeChips];
        [NSLayoutConstraint activateConstraints:@[
            [_modeChips.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
            [_modeChips.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
            [_modeChips.bottomAnchor constraintEqualToAnchor:_bottomContent.topAnchor
                                                    constant:-4.0],
            // Video pane fills the gap above the mode picker.
            [_playerContainer.bottomAnchor constraintEqualToAnchor:_modeChips.topAnchor
                                                          constant:-4.0],
        ]];
    } else {
        // No mode row: the video pane pins directly above the controls.
        [_playerContainer.bottomAnchor constraintEqualToAnchor:_bottomContent.topAnchor constant:-8.0].active = YES;
    }
}

// (Re)builds the chip titles/icons from `availableModes` — called on setup and
// again if a mode is pruned after the asset loads (e.g. a silent video drops the
// Audio Only chip).
- (void)rebuildModeChipItems {
    if (!_modeChips)
        return;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *symbols = [NSMutableArray array];
    NSMutableArray<NSString *> *selectedSymbols = [NSMutableArray array];
    for (NSNumber *modeNum in self.availableModes) {
        SPKTrimResultMode mode = modeNum.integerValue;
        if (mode == SPKTrimResultModeTrimmedVideo) {
            [titles addObject:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_TRIM_VIDEO_TEXT")];
            [symbols addObject:@"video"];
            [selectedSymbols addObject:@"video_filled"];
        } else if (mode == SPKTrimResultModeFrameOnly) {
            [titles addObject:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FRAME_ONLY_TEXT")];
            [symbols addObject:@"photo"];
            [selectedSymbols addObject:@"photo_filled"];
        } else if (mode == SPKTrimResultModeTrimmedAudio) {
            [titles addObject:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_AUDIO_ONLY_TEXT")];
            [symbols addObject:@"audio"];
            [selectedSymbols addObject:@"audio_filled"];
        }
    }
    [_modeChips setItems:titles symbols:symbols selectedSymbols:selectedSymbols];
}

// Removes the Audio Only mode once the asset is known to have no audio track.
// (Modes are decided synchronously in viewDidLoad, before the async track load,
// so the chip is added optimistically and pruned here if the video is silent.)
- (void)pruneAudioModeIfSilent {
    if (![self.availableModes containsObject:@(SPKTrimResultModeTrimmedAudio)])
        return;
    if ([self.asset tracksWithMediaType:AVMediaTypeAudio].count > 0)
        return;

    NSMutableArray<NSNumber *> *modes = [self.availableModes mutableCopy];
    [modes removeObject:@(SPKTrimResultModeTrimmedAudio)];
    self.availableModes = modes;

    // If the currently-selected chip was after the removed one, clamp it.
    if (_modeChips.selectedIndex >= (NSInteger)modes.count) {
        _modeChips.selectedIndex = 0;
    }
    [self rebuildModeChipItems];
    // Nothing but Trim Video left (only possible when single-frame is disabled):
    // hide the lone chip.
    _modeChips.hidden = (modes.count <= 1);
}

#pragma mark - Asset loading

- (void)loadAsset {
    NSURL *url = _configuration.sourceURL;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    self.asset = asset;

    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[ @"duration", @"tracks" ]
                         completionHandler:^{
                             dispatch_async(dispatch_get_main_queue(), ^{
                                 __strong typeof(weakSelf) strongSelf = weakSelf;
                                 if (!strongSelf)
                                     return;
                                 NSError *err = nil;
                                 AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:&err];
                                 if (status != AVKeyValueStatusLoaded) {
                                     [strongSelf failWithMessage:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FILE_COULD_NOT_OPENED_TRIMMING_TEXT")];
                                     return;
                                 }
                                 [strongSelf configurePlayerAndScrubber];
                             });
                         }];
}

- (void)configurePlayerAndScrubber {
    NSTimeInterval duration = CMTimeGetSeconds(self.asset.duration);
    if (duration <= 0.0 || !isfinite(duration)) {
        [self failWithMessage:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FILE_NO_PLAYABLE_DURATION_TEXT")];
        return;
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:self.asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;

    BOOL isAudio = (self.configuration.mediaKind == SPKTrimMediaKindAudio);
    if (!isAudio) {
        // Video (or a video that can switch to Audio Only): keep the picture in a
        // player layer; the audio artwork/waveform are swapped in on demand.
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.playerLayer.frame = self.playerContainer.bounds;
        [self.playerContainer.layer insertSublayer:self.playerLayer atIndex:0];
    }

    AVAssetTrack *videoTrack = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (videoTrack) {
        CGSize rendered = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        self.orientedSize = CGSizeMake(fabs(rendered.width), fabs(rendered.height));
        [self seedLockedAspectCropIfNeeded];
    }

    self.scrubber.duration = duration;
    // A caller-imposed ceiling (an Instant is capped) pre-selects the first
    // allowed window rather than the whole clip.
    NSTimeInterval initialEnd = duration;
    if (self.configuration.maximumDuration > 0.0) {
        initialEnd = MIN(duration, self.configuration.maximumDuration);
    }
    [self.scrubber setStartTime:0.0 endTime:initialEnd];
    self.scrubber.playheadTime = 0.0;
    if (isAudio) {
        // No video track — audio album-art in the pane + waveform in the scrubber.
        [self setAudioPresentation:YES];
    } else {
        [self.scrubber loadThumbnailsForAsset:self.asset];
    }

    __weak typeof(self) weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 30)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
                                                                 [weakSelf playbackTimeChanged:CMTimeGetSeconds(time)];
                                                             }];

    self.playerReady = YES;
    [self updateTimeLabel];
    [self updatePlaybackControls];
    [self pruneAudioModeIfSilent];
}

// Lazily builds the centered audio "album art" — the gallery's crisp EQ bars,
// drawn in IG's white text color (no gray card) so they read on the editor's
// black pane. Created hidden; shown by -setAudioPresentation:.
- (UIImageView *)ensureAudioArtworkView {
    if (_audioArtworkView)
        return _audioArtworkView;
    // Resolve the dynamic text color against dark (the editor is always dark) so
    // the baked-in bar image is white regardless of the drawing trait collection.
    UIColor *barColor = [[SPKUtils SPKColor_InstagramPrimaryText]
                            resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]]
                            ?: [UIColor whiteColor];
    UIImageView *art = [[UIImageView alloc] initWithImage:[SPKGalleryFile audioGlyphImageWithBarColor:barColor]];
    art.translatesAutoresizingMaskIntoConstraints = NO;
    art.contentMode = UIViewContentModeScaleAspectFit;
    art.hidden = YES;
    [self.playerContainer addSubview:art];
    [NSLayoutConstraint activateConstraints:@[
        [art.centerXAnchor constraintEqualToAnchor:self.playerContainer.centerXAnchor],
        [art.centerYAnchor constraintEqualToAnchor:self.playerContainer.centerYAnchor],
        [art.widthAnchor constraintEqualToConstant:150.0],
        [art.heightAnchor constraintEqualToConstant:150.0],
    ]];
    _audioArtworkView = art;
    return art;
}

// Toggles the pane between the video picture and the audio trimmer look (album
// art + waveform). Used both by pure-audio trims and by a video trim switching
// to the "Audio Only" mode. Playback keeps running from the same AVPlayer — only
// the picture is swapped for the artwork.
- (void)setAudioPresentation:(BOOL)audio {
    self.playerLayer.hidden = audio;
    [self ensureAudioArtworkView].hidden = !audio;
    // The cropped preview is a picture, so it goes away with the rest of the
    // picture; switching back to a video mode restores it (updateCropPreview).
    if (audio) {
        self.cropPreviewHost.hidden = YES;
        self.cropPreviewContent.playerLayer.player = nil;
    } else {
        [self updateCropPreview];
    }
    if (audio) {
        // loadWaveformForAsset: also flips the scrubber into waveform mode.
        if (!self.waveformLoaded) {
            self.waveformLoaded = YES;
            [self.scrubber loadWaveformForAsset:self.asset];
        } else {
            self.scrubber.waveformMode = YES;
        }
    } else {
        self.scrubber.waveformMode = NO;
    }
}

#pragma mark - Playback

- (void)playbackTimeChanged:(NSTimeInterval)t {
    if (self.scrubberInteracting || self.scrubber.isFrameOnlyMode)
        return;
    self.scrubber.playheadTime = t;
    [self updateTimeLabel];
    // Loop within the selected range.
    if (self.isPlaying && t >= self.scrubber.endTime - 0.03) {
        [self seekToTime:self.scrubber.startTime];
    }
}

- (void)togglePlayback {
    if (self.scrubber.isFrameOnlyMode || !self.player)
        return;
    if (self.isPlaying) {
        [self.player pause];
        self.isPlaying = NO;
    } else {
        NSTimeInterval now = CMTimeGetSeconds(self.player.currentTime);
        if (now < self.scrubber.startTime || now >= self.scrubber.endTime - 0.03) {
            [self seekToTime:self.scrubber.startTime];
        }
        [self.player play];
        self.isPlaying = YES;
    }
    [self updatePlaybackControls];
}

// Swaps the play/pause glyph and disables the control in single-frame mode
// (which has no playback).
- (void)updatePlaybackControls {
    BOOL frameOnly = self.scrubber.isFrameOnlyMode;
    // Frame Only swaps the (useless) play/pause for an Edit button.
    self.playPauseButton.hidden = frameOnly;
    self.editFrameButton.hidden = !frameOnly;

    BOOL canPlay = self.playerReady && !frameOnly;
    [self.playPauseButton setImage:SPKTrimPlayerIcon(self.isPlaying ? @"video_pause" : @"video_play", 36.0)
                          forState:UIControlStateNormal];
    self.playPauseButton.accessibilityLabel = self.isPlaying ? SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PAUSE_TEXT") : SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PLAY_TEXT");
    self.playPauseButton.enabled = canPlay;
    self.playPauseButton.alpha = canPlay ? 1.0 : 0.35;
    [self updateFrameEditingUI];
}

// Reflects whether a frame edit is currently locked in: the edited still covers
// the pane and the scrubber is hidden (so the frame can't be nudged away),
// replaced by a Revert button. The Edit button stays available to refine further.
- (void)updateFrameEditingUI {
    BOOL hasEdit = (self.pendingEditedFrameURL != nil);
    self.editedFramePreview.hidden = !hasEdit;
    self.scrubber.hidden = hasEdit;
    self.revertFrameButton.hidden = !hasEdit;
}

- (void)seekToTime:(NSTimeInterval)t {
    CMTime cm = CMTimeMakeWithSeconds(t, 600);
    [self.player seekToTime:cm toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

#pragma mark - Frame editing

// Opens the photo editor on the currently-selected still. The edited image is
// stashed as a pending pre-rendered frame; Done then saves it (via the normal
// destination flow) instead of re-extracting the raw frame.
- (void)editFrameTapped {
    // Refine an existing edit when one is locked in; otherwise start from the raw
    // frame at the current playhead.
    UIImage *frame = self.pendingEditedFrameURL
                         ? [UIImage imageWithContentsOfFile:self.pendingEditedFrameURL.path]
                         : [self extractFrameAtSeconds:self.scrubber.frameTime];
    if (!frame) {
        [self failWithMessage:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_COULDN_T_READ_FRAME_TEXT")];
        return;
    }
    __weak typeof(self) weakSelf = self;
    // The edit comes back here to be saved, so its confirm is not the final one.
    SPKPhotoEditorConfiguration *configuration = [SPKPhotoEditorConfiguration freeformConfiguration];
    configuration.intermediateConfirm = YES;
    [SPKPhotoEditorViewController presentWithSourceImage:frame
                                           configuration:configuration
                                                    from:self
                                              completion:^(UIImage *edited) {
                                                  [weakSelf applyEditedFrame:edited];
                                              }];
}

// Discards the locked-in edit and returns to free frame selection.
- (void)revertFrameTapped {
    [self clearPendingEditedFrame];
    [self seekToTime:self.scrubber.frameTime];
    [self updateTimeLabel];
    [self updateFrameEditingUI];
}

- (UIImage *)extractFrameAtSeconds:(NSTimeInterval)seconds {
    if (!self.asset)
        return nil;
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:self.asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    CMTime time = CMTimeMakeWithSeconds(seconds, 600);
    CGImageRef cg = [generator copyCGImageAtTime:time actualTime:NULL error:NULL];
    if (!cg)
        return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

- (void)applyEditedFrame:(UIImage *)edited {
    NSData *data = edited ? UIImageJPEGRepresentation(edited, 0.85) : nil;
    if (!data)
        return;
    [self clearPendingEditedFrame];
    NSString *name = [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"jpg"];
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    if (![data writeToURL:url options:NSDataWritingAtomic error:NULL])
        return;
    self.pendingEditedFrameURL = url;
    self.editedFramePreview.image = edited;
    [self updateTimeLabel];
    [self updateFrameEditingUI];
}

// Discards a stashed edit (revert, or a mode change) and removes its temp file.
// Not called once the URL is handed to the result.
- (void)clearPendingEditedFrame {
    if (self.pendingEditedFrameURL) {
        [[NSFileManager defaultManager] removeItemAtURL:self.pendingEditedFrameURL error:NULL];
        self.pendingEditedFrameURL = nil;
    }
    self.editedFramePreview.image = nil;
}

#pragma mark - Mode

- (void)chipBar:(SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    [self applyMode:index];
}

- (void)applyMode:(NSInteger)index {
    SPKTrimResultMode mode = SPKTrimResultModeTrimmedVideo;
    if (index >= 0 && index < (NSInteger)self.availableModes.count) {
        mode = self.availableModes[index].integerValue;
    }
    // A stashed frame edit only applies to the frame the user picked; leaving
    // Frame Only (or switching modes) discards it.
    [self clearPendingEditedFrame];
    BOOL frameOnly = (mode == SPKTrimResultModeFrameOnly);
    BOOL audio = (mode == SPKTrimResultModeTrimmedAudio);
    // Audio Only reconfigures a video trim into the audio trimmer (waveform +
    // album art, picture hidden); the other modes restore the video picture. The
    // current selection carries over, so if the user never touches the scrubber
    // the full clip's audio is exported.
    if (self.configuration.mediaKind == SPKTrimMediaKindVideo) {
        [self setAudioPresentation:audio];
    }
    if (frameOnly) {
        [self.player pause];
        self.isPlaying = NO;
        self.scrubber.frameOnlyMode = YES;
        [self seekToTime:self.scrubber.frameTime];
    } else {
        self.scrubber.frameOnlyMode = NO;
        [self seekToTime:self.scrubber.startTime];
    }
    [self updatePlaybackControls];
    [self updateTimeLabel];
    [self refreshDoneMenu];
    [self refreshTrailingTopBarItems];
    [self updateCropPreview];
}

- (void)updateTimeLabel {
    if (self.scrubber.isFrameOnlyMode) {
        NSString *suffix = self.pendingEditedFrameURL ? SPKL(@"MEDIA_TRIM_TRIM_EDITOR_EDITED_TEXT") : @"";
        self.timeLabel.text = [NSString stringWithFormat:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FRAME_VALUE_VALUE_FORMAT"),
                                                         SPKTrimFormatTime(self.scrubber.frameTime), suffix];
        return;
    }
    NSTimeInterval dur = self.scrubber.endTime - self.scrubber.startTime;
    self.timeLabel.text = [NSString stringWithFormat:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_VALUE_VALUE_VALUE_S_FORMAT"),
                                                     SPKTrimFormatTime(self.scrubber.startTime),
                                                     SPKTrimFormatTime(self.scrubber.endTime),
                                                     dur];
}

#pragma mark - SPKTrimScrubberViewDelegate

- (void)trimScrubberDidBeginInteraction:(SPKTrimScrubberView *)scrubber {
    self.scrubberInteracting = YES;
    if (self.isPlaying) {
        [self.player pause];
        self.isPlaying = NO;
        [self updatePlaybackControls];
    }
}

- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didChangeStartTime:(NSTimeInterval)startTime {
    [self seekToTime:startTime];
    [self updateTimeLabel];
}

- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didChangeEndTime:(NSTimeInterval)endTime {
    [self seekToTime:endTime];
    [self updateTimeLabel];
}

- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didScrubToTime:(NSTimeInterval)time {
    [self seekToTime:time];
    [self updateTimeLabel];
}

- (void)trimScrubberDidEndInteraction:(SPKTrimScrubberView *)scrubber {
    self.scrubberInteracting = NO;
}

#pragma mark - Actions

- (void)cancelTapped {
    [self.player pause];
    [self finishWithResult:nil];
}

// Confirming returns the trim parameters and dismisses immediately — the actual
// render runs in the background (with a progress pill) from the caller's save
// coordinator, so the app stays usable and the editor never blocks behind a
// full-screen overlay.
- (UIMenu *)buildDoneMenu {
    // In Audio Only mode the output is an .m4a, which Photos can't hold — swap any
    // "Save to Photos" destination for "Save Audio to Files" so the menu matches what
    // will actually be produced. The menu is rebuilt on mode change (applyMode:).
    BOOL audioMode = ([self currentSelectedMode] == SPKTrimResultModeTrimmedAudio);
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (SPKTrimDoneOption *option in self.configuration.doneOptions) {
        NSString *title = option.title;
        NSString *identifier = option.identifier;
        NSString *iconName = option.iconName;
        if (audioMode) {
            if ([identifier isEqualToString:@"photos"] || [identifier isEqualToString:@"files"]) {
                title = SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES");
                identifier = @"files";
                iconName = @"audio_download";
            } else if ([identifier isEqualToString:@"share"]) {
                title = SPKL(@"ALERT_ACTION_SHARE_AUDIO");
            } else if ([identifier isEqualToString:@"clipboard"]) {
                title = SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_MEDIA_PLAYER_COPY_AUDIO_TEXT");
            } else if ([identifier isEqualToString:@"gallery"]) {
                title = SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY");
            }
        }
        UIImage *image = iconName.length > 0
                             ? [SPKAssetUtils menuIconNamed:iconName]
                             : nil;
        UIAction *action = [UIAction actionWithTitle:title
                                               image:image
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 [weakSelf finishWithDestinationTag:identifier];
                                             }];
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:children];
}

// The mode currently chosen in the chip bar (or the sole/implicit mode).
- (SPKTrimResultMode)currentSelectedMode {
    if (self.availableModes.count > 1) {
        NSInteger i = self.modeChips.selectedIndex;
        if (i >= 0 && i < (NSInteger)self.availableModes.count) {
            return self.availableModes[i].integerValue;
        }
    } else if (self.availableModes.count == 1) {
        return self.availableModes.firstObject.integerValue;
    }
    return (self.configuration.mediaKind == SPKTrimMediaKindAudio)
               ? SPKTrimResultModeTrimmedAudio
               : SPKTrimResultModeTrimmedVideo;
}

// Reassigns the Done menu's button so it reflects the current mode (see
// buildDoneMenu's Photos→Files swap). No-op when Done is a plain confirm button.
- (void)refreshDoneMenu {
    if (self.doneMenuItem)
        self.doneMenuItem.menu = [self buildDoneMenu];
}

- (void)doneTapped {
    [self finishWithDestinationTag:nil];
}

- (void)finishWithDestinationTag:(NSString *)destinationTag {
    [self.player pause];
    self.isPlaying = NO;

    SPKTrimResultMode currentMode = [self currentSelectedMode];

    SPKTrimResult *result;
    if (currentMode == SPKTrimResultModeFrameOnly) {
        result = [SPKTrimResult requestWithMode:SPKTrimResultModeFrameOnly
                                      sourceURL:self.configuration.sourceURL
                                   startSeconds:self.scrubber.frameTime
                                durationSeconds:0.0];
        // If the user edited this frame, hand the pre-rendered edit to the save
        // pipeline (it short-circuits extraction). Transfer ownership so dealloc
        // doesn't delete the file before the coordinator consumes it.
        if (self.pendingEditedFrameURL) {
            result.outputURL = self.pendingEditedFrameURL;
            self.pendingEditedFrameURL = nil;
        }
    } else if (currentMode == SPKTrimResultModeTrimmedAudio) {
        result = [SPKTrimResult requestWithMode:SPKTrimResultModeTrimmedAudio
                                      sourceURL:self.configuration.sourceURL
                                   startSeconds:self.scrubber.startTime
                                durationSeconds:(self.scrubber.endTime - self.scrubber.startTime)];
    } else {
        result = [SPKTrimResult requestWithMode:SPKTrimResultModeTrimmedVideo
                                      sourceURL:self.configuration.sourceURL
                                   startSeconds:self.scrubber.startTime
                                durationSeconds:(self.scrubber.endTime - self.scrubber.startTime)];
        result.crop = self.pendingCrop;
    }
    result.destinationTag = destinationTag;
    [self finishWithResult:result];
}

#pragma mark - Finish

- (void)failWithMessage:(NSString *)message {
    SPKNotify(@"spk.trim.editor", SPKL(@"MEDIA_TRIM_TRIM_EDITOR_TRIM_FAILED_TEXT"), message, @"error_filled", SPKNotificationToneError);
}

- (void)finishWithResult:(SPKTrimResult *)result {
    if (self.finished)
        return;
    self.finished = YES;
    void (^completion)(SPKTrimResult *_Nullable) = self.completion;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (completion)
                                     completion(result);
                             }];
}

@end
