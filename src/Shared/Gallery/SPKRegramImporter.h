#import <UIKit/UIKit.h>

#import "SPKGalleryFile.h"
#import "SPKGallerySaveMetadata.h"

NS_ASSUME_NONNULL_BEGIN

/// Reads a Regram "export settings & data" *media vault* so it can be fed into the standard Gallery
/// import queue (editable metadata + the usual save pipeline).
///
/// Regram ships its vault as a Core Data `MediaVault.sqlite` (entities `ZRGVFILE` + `ZRGVUSER`, plus
/// `ZRGVFOLDER` since 7.1) beside a `Files/<userPK>/...` media tree. Older exports hand it over as a
/// plain folder, a `MediaVault.zip` (DEFLATE/ZIP64), or nested inside a full `Regram-Data.zip`. Since
/// 7.1 every export is a "frbackup-package" zip whose `package.json` points at per-feature inner zips
/// (`items/MediaVault/<n>.zip`, laid out as `store/` + `media/Files/`), optionally encrypted with
/// WinZip AES. This reader auto-detects all of those and maps each row onto `SPKGallerySaveMetadata`.
@interface SPKRegramImporter : NSObject

/// Resolves a picked folder/zip and returns one opaque row dictionary per importable vault item
/// (keys are consumed via the helpers below), or nil if the picked item isn't a Regram vault.
/// `password` unlocks an encrypted export; when it is missing or wrong, returns nil with an error
/// that `isPasswordError:` recognises, so the caller can prompt and retry.
/// Heavy (unzip + SQLite) — call off the main thread.
+ (nullable NSArray<NSDictionary *> *)vaultRowsFromPickedURL:(NSURL *)url
                                                    password:(nullable NSString *)password
                                                       error:(NSError **)error;

/// Whether `error` (from `vaultRowsFromPickedURL:password:error:`) means the export is encrypted and
/// the password was missing (`code == SPKZipPasswordRequiredErrorCode`) or wrong.
+ (BOOL)isPasswordError:(nullable NSError *)error;

/// Absolute path to the row's media file (already extracted to a local temp dir).
+ (nullable NSString *)filePathForRow:(NSDictionary *)row;

/// Save metadata (source, username/PK/full-name, media code/PK, dimensions, duration, dates) for a row.
+ (SPKGallerySaveMetadata *)metadataForRow:(NSDictionary *)row;

/// Media type for a row (from Regram's `ZTYPE`, falling back to the file extension).
+ (SPKGalleryMediaType)mediaTypeForRow:(NSDictionary *)row;

/// Whether the row was favorited in Regram.
+ (BOOL)isFavoriteRow:(NSDictionary *)row;

/// The row's Regram folder as a slash-joined path ("Trips/Rome"), or nil when it was unfiled.
+ (nullable NSString *)folderPathForRow:(NSDictionary *)row;

@end

NS_ASSUME_NONNULL_END
