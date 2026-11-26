#import "SPKLiquidGlassGatesViewController.h"

#if SPK_DEV

#import "SPKLiquidGlassBisect.h"
#import "SPKLiquidGlassGates.h"
#import "../../Settings/SPKSettingsViewController.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import "../../Shared/UI/SPKFont.h"

static NSString *const kSPKLiquidGlassGatesRevealKey = @"tools_liquid_glass_gates";
static NSString *const kSPKLiquidGlassGatesCellIdentifier = @"gate";

typedef NS_ENUM(NSInteger, SPKGateStatus) {
    SPKGateStatusUnavailable,
    SPKGateStatusNotRead,
    SPKGateStatusChanged,
    SPKGateStatusSame,
    SPKGateStatusWritten,
    SPKGateStatusLeftToInstagram,
};

// Readable names, keyed by the registry's symbol. A stored value and the getter
// Instagram reads it back through share a name: the section says which is which.
NSString *SPKLiquidGlassGateDisplayName(NSString *symbol) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *master = SPKL(@"DEV_LG_GATES_NAME_MASTER_SWITCH");
        NSString *buttons = SPKL(@"DEV_LG_GATES_NAME_GLASS_BUTTONS");
        NSString *navigation = SPKL(@"DEV_LG_GATES_NAME_GLASS_NAVIGATION");
        NSString *rendering = SPKL(@"DEV_LG_GATES_NAME_RENDERING_OPTIMIZATION");
        NSString *legibility = SPKL(@"DEV_LG_GATES_NAME_LEGIBILITY_BLUR");
        NSString *profileTabs = SPKL(@"DEV_LG_GATES_NAME_PROFILE_TABS_NO_GLASS");
        NSString *browser = SPKL(@"DEV_LG_GATES_NAME_BROWSER_GLASS");
        NSString *headerHeight = SPKL(@"DEV_LG_GATES_NAME_PROFILE_HEADER_HEIGHT");
        names = @{
            @"IGLiquidGlass.isEnabled (static)" : master,
            @"SwizzleToggle setIsEnabled:" : buttons,
            @"Nav overrideIsEnabled:" : navigation,
            @"Nav overrideIsGlassRenderingOptimizationEnabled:" : rendering,
            @"Nav overrideIsLegibilityBlurEnabled:" : legibility,
            @"Nav overrideIsProfileSegmentedTabsGlassDisabled:" : profileTabs,
            @"Nav overrideIsBrowserChromeGlassDisabled:" : browser,
            @"Nav overrideIsProfileOtherNavBarHeightMatchSelf:" : headerHeight,
            @"SwizzleToggle isEnabled" : buttons,
            @"Nav isEnabled" : navigation,
            @"Nav isHomeFeedHeaderEnabled" : SPKL(@"DEV_LG_GATES_NAME_HOME_HEADER"),
            @"Nav isGlassRenderingOptimizationEnabled" : rendering,
            @"Nav isLegibilityBlurEnabled" : legibility,
            @"Nav isBrowserChromeGlassEnabled" : browser,
            @"Nav isProfileSegmentedTabsGlassDisabled" : profileTabs,
            @"Nav isProfileOtherNavBarHeightMatchSelf" : headerHeight,
            @"isLiquidGlassNavigationContentStylePinningEnabled" : SPKL(@"DEV_LG_GATES_NAME_CONTENT_STYLE_PINNING"),
            @"isLiquidGlassEaseInOutBlurEnabled" : SPKL(@"DEV_LG_GATES_NAME_EASE_IN_OUT_BLUR"),
            @"isLiquidGlassCGContextBlurEnabled" : SPKL(@"DEV_LG_GATES_NAME_DRAWN_BLUR"),
            @"isSystemDefaultGlassEnabled" : SPKL(@"DEV_LG_GATES_NAME_SYSTEM_GLASS"),
            @"+IGLiquidGlass isEnabled" : master,
            @"IGUnifiedVideoBackButton _isLiquidGlassEnabled" : SPKL(@"DEV_LG_GATES_NAME_VIDEO_BACK_BUTTON"),
            @"IGUnifiedVideoCameraEntryPointButton _isLiquidGlassEnabled" : SPKL(@"DEV_LG_GATES_NAME_VIDEO_CAMERA_BUTTON"),
            @"+IGDSAlertDialogLiquidGlass isEnabled" : SPKL(@"DEV_LG_GATES_NAME_ALERT_GLASS"),
            @"IGDSAlertDialogActionButton enableLiquidGlass" : SPKL(@"DEV_LG_GATES_NAME_ALERT_BUTTONS"),
            @"IGFloatingTabBarEnabled" : SPKL(@"DEV_LG_GATES_NAME_FLOATING_TAB_BAR"),
            @"IGTabBarDynamicSizingEnabled" : SPKL(@"DEV_LG_GATES_NAME_TAB_BAR_SIZING"),
            @"IGTabBarEnhancedDynamicSizingEnabled" : SPKL(@"DEV_LG_GATES_NAME_TAB_BAR_ENHANCED_SIZING"),
            @"IGTabBarViewPointFixEnabled" : SPKL(@"DEV_LG_GATES_NAME_TAB_BAR_VIEWPOINT_FIX"),
            @"IGTabBarStyleForLauncherSet" : SPKL(@"DEV_LG_GATES_NAME_TAB_BAR_STYLE"),
        };
    });
    return names[symbol] ?: symbol;
}

static NSString *SPKGateGroupTitle(NSString *group) {
    if ([group isEqualToString:@"Writes"])
        return SPKL(@"DEV_LG_GATES_GROUP_STORED_HEADER");
    if ([group isEqualToString:@"Navigation"])
        return SPKL(@"DEV_LG_GATES_GROUP_NAVIGATION_HEADER");
    if ([group isEqualToString:@"Launcher config"])
        return SPKL(@"DEV_LG_GATES_GROUP_RENDERING_HEADER");
    if ([group isEqualToString:@"Components"])
        return SPKL(@"DEV_LG_GATES_GROUP_COMPONENTS_HEADER");
    return SPKL(@"DEV_LG_GATES_GROUP_TAB_BAR_HEADER");
}

static NSString *SPKGateValueText(NSString *symbol, NSInteger value) {
    if ([symbol isEqualToString:@"IGTabBarStyleForLauncherSet"]) {
        if (value == 0)
            return SPKL(@"DEV_LG_GATES_VALUE_CLASSIC");
        if (value == 1)
            return SPKL(@"DEV_LG_GATES_VALUE_FLOATING");
        return [NSString stringWithFormat:@"%ld", (long)value];
    }
    return value ? SPKL(@"DEV_LG_GATES_VALUE_ON") : SPKL(@"DEV_LG_GATES_VALUE_OFF");
}

static SPKGateStatus SPKGateStatusFor(NSDictionary *gate) {
    if (![gate[SPKLiquidGlassGateInstalledKey] boolValue])
        return SPKGateStatusUnavailable;
    NSInteger returnedValue = [gate[SPKLiquidGlassGateReturnedValueKey] integerValue];
    NSInteger instagramValue = [gate[SPKLiquidGlassGateInstagramValueKey] integerValue];
    if (returnedValue < 0)
        return SPKGateStatusNotRead;
    if ([gate[SPKLiquidGlassGateSkippedThisLaunchKey] boolValue])
        return SPKGateStatusLeftToInstagram;
    if (instagramValue < 0)
        return SPKGateStatusWritten;
    return instagramValue == returnedValue ? SPKGateStatusSame : SPKGateStatusChanged;
}

static BOOL SPKGateIsPending(NSDictionary *gate) {
    return [gate[SPKLiquidGlassGateSkippedNextLaunchKey] boolValue] != [gate[SPKLiquidGlassGateSkippedThisLaunchKey] boolValue];
}

@interface SPKLiquidGlassGatesViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *gates;
// Sections of gates, already filtered.
@property (nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *sections;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation SPKLiquidGlassGatesViewController

+ (void)present {
    if ([SPKUtils revealViewControllerWithKey:kSPKLiquidGlassGatesRevealKey])
        return;
    [SPKUtils presentViewControllerInSheet:[[self alloc] initWithStyle:UITableViewStyleInsetGrouped] revealKey:kSPKLiquidGlassGatesRevealKey];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"DEV_LG_GATES_TITLE");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(close)];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(shareReport)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self bulkMenu]];
    self.navigationItem.rightBarButtonItems = @[ more, share ];

    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kSPKLiquidGlassGatesCellIdentifier];
    self.tableView.tableHeaderView = [self buildHeader];
    [self reloadGates];
    // Default to the interesting rows once there are any.
    self.filterControl.selectedSegmentIndex = [self changedCount] > 0 ? 0 : 1;
    [self rebuildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Values keep arriving while Instagram is used behind the sheet.
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) {
                                                              [weakSelf refreshIfChanged];
                                                          }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// MARK: - Data

- (void)reloadGates {
    self.gates = SPKLiquidGlassGateSnapshot();
}

- (NSUInteger)changedCount {
    NSUInteger count = 0;
    for (NSDictionary *gate in self.gates) {
        SPKGateStatus status = SPKGateStatusFor(gate);
        if (status == SPKGateStatusChanged || status == SPKGateStatusWritten)
            count++;
    }
    return count;
}

- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    for (NSDictionary *gate in self.gates) {
        if (SPKGateIsPending(gate))
            count++;
    }
    return count;
}

- (BOOL)showsAll {
    return self.filterControl.selectedSegmentIndex == 1;
}

// The Changed filter keeps whatever is worth acting on: values Sparkle changes,
// values already handed back to Instagram, and switches waiting for a relaunch.
- (BOOL)gateIsInteresting:(NSDictionary *)gate {
    SPKGateStatus status = SPKGateStatusFor(gate);
    return status == SPKGateStatusChanged || status == SPKGateStatusWritten || status == SPKGateStatusLeftToInstagram || SPKGateIsPending(gate);
}

- (void)rebuildSections {
    NSMutableArray<NSArray<NSDictionary *> *> *sections = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *current = nil;
    NSString *group = nil;
    for (NSDictionary *gate in self.gates) {
        if (![self showsAll] && ![self gateIsInteresting:gate])
            continue;
        if (![gate[SPKLiquidGlassGateGroupKey] isEqualToString:group]) {
            group = gate[SPKLiquidGlassGateGroupKey];
            current = [NSMutableArray array];
            [sections addObject:current];
        }
        [current addObject:gate];
    }
    self.sections = sections;
    [self updateSummary];
    [self.tableView reloadData];
}

// Read counts tick on every frame and are not shown, so they never trigger a
// reload; a reload under a finger would cancel a switch mid-flip.
static NSArray *SPKGateVisibleState(NSArray<NSDictionary *> *gates) {
    NSMutableArray *state = [NSMutableArray arrayWithCapacity:gates.count];
    for (NSDictionary *gate in gates) {
        NSMutableDictionary *visible = [gate mutableCopy];
        [visible removeObjectForKey:SPKLiquidGlassGateReadsKey];
        [state addObject:visible];
    }
    return state;
}

- (void)refreshIfChanged {
    NSArray *previous = SPKGateVisibleState(self.gates);
    [self reloadGates];
    if (![previous isEqualToArray:SPKGateVisibleState(self.gates)])
        [self rebuildSections];
}

// MARK: - Header

- (UIView *)buildHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 10)];

    UILabel *summary = [UILabel new];
    summary.numberOfLines = 0;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline] to:summary];
    summary.textColor = UIColor.secondaryLabelColor;
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel = summary;

    UISegmentedControl *filter = [[UISegmentedControl alloc] initWithItems:@[ SPKL(@"DEV_LG_GATES_FILTER_CHANGED"), SPKL(@"DEV_LG_GATES_FILTER_ALL") ]];
    filter.translatesAutoresizingMaskIntoConstraints = NO;
    [filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.filterControl = filter;

    [header addSubview:summary];
    [header addSubview:filter];
    UILayoutGuide *margins = header.layoutMarginsGuide;
    header.layoutMargins = UIEdgeInsetsMake(8, 20, 4, 20);
    [NSLayoutConstraint activateConstraints:@[
        [summary.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [summary.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [summary.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [filter.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:12],
        [filter.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [filter.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [filter.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Table header views do not size themselves.
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                        withHorizontalFittingPriority:UILayoutPriorityRequired
                              verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(header.frame.size.height - size.height) > 0.5 || fabs(header.frame.size.width - width) > 0.5) {
        header.frame = CGRectMake(0, 0, width, size.height);
        self.tableView.tableHeaderView = header;
    }
}

- (void)updateSummary {
    SPKLiquidGlassMode mode = [SPKUtils spk_liquidGlassMode];
    NSString *text;
    if (mode == SPKLiquidGlassModeFollow) {
        text = SPKL(@"DEV_LG_GATES_SUMMARY_DEFAULT_MODE");
    } else {
        NSString *modeText = mode == SPKLiquidGlassModeOn ? SPKL(@"DEV_LG_GATES_VALUE_ON") : SPKL(@"DEV_LG_GATES_VALUE_OFF");
        text = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_SUMMARY_FORCED_FORMAT"), modeText, (unsigned long)[self changedCount]];
    }
    if (![self.summaryLabel.text isEqualToString:text]) {
        self.summaryLabel.text = text;
        [self.view setNeedsLayout];
    }
}

- (void)filterChanged {
    [self rebuildSections];
}

// MARK: - Actions

- (UIMenu *)bulkMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *releaseAll = [UIAction actionWithTitle:SPKL(@"DEV_LG_GATES_RELEASE_ALL")
                                               image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
                                                 SPKLiquidGlassGateSetAllSkippedNextLaunch(YES);
                                                 [weakSelf refreshIfChanged];
                                             }];
    UIAction *forceAll = [UIAction actionWithTitle:SPKL(@"DEV_LG_GATES_FORCE_ALL")
                                             image:[UIImage systemImageNamed:@"lock"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               SPKLiquidGlassGateSetAllSkippedNextLaunch(NO);
                                               [weakSelf refreshIfChanged];
                                           }];
    UIAction *findProblem = [UIAction actionWithTitle:SPKL(@"DEV_LG_TEST_START_ACTION")
                                                image:[UIImage systemImageNamed:@"magnifyingglass"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
                                                  [weakSelf dismissViewControllerAnimated:YES
                                                                               completion:^{
                                                                                   SPKLiquidGlassBisectStart();
                                                                               }];
                                              }];
    UIMenu *bulk = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ releaseAll, forceAll ]];
    return [UIMenu menuWithChildren:@[ findProblem, bulk ]];
}

- (void)shareReport {
    [SPKUtils showShareVC:SPKLiquidGlassGateReport()];
}

- (void)relaunch {
    [[NSUserDefaults standardUserDefaults] synchronize];
    [SPKUtils showRestartConfirmation];
}

- (void)gateSwitchChanged:(UISwitch *)sender {
    NSString *symbol = sender.accessibilityIdentifier;
    if (symbol.length == 0)
        return;
    // On means Sparkle keeps forcing the value; off hands it back to Instagram.
    SPKLiquidGlassGateSetSkippedNextLaunch(symbol, !sender.on);
    [self refreshIfChanged];
}

// MARK: - Table

// The relaunch row sits on top whenever a switch is waiting for one.
- (BOOL)showsRelaunchSection {
    return [self pendingCount] > 0;
}

- (NSInteger)gateSectionOffset {
    return [self showsRelaunchSection] ? 1 : 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSInteger count = (NSInteger)self.sections.count + [self gateSectionOffset];
    return MAX(count, 1);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self showsRelaunchSection] && section == 0)
        return 1;
    NSInteger index = section - [self gateSectionOffset];
    if (index < 0 || index >= (NSInteger)self.sections.count)
        return 0;
    return (NSInteger)self.sections[index].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger index = section - [self gateSectionOffset];
    if (index < 0 || index >= (NSInteger)self.sections.count)
        return nil;
    return SPKGateGroupTitle(self.sections[index].firstObject[SPKLiquidGlassGateGroupKey]);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self showsRelaunchSection] && section == 0)
        return nil;
    if (self.sections.count == 0)
        return [SPKUtils spk_liquidGlassMode] == SPKLiquidGlassModeFollow ? nil : SPKL(@"DEV_LG_GATES_EMPTY_CHANGED");
    if (section == [self numberOfSectionsInTableView:tableView] - 1)
        return SPKL(@"DEV_LG_GATES_LEGEND_FOOTER");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSPKLiquidGlassGatesCellIdentifier forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if ([self showsRelaunchSection] && indexPath.section == 0) {
        UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
        content.text = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_RELAUNCH_FORMAT"), (unsigned long)[self pendingCount]];
        content.textProperties.color = self.view.tintColor;
        content.image = [UIImage systemImageNamed:@"arrow.clockwise"];
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    NSDictionary *gate = self.sections[indexPath.section - [self gateSectionOffset]][indexPath.row];
    NSString *symbol = gate[SPKLiquidGlassGateNameKey];
    SPKGateStatus status = SPKGateStatusFor(gate);
    NSInteger instagramValue = [gate[SPKLiquidGlassGateInstagramValueKey] integerValue];
    NSInteger returnedValue = [gate[SPKLiquidGlassGateReturnedValueKey] integerValue];

    NSString *statusText;
    UIColor *statusColor = UIColor.secondaryLabelColor;
    switch (status) {
    case SPKGateStatusUnavailable:
        statusText = SPKL(@"DEV_LG_GATES_STATUS_UNAVAILABLE");
        break;
    case SPKGateStatusNotRead:
        statusText = SPKL(@"DEV_LG_GATES_STATUS_NOT_READ");
        break;
    case SPKGateStatusChanged:
        statusText = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_STATUS_CHANGED_FORMAT"),
                                                SPKGateValueText(symbol, instagramValue), SPKGateValueText(symbol, returnedValue)];
        statusColor = UIColor.systemOrangeColor;
        break;
    case SPKGateStatusSame:
        statusText = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_STATUS_SAME_FORMAT"), SPKGateValueText(symbol, returnedValue)];
        break;
    case SPKGateStatusWritten:
        statusText = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_STATUS_WRITTEN_FORMAT"), SPKGateValueText(symbol, returnedValue)];
        statusColor = UIColor.systemOrangeColor;
        break;
    case SPKGateStatusLeftToInstagram:
        statusText = [NSString stringWithFormat:SPKL(@"DEV_LG_GATES_STATUS_INSTAGRAM_FORMAT"), SPKGateValueText(symbol, returnedValue)];
        statusColor = UIColor.systemGreenColor;
        break;
    }
    if (SPKGateIsPending(gate)) {
        statusText = [NSString stringWithFormat:@"%@\n%@", statusText, SPKL(@"DEV_LG_GATES_STATUS_PENDING")];
    }

    NSMutableAttributedString *secondary = [[NSMutableAttributedString alloc]
        initWithString:statusText
            attributes:@{NSFontAttributeName : [SPKFont fontForStyle:SPKFontStyleSubheadline], NSForegroundColorAttributeName : statusColor}];
    [secondary appendAttributedString:[[NSAttributedString alloc]
                                          initWithString:[@"\n" stringByAppendingString:symbol]
                                              attributes:@{
                                                  NSFontAttributeName : [SPKFont monospacedFontForStyle:SPKFontStyleCaption2 weight:UIFontWeightRegular],
                                                  NSForegroundColorAttributeName : UIColor.tertiaryLabelColor
                                              }]];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = SPKLiquidGlassGateDisplayName(symbol);
    content.textProperties.font = [SPKFont fontForStyle:SPKFontStyleBody];
    content.secondaryAttributedText = secondary;
    content.textToSecondaryTextVerticalPadding = 3;
    cell.contentConfiguration = content;

    UISwitch *toggle = [UISwitch new];
    toggle.on = ![gate[SPKLiquidGlassGateSkippedNextLaunchKey] boolValue];
    toggle.enabled = status != SPKGateStatusUnavailable;
    toggle.accessibilityIdentifier = symbol;
    [toggle addTarget:self action:@selector(gateSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self showsRelaunchSection] && indexPath.section == 0)
        [self relaunch];
}

@end

#endif
