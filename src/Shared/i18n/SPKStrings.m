#import "SPKStrings.h"
#import "SPKLanguagePack.h"
#import "../../Utils.h"
#import "../SPKResourceBundle.h"

// Persisted directly because this preference is intentionally device-global,
// unlike Sparkle's account-scoped feature preferences.
static NSString *const kSPKLanguageOverrideKey = @"interface_language";
static NSString *const kSPKStringsTable = @"Localizable";

static NSArray<NSString *> *spk_cachedAvailableLanguages = nil;

@implementation SPKStrings

+ (nullable NSBundle *)resourceBundle {
    return SPKResourceBundle();
}

#pragma mark - Language resolution

/// Codes shipped inside Sparkle.bundle. The split is read from the bundle so
/// promoting a reviewed community catalog stays a matter of moving its directory
/// in, with no code change.
+ (NSArray<NSString *> *)shippedLanguages {
    static NSArray<NSString *> *langs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *found = [NSMutableArray arrayWithObject:@"en"];
        NSBundle *bundle = [self resourceBundle];
        if (bundle) {
            NSArray<NSString *> *lprojs = [bundle pathsForResourcesOfType:@"lproj" inDirectory:nil];
            for (NSString *p in lprojs) {
                NSString *code = [[p lastPathComponent] stringByDeletingPathExtension];
                if (code.length > 0 && ![found containsObject:code] &&
                    ![code isEqualToString:@"Base"]) {
                    [found addObject:code];
                }
            }
        }
        langs = [found copy];
        // Before the first lookup resolves a language, so a superseded pack never gets read.
        if (SPKLanguagePackRetireSuperseded(langs).count > 0)
            [self flushCaches];
    });
    return langs;
}

+ (BOOL)isImportedLanguage:(NSString *)language {
    return language.length > 0 && ![[self shippedLanguages] containsObject:language] &&
           SPKLanguagePackPathForCode(language) != nil;
}

// Recomputed rather than cached for the lifetime of the process: a pack can be
// installed or deleted at any time, and the list feeds both the picker and every
// lookup's language resolution.
+ (NSArray<NSString *> *)availableLanguages {
    @synchronized (self) {
        if (!spk_cachedAvailableLanguages) {
            NSMutableArray<NSString *> *found = [[self shippedLanguages] mutableCopy];
            for (NSString *code in SPKInstalledLanguagePackCodes()) {
                if (![found containsObject:code])
                    [found addObject:code];
            }
            spk_cachedAvailableLanguages = [found copy];
        }
        return spk_cachedAvailableLanguages;
    }
}

+ (NSArray<NSString *> *)supportedLanguages {
    NSMutableArray<NSString *> *ordered = [[self availableLanguages] mutableCopy];
    [ordered removeObject:@"en"];
    [ordered sortUsingSelector:@selector(caseInsensitiveCompare:)];
    [ordered insertObject:@"en" atIndex:0];
    return ordered;
}

/// Best shipped code for a requested locale id, e.g. "de-DE"→"de", "pt"→"pt-BR",
/// "zh-Hans-CN"→"zh-Hans". Returns nil if nothing matches.
+ (nullable NSString *)matchAvailable:(NSString *)requested {
    if (requested.length == 0) return nil;
    NSArray<NSString *> *available = [self availableLanguages];
    // 1. exact (case-insensitive)
    for (NSString *code in available) {
        if ([code caseInsensitiveCompare:requested] == NSOrderedSame) return code;
    }
    // 2. script-qualified match, e.g. requested "zh-Hans-CN" vs available "zh-Hans"
    for (NSString *code in available) {
        if ([[requested lowercaseString] hasPrefix:[[code lowercaseString] stringByAppendingString:@"-"]])
            return code;
    }
    // 3. base-language match, e.g. requested "de-DE" or "pt" vs available "de"/"pt-BR"
    NSString *base = [[requested componentsSeparatedByString:@"-"] firstObject].lowercaseString;
    for (NSString *code in available) {  // prefer an exact base like "de"
        if ([code.lowercaseString isEqualToString:base]) return code;
    }
    for (NSString *code in available) {  // then a regional variant like "pt-BR"
        if ([code.lowercaseString hasPrefix:[base stringByAppendingString:@"-"]]) return code;
    }
    return nil;
}

+ (NSString *)activeLanguage {
    NSString *override = [self languageOverride];
    if (override.length > 0) {
        NSString *m = [self matchAvailable:override];
        if (m) return m;
    }
    NSMutableOrderedSet<NSString *> *preferences = [NSMutableOrderedSet orderedSet];
    [preferences addObjectsFromArray:NSBundle.mainBundle.preferredLocalizations ?: @[]];
    [preferences addObjectsFromArray:NSLocale.preferredLanguages ?: @[]];
    for (NSString *pref in preferences) {
        NSString *m = [self matchAvailable:pref];
        if (m) return m;
    }
    return @"en";
}

#pragma mark - Override pref

+ (nullable NSString *)languageOverride {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:kSPKLanguageOverrideKey];
    return value.length > 0 && ![value isEqualToString:@"auto"] ? value : nil;
}

+ (void)setLanguageOverride:(nullable NSString *)langCode {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (langCode.length > 0) {
        [d setObject:langCode forKey:kSPKLanguageOverrideKey];
    } else {
        [d removeObjectForKey:kSPKLanguageOverrideKey];
    }
    [self flushCaches];
}

#pragma mark - Lookup

/// Cache of language-code → its .lproj sub-bundle. Reset when the override changes.
+ (NSMutableDictionary<NSString *, NSBundle *> *)lprojCache {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (void)flushCaches {
    @synchronized (self) { [[self lprojCache] removeAllObjects]; }
}

+ (void)languagePacksDidChange {
    @synchronized (self) { spk_cachedAvailableLanguages = nil; }
    [self flushCaches];
}

+ (nullable NSBundle *)lprojBundleForLanguage:(NSString *)lang {
    if (lang.length == 0) return nil;
    @synchronized (self) {
        NSBundle *cached = [self lprojCache][lang];
        if (cached) return cached;
        // An imported pack wins over a shipped catalog of the same language, so a
        // reviewer can preview their corrections against the build that ships it.
        NSString *path = SPKLanguagePackPathForCode(lang);
        if (!path) {
            NSBundle *root = [self resourceBundle];
            path = [root pathForResource:lang ofType:@"lproj"];
        }
        NSBundle *b = path ? [NSBundle bundleWithPath:path] : nil;
        if (b) [self lprojCache][lang] = b;
        return b;
    }
}

+ (NSString *)localized:(NSString *)key {
    if (key.length == 0) return key;

    return [self localized:key forLanguage:[self activeLanguage]];
}

+ (NSString *)localized:(NSString *)key forLanguage:(NSString *)language {
    if (key.length == 0) return key;

    // Requested language, then English fallback.
    NSString *matchedLanguage = [self matchAvailable:language] ?: @"en";
    NSBundle *active = [self lprojBundleForLanguage:matchedLanguage];
    if (active) {
        NSString *v = [active localizedStringForKey:key value:@"MISS" table:kSPKStringsTable];
        if (![v isEqualToString:@"MISS"]) return v;
    }
    NSBundle *en = [self lprojBundleForLanguage:@"en"];
    if (en) {
        NSString *v = [en localizedStringForKey:key value:@"MISS" table:kSPKStringsTable];
        if (![v isEqualToString:@"MISS"]) return v;
    }
    // Catastrophic fallback. The linter guarantees English contains every key.
    return key;
}

@end

NSString *SPKLocalizedString(NSString *key, NSString *comment) {
    (void)comment; // consumed by `genstrings`, not at runtime
    return [SPKStrings localized:key];
}

NSString *SPKLocalizedPlural(NSString *key, NSInteger count) {
    NSString *format = [SPKStrings localized:key];
    return [NSString localizedStringWithFormat:format, count];
}
