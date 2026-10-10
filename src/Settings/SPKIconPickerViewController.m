#import "SPKIconPickerViewController.h"
#import "SPKStrings.h"

#import "../AssetUtils.h"
#import "../Utils.h"

static NSString *const kSPKIconPickerCellIdentifier = @"SPKIconPickerCell";
static NSString *const kSPKIconPickerPreviewRowCellIdentifier = @"SPKIconPickerPreviewRowCell";
static NSString *const kSPKIconPickerHeaderIdentifier = @"SPKIconPickerHeader";

#pragma mark - Model

@implementation SPKIconPickerItem
+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                        searchText:(NSString *)searchText {
    SPKIconPickerItem *item = [[self alloc] init];
    item.identifier = identifier ?: @"";
    item.title = title;
    item.searchText = [(searchText ?: title ?
                                            : identifier) lowercaseString];
    return item;
}
@end

@implementation SPKIconPickerSection
+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<SPKIconPickerItem *> *)items {
    SPKIconPickerSection *section = [[self alloc] init];
    section.title = title;
    section.items = items ?: @[];
    return section;
}
@end

#pragma mark - Title formatting

// Breaks a long underscore-delimited glyph name (e.g. "carousel_prism_outline")
// onto two balanced lines so it fits the cell; leaves plain titles untouched.
static NSString *SPKIconPickerWrappedTitle(NSString *title) {
    if (title.length == 0 || ![title containsString:@"_"]) {
        return title ?: @"";
    }

    NSArray<NSString *> *parts = [title componentsSeparatedByString:@"_"];
    if (parts.count < 2) {
        return title;
    }

    NSUInteger target = title.length / 2;
    NSUInteger bestIndex = NSNotFound;
    NSUInteger bestDistance = NSUIntegerMax;
    NSUInteger cursor = 0;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        cursor += parts[i].length;
        NSUInteger distance = cursor > target ? cursor - target : target - cursor;
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = i;
        }
        cursor += 1;
    }

    if (bestIndex == NSNotFound) {
        return title;
    }

    NSMutableArray<NSString *> *first = [NSMutableArray array];
    NSMutableArray<NSString *> *second = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        [(i <= bestIndex ? first : second) addObject:parts[i]];
    }
    return [NSString stringWithFormat:@"%@\n%@", [first componentsJoinedByString:@"_"], [second componentsJoinedByString:@"_"]];
}

#pragma mark - Cell

@interface SPKIconPickerCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *checkmarkView;
@property (nonatomic, strong) NSLayoutConstraint *iconWidth;
@property (nonatomic, strong) NSLayoutConstraint *iconHeight;
@property (nonatomic, assign) SPKIconPickerCellStyle style;
- (void)configureWithTitle:(NSString *)title image:(UIImage *)image style:(SPKIconPickerCellStyle)style selected:(BOOL)selected;
@end

@implementation SPKIconPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.contentView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    self.contentView.layer.cornerRadius = 8.0;
    self.contentView.layer.borderWidth = 0.0;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    [self.contentView addSubview:_titleLabel];

    _checkmarkView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled" pointSize:18.0]];
    _checkmarkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkmarkView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    _checkmarkView.hidden = YES;
    [self.contentView addSubview:_checkmarkView];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                            constant:13.0],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],

        [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor
                                              constant:7.0],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                  constant:6.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                   constant:-6.0],
        [_titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor
                                                           constant:-8.0],

        [_checkmarkView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                 constant:6.0],
        [_checkmarkView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                      constant:-6.0],
        [_checkmarkView.widthAnchor constraintEqualToConstant:18.0],
        [_checkmarkView.heightAnchor constraintEqualToConstant:18.0]
    ]];

    _iconWidth = [_iconView.widthAnchor constraintEqualToConstant:32.0];
    _iconHeight = [_iconView.heightAnchor constraintEqualToConstant:32.0];
    _iconWidth.active = YES;
    _iconHeight.active = YES;

    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.titleLabel.text = nil;
    [self applySelected:NO];
}

- (void)applyStyle:(SPKIconPickerCellStyle)style {
    _style = style;
    if (style == SPKIconPickerCellStyleAppIcon) {
        self.iconView.contentMode = UIViewContentModeScaleAspectFill;
        self.iconView.clipsToBounds = YES;
        self.iconView.layer.cornerRadius = 14.0;
        self.iconWidth.constant = 72.0;
        self.iconHeight.constant = 72.0;
        self.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        self.titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    } else {
        self.iconView.contentMode = UIViewContentModeCenter;
        self.iconView.clipsToBounds = NO;
        self.iconView.layer.cornerRadius = 0.0;
        self.iconWidth.constant = 32.0;
        self.iconHeight.constant = 32.0;
        self.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        self.titleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
}

- (void)applySelected:(BOOL)selected {
    self.checkmarkView.hidden = !selected;
    if (selected)
        self.contentView.layer.borderColor = [SPKUtils SPKColor_InstagramBlue].CGColor;
    self.contentView.layer.borderWidth = selected ? 2.0 : 0.0;
    self.contentView.backgroundColor = selected
                                           ? [[SPKUtils SPKColor_InstagramBlue] colorWithAlphaComponent:0.12]
                                           : [SPKUtils SPKColor_InstagramSecondaryBackground];
    if (_style == SPKIconPickerCellStyleGlyph) {
        self.iconView.tintColor = selected ? [SPKUtils SPKColor_InstagramBlue] : [SPKUtils SPKColor_InstagramPrimaryText];
    }
}

- (void)configureWithTitle:(NSString *)title image:(UIImage *)image style:(SPKIconPickerCellStyle)style selected:(BOOL)selected {
    [self applyStyle:style];
    self.titleLabel.text = style == SPKIconPickerCellStyleGlyph ? SPKIconPickerWrappedTitle(title) : (title ?: @"");
    self.iconView.image = image ?: [SPKAssetUtils instagramIconNamed:@"app" pointSize:32.0];
    [self applySelected:selected];
}

@end

#pragma mark - Preview row cell

/// Full-width cell for one icon that has several looks: one captioned preview
/// per grid column, selected as a whole.
@interface SPKIconPickerPreviewRowCell : UICollectionViewCell
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) UIImageView *checkmarkView;
- (void)configureWithImages:(NSArray<UIImage *> *)images titles:(NSArray<NSString *> *)titles spacing:(CGFloat)spacing selected:(BOOL)selected;
@end

@implementation SPKIconPickerPreviewRowCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.contentView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    self.contentView.layer.cornerRadius = 8.0;

    _stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    _stackView.axis = UILayoutConstraintAxisHorizontal;
    _stackView.distribution = UIStackViewDistributionFillEqually;
    _stackView.alignment = UIStackViewAlignmentTop;
    [self.contentView addSubview:_stackView];

    _checkmarkView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled" pointSize:18.0]];
    _checkmarkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkmarkView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    _checkmarkView.hidden = YES;
    [self.contentView addSubview:_checkmarkView];

    [NSLayoutConstraint activateConstraints:@[
        [_stackView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                             constant:13.0],
        [_stackView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_stackView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_stackView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor
                                                          constant:-8.0],

        [_checkmarkView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                 constant:6.0],
        [_checkmarkView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                      constant:-6.0],
        [_checkmarkView.widthAnchor constraintEqualToConstant:18.0],
        [_checkmarkView.heightAnchor constraintEqualToConstant:18.0]
    ]];

    return self;
}

- (UIView *)columnWithImage:(UIImage *)image title:(NSString *)title {
    // Same metrics as a grid cell: 72pt artwork with a caption beneath. The
    // previews already carry the icon shape, so nothing is clipped here.
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [imageView.heightAnchor constraintEqualToConstant:72.0].active = YES;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ imageView, label ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 7.0;
    column.layoutMargins = UIEdgeInsetsMake(0.0, 6.0, 0.0, 6.0);
    column.layoutMarginsRelativeArrangement = YES;
    return column;
}

- (void)configureWithImages:(NSArray<UIImage *> *)images titles:(NSArray<NSString *> *)titles spacing:(CGFloat)spacing selected:(BOOL)selected {
    for (UIView *column in self.stackView.arrangedSubviews) {
        [column removeFromSuperview];
    }
    self.stackView.spacing = spacing;
    for (NSUInteger index = 0; index < images.count; index++) {
        [self.stackView addArrangedSubview:[self columnWithImage:images[index] title:index < titles.count ? titles[index] : @""]];
    }

    self.checkmarkView.hidden = !selected;
    if (selected)
        self.contentView.layer.borderColor = [SPKUtils SPKColor_InstagramBlue].CGColor;
    self.contentView.layer.borderWidth = selected ? 2.0 : 0.0;
    self.contentView.backgroundColor = selected
                                           ? [[SPKUtils SPKColor_InstagramBlue] colorWithAlphaComponent:0.12]
                                           : [SPKUtils SPKColor_InstagramSecondaryBackground];
}

@end

#pragma mark - Header

@interface SPKIconPickerHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation SPKIconPickerHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [self addSubview:_titleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:14.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-14.0],
        [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                 constant:-8.0]
    ]];
    return self;
}
@end

#pragma mark - Controller

@interface SPKIconPickerViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<SPKIconPickerSection *> *allSections;
@property (nonatomic, strong) NSArray<SPKIconPickerSection *> *filteredSections;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@end

@implementation SPKIconPickerViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 256;
    }
    return self;
}

#pragma mark Defaults for hooks

- (NSArray<SPKIconPickerSection *> *)buildSections {
    return @[];
}
- (UIImage *)imageForItem:(SPKIconPickerItem *)item {
    (void)item;
    return nil;
}
- (void)didSelectItem:(SPKIconPickerItem *)item {
    (void)item;
}
- (SPKIconPickerCellStyle)cellStyle {
    return SPKIconPickerCellStyleGlyph;
}
- (NSInteger)columnCountForWidth:(CGFloat)width {
    (void)width;
    return 3;
}
- (CGFloat)itemHeight {
    return [self cellStyle] == SPKIconPickerCellStyleAppIcon ? 124.0 : 96.0;
}
- (NSString *)searchPlaceholder {
    return SPKL(@"SETTINGS_ACTION_SECTION_ICON_PICKER_SEARCH_ICONS_TEXT");
}
- (BOOL)isSelectedItem:(SPKIconPickerItem *)item {
    return self.selectedIdentifier.length > 0 && [item.identifier isEqualToString:self.selectedIdentifier];
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    self.allSections = [self buildSections];
    self.filteredSections = self.allSections;

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = [self cellStyle] == SPKIconPickerCellStyleAppIcon ? 12.0 : 10.0;
    layout.minimumLineSpacing = layout.minimumInteritemSpacing;
    layout.sectionInset = UIEdgeInsetsMake(14.0, 14.0, 24.0, 14.0);
    layout.headerReferenceSize = CGSizeMake(1.0, 42.0);

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.collectionView registerClass:[SPKIconPickerCell class] forCellWithReuseIdentifier:kSPKIconPickerCellIdentifier];
    [self.collectionView registerClass:[SPKIconPickerPreviewRowCell class] forCellWithReuseIdentifier:kSPKIconPickerPreviewRowCellIdentifier];
    [self.collectionView registerClass:[SPKIconPickerHeaderView class]
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:kSPKIconPickerHeaderIdentifier];
    [self.view addSubview:self.collectionView];

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.hidesNavigationBarDuringPresentation = NO;
    searchController.searchBar.placeholder = [self searchPlaceholder];
    [searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                        forSearchBarIcon:UISearchBarIconSearch
                                   state:UIControlStateNormal];
    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self scrollToSelectedItem];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    CGFloat horizontalInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(1.0, self.view.bounds.size.width - horizontalInset);
    NSInteger columns = MAX(1, [self columnCountForWidth:availableWidth]);
    CGFloat itemWidth = floor((availableWidth - (columns - 1) * layout.minimumInteritemSpacing) / columns);
    layout.itemSize = CGSizeMake(itemWidth, [self itemHeight]);
}

#pragma mark Public

- (void)refreshSelectionHighlight {
    [self.collectionView reloadData];
    [self scrollToSelectedItem];
}

#pragma mark Images

- (UIImage *)cachedImageForItem:(SPKIconPickerItem *)item {
    NSString *key = item.identifier ?: @"";
    UIImage *cached = [self.imageCache objectForKey:key];
    if (cached)
        return cached;
    UIImage *image = [self imageForItem:item];
    if (image)
        [self.imageCache setObject:image forKey:key];
    return image;
}

#pragma mark Scroll-to-selected

- (void)scrollToSelectedItem {
    for (NSUInteger s = 0; s < self.filteredSections.count; s++) {
        NSArray<SPKIconPickerItem *> *items = self.filteredSections[s].items;
        NSUInteger index = [items indexOfObjectPassingTest:^BOOL(SPKIconPickerItem *item, NSUInteger idx, BOOL *stop) {
            (void)idx;
            (void)stop;
            return [self isSelectedItem:item];
        }];
        if (index != NSNotFound) {
            [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:s]
                                        atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                                animated:NO];
            return;
        }
    }
}

#pragma mark Search

- (NSArray<NSString *> *)searchTokensForText:(NSString *)text {
    NSString *normalized = [[[text ?: @"" stringByReplacingOccurrencesOfString:@"_" withString:@" "] stringByReplacingOccurrencesOfString:@"-" withString:@" "] lowercaseString];
    NSArray<NSString *> *parts = [normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0)
            [tokens addObject:part];
    }
    return tokens;
}

- (void)updateFilteredSectionsForSearch:(NSString *)searchText {
    NSArray<NSString *> *tokens = [self searchTokensForText:searchText];
    if (tokens.count == 0) {
        self.filteredSections = self.allSections;
        return;
    }

    NSMutableArray<SPKIconPickerSection *> *filtered = [NSMutableArray array];
    for (SPKIconPickerSection *section in self.allSections) {
        NSMutableArray<SPKIconPickerItem *> *matches = [NSMutableArray array];
        for (SPKIconPickerItem *item in section.items) {
            BOOL matchesAll = YES;
            for (NSString *token in tokens) {
                if ([(item.searchText ?: @"") rangeOfString:token].location == NSNotFound) {
                    matchesAll = NO;
                    break;
                }
            }
            if (matchesAll)
                [matches addObject:item];
        }
        if (matches.count > 0) {
            [filtered addObject:[SPKIconPickerSection sectionWithTitle:section.title items:matches]];
        }
    }
    self.filteredSections = filtered;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self updateFilteredSectionsForSearch:searchController.searchBar.text];
    [self.collectionView reloadData];
}

#pragma mark UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    (void)collectionView;
    return self.filteredSections.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    return self.filteredSections[section].items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    SPKIconPickerItem *item = self.filteredSections[indexPath.section].items[indexPath.item];
    if (item.previewImages.count > 0) {
        SPKIconPickerPreviewRowCell *row = [collectionView dequeueReusableCellWithReuseIdentifier:kSPKIconPickerPreviewRowCellIdentifier forIndexPath:indexPath];
        UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionView.collectionViewLayout;
        [row configureWithImages:item.previewImages
                          titles:item.previewTitles
                         spacing:layout.minimumInteritemSpacing
                        selected:[self isSelectedItem:item]];
        return row;
    }

    SPKIconPickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kSPKIconPickerCellIdentifier forIndexPath:indexPath];
    [cell configureWithTitle:item.title
                       image:[self cachedImageForItem:item]
                       style:[self cellStyle]
                    selected:[self isSelectedItem:item]];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    SPKIconPickerHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind
                                                                         withReuseIdentifier:kSPKIconPickerHeaderIdentifier
                                                                                forIndexPath:indexPath];
    header.titleLabel.text = self.filteredSections[indexPath.section].title;
    return header;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)collectionViewLayout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    SPKIconPickerItem *item = self.filteredSections[indexPath.section].items[indexPath.item];
    if (item.previewImages.count == 0)
        return layout.itemSize;
    CGFloat width = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
    return CGSizeMake(MAX(1.0, width), [self itemHeight]);
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                             layout:(UICollectionViewLayout *)collectionViewLayout
    referenceSizeForHeaderInSection:(NSInteger)section {
    (void)collectionView;
    (void)collectionViewLayout;
    NSString *title = self.filteredSections[section].title;
    return title.length > 0 ? CGSizeMake(1.0, 42.0) : CGSizeZero;
}

#pragma mark UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    SPKIconPickerItem *item = self.filteredSections[indexPath.section].items[indexPath.item];
    [self didSelectItem:item];
}

@end
