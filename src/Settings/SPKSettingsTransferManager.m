#import "SPKSettingsTransferManager.h"
#import "SPKStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <compression.h>

#import "../App/SPKCore.h"
#import "../App/SPKPreferenceMigrations.h"
#import "../Features/Messages/DeletedMessagesLog/SPKDeletedMessagesStorage.h"
#import "../Features/Profile/ProfileAnalyzer/SPKProfileAnalyzerStorage.h"
#import "../Shared/Account/SPKAccountManager.h"
#import "../Shared/Gallery/SPKGalleryCoreDataStack.h"
#import "../Shared/Gallery/SPKGalleryManager.h"
#import "../Shared/Gallery/SPKGalleryPaths.h"
#import "../Shared/Settings/SPKSettingsLockManager.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Utils.h"
#import "SPKAppIconCatalog.h"
#import "SPKPreferenceAvailability.h"
#import "TweakSettings.h"

typedef NS_ENUM(NSInteger, SPKTransferAccountScope) {
    SPKTransferAccountScopeAllAccounts = 0,    // global + every account's overrides
    SPKTransferAccountScopeCurrentAccount = 1, // global + the active account's overrides
};

@interface SPKSettingsTransferManager () <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *presentingController;
@property (nonatomic, strong) UIDocumentPickerViewController *activeDocumentPicker;
@property (nonatomic, assign) BOOL pendingImportSettings;
@property (nonatomic, assign) BOOL pendingImportGallery;
@property (nonatomic, assign) BOOL pendingImportDeletedMessages;
@property (nonatomic, assign) BOOL pendingImportProfileAnalyzer;
@property (nonatomic, assign) BOOL isImportMode;
- (void)exportFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer settingsScope:(SPKTransferAccountScope)settingsScope;
@end

// Serial queue for the heavy file/zip work so export/import never block the UI.
static dispatch_queue_t SPKTransferWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.sparkle.sparkle.settings-transfer", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *SPKTemporaryTransferRoot(NSString *suffix) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sparkle-transfer-%@-%@", suffix, NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSArray<SPKSetting *> *SPKFlattenSettingsRowsFromSections(NSArray *sections) {
    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
    for (NSDictionary *section in sections) {
        NSArray *sectionRows = [section[@"rows"] isKindOfClass:[NSArray class]] ? section[@"rows"] : @[];
        for (SPKSetting *row in sectionRows) {
            if (![row isKindOfClass:[SPKSetting class]])
                continue;
            [rows addObject:row];
            if (row.navSections.count > 0) {
                [rows addObjectsFromArray:SPKFlattenSettingsRowsFromSections(row.navSections)];
            }
        }
    }
    return rows;
}

static void SPKAddPreferenceKeysFromMenu(UIMenu *menu, NSMutableSet<NSString *> *keys) {
    for (UIMenuElement *element in menu.children ?: @[]) {
        if ([element isKindOfClass:[UIMenu class]]) {
            SPKAddPreferenceKeysFromMenu((UIMenu *)element, keys);
            continue;
        }

        if (![element isKindOfClass:[UICommand class]])
            continue;
        NSDictionary *propertyList = ((UICommand *)element).propertyList;
        NSString *defaultsKey = [propertyList[@"defaultsKey"] isKindOfClass:[NSString class]] ? propertyList[@"defaultsKey"] : nil;
        if (defaultsKey.length > 0) {
            [keys addObject:defaultsKey];
        }
    }
}

static BOOL SPKIsSPKPreferenceKey(NSString *key) {
    if (key.length == 0)
        return NO;

    static NSSet<NSString *> *exactKeys;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactKeys = [NSSet setWithArray:@[
            @"app_first_run"
        ]];
        // Every Sparkle surface prefix. Keep this complete — a missing prefix means
        // user-set keys of that group that aren't registered defaults / settings rows
        // silently fall out of export (and per-account variants too). Sparkle-specific
        // prefixes only; avoid generic ones (app_, dm_, enable_) that IG might also use.
        prefixes = @[
            @"feed_",
            @"general_",
            @"gallery_",
            @"interface_",
            @"msgs_",
            @"notifs_",
            @"profile_",
            @"reels_",
            @"stories_",
            @"tools_",
            @"downloads_",
            @"instants_",
            @"trim_",
            @"main_"
        ];
    });

    if ([exactKeys containsObject:key])
        return YES;
    for (NSString *prefix in prefixes) {
        if ([key hasPrefix:prefix])
            return YES;
    }
    return NO;
}

// Per-account override keys are "u_<pk>_<baseKey>" (see SPKEffectivePreferenceKey in
// Utils.m); pk is the numeric IG user PK. Parses one out, rejecting anything else.
static BOOL SPKParsePerAccountKey(NSString *key, NSString *_Nullable *_Nullable pkOut, NSString *_Nullable *_Nullable baseOut) {
    if (![key hasPrefix:@"u_"] || key.length < 4)
        return NO;
    NSString *rest = [key substringFromIndex:2];
    NSRange sep = [rest rangeOfString:@"_"];
    if (sep.location == NSNotFound || sep.location == 0)
        return NO;
    NSString *pk = [rest substringToIndex:sep.location];
    // pk must be all digits so we never mistake an unrelated "u_*" key for ours.
    if ([pk rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
        return NO;
    NSString *base = [rest substringFromIndex:sep.location + 1];
    if (base.length == 0)
        return NO;
    if (pkOut)
        *pkOut = pk;
    if (baseOut)
        *baseOut = base;
    return YES;
}

// Transient / device-local state that must never travel between installs:
// crash-recovery safe mode and the startup profiling flag. Exporting these
// could, e.g., drop a fresh install straight into safe mode.
static NSSet<NSString *> *SPKTransferExcludedKeys(void) {
    static NSSet<NSString *> *excluded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[
            @"app_safe_startup",
            @"app_startup_profiling",
            // Cached server state and a dev-only switch, not user settings.
            @"profile_account_privacy_cache",
            @"dev_account_privacy_simulate",
            SPKPreferenceMigrationsCompletedKey
        ]];
    });
    return excluded;
}

static NSSet<NSString *> *SPKExportedPreferenceKeys(void) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];

    // Every key registered as an Sparkle default is, by construction, one of
    // ours — include them all rather than prefix-filtering. The old prefix
    // allowlist silently dropped whole feature groups whose keys don't start
    // with a "surface" prefix (downloads_, instants_, trim_, app_first_run, ...),
    // which is why those settings were lost across export/import.
    for (NSString *key in SPKCoreRegisteredDefaults()) {
        [keys addObject:key];
    }

    for (SPKSetting *row in SPKFlattenSettingsRowsFromSections([SPKTweakSettings sections])) {
        if (row.defaultsKey.length > 0)
            [keys addObject:row.defaultsKey];
        if (row.mutuallyExclusiveDefaultsKey.length > 0)
            [keys addObject:row.mutuallyExclusiveDefaultsKey];
        if (row.baseMenu)
            SPKAddPreferenceKeysFromMenu(row.baseMenu, keys);
    }

    [keys addObjectsFromArray:@[
        @"app_first_run",
        @"gallery_folders",
        @"gallery_sort_mode",
        @"gallery_view_mode",
        @"general_cache_auto_clear",
        @"general_cache_last_cleared_at",
        // Runtime-only prefs whose keys use a non-surface prefix, so they are
        // neither registered as defaults nor caught by the prefix scan below.
        @"dm_log_date_format"
    ]];

    NSDictionary *allPrefs = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in allPrefs) {
        if (SPKIsSPKPreferenceKey(key)) {
            [keys addObject:key];
        }
    }

    [keys minusSet:SPKTransferExcludedKeys()];
    return keys;
}

// Every per-account override key ("u_<pk>_<base>") currently in defaults whose base is
// one of ours, filtered to the requested scope. The base allowlist (SPKExportedPreferenceKeys
// ∪ SPKIsSPKPreferenceKey) is why the SPKIsSPKPreferenceKey prefix list must stay complete.
static NSSet<NSString *> *SPKPerAccountOverrideKeys(SPKTransferAccountScope scope, NSString *currentPK) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    NSSet<NSString *> *base = SPKExportedPreferenceKeys();
    NSSet<NSString *> *excluded = SPKTransferExcludedKeys();
    NSDictionary *allPrefs = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in allPrefs) {
        NSString *pk = nil, *baseKey = nil;
        if (!SPKParsePerAccountKey(key, &pk, &baseKey))
            continue;
        if (![base containsObject:baseKey] && !SPKIsSPKPreferenceKey(baseKey))
            continue;
        if ([excluded containsObject:baseKey])
            continue;
        if (scope == SPKTransferAccountScopeCurrentAccount && ![pk isEqualToString:(currentPK ?: @"")])
            continue;
        [keys addObject:key];
    }
    return keys;
}

// Global/base keys + the in-scope per-account overrides.
static NSSet<NSString *> *SPKExportedPreferenceKeysForScope(SPKTransferAccountScope scope, NSString *currentPK) {
    NSMutableSet<NSString *> *keys = [NSMutableSet setWithSet:SPKExportedPreferenceKeys()];
    [keys unionSet:SPKPerAccountOverrideKeys(scope, currentPK)];
    return keys;
}

static NSDictionary *SPKPreferencesSnapshotForScope(SPKTransferAccountScope scope, NSString *currentPK) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];

    if (scope == SPKTransferAccountScopeCurrentAccount) {
        // "This account" = FLATTEN: capture the active account's *effective* values
        // (per-account override → global → default) for every per-account-capable key,
        // stored under base keys. Device-global keys are excluded — they aren't this
        // account's settings. On import these are re-homed into the importing account's
        // namespace, so other accounts are never touched.
        for (NSString *key in SPKExportedPreferenceKeys()) {
            if (SPKPreferenceKeyIsGlobal(key))
                continue;
            id value = SPKPreferenceObjectForKey(key);
            if (value)
                snapshot[key] = value;
        }
        return snapshot;
    }

    // "All accounts" = verbatim: base/global keys + every account's overrides as stored.
    NSDictionary *allPrefs = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in SPKExportedPreferenceKeysForScope(scope, currentPK)) {
        id value = allPrefs[key];
        if (value)
            snapshot[key] = value;
    }
    return snapshot;
}

static UIViewController *SPKDocumentPickerPresenter(UIViewController *preferredController) {
    UIViewController *presenter = preferredController;
    if (!presenter || !presenter.view.window) {
        presenter = topMostController();
    }
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if ([presenter isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)presenter).visibleViewController;
        if (visible)
            presenter = visible;
    }
    return presenter ?: topMostController();
}

static BOOL SPKIsValidSettingsTransferBundleRoot(NSString *bundleRoot);
static NSString *SPKResolvedSettingsTransferBundleRoot(NSURL *pickedURL);

static void SPKAppendUInt16LE(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = {(uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void SPKAppendUInt32LE(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 24) & 0xff)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t SPKReadUInt16LE(const uint8_t *bytes, NSUInteger offset) {
    return (uint16_t)bytes[offset] | ((uint16_t)bytes[offset + 1] << 8);
}

static uint32_t SPKReadUInt32LE(const uint8_t *bytes, NSUInteger offset) {
    return (uint32_t)bytes[offset] |
           ((uint32_t)bytes[offset + 1] << 8) |
           ((uint32_t)bytes[offset + 2] << 16) |
           ((uint32_t)bytes[offset + 3] << 24);
}

static uint64_t SPKReadUInt64LE(const uint8_t *bytes, NSUInteger offset) {
    return (uint64_t)SPKReadUInt32LE(bytes, offset) |
           ((uint64_t)SPKReadUInt32LE(bytes, offset + 4) << 32);
}

static uint32_t SPKZipCRC32ForBytes(uint32_t crc, const uint8_t *bytes, NSUInteger length) {
    static uint32_t table[256];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int j = 0; j < 8; j++) {
                c = (c & 1) ? (0xedb88320U ^ (c >> 1)) : (c >> 1);
            }
            table[i] = c;
        }
    });

    crc = crc ^ 0xffffffffU;
    for (NSUInteger i = 0; i < length; i++) {
        crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    }
    return crc ^ 0xffffffffU;
}

static void SPKZipCurrentDOSTimeDate(uint16_t *timeOut, uint16_t *dateOut) {
    NSDateComponents *components = [[NSCalendar currentCalendar] components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[NSDate date]];
    NSInteger year = MAX(1980, MIN(2107, components.year));
    if (timeOut)
        *timeOut = (uint16_t)((components.hour << 11) | (components.minute << 5) | (components.second / 2));
    if (dateOut)
        *dateOut = (uint16_t)(((year - 1980) << 9) | (components.month << 5) | components.day);
}

@interface SPKZipEntry : NSObject
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, copy) NSString *sourcePath;
@property (nonatomic, assign) uint32_t crc32;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t localHeaderOffset;
@property (nonatomic, assign) uint16_t dosTime;
@property (nonatomic, assign) uint16_t dosDate;
@end

@implementation SPKZipEntry
@end

static NSArray<SPKZipEntry *> *SPKZipEntriesForDirectory(NSString *root, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    NSMutableArray<SPKZipEntry *> *entries = [NSMutableArray array];

    for (NSString *relativePath in enumerator) {
        NSString *sourcePath = [root stringByAppendingPathComponent:relativePath];
        NSNumber *isDirectory = nil;
        NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
        [sourceURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (isDirectory.boolValue)
            continue;

        NSDictionary *attrs = [fm attributesOfItemAtPath:sourcePath error:error];
        if (!attrs)
            return nil;
        unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
        if (fileSize > UINT32_MAX) {
            if (error) {
                *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                             code:2001
                                         userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_FILE_TOO_LARGE_ERROR")}];
            }
            return nil;
        }

        SPKZipEntry *entry = [SPKZipEntry new];
        entry.relativePath = [relativePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        entry.sourcePath = sourcePath;
        entry.size = (uint32_t)fileSize;
        if ([entry.relativePath dataUsingEncoding:NSUTF8StringEncoding].length > UINT16_MAX) {
            if (error) {
                *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                             code:2003
                                         userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_PATH_TOO_LONG_ERROR")}];
            }
            return nil;
        }
        [entries addObject:entry];
    }

    [entries sortUsingComparator:^NSComparisonResult(SPKZipEntry *a, SPKZipEntry *b) {
        return [a.relativePath compare:b.relativePath];
    }];
    if (entries.count > UINT16_MAX) {
        if (error) {
            *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                         code:2004
                                     userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_TOO_MANY_FILES_ERROR")}];
        }
        return nil;
    }
    return entries;
}

static BOOL SPKWriteStoredZipFromDirectory(NSString *root, NSString *zipPath, NSError **error) {
    NSArray<SPKZipEntry *> *entries = SPKZipEntriesForDirectory(root, error);
    if (!entries)
        return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [zipPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:zipPath contents:nil attributes:nil];
    NSFileHandle *zip = [NSFileHandle fileHandleForWritingAtPath:zipPath];
    if (!zip)
        return NO;

    uint16_t dosTime = 0;
    uint16_t dosDate = 0;
    SPKZipCurrentDOSTimeDate(&dosTime, &dosDate);

    for (SPKZipEntry *entry in entries) {
        entry.dosTime = dosTime;
        entry.dosDate = dosDate;
        if ([zip offsetInFile] > UINT32_MAX) {
            if (error) {
                *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                             code:2005
                                         userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_TOO_LARGE_ERROR")}];
            }
            [zip closeFile];
            return NO;
        }
        entry.localHeaderOffset = (uint32_t)[zip offsetInFile];
        NSData *nameData = [entry.relativePath dataUsingEncoding:NSUTF8StringEncoding];

        NSMutableData *local = [NSMutableData data];
        SPKAppendUInt32LE(local, 0x04034b50);
        SPKAppendUInt16LE(local, 20);
        SPKAppendUInt16LE(local, 0);
        SPKAppendUInt16LE(local, 0);
        SPKAppendUInt16LE(local, entry.dosTime);
        SPKAppendUInt16LE(local, entry.dosDate);
        SPKAppendUInt32LE(local, 0);
        SPKAppendUInt32LE(local, entry.size);
        SPKAppendUInt32LE(local, entry.size);
        SPKAppendUInt16LE(local, (uint16_t)nameData.length);
        SPKAppendUInt16LE(local, 0);
        [local appendData:nameData];
        [zip writeData:local];

        NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:entry.sourcePath];
        if (!input) {
            if (error) {
                *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                             code:2006
                                         userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_ZIP_UNREADABLE_FILE_FORMAT"), entry.relativePath]}];
            }
            [zip closeFile];
            return NO;
        }
        uint32_t crc = 0;
        @autoreleasepool {
            while (true) {
                NSData *chunk = [input readDataOfLength:1024 * 1024];
                if (chunk.length == 0)
                    break;
                crc = SPKZipCRC32ForBytes(crc, chunk.bytes, chunk.length);
                [zip writeData:chunk];
            }
        }
        [input closeFile];
        entry.crc32 = crc;

        unsigned long long returnOffset = [zip offsetInFile];
        [zip seekToFileOffset:entry.localHeaderOffset + 14];
        NSMutableData *sizes = [NSMutableData data];
        SPKAppendUInt32LE(sizes, entry.crc32);
        SPKAppendUInt32LE(sizes, entry.size);
        SPKAppendUInt32LE(sizes, entry.size);
        [zip writeData:sizes];
        [zip seekToFileOffset:returnOffset];
    }

    if ([zip offsetInFile] > UINT32_MAX) {
        if (error) {
            *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                         code:2005
                                     userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_TOO_LARGE_ERROR")}];
        }
        [zip closeFile];
        return NO;
    }
    uint32_t centralOffset = (uint32_t)[zip offsetInFile];
    NSMutableData *central = [NSMutableData data];
    for (SPKZipEntry *entry in entries) {
        NSData *nameData = [entry.relativePath dataUsingEncoding:NSUTF8StringEncoding];
        SPKAppendUInt32LE(central, 0x02014b50);
        SPKAppendUInt16LE(central, 20);
        SPKAppendUInt16LE(central, 20);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt16LE(central, entry.dosTime);
        SPKAppendUInt16LE(central, entry.dosDate);
        SPKAppendUInt32LE(central, entry.crc32);
        SPKAppendUInt32LE(central, entry.size);
        SPKAppendUInt32LE(central, entry.size);
        SPKAppendUInt16LE(central, (uint16_t)nameData.length);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt16LE(central, 0);
        SPKAppendUInt32LE(central, 0);
        SPKAppendUInt32LE(central, entry.localHeaderOffset);
        [central appendData:nameData];
    }
    [zip writeData:central];

    uint32_t centralSize = (uint32_t)central.length;
    NSMutableData *eocd = [NSMutableData data];
    SPKAppendUInt32LE(eocd, 0x06054b50);
    SPKAppendUInt16LE(eocd, 0);
    SPKAppendUInt16LE(eocd, 0);
    SPKAppendUInt16LE(eocd, (uint16_t)entries.count);
    SPKAppendUInt16LE(eocd, (uint16_t)entries.count);
    SPKAppendUInt32LE(eocd, centralSize);
    SPKAppendUInt32LE(eocd, centralOffset);
    SPKAppendUInt16LE(eocd, 0);
    [zip writeData:eocd];
    [zip closeFile];
    return YES;
}

static BOOL SPKIsSafeZipEntryName(NSString *name) {
    if (name.length == 0 || [name hasPrefix:@"/"] || [name containsString:@"\\"])
        return NO;
    for (NSString *part in [name componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@".."])
            return NO;
    }
    return YES;
}

// Inflates a raw DEFLATE blob (`src`, srcLen bytes) into `outputPath`, expecting
// `expectedOut` bytes. Uses libcompression's zlib (raw) decoder. Returns NO on
// failure or a length mismatch.
static BOOL SPKInflateRawDeflateToFile(const uint8_t *src, size_t srcLen, size_t expectedOut, NSString *outputPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:outputPath contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!out)
        return NO;

    compression_stream stream;
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) {
        [out closeFile];
        return NO;
    }
    stream.src_ptr = src;
    stream.src_size = srcLen;

    const size_t dstCap = 256 * 1024;
    uint8_t *dst = malloc(dstCap);
    if (!dst) {
        compression_stream_destroy(&stream);
        [out closeFile];
        return NO;
    }

    BOOL ok = YES;
    size_t totalOut = 0;
    while (YES) {
        stream.dst_ptr = dst;
        stream.dst_size = dstCap;
        compression_status status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        size_t produced = dstCap - stream.dst_size;
        if (produced > 0) {
            @autoreleasepool {
                [out writeData:[NSData dataWithBytesNoCopy:dst length:produced freeWhenDone:NO]];
            }
            totalOut += produced;
        }
        if (status == COMPRESSION_STATUS_END)
            break;
        if (status != COMPRESSION_STATUS_OK) {
            ok = NO;
            break;
        }
    }

    free(dst);
    compression_stream_destroy(&stream);
    [out closeFile];
    if (ok && expectedOut > 0 && totalOut != expectedOut)
        ok = NO;
    return ok;
}

// Expands a zip created by our own exporter (stored, method 0) as well as zips
// re-compressed by Files / iCloud / desktop tools (DEFLATE, method 8).
// Extracts every entry of a zip (STORED method 0 or DEFLATE method 8, incl. ZIP64) into a fresh
// temporary directory and returns that directory — a *generic* unzip with no assumptions about the
// contents. `SPKExpandStoredZipSettingsTransferArchive` layers Sparkle-bundle resolution on top.
static NSString *SPKExpandZipArchiveRaw(NSURL *archiveURL, NSError **error) {
    NSData *zipData = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:error];
    if (zipData.length < 22)
        return nil;

    const uint8_t *bytes = zipData.bytes;
    NSInteger eocdOffset = -1;
    for (NSInteger i = (NSInteger)zipData.length - 22; i >= 0 && i >= (NSInteger)zipData.length - 65557; i--) {
        if (SPKReadUInt32LE(bytes, (NSUInteger)i) == 0x06054b50) {
            eocdOffset = i;
            break;
        }
    }
    if (eocdOffset < 0)
        return nil;

    uint16_t entryCount = SPKReadUInt16LE(bytes, (NSUInteger)eocdOffset + 10);
    uint32_t centralSize = SPKReadUInt32LE(bytes, (NSUInteger)eocdOffset + 12);
    uint32_t centralOffset = SPKReadUInt32LE(bytes, (NSUInteger)eocdOffset + 16);
    if ((NSUInteger)centralOffset + centralSize > zipData.length)
        return nil;

    NSString *tempRoot = SPKTemporaryTransferRoot(@"import");
    NSString *expandedRoot = [tempRoot stringByAppendingPathComponent:@"Expanded"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:expandedRoot withIntermediateDirectories:YES attributes:nil error:nil];

    NSFileHandle *archiveHandle = [NSFileHandle fileHandleForReadingFromURL:archiveURL error:error];
    if (!archiveHandle)
        return nil;

    NSUInteger cursor = centralOffset;
    for (uint16_t i = 0; i < entryCount; i++) {
        if (cursor + 46 > zipData.length || SPKReadUInt32LE(bytes, cursor) != 0x02014b50) {
            [archiveHandle closeFile];
            return nil;
        }

        uint16_t method = SPKReadUInt16LE(bytes, cursor + 10);
        uint64_t compressedSize = SPKReadUInt32LE(bytes, cursor + 20);
        uint64_t uncompressedSize = SPKReadUInt32LE(bytes, cursor + 24);
        uint16_t nameLen = SPKReadUInt16LE(bytes, cursor + 28);
        uint16_t extraLen = SPKReadUInt16LE(bytes, cursor + 30);
        uint16_t commentLen = SPKReadUInt16LE(bytes, cursor + 32);
        uint64_t localOffset = SPKReadUInt32LE(bytes, cursor + 42);
        if (cursor + 46 + nameLen + extraLen + commentLen > zipData.length) {
            [archiveHandle closeFile];
            return nil;
        }

        // ZIP64: any 32-bit size/offset equal to 0xFFFFFFFF is a sentinel; the real 64-bit value
        // lives in the 0x0001 extra block, present in fixed order (uncompressed, compressed, local
        // offset) only for the fields that overflowed. Modern zip writers (incl. Regram exports)
        // emit ZIP64 even for small entries, so this must be handled or every entry looks corrupt.
        if (compressedSize == 0xFFFFFFFFULL || uncompressedSize == 0xFFFFFFFFULL || localOffset == 0xFFFFFFFFULL) {
            NSUInteger ep = cursor + 46 + nameLen;
            NSUInteger extraEnd = ep + extraLen;
            while (ep + 4 <= extraEnd) {
                uint16_t headerID = SPKReadUInt16LE(bytes, ep);
                uint16_t blockSize = SPKReadUInt16LE(bytes, ep + 2);
                NSUInteger body = ep + 4;
                if (body + blockSize > extraEnd)
                    break;
                if (headerID == 0x0001) {
                    NSUInteger q = body;
                    if (uncompressedSize == 0xFFFFFFFFULL && q + 8 <= body + blockSize) {
                        uncompressedSize = SPKReadUInt64LE(bytes, q);
                        q += 8;
                    }
                    if (compressedSize == 0xFFFFFFFFULL && q + 8 <= body + blockSize) {
                        compressedSize = SPKReadUInt64LE(bytes, q);
                        q += 8;
                    }
                    if (localOffset == 0xFFFFFFFFULL && q + 8 <= body + blockSize) {
                        localOffset = SPKReadUInt64LE(bytes, q);
                        q += 8;
                    }
                    break;
                }
                ep = body + blockSize;
            }
        }

        NSData *nameData = [zipData subdataWithRange:NSMakeRange(cursor + 46, nameLen)];
        NSString *entryName = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        cursor += 46 + nameLen + extraLen + commentLen;
        if (!SPKIsSafeZipEntryName(entryName)) {
            [archiveHandle closeFile];
            return nil;
        }
        if ([entryName hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:[expandedRoot stringByAppendingPathComponent:entryName] withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        if (method != 0 && method != 8) {
            if (error) {
                *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                             code:2002
                                         userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_UNSUPPORTED_COMPRESSION_ERROR")}];
            }
            [archiveHandle closeFile];
            return nil;
        }
        if ((NSUInteger)localOffset + 30 > zipData.length || SPKReadUInt32LE(bytes, localOffset) != 0x04034b50) {
            [archiveHandle closeFile];
            return nil;
        }
        uint16_t localNameLen = SPKReadUInt16LE(bytes, localOffset + 26);
        uint16_t localExtraLen = SPKReadUInt16LE(bytes, localOffset + 28);
        unsigned long long dataOffset = (unsigned long long)localOffset + 30ULL + localNameLen + localExtraLen;
        if (dataOffset + compressedSize > zipData.length) {
            [archiveHandle closeFile];
            return nil;
        }

        NSString *destPath = [expandedRoot stringByAppendingPathComponent:entryName];
        [fm createDirectoryAtPath:[destPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

        if (method == 8) {
            // DEFLATE — inflate the compressed payload (mapped, no extra copy).
            if (!SPKInflateRawDeflateToFile(bytes + dataOffset, compressedSize, uncompressedSize, destPath)) {
                if (error) {
                    *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                                 code:2007
                                             userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ZIP_DECOMPRESS_FAILED_ERROR")}];
                }
                [archiveHandle closeFile];
                return nil;
            }
            continue;
        }

        // Stored (method 0) — copy the raw bytes straight through.
        [fm createFileAtPath:destPath contents:nil attributes:nil];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:destPath];
        [archiveHandle seekToFileOffset:dataOffset];
        uint64_t remaining = compressedSize;
        while (remaining > 0) {
            NSUInteger chunkSize = MIN((NSUInteger)remaining, (NSUInteger)(1024 * 1024));
            NSData *chunk = [archiveHandle readDataOfLength:chunkSize];
            if (chunk.length == 0)
                break;
            [output writeData:chunk];
            remaining -= (uint64_t)chunk.length;
        }
        [output closeFile];
        if (remaining > 0) {
            [archiveHandle closeFile];
            return nil;
        }
    }

    [archiveHandle closeFile];
    SPKLog(@"Transfer", @"[unzip] extracted %u entr%@ -> %@", entryCount, entryCount == 1 ? @"y" : @"ies", expandedRoot);
    return expandedRoot;
}

// Expands a Sparkle export zip and resolves it to the bundle root (the directory that actually holds
// Preferences/Gallery/manifest — the export may wrap them in a top-level folder). Returns nil when
// the archive isn't a Sparkle settings bundle.
static NSString *SPKExpandStoredZipSettingsTransferArchive(NSURL *archiveURL, NSError **error) {
    NSString *expandedRoot = SPKExpandZipArchiveRaw(archiveURL, error);
    if (expandedRoot.length == 0)
        return nil;
    if (SPKIsValidSettingsTransferBundleRoot(expandedRoot))
        return expandedRoot;
    return SPKResolvedSettingsTransferBundleRoot([NSURL fileURLWithPath:expandedRoot isDirectory:YES]);
}

static BOOL SPKIsValidSettingsTransferBundleRoot(NSString *bundleRoot) {
    if (bundleRoot.length == 0)
        return NO;
    NSString *prefsPath = [bundleRoot stringByAppendingPathComponent:@"Preferences/settings.plist"];
    NSString *galleryPath = [bundleRoot stringByAppendingPathComponent:@"Gallery"];
    NSString *deletedMessagesPath = [bundleRoot stringByAppendingPathComponent:@"DeletedMessages"];
    NSString *profileAnalyzerPath = [bundleRoot stringByAppendingPathComponent:@"ProfileAnalyzer"];
    return [[NSFileManager defaultManager] fileExistsAtPath:prefsPath] ||
           [[NSFileManager defaultManager] fileExistsAtPath:galleryPath] ||
           [[NSFileManager defaultManager] fileExistsAtPath:deletedMessagesPath] ||
           [[NSFileManager defaultManager] fileExistsAtPath:profileAnalyzerPath];
}

static NSString *SPKResolvedSettingsTransferBundleRoot(NSURL *pickedURL) {
    if (!pickedURL.path.length)
        return nil;

    NSString *candidate = pickedURL.path;
    for (NSInteger i = 0; i < 5 && candidate.length > 1; i++) {
        if (SPKIsValidSettingsTransferBundleRoot(candidate)) {
            return candidate;
        }
        candidate = [candidate stringByDeletingLastPathComponent];
    }
    return nil;
}

static NSString *SPKExpandSerializedSettingsTransferArchive(NSURL *archiveURL, NSError **error) {
    NSData *archiveData = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:error];
    if (archiveData.length == 0)
        return nil;

    NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithSerializedRepresentation:archiveData];
    if (!wrapper.isDirectory) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"SparkleSettingsTransfer"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey : SPKL(@"SETTINGS_TRANSFER_ARCHIVE_INVALID_ERROR")}];
        }
        return nil;
    }

    NSString *tempRoot = SPKTemporaryTransferRoot(@"import");
    NSString *expandedRoot = [tempRoot stringByAppendingPathComponent:@"Expanded"];
    NSURL *expandedURL = [NSURL fileURLWithPath:expandedRoot isDirectory:YES];
    if (![wrapper writeToURL:expandedURL options:NSFileWrapperWritingAtomic originalContentsURL:nil error:error]) {
        return nil;
    }

    return SPKIsValidSettingsTransferBundleRoot(expandedRoot) ? expandedRoot : SPKResolvedSettingsTransferBundleRoot(expandedURL);
}

static NSString *SPKResolvedImportBundleRootForPickedURL(NSURL *pickedURL, NSError **error) {
    NSString *bundleRoot = SPKResolvedSettingsTransferBundleRoot(pickedURL);
    if (bundleRoot.length > 0)
        return bundleRoot;

    NSNumber *isDirectory = nil;
    [pickedURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    if (isDirectory.boolValue)
        return nil;

    NSString *zipBundleRoot = SPKExpandStoredZipSettingsTransferArchive(pickedURL, error);
    if (zipBundleRoot.length > 0)
        return zipBundleRoot;

    return SPKExpandSerializedSettingsTransferArchive(pickedURL, error);
}

static NSString *SPKTransferScopeString(SPKTransferAccountScope scope) {
    return scope == SPKTransferAccountScopeCurrentAccount ? @"current" : @"all";
}

static NSDictionary *SPKTransferManifest(BOOL includeSettings, BOOL includeGallery, BOOL includeDeletedMessages, BOOL includeProfileAnalyzer, SPKTransferAccountScope scope, NSString *sourcePK, NSArray<NSString *> *includedKeys) {
    NSMutableDictionary *manifest = [@{
        @"format_version" : @4,
        @"created_at" : [NSDate date],
        @"includes_settings" : @(includeSettings),
        @"includes_gallery" : @(includeGallery),
        @"includes_deleted_messages" : @(includeDeletedMessages),
        @"includes_profile_analyzer" : @(includeProfileAnalyzer),
        // The account scope of the whole export (settings + gallery). "current" exports
        // are re-homed onto the importing device's active account. `account_scope`
        // replaces the legacy `settings_scope` (still read on import for old archives).
        @"account_scope" : SPKTransferScopeString(scope),
        @"source_account_pk" : sourcePK ?: @"",
        @"included_keys" : (includeSettings && includedKeys) ? [includedKeys sortedArrayUsingSelector:@selector(compare:)] : @[]
    } mutableCopy];
    return manifest;
}

// Sanitize a username/PK so it is safe inside a file name.
static NSString *SPKSanitizeFilenameComponent(NSString *component) {
    if (component.length == 0)
        return @"";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < component.length; i++) {
        unichar c = [component characterAtIndex:i];
        [out appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"-"];
    }
    return out;
}

// Descriptive, sortable, collision-free export file name, e.g.
// "Sparkle-Settings-AllAccounts-2026-06-26.zip" or "Sparkle-Settings-jane.doe-2026-06-26.zip".
static NSString *SPKTransferArchiveFilename(BOOL includeSettings, BOOL includeGallery, BOOL includeDeletedMessages, BOOL includeProfileAnalyzer, SPKTransferAccountScope scope, NSString *currentUsername, NSString *currentPK) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (includeSettings)
        [parts addObject:@"Settings"];
    if (includeGallery)
        [parts addObject:@"Gallery"];
    if (includeDeletedMessages)
        [parts addObject:@"Messages"];
    if (includeProfileAnalyzer)
        [parts addObject:@"Analyzer"];
    NSString *content = parts.count == 0 ? @"Backup" : (parts.count > 2 ? @"Backup" : [parts componentsJoinedByString:@"+"]);

    NSMutableString *name = [NSMutableString stringWithFormat:@"Sparkle-%@", content];
    // Tag the filename by the scope that was chosen: a "this account" export always
    // carries the account's username; an all-accounts export is labelled only when it
    // actually included per-account-scopable content (settings or gallery).
    if (scope == SPKTransferAccountScopeCurrentAccount) {
        NSString *who = currentUsername;
        if (who.length == 0)
            who = [SPKAccountManager usernameForPK:currentPK];
        if (who.length == 0)
            who = currentPK.length ? currentPK : @"account";
        [name appendFormat:@"-%@", SPKSanitizeFilenameComponent(who)];
    } else if (includeSettings || includeGallery) {
        [name appendString:@"-AllAccounts"];
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [name appendFormat:@"-%@.zip", [formatter stringFromDate:[NSDate date]]];
    return name;
}

@implementation SPKSettingsTransferManager

+ (instancetype)sharedManager {
    static SPKSettingsTransferManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[SPKSettingsTransferManager alloc] init];
    });
    return manager;
}

- (void)exportFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer {
    // When per-account settings is on, let the user choose whether to back up every
    // account or just the active one — this scopes both preferences and the Gallery.
    BOOL perAccountOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"general_per_account_settings"];
    NSString *currentPK = [SPKAccountManager currentAccountPK];
    BOOL settingsScopable = includeSettings && SPKPerAccountOverrideKeys(SPKTransferAccountScopeAllAccounts, nil).count > 0;
    BOOL offerScope = perAccountOn && currentPK.length > 0 && (settingsScopable || includeGallery);

    if (!offerScope) {
        [self exportFromController:controller includeSettings:includeSettings includeGallery:includeGallery includeDeletedMessages:includeDeletedMessages includeProfileAnalyzer:includeProfileAnalyzer settingsScope:SPKTransferAccountScopeAllAccounts];
        return;
    }

    NSString *username = [SPKAccountManager currentAccountUsername];
    NSString *thisTitle = username.length ? [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_ACCOUNT_SCOPE_CURRENT_ACCOUNT_FORMAT"), username] : SPKL(@"GALLERY_GALLERY_SETTINGS_ACCOUNT_ONLY_TITLE");
    NSString *scopeMessage = includeGallery
                                 ? SPKL(@"SETTINGS_TRANSFER_EXPORT_SCOPE_WITH_GALLERY_MESSAGE")
                                 : SPKL(@"SETTINGS_TRANSFER_EXPORT_SCOPE_MESSAGE");
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentActionSheetFromViewController:controller
                                                        title:SPKL(@"SETTINGS_TRANSFER_ACCOUNT_SCOPE_QUESTION")
                                                      message:scopeMessage
                                                      actions:@[
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ALL_ACCOUNTS")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf exportFromController:controller includeSettings:includeSettings includeGallery:includeGallery includeDeletedMessages:includeDeletedMessages includeProfileAnalyzer:includeProfileAnalyzer settingsScope:SPKTransferAccountScopeAllAccounts];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:thisTitle
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf exportFromController:controller includeSettings:includeSettings includeGallery:includeGallery includeDeletedMessages:includeDeletedMessages includeProfileAnalyzer:includeProfileAnalyzer settingsScope:SPKTransferAccountScopeCurrentAccount];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                      style:SPKIGAlertActionStyleCancel
                                                                                    handler:nil],
                                                      ]];
}

- (void)exportFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer settingsScope:(SPKTransferAccountScope)settingsScope {
    if (!includeSettings && !includeGallery && !includeDeletedMessages && !includeProfileAnalyzer)
        return;
    self.presentingController = controller;
    self.isImportMode = NO;

    NSString *currentPK = [SPKAccountManager currentAccountPK];
    // Only current-account exports record a source PK (so import can re-map it).
    NSString *sourcePK = (settingsScope == SPKTransferAccountScopeCurrentAccount) ? currentPK : nil;

    NSString *root = SPKTemporaryTransferRoot(@"export");
    NSString *bundleRoot = [root stringByAppendingPathComponent:@"SparkleExportBundle"];
    NSString *prefsPath = [bundleRoot stringByAppendingPathComponent:@"Preferences/settings.plist"];
    NSString *galleryDestination = [bundleRoot stringByAppendingPathComponent:@"Gallery"];
    NSString *deletedMessagesDestination = [bundleRoot stringByAppendingPathComponent:@"DeletedMessages"];
    NSString *profileAnalyzerDestination = [bundleRoot stringByAppendingPathComponent:@"ProfileAnalyzer"];
    NSString *manifestPath = [bundleRoot stringByAppendingPathComponent:@"manifest.plist"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:bundleRoot withIntermediateDirectories:YES attributes:nil error:nil];

    SPKNotificationPillView *pill = SPKNotifyProgress(kSPKNotificationSettingsExport, SPKL(@"SETTINGS_TRANSFER_EXPORT_PROGRESS_TITLE"), nil);
    pill.cancellable = NO;
    void (^setProgress)(float, NSString *) = ^(float fraction, NSString *subtitle) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [pill setProgress:fraction animated:YES];
            [pill updateProgressTitle:SPKL(@"SETTINGS_TRANSFER_EXPORT_PROGRESS_TITLE") subtitle:subtitle];
        });
    };
    void (^failExport)(NSString *) = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [pill showErrorWithTitle:SPKL(@"EXPORT_NOTIFICATION_FAILED") subtitle:message icon:nil];
        });
    };

    dispatch_async(SPKTransferWorkQueue(), ^{
        NSArray<NSString *> *includedKeys = nil;
        if (includeSettings) {
            [fm createDirectoryAtPath:[prefsPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
            NSDictionary *prefs = SPKPreferencesSnapshotForScope(settingsScope, currentPK);
            includedKeys = prefs.allKeys;
            [prefs writeToFile:prefsPath atomically:YES];
        }
        setProgress(0.05f, nil);

        if (includeGallery) {
            // One safe path for both scopes: a fresh store built via Core Data (current ⇒
            // only this account's files, all ⇒ every file). Avoids copying the live, possibly
            // WAL-dirty gallery.sqlite.
            NSString *ownerScope = (settingsScope == SPKTransferAccountScopeCurrentAccount && currentPK.length > 0) ? currentPK : nil;
            NSError *galleryError = nil;
            BOOL ok = [[SPKGalleryCoreDataStack shared] exportGalleryFilesToBundleDirectory:galleryDestination
                                                                             ownerAccountPK:ownerScope
                                                                            progressHandler:^(NSInteger done, NSInteger total) {
                                                                                setProgress(0.05f + 0.55f * (total > 0 ? (float)done / total : 1.0f),
                                                                                            [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_GALLERY_PROGRESS_FORMAT"), (long)done, (long)total]);
                                                                            }
                                                                                      error:&galleryError];
            if (!ok) {
                failExport(galleryError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_GALLERY_EXPORT_FAILED_ERROR"));
                return;
            }
        }

        if (includeDeletedMessages) {
            setProgress(0.65f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_MESSAGES"));
            NSError *copyError = nil;
            NSString *source = [SPKDeletedMessagesStorage storageRootPath];
            if ([fm fileExistsAtPath:source]) {
                if (![fm copyItemAtPath:source toPath:deletedMessagesDestination error:&copyError]) {
                    failExport(copyError.localizedDescription);
                    return;
                }
            } else if (![fm createDirectoryAtPath:deletedMessagesDestination withIntermediateDirectories:YES attributes:nil error:&copyError]) {
                failExport(copyError.localizedDescription);
                return;
            }
            NSString *keepalivePath = [deletedMessagesDestination stringByAppendingPathComponent:@".sparkle_keep"];
            if (![fm fileExistsAtPath:keepalivePath])
                [fm createFileAtPath:keepalivePath contents:[NSData data] attributes:nil];
        }

        if (includeProfileAnalyzer) {
            setProgress(0.72f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_PROFILE_ANALYZER"));
            NSError *copyError = nil;
            NSString *source = [SPKProfileAnalyzerStorage storageRootPath];
            if ([fm fileExistsAtPath:source]) {
                if (![fm copyItemAtPath:source toPath:profileAnalyzerDestination error:&copyError]) {
                    failExport(copyError.localizedDescription);
                    return;
                }
            } else if (![fm createDirectoryAtPath:profileAnalyzerDestination withIntermediateDirectories:YES attributes:nil error:&copyError]) {
                failExport(copyError.localizedDescription);
                return;
            }
            NSString *keepalivePath = [profileAnalyzerDestination stringByAppendingPathComponent:@".sparkle_keep"];
            if (![fm fileExistsAtPath:keepalivePath])
                [fm createFileAtPath:keepalivePath contents:[NSData data] attributes:nil];
        }

        [SPKTransferManifest(includeSettings, includeGallery, includeDeletedMessages, includeProfileAnalyzer, settingsScope, sourcePK, includedKeys) writeToFile:manifestPath atomically:YES];

        setProgress(0.8f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_COMPRESSING"));
        NSError *archiveError = nil;
        NSString *archiveName = SPKTransferArchiveFilename(includeSettings, includeGallery, includeDeletedMessages, includeProfileAnalyzer, settingsScope, [SPKAccountManager currentAccountUsername], currentPK);
        NSString *archivePath = [root stringByAppendingPathComponent:archiveName];
        if (!SPKWriteStoredZipFromDirectory(bundleRoot, archivePath, &archiveError)) {
            failExport(archiveError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_EXPORT_ZIP_FAILED_ERROR"));
            return;
        }
        setProgress(1.0f, nil);

        NSURL *archiveURL = [NSURL fileURLWithPath:archivePath isDirectory:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [pill dismiss];
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ archiveURL ] asCopy:YES];
            picker.delegate = self;
            self.activeDocumentPicker = picker;
            UIViewController *presenter = SPKDocumentPickerPresenter(controller);
            if (!presenter || !presenter.view.window) {
                SPKNotify(kSPKNotificationSettingsExport, SPKL(@"SETTINGS_TRANSFER_EXPORT_READY_TOAST"), SPKL(@"SETTINGS_TRANSFER_FILES_UNAVAILABLE_SHARE_FALLBACK_TOAST"), @"arrow_up", SPKNotificationToneForIconResource(@"arrow_up"));
                [SPKUtils showShareVC:archiveURL];
                return;
            }
            [presenter presentViewController:picker animated:YES completion:nil];
        });
    });
}

+ (BOOL)writeZipArchiveFromDirectory:(NSString *)directory toPath:(NSString *)zipPath error:(NSError **)error {
    if (directory.length == 0 || zipPath.length == 0)
        return NO;
    return SPKWriteStoredZipFromDirectory(directory, zipPath, error);
}

+ (NSString *)expandZipArchiveAtURL:(NSURL *)archiveURL error:(NSError **)error {
    if (!archiveURL) {
        return nil;
    }
    return SPKExpandZipArchiveRaw(archiveURL, error);
}

- (void)importFromController:(UIViewController *)controller includeSettings:(BOOL)includeSettings includeGallery:(BOOL)includeGallery includeDeletedMessages:(BOOL)includeDeletedMessages includeProfileAnalyzer:(BOOL)includeProfileAnalyzer {
    if (!includeSettings && !includeGallery && !includeDeletedMessages && !includeProfileAnalyzer)
        return;
    self.presentingController = controller;
    self.pendingImportSettings = includeSettings;
    self.pendingImportGallery = includeGallery;
    self.pendingImportDeletedMessages = includeDeletedMessages;
    self.pendingImportProfileAnalyzer = includeProfileAnalyzer;
    self.isImportMode = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP ] asCopy:YES];
    picker.delegate = self;
    self.activeDocumentPicker = picker;
    SPKLog(@"Transfer", @"Presenting import document picker settings=%@ gallery=%@ deletedMessages=%@ profileAnalyzer=%@", includeSettings ? @"yes" : @"no", includeGallery ? @"yes" : @"no", includeDeletedMessages ? @"yes" : @"no", includeProfileAnalyzer ? @"yes" : @"no");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = SPKDocumentPickerPresenter(controller);
        if (!presenter || !presenter.view.window) {
            SPKNotify(kSPKNotificationSettingsImport, SPKL(@"SETTINGS_TRANSFER_IMPORT_FAILED_TOAST"), SPKL(@"SETTINGS_TRANSFER_FILES_PICKER_UNAVAILABLE_TOAST"), @"error_filled", SPKNotificationToneForIconResource(@"error_filled"));
            self.activeDocumentPicker = nil;
            return;
        }
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pendingImportSettings = NO;
    self.pendingImportGallery = NO;
    self.pendingImportDeletedMessages = NO;
    self.pendingImportProfileAnalyzer = NO;
    self.presentingController = nil;
    self.activeDocumentPicker = nil;
    self.isImportMode = NO;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    self.presentingController = nil;
    self.activeDocumentPicker = nil;
    if (!url)
        return;

    if (!self.isImportMode) {
        SPKNotify(kSPKNotificationSettingsExport, SPKL(@"SETTINGS_TRANSFER_EXPORT_COMPLETE_TOAST"), SPKL(@"SETTINGS_TRANSFER_BACKUP_SAVED_TOAST"), @"circle_check_filled", SPKNotificationToneForIconResource(@"circle_check_filled"));
        return;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];

    // Progress pill so unzip + the heavy merges never block the UI. Stopping
    // partway would leave settings half merged, so it offers no cancel.
    SPKNotificationPillView *pill = SPKNotifyProgress(kSPKNotificationSettingsImport, SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS"), nil);
    pill.cancellable = NO;
    void (^setProgress)(float, NSString *) = ^(float fraction, NSString *sub) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [pill setProgress:fraction animated:YES];
            [pill updateProgressTitle:SPKL(@"GALLERY_IMPORT_IMPORTING_PROGRESS") subtitle:sub];
        });
    };
    void (^failImport)(NSString *) = ^(NSString *message) {
        SPKLog(@"Transfer", @"Import failed: %@", message);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (scoped)
                [url stopAccessingSecurityScopedResource];
            // An import failure is terminal and the reason is often a long system message,
            // so show it in an alert the user can actually read instead of a pill subtitle.
            [pill dismiss];
            [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                          title:SPKL(@"IMPORT_NOTIFICATION_FAILED")
                                                        message:message
                                                        actions:@[
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                        style:SPKIGAlertActionStyleCancel
                                                                                      handler:nil]
                                                        ]];
        });
    };

    dispatch_async(SPKTransferWorkQueue(), ^{
        setProgress(0.05f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_READING_BACKUP"));
        NSError *archiveError = nil;
        NSString *bundleRoot = SPKResolvedImportBundleRootForPickedURL(url, &archiveError);
        NSString *prefsPath = [bundleRoot stringByAppendingPathComponent:@"Preferences/settings.plist"];
        NSString *galleryPath = [bundleRoot stringByAppendingPathComponent:@"Gallery"];
        NSString *deletedMessagesPath = [bundleRoot stringByAppendingPathComponent:@"DeletedMessages"];
        NSString *profileAnalyzerPath = [bundleRoot stringByAppendingPathComponent:@"ProfileAnalyzer"];
        NSString *manifestPath = [bundleRoot stringByAppendingPathComponent:@"manifest.plist"];
        NSDictionary *manifest = bundleRoot.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:manifestPath] : nil;
        NSDictionary *prefs = [[NSFileManager defaultManager] fileExistsAtPath:prefsPath] ? [NSDictionary dictionaryWithContentsOfFile:prefsPath] : nil;
        BOOL archiveHasSettings = [prefs isKindOfClass:[NSDictionary class]];
        BOOL archiveHasGallery = [[NSFileManager defaultManager] fileExistsAtPath:galleryPath];
        BOOL archiveHasDeletedMessages = [[NSFileManager defaultManager] fileExistsAtPath:deletedMessagesPath];
        BOOL archiveHasProfileAnalyzer = [[NSFileManager defaultManager] fileExistsAtPath:profileAnalyzerPath];
        BOOL importSettings = self.pendingImportSettings;
        BOOL importGallery = self.pendingImportGallery;
        BOOL importDeletedMessages = self.pendingImportDeletedMessages;
        BOOL importProfileAnalyzer = self.pendingImportProfileAnalyzer;
        self.pendingImportSettings = NO;
        self.pendingImportGallery = NO;
        self.pendingImportDeletedMessages = NO;
        self.pendingImportProfileAnalyzer = NO;

        if (manifest && [manifest isKindOfClass:[NSDictionary class]]) {
            NSNumber *manifestSettings = manifest[@"includes_settings"];
            NSNumber *manifestGallery = manifest[@"includes_gallery"];
            NSNumber *manifestDeletedMessages = manifest[@"includes_deleted_messages"];
            NSNumber *manifestProfileAnalyzer = manifest[@"includes_profile_analyzer"];
            if ([manifestSettings respondsToSelector:@selector(boolValue)])
                archiveHasSettings = manifestSettings.boolValue && archiveHasSettings;
            if ([manifestGallery respondsToSelector:@selector(boolValue)])
                archiveHasGallery = manifestGallery.boolValue && archiveHasGallery;
            if ([manifestDeletedMessages respondsToSelector:@selector(boolValue)])
                archiveHasDeletedMessages = manifestDeletedMessages.boolValue && archiveHasDeletedMessages;
            if ([manifestProfileAnalyzer respondsToSelector:@selector(boolValue)])
                archiveHasProfileAnalyzer = manifestProfileAnalyzer.boolValue && archiveHasProfileAnalyzer;
        }

        if ((importSettings && !archiveHasSettings) || (importGallery && !archiveHasGallery) || (importDeletedMessages && !archiveHasDeletedMessages) || (importProfileAnalyzer && !archiveHasProfileAnalyzer) || (!archiveHasSettings && !archiveHasGallery && !archiveHasDeletedMessages && !archiveHasProfileAnalyzer)) {
            failImport(archiveError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_ARCHIVE_INVALID_ERROR"));
            return;
        }
        setProgress(0.15f, nil);

        // Backup scope (applies to both preferences and Gallery). A "current" backup is
        // flattened onto this device's active account on import. Read the new `account_scope`
        // field, falling back to the legacy `settings_scope` for older archives.
        NSDictionary *scopeManifest = [manifest isKindOfClass:[NSDictionary class]] ? manifest : nil;
        NSString *scopeString = scopeManifest[@"account_scope"] ?: scopeManifest[@"settings_scope"];
        BOOL currentScope = [scopeString isEqualToString:@"current"];
        NSString *currentPK = [SPKAccountManager currentAccountPK];
        NSString *currentUsername = [SPKAccountManager currentAccountUsername];

        if (importSettings) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            // Backups made before a preference rename carry the legacy keys.
            prefs = SPKPreferenceMigrationsAppliedToDictionary(prefs);

            if (currentScope) {
                // FLATTEN: re-home the backup's (base-key, effective-value) settings into the
                // importing account's namespace — or global if per-account mode is off — and
                // touch nothing else, so other accounts are unaffected.
                NSString *targetPK = SPKPerAccountModeActive() ? currentPK : nil;
                if (targetPK.length > 0) {
                    for (NSString *key in SPKPerAccountOverrideKeys(SPKTransferAccountScopeCurrentAccount, targetPK)) {
                        [defaults removeObjectForKey:key];
                    }
                } else {
                    for (NSString *key in SPKExportedPreferenceKeys()) {
                        [defaults removeObjectForKey:key];
                    }
                }
                [prefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                    if (SPKPreferenceKeyIsGlobal(key) || !SPKPrefIsAvailable(key))
                        return; // flatten archives carry only per-account-capable base keys
                    NSString *applyKey = targetPK.length > 0 ? [NSString stringWithFormat:@"u_%@_%@", targetPK, key] : key;
                    [defaults setObject:value forKey:applyKey];
                }];
            } else {
                // ALL ACCOUNTS: verbatim restore — clear every scope key, apply as stored.
                for (NSString *key in SPKExportedPreferenceKeysForScope(SPKTransferAccountScopeAllAccounts, nil)) {
                    [defaults removeObjectForKey:key];
                }
                [prefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                    NSString *pk = nil, *baseKey = nil;
                    BOOL isPerAccount = SPKParsePerAccountKey(key, &pk, &baseKey);
                    NSString *availabilityKey = isPerAccount ? baseKey : key; // availability keyed by base pref
                    if (!SPKPrefIsAvailable(availabilityKey))
                        return;
                    [defaults setObject:value forKey:key];
                }];
            }
            // The app icon is a pref but also live UIApplication state — apply the imported
            // selection on the main thread so it changes immediately.
            dispatch_async(dispatch_get_main_queue(), ^{
                [SPKAppIconCatalog applyStoredIconIfNeeded];
            });
        }
        setProgress(0.25f, nil);

        // The non-gallery remainder (messages, profile analyzer, finalize). Runs on the
        // work queue; only the final summary/restart touches the main thread.
        void (^finishImport)(NSInteger) = ^(NSInteger galleryAddedCount) {
            NSInteger messagesAdded = 0;
            if (importDeletedMessages) {
                setProgress(0.85f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_MESSAGES"));
                NSError *deletedMessagesError = nil;
                messagesAdded = [SPKDeletedMessagesStorage mergeFromStorageDirectory:deletedMessagesPath ownerFilterPK:nil error:&deletedMessagesError];
                if (messagesAdded < 0) {
                    failImport(deletedMessagesError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_MESSAGES_IMPORT_FAILED_ERROR"));
                    return;
                }
            }

            NSInteger visitsAdded = 0;
            if (importProfileAnalyzer) {
                setProgress(0.93f, SPKL(@"SETTINGS_TRANSFER_PROGRESS_PROFILE_ANALYZER"));
                NSError *profileAnalyzerError = nil;
                visitsAdded = [SPKProfileAnalyzerStorage mergeFromStorageDirectory:profileAnalyzerPath ownerFilterPK:nil error:&profileAnalyzerError];
                if (visitsAdded < 0) {
                    failImport(profileAnalyzerError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_PROFILE_ANALYZER_IMPORT_FAILED_ERROR"));
                    return;
                }
            }
            setProgress(1.0f, nil);

            NSMutableArray<NSString *> *restored = [NSMutableArray array];
            if (importSettings)
                [restored addObject:SPKL(@"SETTINGS_TRANSFER_RESTORED_PREFERENCES_ITEM")];
            if (importGallery)
                [restored addObject:[NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_RESTORED_CATEGORY_FORMAT"),
                                                              SPKL(@"GALLERY_TITLE"),
                                                              SPKLP(@"COMMON_ITEM_COUNT", galleryAddedCount)]];
            if (importDeletedMessages)
                [restored addObject:[NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_RESTORED_CATEGORY_FORMAT"),
                                                              SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE"),
                                                              SPKLP(@"COMMON_MESSAGE_COUNT", messagesAdded)]];
            if (importProfileAnalyzer)
                [restored addObject:[NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_RESTORED_CATEGORY_FORMAT"),
                                                              SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE"),
                                                              SPKLP(@"COMMON_ITEM_COUNT", visitsAdded)]];
            NSString *subtitle = [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_RESTORED_ITEMS_FORMAT"), [restored componentsJoinedByString:@", "]];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (scoped)
                    [url stopAccessingSecurityScopedResource];
                [pill dismiss];
                SPKNotify(kSPKNotificationSettingsImport, SPKL(@"SETTINGS_TRANSFER_IMPORT_COMPLETE_TOAST"), subtitle, @"circle_check_filled", SPKNotificationToneForIconResource(@"circle_check_filled"));
                // Only preferences need a relaunch (read at launch / hook-install time). The
                // gallery/messages/analyzer merges write live and post change notifications.
                if (importSettings)
                    [SPKUtils showRestartConfirmation];
            });
        };

        // A "this account" import re-assigns gallery files to the active account.
        NSString *remapPK = currentScope ? currentPK : nil;
        NSString *remapUsername = currentScope ? currentUsername : nil;

        void (^mergeGalleryThenFinish)(SPKGalleryImportConflictStrategy) = ^(SPKGalleryImportConflictStrategy strategy) {
            // Always hop to the work queue so file copies never run on the main thread,
            // whether we arrive here directly or from the (main-thread) conflict alert.
            dispatch_async(SPKTransferWorkQueue(), ^{
                NSInteger galleryAddedCount = 0;
                if (importGallery) {
                    NSError *galleryMergeError = nil;
                    galleryAddedCount = [[SPKGalleryCoreDataStack shared] mergeGalleryFilesFromBundleDirectory:galleryPath
                                                                                           remapOwnerAccountPK:remapPK
                                                                                                 ownerUsername:remapUsername
                                                                                              conflictStrategy:strategy
                                                                                               progressHandler:^(NSInteger done, NSInteger total) {
                                                                                                   setProgress(0.25f + 0.55f * (total > 0 ? (float)done / total : 1.0f),
                                                                                                               [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_GALLERY_PROGRESS_FORMAT"), (long)done, (long)total]);
                                                                                               }
                                                                                                         error:&galleryMergeError];
                    if (galleryAddedCount < 0) {
                        failImport(galleryMergeError.localizedDescription ?: SPKL(@"SETTINGS_TRANSFER_GALLERY_IMPORT_FAILED_ERROR"));
                        return;
                    }
                }
                finishImport(galleryAddedCount);
            });
        };

        // If a "this account" gallery import collides with items already owned by another
        // account on this device, ask once how to resolve them all, then proceed. The
        // conflict count reads Core Data, so run it on the main queue.
        __block NSInteger conflicts = 0;
        if (importGallery && remapPK.length > 0) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                conflicts = [[SPKGalleryCoreDataStack shared] galleryImportConflictCountForBundleDirectory:galleryPath ownerAccountPK:remapPK];
            });
        }

        if (conflicts <= 0) {
            mergeGalleryThenFinish(SPKGalleryImportConflictStrategySkip);
            return;
        }

        NSString *message = [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_ACCOUNT_CONFLICTS_FORMAT"),
                                                       SPKLP(@"COMMON_FILE_COUNT", conflicts)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                          title:SPKL(@"SETTINGS_SETTINGS_TRANSFER_MANAGER_FILES_ANOTHER_ACCOUNT_TEXT")
                                                        message:message
                                                        actions:@[
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLAIM_ACCOUNT")
                                                                                        style:SPKIGAlertActionStyleDefault
                                                                                      handler:^{
                                                                                          mergeGalleryThenFinish(SPKGalleryImportConflictStrategyClaim);
                                                                                      }],
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_KEEP_SEPARATE_COPY")
                                                                                        style:SPKIGAlertActionStyleDefault
                                                                                      handler:^{
                                                                                          mergeGalleryThenFinish(SPKGalleryImportConflictStrategyDuplicate);
                                                                                      }],
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"VC_BTN_SKIP")
                                                                                        style:SPKIGAlertActionStyleCancel
                                                                                      handler:^{
                                                                                          mergeGalleryThenFinish(SPKGalleryImportConflictStrategySkip);
                                                                                      }],
                                                        ]];
        });
    });
}

- (void)resetAllSettingsFromController:(UIViewController *)controller {
    // Mirror Export's account-scope prompt: when per-account settings are on and the
    // active account actually has per-account overrides, let the user reset every
    // account or only the active one. Otherwise reset is global — go straight to confirm.
    NSString *currentPK = [SPKAccountManager currentAccountPK];
    BOOL offerScope = SPKPerAccountModeActive() && currentPK.length > 0 && SPKPerAccountOverrideKeys(SPKTransferAccountScopeAllAccounts, nil).count > 0;

    if (!offerScope) {
        [self confirmResetFromController:controller scope:SPKTransferAccountScopeAllAccounts];
        return;
    }

    NSString *username = [SPKAccountManager currentAccountUsername];
    NSString *thisTitle = username.length ? [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_ACCOUNT_SCOPE_CURRENT_ACCOUNT_FORMAT"), username] : SPKL(@"GALLERY_GALLERY_SETTINGS_ACCOUNT_ONLY_TITLE");
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentActionSheetFromViewController:controller
                                                        title:SPKL(@"SETTINGS_SETTINGS_TRANSFER_MANAGER_ACCOUNTS_QUESTION")
                                                      message:SPKL(@"SETTINGS_SETTINGS_TRANSFER_MANAGER_PER_ACCOUNT_SETTINGS_RESET_EVERY_ACCOUNT_S_SETTINGS_ONLY_TEXT")
                                                      actions:@[
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ALL_ACCOUNTS")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf confirmResetFromController:controller scope:SPKTransferAccountScopeAllAccounts];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:thisTitle
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf confirmResetFromController:controller scope:SPKTransferAccountScopeCurrentAccount];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                      style:SPKIGAlertActionStyleCancel
                                                                                    handler:nil],
                                                      ]];
}

- (void)confirmResetFromController:(UIViewController *)controller scope:(SPKTransferAccountScope)scope {
    BOOL currentScope = (scope == SPKTransferAccountScopeCurrentAccount);
    NSString *username = [SPKAccountManager currentAccountUsername];
    NSString *message = currentScope
                            ? [NSString stringWithFormat:SPKL(@"SETTINGS_TRANSFER_RESET_ACCOUNT_CONFIRMATION_FORMAT"), username.length ? username : SPKL(@"SETTINGS_TRANSFER_ACTIVE_ACCOUNT_FALLBACK_TEXT")]
                            : SPKL(@"SETTINGS_TRANSFER_RESET_ALL_CONFIRMATION_MESSAGE");
    NSString *currentPK = [SPKAccountManager currentAccountPK];
    [SPKIGAlertPresenter presentAlertFromViewController:controller
                                                  title:SPKL(@"DATA_GENERAL_RESET_ALL_SETTINGS_TITLE")
                                                message:message
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_RESET")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                                                                                  if (currentScope) {
                                                                                      // Clear only the active account's per-account overrides; global keys
                                                                                      // and other accounts are untouched, so this account falls back to
                                                                                      // the global/default values. The passcode is device-global, so leave it.
                                                                                      for (NSString *key in SPKPerAccountOverrideKeys(SPKTransferAccountScopeCurrentAccount, currentPK)) {
                                                                                          [defaults removeObjectForKey:key];
                                                                                      }
                                                                                  } else {
                                                                                      // Clear global keys AND every account's per-account overrides.
                                                                                      for (NSString *key in SPKExportedPreferenceKeysForScope(SPKTransferAccountScopeAllAccounts, nil)) {
                                                                                          [defaults removeObjectForKey:key];
                                                                                      }
                                                                                      [[SPKSettingsLockManager sharedManager] removePasscode];
                                                                                  }
                                                                                  SPKNotify(kSPKNotificationSettingsImport,
                                                                                            SPKL(@"SETTINGS_TRANSFER_SETTINGS_RESET_TOAST"),
                                                                                            currentScope ? SPKL(@"SETTINGS_TRANSFER_ACCOUNT_DEFAULTS_RESTORED_TOAST") : SPKL(@"SETTINGS_TRANSFER_ALL_DEFAULTS_RESTORED_TOAST"),
                                                                                            @"circle_check_filled",
                                                                                            SPKNotificationToneForIconResource(@"circle_check_filled"));
                                                                                  [SPKUtils showRestartConfirmation];
                                                                              }],
                                                ]];
}

- (void)resetConfigurationGroupFromController:(UIViewController *)controller
                                        title:(NSString *)title
                                      message:(NSString *)message
                                  confirmTitle:(NSString *)confirmTitle
                                         keys:(NSArray<NSString *> *)keys
                                      onReset:(void (^)(void))onReset {
    [SPKIGAlertPresenter presentAlertFromViewController:controller
                                                  title:title
                                                message:message
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:(confirmTitle.length ? confirmTitle : SPKL(@"ALERT_ACTION_RESET"))
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                                                                                  // Remove both the base key and the active account's namespaced
                                                                                  // override so the built-in default is restored for what the user
                                                                                  // is looking at, while other accounts' overrides survive.
                                                                                  for (NSString *key in keys) {
                                                                                      [defaults removeObjectForKey:key];
                                                                                      NSString *effectiveKey = SPKEffectivePreferenceKey(key);
                                                                                      if (![effectiveKey isEqualToString:key])
                                                                                          [defaults removeObjectForKey:effectiveKey];
                                                                                  }
                                                                                  SPKNotify(kSPKNotificationSettingsImport,
                                                                                            SPKL(@"SETTINGS_TRANSFER_RESET_DEFAULT_TOAST"),
                                                                                            SPKL(@"SETTINGS_TRANSFER_GROUP_DEFAULTS_RESTORED_TOAST"),
                                                                                            @"circle_check_filled",
                                                                                            SPKNotificationToneForIconResource(@"circle_check_filled"));
                                                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                                                      if (onReset)
                                                                                          onReset();
                                                                                  });
                                                                              }],
                                                ]];
}

@end
