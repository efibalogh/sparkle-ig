#import "SPKChipBar.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "SPKChipGlass.h"
#import "SPKFont.h"

@interface SPKChipBar ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selection;
@property (nonatomic, copy) NSArray<NSString *> *symbols;
@property (nonatomic, copy) NSArray<NSString *> *selectedSymbols;
@property (nonatomic, strong) NSLayoutConstraint *fitWidthConstraint;
@end

@implementation SPKChipBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return self;
    self.backgroundColor = [UIColor clearColor];
    _selection = [NSMutableSet set];
    _selectedIndex = 0;
    _multiSelect = NO;

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

- (void)ensureFitWidthConstraint {
    if (!self.fitWidthConstraint) {
        // Fill the visible width minus the scroll's symmetric content inset, so
        // the distributed chips span the bar without scrolling.
        self.fitWidthConstraint = [self.stack.widthAnchor
            constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor
                           constant:-(self.scroll.contentInset.left + self.scroll.contentInset.right)];
    }
}

// Applies whichever fill mode is set. Both fill modes disable scrolling and pin
// the stack to the bar width; only the stack distribution differs.
- (void)applyDistributionMode {
    BOOL fills = _distributesToFit || _distributesProportionally;
    self.scroll.scrollEnabled = !fills;
    if (_distributesProportionally)
        self.stack.distribution = UIStackViewDistributionFillProportionally;
    else if (_distributesToFit)
        self.stack.distribution = UIStackViewDistributionFillEqually;
    else
        self.stack.distribution = UIStackViewDistributionFill;
    [self ensureFitWidthConstraint];
    self.fitWidthConstraint.active = fills;
}

- (void)setDistributesToFit:(BOOL)distributesToFit {
    _distributesToFit = distributesToFit;
    if (distributesToFit)
        _distributesProportionally = NO;
    [self applyDistributionMode];
}

- (void)setDistributesProportionally:(BOOL)distributesProportionally {
    _distributesProportionally = distributesProportionally;
    if (distributesProportionally)
        _distributesToFit = NO;
    [self applyDistributionMode];
}

// Full-size icons at all times; on narrow screens the fill-mode chips let their
// titles auto-shrink (adjustsFontSizeToFitWidth) rather than the whole row
// shrinking regardless of screen size.
- (CGFloat)chipIconPointSize {
    return 14.0;
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
        c.titleLabel.font = [SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightSemibold];
        // In a fill mode a label may not fit its share, so allow a touch of
        // shrink rather than truncating. Equal-fill needs more room (0.7);
        // proportional sizes chips to content so it only needs a small safety
        // floor (0.85) for the narrowest screens.
        BOOL fills = self.distributesToFit || self.distributesProportionally;
        c.titleLabel.adjustsFontSizeToFitWidth = fills;
        c.titleLabel.minimumScaleFactor = self.distributesToFit ? 0.7 : (self.distributesProportionally ? 0.85 : 1.0);
        c.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [c setTitle:titles[i] forState:UIControlStateNormal];
        if (sym.length) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:sym pointSize:[self chipIconPointSize] renderingMode:UIImageRenderingModeAlwaysTemplate];
            [c setImage:image forState:UIControlStateNormal];
            c.imageView.contentMode = UIViewContentModeScaleAspectFit;
            // Right inset (18) balances the -6 titleEdgeInset so the icon-side and
            // text-side padding read symmetrically.
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
    if (self.multiSelect) {
        [self.selection removeAllObjects];
    } else {
        // Enforce default selected index bounds
        if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.chips.count) {
            _selectedIndex = 0;
        }
    }
    [self refreshSelection];
}

- (NSSet<NSNumber *> *)selectedIndices {
    if (self.multiSelect) {
        return [self.selection copy];
    } else {
        return [NSSet setWithObject:@(self.selectedIndex)];
    }
}

- (void)setSelectedIndices:(NSSet<NSNumber *> *)selectedIndices {
    if (self.multiSelect) {
        self.selection = [selectedIndices mutableCopy];
    } else {
        NSNumber *first = selectedIndices.anyObject;
        if (first) {
            _selectedIndex = first.integerValue;
        }
    }
    [self refreshSelection];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (_selectedIndex == selectedIndex)
        return;
    _selectedIndex = selectedIndex;
    [self refreshSelection];
}

- (void)clearSelection {
    if (self.multiSelect) {
        if (self.selection.count == 0)
            return;
        [self.selection removeAllObjects];
    } else {
        _selectedIndex = 0;
    }
    [self refreshSelection];
}

- (void)refreshSelection {
    for (NSInteger i = 0; i < (NSInteger)self.chips.count; i++) {
        UIButton *chip = self.chips[i];
        BOOL selected = NO;
        if (self.multiSelect) {
            selected = [self.selection containsObject:@(i)];
        } else {
            selected = (i == self.selectedIndex);
        }
        // Swap to the filled glyph when selected (when a selected variant exists).
        NSString *baseSym = (i < (NSInteger)self.symbols.count) ? self.symbols[i] : nil;
        NSString *selSym = (selected && i < (NSInteger)self.selectedSymbols.count) ? self.selectedSymbols[i] : nil;
        NSString *sym = selSym.length ? selSym : baseSym;
        if (sym.length) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:sym pointSize:[self chipIconPointSize] renderingMode:UIImageRenderingModeAlwaysTemplate];
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
    NSInteger index = c.tag;
    BOOL changed = NO;
    if (self.multiSelect) {
        NSNumber *key = @(index);
        if ([self.selection containsObject:key]) {
            [self.selection removeObject:key];
        } else {
            [self.selection addObject:key];
        }
        changed = YES;
    } else {
        if (self.selectedIndex != index) {
            self.selectedIndex = index;
            changed = YES;
        }
    }

    if (changed) {
        [self refreshSelection];
        if (self.multiSelect) {
            if ([self.delegate respondsToSelector:@selector(chipBar:didChangeSelection:)]) {
                [self.delegate chipBar:self didChangeSelection:[self.selection copy]];
            }
        } else {
            if ([self.delegate respondsToSelector:@selector(chipBar:didSelectIndex:)]) {
                [self.delegate chipBar:self didSelectIndex:index];
            }
        }
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
}

@end
