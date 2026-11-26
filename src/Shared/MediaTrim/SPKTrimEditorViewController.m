#import "SPKStrings.h"
#import "SPKTrimEditorViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../PhotoEdit/SPKPhotoEditorViewController.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKMediaEditorChrome.h"
#import "SPKTrimScrubberView.h"
#import "SPKVideoCropContentView.h"
#import "SPKVideoCropViewController.h"

#import <AVFoundation/AVFoundation.h>
#import "../UI/SPKFont.h"

// Liquid Glass button configuration on iOS 26 (looked up at runtime: it is not in
// the build SDK), or nil where it doesn't exist.
static UIButtonConfiguration *SPKTrimGlassButtonConfiguration(void) {
    Class configClass = [UIButtonConfiguration class];
    SEL sel = NSSelectorFromString(@"glassButtonConfiguration");
    if (![configClass respondsToSelector:sel])
        return nil;
    id config = ((id (*)(id, SEL))[configClass methodForSelector:sel])(configClass, sel);
    return [config isKindOfClass:configClass] ? config : nil;
}

// Small control glyphs (frame steps, revert) from Instagram's own catalog.
static UIImage *SPKTrimPlayerIcon(NSString *name, CGFloat pointSize) {
    return [SPKAssetUtils instagramIconNamed:name
                                   pointSize:pointSize
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Minutes, seconds and tenths ("1:04.3"): whole seconds are too coarse to tell
// which frame a handle is on.
static NSString *SPKTrimFormatTime(NSTimeInterval seconds) {
    if (seconds < 0.0 || !isfinite(seconds))
        seconds = 0.0;
    NSInteger tenths = (NSInteger)llround(seconds * 10.0);
    return [NSString stringWithFormat:@"%ld:%02ld.%ld", (long)(tenths / 600), (long)((tenths / 10) % 60), (long)(tenths % 10)];
}

@interface SPKTrimEditorViewController () <SPKTrimScrubberViewDelegate>
@property (nonatomic, strong) SPKTrimConfiguration *configuration;
@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) id timeObserver;

@property (nonatomic, strong) UIView *playerContainer;
@property (nonatomic, strong) UIImageView *audioArtworkView;
@property (nonatomic, strong) UILabel *audioPlayHint;              // "Tap to play" under the artwork while paused
@property (nonatomic, assign) BOOL waveformLoaded;
@property (nonatomic, strong) UIImageView *playOverlay;            // centred play glyph while paused; tap the pane to toggle
@property (nonatomic, strong) UIButton *revertFrameButton;          // shown while an edit is locked in, to discard it
@property (nonatomic, strong) UIImageView *editedFramePreview;      // covers the pane with the edited still
@property (nonatomic, copy, nullable) NSURL *pendingEditedFrameURL; // set once the user edits the current frame
@property (nonatomic, assign) NSTimeInterval editedFrameTime;       // the frame that edit was made from
@property (nonatomic, strong) UIView *bottomContent;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) SPKTrimScrubberView *scrubber;
@property (nonatomic, strong) UIButton *stepBackButton;
@property (nonatomic, strong) UIButton *stepForwardButton;
@property (nonatomic, assign) NSTimeInterval frameDuration; // one video frame, or a tenth of a second for audio
@property (nonatomic, assign) NSInteger selectedModeIndex;
@property (nonatomic, copy) NSArray<NSNumber *> *availableModes;
@property (nonatomic, strong) UIBarButtonItem *doneMenuItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *toolItem; // Crop for a video, Edit Frame for a still
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *modeItems;
@property (nonatomic, strong) UIBarButtonItem *doneItem;
@property (nonatomic, copy, nullable) SPKTrimCrop *pendingCrop; // framing edit carried onto the result
@property (nonatomic, assign) BOOL seedingLockedCrop;          // re-entry guard for the locked-ratio default
@property (nonatomic, assign) BOOL userCropped;                // a crop came from the crop editor, not the default
@property (nonatomic, assign) NSTimeInterval initialEndTime;   // where the selection started out, for change tracking
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
    // Native top bar and toolbar: Liquid Glass on iOS 26, moved into the side
    // column on iPhone Duo, standard translucent bars on earlier systems.
    SPKMediaEditorPresent(editor, presenter);
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
    _frameDuration = 0.1;

    [self setupChrome];
    [self setupPlayerContainer];
    [self setupBottomContent];
    [self loadAsset];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Modes and tools live in the native toolbar; a single-mode trim with no
    // tool has nothing to put there.
    [self.navigationController setToolbarHidden:(self.toolbarItems.count == 0) animated:NO];
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
    // One tool slot for every mode: Crop for a video, Edit Frame (the photo
    // editor on the chosen frame) for a still, disabled for audio. It never
    // leaves the toolbar, so switching modes doesn't reflow it.
    if ([self canCropVideo] || [self.availableModes containsObject:@(SPKTrimResultModeFrameOnly)]) {
        self.toolItem = SPKMediaChromeBottomBarButtonItem(@"crop", SPKL(@"MEDIA_TRIM_TRIM_EDITOR_CROP_TEXT"), self, @selector(toolItemTapped));
    }
    self.navigationItem.hidesBackButton = YES;
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ doneItem ]);
    [self rebuildModeToolbarItems];
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
                                      startSeconds:self.scrubber.startTime
                                        endSeconds:self.scrubber.endTime
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
    if (!self.seedingLockedCrop)
        self.userCropped = (crop != nil && !crop.isIdentity);
    self.pendingCrop = (crop && !crop.isIdentity) ? crop : nil;
    // Cancelling the crop editor must not drop a locked ratio back to the
    // source's shape; fall back to the centred default instead of no crop.
    if (!self.pendingCrop && self.configuration.lockedCropAspectRatio > 0.0) {
        [self seedLockedAspectCropIfNeeded];
        return;
    }
    [self refreshToolItemTints];
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
    self.cropPreviewContent.straightenDegrees = crop.straightenDegrees;
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
        // The safe area, like the filmstrip below, so the picture centres over
        // the strip rather than the whole display (on iPhone Duo the side
        // column takes the trailing edge).
        [_playerContainer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_playerContainer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
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

    // Tapping the picture plays and pauses it, like Instagram's own player, so
    // the filmstrip keeps the full width.
    _playOverlay = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"video-play"
                                                                             pointSize:64.0
                                                                         renderingMode:UIImageRenderingModeAlwaysOriginal]];
    _playOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _playOverlay.contentMode = UIViewContentModeScaleAspectFit;
    _playOverlay.alpha = 0.0;
    _playOverlay.isAccessibilityElement = NO;
    [_playerContainer addSubview:_playOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [_playOverlay.centerXAnchor constraintEqualToAnchor:_playerContainer.centerXAnchor],
        [_playOverlay.centerYAnchor constraintEqualToAnchor:_playerContainer.centerYAnchor],
        [_playOverlay.widthAnchor constraintEqualToConstant:64.0],
        [_playOverlay.heightAnchor constraintEqualToConstant:64.0],
    ]];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(playerPaneTapped:)];
    [_playerContainer addGestureRecognizer:tap];
    _playerContainer.accessibilityTraits = UIAccessibilityTraitButton;
}

- (BOOL)accessibilityPerformMagicTap {
    [self togglePlayback];
    return YES;
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

    // Shown in place of the scrubber once a frame edit is locked in: discards the
    // edit and unlocks frame selection again.
    // A labelled capsule over the dimmed, locked filmstrip: the one thing to do
    // with the strip while an edit pins the frame.
    UIButtonConfiguration *revertConfig = SPKTrimGlassButtonConfiguration() ?: [UIButtonConfiguration grayButtonConfiguration];
    revertConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    revertConfig.image = SPKTrimPlayerIcon(@"arrow_ccw", 18.0);
    revertConfig.imagePadding = 6.0;
    revertConfig.contentInsets = NSDirectionalEdgeInsetsMake(9.0, 14.0, 9.0, 16.0);
    revertConfig.baseForegroundColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    revertConfig.attributedTitle = [[NSAttributedString alloc]
        initWithString:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_REVERT_EDIT_TEXT")
            attributes:@{NSFontAttributeName : [SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightSemibold]}];
    _revertFrameButton = [UIButton buttonWithConfiguration:revertConfig primaryAction:nil];
    _revertFrameButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_revertFrameButton addTarget:self action:@selector(revertFrameTapped) forControlEvents:UIControlEventTouchUpInside];
    _revertFrameButton.hidden = YES;

    // Frame steps either side of the time readout. They move whatever was
    // dragged last, so a handle can be placed on an exact frame.
    _stepBackButton = [self makeStepButtonWithIcon:@"ig_icon_chevron_left_outline_24"
                                             label:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PREVIOUS_FRAME_ACCESSIBILITY_LABEL")
                                            action:@selector(stepBackTapped)];
    [_bottomContent addSubview:_stepBackButton];
    // The 24pt outline pair by catalog name: the shared "chevron_right" entry
    // prefers the small filled disclosure chevron used in lists.
    _stepForwardButton = [self makeStepButtonWithIcon:@"ig_icon_chevron_right_outline_24"
                                                label:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_NEXT_FRAME_ACCESSIBILITY_LABEL")
                                               action:@selector(stepForwardTapped)];
    [_bottomContent addSubview:_stepForwardButton];

    _scrubber = [[SPKTrimScrubberView alloc] init];
    _scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    _scrubber.minimumDuration = _configuration.minimumDuration;
    _scrubber.maximumDuration = _configuration.maximumDuration;
    _scrubber.delegate = self;
    [_bottomContent addSubview:_scrubber];
    [_bottomContent addSubview:_revertFrameButton];

    [NSLayoutConstraint activateConstraints:@[
        [_bottomContent.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                     constant:14.0],
        [_bottomContent.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                      constant:-14.0],
        [_bottomContent.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-8.0],

        [_timeLabel.centerYAnchor constraintEqualToAnchor:_stepBackButton.centerYAnchor],
        [_timeLabel.centerXAnchor constraintEqualToAnchor:_scrubber.centerXAnchor],

        [_stepBackButton.topAnchor constraintEqualToAnchor:_bottomContent.topAnchor],
        [_stepBackButton.trailingAnchor constraintEqualToAnchor:_timeLabel.leadingAnchor constant:-12.0],
        [_stepBackButton.widthAnchor constraintEqualToConstant:36.0],
        [_stepBackButton.heightAnchor constraintEqualToConstant:32.0],
        [_stepForwardButton.leadingAnchor constraintEqualToAnchor:_timeLabel.trailingAnchor constant:12.0],
        [_stepForwardButton.centerYAnchor constraintEqualToAnchor:_stepBackButton.centerYAnchor],
        [_stepForwardButton.widthAnchor constraintEqualToConstant:36.0],
        [_stepForwardButton.heightAnchor constraintEqualToConstant:32.0],

        [_revertFrameButton.centerXAnchor constraintEqualToAnchor:_scrubber.centerXAnchor],
        [_revertFrameButton.centerYAnchor constraintEqualToAnchor:_scrubber.centerYAnchor],

        // Room above the track for the time bubble over a moving handle.
        [_scrubber.topAnchor constraintEqualToAnchor:_stepBackButton.bottomAnchor
                                            constant:14.0],
        [_scrubber.leadingAnchor constraintEqualToAnchor:_bottomContent.leadingAnchor],
        [_scrubber.trailingAnchor constraintEqualToAnchor:_bottomContent.trailingAnchor],
        [_scrubber.heightAnchor constraintEqualToConstant:52.0],
        [_scrubber.bottomAnchor constraintEqualToAnchor:_bottomContent.bottomAnchor],
    ]];

    // The video pane fills everything above the controls.
    [_playerContainer.bottomAnchor constraintEqualToAnchor:_bottomContent.topAnchor constant:-8.0].active = YES;
}

- (UIButton *)makeStepButtonWithIcon:(NSString *)icon label:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    [button setImage:SPKTrimPlayerIcon(icon, 20.0) forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// (Re)builds the native toolbar: the mode switch from `availableModes`, then
// the tool slot. Called on setup and again if a mode is pruned after the asset
// loads (a silent video drops Audio Only); a mode change only restyles the
// items (refreshToolbarStateAnimated:), so the toolbar never reflows.
- (void)rebuildModeToolbarItems {
    NSMutableArray<NSArray<UIBarButtonItem *> *> *groups = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *modeItems = [NSMutableArray array];
    if (self.availableModes.count > 1) {
        for (NSUInteger i = 0; i < self.availableModes.count; i++) {
            SPKTrimResultMode mode = self.availableModes[i].integerValue;
            NSString *icon = @"video";
            if (mode == SPKTrimResultModeFrameOnly)
                icon = @"photo";
            else if (mode == SPKTrimResultModeTrimmedAudio)
                icon = @"audio";
            UIBarButtonItem *item = SPKMediaChromeBottomBarButtonItem(icon, [self titleForMode:mode], self, @selector(modeItemTapped:));
            item.tag = (NSInteger)i;
            [modeItems addObject:item];
        }
        [groups addObject:modeItems];
    }
    self.modeItems = modeItems;
    if (self.toolItem)
        [groups addObject:@[ self.toolItem ]];
    [self refreshToolbarStateAnimated:NO];
    self.toolbarItems = groups.count > 0 ? SPKMediaChromeBottomToolbarItemsWithGroups(groups) : nil;
    if (self.isViewLoaded && self.view.window)
        [self.navigationController setToolbarHidden:(groups.count == 0) animated:NO];
    [self refreshModeTitle];
}

- (BOOL)canCropVideo {
    return self.configuration.mediaKind == SPKTrimMediaKindVideo && self.configuration.allowsCrop;
}

// The selected mode in blue, and the tool slot set up for it.
- (void)refreshToolbarStateAnimated:(BOOL)animated {
    void (^changes)(void) = ^{
        for (UIBarButtonItem *item in self.modeItems) {
            SPKMediaEditorSetSwitchItemSelected(item, item.tag == self.selectedModeIndex);
        }
        [self refreshToolItemTints];
    };
    UIView *toolbar = self.navigationController.toolbar;
    if (!animated || !toolbar) {
        changes();
        return;
    }
    [UIView transitionWithView:toolbar
                      duration:0.2
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:changes
                    completion:nil];
}

- (void)toolItemTapped {
    switch ([self currentSelectedMode]) {
    case SPKTrimResultModeTrimmedVideo:
        [self cropTapped];
        break;
    case SPKTrimResultModeFrameOnly:
        [self editFrameTapped];
        break;
    case SPKTrimResultModeTrimmedAudio:
        break;
    }
}

// Crop only has meaning for a trimmed *video*: a single frame is edited in the
// photo editor behind Edit Frame, and Audio Only has no picture. The tool turns
// blue while its edit is in effect, so the state is legible even when the
// change itself is subtle.
- (void)refreshToolItemTints {
    UIBarButtonItem *tool = self.toolItem;
    if (!tool)
        return;
    SPKTrimResultMode mode = [self currentSelectedMode];
    BOOL applied = NO;
    if (mode == SPKTrimResultModeFrameOnly) {
        tool.enabled = YES;
        tool.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_EDIT_FRAME_TEXT");
        applied = (self.pendingEditedFrameURL != nil);
    } else {
        tool.enabled = (mode == SPKTrimResultModeTrimmedVideo && [self canCropVideo]);
        tool.accessibilityLabel = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_CROP_TEXT");
        applied = (tool.enabled && self.pendingCrop != nil);
    }
    tool.tintColor = applied ? [SPKUtils SPKColor_InstagramBlue] : ([SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor]);
}

- (NSString *)titleForMode:(SPKTrimResultMode)mode {
    switch (mode) {
    case SPKTrimResultModeFrameOnly:
        return SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FRAME_ONLY_TEXT");
    case SPKTrimResultModeTrimmedAudio:
        return SPKL(@"MEDIA_TRIM_TRIM_EDITOR_AUDIO_ONLY_TEXT");
    case SPKTrimResultModeTrimmedVideo:
        return SPKL(@"MEDIA_TRIM_TRIM_EDITOR_TRIM_VIDEO_TEXT");
    }
    return @"";
}

// The toolbar shows glyphs only, so the title names the mode they select.
- (void)refreshModeTitle {
    if (self.availableModes.count > 1) {
        self.title = [self titleForMode:[self currentSelectedMode]];
    } else {
        self.title = self.configuration.title.length > 0 ? self.configuration.title : SPKL(@"ALERT_ACTION_TRIM");
    }
}

- (void)modeItemTapped:(UIBarButtonItem *)item {
    NSInteger index = item.tag;
    if (index == self.selectedModeIndex || index < 0 || index >= (NSInteger)self.availableModes.count)
        return;
    self.selectedModeIndex = index;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self refreshToolbarStateAnimated:YES];
    [self refreshModeTitle];
    // Crossfade the picture and the controls into the new mode. A layer
    // transition runs in the render server, so the live video fades too rather
    // than flashing black the way a view snapshot would.
    for (UIView *view in @[ self.playerContainer, self.bottomContent ]) {
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = 0.25;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [view.layer addAnimation:fade forKey:@"spk.modeFade"];
    }
    [self applyMode:index];
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

    // If the selected mode was after the removed one, clamp it.
    if (self.selectedModeIndex >= (NSInteger)modes.count) {
        self.selectedModeIndex = 0;
    }
    [self rebuildModeToolbarItems];
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
        if (videoTrack.nominalFrameRate > 1.0) {
            self.frameDuration = 1.0 / videoTrack.nominalFrameRate;
        }
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
    self.initialEndTime = initialEnd;
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

    // The artwork has no play glyph over it, so while paused a line under it
    // says what a tap does.
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = SPKL(@"MEDIA_TRIM_TRIM_EDITOR_TAP_TO_PLAY_HINT");
    hint.textColor = [SPKUtils SPKColor_InstagramSecondaryText] ?: [UIColor lightGrayColor];
    hint.textAlignment = NSTextAlignmentCenter;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightMedium] to:hint];
    hint.alpha = 0.0;
    hint.isAccessibilityElement = NO; // the pane itself is the Play button
    [self.playerContainer addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:art.bottomAnchor constant:12.0],
        [hint.centerXAnchor constraintEqualToAnchor:self.playerContainer.centerXAnchor],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.playerContainer.leadingAnchor constant:16.0],
    ]];
    _audioPlayHint = hint;
    return art;
}

// Toggles the pane between the video picture and the audio trimmer look (album
// art + waveform). Used both by pure-audio trims and by a video trim switching
// to the "Audio Only" mode. Playback keeps running from the same AVPlayer — only
// the picture is swapped for the artwork.
- (void)setAudioPresentation:(BOOL)audio {
    self.playerLayer.hidden = audio;
    [self ensureAudioArtworkView].hidden = !audio;
    self.audioPlayHint.hidden = !audio;
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

// The play glyph sits in the middle of the pane while paused and fades away
// once playing. Frame Only has no playback, so neither the glyph nor the tap.
- (void)updatePlaybackControls {
    BOOL canPlay = self.playerReady && !self.scrubber.isFrameOnlyMode;
    self.playerContainer.isAccessibilityElement = canPlay;
    self.playerContainer.accessibilityLabel = self.isPlaying ? SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PAUSE_TEXT") : SPKL(@"MEDIA_TRIM_TRIM_EDITOR_PLAY_TEXT");
    // Over the audio artwork a play glyph would sit on top of another glyph, so
    // there the artwork itself shows the state: dimmed while paused.
    BOOL audioArt = (self.audioArtworkView && !self.audioArtworkView.hidden);
    BOOL paused = (canPlay && !self.isPlaying);
    CGFloat overlayAlpha = (paused && !audioArt) ? 1.0 : 0.0;
    CGFloat artAlpha = (audioArt && paused) ? 0.4 : 1.0;
    CGFloat hintAlpha = (audioArt && paused) ? 1.0 : 0.0;
    if (self.playOverlay.alpha != overlayAlpha || self.audioArtworkView.alpha != artAlpha || self.audioPlayHint.alpha != hintAlpha) {
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             self.playOverlay.alpha = overlayAlpha;
                             self.playOverlay.transform = overlayAlpha > 0.0 ? CGAffineTransformIdentity : CGAffineTransformMakeScale(1.15, 1.15);
                             self.audioArtworkView.alpha = artAlpha;
                             self.audioPlayHint.alpha = hintAlpha;
                         }
                         completion:nil];
    }
    [self updateFrameEditingUI];
}

- (void)playerPaneTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded)
        return;
    [self togglePlayback];
}

// Reflects whether a frame edit is locked in (and showing: it belongs to Frame
// Only, and waits there while another mode is up). The edited still covers the
// pane, and the filmstrip stays in view but dimmed and locked so the frame
// can't be nudged off the edit, with Revert Edit over it. Edit Frame stays
// available to refine further.
- (BOOL)showsFrameEdit {
    return self.pendingEditedFrameURL != nil && self.scrubber.isFrameOnlyMode;
}

- (void)updateFrameEditingUI {
    BOOL hasEdit = [self showsFrameEdit];
    self.editedFramePreview.hidden = !hasEdit;
    self.scrubber.userInteractionEnabled = !hasEdit;
    self.scrubber.alpha = hasEdit ? 0.35 : 1.0;
    self.scrubber.accessibilityElementsHidden = hasEdit;
    self.revertFrameButton.hidden = !hasEdit;
    // A locked-in edit pins the frame, so stepping is off until it is reverted.
    self.stepBackButton.hidden = hasEdit;
    self.stepForwardButton.hidden = hasEdit;
    [self refreshToolItemTints];
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
    [SPKPhotoEditorViewController openFromEditor:self
                                     sourceImage:frame
                                   configuration:configuration
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
    self.editedFrameTime = self.scrubber.frameTime;
    self.editedFramePreview.image = edited;
    [self updateTimeLabel];
    [self updateFrameEditingUI];
}

// Discards a stashed edit (Revert Edit, or a new edit replacing it) and removes
// its temp file.
// Not called once the URL is handed to the result.
- (void)clearPendingEditedFrame {
    if (self.pendingEditedFrameURL) {
        [[NSFileManager defaultManager] removeItemAtURL:self.pendingEditedFrameURL error:NULL];
        self.pendingEditedFrameURL = nil;
    }
    self.editedFramePreview.image = nil;
}

#pragma mark - Mode

- (void)applyMode:(NSInteger)index {
    SPKTrimResultMode mode = SPKTrimResultModeTrimmedVideo;
    if (index >= 0 && index < (NSInteger)self.availableModes.count) {
        mode = self.availableModes[index].integerValue;
    }
    // A frame edit survives a trip to another mode: it applies only to a Frame
    // Only result, and coming back returns to the frame it was made from (the
    // other modes move the playhead). Only Revert Edit discards it.
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
        if (self.pendingEditedFrameURL)
            self.scrubber.playheadTime = self.editedFrameTime;
        [self seekToTime:self.scrubber.frameTime];
    } else {
        self.scrubber.frameOnlyMode = NO;
        [self seekToTime:self.scrubber.startTime];
    }
    [self updatePlaybackControls];
    [self updateTimeLabel];
    [self refreshDoneMenu];
    [self updateCropPreview];
}

- (void)updateTimeLabel {
    if (self.scrubber.isFrameOnlyMode) {
        NSString *format = self.pendingEditedFrameURL ? SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FRAME_EDITED_VALUE_FORMAT")
                                                      : SPKL(@"MEDIA_TRIM_TRIM_EDITOR_FRAME_VALUE_FORMAT");
        self.timeLabel.text = [NSString stringWithFormat:format, SPKTrimFormatTime(self.scrubber.frameTime)];
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

- (void)stepBackTapped {
    [self stepBy:-1];
}

- (void)stepForwardTapped {
    [self stepBy:1];
}

- (void)stepBy:(NSInteger)frames {
    if (!self.playerReady || [self showsFrameEdit])
        return;
    if (self.isPlaying) {
        [self.player pause];
        self.isPlaying = NO;
        [self updatePlaybackControls];
    }
    [self.scrubber stepActiveTargetBy:(NSTimeInterval)frames * self.frameDuration];
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}

// A moved selection, a crop set in the crop editor, or an edited frame.
- (BOOL)hasChanges {
    if (!self.playerReady)
        return NO;
    BOOL rangeMoved = self.scrubber.startTime > 0.05 || fabs(self.scrubber.endTime - self.initialEndTime) > 0.05;
    return rangeMoved || self.userCropped || self.pendingEditedFrameURL != nil;
}

- (void)cancelTapped {
    __weak typeof(self) weakSelf = self;
    SPKMediaEditorConfirmDiscard(self, [self hasChanges], ^{
        [weakSelf.player pause];
        [weakSelf finishWithResult:nil];
    });
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
        NSInteger i = self.selectedModeIndex;
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
