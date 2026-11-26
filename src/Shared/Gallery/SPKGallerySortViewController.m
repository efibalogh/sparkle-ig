#import "SPKStrings.h"
#import "SPKGallerySortViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKFont.h"

static NSString *SPKGallerySortResourceSymbol(SPKGallerySortMode mode) {
    switch (mode) {
    case SPKGallerySortModeDateAddedDesc:
    case SPKGallerySortModeDateAddedAsc:
        return @"calendar";
    case SPKGallerySortModeNameAsc:
    case SPKGallerySortModeNameDesc:
        return @"text";
    case SPKGallerySortModeSizeDesc:
        return @"size_large";
    case SPKGallerySortModeSizeAsc:
        return @"size_small";
    case SPKGallerySortModeTypeAsc:
    case SPKGallerySortModeTypeDesc:
        return @"photo_gallery";
    }
    return @"sort";
}

@interface SPKGallerySortChip : UIButton
@property (nonatomic, assign) SPKGallerySortMode mode;
@property (nonatomic, assign) BOOL selectedChip;
- (void)updateChipAppearance;
@end

@implementation SPKGallerySortChip

- (instancetype)initWithMode:(SPKGallerySortMode)mode {
    if ((self = [super initWithFrame:CGRectZero])) {
        _mode = mode;
        self.layer.cornerRadius = 12;
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightMedium] to:self.titleLabel];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
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
    } else {
        self.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        self.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [self setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];
    }
}

@end

@interface SPKGallerySortViewController ()
@property (nonatomic, strong) NSMutableArray<SPKGallerySortChip *> *sortChips;
@property (nonatomic, strong) NSMutableArray<UIButton *> *groupChips;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation SPKGallerySortViewController

+ (NSArray<NSSortDescriptor *> *)sortDescriptorsForMode:(SPKGallerySortMode)mode {
    return [self sortDescriptorsForMode:mode groupByMediaType:NO];
}

+ (NSArray<NSSortDescriptor *> *)sortDescriptorsForMode:(SPKGallerySortMode)mode groupByMediaType:(BOOL)groupByMediaType {
    NSMutableArray<NSSortDescriptor *> *descriptors = [NSMutableArray array];
    if (groupByMediaType || mode == SPKGallerySortModeTypeAsc || mode == SPKGallerySortModeTypeDesc) {
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"mediaType" ascending:YES]];
    }

    switch (mode) {
    case SPKGallerySortModeDateAddedDesc:
    case SPKGallerySortModeTypeAsc:
    case SPKGallerySortModeTypeDesc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO]];
        break;
    case SPKGallerySortModeDateAddedAsc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:YES]];
        break;
    case SPKGallerySortModeNameAsc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"relativePath" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]];
        break;
    case SPKGallerySortModeNameDesc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"relativePath" ascending:NO selector:@selector(localizedCaseInsensitiveCompare:)]];
        break;
    case SPKGallerySortModeSizeDesc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"fileSize" ascending:NO]];
        break;
    case SPKGallerySortModeSizeAsc:
        [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"fileSize" ascending:YES]];
        break;
    }
    return descriptors.count ? descriptors : @[ [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO] ];
}

+ (NSString *)labelForMode:(SPKGallerySortMode)mode {
    switch (mode) {
    case SPKGallerySortModeDateAddedDesc:
        return SPKL(@"GALLERY_GALLERY_SORT_NEWEST_FIRST_TEXT");
    case SPKGallerySortModeDateAddedAsc:
        return SPKL(@"GALLERY_GALLERY_SORT_OLDEST_FIRST_TEXT");
    case SPKGallerySortModeNameAsc:
        return SPKL(@"GALLERY_GALLERY_SORT_NAME_Z_TEXT");
    case SPKGallerySortModeNameDesc:
        return SPKL(@"GALLERY_SORT_NAME_DESCENDING_TITLE");
    case SPKGallerySortModeSizeDesc:
        return SPKL(@"GALLERY_GALLERY_SORT_LARGEST_FIRST_TEXT");
    case SPKGallerySortModeSizeAsc:
        return SPKL(@"GALLERY_GALLERY_SORT_SMALLEST_FIRST_TEXT");
    case SPKGallerySortModeTypeAsc:
    case SPKGallerySortModeTypeDesc:
        return SPKL(@"GALLERY_GALLERY_SORT_NEWEST_FIRST_TEXT");
    }
    return SPKL(@"GALLERY_GALLERY_SORT_NEWEST_FIRST_TEXT");
}

- (instancetype)init {
    if ((self = [super init])) {
        _sortChips = [NSMutableArray new];
        _groupChips = [NSMutableArray new];
        _currentSortMode = SPKGallerySortModeDateAddedDesc;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    [self setupNavigationBar];
    [self setupContent];
}

- (void)setupNavigationBar {
    self.title = SPKL(@"MENU_SORT");
}

// Height the content needs at `width`: the stack's fitting height plus its top
// (14) and bottom (12) margins. Excludes the nav bar and bottom safe area, which
// the presenter adds.
- (CGFloat)spkContentHeightForWidth:(CGFloat)width {
    if (!self.contentStack) {
        [self loadViewIfNeeded];
    }
    CGFloat innerWidth = MAX(0.0, width - 40.0); // 20pt leading + 20pt trailing
    CGFloat stackHeight = [self.contentStack systemLayoutSizeFittingSize:CGSizeMake(innerWidth, 0.0)
                                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                              .height;
    return 14.0 + stackHeight + 12.0;
}

- (void)setupContent {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    self.contentStack = stack;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor
                                        constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                            constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                             constant:-20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor
                                                     constant:-20],
    ]];

    [stack addArrangedSubview:[self sectionTitle:SPKL(@"GALLERY_GALLERY_SORT_ORDER_TEXT")]];
    NSArray<NSArray<NSNumber *> *> *rows = @[
        @[ @(SPKGallerySortModeDateAddedDesc), @(SPKGallerySortModeDateAddedAsc) ],
        @[ @(SPKGallerySortModeNameAsc), @(SPKGallerySortModeNameDesc) ],
        @[ @(SPKGallerySortModeSizeDesc), @(SPKGallerySortModeSizeAsc) ],
    ];

    for (NSInteger i = 0; i < rows.count; i++) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;

        for (NSNumber *modeNum in rows[i]) {
            SPKGallerySortMode mode = (SPKGallerySortMode)modeNum.integerValue;
            SPKGallerySortChip *chip = [[SPKGallerySortChip alloc] initWithMode:mode];
            [chip setTitle:[SPKGallerySortViewController labelForMode:mode] forState:UIControlStateNormal];
            UIImage *icon = [SPKAssetUtils instagramIconNamed:SPKGallerySortResourceSymbol(mode) pointSize:14.0];
            [chip setImage:icon forState:UIControlStateNormal];
            chip.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
            chip.selectedChip = (mode == self.currentSortMode);
            [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
            [chip.heightAnchor constraintEqualToConstant:44].active = YES;
            [row addArrangedSubview:chip];
            [self.sortChips addObject:chip];
        }
        [stack addArrangedSubview:row];
    }

    [stack addArrangedSubview:[self sectionTitle:SPKL(@"GALLERY_GALLERY_SORT_GROUPING_TEXT")]];
    UIStackView *groupRow = [[UIStackView alloc] init];
    groupRow.axis = UILayoutConstraintAxisHorizontal;
    groupRow.spacing = 10;
    groupRow.distribution = UIStackViewDistributionFillEqually;
    [groupRow addArrangedSubview:[self groupChipWithTitle:SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_NONE_TEXT") icon:@"circle_off" selected:!self.currentGroupByMediaType tag:0]];
    [groupRow addArrangedSubview:[self groupChipWithTitle:SPKL(@"GALLERY_GALLERY_SORT_MEDIA_TYPE_TEXT") icon:@"photo_gallery" selected:self.currentGroupByMediaType tag:1]];
    [stack addArrangedSubview:groupRow];
}

- (UILabel *)sectionTitle:(NSString *)title {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption1 weight:UIFontWeightSemibold] to:label];
    label.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    return label;
}

- (UIButton *)groupChipWithTitle:(NSString *)title icon:(NSString *)icon selected:(BOOL)selected tag:(NSInteger)tag {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.tag = tag;
    chip.layer.cornerRadius = 12;
    chip.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightMedium] to:chip.titleLabel];
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    chip.titleLabel.minimumScaleFactor = 0.78;
    [chip setTitle:title forState:UIControlStateNormal];
    [chip setImage:[SPKAssetUtils instagramIconNamed:icon pointSize:14.0] forState:UIControlStateNormal];
    chip.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [chip.heightAnchor constraintEqualToConstant:44].active = YES;
    [chip addTarget:self action:@selector(groupChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.groupChips addObject:chip];
    [self updateGroupChip:chip selected:selected];
    return chip;
}

- (void)updateGroupChip:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        chip.backgroundColor = [[SPKUtils SPKColor_InstagramBlue] colorWithAlphaComponent:0.18];
        chip.tintColor = [SPKUtils SPKColor_InstagramBlue];
        [chip setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];
    } else {
        chip.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        chip.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [chip setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];
    }
}

- (void)chipTapped:(SPKGallerySortChip *)chip {
    self.currentSortMode = chip.mode;
    for (SPKGallerySortChip *c in self.sortChips)
        c.selectedChip = (c.mode == chip.mode);
    if ([self.delegate respondsToSelector:@selector(sortController:didSelectSortMode:groupByMediaType:)]) {
        [self.delegate sortController:self didSelectSortMode:self.currentSortMode groupByMediaType:self.currentGroupByMediaType];
    }
    [self dismissController];
}

- (void)groupChipTapped:(UIButton *)chip {
    self.currentGroupByMediaType = chip.tag == 1;
    for (UIButton *c in self.groupChips)
        [self updateGroupChip:c selected:(c.tag == chip.tag)];
    if ([self.delegate respondsToSelector:@selector(sortController:didSelectSortMode:groupByMediaType:)]) {
        [self.delegate sortController:self didSelectSortMode:self.currentSortMode groupByMediaType:self.currentGroupByMediaType];
    }
    [self dismissController];
}

- (void)dismissController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
