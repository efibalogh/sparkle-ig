#import <Foundation/Foundation.h>

#import "SPKDownloadTypes.h"

@class SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

// Custom names for files that leave Sparkle (Photos, the share sheet, Files).
// The Gallery's own storage always keeps the SPKFileNameForMedia layout: it reads
// the posted date and import attribution back out of those names.

FOUNDATION_EXPORT NSString *const kSPKExportNamePartsKey;
FOUNDATION_EXPORT NSString *const kSPKExportNameSeparatorKey;
FOUNDATION_EXPORT NSString *const kSPKExportNameDateStyleKey;
FOUNDATION_EXPORT NSString *const kSPKExportNamePhotosKey;
FOUNDATION_EXPORT NSString *const kSPKExportNameShareKey;

/// Stable part identifiers, stored comma-separated under kSPKExportNamePartsKey.
FOUNDATION_EXPORT NSString *const SPKExportNamePartUsername;
FOUNDATION_EXPORT NSString *const SPKExportNamePartSource;
FOUNDATION_EXPORT NSString *const SPKExportNamePartPostedDate;
FOUNDATION_EXPORT NSString *const SPKExportNamePartSavedDate;
FOUNDATION_EXPORT NSString *const SPKExportNamePartPostID;

FOUNDATION_EXPORT NSArray<NSString *> *SPKExportNameAllParts(void);
FOUNDATION_EXPORT NSArray<NSString *> *SPKExportNameEnabledParts(void);
FOUNDATION_EXPORT void SPKExportNameSetEnabledParts(NSArray<NSString *> *parts);
FOUNDATION_EXPORT NSString *SPKExportNamePartTitle(NSString *part);

/// YES when the user turned custom names on for this destination.
FOUNDATION_EXPORT BOOL SPKExportNamingAppliesToDestination(SPKDownloadDestination destination);

/// The custom stem (no extension) for one file, built from the current settings.
/// `sourceFileName` is the file's current name: when it is a Sparkle-layout name
/// (a Gallery original) its save time and posted date are used, since metadata
/// rebuilt from a Gallery file carries neither. Returns nil when nothing usable
/// remains, so callers keep their default name.
FOUNDATION_EXPORT NSString *_Nullable SPKExportFileNameStem(SPKGallerySaveMetadata *_Nullable metadata,
                                                            NSString *_Nullable sourceFileName);

/// `stem` plus the configured separator and a 1-based position.
FOUNDATION_EXPORT NSString *SPKExportFileNameAppendingIndex(NSString *stem, NSInteger position);

/// A path in `directory` named `stem.ext` that nothing else occupies, numbering
/// clashes (`stem_2.ext`). `ownPath` is the file being renamed, which may keep its slot.
FOUNDATION_EXPORT NSString *SPKExportUniquePath(NSString *directory, NSString *stem, NSString *_Nullable extension, NSString *_Nullable ownPath);

/// For share sheets that hand out a file Sparkle keeps (a Gallery original): a link
/// or clone under the custom name in a temporary folder, or `fileURL` itself when
/// custom names are off for `destination` or the copy fails. Several files passed
/// together share one folder, so their names never clash.
FOUNDATION_EXPORT NSArray<NSURL *> *SPKExportShareableFileURLs(NSArray<NSURL *> *fileURLs,
                                                              NSArray<SPKGallerySaveMetadata *> *_Nullable metadata,
                                                              SPKDownloadDestination destination);
FOUNDATION_EXPORT NSURL *SPKExportShareableFileURL(NSURL *fileURL,
                                                   SPKGallerySaveMetadata *_Nullable metadata,
                                                   SPKDownloadDestination destination);

/// A sample name for the settings preview.
FOUNDATION_EXPORT NSString *SPKExportFileNamePreview(void);

NS_ASSUME_NONNULL_END
