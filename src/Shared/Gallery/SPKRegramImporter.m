#import "SPKRegramImporter.h"

#import <sqlite3.h>

#import "../../Settings/SPKSettingsTransferManager.h"
#import "../../Utils.h"
#import "SPKGalleryFile.h"
#import "SPKGallerySaveMetadata.h"

#pragma mark - Enum mapping

// Regram `ZRGVFILE.ZTYPE` → Sparkle media type. Falls back to extension sniffing.
static SPKGalleryMediaType SPKRegramMediaType(int rgType, NSString *path) {
    switch (rgType) {
        case 1:
            return SPKGalleryMediaTypeImage;
        case 2:
            return SPKGalleryMediaTypeVideo;
        case 3:
            return SPKGalleryMediaTypeAudio;
        case 4:
            return SPKGalleryMediaTypeImage;  // GIF (Regram 7.1+); the gallery keeps GIFs as images
        default:
            return [SPKGalleryFile inferMediaTypeFromFileURL:[NSURL fileURLWithPath:path ?: @""]];
    }
}

// Regram `ZRGVFILE.ZSOURCE` → Sparkle source. Regram's enum is its own, non-contiguous set. The
// COMPLETE value set (0–13) and its semantics were reverse-engineered from Regram.dylib's
// `+[RGMediaVaultManager sourceGroups]`, which buckets every source into a UI group (observed slug
// in parentheses). Regram's grouping is coarser than Sparkle's, so where Sparkle has a finer source
// (Profile / Thumbnail / AudioPage) we prefer it over Regram's catch-all "Other" bucket. Values with
// no Sparkle equivalent fall through to Other; the filename-slug heuristic in the import pipeline
// then recovers the real source anyway, since Regram basenames share Sparkle's
// `epoch_user_slug_date` layout.
//
// Regram sourceGroups (authoritative): Feed{1,11} Stories{2} Reels{5,6} DMs{3,4} Notes{7}
// Instants{12} Comments{13} Other{0,8,9,10}. Per-value slugs (RE'd from the slug string pool +
// DB correlation): 1 feed, 2 story, 3 dm, 4 dm-story, 5 tv, 6 reel, 7 dm-note, 8 profile-photo,
// 9 highlight-cover, 10 cover, 11 post-audio, 12 instant, 13 comment; 0 = default/unspecified.
// Regram 7.1 added 14 for files the user imported from Photos or Files (no Instagram origin), which
// falls through to Other like 0, and 15 for call recordings (→ DMs).
static SPKGallerySource SPKRegramSource(int rgSource) {
    switch (rgSource) {
        case 1:
            return SPKGallerySourceFeed;  // _feed  (Feed group)
        case 2:
            return SPKGallerySourceStories;  // _story  (Stories group)
        case 3:
            return SPKGallerySourceDMs;  // _dm  (DMs group)
        case 4:
            return SPKGallerySourceDMs;  // _dm-story  (DMs group)
        case 7:
            // Notes group in Regram. Sparkle has no Notes source; notes live on the messages tab, so
            // they're filed under DMs (no separate filter entry) rather than Other.
            return SPKGallerySourceDMs;
        case 5:
            return SPKGallerySourceReels;  // _tv  (IGTV; Reels group)
        case 6:
            return SPKGallerySourceReels;  // _reel  (Reels group)
        case 8:
            return SPKGallerySourceProfile;  // _profile-photo  (Regram: Other; refined to Profile)
        case 9:
            return SPKGallerySourceThumbnail;  // _highlight-cover  (Regram: Other; a cover image)
        case 10:
            return SPKGallerySourceThumbnail;  // _cover  (Regram: Other; refined to Thumbnail)
        case 11:
            return SPKGallerySourceAudioPage;  // _post-audio  (Regram: Feed; refined to AudioPage)
        case 12:
            return SPKGallerySourceInstants;  // _instant  (Instants group)
        case 13:
            return SPKGallerySourceComments;  // _comment  (Comments group)
        case 15:
            // Call recordings (Regram 7.1+, own Calls group). Calls happen in Direct, so they file
            // under DMs rather than Other.
            return SPKGallerySourceDMs;
        // 0 = default/unspecified (no slug) → Other. (7 = Notes/_dm-note handled above → DMs.)
        default:
            return SPKGallerySourceOther;
    }
}

// Regram `ZMEDIAID` is either a bare numeric media pk, "<mediaPK>_<userPK>", or a synthetic id
// (e.g. "instant_url_..."). Return the leading digits when they look like a real pk, else nil.
static NSString *SPKRegramMediaPK(NSString *mediaId) {
    if (mediaId.length == 0) {
        return nil;
    }
    NSString *head = [[mediaId componentsSeparatedByString:@"_"] firstObject];
    if (head.length == 0) {
        return nil;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([head rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return nil;
    }
    return head;
}

#pragma mark - Filesystem helpers

// Depth-first search for the first entry whose last path component matches (case-insensitively)
// any of `names`. The Regram vault is small, so an unbounded walk is fine.
static NSString *SPKRegramFindNamed(NSString *root, NSArray<NSString *> *names) {
    if (root.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
    for (NSString *rel in e) {
        NSString *last = rel.lastPathComponent.lowercaseString;
        for (NSString *n in names) {
            if ([last isEqualToString:n.lowercaseString]) {
                return [root stringByAppendingPathComponent:rel];
            }
        }
    }
    return nil;
}

// Expands a zip, forwarding the zip reader's password errors so the caller can prompt and retry.
static NSString *SPKRegramExpand(NSString *zipPath, NSString *password, NSError **error) {
    return [SPKSettingsTransferManager expandZipArchiveAtURL:[NSURL fileURLWithPath:zipPath] password:password error:error];
}

// Resolves a picked folder/zip URL to a local working directory root.
static NSString *SPKRegramWorkingRoot(NSURL *url, NSString *password, NSError **error) {
    NSNumber *isDir = nil;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    if (isDir.boolValue) {
        return url.path;  // asCopy:YES already handed us an owned copy of the folder
    }
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"zip"]) {
        return SPKRegramExpand(url.path, password, error);
    }
    if ([ext isEqualToString:@"sqlite"]) {
        return url.path.stringByDeletingLastPathComponent;
    }
    return nil;
}

// Regram 7.1+ wraps every export in a "frbackup-package": `package.json` lists one inner zip per
// feature under `items/<FeatureID>/<n>.zip`, each optionally password protected (WinZip AES). A
// Media Vault-only export and a full backup share this shape; only the entry list differs. Returns
// the absolute paths of the Media Vault inner zips, or nil when `root` is not such a package.
static NSArray<NSString *> *SPKRegramPackageVaultZips(NSString *root) {
    NSString *packagePath = SPKRegramFindNamed(root, @[ @"package.json" ]);
    NSData *data = packagePath ? [NSData dataWithContentsOfFile:packagePath] : nil;
    NSDictionary *package = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![package isKindOfClass:[NSDictionary class]] || ![package[@"format"] isEqual:@"frbackup-package"]) {
        return nil;
    }
    NSString *packageRoot = packagePath.stringByDeletingLastPathComponent;
    NSMutableArray<NSString *> *zips = [NSMutableArray array];
    NSArray *entries = [package[@"entries"] isKindOfClass:[NSArray class]] ? package[@"entries"] : @[];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"featureID"] isEqual:@"MediaVault"]) {
            continue;
        }
        NSString *relative = [entry[@"path"] isKindOfClass:[NSString class]] ? entry[@"path"] : nil;
        if (relative.length == 0 || [relative hasPrefix:@"/"] || [relative containsString:@".."]) {
            continue;
        }
        NSString *path = [packageRoot stringByAppendingPathComponent:relative];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [zips addObject:path];
        }
    }
    return zips;
}

// Locates every MediaVault.sqlite reachable from a resolved working root, expanding inner zips as
// needed: the 7.1+ package entries, or the older full export's nested `MediaVault.zip`.
static NSArray<NSString *> *SPKRegramLocateSQLites(NSString *root, NSString *password, NSError **error) {
    NSString *sqlitePath = SPKRegramFindNamed(root, @[ @"MediaVault.sqlite" ]);
    if (sqlitePath) {
        return @[ sqlitePath ];
    }
    NSArray<NSString *> *innerZips = SPKRegramPackageVaultZips(root);
    if (!innerZips) {
        NSString *legacyZip = SPKRegramFindNamed(root, @[ @"MediaVault.zip" ]);
        innerZips = legacyZip ? @[ legacyZip ] : @[];
    }
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *zip in innerZips) {
        NSString *expanded = SPKRegramExpand(zip, password, error);
        if (!expanded) {
            return nil;  // a password error must reach the caller rather than read as "not a vault"
        }
        NSString *path = SPKRegramFindNamed(expanded, @[ @"MediaVault.sqlite" ]);
        if (path) {
            [found addObject:path];
        }
    }
    return found;
}

// The media tree sits beside the store: `Files/` next to the sqlite in the older export, and
// `media/Files/` beside `store/` in the 7.1+ package.
static NSString *SPKRegramFilesRoot(NSString *sqlitePath) {
    NSString *storeDir = sqlitePath.stringByDeletingLastPathComponent;
    NSArray<NSString *> *candidates = @[
        [storeDir stringByAppendingPathComponent:@"Files"],
        [storeDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"media/Files"],
    ];
    for (NSString *candidate in candidates) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            return candidate;
        }
    }
    return candidates.firstObject;
}

#pragma mark - SQLite read

static BOOL SPKRegramTableHasColumn(sqlite3 *db, const char *table, const char *column) {
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%s)", table];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        return NO;
    }
    BOOL found = NO;
    while (!found && sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(stmt, 1);
        found = name && strcasecmp((const char *)name, column) == 0;
    }
    sqlite3_finalize(stmt);
    return found;
}

// Regram 7.1 `+[RGMediaVaultManager sourceGroups]`: the group a smart-folder rule names
// (`groups`) → the ZSOURCE values it covers. 0 Feed, 1 Stories, 2 Reels, 3 DMs, 4 Notes, 5 Instants,
// 6 Comments, 7 Other, 8 Imported, 9 Calls.
static NSInteger SPKRegramGroupForSource(int rgSource) {
    switch (rgSource) {
        case 1:
        case 11:
            return 0;
        case 2:
            return 1;
        case 5:
        case 6:
            return 2;
        case 3:
        case 4:
            return 3;
        case 7:
            return 4;
        case 12:
            return 5;
        case 13:
            return 6;
        case 14:
            return 8;
        case 15:
            return 9;
        default:
            return 7;  // 0, 8, 9, 10
    }
}

@interface SPKRegramFolders : NSObject
/// ZRGVFOLDER pk → slash-joined path ("Trips/Rome"), following ZPARENT. Regular and smart folders.
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *paths;
/// Smart folders oldest first, each `@{ @"path": NSString, @"rules": NSDictionary }`.
@property (nonatomic, copy) NSArray<NSDictionary *> *smartFolders;
@end

@implementation SPKRegramFolders
@end

static SPKRegramFolders *SPKRegramReadFolders(sqlite3 *db) {
    SPKRegramFolders *folders = [SPKRegramFolders new];
    folders.paths = @{};
    folders.smartFolders = @[];
    BOOL hasSmart = SPKRegramTableHasColumn(db, "ZRGVFOLDER", "ZISSMART") && SPKRegramTableHasColumn(db, "ZRGVFOLDER", "ZSMARTRULES");
    NSString *sql = hasSmart ? @"SELECT Z_PK, ZPARENT, ZNAME, ZISSMART, ZSMARTRULES FROM ZRGVFOLDER ORDER BY ZCREATEDAT, Z_PK"
                             : @"SELECT Z_PK, ZPARENT, ZNAME, 0, NULL FROM ZRGVFOLDER ORDER BY Z_PK";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        return folders;  // export predates folders
    }
    NSMutableDictionary<NSNumber *, NSString *> *names = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *parents = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray *> *smart = [NSMutableArray array];  // [pk, rules] in creation order
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSNumber *pk = @(sqlite3_column_int64(stmt, 0));
        const unsigned char *name = sqlite3_column_text(stmt, 2);
        NSString *folderName = name ? [[NSString stringWithUTF8String:(const char *)name] stringByReplacingOccurrencesOfString:@"/" withString:@"-"] : nil;
        names[pk] = folderName.length ? folderName : @"Folder";
        if (sqlite3_column_type(stmt, 1) != SQLITE_NULL) {
            parents[pk] = @(sqlite3_column_int64(stmt, 1));
        }
        const unsigned char *rulesText = sqlite3_column_text(stmt, 4);
        if (sqlite3_column_int(stmt, 3) != 0 && rulesText) {
            NSData *json = [NSData dataWithBytes:rulesText length:strlen((const char *)rulesText)];
            NSDictionary *rules = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
            if ([rules isKindOfClass:[NSDictionary class]]) {
                [smart addObject:@[ pk, rules ]];
            }
        }
    }
    sqlite3_finalize(stmt);

    NSMutableDictionary<NSNumber *, NSString *> *paths = [NSMutableDictionary dictionary];
    for (NSNumber *pk in names) {
        NSMutableArray<NSString *> *components = [NSMutableArray array];
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (NSNumber *cursor = pk; cursor && names[cursor] && ![seen containsObject:cursor]; cursor = parents[cursor]) {
            [seen addObject:cursor];  // guards against a parent cycle in a damaged store
            [components insertObject:names[cursor] atIndex:0];
        }
        paths[pk] = [components componentsJoinedByString:@"/"];
    }
    folders.paths = paths;

    NSMutableArray<NSDictionary *> *smartFolders = [NSMutableArray array];
    for (NSArray *entry in smart) {
        NSString *path = paths[entry[0]];
        if (path.length) {
            [smartFolders addObject:@{@"path" : path, @"rules" : entry[1]}];
        }
    }
    folders.smartFolders = smartFolders;
    return folders;
}

static NSSet<NSNumber *> *SPKRegramRuleNumbers(id value) {
    NSMutableSet<NSNumber *> *set = [NSMutableSet set];
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value) {
            if ([item isKindOfClass:[NSNumber class]]) {
                [set addObject:@([item integerValue])];
            }
        }
    }
    return set;
}

// User pks as strings, from an array of strings or numbers, or a single value.
static NSSet<NSString *> *SPKRegramRuleUserIds(id value) {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    NSArray *items = [value isKindOfClass:[NSArray class]] ? value : (value ? @[ value ] : @[]);
    for (id item in items) {
        NSString *pk = [item isKindOfClass:[NSString class]] ? item : ([item isKindOfClass:[NSNumber class]] ? [item stringValue] : nil);
        if (pk.length > 0) {
            [set addObject:pk];
        }
    }
    return set;
}

// Whether a vault row matches a smart folder's rules, mirroring Regram's
// `-[RGVaultFilterQuery predicate]` (every present rule must hold):
//   types     ZTYPE IN set; asking for GIF (4) also matches images whose file ends in .gif
//   groups    the row's source group IN set (see SPKRegramGroupForSource)
//   favorites ZISFAVORITE, autoSave ZISAUTOSAVE
//   userIds   the owner's pk IN set (7.2+; 7.1 wrote a single userId, still read as a fallback)
//   excludedUserIds  the owner's pk NOT IN set (7.2+)
//   date      relative to now: 1 today, 2 last 7 days, 3 last 30 days, 4 older than 30 days,
//             5 older than a year. Evaluated at import time, the same view Regram shows today.
static BOOL SPKRegramRowMatchesRules(NSDictionary *row, NSDictionary *rules) {
    NSSet<NSNumber *> *types = SPKRegramRuleNumbers(rules[@"types"]);
    if (types.count > 0) {
        NSInteger type = [row[@"type"] integerValue];
        BOOL gifImage = type == 1 && [[row[@"basename"] lowercaseString] hasSuffix:@".gif"];
        if (![types containsObject:@(type)] && !([types containsObject:@4] && gifImage)) {
            return NO;
        }
    }
    NSSet<NSNumber *> *groups = SPKRegramRuleNumbers(rules[@"groups"]);
    if (groups.count > 0 && ![groups containsObject:@(SPKRegramGroupForSource([row[@"source"] intValue]))]) {
        return NO;
    }
    if ([rules[@"favorites"] respondsToSelector:@selector(boolValue)] && [rules[@"favorites"] boolValue] && ![row[@"favorite"] boolValue]) {
        return NO;
    }
    if ([rules[@"autoSave"] respondsToSelector:@selector(boolValue)] && [rules[@"autoSave"] boolValue] && ![row[@"autoSave"] boolValue]) {
        return NO;
    }
    NSString *userPK = row[@"userPK"] ?: @"";
    NSSet<NSString *> *userIds = SPKRegramRuleUserIds(rules[@"userIds"]);
    if (userIds.count == 0) {
        userIds = SPKRegramRuleUserIds(rules[@"userId"]);
    }
    if (userIds.count > 0 && ![userIds containsObject:userPK]) {
        return NO;
    }
    if ([SPKRegramRuleUserIds(rules[@"excludedUserIds"]) containsObject:userPK]) {
        return NO;
    }
    NSInteger dateRange = [rules[@"date"] respondsToSelector:@selector(integerValue)] ? [rules[@"date"] integerValue] : 0;
    if (dateRange > 0) {
        NSDate *date = row[@"date"];
        if (!date) {
            return NO;
        }
        NSCalendar *calendar = [NSCalendar currentCalendar];
        NSDate *now = [NSDate date];
        switch (dateRange) {
            case 1:
                return [date compare:[calendar startOfDayForDate:now]] != NSOrderedAscending;
            case 2:
                return [date compare:[calendar dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:now options:0]] != NSOrderedAscending;
            case 3:
                return [date compare:[calendar dateByAddingUnit:NSCalendarUnitDay value:-30 toDate:now options:0]] != NSOrderedAscending;
            case 4:
                return [date compare:[calendar dateByAddingUnit:NSCalendarUnitDay value:-30 toDate:now options:0]] == NSOrderedAscending;
            case 5:
                return [date compare:[calendar dateByAddingUnit:NSCalendarUnitYear value:-1 toDate:now options:0]] == NSOrderedAscending;
            default:
                break;
        }
    }
    return YES;
}

static NSArray<NSDictionary *> *SPKRegramReadRows(NSString *sqlitePath, NSString *filesRoot) {
    sqlite3 *db = NULL;
    // Read-write so SQLite can merge a WAL sidecar if the export wasn't checkpointed.
    if (sqlite3_open(sqlitePath.fileSystemRepresentation, &db) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        SPKLog(@"Regram", @"Could not open MediaVault.sqlite");
        return @[];
    }

    // Regram 7.1 replaced the per-file ZFOLDERPATH string with a ZFOLDER relation into ZRGVFOLDER
    // (named, nestable folders). Read whichever this export has so both generations import.
    // Smart folders hold no files; their contents are computed from rules, evaluated per row below.
    SPKRegramFolders *folders = SPKRegramReadFolders(db);
    NSString *folderColumn = SPKRegramTableHasColumn(db, "ZRGVFILE", "ZFOLDER") ? @"f.ZFOLDER" : @"NULL";
    NSString *autoSaveColumn = SPKRegramTableHasColumn(db, "ZRGVFILE", "ZISAUTOSAVE") ? @"f.ZISAUTOSAVE" : @"0";
    NSString *query = [NSString stringWithFormat:
                                    @"SELECT f.ZTYPE, f.ZSOURCE, f.ZISFAVORITE, f.ZRELATIVEPATH, f.ZFOLDERPATH, "
                                     "f.ZMEDIACODE, f.ZMEDIAID, f.ZWIDTH, f.ZHEIGHT, f.ZDURATION, f.ZDATE, "
                                     "u.ZUSERNAME, u.ZFULLNAME, u.ZPK, %@, %@ "
                                     "FROM ZRGVFILE f LEFT JOIN ZRGVUSER u ON f.ZUSER = u.Z_PK "
                                     "ORDER BY f.ZDATE",
                                    folderColumn, autoSaveColumn];
    const char *sql = query.UTF8String;

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        SPKLog(@"Regram", @"Unexpected MediaVault schema: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return @[];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];

    NSString *(^text)(int) = ^NSString *(int col) {
        const unsigned char *t = sqlite3_column_text(stmt, col);
        return t ? [NSString stringWithUTF8String:(const char *)t] : nil;
    };

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSString *relativePath = text(3);
        if (relativePath.length == 0) {
            continue;
        }
        NSString *mediaPath = [filesRoot stringByAppendingPathComponent:relativePath];
        if (![fm fileExistsAtPath:mediaPath]) {
            continue;  // orphaned DB row with no backing file
        }

        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"type"] = @(sqlite3_column_int(stmt, 0));
        row[@"source"] = @(sqlite3_column_int(stmt, 1));
        row[@"favorite"] = @(sqlite3_column_int(stmt, 2) != 0);
        row[@"path"] = mediaPath;
        row[@"basename"] = relativePath.lastPathComponent;
        if (text(5).length) {
            row[@"mediaCode"] = text(5);
        }
        if (text(6).length) {
            row[@"mediaId"] = text(6);
        }
        if (sqlite3_column_type(stmt, 7) != SQLITE_NULL) {
            row[@"width"] = @(sqlite3_column_double(stmt, 7));
        }
        if (sqlite3_column_type(stmt, 8) != SQLITE_NULL) {
            row[@"height"] = @(sqlite3_column_double(stmt, 8));
        }
        if (sqlite3_column_type(stmt, 9) != SQLITE_NULL) {
            row[@"duration"] = @(sqlite3_column_double(stmt, 9));
        }
        if (sqlite3_column_type(stmt, 10) != SQLITE_NULL) {
            row[@"date"] = [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(stmt, 10)];
        }
        if (text(11).length) {
            row[@"username"] = text(11);
        }
        if (text(12).length) {
            row[@"fullName"] = text(12);
        }
        if (text(13).length) {
            row[@"userPK"] = text(13);
        }
        row[@"autoSave"] = @(sqlite3_column_int(stmt, 15) != 0);
        // A Gallery file sits in one folder. A regular Regram folder wins; an unfiled row goes to the
        // first (oldest) smart folder whose rules it matches.
        NSString *folderPath = nil;
        if (sqlite3_column_type(stmt, 14) != SQLITE_NULL) {
            folderPath = folders.paths[@(sqlite3_column_int64(stmt, 14))];
        }
        if (folderPath.length == 0) {
            folderPath = text(4);
        }
        if (folderPath.length == 0) {
            for (NSDictionary *smartFolder in folders.smartFolders) {
                if (SPKRegramRowMatchesRules(row, smartFolder[@"rules"])) {
                    folderPath = smartFolder[@"path"];
                    break;
                }
            }
        }
        if (folderPath.length) {
            row[@"folderPath"] = folderPath;
        }
        [rows addObject:row];
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rows;
}

#pragma mark - Public reader API

@implementation SPKRegramImporter

+ (NSArray<NSDictionary *> *)vaultRowsFromPickedURL:(NSURL *)url password:(NSString *)password error:(NSError **)error {
    if (!url) {
        return nil;
    }
    NSString *root = SPKRegramWorkingRoot(url, password, error);
    if (!root) {
        return nil;
    }
    NSArray<NSString *> *sqlitePaths = SPKRegramLocateSQLites(root, password, error);
    if (sqlitePaths.count == 0) {
        return nil;  // not a Regram vault, or a password error set above
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *sqlitePath in sqlitePaths) {
        NSString *filesRoot = SPKRegramFilesRoot(sqlitePath);
        SPKLog(@"Regram", @"Vault sqlite=%@ filesRoot exists=%d", sqlitePath, [[NSFileManager defaultManager] fileExistsAtPath:filesRoot]);
        [rows addObjectsFromArray:SPKRegramReadRows(sqlitePath, filesRoot)];
    }
    return rows.count > 0 ? rows : nil;
}

+ (BOOL)isPasswordError:(NSError *)error {
    return [error.domain isEqualToString:@"SparkleSettingsTransfer"] &&
           (error.code == SPKZipPasswordRequiredErrorCode || error.code == SPKZipWrongPasswordErrorCode);
}

+ (NSString *)filePathForRow:(NSDictionary *)row {
    return row[@"path"];
}

+ (SPKGalleryMediaType)mediaTypeForRow:(NSDictionary *)row {
    return SPKRegramMediaType([row[@"type"] intValue], row[@"path"]);
}

+ (BOOL)isFavoriteRow:(NSDictionary *)row {
    return [row[@"favorite"] boolValue];
}

+ (NSString *)folderPathForRow:(NSDictionary *)row {
    return row[@"folderPath"];
}

+ (SPKGallerySaveMetadata *)metadataForRow:(NSDictionary *)row {
    SPKGallerySaveMetadata *meta = [SPKGallerySaveMetadata new];
    meta.source = (int16_t)SPKRegramSource([row[@"source"] intValue]);
    meta.sourceUsername = row[@"username"];
    meta.sourceUserPK = row[@"userPK"];
    meta.sourceFullName = row[@"fullName"];
    meta.sourceMediaCode = row[@"mediaCode"];
    meta.sourceMediaPK = SPKRegramMediaPK(row[@"mediaId"]);
    if ([row[@"width"] doubleValue] > 0) {
        meta.pixelWidth = (int32_t)[row[@"width"] doubleValue];
    }
    if ([row[@"height"] doubleValue] > 0) {
        meta.pixelHeight = (int32_t)[row[@"height"] doubleValue];
    }
    if ([row[@"duration"] doubleValue] > 0) {
        meta.durationSeconds = [row[@"duration"] doubleValue];
    }
    meta.importCapturedDate = row[@"date"];
    // Fill gaps (posted date, and source/user when the DB was sparse) from the Regram basename,
    // which shares Sparkle's own `epoch_user_slug_date` filename layout.
    SPKGalleryApplyImportHeuristicsFromFilename(row[@"basename"], meta);
    return meta;
}

@end
