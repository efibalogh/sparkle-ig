#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../SPKResourceBundle.h"
#import "../SPKStoragePaths.h"
#import "../../Settings/SPKSettingsTransferManager.h"
#import "../../Utils.h"

NSString *const SPKLanguagePackErrorDomain = @"com.sparkle.languagepacks";
static NSString *const kSPKCatalogFileName = @"Localizable.strings";
static NSString *const kSPKPluralFileName = @"Localizable.stringsdict";

static NSError *SPKLanguagePackMakeError(SPKLanguagePackErrorCode code, NSString *message) {
    return [NSError errorWithDomain:SPKLanguagePackErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
}

// A code becomes a path component, so anything but a plain locale identifier is
// rejected outright rather than sanitized.
BOOL SPKLanguageCodeIsWellFormed(NSString *code) {
    if (code.length == 0 || code.length > 20)
        return NO;
    static NSCharacterSet *disallowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
        [allowed addCharactersInString:@"-_"];
        disallowed = [allowed invertedSet];
    });
    if ([code rangeOfCharacterFromSet:disallowed].location != NSNotFound)
        return NO;
    // "-Hans" or "de-" is a typo, not a locale, and "en" needs a letter first.
    return [[NSCharacterSet letterCharacterSet] characterIsMember:[code characterAtIndex:0]];
}

NSString *SPKLanguagePacksDirectory(void) {
    return [SPKStoragePaths languagePacksDirectory];
}

// Reads resolve the path without creating it. String lookup runs before the first
// view exists and asks which languages are installed, so the read path must not
// touch the file system beyond the question it was asked.
static NSString *SPKLanguagePacksRoot(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"Sparkle/Languages"];
}

NSString *SPKLanguagePackPathForCode(NSString *code) {
    if (!SPKLanguageCodeIsWellFormed(code))
        return nil;
    NSString *path = [SPKLanguagePacksRoot() stringByAppendingPathComponent:
                                                      [code stringByAppendingPathExtension:@"lproj"]];
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory)
        return nil;
    return [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:kSPKCatalogFileName]]
               ? path
               : nil;
}

NSArray<NSString *> *SPKInstalledLanguagePackCodes(void) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:SPKLanguagePacksRoot()
                                                                                     error:nil];
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"lproj"])
            continue;
        NSString *code = entry.stringByDeletingPathExtension;
        if (SPKLanguagePackPathForCode(code))
            [codes addObject:code];
    }
    [codes sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return codes;
}

#pragma mark - Provenance

// Which published pack an installed language currently is. Stored device-global alongside
// `interface_language` rather than through the account-scoped preference helpers, because the packs
// themselves live in one shared directory: a pack installed while one account is active is the same
// file every other account reads, so an account-scoped record of it would disagree with the disk.
static NSString *const kSPKLanguagePackProvenanceKey = @"language_pack_provenance";

static NSDictionary *SPKProvenanceRecords(void) {
    NSDictionary *records = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSPKLanguagePackProvenanceKey];
    return [records isKindOfClass:[NSDictionary class]] ? records : @{};
}

void SPKLanguagePackRecordProvenance(NSString *code, NSString *sourceURL, NSString *sha256) {
    if (code.length == 0)
        return;
    NSMutableDictionary *records = [SPKProvenanceRecords() mutableCopy];
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (sourceURL.length)
        entry[@"url"] = sourceURL;
    if (sha256.length)
        entry[@"sha256"] = sha256.lowercaseString;
    entry[@"installedAt"] = @([NSDate date].timeIntervalSince1970);
    records[code] = entry;
    [NSUserDefaults.standardUserDefaults setObject:records forKey:kSPKLanguagePackProvenanceKey];
}

NSString *SPKLanguagePackRecordedSHA256(NSString *code) {
    if (code.length == 0)
        return nil;
    NSDictionary *entry = SPKProvenanceRecords()[code];
    NSString *sha = [entry isKindOfClass:[NSDictionary class]] ? entry[@"sha256"] : nil;
    return [sha isKindOfClass:[NSString class]] && sha.length ? sha : nil;
}

void SPKLanguagePackForgetProvenance(NSString *code) {
    if (code.length == 0)
        return;
    NSMutableDictionary *records = [SPKProvenanceRecords() mutableCopy];
    if (!records[code])
        return;
    [records removeObjectForKey:code];
    [NSUserDefaults.standardUserDefaults setObject:records forKey:kSPKLanguagePackProvenanceKey];
}

NSArray<NSString *> *SPKLanguagePackRetireSuperseded(NSArray<NSString *> *shippedCodes) {
    NSMutableArray<NSString *> *retired = [NSMutableArray array];
    for (NSString *code in SPKInstalledLanguagePackCodes()) {
        if (![shippedCodes containsObject:code] || !SPKLanguagePackRecordedSHA256(code))
            continue;
        NSError *error = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:SPKLanguagePackPathForCode(code) error:&error]) {
            SPKWarnLog(@"i18n", @"Could not retire language pack %@: %@", code, error.localizedDescription);
            continue;
        }
        // The language override is left alone: the same code still resolves, now to the shipped catalog.
        SPKLanguagePackForgetProvenance(code);
        [retired addObject:code];
        SPKLog(@"i18n", @"Retired language pack %@, the language now ships with Sparkle", code);
    }
    return retired;
}

// A .strings file is an old-style property list, so the system parser reads it
// without a hand-written lexer and rejects a malformed one for us.
static NSDictionary<NSString *, NSString *> *SPKCatalogAtPath(NSString *path) {
    if (path.length == 0)
        return nil;
    NSDictionary *catalog = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    return [catalog isKindOfClass:[NSDictionary class]] ? catalog : nil;
}

#pragma mark - Catalog sanitizing

// Every value in a catalog reaches -[NSString stringWithFormat:] or
// +[NSString localizedStringWithFormat:] at some call site, with the arguments the English wording
// implies. A pack is data from outside the app, and since one can now arrive over the network
// rather than only from a file the user chose, a value that declares MORE conversions than English
// does would read arguments that were never passed: garbage pointers formatted as objects, which
// crashes at best and prints adjacent stack at worst. So a pack is normalized against English on
// install, and any entry that would change the argument list is dropped back to its English text.
//
// This runs once per install, never per lookup, so it costs nothing at runtime.

/// Ordered conversion signature of a format string, e.g. "%@ has %ld" → ("@", "ld"). Returns nil
/// when the string uses something a catalog has no business containing: `%n` writes through a
/// pointer argument, and `*` width/precision consumes an extra argument the call site never passes.
static NSArray<NSString *> *SPKFormatSignature(NSString *format) {
    if (format.length == 0)
        return @[];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSString *> *positional = [NSMutableDictionary dictionary];
    NSUInteger length = format.length;
    for (NSUInteger i = 0; i < length; i++) {
        if ([format characterAtIndex:i] != '%')
            continue;
        if (++i >= length)
            return nil;  // trailing '%'
        if ([format characterAtIndex:i] == '%')
            continue;  // literal percent

        // Optional explicit argument position, "%2$@".
        NSUInteger digitsStart = i, position = 0;
        while (i < length && isdigit([format characterAtIndex:i]))
            position = position * 10 + (NSUInteger)([format characterAtIndex:i++] - '0');
        BOOL hasPosition = (i < length && i > digitsStart && [format characterAtIndex:i] == '$');
        if (hasPosition)
            i++;
        else
            i = digitsStart;  // those digits were flags/width, not a position

        while (i < length && strchr("-+ #0'", [format characterAtIndex:i]))  // flags
            i++;
        while (i < length && isdigit([format characterAtIndex:i]))           // width
            i++;
        if (i < length && [format characterAtIndex:i] == '*')
            return nil;  // width from an argument
        if (i < length && [format characterAtIndex:i] == '.') {              // precision
            i++;
            if (i < length && [format characterAtIndex:i] == '*')
                return nil;
            while (i < length && isdigit([format characterAtIndex:i]))
                i++;
        }
        NSUInteger modifierStart = i;
        while (i < length && strchr("hlLqzjt", [format characterAtIndex:i]))  // length modifier
            i++;
        if (i >= length)
            return nil;  // ran out before the conversion character
        unichar conversion = [format characterAtIndex:i];
        if (conversion == 'n')
            return nil;  // writes through a pointer argument
        if (!strchr("diouxXeEfgGaAcsSpv@", conversion))
            return nil;  // not a conversion we recognise, so not one we can vouch for
        NSString *signature = [format substringWithRange:NSMakeRange(modifierStart, i - modifierStart + 1)];
        if (hasPosition) {
            if (position == 0)
                return nil;
            positional[@(position)] = signature;
        } else {
            [ordered addObject:signature];
        }
    }
    // A format mixing positional and implicit conversions is ambiguous; refuse rather than guess.
    if (positional.count > 0) {
        if (ordered.count > 0)
            return nil;
        NSArray<NSNumber *> *keys = [positional.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *key in keys)
            [ordered addObject:positional[key]];
    }
    return ordered;
}

/// English's catalog, the shape every pack is measured against.
static NSDictionary<NSString *, NSString *> *SPKEnglishCatalog(void) {
    static NSDictionary *english = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        english = SPKCatalogAtPath(SPKResourcePath([@"en.lproj" stringByAppendingPathComponent:kSPKCatalogFileName]));
    });
    return english;
}

/// Rewrites the installed catalog at `lprojPath` with every unsafe entry removed. An entry goes
/// when it is not a string pair, names a key English does not have, or would change the argument
/// list English established. Dropped keys fall back to English at lookup, which is exactly what an
/// untranslated key already does, so the cost of being strict here is only ever English text.
static NSUInteger SPKSanitizeInstalledCatalog(NSString *lprojPath) {
    NSString *catalogPath = [lprojPath stringByAppendingPathComponent:kSPKCatalogFileName];
    NSDictionary *catalog = SPKCatalogAtPath(catalogPath);
    NSDictionary<NSString *, NSString *> *english = SPKEnglishCatalog();
    if (catalog.count == 0 || english.count == 0)
        return 0;

    NSMutableDictionary<NSString *, NSString *> *clean = [NSMutableDictionary dictionaryWithCapacity:catalog.count];
    NSUInteger dropped = 0;
    for (id key in catalog) {
        id value = catalog[key];
        NSString *englishValue = [key isKindOfClass:[NSString class]] ? english[key] : nil;
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]] || !englishValue) {
            dropped++;
            continue;
        }
        NSArray<NSString *> *packSignature = SPKFormatSignature(value);
        NSArray<NSString *> *englishSignature = SPKFormatSignature(englishValue);
        if (!packSignature || !englishSignature || ![packSignature isEqualToArray:englishSignature]) {
            dropped++;
            continue;
        }
        clean[key] = value;
    }
    if (dropped == 0)
        return 0;

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:clean
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:NULL];
    if (data)
        [data writeToFile:catalogPath atomically:YES];
    return dropped;
}

/// Plural rules are format strings too, and reach +localizedStringWithFormat: the same way. English
/// owns which keys exist and what they take, so a pack's file is kept only when every key it defines
/// is one English defines with the same argument shape; otherwise it is removed and plurals fall
/// back to English wholesale. Partial repair is not worth it — a stringsdict is a handful of keys.
static BOOL SPKPluralFileIsSafe(NSString *pluralPath) {
    NSDictionary *pack = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:pluralPath] error:nil];
    if (![pack isKindOfClass:[NSDictionary class]])
        return NO;
    NSDictionary *english = [NSDictionary dictionaryWithContentsOfURL:
                                              [NSURL fileURLWithPath:SPKResourcePath([@"en.lproj" stringByAppendingPathComponent:kSPKPluralFileName])]
                                                               error:nil];
    if (![english isKindOfClass:[NSDictionary class]])
        return NO;

    for (id key in pack) {
        if (![key isKindOfClass:[NSString class]])
            return NO;
        NSDictionary *entry = pack[key], *englishEntry = english[key];
        if (![entry isKindOfClass:[NSDictionary class]] || ![englishEntry isKindOfClass:[NSDictionary class]])
            return NO;
        NSArray *signature = SPKFormatSignature(entry[@"NSStringLocalizedFormatKey"]);
        NSArray *englishSignature = SPKFormatSignature(englishEntry[@"NSStringLocalizedFormatKey"]);
        if (!signature || !englishSignature || ![signature isEqualToArray:englishSignature])
            return NO;
        // Each variable block spells out the conversion its plural cases use; anything but a plain
        // integer there would take an argument the count-based call site never supplies.
        for (id variable in entry) {
            if ([variable isEqual:@"NSStringLocalizedFormatKey"])
                continue;
            NSDictionary *rules = entry[variable];
            if (![rules isKindOfClass:[NSDictionary class]])
                return NO;
            NSString *valueType = rules[@"NSStringFormatValueTypeKey"];
            if (![valueType isKindOfClass:[NSString class]])
                return NO;
            static NSSet<NSString *> *allowedTypes;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                allowedTypes = [NSSet setWithArray:@[ @"d", @"i", @"u", @"ld", @"lu", @"lld", @"llu", @"zd", @"zu", @"jd", @"ju" ]];
            });
            if (![allowedTypes containsObject:valueType])
                return NO;
            for (id plural in rules) {
                if ([plural isEqual:@"NSStringFormatSpecTypeKey"] || [plural isEqual:@"NSStringFormatValueTypeKey"])
                    continue;
                NSString *text = rules[plural];
                if (![text isKindOfClass:[NSString class]])
                    return NO;
                NSArray *caseSignature = SPKFormatSignature(text);
                if (!caseSignature || caseSignature.count > 1)
                    return NO;
            }
        }
    }
    return YES;
}

/// A value no translation would change: a single technical token or brand name
/// ("Instagram", "VideoToolbox", "GIF", "1:1"), or a string made only of
/// placeholders and punctuation ("%@ - %@"). Counting these as untranslated made
/// a fully translated pack report in the nineties, which reads as a warning about
/// a catalog that has nothing wrong with it.
static BOOL SPKValueIsLanguageNeutral(NSString *value) {
    if (value.length == 0)
        return YES;
    if ([value rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location == NSNotFound)
        return YES;
    return [value rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound;
}

static NSUInteger SPKEnglishStringCount(void) {
    static NSUInteger count = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        count = SPKCatalogAtPath(SPKResourcePath([@"en.lproj" stringByAppendingPathComponent:kSPKCatalogFileName])).count;
    });
    return count;
}

@implementation SPKLanguagePack
@end

@implementation SPKLanguagePackManager

+ (SPKLanguagePack *)packAtPath:(NSString *)lprojPath code:(NSString *)code {
    NSDictionary<NSString *, NSString *> *catalog =
        SPKCatalogAtPath([lprojPath stringByAppendingPathComponent:kSPKCatalogFileName]);
    if (catalog.count == 0)
        return nil;

    SPKLanguagePack *pack = [SPKLanguagePack new];
    pack.code = code;
    pack.stringCount = catalog.count;
    pack.hasPlurals = [NSFileManager.defaultManager
        fileExistsAtPath:[lprojPath stringByAppendingPathComponent:kSPKPluralFileName]];
    pack.byteSize = [SPKStoragePaths sizeOfDirectory:lprojPath];

    NSUInteger englishCount = SPKEnglishStringCount();
    if (englishCount > 0) {
        NSDictionary<NSString *, NSString *> *english =
            SPKCatalogAtPath(SPKResourcePath([@"en.lproj" stringByAppendingPathComponent:kSPKCatalogFileName]));
        // A string left verbatim in English is not translated, so a pack seeded
        // from the English template reports what it really is rather than 100%.
        NSUInteger translated = 0;
        for (NSString *key in english) {
            NSString *value = catalog[key];
            if (value.length == 0)
                continue;
            if (![value isEqualToString:english[key]] || SPKValueIsLanguageNeutral(english[key]))
                translated++;
        }
        // Floor, so an all-but-one catalog never advertises itself as complete.
        pack.coveragePercent = (100 * translated) / englishCount;
    }
    return pack;
}

+ (NSArray<SPKLanguagePack *> *)installedPacks {
    NSMutableArray<SPKLanguagePack *> *packs = [NSMutableArray array];
    for (NSString *code in SPKInstalledLanguagePackCodes()) {
        SPKLanguagePack *pack = [self packAtPath:SPKLanguagePackPathForCode(code) code:code];
        if (pack)
            [packs addObject:pack];
    }
    return packs;
}

+ (unsigned long long)installedPacksByteSize {
    return [SPKStoragePaths sizeOfDirectory:SPKLanguagePacksRoot()];
}

#pragma mark - Import

/// First `<code>.lproj` holding a catalog anywhere under `root`, so an archive
/// zipped from a parent folder, or with the Finder's __MACOSX sidecar, still
/// resolves to the one directory that matters.
+ (nullable NSString *)firstCatalogDirectoryUnder:(NSString *)root {
    NSDirectoryEnumerator<NSString *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtPath:root];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *relative in enumerator) {
        if ([relative.pathComponents containsObject:@"__MACOSX"])
            continue;
        if (![relative.pathExtension isEqualToString:@"lproj"])
            continue;
        NSString *absolute = [root stringByAppendingPathComponent:relative];
        if ([NSFileManager.defaultManager fileExistsAtPath:[absolute stringByAppendingPathComponent:kSPKCatalogFileName]])
            [candidates addObject:absolute];
    }
    [candidates sortUsingSelector:@selector(compare:)];
    return candidates.firstObject;
}

/// Resolves whatever the user picked to the `.lproj` directory to install.
+ (nullable NSString *)catalogDirectoryForPickedPath:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        if (error)
            *error = SPKLanguagePackMakeError(SPKLanguagePackErrorUnreadable, SPKL(@"LANGUAGE_PACK_ERROR_UNREADABLE"));
        return nil;
    }

    if (isDirectory) {
        if ([path.pathExtension isEqualToString:@"lproj"] &&
            [fm fileExistsAtPath:[path stringByAppendingPathComponent:kSPKCatalogFileName]])
            return path;
        return [self firstCatalogDirectoryUnder:path];
    }

    if ([path.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
        NSError *expandError = nil;
        NSString *expanded = [SPKSettingsTransferManager expandZipArchiveAtURL:[NSURL fileURLWithPath:path]
                                                                         error:&expandError];
        if (expanded.length == 0) {
            if (error)
                *error = expandError ?: SPKLanguagePackMakeError(SPKLanguagePackErrorUnreadable,
                                                                 SPKL(@"LANGUAGE_PACK_ERROR_UNREADABLE"));
            return nil;
        }
        return [self firstCatalogDirectoryUnder:expanded];
    }

    return nil;
}

+ (SPKLanguagePack *)importPackAtURL:(NSURL *)url error:(NSError **)error {
    // The picker hands over a file outside the sandbox, so the security scope
    // has to be held for the whole read.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    @try {
        NSError *resolveError = nil;
        NSString *source = [self catalogDirectoryForPickedPath:url.path error:&resolveError];
        if (source.length == 0) {
            if (error)
                *error = resolveError ?: SPKLanguagePackMakeError(SPKLanguagePackErrorNoCatalog,
                                                                  SPKL(@"LANGUAGE_PACK_ERROR_NO_CATALOG"));
            return nil;
        }

        NSString *code = source.lastPathComponent.stringByDeletingPathExtension;
        if (!SPKLanguageCodeIsWellFormed(code)) {
            if (error)
                *error = SPKLanguagePackMakeError(SPKLanguagePackErrorBadCode,
                                                  [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_ERROR_BAD_CODE_FORMAT"), code]);
            return nil;
        }
        if (SPKCatalogAtPath([source stringByAppendingPathComponent:kSPKCatalogFileName]).count == 0) {
            if (error)
                *error = SPKLanguagePackMakeError(SPKLanguagePackErrorEmptyCatalog,
                                                  SPKL(@"LANGUAGE_PACK_ERROR_EMPTY_CATALOG"));
            return nil;
        }

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *destination = [SPKLanguagePacksDirectory()
            stringByAppendingPathComponent:[code stringByAppendingPathExtension:@"lproj"]];
        // Re-importing a corrected archive is the normal way a translator
        // iterates, so a pack for the same language is replaced, not refused.
        [fm removeItemAtPath:destination error:nil];

        NSError *copyError = nil;
        if (![fm copyItemAtPath:source toPath:destination error:&copyError]) {
            if (error)
                *error = SPKLanguagePackMakeError(SPKLanguagePackErrorCopyFailed, copyError.localizedDescription);
            return nil;
        }

        // Normalize before anything reads it: from here on the catalog is treated as Sparkle's own
        // strings, so it has to be unable to misuse the call sites that format it.
        NSUInteger dropped = SPKSanitizeInstalledCatalog(destination);
        if (dropped > 0)
            SPKWarnLog(@"i18n", @"Dropped %lu unsafe or unknown entr%@ from the %@ pack",
                       (unsigned long)dropped, dropped == 1 ? @"y" : @"ies", code);
        NSString *plurals = [destination stringByAppendingPathComponent:kSPKPluralFileName];
        if ([fm fileExistsAtPath:plurals] && !SPKPluralFileIsSafe(plurals)) {
            SPKWarnLog(@"i18n", @"Discarded the %@ pack's plural rules: they do not match English's arguments", code);
            [fm removeItemAtPath:plurals error:nil];
        }

        // Provisionally a file import, with no published identity. The network importer overwrites
        // this with the URL and hash it verified, which is what separates a pack that tracks a
        // release from one the user built themselves and must not have replaced under them.
        SPKLanguagePackRecordProvenance(code, nil, nil);

        [SPKStrings languagePacksDidChange];
        SPKLanguagePack *pack = [self packAtPath:destination code:code];
        SPKLog(@"i18n", @"Imported language pack %@ (%lu strings)", code, (unsigned long)pack.stringCount);
        return pack;
    } @finally {
        if (scoped)
            [url stopAccessingSecurityScopedResource];
    }
}

#pragma mark - Removal and export

+ (BOOL)removePack:(SPKLanguagePack *)pack error:(NSError **)error {
    NSString *path = SPKLanguagePackPathForCode(pack.code);
    if (path.length == 0)
        return YES;

    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&removeError]) {
        if (error)
            *error = removeError;
        return NO;
    }

    SPKLanguagePackForgetProvenance(pack.code);
    [SPKStrings languagePacksDidChange];
    // The selected language just stopped existing, so fall back to following the
    // system rather than leaving a dangling override behind.
    NSString *selected = [SPKStrings languageOverride];
    if ([selected isEqualToString:pack.code])
        [SPKStrings setLanguageOverride:nil];

    SPKLog(@"i18n", @"Removed language pack %@", pack.code);
    return YES;
}

+ (NSString *)exportArchiveForLanguage:(NSString *)code error:(NSError **)error {
    if (!SPKLanguageCodeIsWellFormed(code)) {
        if (error)
            *error = SPKLanguagePackMakeError(SPKLanguagePackErrorBadCode,
                                              [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_ERROR_BAD_CODE_FORMAT"), code]);
        return nil;
    }

    NSString *lprojName = [code stringByAppendingPathExtension:@"lproj"];
    NSString *source = SPKLanguagePackPathForCode(code)
                           ?: SPKResourcePath([lprojName stringByAppendingPathComponent:kSPKCatalogFileName])
                                  .stringByDeletingLastPathComponent;
    if (source.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:source]) {
        if (error)
            *error = SPKLanguagePackMakeError(SPKLanguagePackErrorNoCatalog, SPKL(@"LANGUAGE_PACK_ERROR_NO_CATALOG"));
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"SparkleLanguage-%@", NSUUID.UUID.UUIDString]];
    // The archive must not sit inside the directory being zipped.
    NSString *payload = [staging stringByAppendingPathComponent:@"Payload"];
    NSString *stagedCatalog = [payload stringByAppendingPathComponent:lprojName];
    if (![fm createDirectoryAtPath:stagedCatalog withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error)
            *error = SPKLanguagePackMakeError(SPKLanguagePackErrorCopyFailed, SPKL(@"LANGUAGE_PACK_ERROR_EXPORT_FAILED"));
        return nil;
    }
    for (NSString *fileName in @[ kSPKCatalogFileName, kSPKPluralFileName ]) {
        NSString *file = [source stringByAppendingPathComponent:fileName];
        if ([fm fileExistsAtPath:file])
            [fm copyItemAtPath:file toPath:[stagedCatalog stringByAppendingPathComponent:fileName] error:nil];
    }

    NSString *archive = [staging stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"Sparkle-%@.zip", code]];
    NSError *zipError = nil;
    if (![SPKSettingsTransferManager writeZipArchiveFromDirectory:payload toPath:archive error:&zipError]) {
        if (error)
            *error = zipError ?: SPKLanguagePackMakeError(SPKLanguagePackErrorCopyFailed,
                                                          SPKL(@"LANGUAGE_PACK_ERROR_EXPORT_FAILED"));
        return nil;
    }
    return archive;
}

@end
