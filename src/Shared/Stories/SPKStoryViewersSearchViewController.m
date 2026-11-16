#import "SPKStrings.h"
#import "SPKStoryViewersSearchViewController.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Avatars/SPKAvatarView.h"
#import "../UI/SPKMediaChrome.h"
#import "SPKStoryViewersFetcher.h"

static CGFloat const kSPKViewerAvatarSize = 52.0;
static NSString *const kSPKStarredStoryViewersKey = @"stories_starred_viewers";

typedef NS_ENUM(NSInteger, SPKViewerFilter) {
    SPKViewerFilterAll = 0,
    SPKViewerFilterFollowing,
    SPKViewerFilterNotFollowing,
    SPKViewerFilterDoesNotFollowYou,
    SPKViewerFilterStarred,
};

static UIImage *SPKViewerStarImage(BOOL filled, CGFloat pointSize) {
    return [SPKAssetUtils resolvedImageNamed:(filled ? @"star_filled" : @"star")
                          fallbackSystemName:(filled ? @"star.fill" : @"star")
                                   pointSize:pointSize
                                      weight:UIImageSymbolWeightRegular
                                      source:SPKResolvedImageSourceAutomatic
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Cell

@interface SPKStoryViewerCell : UITableViewCell
@property (nonatomic, strong) SPKAvatarView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIImageView *verifiedBadge;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *relationshipLabel;
@property (nonatomic, strong) UIButton *starButton;
@property (nonatomic, copy) void (^starToggleHandler)(void);
@end

@implementation SPKStoryViewerCell

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

    _relationshipLabel = [UILabel new];
    _relationshipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _relationshipLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    _relationshipLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _relationshipLabel.textAlignment = NSTextAlignmentRight;
    [_relationshipLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_relationshipLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_relationshipLabel];

    _starButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _starButton.translatesAutoresizingMaskIntoConstraints = NO;
    _starButton.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _starButton.accessibilityLabel = SPKL(@"STORIES_VIEWERS_STAR_VIEWER_ACCESSIBILITY_LABEL");
    [_starButton addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_starButton];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [_avatarView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:kSPKViewerAvatarSize],
        [_avatarView.heightAnchor constraintEqualToConstant:kSPKViewerAvatarSize],

        [nameRow.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:12.0],
        [nameRow.topAnchor constraintEqualToAnchor:_avatarView.topAnchor constant:4.0],
        [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:_relationshipLabel.leadingAnchor constant:-10.0],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:nameRow.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:nameRow.bottomAnchor constant:3.0],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_relationshipLabel.leadingAnchor constant:-10.0],

        [_relationshipLabel.trailingAnchor constraintEqualToAnchor:_starButton.leadingAnchor constant:-4.0],
        [_relationshipLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_starButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10.0],
        [_starButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_starButton.widthAnchor constraintEqualToConstant:44.0],
        [_starButton.heightAnchor constraintEqualToConstant:44.0],
    ]];
    return self;
}

- (void)starTapped {
    if (self.starToggleHandler)
        self.starToggleHandler();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.avatarView prepareForReuse];
    self.verifiedBadge.hidden = YES;
    self.relationshipLabel.text = nil;
    self.starToggleHandler = nil;
}

@end

#pragma mark - VC

@interface SPKStoryViewersSearchViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *mediaID;
@property (nonatomic, strong) SPKStoryViewersFetcher *fetcher;

@property (nonatomic, copy) NSArray<SPKStoryViewerModel *> *allViewers;
@property (nonatomic, copy) NSArray<SPKStoryViewerModel *> *shownViewers;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) BOOL loading;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIBarButtonItem *filterItem;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UILabel *countLabel;

@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel *loadingLabel;

@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyStateIcon;
@property (nonatomic, strong) UILabel *emptyStateTitle;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;

@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, assign) SPKViewerFilter filter;
@property (nonatomic, strong) NSMutableSet<NSString *> *starredViewerIdentifiers;
@end

@implementation SPKStoryViewersSearchViewController

- (instancetype)initWithMediaID:(NSString *)mediaID title:(NSString *)title {
    if ((self = [super init])) {
        _mediaID = [mediaID copy];
        self.title = title.length ? title : SPKL(@"STORIES_SEARCH_STORY_VIEWERS_STORY_VIEWERS_TEXT");
        _filter = SPKViewerFilterAll;
        NSArray *storedStars = SPKPreferenceObjectForKey(kSPKStarredStoryViewersKey);
        _starredViewerIdentifiers = [NSMutableSet setWithArray:[storedStars isKindOfClass:NSArray.class] ? storedStars : @[]];
    }
    return self;
}

+ (void)presentForMediaID:(NSString *)mediaID title:(NSString *)title {
    if (mediaID.length == 0)
        return;
    UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (root.presentedViewController)
        root = root.presentedViewController;
    SPKStoryViewersSearchViewController *vc = [[SPKStoryViewersSearchViewController alloc] initWithMediaID:mediaID title:title];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];

    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(closeTapped)) ]);
    self.filterItem = [[UIBarButtonItem alloc] initWithImage:SPKMediaChromeTopBarIcon(@"filter")
                                                       menu:[self buildFilterMenu]];
    self.filterItem.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [self updateFilterItem];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ self.filterItem ]);

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 80.0, 0.0, 0.0);
    self.tableView.rowHeight = 72.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[SPKStoryViewerCell class] forCellReuseIdentifier:@"v"];
    [self.view addSubview:self.tableView];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_SEARCH_VIEWERS_TEXT");
    [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                             forSearchBarIcon:UISearchBarIconSearch
                                        state:UIControlStateNormal];
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    [self buildTableHeader];
    [self setupLoadingOverlay];
    [self setupEmptyState];

    [self startFetch];
}

- (void)dealloc {
    [_fetcher cancel];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Filter

- (NSArray<NSString *> *)filterTitles {
    return @[ SPKL(@"STORIES_VIEWERS_FILTER_ALL_VIEWERS"), SPKL(@"STORIES_VIEWERS_FILTER_YOU_FOLLOW"), SPKL(@"STORIES_VIEWERS_FILTER_YOU_DONT_FOLLOW"), SPKL(@"STORIES_VIEWERS_FILTER_DOESNT_FOLLOW_YOU"), SPKL(@"STORIES_VIEWERS_FILTER_STARRED") ];
}

- (NSArray<NSString *> *)filterIcons {
    return @[ @"users", @"user_following", @"user_follow", @"user_unfollow", @"star" ];
}

- (UIAction *)filterActionAtIndex:(SPKViewerFilter)index {
    NSArray<NSString *> *titles = [self filterTitles];
    NSArray<NSString *> *icons = [self filterIcons];
    __weak typeof(self) weakSelf = self;
    UIAction *action = [UIAction actionWithTitle:titles[index]
                                           image:[SPKAssetUtils menuIconNamed:icons[index]]
                                      identifier:nil
                                         handler:^(__unused UIAction *selectedAction) {
                                             typeof(self) self = weakSelf;
                                             if (!self)
                                                 return;
                                             self.filter = index;
                                             [self updateFilterItem];
                                             [self applyFilter];
                                         }];
    action.state = self.filter == index ? UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

- (UIMenu *)buildFilterMenu {
    UIMenu *relationships = [UIMenu menuWithTitle:@""
                                            image:nil
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:@[
                                             [self filterActionAtIndex:SPKViewerFilterAll],
                                             [self filterActionAtIndex:SPKViewerFilterFollowing],
                                             [self filterActionAtIndex:SPKViewerFilterNotFollowing],
                                             [self filterActionAtIndex:SPKViewerFilterDoesNotFollowYou],
                                         ]];
    UIMenu *starred = [UIMenu menuWithTitle:@""
                                      image:nil
                                 identifier:nil
                                    options:UIMenuOptionsDisplayInline
                                   children:@[ [self filterActionAtIndex:SPKViewerFilterStarred] ]];
    return [UIMenu menuWithTitle:@"" children:@[ relationships, starred ]];
}

- (void)updateFilterItem {
    self.filterItem.menu = [self buildFilterMenu];
    NSString *selectedTitle = [self filterTitles][self.filter];
    self.filterItem.accessibilityLabel = [NSString stringWithFormat:SPKL(@"STORIES_VIEWERS_FILTER_ACCESSIBILITY_LABEL_FORMAT"), selectedTitle];
}

#pragma mark - Header (count)

- (void)buildTableHeader {
    self.headerContainer = [UIView new];
    self.headerContainer.backgroundColor = [SPKUtils SPKColor_InstagramBackground];

    self.countLabel = [UILabel new];
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    self.countLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    [self.headerContainer addSubview:self.countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.countLabel.topAnchor constraintEqualToAnchor:self.headerContainer.topAnchor constant:8.0],
        [self.countLabel.leadingAnchor constraintEqualToAnchor:self.headerContainer.leadingAnchor constant:16.0],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:self.headerContainer.trailingAnchor constant:-16.0],
        [self.countLabel.bottomAnchor constraintEqualToAnchor:self.headerContainer.bottomAnchor constant:-8.0],
    ]];
}

- (void)layoutTableHeader {
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 1)
        return;
    self.headerContainer.frame = CGRectMake(0, 0, w, 1);
    [self.headerContainer setNeedsLayout];
    [self.headerContainer layoutIfNeeded];
    CGFloat h = [self.headerContainer systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)
                                   withHorizontalFittingPriority:UILayoutPriorityRequired
                                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                    .height;
    CGRect target = CGRectMake(0, 0, w, h);
    if (!CGRectEqualToRect(self.headerContainer.frame, target) || self.tableView.tableHeaderView != self.headerContainer) {
        self.headerContainer.frame = target;
        self.tableView.tableHeaderView = self.headerContainer;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutTableHeader];
    [SPKUtils updateScrollingForFittedContent:self.tableView];
}

#pragma mark - Fetch

- (void)startFetch {
    self.loading = YES;
    [self updateLoadingUI];
    __weak typeof(self) weakSelf = self;
    self.fetcher = [SPKStoryViewersFetcher fetchAllViewersForMediaID:self.mediaID
        progress:^(NSInteger fetched) {
            typeof(self) self = weakSelf;
            if (!self)
                return;
            self.loadingLabel.text = [NSString stringWithFormat:SPKL(@"STORIES_STORY_VIEWERS_SEARCH_LOADING_VIEWERS_VALUE_FORMAT"), (long)fetched];
        }
        completion:^(NSArray<SPKStoryViewerModel *> *viewers, NSInteger totalCount, NSError *error) {
            typeof(self) self = weakSelf;
            if (!self)
                return;
            self.loading = NO;
            self.allViewers = viewers;
            self.totalCount = totalCount;
            [self updateLoadingUI];
            [self applyFilter];
            [self.view setNeedsLayout];
            if (error && viewers.count == 0) {
                self.emptyStateTitle.text = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_COULDN_T_LOAD_VIEWERS_TEXT");
                self.emptyStateSubtitle.text = error.localizedDescription ?: SPKL(@"STORIES_STORY_VIEWERS_SEARCH_PLEASE_TRY_AGAIN_TEXT");
            }
        }];
}

#pragma mark - Filter

- (void)applyFilter {
    NSString *q = self.searchText.lowercaseString;
    BOOL hasQuery = q.length > 0;
    NSMutableArray *out = [NSMutableArray array];
    for (SPKStoryViewerModel *v in self.allViewers) {
        switch (self.filter) {
        case SPKViewerFilterFollowing:
            if (!v.friendshipKnown || !v.following)
                continue;
            break;
        case SPKViewerFilterNotFollowing:
            if (!v.friendshipKnown || v.following)
                continue;
            break;
        case SPKViewerFilterDoesNotFollowYou:
            if (!v.friendshipKnown || v.followedBy)
                continue;
            break;
        case SPKViewerFilterStarred:
            if (![self isViewerStarred:v])
                continue;
            break;
        case SPKViewerFilterAll:
        default:
            break;
        }
        if (hasQuery) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@", v.username ?: @"", v.fullName ?: @""].lowercaseString;
            if (![hay containsString:q])
                continue;
        }
        [out addObject:v];
    }
    self.shownViewers = out;
    [self.tableView reloadData];
    [self updateCountLabel];
    [self updateEmptyState];
}

- (void)updateCountLabel {
    if (self.loading) {
        self.countLabel.text = @"";
        return;
    }
    NSInteger shown = self.shownViewers.count;
    NSInteger total = MAX(self.totalCount, (NSInteger)self.allViewers.count);
    if (self.searchText.length || self.filter != SPKViewerFilterAll) {
        self.countLabel.text = [NSString stringWithFormat:SPKL(@"STORIES_STORY_VIEWERS_SEARCH_VALUE_VALUE_VIEWERS_FORMAT"), (long)shown, (long)total];
    } else {
        self.countLabel.text = total == 1 ? SPKL(@"STORIES_STORY_VIEWERS_SEARCH_VIEWER_TEXT") : [NSString stringWithFormat:SPKL(@"STORIES_STORY_VIEWERS_SEARCH_VALUE_VIEWERS_FORMAT"), (long)total];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.searchText = searchController.searchBar.text;
    [self applyFilter];
}

#pragma mark - Loading overlay

- (void)setupLoadingOverlay {
    self.loadingOverlay = [UIView new];
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingOverlay.hidden = YES;
    [self.view addSubview:self.loadingOverlay];

    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.color = [SPKUtils SPKColor_InstagramSecondaryText];
    [self.loadingSpinner startAnimating];
    [self.loadingOverlay addSubview:self.loadingSpinner];

    self.loadingLabel = [UILabel new];
    self.loadingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    self.loadingLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    self.loadingLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingLabel.text = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_LOADING_VIEWERS_TEXT");
    [self.loadingOverlay addSubview:self.loadingLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.loadingOverlay.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingOverlay.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30.0],

        [self.loadingSpinner.topAnchor constraintEqualToAnchor:self.loadingOverlay.topAnchor],
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],

        [self.loadingLabel.topAnchor constraintEqualToAnchor:self.loadingSpinner.bottomAnchor constant:12.0],
        [self.loadingLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlay.leadingAnchor],
        [self.loadingLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlay.trailingAnchor],
        [self.loadingLabel.bottomAnchor constraintEqualToAnchor:self.loadingOverlay.bottomAnchor],
        [self.loadingOverlay.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40.0],
        [self.loadingOverlay.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-40.0],
    ]];
}

- (void)updateLoadingUI {
    self.loadingOverlay.hidden = !self.loading;
    if (self.loading) {
        [self.loadingSpinner startAnimating];
        self.tableView.hidden = YES;
    } else {
        [self.loadingSpinner stopAnimating];
        self.tableView.hidden = NO;
    }
}

#pragma mark - Empty state

- (void)setupEmptyState {
    self.emptyStateView = [UIView new];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyStateIcon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"users_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate]];
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
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20.0],
        [self.emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:40.0],
        [self.emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-40.0],

        [self.emptyStateIcon.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [self.emptyStateIcon.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyStateIcon.widthAnchor constraintEqualToConstant:96.0],
        [self.emptyStateIcon.heightAnchor constraintEqualToConstant:96.0],

        [self.emptyStateTitle.topAnchor constraintEqualToAnchor:self.emptyStateIcon.bottomAnchor constant:18.0],
        [self.emptyStateTitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyStateTitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [self.emptyStateSubtitle.topAnchor constraintEqualToAnchor:self.emptyStateTitle.bottomAnchor constant:6.0],
        [self.emptyStateSubtitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyStateSubtitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        [self.emptyStateSubtitle.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor],
    ]];
}

- (void)updateEmptyState {
    if (self.loading) {
        self.emptyStateView.hidden = YES;
        return;
    }
    BOOL isEmpty = self.shownViewers.count == 0;
    self.emptyStateView.hidden = !isEmpty;
    if (!isEmpty)
        return;
    // A load failure sets its own copy in the completion handler; don't clobber it.
    if ([self.emptyStateTitle.text isEqualToString:@"Couldn't load viewers"])
        return;
    self.emptyStateIcon.image = [SPKAssetUtils instagramIconNamed:@"users_empty" pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (self.searchText.length || self.filter != SPKViewerFilterAll) {
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_NO_MATCHES_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_NO_VIEWERS_MATCH_SEARCH_TEXT");
    } else {
        self.emptyStateTitle.text = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_NO_VIEWERS_YET_TEXT");
        self.emptyStateSubtitle.text = SPKL(@"STORIES_STORY_VIEWERS_SEARCH_NO_ONE_VIEWED_STORY_TEXT");
    }
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shownViewers.count;
}

- (NSString *)relationshipTextFor:(SPKStoryViewerModel *)v {
    if (!v.friendshipKnown)
        return nil;
    if (v.following && v.followedBy)
        return SPKL(@"STORIES_STORY_VIEWERS_SEARCH_MUTUAL_TEXT");
    if (v.following)
        return SPKL(@"MENU_FOLLOWING");
    if (v.followedBy)
        return SPKL(@"STORIES_STORY_VIEWERS_SEARCH_FOLLOWS_TEXT");
    return nil;
}

- (NSString *)starIdentifierForViewer:(SPKStoryViewerModel *)viewer {
    if (viewer.pk.length > 0)
        return [@"pk:" stringByAppendingString:viewer.pk];
    if (viewer.username.length > 0)
        return [@"username:" stringByAppendingString:viewer.username.lowercaseString];
    return nil;
}

- (BOOL)isViewerStarred:(SPKStoryViewerModel *)viewer {
    NSString *identifier = [self starIdentifierForViewer:viewer];
    return identifier.length > 0 && [self.starredViewerIdentifiers containsObject:identifier];
}

- (void)toggleStarForViewer:(SPKStoryViewerModel *)viewer {
    NSString *identifier = [self starIdentifierForViewer:viewer];
    if (identifier.length == 0)
        return;
    BOOL starred = [self.starredViewerIdentifiers containsObject:identifier];
    if (starred)
        [self.starredViewerIdentifiers removeObject:identifier];
    else
        [self.starredViewerIdentifiers addObject:identifier];
    SPKPreferenceSetObject([self.starredViewerIdentifiers.allObjects sortedArrayUsingSelector:@selector(compare:)], kSPKStarredStoryViewersKey);
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    [self applyFilter];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKStoryViewerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v" forIndexPath:indexPath];
    SPKStoryViewerModel *v = self.shownViewers[indexPath.row];
    cell.usernameLabel.text = v.username.length ? [@"@" stringByAppendingString:v.username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
    cell.subtitleLabel.text = v.fullName.length ? v.fullName : @"";
    cell.subtitleLabel.hidden = v.fullName.length == 0;
    cell.verifiedBadge.hidden = !v.isVerified;
    cell.relationshipLabel.text = [self relationshipTextFor:v];
    BOOL starred = [self isViewerStarred:v];
    [cell.starButton setImage:SPKViewerStarImage(starred, 20.0) forState:UIControlStateNormal];
    cell.starButton.tintColor = starred ? UIColor.systemYellowColor : [SPKUtils SPKColor_InstagramSecondaryText];
    cell.starButton.accessibilityLabel = starred ? SPKL(@"STORIES_VIEWERS_UNSTAR_VIEWER_ACCESSIBILITY_LABEL") : SPKL(@"STORIES_VIEWERS_STAR_VIEWER_ACCESSIBILITY_LABEL");
    __weak typeof(self) weakSelf = self;
    __weak SPKStoryViewerModel *weakViewer = v;
    cell.starToggleHandler = ^{
        [weakSelf toggleStarForViewer:weakViewer];
    };
    [cell.avatarView configureWithPK:v.pk urlString:v.profilePicURL];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKStoryViewerModel *v = self.shownViewers[indexPath.row];
    // The viewer list endpoint already gave us the pk; opening by username alone
    // would throw it away and resolve it again over the network.
    if (v.pk.length || v.username.length)
        [SPKUtils openInstagramProfileForUser:nil pk:v.pk username:v.username fromViewController:self];
}

@end
