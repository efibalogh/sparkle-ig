#import "SPKStrings.h"
#import "SPKProfileAnalyzerViewController.h"
#import "../../../AssetUtils.h"
#import "../../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../../Shared/UI/SPKMediaChrome.h"
#import "../../../Shared/UI/SPKNotificationCenter.h"
#import "../../../Shared/UI/SPKProgressPillButton.h"
#import "../../../Shared/UI/SPKSwitch.h"
#import "../../../Utils.h"
#import "../../../Shared/Avatars/SPKAvatarView.h"
#import "SPKProfileAnalyzerListViewController.h"
#import "SPKProfileAnalyzerModels.h"
#import "SPKProfileAnalyzerService.h"
#import "SPKProfileAnalyzerStorage.h"
#import "../../../App/SPKPerfMeter.h"

#pragma mark - Category descriptor

typedef NS_ENUM(NSInteger, SPKPACategory) {
    SPKPACategoryMutual,
    SPKPACategoryNotFollowingBack,
    SPKPACategoryDontFollowBack,
    SPKPACategoryNewFollowers,
    SPKPACategoryLostFollowers,
    SPKPACategoryYouStartedFollowing,
    SPKPACategoryYouUnfollowed,
    SPKPACategoryProfileUpdates,
};

@interface SPKPACategoryRow : NSObject
@property (nonatomic, assign) SPKPACategory category;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, assign) NSInteger unseenCount; // change rows: unseen "new" badge
@end
@implementation SPKPACategoryRow
@end

#pragma mark - Identity header

@interface SPKPAIdentityHeader : UIView
@property (nonatomic, strong) SPKAvatarView *avatarView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIStackView *statsRow;
@property (nonatomic, strong) SPKProgressPillButton *scanButton;
@end

@implementation SPKPAIdentityHeader

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return self;
    self.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    _avatarView = [[SPKAvatarView alloc] initWithFrame:CGRectZero];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_avatarView];

    _nameLabel = [UILabel new];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    _nameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_nameLabel];

    _usernameLabel = [UILabel new];
    _usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _usernameLabel.font = [UIFont systemFontOfSize:14.0];
    _usernameLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _usernameLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_usernameLabel];

    _statsRow = [[UIStackView alloc] init];
    _statsRow.translatesAutoresizingMaskIntoConstraints = NO;
    _statsRow.axis = UILayoutConstraintAxisHorizontal;
    _statsRow.distribution = UIStackViewDistributionFillEqually;
    _statsRow.alignment = UIStackViewAlignmentCenter;
    [self addSubview:_statsRow];

    _scanButton = [[SPKProgressPillButton alloc] initWithFrame:CGRectZero];
    _scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_scanButton];

    [NSLayoutConstraint activateConstraints:@[
        [_avatarView.topAnchor constraintEqualToAnchor:self.topAnchor
                                              constant:20.0],
        [_avatarView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:88.0],
        [_avatarView.heightAnchor constraintEqualToConstant:88.0],

        [_nameLabel.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor
                                             constant:10.0],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                 constant:16.0],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-16.0],

        [_usernameLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor
                                                 constant:2.0],
        [_usernameLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_usernameLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],

        [_statsRow.topAnchor constraintEqualToAnchor:_usernameLabel.bottomAnchor
                                            constant:16.0],
        [_statsRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                constant:24.0],
        [_statsRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                 constant:-24.0],
        [_statsRow.heightAnchor constraintEqualToConstant:44.0],

        [_scanButton.topAnchor constraintEqualToAnchor:_statsRow.bottomAnchor
                                              constant:16.0],
        [_scanButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:16.0],
        [_scanButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-16.0],
        [_scanButton.heightAnchor constraintEqualToConstant:48.0],
        [_scanButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                  constant:-20.0],
    ]];
    return self;
}

- (UIView *)statColumnValue:(NSString *)value caption:(NSString *)caption {
    UIStackView *col = [[UIStackView alloc] init];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentCenter;
    col.distribution = UIStackViewDistributionFill;
    col.spacing = 1.0;

    UILabel *v = [UILabel new];
    v.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    v.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    v.textAlignment = NSTextAlignmentCenter;
    v.text = value;
    [col addArrangedSubview:v];

    UILabel *c = [UILabel new];
    c.font = [UIFont systemFontOfSize:12.0];
    c.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    c.textAlignment = NSTextAlignmentCenter;
    c.text = caption;
    [col addArrangedSubview:c];

    return col;
}

- (void)setStatsPosts:(NSString *)posts followers:(NSString *)followers following:(NSString *)following {
    for (UIView *v in self.statsRow.arrangedSubviews) {
        [self.statsRow removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.statsRow addArrangedSubview:[self statColumnValue:posts caption:SPKL(@"PROFILE_PROFILE_ANALYZER_POSTS_TEXT")]];
    [self.statsRow addArrangedSubview:[self statColumnValue:followers caption:SPKL(@"PROFILE_PROFILE_ANALYZER_FOLLOWERS_TEXT")]];
    [self.statsRow addArrangedSubview:[self statColumnValue:following caption:SPKL(@"PROFILE_PROFILE_ANALYZER_FOLLOWING_TEXT")]];
}

@end

#pragma mark - Main VC

@interface SPKProfileAnalyzerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) SPKPAIdentityHeader *header;
@property (nonatomic, strong) SPKProfileAnalyzerReport *report;
@property (nonatomic, strong) NSArray<SPKProfileAnalyzerVisit *> *visits;
@property (nonatomic, copy) NSArray<SPKProfileAnalyzerChangeEvent *> *changeEvents; // durable change log, newest-first
@property (nonatomic, strong, nullable) NSDate *lastScanDate; // scan boundary: events at/after this belong to the most recent scan
@property (nonatomic, copy) NSArray<SPKPACategoryRow *> *currentRows;               // section: current snapshot
@property (nonatomic, copy) NSArray<SPKPACategoryRow *> *changeRows;                // section: accumulated changes
@property (nonatomic, copy) NSString *selfPK;
@property (nonatomic, assign) BOOL trackVisits;
@property (nonatomic, copy, nullable) NSString *scanDateText; // "Last scanned …", nil if never
@property (nonatomic, strong, nullable) NSTimer *buttonCycleTimer;
@property (nonatomic, assign) BOOL buttonShowingDate;
@end

@implementation SPKProfileAnalyzerViewController

+ (void)presentFromTop {
    UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (root.presentedViewController)
        root = root.presentedViewController;
    // Bring back an analyzer already on screen rather than stacking a second one.
    if ([SPKUtils revealViewControllerMatching:^BOOL(UIViewController *viewController) {
            return [viewController isKindOfClass:[SPKProfileAnalyzerViewController class]];
        }])
        return;
    SPKProfileAnalyzerViewController *analyzer = [SPKProfileAnalyzerViewController new];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:analyzer];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE");
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.selfPK = [SPKUtils currentUserPK];

    if (self.navigationController.viewControllers.firstObject == self) {
        SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(closeTapped)) ]);
    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.tableView.sectionHeaderTopPadding = 0;
    [self.view addSubview:self.tableView];

    [self buildTableHeader];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dataChanged:) name:SPKProfileAnalyzerDataDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(progressChanged:) name:SPKProfileAnalyzerProgressDidChangeNotification object:nil];

    [self loadCachedData];
    [self paintHeaderIdentity];
}

- (void)dealloc {
    [self stopButtonCycle];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Intentionally NOT cancelling the service — scans run in the background and
    // report completion via the notification pill.
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.trackVisits = [SPKUtils getBoolPref:@"profile_analyzer_track_visits"];
    [self loadCachedData];
    [self paintHeaderIdentity];
    [self syncRunningState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopButtonCycle]; // don't tick while off-screen (restarts on re-appear)
}

#pragma mark - Header

- (void)buildTableHeader {
    self.headerContainer = [UIView new];
    self.header = [[SPKPAIdentityHeader alloc] init];
    self.header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerContainer addSubview:self.header];
    [self.header.scanButton addTarget:self action:@selector(scanTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.header.scanButton setText:SPKL(@"PROFILE_PROFILE_ANALYZER_RUN_ANALYSIS_TEXT")];

    [NSLayoutConstraint activateConstraints:@[
        [self.header.topAnchor constraintEqualToAnchor:self.headerContainer.topAnchor],
        [self.header.leadingAnchor constraintEqualToAnchor:self.headerContainer.leadingAnchor],
        [self.header.trailingAnchor constraintEqualToAnchor:self.headerContainer.trailingAnchor],
        [self.header.bottomAnchor constraintEqualToAnchor:self.headerContainer.bottomAnchor],
    ]];
}

- (void)viewWillLayoutSubviews {
    SPK_PERF_SCOPE(@"SPKProfileAnalyzerViewController.viewWillLayoutSubviews");
    [super viewWillLayoutSubviews];
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

static NSString *SPKPACompact(NSInteger n) {
    if (n >= 1000000)
        return [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
    if (n >= 10000)
        return [NSString stringWithFormat:@"%.0fK", n / 1000.0];
    if (n >= 1000)
        return [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)n];
}

- (void)paintHeaderIdentity {
    NSDictionary *cached = [SPKProfileAnalyzerStorage headerInfoForUserPK:self.selfPK];
    SPKProfileAnalyzerSnapshot *cur = self.report.current;
    // Live session identity paints the real avatar + @username immediately, even
    // before any analysis has run (no network — read straight off the IGUser).
    NSDictionary *live = [SPKUtils currentUserIdentity];

    NSString *username = cached[@"username"] ?: cur.selfUsername ?: live[@"username"];
    NSString *fullName = cached[@"full_name"] ?: cur.selfFullName ?: live[@"full_name"];
    BOOL haveData = (cached != nil) || (cur != nil);
    NSInteger followers = cached[@"follower_count"] ? [cached[@"follower_count"] integerValue] : cur.followerCount;
    NSInteger following = cached[@"following_count"] ? [cached[@"following_count"] integerValue] : cur.followingCount;
    NSInteger posts = cached[@"media_count"] ? [cached[@"media_count"] integerValue] : cur.mediaCount;
    NSString *picURL = cached[@"profile_pic_url"] ?: cur.selfProfilePicURL ?: live[@"profile_pic_url"];

    self.header.nameLabel.text = fullName.length ? fullName : (username.length ? username : SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE"));
    self.header.usernameLabel.text = username.length ? [NSString stringWithFormat:@"@%@", username] : @"";
    [self.header setStatsPosts:haveData ? SPKPACompact(posts) : @"—"
                     followers:haveData ? SPKPACompact(followers) : @"—"
                     following:haveData ? SPKPACompact(following) : @"—"];

    if (cur.scanDate) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.locale = [SPKUtils spk_activeFormattingLocale];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterShortStyle;
        df.doesRelativeDateFormatting = YES;
        self.scanDateText = [NSString stringWithFormat:SPKL(@"PROFILE_PROFILE_ANALYZER_LAST_SCANNED_VALUE_FORMAT"), [df stringFromDate:cur.scanDate]];
    } else {
        self.scanDateText = nil;
    }

    if (picURL.length && self.selfPK.length) {
        [self.header.avatarView configureWithPK:self.selfPK urlString:picURL];
    }

    [self refreshIdleButton];
    [self.view setNeedsLayout];
}

// The idle CTA label. While a scan has run, the button intermittently swaps this
// for the "Last scanned ..." line so we don't need a separate footer.
- (NSString *)idleButtonCTA {
    return self.report.current ? SPKL(@"PROFILE_PROFILE_ANALYZER_SCAN_AGAIN_TEXT") : SPKL(@"PROFILE_PROFILE_ANALYZER_SCAN_NOW_TEXT");
}

- (void)refreshIdleButton {
    if (self.header.scanButton.isBusy)
        return; // scanning — leave the label to setScanning:
    [self stopButtonCycle];
    self.buttonShowingDate = NO;
    [self.header.scanButton setTextAnimated:[self idleButtonCTA]];
    if (self.scanDateText.length) {
        self.buttonCycleTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                 target:self
                                                               selector:@selector(cycleButtonTick)
                                                               userInfo:nil
                                                                repeats:YES];
    }
}

- (void)cycleButtonTick {
    if (self.header.scanButton.isBusy || !self.scanDateText.length) {
        [self stopButtonCycle];
        return;
    }
    self.buttonShowingDate = !self.buttonShowingDate;
    [self.header.scanButton setTextAnimated:(self.buttonShowingDate ? self.scanDateText : [self idleButtonCTA])];
}

- (void)stopButtonCycle {
    [self.buttonCycleTimer invalidate];
    self.buttonCycleTimer = nil;
}

#pragma mark - Data

- (void)dataChanged:(NSNotification *)note {
    NSString *pk = note.userInfo[@"user_pk"];
    if (pk.length && self.selfPK.length && ![pk isEqualToString:self.selfPK])
        return;
    [self loadCachedData];
    [self paintHeaderIdentity];
}

- (void)loadCachedData {
    if (!self.selfPK.length)
        self.selfPK = [SPKUtils currentUserPK];
    SPKProfileAnalyzerSnapshot *cur = [SPKProfileAnalyzerStorage currentSnapshotForUserPK:self.selfPK];
    SPKProfileAnalyzerSnapshot *prev = [SPKProfileAnalyzerStorage previousSnapshotForUserPK:self.selfPK];
    self.report = [SPKProfileAnalyzerReport reportFromCurrent:cur previous:prev];
    // The most recent scan stamps its change events with this same date, so it's
    // the boundary that keeps "Latest" pinned to the last scan's results until the
    // next scan runs — independent of what's been viewed/marked seen.
    self.lastScanDate = cur.scanDate;
    self.visits = [SPKProfileAnalyzerStorage visitedProfilesForUserPK:self.selfPK];
    self.changeEvents = [SPKProfileAnalyzerStorage changeEventsForUserPK:self.selfPK];
    [self rebuildRows];
    [self.tableView reloadData];
}

- (SPKPACategoryRow *)row:(SPKPACategory)cat title:(NSString *)title icon:(NSString *)icon count:(NSInteger)count {
    SPKPACategoryRow *r = [SPKPACategoryRow new];
    r.category = cat;
    r.title = title;
    r.iconName = icon;
    r.count = count;
    return r;
}

// Maps a change category to its change-log type. Returns NO for current-state categories.
- (BOOL)changeType:(SPKPAChangeType *)outType forCategory:(SPKPACategory)cat {
    switch (cat) {
    case SPKPACategoryNewFollowers:
        if (outType)
            *outType = SPKPAChangeTypeNewFollower;
        return YES;
    case SPKPACategoryLostFollowers:
        if (outType)
            *outType = SPKPAChangeTypeLostFollower;
        return YES;
    case SPKPACategoryYouStartedFollowing:
        if (outType)
            *outType = SPKPAChangeTypeStartedFollowing;
        return YES;
    case SPKPACategoryYouUnfollowed:
        if (outType)
            *outType = SPKPAChangeTypeUnfollowed;
        return YES;
    case SPKPACategoryProfileUpdates:
        if (outType)
            *outType = SPKPAChangeTypeProfileUpdate;
        return YES;
    default:
        return NO;
    }
}

- (SPKPACategoryRow *)changeRow:(SPKPACategory)cat title:(NSString *)title icon:(NSString *)icon
                          total:(NSDictionary<NSNumber *, NSNumber *> *)total
                         unseen:(NSDictionary<NSNumber *, NSNumber *> *)unseen {
    SPKPAChangeType type = SPKPAChangeTypeNewFollower;
    [self changeType:&type forCategory:cat];
    SPKPACategoryRow *r = [self row:cat title:title icon:icon count:total[@(type)].integerValue];
    r.unseenCount = unseen[@(type)].integerValue;
    return r;
}

- (void)rebuildRows {
    SPKProfileAnalyzerReport *rep = self.report;
    NSMutableArray *current = [NSMutableArray array];
    NSMutableArray *changes = [NSMutableArray array];
    if (rep.current) {
        [current addObject:[self row:SPKPACategoryMutual title:SPKL(@"PROFILE_PROFILE_ANALYZER_MUTUAL_FOLLOWERS_TEXT") icon:@"user_check" count:rep.mutualFollowers.count]];
        [current addObject:[self row:SPKPACategoryNotFollowingBack title:SPKL(@"PROFILE_PROFILE_ANALYZER_NOT_FOLLOWING_BACK_TEXT") icon:@"user_unfollow" count:rep.notFollowingYouBack.count]];
        [current addObject:[self row:SPKPACategoryDontFollowBack title:SPKL(@"PROFILE_PROFILE_ANALYZER_DON_T_FOLLOW_BACK_TEXT") icon:@"user_follow" count:rep.youDontFollowBack.count]];
    }

    // Change rows are driven by the durable change log (accumulated across runs),
    // not the rotating previous snapshot — so re-running never wipes the history.
    // `count` is the cumulative total; `unseenCount` badges what's new.
    NSMutableDictionary<NSNumber *, NSNumber *> *total = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *unseen = [NSMutableDictionary dictionary];
    for (SPKProfileAnalyzerChangeEvent *e in self.changeEvents) {
        NSNumber *k = @(e.type);
        total[k] = @(total[k].integerValue + 1);
        if (!e.seen)
            unseen[k] = @(unseen[k].integerValue + 1);
    }
    if (self.changeEvents.count > 0) {
        [changes addObject:[self changeRow:SPKPACategoryNewFollowers title:SPKL(@"PROFILE_PROFILE_ANALYZER_NEW_FOLLOWERS_TEXT") icon:@"face_happy" total:total unseen:unseen]];
        [changes addObject:[self changeRow:SPKPACategoryLostFollowers title:SPKL(@"PROFILE_PROFILE_ANALYZER_LOST_FOLLOWERS_TEXT") icon:@"face_sad" total:total unseen:unseen]];
        [changes addObject:[self changeRow:SPKPACategoryYouStartedFollowing title:SPKL(@"PROFILE_PROFILE_ANALYZER_STARTED_FOLLOWING_TEXT") icon:@"user_follow" total:total unseen:unseen]];
        [changes addObject:[self changeRow:SPKPACategoryYouUnfollowed title:SPKL(@"PROFILE_PROFILE_ANALYZER_UNFOLLOWED_TEXT") icon:@"user_unfollow" total:total unseen:unseen]];
        [changes addObject:[self changeRow:SPKPACategoryProfileUpdates title:SPKL(@"PROFILE_PROFILE_ANALYZER_PROFILE_UPDATES_TEXT") icon:@"edit" total:total unseen:unseen]];
    }
    self.currentRows = current;
    self.changeRows = changes;
}

#pragma mark - Scan

- (void)scanTapped {
    SPKProfileAnalyzerService *svc = [SPKProfileAnalyzerService sharedService];
    if (svc.isRunning)
        return;
    if (!self.selfPK.length)
        self.selfPK = [SPKUtils currentUserPK];

    [self setScanning:YES];

    SPKNotificationPillView *pill = nil;
    if (SPKNotificationIsEnabled(kSPKNotificationProfileAnalyzerComplete)) {
        pill = SPKNotifyProgress(kSPKNotificationProfileAnalyzerComplete, SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYZING_PROFILE_TEXT"), ^{
            [[SPKProfileAnalyzerService sharedService] cancel];
        });
        [pill setProgress:0.02f animated:NO];
        // Tapping the pill (during the scan or after it completes) jumps into
        // the analyzer.
        pill.onTapWhenProgress = ^{
            [SPKProfileAnalyzerViewController presentFromTop];
        };
    }

    __weak typeof(self) weakSelf = self;
    [svc
        runForSelfWithHeaderInfo:^(NSDictionary *userInfo) {
            [weakSelf paintHeaderIdentity];
        }
        progress:^(NSString *status, double fraction) {
            [pill updateProgressTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYZING_PROFILE_TEXT") subtitle:status];
            [pill setProgress:(float)fraction animated:YES];
        }
        completion:^(SPKProfileAnalyzerSnapshot *snapshot, NSError *error) {
            [weakSelf setScanning:NO];
            if (error) {
                if (error.code == SPKProfileAnalyzerErrorCancelled) {
                    [pill dismiss];
                } else if (pill) {
                    [pill showErrorWithTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYSIS_FAILED_TEXT") subtitle:error.localizedDescription icon:nil];
                    SPKNotificationTriggerHaptic(kSPKNotificationProfileAnalyzerComplete, SPKNotificationToneError);
                } else {
                    // No progress pill to turn red, but a failure still has to be said.
                    SPKNotify(kSPKNotificationProfileAnalyzerComplete, SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYSIS_FAILED_TEXT"), error.localizedDescription,
                              @"error_filled", SPKNotificationToneError);
                }
                return;
            }
            [pill setProgress:1.0f animated:YES];
            [pill showSuccessWithTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYSIS_COMPLETE_TEXT") subtitle:SPKL(@"PROFILE_PROFILE_ANALYZER_TAP_VIEW_RESULTS_TEXT") icon:nil];
            pill.onTapWhenCompleted = ^{
                [SPKProfileAnalyzerViewController presentFromTop];
            };
            SPKNotificationTriggerHaptic(kSPKNotificationProfileAnalyzerComplete, SPKNotificationToneSuccess);
            // Auto-dismiss after the configured pill duration (progress pills don't
            // self-dismiss on completion, so schedule it explicitly).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SPKNotificationPillDuration() * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               if (pill.superview)
                                   [pill dismiss];
                           });
            [weakSelf loadCachedData];
            [weakSelf paintHeaderIdentity];
        }];
}

- (void)setScanning:(BOOL)scanning {
    self.header.scanButton.busy = scanning;
    if (scanning) {
        [self stopButtonCycle]; // the scan owns the label while running
        [self.header.scanButton setTextAnimated:SPKL(@"PROFILE_PROFILE_ANALYZER_ANALYZING_TEXT")];
        [self.header.scanButton setProgress:MAX(0.02, [SPKProfileAnalyzerService sharedService].currentFraction) animated:NO];
    } else {
        [self refreshIdleButton];
    }
}

- (void)syncRunningState {
    SPKProfileAnalyzerService *svc = [SPKProfileAnalyzerService sharedService];
    if (svc.isRunning) {
        [self setScanning:YES];
        [self.header.scanButton setProgress:svc.currentFraction animated:NO];
        if (svc.currentStatus.length)
            [self.header.scanButton setText:svc.currentStatus];
    } else {
        [self setScanning:NO];
    }
}

- (void)progressChanged:(NSNotification *)note {
    if (![note.userInfo[@"running"] boolValue]) {
        [self setScanning:NO];
        return;
    }
    if (!self.header.scanButton.isBusy)
        [self setScanning:YES];
    [self.header.scanButton setProgress:[note.userInfo[@"fraction"] doubleValue] animated:YES];
    NSString *status = note.userInfo[@"status"];
    if (status.length)
        [self.header.scanButton setText:status];
}

#pragma mark - Section model

// Row identifiers for the non-category list rows.
typedef NS_ENUM(NSInteger, SPKPAOptionRow) {
    SPKPAOptionTrackVisits,
    SPKPAOptionVisitedProfiles,
    SPKPAOptionAbout,
};

typedef NS_ENUM(NSInteger, SPKPASectionKind) {
    SPKPASectionCurrent, // mutuals / not-following-back / don't-follow-back
    SPKPASectionChanges, // new/lost/started/unfollowed/updates (needs 2 scans)
    SPKPASectionOptions, // track visits + visited profiles + about
    SPKPASectionReset,   // reset data (destructive)
};

- (NSArray<NSNumber *> *)activeSections {
    NSMutableArray *s = [NSMutableArray array];
    // No dedicated "empty" section: the header (avatar / @username / — stats /
    // Run Analysis / "Not analyzed yet") already reads as the empty state.
    if (self.report.current) {
        [s addObject:@(SPKPASectionCurrent)];
        if (self.changeRows.count > 0)
            [s addObject:@(SPKPASectionChanges)];
    }
    [s addObject:@(SPKPASectionOptions)];
    [s addObject:@(SPKPASectionReset)];
    return s;
}

// The option rows present in the Options section (Visited Profiles only shows
// when tracking is enabled).
- (NSArray<NSNumber *> *)optionRows {
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@(SPKPAOptionTrackVisits)];
    if (self.trackVisits)
        [rows addObject:@(SPKPAOptionVisitedProfiles)];
    [rows addObject:@(SPKPAOptionAbout)];
    return rows;
}

- (SPKPASectionKind)kindForSection:(NSInteger)section {
    return (SPKPASectionKind)[[self activeSections][section] integerValue];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self activeSections].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ([self kindForSection:section]) {
    case SPKPASectionCurrent:
        return self.currentRows.count;
    case SPKPASectionChanges:
        return self.changeRows.count;
    case SPKPASectionOptions:
        return [self optionRows].count;
    case SPKPASectionReset:
        return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self kindForSection:section]) {
    case SPKPASectionCurrent:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_SCAN_TEXT");
    case SPKPASectionChanges:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_CHANGES_TEXT");
    case SPKPASectionOptions:
        return SPKL(@"PROFILE_PROFILE_ANALYZER_OPTIONS_TEXT");
    case SPKPASectionReset:
        return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKPASectionKind kind = [self kindForSection:indexPath.section];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    UIView *selected = [UIView new];
    selected.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    cell.selectedBackgroundView = selected;
    content.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    content.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];

    if (kind == SPKPASectionReset) {
        content.text = SPKL(@"PROFILE_PROFILE_ANALYZER_RESET_PROFILE_ANALYZER_DATA_TEXT");
        content.textProperties.color = [SPKUtils SPKColor_InstagramDestructive];
        content.image = [SPKAssetUtils instagramIconNamed:@"trash" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
        content.imageProperties.tintColor = [SPKUtils SPKColor_InstagramDestructive];
        cell.contentConfiguration = content;
        return cell;
    }

    if (kind == SPKPASectionOptions) {
        SPKPAOptionRow opt = (SPKPAOptionRow)[[self optionRows][indexPath.row] integerValue];
        if (opt == SPKPAOptionTrackVisits) {
            content.text = SPKL(@"PROFILE_PROFILE_ANALYZER_TRACK_VISITED_PROFILES_TEXT");
            content.image = [SPKAssetUtils instagramIconNamed:@"eye" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            content.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
            SPKSwitch *toggle = [SPKSwitch new];
            toggle.on = self.trackVisits;
            [toggle addTarget:self action:@selector(trackVisitsToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (opt == SPKPAOptionVisitedProfiles) {
            content.text = SPKL(@"PROFILE_PROFILE_ANALYZER_VISITED_PROFILES_TEXT");
            content.image = [SPKAssetUtils instagramIconNamed:@"history" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            content.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
            content.secondaryText = [NSString stringWithFormat:@"%lu", (unsigned long)self.visits.count];
            content.prefersSideBySideTextAndSecondaryText = YES;
            content.secondaryTextProperties.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else { // About
            content.text = SPKL(@"PROFILE_PROFILE_ANALYZER_ABOUT_PROFILE_ANALYZER_TEXT");
            content.image = [SPKAssetUtils instagramIconNamed:@"info" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            content.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.contentConfiguration = content;
        return cell;
    }

    SPKPACategoryRow *r = (kind == SPKPASectionCurrent) ? self.currentRows[indexPath.row] : self.changeRows[indexPath.row];
    content.text = r.title;
    content.image = [SPKAssetUtils instagramIconNamed:r.iconName pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    content.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];

    content.prefersSideBySideTextAndSecondaryText = YES;
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];

    // With unseen changes the count is badged (blue pill) and shows how many are
    // NEW; opening the category marks them seen and the number reverts to the plain
    // cumulative total.
    if (r.unseenCount > 0) {
        content.secondaryText = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = [self badgeAccessoryWithCount:r.unseenCount];
    } else {
        content.secondaryText = [NSString stringWithFormat:@"%ld", (long)r.count];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    cell.contentConfiguration = content;
    return cell;
}

// A blue badge showing the (unseen) count, followed by a disclosure chevron.
- (UIView *)badgeAccessoryWithCount:(NSInteger)count {
    UILabel *pill = [UILabel new];
    pill.text = [NSString stringWithFormat:@"%ld", (long)count];
    pill.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    pill.textColor = [UIColor whiteColor];
    pill.textAlignment = NSTextAlignmentCenter;
    pill.backgroundColor = [SPKUtils SPKColor_InstagramBlue] ?: [UIColor systemBlueColor];
    pill.layer.cornerRadius = 11.0;
    pill.layer.masksToBounds = YES;
    CGFloat pillW = MAX(22.0, [pill sizeThatFits:CGSizeMake(CGFLOAT_MAX, 22.0)].width + 14.0);
    pill.frame = CGRectMake(0.0, 0.0, pillW, 22.0);

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.frame = CGRectMake(pillW + 8.0, 3.0, 8.0, 16.0);

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, pillW + 8.0 + 8.0, 22.0)];
    [container addSubview:pill];
    [container addSubview:chevron];
    return container;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKPASectionKind kind = [self kindForSection:indexPath.section];

    if (kind == SPKPASectionReset) {
        [self confirmReset];
        return;
    }

    if (kind == SPKPASectionOptions) {
        SPKPAOptionRow opt = (SPKPAOptionRow)[[self optionRows][indexPath.row] integerValue];
        if (opt == SPKPAOptionVisitedProfiles)
            [self openVisitedList];
        else if (opt == SPKPAOptionAbout)
            [self showAbout];
        return;
    }

    SPKPACategoryRow *r = (kind == SPKPASectionCurrent) ? self.currentRows[indexPath.row] : self.changeRows[indexPath.row];
    [self openCategory:r.category title:r.title];
}

#pragma mark - Options actions

- (void)trackVisitsToggled:(SPKSwitch *)toggle {
    SPKPreferenceSetObject(@(toggle.isOn), @"profile_analyzer_track_visits");
    self.trackVisits = toggle.isOn;
    NSInteger optionsIndex = [[self activeSections] indexOfObject:@(SPKPASectionOptions)];
    if (optionsIndex != NSNotFound) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:optionsIndex] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (void)showAbout {
    NSString *message =
        SPKL(@"PROFILE_PROFILE_ANALYZER_PROFILE_ANALYZER_FETCHES_FULL_FOLLOWERS_FOLLOWING_LISTS_STORES_DEVICE_TEXT");
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"PROFILE_PROFILE_ANALYZER_ABOUT_PROFILE_ANALYZER_TEXT")
                                                message:message
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                ]];
}

- (void)confirmReset {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"PROFILE_PROFILE_ANALYZER_RESET_PROFILE_ANALYZER_TEXT")
                                                message:SPKL(@"PROFILE_PROFILE_ANALYZER_DELETES_STORED_SNAPSHOTS_CHANGE_HISTORY_VISITED_PROFILE_HISTORY_CANNOT_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_RESET")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [SPKProfileAnalyzerStorage resetAll];
                                                                                  [self loadCachedData];
                                                                                  [self paintHeaderIdentity];
                                                                                  SPKNotify(kSPKNotificationProfileAnalyzerClear, SPKL(@"PROFILE_PROFILE_ANALYZER_RESET_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (void)openVisitedList {
    SPKProfileAnalyzerListViewController *vc =
        [[SPKProfileAnalyzerListViewController alloc] initVisitedListWithTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_VISITED_PROFILES_TEXT")
                                                                        visits:self.visits];
    NSString *owner = self.selfPK;
    vc.onRemoveVisit = ^(SPKProfileAnalyzerVisit *visit) {
        [SPKProfileAnalyzerStorage removeVisitForUserPK:owner visitedPK:visit.user.pk];
    };
    __weak typeof(self) weakSelf = self;
    vc.onClearHistory = ^{
        [SPKProfileAnalyzerStorage clearVisitsForUserPK:owner];
        [weakSelf loadCachedData];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

// Follow-button behaviour for each change list, mirroring the current-state lists.
- (SPKPAListKind)listKindForChangeType:(SPKPAChangeType)type {
    switch (type) {
    case SPKPAChangeTypeNewFollower:
        return SPKPAListKindFollow; // may not follow them back
    case SPKPAChangeTypeStartedFollowing:
        return SPKPAListKindUnfollow; // you follow them
    case SPKPAChangeTypeUnfollowed:
        return SPKPAListKindFollow; // you don't follow them
    case SPKPAChangeTypeLostFollower:
        return SPKPAListKindFollow; // live-resolved either way
    case SPKPAChangeTypeProfileUpdate:
        return SPKPAListKindProfileUpdate;
    }
}

- (void)openCategory:(SPKPACategory)cat title:(NSString *)title {
    SPKPAChangeType type = SPKPAChangeTypeNewFollower;
    if ([self changeType:&type forCategory:cat]) {
        [self openChangeCategory:type title:title];
        return;
    }

    // Current-state categories still come straight from the latest snapshot report.
    SPKProfileAnalyzerReport *r = self.report;
    NSArray<SPKProfileAnalyzerUser *> *users = nil;
    SPKPAListKind kind = SPKPAListKindPlain;
    switch (cat) {
    case SPKPACategoryMutual:
        users = r.mutualFollowers;
        kind = SPKPAListKindUnfollow;
        break;
    case SPKPACategoryNotFollowingBack:
        users = r.notFollowingYouBack;
        kind = SPKPAListKindUnfollow;
        break;
    case SPKPACategoryDontFollowBack:
        users = r.youDontFollowBack;
        kind = SPKPAListKindFollow;
        break;
    default:
        return;
    }
    SPKProfileAnalyzerListViewController *vc =
        [[SPKProfileAnalyzerListViewController alloc] initWithTitle:title
                                                              users:users
                                                               kind:kind];
    [self.navigationController pushViewController:vc animated:YES];
}

// An event belongs to "Latest" when it came from the most recent scan (its date
// is not older than the scan boundary). This is deliberately independent of the
// seen flag, so viewing a category doesn't shuffle its items down into Previous —
// only running another scan does. With no boundary yet (never scanned) nothing is
// latest.
- (BOOL)eventIsFromLatestScan:(SPKProfileAnalyzerChangeEvent *)event {
    if (!self.lastScanDate || !event.date)
        return NO;
    return [event.date compare:self.lastScanDate] != NSOrderedAscending;
}

// Splits a change category's events into Latest (most recent scan) / Previous
// (earlier scans), pushes a grouped list, then marks the category seen to clear
// its badge — the badge tracks unseen, the grouping tracks scan recency.
- (void)openChangeCategory:(SPKPAChangeType)type title:(NSString *)title {
    SPKProfileAnalyzerListViewController *vc;
    // The list is handed display objects, not events, so keep the way back for
    // swipe-to-delete: map each row's object to the event that produced it. Keyed by
    // pointer identity — every event deserializes its own user, so two events for the
    // same account stay distinguishable, which an eventID keyed by the row's contents
    // could not guarantee.
    NSMapTable<id, SPKProfileAnalyzerChangeEvent *> *eventForItem =
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                             valueOptions:NSPointerFunctionsObjectPersonality | NSPointerFunctionsStrongMemory];

    if (type == SPKPAChangeTypeProfileUpdate) {
        NSMutableArray *latest = [NSMutableArray array], *previous = [NSMutableArray array];
        for (SPKProfileAnalyzerChangeEvent *e in self.changeEvents) {
            if (e.type != type)
                continue;
            SPKProfileAnalyzerProfileChange *ch = e.asProfileChange;
            if (ch) {
                [eventForItem setObject:e forKey:ch];
                [([self eventIsFromLatestScan:e] ? latest : previous) addObject:ch];
            }
        }
        vc = [[SPKProfileAnalyzerListViewController alloc] initWithTitle:title
                                                    latestProfileUpdates:latest
                                                  previousProfileUpdates:previous];
    } else {
        NSMutableArray *latest = [NSMutableArray array], *previous = [NSMutableArray array];
        for (SPKProfileAnalyzerChangeEvent *e in self.changeEvents) {
            if (e.type != type)
                continue;
            [eventForItem setObject:e forKey:e.user];
            [([self eventIsFromLatestScan:e] ? latest : previous) addObject:e.user];
        }
        vc = [[SPKProfileAnalyzerListViewController alloc] initWithTitle:title
                                                             latestUsers:latest
                                                           previousUsers:previous
                                                                    kind:[self listKindForChangeType:type]];
    }

    __weak typeof(self) weakSelf = self;
    vc.onRemoveEntry = ^(id item) {
        SPKProfileAnalyzerChangeEvent *event = [eventForItem objectForKey:item];
        typeof(self) strongSelf = weakSelf;
        if (!event || !strongSelf)
            return;
        [SPKProfileAnalyzerStorage removeChangeEventsWithIDs:@[ event.eventID ] forUserPK:strongSelf.selfPK];
        [strongSelf loadCachedData];
    };

    [self.navigationController pushViewController:vc animated:YES];
    [SPKProfileAnalyzerStorage markChangeEventsSeenForType:type forUserPK:self.selfPK];
}

@end
