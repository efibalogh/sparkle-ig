// Story Mentions — Gallery-style bottom sheet listing mentioned users with Follow/Following buttons.
// Triggered by the @ button in story overlays (SeenButtons.x). The user list
// itself comes from SPKStoryMentions, the single deduped source shared with the
// overlay button and its count badge.

#import "../../AssetUtils.h"
#import "SPKStrings.h"
#import "../../InstagramHeaders.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/Stories/SPKStoryMentions.h"
#import "../../Shared/UI/SPKFollowButton.h"
#import "../../Shared/UI/SPKMediaChrome.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>

extern void SPKPauseStoryPlaybackFromOverlaySubview(UIView *view);
extern void SPKResumeStoryPlaybackFromOverlaySubview(UIView *view);

static NSMutableDictionary<NSString *, NSDictionary *> *SPKStoryMentionsFriendshipStatusCache;
static NSCache<NSString *, UIImage *> *SPKStoryMentionsAvatarCache;

static void SPKStoryMentionsEnsureSessionCaches(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKStoryMentionsFriendshipStatusCache = [NSMutableDictionary dictionary];
        SPKStoryMentionsAvatarCache = [[NSCache alloc] init];
        SPKStoryMentionsAvatarCache.countLimit = 128;

        // Friendship status is relative to the viewing account, so nothing
        // cached for one account may be shown to another.
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            [SPKStoryMentionsFriendshipStatusCache removeAllObjects];
        }];
    });
}

static const void *kSPKMentionButtonPKKey = &kSPKMentionButtonPKKey;
static const void *kSPKMentionButtonStateKey = &kSPKMentionButtonStateKey;


/// ============ Bottom sheet VC ============

#define kSPKMentionAvatarSize 52.0
#define kSPKMentionRowHeight 72.0

@interface SPKMentionCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIControl *followBtn;
@end

@implementation SPKMentionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];

        self.avatarView = [[UIImageView alloc] init];
        self.avatarView.clipsToBounds = YES;
        self.avatarView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarView.layer.cornerRadius = kSPKMentionAvatarSize / 2.0;
        self.avatarView.backgroundColor = [SPKUtils SPKColor_InstagramSeparator];
        self.avatarView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.avatarView];

        self.nameLabel = [[UILabel alloc] init];
        self.nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.nameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

        self.subLabel = [[UILabel alloc] init];
        self.subLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        self.subLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        self.subLabel.translatesAutoresizingMaskIntoConstraints = NO;

        self.followBtn = [SPKFollowButton button];
        [self.contentView addSubview:self.followBtn];

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[ self.nameLabel, self.subLabel ]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 2;
        textStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:textStack];

        [NSLayoutConstraint activateConstraints:@[
            [self.avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                          constant:16],
            [self.avatarView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.avatarView.widthAnchor constraintEqualToConstant:kSPKMentionAvatarSize],
            [self.avatarView.heightAnchor constraintEqualToConstant:kSPKMentionAvatarSize],

            [textStack.leadingAnchor constraintEqualToAnchor:self.avatarView.trailingAnchor
                                                    constant:12],
            [textStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.followBtn.leadingAnchor
                                                               constant:-10],

            [self.followBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                          constant:-16],
            [self.followBtn.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.followBtn.widthAnchor constraintGreaterThanOrEqualToConstant:88],
            [self.followBtn.heightAnchor constraintEqualToConstant:32],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];

    // The follow target is re-added on every dequeue, so drop the previous row's
    // registration or one tap would fire a request per reuse. The button may also
    // arrive mid-request from the row it is being recycled away from.
    [self.followBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [SPKFollowButton setLoading:NO forButton:self.followBtn];
}

@end
@interface SPKStoryMentionsVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<SPKStoryMention *> *mentions;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSString *currentUsername;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *friendshipStatuses;
@property (nonatomic, weak) UIView *storyOverlayView; // for resuming playback on dismiss
/// Height of the list as actually laid out, or 0 before the first layout pass.
@property (nonatomic, assign) CGFloat spk_measuredSheetHeight;
@end

@implementation SPKStoryMentionsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.title = SPKL(@"STORIES_STORY_MENTIONS_MENTIONS_TEXT");

    // Resolve current user to hide the Follow button for yourself
    @try {
        id window = [[UIApplication sharedApplication] keyWindow];
        if ([window respondsToSelector:@selector(userSession)])
            self.currentUsername = ((IGUserSession *)[window valueForKey:@"userSession"]).user.username;
    } @catch (__unused id e) {
    }

    // Table view (stretching under navigation bar)
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 80.0, 0.0, 0.0);
    self.tableView.rowHeight = kSPKMentionRowHeight;
    self.tableView.estimatedRowHeight = 0;
    self.tableView.estimatedSectionHeaderHeight = 0;
    self.tableView.estimatedSectionFooterHeight = 0;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 12, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 12, 0);
    self.tableView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Bulk-fetch friendship statuses in one round trip
    SPKStoryMentionsEnsureSessionCaches();
    self.friendshipStatuses = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *missingPKs = [NSMutableArray array];
    for (SPKStoryMention *mention in self.mentions) {
        NSString *pk = mention.pk;
        if (!pk.length)
            continue;
        NSDictionary *cachedStatus = SPKStoryMentionsFriendshipStatusCache[pk];
        if (cachedStatus) {
            self.friendshipStatuses[pk] = cachedStatus;
        } else {
            [missingPKs addObject:pk];
        }
    }
    if (missingPKs.count) {
        __weak typeof(self) weakSelf = self;
        [SPKInstagramAPI fetchFriendshipStatusesForPKs:missingPKs
                                            completion:^(NSDictionary *statuses, NSError *error) {
                                                (void)error;
                                                if (!statuses.count)
                                                    return;
                                                [SPKStoryMentionsFriendshipStatusCache addEntriesFromDictionary:statuses];
                                                [weakSelf.friendshipStatuses addEntriesFromDictionary:statuses];
                                                [weakSelf.tableView reloadData];
                                            }];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Row count times row height misses the bar and the safe area by a few
    // points, which leaves the sheet one gesture short of showing its last row.
    // The laid-out height carries both, so hand it to the resolver.
    CGFloat measured = [SPKUtils sheetHeightFittingContentOfScrollView:self.tableView];
    if (measured > 0.0 && fabs(measured - self.spk_measuredSheetHeight) > 0.5) {
        self.spk_measuredSheetHeight = measured;
        if (@available(iOS 16.0, *)) {
            [self.navigationController.sheetPresentationController invalidateDetents];
        }
    }

    [SPKUtils updateScrollingForFittedContent:self.tableView];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Resume story playback when mentions sheet is dismissed
    if (self.storyOverlayView) {
        SPKResumeStoryPlaybackFromOverlaySubview(self.storyOverlayView);

        UIResponder *r = self.storyOverlayView;
        while (r) {
            if ([r isKindOfClass:[UIViewController class]]) {
                SEL sel = NSSelectorFromString(@"tryResumePlayback");
                if ([r respondsToSelector:sel]) {
                    ((void (*)(id, SEL))objc_msgSend)(r, sel);
                    break;
                }
            }
            r = r.nextResponder;
        }
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mentions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"SPKMention";
    SPKMentionCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[SPKMentionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    }

    SPKStoryMention *mention = self.mentions[indexPath.row];
    NSString *username = mention.username ?: SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_TEXT");
    NSString *fullName = mention.fullName;
    NSURL *picURL = mention.profilePictureURL;

    cell.nameLabel.text = username;
    cell.subLabel.text = fullName ?: @"";
    cell.subLabel.hidden = !fullName.length;

    // Default avatar — draw the 24pt glyph at its native size (contentMode Center)
    // so the small asset isn't upscaled and blurred by the avatar's aspect-fill.
    cell.avatarView.contentMode = UIViewContentModeCenter;
    cell.avatarView.image = [SPKAssetUtils instagramIconNamed:@"user_circle" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.avatarView.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];

    // Avatar fetch with session cache
    if (picURL) {
        NSString *cacheKey = picURL.absoluteString;
        objc_setAssociatedObject(cell.avatarView, @selector(cellForRowAtIndexPath:), cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);

        UIImage *cachedAvatar = cacheKey.length > 0 ? [SPKStoryMentionsAvatarCache objectForKey:cacheKey] : nil;
        if (cachedAvatar) {
            cell.avatarView.contentMode = UIViewContentModeScaleAspectFill;
            cell.avatarView.image = cachedAvatar;
            cell.avatarView.tintColor = nil;
        } else {
            NSURL *url = [picURL copy];
            NSInteger row = indexPath.row;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:url];
                if (!data)
                    return;
                UIImage *img = [UIImage imageWithData:data];
                if (!img)
                    return;
                if (cacheKey.length > 0) {
                    [SPKStoryMentionsAvatarCache setObject:img forKey:cacheKey];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    UITableViewCell *c = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
                    if (!c || ![c isKindOfClass:[SPKMentionCell class]])
                        return;
                    SPKMentionCell *mc = (SPKMentionCell *)c;
                    NSString *boundKey = objc_getAssociatedObject(mc.avatarView, @selector(cellForRowAtIndexPath:));
                    if (mc.avatarView && (!boundKey || [boundKey isEqualToString:cacheKey])) {
                        mc.avatarView.contentMode = UIViewContentModeScaleAspectFill;
                        mc.avatarView.image = img;
                        mc.avatarView.tintColor = nil;
                    }
                });
            });
        }
    }

    // Follow button state
    [cell.followBtn removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [SPKFollowButton setLoading:NO forButton:cell.followBtn];

    BOOL isMe = self.currentUsername && [username isEqualToString:self.currentUsername];
    if (isMe) {
        cell.followBtn.hidden = YES;
    } else {
        cell.followBtn.hidden = NO;

        NSString *pk = mention.pk;
        NSDictionary *status = pk ? self.friendshipStatuses[pk] : nil;
        SPKFollowButtonState state = [SPKFollowButton stateForFriendshipStatus:status];
        [SPKFollowButton applyState:state toButton:cell.followBtn];

        objc_setAssociatedObject(cell.followBtn, kSPKMentionButtonPKKey, pk, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cell.followBtn, kSPKMentionButtonStateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell.followBtn addTarget:self action:@selector(spk_followTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    return cell;
}

#pragma mark - Follow/Unfollow

- (void)spk_followTapped:(UIControl *)sender {
    NSString *pk = objc_getAssociatedObject(sender, kSPKMentionButtonPKKey);
    if (!pk.length)
        return;

    // Tracked explicitly rather than read back off the button title, which is
    // localized and would invert the action on every non-English language.
    SPKFollowButtonState currentState = (SPKFollowButtonState)[objc_getAssociatedObject(sender, kSPKMentionButtonStateKey) integerValue];
    // Covers withdrawing a pending request as well as unfollowing.
    BOOL unfollowing = [SPKFollowButton tapUnfollowsFromState:currentState];

    void (^doIt)(void) = ^{
        [SPKFollowButton setLoading:YES forButton:sender];

        __weak typeof(self) weakSelf = self;
        SPKAPICompletion done = ^(NSDictionary *response, NSError *error) {
            BOOL ok = (response && [response[@"status"] isEqualToString:@"ok"]);

            SPKFollowButtonState resolvedState = currentState;
            if (ok) {
                // Following a private account yields a pending request rather than
                // a follow, so prefer the status Instagram reports back over
                // assuming the relationship we asked for.
                NSDictionary *reported = response[@"friendship_status"];
                NSDictionary *updatedStatus = nil;
                if ([reported isKindOfClass:[NSDictionary class]]) {
                    updatedStatus = reported;
                } else {
                    NSMutableDictionary *merged = [weakSelf.friendshipStatuses[pk] mutableCopy] ?: [NSMutableDictionary dictionary];
                    merged[@"following"] = @(!unfollowing);
                    merged[@"outgoing_request"] = @NO;
                    updatedStatus = [merged copy];
                }
                resolvedState = [SPKFollowButton stateForFriendshipStatus:updatedStatus];
                weakSelf.friendshipStatuses[pk] = updatedStatus;
                SPKStoryMentionsEnsureSessionCaches();
                SPKStoryMentionsFriendshipStatusCache[pk] = updatedStatus;
            }

            // The cell may have been recycled onto another user while the request
            // was in flight. Its new row already reflects its own state, so leave
            // the button alone rather than flipping the wrong person's control.
            NSString *currentPK = objc_getAssociatedObject(sender, kSPKMentionButtonPKKey);
            if (![currentPK isEqualToString:pk])
                return;

            [SPKFollowButton setLoading:NO forButton:sender];
            if (ok) {
                [SPKFollowButton applyState:resolvedState toButton:sender];
                objc_setAssociatedObject(sender, kSPKMentionButtonStateKey, @(resolvedState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        };

        if (unfollowing)
            [SPKInstagramAPI unfollowUserPK:pk completion:done];
        else
            [SPKInstagramAPI followUserPK:pk completion:done];
    };
    if (!unfollowing && [SPKUtils getBoolPref:@"profile_confirm_follow"]) {
        [SPKUtils showConfirmation:doIt
                             title:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_FOLLOW_TITLE")
                           message:SPKL(@"GENERAL_FOLLOW_CONFIRM_FOLLOW_ACCOUNT_CONFIRMATION_MESSAGE")];
    } else if (unfollowing && [SPKUtils getBoolPref:@"profile_confirm_unfollow"]) {
        [SPKUtils showConfirmation:doIt
                             title:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_UNFOLLOW_TITLE")
                           message:SPKL(@"GENERAL_FOLLOW_CONFIRM_UNFOLLOW_ACCOUNT_CONFIRMATION_MESSAGE")];
    } else {
        doIt();
    }
}

#pragma mark - UITableViewDelegate (row tap → profile)

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.mentions.count)
        return;
    SPKStoryMention *mention = self.mentions[indexPath.row];
    id userObject = mention.userObject;
    if (mention.username.length == 0 && !userObject)
        return;

    [SPKUtils openInstagramProfileForUser:userObject pk:mention.pk username:mention.username fromViewController:self];
}

@end

// ============ Presentation entry point ============

extern void SPKPauseStoryPlaybackFromOverlaySubview(UIView *);
extern void SPKResumeStoryPlaybackFromOverlaySubview(UIView *);

void SPKPresentStoryMentionsSheet(UIView *overlayView) {
    NSArray<SPKStoryMention *> *mentions = SPKStoryMentionsForOverlay(overlayView);

    UIViewController *presenter = [SPKUtils nearestViewControllerForView:overlayView];
    if (!presenter)
        return;

    SPKPauseStoryPlaybackFromOverlaySubview(overlayView);

    SPKStoryMentionsVC *vc = [[SPKStoryMentionsVC alloc] init];
    vc.mentions = mentions;
    vc.storyOverlayView = overlayView;

    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    UISheetPresentationController *sheet = nav.sheetPresentationController;

    if (@available(iOS 16.0, *)) {
        CGFloat headerHeight = 56.0;
        CGFloat contentHeight = MAX(1, mentions.count) * kSPKMentionRowHeight;
        CGFloat estimatedHeight = headerHeight + contentHeight + 40.0;
        // The estimate only has to carry the sheet until the list has been laid
        // out once; from there the measured height is the accurate one.
        __weak SPKStoryMentionsVC *weakVC = vc;
        UISheetPresentationControllerDetent *customDetent =
            [UISheetPresentationControllerDetent customDetentWithIdentifier:@"custom_fit"
                                                                   resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                                                                       CGFloat measured = weakVC.spk_measuredSheetHeight;
                                                                       CGFloat height = measured > 0.0 ? measured : estimatedHeight;
                                                                       return MIN(height, ctx.maximumDetentValue * 0.85);
                                                                   }];
        sheet.detents = @[ customDetent ];
    } else {
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
    }

    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
    sheet.prefersGrabberVisible = YES;

    SPKNotificationTriggerHaptic(kSPKNotificationStoryMentionsSheet, SPKNotificationToneInfo);
    [presenter presentViewController:nav animated:YES completion:nil];
}
