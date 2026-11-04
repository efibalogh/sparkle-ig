#import "SPKStrings.h"
#import "SPKDeletedMessagesViewController.h"

#import "../../../AssetUtils.h"
#import "../../../Shared/Avatars/SPKAvatarCache.h"
#import "../../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../../Shared/UI/SPKMediaChrome.h"
#import "../../../Utils.h"
#import "SPKDeletedMessagesChipBar.h"
#import "SPKDeletedMessagesDate.h"
#import "SPKDeletedMessagesFilter.h"
#import "SPKDeletedMessagesSenderCell.h"
#import "SPKDeletedMessagesStorage.h"
#import "SPKDeletedMessagesStorageViewController.h"
#import "SPKDeletedMessagesUserDetailViewController.h"

#import <objc/runtime.h>
#import "../../../Shared/UI/SPKNotificationCenter.h"

static NSString *SPKDMCurrentUserPK(void) {
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            id session = nil;
            @try {
                session = [window valueForKey:@"userSession"];
            } @catch (__unused id e) {
            }
            id user = nil;
            @try {
                user = [session valueForKey:@"user"];
            } @catch (__unused id e) {
            }
            for (NSString *key in @[ @"pk", @"instagramUserID", @"instagramUserId", @"userID", @"userId" ]) {
                id value = nil;
                @try {
                    value = [user valueForKey:key];
                } @catch (__unused id e) {
                }
                if ([value isKindOfClass:NSString.class] && [value length])
                    return value;
                if ([value isKindOfClass:NSNumber.class])
                    return [value stringValue];
            }
        }
    } @catch (__unused id e) {
    }
    NSArray<NSString *> *owners = [SPKDeletedMessagesStorage allOwnerPKs];
    return owners.firstObject ?: @"anon";
}

@interface SPKDeletedMessagesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, SPKDeletedMessagesChipBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) SPKDeletedMessagesChipBar *chipBar;
@property (nonatomic, strong) NSLayoutConstraint *chipBarHeight;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyStateIcon;
@property (nonatomic, strong) UILabel *emptyStateTitle;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;
@property (nonatomic, strong) SPKDeletedMessagesFilter *filter;
@property (nonatomic, copy) NSString *ownerPK;
@property (nonatomic, copy) NSArray<SPKDeletedMessageGroup *> *groups;
@property (nonatomic, copy) NSArray<SPKDeletedMessageGroup *> *visibleGroups;
@end

@implementation SPKDeletedMessagesViewController

// Chip filter columns. Multi-select; an empty selection means "show all", so
// there's no dedicated "All" chip. Index maps to an explicit kind so chip order
// is decoupled from the enum's numeric values.
static NSArray<NSString *> *SPKDMChipTitles(void) {
    return @[ SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_TEXT"), SPKL(@"COMMON_MEDIA_TYPE_PHOTO"), SPKL(@"COMMON_MEDIA_TYPE_VIDEO"), SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_VOICE_TEXT"), SPKL(@"COMMON_MEDIA_TYPE_GIF"), SPKL(@"COMMON_MEDIA_TYPE_STICKER"), SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_SHARES_TEXT"), SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_LINK_TEXT"), SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_REACTION_ACTION") ];
}
static NSArray<NSString *> *SPKDMChipSymbols(void) {
    return @[ @"message", @"photo", @"video", @"voice", @"gif", @"sticker", @"shares", @"link", @"reactions" ];
}
// Filled variants used when a chip is selected.
static NSArray<NSString *> *SPKDMChipSelectedSymbols(void) {
    return @[ @"message", @"photo_filled", @"video_filled", @"voice_filled", @"gif_filled", @"sticker_filled", @"shares_filled", @"link", @"reactions" ];
}
static SPKDeletedMessageKind SPKDMChipKindForIndex(NSInteger index) {
    switch (index) {
    case 0:
        return SPKDeletedMessageKindText;
    case 1:
        return SPKDeletedMessageKindPhoto;
    case 2:
        return SPKDeletedMessageKindVideo;
    case 3:
        return SPKDeletedMessageKindVoice;
    case 4:
        return SPKDeletedMessageKindGif;
    case 5:
        return SPKDeletedMessageKindSticker;
    case 6:
        return SPKDeletedMessageKindShare;
    case 7:
        return SPKDeletedMessageKindLink;
    case 8:
        return SPKDeletedMessageKindReaction;
    default:
        return SPKDeletedMessageKindUnknown;
    }
}

+ (void)presentFromViewController:(UIViewController *)presenter {
    UIViewController *root = presenter ?: UIApplication.sharedApplication.keyWindow.rootViewController;
    while (root.presentedViewController)
        root = root.presentedViewController;
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:[SPKDeletedMessagesViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

+ (void)presentForThreadId:(NSString *)threadId
                  senderPK:(NSString *)senderPK
                senderName:(NSString *)senderName
        fromViewController:(UIViewController *)presenter {
    UIViewController *root = presenter ?: UIApplication.sharedApplication.keyWindow.rootViewController;
    while (root.presentedViewController)
        root = root.presentedViewController;

    SPKDeletedMessagesViewController *list = [SPKDeletedMessagesViewController new];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    // Prefer threadId (reliable from an open chat); fall back to senderPK.
    NSString *ownerPK = SPKDMCurrentUserPK();
    SPKDeletedMessageGroup *group = nil;
    if (threadId.length) {
        group = [SPKDeletedMessagesStorage groupForThreadId:threadId ownerPK:ownerPK];
    }
    if (!group && senderPK.length) {
        group = [SPKDeletedMessagesStorage groupForSenderPK:senderPK ownerPK:ownerPK];
    }

    UIViewController *detail = nil;
    if (group) {
        detail = [[SPKDeletedMessagesUserDetailViewController alloc] initWithGroup:group ownerPK:ownerPK];
    }

    [root presentViewController:nav
                       animated:YES
                     completion:^{
                         if (detail) {
                             [list.navigationController pushViewController:detail animated:YES];
                         }
                     }];
}

- (instancetype)init {
    if ((self = [super init])) {
        _filter = [SPKDeletedMessagesFilter new];
        _ownerPK = SPKDMCurrentUserPK();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"ALERT_ACTION_DELETED_MESSAGES");
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    UIBarButtonItem *moreItem = SPKMediaChromeTopBarMenuButtonItem(@"more", [self moreMenu], SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT"));
    UIBarButtonItem *sortItem = SPKMediaChromeTopBarMenuButtonItem(@"sort", [self sortMenu], SPKL(@"MESSAGES_DELETED_MESSAGES_SORT_FILTER_TEXT"));
    // More button is always rightmost (last in trailing-group order), matching
    // the downloads history convention.
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ sortItem, moreItem ]);
    if (self.navigationController.viewControllers.firstObject == self) {
        SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(close)) ]);
    }

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = SPKL(@"MESSAGES_DELETED_MESSAGES_SEARCH_DELETED_MESSAGES_MESSAGE");
    [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                             forSearchBarIcon:UISearchBarIconSearch
                                        state:UIControlStateNormal];
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.chipBar = [[SPKDeletedMessagesChipBar alloc] initWithFrame:CGRectZero];
    self.chipBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipBar.delegate = self;
    [self.chipBar setItems:SPKDMChipTitles() symbols:SPKDMChipSymbols() selectedSymbols:SPKDMChipSelectedSymbols()];
    [self.view addSubview:self.chipBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 80.0, 0.0, 0.0);
    self.tableView.rowHeight = 72.0;
    [self.tableView registerClass:[SPKDeletedMessagesSenderCell class] forCellReuseIdentifier:SPKDeletedMessagesSenderCellReuseID];
    [self.view addSubview:self.tableView];

    [self setupEmptyState];

    self.chipBarHeight = [self.chipBar.heightAnchor constraintEqualToConstant:50.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.chipBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chipBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chipBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        self.chipBarHeight,
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.chipBar.bottomAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:SPKDeletedMessagesDidChangeNotification object:nil];
    [self reloadData];
}

- (void)setupEmptyState {
    self.emptyStateView = [UIView new];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyStateIcon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"messages_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate]];
    self.emptyStateIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.emptyStateIcon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [self.emptyStateView addSubview:self.emptyStateIcon];

    self.emptyStateTitle = [UILabel new];
    self.emptyStateTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateTitle.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    self.emptyStateTitle.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    self.emptyStateTitle.textAlignment = NSTextAlignmentCenter;
    self.emptyStateTitle.numberOfLines = 0;
    [self.emptyStateView addSubview:self.emptyStateTitle];

    self.emptyStateSubtitle = [UILabel new];
    self.emptyStateSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateSubtitle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    self.emptyStateSubtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    self.emptyStateSubtitle.textAlignment = NSTextAlignmentCenter;
    self.emptyStateSubtitle.numberOfLines = 0;
    [self.emptyStateView addSubview:self.emptyStateSubtitle];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor
                                                          constant:-30.0],
        [self.emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor
                                                                       constant:40.0],
        [self.emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor
                                                                     constant:-40.0],

        [self.emptyStateIcon.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [self.emptyStateIcon.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyStateIcon.widthAnchor constraintEqualToConstant:96.0],
        [self.emptyStateIcon.heightAnchor constraintEqualToConstant:96.0],

        [self.emptyStateTitle.topAnchor constraintEqualToAnchor:self.emptyStateIcon.bottomAnchor
                                                       constant:18.0],
        [self.emptyStateTitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyStateTitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [self.emptyStateSubtitle.topAnchor constraintEqualToAnchor:self.emptyStateTitle.bottomAnchor
                                                          constant:6.0],
        [self.emptyStateSubtitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyStateSubtitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        [self.emptyStateSubtitle.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor],
    ]];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadData {
    self.ownerPK = SPKDMCurrentUserPK();
    NSArray<SPKDeletedMessageGroup *> *allGroups = [SPKDeletedMessagesStorage groupedForOwnerPK:self.ownerPK];
    NSMutableArray<SPKDeletedMessageGroup *> *filtered = [NSMutableArray array];
    for (SPKDeletedMessageGroup *g in allGroups) {
        // Hide the owner's own 1:1 bucket (self-thread); group threads always show.
        if (!g.isGroup && [g.senderPk isEqualToString:self.ownerPK])
            continue;
        [filtered addObject:g];
    }
    self.groups = [filtered copy];
    [self applyFilter];
    [self rebuildMenus];
}

- (void)applyFilter {
    self.visibleGroups = [self.filter applyToGroups:self.groups ?: @[]];
    [self updateChipBarVisibility];
    [self updateEmptyState];
    [self.tableView reloadData];
}

// Distinct message kinds present across all unfiltered groups. Drives whether
// the kind chip bar is worth showing at all.
- (NSUInteger)distinctKindCount {
    NSMutableSet<NSNumber *> *kinds = [NSMutableSet set];
    for (SPKDeletedMessageGroup *group in self.groups) {
        for (SPKDeletedMessage *message in group.messages) {
            [kinds addObject:@(message.kind)];
        }
    }
    return kinds.count;
}

- (void)updateChipBarVisibility {
    // Show when there's something to filter (2+ kinds), OR when a filter is
    // currently active / hiding everything so the user can change it.
    BOOL hasActiveKindFilter = [self.filter hasKindFilter];
    BOOL show = ([self distinctKindCount] >= 2) || hasActiveKindFilter;
    BOOL hidden = !show;
    if (self.chipBar.hidden != hidden) {
        self.chipBar.hidden = hidden;
        self.chipBarHeight.constant = hidden ? 0.0 : 50.0;
    }
}

- (void)updateEmptyState {
    BOOL loggingEnabled = [SPKUtils getBoolPref:@"msgs_deleted_log"];
    BOOL hasAnyData = (self.groups.count > 0);
    BOOL hasFiltersActive = ![self.filter isEmpty];
    BOOL isEmpty = (self.visibleGroups.count == 0);

    self.emptyStateView.hidden = !isEmpty;
    self.tableView.hidden = isEmpty;

    if (!isEmpty)
        return;

    if (!loggingEnabled && !hasAnyData) {
        self.emptyStateIcon.image = [SPKAssetUtils instagramIconNamed:@"messages_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_LOGGING_OFF_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_TURN_LOG_DELETED_MESSAGES_SETTINGS_START_CAPTURING_UNSENT_MESSAGES_MESSAGE");
    } else if (hasAnyData && hasFiltersActive) {
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_NO_MATCHES_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_NO_DELETED_MESSAGES_MATCH_CURRENT_FILTERS_MESSAGE");
    } else {
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_NOTHING_HERE_YET_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_MESSAGES_OTHER_PEOPLE_UNSEND_SHOW_UP_HERE_MESSAGE");
    }
}

- (void)rebuildMenus {
    // Menus are deferred (self-refreshing), so nothing to reassign here.
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter.searchText = searchController.searchBar.text;
    [self applyFilter];
}

#pragma mark - Chip Bar

- (void)chipBar:(SPKDeletedMessagesChipBar *)bar didChangeSelection:(NSSet<NSNumber *> *)selectedIndices {
    [self.filter clearKinds];
    for (NSNumber *index in selectedIndices) {
        SPKDeletedMessageKind kind = SPKDMChipKindForIndex(index.integerValue);
        if (kind != SPKDeletedMessageKindUnknown)
            [self.filter toggleKind:kind];
    }
    [self applyFilter];
}

#pragma mark - Menus

// Both top-bar menus resolve their children fresh each open (via a deferred
// element), so checkmarks / titles always reflect current state without
// reassigning the button's menu.
- (UIMenu *)sortMenu {
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion([weakSelf sortMenuElements]);
    }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

- (NSArray<UIMenuElement *> *)sortMenuElements {
    __weak typeof(self) weakSelf = self;
    NSArray *items = @[
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_RECENT_TEXT"), @(SPKDMSortRecent) ],
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_OLDEST_TEXT"), @(SPKDMSortOldest) ],
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_MOST_MESSAGES_MESSAGE"), @(SPKDMSortCountDesc) ]
    ];
    NSMutableArray<UIAction *> *sortActions = [NSMutableArray array];
    for (NSArray *item in items) {
        SPKDMSort sort = [item[1] integerValue];
        UIAction *action = [UIAction actionWithTitle:item[0]
                                               image:nil
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 weakSelf.filter.sort = sort;
                                                 [weakSelf applyFilter];
                                             }];
        if (self.filter.sort == sort)
            action.state = UIMenuElementStateOn;
        [sortActions addObject:action];
    }
    UIMenu *sortSection = [UIMenu menuWithTitle:SPKL(@"MENU_SORT") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sortActions];

    NSMutableArray<UIAction *> *dateActions = [NSMutableArray array];
    NSArray *dateItems = @[
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_TIME_TEXT"), @(SPKDMDateRangeAll) ],
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_TODAY_TEXT"), @(SPKDMDateRangeToday) ],
        @[ SPKL(@"MESSAGES_DELETED_FILTER_LAST_SEVEN_DAYS_TITLE"), @(SPKDMDateRangeWeek) ],
        @[ SPKL(@"MESSAGES_DELETED_MESSAGES_LAST_DAYS_TEXT"), @(SPKDMDateRangeMonth) ]
    ];
    for (NSArray *item in dateItems) {
        SPKDMDateRange range = [item[1] integerValue];
        UIAction *action = [UIAction actionWithTitle:item[0]
                                               image:nil
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 weakSelf.filter.dateRange = range;
                                                 [weakSelf applyFilter];
                                             }];
        if (self.filter.dateRange == range)
            action.state = UIMenuElementStateOn;
        [dateActions addObject:action];
    }
    UIMenu *dateSection = [UIMenu menuWithTitle:SPKL(@"MENU_DATE_RANGE") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:dateActions];

    return @[ sortSection, dateSection ];
}

- (UIMenu *)moreMenu {
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion([weakSelf moreMenuElements]);
    }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

- (NSArray<UIMenuElement *> *)moreMenuElements {
    __weak typeof(self) weakSelf = self;

    UIAction *storageAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_STORAGE")
                                                  image:[SPKAssetUtils menuIconNamed:@"info"]
                                             identifier:nil
                                                handler:^(__unused UIAction *a) {
                                                    [weakSelf.navigationController pushViewController:[SPKDeletedMessagesStorageViewController new] animated:YES];
                                                }];

    UIAction *refreshAvatarsAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_REFRESH_PROFILE_PICTURES")
                                                         image:[SPKAssetUtils menuIconNamed:@"user_circle"]
                                                    identifier:nil
                                                       handler:^(__unused UIAction *a) {
                                                           [[SPKAvatarCache shared] purge];
                                                           [weakSelf.tableView reloadData];
                                                       }];

    UIAction *clearFiltersAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_FILTERS")
                                                       image:[SPKAssetUtils menuIconNamed:@"filter"]
                                                  identifier:nil
                                                     handler:^(__unused UIAction *a) {
                                                         weakSelf.filter = [SPKDeletedMessagesFilter new];
                                                         weakSelf.searchController.searchBar.text = nil;
                                                         [weakSelf.chipBar clearSelection];
                                                         [weakSelf applyFilter];
                                                     }];

    UIAction *clearAllAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_ALL_MESSAGES")
                                                   image:[SPKAssetUtils menuIconNamed:@"trash"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *a) {
                                                     [weakSelf confirmClearAll];
                                                 }];
    /// TODO: investigate whether native UIMenu destructive tint can be customized. UIMenuElement exposes no supported color API.
    clearAllAction.attributes = UIMenuElementAttributesDestructive;

    UIMenu *destructiveSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ clearAllAction ]];

    return @[ storageAction, refreshAvatarsAction, clearFiltersAction, destructiveSection ];
}

- (void)confirmClearAll {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"MESSAGES_DELETED_MESSAGES_CLEAR_DELETED_MESSAGES_MESSAGE")
                                                message:SPKL(@"MESSAGES_DELETED_MESSAGES_REMOVES_LOG_CAPTURED_MEDIA_CURRENT_ACCOUNT_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [SPKDeletedMessagesStorage resetForOwnerPK:self.ownerPK];
                                                                                  SPKNotify(kSPKNotificationDeletedMessagesClear, SPKL(@"MESSAGES_DELETED_MESSAGES_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (void)confirmDeleteGroup:(SPKDeletedMessageGroup *)group {
    BOOL isGroup = group.isGroup;
    if (isGroup ? !group.threadId.length : !group.senderPk.length)
        return;
    NSString *who = isGroup ? group.displayName
                            : (group.senderUsername.length ? [@"@" stringByAppendingString:group.senderUsername] : SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_THIS_SENDER_LABEL"));
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:isGroup ? SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_DELETE_GROUP_LOG_CONFIRMATION_MESSAGE") : SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_DELETE_SENDER_LOG_CONFIRMATION_MESSAGE")
                                                message:[NSString stringWithFormat:SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_REMOVES_LOGGED_MESSAGES_VALUE_MESSAGE"), who]
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETE")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  if (isGroup)
                                                                                      [SPKDeletedMessagesStorage deleteMessagesForThreadId:group.threadId ownerPK:self.ownerPK];
                                                                                  else
                                                                                      [SPKDeletedMessagesStorage deleteMessagesForSenderPK:group.senderPk ownerPK:self.ownerPK];
                                                                                  SPKNotify(kSPKNotificationDeletedMessagesClear, SPKL(@"MESSAGES_DELETED_MESSAGES_LOG_DELETED_TOAST"), who, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleGroups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKDeletedMessagesSenderCell *cell = [tableView dequeueReusableCellWithIdentifier:SPKDeletedMessagesSenderCellReuseID forIndexPath:indexPath];
    [cell configureWithGroup:self.visibleGroups[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKDeletedMessageGroup *group = self.visibleGroups[indexPath.row];
    [self.navigationController pushViewController:[[SPKDeletedMessagesUserDetailViewController alloc] initWithGroup:group ownerPK:self.ownerPK] animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKDeletedMessageGroup *group = self.visibleGroups[indexPath.row];
    UIContextualAction *pinAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                            title:nil
                                                                          handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
                                                                              [SPKDeletedMessagesStorage setSenderPinned:!group.isPinned senderPK:group.flagKey ownerPK:self.ownerPK];
                                                                              completionHandler(YES);
                                                                          }];
    pinAction.image = [SPKAssetUtils menuIconNamed:(group.isPinned ? @"pin_filled" : @"pin")];
    pinAction.backgroundColor = [SPKUtils SPKColor_InstagramBlue];
    pinAction.accessibilityLabel = group.isPinned ? SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_UNPIN_TEXT") : SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_PIN_TEXT");
    UIContextualAction *blockAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                              title:nil
                                                                            handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
                                                                                [SPKDeletedMessagesStorage setSenderBlocked:!group.isBlocked senderPK:group.flagKey ownerPK:self.ownerPK];
                                                                                completionHandler(YES);
                                                                            }];
    blockAction.image = [SPKAssetUtils menuIconNamed:(group.isBlocked ? @"circle" : @"circle_off")];
    blockAction.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryText];
    blockAction.accessibilityLabel = group.isBlocked ? SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_UNBLOCK_TEXT") : SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_BLOCK_TEXT");
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:nil
                                                                             handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
                                                                                 [self confirmDeleteGroup:group];
                                                                                 completionHandler(NO);
                                                                             }];
    deleteAction.image = [SPKAssetUtils menuIconNamed:@"trash"];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"ALERT_ACTION_DELETE");
    return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction, blockAction, pinAction ]];
}

@end
