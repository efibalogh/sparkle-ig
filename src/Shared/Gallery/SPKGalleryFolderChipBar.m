#import "SPKGalleryFolderChipBar.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKChipGlass.h"

static CGFloat const kChipBarHeight = 52.0;
static CGFloat const kChipHeight = 34.0;
static CGFloat const kChipSpacing = 8.0;
static CGFloat const kChipHorizontalInset = 14.0;

@interface SPKGalleryFolderChipBar ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);
@property (nonatomic, copy, nullable) UIMenu *_Nullable (^menuProvider)(NSInteger index);
@end

@implementation SPKGalleryFolderChipBar

+ (CGFloat)preferredHeight {
    return kChipBarHeight;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];

        _scroll = [[UIScrollView alloc] init];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.showsVerticalScrollIndicator = NO;
        _scroll.contentInset = UIEdgeInsetsMake(0, kChipHorizontalInset, 0, kChipHorizontalInset);
        [self addSubview:_scroll];

        _stack = [[UIStackView alloc] init];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.spacing = kChipSpacing;
        _stack.alignment = UIStackViewAlignmentCenter;
        [_scroll addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            // Clear of a side column, like the grid below it.
            [_scroll.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
            [_stack.centerYAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.centerYAnchor],
            [_stack.heightAnchor constraintEqualToConstant:kChipHeight],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onSelect = nil;
    self.menuProvider = nil;
    for (UIView *v in self.stack.arrangedSubviews) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)configureWithFolderNames:(NSArray<NSString *> *)names
                          counts:(NSArray<NSNumber *> *)counts
                        onSelect:(void (^)(NSInteger))onSelect
                    menuProvider:(UIMenu *_Nullable (^)(NSInteger))menuProvider {
    self.onSelect = onSelect;
    self.menuProvider = menuProvider;

    for (UIView *v in self.stack.arrangedSubviews) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        NSInteger count = (i < (NSInteger)counts.count) ? counts[i].integerValue : 0;
        UIButton *chip = [self chipForName:names[i] count:count index:i];
        [self.stack addArrangedSubview:chip];
    }
}

- (UIButton *)chipForName:(NSString *)name count:(NSInteger)count index:(NSInteger)index {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.tag = index;
    chip.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];

    NSString *title = count > 0
                          ? [NSString stringWithFormat:@"%@  •  %ld", name, (long)count]
                          : name;
    [chip setTitle:title forState:UIControlStateNormal];

    UIImage *icon = [SPKAssetUtils instagramIconNamed:@"folder"
                                            pointSize:14.0
                                        renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (icon) {
        [chip setImage:icon forState:UIControlStateNormal];
        chip.imageView.contentMode = UIViewContentModeScaleAspectFit;
        chip.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
        chip.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 20);
    } else {
        chip.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    }

    chip.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [chip setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];
    chip.layer.cornerRadius = kChipHeight / 2.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    // Folder chips aren't a selection — clear glass capsules on iOS 26, solid
    // fill otherwise.
    if (!SPKChipApplyStaticGlass(chip, kChipHeight / 2.0)) {
        chip.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    }

    [chip.heightAnchor constraintEqualToConstant:kChipHeight].active = YES;
    [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];

    // Context menu (rename/delete/etc.) when a provider is supplied.
    if (self.menuProvider) {
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:(id<UIContextMenuInteractionDelegate>)self];
        [chip addInteraction:interaction];
    }

    return chip;
}

- (void)chipTapped:(UIButton *)chip {
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
    if (self.onSelect) {
        self.onSelect(chip.tag);
    }
}

#pragma mark - UIContextMenuInteractionDelegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    UIView *view = interaction.view;
    if (![view isKindOfClass:[UIButton class]] || !self.menuProvider) {
        return nil;
    }
    NSInteger index = view.tag;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *_Nullable(NSArray<UIMenuElement *> *_Nonnull suggested) {
                                                        __strong typeof(weakSelf) strongSelf = weakSelf;
                                                        if (!strongSelf.menuProvider)
                                                            return nil;
                                                        return strongSelf.menuProvider(index);
                                                    }];
}

@end
