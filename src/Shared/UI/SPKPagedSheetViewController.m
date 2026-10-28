#import "SPKStrings.h"
#import "SPKPagedSheetViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "SPKGlassButton.h"
#import "SPKBrandHeroView.h"
#import "../../Utils.h"

@implementation SPKPagedSheetPage
+ (instancetype)pageWithTitle:(NSString *)title
                         body:(NSString *)body
                         rows:(NSArray<NSDictionary *> *)rows {
    SPKPagedSheetPage *page = [self new];
    page.title = title;
    page.body = body;
    page.rows = rows;
    return page;
}
@end

#pragma mark - Controller

@interface SPKPagedSheetViewController () <UIScrollViewDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) NSArray<SPKPagedSheetPage *> *pages;
@property (nonatomic, strong) SPKBrandHeroView *heroView;
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) SPKGlassButton *primaryButton;
@property (nonatomic, strong) UIButton *skipButton;
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, assign) BOOL didFinish;
@end

@implementation SPKPagedSheetViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _pages = [self buildPages] ?: @[];
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        // A deliberate intro shouldn't be swipe-dismissable unless the subclass opts in.
        self.modalInPresentation = ![self allowsInteractiveDismiss];
    }
    return self;
}

#pragma mark - Subclass hooks (defaults)

- (NSArray<SPKPagedSheetPage *> *)buildPages { return @[]; }
- (NSString *)continueButtonTitle { return SPKL(@"ALERT_ACTION_CONTINUE"); }
- (NSString *)finishButtonTitle { return SPKL(@"UI_PAGED_SHEET_GET_STARTED_TEXT"); }
- (BOOL)allowsInteractiveDismiss { return NO; }

#pragma mark - Presentation

+ (void)presentFromViewController:(UIViewController *)presenter
                         onFinish:(void (^)(void))onFinish {
    if (!presenter)
        presenter = topMostController();
    if (!presenter || presenter.presentedViewController)
        return;

    SPKPagedSheetViewController *sheet = [[self alloc] init];
    sheet.overrideUserInterfaceStyle = presenter.overrideUserInterfaceStyle;
    sheet.onFinish = onFinish;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    if (self.allowsInteractiveDismiss)
        self.presentationController.delegate = self;

    self.heroView = [[SPKBrandHeroView alloc] initWithFrame:CGRectZero];
    self.heroView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.heroView];

    self.pager = [[UIScrollView alloc] init];
    self.pager.pagingEnabled = YES;
    self.pager.showsHorizontalScrollIndicator = NO;
    self.pager.alwaysBounceVertical = NO;
    self.pager.delegate = self;
    self.pager.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pager];

    self.pageControl = [[UIPageControl alloc] init];
    self.pageControl.numberOfPages = (NSInteger)self.pages.count;
    self.pageControl.currentPage = 0;
    self.pageControl.currentPageIndicatorTintColor = [SPKUtils SPKColor_InstagramBlue];
    self.pageControl.pageIndicatorTintColor = [SPKUtils SPKColor_InstagramSeparator];
    self.pageControl.userInteractionEnabled = NO;
    self.pageControl.hidesForSinglePage = YES;
    self.pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pageControl];

    self.primaryButton = [[SPKGlassButton alloc] initWithFrame:CGRectZero];
    self.primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.primaryButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.primaryButton];

    self.skipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.skipButton setTitle:SPKL(@"VC_BTN_SKIP") forState:UIControlStateNormal];
    [self.skipButton setTitleColor:[SPKUtils SPKColor_InstagramSecondaryText] forState:UIControlStateNormal];
    self.skipButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    self.skipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.skipButton addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.skipButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.heroView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24.0],
        [self.heroView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.heroView.widthAnchor constraintEqualToConstant:92.0],
        [self.heroView.heightAnchor constraintEqualToConstant:92.0],

        [self.pager.topAnchor constraintEqualToAnchor:self.heroView.bottomAnchor constant:16.0],
        [self.pager.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.pager.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.pager.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-4.0],

        [self.pageControl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.pageControl.bottomAnchor constraintEqualToAnchor:self.primaryButton.topAnchor constant:-8.0],

        [self.primaryButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
        [self.primaryButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
        [self.primaryButton.heightAnchor constraintEqualToConstant:50.0],

        // Skip sits directly beneath the primary CTA.
        [self.skipButton.topAnchor constraintEqualToAnchor:self.primaryButton.bottomAnchor constant:8.0],
        [self.skipButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.skipButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10.0],
        [self.skipButton.heightAnchor constraintEqualToConstant:32.0],
    ]];

    // hidesForSinglePage only stops the dots being drawn; the control still
    // reserves its intrinsic height in Auto Layout, leaving an empty strip above
    // the button. A single-page sheet has nothing to page through, so collapse it.
    if (self.pages.count <= 1) {
        [self.pageControl.heightAnchor constraintEqualToConstant:0.0].active = YES;
    }

    [self layoutPages];
    [self updateControlsForPage:0];
}

- (void)layoutPages {
    UIStackView *hStack = [[UIStackView alloc] init];
    hStack.axis = UILayoutConstraintAxisHorizontal;
    hStack.distribution = UIStackViewDistributionFillEqually;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pager addSubview:hStack];

    [NSLayoutConstraint activateConstraints:@[
        [hStack.topAnchor constraintEqualToAnchor:self.pager.contentLayoutGuide.topAnchor],
        [hStack.bottomAnchor constraintEqualToAnchor:self.pager.contentLayoutGuide.bottomAnchor],
        [hStack.leadingAnchor constraintEqualToAnchor:self.pager.contentLayoutGuide.leadingAnchor],
        [hStack.trailingAnchor constraintEqualToAnchor:self.pager.contentLayoutGuide.trailingAnchor],
        [hStack.heightAnchor constraintEqualToAnchor:self.pager.frameLayoutGuide.heightAnchor],
    ]];

    for (SPKPagedSheetPage *page in self.pages) {
        UIScrollView *pageView = [self viewForPage:page];
        pageView.translatesAutoresizingMaskIntoConstraints = NO;
        [hStack addArrangedSubview:pageView];
        [pageView.widthAnchor constraintEqualToAnchor:self.pager.frameLayoutGuide.widthAnchor].active = YES;
    }
}

- (UIScrollView *)viewForPage:(SPKPagedSheetPage *)page {
    // Each page scrolls vertically: on small screens (e.g. iPhone SE/8) the hero +
    // title + a long list can exceed the fixed paging region, so the content must
    // scroll rather than be compressed or clipped. On tall screens it simply sits
    // at the top with room to spare and never needs to scroll.
    UIScrollView *container = [[UIScrollView alloc] init];
    container.showsVerticalScrollIndicator = NO;
    container.alwaysBounceVertical = NO;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = page.title;
    titleLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightBold];
    titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    [titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [stack addArrangedSubview:titleLabel];

    // Only add the body label when there's copy — an empty label would otherwise
    // eat its spacing and leave a dead gap between the title and the list.
    UIView *lastHeaderView = titleLabel;
    if (page.body.length > 0) {
        UILabel *bodyLabel = [[UILabel alloc] init];
        bodyLabel.text = page.body;
        bodyLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        bodyLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        bodyLabel.textAlignment = NSTextAlignmentCenter;
        bodyLabel.numberOfLines = 0;
        [stack setCustomSpacing:12.0 afterView:titleLabel];
        [stack addArrangedSubview:bodyLabel];
        lastHeaderView = bodyLabel;
    }

    if (page.rows.count > 0) {
        UIStackView *rowStack = [[UIStackView alloc] init];
        rowStack.axis = UILayoutConstraintAxisVertical;
        rowStack.alignment = UIStackViewAlignmentLeading;
        rowStack.spacing = 14.0;
        for (NSDictionary *row in page.rows) {
            [rowStack addArrangedSubview:[self rowForEntry:row]];
        }
        [stack addArrangedSubview:rowStack];
        [stack setCustomSpacing:24.0 afterView:lastHeaderView];
    }

    UILayoutGuide *content = container.contentLayoutGuide;
    UILayoutGuide *frame = container.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // Pin the stack to the scroll content so content height drives scrolling.
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:12.0],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16.0],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-32.0],
        // Lock the content width to the frame so it only ever scrolls vertically.
        [stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-64.0],
    ]];

    return container;
}

- (UIView *)rowForEntry:(NSDictionary *)entry {
    NSString *iconName = entry[@"icon"];
    NSString *text = entry[@"text"];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;

    // A row with no glyph is a "closer" teaser (e.g. "…and so much more!") rather
    // than a concrete item: keep its text aligned under the other rows via an empty
    // icon-width spacer, and give it an accented italic treatment.
    BOOL isTeaser = (iconName.length == 0);
    static const CGFloat kIconSize = 24.0;

    UIImage *glyph = nil;
    NSString *fallbackSymbol = entry[@"symbol"];
    if (iconName.length > 0 && fallbackSymbol.length > 0) {
        // Glyphs missing from older Instagram builds fall back to the entry's SF Symbol
        // instead of the generic placeholder.
        glyph = [SPKAssetUtils resolvedImageNamed:iconName
                               fallbackSystemName:fallbackSymbol
                                        pointSize:0
                                           weight:UIImageSymbolWeightSemibold
                                           source:SPKResolvedImageSourceInstagramIcon
                                    renderingMode:UIImageRenderingModeAlwaysTemplate];
    } else if (iconName.length > 0) {
        // Load the pristine catalog image at native size (pointSize 0 = no rasterising
        // downscale), the same path menuIconNamed: relies on. Forcing a smaller point
        // size routes vector-backed (.svg) glyphs through a renderer downscale that
        // iOS 16 refuses to draw, leaving them blank.
        glyph = [SPKAssetUtils instagramIconNamed:iconName
                                        pointSize:0
                                           source:SPKAssetCatalogSourceAutomatic
                                    renderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    if (glyph) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:glyph];
        icon.tintColor = [SPKUtils SPKColor_InstagramBlue];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [icon.widthAnchor constraintEqualToConstant:kIconSize].active = YES;
        [icon.heightAnchor constraintEqualToConstant:kIconSize].active = YES;
        [row addArrangedSubview:icon];
    } else {
        UIView *spacer = [[UIView alloc] init];
        spacer.translatesAutoresizingMaskIntoConstraints = NO;
        [spacer.widthAnchor constraintEqualToConstant:kIconSize].active = YES;
        [row addArrangedSubview:spacer];
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    if (isTeaser) {
        UIFont *base = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        UIFontDescriptor *italicDescriptor = [base.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        label.font = italicDescriptor ? [UIFont fontWithDescriptor:italicDescriptor size:16.0] : base;
        label.textColor = [SPKUtils SPKColor_InstagramBlue];
    } else {
        label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    }
    [row addArrangedSubview:label];

    return row;
}

#pragma mark - Paging

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Only the horizontal pager drives the hero; per-page vertical scrolls are ignored.
    if (scrollView != self.pager)
        return;

    CGFloat width = scrollView.bounds.size.width;
    if (width <= 0.0)
        return;
    CGFloat progress = scrollView.contentOffset.x / width;
    [self.heroView setPageProgress:progress];

    if (scrollView.isDragging || scrollView.isDecelerating) {
        NSInteger page = (NSInteger)lround(scrollView.contentOffset.x / width);
        page = MAX(0, MIN(page, (NSInteger)self.pages.count - 1));
        if (page != self.currentPage)
            [self updateControlsForPage:page];
    }
}

- (void)updateControlsForPage:(NSInteger)page {
    self.currentPage = page;
    self.pageControl.currentPage = page;
    BOOL isLast = (page == (NSInteger)self.pages.count - 1);
    NSString *finishTitle = self.finishTitleOverride.length > 0 ? self.finishTitleOverride : [self finishButtonTitle];
    [self.primaryButton setTextAnimated:(isLast ? finishTitle : [self continueButtonTitle])];
    self.skipButton.hidden = isLast;
}

- (void)primaryTapped {
    if (self.currentPage >= (NSInteger)self.pages.count - 1) {
        [self finish];
        return;
    }
    NSInteger next = self.currentPage + 1;
    [self updateControlsForPage:next];

    CGPoint offset = CGPointMake(self.pager.bounds.size.width * next, 0.0);
    [self.pager setContentOffset:offset animated:YES];
}

- (void)finish {
    if (self.didFinish)
        return;
    self.didFinish = YES;
    void (^completion)(void) = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion)
            completion();
    }];
}

#pragma mark - Interactive dismiss

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    // A swipe-down counts as finishing so state is stamped just like tapping the CTA.
    if (self.didFinish)
        return;
    self.didFinish = YES;
    if (self.onFinish)
        self.onFinish();
}

@end
