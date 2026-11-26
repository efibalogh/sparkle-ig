#import "SPKStrings.h"
#import "SPKDeletedMessagesSenderCell.h"
#import "../../../AssetUtils.h"
#import "../../../Utils.h"
#import "SPKDeletedMessagesAvatarView.h"
#import "SPKDeletedMessagesDate.h"
#import "../../../Shared/UI/SPKFont.h"

NSString *const SPKDeletedMessagesSenderCellReuseID = @"SPKDeletedMessagesSenderCell";

static CGFloat const kSPKAvatarSize = 52.0;

static NSString *SPKDeletedMessagesSenderPreview(SPKDeletedMessageGroup *group);

@interface SPKDeletedMessagesSenderCell ()
@property (nonatomic, strong) SPKDeletedMessagesAvatarView *avatarView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *pinBadge;
@property (nonatomic, strong) UIImageView *previewIcon;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIStackView *previewRow;
@end

@implementation SPKDeletedMessagesSenderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];

        _avatarView = [[SPKDeletedMessagesAvatarView alloc] initWithFrame:CGRectZero];
        _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_avatarView];

        _nameLabel = [UILabel new];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightSemibold] to:_nameLabel];
        _nameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        _pinBadge = [UIImageView new];
        _pinBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _pinBadge.contentMode = UIViewContentModeScaleAspectFit;
        _pinBadge.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        _pinBadge.image = [SPKAssetUtils instagramIconNamed:@"pin_filled" pointSize:12.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
        _pinBadge.hidden = YES;
        [_pinBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _nameLabel, _pinBadge ]];
        nameRow.translatesAutoresizingMaskIntoConstraints = NO;
        nameRow.axis = UILayoutConstraintAxisHorizontal;
        nameRow.alignment = UIStackViewAlignmentCenter;
        nameRow.spacing = 5.0;
        [self.contentView addSubview:nameRow];

        _previewIcon = [UIImageView new];
        _previewIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _previewIcon.contentMode = UIViewContentModeScaleAspectFit;
        _previewIcon.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [_previewIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_previewIcon.widthAnchor constraintEqualToConstant:14.0],
            [_previewIcon.heightAnchor constraintEqualToConstant:14.0],
        ]];

        _previewLabel = [UILabel new];
        _previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleFootnote] to:_previewLabel];
        _previewLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];

        _previewRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _previewIcon, _previewLabel ]];
        _previewRow.translatesAutoresizingMaskIntoConstraints = NO;
        _previewRow.axis = UILayoutConstraintAxisHorizontal;
        _previewRow.alignment = UIStackViewAlignmentCenter;
        _previewRow.spacing = 5.0;
        [self.contentView addSubview:_previewRow];

        _timeLabel = [UILabel new];
        _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleCaption1] to:_timeLabel];
        _timeLabel.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
        _timeLabel.textAlignment = NSTextAlignmentRight;
        [_timeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_timeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentView addSubview:_timeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                      constant:16.0],
            [_avatarView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_avatarView.widthAnchor constraintEqualToConstant:kSPKAvatarSize],
            [_avatarView.heightAnchor constraintEqualToConstant:kSPKAvatarSize],

            [nameRow.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor
                                                  constant:12.0],
            [nameRow.topAnchor constraintEqualToAnchor:_avatarView.topAnchor
                                              constant:4.0],
            [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:_timeLabel.leadingAnchor
                                                             constant:-8.0],

            [_previewRow.leadingAnchor constraintEqualToAnchor:nameRow.leadingAnchor],
            [_previewRow.topAnchor constraintEqualToAnchor:nameRow.bottomAnchor
                                                  constant:3.0],
            [_previewRow.trailingAnchor constraintLessThanOrEqualToAnchor:_timeLabel.leadingAnchor
                                                                 constant:-8.0],

            [_timeLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                      constant:-16.0],
            [_timeLabel.topAnchor constraintEqualToAnchor:nameRow.topAnchor],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.avatarView prepareForReuse];
}

- (void)configureWithGroup:(SPKDeletedMessageGroup *)group {
    self.nameLabel.text = group.displayName;
    self.pinBadge.hidden = !group.isPinned;

    SPKDeletedMessage *latest = group.latest;
    NSString *previewSymbol = latest.kind == SPKDeletedMessageKindShare
                                  ? SPKDeletedMessageShareSubtypeSymbol(latest.shareSubtype)
                                  : SPKDeletedMessageKindSymbolFilled(latest.kind, YES);
    self.previewIcon.image = [SPKAssetUtils instagramIconNamed:previewSymbol
                                                     pointSize:14.0
                                                 renderingMode:UIImageRenderingModeAlwaysTemplate];
    self.previewLabel.text = SPKDeletedMessagesSenderPreview(group);
    self.timeLabel.text = [SPKDeletedMessagesDate stringForDate:group.lastDeletedAt];

    self.avatarView.alpha = group.isBlocked ? 0.4 : 1.0;
    self.nameLabel.alpha = group.isBlocked ? 0.5 : 1.0;
    self.previewRow.alpha = group.isBlocked ? 0.5 : 1.0;

    if (group.isGroup) {
        [self.avatarView configureAsGroupWithThreadId:group.threadId photoURL:group.threadPhotoURL];
    } else {
        [self.avatarView configureWithPK:group.senderPk urlString:group.senderProfilePicURL];
    }
}

// Latest message preview: text body when present, otherwise a kind label plus
// a count suffix when the sender has more than one unsent message.
static NSString *SPKDeletedMessagesSenderPreview(SPKDeletedMessageGroup *group) {
    SPKDeletedMessage *latest = group.latest;
    NSString *body = nil;
    if (latest.kind == SPKDeletedMessageKindShare) {
        // "Reel • @author" / "Post • caption" so shares read by type at a glance.
        NSString *type = SPKDeletedMessageShareSubtypeName(latest.shareSubtype);
        NSString *detail = latest.shareAuthor.length ? latest.shareAuthor : SPKDeletedMessageDisplayBody(latest);
        body = detail.length ? [NSString stringWithFormat:@"%@ • %@", type, detail] : type;
    } else {
        body = SPKDeletedMessageDisplayBody(latest);
    }
    if (!body.length)
        body = SPKDeletedMessageKindLocalizedName(latest.kind);

    body = [body stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

    // In a group, lead with who sent the latest unsent message.
    if (group.isGroup) {
        NSString *who = latest.senderUsername.length ? latest.senderUsername
                                                     : (latest.senderFullName.length ? latest.senderFullName : nil);
        if (who.length)
            body = [NSString stringWithFormat:@"%@: %@", who, body];
    }

    if (group.count > 1) {
        return [NSString stringWithFormat:SPKL(@"MESSAGES_DELETED_MESSAGES_SENDER_CELL_VALUE_VALUE_UNSENT_FORMAT"), body, (unsigned long)group.count];
    }
    return body;
}

@end
