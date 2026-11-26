#import "SPKDeletedMessagesChipBar.h"
#import "../../../AssetUtils.h"
#import "../../../Shared/UI/SPKChipGlass.h"
#import "../../../Utils.h"
#import "../../../Shared/UI/SPKFont.h"

@interface SPKDeletedMessagesChipBar ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selection;
@property (nonatomic, copy) NSArray<NSString *> *symbols;
@property (nonatomic, copy) NSArray<NSString *> *selectedSymbols;
@end

@implementation SPKDeletedMessagesChipBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return self;
    self.backgroundColor = [UIColor clearColor];
    _selection = [NSMutableSet set];

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.contentInset = UIEdgeInsetsMake(0, 14, 0, 14);
    [self addSubview:_scroll];

    _stack = [UIStackView new];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisHorizontal;
    _stack.spacing = 8;
    _stack.alignment = UIStackViewAlignmentCenter;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor
                                         constant:6],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor
                                            constant:-6],
        [_stack.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor
                                            constant:-12],
    ]];
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 50);
}

- (void)setItems:(NSArray<NSString *> *)titles symbols:(NSArray<NSString *> *)symbols {
    [self setItems:titles symbols:symbols selectedSymbols:nil];
}

- (void)setItems:(NSArray<NSString *> *)titles
            symbols:(NSArray<NSString *> *)symbols
    selectedSymbols:(NSArray<NSString *> *)selectedSymbols {
    self.symbols = symbols;
    self.selectedSymbols = selectedSymbols;
    for (UIView *v in self.stack.arrangedSubviews) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSMutableArray<UIButton *> *chips = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *sym = (i < (NSInteger)symbols.count) ? symbols[i] : nil;
        UIButton *c = [UIButton buttonWithType:UIButtonTypeSystem];
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightSemibold] to:c.titleLabel];
        [c setTitle:titles[i] forState:UIControlStateNormal];
        if (sym.length) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:sym pointSize:14.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            [c setImage:image forState:UIControlStateNormal];
            c.imageView.contentMode = UIViewContentModeScaleAspectFit;
            c.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
            c.contentEdgeInsets = UIEdgeInsetsMake(7, 12, 7, 18);
        } else {
            c.contentEdgeInsets = UIEdgeInsetsMake(7, 12, 7, 12);
        }
        c.layer.cornerRadius = 15.0;
        c.tag = i;
        [c addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.stack addArrangedSubview:c];
        [chips addObject:c];
    }
    self.chips = chips;
    [self.selection removeAllObjects];
    [self refreshSelection];
}

- (NSSet<NSNumber *> *)selectedIndices {
    return [self.selection copy];
}

- (void)clearSelection {
    if (self.selection.count == 0)
        return;
    [self.selection removeAllObjects];
    [self refreshSelection];
}

- (void)refreshSelection {
    for (NSInteger i = 0; i < (NSInteger)self.chips.count; i++) {
        UIButton *chip = self.chips[i];
        BOOL selected = [self.selection containsObject:@(i)];
        // Swap to the filled glyph when selected (when a selected variant exists).
        NSString *baseSym = (i < (NSInteger)self.symbols.count) ? self.symbols[i] : nil;
        NSString *selSym = (selected && i < (NSInteger)self.selectedSymbols.count) ? self.selectedSymbols[i] : nil;
        NSString *sym = selSym.length ? selSym : baseSym;
        if (sym.length) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:sym pointSize:14.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            [chip setImage:image forState:UIControlStateNormal];
        }
        // After the glyph swap: the glass reads the chip's current image.
        if (!SPKChipApplyGlass(chip, selected, chip.layer.cornerRadius, [SPKUtils SPKColor_InstagramPrimaryText])) {
            chip.backgroundColor = selected ? [SPKUtils SPKColor_InstagramPrimaryText] : [SPKUtils SPKColor_InstagramSecondaryBackground];
            chip.tintColor = selected ? [SPKUtils SPKColor_InstagramBackground] : [SPKUtils SPKColor_InstagramPrimaryText];
            [chip setTitleColor:(selected ? [SPKUtils SPKColor_InstagramBackground] : [SPKUtils SPKColor_InstagramPrimaryText]) forState:UIControlStateNormal];
        }
    }
}

- (void)chipTapped:(UIButton *)c {
    NSNumber *key = @(c.tag);
    if ([self.selection containsObject:key]) {
        [self.selection removeObject:key]; // retap deselects
    } else {
        [self.selection addObject:key]; // multi-select
    }
    [self refreshSelection];
    if ([self.delegate respondsToSelector:@selector(chipBar:didChangeSelection:)]) {
        [self.delegate chipBar:self didChangeSelection:[self.selection copy]];
    }
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

@end
