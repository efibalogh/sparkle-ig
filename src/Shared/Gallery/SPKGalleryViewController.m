#import "SPKStrings.h"
#import "SPKGalleryViewController.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../MediaTrim/SPKTrimConfiguration.h"
#import "../MediaTrim/SPKTrimEditorViewController.h"
#import "../MediaTrim/SPKTrimResult.h"
#import "../MediaTrim/SPKTrimSaveCoordinator.h"
#import "../PhotoEdit/SPKPhotoEditorViewController.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryDeleteViewController.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryFileDetailsViewController.h"
#import "SPKGalleryFilterViewController.h"
#import "SPKGalleryFolderCell.h"
#import "SPKGalleryFolderChipBar.h"
#import "SPKGalleryGridCell.h"
#import "SPKGalleryGridDensity.h"
#import "SPKGalleryHiddenSources.h"
#import "SPKGalleryListCollectionCell.h"
#import "SPKGalleryLockViewController.h"
#import "SPKGalleryManager.h"
#import "SPKGalleryOriginController.h"
#import "SPKGallerySettingsViewController.h"
#import "SPKGallerySortViewController.h"
#import <CoreData/CoreData.h>

static NSString *const kGridCellID = @"SPKGalleryGridCell";
static NSString *const kListCellID = @"SPKGalleryListCell";
static NSString *const kFolderCellID = @"SPKGalleryFolderCell";
static NSString *const kFolderChipHeaderID = @"SPKGalleryFolderChipHeader";

static NSString *const kSortModeKey = @"gallery_sort_mode";
static NSString *const kSortGroupByTypeKey = @"gallery_sort_group_by_type";
static NSString *const kViewModeKey = @"gallery_view_mode"; // 0 = grid, 1 = list
static NSString *const kFavoritesAtTopKey = @"gallery_show_favorites_top";

static CGFloat const kGridSpacing = 2.0;
static NSInteger const kSPKUINavigationItemSearchBarPlacementIntegratedButton = 4;

static UIImage *SPKGalleryMenuActionIcon(NSString *resourceName) {
    // menuIconNamed: avoids the UIGraphicsImageRenderer downscale that iOS 16's
    // UIMenu renders blank for vector-backed (.svg) glyphs. See SPKAssetUtils.
    return [SPKAssetUtils menuIconNamed:(resourceName.length > 0 ? resourceName : @"more")];
}

// Counts items in `folderPath` (including descendants). When `extraFilter` is
// non-nil (the active media-type/source/favorites/username filter), it's ANDed
// in so the count reflects what the folder actually shows under the current
// filter rather than its raw total.
static NSInteger SPKGalleryItemCountForFolderPath(NSManagedObjectContext *context, NSString *folderPath, NSPredicate *extraFilter) {
    if (folderPath.length == 0)
        return 0;
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    NSPredicate *folder = [NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                           folderPath, [folderPath stringByAppendingString:@"/"]];
    NSMutableArray<NSPredicate *> *parts = [NSMutableArray arrayWithObject:folder];
    NSPredicate *visible = SPKGalleryVisibleSourcesPredicate();
    if (visible)
        [parts addObject:visible];
    if (extraFilter)
        [parts addObject:extraFilter];
    request.predicate = parts.count == 1 ? folder : [NSCompoundPredicate andPredicateWithSubpredicates:parts];
    return [context countForFetchRequest:request error:nil];
}

typedef NS_ENUM(NSInteger, SPKGalleryViewMode) {
    SPKGalleryViewModeGrid = 0,
    SPKGalleryViewModeList = 1,
};

@interface SPKGalleryViewController () <UICollectionViewDataSource,
                                        UICollectionViewDelegate,
                                        UICollectionViewDelegateFlowLayout,
                                        NSFetchedResultsControllerDelegate,
                                        SPKGallerySortViewControllerDelegate,
                                        SPKGalleryFilterViewControllerDelegate,
                                        UIAdaptivePresentationControllerDelegate,
                                        UISearchResultsUpdating,
                                        UISearchControllerDelegate,
                                        UISearchBarDelegate>

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;
// Bottom toolbar is the hosting navigation controller's native UIToolbar.
// iOS 26 renders it as a Liquid Glass pill; earlier systems show a standard bar.

// Folder navigation. Folders are browsed in place (one shared-chrome view
// controller) rather than by pushing a new view controller per folder, so the
// nav bar / search / toolbar are never recreated or cross-faded — which is what
// produced the Liquid Glass transition flashes. `folderTrail` is the stack of
// folder paths from root to the current folder (empty at root); `folderScrollOffsets`
// holds the parallel grid scroll position to restore when navigating back.
@property (nonatomic, copy, nullable) NSString *currentFolderPath;
@property (nonatomic, strong) NSMutableArray<NSString *> *folderTrail;
@property (nonatomic, strong) NSMutableArray<NSValue *> *folderScrollOffsets;
@property (nonatomic, strong) NSArray<NSString *> *subfolders;

// View mode
@property (nonatomic, assign) SPKGalleryViewMode viewMode;
/// Number of columns in grid mode (clamped to kGridColumnsMin...kGridColumnsMax).
@property (nonatomic, assign) NSInteger gridColumns;

// Sort
@property (nonatomic, assign) SPKGallerySortMode sortMode;
@property (nonatomic, assign) BOOL sortGroupByMediaType;

// Filter
@property (nonatomic, strong) NSMutableSet<NSNumber *> *filterTypes;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *filterSources;
@property (nonatomic, assign) BOOL filterFavoritesOnly;
@property (nonatomic, strong) NSMutableSet<NSString *> *filterUsernames;
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedFileIDs;
// Set while the two-finger multiple-selection drag is in flight. The drag drives
// selection through the collection view's own selected state, so the tap path
// has to stop clearing it, and the header chips have to stay put until the
// fingers lift (removing them mid-drag shifts the rows under them).
@property (nonatomic, weak, nullable) UIPinchGestureRecognizer *gridDensityPinch;
@property (nonatomic, weak, nullable) UIGestureRecognizer *multiSelectOneFingerPan;
@property (nonatomic, assign) BOOL multiSelectDragActive;
@property (nonatomic, assign) BOOL multiSelectDragOpenedSelection;
@property (nonatomic, strong, nullable) UISelectionFeedbackGenerator *multiSelectDragFeedback;
// Signatures of the last-applied nav bar items, tracked separately for the
// leading and trailing groups. The leading button changes as you browse folders
// (close ⇄ back), but the trailing group does not — so reassigning trailing on
// every folder change just re-lays-out its Liquid Glass pill (a visible jump).
@property (nonatomic, copy) NSString *lastLeadingNavSignature;
@property (nonatomic, copy) NSString *lastTrailingNavSignature;
@property (nonatomic, strong) UISearchController *searchController;
// The iOS 26 integrated search button, vended and cached once at load so the
// bottom toolbar always installs the same fully-materialized instance. If we let
// each refresh re-vend it lazily, the nav bar wins the first transition layout
// and briefly renders it in its top-right home (the flash) before we relocate it.
@property (nonatomic, strong) UIBarButtonItem *cachedSearchToolbarItem;
@property (nonatomic, copy) NSString *searchQuery;
@property (nonatomic, assign) BOOL preservingSearchQuery;
// When YES (and a query is active), search ignores the folder scope and matches
// across all folders; the search bar scope buttons toggle it.
@property (nonatomic, assign) BOOL searchAllFolders;
// Set when the gallery is opened on a seeded filter (e.g. "instants from @user"): that
// entry point means "everything matching", so it spans folders whatever the browsing
// pref says -- otherwise a match filed inside a folder would look like it doesn't exist.
@property (nonatomic, assign) BOOL forcesFlatBrowsing;
// Title for a gallery opened on a seeded filter ("@user" rather than "Gallery"). Only
// used at the root of the browse trail -- inside a folder the folder name still wins.
@property (nonatomic, copy, nullable) NSString *seededFilterTitle;
// A gallery opened on a seeded filter *is* the answer to a question already asked ("this
// user's Instants"), so it drops the filter and search affordances: re-filtering would
// fight the seed, and searching one person's saved media has nothing to narrow.
@property (nonatomic, assign) BOOL locksSeededFilter;

@end

@implementation SPKGalleryViewController

#pragma mark - Presentation

+ (instancetype)galleryFilteredToSources:(NSSet<NSNumber *> *)sources
                               usernames:(NSSet<NSString *> *)usernames
                                   title:(NSString *)title {
    SPKGalleryViewController *vc = [[SPKGalleryViewController alloc] init];
    vc.seededFilterTitle = [title copy];
    // Seeded before the view loads, so the very first fetch is already filtered -- no
    // flash of the full gallery.
    if (sources.count > 0)
        vc.filterSources = [sources mutableCopy];
    if (usernames.count > 0)
        vc.filterUsernames = [usernames mutableCopy];
    vc.forcesFlatBrowsing = (sources.count > 0 || usernames.count > 0);
    vc.locksSeededFilter = vc.forcesFlatBrowsing;
    return vc;
}

+ (void)presentGallery {
    UIViewController *presenter = topMostController();
    SPKGalleryManager *mgr = [SPKGalleryManager sharedManager];

    void (^presentGalleryNav)(void) = ^{
        SPKGalleryViewController *vc = [[SPKGalleryViewController alloc] init];
        UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [presenter presentViewController:nav animated:YES completion:nil];
    };

    // Authenticate on the presenter (Instagram / settings) before any gallery UI is shown,
    // so Face ID / passcode runs first with no flash of gallery content.
    if (mgr.isLockEnabled && !mgr.isUnlocked) {
        [SPKGalleryLockViewController presentUnlockFromViewController:presenter
                                                           completion:^(BOOL success) {
                                                               if (!success)
                                                                   return;
                                                               presentGalleryNav();
                                                           }];
    } else {
        presentGalleryNav();
    }
}

#pragma mark - Init

- (instancetype)init {
    return [self initWithFolderPath:nil];
}

- (instancetype)initWithFolderPath:(NSString *)folderPath {
    if ((self = [super init])) {
        _currentFolderPath = [folderPath copy];
        _folderTrail = [NSMutableArray array];
        _folderScrollOffsets = [NSMutableArray array];
        // Seed the trail if we were opened directly inside a folder (root is empty).
        if (_currentFolderPath.length > 0) {
            [_folderTrail addObject:_currentFolderPath];
        }
        _filterTypes = [NSMutableSet set];
        _filterSources = [NSMutableSet set];
        _filterUsernames = [NSMutableSet set];
        _filterFavoritesOnly = NO;
        _selectedFileIDs = [NSMutableSet set];

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        _sortMode = (SPKGallerySortMode)[d integerForKey:kSortModeKey];
        _sortGroupByMediaType = [d boolForKey:kSortGroupByTypeKey];
        if (_sortMode == SPKGallerySortModeTypeAsc || _sortMode == SPKGallerySortModeTypeDesc) {
            _sortMode = SPKGallerySortModeDateAddedDesc;
            _sortGroupByMediaType = YES;
            [d setInteger:_sortMode forKey:kSortModeKey];
            [d setBool:_sortGroupByMediaType forKey:kSortGroupByTypeKey];
        }
        _viewMode = (SPKGalleryViewMode)[d integerForKey:kViewModeKey];
        _gridColumns = SPKGalleryGridColumns();
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGalleryPreferencesChanged:)
                                                 name:@"SPKGalleryFavoritesSortPreferenceChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGridControlsPreferenceChanged:)
                                                 name:kSPKGalleryGridControlsChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGalleryPreferencesChanged:)
                                                 name:SPKGalleryHiddenSourcesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGalleryPreferencesChanged:)
                                                 name:kSPKGalleryBrowsingScopeChangedNotification
                                               object:nil];
    // Re-scope when the active account changes (per-account filter).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGalleryPreferencesChanged:)
                                                 name:SPKAccountDidChangeNotification
                                               object:nil];

    [self setupCenteredTitle];
    [self setupNavigationItems];
    [self setupSearchController];
    [self setupBottomToolbar];
    [self setupCollectionView];
    [self setupEmptyState];
    [self setupFolderBackGesture];
    [self setupFetchedResultsController];
    [self reloadSubfolders];
    [self updateEmptyState];

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationController.presentationController.delegate = self;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Pick up an in-app account switch that didn't round-trip through the
    // background; posts SPKAccountDidChangeNotification (→ refetch) if it moved.
    [[SPKAccountManager shared] refreshCurrentAccount];
    [self applyGalleryNavigationChrome];
    [self refreshNavigationItems];
    [self refreshBottomToolbarItems];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self updateCollectionInsets];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // UIKit adds its selection recognizers with the interaction rather than at
    // init, and recomputes their enabled state whenever it revisits the
    // collection view's selection support, so the one-finger pan is caught here
    // instead of only once at setup.
    [self disableOneFingerMultiSelectPan];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Hide the shared toolbar when navigating to a child that shouldn't show it
    // (e.g. settings). Keep it visible when pushing another gallery screen so it
    // doesn't flicker during the push animation; that screen manages its own.
    UIViewController *incoming = self.navigationController.topViewController;
    if (incoming && incoming != self && ![incoming isKindOfClass:[SPKGalleryViewController class]]) {
        [self.navigationController setToolbarHidden:YES animated:animated];
    }
    if (self.navigationController.viewControllers.firstObject != self)
        return;
    if (self.isMovingFromParentViewController)
        return;
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        if ([SPKGalleryManager sharedManager].isLockEnabled) {
            [[SPKGalleryManager sharedManager] lockGallery];
        }
    }
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if ([SPKGalleryManager sharedManager].isLockEnabled) {
        [[SPKGalleryManager sharedManager] lockGallery];
    }
}

- (void)dismissSelf {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)popSelf {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Navigation & chrome

/// Shared neutral chrome matching the Instagram-inspired custom palette.
- (void)applyGalleryNavigationChrome {
    UINavigationController *nav = self.navigationController;
    if (!nav) {
        return;
    }
    nav.navigationBar.prefersLargeTitles = NO;
    SPKApplyMediaChromeNavigationBar(nav.navigationBar);
}

- (void)setupCenteredTitle {
    NSString *text = nil;
    if (self.selectionMode) {
        text = self.selectedFileIDs.count > 0
                   ? [NSString stringWithFormat:SPKL(@"AUTO_SAVE_AUTO_SAVE_FILTER_VALUE_SELECTED_FORMAT"), (unsigned long)self.selectedFileIDs.count]
                   : SPKL(@"GALLERY_GALLERY_SELECT_FILES_TEXT");
    } else {
        text = self.currentFolderPath.length > 0 ? [self.currentFolderPath lastPathComponent]
                                                 : (self.seededFilterTitle.length > 0 ? self.seededFilterTitle : SPKL(@"GALLERY_TITLE"));
    }
    self.navigationItem.titleView = nil;
    self.title = text;
}

- (void)setupNavigationItems {
    [self refreshNavigationItems];
}

- (void)setupSearchController {
    // A seeded filter answers the only question this screen exists to answer, so it gets
    // no search bar and no iOS 26 integrated search button (which is vended from here).
    if (self.locksSeededFilter)
        return;

    UISearchController *controller = [[UISearchController alloc] initWithSearchResultsController:nil];
    controller.obscuresBackgroundDuringPresentation = NO;
    controller.hidesNavigationBarDuringPresentation = NO;
    controller.searchResultsUpdater = self;
    controller.delegate = self;
    controller.searchBar.delegate = self;
    [controller.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                  forSearchBarIcon:UISearchBarIconSearch
                             state:UIControlStateNormal];
    controller.searchBar.placeholder = SPKL(@"GALLERY_GALLERY_PICKER_SEARCH_GALLERY_TEXT");
    // Scope toggle: search the current folder, or across all folders. Let the
    // search controller manage the scope bar's visibility (shown while searching).
    controller.searchBar.scopeButtonTitles = @[ SPKL(@"GALLERY_GALLERY_PICKER_FOLDER_TEXT"), SPKL(@"GALLERY_GALLERY_PICKER_FOLDERS_TEXT") ];
    controller.automaticallyShowsScopeBar = YES;
    self.searchController = controller;
    self.navigationItem.searchController = controller;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    // iOS 26 integrated search button: collapses search into a single button (the
    // vended `searchBarPlacementBarButtonItem`) instead of an always-visible bar.
    // That item is toolbar-only, so it lives in the bottom toolbar.
    if (@available(iOS 26.0, *)) {
        @try {
            [self.navigationItem setValue:@(kSPKUINavigationItemSearchBarPlacementIntegratedButton) forKey:@"preferredSearchBarPlacement"];
            // Force the integrated button to fully materialize now (and cache it), so
            // the bottom toolbar claims a ready instance on its very first build. If
            // it's vended lazily later, the nav bar renders it in its top-right home
            // for a frame during the first transition — the flash the user sees, which
            // only stops once search has been activated (which forces this same
            // materialization). Loading the controller's view commits that state up
            // front, the way a real activation does.
            [self.searchController loadViewIfNeeded];
            UIBarButtonItem *vended = [self.navigationItem valueForKey:@"searchBarPlacementBarButtonItem"];
            if ([vended isKindOfClass:[UIBarButtonItem class]]) {
                self.cachedSearchToolbarItem = vended;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    self.definesPresentationContext = YES;
}

- (void)refreshNavigationItems {
    // Selection-mode select-all icon reflects current selection.
    NSString *selectionIcon = @"circle";
    NSString *selectionAccessibilityLabel = SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_SELECT_TEXT");
    if (self.selectionMode) {
        NSArray<SPKGalleryFile *> *files = [self visibleGalleryFiles];
        BOOL allSelected = files.count > 0 && self.selectedFileIDs.count == files.count;
        if (allSelected) {
            selectionIcon = @"circle_check_filled";
            selectionAccessibilityLabel = SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_DESELECT_TEXT");
        } else if (self.selectedFileIDs.count > 0) {
            selectionIcon = @"circle_check";
            selectionAccessibilityLabel = SPKL(@"ACTION_BUTTON_BULK_MEDIA_SELECTION_SELECT_TEXT");
        }
    }

    // Leading group changes as you browse (close ⇄ back) or enter selection
    // (Cancel). Apply only when it actually changes.
    // A pushed gallery (e.g. opened from the saved-instants list) goes back to whatever
    // pushed it rather than dismissing the whole stack.
    BOOL isPushed = self.navigationController && self.navigationController.viewControllers.firstObject != self;
    NSString *leadingSignature = self.selectionMode
                                     ? @"cancel"
                                     : ([self canNavigateBackInFolders] ? @"back" : (isPushed ? @"pop" : @"close"));
    if (![leadingSignature isEqualToString:self.lastLeadingNavSignature]) {
        self.lastLeadingNavSignature = leadingSignature;
        UIBarButtonItem *leadingItem;
        if (self.selectionMode) {
            leadingItem = SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(exitSelectionMode));
            leadingItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
        } else if ([self canNavigateBackInFolders]) {
            leadingItem = SPKMediaChromeTopBarButtonItem(@"chevron_left", self, @selector(navigateBackInFolders));
        } else if (isPushed) {
            leadingItem = SPKMediaChromeTopBarButtonItem(@"chevron_left", self, @selector(popSelf));
            leadingItem.accessibilityLabel = SPKL(@"GALLERY_GALLERY_PICKER_BACK_TEXT");
        } else {
            leadingItem = SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(dismissSelf));
        }
        SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ leadingItem ]);
    }

    // Trailing group only changes between browse (Select + Settings) and selection
    // (Select-all, whose icon tracks the count) — never on folder navigation. Apply
    // only on change so the Liquid Glass pill doesn't re-lay-out (a visible jump).
    NSString *trailingSignature = self.selectionMode
                                      ? [@"selectAll:" stringByAppendingString:selectionIcon]
                                      : @"browse";
    if (![trailingSignature isEqualToString:self.lastTrailingNavSignature]) {
        self.lastTrailingNavSignature = trailingSignature;
        if (self.selectionMode) {
            UIBarButtonItem *selectAllItem = SPKMediaChromeTopBarButtonItem(selectionIcon, self, @selector(selectAllVisibleFiles));
            selectAllItem.accessibilityLabel = selectionAccessibilityLabel;
            SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ selectAllItem ]);
        } else {
            // Search is the native iOS 26 integrated button (toolbar-only), so it
            // lives in the bottom toolbar, not here.
            NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
            [items addObject:SPKMediaChromeTopBarButtonItem(@"circle_check", self, @selector(enterSelectionMode))];
            [items addObject:SPKMediaChromeTopBarButtonItem(@"settings", self, @selector(pushSettings))];
            SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, items);
        }
    }
}

- (void)setupBottomToolbar {
    [self refreshBottomToolbarItems];
}

- (UIBarButtonItem *)galleryBottomBarItemWithResource:(NSString *)resourceName accessibility:(NSString *)label action:(SEL)action {
    return SPKMediaChromeBottomBarButtonItem(resourceName, label, self, action);
}

- (void)refreshBottomToolbarItems {
    SPKMediaChromeConfigureBottomToolbar(self.navigationController.toolbar);

    NSArray<UIBarButtonItem *> *primary;
    if (self.selectionMode) {
        UIBarButtonItem *shareItem = [self galleryBottomBarItemWithResource:@"share" accessibility:SPKL(@"GALLERY_GALLERY_SHARE_SELECTED_TEXT") action:@selector(shareSelectedFiles)];
        UIBarButtonItem *moveItem = [self galleryBottomBarItemWithResource:@"folder_move" accessibility:SPKL(@"GALLERY_GALLERY_MOVE_SELECTED_TEXT") action:@selector(moveSelectedFiles)];
        UIBarButtonItem *favoriteItem = [self galleryBottomBarItemWithResource:@"heart" accessibility:SPKL(@"GALLERY_GALLERY_FAVORITE_SELECTED_TEXT") action:@selector(toggleFavoriteForSelectedFiles)];
        UIBarButtonItem *deleteItem = [self galleryBottomBarItemWithResource:@"trash" accessibility:SPKL(@"GALLERY_GALLERY_DELETE_SELECTED_TEXT") action:@selector(deleteSelectedFiles)];
        deleteItem.tintColor = [SPKUtils SPKColor_InstagramDestructive];

        primary = @[ shareItem, moveItem, favoriteItem, deleteItem ];
    } else {
        UIBarButtonItem *filterItem = [self galleryBottomBarItemWithResource:@"filter" accessibility:SPKL(@"GALLERY_GALLERY_FILTER_FILTER_TEXT") action:@selector(presentFilter)];
        UIBarButtonItem *sortItem = [self galleryBottomBarItemWithResource:@"sort" accessibility:SPKL(@"MENU_SORT") action:@selector(presentSort)];

        NSString *toggleResource = self.viewMode == SPKGalleryViewModeGrid ? @"list" : @"grid";
        NSString *toggleAX = self.viewMode == SPKGalleryViewModeGrid ? SPKL(@"GALLERY_GALLERY_PICKER_LIST_VIEW_TEXT") : SPKL(@"GALLERY_GALLERY_PICKER_GRID_VIEW_TEXT");
        UIBarButtonItem *toggleItem = [self galleryBottomBarItemWithResource:toggleResource accessibility:toggleAX action:@selector(toggleViewMode)];

        UIBarButtonItem *folderItem = [self galleryBottomBarItemWithResource:@"folder" accessibility:SPKL(@"GALLERY_GALLERY_NEW_FOLDER_TEXT") action:@selector(presentCreateFolder)];

        primary = self.locksSeededFilter ? @[ toggleItem, sortItem, folderItem ]
                                         : @[ toggleItem, sortItem, filterItem, folderItem ];
    }

    if (self.locksSeededFilter) {
        self.toolbarItems = SPKMediaChromeBottomToolbarItems(primary);
        return;
    }

    // Search lives in its own trailing capsule in both browse and selection modes
    // (you can search to find more items to select).
    self.toolbarItems = SPKMediaChromeBottomToolbarItemsWithTrailingGroup(primary, @[ [self bottomToolbarSearchItem] ]);
}

// The bottom toolbar's search item: the native iOS 26 integrated search button
// (toolbar-only, materialized + cached at load), falling back to a custom button
// that reveals the nav bar search on older systems.
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
        searchItem = [self galleryBottomBarItemWithResource:@"search" accessibility:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT") action:@selector(activateSearch)];
    }
    return searchItem;
}

#pragma mark - Collection View

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self layoutForViewMode:self.viewMode];

    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    _collectionView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.alwaysBounceVertical = YES;
    _collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [_collectionView registerClass:[SPKGalleryGridCell class] forCellWithReuseIdentifier:kGridCellID];
    [_collectionView registerClass:[SPKGalleryListCollectionCell class] forCellWithReuseIdentifier:kListCellID];
    [_collectionView registerClass:[SPKGalleryFolderCell class] forCellWithReuseIdentifier:kFolderCellID];
    [_collectionView registerClass:[SPKGalleryFolderChipBar class]
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
               withReuseIdentifier:kFolderChipHeaderID];
    [self.view addSubview:_collectionView];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleGridPinch:)];
    [_collectionView addGestureRecognizer:pinch];
    self.gridDensityPinch = pinch;
    [self updateTwoFingerGestureConfiguration];

    [NSLayoutConstraint activateConstraints:@[
        [_collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateCollectionInsets];
}

- (void)updateCollectionInsets {
    // The hosting navigation controller folds the visible bottom toolbar into
    // this view controller's safe area, and the collection view's automatic
    // content-inset adjustment already accounts for it. Keep our manual bottom
    // inset at zero so we don't double-count the toolbar height.
    UIEdgeInsets contentInsets = self.collectionView.contentInset;
    contentInsets.bottom = 0.0;
    self.collectionView.contentInset = contentInsets;

    UIEdgeInsets indicatorInsets = self.collectionView.scrollIndicatorInsets;
    indicatorInsets.bottom = 0.0;
    self.collectionView.scrollIndicatorInsets = indicatorInsets;
}

- (UICollectionViewLayout *)layoutForViewMode:(SPKGalleryViewMode)mode {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    if (mode == SPKGalleryViewModeGrid) {
        layout.minimumInteritemSpacing = kGridSpacing;
        layout.minimumLineSpacing = kGridSpacing;
    } else {
        layout.minimumInteritemSpacing = 0;
        layout.minimumLineSpacing = 0;
    }
    layout.sectionHeadersPinToVisibleBounds = SPKGalleryFolderBarPinned();
    return layout;
}

- (void)toggleViewMode {
    if (self.selectionMode) {
        [self exitSelectionMode];
    }
    self.viewMode = self.viewMode == SPKGalleryViewModeGrid ? SPKGalleryViewModeList : SPKGalleryViewModeGrid;
    [[NSUserDefaults standardUserDefaults] setInteger:self.viewMode forKey:kViewModeKey];

    UICollectionViewLayout *newLayout = [self layoutForViewMode:self.viewMode];
    [self.collectionView setCollectionViewLayout:newLayout animated:NO];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self refreshBottomToolbarItems];
    [self updateTwoFingerGestureConfiguration];
}

/// List and grid both want the two-finger touches, so hand them to exactly one
/// owner per mode: the multiple-selection drag in list, the density pinch in grid.
///
/// UIKit keeps its own two-finger selection pan disabled unless the collection
/// view reports that it supports multiple selection, which it answers from
/// allowsMultipleSelectionDuringEditing (and from allowsMultipleSelection when it
/// decides whether the sweep may run). Both are off by default, so implementing
/// the delegate methods alone leaves the gesture permanently disabled. Turning
/// them on costs nothing here: taps deselect immediately and the drag hands its
/// result back to selectedFileIDs, so the collection view's own selected state is
/// only ever borrowed for the length of a sweep.
- (void)updateTwoFingerGestureConfiguration {
    BOOL listMode = (self.viewMode == SPKGalleryViewModeList);
    self.gridDensityPinch.enabled = !listMode;
    self.collectionView.allowsMultipleSelection = listMode;
    self.collectionView.allowsMultipleSelectionDuringEditing = listMode;
    [self disableOneFingerMultiSelectPan];
}

/// Supporting multiple selection brings in a second selection recognizer beside
/// the two-finger drag: a one-finger pan that starts a sweep from a swipe across
/// the list's short axis. That turns an ordinary horizontal swipe into a
/// selection, including one that begins at the scroll indicator, so only the
/// two-finger drag is left switched on. If a future iOS drops the recognizer
/// this finds nothing and the gesture set is whatever that release ships.
- (void)disableOneFingerMultiSelectPan {
    if (self.multiSelectOneFingerPan) {
        self.multiSelectOneFingerPan.enabled = NO;
        return;
    }

    Class oneFingerPanClass = NSClassFromString(@"_UIMultiSelectOneFingerPanGesture");
    if (!oneFingerPanClass) {
        return;
    }
    for (UIGestureRecognizer *recognizer in self.collectionView.gestureRecognizers) {
        if ([recognizer isKindOfClass:oneFingerPanClass]) {
            recognizer.enabled = NO;
            self.multiSelectOneFingerPan = recognizer;
            break;
        }
    }
}

#pragma mark - Grid Density

- (void)setGridColumns:(NSInteger)gridColumns {
    NSInteger clamped = MAX(kSPKGalleryGridColumnsMin, MIN(kSPKGalleryGridColumnsMax, gridColumns));
    if (clamped == _gridColumns)
        return;
    _gridColumns = clamped;
    SPKGalleryGridSetColumns(clamped);
}

/// Applies a new column count with a smooth relayout. No-op outside grid mode.
- (void)applyGridColumns:(NSInteger)columns animated:(BOOL)animated {
    if (self.viewMode != SPKGalleryViewModeGrid)
        return;
    NSInteger clamped = MAX(kSPKGalleryGridColumnsMin, MIN(kSPKGalleryGridColumnsMax, columns));
    if (clamped == self.gridColumns)
        return;

    self.gridColumns = clamped;

    if (animated) {
        [UIView animateWithDuration:0.25
            delay:0.0
            options:UIViewAnimationOptionCurveEaseInOut
            animations:^{
                [self.collectionView.collectionViewLayout invalidateLayout];
                [self.collectionView layoutIfNeeded];
            }
            completion:^(__unused BOOL finished) {
                // Username overlay visibility depends on density; refresh cells.
                [self reconfigureVisibleGridCells];
            }];
    } else {
        [self.collectionView.collectionViewLayout invalidateLayout];
        [self reconfigureVisibleGridCells];
    }
    [self refreshBottomToolbarItems];
}

/// Re-runs grid cell configuration for visible items (e.g. after a density
/// change that toggles the username overlay) without a full reload.
- (void)reconfigureVisibleGridCells {
    if (self.viewMode != SPKGalleryViewModeGrid)
        return;
    BOOL showsMeta = ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridShowSourceUsernameDisabledKey];
    BOOL showsUsername = showsMeta && self.gridColumns <= 3;
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        if (![cell isKindOfClass:[SPKGalleryGridCell class]])
            continue;
        SPKGalleryFile *file = [self galleryFileForCollectionIndexPath:indexPath];
        if (!file)
            continue;
        NSString *folderName = [self folderBadgeNameForFile:file];
        [(SPKGalleryGridCell *)cell configureWithGalleryFile:file
                                               selectionMode:self.selectionMode
                                                    selected:[self.selectedFileIDs containsObject:file.identifier]
                                                 showsSource:showsMeta
                                               showsUsername:showsUsername
                                                  folderName:folderName];
    }
}

- (void)handleGridPinch:(UIPinchGestureRecognizer *)pinch {
    if (self.viewMode != SPKGalleryViewModeGrid)
        return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridPinchDisabledKey])
        return;
    if (pinch.state != UIGestureRecognizerStateChanged)
        return;
    // Pinch out (scale > 1) -> fewer columns (bigger cells); pinch in -> more.
    CGFloat threshold = 0.30;
    if (pinch.scale > 1.0 + threshold && self.gridColumns > kSPKGalleryGridColumnsMin) {
        [self applyGridColumns:SPKGalleryGridColumnsAdjacent(self.gridColumns, YES) animated:YES];
        pinch.scale = 1.0;
    } else if (pinch.scale < 1.0 - threshold && self.gridColumns < kSPKGalleryGridColumnsMax) {
        [self applyGridColumns:SPKGalleryGridColumnsAdjacent(self.gridColumns, NO) animated:YES];
        pinch.scale = 1.0;
    }
}

#pragma mark - Empty State

- (void)setupEmptyState {
    _emptyStateView = [[UIView alloc] initWithFrame:CGRectZero];
    _emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyStateView.hidden = YES;
    [self.view addSubview:_emptyStateView];

    UIImage *emptyIconImage = [SPKAssetUtils instagramIconNamed:@"media_empty"
                                                      pointSize:96.0];
    UIImageView *icon = [[UIImageView alloc] initWithImage:emptyIconImage];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [_emptyStateView addSubview:icon];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = SPKL(@"GALLERY_GALLERY_NO_FILES_GALLERY_TEXT");
    label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    [_emptyStateView addSubview:label];
    _emptyStateLabel = label;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = SPKL(@"GALLERY_GALLERY_MEDIA_SAVE_SPARKLE_APPEAR_HERE_TEXT");
    subtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [_emptyStateView addSubview:subtitle];
    _emptyStateSubtitle = subtitle;

    [NSLayoutConstraint activateConstraints:@[
        [_emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor
                                                      constant:-40],
        [_emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor
                                                                   constant:40],
        [_emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor
                                                                 constant:-40],

        [icon.topAnchor constraintEqualToAnchor:_emptyStateView.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:96],
        [icon.heightAnchor constraintEqualToConstant:96],

        [label.topAnchor constraintEqualToAnchor:icon.bottomAnchor
                                        constant:20],
        [label.leadingAnchor constraintEqualToAnchor:_emptyStateView.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:_emptyStateView.trailingAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:label.bottomAnchor
                                           constant:8],
        [subtitle.leadingAnchor constraintEqualToAnchor:_emptyStateView.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:_emptyStateView.trailingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:_emptyStateView.bottomAnchor],
    ]];
}

- (void)updateEmptyState {
    NSInteger files = self.fetchedResultsController.fetchedObjects.count;
    NSInteger folders = [self showsFolderChips] ? self.subfolders.count : 0;
    BOOL hasFilters = self.filterTypes.count > 0 || self.filterSources.count > 0 || self.filterFavoritesOnly;

    BOOL isEmpty = (files == 0 && folders == 0);
    self.emptyStateView.hidden = !isEmpty;
    self.collectionView.hidden = isEmpty;

    if (!isEmpty)
        return;

    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *folderName = self.currentFolderPath.length > 0 ? [self.currentFolderPath lastPathComponent] : nil;

    NSString *title;
    NSString *subtitle;
    if (query.length > 0) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_NO_RESULTS_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_PICKER_NO_MEDIA_MATCHES_SEARCH_TEXT");
    } else if (hasFilters) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_NO_MATCHING_FILES_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_PICKER_TRY_ADJUSTING_FILTERS_TEXT");
    } else if (folderName.length > 0) {
        title = SPKL(@"GALLERY_GALLERY_PICKER_FOLDER_EMPTY_TEXT");
        subtitle = [NSString stringWithFormat:SPKL(@"GALLERY_FOLDER_EMPTY_SUBTITLE_FORMAT"), folderName];
    } else {
        title = SPKL(@"GALLERY_GALLERY_NO_FILES_GALLERY_TEXT");
        subtitle = SPKL(@"GALLERY_GALLERY_MEDIA_SAVE_SPARKLE_APPEAR_HERE_TEXT");
    }
    self.emptyStateLabel.text = title;
    self.emptyStateSubtitle.text = subtitle;
}

#pragma mark - Fetched Results Controller

/// Whether the grid lists the files inside subfolders alongside the current
/// folder's own ones. Read on every fetch, so the settings toggle applies live.
- (BOOL)flatBrowsingEnabled {
    return self.forcesFlatBrowsing || [SPKUtils getBoolPref:kSPKGalleryFlatBrowsingKey];
}

- (void)setupFetchedResultsController {
    NSFetchRequest *request = [self currentFetchRequest];

    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    _fetchedResultsController = [[NSFetchedResultsController alloc] initWithFetchRequest:request
                                                                    managedObjectContext:ctx
                                                                      sectionNameKeyPath:nil
                                                                               cacheName:nil];
    _fetchedResultsController.delegate = self;

    NSError *error;
    if (![_fetchedResultsController performFetch:&error]) {
        SPKLog(@"General", @"[Sparkle Gallery] Fetch failed: %@", error);
    }
}

- (NSFetchRequest *)currentFetchRequest {
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    NSMutableArray<NSSortDescriptor *> *sortDescriptors = [[SPKGallerySortViewController sortDescriptorsForMode:self.sortMode groupByMediaType:self.sortGroupByMediaType] mutableCopy];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kFavoritesAtTopKey] && !self.filterFavoritesOnly) {
        [sortDescriptors insertObject:[NSSortDescriptor sortDescriptorWithKey:@"isFavorite" ascending:NO] atIndex:0];
    }
    request.sortDescriptors = sortDescriptors;
    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // "Search all folders" only applies while actually searching; otherwise stay
    // scoped to the current folder.
    BOOL searchingAllFolders = self.searchAllFolders && query.length > 0;
    // Flat browsing widens the folder scope from "this folder" to "this folder and
    // everything under it" (so the root lists the whole gallery). The exact-folder
    // predicate the filter builds can't express that, so ask it not to scope and add
    // the subtree predicate here. Folders stay browsable: descending still narrows
    // the subtree, and searching all folders still drops the scope entirely.
    BOOL flatBrowsing = [self flatBrowsingEnabled];
    NSPredicate *basePredicate = [SPKGalleryFilterViewController predicateForTypes:self.filterTypes
                                                                           sources:self.filterSources
                                                                     favoritesOnly:self.filterFavoritesOnly
                                                                         usernames:self.filterUsernames
                                                                        folderPath:self.currentFolderPath
                                                                     scopeToFolder:!searchingAllFolders && !flatBrowsing];
    if (flatBrowsing && !searchingAllFolders && self.currentFolderPath.length > 0) {
        NSPredicate *subtree = [NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                               self.currentFolderPath,
                                                               [self.currentFolderPath stringByAppendingString:@"/"]];
        basePredicate = basePredicate
                            ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ basePredicate, subtree ]]
                            : subtree;
    }
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (visibleSources) {
        basePredicate = basePredicate
                            ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ basePredicate, visibleSources ]]
                            : visibleSources;
    }
    if (query.length == 0) {
        request.predicate = basePredicate;
        return request;
    }

    NSPredicate *searchPredicate = [NSPredicate predicateWithFormat:@"(sourceUsername CONTAINS[cd] %@) OR (customName CONTAINS[cd] %@) OR (relativePath CONTAINS[cd] %@)",
                                                                    query, query, query];
    // basePredicate can be nil when searching all folders with no other filters
    // active (no folder scope, no filters) — don't put nil into the AND array.
    request.predicate = basePredicate
                            ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ basePredicate, searchPredicate ]]
                            : searchPredicate;
    return request;
}

- (void)refetch {
    if (self.selectionMode) {
        [self.selectedFileIDs removeAllObjects];
    }
    NSFetchRequest *request = [self currentFetchRequest];
    _fetchedResultsController.fetchRequest.sortDescriptors = request.sortDescriptors;
    _fetchedResultsController.fetchRequest.predicate = request.predicate;

    NSError *error;
    if (![_fetchedResultsController performFetch:&error]) {
        SPKLog(@"General", @"[Sparkle Gallery] Refetch failed: %@", error);
    }
    [self reloadSubfolders];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self setupCenteredTitle];
    [self refreshNavigationItems];
}

#pragma mark - Subfolders

// The active content filter (media types / sources / favorites / usernames) with
// no folder scoping, so it can be ANDed into per-folder counts. Nil when no
// filter is active, which keeps folder counts at their raw totals.
- (NSPredicate *)activeContentFilterPredicate {
    if (self.filterTypes.count == 0 && self.filterSources.count == 0 &&
        !self.filterFavoritesOnly && self.filterUsernames.count == 0) {
        return nil;
    }
    return [SPKGalleryFilterViewController predicateForTypes:self.filterTypes
                                                     sources:self.filterSources
                                               favoritesOnly:self.filterFavoritesOnly
                                                   usernames:self.filterUsernames
                                                  folderPath:nil
                                               scopeToFolder:NO];
}

- (void)reloadSubfolders {
    if (self.searchQuery.length > 0) {
        self.subfolders = @[];
        return;
    }
    // Subfolders are derived from distinct `folderPath` values on files whose path
    // is a descendant of the current path.
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"folderPath" ];
    req.returnsDistinctResults = YES;

    NSString *base = self.currentFolderPath ?: @"";
    NSString *prefix = base.length == 0 ? @"/" : [base stringByAppendingString:@"/"];
    NSPredicate *folderPredicate = [NSPredicate predicateWithFormat:@"folderPath BEGINSWITH %@", prefix];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    req.predicate = visibleSources
                        ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ folderPredicate, visibleSources ]]
                        : folderPredicate;

    NSArray<NSDictionary *> *results = [ctx executeFetchRequest:req error:nil];
    NSMutableSet<NSString *> *immediate = [NSMutableSet set];

    for (NSDictionary *row in results) {
        NSString *p = row[@"folderPath"];
        if (p.length <= prefix.length)
            continue;
        NSString *rest = [p substringFromIndex:prefix.length];
        NSRange slash = [rest rangeOfString:@"/"];
        NSString *folderName = slash.location == NSNotFound ? rest : [rest substringToIndex:slash.location];
        if (folderName.length == 0)
            continue;
        [immediate addObject:[prefix stringByAppendingString:folderName]];
    }

    NSArray<NSString *> *sorted = [[immediate allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    // When a filter is active, drop subfolders that (including their descendants)
    // have no items matching it, so the chip strip only shows folders the user can
    // actually reach results in.
    NSPredicate *contentFilter = [self activeContentFilterPredicate];
    if (contentFilter) {
        NSMutableArray<NSString *> *nonEmpty = [NSMutableArray arrayWithCapacity:sorted.count];
        for (NSString *path in sorted) {
            if (SPKGalleryItemCountForFolderPath(ctx, path, contentFilter) > 0) {
                [nonEmpty addObject:path];
            }
        }
        sorted = nonEmpty;
    }

    self.subfolders = sorted;
    // Placeholder folders are empty by definition, so they'd match no filter —
    // only surface them while browsing unfiltered.
    if (!contentFilter) {
        [self mergePlaceholderSubfolders];
    }
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    // If the last media from a filtered user was removed, drop that username from
    // the active filter so the user isn't left staring at an empty filtered view.
    if ([self pruneStaleUsernameFilters]) {
        [self refetch];
        return;
    }
    [self reloadSubfolders];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self refreshNavigationItems];
}

#pragma mark - UICollectionViewDataSource

- (BOOL)showsFolderSection {
    // Folders are now presented as a horizontal chip strip in the section
    // header (see showsFolderChips), not as full-width rows. Retiring the row
    // section collapses the layout to a single files section in both modes.
    return NO;
}

/// Folder chips show above the media in both grid and list modes, whenever the
/// current folder has subfolders and the user isn't searching or selecting.
- (BOOL)showsFolderChips {
    return self.subfolders.count > 0 && self.searchQuery.length == 0 && !self.selectionMode;
}

- (BOOL)isFolderIndexPath:(NSIndexPath *)indexPath {
    return [self showsFolderSection] && indexPath.section == 0;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return [self showsFolderSection] ? 2 : 1;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if ([self showsFolderSection] && section == 0)
        return self.subfolders.count;
    NSArray *sections = self.fetchedResultsController.sections;
    if (sections.count == 0)
        return 0;
    return ((id<NSFetchedResultsSectionInfo>)sections[0]).numberOfObjects;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)cv
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isFolderIndexPath:indexPath]) {
        SPKGalleryFolderCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kFolderCellID forIndexPath:indexPath];
        NSString *path = self.subfolders[indexPath.item];
        NSInteger itemCount = SPKGalleryItemCountForFolderPath([SPKGalleryCoreDataStack shared].viewContext, path, [self activeContentFilterPredicate]);
        [cell configureWithFolderName:[path lastPathComponent] itemCount:itemCount];
        return cell;
    }

    NSIndexPath *filePath = [NSIndexPath indexPathForItem:indexPath.item inSection:0];
    SPKGalleryFile *file = [self.fetchedResultsController objectAtIndexPath:filePath];

    if (self.viewMode == SPKGalleryViewModeGrid) {
        SPKGalleryGridCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kGridCellID forIndexPath:indexPath];
        BOOL showsMeta = ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridShowSourceUsernameDisabledKey];
        // Username caption only fits at roomy densities (2-3 columns).
        BOOL showsUsername = showsMeta && self.gridColumns <= 3;
        NSString *folderName = [self folderBadgeNameForFile:file];
        [cell configureWithGalleryFile:file
                         selectionMode:self.selectionMode
                              selected:[self.selectedFileIDs containsObject:file.identifier]
                           showsSource:showsMeta
                         showsUsername:showsUsername
                            folderName:folderName];
        return cell;
    }

    SPKGalleryListCollectionCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kListCellID forIndexPath:indexPath];
    [cell configureWithGalleryFile:file
                     selectionMode:self.selectionMode
                          selected:[self.selectedFileIDs containsObject:file.identifier]];
    [cell setFolderContextName:[self folderBadgeNameForFile:file]];
    [cell setMoreActionsMenu:self.selectionMode ? nil : [self fileActionsMenuForFile:file]];
    return cell;
}

// The folder a listed file lives in, shown on the cell only when the list can
// span folders (searching across all folders, or flat browsing) and the file is
// in a different, non-root folder — otherwise the label is noise.
- (NSString *)folderBadgeNameForFile:(SPKGalleryFile *)file {
    BOOL listSpansFolders = [self flatBrowsingEnabled] || (self.searchAllFolders && self.searchQuery.length > 0);
    if (!listSpansFolders) {
        return nil;
    }
    NSString *folderPath = file.folderPath;
    if (folderPath.length == 0) {
        return nil; // root
    }
    if ([folderPath isEqualToString:self.currentFolderPath ?: @""]) {
        return nil; // already the folder we're in
    }
    return [folderPath lastPathComponent];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    if (![kind isEqualToString:UICollectionElementKindSectionHeader]) {
        return [[UICollectionReusableView alloc] init];
    }

    SPKGalleryFolderChipBar *header =
        [cv dequeueReusableSupplementaryViewOfKind:kind
                               withReuseIdentifier:kFolderChipHeaderID
                                      forIndexPath:indexPath];

    if (![self showsFolderChips]) {
        return header;
    }

    NSArray<NSString *> *folders = self.subfolders;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:folders.count];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithCapacity:folders.count];
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSPredicate *contentFilter = [self activeContentFilterPredicate];
    for (NSString *path in folders) {
        [names addObject:[path lastPathComponent]];
        [counts addObject:@(SPKGalleryItemCountForFolderPath(ctx, path, contentFilter))];
    }

    __weak typeof(self) weakSelf = self;
    [header configureWithFolderNames:names
        counts:counts
        onSelect:^(NSInteger index) {
            [weakSelf openSubfolderAtIndex:index];
        }
        menuProvider:^UIMenu *_Nullable(NSInteger index) {
            return [weakSelf folderChipMenuForIndex:index];
        }];
    return header;
}

/// Opens the subfolder at `index` in place (no pushed view controller).
- (void)openSubfolderAtIndex:(NSInteger)index {
    if (self.selectionMode)
        return;
    if (index < 0 || index >= (NSInteger)self.subfolders.count)
        return;
    [self navigateIntoFolder:self.subfolders[index]];
}

#pragma mark - In-place folder navigation

// Left-edge swipe to go up a folder, mirroring the native pop gesture (we no
// longer push view controllers, so the system one doesn't apply).
- (void)setupFolderBackGesture {
    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFolderBackEdgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgePan];
}

- (void)handleFolderBackEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan && [self canNavigateBackInFolders]) {
        [self navigateBackInFolders];
    }
}

- (BOOL)canNavigateBackInFolders {
    return self.folderTrail.count > 0;
}

/// Descends into `subfolderPath` by re-scoping the current screen's data, instead
/// of pushing a new view controller — keeping the shared chrome intact.
- (void)navigateIntoFolder:(NSString *)subfolderPath {
    if (subfolderPath.length == 0) {
        return;
    }
    // Remember where we were so returning restores the grid position.
    [self.folderScrollOffsets addObject:[NSValue valueWithCGPoint:self.collectionView.contentOffset]];
    [self.folderTrail addObject:subfolderPath];
    self.currentFolderPath = subfolderPath;

    [self prepareForFolderChange];
    __weak typeof(self) weakSelf = self;
    [self replaceGridContentWithCrossfade:^{
        [weakSelf refetch];
        [weakSelf scrollGridToTop];
    }];
    [self setupCenteredTitle];
    [self refreshNavigationItems];
}

/// Returns to the parent folder, restoring its previous scroll position.
- (void)navigateBackInFolders {
    if (![self canNavigateBackInFolders]) {
        return;
    }
    [self.folderTrail removeLastObject];
    self.currentFolderPath = self.folderTrail.lastObject; // nil at root

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
        [weakSelf refetch];
        if (hasRestoreOffset) {
            [weakSelf.collectionView setContentOffset:restoreOffset animated:NO];
        } else {
            [weakSelf scrollGridToTop];
        }
    }];
    [self setupCenteredTitle];
    [self refreshNavigationItems];
}

/// Shared cleanup when changing folders: exit selection and clear any active search
/// so each folder opens in a clean browse state.
- (void)prepareForFolderChange {
    if (self.selectionMode) {
        [self exitSelectionMode];
    }
    if (self.searchController.active) {
        self.searchController.active = NO;
    }
    self.searchQuery = nil;
    self.searchController.searchBar.text = nil;
    self.searchAllFolders = NO;
    self.searchController.searchBar.selectedScopeButtonIndex = 0;
}

- (void)scrollGridToTop {
    CGFloat topY = -self.collectionView.adjustedContentInset.top;
    [self.collectionView setContentOffset:CGPointMake(0.0, topY) animated:NO];
}

/// Smoothly swaps the grid's contents with a cross-dissolve (no positional slide,
/// so no layout jank). `contentUpdate` should apply the new data/scroll; the
/// transition dissolves the old contents into the new.
- (void)replaceGridContentWithCrossfade:(void (^)(void))contentUpdate {
    if (!contentUpdate) {
        return;
    }
    [UIView transitionWithView:self.collectionView
                      duration:0.22
                       options:(UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction)
                    animations:contentUpdate
                    completion:nil];
}

/// Context menu (rename/delete/etc.) for the folder chip at `index`, reusing the
/// same actions as the legacy folder rows.
- (UIMenu *)folderChipMenuForIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.subfolders.count)
        return nil;
    NSString *folderPath = self.subfolders[index];
    return [self folderActionsMenuForFolderPath:folderPath];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)cv
                    layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = cv.bounds.size.width;
    if ([self isFolderIndexPath:indexPath]) {
        return CGSizeMake(width, 88);
    }
    if (self.viewMode == SPKGalleryViewModeGrid) {
        NSInteger columns = MAX(kSPKGalleryGridColumnsMin, MIN(kSPKGalleryGridColumnsMax, self.gridColumns));
        CGFloat totalSpacing = kGridSpacing * (columns - 1);
        CGFloat side = floor((width - totalSpacing) / columns);
        return CGSizeMake(side, side);
    }
    return CGSizeMake(width, 72);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)cv
                        layout:(UICollectionViewLayout *)layout
        insetForSectionAtIndex:(NSInteger)section {
    if ([self showsFolderSection] && section == 0 && self.subfolders.count > 0) {
        return UIEdgeInsetsMake(10, 0, 6, 0);
    }
    return UIEdgeInsetsZero;
}

- (CGSize)collectionView:(UICollectionView *)cv
                             layout:(UICollectionViewLayout *)layout
    referenceSizeForHeaderInSection:(NSInteger)section {
    if (section == 0 && [self showsFolderChips]) {
        return CGSizeMake(cv.bounds.size.width, [SPKGalleryFolderChipBar preferredHeight]);
    }
    return CGSizeZero;
}

- (CGFloat)collectionView:(UICollectionView *)cv
                                      layout:(UICollectionViewLayout *)layout
    minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    if ([self showsFolderSection] && section == 0) {
        return 0;
    }
    return self.viewMode == SPKGalleryViewModeGrid ? kGridSpacing : 0;
}

- (CGFloat)collectionView:(UICollectionView *)cv
                                 layout:(UICollectionViewLayout *)layout
    minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    if ([self showsFolderSection] && section == 0) {
        return 0;
    }
    return self.viewMode == SPKGalleryViewModeGrid ? kGridSpacing : 0;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // During the two-finger drag the collection view owns the selected state and
    // decides the direction of the sweep, so mirror it instead of toggling, and
    // leave the item selected so a reversed drag reports a matching deselect.
    if (self.multiSelectDragActive) {
        [self applyDragSelection:YES atIndexPath:indexPath];
        return;
    }

    [cv deselectItemAtIndexPath:indexPath animated:YES];

    if ([self isFolderIndexPath:indexPath]) {
        if (self.selectionMode) {
            return;
        }
        [self navigateIntoFolder:self.subfolders[indexPath.item]];
        return;
    }

    NSIndexPath *filePath = [NSIndexPath indexPathForItem:indexPath.item inSection:0];
    SPKGalleryFile *selectedFile = [self.fetchedResultsController objectAtIndexPath:filePath];
    if (self.selectionMode) {
        [self toggleSelectionForFile:selectedFile];
        return;
    }

    NSArray *allFiles = self.fetchedResultsController.fetchedObjects;
    // filePath.item is already the index into fetchedObjects -- objectAtIndexPath:
    // above resolved the file from it -- so there is no need to search the array.
    NSInteger idx = filePath.item;
    if (idx < 0 || idx >= (NSInteger)allFiles.count)
        idx = 0;
    [SPKFullScreenMediaPlayer showGalleryFiles:allFiles
                               startingAtIndex:idx
                            fromViewController:self];
}

- (void)collectionView:(UICollectionView *)cv didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    // Only the drag deselects meaningfully. Programmatic deselection does not
    // reach the delegate, so the tap path never lands here.
    if (!self.multiSelectDragActive) {
        return;
    }
    [self applyDragSelection:NO atIndexPath:indexPath];
}

#pragma mark - Two-finger multiple selection

- (BOOL)collectionView:(UICollectionView *)cv
    shouldBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    // List rows only: the grid already answers a two-finger gesture with the
    // column-density pinch, and the two would fight over the same touches.
    if (self.viewMode != SPKGalleryViewModeList) {
        return NO;
    }
    if ([self isFolderIndexPath:indexPath] || ![self galleryFileForCollectionIndexPath:indexPath]) {
        return NO;
    }

    // The collection view reads its own selected state to decide whether this
    // sweep selects or deselects, so publish our set into it before it begins.
    // Starting on an already-picked row then unpicks along the drag.
    [self syncCollectionSelectionFromSelectedFiles];
    return YES;
}

- (void)collectionView:(UICollectionView *)cv
    didBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    self.multiSelectDragActive = YES;
    self.multiSelectDragFeedback = [[UISelectionFeedbackGenerator alloc] init];
    [self.multiSelectDragFeedback prepare];

    // Only a drag that opened selection mode itself is allowed to close it again
    // when it ends up picking nothing. A drag inside an existing selection stays.
    self.multiSelectDragOpenedSelection = !self.selectionMode;
    if (!self.selectionMode) {
        CGFloat chipHeight =
            [self showsFolderChips] ? [SPKGalleryFolderChipBar preferredHeight] : 0.0;
        [self enterSelectionMode];

        // Selection mode retires the chip header, which pulls every row up by its
        // height while the fingers are still down, so the sweep would carry on
        // over rows that moved. Scrolling back by the same amount keeps the media
        // under the fingers exactly where it was.
        if (chipHeight > 0.0 && ![self showsFolderChips]) {
            [cv layoutIfNeeded];
            CGPoint offset = cv.contentOffset;
            offset.y = MAX(-cv.adjustedContentInset.top, offset.y - chipHeight);
            cv.contentOffset = offset;
        }
    }
}

- (void)collectionViewDidEndMultipleSelectionInteraction:(UICollectionView *)cv {
    self.multiSelectDragActive = NO;
    self.multiSelectDragFeedback = nil;

    // Hand ownership of the selection back to selectedFileIDs, which drives the
    // badges from here on.
    for (NSIndexPath *indexPath in [cv.indexPathsForSelectedItems copy]) {
        [cv deselectItemAtIndexPath:indexPath animated:NO];
    }

    if (self.multiSelectDragOpenedSelection && self.selectedFileIDs.count == 0) {
        [self exitSelectionMode];
    }
    self.multiSelectDragOpenedSelection = NO;
}

/// Mirrors one drag-reported item into `selectedFileIDs` and its cell badge.
- (void)applyDragSelection:(BOOL)selected atIndexPath:(NSIndexPath *)indexPath {
    SPKGalleryFile *file = [self galleryFileForCollectionIndexPath:indexPath];
    if (file.identifier.length == 0) {
        return;
    }
    if ([self.selectedFileIDs containsObject:file.identifier] == selected) {
        return;
    }

    if (selected) {
        [self.selectedFileIDs addObject:file.identifier];
    } else {
        [self.selectedFileIDs removeObject:file.identifier];
    }

    [self.multiSelectDragFeedback selectionChanged];
    [self.multiSelectDragFeedback prepare];
    [self setupCenteredTitle];
    [self refreshNavigationItems];
    [self updateSelectionBadgeForFile:file selected:selected];
}

/// Publishes `selectedFileIDs` into the collection view's own selected state,
/// which is otherwise kept empty because taps deselect immediately.
- (void)syncCollectionSelectionFromSelectedFiles {
    if (self.selectedFileIDs.count == 0) {
        return;
    }

    NSArray<SPKGalleryFile *> *files = [self visibleGalleryFiles];
    [files enumerateObjectsUsingBlock:^(SPKGalleryFile *file, NSUInteger idx, BOOL *stop) {
        if (file.identifier.length == 0 || ![self.selectedFileIDs containsObject:file.identifier]) {
            return;
        }
        [self.collectionView selectItemAtIndexPath:[NSIndexPath indexPathForItem:(NSInteger)idx inSection:0]
                                          animated:NO
                                    scrollPosition:UICollectionViewScrollPositionNone];
    }];
}

- (void)showGalleryOpenFailureMessage:(NSString *)title actionIdentifier:(NSString *)actionIdentifier {
    SPKNotify(actionIdentifier, title, SPKL(@"COMMON_ORIGINAL_CONTENT_UNAVAILABLE_TOAST"), @"error_filled", SPKNotificationToneError);
}

- (void)dismissGalleryForOriginOpenWithCompletion:(void (^)(void))completion {
    if ([SPKGalleryManager sharedManager].isLockEnabled) {
        [[SPKGalleryManager sharedManager] lockGallery];
    }

    [self.navigationController dismissViewControllerAnimated:YES
                                                  completion:^{
                                                      if (completion) {
                                                          completion();
                                                      }
                                                  }];
}

- (void)openOriginalPostForFile:(SPKGalleryFile *)file {
    NSString *failureTitle = nil;
    switch ((SPKGallerySource)file.source) {
    case SPKGallerySourceStories:
        failureTitle = SPKL(@"GALLERY_UNABLE_OPEN_ORIGINAL_STORY_TOAST");
        break;
    case SPKGallerySourceReels:
        failureTitle = SPKL(@"GALLERY_UNABLE_OPEN_ORIGINAL_REEL_TOAST");
        break;
    default:
        failureTitle = SPKL(@"GALLERY_UNABLE_OPEN_ORIGINAL_POST_TOAST");
        break;
    }
    __weak __typeof(self) weakSelf = self;
    // The Gallery stays up: the post is pushed over it, so it is still here when
    // the post is closed. Dismissing is only the fallback for a build where the
    // push cannot be redirected.
    if ([SPKGalleryOriginController openOriginalPostForGalleryFile:file
                                               fromViewController:self
                                                   legacyFallback:^{
                                                       // The post is what shows next, so there is nothing to announce;
                                                       // the tap is still felt.
                                                       [weakSelf dismissGalleryForOriginOpenWithCompletion:^{
                                                           SPKNotificationTriggerHaptic(kSPKNotificationGalleryOpenOriginal, SPKNotificationToneInfo);
                                                       }];
                                                   }
                                                        onDismiss:nil]) {
        // Nothing to announce: the post is on screen.
    } else {
        [self showGalleryOpenFailureMessage:failureTitle actionIdentifier:kSPKNotificationGalleryOpenOriginal];
    }
}

- (void)openProfileForFile:(SPKGalleryFile *)file {
    // Via the completion: an item with no stored pk looks one up first, so only
    // the outcome says whether it opened. The profile on screen is the
    // confirmation, so a success is only felt; a failure is said.
    __weak __typeof(self) weakSelf = self;
    [SPKGalleryOriginController openProfileForGalleryFile:file
                                      fromViewController:self
                                              completion:^(BOOL success, BOOL didLink) {
                                                  if (success) {
                                                      // A link just made already posted its own notification.
                                                      if (!didLink)
                                                          SPKNotificationTriggerHaptic(kSPKNotificationGalleryOpenProfile, SPKNotificationToneInfo);
                                                  } else {
                                                      [weakSelf showGalleryOpenFailureMessage:SPKL(@"COMMON_UNABLE_OPEN_PROFILE_TOAST") actionIdentifier:kSPKNotificationGalleryOpenProfile];
                                                  }
                                              }];
}

- (NSArray<SPKGalleryFile *> *)visibleGalleryFiles {
    return self.fetchedResultsController.fetchedObjects ?: @[];
}

- (SPKGalleryFile *)galleryFileForCollectionIndexPath:(NSIndexPath *)indexPath {
    if ([self isFolderIndexPath:indexPath]) {
        return nil;
    }
    NSIndexPath *filePath = [NSIndexPath indexPathForItem:indexPath.item inSection:0];
    return [self.fetchedResultsController objectAtIndexPath:filePath];
}

- (void)animateSelectionModeTransition {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        SPKGalleryFile *file = [self galleryFileForCollectionIndexPath:indexPath];
        if (!file) {
            continue;
        }

        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        BOOL selected = [self.selectedFileIDs containsObject:file.identifier];
        if ([cell isKindOfClass:[SPKGalleryListCollectionCell class]]) {
            [(SPKGalleryListCollectionCell *)cell setSelectionMode:self.selectionMode selected:selected animated:YES];
            [(SPKGalleryListCollectionCell *)cell setMoreActionsMenu:self.selectionMode ? nil : [self fileActionsMenuForFile:file]];
        } else if ([cell isKindOfClass:[SPKGalleryGridCell class]]) {
            [(SPKGalleryGridCell *)cell setSelectionMode:self.selectionMode selected:selected animated:YES];
        }
    }
}

- (NSArray<SPKGalleryFile *> *)selectedGalleryFiles {
    if (self.selectedFileIDs.count == 0) {
        return @[];
    }

    NSMutableArray<SPKGalleryFile *> *files = [NSMutableArray array];
    for (SPKGalleryFile *file in [self visibleGalleryFiles]) {
        if ([self.selectedFileIDs containsObject:file.identifier]) {
            [files addObject:file];
        }
    }
    return files;
}

- (void)enterSelectionMode {
    if (self.searchController.isActive && self.searchController.searchBar.text.length > 0) {
        self.preservingSearchQuery = YES;
        self.searchController.active = NO;
    }
    self.selectionMode = YES;
    [self.selectedFileIDs removeAllObjects];
    [self setupCenteredTitle];
    [self refreshNavigationItems];
    [self refreshBottomToolbarItems];
    [self animateSelectionModeTransition];
    // Folder chips hide during selection; reflect the header change.
    [self.collectionView.collectionViewLayout invalidateLayout];
}

- (void)exitSelectionMode {
    self.selectionMode = NO;
    [self.selectedFileIDs removeAllObjects];

    if (self.searchQuery.length > 0) {
        self.searchQuery = nil;
        self.searchController.searchBar.text = nil;
        [self refetch];
    }

    [self setupCenteredTitle];
    [self refreshNavigationItems];
    [self refreshBottomToolbarItems];
    [self animateSelectionModeTransition];
    // Folder chips return after leaving selection mode.
    [self.collectionView.collectionViewLayout invalidateLayout];
}

- (void)toggleSelectionForFile:(SPKGalleryFile *)file {
    if (file.identifier.length == 0) {
        return;
    }
    BOOL nowSelected;
    if ([self.selectedFileIDs containsObject:file.identifier]) {
        [self.selectedFileIDs removeObject:file.identifier];
        nowSelected = NO;
    } else {
        [self.selectedFileIDs addObject:file.identifier];
        nowSelected = YES;
    }
    [self setupCenteredTitle];
    [self refreshNavigationItems];
    // Update just the tapped cell's selection badge. A full reloadData here
    // reconfigures every visible cell, which re-toggles their gradient scrims and
    // makes them flash.
    [self updateSelectionBadgeForFile:file selected:nowSelected];
}

- (void)updateSelectionBadgeForFile:(SPKGalleryFile *)file selected:(BOOL)selected {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        SPKGalleryFile *visibleFile = [self galleryFileForCollectionIndexPath:indexPath];
        if (![visibleFile.identifier isEqualToString:file.identifier]) {
            continue;
        }
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        if ([cell isKindOfClass:[SPKGalleryGridCell class]]) {
            [(SPKGalleryGridCell *)cell setSelectionMode:self.selectionMode selected:selected animated:YES];
        } else if ([cell isKindOfClass:[SPKGalleryListCollectionCell class]]) {
            [(SPKGalleryListCollectionCell *)cell setSelectionMode:self.selectionMode selected:selected animated:YES];
        }
        break;
    }
}

- (void)selectAllVisibleFiles {
    NSArray<SPKGalleryFile *> *files = [self visibleGalleryFiles];
    if (files.count > 0 && self.selectedFileIDs.count == files.count) {
        [self.selectedFileIDs removeAllObjects];
    } else {
        [self.selectedFileIDs removeAllObjects];
        for (SPKGalleryFile *file in files) {
            if (file.identifier.length > 0) {
                [self.selectedFileIDs addObject:file.identifier];
            }
        }
    }
    [self setupCenteredTitle];
    [self refreshNavigationItems];
    [self.collectionView reloadData];
}

- (void)activateSearch {
    CGFloat revealOffsetY = -self.collectionView.adjustedContentInset.top;
    if (self.collectionView.contentOffset.y > revealOffsetY) {
        [self.collectionView setContentOffset:CGPointMake(self.collectionView.contentOffset.x, revealOffsetY) animated:NO];
        [self.collectionView layoutIfNeeded];
        [self.navigationController.navigationBar layoutIfNeeded];
    }
    self.searchController.active = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchController.searchBar becomeFirstResponder];
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (self.preservingSearchQuery) {
        return;
    }
    NSString *nextQuery = searchController.searchBar.text ?: @"";
    if ((self.searchQuery ?: @"").length == nextQuery.length && [(self.searchQuery ?: @"") isEqualToString:nextQuery]) {
        return;
    }
    self.searchQuery = nextQuery;
    [self refetch];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    BOOL allFolders = (selectedScope == 1);
    if (allFolders == self.searchAllFolders) {
        return;
    }
    self.searchAllFolders = allFolders;
    [self refetch];
}

- (void)willDismissSearchController:(UISearchController *)searchController {
    if (self.selectionMode) {
        self.preservingSearchQuery = YES;
    }
}

- (void)didDismissSearchController:(UISearchController *)searchController {
    self.preservingSearchQuery = NO;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    if (self.selectionMode) {
        [self.searchController setActive:NO];
    } else {
        [searchBar resignFirstResponder];
    }
}

- (void)shareSelectedFiles {
    NSArray<SPKGalleryFile *> *files = [self selectedGalleryFiles];
    if (files.count == 0) {
        return;
    }

    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:files.count];
    for (SPKGalleryFile *file in files) {
        [urls addObject:file.fileURL];
    }

    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)moveSelectedFiles {
    NSArray<SPKGalleryFile *> *files = [self selectedGalleryFiles];
    if (files.count == 0) {
        return;
    }
    [self presentMoveSheetForFiles:files];
}

- (void)toggleFavoriteForSelectedFiles {
    NSArray<SPKGalleryFile *> *files = [self selectedGalleryFiles];
    if (files.count == 0) {
        return;
    }

    BOOL shouldFavorite = NO;
    for (SPKGalleryFile *file in files) {
        if (!file.isFavorite) {
            shouldFavorite = YES;
            break;
        }
    }

    for (SPKGalleryFile *file in files) {
        file.isFavorite = shouldFavorite;
    }
    [[SPKGalleryCoreDataStack shared] saveContext];
    [self refetch];
}

- (void)deleteSelectedFiles {
    NSArray<SPKGalleryFile *> *files = [self selectedGalleryFiles];
    if (files.count == 0) {
        return;
    }

    NSString *message = [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_PERMANENTLY_REMOVE_VALUE_FILE_VALUE_GALLERY_FORMAT"), SPKLP(@"COMMON_FILE_COUNT", files.count)];
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"GALLERY_GALLERY_DELETE_SELECTED_FILES_CONFIRMATION_MESSAGE")
                                                message:message
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  NSError *firstError = nil;
                                                                                  for (SPKGalleryFile *file in files) {
                                                                                      NSError *removeError = nil;
                                                                                      [file removeWithError:&removeError];
                                                                                      if (!firstError && removeError) {
                                                                                          firstError = removeError;
                                                                                      }
                                                                                  }
                                                                                  if (firstError) {
                                                                                      SPKNotify(kSPKNotificationGalleryDeleteSelected, SPKL(@"COMMON_DELETE_FAILED_TOAST"), firstError.localizedDescription, @"error_filled", SPKNotificationToneError);
                                                                                      return;
                                                                                  }
                                                                                  SPKNotify(kSPKNotificationGalleryDeleteSelected, SPKL(@"GALLERY_GALLERY_DELETED_SELECTED_FILES_TEXT"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                                  [self pruneStaleUsernameFilters];
                                                                                  [self exitSelectionMode];
                                                                              }],
                                                ]];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
                                         point:(CGPoint)point {
    if (self.selectionMode) {
        return nil;
    }
    if ([self isFolderIndexPath:indexPath]) {
        NSString *folder = self.subfolders[indexPath.item];
        return [self contextMenuForFolder:folder];
    }

    NSIndexPath *filePath = [NSIndexPath indexPathForItem:indexPath.item inSection:0];
    SPKGalleryFile *file = [self.fetchedResultsController objectAtIndexPath:filePath];
    return [self contextMenuForFile:file];
}

- (UIMenu *)fileActionsMenuForFile:(SPKGalleryFile *)file {
    __weak typeof(self) weakSelf = self;

    NSString *favTitle = file.isFavorite ? SPKL(@"GALLERY_GALLERY_UNFAVORITE_TEXT") : SPKL(@"GALLERY_GALLERY_FAVORITE_TEXT");
    UIImage *favImg = file.isFavorite
                          ? SPKGalleryMenuActionIcon(@"heart_filled")
                          : SPKGalleryMenuActionIcon(@"heart");

    UIAction *favoriteAction = [UIAction actionWithTitle:favTitle
                                                   image:favImg
                                              identifier:nil
                                                 handler:^(UIAction *a) {
                                                     file.isFavorite = !file.isFavorite;
                                                     [[SPKGalleryCoreDataStack shared] saveContext];
                                                     // Re-sort/reload so the item visibly moves (e.g. up to the top when
                                                     // "favorites at top" is on) and its badge updates — the FRC's implicit
                                                     // re-sort on an in-place property change isn't reliable. Matches the bulk
                                                     // favorite path.
                                                     [weakSelf refetch];
                                                 }];

    UIImage *editImg = SPKGalleryMenuActionIcon(@"edit");
    UIAction *renameAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_EDIT_DETAILS")
                                                 image:editImg
                                            identifier:nil
                                               handler:^(UIAction *a) {
                                                   [weakSelf editDetailsForFile:file];
                                               }];

    UIImage *moveImg = SPKGalleryMenuActionIcon(@"folder_move");
    UIAction *moveAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_MOVE_FOLDER")
                                               image:moveImg
                                          identifier:nil
                                             handler:^(UIAction *a) {
                                                 [weakSelf moveFile:file];
                                             }];

    UIAction *trimAction = nil;
    if (file.mediaType == SPKGalleryMediaTypeVideo || file.mediaType == SPKGalleryMediaTypeAudio) {
        trimAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_TRIM")
                                         image:SPKGalleryMenuActionIcon(@"trim")
                                    identifier:nil
                                       handler:^(__unused UIAction *a) {
                                           [weakSelf trimFile:file];
                                       }];
    }

    UIAction *editAction = nil;
    if (file.mediaType == SPKGalleryMediaTypeImage) {
        editAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_EDIT")
                                         image:SPKGalleryMenuActionIcon(@"crop")
                                    identifier:nil
                                       handler:^(__unused UIAction *a) {
                                           [weakSelf editFile:file];
                                       }];
    }

    UIImage *shareImg = SPKGalleryMenuActionIcon(@"share");
    UIAction *shareAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_SHARE")
                                                image:shareImg
                                           identifier:nil
                                              handler:^(UIAction *a) {
                                                  NSURL *url = [file fileURL];
                                                  UIActivityViewController *acVC = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
                                                  [weakSelf presentViewController:acVC animated:YES completion:nil];
                                              }];

    UIAction *openOriginalAction = nil;
    if (file.hasOpenableOriginalMedia) {
        openOriginalAction = [UIAction actionWithTitle:[file openOriginalActionTitle]
                                                 image:SPKGalleryMenuActionIcon(@"external_link")
                                            identifier:nil
                                               handler:^(__unused UIAction *a) {
                                                   [weakSelf openOriginalPostForFile:file];
                                               }];
    }

    UIAction *openProfileAction = nil;
    if (file.hasOpenableProfile) {
        openProfileAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_OPEN_PROFILE")
                                                image:SPKGalleryMenuActionIcon(@"user_circle")
                                           identifier:nil
                                              handler:^(__unused UIAction *a) {
                                                  [weakSelf openProfileForFile:file];
                                              }];
    }

    UIImage *deleteImg = SPKGalleryMenuActionIcon(@"trash");
    UIAction *deleteAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                 image:deleteImg
                                            identifier:nil
                                               handler:^(UIAction *a) {
                                                   [SPKIGAlertPresenter presentAlertFromViewController:weakSelf
                                                                                                 title:SPKL(@"GALLERY_GALLERY_DELETE_GALLERY_TEXT")
                                                                                               message:SPKL(@"GALLERY_GALLERY_PERMANENTLY_REMOVE_FILE_GALLERY_TEXT")
                                                                                               actions:@[
                                                                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                               style:SPKIGAlertActionStyleCancel
                                                                                                                             handler:nil],
                                                                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                                                                                               style:SPKIGAlertActionStyleDestructive
                                                                                                                             handler:^{
                                                                                                                                 NSError *err;
                                                                                                                                 [file removeWithError:&err];
                                                                                                                                 if (err) {
                                                                                                                                     SPKNotify(kSPKNotificationGalleryDeleteFile, SPKL(@"COMMON_DELETE_FAILED_TOAST"), err.localizedDescription, @"error_filled", SPKNotificationToneError);
                                                                                                                                 } else {
                                                                                                                                     SPKNotify(kSPKNotificationGalleryDeleteFile, SPKL(@"GALLERY_DELETED_FROM_GALLERY_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                                                                                 }
                                                                                                                             }],
                                                                                               ]];
                                               }];
    /// TODO: investigate whether native UIMenu destructive tint can be customized. UIMenuElement exposes no supported color API.
    deleteAction.attributes = UIMenuElementAttributesDestructive;

    UIAction *usernameAction = nil;
    if (file.sourceUsername.length > 0) {
        NSString *username = [file.sourceUsername copy];
        BOOL isCurrentUsernameFilter = [self usernameFilterContainsUsername:username];
        usernameAction = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", (isCurrentUsernameFilter ? SPKL(@"GALLERY_GALLERY_UNDO_VIEW_TEXT") : SPKL(@"GALLERY_GALLERY_VIEW_TEXT")), username]
                                             image:SPKGalleryMenuActionIcon(@"mention")
                                        identifier:nil
                                           handler:^(__unused UIAction *a) {
                                               [weakSelf toggleUsernameFilter:username];
                                           }];
    }

    // Grouped into inline sections so related actions read together and the
    // destructive delete is isolated at the bottom: open/navigate • edit • share •
    // delete.
    NSMutableArray<UIMenuElement *> *openSection = [NSMutableArray array];
    if (openOriginalAction)
        [openSection addObject:openOriginalAction];
    if (openProfileAction)
        [openSection addObject:openProfileAction];
    if (usernameAction)
        [openSection addObject:usernameAction];

    NSMutableArray<UIMenuElement *> *editSection = [NSMutableArray arrayWithObject:favoriteAction];
    [editSection addObject:renameAction];
    [editSection addObject:moveAction];
    if (trimAction)
        [editSection addObject:trimAction];
    if (editAction)
        [editSection addObject:editAction];

    NSMutableArray<UIMenu *> *sections = [NSMutableArray array];
    if (openSection.count > 0) {
        [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:openSection]];
    }
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:editSection]];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ shareAction ]]];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ deleteAction ]]];
    return [UIMenu menuWithTitle:@"" children:sections];
}

- (UIContextMenuConfiguration *)contextMenuForFile:(SPKGalleryFile *)file {
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
                                                        __strong typeof(weakSelf) strongSelf = weakSelf;
                                                        return strongSelf ? [strongSelf fileActionsMenuForFile:file] : nil;
                                                    }];
}

- (UIContextMenuConfiguration *)contextMenuForFolder:(NSString *)folderPath {
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
                                                        return [weakSelf folderActionsMenuForFolderPath:folderPath];
                                                    }];
}

- (UIMenu *)folderActionsMenuForFolderPath:(NSString *)folderPath {
    __weak typeof(self) weakSelf = self;
    UIImage *folderRenameImg = SPKGalleryMenuActionIcon(@"edit");
    UIAction *renameAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_RENAME_FOLDER")
                                                 image:folderRenameImg
                                            identifier:nil
                                               handler:^(UIAction *a) {
                                                   [weakSelf renameFolder:folderPath];
                                               }];

    UIImage *folderDeleteImg = SPKGalleryMenuActionIcon(@"trash");
    UIAction *deleteAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE_FOLDER")
                                                 image:folderDeleteImg
                                            identifier:nil
                                               handler:^(UIAction *a) {
                                                   [weakSelf deleteFolder:folderPath];
                                               }];
    /// TODO: investigate whether native UIMenu destructive tint can be customized. UIMenuElement exposes no supported color API.
    deleteAction.attributes = UIMenuElementAttributesDestructive;

    return [UIMenu menuWithTitle:@"" children:@[ renameAction, deleteAction ]];
}

#pragma mark - Folder CRUD

- (void)presentCreateFolder {
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                           title:SPKL(@"GALLERY_GALLERY_NEW_FOLDER_TEXT")
                                                         message:@""
                                                     placeholder:SPKL(@"VC_PLACEHOLDER_FOLDER_NAME")
                                                     initialText:nil
                                                 autocapitalized:YES
                                                    confirmTitle:SPKL(@"TAB_CREATE")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        NSString *name = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                        if (name.length == 0)
                                                            return;
                                                        [self createFolderNamed:name];
                                                    }
                                                     cancelBlock:nil];
}

- (void)createFolderNamed:(NSString *)name {
    NSString *newPath = [self folderPathByAppendingComponent:name toBase:self.currentFolderPath];

    // Folders materialize when any file references them. To make empty folders
    // discoverable, we store a placeholder record in NSUserDefaults.
    NSString *key = @"gallery_folders";
    NSMutableArray<NSString *> *placeholders = [[[NSUserDefaults standardUserDefaults] arrayForKey:key] mutableCopy] ?: [NSMutableArray array];
    if (![placeholders containsObject:newPath]) {
        [placeholders addObject:newPath];
        [[NSUserDefaults standardUserDefaults] setObject:placeholders forKey:key];
    }
    [self reloadSubfolders];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (NSString *)folderPathByAppendingComponent:(NSString *)component toBase:(NSString *)base {
    NSString *sanitized = [component stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (base.length == 0)
        return [@"/" stringByAppendingString:sanitized];
    return [base stringByAppendingFormat:@"/%@", sanitized];
}

- (void)mergePlaceholderSubfolders {
    NSArray<NSString *> *placeholders = [self filteredPlaceholders];
    NSString *base = self.currentFolderPath ?: @"";
    NSString *prefix = base.length == 0 ? @"/" : [base stringByAppendingString:@"/"];

    NSMutableSet<NSString *> *merged = [NSMutableSet setWithArray:self.subfolders];
    for (NSString *p in placeholders) {
        if (![p hasPrefix:prefix])
            continue;
        NSString *rest = [p substringFromIndex:prefix.length];
        if (rest.length == 0)
            continue;
        NSRange slash = [rest rangeOfString:@"/"];
        NSString *folderName = slash.location == NSNotFound ? rest : [rest substringToIndex:slash.location];
        [merged addObject:[prefix stringByAppendingString:folderName]];
    }
    self.subfolders = [[merged allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)renameFolder:(NSString *)folderPath {
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                           title:SPKL(@"ALERT_ACTION_RENAME_FOLDER")
                                                         message:SPKL(@"GALLERY_GALLERY_ENTER_NEW_NAME_FOLDER_TEXT")
                                                     placeholder:nil
                                                     initialText:[folderPath lastPathComponent]
                                                 autocapitalized:YES
                                                    confirmTitle:SPKL(@"GALLERY_GALLERY_RENAME_TEXT")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        NSString *newName = [text stringByTrimmingCharactersInSet:
                                                                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                        if (newName.length == 0)
                                                            return;
                                                        [self performRenameOfFolder:folderPath toName:newName];
                                                    }
                                                     cancelBlock:nil];
}

- (void)performRenameOfFolder:(NSString *)oldPath toName:(NSString *)newName {
    NSString *parent = [oldPath stringByDeletingLastPathComponent];
    if (![parent hasPrefix:@"/"])
        parent = [@"/" stringByAppendingString:parent];
    NSString *newPath = [parent isEqualToString:@"/"]
                            ? [@"/" stringByAppendingString:newName]
                            : [parent stringByAppendingFormat:@"/%@", newName];

    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.predicate = [NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                     oldPath, [oldPath stringByAppendingString:@"/"]];
    NSArray<SPKGalleryFile *> *files = [ctx executeFetchRequest:req error:nil];
    for (SPKGalleryFile *f in files) {
        NSString *current = f.folderPath ?: @"";
        if ([current isEqualToString:oldPath]) {
            f.folderPath = newPath;
        } else if ([current hasPrefix:[oldPath stringByAppendingString:@"/"]]) {
            NSString *suffix = [current substringFromIndex:oldPath.length];
            f.folderPath = [newPath stringByAppendingString:suffix];
        }
    }
    [ctx save:nil];

    // Update placeholders.
    NSString *key = @"gallery_folders";
    NSMutableArray<NSString *> *placeholders = [[[NSUserDefaults standardUserDefaults] arrayForKey:key] mutableCopy] ?: [NSMutableArray array];
    NSMutableArray<NSString *> *updated = [NSMutableArray array];
    for (NSString *p in placeholders) {
        if ([p isEqualToString:oldPath]) {
            [updated addObject:newPath];
        } else if ([p hasPrefix:[oldPath stringByAppendingString:@"/"]]) {
            [updated addObject:[newPath stringByAppendingString:[p substringFromIndex:oldPath.length]]];
        } else {
            [updated addObject:p];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:updated forKey:key];

    [self reloadSubfolders];
    [self.collectionView reloadData];
}

- (void)deleteFolder:(NSString *)folderPath {
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.predicate = [NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                     folderPath, [folderPath stringByAppendingString:@"/"]];
    NSInteger count = [ctx countForFetchRequest:req error:nil];

    NSString *msg = count == 0
                        ? SPKL(@"GALLERY_GALLERY_FOLDER_EMPTY_TEXT")
                        : [NSString stringWithFormat:SPKL(@"GALLERY_FOLDER_DELETE_CONTENTS_MOVE_MESSAGE_FORMAT"),
                                                       SPKLP(@"COMMON_FILE_COUNT", count)];

    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"GALLERY_GALLERY_DELETE_FOLDER_CONFIRMATION_MESSAGE")
                                                message:msg
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [self performDeleteFolder:folderPath];
                                                                              }],
                                                ]];
}

- (void)performDeleteFolder:(NSString *)folderPath {
    NSString *parent = [folderPath stringByDeletingLastPathComponent];
    if (parent.length == 0 || [parent isEqualToString:@"/"])
        parent = nil; // move to root

    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.predicate = [NSPredicate predicateWithFormat:@"folderPath == %@ OR folderPath BEGINSWITH %@",
                                                     folderPath, [folderPath stringByAppendingString:@"/"]];
    NSArray<SPKGalleryFile *> *files = [ctx executeFetchRequest:req error:nil];
    for (SPKGalleryFile *f in files) {
        f.folderPath = parent;
    }
    [ctx save:nil];

    // Remove placeholders beneath the folder path.
    NSString *key = @"gallery_folders";
    NSMutableArray<NSString *> *placeholders = [[[NSUserDefaults standardUserDefaults] arrayForKey:key] mutableCopy] ?: [NSMutableArray array];
    NSString *prefix = [folderPath stringByAppendingString:@"/"];
    [placeholders filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *p, NSDictionary *b) {
                      return ![p isEqualToString:folderPath] && ![p hasPrefix:prefix];
                  }]];
    [[NSUserDefaults standardUserDefaults] setObject:placeholders forKey:key];

    [self reloadSubfolders];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

#pragma mark - File rename / move

- (void)editDetailsForFile:(SPKGalleryFile *)file {
    SPKGalleryFileDetailsViewController *vc = [[SPKGalleryFileDetailsViewController alloc] initWithFile:file];
    __weak typeof(self) weakSelf = self;
    vc.onSaved = ^{
        [weakSelf refetch];
    };
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        nav.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent,
        ];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)trimFile:(SPKGalleryFile *)file {
    NSURL *url = [file fileURL];
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        SPKNotify(@"spk.trim.gallery", SPKL(@"MEDIA_TRIM_CANNOT_TRIM_TOAST"), SPKL(@"MEDIA_TRIM_ORIGINAL_FILE_MISSING_TOAST"), @"error_filled", SPKNotificationToneError);
        return;
    }
    SPKTrimConfiguration *config = (file.mediaType == SPKGalleryMediaTypeAudio)
                                       ? [SPKTrimConfiguration configurationWithAudioURL:url]
                                       : [SPKTrimConfiguration configurationWithVideoURL:url];
    __weak typeof(self) weakSelf = self;
    [SPKTrimEditorViewController presentWithConfiguration:config
                                                     from:self
                                               completion:^(SPKTrimResult *result) {
                                                   if (!result)
                                                       return; // Cancelled.
                                                   [weakSelf saveTrimResult:result fromFile:file];
                                               }];
}

- (void)editFile:(SPKGalleryFile *)file {
    NSURL *url = [file fileURL];
    UIImage *source = (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path])
                          ? [UIImage imageWithContentsOfFile:url.path]
                          : nil;
    if (!source) {
        SPKNotify(@"spk.photoedit.gallery", SPKL(@"GALLERY_GALLERY_CANNOT_EDIT_TEXT"), SPKL(@"MEDIA_TRIM_ORIGINAL_FILE_MISSING_TOAST"), @"error_filled", SPKNotificationToneError);
        return;
    }
    __weak typeof(self) weakSelf = self;
    [SPKPhotoEditorViewController presentWithSourceImage:source
                                           configuration:[SPKPhotoEditorConfiguration freeformConfiguration]
                                                    from:self
                                              completion:^(UIImage *edited) {
                                                  if (!edited)
                                                      return; // Cancelled.
                                                  [weakSelf saveEditedImage:edited fromFile:file];
                                              }];
}

- (void)saveEditedImage:(UIImage *)image fromFile:(SPKGalleryFile *)sourceFile {
    __weak typeof(self) weakSelf = self;
    [SPKTrimSaveCoordinator saveEditedImage:image
                                 originFile:sourceFile
                             fallbackSource:(SPKGallerySource)sourceFile.source
                                 folderPath:sourceFile.folderPath
                                  presenter:self
                                 completion:^(BOOL didChange) {
                                     if (didChange) {
                                         [weakSelf refetch];
                                     }
                                 }];
}

- (void)saveTrimResult:(SPKTrimResult *)result fromFile:(SPKGalleryFile *)sourceFile {
    __weak typeof(self) weakSelf = self;
    [SPKTrimSaveCoordinator saveResult:result
                            originFile:sourceFile
                        fallbackSource:(SPKGallerySource)sourceFile.source
                            folderPath:sourceFile.folderPath
                             presenter:self
                            completion:^(BOOL didChange) {
                                if (didChange) {
                                    [weakSelf refetch];
                                }
                            }];
}

- (void)assignFolderPath:(nullable NSString *)folderPath toFiles:(NSArray<SPKGalleryFile *> *)files {
    for (SPKGalleryFile *file in files) {
        file.folderPath = folderPath;
    }
    [[SPKGalleryCoreDataStack shared] saveContext];
    [self refetch];
}

- (void)presentMoveSheetForFiles:(NSArray<SPKGalleryFile *> *)files {
    NSArray<NSString *> *allFolders = [self allFolderPaths];

    // The files' shared current folder (nil = Root). When every selected file
    // already lives in the same folder, that folder is omitted as a destination —
    // moving them there would be a no-op. With a mixed selection nothing is omitted.
    NSString *currentFolder = nil;
    BOOL sharesCurrentFolder = files.count > 0;
    for (NSUInteger i = 0; i < files.count; i++) {
        NSString *path = files[i].folderPath.length > 0 ? files[i].folderPath : nil;
        if (i == 0) {
            currentFolder = path;
        } else if (!((path == nil && currentFolder == nil) || [path isEqualToString:currentFolder])) {
            sharesCurrentFolder = NO;
            break;
        }
    }
    BOOL currentIsRoot = sharesCurrentFolder && currentFolder == nil;

    NSMutableArray<SPKIGAlertAction *> *actions = [NSMutableArray array];

    if (!currentIsRoot) {
        [actions addObject:[SPKIGAlertAction actionWithTitle:@"/"
                                                       style:SPKIGAlertActionStyleDefault
                                                     handler:^{
                                                         [self assignFolderPath:nil toFiles:files];
                                                     }]];
    }

    for (NSString *folder in allFolders) {
        if (sharesCurrentFolder && currentFolder != nil && [folder isEqualToString:currentFolder]) {
            continue;
        }
        [actions addObject:[SPKIGAlertAction actionWithTitle:folder
                                                       style:SPKIGAlertActionStyleDefault
                                                     handler:^{
                                                         [self assignFolderPath:folder toFiles:files];
                                                     }]];
    }

    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_NEW_FOLDER")
                                                   style:SPKIGAlertActionStyleDefault
                                                 handler:^{
                                                     [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                                                                            title:SPKL(@"GALLERY_GALLERY_NEW_FOLDER_TEXT")
                                                                                                          message:SPKL(@"GALLERY_GALLERY_ENTER_NEW_FOLDER_NAME_THEN_MOVE_SELECTED_FILES_THERE_TEXT")
                                                                                                      placeholder:SPKL(@"VC_PLACEHOLDER_FOLDER_NAME")
                                                                                                      initialText:nil
                                                                                                  autocapitalized:NO
                                                                                                     confirmTitle:SPKL(@"GALLERY_GALLERY_CREATE_MOVE_TEXT")
                                                                                                      cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                                                                     confirmStyle:SPKIGAlertActionStyleDefault
                                                                                                     confirmBlock:^(NSString *text) {
                                                                                                         NSString *name = [text stringByTrimmingCharactersInSet:
                                                                                                                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                                                                         if (name.length == 0)
                                                                                                             return;
                                                                                                         NSString *newPath = [self folderPathByAppendingComponent:name toBase:self.currentFolderPath];
                                                                                                         [self assignFolderPath:newPath toFiles:files];
                                                                                                     }
                                                                                                      cancelBlock:nil];
                                                 }]];

    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:SPKIGAlertActionStyleCancel handler:nil]];

    NSString *message = SPKL(@"GALLERY_GALLERY_CHOOSE_MOVE_SELECTED_FILE_S_TEXT");
    if (sharesCurrentFolder) {
        NSString *currentName = currentFolder.length > 0 ? [currentFolder lastPathComponent] : @"/";
        message = [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_CURRENTLY_VALUE_CHOOSE_MOVE_SELECTED_FILE_S_FORMAT"), currentName];
    }
    [SPKIGAlertPresenter presentActionSheetFromViewController:self
                                                        title:SPKL(@"ALERT_ACTION_MOVE_FOLDER")
                                                      message:message
                                                      actions:actions
                                                   forceSheet:YES];
}

- (void)moveFile:(SPKGalleryFile *)file {
    [self presentMoveSheetForFiles:@[ file ]];
}

- (NSArray<NSString *> *)filteredPlaceholders {
    NSArray<NSString *> *placeholders = [[NSUserDefaults standardUserDefaults] arrayForKey:@"gallery_folders"] ?: @[];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (!visibleSources)
        return placeholders;

    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;

    // Fetch distinct folder paths for files matching current account / visible filters.
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"folderPath" ];
    req.returnsDistinctResults = YES;
    req.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [NSPredicate predicateWithFormat:@"folderPath != nil AND folderPath != ''"],
        visibleSources
    ]];
    NSArray<NSDictionary *> *results = [ctx executeFetchRequest:req error:nil];
    NSMutableSet<NSString *> *currentAccountFolders = [NSMutableSet set];
    for (NSDictionary *d in results) {
        NSString *p = d[@"folderPath"];
        if (p.length > 0)
            [currentAccountFolders addObject:p];
    }

    // Fetch all distinct folder paths in the database (regardless of account filter).
    NSFetchRequest *allReq = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    allReq.resultType = NSDictionaryResultType;
    allReq.propertiesToFetch = @[ @"folderPath" ];
    allReq.returnsDistinctResults = YES;
    allReq.predicate = [NSPredicate predicateWithFormat:@"folderPath != nil AND folderPath != ''"];
    NSArray<NSDictionary *> *allResults = [ctx executeFetchRequest:allReq error:nil];
    NSMutableSet<NSString *> *allFileFolders = [NSMutableSet set];
    for (NSDictionary *d in allResults) {
        NSString *p = d[@"folderPath"];
        if (p.length > 0)
            [allFileFolders addObject:p];
    }

    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *p in placeholders) {
        if (p.length == 0)
            continue;
        // Skip placeholders that are associated with other accounts, but not the current account.
        if ([allFileFolders containsObject:p] && ![currentAccountFolders containsObject:p]) {
            continue;
        }
        [filtered addObject:p];
    }
    return [filtered copy];
}

- (NSArray<NSString *> *)allFolderPaths {
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"folderPath" ];
    req.returnsDistinctResults = YES;

    NSPredicate *nonEmptyFolder = [NSPredicate predicateWithFormat:@"folderPath != nil AND folderPath != ''"];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    req.predicate = visibleSources
                        ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ nonEmptyFolder, visibleSources ]]
                        : nonEmptyFolder;

    NSArray<NSDictionary *> *results = [ctx executeFetchRequest:req error:nil];

    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NSDictionary *d in results) {
        NSString *p = d[@"folderPath"];
        if (p.length > 0)
            [set addObject:p];
    }
    [set addObjectsFromArray:[self filteredPlaceholders]];

    return [[set allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSArray<NSString *> *)availableSourceUsernamesForCurrentFilterContext {
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"sourceUsername" ];
    req.returnsDistinctResults = YES;

    NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];
    NSPredicate *contextPredicate = [SPKGalleryFilterViewController predicateForTypes:self.filterTypes
                                                                              sources:self.filterSources
                                                                        favoritesOnly:self.filterFavoritesOnly
                                                                            usernames:[NSSet set]
                                                                           folderPath:self.currentFolderPath];
    if (contextPredicate)
        [predicates addObject:contextPredicate];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (visibleSources)
        [predicates addObject:visibleSources];
    NSString *query = [self.searchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length > 0) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"(sourceUsername CONTAINS[cd] %@) OR (customName CONTAINS[cd] %@) OR (relativePath CONTAINS[cd] %@)",
                                                               query, query, query]];
    }
    [predicates addObject:[NSPredicate predicateWithFormat:@"sourceUsername != nil AND sourceUsername != ''"]];
    req.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];

    NSArray<NSDictionary *> *results = [ctx executeFetchRequest:req error:nil];

    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NSDictionary *row in results) {
        NSString *username = [row[@"sourceUsername"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (username.length > 0)
            [set addObject:username];
    }
    return [[set allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSArray<NSString *> *)usernamesForFilterDisplayFromUsernames:(NSArray<NSString *> *)usernames {
    return [usernames sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL aSelected = [self usernameFilterContainsUsername:a];
        BOOL bSelected = [self usernameFilterContainsUsername:b];
        if (aSelected && !bSelected)
            return NSOrderedAscending;
        if (!aSelected && bSelected)
            return NSOrderedDescending;
        return [a localizedCaseInsensitiveCompare:b];
    }];
}

- (NSString *)matchingSelectedUsernameForUsername:(NSString *)username {
    if (username.length == 0)
        return nil;
    for (NSString *selectedUsername in self.filterUsernames) {
        if ([selectedUsername caseInsensitiveCompare:username] == NSOrderedSame)
            return selectedUsername;
    }
    return nil;
}

- (BOOL)usernameFilterContainsUsername:(NSString *)username {
    return [self matchingSelectedUsernameForUsername:username].length > 0;
}

- (void)toggleUsernameFilter:(NSString *)username {
    NSString *existing = [self matchingSelectedUsernameForUsername:username];
    if (existing.length > 0) {
        [self.filterUsernames removeObject:existing];
    } else if (username.length > 0) {
        [self.filterUsernames addObject:username];
    }
    [self refetch];
}

/// Drops any active username filters that no longer have matching media (e.g. after
/// the last item from that user was deleted). Returns YES if the filter set changed.
///
/// Uses a per-username count fetch with `includesPendingChanges = YES` rather than the
/// store-only distinct fetch in `availableSourceUsernamesForCurrentFilterContext`. This
/// matters because the FRC fires `controllerDidChangeContent:` during `processPendingChanges`,
/// *before* the deletes are flushed to SQLite — a store-only (NSDictionaryResultType) fetch
/// would still see the just-deleted rows and never prune the filter.
- (BOOL)pruneStaleUsernameFilters {
    if (self.filterUsernames.count == 0)
        return NO;
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    for (NSString *selected in self.filterUsernames) {
        if ([self countOfMediaForUsername:selected inContext:ctx] == 0) {
            [stale addObject:selected];
        }
    }
    if (stale.count == 0)
        return NO;
    for (NSString *username in stale)
        [self.filterUsernames removeObject:username];
    return YES;
}

/// Counts media for a username within the current (non-username) filter context, honoring
/// unsaved in-memory deletions so prune works mid-save from the FRC delegate.
- (NSUInteger)countOfMediaForUsername:(NSString *)username inContext:(NSManagedObjectContext *)ctx {
    if (username.length == 0)
        return 0;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    req.includesPendingChanges = YES;

    NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];
    [predicates addObject:[NSPredicate predicateWithFormat:@"sourceUsername ==[c] %@", username]];
    NSPredicate *contextPredicate = [SPKGalleryFilterViewController predicateForTypes:self.filterTypes
                                                                              sources:self.filterSources
                                                                        favoritesOnly:self.filterFavoritesOnly
                                                                            usernames:[NSSet set]
                                                                           folderPath:self.currentFolderPath];
    if (contextPredicate)
        [predicates addObject:contextPredicate];
    NSPredicate *visibleSources = SPKGalleryVisibleSourcesPredicate();
    if (visibleSources)
        [predicates addObject:visibleSources];
    req.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];

    NSUInteger count = [ctx countForFetchRequest:req error:nil];
    return count == NSNotFound ? 0 : count;
}

#pragma mark - Sort / Filter

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
                customDetentWithIdentifier:@"sparkle.gallery.sort.fit"
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

// Single fixed sheet height for the sort/filter sheets: the controller's content
// height plus the sheet nav bar and the device's bottom safe area. Computed once
// at present time so there's no layout-time detent invalidation (which deadlocks
// iOS 26 via an observation feedback loop).
- (CGFloat)sheetFitHeightForContentHeight:(CGFloat)contentHeight {
    CGFloat bottomSafe = self.view.window.safeAreaInsets.bottom;
    CGFloat navBar = 56.0; // grabber + nav bar in a sheet
    return navBar + contentHeight + bottomSafe + 8.0;
}

- (CGFloat)sheetContentWidth {
    return CGRectGetWidth(self.view.bounds);
}

- (void)presentFilter {
    SPKGalleryFilterViewController *vc = [[SPKGalleryFilterViewController alloc] init];
    vc.delegate = self;
    vc.filterTypes = self.filterTypes;
    vc.filterSources = self.filterSources;
    vc.filterFavoritesOnly = self.filterFavoritesOnly;
    vc.filterUsernames = [self.filterUsernames mutableCopy];
    NSArray<NSString *> *availableUsernames = [self availableSourceUsernamesForCurrentFilterContext];
    BOOL showsUsernameSection = availableUsernames.count > 1;
    vc.availableUsernames = showsUsernameSection ? [self usernamesForFilterDisplayFromUsernames:availableUsernames] : @[];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    [self configureGallerySheetForNavigation:nav];

    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        if (@available(iOS 16.0, *)) {
            CGFloat fitHeight = [self sheetFitHeightForContentHeight:[vc spkContentHeightForWidth:[self sheetContentWidth]]];
            UISheetPresentationControllerDetent *fit = [UISheetPresentationControllerDetent
                customDetentWithIdentifier:@"sparkle.gallery.filter.fit"
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

- (void)sortController:(SPKGallerySortViewController *)controller didSelectSortMode:(SPKGallerySortMode)mode groupByMediaType:(BOOL)groupByMediaType {
    self.sortMode = mode;
    self.sortGroupByMediaType = groupByMediaType;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kSortModeKey];
    [[NSUserDefaults standardUserDefaults] setBool:groupByMediaType forKey:kSortGroupByTypeKey];
    [self refetch];
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
    [self refetch];
}

- (void)filterControllerDidClear:(SPKGalleryFilterViewController *)controller {
    [self.filterTypes removeAllObjects];
    [self.filterSources removeAllObjects];
    self.filterFavoritesOnly = NO;
    [self.filterUsernames removeAllObjects];
    [self refetch];
}

- (void)handleGalleryPreferencesChanged:(NSNotification *)note {
    (void)note;
    [self refetch];
}

- (void)handleGridControlsPreferenceChanged:(NSNotification *)note {
    (void)note;
    [self refreshBottomToolbarItems];
    [self reconfigureVisibleGridCells];
    if ([self.collectionView.collectionViewLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
        BOOL pinned = SPKGalleryFolderBarPinned();
        if (flow.sectionHeadersPinToVisibleBounds != pinned) {
            flow.sectionHeadersPinToVisibleBounds = pinned;
            [flow invalidateLayout];
        }
    }
}

#pragma mark - Settings

- (void)pushSettings {
    SPKGallerySettingsViewController *vc = [[SPKGallerySettingsViewController alloc] init];
    vc.importDestinationFolderPath = self.currentFolderPath;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
