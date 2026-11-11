#import "SPKExportFileNaming.h"

#import "SPKStrings.h"
#import "../../Utils.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"

NSString *const kSPKExportNamePartsKey = @"downloads_filename_parts";
NSString *const kSPKExportNameSeparatorKey = @"downloads_filename_separator";
NSString *const kSPKExportNameDateStyleKey = @"downloads_filename_date_style";
NSString *const kSPKExportNamePhotosKey = @"downloads_filename_photos";
NSString *const kSPKExportNameShareKey = @"downloads_filename_share";

NSString *const SPKExportNamePartUsername = @"username";
NSString *const SPKExportNamePartSource = @"source";
NSString *const SPKExportNamePartPostedDate = @"posted_date";
NSString *const SPKExportNamePartSavedDate = @"saved_date";
NSString *const SPKExportNamePartPostID = @"post_id";

// Longest single part kept in a name, so one odd value cannot push the whole
// name past the file system's 255-byte limit.
static NSUInteger const kSPKExportPartMaxLength = 64;
// Leftover share folders older than this are removed on the next export.
static NSTimeInterval const kSPKExportTemporaryLifetime = 60.0 * 60.0;

NSArray<NSString *> *SPKExportNameAllParts(void) {
    return @[ SPKExportNamePartUsername, SPKExportNamePartSource, SPKExportNamePartPostedDate, SPKExportNamePartSavedDate, SPKExportNamePartPostID ];
}

NSArray<NSString *> *SPKExportNameEnabledParts(void) {
    NSString *stored = [SPKUtils getStringPref:kSPKExportNamePartsKey];
    NSArray<NSString *> *known = SPKExportNameAllParts();
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *raw in [stored ?: @"" componentsSeparatedByString:@","]) {
        NSString *part = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([known containsObject:part] && ![parts containsObject:part]) {
            [parts addObject:part];
        }
    }
    return parts;
}

void SPKExportNameSetEnabledParts(NSArray<NSString *> *parts) {
    NSString *value = [parts ?: @[] componentsJoinedByString:@","];
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:SPKEffectivePreferenceKey(kSPKExportNamePartsKey)];
}

NSString *SPKExportNamePartTitle(NSString *part) {
    if ([part isEqualToString:SPKExportNamePartUsername])
        return SPKL(@"DOWNLOADS_FILE_NAMES_PART_USERNAME_TITLE");
    if ([part isEqualToString:SPKExportNamePartSource])
        return SPKL(@"DOWNLOADS_FILE_NAMES_PART_SOURCE_TITLE");
    if ([part isEqualToString:SPKExportNamePartPostedDate])
        return SPKL(@"DOWNLOADS_FILE_NAMES_PART_POSTED_DATE_TITLE");
    if ([part isEqualToString:SPKExportNamePartSavedDate])
        return SPKL(@"DOWNLOADS_FILE_NAMES_PART_SAVED_DATE_TITLE");
    if ([part isEqualToString:SPKExportNamePartPostID])
        return SPKL(@"DOWNLOADS_FILE_NAMES_PART_POST_ID_TITLE");
    return part;
}

BOOL SPKExportNamingAppliesToDestination(SPKDownloadDestination destination) {
    switch (destination) {
    case SPKDownloadDestinationPhotos:
        return [SPKUtils getBoolPref:kSPKExportNamePhotosKey];
    case SPKDownloadDestinationShare:
        return [SPKUtils getBoolPref:kSPKExportNameShareKey];
    default:
        return NO;
    }
}

static NSString *SPKExportSeparator(void) {
    NSString *value = [SPKUtils getStringPref:kSPKExportNameSeparatorKey];
    if ([value isEqualToString:@"dash"])
        return @"-";
    if ([value isEqualToString:@"space"])
        return @" ";
    return @"_";
}

static NSDateFormatter *SPKExportDateFormatter(NSString *format) {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    @synchronized(cache) {
        NSDateFormatter *formatter = cache[format];
        if (!formatter) {
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone localTimeZone];
            formatter.dateFormat = format;
            cache[format] = formatter;
        }
        return formatter;
    }
}

static NSString *SPKExportDateString(NSDate *date, NSString *separator) {
    NSString *style = [SPKUtils getStringPref:kSPKExportNameDateStyleKey];
    if ([style isEqualToString:@"compact"])
        return [SPKExportDateFormatter(@"yyyyMMddHHmmss") stringFromDate:date];
    NSString *day = [SPKExportDateFormatter(@"yyyy-MM-dd") stringFromDate:date];
    if ([style isEqualToString:@"date"])
        return day;
    // Dots in the time, as macOS screenshots do: colons are not allowed in Files.
    return [NSString stringWithFormat:@"%@%@%@", day, separator, [SPKExportDateFormatter(@"HH.mm.ss") stringFromDate:date]];
}

/// One part made safe for a file name: no path separators, colons, reserved
/// characters or control characters, and no leading dot that would hide the file.
static NSString *SPKExportSanitizedPart(NSString *raw) {
    if (raw.length == 0)
        return @"";
    NSMutableCharacterSet *invalid = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    [invalid formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    [invalid formUnionWithCharacterSet:NSCharacterSet.newlineCharacterSet];
    NSString *cleaned = [[raw componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"-"];
    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .-"]];
    if (cleaned.length > kSPKExportPartMaxLength) {
        NSRange range = [cleaned rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kSPKExportPartMaxLength)];
        cleaned = [cleaned substringWithRange:range];
    }
    return cleaned;
}

static NSString *SPKExportSourceLabel(SPKGallerySaveMetadata *metadata) {
    SPKGallerySource source = metadata ? (SPKGallerySource)metadata.source : SPKGallerySourceOther;
    return [SPKGalleryFile labelForSource:source];
}

NSString *SPKExportFileNameStem(SPKGallerySaveMetadata *metadata, NSString *sourceFileName) {
    NSArray<NSString *> *parts = SPKExportNameEnabledParts();
    if (parts.count == 0)
        return nil;

    // Default names stamp the posted date with the save time when Instagram gave
    // none, so a posted date equal to the save time is not a real one. A Gallery
    // original's own name still holds both dates, which metadata rebuilt from the
    // Gallery row loses.
    NSDate *saved = metadata.importCapturedDate;
    NSDate *posted = metadata.importPostedDate;
    BOOL postedKnown = posted && !(saved && fabs([posted timeIntervalSinceDate:saved]) < 1.0);
    if (!postedKnown) {
        NSDate *parsedSaved = nil;
        NSDate *parsedPosted = nil;
        if (SPKGalleryParseSparkleFilenameDates(sourceFileName, &parsedSaved, &parsedPosted)) {
            saved = parsedSaved;
            posted = parsedPosted;
        }
    }
    NSDate *now = [NSDate date];
    saved = saved ?: now;
    posted = posted ?: saved;

    NSString *separator = SPKExportSeparator();
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *value = nil;
        if ([part isEqualToString:SPKExportNamePartUsername]) {
            value = metadata.sourceUsername;
            // "audio" is the placeholder older audio saves carry instead of a handle.
            if ([value.lowercaseString isEqualToString:@"audio"])
                value = nil;
            // A name that is not a handle, such as a song's artist.
            if (value.length == 0)
                value = metadata.importFileNameStem;
            // Without a username the source still says where the file came from,
            // unless the user already shows it as its own part.
            if (value.length == 0 && ![parts containsObject:SPKExportNamePartSource])
                value = SPKExportSourceLabel(metadata);
        } else if ([part isEqualToString:SPKExportNamePartSource]) {
            value = SPKExportSourceLabel(metadata);
        } else if ([part isEqualToString:SPKExportNamePartPostedDate]) {
            value = SPKExportDateString(posted, separator);
        } else if ([part isEqualToString:SPKExportNamePartSavedDate]) {
            value = SPKExportDateString(saved, separator);
        } else if ([part isEqualToString:SPKExportNamePartPostID]) {
            value = metadata.sourceMediaCode.length ? metadata.sourceMediaCode : metadata.sourceMediaPK;
        }
        NSString *clean = SPKExportSanitizedPart(value);
        if (clean.length > 0)
            [components addObject:clean];
    }
    if (components.count == 0)
        return nil;
    return [components componentsJoinedByString:separator];
}

NSString *SPKExportFileNameAppendingIndex(NSString *stem, NSInteger position) {
    return [NSString stringWithFormat:@"%@%@%ld", stem, SPKExportSeparator(), (long)position];
}

NSString *SPKExportUniquePath(NSString *directory, NSString *stem, NSString *extension, NSString *ownPath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *(^pathFor)(NSString *) = ^NSString *(NSString *name) {
        NSString *file = extension.length ? [name stringByAppendingPathExtension:extension] : name;
        return [directory stringByAppendingPathComponent:file];
    };
    NSString *candidate = pathFor(stem);
    for (NSInteger position = 2; [fm fileExistsAtPath:candidate] && ![candidate isEqualToString:ownPath]; position++) {
        candidate = pathFor(SPKExportFileNameAppendingIndex(stem, position));
    }
    return candidate;
}

static NSString *SPKExportTemporaryRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"SparkleExport"];
}

static void SPKExportPruneTemporaryRoot(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = SPKExportTemporaryRoot();
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kSPKExportTemporaryLifetime];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSDate *modified = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified && [modified compare:cutoff] == NSOrderedAscending)
            [fm removeItemAtPath:path error:nil];
    }
}

NSArray<NSURL *> *SPKExportShareableFileURLs(NSArray<NSURL *> *fileURLs, NSArray<SPKGallerySaveMetadata *> *metadata, SPKDownloadDestination destination) {
    if (fileURLs.count == 0 || !SPKExportNamingAppliesToDestination(destination))
        return fileURLs ?: @[];

    SPKExportPruneTemporaryRoot();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = [SPKExportTemporaryRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil])
        return fileURLs;

    NSMutableArray<NSURL *> *result = [NSMutableArray arrayWithCapacity:fileURLs.count];
    [fileURLs enumerateObjectsUsingBlock:^(NSURL *fileURL, NSUInteger index, BOOL *stop) {
        SPKGallerySaveMetadata *meta = index < metadata.count ? metadata[index] : nil;
        if ([meta isKindOfClass:NSNull.class])
            meta = nil;
        NSString *stem = fileURL.isFileURL ? SPKExportFileNameStem(meta, fileURL.lastPathComponent) : nil;
        if (stem.length == 0) {
            [result addObject:fileURL];
            return;
        }
        NSString *target = SPKExportUniquePath(directory, stem, fileURL.pathExtension, nil);
        NSURL *targetURL = [NSURL fileURLWithPath:target];
        // A hard link costs nothing and leaves the original alone; a copy (an APFS
        // clone) covers the case where the two sit on different volumes.
        if ([fm linkItemAtURL:fileURL toURL:targetURL error:nil] || [fm copyItemAtURL:fileURL toURL:targetURL error:nil]) {
            [result addObject:targetURL];
        } else {
            [result addObject:fileURL];
        }
    }];
    return result;
}

NSURL *SPKExportShareableFileURL(NSURL *fileURL, SPKGallerySaveMetadata *metadata, SPKDownloadDestination destination) {
    if (!fileURL)
        return fileURL;
    NSArray *meta = metadata ? @[ metadata ] : @[];
    return SPKExportShareableFileURLs(@[ fileURL ], meta, destination).firstObject ?: fileURL;
}

NSString *SPKExportFileNamePreview(void) {
    SPKGallerySaveMetadata *sample = [[SPKGallerySaveMetadata alloc] init];
    sample.source = SPKGallerySourceFeed;
    sample.sourceUsername = @"instagram";
    sample.sourceMediaCode = @"C9xQ2mLpR4k";
    NSDate *now = [NSDate date];
    sample.importCapturedDate = now;
    sample.importPostedDate = [now dateByAddingTimeInterval:-26.0 * 60.0 * 60.0];
    NSString *stem = SPKExportFileNameStem(sample, nil);
    return [(stem.length ? stem : sample.sourceUsername) stringByAppendingPathExtension:@"jpg"];
}
