#import "SPKStrings.h"
#import "SPKGalleryImportMetadataFormViewController.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryOriginController.h"
#import "SPKGallerySaveMetadata.h"
#import "../UI/SPKFont.h"

typedef NS_ENUM(NSInteger, SPKGalleryImportFormRow) {
    SPKGalleryImportFormRowDisplayName = 0,
    SPKGalleryImportFormRowUsername,
    SPKGalleryImportFormRowPasteLink,
    SPKGalleryImportFormRowSource,
    SPKGalleryImportFormRowFileStem,
    SPKGalleryImportFormRowUserPK,
    SPKGalleryImportFormRowProfileURL,
    SPKGalleryImportFormRowMediaPK,
    SPKGalleryImportFormRowMediaCode,
    SPKGalleryImportFormRowMediaURL,
    SPKGalleryImportFormRowPixelWidth,
    SPKGalleryImportFormRowPixelHeight,
    SPKGalleryImportFormRowDuration,
    SPKGalleryImportFormRowGallerySortDate,
};

typedef NS_ENUM(NSInteger, SPKGalleryImportFormSection) {
    SPKGalleryImportFormSectionIdentity = 0,
    SPKGalleryImportFormSectionLink,
    SPKGalleryImportFormSectionAdvanced,
    SPKGalleryImportFormSectionCount,
};

#pragma mark - Instagram link parsing

// Parse a pasted Instagram post/reel/story/profile link into metadata, mirroring the source→path
// mapping that SPKGalleryOriginController uses to *build* links. Returns YES if anything was filled.
static BOOL SPKParseInstagramLink(NSString *raw, SPKGallerySaveMetadata *m) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) {
        return NO;
    }
    if (![s containsString:@"://"]) {
        s = [@"https://" stringByAppendingString:s];
    }
    NSURL *url = [NSURL URLWithString:s];
    if (!url || !url.host) {
        return NO;
    }
    if (![url.host.lowercaseString containsString:@"instagram."]) {
        return NO;
    }

    NSMutableArray<NSString *> *comps = [NSMutableArray array];
    for (NSString *c in url.pathComponents) {
        if (c.length > 0 && ![c isEqualToString:@"/"]) {
            [comps addObject:c];
        }
    }
    if (comps.count == 0) {
        return NO;
    }

    NSString *verb = comps[0].lowercaseString;
    NSString *normalized = [NSString stringWithFormat:@"https://www.instagram.com%@", url.path];

    if (([verb isEqualToString:@"reel"] || [verb isEqualToString:@"reels"] || [verb isEqualToString:@"p"] ||
         [verb isEqualToString:@"tv"]) &&
        comps.count >= 2) {
        m.source = (int16_t)([verb isEqualToString:@"reel"] || [verb isEqualToString:@"reels"]
                                 ? SPKGallerySourceReels
                                 : SPKGallerySourceFeed);
        m.sourceMediaCode = comps[1];
        m.sourceMediaURLString = normalized;
        return YES;
    }

    if ([verb isEqualToString:@"stories"] && comps.count >= 3) {
        m.source = (int16_t)SPKGallerySourceStories;
        m.sourceUsername = comps[1];
        m.sourceMediaPK = comps[2];
        [SPKGalleryOriginController populateProfileMetadata:m username:comps[1] user:nil];
        return YES;
    }

    static NSSet<NSString *> *reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reserved = [NSSet setWithArray:@[ @"p", @"reel", @"reels", @"tv", @"stories", @"s", @"explore",
                                          @"accounts", @"direct", @"about", @"web" ]];
    });
    if (![reserved containsObject:verb]) {
        m.sourceUsername = comps[0];
        m.sourceProfileURLString = normalized;
        [SPKGalleryOriginController populateProfileMetadata:m username:comps[0] user:nil];
        return YES;
    }

    return NO;
}

#pragma mark - Source picker (pushed list with icons)

@interface SPKGalleryImportSourcePickerViewController : UITableViewController
@property (nonatomic) SPKGallerySource selectedSource;
@property (nonatomic, copy) void (^onPick)(SPKGallerySource source);
@end

@implementation SPKGalleryImportSourcePickerViewController {
    NSArray<NSNumber *> *_sources;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"GALLERY_GALLERY_FILTER_SOURCE_TEXT");
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    _sources = @[
        @(SPKGallerySourceFeed), @(SPKGallerySourceStories), @(SPKGallerySourceReels),
        @(SPKGallerySourceProfile), @(SPKGallerySourceDMs), @(SPKGallerySourceThumbnail),
        @(SPKGallerySourceInstants), @(SPKGallerySourceAudioPage), @(SPKGallerySourceComments),
        @(SPKGallerySourceOther)
    ];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_sources.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"src"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"src"];
        cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        cell.textLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];
        cell.selectedBackgroundView = sel;
    }
    SPKGallerySource src = (SPKGallerySource)_sources[(NSUInteger)indexPath.row].intValue;
    cell.textLabel.text = [SPKGalleryFile labelForSource:src];
    cell.imageView.image = [SPKAssetUtils instagramIconNamed:[SPKGalleryFile symbolNameForSource:src]
                                                   pointSize:22.0
                                               renderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.imageView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    // Sparkle's pickers mark the selection with the filled circle-check, not the system tick.
    if (src == self.selectedSource) {
        UIImageView *checkmark = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled"]];
        checkmark.tintColor = [SPKUtils SPKColor_InstagramBlue];
        cell.accessoryView = checkmark;
    } else {
        cell.accessoryView = nil;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKGallerySource src = (SPKGallerySource)_sources[(NSUInteger)indexPath.row].intValue;
    self.selectedSource = src;
    if (self.onPick) {
        self.onPick(src);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Controller

@interface SPKGalleryImportMetadataFormViewController () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UITextField *> *textFields;
@property (nonatomic, strong) UIImageView *heroImageView;
@property (nonatomic) BOOL advancedExpanded;
@property (nonatomic, readwrite) BOOL didModifyMetadata;
@end

@implementation SPKGalleryImportMetadataFormViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSArray<NSNumber *> *)advancedRows {
    return @[
        @(SPKGalleryImportFormRowMediaCode), @(SPKGalleryImportFormRowMediaURL), @(SPKGalleryImportFormRowMediaPK),
        @(SPKGalleryImportFormRowUserPK), @(SPKGalleryImportFormRowProfileURL), @(SPKGalleryImportFormRowFileStem),
        @(SPKGalleryImportFormRowPixelWidth), @(SPKGalleryImportFormRowPixelHeight), @(SPKGalleryImportFormRowDuration),
        @(SPKGalleryImportFormRowGallerySortDate)
    ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    // Self-size rows from their content configuration, exactly like SPKSettingsViewController — this
    // is what gives the framework's ~44pt height floor and body metrics.
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48.0;
    self.textFields = [NSMutableDictionary dictionary];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(spk_dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:tap];

    [self installPreviewHeaderIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

// A hero header above the form: the media itself (the most important thing), then the full filename
// (wrapping) and type/size. Skipped for the shared-defaults editor.
- (void)installPreviewHeaderIfNeeded {
    if (self.previewFilename.length == 0 && !self.previewThumbnail && !self.previewFileURL) {
        return;
    }
    // Audio gets no header at all: there is no frame to show, and the type/size/filename it would
    // otherwise carry are already implied by the row the user tapped to get here.
    if (self.previewMediaType == SPKGalleryMediaTypeAudio) {
        return;
    }

    CGFloat width = self.view.bounds.size.width > 1.0 ? self.view.bounds.size.width
                                                      : UIScreen.mainScreen.bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 240.0)];

    self.heroImageView = [[UIImageView alloc] init];
    self.heroImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.heroImageView.clipsToBounds = YES;
    self.heroImageView.layer.cornerRadius = 14.0;
    self.heroImageView.layer.cornerCurve = kCACornerCurveContinuous;
    self.heroImageView.backgroundColor = [SPKUtils SPKColor_InstagramTertiaryBackground];
    self.heroImageView.image = self.previewThumbnail;
    self.heroImageView.userInteractionEnabled = (self.previewFileURL != nil);
    [self.heroImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(previewHeroTapped)]];
    [header addSubview:self.heroImageView];

    // Type · size reads as the headline fact; the raw tweak-style filename is demoted to a single
    // middle-truncated line beneath it (wrapping it produced an ugly multi-line monospace blob).
    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightSemibold] to:sub];
    sub.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    sub.text = self.previewSubtitle;
    sub.textAlignment = NSTextAlignmentCenter;
    [header addSubview:sub];

    UILabel *file = [[UILabel alloc] init];
    file.translatesAutoresizingMaskIntoConstraints = NO;
    file.font = [SPKFont monospacedFontForStyle:SPKFontStyleCaption2 weight:UIFontWeightRegular];
    file.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
    file.text = self.previewFilename;
    file.numberOfLines = 1;
    file.lineBreakMode = NSLineBreakByTruncatingMiddle;
    file.textAlignment = NSTextAlignmentCenter;
    [header addSubview:file];

    UILayoutGuide *g = header.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.heroImageView.topAnchor constraintEqualToAnchor:header.topAnchor constant:8.0],
        [self.heroImageView.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [self.heroImageView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [self.heroImageView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [self.heroImageView.heightAnchor constraintEqualToConstant:180.0],

        [sub.topAnchor constraintEqualToAnchor:self.heroImageView.bottomAnchor constant:12.0],
        [sub.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [file.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:3.0],
        [file.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [file.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [file.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-14.0],
    ]];

    CGSize fit = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                      withHorizontalFittingPriority:UILayoutPriorityRequired
                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    header.frame = CGRectMake(0, 0, width, MAX(fit.height, 220.0));
    self.tableView.tableHeaderView = header;

    [self renderHeroThumbnail];
}

// Render a crisp, full-width hero from the file (the queue thumbnail is only ~52pt and looks soft
// blown up). Only reached for photo/video — audio has no header.
- (void)renderHeroThumbnail {
    if (!self.previewFileURL) {
        return;
    }
    SPKGalleryMediaType type = self.previewMediaType;
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
    // view.bounds can still be zero-width in viewDidLoad; fall back to the screen so we never
    // ask for a {0,0} thumbnail (which asserts in the resize path).
    CGFloat width = self.view.bounds.size.width > 1.0 ? self.view.bounds.size.width
                                                      : UIScreen.mainScreen.bounds.size.width;
    CGSize size = CGSizeMake(width * scale, 180.0 * scale);
    __weak typeof(self) weakSelf = self;
    [SPKGalleryFile generateThumbnailForURL:self.previewFileURL
                                  mediaType:type
                                       size:size
                                 completion:^(UIImage *_Nullable image) {
                                     if (image) {
                                         weakSelf.heroImageView.image = image;
                                     }
                                 }];
}

- (void)previewHeroTapped {
    if (self.previewFileURL) {
        // Pass the known type rather than letting the player sniff the extension — otherwise audio
        // in an .mp4 container opens as a video and shows AVPlayer's generic QuickTime placeholder
        // instead of Sparkle's audio artwork overlay.
        SPKMediaItemType type = (self.previewMediaType == SPKGalleryMediaTypeAudio)   ? SPKMediaItemTypeAudio
                                : (self.previewMediaType == SPKGalleryMediaTypeVideo) ? SPKMediaItemTypeVideo
                                                                                      : SPKMediaItemTypeImage;
        [SPKFullScreenMediaPlayer showLocalFilePreview:self.previewFileURL mediaType:type];
    }
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return SPKGalleryImportFormSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch ((SPKGalleryImportFormSection)section) {
    case SPKGalleryImportFormSectionIdentity:
        return 2;
    case SPKGalleryImportFormSectionLink:
        return 2;
    case SPKGalleryImportFormSectionAdvanced:
        return self.advancedExpanded ? (NSInteger)(1 + self.advancedRows.count) : 1;
    default:
        return 0;
    }
}

- (SPKGalleryImportFormRow)rowForIndexPath:(NSIndexPath *)indexPath {
    switch ((SPKGalleryImportFormSection)indexPath.section) {
    case SPKGalleryImportFormSectionIdentity:
        return indexPath.row == 0 ? SPKGalleryImportFormRowDisplayName : SPKGalleryImportFormRowUsername;
    case SPKGalleryImportFormSectionLink:
        return indexPath.row == 0 ? SPKGalleryImportFormRowPasteLink : SPKGalleryImportFormRowSource;
    case SPKGalleryImportFormSectionAdvanced:
        return (SPKGalleryImportFormRow)[self.advancedRows[(NSUInteger)(indexPath.row - 1)] integerValue];
    default:
        return SPKGalleryImportFormRowDisplayName;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch ((SPKGalleryImportFormSection)section) {
    case SPKGalleryImportFormSectionIdentity:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_IDENTITY_TEXT");
    case SPKGalleryImportFormSectionLink:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_LINK_BACK_TEXT");
    default:
        return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    switch ((SPKGalleryImportFormSection)section) {
    case SPKGalleryImportFormSectionIdentity:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_USERNAME_POWERS_OPEN_PROFILE_TEXT");
    case SPKGalleryImportFormSectionLink: {
        NSString *preview = [self permalinkPreview];
        return preview.length ? [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_OPEN_ORIGINAL_VALUE_FORMAT"), preview]
                              : SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_PASTE_POST_REEL_STORY_PROFILE_LINK_FILL_EVERYTHING_TEXT");
    }
    case SPKGalleryImportFormSectionAdvanced:
        if (!self.advancedExpanded) {
            return nil;
        }
        return self.footerStemExplanation.length ? self.footerStemExplanation
                                                 : SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_MANUAL_OVERRIDES_LEAVE_BLANK_AUTO_DETECT_TEXT");
    default:
        return nil;
    }
}

- (NSString *)permalinkPreview {
    SPKGallerySaveMetadata *m = self.metadata;
    if (m.sourceMediaURLString.length > 0) {
        return m.sourceMediaURLString;
    }
    if ((SPKGallerySource)m.source == SPKGallerySourceStories && m.sourceUsername.length > 0 && m.sourceMediaPK.length > 0) {
        return [NSString stringWithFormat:@"instagram.com/stories/%@/%@/", m.sourceUsername, m.sourceMediaPK];
    }
    if (m.sourceMediaCode.length > 0) {
        NSString *path = ((SPKGallerySource)m.source == SPKGallerySourceReels) ? @"reel" : @"p";
        return [NSString stringWithFormat:@"instagram.com/%@/%@/", path, m.sourceMediaCode];
    }
    return nil;
}

#pragma mark - Field metadata

// Compact labels for the inline label+field rows (units live in the placeholder).
- (NSString *)titleForRow:(SPKGalleryImportFormRow)row {
    switch (row) {
    case SPKGalleryImportFormRowDisplayName:
        return SPKL(@"SETTINGS_PROFILE_NAME_TEXT");
    case SPKGalleryImportFormRowUsername:
        return SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT");
    case SPKGalleryImportFormRowPasteLink:
        return @"Link";
    case SPKGalleryImportFormRowSource:
        return SPKL(@"GALLERY_GALLERY_FILTER_SOURCE_TEXT");
    case SPKGalleryImportFormRowFileStem:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_FILE_KEY_TEXT");
    case SPKGalleryImportFormRowUserPK:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_USER_ID_TEXT");
    case SPKGalleryImportFormRowProfileURL:
        return SPKL(@"PROFILE_TITLE");
    case SPKGalleryImportFormRowMediaPK:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_MEDIA_ID_TEXT");
    case SPKGalleryImportFormRowMediaCode:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_SHORTCODE_TEXT");
    case SPKGalleryImportFormRowMediaURL:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_PERMALINK_TEXT");
    case SPKGalleryImportFormRowPixelWidth:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_WIDTH_TEXT");
    case SPKGalleryImportFormRowPixelHeight:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_HEIGHT_TEXT");
    case SPKGalleryImportFormRowDuration:
        return SPKL(@"NOTIFICATION_APPEARANCE_DURATION_TITLE");
    case SPKGalleryImportFormRowGallerySortDate:
        return SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DATE_TEXT");
    default:
        return @"";
    }
}

- (NSString *)placeholderForRow:(SPKGalleryImportFormRow)row {
    switch (row) {
    case SPKGalleryImportFormRowPixelWidth:
    case SPKGalleryImportFormRowPixelHeight:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_PX_TEXT");
    case SPKGalleryImportFormRowDuration:
        return SPKL(@"NOTIFICATION_APPEARANCE_DURATION_UNIT");
    case SPKGalleryImportFormRowMediaCode:
        return @"ABCde123";
    case SPKGalleryImportFormRowProfileURL:
    case SPKGalleryImportFormRowMediaURL:
        return @"https://...";
    default:
        return SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_OPTIONAL_TEXT");
    }
}

- (NSString *)stringValueForRow:(SPKGalleryImportFormRow)row {
    SPKGallerySaveMetadata *m = self.metadata;
    switch (row) {
    case SPKGalleryImportFormRowDisplayName:
        return m.customName ?: @"";
    case SPKGalleryImportFormRowUsername:
        return m.sourceUsername ?: @"";
    case SPKGalleryImportFormRowFileStem:
        return m.importFileNameStem ?: @"";
    case SPKGalleryImportFormRowUserPK:
        return m.sourceUserPK ?: @"";
    case SPKGalleryImportFormRowProfileURL:
        return m.sourceProfileURLString ?: @"";
    case SPKGalleryImportFormRowMediaPK:
        return m.sourceMediaPK ?: @"";
    case SPKGalleryImportFormRowMediaCode:
        return m.sourceMediaCode ?: @"";
    case SPKGalleryImportFormRowMediaURL:
        return m.sourceMediaURLString ?: @"";
    case SPKGalleryImportFormRowPixelWidth:
        return m.pixelWidth > 0 ? [NSString stringWithFormat:@"%d", (int)m.pixelWidth] : @"";
    case SPKGalleryImportFormRowPixelHeight:
        return m.pixelHeight > 0 ? [NSString stringWithFormat:@"%d", (int)m.pixelHeight] : @"";
    case SPKGalleryImportFormRowDuration:
        return m.durationSeconds > 0.05 ? [NSString stringWithFormat:@"%.3f", m.durationSeconds] : @"";
    default:
        return @"";
    }
}

- (void)applyString:(NSString *)value forRow:(SPKGalleryImportFormRow)row {
    NSString *before = [self stringValueForRow:row];
    NSString *t = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    SPKGallerySaveMetadata *m = self.metadata;
    switch (row) {
    case SPKGalleryImportFormRowDisplayName:
        m.customName = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowFileStem:
        m.importFileNameStem = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowUsername:
        m.sourceUsername = t.length ? t : nil;
        if (t.length > 0) {
            [SPKGalleryOriginController populateProfileMetadata:m username:t user:nil];
        }
        break;
    case SPKGalleryImportFormRowUserPK:
        m.sourceUserPK = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowProfileURL:
        m.sourceProfileURLString = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowMediaPK:
        m.sourceMediaPK = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowMediaCode:
        m.sourceMediaCode = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowMediaURL:
        m.sourceMediaURLString = t.length ? t : nil;
        break;
    case SPKGalleryImportFormRowPixelWidth:
        m.pixelWidth = t.length ? (int32_t)[t intValue] : 0;
        break;
    case SPKGalleryImportFormRowPixelHeight:
        m.pixelHeight = t.length ? (int32_t)[t intValue] : 0;
        break;
    case SPKGalleryImportFormRowDuration:
        m.durationSeconds = t.length ? [t doubleValue] : 0;
        break;
    default:
        break;
    }
    if (![before isEqualToString:[self stringValueForRow:row]]) {
        self.didModifyMetadata = YES;
    }
}

#pragma mark - Cells

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if ((SPKGalleryImportFormSection)indexPath.section == SPKGalleryImportFormSectionAdvanced && indexPath.row == 0) {
        return [self advancedToggleCell];
    }
    SPKGalleryImportFormRow row = [self rowForIndexPath:indexPath];
    switch (row) {
    case SPKGalleryImportFormRowSource:
        return [self sourceNavlinkCell];
    case SPKGalleryImportFormRowPasteLink:
        return [self pasteLinkCell];
    case SPKGalleryImportFormRowGallerySortDate:
        return [self dateCell];
    default:
        return [self inlineFieldCellForRow:row];
    }
}

// Shared chrome so every row is the *same UITableViewCell + UIListContentConfiguration* the
// SPKSettingsViewController framework (e.g. "Encoding Settings") builds — identical system metrics,
// height floor, margins and body font. Each row just fills in the content config + accessoryView.
- (UITableViewCell *)chromeCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];
    cell.selectedBackgroundView = sel;
    return cell;
}

// A trailing text field sized like the framework's SPKTableCellTextField accessory (right-aligned,
// body-medium). Fixed width keeps every value's right edge aligned across rows.
- (UITextField *)accessoryFieldForRow:(SPKGalleryImportFormRow)row {
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 170, 34)];
    tf.textAlignment = NSTextAlignmentRight;
    tf.font = [SPKFont fontForStyle:SPKFontStyleBody weight:UIFontWeightMedium];
    tf.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    tf.text = [self stringValueForRow:row];
    tf.placeholder = [self placeholderForRow:row];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    tf.tag = row;
    if (row == SPKGalleryImportFormRowPixelWidth || row == SPKGalleryImportFormRowPixelHeight) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
    } else if (row == SPKGalleryImportFormRowDuration) {
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    } else if (row == SPKGalleryImportFormRowProfileURL || row == SPKGalleryImportFormRowMediaURL) {
        tf.keyboardType = UIKeyboardTypeURL;
    } else {
        tf.keyboardType = UIKeyboardTypeDefault;
    }
    return tf;
}

// Title (content config) + right-aligned editable value (accessory) — the framework's text-field row.
- (UITableViewCell *)inlineFieldCellForRow:(SPKGalleryImportFormRow)row {
    UITableViewCell *cell = [self chromeCell];
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = [self titleForRow:row];
    cfg.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.contentConfiguration = cfg;

    UITextField *tf = [self accessoryFieldForRow:row];
    cell.accessoryView = tf;
    self.textFields[@(row)] = tf;
    return cell;
}

// A blue button row (framework SPKTableCellButton look) that fills the whole form from the clipboard.
- (UITableViewCell *)pasteLinkCell {
    UITableViewCell *cell = [self chromeCell];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_PASTE_LINK_AUTOFILL_TEXT");
    cfg.textProperties.color = [SPKUtils SPKColor_InstagramBlue];
    cell.contentConfiguration = cfg;
    return cell;
}

// Title + current value (side-by-side secondary text) + disclosure — the framework's navigation row.
- (UITableViewCell *)sourceNavlinkCell {
    UITableViewCell *cell = [self chromeCell];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    SPKGallerySource src = (SPKGallerySource)self.metadata.source;
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = SPKL(@"GALLERY_GALLERY_FILTER_SOURCE_TEXT");
    cfg.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    cfg.secondaryText = [SPKGalleryFile labelForSource:src];
    cfg.prefersSideBySideTextAndSecondaryText = YES;
    cfg.secondaryTextProperties.numberOfLines = 1;
    cfg.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
    cfg.secondaryTextProperties.font = [SPKFont fontForStyle:SPKFontStyleBody weight:UIFontWeightMedium];
    cell.contentConfiguration = cfg;
    return cell;
}

// Title + a compact date picker (with an optional Clear) in the accessory, mirroring how the
// framework hangs a UIStepper off the accessory.
- (UITableViewCell *)dateCell {
    UITableViewCell *cell = [self chromeCell];
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DATE_TEXT");
    cfg.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    // The picker's date and time pills grow with the text size and take most of
    // the row, so the title keeps to one line and shrinks rather than breaking
    // between letters.
    cfg.textProperties.numberOfLines = 1;
    cfg.textProperties.adjustsFontSizeToFitWidth = YES;
    cfg.textProperties.minimumScaleFactor = 0.7;
    cell.contentConfiguration = cfg;

    UIDatePicker *picker = [[UIDatePicker alloc] init];
    picker.datePickerMode = UIDatePickerModeDateAndTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    picker.date = self.metadata.importCapturedDate ?: [NSDate date];
    [picker addTarget:self action:@selector(dateChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *accessory = [[UIStackView alloc] init];
    accessory.axis = UILayoutConstraintAxisHorizontal;
    accessory.alignment = UIStackViewAlignmentCenter;
    accessory.spacing = 6.0;

    if (self.metadata.importCapturedDate != nil) {
        // An icon, like a text field's clear button, so it costs the title as
        // little width as possible at any text size and in any language.
        UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *clearSymbol =
            [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
        [clear setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:clearSymbol] forState:UIControlStateNormal];
        clear.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
        clear.accessibilityLabel = SPKL(@"ALERT_ACTION_CLEAR");
        [clear addTarget:self action:@selector(clearDate) forControlEvents:UIControlEventTouchUpInside];
        [accessory addArrangedSubview:clear];
    }
    [accessory addArrangedSubview:picker];
    CGSize fit = [accessory systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    accessory.frame = CGRectMake(0, 0, fit.width, fit.height);
    cell.accessoryView = accessory;
    return cell;
}

// Title over a one-line hint (subtitle content config) + rotating chevron accessory — the framework's
// subtitle row look, so the disclosure sits at the same height as every other row.
- (UITableViewCell *)advancedToggleCell {
    UITableViewCell *cell = [self chromeCell];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_ADVANCED_TEXT");
    cfg.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    cfg.secondaryText = SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_IDS_SHORTCODE_PERMALINK_SIZE_DATE_TEXT");
    cfg.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
    cfg.textToSecondaryTextVerticalPadding = 3.0;
    cell.contentConfiguration = cfg;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(self.advancedExpanded ? @"chevron.up" : @"chevron.down")]];
    chevron.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    cell.accessoryView = chevron;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKGalleryImportFormSection section = (SPKGalleryImportFormSection)indexPath.section;
    if (section == SPKGalleryImportFormSectionAdvanced && indexPath.row == 0) {
        [self toggleAdvanced];
        return;
    }
    if (section == SPKGalleryImportFormSectionLink && indexPath.row == 0) {
        [self pasteFromClipboard];
        return;
    }
    if (section == SPKGalleryImportFormSectionLink && indexPath.row == 1) {
        [self pushSourcePicker];
    }
}

- (void)pushSourcePicker {
    [self.view endEditing:YES];
    SPKGalleryImportSourcePickerViewController *picker = [[SPKGalleryImportSourcePickerViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.selectedSource = (SPKGallerySource)self.metadata.source;
    __weak typeof(self) weakSelf = self;
    picker.onPick = ^(SPKGallerySource source) {
        __strong typeof(weakSelf) self = weakSelf;
        if ((SPKGallerySource)self.metadata.source != source) {
            self.didModifyMetadata = YES;
        }
        self.metadata.source = (int16_t)source;
        [self.tableView reloadData];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)toggleAdvanced {
    [self.view endEditing:YES];
    self.advancedExpanded = !self.advancedExpanded;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SPKGalleryImportFormSectionAdvanced]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Date

- (void)dateChanged:(UIDatePicker *)picker {
    self.metadata.importCapturedDate = picker.date;
    self.didModifyMetadata = YES;
    // Reveal the Clear button now that a date is set.
    [self.tableView reloadData];
}

- (void)clearDate {
    if (self.metadata.importCapturedDate) {
        self.metadata.importCapturedDate = nil;
        self.didModifyMetadata = YES;
        [self.tableView reloadData];
    }
}

#pragma mark - Paste

- (void)pasteFromClipboard {
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length == 0) {
        SPKNotify(kSPKNotificationGalleryImport, SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_NOTHING_PASTE_TEXT"), SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_CLIPBOARD_EMPTY_TEXT"), @"info_filled", SPKNotificationToneInfo);
        return;
    }
    [self applyPastedLink:clip];
}

- (void)applyPastedLink:(NSString *)link {
    if (SPKParseInstagramLink(link, self.metadata)) {
        self.didModifyMetadata = YES;
        [self.view endEditing:YES];
        [self.tableView reloadData];
        UINotificationFeedbackGenerator *h = [[UINotificationFeedbackGenerator alloc] init];
        [h notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else {
        SPKNotify(kSPKNotificationGalleryImport, SPKL(@"GALLERY_IMPORT_LINK_UNREADABLE_TOAST"),
                  SPKL(@"GALLERY_GALLERY_IMPORT_METADATA_FORM_PASTE_POST_REEL_STORY_PROFILE_LINK_TEXT"), @"error_filled", SPKNotificationToneError);
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)spk_dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self applyString:textField.text forRow:(SPKGalleryImportFormRow)textField.tag];
    // The permalink preview footer refreshes on paste, source change, and re-entry — not on every
    // field end, so a field-to-field tap doesn't drop the new field's focus.
}

@end
