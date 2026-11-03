#import "SPKMediaUnavailableView.h"

#import "../../AssetUtils.h"

@interface SPKMediaUnavailableView ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@end

@implementation SPKMediaUnavailableView

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame]))
        return nil;

    _iconView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"error_empty"
                                                                           pointSize:96
                                                                       renderingMode:UIImageRenderingModeAlwaysTemplate]];
    _iconView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 0;

    _messageLabel = [[UILabel alloc] init];
    _messageLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    _messageLabel.font = [UIFont systemFontOfSize:15];
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ _iconView, _titleLabel, _messageLabel ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [stack setCustomSpacing:18 afterView:_iconView];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.widthAnchor constraintEqualToConstant:96],
        [_iconView.heightAnchor constraintEqualToConstant:96],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    return self;
}

- (void)setTitle:(NSString *)title message:(NSString *)message {
    self.titleLabel.text = title;
    self.messageLabel.text = message;
    self.messageLabel.hidden = message.length == 0;
    self.accessibilityLabel = title;
    self.accessibilityValue = message.length > 0 ? message : nil;
}

@end
