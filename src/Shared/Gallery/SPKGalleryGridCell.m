#import "SPKGalleryGridCell.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "SPKGalleryFile.h"

@interface SPKGalleryGridCell ()

@property (nonatomic, strong) SPKGalleryFile *file;
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) CAGradientLayer *bottomScrim;
@property (nonatomic, strong) CAGradientLayer *topScrim;
@property (nonatomic, strong) UIImageView *sourceBadge;
@property (nonatomic, strong) UIImageView *videoBadge;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UIStackView *bottomLeftStack;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIStackView *folderStack;
@property (nonatomic, strong) UIImageView *folderIcon;
@property (nonatomic, strong) UILabel *folderLabel;
@property (nonatomic, strong) UIImageView *favoriteBadge;
@property (nonatomic, strong) UIImageView *selectionBadge;
@property (nonatomic, strong) NSLayoutConstraint *favoriteTrailingConstraint;
/// Bumped on every reconfigure so an async thumbnail that finishes after the cell
/// has been recycled is dropped instead of painted onto the wrong item.
@property (nonatomic, assign) NSUInteger thumbnailToken;

@end

@implementation SPKGalleryGridCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 6.0;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];

        _thumbnailView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        [self.contentView addSubview:_thumbnailView];

        // Bottom gradient scrim so the video glyph / duration stay legible over
        // bright thumbnails. Sits above the thumbnail, below the badges.
        _bottomScrim = [CAGradientLayer layer];
        _bottomScrim.colors = @[ (id)[UIColor clearColor].CGColor,
                                 (id)[[UIColor blackColor] colorWithAlphaComponent:0.95].CGColor ];
        _bottomScrim.startPoint = CGPointMake(0.5, 0.0);
        _bottomScrim.endPoint = CGPointMake(0.5, 1.0);
        _bottomScrim.hidden = YES;
        [self.contentView.layer addSublayer:_bottomScrim];

        // Top gradient scrim keeps the source badge / favorite legible.
        _topScrim = [CAGradientLayer layer];
        _topScrim.colors = @[ (id)[[UIColor blackColor] colorWithAlphaComponent:0.95].CGColor,
                              (id)[UIColor clearColor].CGColor ];
        _topScrim.startPoint = CGPointMake(0.5, 0.0);
        _topScrim.endPoint = CGPointMake(0.5, 1.0);
        _topScrim.hidden = YES;
        [self.contentView.layer addSublayer:_topScrim];

        _sourceBadge = [[UIImageView alloc] initWithFrame:CGRectZero];
        _sourceBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _sourceBadge.tintColor = [UIColor whiteColor];
        _sourceBadge.contentMode = UIViewContentModeScaleAspectFit;
        _sourceBadge.hidden = YES;
        [self.contentView addSubview:_sourceBadge];

        _videoBadge = [[UIImageView alloc] initWithFrame:CGRectZero];
        _videoBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _videoBadge.image = [SPKAssetUtils instagramIconNamed:@"video_filled" pointSize:13.0];
        _videoBadge.tintColor = [UIColor whiteColor];
        _videoBadge.contentMode = UIViewContentModeScaleAspectFit;
        _videoBadge.hidden = YES;
        [self.contentView addSubview:_videoBadge];

        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _durationLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        _durationLabel.textColor = [UIColor whiteColor];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        _durationLabel.hidden = YES;
        [self.contentView addSubview:_durationLabel];

        // Bottom-left vertical stack for username & folder context.
        _bottomLeftStack = [[UIStackView alloc] init];
        _bottomLeftStack.translatesAutoresizingMaskIntoConstraints = NO;
        _bottomLeftStack.axis = UILayoutConstraintAxisVertical;
        _bottomLeftStack.alignment = UIStackViewAlignmentLeading;
        _bottomLeftStack.spacing = 2.0;
        [self.contentView addSubview:_bottomLeftStack];

        _usernameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _usernameLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        _usernameLabel.textColor = [UIColor whiteColor];
        _usernameLabel.textAlignment = NSTextAlignmentLeft;
        _usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _usernameLabel.hidden = YES;
        [_usernameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [_bottomLeftStack addArrangedSubview:_usernameLabel];

        _folderStack = [[UIStackView alloc] init];
        _folderStack.axis = UILayoutConstraintAxisHorizontal;
        _folderStack.alignment = UIStackViewAlignmentCenter;
        _folderStack.spacing = 4.0;
        _folderStack.hidden = YES;

        _folderIcon = [[UIImageView alloc] init];
        _folderIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _folderIcon.image = [SPKAssetUtils instagramIconNamed:@"folder" pointSize:11.0];
        _folderIcon.tintColor = [UIColor whiteColor];
        _folderIcon.contentMode = UIViewContentModeScaleAspectFit;
        [_folderStack addArrangedSubview:_folderIcon];

        _folderLabel = [[UILabel alloc] init];
        _folderLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
        _folderLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        _folderLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_folderStack addArrangedSubview:_folderLabel];

        [_bottomLeftStack addArrangedSubview:_folderStack];

        _favoriteBadge = [[UIImageView alloc] initWithFrame:CGRectZero];
        _favoriteBadge.translatesAutoresizingMaskIntoConstraints = NO;
        UIImage *favImg = [SPKAssetUtils instagramIconNamed:@"heart_filled" pointSize:16.0];
        _favoriteBadge.image = favImg;
        _favoriteBadge.contentMode = UIViewContentModeScaleAspectFit;
        _favoriteBadge.tintColor = [SPKUtils SPKColor_InstagramFavorite];
        _favoriteBadge.hidden = YES;
        [self.contentView addSubview:_favoriteBadge];

        _selectionBadge = [[UIImageView alloc] initWithFrame:CGRectZero];
        _selectionBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _selectionBadge.contentMode = UIViewContentModeScaleAspectFit;
        _selectionBadge.tintColor = [UIColor whiteColor];
        _selectionBadge.hidden = YES;
        [self.contentView addSubview:_selectionBadge];

        _favoriteTrailingConstraint = [_favoriteBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbnailView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_thumbnailView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [_thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_thumbnailView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

            // Source badge (top-left).
            [_sourceBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                       constant:6],
            [_sourceBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                   constant:6],
            [_sourceBadge.widthAnchor constraintEqualToConstant:14],
            [_sourceBadge.heightAnchor constraintEqualToConstant:14],

            // Video glyph + duration (bottom-right).
            [_durationLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                          constant:-6],
            [_durationLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                        constant:-6],

            [_videoBadge.trailingAnchor constraintEqualToAnchor:_durationLabel.leadingAnchor
                                                       constant:-4],
            [_videoBadge.centerYAnchor constraintEqualToAnchor:_durationLabel.centerYAnchor],
            [_videoBadge.widthAnchor constraintEqualToConstant:14],
            [_videoBadge.heightAnchor constraintEqualToConstant:14],

            // Bottom-left stack constraints.
            [_bottomLeftStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                           constant:6],
            [_bottomLeftStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                          constant:-6],
            [_bottomLeftStack.trailingAnchor constraintLessThanOrEqualToAnchor:_videoBadge.leadingAnchor
                                                                      constant:-6],
            [_bottomLeftStack.trailingAnchor constraintLessThanOrEqualToAnchor:_durationLabel.leadingAnchor
                                                                      constant:-6],

            [_folderIcon.widthAnchor constraintEqualToConstant:11],
            [_folderIcon.heightAnchor constraintEqualToConstant:11],

            [_favoriteBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                     constant:6],
            [_favoriteBadge.widthAnchor constraintEqualToConstant:16],
            [_favoriteBadge.heightAnchor constraintEqualToConstant:16],

            [_selectionBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                      constant:6],
            [_selectionBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                           constant:-6],
            [_selectionBadge.widthAnchor constraintEqualToConstant:20],
            [_selectionBadge.heightAnchor constraintEqualToConstant:20],

            _favoriteTrailingConstraint,
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Bottom scrim spans the lower third of the cell.
    CGFloat bottomHeight = MAX(28.0, height * 0.34);
    self.bottomScrim.frame = CGRectMake(0.0, height - bottomHeight, width, bottomHeight);
    // Top scrim is identical to bottom scrim.
    CGFloat topHeight = bottomHeight;
    self.topScrim.frame = CGRectMake(0.0, 0.0, width, topHeight);
    [CATransaction commit];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Deliberately minimal. Every other property this cell displays is
    // unconditionally reassigned by configureWithGalleryFile:... immediately
    // after dequeue, so clearing it here is redundant work on every reuse.
    //
    // The invariant this relies on: a dequeued cell is always configured before
    // it is shown. If a caller ever dequeues one without configuring it, it will
    // display the previous item's content.
    self.thumbnailToken++;
    self.file = nil;
    self.thumbnailView.image = nil;
}


static NSString *SPKGalleryGridFormatDuration(double seconds) {
    if (seconds <= 0.0 || !isfinite(seconds))
        return nil;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

- (UIImage *)selectionBadgeImageSelected:(BOOL)selected {
    NSString *resourceName = selected ? @"circle_check_filled" : @"circle";
    return [SPKAssetUtils instagramIconNamed:resourceName pointSize:20.0];
}

- (void)configureWithGalleryFile:(SPKGalleryFile *)file
                   selectionMode:(BOOL)selectionMode
                        selected:(BOOL)selected {
    [self configureWithGalleryFile:file
                     selectionMode:selectionMode
                          selected:selected
                       showsSource:NO
                     showsUsername:NO
                        folderName:nil];
}

- (void)configureWithGalleryFile:(SPKGalleryFile *)file
                   selectionMode:(BOOL)selectionMode
                        selected:(BOOL)selected
                     showsSource:(BOOL)showsSource
                   showsUsername:(BOOL)showsUsername {
    [self configureWithGalleryFile:file
                     selectionMode:selectionMode
                          selected:selected
                       showsSource:showsSource
                     showsUsername:showsUsername
                        folderName:nil];
}

- (void)configureWithGalleryFile:(SPKGalleryFile *)file
                   selectionMode:(BOOL)selectionMode
                        selected:(BOOL)selected
                     showsSource:(BOOL)showsSource
                   showsUsername:(BOOL)showsUsername
                      folderName:(nullable NSString *)folderName {
    self.file = file;
    // Only an in-memory hit is resolved inline. Anything that needs the disk (or
    // a render) goes to the background, so a fast scroll never blocks the main
    // thread on a file read plus a JPEG decode per cell.
    NSUInteger token = ++self.thumbnailToken;
    UIImage *thumb = [SPKGalleryFile cachedThumbnailForFile:file];
    if (thumb) {
        self.thumbnailView.image = thumb;
    } else {
        self.thumbnailView.image = nil;
        __weak typeof(self) weakSelf = self;
        [SPKGalleryFile loadThumbnailAsyncForFile:file
                                       completion:^(UIImage *loaded) {
                                           if (loaded && weakSelf.thumbnailToken == token) {
                                               weakSelf.thumbnailView.image = loaded;
                                           }
                                       }];
    }

    BOOL isVideo = (file.mediaType == SPKGalleryMediaTypeVideo);
    BOOL isAudio = (file.mediaType == SPKGalleryMediaTypeAudio);
    BOOL hasTypeBadge = isVideo || isAudio;
    if (hasTypeBadge) {
        self.videoBadge.image = [SPKAssetUtils instagramIconNamed:(isAudio ? @"audio_filled" : @"video_filled") pointSize:13.0];
    }
    self.videoBadge.hidden = !hasTypeBadge;

    NSString *durationText = hasTypeBadge ? SPKGalleryGridFormatDuration(file.durationSeconds) : nil;
    self.durationLabel.text = durationText;
    self.durationLabel.hidden = (durationText == nil);

    // Source-type badge (top-left).
    if (showsSource) {
        NSString *symbol = [file sourceSymbolName];
        NSString *filledSymbol = [symbol stringByAppendingString:@"_filled"];
        UIImage *icon = nil;
        if ([SPKAssetUtils resolvedInstagramIconNameForName:filledSymbol]) {
            icon = [SPKAssetUtils instagramIconNamed:filledSymbol pointSize:13.0];
        } else {
            icon = [SPKAssetUtils instagramIconNamed:symbol pointSize:13.0];
        }
        self.sourceBadge.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.sourceBadge.hidden = (icon == nil);
    } else {
        self.sourceBadge.image = nil;
        self.sourceBadge.hidden = YES;
    }

    // Username caption (bottom-left), truncated to fit.
    NSString *username = file.sourceUsername.length > 0 ? file.sourceUsername : nil;
    if (showsUsername && username) {
        self.usernameLabel.text = [NSString stringWithFormat:@"@%@", username];
        self.usernameLabel.hidden = NO;
    } else {
        self.usernameLabel.text = nil;
        self.usernameLabel.hidden = YES;
    }

    // Folder caption (bottom-left), below username.
    if (folderName.length > 0) {
        self.folderLabel.text = folderName;
        self.folderStack.hidden = NO;
    } else {
        self.folderLabel.text = nil;
        self.folderStack.hidden = YES;
    }

    // Scrims only when there is overlay content to keep legible. Toggle their
    // hidden state with implicit layer animations disabled, otherwise the scrim
    // fades in/out when the cell is reconfigured and reads as a flash.
    BOOL hasBottomOverlay = hasTypeBadge || (showsUsername && username != nil) || (folderName.length > 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.bottomScrim.hidden = !hasBottomOverlay;
    self.topScrim.hidden = !(showsSource && !self.sourceBadge.hidden);
    [CATransaction commit];

    self.favoriteBadge.hidden = !file.isFavorite;

    [self setSelectionMode:selectionMode selected:selected animated:NO];
}

- (void)setSelectionMode:(BOOL)selectionMode selected:(BOOL)selected animated:(BOOL)animated {
    self.selectionBadge.image = selectionMode ? [self selectionBadgeImageSelected:selected] : nil;
    if (selectionMode) {
        self.selectionBadge.hidden = NO;
    }
    self.favoriteTrailingConstraint.constant = selectionMode ? -30.0 : -6.0;

    void (^applyState)(void) = ^{
        self.selectionBadge.alpha = selectionMode ? 1.0 : 0.0;
        [self.contentView layoutIfNeeded];
    };
    void (^finishState)(void) = ^{
        self.selectionBadge.hidden = !selectionMode;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:applyState
                         completion:^(__unused BOOL finished) {
                             finishState();
                         }];
    } else {
        applyState();
        finishState();
    }
}

@end
