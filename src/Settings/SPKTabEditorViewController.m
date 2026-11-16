#import "SPKStrings.h"
#import "SPKTabEditorViewController.h"
#import "SPKPreferenceAvailability.h"
#import "SPKPreferences.h"

#import "../AssetUtils.h"
#import "../Shared/Navigation/SPKTabConfiguration.h"
#import "../Shared/UI/SPKChipBar.h"
#import "../Shared/UI/SPKChipGlass.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Shared/UI/SPKSwitch.h"
#import "../Utils.h"
#import "../Features/Interface/SPKNativeTabBar.h"

static CGFloat const SPKTabEditorGlyphSize = 24.0;

typedef NS_ENUM(NSInteger, SPKTabEditorSection) {
    SPKTabEditorSectionTabs,
    SPKTabEditorSectionBehavior,
    SPKTabEditorSectionSingleTab,
    SPKTabEditorSectionDiscard,
    SPKTabEditorSectionReset,
    SPKTabEditorSectionCount,
};

static UIImage *SPKTabEditorGlyph(NSString *iconName) {
    UIImage *image = [SPKAssetUtils instagramIconNamed:iconName pointSize:SPKTabEditorGlyphSize];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Preview

// A miniature, non-interactive tab bar. It is the whole point of this screen:
// every staged change is visible here before anything is written, so the user
// never has to restart Instagram to find out what a layout actually looks like.
@interface SPKTabBarPreviewView : UIView
@property (nonatomic, strong) UIStackView *barStack;
@property (nonatomic, strong) UIView *headerStrip;
@property (nonatomic, strong) UIImageView *headerMessagesView;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation SPKTabBarPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:card];

    // Classic keeps Messages in the feed header rather than the bar, so the
    // preview grows a header strip to show where it lands.
    _headerStrip = [[UIView alloc] init];
    _headerStrip.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_headerStrip];

    UIView *headerRule = [[UIView alloc] init];
    headerRule.backgroundColor = [SPKUtils SPKColor_InstagramSeparator];
    headerRule.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerStrip addSubview:headerRule];

    UIView *wordmark = [[UIView alloc] init];
    wordmark.backgroundColor = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.35];
    wordmark.layer.cornerRadius = 4.0;
    wordmark.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerStrip addSubview:wordmark];

    _headerMessagesView = [[UIImageView alloc] initWithImage:SPKTabEditorGlyph(@"messages")];
    _headerMessagesView.contentMode = UIViewContentModeScaleAspectFit;
    _headerMessagesView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _headerMessagesView.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerStrip addSubview:_headerMessagesView];

    _barStack = [[UIStackView alloc] init];
    _barStack.axis = UILayoutConstraintAxisHorizontal;
    _barStack.distribution = UIStackViewDistributionFillEqually;
    _barStack.alignment = UIStackViewAlignmentCenter;
    _barStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_barStack];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = SPKL(@"SETTINGS_TAB_EDITOR_NO_VISIBLE_TABS_TEXT");
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _emptyLabel.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
    _emptyLabel.hidden = YES;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_emptyLabel];

    // The home indicator sells the illusion: without it the icon row reads as a
    // toolbar rather than the bottom of a phone screen.
    UIView *homeIndicator = [[UIView alloc] init];
    homeIndicator.backgroundColor = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.4];
    homeIndicator.layer.cornerRadius = 2.5;
    homeIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:homeIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.topAnchor constant:4.0],
        [card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16.0],
        [card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],

        [_headerStrip.topAnchor constraintEqualToAnchor:card.topAnchor],
        [_headerStrip.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [_headerStrip.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [_headerStrip.heightAnchor constraintEqualToConstant:44.0],

        [headerRule.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [headerRule.leadingAnchor constraintEqualToAnchor:_headerStrip.leadingAnchor],
        [headerRule.trailingAnchor constraintEqualToAnchor:_headerStrip.trailingAnchor],
        [headerRule.bottomAnchor constraintEqualToAnchor:_headerStrip.bottomAnchor],

        [wordmark.leadingAnchor constraintEqualToAnchor:_headerStrip.leadingAnchor constant:16.0],
        [wordmark.centerYAnchor constraintEqualToAnchor:_headerStrip.centerYAnchor constant:-2.0],
        [wordmark.widthAnchor constraintEqualToConstant:64.0],
        [wordmark.heightAnchor constraintEqualToConstant:8.0],

        [_headerMessagesView.trailingAnchor constraintEqualToAnchor:_headerStrip.trailingAnchor constant:-16.0],
        [_headerMessagesView.centerYAnchor constraintEqualToAnchor:wordmark.centerYAnchor],
        [_headerMessagesView.widthAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],
        [_headerMessagesView.heightAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],

        [_barStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [_barStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [_barStack.bottomAnchor constraintEqualToAnchor:homeIndicator.topAnchor constant:-10.0],
        [_barStack.heightAnchor constraintEqualToConstant:46.0],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_barStack.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_barStack.centerYAnchor],

        [homeIndicator.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [homeIndicator.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
        [homeIndicator.widthAnchor constraintEqualToConstant:110.0],
        [homeIndicator.heightAnchor constraintEqualToConstant:5.0],
    ]];

    return self;
}

- (UIView *)tabItemViewWithIcon:(NSString *)iconName selected:(BOOL)selected {
    UIView *container = [[UIView alloc] init];

    UIImageView *icon = [[UIImageView alloc] initWithImage:SPKTabEditorGlyph(iconName)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = selected ? [SPKUtils SPKColor_InstagramPrimaryText]
                              : [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.55];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:icon];

    UIView *dot = [[UIView alloc] init];
    dot.backgroundColor = [SPKUtils SPKColor_InstagramBlue];
    dot.layer.cornerRadius = 2.5;
    dot.hidden = !selected;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:dot];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-4.0],
        [icon.widthAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],
        [icon.heightAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],
        [dot.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [dot.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:5.0],
        [dot.widthAnchor constraintEqualToConstant:5.0],
        [dot.heightAnchor constraintEqualToConstant:5.0],
    ]];
    return container;
}

- (void)configureWithItems:(NSArray<NSDictionary *> *)items showsHeaderStrip:(BOOL)showsHeaderStrip {
    self.headerStrip.hidden = !showsHeaderStrip;
    self.emptyLabel.hidden = items.count > 0;

    for (UIView *view in self.barStack.arrangedSubviews)
        [view removeFromSuperview];
    for (NSDictionary *item in items) {
        [self.barStack addArrangedSubview:[self tabItemViewWithIcon:item[@"icon"]
                                                           selected:[item[@"selected"] boolValue]]];
    }
}

@end

// The stored layout as the tab bar can build it: Classic reads as Default where
// the tab bar runs down a side column, so opening the editor there stages no change by itself.
static NSString *SPKTabEditorStoredLayout(void) {
    NSString *layout = SPKNormalizedTabLayout(SPKPreferenceObjectForKey(SPKPrefTabLayout));
    if ([layout isEqualToString:SPKTabLayoutClassic] && SPKSystemTabBarRunsAsColumn())
        return SPKTabLayoutDefault;
    return layout;
}

#pragma mark - Column preview

// The system tab bar where it stands as a column on the trailing edge (a side
// vertical bar, as on a foldable): the status area on top, the feed header's
// create and notifications buttons that move into the column, the slot Sparkle's
// feed header button docks into under them, and the tab platter at the bottom
// with the selection lens. Tabs Instagram adds in wide layouts (Activity,
// Create) wear a dashed ring, matching the legend.
static CGFloat const SPKColumnPreviewItemHeight = 34.0;
static CGFloat const SPKColumnPreviewPlatterWidth = 46.0;
static CGFloat const SPKColumnPreviewColumnWidth = 60.0;

@interface SPKTabBarColumnPreviewView : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *column;
@property (nonatomic, strong) UIView *platter;
@property (nonatomic, strong) UIStackView *platterStack;
@property (nonatomic, strong) UIView *headerGroup;
@property (nonatomic, strong) UIView *headerCreateItem;
@property (nonatomic, strong) NSLayoutConstraint *headerItemsHeight;
@property (nonatomic, strong) NSLayoutConstraint *headerSlotBelowGroup;
@property (nonatomic, strong) NSLayoutConstraint *headerSlotBelowStatus;
@property (nonatomic, strong) UIView *headerSlot;
@property (nonatomic, strong) CAShapeLayer *headerSlotRing;
@property (nonatomic, strong) UIImageView *headerMessagesView;
@property (nonatomic, strong) UIStackView *legend;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation SPKTabBarColumnPreviewView

+ (CGFloat)preferredHeightForItemCount:(NSUInteger)count showsLegend:(BOOL)showsLegend {
    CGFloat platter = MAX((CGFloat)count, 1.0) * SPKColumnPreviewItemHeight + 12.0;
    // Card insets, status area, header group, header slot and the gap above the platter.
    return 4.0 + 16.0 + 12.0 + 34.0 + (2.0 * SPKColumnPreviewItemHeight + 12.0 + 8.0) + 40.0 + 14.0 + platter + 12.0 +
           (showsLegend ? 26.0 : 0.0);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    UIColor *placeholder = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.10];

    _card = [[UIView alloc] init];
    _card.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _card.layer.cornerRadius = 20.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_card];

    // The screen beside the column, sketched: a header line and a post.
    UIView *wordmark = [[UIView alloc] init];
    wordmark.backgroundColor = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.35];
    wordmark.layer.cornerRadius = 4.0;
    wordmark.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:wordmark];

    _headerMessagesView = [[UIImageView alloc] initWithImage:SPKTabEditorGlyph(@"messages")];
    _headerMessagesView.contentMode = UIViewContentModeScaleAspectFit;
    _headerMessagesView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _headerMessagesView.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_headerMessagesView];

    UIView *post = [[UIView alloc] init];
    post.backgroundColor = placeholder;
    post.layer.cornerRadius = 12.0;
    post.layer.cornerCurve = kCACornerCurveContinuous;
    post.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:post];

    _column = [[UIView alloc] init];
    _column.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_column];

    UILabel *clock = [[UILabel alloc] init];
    clock.text = @"9:41";
    clock.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightSemibold];
    clock.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    clock.isAccessibilityElement = NO;
    UIImageView *signal = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi"]];
    signal.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    signal.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:10.0 weight:UIImageSymbolWeightSemibold];
    UIStackView *status = [[UIStackView alloc] initWithArrangedSubviews:@[ clock, signal ]];
    status.axis = UILayoutConstraintAxisVertical;
    status.alignment = UIStackViewAlignmentCenter;
    status.spacing = 3.0;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [_column addSubview:status];

    // Instagram's own header items in the column, one glass group.
    _headerGroup = [[UIView alloc] init];
    _headerGroup.backgroundColor = [[SPKUtils SPKColor_InstagramPrimaryText] colorWithAlphaComponent:0.07];
    _headerGroup.layer.cornerRadius = SPKColumnPreviewPlatterWidth / 2.0;
    _headerGroup.layer.cornerCurve = kCACornerCurveContinuous;
    _headerGroup.translatesAutoresizingMaskIntoConstraints = NO;
    [_column addSubview:_headerGroup];
    _headerCreateItem = [self itemViewWithIcon:SPKTabIconName(SPKTabIdentifierCreate) selected:NO addedByInstagram:NO];
    UIStackView *headerItems = [[UIStackView alloc] initWithArrangedSubviews:@[
        _headerCreateItem,
        [self itemViewWithIcon:@"heart" selected:NO addedByInstagram:NO],
    ]];
    headerItems.axis = UILayoutConstraintAxisVertical;
    headerItems.distribution = UIStackViewDistributionFillEqually;
    headerItems.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerGroup addSubview:headerItems];

    _headerSlot = [[UIView alloc] init];
    _headerSlot.translatesAutoresizingMaskIntoConstraints = NO;
    _headerSlot.layer.cornerRadius = 17.0;
    _headerSlotRing = [CAShapeLayer layer];
    _headerSlotRing.fillColor = UIColor.clearColor.CGColor;
    _headerSlotRing.lineWidth = 1.0;
    _headerSlotRing.lineDashPattern = @[ @3, @3 ];
    [_headerSlot.layer addSublayer:_headerSlotRing];
    [_column addSubview:_headerSlot];

    _platter = [[UIView alloc] init];
    _platter.backgroundColor = [[SPKUtils SPKColor_InstagramPrimaryText] colorWithAlphaComponent:0.07];
    _platter.layer.cornerRadius = SPKColumnPreviewPlatterWidth / 2.0;
    _platter.layer.cornerCurve = kCACornerCurveContinuous;
    _platter.translatesAutoresizingMaskIntoConstraints = NO;
    [_column addSubview:_platter];

    _platterStack = [[UIStackView alloc] init];
    _platterStack.axis = UILayoutConstraintAxisVertical;
    _platterStack.distribution = UIStackViewDistributionFillEqually;
    _platterStack.alignment = UIStackViewAlignmentFill;
    _platterStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_platter addSubview:_platterStack];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = SPKL(@"SETTINGS_TAB_EDITOR_NO_VISIBLE_TABS_TEXT");
    _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _emptyLabel.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.hidden = YES;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_emptyLabel];

    UIView *legendRing = [self instagramRingView];
    UILabel *legendLabel = [[UILabel alloc] init];
    legendLabel.text = SPKL(@"SETTINGS_TAB_EDITOR_PREVIEW_ADDED_BY_INSTAGRAM_LABEL");
    legendLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    legendLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _legend = [[UIStackView alloc] initWithArrangedSubviews:@[ legendRing, legendLabel ]];
    _legend.axis = UILayoutConstraintAxisHorizontal;
    _legend.alignment = UIStackViewAlignmentCenter;
    _legend.spacing = 8.0;
    _legend.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_legend];

    _headerItemsHeight = [headerItems.heightAnchor constraintEqualToConstant:2.0 * SPKColumnPreviewItemHeight];
    _headerItemsHeight.active = YES;
    _headerSlotBelowGroup = [_headerSlot.topAnchor constraintEqualToAnchor:_headerGroup.bottomAnchor constant:10.0];
    _headerSlotBelowStatus = [_headerSlot.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8.0];
    _headerSlotBelowGroup.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:4.0],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16.0],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],

        [_column.topAnchor constraintEqualToAnchor:_card.topAnchor constant:12.0],
        [_column.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12.0],
        [_column.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-6.0],
        [_column.widthAnchor constraintEqualToConstant:SPKColumnPreviewColumnWidth],

        [status.topAnchor constraintEqualToAnchor:_column.topAnchor],
        [status.centerXAnchor constraintEqualToAnchor:_column.centerXAnchor],
        [status.heightAnchor constraintEqualToConstant:30.0],

        [_headerGroup.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8.0],
        [_headerGroup.centerXAnchor constraintEqualToAnchor:_column.centerXAnchor],
        [_headerGroup.widthAnchor constraintEqualToConstant:SPKColumnPreviewPlatterWidth],
        [headerItems.topAnchor constraintEqualToAnchor:_headerGroup.topAnchor constant:6.0],
        [headerItems.bottomAnchor constraintEqualToAnchor:_headerGroup.bottomAnchor constant:-6.0],
        [headerItems.leadingAnchor constraintEqualToAnchor:_headerGroup.leadingAnchor],
        [headerItems.trailingAnchor constraintEqualToAnchor:_headerGroup.trailingAnchor],

        [_headerSlot.centerXAnchor constraintEqualToAnchor:_column.centerXAnchor],
        [_headerSlot.widthAnchor constraintEqualToConstant:34.0],
        [_headerSlot.heightAnchor constraintEqualToConstant:34.0],

        [_platter.bottomAnchor constraintEqualToAnchor:_column.bottomAnchor],
        [_platter.centerXAnchor constraintEqualToAnchor:_column.centerXAnchor],
        [_platter.widthAnchor constraintEqualToConstant:SPKColumnPreviewPlatterWidth],
        [_platter.topAnchor constraintGreaterThanOrEqualToAnchor:_headerSlot.bottomAnchor constant:14.0],

        [_platterStack.topAnchor constraintEqualToAnchor:_platter.topAnchor constant:6.0],
        [_platterStack.bottomAnchor constraintEqualToAnchor:_platter.bottomAnchor constant:-6.0],
        [_platterStack.leadingAnchor constraintEqualToAnchor:_platter.leadingAnchor],
        [_platterStack.trailingAnchor constraintEqualToAnchor:_platter.trailingAnchor],

        [wordmark.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:16.0],
        [wordmark.topAnchor constraintEqualToAnchor:_card.topAnchor constant:24.0],
        [wordmark.widthAnchor constraintEqualToConstant:64.0],
        [wordmark.heightAnchor constraintEqualToConstant:8.0],

        [_headerMessagesView.trailingAnchor constraintEqualToAnchor:_column.leadingAnchor constant:-12.0],
        [_headerMessagesView.centerYAnchor constraintEqualToAnchor:wordmark.centerYAnchor],
        [_headerMessagesView.widthAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],
        [_headerMessagesView.heightAnchor constraintEqualToConstant:SPKTabEditorGlyphSize],

        [post.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:16.0],
        [post.trailingAnchor constraintEqualToAnchor:_column.leadingAnchor constant:-12.0],
        [post.topAnchor constraintEqualToAnchor:wordmark.bottomAnchor constant:22.0],
        [post.bottomAnchor constraintEqualToAnchor:_legend.topAnchor constant:-12.0],

        [_legend.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:16.0],
        [_legend.trailingAnchor constraintLessThanOrEqualToAnchor:_column.leadingAnchor constant:-8.0],
        [_legend.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-14.0],

        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_platter.centerYAnchor],
        [_emptyLabel.trailingAnchor constraintEqualToAnchor:_column.leadingAnchor constant:-8.0],
        [_emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_card.leadingAnchor constant:16.0],
    ]];
    return self;
}

- (UIView *)instagramRingView {
    UIView *ring = [[UIView alloc] init];
    ring.translatesAutoresizingMaskIntoConstraints = NO;
    [ring.widthAnchor constraintEqualToConstant:14.0].active = YES;
    [ring.heightAnchor constraintEqualToConstant:14.0].active = YES;
    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.5, 0.5, 13.0, 13.0)].CGPath;
    shape.fillColor = UIColor.clearColor.CGColor;
    shape.strokeColor = [SPKUtils SPKColor_InstagramSecondaryText].CGColor;
    shape.lineWidth = 1.0;
    shape.lineDashPattern = @[ @2, @2 ];
    [ring.layer addSublayer:shape];
    return ring;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.headerSlotRing.frame = self.headerSlot.bounds;
    self.headerSlotRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.headerSlot.bounds, 0.5, 0.5)].CGPath;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Layer colors do not follow the appearance by themselves.
    self.headerSlotRing.strokeColor = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.6].CGColor;
}

- (UIView *)itemViewWithIcon:(NSString *)iconName selected:(BOOL)selected addedByInstagram:(BOOL)addedByInstagram {
    UIView *container = [[UIView alloc] init];
    if (selected) {
        // The lens: UIKit's selection on the column platter.
        UIView *lens = [[UIView alloc] init];
        lens.backgroundColor = [[SPKUtils SPKColor_InstagramPrimaryText] colorWithAlphaComponent:0.12];
        lens.layer.cornerRadius = 17.0;
        lens.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:lens];
        [NSLayoutConstraint activateConstraints:@[
            [lens.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [lens.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [lens.widthAnchor constraintEqualToConstant:40.0],
            [lens.heightAnchor constraintEqualToConstant:34.0],
        ]];
    }
    if (addedByInstagram) {
        UIView *ring = [[UIView alloc] init];
        ring.translatesAutoresizingMaskIntoConstraints = NO;
        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.5, 0.5, 29.0, 29.0)].CGPath;
        shape.fillColor = UIColor.clearColor.CGColor;
        shape.strokeColor = [SPKUtils SPKColor_InstagramSecondaryText].CGColor;
        shape.lineWidth = 1.0;
        shape.lineDashPattern = @[ @2, @2 ];
        [ring.layer addSublayer:shape];
        [container addSubview:ring];
        [NSLayoutConstraint activateConstraints:@[
            [ring.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [ring.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [ring.widthAnchor constraintEqualToConstant:30.0],
            [ring.heightAnchor constraintEqualToConstant:30.0],
        ]];
    }
    UIImageView *icon = [[UIImageView alloc] initWithImage:[[SPKAssetUtils instagramIconNamed:iconName pointSize:20.0]
                                                               imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = selected ? [SPKUtils SPKColor_InstagramPrimaryText]
                              : [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:addedByInstagram ? 0.55 : 0.8];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:20.0],
        [icon.heightAnchor constraintEqualToConstant:20.0],
    ]];
    return container;
}

- (void)configureWithItems:(NSArray<NSDictionary *> *)items
          showsHeaderStrip:(BOOL)showsHeaderStrip
         headerButtonShown:(BOOL)headerButtonShown
       headerItemsInColumn:(BOOL)headerItemsInColumn {
    self.headerMessagesView.hidden = !showsHeaderStrip;
    // Classic puts the create button in the tab bar, leaving the heart here.
    self.headerCreateItem.hidden = showsHeaderStrip;
    self.headerItemsHeight.constant = (showsHeaderStrip ? 1.0 : 2.0) * SPKColumnPreviewItemHeight;
    // Where Instagram makes those header items tabs instead, the slot moves up.
    self.headerGroup.hidden = !headerItemsInColumn;
    self.headerSlotBelowGroup.active = NO;
    self.headerSlotBelowStatus.active = NO;
    (headerItemsInColumn ? self.headerSlotBelowGroup : self.headerSlotBelowStatus).active = YES;
    self.emptyLabel.hidden = items.count > 0;
    self.platter.hidden = items.count == 0;
    self.headerSlot.backgroundColor = headerButtonShown ? [[SPKUtils SPKColor_InstagramPrimaryText] colorWithAlphaComponent:0.12]
                                                        : UIColor.clearColor;
    self.headerSlotRing.strokeColor = [[SPKUtils SPKColor_InstagramSecondaryText] colorWithAlphaComponent:0.6].CGColor;
    BOOL anyInstagram = NO;
    for (UIView *view in self.platterStack.arrangedSubviews)
        [view removeFromSuperview];
    for (NSDictionary *item in items) {
        BOOL added = [item[@"instagram"] boolValue];
        anyInstagram = anyInstagram || added;
        [self.platterStack addArrangedSubview:[self itemViewWithIcon:item[@"icon"]
                                                            selected:[item[@"selected"] boolValue]
                                                    addedByInstagram:added]];
    }
    for (NSLayoutConstraint *constraint in self.platterStack.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight && constraint.firstItem == self.platterStack)
            constraint.active = NO;
    }
    [self.platterStack.heightAnchor constraintEqualToConstant:MAX((CGFloat)items.count, 1.0) * SPKColumnPreviewItemHeight].active = YES;
    self.legend.hidden = !anyInstagram;
}

@end

#pragma mark - Cell

@interface SPKTabEditorCell : UITableViewCell
@property (nonatomic, strong) UIImageView *gripView;
@property (nonatomic, strong) UIButton *visibilityButton;
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation SPKTabEditorCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;

    self.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIView *selection = [[UIView alloc] init];
    selection.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    self.selectedBackgroundView = selection;

    // A plain image, not a control: the drag is owned by the table's drag
    // interaction, which only lifts a row when the gesture starts inside this
    // view's frame. Everything else on the row stays an ordinary tap target.
    _gripView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"hamburger" pointSize:20.0]];
    _gripView.contentMode = UIViewContentModeCenter;
    _gripView.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [_gripView.widthAnchor constraintEqualToConstant:24.0].active = YES;

    _glyphView = [[UIImageView alloc] init];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    [_glyphView.widthAnchor constraintEqualToConstant:SPKTabEditorGlyphSize].active = YES;
    [_glyphView.heightAnchor constraintEqualToConstant:SPKTabEditorGlyphSize].active = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleLabel.adjustsFontForContentSizeCategory = YES;

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _statusLabel.numberOfLines = 0;

    _visibilityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _visibilityButton.adjustsImageWhenHighlighted = NO;
    _visibilityButton.userInteractionEnabled = NO; // The row owns the tap.
    [_visibilityButton.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [_visibilityButton.heightAnchor constraintEqualToConstant:24.0].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _gripView, _glyphView, _titleLabel, _statusLabel, _visibilityButton
    ]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];

    // The tab name never shrinks; a long status ("Replaces Messages tab") wraps
    // instead.
    [_titleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_statusLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    for (UIView *view in @[ _gripView, _visibilityButton ]) {
        [view setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [view setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11.0],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:52.0],
    ]];

    return self;
}

// Generous horizontally, full height: a drag has to be easy to start without the
// grip stealing taps meant for the row.
- (BOOL)spk_pointStartsDrag:(CGPoint)point {
    if (self.gripView.hidden)
        return NO;
    CGRect area = [self convertRect:self.gripView.bounds fromView:self.gripView];
    area = CGRectInset(area, -14.0, -CGRectGetHeight(self.bounds));
    return CGRectContainsPoint(area, point);
}

@end

#pragma mark - Editor

@interface SPKTabEditorViewController () <UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate,
                                         UITableViewDropDelegate, SPKChipBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) SPKChipBar *layoutChipBar;
@property (nonatomic, strong) UILabel *layoutCaption;
@property (nonatomic, strong) SPKTabBarPreviewView *previewView;
@property (nonatomic, strong) SPKTabBarColumnPreviewView *columnPreviewView;

@property (nonatomic, copy) NSString *layoutMode;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;
@property (nonatomic, strong) NSMutableSet<NSString *> *hidden;
@property (nonatomic, copy) NSString *launchTab;
@property (nonatomic, copy) NSString *swipeMode;
@property (nonatomic, copy) NSString *savedCarrier;
@property (nonatomic) BOOL hidesTabBarWhenSingle;
@property (nonatomic) BOOL showsInboxShortcut;
@property (nonatomic, strong) NSDictionary *persistedSnapshot;
@property (nonatomic) BOOL showsApplyItem;
@property (nonatomic) NSUInteger previewItemCount;
@property (nonatomic) BOOL previewShowsLegend;
@end

@implementation SPKTabEditorViewController

- (instancetype)init {
    self = [super init];
    if (self)
        self.title = SPKL(@"INTERFACE_TABS_TAB_EDITOR_TITLE");
    return self;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    SPKMigrateTabConfigurationIfNeeded();
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    [self loadPersistedValues];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = self.view.backgroundColor;
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
    [self.view addSubview:self.tableView];

    self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 0)];

    self.layoutChipBar = [[SPKChipBar alloc] init];
    self.layoutChipBar.delegate = self;
    self.layoutChipBar.distributesToFit = YES;
    // A tab bar running down a side column cannot take Classic's shape, so it is
    // not offered there.
    NSMutableArray<NSString *> *layoutTitles = [@[ SPKL(@"MENU_DEFAULT"), SPKL(@"TAB_LAYOUT_CUSTOM") ] mutableCopy];
    if (!SPKSystemTabBarRunsAsColumn())
        [layoutTitles addObject:SPKL(@"SETTINGS_TAB_EDITOR_CLASSIC_TEXT")];
    [self.layoutChipBar setItems:layoutTitles symbols:nil];
    self.layoutChipBar.selectedIndex = [self usesCustomLayout] ? 1 : ([self usesClassicLayout] ? 2 : 0);
    [self.headerContainer addSubview:self.layoutChipBar];

    self.layoutCaption = [[UILabel alloc] init];
    self.layoutCaption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.layoutCaption.adjustsFontForContentSizeCategory = YES;
    self.layoutCaption.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    self.layoutCaption.numberOfLines = 0;
    [self.headerContainer addSubview:self.layoutCaption];

    self.previewView = [[SPKTabBarPreviewView alloc] initWithFrame:CGRectZero];
    [self.headerContainer addSubview:self.previewView];
    self.columnPreviewView = [[SPKTabBarColumnPreviewView alloc] initWithFrame:CGRectZero];
    self.columnPreviewView.hidden = YES;
    [self.headerContainer addSubview:self.columnPreviewView];
    self.tableView.tableHeaderView = self.headerContainer;

    [self applyEditingState];
    [self refreshStagedUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // SPKSetting retains its destination controller, so a second visit shows the
    // same object. Staged edits are kept across visits on purpose - leaving is
    // never destructive, so no gesture has to be blocked - but a configuration
    // changed elsewhere (account switch, settings import) wins over a stale one.
    if (self.isMovingToParentViewController && self.tableView) {
        NSDictionary *persisted = self.persistedSnapshot;
        [self loadPersistedValuesKeepingStagedEdits:[self isDirty] &&
                                                    [persisted isEqual:[self persistedValuesSnapshot]]];
        [self.tableView reloadData];
        [self applyEditingState];
        [self refreshStagedUI];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPreviewHeader];
}

// Folding, unfolding or resizing changes which bar the preview has to draw.
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.tableView && previousTraitCollection.horizontalSizeClass != self.traitCollection.horizontalSizeClass) {
        [self.tableView reloadData];
        [self refreshStagedUI];
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    if (self.tableView && [self previewUsesColumn] != !self.columnPreviewView.hidden)
        [self refreshStagedUI];
}

#pragma mark Bar shape

// The preview draws the bar this screen's own geometry implies, never the
// device model. The system tab bar stands as a column on the trailing edge
// where the window gives that edge a side bar's inset (more than the leading
// one: a landscape iPhone's insets are symmetric); everywhere else it is a
// bottom bar like Instagram's own.
- (BOOL)previewUsesColumn {
    if (!SPKSystemTabBarInUse())
        return NO;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    BOOL rightToLeft = self.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat trailing = rightToLeft ? insets.left : insets.right;
    CGFloat leading = rightToLeft ? insets.right : insets.left;
    return trailing > leading + 20.0;
}

// In regular width the system bar shows Instagram's wide topology: Activity and
// Create become tabs, and Classic stops applying.
- (BOOL)previewIsRegularWidth {
    return SPKSystemTabBarInUse() && self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
}

// Hand-laid out: a table header view is sized by its frame, so the height has to
// be known up front.
- (void)layoutPreviewHeader {
    if (!self.headerContainer)
        return;

    // The rows sit on the table's layout margins, which already absorb a side
    // column's safe-area inset. The chips and preview card are drawn 16pt
    // inside their frames, so these frames reach 16pt past the margins to line
    // their edges up with the rows.
    UIEdgeInsets margins = self.tableView.layoutMargins;
    CGFloat const contentInset = 16.0;
    CGFloat fullWidth = CGRectGetWidth(self.tableView.bounds);
    CGFloat x = MAX(0.0, margins.left - contentInset);
    CGFloat width = fullWidth - x - MAX(0.0, margins.right - contentInset);
    if (width <= 0.0)
        return;

    CGFloat const margin = 20.0;
    CGFloat const chipHeight = 50.0;
    CGFloat captionWidth = width - margin * 2.0;

    self.layoutCaption.text = [self layoutCaptionText];
    CGSize captionSize = [self.layoutCaption sizeThatFits:CGSizeMake(captionWidth, CGFLOAT_MAX)];

    CGFloat y = 4.0;
    self.layoutChipBar.frame = CGRectMake(x, y, width, chipHeight);
    y += chipHeight + 4.0;

    BOOL column = [self previewUsesColumn];
    CGFloat previewHeight = [self usesClassicLayout] && ![self previewIsRegularWidth] ? 212.0 : 168.0;
    if (column)
        previewHeight = [SPKTabBarColumnPreviewView preferredHeightForItemCount:MAX(self.previewItemCount, (NSUInteger)1)
                                                                    showsLegend:self.previewShowsLegend];
    self.previewView.hidden = column;
    self.columnPreviewView.hidden = !column;
    (column ? (UIView *)self.columnPreviewView : (UIView *)self.previewView).frame = CGRectMake(x, y, width, previewHeight);
    y += previewHeight;

    self.layoutCaption.frame = CGRectMake(x + margin, y, captionWidth, captionSize.height);
    y += captionSize.height + 10.0;

    CGRect frame = CGRectMake(0, 0, fullWidth, y);
    if (!CGRectEqualToRect(self.headerContainer.frame, frame)) {
        self.headerContainer.frame = frame;
        self.tableView.tableHeaderView = self.headerContainer;
    }
}

- (NSString *)layoutCaptionText {
    NSString *text;
    if ([self usesCustomLayout])
        text = SPKL(@"SETTINGS_TAB_EDITOR_ARRANGE_TAB_BAR_YOURSELF_ONLY_LAYOUT_CAN_HOLD_SAVED_TEXT");
    else if ([self usesClassicLayout])
        text = SPKL(@"SETTINGS_TAB_EDITOR_INSTAGRAM_S_LEGACY_LAYOUT_MESSAGES_MOVES_FEED_HEADER_CREATE_MESSAGE");
    else
        text = SPKL(@"SETTINGS_TAB_EDITOR_INSTAGRAM_DECIDES_ORDER_CAN_STILL_HIDE_TABS_CHOOSE_APP_TEXT");
    if (SPKSystemTabBarRunsAsColumn())
        text = [NSString stringWithFormat:@"%@ %@", text, SPKL(@"TAB_EDITOR_CLASSIC_SIDE_TAB_BAR_UNAVAILABLE_TEXT")];
    return text;
}

#pragma mark State

- (BOOL)usesCustomLayout { return [self.layoutMode isEqualToString:SPKTabLayoutCustom]; }
- (BOOL)usesClassicLayout { return [self.layoutMode isEqualToString:SPKTabLayoutClassic]; }

// What is on disk right now, in the same shape as -snapshot, so a staged edit can
// be compared against it without disturbing what is staged.
- (NSDictionary *)persistedValuesSnapshot {
    NSMutableDictionary *hidden = [NSMutableDictionary dictionary];
    for (NSString *identifier in SPKTabEditableIdentifiers()) {
        id value = SPKPreferenceObjectForKey(SPKTabHidePreferenceKey(identifier));
        hidden[identifier] = @([value respondsToSelector:@selector(boolValue)] && [value boolValue]);
    }
    id launch = SPKPreferenceObjectForKey(@"interface_launch_tab");
    id swipe = SPKPreferenceObjectForKey(@"interface_swipe_tabs");
    return @{
        @"layout" : SPKTabEditorStoredLayout(),
        @"order" : SPKNormalizeTabOrder(SPKPreferenceObjectForKey(SPKPrefCustomTabOrder)),
        @"hidden" : hidden,
        @"launch" : [launch isKindOfClass:[NSString class]] ? launch : @"default",
        @"swipe" : [swipe isKindOfClass:[NSString class]] ? swipe : @"default",
        @"saved" : SPKNormalizedSavedCarrier(SPKPreferenceObjectForKey(SPKPrefSavedTabCarrier)),
        @"hidesBar" : @([self stagedBoolForKey:SPKPrefHideTabBarWhenSingle fallback:NO]),
        @"inboxShortcut" : @([self stagedBoolForKey:SPKPrefInboxHeaderShortcut fallback:YES]),
    };
}

- (void)loadPersistedValuesKeepingStagedEdits:(BOOL)keepStaged {
    if (keepStaged)
        return;
    [self loadPersistedValues];
}

- (void)loadPersistedValues {
    self.layoutMode = SPKTabEditorStoredLayout();
    self.order = [SPKNormalizeTabOrder(SPKPreferenceObjectForKey(SPKPrefCustomTabOrder)) mutableCopy];
    self.hidden = [NSMutableSet set];
    for (NSString *identifier in SPKTabEditableIdentifiers()) {
        id value = SPKPreferenceObjectForKey(SPKTabHidePreferenceKey(identifier));
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue])
            [self.hidden addObject:identifier];
    }
    id launch = SPKPreferenceObjectForKey(@"interface_launch_tab");
    self.launchTab = [launch isKindOfClass:[NSString class]] ? launch : @"default";
    id swipe = SPKPreferenceObjectForKey(@"interface_swipe_tabs");
    self.swipeMode = [swipe isKindOfClass:[NSString class]] ? swipe : @"default";
    self.savedCarrier = SPKNormalizedSavedCarrier(SPKPreferenceObjectForKey(SPKPrefSavedTabCarrier));
    self.hidesTabBarWhenSingle = [self stagedBoolForKey:SPKPrefHideTabBarWhenSingle fallback:NO];
    self.showsInboxShortcut = [self stagedBoolForKey:SPKPrefInboxHeaderShortcut fallback:YES];

    self.persistedSnapshot = [self snapshot];
    // A carrier whose tab was un-hidden elsewhere (or imported inconsistently)
    // no longer has a slot to borrow. Repairing it here is intentionally dirty.
    [self normalizeSavedCarrier];
    // A launch destination that was imported (or left behind) hidden is staged
    // back to Default. That is intentionally dirty: Apply repairs the stored
    // configuration instead of leaving a dead launch target in place.
    [self normalizeLaunchTab];
}

// Deliberately not -getBoolPref:, whose master-disable overlay would report a
// value the user never chose and Apply would then write back as if they had.
- (BOOL)stagedBoolForKey:(NSString *)key fallback:(BOOL)fallback {
    id value = SPKPreferenceObjectForKey(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (NSDictionary *)snapshot {
    NSMutableDictionary *hidden = [NSMutableDictionary dictionary];
    for (NSString *identifier in SPKTabEditableIdentifiers())
        hidden[identifier] = @([self.hidden containsObject:identifier]);
    return @{
        @"layout" : self.layoutMode ?: SPKTabLayoutDefault,
        @"order" : [self.order copy] ?: @[],
        @"hidden" : hidden,
        @"launch" : self.launchTab ?: @"default",
        @"swipe" : self.swipeMode ?: @"default",
        @"saved" : self.savedCarrier ?: SPKTabSavedCarrierNone,
        @"hidesBar" : @(self.hidesTabBarWhenSingle),
        @"inboxShortcut" : @(self.showsInboxShortcut),
    };
}

- (BOOL)isDirty {
    return ![[self snapshot] isEqual:self.persistedSnapshot];
}

// How many navigable tabs the bar would still show. Only slots that exist in the
// current layout count, so hiding Classic's header-only Messages link never
// looks like it emptied the bar.
- (NSUInteger)visibleDestinationCount {
    NSUInteger count = 0;
    for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
        if (![self occupiesBarSlot:identifier])
            continue;
        if (![self.hidden containsObject:identifier])
            count++;
    }
    return count;
}

- (BOOL)occupiesBarSlot:(NSString *)identifier {
    return SPKTabOccupiesBarSlot(identifier, self.layoutMode);
}

- (void)normalizeLaunchTab {
    NSString *identifier = SPKTabIdentifierForLaunchPreference(self.launchTab);
    if (identifier && [self.hidden containsObject:identifier])
        self.launchTab = @"default";
}

// The rows shown in the Tabs section, in the order the user sees them.
- (NSArray<NSString *> *)rowIdentifiers {
    if ([self usesClassicLayout]) {
        // Classic is Instagram's own legacy topology: its order is fixed and the
        // Create launcher comes back as a tab. Messages is not listed at all -
        // it is the feed header link there, reachable by tapping it or by
        // swiping, so a visibility toggle for it would be a toggle for nothing.
        return @[ SPKTabIdentifierFeed, SPKTabIdentifierSearch, SPKTabIdentifierCreate,
                  SPKTabIdentifierClips, SPKTabIdentifierProfile ];
    }
    if ([self usesCustomLayout])
        return self.order;
    return SPKCanonicalTabIdentifiers();
}

- (BOOL)canReorderIdentifier:(NSString *)identifier {
    return [self usesCustomLayout] && [SPKTabOrderableIdentifiers() containsObject:identifier];
}

- (NSString *)displayTitleForIdentifier:(NSString *)identifier {
    return SPKTabTitle(identifier);
}

- (NSString *)displayIconForIdentifier:(NSString *)identifier {
    return SPKTabIconName(identifier);
}

#pragma mark Saved slot

- (BOOL)savedEnabled {
    return ![self.savedCarrier isEqualToString:SPKTabSavedCarrierNone];
}

// Saved has no surface of its own: it borrows a hidden bar slot. The first
// hidden candidate for the current layout is the one it takes, so the user never
// has to understand carriers to use the feature.
- (NSString *)availableSavedCarrier {
    for (NSString *identifier in SPKTabSavedCarrierPreferenceForLayout(self.layoutMode)) {
        if ([self.hidden containsObject:identifier])
            return identifier;
    }
    return nil;
}

// Keeps the carrier pointing at a slot that is actually free in this layout.
// Showing a tab that Saved was borrowing (or switching to a layout where that
// tab owns no slot, as Messages does in Classic) silently hands the slot back
// instead of leaving two entries fighting over one surface.
- (void)normalizeSavedCarrier {
    if (![self savedEnabled])
        return;
    if (![self usesCustomLayout]) {
        self.savedCarrier = SPKTabSavedCarrierNone;
        return;
    }
    if ([self.hidden containsObject:self.savedCarrier] && [self occupiesBarSlot:self.savedCarrier])
        return;
    self.savedCarrier = [self availableSavedCarrier] ?: SPKTabSavedCarrierNone;
}

#pragma mark Chrome

// Apply is a prominent trailing bar item that appears only once something is
// staged, so the screen stays quiet until there is something to write.
- (void)refreshChrome {
    BOOL dirty = [self isDirty];
    if (dirty == self.showsApplyItem)
        return;
    self.showsApplyItem = dirty;

    UIBarButtonItem *apply = SPKMediaChromeTopBarButtonItemWithStyle(@"check", self, @selector(applyTapped),
                                                                    UIBarButtonItemStyleDone,
                                                                    [SPKUtils SPKColor_InstagramBlue],
                                                                    SPKL(@"SETTINGS_TAB_EDITOR_APPLY_RESTART_TEXT"));
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, dirty ? @[ apply ] : @[]);
}

- (void)applyEditingState {
    // Reordering is drag and drop anchored to each row's grip, so the table never
    // enters editing mode: rows stay tappable and the grip stays on the leading
    // edge instead of UIKit's fixed trailing reorder control.
    self.tableView.dragInteractionEnabled = [self usesCustomLayout];
}

// The order the bar is built in, as the preview draws it. Classic in regular
// width is not Classic at all: Instagram builds the wide system bar from its
// default topology there, with Messages as a tab.
- (NSArray<NSString *> *)previewIdentifiers {
    if ([self usesClassicLayout] && [self previewIsRegularWidth])
        return SPKCanonicalTabIdentifiers();
    return [self rowIdentifiers];
}

// Re-renders the preview, the dirty affordances and the back-button override.
- (void)refreshStagedUI {
    self.layoutChipBar.selectedIndex = [self usesCustomLayout] ? 1 : ([self usesClassicLayout] ? 2 : 0);

    BOOL custom = [self usesCustomLayout];
    BOOL regular = [self previewIsRegularWidth];
    BOOL classicBar = [self usesClassicLayout] && !regular;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSString *launchIdentifier = SPKTabIdentifierForLaunchPreference(self.launchTab);
    NSString *firstVisible = nil;
    // Tabs Instagram places ahead of its wide-layout additions: everything but
    // Profile, counted by the surface a slot shows (Saved shows its carrier's).
    NSUInteger leadingSlots = 0;
    for (NSString *identifier in [self previewIdentifiers]) {
        NSString *icon = nil;
        NSString *surface = identifier;
        if ([identifier isEqualToString:SPKTabIdentifierSaved]) {
            if (![self savedEnabled] || !custom)
                continue;
            icon = SPKTabIconName(SPKTabIdentifierSaved);
            surface = self.savedCarrier;
        } else if ([self isIdentifierHidden:identifier]) {
            continue;
        } else {
            icon = [self displayIconForIdentifier:identifier];
        }
        if (classicBar && [identifier isEqualToString:SPKTabIdentifierDirect])
            continue; // Header, not a bar item.
        if (!firstVisible && ![identifier isEqualToString:SPKTabIdentifierCreate])
            firstVisible = identifier;
        if (![surface isEqualToString:SPKTabIdentifierProfile] && ![surface isEqualToString:SPKTabIdentifierCreate])
            leadingSlots++;
        [items addObject:@{ @"icon" : icon, @"id" : identifier }];
    }
    BOOL instagramTabs = regular && SPKSystemTabBarRegularWidthAddsInstagramTabs();
    if (instagramTabs) {
        // Activity replaces the Feed header heart, so it goes with Feed; Create
        // follows its own hide flag, as at runtime.
        NSMutableArray<NSDictionary *> *added = [NSMutableArray array];
        if (![self.hidden containsObject:SPKTabIdentifierFeed])
            [added addObject:@{ @"icon" : @"heart", @"id" : @"activity", @"instagram" : @YES }];
        if (![self.hidden containsObject:SPKTabIdentifierCreate])
            [added addObject:@{ @"icon" : SPKTabIconName(SPKTabIdentifierCreate), @"id" : SPKTabIdentifierCreate, @"instagram" : @YES }];
        NSUInteger index = MIN(leadingSlots, items.count);
        [items insertObjects:added atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, added.count)]];
    }
    // With no explicit launch tab Instagram opens the first destination, which is
    // what the preview should highlight.
    NSString *highlighted = launchIdentifier ?: firstVisible;
    NSMutableArray<NSDictionary *> *decorated = [NSMutableArray array];
    BOOL anyInstagram = NO;
    for (NSDictionary *item in items) {
        BOOL added = [item[@"instagram"] boolValue];
        anyInstagram = anyInstagram || added;
        [decorated addObject:@{ @"icon" : item[@"icon"],
                                @"instagram" : @(added),
                                @"selected" : @(!added && [item[@"id"] isEqualToString:highlighted ?: @""]) }];
    }
    self.previewItemCount = decorated.count;
    self.previewShowsLegend = anyInstagram;
    [self layoutPreviewHeader];

    // Classic keeps Messages in the feed header, so the strip goes with the
    // layout rather than with any toggle.
    BOOL showsHeaderStrip = classicBar;
    BOOL headerButton = [SPKUtils getBoolPref:@"feed_header_button"];
    BOOL column = [self previewUsesColumn];
    UIView *target = column ? (UIView *)self.columnPreviewView : (UIView *)self.previewView;
    [UIView transitionWithView:target
                      duration:0.22
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        if (column)
                            [self.columnPreviewView configureWithItems:decorated
                                                      showsHeaderStrip:showsHeaderStrip
                                                     headerButtonShown:headerButton
                                                   headerItemsInColumn:!instagramTabs];
                        else
                            [self.previewView configureWithItems:decorated showsHeaderStrip:showsHeaderStrip];
                    }
                    completion:nil];

    [self refreshChrome];
}

#pragma mark Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SPKTabEditorSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
    case SPKTabEditorSectionTabs: return (NSInteger)[self rowIdentifiers].count;
    case SPKTabEditorSectionBehavior: return (NSInteger)[self behaviorRowKeys].count;
    case SPKTabEditorSectionSingleTab: return (NSInteger)[self singleTabRowKeys].count;
    case SPKTabEditorSectionDiscard: return 1;
    case SPKTabEditorSectionReset: return 1;
    default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == SPKTabEditorSectionTabs) return SPKL(@"INTERFACE_TABS_HEADER");
    if (section == SPKTabEditorSectionBehavior) return SPKL(@"REELS_BEHAVIOR_HEADER");
    if (section == SPKTabEditorSectionSingleTab) return SPKL(@"SETTINGS_TAB_EDITOR_SINGLE_TAB_MODE_TEXT");
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == SPKTabEditorSectionTabs) {
        NSMutableString *text = [NSMutableString stringWithString:SPKL(@"TAB_EDITOR_HELP_TAP")];
        if ([self usesCustomLayout])
            [text appendString:SPKL(@"TAB_EDITOR_HELP_DRAG")];
        [text appendString:SPKL(@"TAB_EDITOR_HELP_LAST_VISIBLE")];
        if ([self usesClassicLayout]) {
            [text appendString:SPKL(@"TAB_EDITOR_HELP_MESSAGES_CLASSIC")];
        }
        if ([self usesCustomLayout]) {
            [text appendString:SPKL(@"TAB_EDITOR_HELP_SAVED_BORROWS")];
        }
        // What the system tab bar does differently, said where it matters.
        if ([self previewIsRegularWidth] && SPKSystemTabBarRegularWidthAddsInstagramTabs())
            [text appendFormat:@"\n%@", SPKL(@"TAB_EDITOR_HELP_INSTAGRAM_WIDE_TABS")];
        return text;
    }
    if (section == SPKTabEditorSectionBehavior && [self systemTabBarDisablesSwipe])
        return SPKL(@"TAB_EDITOR_SWIPE_SYSTEM_TAB_BAR_FOOTER");
    if (section == SPKTabEditorSectionSingleTab) {
        NSString *single = [self singleVisibleTab];
        NSMutableString *text = [NSMutableString string];
        if (!single) {
            [text appendString:SPKL(@"TAB_EDITOR_SINGLE_TAB_EXPLANATION")];
        } else if (SPKSingleTabAllowsHidingTabBar(single)) {
            [text appendFormat:SPKL(@"TAB_EDITOR_HELP_ONLY_LEFT"), SPKTabTitle(single)];
            [text appendString:[single isEqualToString:SPKTabIdentifierDirect]
                                   ? SPKL(@"TAB_EDITOR_DIRECT_TAB_ACCESS")
                                   : SPKL(@"TAB_EDITOR_FEED_TAB_ACCESS")];
        } else if ([single isEqualToString:SPKTabIdentifierFeed]) {
            [text appendString:SPKL(@"TAB_EDITOR_FEED_HEADER_REQUIRED")];
        } else {
            [text appendFormat:SPKL(@"TAB_EDITOR_CANNOT_HIDE_FORMAT"), SPKTabTitle(single)];
        }
        [text appendString:SPKL(@"TAB_EDITOR_HEADER_BUTTON_DESC")];
        return text;
    }
    if (section == SPKTabEditorSectionDiscard)
        return SPKL(@"SETTINGS_TAB_EDITOR_LEAVING_SCREEN_KEEPS_CHANGES_STAGED_SO_CAN_COME_BACK_TEXT");
    if (section == SPKTabEditorSectionReset)
        return SPKL(@"SETTINGS_TAB_EDITOR_STAGES_INSTAGRAM_S_STOCK_LAYOUT_NOTHING_WRITTEN_UNTIL_APPLY_TEXT");
    return nil;
}

- (UITableViewCell *)baseCellWithStyle:(UITableViewCellStyle)style {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    UIView *selection = [[UIView alloc] init];
    selection.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    cell.selectedBackgroundView = selection;
    cell.textLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.detailTextLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    return cell;
}

- (UIButton *)menuButtonWithTitle:(NSString *)title menu:(UIMenu *)menu {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
    config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
    config.imagePlacement = NSDirectionalRectEdgeTrailing;
    config.imagePadding = 6.0;
    config.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:10.0 weight:UIImageSymbolWeightBold];
    button.configuration = config;
    button.titleLabel.numberOfLines = 1;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    button.menu = menu;
    button.showsMenuAsPrimaryAction = YES;
    [button sizeToFit];
    return button;
}

- (void)chipBar:(SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    NSString *layout = index == 1 ? SPKTabLayoutCustom : index == 2 ? SPKTabLayoutClassic : SPKTabLayoutDefault;
    if ([layout isEqualToString:self.layoutMode])
        return;
    self.layoutMode = layout;
    // Saved lives in the Custom layout only, and the layouts do not share bar
    // slots, so a carrier that was valid a moment ago may own nothing now.
    [self normalizeSavedCarrier];
    [self applyEditingState];
    [self.tableView reloadData];
    [self refreshStagedUI];
}

- (UITableViewCell *)tabCellForIdentifier:(NSString *)identifier {
    SPKTabEditorCell *cell = [[SPKTabEditorCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    BOOL isHidden = [self isIdentifierHidden:identifier];
    BOOL locked = [self isVisibilityLockedForIdentifier:identifier];

    UIImage *symbol = [SPKAssetUtils instagramIconNamed:(isHidden ? @"circle" : @"circle_check_filled")
                                              pointSize:22.0];
    [cell.visibilityButton setImage:symbol forState:UIControlStateNormal];
    cell.visibilityButton.tintColor = (isHidden || locked) ? [SPKUtils SPKColor_InstagramTertiaryText]
                                                           : [SPKUtils SPKColor_InstagramBlue];
    cell.visibilityButton.accessibilityLabel = isHidden ? SPKL(@"SETTINGS_TAB_EDITOR_SHOW_TAB_TEXT") : SPKL(@"SETTINGS_TAB_EDITOR_HIDE_TAB_TEXT");

    cell.gripView.hidden = ![self canReorderIdentifier:identifier];
    cell.glyphView.image = SPKTabEditorGlyph([self displayIconForIdentifier:identifier]);
    cell.glyphView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.titleLabel.text = [self displayTitleForIdentifier:identifier];
    cell.titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];

    cell.statusLabel.text = [self statusTextForIdentifier:identifier];
    cell.glyphView.alpha = isHidden ? 0.4 : 1.0;
    cell.titleLabel.alpha = isHidden ? 0.4 : 1.0;
    return cell;
}

- (NSString *)statusTextForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:SPKTabIdentifierSaved]) {
        if (![self savedEnabled])
            return [self availableSavedCarrier] ? nil : SPKL(@"SETTINGS_TAB_EDITOR_HIDE_TAB_FIRST_TEXT");
        return [NSString stringWithFormat:SPKL(@"SETTINGS_TAB_EDITOR_REPLACES_VALUE_TAB_FORMAT"), SPKTabTitle(self.savedCarrier)];
    }
    if ([self.hidden containsObject:identifier])
        return nil;
    if ([self usesClassicLayout] && [identifier isEqualToString:SPKTabIdentifierDirect])
        return SPKL(@"SETTINGS_TAB_EDITOR_FEED_HEADER_LINK_HEADER");
    if ([identifier isEqualToString:SPKTabIdentifierCreate])
        return SPKL(@"SETTINGS_TAB_EDITOR_OPENS_CAMERA_TEXT");
    NSString *launchIdentifier = SPKTabIdentifierForLaunchPreference(self.launchTab);
    if (launchIdentifier && [launchIdentifier isEqualToString:identifier])
        return SPKL(@"SETTINGS_TAB_EDITOR_OPENS_LAUNCH_TEXT");
    return nil;
}

// The single-tab rows only exist while the staged configuration actually leaves
// one tab, so they appear and disappear as the bar above them is edited.
- (NSString *)singleVisibleTab {
    return SPKSingleVisibleTabIdentifier(self.layoutMode, self.hidden, self.savedCarrier);
}

// The system tab bar has no swipe between tabs: Instagram only builds its
// swipe container for its own bar. Answered from the running bar, so a
// foldable that picked the system bar by itself greys the row out too.
- (BOOL)systemTabBarDisablesSwipe {
    return SPKSystemTabBarInUse();
}

- (NSArray<NSString *> *)behaviorRowKeys {
    return @[ @"launch", @"swipe" ];
}

// Always listed and disabled rather than removed: a row that vanishes while the
// bar above it is edited cannot be found again.
- (NSArray<NSString *> *)singleTabRowKeys {
    return @[ @"hideBar", @"inboxShortcut" ];
}

- (BOOL)isSingleTabRowEnabled:(NSString *)key {
    NSString *single = [self singleVisibleTab];
    if ([key isEqualToString:@"hideBar"])
        return single != nil && SPKSingleTabAllowsHidingTabBar(single);
    return [single isEqualToString:SPKTabIdentifierDirect];
}

- (UITableViewCell *)behaviorCellForRow:(NSInteger)row {
    UITableViewCell *cell = [self baseCellWithStyle:UITableViewCellStyleDefault];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray<NSString *> *keys = [self behaviorRowKeys];
    NSString *key = row < (NSInteger)keys.count ? keys[row] : nil;

    if ([key isEqualToString:@"launch"]) {
        NSString *identifier = SPKTabIdentifierForLaunchPreference(self.launchTab);
        cell.textLabel.text = SPKL(@"SETTINGS_TAB_EDITOR_LAUNCH_TAB_TEXT");
        cell.imageView.image = SPKTabEditorGlyph(identifier ? [self displayIconForIdentifier:identifier] : @"home");
        cell.imageView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
        cell.accessoryView = [self menuButtonWithTitle:(identifier ? [self displayTitleForIdentifier:identifier] : SPKL(@"MENU_DEFAULT"))
                                                  menu:[self launchMenu]];
    } else if ([key isEqualToString:@"swipe"]) {
        cell.textLabel.text = SPKL(@"SETTINGS_TAB_EDITOR_SWIPE_BETWEEN_TABS_TEXT");
        cell.imageView.image = SPKTabEditorGlyph(@"left_right");
        cell.imageView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
        NSString *title = [self.swipeMode isEqualToString:@"enabled"] ? SPKL(@"MENU_ON")
                        : [self.swipeMode isEqualToString:@"disabled"] ? SPKL(@"MENU_OFF") : SPKL(@"MENU_DEFAULT");
        UIButton *button = [self menuButtonWithTitle:title menu:[self swipeMenu]];
        if ([self systemTabBarDisablesSwipe]) {
            button.enabled = NO;
            cell.textLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        }
        cell.accessoryView = button;
    }
    return cell;
}

- (UITableViewCell *)singleTabCellForRow:(NSInteger)row {
    UITableViewCell *cell = [self baseCellWithStyle:UITableViewCellStyleDefault];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray<NSString *> *keys = [self singleTabRowKeys];
    NSString *key = row < (NSInteger)keys.count ? keys[row] : nil;
    if (!key)
        return cell;

    BOOL enabled = [self isSingleTabRowEnabled:key];
    BOOL hidesBar = [key isEqualToString:@"hideBar"];
    cell.textLabel.text = hidesBar ? SPKL(@"SETTINGS_TAB_EDITOR_HIDE_TAB_BAR_TEXT") : SPKL(@"SETTINGS_TAB_EDITOR_MESSAGES_HEADER_SHORTCUT_HEADER");
    cell.textLabel.textColor = enabled ? [SPKUtils SPKColor_InstagramPrimaryText]
                                       : [SPKUtils SPKColor_InstagramSecondaryText];
    cell.accessoryView = [self switchWithValue:(hidesBar ? self.hidesTabBarWhenSingle : self.showsInboxShortcut)
                                        action:(hidesBar ? @selector(hideTabBarSwitchChanged:)
                                                         : @selector(inboxShortcutSwitchChanged:))
                                       enabled:enabled];
    return cell;
}

- (UISwitch *)switchWithValue:(BOOL)value action:(SEL)action enabled:(BOOL)enabled {
    SPKSwitch *toggle = [[SPKSwitch alloc] init];
    toggle.on = value;
    toggle.enabled = enabled;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (void)hideTabBarSwitchChanged:(UISwitch *)toggle {
    self.hidesTabBarWhenSingle = toggle.isOn;
    [self refreshStagedUI];
}

- (void)inboxShortcutSwitchChanged:(UISwitch *)toggle {
    self.showsInboxShortcut = toggle.isOn;
    [self refreshStagedUI];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
    case SPKTabEditorSectionTabs: {
        NSArray<NSString *> *identifiers = [self rowIdentifiers];
        if (indexPath.row >= (NSInteger)identifiers.count)
            return [self baseCellWithStyle:UITableViewCellStyleDefault];
        return [self tabCellForIdentifier:identifiers[indexPath.row]];
    }
    case SPKTabEditorSectionBehavior:
        return [self behaviorCellForRow:indexPath.row];
    case SPKTabEditorSectionSingleTab:
        return [self singleTabCellForRow:indexPath.row];
    default: {
        UITableViewCell *cell = [self baseCellWithStyle:UITableViewCellStyleDefault];
        BOOL discard = indexPath.section == SPKTabEditorSectionDiscard;
        BOOL dirty = [self isDirty];
        cell.textLabel.text = discard ? SPKL(@"SETTINGS_TAB_EDITOR_DISCARD_CHANGES_TEXT") : SPKL(@"SETTINGS_TAB_EDITOR_RESET_INSTAGRAM_DEFAULT_TEXT");
        cell.textLabel.textColor = (discard && !dirty) ? [SPKUtils SPKColor_InstagramTertiaryText]
                                                       : [SPKUtils SPKColor_InstagramDestructive];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = (discard && !dirty) ? UITableViewCellSelectionStyleNone
                                                  : UITableViewCellSelectionStyleDefault;
        return cell;
    }
    }
}

#pragma mark Table interaction

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == SPKTabEditorSectionTabs) {
        NSArray<NSString *> *identifiers = [self rowIdentifiers];
        if (indexPath.row < (NSInteger)identifiers.count)
            [self toggleVisibilityForIdentifier:identifiers[indexPath.row]];
    } else if (indexPath.section == SPKTabEditorSectionDiscard) {
        [self discardTapped];
    } else if (indexPath.section == SPKTabEditorSectionReset) {
        [self stageDefaults];
    }
}

#pragma mark Reordering

// Only a lift that starts on the grip reorders. Anywhere else the touch stays a
// plain tap, which is what makes the rest of the row (and its controls) usable.
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView
        itemsForBeginningDragSession:(id<UIDragSession>)session
                         atIndexPath:(NSIndexPath *)indexPath {
    if (![self usesCustomLayout] || indexPath.section != SPKTabEditorSectionTabs)
        return @[];
    NSArray<NSString *> *identifiers = [self rowIdentifiers];
    if (indexPath.row >= (NSInteger)identifiers.count)
        return @[];
    SPKTabEditorCell *cell = (SPKTabEditorCell *)[tableView cellForRowAtIndexPath:indexPath];
    if (![cell isKindOfClass:[SPKTabEditorCell class]] ||
        ![cell spk_pointStartsDrag:[session locationInView:cell]])
        return @[];

    NSString *identifier = identifiers[indexPath.row];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:identifier]];
    item.localObject = identifier;
    return @[ item ];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView
                  dropSessionDidUpdate:(id<UIDropSession>)session
              withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (![self usesCustomLayout] || destinationIndexPath.section != SPKTabEditorSectionTabs)
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                           intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    id<UITableViewDropItem> item = coordinator.items.firstObject;
    NSString *identifier = item.dragItem.localObject;
    NSIndexPath *source = item.sourceIndexPath;
    NSIndexPath *destination = coordinator.destinationIndexPath
                                   ?: [NSIndexPath indexPathForRow:MAX((NSInteger)self.order.count - 1, 0)
                                                         inSection:SPKTabEditorSectionTabs];
    if (![self usesCustomLayout] || !identifier || !source || destination.section != SPKTabEditorSectionTabs)
        return;
    if (![self.order containsObject:identifier])
        return;

    [self.order removeObject:identifier];
    NSUInteger target = MIN((NSUInteger)destination.row, self.order.count);
    [self.order insertObject:identifier atIndex:target];

    [tableView performBatchUpdates:^{
        [tableView deleteRowsAtIndexPaths:@[ source ] withRowAnimation:UITableViewRowAnimationAutomatic];
        [tableView insertRowsAtIndexPaths:@[ destination ] withRowAnimation:UITableViewRowAnimationAutomatic];
    } completion:^(__unused BOOL finished) {
        // Status text ("Opens at launch", the Saved slot) is position-independent
        // but the moved row was rebuilt mid-drag, so refresh the section once.
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:SPKTabEditorSectionTabs]
                 withRowAnimation:UITableViewRowAnimationNone];
    }];
    [coordinator dropItem:item.dragItem toRowAtIndexPath:destination];
    [self refreshStagedUI];
}

#pragma mark Actions

- (BOOL)isIdentifierHidden:(NSString *)identifier {
    if ([identifier isEqualToString:SPKTabIdentifierSaved])
        return ![self savedEnabled];
    return [self.hidden containsObject:identifier];
}

// A row whose visibility cannot be flipped right now: the last reachable
// destination can never be hidden, and Saved cannot be shown while all five
// native tabs are visible, since it has no slot to borrow.
- (BOOL)isVisibilityLockedForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:SPKTabIdentifierSaved]) {
        // Turning Saved off is only refused when it is the last thing left: it
        // counts as a destination, so hiding the native tabs down to Saved alone
        // is allowed, and switching it off there would empty the bar.
        if ([self savedEnabled])
            return [self visibleDestinationCount] == 0;
        return ![self availableSavedCarrier];
    }
    if ([identifier isEqualToString:SPKTabIdentifierCreate])
        return NO; // Create is a launcher, hiding it can never strand the user.
    if ([self.hidden containsObject:identifier])
        return NO;
    // Hiding the last native tab is still allowed while Saved is on: Saved is
    // itself a reachable destination and keeps the bar usable.
    return [self visibleDestinationCount] <= 1 && ![self savedEnabled];
}

// Reloading a section is what re-reads its footer, and what flickers, so the
// sections below the Tabs list are only reloaded when this changes.
- (NSDictionary *)editSignature {
    NSMutableArray *singleTab = [NSMutableArray array];
    for (NSString *key in [self singleTabRowKeys])
        [singleTab addObject:@([self isSingleTabRowEnabled:key])];
    [singleTab addObject:[self singleVisibleTab] ?: @""];
    NSMutableArray *launchable = [NSMutableArray array];
    for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
        if (![self.hidden containsObject:identifier])
            [launchable addObject:identifier];
    }
    return @{
        @(SPKTabEditorSectionSingleTab) : singleTab,
        // The launch menu lists the visible tabs, so it goes stale when one is
        // hidden even though the chosen value has not changed.
        @(SPKTabEditorSectionBehavior) : @[ self.launchTab ?: @"", self.swipeMode ?: @"", launchable ],
        @(SPKTabEditorSectionDiscard) : @([self isDirty]),
    };
}

// A nil signature means the caller already applied its change and cannot say what
// it was, so its sections reload unconditionally.
- (void)reloadAfterEditFromSignature:(NSDictionary *)before {
    NSDictionary *after = [self editSignature];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
    for (NSNumber *section in after) {
        if (!before || ![before[section] isEqual:after[section]])
            [sections addIndex:(NSUInteger)section.integerValue];
    }

    NSMutableArray<NSIndexPath *> *tabRows = [NSMutableArray array];
    NSUInteger rowCount = [self rowIdentifiers].count;
    for (NSUInteger row = 0; row < rowCount; row++)
        [tabRows addObject:[NSIndexPath indexPathForRow:(NSInteger)row inSection:SPKTabEditorSectionTabs]];

    [UIView performWithoutAnimation:^{
        if (tabRows.count == (NSUInteger)[self.tableView numberOfRowsInSection:SPKTabEditorSectionTabs])
            [self.tableView reloadRowsAtIndexPaths:tabRows withRowAnimation:UITableViewRowAnimationNone];
        else
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SPKTabEditorSectionTabs]
                          withRowAnimation:UITableViewRowAnimationNone];
        if (sections.count > 0)
            [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)toggleVisibilityForIdentifier:(NSString *)identifier {
    if ([self isVisibilityLockedForIdentifier:identifier]) {
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning];
        return;
    }

    NSDictionary *signature = [self editSignature];
    if ([identifier isEqualToString:SPKTabIdentifierSaved]) {
        self.savedCarrier = [self savedEnabled] ? SPKTabSavedCarrierNone : [self availableSavedCarrier];
    } else if ([self.hidden containsObject:identifier]) {
        [self.hidden removeObject:identifier];
    } else {
        [self.hidden addObject:identifier];
    }

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self normalizeSavedCarrier];
    [self normalizeLaunchTab];
    [self reloadAfterEditFromSignature:signature];
    [self refreshStagedUI];
}

- (UIMenu *)launchMenu {
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    UIAction *defaultAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_DEFAULT")
                                                  image:nil
                                             identifier:nil
                                                handler:^(__unused UIAction *action) {
                                                    weakSelf.launchTab = @"default";
                                                    [weakSelf stagedValueChanged];
                                                }];
    defaultAction.state = [self.launchTab isEqualToString:@"default"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
        if ([self.hidden containsObject:identifier])
            continue;
        NSString *value = SPKTabLaunchPreferenceValue(identifier);
        UIAction *action = [UIAction actionWithTitle:[self displayTitleForIdentifier:identifier]
                                               image:[SPKAssetUtils menuIconNamed:[self displayIconForIdentifier:identifier]]
                                          identifier:nil
                                             handler:^(__unused UIAction *element) {
                                                 weakSelf.launchTab = value;
                                                 [weakSelf stagedValueChanged];
                                             }];
        action.state = [self.launchTab isEqualToString:value] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIMenu *tabs = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                 options:UIMenuOptionsDisplayInline children:actions];
    UIMenu *fallback = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                     options:UIMenuOptionsDisplayInline children:@[ defaultAction ]];
    return [UIMenu menuWithTitle:@"" children:@[ fallback, tabs ]];
}

- (UIMenu *)swipeMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray<NSString *> *> *choices = @[ @[ SPKL(@"MENU_DEFAULT"), @"default" ], @[ SPKL(@"MENU_ON"), @"enabled" ], @[ SPKL(@"MENU_OFF"), @"disabled" ] ];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *fallback = [NSMutableArray array];
    for (NSArray<NSString *> *choice in choices) {
        NSString *value = choice[1];
        UIAction *action = [UIAction actionWithTitle:choice[0]
                                               image:nil
                                          identifier:nil
                                             handler:^(__unused UIAction *element) {
                                                 weakSelf.swipeMode = value;
                                                 [weakSelf stagedValueChanged];
                                             }];
        action.state = [self.swipeMode isEqualToString:value] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [([value isEqualToString:@"default"] ? fallback : actions) addObject:action];
    }
    UIMenu *choicesMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:actions];
    UIMenu *fallbackMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                         options:UIMenuOptionsDisplayInline children:fallback];
    return [UIMenu menuWithTitle:@"" children:@[ fallbackMenu, choicesMenu ]];
}

- (void)stagedValueChanged {
    [self normalizeLaunchTab];
    [self reloadAfterEditFromSignature:nil];
    [self refreshStagedUI];
}

- (void)stageDefaults {
    self.layoutMode = SPKTabLayoutDefault;
    self.order = [SPKNormalizeTabOrder(nil) mutableCopy];
    self.hidden = [NSMutableSet set];
    self.launchTab = @"default";
    self.swipeMode = @"default";
    self.savedCarrier = SPKTabSavedCarrierNone;
    self.hidesTabBarWhenSingle = NO;
    self.showsInboxShortcut = YES;
    [self applyEditingState];
    [self.tableView reloadData];
    [self refreshStagedUI];
}

- (void)applyTapped {
    SPKPreferenceSetObject(self.layoutMode, SPKPrefTabLayout);
    SPKPreferenceSetObject(SPKNormalizeTabOrder(self.order), SPKPrefCustomTabOrder);
    for (NSString *identifier in SPKTabEditableIdentifiers())
        SPKPreferenceSetObject(@([self.hidden containsObject:identifier]), SPKTabHidePreferenceKey(identifier));
    SPKPreferenceSetObject(self.launchTab, @"interface_launch_tab");
    SPKPreferenceSetObject(self.swipeMode, @"interface_swipe_tabs");
    SPKPreferenceSetObject(self.savedCarrier, SPKPrefSavedTabCarrier);
    SPKPreferenceSetObject(@(self.hidesTabBarWhenSingle), SPKPrefHideTabBarWhenSingle);
    SPKPreferenceSetObject(@(self.showsInboxShortcut), SPKPrefInboxHeaderShortcut);
    // The restart prompt below can terminate the app, so the staged values have
    // to be on disk before it is presented.
    [NSUserDefaults.standardUserDefaults synchronize];

    self.persistedSnapshot = [self snapshot];
    [self refreshStagedUI];
    [SPKUtils showRestartConfirmation];
}

- (void)discardTapped {
    if (![self isDirty])
        return;
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"SETTINGS_TAB_EDITOR_DISCARD_CHANGES_QUESTION")
                                                message:SPKL(@"SETTINGS_TAB_EDITOR_TAB_LAYOUT_NOT_APPLIED_YET_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DISCARD")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [weakSelf loadPersistedValues];
                                                                                  [weakSelf applyEditingState];
                                                                                  [weakSelf.tableView reloadData];
                                                                                  [weakSelf refreshStagedUI];
                                                                              }],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_KEEP_EDITING")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                ]];
}

@end
