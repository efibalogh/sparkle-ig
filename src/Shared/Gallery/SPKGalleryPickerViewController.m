#import "../UI/SPKSafeAreaLayout.h"
#import "SPKStrings.h"
#import "SPKGalleryPickerViewController.h"

#import <CoreData/CoreData.h>

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKMediaChrome.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryFilterViewController.h"
#import "SPKGalleryFolderChipBar.h"
#import "SPKGalleryGridCell.h"
#import "SPKGalleryGridDensity.h"
#import "SPKGalleryHiddenSources.h"
#import "SPKGalleryListCollectionCell.h"
#import "SPKGalleryLockViewController.h"
#import "SPKGalleryManager.h"
#import "SPKGallerySortViewController.h"
#import "../UI/SPKFont.h"

NSNotificationName const SPKGalleryPickerDidDismissNotification = @"SPKGalleryPickerDidDismissNotification";

// The picker gets its own UIWindow rather than being presented into IG's. From
// the story composer IG keeps its editor mounted behind the picker (it presents
// the sticker tray overFullScreen), and sharing a window with it made the
// picker's grid scroll several times slower than the same grid opened from
// Direct. A separate window keeps the picker's view hierarchy to itself.
//
// Held in a global rather than on the picker: the window retains its root, which
// retains the navigation controller, which retains the picker, so a back
// reference from the picker would be a cycle.
static UIWindow *sSPKGalleryPickerWindow = nil;
static __weak UIWindow *sSPKGalleryPickerPreviousKeyWindow = nil;

static void SPKGalleryPickerTeardownWindow(void) {
    if (!sSPKGalleryPickerWindow) {
        return;
    }
    [sSPKGalleryPickerPreviousKeyWindow makeKeyWindow];
    sSPKGalleryPickerWindow.hidden = YES;
    sSPKGalleryPickerWindow.rootViewController = nil;
    sSPKGalleryPickerWindow = nil;
    sSPKGalleryPickerPreviousKeyWindow = nil;
}

static NSString *const kSPKGalleryPickerListCellID = @"SPKGalleryPickerListCell";
static NSString *const kSPKGalleryPickerGridCellID = @"SPKGalleryPickerGridCell";
static NSString *const kSPKGalleryPickerFolderChipHeaderID = @"SPKGalleryPickerFolderChipHeader";
static NSString *const kSPKGalleryPickerViewModeKey = @"gallery_picker_view_mode"; // 0 = grid, 1 = list
static CGFloat const kSPKGalleryPickerGridSpacing = 2.0;

typedef NS_ENUM(NSInteger, SPKGalleryPickerViewMode) {
    SPKGalleryPickerViewModeGrid = 0,
    SPKGalleryPickerViewModeList = 1,
};

@interface SPKGalleryPickerViewController () <UICollectionViewDataSource,
                                              UICollectionViewDelegate,
                                              UICollectionViewDelegateFlowLayout,
                                              UIAdaptivePresentationControllerDelegate,
                                              UISearchResultsUpdating,
                                              UISearchBarDelegate,
                                              SPKGallerySortViewControllerDelegate,
                                              SPKGalleryFilterViewControllerDelegate>
// Folders are browsed in place (re-scoping this one controller) rather than by
// pushing a picker per folder, matching the Gallery — the nav bar, search field
// and toolbar are never recreated, so the chrome never flashes mid-transition.
// `folderTrail` is the stack of folder paths from root to the current folder
// (empty at root); `folderScrollOffsets` holds the parallel grid scroll position
// to restore on the way back.
@property (nonatomic, copy, nullable) NSString *folderPath;
@property (nonatomic, strong) NSMutableArray<NSString *> *folderTrail;
@property (nonatomic, strong) NSMutableArray<NSValue *> *folderScrollOffsets;
@property (nonatomic, copy) NSString *pickerTitle;
@property (nonatomic, strong, nullable) NSSet<NSNumber *> *allowedMediaTypes;
@property (nonatomic, assign) BOOL allowsMultipleSelection;
@property (nonatomic, copy) SPKGalleryPickerCompletion completion;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *searchQuery;
// When YES (and a query is active), search ignores the folder scope and matches
// across all folders; the search bar scope buttons toggle it. Same affordance as
// the Gallery, so a file you know is filed away is still findable from the root.
@property (nonatomic, assign) BOOL searchAllFolders;
@property (nonatomic, strong) NSArray<NSString *> *subfolders;
@property (nonatomic, strong) NSArray<SPKGalleryFile *> *files;
@property (nonatomic, strong) NSMutableArray<NSString *> *selectedIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SPKGalleryFile *> *selectedFilesByID;
@property (nonatomic, assign) SPKGalleryPickerViewMode viewMode;
@property (nonatomic, assign) NSInteger gridColumns;
@property (nonatomic, assign) SPKGallerySortMode sortMode;
@property (nonatomic, assign) BOOL sortGroupByMediaType;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *filterTypes;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *filterSources;
@property (nonatomic, assign) BOOL filterFavoritesOnly;
@property (nonatomic, strong) NSMutableSet<NSString *> *filterUsernames;
@property (nonatomic, strong) UIBarButtonItem *cachedSearchToolbarItem;

- (void)presentInOwnWindowAbove:(UIViewController *)presenter navigationController:(UINavigationController *)nav;
@end

@implementation SPKGalleryPickerViewController

+ (BOOL)hasSelectableFilesForAllowedMediaTypes:(NSSet<NSNumber *> *)allowedMediaTypes {
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    NSMutableArray *predicates = [NSMutableArray array];
    if (allowedMediaTypes.count > 0)
        [predicates addObject:[NSPredicate predicateWithFormat:@"mediaType IN %@", allowedMediaTypes.allObjects]];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (visibleSources)
        [predicates addObject:visibleSources];
    request.predicate = predicates.count > 0 ? [NSCompoundPredicate andPredicateWithSubpredicates:predicates] : nil;
    request.fetchLimit = 50;
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO] ];
    NSArray<SPKGalleryFile *> *files = [[SPKGalleryCoreDataStack shared].viewContext executeFetchRequest:request error:nil] ?: @[];
    for (SPKGalleryFile *file in files) {
        if ([file fileExists])
            return YES;
    }
    return NO;
}

+ (void)presentFromViewController:(UIViewController *)presenter
                            title:(NSString *)title
                allowedMediaTypes:(NSSet<NSNumber *> *)allowedMediaTypes
          allowsMultipleSelection:(BOOL)allowsMultipleSelection
                       completion:(SPKGalleryPickerCompletion)completion {
    if (!presenter || !completion)
        return;

    SPKGalleryManager *mgr = [SPKGalleryManager sharedManager];

    void (^presentPicker)(void) = ^{
        SPKGalleryPickerViewController *picker = [[self alloc] initWithTitle:title
                                                           allowedMediaTypes:allowedMediaTypes
                                                     allowsMultipleSelection:allowsMultipleSelection
                                                                  completion:completion];
        UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:picker];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [picker presentInOwnWindowAbove:presenter navigationController:nav];
    };

    if (mgr.isLockEnabled && !mgr.isUnlocked) {
        [SPKGalleryLockViewController presentUnlockFromViewController:presenter
                                                           completion:^(BOOL success) {
                                                               if (!success)
                                                                   return;
                                                               presentPicker();
                                                           }];
    } else {
        presentPicker();
    }
}

- (void)presentInOwnWindowAbove:(UIViewController *)presenter navigationController:(UINavigationController *)nav {
    UIWindow *presenterWindow = presenter.viewIfLoaded.window;

    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = presenterWindow.windowScene;
        if (scene) {
            window = [[UIWindow alloc] initWithWindowScene:scene];
        }
    }
    if (!window) {
        CGRect frame = CGRectGetWidth(presenterWindow.bounds) > 0.0 ? presenterWindow.bounds : UIScreen.mainScreen.bounds;
        window = [[UIWindow alloc] initWithFrame:frame];
    }

    // Just above whatever we were launched over, so IG's own chrome stays behind
    // the picker without competing with system windows (alerts, status bar).
    window.windowLevel = (presenterWindow ? presenterWindow.windowLevel : UIWindowLevelNormal) + 1.0;
    // Clear, so IG shows through during the present/dismiss transition exactly as
    // it did when the picker was presented into IG's own window.
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;

    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = [UIColor clearColor];
    host.view.opaque = NO;
    window.rootViewController = host;

    sSPKGalleryPickerPreviousKeyWindow = presenterWindow.isKeyWindow ? presenterWindow : UIApplication.sharedApplication.keyWindow;
    sSPKGalleryPickerWindow = window;
    // Key, or the search field would never get the keyboard.
    [window makeKeyAndVisible];

    [host presentViewController:nav animated:YES completion:nil];
}

- (instancetype)initWithTitle:(NSString *)title
            allowedMediaTypes:(NSSet<NSNumber *> *)allowedMediaTypes
      allowsMultipleSelection:(BOOL)allowsMultipleSelection
                   completion:(SPKGalleryPickerCompletion)completion {
    return [self initWithFolderPath:nil
                              title:title
                  allowedMediaTypes:allowedMediaTypes
            allowsMultipleSelection:allowsMultipleSelection
                         completion:completion];
}

- (instancetype)initWithFolderPath:(NSString *)folderPath
                             title:(NSString *)title
                 allowedMediaTypes:(NSSet<NSNumber *> *)allowedMediaTypes
           allowsMultipleSelection:(BOOL)allowsMultipleSelection
                        completion:(SPKGalleryPickerCompletion)completion {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _folderPath = [folderPath copy];
        _folderTrail = [NSMutableArray array];
        _folderScrollOffsets = [NSMutableArray array];
        if (_folderPath.length > 0) {
            [_folderTrail addObject:_folderPath];
        }
        _pickerTitle = [title.length > 0 ? title : SPKL(@"GALLERY_TITLE") copy];
        _allowedMediaTypes = [allowedMediaTypes copy];
        _allowsMultipleSelection = allowsMultipleSelection;
        _completion = [completion copy];
        _searchQuery = @"";
        _subfolders = @[];
        _files = @[];
        _selectedIDs = [NSMutableArray array];
        _selectedFilesByID = [NSMutableDictionary dictionary];
        _viewMode = (SPKGalleryPickerViewMode)[[NSUserDefaults standardUserDefaults] integerForKey:kSPKGalleryPickerViewModeKey];
        _gridColumns = SPKGalleryGridColumns();
        _sortMode = SPKGallerySortModeDateAddedDesc;
        _sortGroupByMediaType = NO;
        _filterTypes = [NSMutableSet set];
        _filterSources = [NSMutableSet set];
        _filterFavoritesOnly = NO;
        _filterUsernames = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hiddenSourcesChanged:)
                                                 name:SPKGalleryHiddenSourcesDidChangeNotification
                                               object:nil];

    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    [self updateFolderTitle];

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:[self makeLayout]];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:SPKGalleryListCollectionCell.class forCellWithReuseIdentifier:kSPKGalleryPickerListCellID];
    [self.collectionView registerClass:SPKGalleryGridCell.class forCellWithReuseIdentifier:kSPKGalleryPickerGridCellID];
    [self.collectionView registerClass:SPKGalleryFolderChipBar.class
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:kSPKGalleryPickerFolderChipHeaderID];
    [self.view addSubview:self.collectionView];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleGridPinch:)];
    [self.collectionView addGestureRecognizer:pinch];

    [self setupEmptyState];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self refreshLeadingNavItem];
    [self refreshNavigationRightItems];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    self.searchController.searchBar.placeholder = SPKL(@"GALLERY_GALLERY_PICKER_SEARCH_GALLERY_TEXT");
    self.searchController.searchBar.delegate = self;
    [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                             forSearchBarIcon:UISearchBarIconSearch
                                        state:UIControlStateNormal];
    // Scope toggle: search the current folder, or across all folders. Let the
    // search controller manage the scope bar's visibility (shown while searching).
    self.searchController.searchBar.scopeButtonTitles = @[ SPKL(@"GALLERY_GALLERY_PICKER_FOLDER_TEXT"), SPKL(@"GALLERY_GALLERY_PICKER_FOLDERS_TEXT") ];
    self.searchController.automaticallyShowsScopeBar = YES;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    if (@available(iOS 26.0, *)) {
        @try {
            [self.navigationItem setValue:@(4) forKey:@"preferredSearchBarPlacement"];
            [self.searchController loadViewIfNeeded];
            UIBarButtonItem *vended = [self.navigationItem valueForKey:@"searchBarPlacementBarButtonItem"];
            if ([vended isKindOfClass:[UIBarButtonItem class]]) {
                self.cachedSearchToolbarItem = vended;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    self.definesPresentationContext = YES;

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationController.presentationController.delegate = self;
    }

    [self reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)hiddenSourcesChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
        SPKApplyMediaChromeNavigationBar(self.navigationController.navigationBar);
    }
    self.navigationController.toolbarHidden = NO;
    [self refreshBottomToolbarItems];
    [self reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.navigationController.viewControllers.firstObject != self)
        return;
    if (self.isMovingFromParentViewController)
        return;
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKGalleryPickerDidDismissNotification object:self];
        if ([SPKGalleryManager sharedManager].isLockEnabled) {
            [[SPKGalleryManager sharedManager] lockGallery];
        }
    }
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    // Interactive dismissal bypasses dismissPickerWithCompletion:, so the host
    // window has to be released here too or it would linger above IG forever.
    SPKGalleryPickerTeardownWindow();
    if ([SPKGalleryManager sharedManager].isLockEnabled) {
        [[SPKGalleryManager sharedManager] lockGallery];
    }
}

- (NSArray<NSNumber *> *)allowedMediaTypeValues {
    return self.allowedMediaTypes.count > 0 ? self.allowedMediaTypes.allObjects : @[];
}

- (NSPredicate *)filePredicateForFolderPath:(NSString *)folderPath includeDescendants:(BOOL)includeDescendants {
    NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];
    NSArray<NSNumber *> *allowed = [self allowedMediaTypeValues];
    if (allowed.count > 0) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"mediaType IN %@", allowed]];
    }
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (visibleSources)
        [predicates addObject:visibleSources];

    if (folderPath.length > 0) {
        if (includeDescendants) {
            [predicates addObject:[NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                                   folderPath,
                                                                   [folderPath stringByAppendingString:@"/"]]];
        } else {
            [predicates addObject:[NSPredicate predicateWithFormat:@"folderPath == %@", folderPath]];
        }
    } else if (!includeDescendants) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folderPath == nil OR folderPath == %@", @""]];
    }

    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length > 0) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"sourceUsername CONTAINS[cd] %@ OR customName CONTAINS[cd] %@ OR relativePath CONTAINS[cd] %@",
                                                               query, query, query]];
    }

    return predicates.count > 0 ? [NSCompoundPredicate andPredicateWithSubpredicates:predicates] : nil;
}

/// The scope toggle is only meaningful while a query is active — with no query,
/// "All Folders" would flatten the whole gallery into the folder you are in.
- (BOOL)searchingAllFolders {
    if (!self.searchAllFolders)
        return NO;
    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return query.length > 0;
}

- (NSArray<SPKGalleryFile *> *)fetchFiles {
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];

    // "All Folders" only applies while actually searching; otherwise stay scoped
    // to the folder being browsed. Passing a nil path with descendants included
    // drops the folder predicate entirely, which is exactly "everywhere".
    NSPredicate *basePred = [self searchingAllFolders]
                                ? [self filePredicateForFolderPath:nil includeDescendants:YES]
                                : [self filePredicateForFolderPath:self.folderPath includeDescendants:NO];
    if (basePred) [predicates addObject:basePred];

    NSPredicate *filterPred = [SPKGalleryFilterViewController predicateForTypes:self.filterTypes
                                                                        sources:self.filterSources
                                                                  favoritesOnly:self.filterFavoritesOnly
                                                                      usernames:self.filterUsernames
                                                                     folderPath:self.folderPath
                                                                  scopeToFolder:NO];
    if (filterPred) [predicates addObject:filterPred];

    request.predicate = predicates.count > 0 ? [NSCompoundPredicate andPredicateWithSubpredicates:predicates] : nil;

    NSArray<NSSortDescriptor *> *sortDescriptors = [SPKGallerySortViewController sortDescriptorsForMode:self.sortMode groupByMediaType:self.sortGroupByMediaType];
    if (sortDescriptors.count > 0) {
        request.sortDescriptors = sortDescriptors;
    } else {
        request.sortDescriptors = @[
            [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO],
            [NSSortDescriptor sortDescriptorWithKey:@"relativePath" ascending:YES selector:@selector(localizedStandardCompare:)]
        ];
    }

    NSArray<SPKGalleryFile *> *fetched = [[SPKGalleryCoreDataStack shared].viewContext executeFetchRequest:request error:nil] ?: @[];
    NSMutableArray<SPKGalleryFile *> *existing = [NSMutableArray arrayWithCapacity:fetched.count];
    for (SPKGalleryFile *file in fetched) {
        if ([file fileExists])
            [existing addObject:file];
    }
    return existing;
}

- (NSInteger)eligibleFileCountForFolderPath:(NSString *)folderPath {
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    request.predicate = [self filePredicateForFolderPath:folderPath includeDescendants:YES];
    return [[SPKGalleryCoreDataStack shared].viewContext countForFetchRequest:request error:nil];
}

- (NSArray<NSString *> *)fetchSubfolders {
    if (self.searchQuery.length > 0)
        return @[];

    NSManagedObjectContext *context = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    request.resultType = NSDictionaryResultType;
    request.propertiesToFetch = @[ @"folderPath" ];
    request.returnsDistinctResults = YES;

    NSString *base = self.folderPath ?: @"";
    NSString *prefix = base.length == 0 ? @"/" : [base stringByAppendingString:@"/"];
    NSPredicate *folderPredicate = [NSPredicate predicateWithFormat:@"folderPath BEGINSWITH %@", prefix];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    request.predicate = visibleSources
                            ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ folderPredicate, visibleSources ]]
                            : folderPredicate;

    NSArray<NSDictionary *> *rows = [context executeFetchRequest:request error:nil] ?: @[];
    NSMutableSet<NSString *> *folders = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *path = row[@"folderPath"];
        if (path.length <= prefix.length)
            continue;
        NSString *rest = [path substringFromIndex:prefix.length];
        NSRange slash = [rest rangeOfString:@"/"];
        NSString *folderName = slash.location == NSNotFound ? rest : [rest substringToIndex:slash.location];
        if (folderName.length == 0)
            continue;
        NSString *folderPath = [prefix stringByAppendingString:folderName];
        if ([self eligibleFileCountForFolderPath:folderPath] > 0) {
            [folders addObject:folderPath];
        }
    }
    return [[folders allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)reloadData {
    self.subfolders = [self fetchSubfolders];
    self.files = [self fetchFiles];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self updateDoneButton];
}

#pragma mark - View Mode & Density

- (UICollectionViewLayout *)makeLayout {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    if (self.viewMode == SPKGalleryPickerViewModeGrid) {
        layout.minimumLineSpacing = kSPKGalleryPickerGridSpacing;
        layout.minimumInteritemSpacing = kSPKGalleryPickerGridSpacing;
    } else {
        layout.minimumLineSpacing = 0.0;
        layout.minimumInteritemSpacing = 0.0;
    }
    SPKFlowLayoutUseSafeArea(layout);
    return layout;
}

- (void)setGridColumns:(NSInteger)gridColumns {
    NSInteger clamped = MAX(kSPKGalleryGridColumnsMin, MIN(kSPKGalleryGridColumnsMax, gridColumns));
    if (clamped == _gridColumns)
        return;
    _gridColumns = clamped;
    SPKGalleryGridSetColumns(clamped);
}

- (UIBarButtonItem *)pickerBottomBarItemWithResource:(NSString *)resourceName accessibility:(NSString *)label action:(SEL)action {
    return SPKMediaChromeBottomBarButtonItem(resourceName, label, self, action);
}

- (UIBarButtonItem *)bottomToolbarSearchItem {
    UIBarButtonItem *searchItem = self.cachedSearchToolbarItem;
    if (!searchItem) {
        if (@available(iOS 26.0, *)) {
            @try {
                UIBarButtonItem *vended = [self.navigationItem valueForKey:@"searchBarPlacementBarButtonItem"];
                if ([vended isKindOfClass:[UIBarButtonItem class]]) {
                    searchItem = vended;
                    self.cachedSearchToolbarItem = vended;
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (!searchItem) {
        searchItem = [self pickerBottomBarItemWithResource:@"search" accessibility:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT") action:@selector(activateSearch)];
    }
    return searchItem;
}

- (void)activateSearch {
    if (!self.searchController.active) {
        self.searchController.active = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchController.searchBar becomeFirstResponder];
    });
}

- (void)refreshBottomToolbarItems {
    SPKMediaChromeConfigureBottomToolbar(self.navigationController.toolbar);

    NSString *toggleResource = self.viewMode == SPKGalleryPickerViewModeGrid ? @"list" : @"grid";
    NSString *toggleAX = self.viewMode == SPKGalleryPickerViewModeGrid ? SPKL(@"GALLERY_GALLERY_PICKER_LIST_VIEW_TEXT") : SPKL(@"GALLERY_GALLERY_PICKER_GRID_VIEW_TEXT");
    UIBarButtonItem *toggleItem = [self pickerBottomBarItemWithResource:toggleResource accessibility:toggleAX action:@selector(togglePickerViewMode)];

    UIBarButtonItem *sortItem = [self pickerBottomBarItemWithResource:@"sort" accessibility:SPKL(@"MENU_SORT") action:@selector(presentSort)];
    UIBarButtonItem *filterItem = [self pickerBottomBarItemWithResource:@"filter" accessibility:SPKL(@"GALLERY_GALLERY_FILTER_FILTER_TEXT") action:@selector(presentFilter)];

    NSArray<UIBarButtonItem *> *primary = @[ toggleItem, sortItem, filterItem ];
    self.toolbarItems = SPKMediaChromeBottomToolbarItemsWithTrailingGroup(primary, @[ [self bottomToolbarSearchItem] ]);
}

- (void)refreshNavigationRightItems {
    if (self.allowsMultipleSelection) {
        // An icon item like the editors' confirm button, so it can move into a
        // vertical side bar with the other bar items.
        UIBarButtonItem *addItem = SPKMediaChromeTopBarButtonItemWithStyle(@"check", self, @selector(doneTapped),
                                                                           UIBarButtonItemStyleDone,
                                                                           [SPKUtils SPKColor_InstagramBlue],
                                                                           SPKL(@"ALERT_ACTION_ADD"));
        addItem.enabled = self.selectedIDs.count > 0;
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ addItem ]);
    } else {
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[]);
    }
}

- (void)togglePickerViewMode {
    self.viewMode = self.viewMode == SPKGalleryPickerViewModeGrid ? SPKGalleryPickerViewModeList : SPKGalleryPickerViewModeGrid;
    [[NSUserDefaults standardUserDefaults] setInteger:self.viewMode forKey:kSPKGalleryPickerViewModeKey];
    [self.collectionView setCollectionViewLayout:[self makeLayout] animated:NO];
    [self.collectionView reloadData];
    [self refreshBottomToolbarItems];
}

#pragma mark - Sort & Filter Presentation

- (void)configureGallerySheetForNavigation:(UINavigationController *)nav {
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        sheet.prefersGrabberVisible = YES;
    }
}

- (CGFloat)sheetFitHeightForContentHeight:(CGFloat)contentHeight {
    CGFloat bottomSafe = self.view.window.safeAreaInsets.bottom;
    CGFloat navBar = 56.0;
    return navBar + contentHeight + bottomSafe + 8.0;
}

- (CGFloat)sheetContentWidth {
    return CGRectGetWidth(self.view.bounds);
}

- (void)presentSort {
    SPKGallerySortViewController *vc = [[SPKGallerySortViewController alloc] init];
    vc.delegate = self;
    vc.currentSortMode = self.sortMode;
    vc.currentGroupByMediaType = self.sortGroupByMediaType;
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    [self configureGallerySheetForNavigation:nav];

    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        if (@available(iOS 16.0, *)) {
            CGFloat fitHeight = [self sheetFitHeightForContentHeight:[vc spkContentHeightForWidth:[self sheetContentWidth]]];
            UISheetPresentationControllerDetent *fit = [UISheetPresentationControllerDetent
                customDetentWithIdentifier:@"sparkle.picker.sort.fit"
                                  resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                      return MIN(context.maximumDetentValue, fitHeight);
                                  }];
            sheet.detents = @[ fit ];
            sheet.selectedDetentIdentifier = fit.identifier;
        } else {
            sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
        }
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    }

    [self presentViewController:nav animated:YES completion:nil];
}

- (NSArray<NSString *> *)availableSourceUsernames {
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"sourceUsername" ];
    req.returnsDistinctResults = YES;
    NSArray<NSDictionary *> *rows = [[SPKGalleryCoreDataStack shared].viewContext executeFetchRequest:req error:nil] ?: @[];
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *u = row[@"sourceUsername"];
        if (u.length > 0) [set addObject:u];
    }
    return [[set allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)presentFilter {
    SPKGalleryFilterViewController *vc = [[SPKGalleryFilterViewController alloc] init];
    vc.delegate = self;
    vc.filterTypes = self.filterTypes;
    vc.filterSources = self.filterSources;
    vc.filterFavoritesOnly = self.filterFavoritesOnly;
    vc.filterUsernames = [self.filterUsernames mutableCopy];
    NSArray<NSString *> *available = [self availableSourceUsernames];
    vc.availableUsernames = available.count > 1 ? available : @[];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    [self configureGallerySheetForNavigation:nav];

    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        if (@available(iOS 16.0, *)) {
            CGFloat fitHeight = [self sheetFitHeightForContentHeight:[vc spkContentHeightForWidth:[self sheetContentWidth]]];
            UISheetPresentationControllerDetent *fit = [UISheetPresentationControllerDetent
                customDetentWithIdentifier:@"sparkle.picker.filter.fit"
                                  resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                      return MIN(context.maximumDetentValue, fitHeight);
                                  }];
            sheet.detents = @[ fit ];
            sheet.selectedDetentIdentifier = fit.identifier;
        } else {
            sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
        }
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    }

    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Sort & Filter Delegates

- (void)sortController:(SPKGallerySortViewController *)controller didSelectSortMode:(SPKGallerySortMode)mode groupByMediaType:(BOOL)groupByMediaType {
    self.sortMode = mode;
    self.sortGroupByMediaType = groupByMediaType;
    [self reloadData];
}

- (void)filterController:(SPKGalleryFilterViewController *)controller
           didApplyTypes:(NSSet<NSNumber *> *)types
                 sources:(NSSet<NSNumber *> *)sources
           favoritesOnly:(BOOL)favoritesOnly
               usernames:(NSSet<NSString *> *)usernames {
    self.filterTypes = [types mutableCopy];
    self.filterSources = [sources mutableCopy];
    self.filterFavoritesOnly = favoritesOnly;
    self.filterUsernames = [usernames mutableCopy] ?: [NSMutableSet set];
    [self reloadData];
}

- (void)filterControllerDidClear:(SPKGalleryFilterViewController *)controller {
    [self.filterTypes removeAllObjects];
    [self.filterSources removeAllObjects];
    self.filterFavoritesOnly = NO;
    [self.filterUsernames removeAllObjects];
    [self reloadData];
}

- (void)handleGridPinch:(UIPinchGestureRecognizer *)pinch {
    if (self.viewMode != SPKGalleryPickerViewModeGrid)
        return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridPinchDisabledKey])
        return;
    if (pinch.state != UIGestureRecognizerStateChanged)
        return;
    CGFloat threshold = 0.30;
    if (pinch.scale > 1.0 + threshold && self.gridColumns > kSPKGalleryGridColumnsMin) {
        self.gridColumns = SPKGalleryGridColumnsAdjacent(self.gridColumns, YES);
        [self.collectionView.collectionViewLayout invalidateLayout];
        pinch.scale = 1.0;
    } else if (pinch.scale < 1.0 - threshold && self.gridColumns < kSPKGalleryGridColumnsMax) {
        self.gridColumns = SPKGalleryGridColumnsAdjacent(self.gridColumns, NO);
        [self.collectionView.collectionViewLayout invalidateLayout];
        pinch.scale = 1.0;
    }
}

#pragma mark - Empty State

/// Same icon + title + subtitle treatment as the Gallery, so an empty picker
/// reads as a deliberate state rather than a blank sheet with one grey line.
- (void)setupEmptyState {
    _emptyStateView = [[UIView alloc] initWithFrame:CGRectZero];
    _emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyStateView.hidden = YES;
    [self.view addSubview:_emptyStateView];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"media_empty"
                                                                                   pointSize:96.0]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [_emptyStateView addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleBody weight:UIFontWeightMedium] to:label];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [_emptyStateView addSubview:label];
    _emptyStateLabel = label;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline] to:subtitle];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [_emptyStateView addSubview:subtitle];
    _emptyStateSubtitle = subtitle;

    [NSLayoutConstraint activateConstraints:@[
        [_emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [_emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor
                                                      constant:-40.0],
        [_emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                                   constant:40.0],
        [_emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                                 constant:-40.0],

        [icon.topAnchor constraintEqualToAnchor:_emptyStateView.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:96.0],
        [icon.heightAnchor constraintEqualToConstant:96.0],

        [label.topAnchor constraintEqualToAnchor:icon.bottomAnchor
                                        constant:20.0],
        [label.leadingAnchor constraintEqualToAnchor:_emptyStateView.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:_emptyStateView.trailingAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:label.bottomAnchor
                                           constant:8.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:_emptyStateView.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:_emptyStateView.trailingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:_emptyStateView.bottomAnchor],
    ]];
}

- (void)updateEmptyState {
    BOOL empty = self.subfolders.count == 0 && self.files.count == 0;
    self.emptyStateView.hidden = !empty;
    self.collectionView.hidden = empty;

    if (!empty)
        return;

    BOOL hasFilters = self.filterTypes.count > 0 || self.filterSources.count > 0 ||
                      self.filterFavoritesOnly || self.filterUsernames.count > 0;
    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *folderName = self.folderPath.length > 0 ? self.folderPath.lastPathComponent : nil;

    NSString *title;
    NSString *subtitle;
    if (query.length > 0) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_NO_RESULTS_TEXT");
        // Point at the scope toggle: the match may simply live in another folder.
        subtitle = (!self.searchAllFolders && folderName.length > 0)
                       ? SPKL(@"GALLERY_GALLERY_PICKER_NOTHING_FOLDER_MATCHES_SEARCH_TRY_FOLDERS_TEXT")
                       : SPKL(@"GALLERY_GALLERY_PICKER_NO_MEDIA_MATCHES_SEARCH_TEXT");
    } else if (hasFilters) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_NO_MATCHING_FILES_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_PICKER_TRY_ADJUSTING_FILTERS_TEXT");
    } else if (folderName.length > 0) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_FOLDER_EMPTY_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_PICKER_NOTHING_HERE_CAN_SELECTED_TEXT");
    } else {
        title = SPKL(@"GALLERY_GALLERY_PICKER_NOTHING_SELECT_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_PICKER_THERE_NO_GALLERY_MEDIA_KIND_YET_TEXT");
    }
    self.emptyStateLabel.text = title;
    self.emptyStateSubtitle.text = subtitle;
}

- (void)updateDoneButton {
    if (!self.allowsMultipleSelection)
        return;
    [self refreshNavigationRightItems];
}

- (BOOL)showsFolderChips {
    return self.subfolders.count > 0 && self.searchQuery.length == 0;
}

- (void)cancelTapped {
    [self dismissPickerWithCompletion:nil];
}

- (void)doneTapped {
    NSMutableArray<SPKGalleryFile *> *files = [NSMutableArray arrayWithCapacity:self.selectedIDs.count];
    for (NSString *identifier in self.selectedIDs) {
        SPKGalleryFile *file = self.selectedFilesByID[identifier];
        if (file)
            [files addObject:file];
    }
    SPKGalleryPickerCompletion completion = [self.completion copy];
    [self dismissPickerWithCompletion:^{
        if (completion)
            completion(files);
    }];
}

- (void)dismissPickerWithCompletion:(void (^)(void))completion {
    UIViewController *controller = self.navigationController ?: self;
    [controller dismissViewControllerAnimated:YES
                                   completion:^{
                                       // After the transition, so the window stays
                                       // around to host it.
                                       SPKGalleryPickerTeardownWindow();
                                       if (completion) {
                                           completion();
                                       }
                                   }];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.files.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    SPKGalleryFile *file = self.files[indexPath.item];
    if (self.viewMode == SPKGalleryPickerViewModeGrid) {
        SPKGalleryGridCell *gridCell = [collectionView dequeueReusableCellWithReuseIdentifier:kSPKGalleryPickerGridCellID forIndexPath:indexPath];
        BOOL showsMeta = ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridShowSourceUsernameDisabledKey];
        BOOL showsUsername = showsMeta && self.gridColumns <= 3;
        [gridCell configureWithGalleryFile:file
                             selectionMode:self.allowsMultipleSelection
                                  selected:[self.selectedIDs containsObject:file.identifier]
                               showsSource:showsMeta
                             showsUsername:showsUsername];
        return gridCell;
    }

    SPKGalleryListCollectionCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kSPKGalleryPickerListCellID forIndexPath:indexPath];
    [cell configureWithGalleryFile:file
                     selectionMode:self.allowsMultipleSelection
                          selected:[self.selectedIDs containsObject:file.identifier]];
    [cell setMoreActionsMenu:nil];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    if (![kind isEqualToString:UICollectionElementKindSectionHeader]) {
        return [[UICollectionReusableView alloc] init];
    }
    SPKGalleryFolderChipBar *header =
        [collectionView dequeueReusableSupplementaryViewOfKind:kind
                                           withReuseIdentifier:kSPKGalleryPickerFolderChipHeaderID
                                                  forIndexPath:indexPath];
    if (![self showsFolderChips]) {
        return header;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:self.subfolders.count];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithCapacity:self.subfolders.count];
    for (NSString *path in self.subfolders) {
        [names addObject:path.lastPathComponent];
        [counts addObject:@([self eligibleFileCountForFolderPath:path])];
    }

    __weak typeof(self) weakSelf = self;
    [header configureWithFolderNames:names
                              counts:counts
                            onSelect:^(NSInteger index) {
                                [weakSelf openSubfolderAtIndex:index];
                            }
                        menuProvider:nil];
    return header;
}

- (void)openSubfolderAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.subfolders.count)
        return;
    [self navigateIntoFolder:self.subfolders[index]];
}

#pragma mark - Folder Navigation

- (BOOL)canNavigateBackInFolders {
    return self.folderTrail.count > 0;
}

/// Descends into `subfolderPath` by re-scoping this screen's data instead of
/// pushing another picker, so the chrome and the running selection stay intact.
- (void)navigateIntoFolder:(NSString *)subfolderPath {
    if (subfolderPath.length == 0)
        return;
    // Remember where we were so returning restores the grid position.
    [self.folderScrollOffsets addObject:[NSValue valueWithCGPoint:self.collectionView.contentOffset]];
    [self.folderTrail addObject:subfolderPath];
    self.folderPath = subfolderPath;

    [self prepareForFolderChange];
    __weak typeof(self) weakSelf = self;
    [self replaceGridContentWithCrossfade:^{
        [weakSelf reloadData];
        [weakSelf scrollGridToTop];
    }];
    [self updateFolderTitle];
    [self refreshLeadingNavItem];
}

/// Returns to the parent folder, restoring its previous scroll position.
- (void)navigateBackInFolders {
    if (![self canNavigateBackInFolders])
        return;
    [self.folderTrail removeLastObject];
    self.folderPath = self.folderTrail.lastObject; // nil at root

    CGPoint restoreOffset = CGPointZero;
    BOOL hasRestoreOffset = NO;
    if (self.folderScrollOffsets.count > 0) {
        restoreOffset = [self.folderScrollOffsets.lastObject CGPointValue];
        [self.folderScrollOffsets removeLastObject];
        hasRestoreOffset = YES;
    }

    [self prepareForFolderChange];
    __weak typeof(self) weakSelf = self;
    [self replaceGridContentWithCrossfade:^{
        [weakSelf reloadData];
        if (hasRestoreOffset) {
            [weakSelf.collectionView setContentOffset:restoreOffset animated:NO];
        } else {
            [weakSelf scrollGridToTop];
        }
    }];
    [self updateFolderTitle];
    [self refreshLeadingNavItem];
}

/// A folder change starts fresh: a search scoped to the folder we just left
/// would otherwise silently carry over and hide the new folder's contents.
- (void)prepareForFolderChange {
    if (self.searchController.active) {
        self.searchController.active = NO;
    }
    self.searchQuery = @"";
    self.searchController.searchBar.text = nil;
    self.searchAllFolders = NO;
    self.searchController.searchBar.selectedScopeButtonIndex = 0;
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    BOOL allFolders = (selectedScope == 1);
    if (allFolders == self.searchAllFolders)
        return;
    self.searchAllFolders = allFolders;
    [self reloadData];
}

- (void)scrollGridToTop {
    CGFloat topY = -self.collectionView.adjustedContentInset.top;
    [self.collectionView setContentOffset:CGPointMake(0.0, topY) animated:NO];
}

/// Cross-dissolves the grid's contents (no positional slide, so no layout jank)
/// as a stand-in for the push animation we no longer perform.
- (void)replaceGridContentWithCrossfade:(void (^)(void))contentUpdate {
    if (!contentUpdate)
        return;
    [UIView transitionWithView:self.collectionView
                      duration:0.22
                       options:(UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction)
                    animations:contentUpdate
                    completion:nil];
}

- (void)updateFolderTitle {
    self.title = self.folderPath.length > 0 ? self.folderPath.lastPathComponent : self.pickerTitle;
}

/// Close at the root, back while inside a folder — the only affordance for
/// leaving a folder now that there is no navigation stack to pop.
- (void)refreshLeadingNavItem {
    UIBarButtonItem *leadingItem;
    if ([self canNavigateBackInFolders]) {
        leadingItem = SPKMediaChromeTopBarButtonItem(@"chevron_left", self, @selector(navigateBackInFolders));
        leadingItem.accessibilityLabel = SPKL(@"GALLERY_GALLERY_PICKER_BACK_TEXT");
    } else {
        leadingItem = SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(cancelTapped));
        leadingItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
    }
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ leadingItem ]);
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = SPKCollectionViewUsableWidth(collectionView);
    if (self.viewMode == SPKGalleryPickerViewModeGrid) {
        NSInteger columns = SPKAdaptiveColumnCount(MAX(kSPKGalleryGridColumnsMin, MIN(kSPKGalleryGridColumnsMax, self.gridColumns)), width);
        CGFloat totalSpacing = kSPKGalleryPickerGridSpacing * (columns - 1);
        CGFloat side = floor((width - totalSpacing) / columns);
        return CGSizeMake(side, side);
    }
    return CGSizeMake(width, 72.0);
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                             layout:(UICollectionViewLayout *)layout
    referenceSizeForHeaderInSection:(NSInteger)section {
    if (section == 0 && [self showsFolderChips]) {
        return CGSizeMake(collectionView.bounds.size.width, [SPKGalleryFolderChipBar preferredHeight]);
    }
    return CGSizeZero;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    SPKGalleryFile *file = self.files[indexPath.item];
    if (self.allowsMultipleSelection) {
        if ([self.selectedIDs containsObject:file.identifier]) {
            [self.selectedIDs removeObject:file.identifier];
            [self.selectedFilesByID removeObjectForKey:file.identifier];
        } else {
            [self.selectedIDs addObject:file.identifier];
            self.selectedFilesByID[file.identifier] = file;
        }
        [self.collectionView reloadItemsAtIndexPaths:@[ indexPath ]];
        [self updateDoneButton];
        return;
    }

    SPKGalleryPickerCompletion completion = [self.completion copy];
    [self dismissPickerWithCompletion:^{
        if (completion)
            completion(@[ file ]);
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.searchQuery = searchController.searchBar.text ?: @"";
    [self reloadData];
}

@end
