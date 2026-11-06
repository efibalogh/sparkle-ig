#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Error code (domain `SparkleSettingsTransfer`) for an archive past an expansion limit.
FOUNDATION_EXPORT const NSInteger SPKZipExpandLimitErrorCode;

@interface SPKSettingsTransferManager : NSObject

+ (instancetype)sharedManager;
- (void)exportFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer;
- (void)importFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer;
- (void)resetAllSettingsFromController:(UIViewController *)controller;

/// Expands a picked `.zip` (STORED method 0 or DEFLATE method 8) into a fresh temporary
/// directory and returns its root path, or nil on failure. Exposed so other importers
/// (e.g. the Regram media-vault importer) can reuse Sparkle's dependency-free unzip reader.
/// Runs synchronously — call off the main thread.
+ (nullable NSString *)expandZipArchiveAtURL:(NSURL *)archiveURL error:(NSError **)error;

/// Same, for archives from an untrusted source: refuses one that declares more than
/// `maximumBytes` of uncompressed data or more than `maximumEntries` entries, failing with
/// `SPKZipExpandLimitErrorCode` before writing past the limit. Each entry is always held to its
/// declared size, so the declared total is the real ceiling. A failed expansion leaves nothing behind.
+ (nullable NSString *)expandZipArchiveAtURL:(NSURL *)archiveURL
                    maximumUncompressedBytes:(unsigned long long)maximumBytes
                              maximumEntries:(NSUInteger)maximumEntries
                                       error:(NSError **)error;

/// Writes every file under `directory` into a STORED `.zip` at `zipPath`. The
/// counterpart of `expandZipArchiveAtURL:error:`, exposed for the same reason:
/// small exports (a language pack, say) should not carry a second zip writer.
/// Runs synchronously — call off the main thread.
+ (BOOL)writeZipArchiveFromDirectory:(NSString *)directory toPath:(NSString *)zipPath error:(NSError **)error;

// Restores a single grouped, multi-key configuration (e.g. Advanced Encoding, a
// surface's Action Button layout) to its built-in defaults for the active account,
// leaving all other preferences — and other accounts' overrides — untouched. Confirms
// first; no restart is needed since these configs are read at call time. `onReset`
// runs on the main thread after the keys are cleared so the page can refresh live.
- (void)resetConfigurationGroupFromController:(UIViewController *)controller
                                        title:(NSString *)title
                                      message:(NSString *)message
                                 confirmTitle:(NSString *)confirmTitle
                                         keys:(NSArray<NSString *> *)keys
                                      onReset:(void (^ _Nullable)(void))onReset;

@end

NS_ASSUME_NONNULL_END
