//  SPKLanguagePackURLImporter.h
//  Sparkle — downloads a language pack over the network and installs it.
//
//  Installs through the EXISTING SPKLanguagePackManager importPackAtURL: path, so catalog,
//  code and format validation stay in one place. This class adds only the transport: an
//  HTTPS-only download, a size cap, optional sha256 pinning, progress, cancel, and temp-file
//  hygiene.
//
//  A pinned `expectedSHA256` (a catalog row, or an auto-update) decides what may be installed.
//  A pasted URL has no pin, so only the archive validation and string sanitizer stand behind it.
//  Where the host resolves is not checked: see the note in the implementation.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SPKLanguagePackURLImportErrorDomain;

typedef NS_ENUM(NSInteger, SPKLanguagePackURLImportErrorCode) {
    SPKLanguagePackURLImportErrorInvalidURL = 1,
    SPKLanguagePackURLImportErrorInsecureScheme,
    SPKLanguagePackURLImportErrorDisallowedHost,
    SPKLanguagePackURLImportErrorHTTPStatus,
    SPKLanguagePackURLImportErrorDownloadFailed,
    SPKLanguagePackURLImportErrorTooLarge,
    SPKLanguagePackURLImportErrorChecksumMismatch,
    SPKLanguagePackURLImportErrorCancelled,
};

@class SPKLanguagePack;

@interface SPKLanguagePackURLImporter : NSObject

/// Downloads the language-pack archive at `url`, verifies it, and installs it via
/// SPKLanguagePackManager. `expectedSHA256` (lowercase hex) is verified when non-nil.
/// `progress` (0..1) and
/// `completion` are always delivered on the main thread. Returns the live importer so the
/// caller can `-cancel` it; the importer keeps itself alive for the download's duration.
+ (instancetype)importFromURL:(NSURL *)url
               expectedSHA256:(nullable NSString *)expectedSHA256
                     progress:(nullable void (^)(double fraction))progress
                   completion:(void (^)(SPKLanguagePack *_Nullable pack, NSError *_Nullable error))completion;

/// Cancels an in-flight download; `completion` fires once with a Cancelled error.
- (void)cancel;

/// The hard byte ceiling for a downloaded pack (a real pack is ~50–300 KB).
@property (class, nonatomic, readonly) long long maximumPackBytes;

@end

NS_ASSUME_NONNULL_END
