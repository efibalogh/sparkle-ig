#import "../UI/SPKSafeAreaLayout.h"
#import "SPKBulkMediaSelectionViewController.h"
#import "SPKStrings.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"

#pragma mark - Models

@implementation SPKBulkSelectionItem
+ (instancetype)itemWithThumbnailURL:(NSURL *)thumbnailURL isVideo:(BOOL)isVideo {
    SPKBulkSelectionItem *item = [self new];
    item.thumbnailURL = thumbnailURL;
    item.isVideo = isVideo;
    return item;
}
+ (instancetype)itemWithThumbnailImage:(UIImage *)thumbnailImage isVideo:(BOOL)isVideo {
    SPKBulkSelectionItem *item = [self new];
    item.thumbnailImage = thumbnailImage;
    item.isVideo = isVideo;
    return item;
}
@end

@implementation SPKBulkSelectionDestination
+ (instancetype)destinationWithIdentifier:(NSString *)identifier
                                    title:(NSString *)title
                                 iconName:(NSString *)iconName {
    SPKBulkSelectionDestination *dest = [self new];
    dest.identifier = [identifier copy];
    dest.title = [title copy];
    dest.iconName = [iconName copy];
    return dest;
}
@end

#pragma mark - Cell

@interface SPKBulkSelectionCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UIImageView *selectionBadge;
@property (nonatomic, strong) UIImageView *videoBadge;
@property (nonatomic, strong) UIView *selectedOverlay;
@property (nonatomic, strong, nullable) NSURL *representedURL;
- (void)setItemSelected:(BOOL)selected;
@end

@implementation SPKBulkSelectionCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [SPKUtils SPKColor_InstagramTertiaryBackground];
        self.contentView.layer.cornerRadius = 10.0;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.clipsToBounds = YES;

        _thumbnailView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _thumbnailView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        [self.contentView addSubview:_thumbnailView];

        _selectedOverlay = [[UIView alloc] initWithFrame:self.contentView.bounds];
        _selectedOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _selectedOverlay.backgroundColor = [[SPKUtils SPKColor_InstagramBlue] colorWithAlphaComponent:0.28];
        _selectedOverlay.layer.borderWidth = 2.0;
        _selectedOverlay.layer.borderColor = [SPKUtils SPKColor_InstagramBlue].CGColor;
        _selectedOverlay.layer.cornerRadius = 10.0;
        _selectedOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        _selectedOverlay.hidden = YES;
        [self.contentView addSubview:_selectedOverlay];

        _videoBadge = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"video_filled" pointSize:14.0]];
        _videoBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _videoBadge.tintColor = [UIColor whiteColor];
        _videoBadge.contentMode = UIViewContentModeScaleAspectFit;
        _videoBadge.layer.shadowColor = [UIColor blackColor].CGColor;
        _videoBadge.layer.shadowOpacity = 0.5;
        _videoBadge.layer.shadowRadius = 2.0;
        _videoBadge.layer.shadowOffset = CGSizeZero;
        [self.contentView addSubview:_videoBadge];

        _selectionBadge = [[UIImageView alloc] initWithFrame:CGRectZero];
        _selectionBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _selectionBadge.contentMode = UIViewContentModeScaleAspectFit;
        _selectionBadge.layer.shadowColor = [UIColor blackColor].CGColor;
        _selectionBadge.layer.shadowOpacity = 0.5;
        _selectionBadge.layer.shadowRadius = 2.0;
        _selectionBadge.layer.shadowOffset = CGSizeZero;
        [self.contentView addSubview:_selectionBadge];

        [NSLayoutConstraint activateConstraints:@[
            [_videoBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                  constant:6.0],
            [_videoBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                      constant:6.0],
            [_selectionBadge.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                         constant:-6.0],
            [_selectionBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                           constant:-6.0],
            [_selectionBadge.widthAnchor constraintEqualToConstant:24.0],
            [_selectionBadge.heightAnchor constraintEqualToConstant:24.0],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.thumbnailView.image = nil;
    self.representedURL = nil;
    [self setItemSelected:NO];
}

- (void)setItemSelected:(BOOL)selected {
    NSString *resource = selected ? @"circle_check_filled" : @"circle";
    UIImage *badge = [SPKAssetUtils instagramIconNamed:resource pointSize:24.0];
    if (selected) {
        badge = [badge imageWithTintColor:[SPKUtils SPKColor_InstagramBlue] renderingMode:UIImageRenderingModeAlwaysOriginal];
    } else {
        badge = [badge imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    self.selectionBadge.image = badge;
    self.selectedOverlay.hidden = !selected;
}

@end

#import "../UI/SPKMediaChrome.h"

#pragma mark - Controller
#import <objc/runtime.h>

@interface SPKBulkMediaSelectionViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, copy) NSArray<SPKBulkSelectionItem *> *items;
@property (nonatomic, copy) NSArray<SPKBulkSelectionDestination *> *destinations;
@property (nonatomic, copy) SPKBulkSelectionCompletion completion;
@property (nonatomic, strong) NSMutableIndexSet *selectedIndexes;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIBarButtonItem *selectAllItem;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *destinationBarItems;
@property (nonatomic, strong) NSURLSession *thumbnailSession;
@end

static const void *kSPKBulkSelectionDestinationIdentifierKey = &kSPKBulkSelectionDestinationIdentifierKey;

static NSCache<NSURL *, UIImage *> *SPKBulkSelectionThumbnailCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 120;
    });
    return cache;
}

@implementation SPKBulkMediaSelectionViewController

- (instancetype)initWithItems:(NSArray<SPKBulkSelectionItem *> *)items
                 destinations:(NSArray<SPKBulkSelectionDestination *> *)destinations
                   completion:(SPKBulkSelectionCompletion)completion {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _items = [items copy] ?: @[];
        _destinations = [destinations copy] ?: @[];
        _completion = [completion copy];
        _selectedIndexes = [NSMutableIndexSet indexSet];
        // Start with nothing selected; the user opts in per item (or via Select All).
        _thumbnailSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    }
    return self;
}

+ (void)presentFromViewController:(UIViewController *)presenter
                            items:(NSArray<SPKBulkSelectionItem *> *)items
                     destinations:(NSArray<SPKBulkSelectionDestination *> *)destinations
                       completion:(SPKBulkSelectionCompletion)completion {
    if (items.count == 0 || destinations.count == 0)
        return;

    UIViewController *host = presenter;
    while (host.presentedViewController)
        host = host.presentedViewController;
    if (!host)
        return;

    SPKBulkMediaSelectionViewController *vc =
        [[SPKBulkMediaSelectionViewController alloc] initWithItems:items
                                                      destinations:destinations
                                                        completion:completion];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.navigationBar.prefersLargeTitles = NO;
    [host presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 8.0;
    layout.minimumLineSpacing = 8.0;
    layout.sectionInset = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
    SPKFlowLayoutUseSafeArea(layout);

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[SPKBulkSelectionCell class] forCellWithReuseIdentifier:@"cell"];
    [self.view addSubview:self.collectionView];

    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem,
                                        @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(cancel)) ]);

    self.selectAllItem = SPKMediaChromeTopBarButtonItem(@"circle", self, @selector(toggleSelectAll));
    self.selectAllItem.accessibilityLabel = SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_SELECT_TEXT");
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ self.selectAllItem ]);
    self.navigationItem.title = SPKL(@"ALERT_ACTION_SELECT_MEDIA");

    // Bottom toolbar: one button per bulk destination, native chrome icons.
    NSMutableArray<UIBarButtonItem *> *destinationItems = [NSMutableArray array];
    for (SPKBulkSelectionDestination *dest in self.destinations) {
        UIBarButtonItem *item = SPKMediaChromeBottomBarButtonItem(dest.iconName ?: @"download",
                                                                  dest.title,
                                                                  self,
                                                                  @selector(toolbarItemTapped:));
        objc_setAssociatedObject(item, kSPKBulkSelectionDestinationIdentifierKey, dest.identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [destinationItems addObject:item];
    }
    self.destinationBarItems = destinationItems;
    self.toolbarItems = SPKMediaChromeBottomToolbarItems(destinationItems);

    [self updateChrome];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    SPKMediaChromeConfigureBottomToolbar(self.navigationController.toolbar);
}

#pragma mark - Chrome

- (void)updateChrome {
    NSUInteger count = self.selectedIndexes.count;
    NSUInteger total = self.items.count;

    self.navigationItem.title = count == 0
                                    ? SPKL(@"ALERT_ACTION_SELECT_MEDIA")
                                    : [NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"), (unsigned long)count, (unsigned long)total];

    BOOL enabled = (count > 0);
    for (UIBarButtonItem *item in self.destinationBarItems) {
        item.enabled = enabled;
    }

    NSString *resource;
    if (count == 0) {
        resource = @"circle";
    } else if (count == total) {
        resource = @"circle_check_filled";
    } else {
        resource = @"circle_check";
    }
    self.selectAllItem.image = SPKMediaChromeTopBarIcon(resource);
    self.selectAllItem.accessibilityLabel = (count == total) ? SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_DESELECT_TEXT") : SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_SELECT_TEXT");
}

#pragma mark - Actions

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleSelectAll {
    if (self.selectedIndexes.count == self.items.count) {
        [self.selectedIndexes removeAllIndexes];
    } else {
        [self.selectedIndexes addIndexesInRange:NSMakeRange(0, self.items.count)];
    }
    [self.collectionView reloadData];
    [self updateChrome];
}

- (void)toolbarItemTapped:(UIBarButtonItem *)sender {
    NSString *destIdentifier = objc_getAssociatedObject(sender, kSPKBulkSelectionDestinationIdentifierKey);
    if (destIdentifier) {
        [self confirmWithDestination:destIdentifier];
    }
}

- (void)confirmWithDestination:(NSString *)destinationIdentifier {
    if (self.selectedIndexes.count == 0)
        return;
    NSIndexSet *selection = [self.selectedIndexes copy];
    SPKBulkSelectionCompletion completion = self.completion;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (completion)
                                     completion(selection, destinationIdentifier);
                             }];
}

#pragma mark - Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    SPKBulkSelectionCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:indexPath];
    SPKBulkSelectionItem *item = self.items[(NSUInteger)indexPath.item];
    cell.videoBadge.hidden = !item.isVideo;
    [cell setItemSelected:[self.selectedIndexes containsIndex:(NSUInteger)indexPath.item]];
    [self loadThumbnailForCell:cell item:item];
    return cell;
}

- (void)loadThumbnailForCell:(SPKBulkSelectionCell *)cell item:(SPKBulkSelectionItem *)item {
    // Prefer an already-resolved image (e.g. the preview screen's thumbnails).
    if (item.thumbnailImage) {
        cell.representedURL = nil;
        cell.thumbnailView.image = item.thumbnailImage;
        return;
    }

    NSURL *url = item.thumbnailURL;
    cell.representedURL = url;
    if (!url)
        return;

    UIImage *cached = [SPKBulkSelectionThumbnailCache() objectForKey:url];
    if (cached) {
        cell.thumbnailView.image = cached;
        return;
    }

    __weak typeof(cell) weakCell = cell;
    void (^apply)(UIImage *) = ^(UIImage *image) {
        if (!image)
            return;
        [SPKBulkSelectionThumbnailCache() setObject:image forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKBulkSelectionCell *strongCell = weakCell;
            if (strongCell && [strongCell.representedURL isEqual:url]) {
                strongCell.thumbnailView.image = image;
            }
        });
    };

    // NSURLSession data tasks don't support file URLs; read those off-thread.
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            apply([UIImage imageWithContentsOfFile:url.path]);
        });
        return;
    }

    NSURLSessionDataTask *task = [self.thumbnailSession dataTaskWithURL:url
                                                      completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
                                                          if (!data)
                                                              return;
                                                          apply([UIImage imageWithData:data]);
                                                      }];
    [task resume];
}

#pragma mark - Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger index = (NSUInteger)indexPath.item;
    if ([self.selectedIndexes containsIndex:index]) {
        [self.selectedIndexes removeIndex:index];
    } else {
        [self.selectedIndexes addIndex:index];
    }
    SPKBulkSelectionCell *cell = (SPKBulkSelectionCell *)[collectionView cellForItemAtIndexPath:indexPath];
    if ([cell isKindOfClass:[SPKBulkSelectionCell class]]) {
        [cell setItemSelected:[self.selectedIndexes containsIndex:index]];
    }
    [self updateChrome];
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)collectionViewLayout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat usable = SPKCollectionViewUsableWidth(collectionView);
    CGFloat columns = (CGFloat)SPKAdaptiveColumnCount(3, usable);
    CGFloat insets = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat spacing = layout.minimumInteritemSpacing * (columns - 1.0);
    CGFloat available = usable - insets - spacing;
    CGFloat side = floor(available / columns);
    return CGSizeMake(side, side);
}

@end
