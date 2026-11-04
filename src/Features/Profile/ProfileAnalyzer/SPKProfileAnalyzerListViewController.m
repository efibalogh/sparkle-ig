#import "SPKStrings.h"
#import "SPKProfileAnalyzerListViewController.h"
#import "../../../AssetUtils.h"
#import "../../../Networking/SPKInstagramAPI.h"
#import "../../../Shared/Avatars/SPKAvatarCache.h"
#import "../../../Shared/UI/SPKFollowButton.h"
#import "../../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../../Shared/UI/SPKMediaChrome.h"
#import "../../../Utils.h"
#import "../../../Shared/Avatars/SPKAvatarView.h"
#import "../../../Shared/UI/SPKNotificationCenter.h"

// IG throttles /friendships/ — batch follow-state lookups (50/request) with a
// short cushion stays inside the limit.
static const NSInteger kSPKPABatchCap = 50;
static const NSTimeInterval kSPKPAFriendshipTTL = 10 * 60;
static CGFloat const kSPKPAAvatarSize = 52.0;

typedef NS_ENUM(NSInteger, SPKPASortMode) {
    SPKPASortModeDefault,
    SPKPASortModeAZ,
    SPKPASortModeZA,
    SPKPASortModeRecent,      // visited only
    SPKPASortModeMostVisited, // visited only
};

#pragma mark - Follow-state memory cache (process-wide, TTL'd)

@interface SPKPAFollowCache : NSObject
/// Boxed SPKFollowButtonState, or nil when unknown or expired.
+ (NSNumber *)stateForPK:(NSString *)pk;
+ (void)setState:(SPKFollowButtonState)state forPK:(NSString *)pk;
@end

@implementation SPKPAFollowCache
+ (NSMutableDictionary *)store {
    static NSMutableDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [NSMutableDictionary dictionary];
    });
    return m;
}
+ (NSNumber *)stateForPK:(NSString *)pk {
    if (!pk.length)
        return nil;
    NSDictionary *e = [self store][pk];
    if (!e)
        return nil;
    if (-[e[@"ts"] timeIntervalSinceNow] > kSPKPAFriendshipTTL) {
        [[self store] removeObjectForKey:pk];
        return nil;
    }
    return e[@"state"];
}
+ (void)setState:(SPKFollowButtonState)state forPK:(NSString *)pk {
    if (!pk.length)
        return;
    [self store][pk] = @{@"state" : @(state), @"ts" : [NSDate date]};
}
@end

#pragma mark - Cell

@interface SPKPAUserCell : UITableViewCell
@property (nonatomic, strong) SPKAvatarView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIImageView *verifiedBadge;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIControl *actionButton;
@property (nonatomic, strong) NSLayoutConstraint *nameTrailingToButton;
@property (nonatomic, strong) NSLayoutConstraint *nameTrailingToEdge;
@property (nonatomic, strong) NSLayoutConstraint *nameTopConstraint;    // active when a subtitle is shown
@property (nonatomic, strong) NSLayoutConstraint *nameCenterConstraint; // active when the name stands alone
@property (nonatomic, copy) NSString *boundPK;
@property (nonatomic, copy) void (^onActionTap)(SPKPAUserCell *);
@end

@implementation SPKPAUserCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return self;
    self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.selectedBackgroundView = [UIView new];
    self.selectedBackgroundView.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];

    _avatarView = [[SPKAvatarView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_avatarView];

    _usernameLabel = [UILabel new];
    _usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _usernameLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    _usernameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [_usernameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _verifiedBadge = [UIImageView new];
    _verifiedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _verifiedBadge.contentMode = UIViewContentModeScaleAspectFit;
    _verifiedBadge.image = [SPKAssetUtils instagramIconNamed:@"verified" pointSize:13.0];
    _verifiedBadge.hidden = YES;
    [_verifiedBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _usernameLabel, _verifiedBadge ]];
    nameRow.translatesAutoresizingMaskIntoConstraints = NO;
    nameRow.axis = UILayoutConstraintAxisHorizontal;
    nameRow.alignment = UIStackViewAlignmentCenter;
    nameRow.spacing = 4.0;
    [self.contentView addSubview:nameRow];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _subtitleLabel.numberOfLines = 1;
    [self.contentView addSubview:_subtitleLabel];

    _actionButton = [SPKFollowButton button];
    _actionButton.hidden = YES;
    [_actionButton addTarget:self action:@selector(onAction) forControlEvents:UIControlEventTouchUpInside];
    [_actionButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_actionButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_actionButton];

    _nameTrailingToButton = [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor constant:-10.0];
    _nameTrailingToEdge = [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0];
    _nameTopConstraint = [nameRow.topAnchor constraintEqualToAnchor:_avatarView.topAnchor constant:4.0];
    _nameCenterConstraint = [nameRow.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                  constant:16.0],
        [_avatarView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:kSPKPAAvatarSize],
        [_avatarView.heightAnchor constraintEqualToConstant:kSPKPAAvatarSize],

        [nameRow.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor
                                              constant:12.0],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:nameRow.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:nameRow.bottomAnchor
                                                 constant:3.0],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor
                                                                constant:-10.0],

        [_actionButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                     constant:-16.0],
        [_actionButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
    _nameTrailingToButton.active = YES;
    _nameTopConstraint.active = YES;
    return self;
}

- (void)setActionButtonVisible:(BOOL)visible {
    self.actionButton.hidden = !visible;
    self.nameTrailingToButton.active = visible;
    self.nameTrailingToEdge.active = !visible;
}

// With no subtitle, drop the top-alignment and vertically center the username
// so it doesn't sit high with empty space beneath it.
- (void)setSubtitleShown:(BOOL)shown {
    self.subtitleLabel.hidden = !shown;
    self.nameCenterConstraint.active = !shown;
    self.nameTopConstraint.active = shown;
}

- (void)onAction {
    if (self.onActionTap)
        self.onActionTap(self);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.avatarView prepareForReuse];
    self.boundPK = nil;
    self.verifiedBadge.hidden = YES;
    self.onActionTap = nil;
    [SPKFollowButton setLoading:NO forButton:self.actionButton];
    self.actionButton.hidden = YES;
    self.subtitleLabel.hidden = NO;
    self.nameCenterConstraint.active = NO;
    self.nameTopConstraint.active = YES;
}

@end

#pragma mark - Grouped section

// A titled group of rows (users or profile-change objects) for the Latest /
// Previous split. Only used when `grouped` is set.
@interface SPKPAListSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *items; // users or profile-changes, per kind
@end
@implementation SPKPAListSection
@end

#pragma mark - List VC

@interface SPKProfileAnalyzerListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, assign) SPKPAListKind kind;
@property (nonatomic, assign) BOOL grouped;
@property (nonatomic, copy) NSArray<SPKPAListSection *> *baseSections;  // unfiltered
@property (nonatomic, copy) NSArray<SPKPAListSection *> *shownSections; // filtered + sorted
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerUser *> *allUsers;
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerProfileChange *> *allUpdates;
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerVisit *> *allVisits;

@property (nonatomic, copy) NSArray<SPKProfileAnalyzerUser *> *shownUsers;
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerProfileChange *> *shownUpdates;
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerVisit *> *shownVisits;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyStateIcon;
@property (nonatomic, strong) UILabel *emptyStateTitle;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;
@property (nonatomic, assign) SPKPASortMode sortMode;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) NSMutableSet<NSString *> *requestedFollowPKs;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingFollowPKs;
@property (nonatomic, assign) BOOL followFlushScheduled;
@end

@implementation SPKProfileAnalyzerListViewController

- (instancetype)initWithTitle:(NSString *)title users:(NSArray<SPKProfileAnalyzerUser *> *)users kind:(SPKPAListKind)kind {
    if ((self = [super init])) {
        self.title = title;
        _kind = kind;
        _allUsers = [users copy] ?: @[];
        _sortMode = SPKPASortModeDefault;
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title profileUpdates:(NSArray<SPKProfileAnalyzerProfileChange *> *)updates {
    if ((self = [super init])) {
        self.title = title;
        _kind = SPKPAListKindProfileUpdate;
        _allUpdates = [updates copy] ?: @[];
        _sortMode = SPKPASortModeDefault;
    }
    return self;
}

- (NSArray<SPKPAListSection *> *)sectionsFromLatest:(NSArray *)latest previous:(NSArray *)previous {
    NSMutableArray<SPKPAListSection *> *out = [NSMutableArray array];
    if (latest.count) {
        SPKPAListSection *s = [SPKPAListSection new];
        s.title = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_LATEST_TEXT");
        s.items = latest;
        [out addObject:s];
    }
    if (previous.count) {
        SPKPAListSection *s = [SPKPAListSection new];
        s.title = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_PREVIOUS_TEXT");
        s.items = previous;
        [out addObject:s];
    }
    return out;
}

- (instancetype)initWithTitle:(NSString *)title
                  latestUsers:(NSArray<SPKProfileAnalyzerUser *> *)latestUsers
                previousUsers:(NSArray<SPKProfileAnalyzerUser *> *)previousUsers
                         kind:(SPKPAListKind)kind {
    if ((self = [super init])) {
        self.title = title;
        _kind = kind;
        _grouped = YES;
        _baseSections = [self sectionsFromLatest:(latestUsers ?: @[]) previous:(previousUsers ?: @[])];
        _sortMode = SPKPASortModeDefault;
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title
         latestProfileUpdates:(NSArray<SPKProfileAnalyzerProfileChange *> *)latestUpdates
       previousProfileUpdates:(NSArray<SPKProfileAnalyzerProfileChange *> *)previousUpdates {
    if ((self = [super init])) {
        self.title = title;
        _kind = SPKPAListKindProfileUpdate;
        _grouped = YES;
        _baseSections = [self sectionsFromLatest:(latestUpdates ?: @[]) previous:(previousUpdates ?: @[])];
        _sortMode = SPKPASortModeDefault;
    }
    return self;
}

- (instancetype)initVisitedListWithTitle:(NSString *)title visits:(NSArray<SPKProfileAnalyzerVisit *> *)visits {
    if ((self = [super init])) {
        self.title = title;
        _kind = SPKPAListKindVisited;
        _allVisits = [visits copy] ?: @[];
        _sortMode = SPKPASortModeRecent;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.requestedFollowPKs = [NSMutableSet set];
    self.pendingFollowPKs = [NSMutableSet set];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 80.0, 0.0, 0.0);
    self.tableView.rowHeight = 72.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[SPKPAUserCell class] forCellReuseIdentifier:@"u"];
    [self.view addSubview:self.tableView];

    [self setupEmptyState];

    if (self.kind != SPKPAListKindProfileUpdate) {
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT");
        [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                                 forSearchBarIcon:UISearchBarIconSearch
                                            state:UIControlStateNormal];
        self.navigationItem.searchController = self.searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
        [self installSortItem];
    }

    [self applyFilterAndSort];
}

- (void)setupEmptyState {
    self.emptyStateView = [UIView new];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyStateIcon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"promote_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate]];
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

#pragma mark - Sort

- (void)installSortItem {
    UIBarButtonItem *sortItem = SPKMediaChromeTopBarMenuButtonItem(@"sort", [self sortMenu], SPKL(@"MENU_SORT"));
    UIBarButtonItem *moreItem = SPKMediaChromeTopBarMenuButtonItem(@"more", [self moreMenu], SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT"));
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ sortItem, moreItem ]);
}

- (UIMenu *)moreMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *refreshAvatars = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_REFRESH_PROFILE_PICTURES")
                                                   image:[SPKAssetUtils menuIconNamed:@"user_circle"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
                                                     [[SPKAvatarCache shared] purge];
                                                     [weakSelf.tableView reloadData];
                                                 }];

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObject:refreshAvatars];

    // Visited history is the only mutable-in-bulk list; offer a destructive clear.
    if (self.kind == SPKPAListKindVisited) {
        UIAction *clearHistory = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_HISTORY")
                                                     image:[SPKAssetUtils menuIconNamed:@"trash"]
                                                identifier:nil
                                                   handler:^(__unused UIAction *action) {
                                                       [weakSelf confirmClearHistory];
                                                   }];
        clearHistory.attributes = UIMenuElementAttributesDestructive;
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ clearHistory ]]];
    }

    return [UIMenu menuWithTitle:@"" children:children];
}

- (void)confirmClearHistory {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_CLEAR_VISITED_HISTORY_TEXT")
                                                message:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_REMOVES_EVERY_PROFILE_VISITED_HISTORY_CANNOT_UNDONE_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_HISTORY")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  typeof(self) strongSelf = weakSelf;
                                                                                  if (!strongSelf)
                                                                                      return;
                                                                                  if (strongSelf.onClearHistory)
                                                                                      strongSelf.onClearHistory();
                                                                                  strongSelf.allVisits = @[];
                                                                                  [strongSelf applyFilterAndSort];
                                                                                  SPKNotify(kSPKNotificationProfileAnalyzerClear, SPKL(@"PROFILE_PROFILE_ANALYZER_VISITED_HISTORY_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (UIMenu *)sortMenu {
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion([weakSelf sortMenuElements]);
    }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

- (NSArray<UIMenuElement *> *)sortMenuElements {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    void (^add)(NSString *, SPKPASortMode) = ^(NSString *titleStr, SPKPASortMode mode) {
        UIAction *a = [UIAction actionWithTitle:titleStr
                                          image:nil
                                     identifier:nil
                                        handler:^(__unused UIAction *action) {
                                            weakSelf.sortMode = mode;
                                            [weakSelf applyFilterAndSort];
                                        }];
        if (weakSelf.sortMode == mode)
            a.state = UIMenuElementStateOn;
        [actions addObject:a];
    };
    if (self.kind == SPKPAListKindVisited) {
        add(SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_MOST_RECENT_TEXT"), SPKPASortModeRecent);
        add(SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_MOST_VISITED_TEXT"), SPKPASortModeMostVisited);
        add(@"A–Z", SPKPASortModeAZ);
        add(@"Z–A", SPKPASortModeZA);
    } else {
        add(SPKL(@"MENU_DEFAULT"), SPKPASortModeDefault);
        add(@"A–Z", SPKPASortModeAZ);
        add(@"Z–A", SPKPASortModeZA);
    }
    return @[ [UIMenu menuWithTitle:SPKL(@"MENU_SORT") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions] ];
}

#pragma mark - Filter + sort

- (NSString *)haystackForUser:(SPKProfileAnalyzerUser *)u {
    return [NSString stringWithFormat:@"%@ %@", u.username ?: @"", u.fullName ?: @""].lowercaseString;
}

- (NSArray *)sortUsers:(NSArray<SPKProfileAnalyzerUser *> *)users {
    if (self.sortMode == SPKPASortModeAZ) {
        return [users sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerUser *a, SPKProfileAnalyzerUser *b) {
            return [(a.username ?: @"") caseInsensitiveCompare:(b.username ?: @"")];
        }];
    }
    if (self.sortMode == SPKPASortModeZA) {
        return [users sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerUser *a, SPKProfileAnalyzerUser *b) {
            return [(b.username ?: @"") caseInsensitiveCompare:(a.username ?: @"")];
        }];
    }
    return users;
}

- (NSArray *)sortVisits:(NSArray<SPKProfileAnalyzerVisit *> *)visits {
    switch (self.sortMode) {
    case SPKPASortModeMostVisited:
        return [visits sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerVisit *a, SPKProfileAnalyzerVisit *b) {
            if (a.visitCount != b.visitCount)
                return a.visitCount > b.visitCount ? NSOrderedAscending : NSOrderedDescending;
            return [b.lastSeen compare:a.lastSeen];
        }];
    case SPKPASortModeAZ:
        return [visits sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerVisit *a, SPKProfileAnalyzerVisit *b) {
            return [(a.user.username ?: @"") caseInsensitiveCompare:(b.user.username ?: @"")];
        }];
    case SPKPASortModeZA:
        return [visits sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerVisit *a, SPKProfileAnalyzerVisit *b) {
            return [(b.user.username ?: @"") caseInsensitiveCompare:(a.user.username ?: @"")];
        }];
    default:
        return [visits sortedArrayUsingComparator:^NSComparisonResult(SPKProfileAnalyzerVisit *a, SPKProfileAnalyzerVisit *b) {
            return [b.lastSeen compare:a.lastSeen];
        }];
    }
}

- (void)applyFilterAndSort {
    NSString *q = self.searchText.lowercaseString;
    BOOL hasQuery = q.length > 0;

    if (self.grouped) {
        NSMutableArray<SPKPAListSection *> *shown = [NSMutableArray array];
        for (SPKPAListSection *base in self.baseSections) {
            NSArray *items = base.items;
            if (hasQuery) {
                NSMutableArray *out = [NSMutableArray array];
                for (id item in items) {
                    SPKProfileAnalyzerUser *u = [self userForItem:item];
                    if (u && [[self haystackForUser:u] containsString:q])
                        [out addObject:item];
                }
                items = out;
            }
            // Sort only user lists; profile-update groups stay in chronological order.
            if (self.kind != SPKPAListKindProfileUpdate)
                items = [self sortUsers:items];
            if (items.count) {
                SPKPAListSection *s = [SPKPAListSection new];
                s.title = base.title;
                s.items = items;
                [shown addObject:s];
            }
        }
        self.shownSections = shown;
        [self.tableView reloadData];
        [self updateEmptyState];
        return;
    }

    if (self.kind == SPKPAListKindProfileUpdate) {
        self.shownUpdates = self.allUpdates;
    } else if (self.kind == SPKPAListKindVisited) {
        NSArray *visits = self.allVisits;
        if (hasQuery) {
            NSMutableArray *out = [NSMutableArray array];
            for (SPKProfileAnalyzerVisit *v in visits)
                if ([[self haystackForUser:v.user] containsString:q])
                    [out addObject:v];
            visits = out;
        }
        self.shownVisits = [self sortVisits:visits];
    } else {
        NSArray *users = self.allUsers;
        if (hasQuery) {
            NSMutableArray *out = [NSMutableArray array];
            for (SPKProfileAnalyzerUser *u in users)
                if ([[self haystackForUser:u] containsString:q])
                    [out addObject:u];
            users = out;
        }
        self.shownUsers = [self sortUsers:users];
    }

    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    NSInteger count = 0;
    if (self.grouped) {
        for (SPKPAListSection *s in self.shownSections)
            count += s.items.count;
    } else {
        count = [self.tableView numberOfRowsInSection:0];
    }
    BOOL isEmpty = count == 0;
    self.emptyStateView.hidden = !isEmpty;
    self.tableView.hidden = isEmpty;
    if (!isEmpty)
        return;
    if (self.searchText.length) {
        self.emptyStateIcon.image = [SPKAssetUtils instagramIconNamed:@"promote_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_NO_MATCHES_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_NO_ACCOUNTS_MATCH_SEARCH_TEXT");
    } else {
        self.emptyStateIcon.image = [SPKAssetUtils instagramIconNamed:@"promote_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
        self.emptyStateTitle.text = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_NOTHING_HERE_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_THERE_NO_ACCOUNTS_LIST_TEXT");
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.searchText = searchController.searchBar.text;
    [self applyFilterAndSort];
}

#pragma mark - Helpers

static NSString *SPKPARelativeDate(NSDate *date) {
    if (!date)
        return @"";
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [SPKUtils spk_activeFormattingLocale];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterShortStyle;
        df.doesRelativeDateFormatting = YES;
    });
    return [df stringFromDate:date];
}

// Extracts the displayable user from a section item (a user, or a profile-change's current side).
- (SPKProfileAnalyzerUser *)userForItem:(id)item {
    if ([item isKindOfClass:[SPKProfileAnalyzerProfileChange class]])
        return ((SPKProfileAnalyzerProfileChange *)item).current;
    return [item isKindOfClass:[SPKProfileAnalyzerUser class]] ? item : nil;
}

- (id)itemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.shownSections.count)
        return nil;
    NSArray *items = self.shownSections[indexPath.section].items;
    return indexPath.row < (NSInteger)items.count ? items[indexPath.row] : nil;
}

- (SPKProfileAnalyzerProfileChange *)updateAtIndexPath:(NSIndexPath *)indexPath {
    if (self.grouped) {
        id item = [self itemAtIndexPath:indexPath];
        return [item isKindOfClass:[SPKProfileAnalyzerProfileChange class]] ? item : nil;
    }
    return indexPath.row < (NSInteger)self.shownUpdates.count ? self.shownUpdates[indexPath.row] : nil;
}

- (SPKProfileAnalyzerUser *)userAtIndexPath:(NSIndexPath *)indexPath {
    if (self.grouped)
        return [self userForItem:[self itemAtIndexPath:indexPath]];
    switch (self.kind) {
    case SPKPAListKindVisited:
        return indexPath.row < (NSInteger)self.shownVisits.count ? self.shownVisits[indexPath.row].user : nil;
    case SPKPAListKindProfileUpdate:
        return indexPath.row < (NSInteger)self.shownUpdates.count ? self.shownUpdates[indexPath.row].current : nil;
    default:
        return indexPath.row < (NSInteger)self.shownUsers.count ? self.shownUsers[indexPath.row] : nil;
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.grouped ? self.shownSections.count : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.grouped) {
        return section < (NSInteger)self.shownSections.count ? (NSInteger)self.shownSections[section].items.count : 0;
    }
    switch (self.kind) {
    case SPKPAListKindVisited:
        return self.shownVisits.count;
    case SPKPAListKindProfileUpdate:
        return self.shownUpdates.count;
    default:
        return self.shownUsers.count;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // Always label the groups — the same user can appear in both Latest and Previous.
    return (self.grouped && section < (NSInteger)self.shownSections.count) ? 34.0 : 0.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (!self.grouped || section >= (NSInteger)self.shownSections.count)
        return nil;
    SPKPAListSection *s = self.shownSections[section];

    UIView *container = [UIView new];
    container.backgroundColor = [UIColor clearColor];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    label.text = [NSString stringWithFormat:@"%@  ·  %lu", s.title, (unsigned long)s.items.count];
    [container addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                            constant:16.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor
                                           constant:-6.0],
    ]];
    return container;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKPAUserCell *cell = [tableView dequeueReusableCellWithIdentifier:@"u" forIndexPath:indexPath];

    SPKProfileAnalyzerUser *user = [self userAtIndexPath:indexPath];
    cell.boundPK = user.pk;
    cell.usernameLabel.text = user.username.length ? [@"@" stringByAppendingString:user.username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
    cell.verifiedBadge.hidden = !user.isVerified;

    if (self.kind == SPKPAListKindVisited && indexPath.row < (NSInteger)self.shownVisits.count) {
        SPKProfileAnalyzerVisit *v = self.shownVisits[indexPath.row];
        NSString *count = v.visitCount > 1 ? [NSString stringWithFormat:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_VALUE_VISITS_FORMAT"), (long)v.visitCount] : @"";
        // The localized count carries its own leading bullet with inconsistent
        // spacing across locales (and none before it), so strip it here and
        // rejoin with a single " • " separator.
        NSString *trimmedCount = [count stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmedCount hasPrefix:@"•"] || [trimmedCount hasPrefix:@"·"]) {
            trimmedCount = [[trimmedCount substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        NSString *dateString = SPKPARelativeDate(v.lastSeen);
        cell.subtitleLabel.text = trimmedCount.length ? [NSString stringWithFormat:@"%@ • %@", dateString, trimmedCount] : dateString;
    } else if (self.kind == SPKPAListKindProfileUpdate) {
        SPKProfileAnalyzerProfileChange *ch = [self updateAtIndexPath:indexPath];
        cell.subtitleLabel.text = ch ? [self changeSummaryForUpdate:ch] : @"";
    } else {
        cell.subtitleLabel.text = user.fullName.length ? user.fullName : @"";
    }
    [cell setSubtitleShown:cell.subtitleLabel.text.length > 0];

    BOOL wantsButton = (self.kind == SPKPAListKindFollow || self.kind == SPKPAListKindUnfollow);
    [cell setActionButtonVisible:wantsButton];
    if (wantsButton) {
        // Until the batched lookup lands, assume the relationship the list itself
        // implies: an unfollow list is people you follow.
        SPKFollowButtonState state = (self.kind == SPKPAListKindUnfollow) ? SPKFollowButtonStateFollowing
                                                                         : SPKFollowButtonStateNotFollowing;
        NSNumber *cached = [SPKPAFollowCache stateForPK:user.pk];
        if (cached)
            state = (SPKFollowButtonState)cached.integerValue;
        [self styleButton:cell.actionButton state:state];
        __weak typeof(self) weakSelf = self;
        cell.onActionTap = ^(SPKPAUserCell *c) {
            [weakSelf toggleFollowForCell:c];
        };
    }

    [cell.avatarView configureWithPK:user.pk urlString:user.profilePicURL];
    return cell;
}

- (NSString *)changeSummaryForUpdate:(SPKProfileAnalyzerProfileChange *)ch {
    NSMutableArray *parts = [NSMutableArray array];
    if (ch.usernameChanged)
        [parts addObject:[NSString stringWithFormat:@"@%@ → @%@", ch.previous.username ?: @"", ch.current.username ?: @""]];
    if (ch.fullNameChanged)
        [parts addObject:[NSString stringWithFormat:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_NAME_VALUE_VALUE_FORMAT"), ch.previous.fullName ?: @"—", ch.current.fullName ?: @"—"]];
    if (ch.profilePicChanged)
        [parts addObject:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_CHANGED_PROFILE_PICTURE_TEXT")];
    return [parts componentsJoinedByString:@"  •  "];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKProfileAnalyzerUser *user = [self userAtIndexPath:indexPath];
    // Pass the pk we already hold: a username-only open has to resolve it over
    // the network first, and nothing appears on screen until that lands.
    if (user.pk.length || user.username.length)
        [SPKUtils openInstagramProfileForUser:nil pk:user.pk username:user.username fromViewController:self];
}

#pragma mark - Live follow-state resolution (batched)

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.kind != SPKPAListKindFollow && self.kind != SPKPAListKindUnfollow)
        return;
    SPKProfileAnalyzerUser *user = [self userAtIndexPath:indexPath];
    NSString *pk = user.pk;
    if (!pk.length)
        return;
    if ([SPKPAFollowCache stateForPK:pk])
        return;
    if ([self.requestedFollowPKs containsObject:pk])
        return;
    [self.requestedFollowPKs addObject:pk];
    [self.pendingFollowPKs addObject:pk];
    [self scheduleFollowBatchFlush];
}

- (void)scheduleFollowBatchFlush {
    if (self.followFlushScheduled)
        return;
    self.followFlushScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakSelf.followFlushScheduled = NO;
        [weakSelf flushFollowBatch];
    });
}

- (void)flushFollowBatch {
    if (!self.pendingFollowPKs.count)
        return;
    NSArray *batch = [self.pendingFollowPKs.allObjects subarrayWithRange:NSMakeRange(0, MIN(kSPKPABatchCap, self.pendingFollowPKs.count))];
    [self.pendingFollowPKs minusSet:[NSSet setWithArray:batch]];

    __weak typeof(self) weakSelf = self;
    [SPKInstagramAPI fetchFriendshipStatusesForPKs:batch
                                        completion:^(NSDictionary *statuses, NSError *error) {
                                            if (!error && statuses.count) {
                                                for (NSString *pk in statuses) {
                                                    id s = statuses[pk];
                                                    if ([s isKindOfClass:[NSDictionary class]])
                                                        [SPKPAFollowCache setState:[SPKFollowButton stateForFriendshipStatus:s] forPK:pk];
                                                }
                                                [weakSelf refreshVisibleFollowButtons];
                                            }
                                            if (weakSelf.pendingFollowPKs.count)
                                                [weakSelf scheduleFollowBatchFlush];
                                        }];
}

- (void)refreshVisibleFollowButtons {
    for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
        SPKPAUserCell *cell = (SPKPAUserCell *)[self.tableView cellForRowAtIndexPath:ip];
        if (![cell isKindOfClass:[SPKPAUserCell class]])
            continue;
        NSNumber *cached = [SPKPAFollowCache stateForPK:cell.boundPK];
        if (cached && !cell.actionButton.hidden)
            [self styleButton:cell.actionButton state:(SPKFollowButtonState)cached.integerValue];
    }
}

#pragma mark - Swipe to delete (visited list, and change lists with an owner)

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    void (^removal)(void) = nil;
    __weak typeof(self) weakSelf = self;

    if (self.kind == SPKPAListKindVisited) {
        if (indexPath.row >= (NSInteger)self.shownVisits.count)
            return nil;
        SPKProfileAnalyzerVisit *visit = self.shownVisits[indexPath.row];
        removal = ^{
            [weakSelf removeVisit:visit];
        };
    } else if (self.onRemoveEntry) {
        id item = [self entryAtIndexPath:indexPath];
        if (!item)
            return nil;
        removal = ^{
            [weakSelf removeEntry:item];
        };
    }

    if (!removal)
        return nil;

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:nil
                                                                    handler:^(UIContextualAction *action, UIView *sourceView, void (^done)(BOOL)) {
                                                                        removal();
                                                                        done(YES);
                                                                    }];
    del.image = [SPKAssetUtils menuIconNamed:@"trash"];
    del.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    del.accessibilityLabel = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_REMOVE_TEXT");
    return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

- (void)removeVisit:(SPKProfileAnalyzerVisit *)visit {
    NSMutableArray *all = [self.allVisits mutableCopy];
    [all removeObject:visit];
    self.allVisits = all;
    if (self.onRemoveVisit)
        self.onRemoveVisit(visit);
    [self applyFilterAndSort];
}

// The row's underlying item, whichever list shape we are in. Grouped lists keep it in a
// section; flat ones in the per-kind array.
- (id)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (self.grouped)
        return [self itemAtIndexPath:indexPath];
    if (self.kind == SPKPAListKindProfileUpdate)
        return indexPath.row < (NSInteger)self.shownUpdates.count ? self.shownUpdates[indexPath.row] : nil;
    return indexPath.row < (NSInteger)self.shownUsers.count ? self.shownUsers[indexPath.row] : nil;
}

// Drop the item locally, then let the owner persist it. Removal is by pointer identity
// (`indexOfObjectIdenticalTo:`) rather than equality: neither model class implements
// -isEqual:, and two entries for the same account are legitimately distinct rows.
- (void)removeEntry:(id)item {
    if (!item)
        return;

    if (self.grouped) {
        NSMutableArray<SPKPAListSection *> *sections = [NSMutableArray array];
        for (SPKPAListSection *base in self.baseSections) {
            NSUInteger idx = [base.items indexOfObjectIdenticalTo:item];
            if (idx == NSNotFound) {
                [sections addObject:base];
                continue;
            }
            NSMutableArray *items = [base.items mutableCopy];
            [items removeObjectAtIndex:idx];
            if (!items.count)
                continue; // an emptied group loses its header too
            SPKPAListSection *s = [SPKPAListSection new];
            s.title = base.title;
            s.items = items;
            [sections addObject:s];
        }
        self.baseSections = sections;
    } else if (self.kind == SPKPAListKindProfileUpdate) {
        NSMutableArray *all = [self.allUpdates mutableCopy];
        NSUInteger idx = [all indexOfObjectIdenticalTo:item];
        if (idx != NSNotFound)
            [all removeObjectAtIndex:idx];
        self.allUpdates = all;
    } else {
        NSMutableArray *all = [self.allUsers mutableCopy];
        NSUInteger idx = [all indexOfObjectIdenticalTo:item];
        if (idx != NSNotFound)
            [all removeObjectAtIndex:idx];
        self.allUsers = all;
    }

    if (self.onRemoveEntry)
        self.onRemoveEntry(item);
    [self applyFilterAndSort];
}

#pragma mark - Follow / unfollow

- (void)styleButton:(UIControl *)button state:(SPKFollowButtonState)state {
    [SPKFollowButton applyState:state toButton:button];
}

- (void)toggleFollowForCell:(SPKPAUserCell *)cell {
    NSString *pk = cell.boundPK;
    if (!pk.length)
        return;

    NSNumber *cached = [SPKPAFollowCache stateForPK:pk];
    SPKFollowButtonState currentState = cached ? (SPKFollowButtonState)cached.integerValue
                                               : (self.kind == SPKPAListKindUnfollow ? SPKFollowButtonStateFollowing
                                                                                     : SPKFollowButtonStateNotFollowing);
    BOOL unfollowing = [SPKFollowButton tapUnfollowsFromState:currentState];

    [SPKFollowButton setLoading:YES forButton:cell.actionButton];

    void (^finish)(SPKFollowButtonState) = ^(SPKFollowButtonState newState) {
        [SPKPAFollowCache setState:newState forPK:pk];
        // The cell may have been recycled onto another user mid-request; its new
        // row is already configured, so leave the control to it.
        if (![cell.boundPK isEqualToString:pk])
            return;
        [SPKFollowButton setLoading:NO forButton:cell.actionButton];
        [self styleButton:cell.actionButton state:newState];
    };

    // Following a private account yields a pending request rather than a follow,
    // so prefer the status Instagram reports back over the one we asked for.
    SPKAPICompletion done = ^(NSDictionary *resp, NSError *error) {
        if (error) {
            finish(currentState);
            return;
        }
        NSDictionary *reported = resp[@"friendship_status"];
        if ([reported isKindOfClass:[NSDictionary class]]) {
            finish([SPKFollowButton stateForFriendshipStatus:reported]);
            return;
        }
        finish(unfollowing ? SPKFollowButtonStateNotFollowing : SPKFollowButtonStateFollowing);
    };

    if (unfollowing)
        [SPKInstagramAPI unfollowUserPK:pk completion:done];
    else
        [SPKInstagramAPI followUserPK:pk completion:done];
}

@end
