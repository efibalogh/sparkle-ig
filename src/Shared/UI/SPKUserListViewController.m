#import "SPKUserListViewController.h"
#import "SPKStrings.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Avatars/SPKAvatarView.h"
#import "SPKIGAlertPresenter.h"
#import "SPKMediaChrome.h"

static CGFloat const kSPKUserListAvatarSize = 52.0;

typedef NS_ENUM(NSInteger, SPKUserListSortMode) {
    SPKUserListSortModeDefault,
    SPKUserListSortModeAZ,
    SPKUserListSortModeZA,
};

@implementation SPKUserListItem
@end

#pragma mark - Cell

@interface SPKUserListCell : UITableViewCell
@property (nonatomic, strong) SPKAvatarView *avatarView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *verifiedBadge;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) NSLayoutConstraint *nameTopConstraint;    // active with a subtitle
@property (nonatomic, strong) NSLayoutConstraint *nameCenterConstraint; // active when name stands alone
@end

@implementation SPKUserListCell

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

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _verifiedBadge = [UIImageView new];
    _verifiedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _verifiedBadge.contentMode = UIViewContentModeScaleAspectFit;
    _verifiedBadge.image = [SPKAssetUtils instagramIconNamed:@"verified" pointSize:13.0];
    _verifiedBadge.hidden = YES;
    [_verifiedBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _verifiedBadge ]];
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

    _nameTopConstraint = [nameRow.topAnchor constraintEqualToAnchor:_avatarView.topAnchor constant:4.0];
    _nameCenterConstraint = [nameRow.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [_avatarView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:kSPKUserListAvatarSize],
        [_avatarView.heightAnchor constraintEqualToConstant:kSPKUserListAvatarSize],

        [nameRow.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:12.0],
        [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:nameRow.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:nameRow.bottomAnchor constant:3.0],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
    ]];
    _nameTopConstraint.active = YES;
    return self;
}

// With no subtitle, vertically center the title instead of top-aligning it.
- (void)setSubtitleShown:(BOOL)shown {
    self.subtitleLabel.hidden = !shown;
    self.nameCenterConstraint.active = !shown;
    self.nameTopConstraint.active = shown;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.avatarView prepareForReuse];
    self.verifiedBadge.hidden = YES;
    self.subtitleLabel.hidden = NO;
    self.nameCenterConstraint.active = NO;
    self.nameTopConstraint.active = YES;
}

@end

#pragma mark - List VC

@interface SPKUserListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<SPKUserListItem *> *allItems;
@property (nonatomic, copy) NSArray<SPKUserListItem *> *shownItems;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyStateIcon;
@property (nonatomic, strong) UILabel *emptyStateTitle;
@property (nonatomic, strong) UILabel *emptyStateSubtitle;
@property (nonatomic, assign) SPKUserListSortMode sortMode;
@property (nonatomic, copy) NSString *searchText;
@end

@implementation SPKUserListViewController

- (instancetype)init {
    if ((self = [super init])) {
        _enablesSearch = YES;
        _enablesSort = YES;
        _allowsDelete = YES;
        _emptyTitle = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_NOTHING_HERE_TEXT");
        _emptySubtitle = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_THERE_NO_ACCOUNTS_LIST_TEXT");
        _sortMode = SPKUserListSortModeDefault;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 80.0, 0.0, 0.0);
    self.tableView.rowHeight = 72.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[SPKUserListCell class] forCellReuseIdentifier:@"u"];
    [self.view addSubview:self.tableView];

    [self setupEmptyState];

    if (self.enablesSearch) {
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT");
        [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                                 forSearchBarIcon:UISearchBarIconSearch
                                            state:UIControlStateNormal];
        self.navigationItem.searchController = self.searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
    }

    [self installBarButtons];
    [self reloadItems];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [SPKUtils updateScrollingForFittedContent:self.tableView];
}

#pragma mark - Bar buttons

- (void)installBarButtons {
    // Keep the toolbar to at most two items: a "+" for the primary add action,
    // and a single "•••" overflow that folds sort + "How It Works" together.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    if (self.showsAddButton)
        [items addObject:SPKMediaChromeTopBarButtonItemWithTint(@"plus", self, @selector(spk_addTapped), [SPKUtils SPKColor_InstagramPrimaryText], SPKL(@"ALERT_ACTION_ADD"))];
    // When the overflow folds nothing but sort, say so with the sort glyph: "•••"
    // promises more than the menu delivers. It only earns the dots once something
    // else ("How It Works") shares it.
    if (self.enablesSort || self.infoText.length) {
        BOOL sortOnly = (self.enablesSort && self.infoText.length == 0);
        [items addObject:SPKMediaChromeTopBarMenuButtonItem(sortOnly ? @"sort" : @"more",
                                                            [self moreMenu],
                                                            sortOnly ? SPKL(@"MENU_SORT") : SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT"))];
    }
    // A subclass's own buttons get their own bubble at the trailing edge.
    NSArray<UIBarButtonItem *> *extraItems = [self additionalTrailingBarItems] ?: @[];
    if (extraItems.count)
        SPKMediaChromeSetTrailingTopBarItemGroups(self.navigationItem, @[ items, extraItems ]);
    else if (items.count)
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, items);
}

- (UIMenu *)moreMenu {
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
        if (weakSelf.enablesSort)
            [children addObjectsFromArray:[weakSelf sortMenuElements]];
        if (weakSelf.infoText.length) {
            UIAction *info = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_HOW_WORKS")
                                                 image:[SPKAssetUtils menuIconNamed:@"info"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) {
                                                   [weakSelf spk_showInfo];
                                               }];
            [children addObject:info];
        }
        completion(children);
    }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

- (NSArray<UIMenuElement *> *)sortMenuElements {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    void (^add)(NSString *, SPKUserListSortMode) = ^(NSString *titleStr, SPKUserListSortMode mode) {
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
    add(SPKL(@"MENU_DEFAULT"), SPKUserListSortModeDefault);
    add(@"A–Z", SPKUserListSortModeAZ);
    add(@"Z–A", SPKUserListSortModeZA);
    return @[ [UIMenu menuWithTitle:SPKL(@"MENU_SORT") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions] ];
}

- (void)spk_showInfo {
    if (!self.infoText.length)
        return;
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"ALERT_ACTION_HOW_WORKS")
                                                message:self.infoText
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleCancel handler:nil] ]];
}

- (void)spk_addTapped {
    [self didTapAdd];
}

#pragma mark - Empty state

- (void)setupEmptyState {
    self.emptyStateView = [UIView new];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyStateIcon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:(self.emptyIconName ?: @"users_empty") pointSize:96.0 renderingMode:UIImageRenderingModeAlwaysTemplate]];
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
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30.0],
        [self.emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40.0],
        [self.emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-40.0],

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
    BOOL isEmpty = self.shownItems.count == 0;
    self.emptyStateView.hidden = !isEmpty;
    self.tableView.hidden = isEmpty;
    if (!isEmpty)
        return;
    if (self.searchText.length) {
        self.emptyStateTitle.text = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_NO_MATCHES_TEXT");
        self.emptyStateSubtitle.text = self.emptySearchSubtitle.length ? self.emptySearchSubtitle : SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_NO_ACCOUNTS_MATCH_SEARCH_TEXT");
    } else {
        self.emptyStateTitle.text = self.emptyTitle;
        self.emptyStateSubtitle.text = self.emptySubtitle;
    }
}

#pragma mark - Data

- (void)reloadItems {
    self.allItems = [self buildItems] ?: @[];
    [self applyFilterAndSort];
    [self listDidUpdateItemCount:self.allItems.count];
}

- (void)applyFilterAndSort {
    NSString *q = self.searchText.lowercaseString;
    NSArray<SPKUserListItem *> *items = self.allItems;
    if (q.length) {
        NSMutableArray *out = [NSMutableArray array];
        for (SPKUserListItem *item in items) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@", item.title ?: @"", item.subtitle ?: @""].lowercaseString;
            if ([hay containsString:q])
                [out addObject:item];
        }
        items = out;
    }
    items = [self sortItems:items];
    self.shownItems = items;
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (NSArray<SPKUserListItem *> *)sortItems:(NSArray<SPKUserListItem *> *)items {
    if (self.sortMode == SPKUserListSortModeAZ) {
        return [items sortedArrayUsingComparator:^NSComparisonResult(SPKUserListItem *a, SPKUserListItem *b) {
            return [(a.title ?: @"") caseInsensitiveCompare:(b.title ?: @"")];
        }];
    }
    if (self.sortMode == SPKUserListSortModeZA) {
        return [items sortedArrayUsingComparator:^NSComparisonResult(SPKUserListItem *a, SPKUserListItem *b) {
            return [(b.title ?: @"") caseInsensitiveCompare:(a.title ?: @"")];
        }];
    }
    return items;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.searchText = searchController.searchBar.text;
    [self applyFilterAndSort];
}

- (SPKUserListItem *)itemAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row < (NSInteger)self.shownItems.count ? self.shownItems[indexPath.row] : nil;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shownItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKUserListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"u" forIndexPath:indexPath];
    SPKUserListItem *item = [self itemAtIndexPath:indexPath];
    cell.titleLabel.text = item.title.length ? item.title : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_TEXT");
    cell.verifiedBadge.hidden = !item.isVerified;
    cell.subtitleLabel.text = item.subtitle ?: @"";
    [cell setSubtitleShown:item.subtitle.length > 0];
    [cell.avatarView configureWithPK:item.pk urlString:item.avatarURLString isGroup:item.isGroup];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKUserListItem *item = [self itemAtIndexPath:indexPath];
    if (item)
        [self didSelectItem:item];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.allowsDelete)
        return nil;
    SPKUserListItem *item = [self itemAtIndexPath:indexPath];
    if (!item)
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:nil
                                                                    handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^done)(BOOL)) {
                                                                        [weakSelf didDeleteItem:item];
                                                                        done(YES);
                                                                    }];
    del.image = [SPKAssetUtils menuIconNamed:@"trash"];
    del.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    del.accessibilityLabel = SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_REMOVE_TEXT");
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

#pragma mark - Subclass hooks (defaults)

- (NSArray<SPKUserListItem *> *)buildItems {
    return @[];
}

- (void)didSelectItem:(SPKUserListItem *)item {
    // Default: open the profile if the title is an @username.
    NSString *title = item.title;
    if ([title hasPrefix:@"@"])
        title = [title substringFromIndex:1];
    // The pk goes along for the ride whenever the item carries one: opening by
    // username alone costs a network round trip before anything is presented.
    if (item.pk.length || title.length)
        [SPKUtils openInstagramProfileForUser:nil pk:item.pk username:title fromViewController:self];
}

- (void)didDeleteItem:(SPKUserListItem *)item {
}

- (void)didTapAdd {
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
}

- (NSArray<UIBarButtonItem *> *)additionalTrailingBarItems {
    return @[];
}

@end
