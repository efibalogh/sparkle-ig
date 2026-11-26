#import "SPKStrings.h"
#import "SPKDeletedMessageBubbleCell.h"
#import "../../../AssetUtils.h"
#import "../../../Utils.h"
#import "SPKDeletedMessagesAvatarView.h"
#import "SPKDeletedMessagesDate.h"
#import "../../../App/SPKPerfMeter.h"
#import "../../../Shared/UI/SPKFont.h"

NSString *const SPKDeletedMessageBubbleCellReuseID = @"SPKDeletedMessageBubbleCell";

static CGFloat const kSPKBubbleMediaSize = 150.0;

static NSString *SPKDeletedFormatDuration(double seconds);

@interface SPKDeletedMessageBubbleCell ()
@property (nonatomic, copy, readwrite, nullable) NSString *messageId;
@property (nonatomic, strong) SPKDeletedMessage *message;
@property (nonatomic, assign) BOOL outgoing;

@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UIStackView *contentStack;

// Kind chip header.
@property (nonatomic, strong) UIView *kindChip;
@property (nonatomic, strong) UIImageView *kindIcon;
@property (nonatomic, strong) UILabel *kindLabel;

// Text content.
@property (nonatomic, strong) UILabel *textLabel_;

// Media content.
@property (nonatomic, strong) UIView *mediaContainer;
@property (nonatomic, strong) UIImageView *mediaView;
@property (nonatomic, strong) UIImageView *playGlyph;
@property (nonatomic, strong) UIImageView *unavailableGlyph;
@property (nonatomic, strong) UILabel *unavailableLabel;
@property (nonatomic, strong) UIView *durationPill;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) NSLayoutConstraint *mediaHeightConstraint;

// Voice content.
@property (nonatomic, strong) UIView *voicePill;
@property (nonatomic, strong) UIImageView *voicePlayIcon;
@property (nonatomic, strong) UILabel *voiceLabel;

// Share / link card.
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *cardThumb;
@property (nonatomic, strong) UIImageView *cardPlaceholder;
@property (nonatomic, strong) UILabel *cardTitle;
@property (nonatomic, strong) UILabel *cardURL;

// Per-sender avatar + name row above incoming bubbles (group threads only).
@property (nonatomic, strong) SPKDeletedMessagesAvatarView *senderAvatarView;
@property (nonatomic, strong) UILabel *senderLabel;
@property (nonatomic, strong) NSLayoutConstraint *bubbleTopDefault;   // bubble pinned to contentView top
@property (nonatomic, strong) NSLayoutConstraint *bubbleTopBelowName; // bubble pinned below the avatar row

@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) NSLayoutConstraint *bubbleLeadingPin;    // incoming: pin to left
@property (nonatomic, strong) NSLayoutConstraint *bubbleTrailingPin;   // outgoing: pin to right
@property (nonatomic, strong) NSLayoutConstraint *bubbleLeadingLimit;  // outgoing: keep off the left edge
@property (nonatomic, strong) NSLayoutConstraint *bubbleTrailingLimit; // incoming: keep off the right edge
@property (nonatomic, strong) NSLayoutConstraint *timeLeadingPin;
@property (nonatomic, strong) NSLayoutConstraint *timeTrailingPin;
@end

@implementation SPKDeletedMessageBubbleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self buildHierarchy];
    }
    return self;
}

- (void)buildHierarchy {
    _bubble = [UIView new];
    _bubble.translatesAutoresizingMaskIntoConstraints = NO;
    _bubble.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _bubble.layer.cornerRadius = 18.0;
    _bubble.clipsToBounds = YES;
    [self.contentView addSubview:_bubble];

    _contentStack = [UIStackView new];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = 8.0;
    _contentStack.alignment = UIStackViewAlignmentLeading;
    [_bubble addSubview:_contentStack];

    [self buildKindChip];
    [self buildTextContent];
    [self buildMediaContent];
    [self buildVoiceContent];
    [self buildCardContent];

    [_contentStack addArrangedSubview:_kindChip];
    [_contentStack addArrangedSubview:_textLabel_];
    [_contentStack addArrangedSubview:_mediaContainer];
    [_contentStack addArrangedSubview:_voicePill];
    [_contentStack addArrangedSubview:_cardView];

    // 22pt circular avatar shown to the left of the sender name (group threads only).
    static CGFloat const kSenderAvatarSize = 22.0;
    _senderAvatarView = [[SPKDeletedMessagesAvatarView alloc] initWithFrame:CGRectZero];
    _senderAvatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _senderAvatarView.hidden = YES;
    [self.contentView addSubview:_senderAvatarView];

    _senderLabel = [UILabel new];
    _senderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption2 weight:UIFontWeightSemibold] to:_senderLabel];
    _senderLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _senderLabel.hidden = YES;
    [self.contentView addSubview:_senderLabel];

    _timeLabel = [UILabel new];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption2] to:_timeLabel];
    _timeLabel.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [self.contentView addSubview:_timeLabel];

    CGFloat sideInset = 16.0;
    CGFloat minGutter = 56.0; // keep the opposite edge clear so bubbles read as L/R

    _bubbleLeadingPin = [_bubble.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:sideInset];
    _bubbleTrailingPin = [_bubble.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-sideInset];
    _bubbleLeadingLimit = [_bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:minGutter];
    _bubbleTrailingLimit = [_bubble.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-minGutter];

    _timeLeadingPin = [_timeLabel.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor constant:4.0];
    _timeTrailingPin = [_timeLabel.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor constant:-4.0];

    // Bubble top is normally pinned to the cell top; when a sender avatar+name row
    // is shown (group threads) the bubble drops below the avatar instead.
    _bubbleTopDefault = [_bubble.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6.0];
    _bubbleTopBelowName = [_bubble.topAnchor constraintEqualToAnchor:_senderAvatarView.bottomAnchor constant:4.0];
    _bubbleTopDefault.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        // Avatar: left-aligned with the bubble, sits at the top of the name row.
        [_senderAvatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                        constant:sideInset],
        [_senderAvatarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                    constant:6.0],
        [_senderAvatarView.widthAnchor constraintEqualToConstant:kSenderAvatarSize],
        [_senderAvatarView.heightAnchor constraintEqualToConstant:kSenderAvatarSize],

        // Name: to the right of the avatar, vertically centered with it.
        [_senderLabel.leadingAnchor constraintEqualToAnchor:_senderAvatarView.trailingAnchor
                                                   constant:6.0],
        [_senderLabel.centerYAnchor constraintEqualToAnchor:_senderAvatarView.centerYAnchor],
        [_senderLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor
                                                              constant:-16.0],

        [_contentStack.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor
                                                    constant:12.0],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor
                                                     constant:-12.0],
        [_contentStack.topAnchor constraintEqualToAnchor:_bubble.topAnchor
                                                constant:10.0],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_bubble.bottomAnchor
                                                   constant:-10.0],

        [_timeLabel.topAnchor constraintEqualToAnchor:_bubble.bottomAnchor
                                             constant:4.0],
        [_timeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                constant:-8.0],
    ]];

    // Default to incoming (left-aligned).
    [self setOutgoing:NO];
}

// Toggle bubble alignment + tint. Outgoing (your own unsends) sit on the right
// with an inverted high-contrast tint so they read as "sent". Inner surfaces
// (media placeholder, card, voice pill) layer against the bubble using the
// inverse dynamic colors so they stay legible in both light and dark mode.
- (void)setOutgoing:(BOOL)outgoing {
    _outgoing = outgoing;

    self.bubbleLeadingPin.active = !outgoing;
    self.bubbleTrailingLimit.active = !outgoing;
    self.bubbleTrailingPin.active = outgoing;
    self.bubbleLeadingLimit.active = outgoing;
    self.timeLeadingPin.active = !outgoing;
    self.timeTrailingPin.active = outgoing;
    self.timeLabel.textAlignment = outgoing ? NSTextAlignmentRight : NSTextAlignmentLeft;

    UIColor *bubbleColor = outgoing ? [SPKUtils SPKColor_InstagramPrimaryText] : [SPKUtils SPKColor_InstagramSecondaryBackground];
    UIColor *primaryTextColor = [self bubblePrimaryTextColor];
    UIColor *secondaryTextColor = [self bubbleSecondaryTextColor];
    UIColor *innerSurface = [self bubbleInnerSurfaceColor];

    self.bubble.backgroundColor = bubbleColor;
    self.textLabel_.textColor = primaryTextColor;
    self.kindIcon.tintColor = secondaryTextColor;
    self.kindLabel.textColor = secondaryTextColor;

    // Media placeholder backdrop (behind thumbnails / kind glyph).
    self.mediaView.backgroundColor = innerSurface;
    self.unavailableGlyph.tintColor = secondaryTextColor;
    self.unavailableLabel.textColor = secondaryTextColor;

    // Voice pill.
    self.voicePill.backgroundColor = innerSurface;
    self.voicePlayIcon.tintColor = primaryTextColor;
    self.voiceLabel.textColor = primaryTextColor;

    // Share / link card.
    self.cardView.backgroundColor = innerSurface;
    self.cardThumb.backgroundColor = innerSurface;
    self.cardPlaceholder.tintColor = secondaryTextColor;
    self.cardTitle.textColor = primaryTextColor;
    self.cardURL.textColor = secondaryTextColor;
}

// Text/icons that must contrast with the bubble fill.
- (UIColor *)bubblePrimaryTextColor {
    return _outgoing ? [SPKUtils SPKColor_InstagramBackground] : [SPKUtils SPKColor_InstagramPrimaryText];
}
- (UIColor *)bubbleSecondaryTextColor {
    return _outgoing ? [[SPKUtils SPKColor_InstagramBackground] colorWithAlphaComponent:0.7]
                     : [SPKUtils SPKColor_InstagramSecondaryText];
}
// A subtle layer drawn on top of the bubble fill for media/cards/voice. On the
// inverted outgoing bubble this is a translucent wash of the inverse color so
// it reads as a lighter/darker panel rather than clashing.
- (UIColor *)bubbleInnerSurfaceColor {
    return _outgoing ? [[SPKUtils SPKColor_InstagramBackground] colorWithAlphaComponent:0.18]
                     : [SPKUtils SPKColor_InstagramTertiaryBackground];
}

- (UITargetedPreview *)contextMenuTargetedPreview {
    UIPreviewParameters *parameters = [UIPreviewParameters new];
    parameters.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    return [[UITargetedPreview alloc] initWithView:self.contentView parameters:parameters];
}

- (void)buildKindChip {
    _kindChip = [UIView new];
    _kindChip.translatesAutoresizingMaskIntoConstraints = NO;

    _kindIcon = [UIImageView new];
    _kindIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _kindIcon.contentMode = UIViewContentModeScaleAspectFit;
    _kindIcon.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    [_kindChip addSubview:_kindIcon];

    _kindLabel = [UILabel new];
    _kindLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleBadge weight:UIFontWeightSemibold] to:_kindLabel];
    _kindLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    [_kindChip addSubview:_kindLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_kindIcon.leadingAnchor constraintEqualToAnchor:_kindChip.leadingAnchor],
        [_kindIcon.centerYAnchor constraintEqualToAnchor:_kindChip.centerYAnchor],
        [_kindIcon.widthAnchor constraintEqualToConstant:12.0],
        [_kindIcon.heightAnchor constraintEqualToConstant:12.0],
        [_kindIcon.topAnchor constraintEqualToAnchor:_kindChip.topAnchor],
        [_kindIcon.bottomAnchor constraintEqualToAnchor:_kindChip.bottomAnchor],
        [_kindLabel.leadingAnchor constraintEqualToAnchor:_kindIcon.trailingAnchor
                                                 constant:5.0],
        [_kindLabel.trailingAnchor constraintEqualToAnchor:_kindChip.trailingAnchor],
        [_kindLabel.centerYAnchor constraintEqualToAnchor:_kindChip.centerYAnchor],
    ]];
}

- (void)buildTextContent {
    _textLabel_ = [UILabel new];
    _textLabel_.translatesAutoresizingMaskIntoConstraints = NO;
    _textLabel_.numberOfLines = 0;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline] to:_textLabel_];
    _textLabel_.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
}

- (void)buildMediaContent {
    _mediaContainer = [UIView new];
    _mediaContainer.translatesAutoresizingMaskIntoConstraints = NO;

    _mediaView = [UIImageView new];
    _mediaView.translatesAutoresizingMaskIntoConstraints = NO;
    _mediaView.contentMode = UIViewContentModeScaleAspectFill;
    _mediaView.clipsToBounds = YES;
    _mediaView.layer.cornerRadius = 12.0;
    _mediaView.backgroundColor = [SPKUtils SPKColor_InstagramTertiaryBackground];
    _mediaView.userInteractionEnabled = YES;
    [_mediaContainer addSubview:_mediaView];

    _playGlyph = [UIImageView new];
    _playGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    _playGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _playGlyph.tintColor = [UIColor whiteColor];
    _playGlyph.image = [SPKAssetUtils instagramIconNamed:@"play_filled_32" pointSize:32.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    _playGlyph.hidden = YES;
    [_mediaContainer addSubview:_playGlyph];

    _unavailableGlyph = [UIImageView new];
    _unavailableGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    _unavailableGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _unavailableGlyph.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _unavailableGlyph.hidden = YES;
    [_mediaContainer addSubview:_unavailableGlyph];

    _unavailableLabel = [UILabel new];
    _unavailableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption1 weight:UIFontWeightSemibold] to:_unavailableLabel];
    _unavailableLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _unavailableLabel.text = SPKL(@"MESSAGES_DELETED_MESSAGE_BUBBLE_CELL_MEDIA_UNAVAILABLE_TEXT");
    _unavailableLabel.adjustsFontSizeToFitWidth = YES;
    _unavailableLabel.minimumScaleFactor = 0.75;
    _unavailableLabel.hidden = YES;
    [_mediaContainer addSubview:_unavailableLabel];

    _durationPill = [UIView new];
    _durationPill.translatesAutoresizingMaskIntoConstraints = NO;
    _durationPill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _durationPill.layer.cornerRadius = 9.0;
    _durationPill.hidden = YES;
    [_mediaContainer addSubview:_durationPill];

    _durationLabel = [UILabel new];
    _durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption2 weight:UIFontWeightSemibold] to:_durationLabel];
    _durationLabel.textColor = [UIColor whiteColor];
    [_durationPill addSubview:_durationLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMediaTap)];
    [_mediaView addGestureRecognizer:tap];

    _mediaHeightConstraint = [_mediaView.heightAnchor constraintEqualToConstant:kSPKBubbleMediaSize];
    [NSLayoutConstraint activateConstraints:@[
        [_mediaView.leadingAnchor constraintEqualToAnchor:_mediaContainer.leadingAnchor],
        [_mediaView.trailingAnchor constraintEqualToAnchor:_mediaContainer.trailingAnchor],
        [_mediaView.topAnchor constraintEqualToAnchor:_mediaContainer.topAnchor],
        [_mediaView.bottomAnchor constraintEqualToAnchor:_mediaContainer.bottomAnchor],
        [_mediaView.widthAnchor constraintEqualToConstant:kSPKBubbleMediaSize],
        _mediaHeightConstraint,

        [_playGlyph.centerXAnchor constraintEqualToAnchor:_mediaView.centerXAnchor],
        [_playGlyph.centerYAnchor constraintEqualToAnchor:_mediaView.centerYAnchor],
        [_playGlyph.widthAnchor constraintEqualToConstant:40.0],
        [_playGlyph.heightAnchor constraintEqualToConstant:40.0],

        [_unavailableGlyph.leadingAnchor constraintEqualToAnchor:_mediaView.leadingAnchor constant:12.0],
        [_unavailableGlyph.centerYAnchor constraintEqualToAnchor:_mediaView.centerYAnchor],
        [_unavailableGlyph.widthAnchor constraintEqualToConstant:18.0],
        [_unavailableGlyph.heightAnchor constraintEqualToConstant:18.0],
        [_unavailableLabel.leadingAnchor constraintEqualToAnchor:_unavailableGlyph.trailingAnchor constant:8.0],
        [_unavailableLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_mediaView.trailingAnchor constant:-12.0],
        [_unavailableLabel.centerYAnchor constraintEqualToAnchor:_mediaView.centerYAnchor],

        [_durationPill.trailingAnchor constraintEqualToAnchor:_mediaView.trailingAnchor
                                                     constant:-8.0],
        [_durationPill.bottomAnchor constraintEqualToAnchor:_mediaView.bottomAnchor
                                                   constant:-8.0],
        [_durationPill.heightAnchor constraintEqualToConstant:18.0],
        [_durationLabel.leadingAnchor constraintEqualToAnchor:_durationPill.leadingAnchor
                                                     constant:7.0],
        [_durationLabel.trailingAnchor constraintEqualToAnchor:_durationPill.trailingAnchor
                                                      constant:-7.0],
        [_durationLabel.centerYAnchor constraintEqualToAnchor:_durationPill.centerYAnchor],
    ]];
}

- (void)buildVoiceContent {
    _voicePill = [UIView new];
    _voicePill.translatesAutoresizingMaskIntoConstraints = NO;
    _voicePill.backgroundColor = [SPKUtils SPKColor_InstagramTertiaryBackground];
    _voicePill.layer.cornerRadius = 16.0;
    _voicePill.userInteractionEnabled = YES;

    _voicePlayIcon = [UIImageView new];
    _voicePlayIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _voicePlayIcon.contentMode = UIViewContentModeScaleAspectFit;
    _voicePlayIcon.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _voicePlayIcon.image = [SPKAssetUtils instagramIconNamed:@"play_filled" pointSize:20.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    [_voicePill addSubview:_voicePlayIcon];

    _voiceLabel = [UILabel new];
    _voiceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightMedium] to:_voiceLabel];
    _voiceLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    [_voicePill addSubview:_voiceLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMediaTap)];
    [_voicePill addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [_voicePill.heightAnchor constraintEqualToConstant:44.0],

        [_voicePlayIcon.leadingAnchor constraintEqualToAnchor:_voicePill.leadingAnchor
                                                     constant:14.0],
        [_voicePlayIcon.centerYAnchor constraintEqualToAnchor:_voicePill.centerYAnchor],
        [_voicePlayIcon.widthAnchor constraintEqualToConstant:20.0],
        [_voicePlayIcon.heightAnchor constraintEqualToConstant:20.0],

        [_voiceLabel.leadingAnchor constraintEqualToAnchor:_voicePlayIcon.trailingAnchor
                                                  constant:10.0],
        [_voiceLabel.trailingAnchor constraintEqualToAnchor:_voicePill.trailingAnchor
                                                   constant:-16.0],
        [_voiceLabel.centerYAnchor constraintEqualToAnchor:_voicePill.centerYAnchor],
    ]];
}

- (void)buildCardContent {
    _cardView = [UIView new];
    _cardView.translatesAutoresizingMaskIntoConstraints = NO;
    _cardView.backgroundColor = [SPKUtils SPKColor_InstagramTertiaryBackground];
    _cardView.layer.cornerRadius = 12.0;
    _cardView.clipsToBounds = YES;
    _cardView.userInteractionEnabled = YES;

    _cardThumb = [UIImageView new];
    _cardThumb.translatesAutoresizingMaskIntoConstraints = NO;
    _cardThumb.contentMode = UIViewContentModeScaleAspectFill;
    _cardThumb.clipsToBounds = YES;
    _cardThumb.layer.cornerRadius = 8.0;
    _cardThumb.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    [_cardView addSubview:_cardThumb];

    // Placeholder glyph shown inside the thumb when a share/link has no preview image.
    _cardPlaceholder = [UIImageView new];
    _cardPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    _cardPlaceholder.contentMode = UIViewContentModeScaleAspectFit;
    _cardPlaceholder.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    [_cardThumb addSubview:_cardPlaceholder];

    _cardTitle = [UILabel new];
    _cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightSemibold] to:_cardTitle];
    _cardTitle.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _cardTitle.numberOfLines = 2;

    _cardURL = [UILabel new];
    _cardURL.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption2] to:_cardURL];
    _cardURL.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _cardURL.numberOfLines = 1;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _cardTitle, _cardURL ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2.0;
    textStack.alignment = UIStackViewAlignmentLeading;
    [_cardView addSubview:textStack];

    // One recognizer, split by location: tapping the thumbnail opens the preview
    // image; tapping the rest of the card body opens the shared post itself.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardTap:)];
    [_cardView addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [_cardView.widthAnchor constraintEqualToConstant:248.0],
        [_cardView.heightAnchor constraintEqualToConstant:72.0],

        [_cardThumb.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor
                                                 constant:8.0],
        [_cardThumb.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
        [_cardThumb.widthAnchor constraintEqualToConstant:56.0],
        [_cardThumb.heightAnchor constraintEqualToConstant:56.0],

        [_cardPlaceholder.centerXAnchor constraintEqualToAnchor:_cardThumb.centerXAnchor],
        [_cardPlaceholder.centerYAnchor constraintEqualToAnchor:_cardThumb.centerYAnchor],
        [_cardPlaceholder.widthAnchor constraintEqualToConstant:24.0],
        [_cardPlaceholder.heightAnchor constraintEqualToConstant:24.0],

        [textStack.leadingAnchor constraintEqualToAnchor:_cardThumb.trailingAnchor
                                                constant:10.0],
        [textStack.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor
                                                 constant:-12.0],
        [textStack.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
    ]];
}

- (void)layoutSubviews {
    SPK_PERF_SCOPE(@"SPKDeletedMessageBubbleCell.layoutSubviews");
    [super layoutSubviews];
    // Keep media a comfortable square; cards/text wrap naturally.
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.messageId = nil;
    self.message = nil;
    self.mediaView.image = nil;
    self.cardThumb.image = nil;
    [self applySenderName:nil senderPk:nil avatarURL:nil];
}

// Show a sender avatar + name above the bubble (group threads, incoming only).
// Pass nil to hide — outgoing messages or consecutive messages from the same sender.
- (void)applySenderName:(NSString *)name senderPk:(NSString *)senderPk avatarURL:(NSString *)avatarURL {
    if (name.length) {
        self.senderLabel.text = name;
        self.senderLabel.hidden = NO;
        self.senderAvatarView.hidden = NO;
        [self.senderAvatarView configureWithPK:senderPk urlString:avatarURL];
        self.bubbleTopDefault.active = NO;
        self.bubbleTopBelowName.active = YES;
    } else {
        self.senderLabel.text = nil;
        self.senderLabel.hidden = YES;
        self.senderAvatarView.hidden = YES;
        [self.senderAvatarView prepareForReuse];
        self.bubbleTopBelowName.active = NO;
        self.bubbleTopDefault.active = YES;
    }
}

- (void)handleMediaTap {
    if (self.message && [self.delegate respondsToSelector:@selector(bubbleCell:didTapMediaForMessage:)]) {
        [self.delegate bubbleCell:self didTapMediaForMessage:self.message];
    }
}

- (void)handleCardTap:(UITapGestureRecognizer *)recognizer {
    // Thumbnail area → open the preview image (existing media-tap behavior).
    CGPoint point = [recognizer locationInView:self.cardThumb];
    if ([self.cardThumb pointInside:point withEvent:nil]) {
        [self handleMediaTap];
        return;
    }
    // Card body → open the shared post itself inside Instagram, routed through
    // the app's universal-link/deeplink handler (same path as the gallery's
    // "Open Original Post"). Links/audio keep the whole-card behavior.
    if (self.message.kind == SPKDeletedMessageKindShare) {
        NSString *urlStr = self.message.mediaURL.length ? self.message.mediaURL : self.message.thumbnailURL;
        NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
        if (url) {
            [SPKUtils openInstagramMediaURL:url];
            return;
        }
    }
    [self handleMediaTap];
}

- (void)applyLoadedThumbnail:(UIImage *)thumbnail forMessageId:(NSString *)messageId {
    if (!thumbnail || !messageId.length)
        return;
    if (![self.messageId isEqualToString:messageId])
        return; // cell was reused
    switch (self.message.kind) {
    case SPKDeletedMessageKindPhoto:
    case SPKDeletedMessageKindVideo:
    case SPKDeletedMessageKindGif:
    case SPKDeletedMessageKindSticker:
        self.mediaView.image = thumbnail;
        self.mediaHeightConstraint.constant = kSPKBubbleMediaSize;
        self.unavailableGlyph.hidden = YES;
        self.unavailableLabel.hidden = YES;
        break;
    case SPKDeletedMessageKindShare:
    case SPKDeletedMessageKindLink:
    case SPKDeletedMessageKindAudioShare:
        self.cardThumb.image = thumbnail;
        self.cardPlaceholder.hidden = YES;
        break;
    default:
        break;
    }
}

#pragma mark - Configure

- (void)configureWithMessage:(SPKDeletedMessage *)message
                   thumbnail:(UIImage *)thumbnail
            mediaUnavailable:(BOOL)mediaUnavailable
                    outgoing:(BOOL)outgoing {
    self.message = message;
    self.messageId = message.messageId;

    [self setOutgoing:outgoing];

    // Share-kind rows label themselves by the actual content type (Reel/Post/...)
    // instead of a generic "Share".
    NSString *kindName, *kindSymbol;
    if (message.kind == SPKDeletedMessageKindShare) {
        kindName = SPKDeletedMessageShareSubtypeName(message.shareSubtype);
        kindSymbol = SPKDeletedMessageShareSubtypeSymbol(message.shareSubtype);
    } else {
        kindName = SPKDeletedMessageKindLocalizedName(message.kind);
        kindSymbol = SPKDeletedMessageKindSymbolFilled(message.kind, YES);
    }
    self.kindIcon.image = [SPKAssetUtils instagramIconNamed:kindSymbol pointSize:12.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    self.kindLabel.text = [kindName uppercaseString];
    self.timeLabel.text = [SPKDeletedMessagesDate stringForDate:(message.deletedAt ?: message.capturedAt ?
                                                                                                         : message.sentAt)];

    // Reset visibility.
    self.textLabel_.hidden = YES;
    self.mediaContainer.hidden = YES;
    self.voicePill.hidden = YES;
    self.cardView.hidden = YES;
    self.playGlyph.hidden = YES;
    self.unavailableGlyph.hidden = YES;
    self.unavailableLabel.hidden = YES;
    self.durationPill.hidden = YES;
    self.mediaHeightConstraint.constant = kSPKBubbleMediaSize;

    switch (message.kind) {
    case SPKDeletedMessageKindText:
    case SPKDeletedMessageKindReaction:
    case SPKDeletedMessageKindUnknown:
    case SPKDeletedMessageKindOther:
        [self configureTextWithMessage:message];
        break;
    case SPKDeletedMessageKindPhoto:
    case SPKDeletedMessageKindVideo:
    case SPKDeletedMessageKindGif:
    case SPKDeletedMessageKindSticker:
        [self configureMediaWithMessage:message thumbnail:thumbnail unavailable:mediaUnavailable];
        break;
    case SPKDeletedMessageKindVoice:
        [self configureVoiceWithMessage:message];
        break;
    case SPKDeletedMessageKindShare:
    case SPKDeletedMessageKindLink:
    case SPKDeletedMessageKindAudioShare:
        [self configureCardWithMessage:message thumbnail:thumbnail];
        break;
    }
}

- (void)configureTextWithMessage:(SPKDeletedMessage *)message {
    NSString *body = SPKDeletedMessageDisplayBody(message);
    if (!body.length)
        body = SPKDeletedMessageKindLocalizedName(message.kind);
    self.textLabel_.text = body;
    self.textLabel_.hidden = NO;
}

- (void)configureMediaWithMessage:(SPKDeletedMessage *)message thumbnail:(UIImage *)thumbnail unavailable:(BOOL)unavailable {
    self.mediaContainer.hidden = NO;
    if (unavailable) {
        self.mediaView.image = nil;
        self.mediaHeightConstraint.constant = 48.0;
        self.unavailableGlyph.image = [SPKAssetUtils instagramIconNamed:@"warning_filled"
                                                              pointSize:16.0
                                                          renderingMode:UIImageRenderingModeAlwaysTemplate];
        self.unavailableGlyph.hidden = NO;
        self.unavailableLabel.hidden = NO;
        self.playGlyph.hidden = YES;
        self.durationPill.hidden = YES;
    } else {
        if (thumbnail) {
            self.mediaView.image = thumbnail;
        } else {
            self.mediaView.image = nil;
        }
        self.playGlyph.hidden = (message.kind != SPKDeletedMessageKindVideo);

        if (message.kind == SPKDeletedMessageKindVideo && message.durationSeconds > 0) {
            self.durationLabel.text = SPKDeletedFormatDuration(message.durationSeconds);
            self.durationPill.hidden = NO;
        }
    }

    // A caption can ride along with media. Use the display helper so generated
    // reaction bodies are rebuilt in the reader's current language as well.
    NSString *body = SPKDeletedMessageDisplayBody(message);
    if (body.length) {
        self.textLabel_.text = body;
        self.textLabel_.hidden = NO;
    }
}

- (void)configureVoiceWithMessage:(SPKDeletedMessage *)message {
    self.voicePill.hidden = NO;
    self.voiceLabel.text = message.durationSeconds > 0
                               ? SPKDeletedFormatDuration(message.durationSeconds)
                               : SPKL(@"MESSAGES_DELETED_MESSAGE_BUBBLE_CELL_TAP_PLAY_TEXT");
}

- (void)configureCardWithMessage:(SPKDeletedMessage *)message thumbnail:(UIImage *)thumbnail {
    self.cardView.hidden = NO;
    self.cardThumb.image = thumbnail;
    BOOL isShare = (message.kind == SPKDeletedMessageKindShare);

    // Show a glyph in the thumb when there's no preview image.
    if (thumbnail) {
        self.cardPlaceholder.hidden = YES;
    } else {
        self.cardPlaceholder.hidden = NO;
        NSString *symbol = isShare ? SPKDeletedMessageShareSubtypeSymbol(message.shareSubtype)
                                   : SPKDeletedMessageKindSymbol(message.kind);
        self.cardPlaceholder.image = [SPKAssetUtils instagramIconNamed:symbol
                                                             pointSize:22.0
                                                         renderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    // First line of the caption (if any).
    NSString *caption = SPKDeletedMessageDisplayBody(message);
    NSRange newline = caption.length ? [caption rangeOfString:@"\n"] : NSMakeRange(NSNotFound, 0);
    if (newline.location != NSNotFound)
        caption = [caption substringToIndex:newline.location];

    if (isShare) {
        // Title = the shared content's author; subtitle = "Reel • caption".
        NSString *typeName = SPKDeletedMessageShareSubtypeName(message.shareSubtype);
        NSString *author = message.shareAuthor.length ? message.shareAuthor : nil;
        self.cardTitle.text = author ?: (caption.length ? caption : typeName);

        // Subtitle carries the type (and caption when the title is the author).
        // When the title already is the type, drop the subtitle so it's not shown
        // twice.
        NSString *subtitle = nil;
        if (author) {
            subtitle = (caption.length && ![caption isEqualToString:author])
                           ? [NSString stringWithFormat:@"%@ • %@", typeName, caption]
                           : typeName;
        } else if (caption.length) {
            subtitle = typeName;
        }
        self.cardURL.text = subtitle ?: @"";
        self.cardURL.hidden = (subtitle.length == 0);
    } else {
        // Link / audio share — caption title + the URL host underneath.
        self.cardTitle.text = caption.length ? caption : SPKDeletedMessageKindLocalizedName(message.kind);
        NSString *urlStr = message.mediaURL.length ? message.mediaURL : message.thumbnailURL;
        NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
        self.cardURL.text = url.host ?: urlStr;
        self.cardURL.hidden = (self.cardURL.text.length == 0);
    }
}

#pragma mark - Helpers

static NSString *SPKDeletedFormatDuration(double seconds) {
    if (seconds <= 0)
        return @"0:00";
    int total = (int)round(seconds);
    int mins = total / 60;
    int secs = total % 60;
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

@end
