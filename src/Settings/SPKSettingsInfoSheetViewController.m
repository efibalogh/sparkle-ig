#import "SPKSettingsInfoSheetViewController.h"

#import "SPKSetting.h"
#import "SPKStrings.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Utils.h"

static CGFloat const kSPKInfoSheetHorizontalInset = 24.0;
static CGFloat const kSPKInfoSheetTopPadding = 20.0;
static CGFloat const kSPKInfoSheetBottomPadding = 20.0;
static CGFloat const kSPKInfoSheetEntrySpacing = 22.0;
static CGFloat const kSPKInfoSheetTitleBodySpacing = 3.0;
static CGFloat const kSPKInfoSheetIconSize = 22.0;
static CGFloat const kSPKInfoSheetIconGutter = 14.0;
// Grabber plus title bar: the detent sizes the whole sheet, not just its scroll
// view, so the chrome above the content has to be paid for too.
static CGFloat const kSPKInfoSheetChromeHeight = 60.0;
static CGFloat const kSPKInfoSheetMinimumHeight = 180.0;

NSString *const SPKTopicSectionInfoSheetKey = @"spk_usesInfoSheet";

NSArray<SPKSetting *> *SPKSettingsHelpRowsInSection(NSDictionary *section) {
    if (![section isKindOfClass:[NSDictionary class]])
        return @[];

    NSArray *rows = section[@"rows"];
    if (![rows isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray<SPKSetting *> *helpRows = [NSMutableArray array];
    for (SPKSetting *row in rows) {
        if (![row isKindOfClass:[SPKSetting class]])
            continue;
        if (row.helpText.length == 0)
            continue;
        // A row removed from the table is removed from its own explanation too.
        // This is the whole point of hanging help off the row rather than
        // listing it separately in a footer.
        if (row.hiddenProvider && row.hiddenProvider())
            continue;
        [helpRows addObject:row];
    }
    return [helpRows copy];
}

/// Laid-out height of `text` at `width`, with no view involved.
static CGFloat SPKInfoSheetTextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (text.length == 0 || !font)
        return 0.0;

    CGRect bounds = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                    attributes:@{NSFontAttributeName : font}
                                       context:nil];
    return ceil(CGRectGetHeight(bounds));
}

// MARK: - Sheet

@interface SPKSettingsInfoSheetViewController ()

@property (nonatomic, copy) NSArray<SPKSetting *> *rows;
@property (nonatomic, strong) UIStackView *entryStack;
@property (nonatomic, strong) UIScrollView *scrollView;
/// Height of the assembled sheet as actually laid out, or 0 before the first
/// layout pass. Preferred over the estimate once it lands.
@property (nonatomic, assign) CGFloat spk_measuredSheetHeight;

- (CGFloat)spk_contentHeightForWidth:(CGFloat)width;
- (CGFloat)spk_sheetHeightForWidth:(CGFloat)width;

@end

@implementation SPKSettingsInfoSheetViewController

- (instancetype)initWithTitle:(NSString *)title rows:(NSArray<SPKSetting *> *)rows {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.title = title;
        _rows = [rows copy];
    }
    return self;
}

/// Whether any row in the sheet has an icon. When none do, the gutter that
/// keeps titles aligned would just indent every line for nothing.
- (BOOL)spk_reservesIconGutter {
    for (SPKSetting *row in self.rows) {
        if (row.title.length == 0)
            continue;
        if (row.iconProvider ? row.iconProvider() : row.icon)
            return YES;
    }
    return NO;
}

- (UIView *)spk_viewForRow:(SPKSetting *)row {
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *bodyLabel = [UILabel new];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = row.helpText;
    bodyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    bodyLabel.adjustsFontForContentSizeCategory = YES;
    bodyLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    bodyLabel.numberOfLines = 0;
    [container addSubview:bodyLabel];

    // A row with no title of its own (a note about the section as a whole)
    // runs the full width with no icon gutter and no heading.
    if (row.title.length == 0) {
        [NSLayoutConstraint activateConstraints:@[
            [bodyLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [bodyLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [bodyLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
            [bodyLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
        ]];
        return container;
    }

    UIFont *subheadline = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = row.title;
    titleLabel.font = [UIFont systemFontOfSize:subheadline.pointSize weight:UIFontWeightSemibold];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    titleLabel.numberOfLines = 0;
    [container addSubview:titleLabel];

    // Once one row in the sheet has an icon the gutter is reserved for all of
    // them, so every title starts on the same line. A sheet with no icons at
    // all keeps its text flush left instead.
    NSLayoutXAxisAnchor *textLeading = container.leadingAnchor;
    CGFloat textInset = [self spk_reservesIconGutter] ? (kSPKInfoSheetIconSize + kSPKInfoSheetIconGutter) : 0.0;
    UIImage *icon = row.iconProvider ? row.iconProvider() : row.icon;
    if (icon) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.tintColor = row.iconTintColor ?: [SPKUtils SPKColor_InstagramPrimaryText];
        [container addSubview:iconView];
        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            // A point down from the top so the glyph reads as centred on the
            // title's cap height rather than sitting proud of it.
            [iconView.topAnchor constraintEqualToAnchor:container.topAnchor constant:1.0],
            [iconView.widthAnchor constraintEqualToConstant:kSPKInfoSheetIconSize],
            [iconView.heightAnchor constraintEqualToConstant:kSPKInfoSheetIconSize]
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:textLeading constant:textInset],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor],

        [bodyLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:kSPKInfoSheetTitleBodySpacing],
        [bodyLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ]];

    return container;
}

/// Height of the assembled content, used by the fitted detent so a two-entry
/// sheet does not open as tall as an eight-entry one.
///
/// Measured from the text rather than from the view hierarchy: a detent
/// resolver runs mid-layout, so laying the sheet out from inside one is not
/// allowed and makes UIKit fall back to its default detents.
- (CGFloat)spk_contentHeightForWidth:(CGFloat)width {
    if (width <= 0.0) {
        width = CGRectGetWidth(UIScreen.mainScreen.bounds);
    }

    UIFont *subheadline = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    UIFont *titleFont = [UIFont systemFontOfSize:subheadline.pointSize weight:UIFontWeightSemibold];
    UIFont *bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];

    CGFloat contentWidth = MAX(width - (kSPKInfoSheetHorizontalInset * 2.0), 1.0);
    CGFloat gutter = [self spk_reservesIconGutter] ? (kSPKInfoSheetIconSize + kSPKInfoSheetIconGutter) : 0.0;
    CGFloat textWidth = MAX(contentWidth - gutter, 1.0);

    CGFloat total = 0.0;
    for (SPKSetting *row in self.rows) {
        BOOL titled = row.title.length > 0;
        CGFloat entryWidth = titled ? textWidth : contentWidth;
        if (titled) {
            total += SPKInfoSheetTextHeight(row.title, titleFont, entryWidth) + kSPKInfoSheetTitleBodySpacing;
        }
        total += SPKInfoSheetTextHeight(row.helpText, bodyFont, entryWidth);
    }

    NSInteger gaps = (NSInteger)self.rows.count - 1;
    if (gaps > 0) {
        total += kSPKInfoSheetEntrySpacing * (CGFloat)gaps;
    }

    // The sheet presentation already accounts for its bottom safe area. Adding
    // the presenting window's inset here makes the fitted stop visibly too tall.
    return total + kSPKInfoSheetTopPadding + kSPKInfoSheetBottomPadding + kSPKInfoSheetChromeHeight;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;

    UIScrollView *scrollView = [UIScrollView new];
    self.scrollView = scrollView;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    // Scrolling is armed in -viewDidLayoutSubviews, and only when the
    // explanation is taller than the stop the sheet settled on.
    scrollView.alwaysBounceVertical = NO;
    // Runs the full height of the sheet, under the navigation bar, so the bar
    // picks up its own scroll-edge treatment: Liquid Glass on iOS 26, and the
    // solid Instagram background with a hairline on iOS 18 and lower. The safe
    // area (which includes the bar) supplies the content inset.
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:scrollView];

    self.entryStack = [UIStackView new];
    self.entryStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.entryStack.axis = UILayoutConstraintAxisVertical;
    self.entryStack.alignment = UIStackViewAlignmentFill;
    self.entryStack.spacing = kSPKInfoSheetEntrySpacing;
    [scrollView addSubview:self.entryStack];

    for (SPKSetting *row in self.rows) {
        [self.entryStack addArrangedSubview:[self spk_viewForRow:row]];
    }

    UILayoutGuide *content = scrollView.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.entryStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:kSPKInfoSheetTopPadding],
        [self.entryStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-kSPKInfoSheetBottomPadding],
        [self.entryStack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:kSPKInfoSheetHorizontalInset],
        [self.entryStack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-kSPKInfoSheetHorizontalInset]
    ]];
}

/// The height the detent should resolve to: the measured one once there is a
/// layout to measure, and the text estimate only until then.
- (CGFloat)spk_sheetHeightForWidth:(CGFloat)width {
    if (self.spk_measuredSheetHeight > 0.0)
        return self.spk_measuredSheetHeight;
    return [self spk_contentHeightForWidth:width];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // The estimate is measured from the text rather than from the view tree, so
    // it can land a few points short of the real layout: enough for the sheet to
    // need a scroll it visibly should not need, which costs a gesture to
    // discover. Once there is a laid-out height, hand it to the resolver and let
    // the sheet settle on it.
    CGFloat measured = [SPKUtils sheetHeightFittingContentOfScrollView:self.scrollView];
    if (measured > 0.0 && fabs(measured - self.spk_measuredSheetHeight) > 0.5) {
        self.spk_measuredSheetHeight = measured;
        if (@available(iOS 16.0, *)) {
            // Height does not feed back into the wrap width, so the next pass
            // measures the same content and this settles after one round.
            [self.navigationController.sheetPresentationController invalidateDetents];
        }
    }

    [SPKUtils updateScrollingForFittedContent:self.scrollView];
}

// MARK: - Presentation

+ (void)presentFromViewController:(UIViewController *)presenter
                            title:(NSString *)title
                             rows:(NSArray<SPKSetting *> *)rows {
    if (!presenter || rows.count == 0)
        return;

    SPKSettingsInfoSheetViewController *vc = [[self alloc] initWithTitle:title rows:rows];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    sheet.prefersGrabberVisible = YES;
    if (@available(iOS 16.0, *)) {
        // A single detent, exactly as tall as the explanation needs. There is
        // nothing to expand into: a sheet longer than the screen is clamped to
        // the maximum and scrolls in place.
        __weak SPKSettingsInfoSheetViewController *weakVC = vc;
        __weak UINavigationController *weakNav = nav;
        UISheetPresentationControllerDetent *fitted =
            [UISheetPresentationControllerDetent customDetentWithIdentifier:@"spk.settings.info.fitted"
                                                                   resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                                                       SPKSettingsInfoSheetViewController *strongVC = weakVC;
                                                                       UINavigationController *strongNav = weakNav;
                                                                       if (!strongVC || !strongNav)
                                                                           return context.maximumDetentValue * 0.5;

                                                                       CGFloat height = [strongVC spk_sheetHeightForWidth:CGRectGetWidth(strongNav.view.bounds)];
                                                                       return MIN(MAX(height, kSPKInfoSheetMinimumHeight), context.maximumDetentValue);
                                                                   }];
        sheet.detents = @[ fitted ];
    } else {
        // iOS 15 has no custom detents, so the closest fixed stop has to do.
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
    }

    // Settings can be presented over Instagram surfaces that force their own
    // style; inherit the presenter's so the sheet doesn't flip light/dark.
    UIUserInterfaceStyle style = presenter.view.window.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = presenter.traitCollection.userInterfaceStyle;
    }
    if (style != UIUserInterfaceStyleUnspecified) {
        nav.overrideUserInterfaceStyle = style;
        vc.overrideUserInterfaceStyle = style;
    }

    [presenter presentViewController:nav animated:YES completion:nil];
}

@end
