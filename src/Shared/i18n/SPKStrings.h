#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Localized-string lookup for Sparkle.
///
/// Sparkle runs INSIDE Instagram's process, so `NSLocalizedString` (which reads
/// `[NSBundle mainBundle]` = Instagram) would never find our strings. Everything
/// here loads from Sparkle's OWN bundle instead.
///
/// Migration is `genstrings`-compatible: the `SPKLocalizedString(key, comment)`
/// function has the same shape as `NSLocalizedString`, so the base table is
/// generated with:  `genstrings -s SPKLocalizedString -o en.lproj **/*.{m,mm,x,xm}`
///
/// Keys are SEMANTIC (e.g. `FEED_LAYOUT_HIDE_STORIES_TRAY_TITLE`), matching the
/// a stable-key convention — stable when English copy is reworded, no paragraph-
/// length footer keys, no homograph collisions. `en.lproj` is the source of truth
/// for English. Sparkle also ships the catalogs a native speaker has reviewed; every
/// other language is a community pack the user imports. Lookup falls back active → English, so the raw
/// key is only ever returned if `en.lproj` itself is missing it, which
/// `tools/lint-i18n.py` exists to catch.
FOUNDATION_EXPORT NSString *SPKLocalizedString(NSString *key, NSString *_Nullable comment);
FOUNDATION_EXPORT NSString *SPKLocalizedPlural(NSString *key, NSInteger count);

/// Shorthand for call sites. Use stable semantic keys, never English source text.
/// Example: `SPKL(@"COMMON_ACTION_CANCEL")`.
#define SPKL(key)            SPKLocalizedString((key), nil)
#define SPKLC(key, comment)  SPKLocalizedString((key), (comment))
#define SPKLP(key, count)    SPKLocalizedPlural((key), (count))

@interface SPKStrings : NSObject

/// Look up `key` in the active language, falling back active → English → key.
+ (NSString *)localized:(NSString *)key;

/// Look up `key` in one specific language. Intended for migrations which need
/// to recognize previously persisted localized defaults.
+ (NSString *)localized:(NSString *)key forLanguage:(NSString *)language;

/// nil = follow the system/Instagram language. Otherwise an available code
/// (e.g. @"de", @"pt-BR"), shipped or imported. Persisted in Sparkle's prefs;
/// refreshes the cache. An override naming a language that is no longer
/// installed resolves back to English until its pack is imported again.
@property (class, nonatomic, copy, nullable) NSString *languageOverride;

/// Every language that can currently be selected: the catalogs Sparkle ships
/// (always including @"en") plus the community packs the user has imported.
+ (NSArray<NSString *> *)availableLanguages;

/// The same set, ordered for the language picker: English first, then the rest
/// alphabetically.
+ (NSArray<NSString *> *)supportedLanguages;

/// YES when `language` comes from an imported pack rather than the shipped bundle.
+ (BOOL)isImportedLanguage:(NSString *)language;

/// Call after installing or deleting a language pack. Drops the cached language
/// list and catalog bundles so the next lookup reads what is now on disk.
+ (void)languagePacksDidChange;

/// Resolve a requested language identifier to an available localization.
+ (nullable NSString *)matchAvailable:(NSString *)requested;

/// Effective language after applying the explicit override, Instagram's
/// preferred localization, the system language, and the English fallback.
+ (NSString *)activeLanguage;

@end

NS_ASSUME_NONNULL_END
