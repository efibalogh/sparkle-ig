#import "SPKStrings.h"
#import "SPKNotificationSettingsProvider.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "../SPKPreferenceAvailability.h"
#import "../SPKSettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"

// The page carries a live sample of the chosen style above its rows, updated
// whenever a row that changes the look does. Tapping it steps through the kinds of
// notification Sparkle shows.
@interface SPKNotificationSettingsViewController : SPKSettingsViewController
@property (nonatomic, strong) UIView *previewHeader;
@property (nonatomic, strong) SPKNotificationPillView *previewPill;
// What the current pill was built for; anything else is restyled in place.
@property (nonatomic, copy) NSString *previewBuildSignature;
@property (nonatomic, assign) NSUInteger previewToneIndex;
// The download variant runs like a real one: 0 to 100%, a short hold, then again.
@property (nonatomic, strong) NSTimer *previewDownloadTimer;
@property (nonatomic, assign) float previewDownloadProgress;
@property (nonatomic, assign) NSTimeInterval previewDownloadHoldUntil;
@end

@interface SPKNotificationSettingsProvider (Preview)
+ (NSArray<NSDictionary *> *)spk_previewConfigs;
@end

@implementation SPKNotificationSettingsViewController

- (instancetype)init {
    return [super initWithTitle:SPKL(@"INTERFACE_NOTIFICATIONS_HEADER") sections:[SPKNotificationSettingsProvider sections] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, CGRectGetWidth(self.tableView.bounds), 112.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.isAccessibilityElement = YES;
    header.accessibilityTraits = UIAccessibilityTraitButton;
    header.accessibilityLabel = SPKL(@"NOTIFICATION_PREVIEW_ACCESSIBILITY_LABEL");
    header.accessibilityHint = SPKL(@"NOTIFICATION_PREVIEW_TAP_HINT");
    [header addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(spk_previewTapped)]];

    UILabel *hint = [UILabel new];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = SPKL(@"NOTIFICATION_PREVIEW_TAP_HINT");
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.adjustsFontForContentSizeCategory = YES;
    hint.textColor = UIColor.secondaryLabelColor;
    hint.textAlignment = NSTextAlignmentCenter;
    [header addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:header.leadingAnchor constant:16.0],
    ]];

    self.previewHeader = header;
    self.tableView.tableHeaderView = header;
    [self spk_refreshPreview];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self spk_refreshPreview];
    [self spk_updatePreviewDownloadTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewDownloadTimer invalidate];
    self.previewDownloadTimer = nil;
}

#pragma mark - Simulated download

static const int64_t kSPKPreviewDownloadBytes = 10500000;
static const NSTimeInterval kSPKPreviewDownloadDuration = 4.0;
static const NSTimeInterval kSPKPreviewDownloadHold = 1.0;
static const NSTimeInterval kSPKPreviewDownloadTick = 1.0 / 20.0;

- (BOOL)spk_previewShowsDownload {
    return [[self spk_currentPreviewConfig][@"kind"] isEqualToString:@"progress"];
}

// Runs only while the download variant is on screen.
- (void)spk_updatePreviewDownloadTimer {
    BOOL wanted = [self spk_previewShowsDownload] && self.view.window != nil;
    if (!wanted) {
        [self.previewDownloadTimer invalidate];
        self.previewDownloadTimer = nil;
        return;
    }
    if (self.previewDownloadTimer)
        return;
    __weak typeof(self) weakSelf = self;
    self.previewDownloadTimer = [NSTimer scheduledTimerWithTimeInterval:kSPKPreviewDownloadTick
                                                                repeats:YES
                                                                  block:^(__unused NSTimer *timer) {
                                                                      [weakSelf spk_previewDownloadTick];
                                                                  }];
    // Keeps ticking while the table scrolls.
    [NSRunLoop.mainRunLoop addTimer:self.previewDownloadTimer forMode:NSRunLoopCommonModes];
}

- (void)spk_previewDownloadTick {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (self.previewDownloadHoldUntil > 0.0) {
        if (now < self.previewDownloadHoldUntil)
            return;
        self.previewDownloadHoldUntil = 0.0;
        self.previewDownloadProgress = 0.0f;
    } else {
        // A little uneven, like a real transfer.
        float step = (float)(kSPKPreviewDownloadTick / kSPKPreviewDownloadDuration) * (0.6f + 0.8f * (float)arc4random_uniform(1000) / 1000.0f);
        self.previewDownloadProgress = MIN(1.0f, self.previewDownloadProgress + step);
        if (self.previewDownloadProgress >= 1.0f)
            self.previewDownloadHoldUntil = now + kSPKPreviewDownloadHold;
    }
    [self spk_applyPreviewDownloadProgressAnimated:self.previewDownloadProgress > 0.0f];
}

- (void)spk_applyPreviewDownloadProgressAnimated:(BOOL)animated {
    float progress = self.previewDownloadProgress;
    [self.previewPill setProgress:progress
                     bytesWritten:(int64_t)(progress * kSPKPreviewDownloadBytes)
               totalBytesExpected:kSPKPreviewDownloadBytes
                         animated:animated];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        [self spk_refreshPreview];
}

- (void)menuChanged:(UICommand *)command {
    [super menuChanged:command];
    NSDictionary *plist = [command.propertyList isKindOfClass:NSDictionary.class] ? command.propertyList : nil;
    // Show what Download Progress changes rather than leaving it to be found.
    if ([plist[@"defaultsKey"] isEqualToString:kSPKNotificationProgressSubtitleStyleKey])
        [self spk_showPreviewAtIndex:[self spk_previewIndexOfKind:@"progress"]];
    [self spk_refreshPreview];
}

- (void)switchChanged:(UISwitch *)sender {
    [super switchChanged:sender];
    [self spk_refreshPreview];
}

// Style and Liquid Glass are fixed when a pill is made, so only they need a new
// one. Everything else (glow or tint, light or dark) is applied to the pill on screen.
- (NSString *)spk_previewBuildSignature {
    return [NSString stringWithFormat:@"%d-%d", SPKNotificationUsesInstagramStyle(),
                                      [SPKUtils getBoolPref:kSPKNotificationPillLiquidGlassEnabledKey]];
}

- (NSDictionary *)spk_currentPreviewConfig {
    NSArray<NSDictionary *> *configs = [SPKNotificationSettingsProvider spk_previewConfigs];
    return configs[self.previewToneIndex % configs.count];
}

- (NSUInteger)spk_previewIndexOfKind:(NSString *)kind {
    NSArray<NSDictionary *> *configs = [SPKNotificationSettingsProvider spk_previewConfigs];
    for (NSUInteger index = 0; index < configs.count; index++) {
        if ([configs[index][@"kind"] isEqualToString:kind])
            return index;
    }
    return 0;
}

// Puts `config` on the pill on screen. Every kind can follow every other, so each
// path fully sets its own state. The pill animates the difference itself.
- (void)spk_applyPreviewConfig:(NSDictionary *)config toPill:(SPKNotificationPillView *)pill {
    NSString *kind = config[@"kind"];
    if ([kind isEqualToString:@"progress"]) {
        [UIView transitionWithView:pill
                          duration:0.24
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:^{
                            self.previewDownloadProgress = 0.0f;
                            self.previewDownloadHoldUntil = 0.0;
                            [pill setProgress:0.0f bytesWritten:0 totalBytesExpected:kSPKPreviewDownloadBytes animated:NO];
                            [pill updateProgressTitle:config[@"title"] subtitle:nil];
                        }
                        completion:nil];
    } else if ([kind isEqualToString:@"transient"]) {
        [UIView transitionWithView:pill
                          duration:0.24
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:^{
                            [pill updateProgressTitle:config[@"title"] subtitle:nil];
                            [pill setProgressIndeterminate:YES];
                        }
                        completion:nil];
    } else {
        [pill updateToastWithTitle:config[@"title"]
                          subtitle:config[@"subtitle"]
                              icon:[self spk_previewIconForConfig:config]
                              tone:[config[@"tone"] unsignedIntegerValue]];
    }
}

- (UIImage *)spk_previewIconForConfig:(NSDictionary *)config {
    return SPKNotificationIconNamed(config[@"iconResource"], SPKNotificationUsesInstagramStyle());
}

- (void)spk_refreshPreview {
    if (!self.previewHeader)
        return;
    NSString *signature = [self spk_previewBuildSignature];
    NSDictionary *config = [self spk_currentPreviewConfig];
    if (self.previewPill && [signature isEqualToString:self.previewBuildSignature]) {
        [self.previewPill refreshVisualStyleAnimated:YES];
        // The download's line re-reads Download Progress on every update.
        if ([config[@"kind"] isEqualToString:@"progress"])
            [self spk_applyPreviewDownloadProgressAnimated:NO];
        return;
    }

    SPKNotificationPillView *pill = [SPKNotificationPillView toastPillWithTitle:config[@"title"]
                                                                       subtitle:config[@"subtitle"]
                                                                           icon:[self spk_previewIconForConfig:config]
                                                                           tone:[config[@"tone"] unsignedIntegerValue]];
    pill.userInteractionEnabled = NO;
    pill.isAccessibilityElement = NO;
    pill.accessibilityElementsHidden = YES;

    UIView *oldPill = self.previewPill;
    [self.previewHeader addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:self.previewHeader.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:self.previewHeader.topAnchor constant:14.0],
    ]];
    if (![config[@"kind"] isEqualToString:@"toast"]) {
        [UIView performWithoutAnimation:^{
            [self spk_applyPreviewConfig:config toPill:pill];
            [pill layoutIfNeeded];
        }];
    }
    self.previewPill = pill;
    self.previewBuildSignature = signature;
    [self spk_updatePreviewDownloadTimer];
    if (!oldPill)
        return;
    // A different kind of notification: fade one into the other in the same spot.
    pill.alpha = 0.0;
    [UIView animateWithDuration:0.25
        animations:^{
            pill.alpha = 1.0;
            oldPill.alpha = 0.0;
        }
        completion:^(__unused BOOL finished) {
            [oldPill removeFromSuperview];
        }];
}

- (void)spk_showPreviewAtIndex:(NSUInteger)index {
    if (index == self.previewToneIndex % [SPKNotificationSettingsProvider spk_previewConfigs].count)
        return;
    self.previewToneIndex = index;
    if (self.previewPill)
        [self spk_applyPreviewConfig:[self spk_currentPreviewConfig] toPill:self.previewPill];
    [self spk_updatePreviewDownloadTimer];
}

- (void)spk_previewTapped {
    NSUInteger count = [SPKNotificationSettingsProvider spk_previewConfigs].count;
    [self spk_showPreviewAtIndex:(self.previewToneIndex + 1) % count];
}

@end

@implementation SPKNotificationSettingsProvider

+ (NSArray<SPKSetting *> *)spk_groupRowsOfKind:(NSString *)kind {
    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
    for (NSDictionary *group in SPKNotificationGroups()) {
        if (![group[@"kind"] isEqualToString:kind])
            continue;
        SPKSetting *row = [SPKSetting menuCellWithTitle:group[@"title"]
                                                   icon:SPKSettingsIcon(group[@"iconName"])
                                                   menu:SPKNotificationModeMenu(SPKNotificationGroupModeKey(group[@"group"]))];
        row.helpText = group[@"footer"];
        [rows addObject:row];
    }
    return [rows copy];
}

// What the preview cycles through: the three toast tones, a running download (whose
// line follows Download Progress) and the spinning pill shown while Sparkle looks
// something up.
+ (NSArray<NSDictionary *> *)spk_previewConfigs {
    return @[
        @{
            @"kind" : @"toast",
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_SAVED_GALLERY_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_SUCCESS_TONE_TEXT"),
            @"iconResource" : @"circle_check_filled",
            @"tone" : @(SPKNotificationToneSuccess)
        },
        @{
            @"kind" : @"toast",
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_SOMETHING_WENT_WRONG_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_ERROR_TONE_TEXT"),
            @"iconResource" : @"error_filled",
            @"tone" : @(SPKNotificationToneError)
        },
        @{
            @"kind" : @"toast",
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_HEADS_UP_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_INFO_TONE_TEXT"),
            @"iconResource" : @"info_filled",
            @"tone" : @(SPKNotificationToneInfo)
        },
        @{
            @"kind" : @"progress",
            @"title" : SPKL(@"MEDIA_TRIM_TRIM_ENTRY_DOWNLOADING_TEXT"),
        },
        @{
            @"kind" : @"transient",
            @"title" : SPKL(@"GENERAL_UTILS_OPENING_PROFILE_TEXT"),
        },
    ];
}

+ (UIViewController *)settingsViewController {
    return [[SPKNotificationSettingsViewController alloc] init];
}

+ (NSArray *)sections {
    BOOL (^instagramStyle)(void) = ^BOOL {
        return SPKNotificationUsesInstagramStyle();
    };

    SPKSetting *style = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_STYLE_TITLE")
                                                                subtitle:@""
                                                                    menu:SPKNotificationStyleMenu()],
                                           SPKL(@"NOTIFICATION_APPEARANCE_STYLE_HELP"));

    // Glow and Tint by Result are one preference: the pill shows the result's colour
    // as a glow, the Instagram toast as a tint, so each style names it for what it does.
    SPKSetting *glow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_GLOW_TITLE")
                                                                 subtitle:@""
                                                              defaultsKey:kSPKNotificationPillGlowEnabledKey],
                                          SPKL(@"NOTIFICATION_APPEARANCE_GLOW_HELP"));
    glow.hiddenProvider = instagramStyle;
    SPKSetting *tint = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_TINT_TITLE")
                                                                 subtitle:@""
                                                              defaultsKey:kSPKNotificationPillGlowEnabledKey],
                                          SPKL(@"NOTIFICATION_APPEARANCE_TINT_HELP"));
    tint.hiddenProvider = ^BOOL {
        return !instagramStyle();
    };
    SPKSetting *liquidGlass = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_CAPTURE_LIQUID_GLASS_TITLE")
                                                                        subtitle:@""
                                                                     defaultsKey:kSPKNotificationPillLiquidGlassEnabledKey],
                                                 SPKL(@"NOTIFICATION_APPEARANCE_LIQUID_GLASS_HELP"));
    liquidGlass.hiddenProvider = ^BOOL {
        return instagramStyle() || !SPKPrefIsAvailable(kSPKNotificationPillLiquidGlassEnabledKey);
    };

    SPKSetting *progress = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_DOWNLOAD_PROGRESS_TITLE")
                                                                   subtitle:@""
                                                                       menu:SPKNotificationProgressSubtitleStyleMenu()],
                                              SPKL(@"NOTIFICATION_APPEARANCE_DOWNLOAD_PROGRESS_HELP"));

    return @[
        SPKTopicSection(SPKL(@"NOTIFICATION_STYLE_HEADER"), @[ style ], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_APPEARANCE_HEADER"), @[ glow, tint, liquidGlass ], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_BEHAVIOR_HEADER"), @[
            [SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_POSITION_TITLE")
                                 subtitle:@""
                                     menu:SPKNotificationPillPositionMenu()],
            [SPKSetting stepperCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_DURATION_TITLE")
                                    subtitle:SPKL(@"NOTIFICATION_APPEARANCE_DISMISS_AFTER_SUBTITLE")
                                 defaultsKey:kSPKNotificationPillDurationKey
                                         min:0.5
                                         max:5.0
                                        step:0.25
                                       label:SPKL(@"NOTIFICATION_APPEARANCE_DURATION_UNIT")
                               singularLabel:@" second"],
            progress
        ],
                        nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_CONFIRMATIONS_HEADER"), [self spk_groupRowsOfKind:@"confirmation"], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_EVENTS_HEADER"), [self spk_groupRowsOfKind:@"event"], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_ERRORS_HEADER"), @[
            [SPKSetting switchCellWithTitle:SPKL(@"NOTIFICATION_ERRORS_HAPTIC_TITLE")
                                   subtitle:@""
                                defaultsKey:kSPKNotificationErrorHapticKey]
        ],
                        SPKL(@"NOTIFICATION_ERRORS_FOOTER"))
    ];
}

@end
