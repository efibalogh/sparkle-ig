#import "SPKStrings.h"
#import "../../Settings/SPKNewBadges.h"
#import "SPKFileNamesSettingsViewController.h"

#import "../../Settings/SPKAppIconCatalog.h"
#import "../../Settings/SPKSetting.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "../../Utils.h"
#import "SPKExportFileNaming.h"
#import "../UI/SPKFont.h"

static BOOL SPKFileNamesAnyDestinationEnabled(void) {
    return [SPKUtils getBoolPref:kSPKExportNamePhotosKey] || [SPKUtils getBoolPref:kSPKExportNameShareKey];
}

static UICommand *SPKFileNamesMenuCommand(NSString *title, NSString *defaultsKey, NSString *value) {
    return [UICommand commandWithTitle:title
                                 image:nil
                                action:@selector(menuChanged:)
                          propertyList:@{@"defaultsKey" : defaultsKey, @"value" : value}];
}

#pragma mark - Preview header

/// The example name as a file: the app icon as its thumbnail with the name under
/// it, above the page's rows rather than inside one.
@interface SPKFileNamePreviewView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *captionLabel;
- (void)refresh;
@end

@implementation SPKFileNamePreviewView

// The standard (light) look of an icon, whatever the current appearance: the
// appearance-aware previews list it first, and an asset image resolves it from a
// light trait collection.
static UIImage *SPKFileNamePreviewStandardImage(SPKAppIconItem *item) {
    if (!item)
        return nil;
    UIImage *image = [SPKAppIconCatalog appearancePreviewImagesForAppIcon:item].firstObject ?: [SPKAppIconCatalog imageForAppIcon:item];
    UITraitCollection *light = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    return [image.imageAsset imageWithTraitCollection:light] ?: image;
}

// Sparkle's icon when this build carries it, else Instagram's own, so the
// thumbnail is never empty.
static UIImage *SPKFileNamePreviewIcon(void) {
    return SPKFileNamePreviewStandardImage([SPKAppIconCatalog appIconWithIdentifier:@"sparkle"])
               ?: SPKFileNamePreviewStandardImage([SPKAppIconCatalog appIconWithIdentifier:@""]);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    static const CGFloat kIconSize = 84.0;

    _iconView = [[UIImageView alloc] initWithImage:SPKFileNamePreviewIcon()];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    _iconView.layer.cornerRadius = kIconSize * 0.2237;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _iconView.layer.borderColor = [SPKUtils SPKColor_InstagramSeparator].CGColor;
    _iconView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    [self addSubview:_iconView];

    _nameLabel = [UILabel new];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightMedium] to:_nameLabel];
    _nameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.numberOfLines = 0;
    // Names have no spaces to break at; wrap anywhere, as Files does.
    _nameLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [self addSubview:_nameLabel];

    _captionLabel = [UILabel new];
    _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _captionLabel.font = [SPKFont fontForStyle:SPKFontStyleFootnote];
    _captionLabel.adjustsFontForContentSizeCategory = YES;
    _captionLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    // Reads as the section footer it replaces.
    _captionLabel.textAlignment = NSTextAlignmentNatural;
    _captionLabel.numberOfLines = 0;
    _captionLabel.text = SPKL(@"DOWNLOADS_FILE_NAMES_PREVIEW_FOOTER");
    [self addSubview:_captionLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:16.0],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:kIconSize],
        [_iconView.heightAnchor constraintEqualToConstant:kIconSize],
        [_nameLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:10.0],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor constant:16.0],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor constant:-16.0],
        [_captionLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:14.0],
        [_captionLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_captionLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_captionLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4.0],
    ]];

    self.isAccessibilityElement = YES;
    [self refresh];
    return self;
}

- (void)refresh {
    NSString *name = SPKExportFileNamePreview();
    self.nameLabel.text = name;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", SPKL(@"DOWNLOADS_FILE_NAMES_PREVIEW_HEADER"), name];
    self.accessibilityHint = self.captionLabel.text;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // The border is a CGColor and does not follow appearance changes on its own.
    self.iconView.layer.borderColor = [SPKUtils SPKColor_InstagramSeparator].CGColor;
}

@end

/// Sizes a table header to its content at the table's width. Table headers do not
/// self-size, so this runs from the owner's layout pass.
static void SPKFileNamesFitTableHeader(UITableView *tableView) {
    UIView *header = tableView.tableHeaderView;
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (!header || width <= 0.0)
        return;
    CGSize fitting = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(CGRectGetHeight(header.frame) - fitting.height) < 0.5 && fabs(CGRectGetWidth(header.frame) - width) < 0.5)
        return;
    header.frame = CGRectMake(0.0, 0.0, width, fitting.height);
    tableView.tableHeaderView = header;
}

#pragma mark - Name parts editor

/// Every part in one list: a check circle includes it in the name, the grabber
/// sets its place. Checked parts keep their saved order; unchecked ones follow.
@interface SPKFileNamePartsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *parts;
@property (nonatomic, strong) NSMutableSet<NSString *> *enabledParts;
@property (nonatomic, strong) SPKFileNamePreviewView *previewView;
@end

@implementation SPKFileNamePartsViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = SPKL(@"DOWNLOADS_FILE_NAMES_PARTS_TITLE");
        _parts = [NSMutableArray array];
        _enabledParts = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    // Always editing, for the grabbers; rows still take taps to toggle.
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    self.previewView = [[SPKFileNamePreviewView alloc] initWithFrame:CGRectZero];
    self.tableView.tableHeaderView = self.previewView;
    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SPKFileNamesFitTableHeader(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Read on every appearance: another account's namespace may have been active
    // when this page was built.
    NSArray<NSString *> *enabled = SPKExportNameEnabledParts();
    self.parts = [enabled mutableCopy];
    for (NSString *part in SPKExportNameAllParts()) {
        if (![self.parts containsObject:part])
            [self.parts addObject:part];
    }
    self.enabledParts = [NSMutableSet setWithArray:enabled];
    [self.tableView reloadData];
    [self reloadPreview];
}

- (void)persist {
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *part in self.parts) {
        if ([self.enabledParts containsObject:part])
            [ordered addObject:part];
    }
    SPKExportNameSetEnabledParts(ordered);
}

- (void)reloadPreview {
    [self.previewView refresh];
    // The name can take another line.
    [self.view setNeedsLayout];
}

- (UIImage *)checkImageForEnabled:(BOOL)enabled {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:(enabled ? @"checkmark.circle.fill" : @"circle") withConfiguration:config];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.parts.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return SPKL(@"DOWNLOADS_FILE_NAMES_PARTS_TITLE");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return SPKL(@"DOWNLOADS_FILE_NAMES_PARTS_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *config = cell.defaultContentConfiguration;
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    config.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];

    NSString *part = self.parts[indexPath.row];
    BOOL enabled = [self.enabledParts containsObject:part];
    config.text = SPKExportNamePartTitle(part);
    config.image = [self checkImageForEnabled:enabled];
    config.imageProperties.tintColor = enabled ? [SPKUtils SPKColor_InstagramBlue] : [SPKUtils SPKColor_InstagramTertiaryText];
    cell.contentConfiguration = config;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsReorderControl = YES;
    cell.shouldIndentWhileEditing = NO;
    cell.accessibilityTraits = enabled ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSString *part = self.parts[sourceIndexPath.row];
    [self.parts removeObjectAtIndex:sourceIndexPath.row];
    [self.parts insertObject:part atIndex:destinationIndexPath.row];
    [self persist];
    // After UIKit settles the move; reloading inside it fights the animation.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadPreview];
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *part = self.parts[indexPath.row];
    if ([self.enabledParts containsObject:part]) {
        // A name needs at least one part.
        if (self.enabledParts.count <= 1) {
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning];
            return;
        }
        [self.enabledParts removeObject:part];
    } else {
        [self.enabledParts addObject:part];
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self persist];
    [self.tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    [self reloadPreview];
}

@end

#pragma mark - File Names page

@implementation SPKFileNamesSettingsViewController

+ (SPKSetting *)navigationSetting {
    SPKSetting *row = [SPKSetting navigationCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_TITLE")
                                                 subtitle:@""
                                                     icon:SPKSettingsIcon(@"text")
                                           viewController:[SPKFileNamesSettingsViewController new]];
    row.accessoryTextProvider = ^NSString * {
        return SPKFileNamesAnyDestinationEnabled() ? SPKL(@"MENU_ON") : SPKL(@"MENU_OFF");
    };
    row.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_HELP");
    row.searchKeywords = @"file name filename rename username date timestamp photos share files";
    SPKSettingMarkedNewWithID(row, @"v1.7.0", @"downloads_file_names_page");
    row.searchSectionsProvider = ^NSArray * {
        return [SPKFileNamesSettingsViewController searchSections];
    };
    return row;
}

+ (UIMenu *)separatorMenu {
    return [UIMenu menuWithChildren:@[
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_SEPARATOR_UNDERSCORE"), kSPKExportNameSeparatorKey, @"underscore"),
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_SEPARATOR_HYPHEN"), kSPKExportNameSeparatorKey, @"dash"),
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_SEPARATOR_SPACE"), kSPKExportNameSeparatorKey, @"space"),
    ]];
}

+ (UIMenu *)dateStyleMenu {
    return [UIMenu menuWithChildren:@[
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_DATE_STYLE_READABLE"), kSPKExportNameDateStyleKey, @"readable"),
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_DATE_STYLE_COMPACT"), kSPKExportNameDateStyleKey, @"compact"),
        SPKFileNamesMenuCommand(SPKL(@"DOWNLOADS_FILE_NAMES_DATE_STYLE_DATE"), kSPKExportNameDateStyleKey, @"date"),
    ]];
}

+ (NSArray *)contentSections {
    SPKSetting *photos = [SPKSetting switchCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_PHOTOS_TITLE")
                                                    icon:SPKSettingsIcon(@"photo_gallery")
                                             defaultsKey:kSPKExportNamePhotosKey];
    photos.reloadsTableOnSwitchChange = YES;
    photos.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_PHOTOS_HELP");

    SPKSetting *share = [SPKSetting switchCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_SHARE_TITLE")
                                                   icon:SPKSettingsIcon(@"share")
                                            defaultsKey:kSPKExportNameShareKey];
    share.reloadsTableOnSwitchChange = YES;
    share.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_SHARE_HELP");

    SPKSetting *parts = [SPKSetting navigationCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_PARTS_TITLE")
                                                   subtitle:@""
                                                       icon:SPKSettingsIcon(@"text")
                                             viewController:[SPKFileNamePartsViewController new]];
    parts.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_PARTS_HELP");
    parts.enabledProvider = ^BOOL {
        return SPKFileNamesAnyDestinationEnabled();
    };

    SPKSetting *separator = [SPKSetting menuCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_SEPARATOR_TITLE")
                                                     icon:SPKSettingsIcon(@"left_right")
                                                     menu:[self separatorMenu]];
    separator.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_SEPARATOR_HELP");
    separator.enabledProvider = parts.enabledProvider;

    SPKSetting *dateStyle = [SPKSetting menuCellWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_DATE_STYLE_TITLE")
                                                     icon:SPKSettingsIcon(@"calendar")
                                                     menu:[self dateStyleMenu]];
    dateStyle.helpText = SPKL(@"DOWNLOADS_FILE_NAMES_DATE_STYLE_HELP");
    dateStyle.enabledProvider = parts.enabledProvider;

    return @[
        SPKTopicSection(SPKL(@"DOWNLOADS_FILE_NAMES_USE_FOR_HEADER"), @[ photos, share ], nil),
        SPKTopicSection(SPKL(@"DOWNLOADS_FILE_NAMES_FORMAT_HEADER"), @[ parts, separator, dateStyle ], nil),
    ];
}

+ (NSArray *)searchSections {
    return [self contentSections];
}

- (instancetype)init {
    return [super initWithTitle:SPKL(@"DOWNLOADS_FILE_NAMES_TITLE") sections:[[self class] contentSections] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = [[SPKFileNamePreviewView alloc] initWithFrame:CGRectZero];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SPKFileNamesFitTableHeader(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPreview];
}

- (void)refreshPreview {
    SPKFileNamePreviewView *preview = (SPKFileNamePreviewView *)self.tableView.tableHeaderView;
    if ([preview isKindOfClass:SPKFileNamePreviewView.class]) {
        [preview refresh];
        [self.view setNeedsLayout];
    }
}

- (void)menuChanged:(UICommand *)command {
    [super menuChanged:command];
    // The preview reads the separator and date style.
    [self refreshPreview];
}

@end
