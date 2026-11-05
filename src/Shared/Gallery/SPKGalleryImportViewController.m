#import "SPKGalleryImportViewController.h"
#import "SPKStrings.h"
#import <stdatomic.h>

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKGlassButton.h"
#import "../UI/SPKNotificationPillView.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryImportMetadataFormViewController.h"
#import "SPKGallerySaveMetadata.h"
#import "SPKRegramImporter.h"
#import <CoreServices/CoreServices.h>

typedef NS_ENUM(NSInteger, SPKGalleryImportMainSection) {
    SPKGalleryImportMainSectionShared = 0,
    SPKGalleryImportMainSectionQueue,
};

static CGFloat const SPKImportThumbnailSize = 52.0;
static CGFloat const SPKImportRowHeight = 72.0;  // matches SPKGalleryListCollectionCell media rows (folders are 88)
static CGFloat const SPKImportPillHeight = 48.0;  // empty-state CTA + footer import button
// Footer CTA: aligned to the grouped table's cell inset, with breathing room above it and the same
// again below so it doesn't sit flush against the end of the scroll.
static CGFloat const SPKImportFooterVPad = 16.0;
static CGFloat const SPKImportFooterHMargin = 16.0;
// Floating "jump to the import button" affordance: the CTA scrolls away with the list, so a long
// queue would otherwise bury it.
static CGFloat const SPKImportJumpButtonSize = 52.0;
static CGFloat const SPKImportJumpButtonMargin = 16.0;

// No semantic warning color ships in SPKUtils, so define the amber used by the
// "Needs details" nudge here (matches the gallery's warm accent in both themes).
static UIColor *SPKImportAmberColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithRed:0.88 green:0.64 blue:0.23 alpha:1.0]
                    : [UIColor colorWithRed:0.72 green:0.47 blue:0.11 alpha:1.0];
    }];
}

#pragma mark - Queued file model

@interface SPKGalleryImportQueuedFile : NSObject
@property (nonatomic, copy) NSString *fileLabel;
@property (nonatomic, strong, nullable) NSURL *tempFileURL;
@property (nonatomic, strong) SPKGallerySaveMetadata *metadata;
@property (nonatomic) SPKGalleryMediaType mediaType;
@property (nonatomic) long long fileSize;
@property (nonatomic, strong, nullable) UIImage *thumbnail;
@property (nonatomic) BOOL thumbnailRequested;
/// Frame grabs that have already been run for this file, so a failed one can be retried without
/// re-running the generator on every scroll.
@property (nonatomic) NSInteger thumbnailAttempts;
/// Set once the user edits this file's own metadata, pinning it against shared-defaults changes.
@property (nonatomic) BOOL userEdited;
/// Carried over from a Regram vault import; applied to the saved gallery file.
@property (nonatomic) BOOL isFavorite;
@end

@implementation SPKGalleryImportQueuedFile
@end

#pragma mark - Shared defaults cell

// One full-width row standing in for the old "Edit shared metadata" + "Merge into all"
// pair: an accent badge, a summary of what will be stamped on new/unedited files, and a
// chevron into the shared editor. Applied live — there is no manual merge step.
@interface SPKGalleryImportSharedCell : UITableViewCell
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UIImageView *badgeIcon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *highlightOverlay;
@end

@implementation SPKGalleryImportSharedCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.separatorInset = UIEdgeInsetsMake(0.0, 16.0 + SPKImportThumbnailSize + 12.0, 0.0, 0.0);

        // Same pressed feel as the gallery list rows: a translucent overlay toggled on touch, not the
        // system gray selection. Added to the cell *below* contentView (not inside it) and pinned to
        // the cell's full width so the press tint spans the disclosure chevron too, not just up to it.
        _highlightOverlay = [[UIView alloc] init];
        _highlightOverlay.translatesAutoresizingMaskIntoConstraints = NO;
        _highlightOverlay.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];
        _highlightOverlay.hidden = YES;
        _highlightOverlay.userInteractionEnabled = NO;
        [self insertSubview:_highlightOverlay atIndex:0];

        // A 52pt elevated tile with a centred glyph — same footprint and treatment as the queue
        // thumbnails and the Downloads placeholder, so the shared row lines up with the media rows.
        _badge = [[UIView alloc] init];
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        _badge.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        _badge.layer.cornerRadius = 6.0;
        [self.contentView addSubview:_badge];

        _badgeIcon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"info"
                                                                                pointSize:24.0
                                                                            renderingMode:UIImageRenderingModeAlwaysTemplate]];
        _badgeIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeIcon.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        _badgeIcon.contentMode = UIViewContentModeCenter;
        [_badge addSubview:_badgeIcon];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        _titleLabel.text = SPKL(@"GALLERY_IMPORT_SHARED_DETAILS_TITLE");
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        _subtitleLabel.numberOfLines = 1;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_highlightOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_highlightOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_highlightOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_highlightOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_badge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [_badge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_badge.widthAnchor constraintEqualToConstant:SPKImportThumbnailSize],
            [_badge.heightAnchor constraintEqualToConstant:SPKImportThumbnailSize],

            [_badgeIcon.centerXAnchor constraintEqualToAnchor:_badge.centerXAnchor],
            [_badgeIcon.centerYAnchor constraintEqualToAnchor:_badge.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_badge.trailingAnchor constant:12.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:_badge.centerYAnchor constant:-1.0],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_badge.centerYAnchor constant:2.0],
        ]];
    }
    return self;
}

- (void)setSubtitle:(NSString *)subtitle {
    self.subtitleLabel.text = subtitle;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.highlightOverlay.hidden = !highlighted;
}

@end

#pragma mark - Queue cell

@interface SPKGalleryImportQueueCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UIImageView *placeholderGlyph;
@property (nonatomic, strong) UIImageView *rowTypeIcon;
@property (nonatomic, strong) UIView *highlightOverlay;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *technicalLabel;
@property (nonatomic, strong) UIView *sourcePill;
@property (nonatomic, strong) UILabel *sourcePillLabel;
@property (nonatomic, strong) UIView *needsPill;
@property (nonatomic, strong) UILabel *needsPillLabel;
@property (nonatomic, copy, nullable) void (^onThumbnailTap)(void);
@end

@implementation SPKGalleryImportQueueCell

// Mirrors SPKGalleryListCollectionCell (the gallery list-view row): flat Instagram background, a 52pt
// thumbnail, then title / type-icon + facts / source pill stacked over three lines.
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.separatorInset = UIEdgeInsetsMake(0.0, 16.0 + SPKImportThumbnailSize + 12.0, 0.0, 0.0);

        // Below contentView, pinned to the full cell width so the press tint covers the disclosure
        // chevron too (see the shared cell for the rationale).
        _highlightOverlay = [[UIView alloc] init];
        _highlightOverlay.translatesAutoresizingMaskIntoConstraints = NO;
        _highlightOverlay.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];
        _highlightOverlay.hidden = YES;
        _highlightOverlay.userInteractionEnabled = NO;
        [self insertSubview:_highlightOverlay atIndex:0];

        _thumbnailView = [[UIImageView alloc] init];
        _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        _thumbnailView.layer.cornerRadius = 6.0;
        _thumbnailView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
        _thumbnailView.userInteractionEnabled = YES;
        [self.contentView addSubview:_thumbnailView];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailTapped)];
        [_thumbnailView addGestureRecognizer:tap];

        // A centred glyph on the elevated thumbnail tile, matching the Downloads placeholder style —
        // used for audio and for media whose frame hasn't rendered yet.
        _placeholderGlyph = [[UIImageView alloc] init];
        _placeholderGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        _placeholderGlyph.contentMode = UIViewContentModeCenter;
        _placeholderGlyph.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [_thumbnailView addSubview:_placeholderGlyph];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];

        _rowTypeIcon = [[UIImageView alloc] init];
        _rowTypeIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _rowTypeIcon.contentMode = UIViewContentModeScaleAspectFit;
        _rowTypeIcon.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [self.contentView addSubview:_rowTypeIcon];

        _technicalLabel = [[UILabel alloc] init];
        _technicalLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _technicalLabel.font = [UIFont systemFontOfSize:12.0];
        _technicalLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        _technicalLabel.numberOfLines = 1;
        _technicalLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_technicalLabel];

        // Source pill matches the gallery row's pill: tertiary fill, secondary text.
        _sourcePill = [self makePillWithBackground:[SPKUtils SPKColor_InstagramTertiaryBackground]];
        _sourcePillLabel = (UILabel *)_sourcePill.subviews.firstObject;
        _sourcePillLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        [self.contentView addSubview:_sourcePill];

        UIColor *amber = SPKImportAmberColor();
        _needsPill = [self makePillWithBackground:[amber colorWithAlphaComponent:0.16]];
        _needsPillLabel = (UILabel *)_needsPill.subviews.firstObject;
        _needsPillLabel.textColor = amber;
        _needsPillLabel.text = SPKL(@"GALLERY_IMPORT_NEEDS_DETAILS_BADGE");
        [self.contentView addSubview:_needsPill];

        [NSLayoutConstraint activateConstraints:@[
            [_highlightOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_highlightOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_highlightOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_highlightOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [_thumbnailView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_thumbnailView.widthAnchor constraintEqualToConstant:SPKImportThumbnailSize],
            [_thumbnailView.heightAnchor constraintEqualToConstant:SPKImportThumbnailSize],

            [_placeholderGlyph.centerXAnchor constraintEqualToAnchor:_thumbnailView.centerXAnchor],
            [_placeholderGlyph.centerYAnchor constraintEqualToAnchor:_thumbnailView.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_thumbnailView.trailingAnchor constant:12.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_thumbnailView.topAnchor constant:-1.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],

            [_rowTypeIcon.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_rowTypeIcon.centerYAnchor constraintEqualToAnchor:_technicalLabel.centerYAnchor],
            [_rowTypeIcon.widthAnchor constraintEqualToConstant:14.0],
            [_rowTypeIcon.heightAnchor constraintEqualToConstant:14.0],

            [_technicalLabel.leadingAnchor constraintEqualToAnchor:_rowTypeIcon.trailingAnchor constant:4.0],
            [_technicalLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3.0],
            [_technicalLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],

            [_sourcePill.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_sourcePill.topAnchor constraintEqualToAnchor:_technicalLabel.bottomAnchor constant:4.0],

            [_needsPill.leadingAnchor constraintEqualToAnchor:_sourcePill.trailingAnchor constant:6.0],
            [_needsPill.centerYAnchor constraintEqualToAnchor:_sourcePill.centerYAnchor],
            [_needsPill.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        ]];
    }
    return self;
}

- (UIView *)makePillWithBackground:(UIColor *)bg {
    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = bg;
    pill.layer.cornerRadius = 5.0;
    pill.clipsToBounds = YES;
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    label.numberOfLines = 1;
    [pill addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8.0],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8.0],
        [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:3.0],
        [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-3.0],
    ]];
    return pill;
}

- (void)thumbnailTapped {
    if (self.onThumbnailTap) {
        self.onThumbnailTap();
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.highlightOverlay.hidden = !highlighted;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onThumbnailTap = nil;
    self.thumbnailView.image = nil;
    self.placeholderGlyph.image = nil;
}

- (void)configureWithItem:(SPKGalleryImportQueuedFile *)item
              technicalText:(NSString *)technicalText
                sourceLabel:(nullable NSString *)sourceLabel
               needsDetails:(BOOL)needsDetails {
    SPKGallerySaveMetadata *m = item.metadata;
    NSString *identity = m.customName.length ? m.customName
                                             : (m.sourceUsername.length ? m.sourceUsername : nil);
    if (!identity.length) {
        switch (item.mediaType) {
        case SPKGalleryMediaTypeVideo:
            identity = SPKL(@"COMMON_MEDIA_TYPE_VIDEO");
            break;
        case SPKGalleryMediaTypeAudio:
            identity = SPKL(@"COMMON_MEDIA_TYPE_AUDIO");
            break;
        default:
            identity = SPKL(@"COMMON_MEDIA_TYPE_PHOTO");
            break;
        }
    }
    self.titleLabel.text = identity;
    self.technicalLabel.text = technicalText;

    BOOL isVideo = (item.mediaType == SPKGalleryMediaTypeVideo);
    BOOL isAudio = (item.mediaType == SPKGalleryMediaTypeAudio);
    self.rowTypeIcon.image = [SPKAssetUtils instagramIconNamed:(isAudio ? @"audio_filled" : (isVideo ? @"video_filled" : @"photo_filled"))
                                                     pointSize:12.0];

    self.sourcePill.hidden = (sourceLabel.length == 0);
    self.sourcePillLabel.text = sourceLabel;
    self.needsPill.hidden = !needsDetails;

    if (isAudio) {
        // The exact placeholder the gallery renders for saved audio, so a queued audio row and an
        // imported one are indistinguishable.
        self.thumbnailView.image = [SPKGalleryFile audioPlaceholderThumbnail];
        self.placeholderGlyph.hidden = YES;
    } else if (item.thumbnail) {
        self.thumbnailView.image = item.thumbnail;
        self.placeholderGlyph.hidden = YES;
    } else {
        // A frame that hasn't rendered yet: a centred glyph on the elevated tile.
        self.thumbnailView.image = nil;
        self.placeholderGlyph.hidden = NO;
        self.placeholderGlyph.image = [SPKAssetUtils instagramIconNamed:(isVideo ? @"video" : @"photo")
                                                              pointSize:24.0
                                                          renderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

@end

#pragma mark - View controller

@interface SPKGalleryImportViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) NSString *destinationFolderPath;
@property (nonatomic, strong) NSMutableArray<SPKGalleryImportQueuedFile *> *queuedFiles;
@property (nonatomic, strong) SPKGallerySaveMetadata *sharedDefaults;
@property (nonatomic, strong) UIBarButtonItem *overflowBarButtonItem;
@property (nonatomic, strong) UIView *emptyStateView;
/// The primary "Import N files" action: a full-width SPKGlassButton closing out the list as the
/// table's footer (see -installFooterCTA). IG blue glass on iOS 26, solid black/white fill below.
@property (nonatomic, strong) SPKGlassButton *importButton;
@property (nonatomic, strong) UIView *footerContainer;
/// Floats over the list while the footer CTA is off-screen; hides itself on arrival.
@property (nonatomic, strong) UIButton *jumpToBottomButton;
@property (nonatomic, strong) NSLayoutConstraint *jumpButtonBottomConstraint;
@property (nonatomic) BOOL jumpButtonVisible;
@property (nonatomic) BOOL isImporting;
@property (nonatomic) BOOL importCancelled;
// The single progress surface for a running import — the same notification pill used for reading a
// vault, so the whole feature reports progress one consistent way (the Import button stays a plain CTA).
@property (nonatomic, strong, nullable) SPKNotificationPillView *importPill;
// Tracks a per-file editor push so we can pin the file if the user changed anything. Strong so the
// form survives the pop transition until we read its didModifyMetadata in viewWillAppear.
@property (nonatomic, strong, nullable) SPKGalleryImportMetadataFormViewController *activeForm;
@property (nonatomic, weak, nullable) SPKGalleryImportQueuedFile *activeFormItem;
@property (nonatomic) BOOL activeFormIsShared;
@end

@implementation SPKGalleryImportViewController

- (instancetype)initWithDestinationFolderPath:(NSString *)folderPath {
    // Grouped (not plain): grouped section footers scroll with the content instead of sticking to
    // the table bounds behind the floating Import pill, and cells read as a consistent list.
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _destinationFolderPath = [folderPath copy];
        _queuedFiles = [NSMutableArray array];
        _sharedDefaults = [[SPKGallerySaveMetadata alloc] init];
        _sharedDefaults.source = (int16_t)SPKGallerySourceOther;
    }
    return self;
}

// No dealloc cleanup: the queue (files + manifest) lives in a persistent staging directory so it
// survives leaving the screen and app relaunches. Staged files are removed only when a file is
// imported, swiped away, or the queue is cleared.

#pragma mark - Persistent staging

// A private (non-user-visible) staging directory that survives relaunches, unlike NSTemporaryDirectory
// which the OS may purge. Queued media + the manifest live here until imported or cleared.
+ (NSString *)stagingDirectoryPath {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        path = [[appSupport stringByAppendingPathComponent:@"Sparkle"] stringByAppendingPathComponent:@"GalleryImportStaging"];
    });
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

+ (NSString *)manifestPath {
    return [[self stagingDirectoryPath] stringByAppendingPathComponent:@"queue.plist"];
}

- (NSURL *)stagedFileURLWithExtension:(NSString *)ext {
    NSString *name = [NSString stringWithFormat:@"sparkle-gallery-import-%@.%@", [NSUUID UUID].UUIDString, ext.length ? ext : @"dat"];
    return [NSURL fileURLWithPath:[[[self class] stagingDirectoryPath] stringByAppendingPathComponent:name]];
}

// Rewrite the manifest from the live queue + shared defaults. Called after every mutation so the
// on-disk state always matches what's on screen.
- (void)persistQueue {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (SPKGalleryImportQueuedFile *item in self.queuedFiles) {
        if (!item.tempFileURL) {
            continue;
        }
        [items addObject:@{
            @"file": item.tempFileURL.lastPathComponent ?: @"",
            @"label": item.fileLabel ?: @"",
            @"mediaType": @(item.mediaType),
            @"fileSize": @(item.fileSize),
            @"isFavorite": @(item.isFavorite),
            @"userEdited": @(item.userEdited),
            @"metadata": [item.metadata spk_dictionaryRepresentation] ?: @{},
        }];
    }
    NSDictionary *manifest = @{
        @"version": @1,
        @"shared": [self.sharedDefaults spk_dictionaryRepresentation] ?: @{},
        @"items": items,
    };
    NSString *manifestPath = [[self class] manifestPath];
    if (items.count == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];
        return;
    }
    [manifest writeToFile:manifestPath atomically:YES];
}

// Rebuild the queue from a previously written manifest, dropping any entries whose staged file has
// gone missing. Called once on load.
- (void)restoreQueue {
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[[self class] manifestPath]];
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        return;
    }
    if ([manifest[@"shared"] isKindOfClass:[NSDictionary class]]) {
        self.sharedDefaults = [SPKGallerySaveMetadata spk_metadataFromDictionary:manifest[@"shared"]];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[self class] stagingDirectoryPath];
    for (NSDictionary *entry in manifest[@"items"]) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *file = entry[@"file"];
        NSString *fullPath = file.length ? [dir stringByAppendingPathComponent:file] : nil;
        if (!fullPath || ![fm fileExistsAtPath:fullPath]) {
            continue;  // staged media gone (manual cleanup / interrupted copy) — skip it
        }
        SPKGalleryImportQueuedFile *item = [SPKGalleryImportQueuedFile new];
        item.tempFileURL = [NSURL fileURLWithPath:fullPath];
        item.fileLabel = [entry[@"label"] isKindOfClass:[NSString class]] ? entry[@"label"] : file;
        item.mediaType = (SPKGalleryMediaType)[entry[@"mediaType"] integerValue];
        item.fileSize = [entry[@"fileSize"] longLongValue];
        item.isFavorite = [entry[@"isFavorite"] boolValue];
        item.userEdited = [entry[@"userEdited"] boolValue];
        item.metadata = [SPKGallerySaveMetadata spk_metadataFromDictionary:entry[@"metadata"]];
        [self.queuedFiles addObject:item];
    }

    // Prune orphaned staged media (interrupted copies, entries dropped above) so the directory can't
    // grow unbounded. Keep only files still referenced by a live queue item, plus the manifest.
    NSMutableSet<NSString *> *keep = [NSMutableSet setWithObject:[[[self class] manifestPath] lastPathComponent]];
    for (SPKGalleryImportQueuedFile *item in self.queuedFiles) {
        if (item.tempFileURL.lastPathComponent) {
            [keep addObject:item.tempFileURL.lastPathComponent];
        }
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![keep containsObject:name]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"GALLERY_GALLERY_SETTINGS_IMPORT_MEDIA_TITLE");
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    // Every row is a fixed SPKImportRowHeight, so estimation buys nothing and actively hurts: it
    // defaults to UITableViewAutomaticDimension, which leaves contentSize a running guess until
    // rows are realized — and -jumpToBottom would then chase a moving target. Off = exact metrics.
    self.tableView.estimatedRowHeight = 0.0;
    self.tableView.estimatedSectionHeaderHeight = 0.0;
    self.tableView.estimatedSectionFooterHeight = 0.0;
    // Separator insets are set per-cell (queue rows align under the title, shared row near the
    // edge); the table-level inset is left alone so section headers/footers stay at the margin.
    [self.tableView registerClass:[SPKGalleryImportQueueCell class] forCellReuseIdentifier:@"queueCell"];
    [self.tableView registerClass:[SPKGalleryImportSharedCell class] forCellReuseIdentifier:@"sharedCell"];

    self.overflowBarButtonItem = SPKMediaChromeTopBarMenuButtonItemWithTint(@"more", [self buildOverflowMenu],
                                                                            [SPKUtils SPKColor_InstagramPrimaryText],
                                                                            SPKL(@"COMMON_MORE_ACCESSIBILITY_LABEL"));
    [self restoreQueue];
    [self installEmptyState];
    [self installFooterCTA];
    [self installJumpToBottomButton];
    [self updateImportButton];
}

// A full-screen empty state matching the gallery's spec (SPKGalleryViewController): a 96pt icon in
// tertiary, a 17pt medium primary title, a 14pt secondary subtitle. Import is actionable where the
// gallery is passive, so a glass "Choose from Files" button hangs below the stack.
- (void)installEmptyState {
    UIView *container = [[UIView alloc] init];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"media_empty"
                                                                                   pointSize:96.0]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [container addSubview:icon];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = SPKL(@"GALLERY_IMPORT_EMPTY_TITLE");
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    title.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    title.textAlignment = NSTextAlignmentCenter;
    [container addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = SPKL(@"GALLERY_IMPORT_EMPTY_SUBTITLE");
    subtitle.font = [UIFont systemFontOfSize:14.0];
    subtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    subtitle.numberOfLines = 0;
    subtitle.textAlignment = NSTextAlignmentCenter;
    [container addSubview:subtitle];

    SPKGlassButton *cta = [[SPKGlassButton alloc] initWithFrame:CGRectZero];
    cta.translatesAutoresizingMaskIntoConstraints = NO;
    [cta setText:SPKL(@"GALLERY_IMPORT_CHOOSE_FILES_ACTION")];
    [cta addTarget:self action:@selector(addFiles) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:cta];

    [NSLayoutConstraint activateConstraints:@[
        [icon.topAnchor constraintEqualToAnchor:container.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:96.0],
        [icon.heightAnchor constraintEqualToConstant:96.0],

        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:20.0],
        [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [cta.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:26.0],
        [cta.heightAnchor constraintEqualToConstant:SPKImportPillHeight],
        [cta.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [cta.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [cta.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    UIView *host = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [container.centerYAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.centerYAnchor constant:-40.0],
        [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:host.layoutMarginsGuide.leadingAnchor constant:8.0],
        [container.trailingAnchor constraintLessThanOrEqualToAnchor:host.layoutMarginsGuide.trailingAnchor constant:-8.0],
        [container.widthAnchor constraintLessThanOrEqualToConstant:340.0],
    ]];

    self.emptyStateView = host;
    self.tableView.backgroundView = host;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Returning from a per-file/shared editor: pin the file if changed, propagate shared live.
    [self reconcileActiveFormOnReturn];
    [self.tableView reloadData];
    [self updateImportButton];
}

#pragma mark - Overflow menu

- (UIMenu *)buildOverflowMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *add = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD_MORE_FILES")
                                        image:[SPKAssetUtils menuIconNamed:@"plus"]
                                   identifier:nil
                                      handler:^(__unused UIAction *a) { [weakSelf addFiles]; }];
    UIAction *clear = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_QUEUE")
                                          image:[SPKAssetUtils menuIconNamed:@"trash"]
                                     identifier:nil
                                        handler:^(__unused UIAction *a) { [weakSelf clearAllFiles]; }];
    clear.attributes = UIMenuElementAttributesDestructive;
    if (self.queuedFiles.count == 0 || self.isImporting) {
        clear.attributes = UIMenuElementAttributesDestructive | UIMenuElementAttributesDisabled;
    }
    return [UIMenu menuWithTitle:@"" children:@[ add, clear ]];
}

- (void)refreshOverflowMenu {
    UIButton *button = (UIButton *)self.overflowBarButtonItem.customView;
    if ([button isKindOfClass:[UIButton class]]) {
        button.menu = [self buildOverflowMenu];
    }
}

#pragma mark - Import action

// The import CTA closes out the list as a table footer rather than living in any bar. Bar chrome
// was tried twice and abandoned: hosting the button in a bottom UIToolbar stacked the system's
// shared background platter behind it (glass-on-glass, and a UIBarButtonItemGroup ignores per-item
// hiding), while a title-only Done bar item just tints its *text* and shares one pill with the
// overflow. Outside a bar there is no system chrome to fight, so the button renders its own glass
// exactly like the empty state's CTA — and it scrolls with the content it applies to.
- (void)installFooterCTA {
    self.importButton = [[SPKGlassButton alloc] initWithFrame:CGRectZero];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton addTarget:self action:@selector(importAll) forControlEvents:UIControlEventTouchUpInside];

    // A tableFooterView is frame-driven: it needs a real height up front, and its width is tracked
    // against the table in -viewDidLayoutSubviews.
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, SPKImportPillHeight + SPKImportFooterVPad * 2.0)];
    [container addSubview:self.importButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.importButton.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor
                                                        constant:SPKImportFooterHMargin],
        [self.importButton.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor
                                                         constant:-SPKImportFooterHMargin],
        [self.importButton.topAnchor constraintEqualToAnchor:container.topAnchor constant:SPKImportFooterVPad],
        [self.importButton.heightAnchor constraintEqualToConstant:SPKImportPillHeight],
    ]];
    self.footerContainer = container;
}

// This is a UITableViewController, so self.view IS the table — a floating overlay has to hang off
// the scroll view's frameLayoutGuide (fixed to the frame) rather than its bounds, which scroll.
// The scroll view's own safeAreaLayoutGuide scrolls with the content for the same reason, so the
// home-indicator inset is applied by hand in -viewDidLayoutSubviews.
- (void)installJumpToBottomButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    // Real system Liquid Glass: the material AND the interactive bounce both come from the button
    // *configuration*. Never stack a UIGlassEffect/UIVisualEffectView behind it — that's the
    // overlapping blur, and it renders flat and dead (proven on the import CTA). Non-prominent
    // glass() is the neutral capsule; prominentGlass() would tint it with the accent.
    Class configClass = NSClassFromString(@"UIButtonConfiguration");
    SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
    UIButtonConfiguration *config = nil;
    if (configClass && [configClass respondsToSelector:glassSel]) {
        config = ((id (*)(id, SEL))[configClass methodForSelector:glassSel])(configClass, glassSel);
    } else {
        config = [UIButtonConfiguration filledButtonConfiguration];
        config.baseBackgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    }
    config.image = [SPKAssetUtils instagramIconNamed:@"arrow_down"
                                           pointSize:24.0
                                       renderingMode:UIImageRenderingModeAlwaysTemplate];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = [SPKUtils SPKColor_InstagramPrimaryText];
    button.configuration = config;

    button.accessibilityLabel = SPKL(@"GALLERY_IMPORT_SCROLL_TO_BUTTON_ACCESSIBILITY_LABEL");
    button.alpha = 0.0;
    button.hidden = YES;
    [button addTarget:self action:@selector(jumpToBottom) forControlEvents:UIControlEventTouchUpInside];
    [self.tableView addSubview:button];

    self.jumpButtonBottomConstraint = [button.bottomAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor
                                                                         constant:-SPKImportJumpButtonMargin];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor
                                              constant:-SPKImportJumpButtonMargin],
        self.jumpButtonBottomConstraint,
        [button.widthAnchor constraintEqualToConstant:SPKImportJumpButtonSize],
        [button.heightAnchor constraintEqualToConstant:SPKImportJumpButtonSize],
    ]];

    self.jumpToBottomButton = button;
}

- (void)jumpToBottom {
    CGFloat maxOffset = self.tableView.contentSize.height - CGRectGetHeight(self.tableView.bounds)
                        + self.tableView.adjustedContentInset.bottom;
    CGFloat top = -self.tableView.adjustedContentInset.top;
    [self.tableView setContentOffset:CGPointMake(0.0, MAX(maxOffset, top)) animated:YES];
}

// Visible only while the footer CTA is actually off-screen, so it can't cover the button it points at.
- (void)updateJumpButtonVisibility {
    UIView *footer = self.tableView.tableFooterView;
    BOOL shouldShow = NO;
    if (footer && !self.isImporting) {
        CGRect visible = CGRectMake(self.tableView.contentOffset.x,
                                    self.tableView.contentOffset.y,
                                    CGRectGetWidth(self.tableView.bounds),
                                    CGRectGetHeight(self.tableView.bounds) - self.tableView.adjustedContentInset.bottom);
        shouldShow = !CGRectIntersectsRect(visible, footer.frame);
    }
    if (shouldShow == self.jumpButtonVisible) {
        return;
    }
    self.jumpButtonVisible = shouldShow;
    if (shouldShow) {
        self.jumpToBottomButton.hidden = NO;
    }
    [UIView animateWithDuration:0.2
        animations:^{
            self.jumpToBottomButton.alpha = shouldShow ? 1.0 : 0.0;
        }
        completion:^(BOOL finished) {
            if (finished && !self.jumpButtonVisible) {
                self.jumpToBottomButton.hidden = YES;
            }
        }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    (void)scrollView;
    [self updateJumpButtonVisibility];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.jumpButtonBottomConstraint.constant = -(SPKImportJumpButtonMargin + self.tableView.safeAreaInsets.bottom);
    // The table owns this subview alongside its cells, which are inserted as they recycle — keep the
    // overlay on top or it ends up behind a row.
    [self.tableView bringSubviewToFront:self.jumpToBottomButton];
    UIView *footer = self.tableView.tableFooterView;
    if (footer) {
        CGFloat width = self.tableView.bounds.size.width;
        if (fabs(CGRectGetWidth(footer.frame) - width) > 0.5) {
            CGRect frame = footer.frame;
            frame.size.width = width;
            footer.frame = frame;
            self.tableView.tableFooterView = footer; // re-assign so the table picks up the new metrics
        }
    }
    [self updateJumpButtonVisibility];
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.queuedFiles.count == 0 ? 0 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == SPKGalleryImportMainSectionShared) {
        return 1;
    }
    return (NSInteger)self.queuedFiles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    // No header for the shared section — the row already says "Shared Details".
    if (section == SPKGalleryImportMainSectionShared) {
        return nil;
    }
    NSUInteger n = self.queuedFiles.count;
    return n ? [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_QUEUE_HEADER_FORMAT"), SPKLP(@"COMMON_FILE_COUNT", (NSInteger)n)] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == SPKGalleryImportMainSectionShared) {
        return SPKL(@"GALLERY_IMPORT_SHARED_DETAILS_FOOTER");
    }
    if (section == SPKGalleryImportMainSectionQueue && self.queuedFiles.count > 0) {
        return SPKL(@"GALLERY_IMPORT_QUEUE_FOOTER");
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return SPKImportRowHeight;
}

#pragma mark - Shared summary

- (NSString *)sharedSummary {
    SPKGallerySaveMetadata *m = self.sharedDefaults;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ((SPKGallerySource)m.source != SPKGallerySourceOther) {
        [parts addObject:[SPKGalleryFile labelForSource:(SPKGallerySource)m.source]];
    }
    if (m.sourceUsername.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"@%@", m.sourceUsername]];
    }
    return parts.count ? [parts componentsJoinedByString:@" · "] : SPKL(@"COMMON_NOT_SET_LABEL");
}

#pragma mark - Queue row facts

- (NSString *)technicalTextForItem:(SPKGalleryImportQueuedFile *)item {
    SPKGallerySaveMetadata *m = item.metadata;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (m.durationSeconds > 0.05) {
        NSInteger total = (NSInteger)llround(m.durationSeconds);
        [parts addObject:[NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)]];
    }
    if (item.fileSize > 0) {
        [parts addObject:[NSByteCountFormatter stringFromByteCount:item.fileSize countStyle:NSByteCountFormatterCountStyleFile]];
    }
    if (item.mediaType != SPKGalleryMediaTypeAudio && m.pixelWidth > 0 && m.pixelHeight > 0) {
        [parts addObject:[NSString stringWithFormat:@"%d×%d", m.pixelWidth, m.pixelHeight]];
    }
    return [parts componentsJoinedByString:@" · "];
}

// The source pill only shows when a source was actually identified (not the default "Other"),
// so plain screenshots stay quiet instead of flashing a meaningless label.
- (nullable NSString *)sourceLabelForItem:(SPKGalleryImportQueuedFile *)item {
    if ((SPKGallerySource)item.metadata.source == SPKGallerySourceOther) {
        return nil;
    }
    return [SPKGalleryFile labelForSource:(SPKGallerySource)item.metadata.source];
}

// "Needs details" is a targeted nudge, not a blanket warning: it only fires when a post-bearing
// source was identified but there's no way to build an Open-original link yet. Screenshots and
// generic files never trigger it.
- (BOOL)needsDetailsForItem:(SPKGalleryImportQueuedFile *)item {
    SPKGallerySaveMetadata *m = item.metadata;
    SPKGallerySource src = (SPKGallerySource)m.source;
    BOOL postBearing = (src == SPKGallerySourceFeed || src == SPKGallerySourceReels || src == SPKGallerySourceStories);
    if (!postBearing) {
        return NO;
    }
    if (src == SPKGallerySourceStories) {
        return !(m.sourceUsername.length > 0 && m.sourceMediaPK.length > 0);
    }
    BOOL canLink = m.sourceMediaURLString.length > 0 || m.sourceMediaCode.length > 0 || m.sourceMediaPK.length > 0;
    return !canLink;
}

#pragma mark - Cells

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SPKGalleryImportMainSectionShared) {
        SPKGalleryImportSharedCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sharedCell" forIndexPath:indexPath];
        [cell setSubtitle:[self sharedSummary]];
        return cell;
    }

    SPKGalleryImportQueueCell *cell = [tableView dequeueReusableCellWithIdentifier:@"queueCell" forIndexPath:indexPath];
    SPKGalleryImportQueuedFile *item = self.queuedFiles[(NSUInteger)indexPath.row];
    [cell configureWithItem:item
              technicalText:[self technicalTextForItem:item]
                sourceLabel:[self sourceLabelForItem:item]
               needsDetails:[self needsDetailsForItem:item]];
    __weak typeof(self) weakSelf = self;
    __weak SPKGalleryImportQueuedFile *weakItem = item;
    cell.onThumbnailTap = ^{ [weakSelf previewItem:weakItem]; };
    [self ensureThumbnailForItem:item];
    return cell;
}

#pragma mark - Preview

- (void)previewItem:(SPKGalleryImportQueuedFile *)item {
    if (!item.tempFileURL) {
        return;
    }
    // Bare local preview — no action toolbar, no metadata (avoids remote-URL resolution). Pass the
    // queue's known media type: a Regram vault stores audio in an .mp4 container, which the player
    // would otherwise sniff as video and show as a black frame with no audio artwork.
    SPKMediaItemType type = (item.mediaType == SPKGalleryMediaTypeAudio)   ? SPKMediaItemTypeAudio
                            : (item.mediaType == SPKGalleryMediaTypeVideo) ? SPKMediaItemTypeVideo
                                                                           : SPKMediaItemTypeImage;
    [SPKFullScreenMediaPlayer showLocalFilePreview:item.tempFileURL mediaType:type];
}

#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != SPKGalleryImportMainSectionQueue || self.queuedFiles.count == 0 || self.isImporting) {
        return NO;
    }
    return YES;
}

- (void)removeQueuedFileAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != SPKGalleryImportMainSectionQueue || indexPath.row >= (NSInteger)self.queuedFiles.count)
        return;

    SPKGalleryImportQueuedFile *item = self.queuedFiles[(NSUInteger)indexPath.row];
    if (item.tempFileURL) {
        [[NSFileManager defaultManager] removeItemAtURL:item.tempFileURL error:nil];
    }
    [self.queuedFiles removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self persistQueue];
    // Full reload keeps the "Queue · N files" header count in sync without risking a
    // delete+reload-same-section conflict; the swipe itself still animates.
    [self.tableView reloadData];
    [self updateImportButton];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath])
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:nil
                                                                             handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
                                                                                 [weakSelf removeQueuedFileAtIndexPath:indexPath];
                                                                                 completionHandler(YES);
                                                                             }];
    deleteAction.image = [SPKAssetUtils instagramIconNamed:@"trash" pointSize:22.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"COMMON_REMOVE_ACTION");
    return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.isImporting) {
        return;
    }

    if (indexPath.section == SPKGalleryImportMainSectionShared) {
        [self pushSharedEditor];
        return;
    }

    SPKGalleryImportQueuedFile *item = self.queuedFiles[(NSUInteger)indexPath.row];
    [self pushEditorForItem:item];
}

- (void)pushSharedEditor {
    SPKGalleryImportMetadataFormViewController *form = [[SPKGalleryImportMetadataFormViewController alloc] init];
    form.metadata = self.sharedDefaults;
    form.title = SPKL(@"GALLERY_IMPORT_SHARED_DETAILS_TITLE");
    self.activeForm = form;
    self.activeFormItem = nil;
    self.activeFormIsShared = YES;
    [self.navigationController pushViewController:form animated:YES];
}

- (void)pushEditorForItem:(SPKGalleryImportQueuedFile *)item {
    SPKGalleryImportMetadataFormViewController *form = [[SPKGalleryImportMetadataFormViewController alloc] init];
    form.metadata = item.metadata;
    form.title = item.metadata.customName.length ? item.metadata.customName
                                                 : (item.metadata.sourceUsername.length ? item.metadata.sourceUsername : SPKL(@"GALLERY_IMPORT_FILE_DETAILS_TITLE"));
    // Audio gets no hero at all (the form drops the header for it) — a waveform placeholder blown
    // up to 180pt says nothing the row already didn't.
    form.previewThumbnail = (item.mediaType == SPKGalleryMediaTypeAudio) ? nil : item.thumbnail;
    form.previewFileURL = item.tempFileURL;
    form.previewMediaType = item.mediaType;
    form.previewFilename = item.fileLabel;
    NSString *typeName = item.mediaType == SPKGalleryMediaTypeVideo ? SPKL(@"COMMON_MEDIA_TYPE_VIDEO")
                                                                    : (item.mediaType == SPKGalleryMediaTypeAudio ? SPKL(@"COMMON_MEDIA_TYPE_AUDIO") : SPKL(@"COMMON_MEDIA_TYPE_PHOTO"));
    NSString *sizeText = item.fileSize > 0 ? [NSByteCountFormatter stringFromByteCount:item.fileSize countStyle:NSByteCountFormatterCountStyleFile] : nil;
    form.previewSubtitle = sizeText ? [NSString stringWithFormat:@"%@ · %@", typeName, sizeText] : typeName;
    self.activeForm = form;
    self.activeFormItem = item;
    self.activeFormIsShared = NO;
    [self.navigationController pushViewController:form animated:YES];
}

// Called on viewWillAppear when we return from an editor. A per-file edit pins the file; a shared
// edit re-seeds every file the user hasn't pinned, so shared details flow in live.
- (void)reconcileActiveFormOnReturn {
    SPKGalleryImportMetadataFormViewController *form = self.activeForm;
    if (!form) {
        return;
    }
    if (self.navigationController.viewControllers.count > 0 &&
        [self.navigationController.viewControllers containsObject:form]) {
        return; // still on screen (e.g. a sub-push), not actually returning yet
    }

    BOOL modified = form.didModifyMetadata;
    if (self.activeFormIsShared) {
        if (modified) {
            [self applySharedToUneditedFiles];
        }
    } else if (modified && self.activeFormItem) {
        self.activeFormItem.userEdited = YES;
    }
    if (modified) {
        [self persistQueue];  // capture the edited per-file/shared metadata to disk
    }
    self.activeForm = nil;
    self.activeFormItem = nil;
    self.activeFormIsShared = NO;
}

- (void)applySharedToUneditedFiles {
    for (SPKGalleryImportQueuedFile *item in self.queuedFiles) {
        if (item.userEdited) {
            continue;
        }
        item.metadata = [self.sharedDefaults copy];
        // Filename heuristics still win over shared for per-file specifics (date, shortcode).
        SPKGalleryApplyImportHeuristicsFromFilename(item.fileLabel, item.metadata);
    }
}

#pragma mark - Thumbnails

// A frame grab can come back empty for a file that is still settling on disk, while an undecodable
// one would re-run the generator on every scroll if it were retried forever.
static const NSInteger kSPKImportThumbnailMaxAttempts = 2;

- (void)ensureThumbnailForItem:(SPKGalleryImportQueuedFile *)item {
    if (item.thumbnail || item.thumbnailRequested || !item.tempFileURL ||
        item.thumbnailAttempts >= kSPKImportThumbnailMaxAttempts ||
        item.mediaType == SPKGalleryMediaTypeAudio) {
        return; // audio uses the gallery placeholder, no frame to render
    }
    item.thumbnailRequested = YES;
    item.thumbnailAttempts++;
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
    CGSize size = CGSizeMake(SPKImportThumbnailSize * scale, SPKImportThumbnailSize * scale);
    __weak typeof(self) weakSelf = self;
    [SPKGalleryFile generateThumbnailForURL:item.tempFileURL
                                  mediaType:item.mediaType
                                       size:size
                                 completion:^(UIImage *_Nullable image) {
                                     if (!image) {
                                         // Clearing the request lets a later reconfigure try again,
                                         // bounded by the attempt cap, instead of leaving the row on
                                         // its placeholder for the rest of the session.
                                         item.thumbnailRequested = NO;
                                         SPKLog(@"Gallery", @"[Sparkle] Import thumbnail render failed for %@", item.fileLabel);
                                         return;
                                     }
                                     item.thumbnail = image;
                                     [weakSelf refreshRowForItem:item];
                                 }];
}

// The frame lands well after the row was configured, and often while that row sits outside the
// visible set, so asking the table to reload it dropped the update and the placeholder stayed until
// something else happened to rebuild the cell. The live cell is reconfigured directly instead, and a
// row without one needs nothing: dequeuing it reads the thumbnail straight off the item.
- (void)refreshRowForItem:(SPKGalleryImportQueuedFile *)item {
    NSUInteger row = [self.queuedFiles indexOfObjectIdenticalTo:item];
    if (row == NSNotFound) {
        return;
    }
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)row inSection:SPKGalleryImportMainSectionQueue];
    SPKGalleryImportQueueCell *cell = (SPKGalleryImportQueueCell *)[self.tableView cellForRowAtIndexPath:ip];
    if (![cell isKindOfClass:[SPKGalleryImportQueueCell class]]) {
        return;
    }

    [cell configureWithItem:item
              technicalText:[self technicalTextForItem:item]
                sourceLabel:[self sourceLabelForItem:item]
               needsDetails:[self needsDetailsForItem:item]];
}

#pragma mark - Document picker

- (void)addFiles {
    if (self.isImporting) {
        return;
    }
    NSArray<NSString *> *utiStrings = @[
        (__bridge NSString *)kUTTypeImage,
        (__bridge NSString *)kUTTypeMovie,
        (__bridge NSString *)kUTTypeVideo,
        (__bridge NSString *)kUTTypeMPEG4,
        (__bridge NSString *)kUTTypeQuickTimeMovie,
        (__bridge NSString *)kUTTypeGIF,
        (__bridge NSString *)kUTTypeAudio,
        (__bridge NSString *)kUTTypeMP3,
        (__bridge NSString *)kUTTypeMPEG4Audio,
        (__bridge NSString *)kUTTypeAudioInterchangeFileFormat,
        (__bridge NSString *)kUTTypeWaveformAudio,
        @"org.webmproject.webp",
        @"org.xiph.ogg",
        @"public.ogg",
        // Regram Media Vault: a folder export or a (nested) MediaVault.zip.
        @"public.zip-archive",
        @"public.folder",
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:utiStrings inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)clearAllFiles {
    if (self.isImporting || self.queuedFiles.count == 0) {
        return;
    }
    NSUInteger count = self.queuedFiles.count;
    NSString *title = [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_REMOVE_ALL_QUESTION_FORMAT"), SPKLP(@"COMMON_FILE_COUNT", (NSInteger)count)];
    __weak typeof(self) weakSelf = self;
    [SPKUtils showConfirmation:^{
        __strong typeof(weakSelf) self = weakSelf;
        NSFileManager *fm = [NSFileManager defaultManager];
        for (SPKGalleryImportQueuedFile *item in self.queuedFiles) {
            if (item.tempFileURL) {
                [fm removeItemAtURL:item.tempFileURL error:nil];
            }
        }
        [self.queuedFiles removeAllObjects];
        [self persistQueue];
        [self.tableView reloadData];
        [self updateImportButton];
    }
                         title:title
                       message:SPKL(@"GALLERY_GALLERY_IMPORT_THEY_STAY_FILES_APP_ONLY_IMPORT_QUEUE_CLEARED_TEXT")];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSMutableArray<NSURL *> *containers = [NSMutableArray array];  // folders / zips (possible Regram vaults)
    for (NSURL *url in urls) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue || [url.pathExtension.lowercaseString isEqualToString:@"zip"]) {
            [containers addObject:url];
        } else {
            [self enqueueCopiedFileFromURL:url];
        }
    }
    [self persistQueue];
    [self.tableView reloadData];
    [self updateImportButton];

    if (containers.count > 0) {
        [self ingestContainerURLs:containers];
    }
}

// Folders and zips are read off the main thread (unzip + SQLite + copying many files). A Regram
// Media Vault becomes queued items with its DB metadata pre-filled; anything else is ignored.
- (void)ingestContainerURLs:(NSArray<NSURL *> *)urls {
    // Cancelling stops reading at the next row and queues nothing; the files
    // already copied for the rows read so far are removed.
    __block atomic_bool cancelled = false;
    __block SPKNotificationPillView *pill = SPKNotifyProgress(kSPKNotificationGalleryImport, SPKL(@"GALLERY_IMPORT_READING_EXPORT_PROGRESS"), ^{
        atomic_store(&cancelled, true);
        [pill dismiss];
    });
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<SPKGalleryImportQueuedFile *> *newItems = [NSMutableArray array];
        NSUInteger vaults = 0;
        for (NSURL *url in urls) {
            if (atomic_load(&cancelled))
                break;
            NSArray<NSDictionary *> *rows = [SPKRegramImporter vaultRowsFromPickedURL:url];
            if (rows.count == 0) {
                continue;  // not a Regram vault, skip (folders of loose media aren't supported here)
            }
            vaults++;
            NSUInteger total = rows.count, done = 0;
            for (NSDictionary *row in rows) {
                if (atomic_load(&cancelled))
                    break;
                SPKGalleryImportQueuedFile *item = [weakSelf queuedItemFromRegramRow:row];
                if (item) {
                    [newItems addObject:item];
                }
                done++;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [pill setProgress:(float)done / (float)total animated:YES];
                    [pill updateProgressTitle:SPKL(@"GALLERY_IMPORT_READING_EXPORT_PROGRESS")
                                     subtitle:[NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"), (unsigned long)done, (unsigned long)total]];
                });
            }
        }

        void (^discardItems)(void) = ^{
            for (SPKGalleryImportQueuedFile *item in newItems) {
                if (item.tempFileURL)
                    [[NSFileManager defaultManager] removeItemAtURL:item.tempFileURL error:nil];
            }
        };
        if (atomic_load(&cancelled)) {
            discardItems();
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (atomic_load(&cancelled)) {
                discardItems();
                return;
            }
            if (!self) {
                return;
            }
            if (newItems.count > 0) {
                [self.queuedFiles addObjectsFromArray:newItems];
                [self persistQueue];
                [self.tableView reloadData];
                [self updateImportButton];
                [pill showSuccessWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_MEDIA_VAULT_READY_TEXT")
                                  subtitle:[NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_ADDED_TO_QUEUE_FORMAT"), SPKLP(@"COMMON_ITEM_COUNT", (NSInteger)newItems.count)]
                                      icon:nil];
            } else if (vaults > 0) {
                [pill showErrorWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_NOTHING_IMPORT_TEXT") subtitle:SPKL(@"GALLERY_GALLERY_IMPORT_REGRAM_VAULT_HAD_NO_MEDIA_TEXT") icon:nil];
            } else {
                [pill showErrorWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_NOT_REGRAM_VAULT_TEXT") subtitle:SPKL(@"GALLERY_GALLERY_IMPORT_PICK_REGRAM_EXPORT_FOLDER_MEDIAVAULT_ZIP_TEXT") icon:nil];
            }
        });
    });
}

// Copies a Regram vault row's media into the import temp dir and builds a queued item with its DB
// metadata pre-filled. The metadata is pinned (userEdited) so shared-defaults edits don't clobber it.
- (SPKGalleryImportQueuedFile *)queuedItemFromRegramRow:(NSDictionary *)row {
    NSString *srcPath = [SPKRegramImporter filePathForRow:row];
    if (srcPath.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ext = srcPath.pathExtension.length ? srcPath.pathExtension : @"dat";
    NSURL *stagedURL = [self stagedFileURLWithExtension:ext];
    NSString *tempPath = stagedURL.path;
    [fm removeItemAtPath:tempPath error:nil];
    if (![fm copyItemAtPath:srcPath toPath:tempPath error:nil]) {
        return nil;
    }

    SPKGalleryImportQueuedFile *item = [SPKGalleryImportQueuedFile new];
    item.tempFileURL = stagedURL;
    item.fileLabel = srcPath.lastPathComponent ?: @"file";
    item.mediaType = [SPKRegramImporter mediaTypeForRow:row];
    item.fileSize = (long long)[[fm attributesOfItemAtPath:tempPath error:nil] fileSize];
    item.metadata = [SPKRegramImporter metadataForRow:row];
    item.isFavorite = [SPKRegramImporter isFavoriteRow:row];
    item.userEdited = YES;  // DB metadata is authoritative — don't let shared defaults overwrite it
    return item;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

- (void)enqueueCopiedFileFromURL:(NSURL *)srcURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ext = srcURL.pathExtension.length ? srcURL.pathExtension : @"dat";
    NSURL *tempURL = [self stagedFileURLWithExtension:ext];
    NSString *tempPath = tempURL.path;
    [fm removeItemAtPath:tempPath error:nil];

    // Provider/iCloud URLs must be read through a file coordinator and inside a security scope, or
    // the copy can race and leave nothing on disk (the "source file does not exist" failures at
    // import time). Coordinate the read and copy from the coordinated URL.
    __block NSError *copyError = nil;
    BOOL scoped = [srcURL startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError = nil;
    [coordinator coordinateReadingItemAtURL:srcURL
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordError
                                 byAccessor:^(NSURL *readingURL) {
                                     [fm removeItemAtURL:tempURL error:nil];
                                     [fm copyItemAtURL:readingURL toURL:tempURL error:&copyError];
                                 }];
    if (scoped) {
        [srcURL stopAccessingSecurityScopedResource];
    }

    if (![fm fileExistsAtPath:tempPath]) {
        NSString *reason = (coordError ?: copyError).localizedDescription ?: SPKL(@"GALLERY_IMPORT_COULD_NOT_READ_FILE_ERROR");
        SPKNotify(kSPKNotificationGalleryImport, SPKL(@"GALLERY_IMPORT_COULD_NOT_ADD_FILE_TITLE"), reason, @"error_filled", SPKNotificationToneError);
        return;
    }

    SPKGalleryImportQueuedFile *item = [SPKGalleryImportQueuedFile new];
    item.tempFileURL = tempURL;
    item.fileLabel = srcURL.lastPathComponent ?: @"file";
    item.mediaType = [SPKGalleryFile inferMediaTypeFromFileURL:tempURL];
    item.fileSize = (long long)[[fm attributesOfItemAtPath:tempPath error:nil] fileSize];
    item.metadata = [self.sharedDefaults copy];
    SPKGalleryApplyImportHeuristicsFromFilename(item.fileLabel, item.metadata);
    [self.queuedFiles addObject:item];
}

#pragma mark - Import

- (void)updateImportButton {
    NSUInteger count = self.queuedFiles.count;
    BOOL empty = (count == 0) && !self.isImporting;
    self.tableView.backgroundView.hidden = !empty;
    self.tableView.scrollEnabled = !empty;
    // The empty state carries its own CTA, so the footer only exists once there's a queue.
    UIView *footer = empty ? nil : self.footerContainer;
    if (self.tableView.tableFooterView != footer) {
        self.tableView.tableFooterView = footer;
    }
    if (self.isImporting) {
        return; // chrome + label driven by the batch progress updates
    }
    // The overflow (Add / Clear) only makes sense once the empty state is gone.
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, empty ? @[] : @[ self.overflowBarButtonItem ]);
    [self refreshOverflowMenu];
    [self.importButton setText:[NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_BUTTON_FORMAT"), SPKLP(@"COMMON_FILE_COUNT", (NSInteger)count)]];
    self.importButton.enabled = YES;
    [self updateJumpButtonVisibility];
}

- (void)setImportingChrome:(BOOL)importing {
    if (importing) {
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                target:self
                                                                                action:@selector(cancelImport)];
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ cancel ]);
    } else {
        SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ self.overflowBarButtonItem ]);
        [self refreshOverflowMenu];
    }
}

- (void)cancelImport {
    self.importCancelled = YES;
}

- (void)importAll {
    if (self.isImporting || self.queuedFiles.count == 0) {
        return;
    }
    self.isImporting = YES;
    self.importCancelled = NO;
    [self setImportingChrome:YES];

    NSArray<SPKGalleryImportQueuedFile *> *batch = [self.queuedFiles copy];
    self.importButton.enabled = NO;
    [self.importButton setText:SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS")];
    // One progress surface for the whole feature: the notification pill (same as reading a vault).
    // Its cancel affordance drives the same cancel path as the top-bar Cancel button.
    __weak typeof(self) weakSelf = self;
    self.importPill = SPKNotifyProgress(kSPKNotificationGalleryImport, SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS"), ^{ [weakSelf cancelImport]; });
    [self.importPill updateProgressTitle:SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS")
                                subtitle:[NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"), 0UL, (unsigned long)batch.count]];

    [self importNextInBatch:batch
                      index:0
                  succeeded:[NSMutableArray array]
                   failures:0
                  lastError:nil];
}

- (void)importNextInBatch:(NSArray<SPKGalleryImportQueuedFile *> *)batch
                    index:(NSUInteger)index
                succeeded:(NSMutableArray<SPKGalleryImportQueuedFile *> *)succeeded
                 failures:(NSUInteger)failures
                lastError:(nullable NSString *)lastError {
    NSUInteger total = batch.count;
    if (self.importCancelled || index >= total) {
        [self finishImportWithSucceeded:succeeded failures:failures lastError:lastError];
        return;
    }

    [self.importPill setProgress:(total ? (float)index / (float)total : 0.0f) animated:YES];
    [self.importPill updateProgressTitle:SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS")
                                subtitle:[NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"), (unsigned long)(index + 1), (unsigned long)total]];

    // Hop to the next runloop pass so the pill paints and the Cancel tap stays responsive between
    // files. saveFileToGallery: uses the main-queue Core Data context, so the save stays on main.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        SPKGalleryImportQueuedFile *item = batch[index];
        NSUInteger nextFailures = failures;
        NSString *nextError = lastError;

        // Use the item's known media type (set at enqueue for every path). Regram marks audio that
        // lives in an .mp4 container, which extension sniffing would otherwise misread as video.
        SPKGalleryMediaType mediaType = item.mediaType;
        NSError *err = nil;
        SPKGalleryFile *saved = [SPKGalleryFile saveFileToGallery:item.tempFileURL
                                                           source:(SPKGallerySource)item.metadata.source
                                                        mediaType:mediaType
                                                       folderPath:self.destinationFolderPath
                                                         metadata:item.metadata
                                                            error:&err];
        if (saved) {
            if (item.isFavorite) {
                saved.isFavorite = YES;
                [[SPKGalleryCoreDataStack shared].viewContext save:NULL];
            }
            [[NSFileManager defaultManager] removeItemAtURL:item.tempFileURL error:nil];
            item.tempFileURL = nil;
            [succeeded addObject:item];
        } else {
            nextFailures++;
            nextError = err.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVE_FAILED_TEXT");
        }

        [self importNextInBatch:batch
                          index:index + 1
                      succeeded:succeeded
                       failures:nextFailures
                      lastError:nextError];
    });
}

- (void)finishImportWithSucceeded:(NSMutableArray<SPKGalleryImportQueuedFile *> *)succeeded
                         failures:(NSUInteger)failures
                        lastError:(nullable NSString *)lastError {
    BOOL cancelled = self.importCancelled;
    NSUInteger imported = succeeded.count;

    self.isImporting = NO;
    [self.queuedFiles removeObjectsInArray:succeeded];
    [self persistQueue];  // staged files for imported items were already deleted; drop them from the manifest
    [self.tableView reloadData];
    [self setImportingChrome:NO];
    [self updateImportButton];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKGalleryFavoritesSortPreferenceChanged" object:nil];

    // Resolve the running progress pill in place, so the import reports its result on the same
    // surface it showed progress on (no second pill).
    SPKNotificationPillView *pill = self.importPill;
    self.importPill = nil;

    if (cancelled) {
        NSString *subtitle = imported
                                 ? [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_IMPORTED_BEFORE_CANCEL_FORMAT"), (unsigned long)imported]
                                 : SPKL(@"GALLERY_IMPORT_NO_FILES_IMPORTED_TEXT");
        [pill showErrorWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_IMPORT_CANCELLED_TEXT") subtitle:subtitle icon:nil];
        return;
    }

    if (failures > 0) {
        NSString *subtitle = lastError.length
                                 ? [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_FAILURE_WITH_REASON_FORMAT"), (unsigned long)failures, lastError]
                                 : [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_FAILURE_FORMAT"), (unsigned long)failures];
        [pill showErrorWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_IMPORT_INCOMPLETE_TEXT") subtitle:subtitle icon:nil];
        return;
    }

    NSString *subtitle = [NSString stringWithFormat:SPKL(@"GALLERY_IMPORT_SAVED_TO_GALLERY_FORMAT"), SPKLP(@"COMMON_FILE_COUNT", (NSInteger)imported)];
    [pill showSuccessWithTitle:SPKL(@"GALLERY_GALLERY_IMPORT_IMPORTED_TEXT") subtitle:subtitle icon:nil];
    if (self.queuedFiles.count == 0) {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

@end
