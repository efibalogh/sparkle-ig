#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SPKLanguagePackErrorDomain;

typedef NS_ENUM(NSInteger, SPKLanguagePackErrorCode) {
    SPKLanguagePackErrorUnreadable = 1,
    SPKLanguagePackErrorNoCatalog,
    SPKLanguagePackErrorBadCode,
    SPKLanguagePackErrorEmptyCatalog,
    SPKLanguagePackErrorCopyFailed,
};

/// YES when `code` can name a language pack: a plain locale identifier, never a
/// path fragment.
FOUNDATION_EXPORT BOOL SPKLanguageCodeIsWellFormed(NSString *code);

/// Directory holding user-imported language packs, one `<code>.lproj` per
/// language. Created on demand.
///
/// Sparkle ships only reviewed languages, because a translation nobody who speaks the
/// language has read is worse than no translation: it looks official while
/// quietly describing the wrong setting. Every other catalog is community work,
/// distributed as a pack the user chooses to install, and promoted into the
/// shipped bundle once a native speaker has reviewed it.
FOUNDATION_EXPORT NSString *SPKLanguagePacksDirectory(void);

/// Path of an installed pack's `.lproj`, or nil when `code` is not installed.
/// Free of any localized lookup so `SPKStrings` can call it while resolving one.
FOUNDATION_EXPORT NSString *_Nullable SPKLanguagePackPathForCode(NSString *code);

/// Language codes with an installed pack, alphabetically.
FOUNDATION_EXPORT NSArray<NSString *> *SPKInstalledLanguagePackCodes(void);

/// Records where an installed pack came from, so a later catalog can tell a newer build of the
/// same language apart from the one on disk. `sha256` is nil for a pack imported from a file,
/// which is what marks it as not tracking any published pack.
FOUNDATION_EXPORT void SPKLanguagePackRecordProvenance(NSString *code, NSString *_Nullable sourceURL, NSString *_Nullable sha256);

/// The sha256 recorded when `code` was installed, or nil when it came from a file and so has no
/// published identity to compare a catalog row against.
FOUNDATION_EXPORT NSString *_Nullable SPKLanguagePackRecordedSHA256(NSString *code);

/// Forgets a pack's provenance. Called when the pack is deleted.
FOUNDATION_EXPORT void SPKLanguagePackForgetProvenance(NSString *code);

/// Deletes packs installed from the catalog whose language now ships in Sparkle.bundle, and returns
/// their codes. Such a pack would otherwise shadow the reviewed catalog forever: an installed pack
/// wins over a shipped one, and a promoted language is no longer published, so the pack never
/// refreshes. A pack imported from a file is kept, since that is how a reviewer previews corrections.
FOUNDATION_EXPORT NSArray<NSString *> *SPKLanguagePackRetireSuperseded(NSArray<NSString *> *shippedCodes);

/// One installed pack, as the settings UI presents it.
@interface SPKLanguagePack : NSObject
/// Localization code the pack provides, e.g. "de" or "pt-BR".
@property (nonatomic, copy) NSString *code;
/// Number of strings the pack defines.
@property (nonatomic, assign) NSUInteger stringCount;
/// How many of English's keys the pack covers, 0-100.
@property (nonatomic, assign) NSUInteger coveragePercent;
/// YES when the pack also carries plural rules (`Localizable.stringsdict`).
@property (nonatomic, assign) BOOL hasPlurals;
@property (nonatomic, assign) unsigned long long byteSize;
@end

@interface SPKLanguagePackManager : NSObject

/// Installed packs, sorted by code.
+ (NSArray<SPKLanguagePack *> *)installedPacks;

/// Installs the pack in the `.zip` at `url`, replacing any pack for the same
/// language. Returns nil with `error` set when the archive carries no usable
/// `<code>.lproj`.
///
/// A zip is the only shape the picker offers, because it is the only one that
/// survives the trip through it with its language intact: iOS refuses to let a
/// folder be selected next to file types, and it copies a picked file out of its
/// folder, so a bare Localizable.strings arrives saying nothing about what
/// language it is. A directory URL is still resolved if one ever arrives from
/// somewhere other than the picker.
+ (nullable SPKLanguagePack *)importPackAtURL:(NSURL *)url error:(NSError **)error;

/// Deletes the pack. If it was the selected language, the override is cleared and
/// the selection falls back to following the system, which is English again once
/// the last pack is gone.
+ (BOOL)removePack:(SPKLanguagePack *)pack error:(NSError **)error;

/// Writes `code`'s catalog to a temporary `Sparkle-<code>.zip` and returns its
/// path, for handing to a share sheet. Works for the shipped English catalog
/// (the template a new translation starts from) and for any installed pack.
+ (nullable NSString *)exportArchiveForLanguage:(NSString *)code error:(NSError **)error;

/// Total bytes of all installed packs.
+ (unsigned long long)installedPacksByteSize;

@end

NS_ASSUME_NONNULL_END
