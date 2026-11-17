#import "SPKStrings.h"
#import "SPKGalleryFilterViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKMediaChrome.h"
#import "SPKGalleryHiddenSources.h"
#import "SPKGalleryUserPickerViewController.h"
#import "../UI/SPKFont.h"

static CGFloat const kSPKGalleryFilterChipIconPointSize = 14.0;

@interface SPKGalleryFilterChip : UIButton
@property (nonatomic, assign) NSInteger itemTag;
@property (nonatomic, assign) BOOL selectedChip;
@property (nonatomic, copy, nullable) NSString *baseIconName;
- (void)updateChipAppearance;
@end

@implementation SPKGalleryFilterChip

- (instancetype)initWithTag:(NSInteger)tag {
    if ((self = [super initWithFrame:CGRectZero])) {
        _itemTag = tag;
        self.layer.cornerRadius = 12;
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        self.titleLabel.font = [SPKFont fontForStyle:SPKFontStyleCallout weight:UIFontWeightMedium];
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.titleLabel.minimumScaleFactor = 0.78;
        [self updateChipAppearance];
    }
    return self;
}

- (void)setSelectedChip:(BOOL)selectedChip {
    _selectedChip = selectedChip;
    [self updateChipAppearance];
}

- (void)updateChipAppearance {
    if (self.selectedChip) {
        self.backgroundColor = [[SPKUtils SPKColor_InstagramBlue] colorWithAlphaComponent:0.18];
        self.tintColor = [SPKUtils SPKColor_InstagramBlue];
        [self setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];

        if (self.baseIconName) {
            NSString *filledName = [self.baseIconName stringByAppendingString:@"_filled"];
            UIImage *icon = nil;
            if ([SPKAssetUtils resolvedInstagramIconNameForName:filledName]) {
                icon = [SPKAssetUtils instagramIconNamed:filledName pointSize:kSPKGalleryFilterChipIconPointSize];
            } else {
                icon = [SPKAssetUtils instagramIconNamed:self.baseIconName pointSize:kSPKGalleryFilterChipIconPointSize];
            }
            [self setImage:icon forState:UIControlStateNormal];
        }
    } else {
        self.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        self.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [self setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];

        if (self.baseIconName) {
            UIImage *icon = [SPKAssetUtils instagramIconNamed:self.baseIconName pointSize:kSPKGalleryFilterChipIconPointSize];
            [self setImage:icon forState:UIControlStateNormal];
        }
    }
}

@end

@interface SPKGalleryFilterViewController ()

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) NSMutableArray<SPKGalleryFilterChip *> *typeChips;
@property (nonatomic, strong) NSMutableArray<SPKGalleryFilterChip *> *sourceChips;
@property (nonatomic, strong) UILabel *usernameSectionTitle;
@property (nonatomic, strong) UIControl *favoritesRow;
@property (nonatomic, strong) UIImageView *favoritesLeadingIcon;
@property (nonatomic, strong) UILabel *favoritesLabel;
@property (nonatomic, strong) UIControl *clearRow;
@property (nonatomic, strong) UIImageView *clearLeadingIcon;
@property (nonatomic, strong) UILabel *clearLabel;
@property (nonatomic, strong) UILabel *usernameRowLabel;

@end

@implementation SPKGalleryFilterViewController

+ (NSPredicate *)predicateForTypes:(NSSet<NSNumber *> *)types
                           sources:(NSSet<NSNumber *> *)sources
                     favoritesOnly:(BOOL)favoritesOnly
                         usernames:(NSSet<NSString *> *)usernames
                        folderPath:(NSString *)folderPath {
    return [self predicateForTypes:types sources:sources favoritesOnly:favoritesOnly usernames:usernames folderPath:folderPath scopeToFolder:YES];
}

+ (NSPredicate *)predicateForTypes:(NSSet<NSNumber *> *)types
                           sources:(NSSet<NSNumber *> *)sources
                     favoritesOnly:(BOOL)favoritesOnly
                         usernames:(NSSet<NSString *> *)usernames
                        folderPath:(NSString *)folderPath
                     scopeToFolder:(BOOL)scopeToFolder {
    NSMutableArray<NSPredicate *> *parts = [NSMutableArray new];
    if (types.count > 0) {
        NSArray *typeList = [types.allObjects sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES] ]];
        [parts addObject:[NSPredicate predicateWithFormat:@"mediaType IN %@", typeList]];
    }
    if (sources.count > 0) {
        NSArray *sourceList = [sources.allObjects sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES] ]];
        [parts addObject:[NSPredicate predicateWithFormat:@"source IN %@", sourceList]];
    }
    if (favoritesOnly) {
        [parts addObject:[NSPredicate predicateWithFormat:@"isFavorite == %@", @(YES)]];
    }
    if (usernames.count > 0) {
        NSMutableArray<NSPredicate *> *usernameParts = [NSMutableArray array];
        for (NSString *username in usernames) {
            if (username.length == 0)
                continue;
            [usernameParts addObject:[NSPredicate predicateWithFormat:@"sourceUsername ==[c] %@", username]];
        }
        if (usernameParts.count > 0) {
            [parts addObject:[NSCompoundPredicate orPredicateWithSubpredicates:usernameParts]];
        }
    }
    if (scopeToFolder) {
        if (folderPath.length > 0) {
            [parts addObject:[NSPredicate predicateWithFormat:@"folderPath == %@", folderPath]];
        } else {
            // Root: only items not stored inside a folder (nil or empty string).
            [parts addObject:[NSPredicate predicateWithFormat:@"(folderPath == nil) OR (folderPath == %@)", @""]];
        }
    }
    if (parts.count == 0)
        return nil;
    return [NSCompoundPredicate andPredicateWithSubpredicates:parts];
}

- (instancetype)init {
    if ((self = [super init])) {
        _filterTypes = [NSMutableSet new];
        _filterSources = [NSMutableSet new];
        _typeChips = [NSMutableArray new];
        _sourceChips = [NSMutableArray new];
        _filterUsernames = [NSMutableSet new];
        _availableUsernames = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    [self setupNavigationBar];
    [self setupContent];
    [self updateClearRowState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateScrollAvailability];
}

// Height the content needs at `width`: the content stack's fitting height plus
// its 12pt top/bottom insets. Excludes the nav bar and bottom safe area, which
// the presenter adds.
- (CGFloat)spkContentHeightForWidth:(CGFloat)width {
    [self loadViewIfNeeded];
    CGFloat innerWidth = MAX(0.0, width - 32.0); // 16pt leading + 16pt trailing
    CGFloat stackHeight = [self.contentStack systemLayoutSizeFittingSize:CGSizeMake(innerWidth, 0.0)
                                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                              .height;
    return 12.0 + stackHeight + 12.0;
}

- (void)setupNavigationBar {
    self.title = SPKL(@"GALLERY_GALLERY_FILTER_FILTER_TEXT");
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = nil;
}

- (void)setupContent {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.bounces = NO;
    self.scrollView.scrollEnabled = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 10;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentStack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor
                                                    constant:12],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor
                                                        constant:16],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor
                                                         constant:-16],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor
                                                       constant:-12],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor
                                                      constant:-32],
    ]];

    [self.contentStack addArrangedSubview:[self sectionTitle:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_TYPE_TEXT")]];
    [self.contentStack addArrangedSubview:[self createTypeRow]];
    [self.contentStack addArrangedSubview:[self sectionTitle:SPKL(@"GALLERY_GALLERY_FILTER_SOURCE_TEXT")]];
    [self.contentStack addArrangedSubview:[self createSourceGrid]];
    if (self.availableUsernames.count > 0) {
        self.usernameSectionTitle = [self sectionTitle:SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT")];
        [self updateUsernameSectionTitle];
        [self.contentStack addArrangedSubview:self.usernameSectionTitle];
        [self.contentStack addArrangedSubview:[self createUsernameRow]];
    }
    [self.contentStack addArrangedSubview:[self sectionTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_OPTIONS_TEXT")]];
    [self.contentStack addArrangedSubview:[self createOptionsRow]];
}

- (BOOL)isPresentedAtFullscreenHeight {
    UIView *presentedView = self.navigationController.view ?: self.view;
    UIView *containerView = self.presentationController.containerView ?: presentedView.superview;
    if (!containerView)
        return NO;

    CGFloat presentedHeight = CGRectGetHeight(presentedView.bounds);
    CGFloat containerHeight = CGRectGetHeight(containerView.bounds);
    if (presentedHeight <= 0.0 || containerHeight <= 0.0)
        return NO;
    return presentedHeight >= floor(containerHeight * 0.92);
}

- (void)updateScrollAvailability {
    CGFloat viewportHeight = CGRectGetHeight(self.scrollView.bounds);
    CGFloat contentHeight = self.scrollView.contentSize.height;
    BOOL contentOverflows = contentHeight > viewportHeight + 1.0;
    BOOL shouldScroll = contentOverflows && [self isPresentedAtFullscreenHeight];
    self.scrollView.scrollEnabled = shouldScroll;
    self.scrollView.bounces = shouldScroll;
    self.scrollView.alwaysBounceVertical = shouldScroll;
    self.scrollView.showsVerticalScrollIndicator = shouldScroll;
}

- (UILabel *)sectionTitle:(NSString *)title {
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption1 weight:UIFontWeightSemibold] to:l];
    l.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    return l;
}

- (UIView *)createTypeRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;

    NSArray *defs = @[
        @{@"label" : SPKL(@"GALLERY_GALLERY_FILTER_IMAGES_TITLE"), @"resource" : @"photo", @"tag" : @(SPKGalleryMediaTypeImage)},
        @{@"label" : SPKL(@"GALLERY_GALLERY_FILTER_VIDEOS_TITLE"), @"resource" : @"video", @"tag" : @(SPKGalleryMediaTypeVideo)},
        @{@"label" : SPKL(@"COMMON_MEDIA_TYPE_AUDIO"), @"resource" : @"audio", @"tag" : @(SPKGalleryMediaTypeAudio)},
    ];
    for (NSDictionary *d in defs) {
        NSInteger tag = [d[@"tag"] integerValue];
        SPKGalleryFilterChip *chip = [[SPKGalleryFilterChip alloc] initWithTag:tag];
        chip.baseIconName = d[@"resource"];
        [chip setTitle:d[@"label"] forState:UIControlStateNormal];
        chip.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
        chip.selectedChip = [self.filterTypes containsObject:@(tag)];
        [chip addTarget:self action:@selector(typeChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chip.heightAnchor constraintEqualToConstant:44].active = YES;
        [row addArrangedSubview:chip];
        [self.typeChips addObject:chip];
    }
    return row;
}

- (UIView *)createSourceGrid {
    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 8;

    NSArray *sources = @[
        @(SPKGallerySourceFeed),
        @(SPKGallerySourceStories),
        @(SPKGallerySourceReels),
        @(SPKGallerySourceProfile),
        @(SPKGallerySourceDMs),
        @(SPKGallerySourceThumbnail),
        @(SPKGallerySourceInstants),
        @(SPKGallerySourceAudioPage),
        @(SPKGallerySourceComments),
    ];

    NSInteger columns = 3;
    NSInteger visibleIndex = 0;
    UIStackView *currentRow = nil;
    for (NSInteger i = 0; i < sources.count; i++) {
        if (SPKGallerySourceIsHidden([sources[i] integerValue]))
            continue;
        if (visibleIndex % columns == 0) {
            currentRow = [[UIStackView alloc] init];
            currentRow.axis = UILayoutConstraintAxisHorizontal;
            currentRow.spacing = 8;
            currentRow.distribution = UIStackViewDistributionFillEqually;
            [grid addArrangedSubview:currentRow];
        }

        SPKGallerySource src = (SPKGallerySource)[sources[i] integerValue];
        SPKGalleryFilterChip *chip = [[SPKGalleryFilterChip alloc] initWithTag:src];
        chip.baseIconName = [SPKGalleryFile symbolNameForSource:src];
        [chip setTitle:[SPKGalleryFile labelForSource:src] forState:UIControlStateNormal];
        chip.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
        chip.selectedChip = [self.filterSources containsObject:@(src)];
        [chip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chip.heightAnchor constraintEqualToConstant:44].active = YES;
        [currentRow addArrangedSubview:chip];
        [self.sourceChips addObject:chip];
        visibleIndex += 1;
    }

    // Pad last row so chips have equal width
    while (currentRow && currentRow.arrangedSubviews.count % columns != 0) {
        UIView *spacer = [[UIView alloc] init];
        [currentRow addArrangedSubview:spacer];
    }
    return grid;
}

// A disclosure row that pushes a full-screen searchable multi-select picker —
// scales to hundreds of users, unlike the old horizontal chip strip.
- (UIView *)createUsernameRow {
    UIControl *row = [[UIControl alloc] init];
    row.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    row.layer.cornerRadius = 12;
    [row.heightAnchor constraintEqualToConstant:50].active = YES;
    [row addTarget:self action:@selector(usernameRowTapped) forControlEvents:UIControlEventTouchUpInside];

    UIImage *rowIcon = [SPKAssetUtils instagramIconNamed:@"mention" pointSize:18.0];
    UIImageView *icon = [[UIImageView alloc] initWithImage:rowIcon];
    icon.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.font = [SPKFont fontForStyle:SPKFontStyleCallout weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.minimumScaleFactor = 0.78;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    self.usernameRowLabel = label;

    UIImage *chevronImg = [SPKAssetUtils instagramIconNamed:@"chevron_right" pointSize:14.0];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:chevronImg];
    chevron.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                           constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:18],
        [icon.heightAnchor constraintEqualToConstant:18],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                            constant:10],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor
                                                           constant:8],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor
                                               constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],
        [chevron.heightAnchor constraintEqualToConstant:14],
    ]];
    [self updateUsernameRowLabel];
    return row;
}

- (void)updateUsernameRowLabel {
    NSUInteger count = self.filterUsernames.count;
    self.usernameRowLabel.text = count > 0
                                     ? [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_FILTER_VALUE_USER_VALUE_SELECTED_FORMAT"), SPKLP(@"COMMON_USER_COUNT", (NSInteger)count)]
                                     : SPKL(@"GALLERY_GALLERY_FILTER_USERS_TEXT");
    self.usernameRowLabel.textColor = count > 0
                                          ? [SPKUtils SPKColor_InstagramPrimaryText]
                                          : [SPKUtils SPKColor_InstagramSecondaryText];
}

- (void)usernameRowTapped {
    SPKGalleryUserPickerViewController *picker = [[SPKGalleryUserPickerViewController alloc]
        initWithUsernames:self.availableUsernames
                 selected:self.filterUsernames];
    __weak typeof(self) weakSelf = self;
    picker.selectionChanged = ^(NSSet<NSString *> *selected) {
        weakSelf.filterUsernames = [selected mutableCopy];
        [weakSelf updateUsernameRowLabel];
        [weakSelf updateUsernameSectionTitle];
        [weakSelf notifyFilterStateChanged];
    };
    // Present as its own full-height sheet rather than pushing into the filter's
    // single-size sheet, so the searchable list gets full height and the filter
    // sheet keeps one fixed size.
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        nav.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (UIView *)createFavoritesRow {
    UIControl *row = [[UIControl alloc] init];
    row.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    row.layer.cornerRadius = 12;
    [row.heightAnchor constraintEqualToConstant:50].active = YES;
    [row addTarget:self action:@selector(favoritesRowTapped) forControlEvents:UIControlEventTouchUpInside];

    UIImage *favRowIcon = [SPKAssetUtils instagramIconNamed:@"heart" pointSize:18.0];
    UIImageView *icon = [[UIImageView alloc] initWithImage:favRowIcon];
    icon.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.text = SPKL(@"GALLERY_GALLERY_FILTER_FAVORITES_TEXT");
    label.font = [SPKFont fontForStyle:SPKFontStyleCallout weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.minimumScaleFactor = 0.78;
    label.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    self.favoritesRow = row;
    self.favoritesLeadingIcon = icon;
    self.favoritesLabel = label;
    [self updateFavoritesRowAppearance];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                           constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:18],
        [icon.heightAnchor constraintEqualToConstant:18],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                            constant:10],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor
                                                       constant:-12],
    ]];
    return row;
}

- (UIView *)createOptionsRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    [row addArrangedSubview:[self createFavoritesRow]];
    [row addArrangedSubview:[self createClearRow]];
    return row;
}

- (UIView *)createClearRow {
    UIControl *row = [[UIControl alloc] init];
    row.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    row.layer.cornerRadius = 12;
    [row.heightAnchor constraintEqualToConstant:50].active = YES;
    [row addTarget:self action:@selector(clearFilters) forControlEvents:UIControlEventTouchUpInside];

    UIImage *clearIcon = [SPKAssetUtils instagramIconNamed:@"backspace" pointSize:18.0];
    UIImageView *icon = [[UIImageView alloc] initWithImage:clearIcon];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.text = SPKL(@"GALLERY_GALLERY_FILTER_CLEAR_FILTERS_TEXT");
    label.font = [SPKFont fontForStyle:SPKFontStyleCallout weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.minimumScaleFactor = 0.78;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    self.clearRow = row;
    self.clearLeadingIcon = icon;
    self.clearLabel = label;

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                           constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:18],
        [icon.heightAnchor constraintEqualToConstant:18],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                            constant:10],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor
                                                       constant:-12],
    ]];

    return row;
}

#pragma mark - Actions

- (void)typeChipTapped:(SPKGalleryFilterChip *)chip {
    NSNumber *tag = @(chip.itemTag);
    if ([self.filterTypes containsObject:tag]) {
        [self.filterTypes removeObject:tag];
        chip.selectedChip = NO;
    } else {
        [self.filterTypes addObject:tag];
        chip.selectedChip = YES;
    }
    [self notifyFilterStateChanged];
}

- (void)sourceChipTapped:(SPKGalleryFilterChip *)chip {
    NSNumber *tag = @(chip.itemTag);
    if ([self.filterSources containsObject:tag]) {
        [self.filterSources removeObject:tag];
        chip.selectedChip = NO;
    } else {
        [self.filterSources addObject:tag];
        chip.selectedChip = YES;
    }
    [self notifyFilterStateChanged];
}

- (void)updateUsernameSectionTitle {
    // Static header like the other sections; the selection count lives on the row
    // itself, so don't duplicate it here.
    if (!self.usernameSectionTitle)
        return;
    self.usernameSectionTitle.text = SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT");
}

- (void)favoritesRowTapped {
    self.filterFavoritesOnly = !self.filterFavoritesOnly;
    [self updateFavoritesRowAppearance];
    [self notifyFilterStateChanged];
}

- (void)updateFavoritesRowAppearance {
    if (!self.favoritesRow || !self.favoritesLeadingIcon || !self.favoritesLabel)
        return;

    if (self.filterFavoritesOnly) {
        UIColor *accent = [SPKUtils SPKColor_InstagramFavorite];
        self.favoritesRow.backgroundColor = [accent colorWithAlphaComponent:0.2];
        self.favoritesLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        self.favoritesLeadingIcon.image = [SPKAssetUtils instagramIconNamed:@"heart_filled" pointSize:14.0];
        self.favoritesLeadingIcon.tintColor = accent;
    } else {
        self.favoritesRow.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        self.favoritesLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        self.favoritesLeadingIcon.image = [SPKAssetUtils instagramIconNamed:@"heart" pointSize:14.0];
        self.favoritesLeadingIcon.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    }
}

- (void)updateClearRowState {
    if (!self.clearRow || !self.clearLeadingIcon || !self.clearLabel)
        return;

    BOOL active = [self hasActiveFilters];
    self.clearRow.userInteractionEnabled = active;
    self.clearRow.backgroundColor = active
                                        ? [[SPKUtils SPKColor_InstagramDestructive] colorWithAlphaComponent:0.16]
                                        : [SPKUtils SPKColor_InstagramSecondaryBackground];
    self.clearLeadingIcon.tintColor = active ? [SPKUtils SPKColor_InstagramDestructive] : [SPKUtils SPKColor_InstagramTertiaryText];
    self.clearLabel.textColor = active ? [SPKUtils SPKColor_InstagramDestructive] : [SPKUtils SPKColor_InstagramTertiaryText];
}

- (BOOL)hasActiveFilters {
    return self.filterTypes.count > 0 || self.filterSources.count > 0 || self.filterFavoritesOnly || self.filterUsernames.count > 0;
}

- (void)notifyFilterStateChanged {
    [self updateClearRowState];
    if ([self.delegate respondsToSelector:@selector(filterController:didApplyTypes:sources:favoritesOnly:usernames:)]) {
        [self.delegate filterController:self
                          didApplyTypes:[self.filterTypes copy]
                                sources:[self.filterSources copy]
                          favoritesOnly:self.filterFavoritesOnly
                              usernames:[self.filterUsernames copy]];
    }
}

- (void)clearFilters {
    if (![self hasActiveFilters])
        return;
    [self.filterTypes removeAllObjects];
    [self.filterSources removeAllObjects];
    self.filterFavoritesOnly = NO;
    [self.filterUsernames removeAllObjects];
    [self updateFavoritesRowAppearance];
    for (SPKGalleryFilterChip *c in self.typeChips)
        c.selectedChip = NO;
    for (SPKGalleryFilterChip *c in self.sourceChips)
        c.selectedChip = NO;
    [self updateUsernameSectionTitle];
    [self updateUsernameRowLabel];
    if ([self.delegate respondsToSelector:@selector(filterControllerDidClear:)]) {
        [self.delegate filterControllerDidClear:self];
    } else {
        [self notifyFilterStateChanged];
    }
    [self updateClearRowState];
}

@end
