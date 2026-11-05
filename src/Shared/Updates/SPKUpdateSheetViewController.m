#import "SPKStrings.h"
#import "SPKUpdateSheetViewController.h"
#import "SPKChangelogView.h"
#import "SPKUpdateChecker.h"
#import "../UI/SPKBrandHeroView.h"
#import "../UI/SPKGlassButton.h"
#import "../../Utils.h"

static const CGFloat kSPKUpdateSheetTopInset = 32.0;
static const CGFloat kSPKUpdateSheetBottomInset = 10.0;
static const CGFloat kSPKUpdateSheetSideInset = 24.0;
static const CGFloat kSPKUpdateSheetHeaderToActions = 22.0;
// How far past its compact height the sheet travels before the changelog has fully replaced the
// version header. A short distance, so the swap reads as one motion with the sheet growing.
static const CGFloat kSPKUpdateSheetMorphDistance = 160.0;
static NSString *const kSPKUpdateSheetCompactDetent = @"spk.update.compact";
// The changelog ends this far above the buttons, where a hairline marks the edge.
static const CGFloat kSPKUpdateSheetActionsBarGap = 12.0;

@interface SPKUpdateSheetViewController () <UISheetPresentationControllerDelegate>
@property (nonatomic, strong) UIStackView *headerStack;
@property (nonatomic, strong) UIStackView *actionsStack;
@property (nonatomic, strong) SPKChangelogView *changelogView;
@property (nonatomic, strong) UIView *actionsHairline;
@property (nonatomic, strong) UIImageView *swipeHintChevron;
@property (nonatomic, assign) CGFloat measuredWidth;
@property (nonatomic, assign) BOOL announce;
@property (nonatomic, assign) BOOL hasAppeared;
@property (nonatomic, strong) UIImpactFeedbackGenerator *softImpact;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@end

@implementation SPKUpdateSheetViewController

+ (void)presentFromViewController:(nullable UIViewController *)presenter {
    [self presentFromViewController:presenter announce:NO];
}

+ (void)presentFromViewController:(nullable UIViewController *)presenter announce:(BOOL)announce {
    UIViewController *from = presenter ?: topMostController();
    if (!from || from.presentedViewController)
        return;
    SPKUpdateSheetViewController *sheet = [SPKUpdateSheetViewController new];
    sheet.announce = announce;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    // Unprompted, a stray tap above the sheet or a downward flick would throw it away unread, so
    // only the buttons close it. A drag still moves it between its two heights. Opened from About,
    // it was asked for and dismisses normally.
    sheet.modalInPresentation = announce;
    sheet.overrideUserInterfaceStyle = from.overrideUserInterfaceStyle;
    [from presentViewController:sheet animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    NSString *latest = [SPKUpdateChecker displayVersion:[SPKUpdateChecker latestKnownVersion] ?: @""];
    NSString *installed = [SPKUpdateChecker displayVersion:[SPKUpdateChecker installedVersion]];

    // Header: what is new and what is installed. Fades out as the sheet grows into the changelog.
    SPKBrandHeroView *hero = [[SPKBrandHeroView alloc] initWithFrame:CGRectZero];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [hero.widthAnchor constraintEqualToConstant:76.0],
        [hero.heightAnchor constraintEqualToConstant:76.0],
    ]];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = [NSString stringWithFormat:SPKL(@"UPDATE_SHEET_TITLE_FORMAT"), latest];
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [UILabel new];
    bodyLabel.text = [NSString stringWithFormat:SPKL(@"UPDATE_SHEET_INSTALLED_FORMAT"), installed];
    bodyLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    bodyLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    bodyLabel.textAlignment = NSTextAlignmentCenter;
    bodyLabel.numberOfLines = 0;

    UIControl *swipeHint = [self swipeHintControl];

    self.headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[ hero, titleLabel, bodyLabel, swipeHint ]];
    self.headerStack.axis = UILayoutConstraintAxisVertical;
    self.headerStack.alignment = UIStackViewAlignmentCenter;
    self.headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerStack setCustomSpacing:18.0 afterView:hero];
    [self.headerStack setCustomSpacing:6.0 afterView:titleLabel];
    [self.headerStack setCustomSpacing:14.0 afterView:bodyLabel];
    [self.view addSubview:self.headerStack];

    // Actions: stay pinned to the bottom in both states, so the changelog can be read and acted on.
    SPKGlassButton *updateButton = [[SPKGlassButton alloc] initWithFrame:CGRectZero];
    // Sideloaded builds are published on the Telegram channel, so say where the button goes.
    [updateButton setText:[SPKUpdateChecker isJailbreakInstall] ? SPKL(@"UPDATE_SHEET_ACTION_UPDATE") : SPKL(@"UPDATE_SHEET_ACTION_TELEGRAM")];
    updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [updateButton addTarget:self action:@selector(updateTapped) forControlEvents:UIControlEventTouchUpInside];
    [updateButton.heightAnchor constraintEqualToConstant:50.0].active = YES;

    UIButton *notNowButton = [self secondaryButtonWithTitle:SPKL(@"ALERT_ACTION_NOT_NOW") action:@selector(notNowTapped)];
    UIButton *skipButton = [self secondaryButtonWithTitle:[NSString stringWithFormat:SPKL(@"UPDATE_SHEET_SKIP_VERSION_FORMAT"), latest]
                                                   action:@selector(skipTapped)];
    UIStackView *secondaryRow = [[UIStackView alloc] initWithArrangedSubviews:@[ notNowButton, skipButton ]];
    secondaryRow.axis = UILayoutConstraintAxisHorizontal;
    secondaryRow.distribution = UIStackViewDistributionFillEqually;
    secondaryRow.spacing = 12.0;
    [secondaryRow.heightAnchor constraintEqualToConstant:36.0].active = YES;

    self.actionsStack = [[UIStackView alloc] initWithArrangedSubviews:@[ updateButton, secondaryRow ]];
    self.actionsStack.axis = UILayoutConstraintAxisVertical;
    self.actionsStack.spacing = 6.0;
    self.actionsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionsStack];

    // The changelog fills the expanded sheet down to the hairline over the buttons, opening on what
    // the update adds. Loaded as soon as the sheet is up.
    self.changelogView = [[SPKChangelogView alloc] initWithOptions:SPKChangelogOptionFoldInstalled];
    self.changelogView.translatesAutoresizingMaskIntoConstraints = NO;
    self.changelogView.alpha = 0.0;
    [self.view insertSubview:self.changelogView belowSubview:self.actionsStack];

    // Marks where the changelog stops above the buttons, once it is showing.
    self.actionsHairline = [UIView new];
    self.actionsHairline.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionsHairline.backgroundColor = [SPKUtils SPKColor_InstagramSeparator];
    self.actionsHairline.alpha = 0.0;
    [self.view addSubview:self.actionsHairline];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.actionsStack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kSPKUpdateSheetBottomInset],
        [self.actionsStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:kSPKUpdateSheetSideInset],
        [self.actionsStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-kSPKUpdateSheetSideInset],

        // The header sits on the actions, so a taller sheet only adds space above it.
        [self.headerStack.bottomAnchor constraintEqualToAnchor:self.actionsStack.topAnchor constant:-kSPKUpdateSheetHeaderToActions],
        [self.headerStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:kSPKUpdateSheetSideInset],
        [self.headerStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-kSPKUpdateSheetSideInset],
        [titleLabel.widthAnchor constraintEqualToAnchor:self.headerStack.widthAnchor],
        [bodyLabel.widthAnchor constraintEqualToAnchor:self.headerStack.widthAnchor],

        [self.changelogView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.changelogView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.changelogView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Ends at the hairline, so the notes never run under the buttons.
        [self.changelogView.bottomAnchor constraintEqualToAnchor:self.actionsHairline.topAnchor],

        [self.actionsHairline.bottomAnchor constraintEqualToAnchor:self.actionsStack.topAnchor constant:-kSPKUpdateSheetActionsBarGap],
        [self.actionsHairline.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.actionsHairline.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.actionsHairline.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
    ]];

    self.softImpact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    self.selectionFeedback = [UISelectionFeedbackGenerator new];
    // Woken here rather than in -viewWillAppear:, so the arrival tap is ready the moment the
    // sheet starts to rise.
    [self.softImpact prepare];

    // Entrance start state (see -animateEntrance). The header's own alpha belongs to the morph, so
    // the entrance fades its rows instead.
    for (UIView *row in self.headerStack.arrangedSubviews)
        row.alpha = 0.0;
    self.headerStack.transform = CGAffineTransformMakeScale(0.9, 0.9);
    self.actionsStack.alpha = 0.0;
    self.actionsStack.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    [self configureSheet];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.selectionFeedback prepare];
    if (!self.hasAppeared) {
        // A single gentle tap as the sheet starts to rise, only when it arrives unprompted. Fired
        // here because -viewDidAppear: only runs once the slide has already finished.
        if (self.announce) {
            [self.softImpact impactOccurredWithIntensity:0.65];
            [self.softImpact prepare];
        }
        // Runs with the slide rather than after it, so the sheet never rises empty.
        [self animateEntrance];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.hasAppeared)
        return;
    self.hasAppeared = YES;
    [self nudgeSwipeHint];
    // Load the changelog while the version is being read, so growing the sheet reveals a page that
    // is already drawn. Only once the sheet is up, so building the web view cannot stall the slide.
    [self.changelogView loadIfNeeded];
}

/// While the sheet slides up, the header grows into place and the buttons rise in just behind it.
- (void)animateEntrance {
    void (^showHeader)(void) = ^{
        for (UIView *row in self.headerStack.arrangedSubviews)
            row.alpha = 1.0;
        self.headerStack.transform = CGAffineTransformIdentity;
    };
    void (^showActions)(void) = ^{
        self.actionsStack.alpha = 1.0;
        self.actionsStack.transform = CGAffineTransformIdentity;
    };
    if (UIAccessibilityIsReduceMotionEnabled()) {
        showHeader();
        showActions();
        return;
    }
    [UIView animateWithDuration:0.5
                          delay:0.0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:showHeader
                     completion:nil];
    [UIView animateWithDuration:0.4
                          delay:0.1
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:showActions
                     completion:nil];
}

/// The way into the changelog is dragging the sheet up, so the header says so instead of offering
/// a button. Still a control, so a tap (and VoiceOver's activate) opens it too.
- (UIControl *)swipeHintControl {
    UIControl *control = [UIControl new];
    control.isAccessibilityElement = YES;
    control.accessibilityTraits = UIAccessibilityTraitButton;
    control.accessibilityLabel = SPKL(@"UPDATE_SHEET_CHANGELOG_SWIPE_HINT");
    [control addTarget:self action:@selector(changelogTapped) forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.compact.up" withConfiguration:config]];
    chevron.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    chevron.contentMode = UIViewContentModeCenter;
    self.swipeHintChevron = chevron;

    UILabel *label = [UILabel new];
    label.text = SPKL(@"UPDATE_SHEET_CHANGELOG_SWIPE_HINT");
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ chevron, label ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 0.0;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [control addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:control.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:control.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:control.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:control.trailingAnchor],
    ]];
    return control;
}

/// Lifts the chevron a few points twice once the sheet has settled, so the hint reads as a
/// direction to drag rather than a label.
- (void)nudgeSwipeHint {
    if (UIAccessibilityIsReduceMotionEnabled())
        return;
    UIImageView *chevron = self.swipeHintChevron;
    [UIView animateKeyframesWithDuration:1.6
                                   delay:0.3
                                 options:UIViewKeyframeAnimationOptionCalculationModeCubic | UIViewKeyframeAnimationOptionAllowUserInteraction
                              animations:^{
                                  [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:0.25 animations:^{
                                      chevron.transform = CGAffineTransformMakeTranslation(0.0, -5.0);
                                  }];
                                  [UIView addKeyframeWithRelativeStartTime:0.25 relativeDuration:0.25 animations:^{
                                      chevron.transform = CGAffineTransformIdentity;
                                  }];
                                  [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.25 animations:^{
                                      chevron.transform = CGAffineTransformMakeTranslation(0.0, -5.0);
                                  }];
                                  [UIView addKeyframeWithRelativeStartTime:0.75 relativeDuration:0.25 animations:^{
                                      chevron.transform = CGAffineTransformIdentity;
                                  }];
                              }
                              completion:nil];
}

- (UIButton *)secondaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[SPKUtils SPKColor_InstagramSecondaryText] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Sheet

- (CGFloat)compactHeight {
    CGFloat width = self.view.bounds.size.width > 0.0 ? self.view.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat contentWidth = width - self.view.safeAreaInsets.left - self.view.safeAreaInsets.right - 2.0 * kSPKUpdateSheetSideInset;
    CGSize fitting = CGSizeMake(contentWidth, UILayoutFittingCompressedSize.height);
    CGFloat header = [self.headerStack systemLayoutSizeFittingSize:fitting
                                     withHorizontalFittingPriority:UILayoutPriorityRequired
                                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                         .height;
    CGFloat actions = [self.actionsStack systemLayoutSizeFittingSize:fitting
                                       withHorizontalFittingPriority:UILayoutPriorityRequired
                                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                          .height;
    return ceil(kSPKUpdateSheetTopInset + header + kSPKUpdateSheetHeaderToActions + actions + kSPKUpdateSheetBottomInset);
}

/// Two heights: compact for the version, full for the changelog. Dragging up is the same as
/// tapping the swipe hint, so the stretch the system gives a sheet's top edge leads somewhere.
- (void)configureSheet {
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (!sheet)
        return;
    sheet.delegate = self;
    sheet.prefersGrabberVisible = NO;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    if (@available(iOS 16.0, *)) {
        __weak __typeof(self) weakSelf = self;
        UISheetPresentationControllerDetent *compact =
            [UISheetPresentationControllerDetent customDetentWithIdentifier:kSPKUpdateSheetCompactDetent
                                                                   resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                                                       CGFloat height = weakSelf ? [weakSelf compactHeight] : context.maximumDetentValue;
                                                                       return MIN(height, context.maximumDetentValue);
                                                                   }];
        sheet.detents = @[ compact, UISheetPresentationControllerDetent.largeDetent ];
        sheet.selectedDetentIdentifier = kSPKUpdateSheetCompactDetent;
    } else {
        // iOS 15 has no custom heights; half height holds the version on every iPhone.
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    if (width > 0.0 && width != self.measuredWidth) {
        // Text wraps differently at the sheet's real width (and after rotation), so measure again.
        self.measuredWidth = width;
        if (@available(iOS 16.0, *))
            [self.sheetPresentationController invalidateDetents];
    }
    [self updateMorph];
}

/// Crossfades the version header into the changelog by how far the sheet has grown past its
/// compact height. Driven by layout, so a drag scrubs it and a detent change animates it.
- (void)updateMorph {
    CGFloat grown = self.view.bounds.size.height - [self compactHeight] - self.view.safeAreaInsets.bottom;
    CGFloat progress = MIN(MAX(grown / kSPKUpdateSheetMorphDistance, 0.0), 1.0);
    if (progress > 0.0)
        [self.changelogView loadIfNeeded];
    self.headerStack.alpha = 1.0 - MIN(progress * 1.6, 1.0);
    // All three buttons stay under the changelog, so it can be skipped or dismissed from there too.
    self.changelogView.alpha = MAX(progress * 1.6 - 0.6, 0.0);
    self.actionsHairline.alpha = self.changelogView.alpha;
}

- (void)expandToChangelog {
    UISheetPresentationController *sheet = self.sheetPresentationController;
    [self.changelogView loadIfNeeded];
    [sheet animateChanges:^{
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
    }];
}

#pragma mark - Actions

- (void)changelogTapped {
    [self softTap];
    [self expandToChangelog];
}

- (void)softTap {
    [self.softImpact impactOccurred];
    [self.softImpact prepare];
}

- (void)selectionTick {
    [self.selectionFeedback selectionChanged];
    [self.selectionFeedback prepare];
}

- (void)updateTapped {
    [self softTap];
    [self dismissViewControllerAnimated:YES completion:^{
        [SPKUpdateChecker openUpdateDestination];
    }];
}

- (void)notNowTapped {
    [self selectionTick];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)skipTapped {
    [self selectionTick];
    [SPKUpdateChecker skipLatestVersion];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
