#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>

#import "SPKGallerySaveMetadata.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int16_t, SPKGalleryMediaType) {
    SPKGalleryMediaTypeImage = 0,
    SPKGalleryMediaTypeVideo = 1,
    SPKGalleryMediaTypeAudio = 2
};

FOUNDATION_EXPORT NSString *SPKFileNameForMedia(NSURL *originalURL, SPKGalleryMediaType mediaType, SPKGallerySaveMetadata *_Nullable metadata);

/// Best-effort parse of tweak/Sparkle-style basenames, e.g. \c 1778088045602_username_story_20260210001603 — fills save-time epoch, posted-time compact date, user pk, username, and source slug when \a metadata fields are still empty (or source is Other).
FOUNDATION_EXPORT void SPKGalleryApplyImportHeuristicsFromFilename(NSString *fileName, SPKGallerySaveMetadata *metadata);

typedef NS_ENUM(int16_t, SPKGallerySource) {
    SPKGallerySourceOther = 0,
    SPKGallerySourceFeed = 1,
    SPKGallerySourceStories = 2,
    SPKGallerySourceReels = 3,
    SPKGallerySourceProfile = 4,
    SPKGallerySourceDMs = 5,
    SPKGallerySourceThumbnail = 6,
    SPKGallerySourceInstants = 7,
    SPKGallerySourceAudioPage = 8,
    SPKGallerySourceComments = 9
};

@interface SPKGalleryFile : NSManagedObject

@property (nonatomic, strong) NSString *identifier;
@property (nonatomic, strong) NSString *relativePath;
@property (nonatomic) int16_t mediaType;
@property (nonatomic) int16_t source;
@property (nonatomic, strong) NSDate *dateAdded;
@property (nonatomic) int64_t fileSize;
@property (nonatomic) BOOL isFavorite;
/// YES when captured by auto-save rather than an explicit user action.
@property (nonatomic) BOOL isAutoSave;
@property (nonatomic, copy, nullable) NSString *folderPath;
@property (nonatomic, copy, nullable) NSString *customName;
@property (nonatomic, copy, nullable) NSString *sourceUsername;
@property (nonatomic, copy, nullable) NSString *sourceUserPK;
@property (nonatomic, copy, nullable) NSString *sourceProfileURLString;
@property (nonatomic, copy, nullable) NSString *sourceMediaPK;
@property (nonatomic, copy, nullable) NSString *sourceMediaCode;
@property (nonatomic, copy, nullable) NSString *sourceMediaURLString;
@property (nonatomic) int32_t pixelWidth;
@property (nonatomic) int32_t pixelHeight;
@property (nonatomic) double durationSeconds;
/// Per-account ownership. nil/empty = unassigned (legacy files).
@property (nonatomic, copy, nullable) NSString *ownerAccountPK;
@property (nonatomic, copy, nullable) NSString *ownerUsername;

/// Classifies by path extension; unknown extensions default to image.
+ (SPKGalleryMediaType)inferMediaTypeFromFileURL:(NSURL *)fileURL;

+ (nullable SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                                        source:(SPKGallerySource)source
                                     mediaType:(SPKGalleryMediaType)mediaType
                                         error:(NSError **)error;

/// Convenience: adds to gallery inside the given folder.
+ (nullable SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                                        source:(SPKGallerySource)source
                                     mediaType:(SPKGalleryMediaType)mediaType
                                    folderPath:(nullable NSString *)folderPath
                                         error:(NSError **)error;

/// When `metadata` is non-nil, its fields override `source` and populate list UI. File is probed for any missing dimensions/duration.
+ (nullable SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                                        source:(SPKGallerySource)source
                                     mediaType:(SPKGalleryMediaType)mediaType
                                    folderPath:(nullable NSString *)folderPath
                                      metadata:(nullable SPKGallerySaveMetadata *)metadata
                                         error:(NSError **)error;

- (BOOL)removeWithError:(NSError *_Nullable *_Nullable)error;

/// Replaces this file's media in place with `newURL` (e.g. a trimmed clip or an
/// extracted frame), updating mediaType/dimensions/duration/fileSize/thumbnail
/// while preserving the file's identity (identifier, dateAdded, origin, folder,
/// custom name, favorite). Copies before deleting the original, so a failed
/// replace leaves the original intact.
- (BOOL)replaceMediaWithFileURL:(NSURL *)newURL
                      mediaType:(SPKGalleryMediaType)mediaType
                          error:(NSError *_Nullable *_Nullable)error;

/// Builds save metadata mirroring this file's source attribution (username,
/// user/media IDs, profile/permalink URLs, source, dates). Used to carry origin
/// info onto a derived copy (e.g. a trimmed clip) so its filename and Open
/// Profile/Post links match the original. Dimensions/duration are intentionally
/// omitted so the derived file is probed fresh.
- (SPKGallerySaveMetadata *)saveMetadata;

/// Stamps this file's `dateAdded` to now and persists it. Used for derived
/// copies (e.g. a trimmed clip) that inherit the original's date via
/// `saveMetadata` for filename/attribution but should still sort as the newest
/// item in the gallery.
- (void)markAddedNow;

/// Number of files with no owning account (legacy / pre-feature saves).
+ (NSUInteger)unassignedFileCount;
/// Assigns every unassigned file to the given account. Returns the count moved.
+ (NSUInteger)claimUnassignedFilesForAccountPK:(NSString *)pk username:(nullable NSString *)username;

- (NSString *)filePath;
- (NSURL *)fileURL;
- (BOOL)fileExists;
- (NSString *)thumbnailPath;
- (BOOL)thumbnailExists;

/// User-facing display name — customName if set, else the portion of relativePath after the timestamp prefix.
- (NSString *)displayName;

/// Human-readable label for the source type.
/// YES for a story known to live in a highlight: saved from one, or found in one
/// and relinked on a later open. Read from the stored origin link, so a story
/// added to a highlight since it was saved is not known until it is opened.
- (BOOL)isFromHighlight;
/// The source's name for display. A highlight story says so, while it still
/// counts as a story for filtering.
- (NSString *)sourceLabel;
/// The icon name for this item's source, as +symbolNameForSource: but aware of
/// highlight stories.
- (NSString *)sourceSymbolName;

/// Primary line in list mode: username when known, else `displayName`.
- (NSString *)listPrimaryTitle;

/// Second line: duration • size • resolution • bitrate (video), or size • resolution (image).
- (NSString *)listTechnicalLine;

/// Third line: human-readable download date (e.g. Apr 17 at 2:04 AM).
- (NSString *)listDownloadDateString;
- (nullable NSURL *)preferredProfileURL;
- (nullable NSURL *)preferredOriginalMediaURL;
/// The link a person would share for this item's original post, reel, story or
/// highlight: always an https instagram.com address, never the in-app router URL
/// that preferredOriginalMediaURL prefers for opening.
- (nullable NSURL *)originalWebURL;
- (BOOL)hasOpenableProfile;
- (BOOL)hasOpenableOriginalMedia;

/// Full Instagram media identifier (`<mediaPK>_<userPK>`) used by the authenticated `instagram://media?id=` deep link. Returns nil unless a complete id can be assembled (a bare media pk on its own resolves to the home feed, not the post).
- (nullable NSString *)fullInstagramMediaID;

/// Source-appropriate title for the "open original" action (e.g. "Open Story", "Open Reel", "Open Post").
- (NSString *)openOriginalActionTitle;

+ (void)generateThumbnailForFile:(SPKGalleryFile *)file
                      completion:(void (^_Nullable)(BOOL success))completion;

/// Renders a thumbnail straight from a file URL (image or video) using the same pipeline as the
/// saved-file thumbnailer, for media that isn't a \c SPKGalleryFile yet (e.g. Files import). The
/// completion is called on the main queue; \c nil means no thumbnail could be produced.
+ (void)generateThumbnailForURL:(NSURL *)url
                      mediaType:(SPKGalleryMediaType)mediaType
                           size:(CGSize)size
                     completion:(void (^)(UIImage *_Nullable thumbnail))completion;

+ (nullable UIImage *)loadThumbnailForFile:(SPKGalleryFile *)file;

/// Cache-only lookup: returns a ready-to-draw thumbnail if one is already in
/// memory, otherwise nil. Never touches the disk, so it is safe to call from
/// \c cellForItemAtIndexPath as the synchronous fast path. Must be called on the
/// main queue (audio files return the trait-dependent placeholder).
+ (nullable UIImage *)cachedThumbnailForFile:(SPKGalleryFile *)file;

/// Reads (and if needed generates) the thumbnail off the main thread, decoding it
/// before it is handed back so the first draw does not run the JPEG decoder on
/// the main thread. The completion is always called asynchronously, on the main
/// queue; \c nil means no thumbnail could be produced.
+ (void)loadThumbnailAsyncForFile:(SPKGalleryFile *)file
                       completion:(void (^)(UIImage *_Nullable thumbnail))completion;

/// Crisp three-bar EQ glyph (the same shape the gallery grid draws for audio)
/// rendered in `barColor` on a transparent background. Lets dark surfaces such
/// as the trim editor's audio pane show the bars in white without the gray card.
+ (UIImage *)audioGlyphImageWithBarColor:(UIColor *)barColor;

/// The exact audio thumbnail the gallery grid/list draws for audio files
/// (tertiary-background card with centered EQ bars). Cached per interface style.
/// Used by the Files-import queue so audio rows match the gallery.
+ (UIImage *)audioPlaceholderThumbnail;

/// Returns a human-readable label for the given source.
+ (NSString *)labelForSource:(SPKGallerySource)source;

/// Returns the symbol name for the given source.
+ (NSString *)symbolNameForSource:(SPKGallerySource)source;

@end

NS_ASSUME_NONNULL_END
