#import "SPKMediaPreviewInfoOverlay.h"
#import "../UI/SPKFont.h"

@interface SPKMediaPreviewInfoOverlay ()
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation SPKMediaPreviewInfoOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Pure decoration: never eat touches so the media's tap-to-toggle keeps working.
        self.userInteractionEnabled = NO;

        _titleLabel = [self makeLabel];
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightSemibold] to:_titleLabel];
        _titleLabel.textColor = [UIColor whiteColor];

        _subtitleLabel = [self makeLabel];
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption1] to:_subtitleLabel];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];

        _stack = [[UIStackView alloc]
            initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.alignment = UIStackViewAlignmentLeading;
        _stack.spacing = 2.0;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
            [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:8.0],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0],
        ]];
    }
    return self;
}

- (UILabel *)makeLabel {
    UILabel *label = [UILabel new];
    // No scrim: a strong drop shadow is what keeps text legible over bright media.
    label.layer.shadowColor = [UIColor blackColor].CGColor;
    label.layer.shadowOpacity = 0.85;
    label.layer.shadowRadius = 3.0;
    label.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    label.layer.masksToBounds = NO;
    return label;
}

- (BOOL)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    NSString *trimmedTitle = [self trimmedOrNil:title];
    self.titleLabel.text = trimmedTitle;
    self.titleLabel.hidden = (trimmedTitle.length == 0);

    NSString *trimmedSubtitle = [self trimmedOrNil:subtitle];
    self.subtitleLabel.text = trimmedSubtitle;
    self.subtitleLabel.hidden = (trimmedSubtitle.length == 0);

    return !(self.titleLabel.hidden && self.subtitleLabel.hidden);
}

- (NSString *)trimmedOrNil:(NSString *)value {
    if (![value isKindOfClass:[NSString class]])
        return nil;
    NSString *trimmed = [value
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

@end
