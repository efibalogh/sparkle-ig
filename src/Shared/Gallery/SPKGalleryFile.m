#import "SPKStrings.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <ctype.h>
#import <math.h>

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryOriginController.h"
#import "SPKGalleryPaths.h"

static CGFloat const kThumbnailSize = 300.0;

static NSCache<NSString *, UIImage *> *SPKGalleryThumbnailCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 2000;
        cache.totalCostLimit = 64 * 1024 * 1024; // 64 MB
    });
    return cache;
}

static dispatch_queue_t SPKGalleryThumbnailStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.sparkle.gallery.thumbnail-state", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Reads and decodes off the main thread. UIImage(contentsOfFile:) only maps the
// file and defers the JPEG decode to the CA commit, so a grid that loads
// thumbnails inside cellForItemAtIndexPath pays a decode per cell on the main
// thread while scrolling. Loads run here instead.
// Serial on purpose. A fast scroll enqueues a load for every cell that passes,
// and each block does blocking file I/O -- on a concurrent queue GCD reacts to
// the blocked threads by spawning more, up to dozens, which saturates every core
// and starves the main thread that the scroll is running on. Decoding a 300px
// thumbnail is ~1ms, so one queue drains a backlog fast enough and costs the
// scroll nothing.
static dispatch_queue_t SPKGalleryThumbnailLoadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                             QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.sparkle.gallery.thumbnail-load", attr);
    });
    return queue;
}

static dispatch_queue_t SPKGalleryThumbnailRenderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                             QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.sparkle.gallery.thumbnail-render", attr);
    });
    return queue;
}

// Forces the decode now, so what lands in the cache is a ready-to-draw bitmap
// and the main thread only has to blit it.
static UIImage *SPKGalleryDecodedImage(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return image;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return image;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return image;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), cgImage);
    CGImageRef decoded = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!decoded) {
        return image;
    }

    UIImage *result = [UIImage imageWithCGImage:decoded scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(decoded);
    return result;
}

static NSUInteger SPKGalleryImageCacheCost(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (cgImage) {
        return CGImageGetHeight(cgImage) * CGImageGetBytesPerRow(cgImage);
    }
    return (NSUInteger)(image.size.width * image.size.height * 4.0);
}

static void SPKGalleryCacheThumbnail(UIImage *image, NSString *thumbPath) {
    if (!image || thumbPath.length == 0) {
        return;
    }
    [SPKGalleryThumbnailCache() setObject:image forKey:thumbPath cost:SPKGalleryImageCacheCost(image)];
}

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(BOOL success)> *> *SPKGalleryThumbnailCompletions(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<void (^)(BOOL success)> *> *completions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        completions = [NSMutableDictionary dictionary];
    });
    return completions;
}

static NSString *SPKGalleryNormalizedExtension(NSString *_Nullable origExt, SPKGalleryMediaType mediaType) {
    NSString *e = origExt.length ? origExt.lowercaseString : @"";
    static NSSet<NSString *> *imageExts;
    static NSSet<NSString *> *videoExts;
    static NSSet<NSString *> *audioExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExts = [NSSet setWithArray:@[ @"jpg", @"jpeg", @"png", @"heic", @"webp", @"gif" ]];
        videoExts = [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v", @"webm" ]];
        audioExts = [NSSet setWithArray:@[ @"m4a", @"aac", @"mp3", @"wav", @"caf", @"aiff", @"flac", @"opus", @"ogg" ]];
    });
    // Only keep the original extension when it belongs to the SAME category as the
    // requested media type. Otherwise we'd e.g. keep a ".mp4" extension for audio
    // (audio extracted from a video container), which makes the file look like a
    // video to every downstream extension-based check and breaks duplicate detection.
    if (e.length > 0 && e.length <= 5) {
        if (mediaType == SPKGalleryMediaTypeAudio && [audioExts containsObject:e])
            return e;
        if (mediaType == SPKGalleryMediaTypeVideo && [videoExts containsObject:e])
            return e;
        if (mediaType == SPKGalleryMediaTypeImage && [imageExts containsObject:e]) {
            return [e isEqualToString:@"jpeg"] ? @"jpg" : e;
        }
    }
    if (mediaType == SPKGalleryMediaTypeAudio)
        return @"m4a";
    return (mediaType == SPKGalleryMediaTypeVideo) ? @"mp4" : @"jpg";
}

static NSString *SPKGallerySourceSlug(SPKGallerySource source) {
    switch (source) {
    case SPKGallerySourceFeed:
        return @"feed";
    case SPKGallerySourceStories:
        return @"story";
    case SPKGallerySourceReels:
        return @"reel";
    case SPKGallerySourceProfile:
        return @"profile-photo";
    case SPKGallerySourceDMs:
        return @"dms";
    case SPKGallerySourceThumbnail:
        return @"thumbnail";
    case SPKGallerySourceInstants:
        return @"instants";
    case SPKGallerySourceAudioPage:
        return @"audio-page";
    case SPKGallerySourceComments:
        return @"comments";
    case SPKGallerySourceOther:
    default:
        return @"other";
    }
}

/// Path component for a canonical web post/reel link (`/p/` or `/reel/`). Stories are intentionally excluded — they use `/stories/<user>/<pk>/` instead, built separately. Returns nil for sources that have no shareable post link.
static NSString *SPKGalleryPostPathComponentForSource(SPKGallerySource source) {
    switch (source) {
    case SPKGallerySourceReels:
        return @"reel";
    case SPKGallerySourceFeed:
    case SPKGallerySourceProfile:
    case SPKGallerySourceOther:
        return @"p";
    default:
        return nil;
    }
}

static long long SPKEpochMillisecondsForDate(NSDate *date) {
    NSTimeInterval interval = [date timeIntervalSince1970];
    if (interval <= 0.0) {
        interval = [[NSDate date] timeIntervalSince1970];
    }
    return (long long)llround(interval * 1000.0);
}

/// Safe single path segment: ASCII-ish, no path separators.
static NSString *SPKSanitizedGalleryUsername(NSString *raw) {
    if (!raw.length) {
        return @"";
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:MIN((NSUInteger)48, raw.length)];
    NSUInteger maxLen = 48;
    [raw enumerateSubstringsInRange:NSMakeRange(0, raw.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *_Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                             if (out.length >= maxLen) {
                                 *stop = YES;
                                 return;
                             }
                             if (substring.length != 1) {
                                 [out appendString:@"_"];
                                 return;
                             }
                             unichar c = [substring characterAtIndex:0];
                             if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
                                 [out appendString:substring];
                             } else if (c == ' ') {
                                 [out appendString:@"_"];
                             } else {
                                 [out appendString:@"_"];
                             }
                         }];
    NSString *collapsed = [out stringByReplacingOccurrencesOfString:@"__" withString:@"_"];
    while ([collapsed containsString:@"__"]) {
        collapsed = [collapsed stringByReplacingOccurrencesOfString:@"__" withString:@"_"];
    }
    collapsed = [collapsed stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._-"]];
    return collapsed.length ? collapsed : @"user";
}

static BOOL SPKDigitsOnlyString(NSString *s) {
    if (s.length == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < s.length; i++) {
        if (!isdigit((unsigned char)[s characterAtIndex:i])) {
            return NO;
        }
    }
    return YES;
}

static NSDate *_Nullable SPKParseCompactDigitDateFromString(NSString *s) {
    if (!SPKDigitsOnlyString(s)) {
        return nil;
    }
    NSUInteger n = s.length;
    if (n != 8 && n != 12 && n != 14) {
        return nil;
    }
    static NSDateFormatter *fmt8;
    static NSDateFormatter *fmt12;
    static NSDateFormatter *fmt14;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt8 = [[NSDateFormatter alloc] init];
        fmt8.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt8.timeZone = [NSTimeZone localTimeZone];
        fmt8.dateFormat = @"yyyyMMdd";

        fmt12 = [[NSDateFormatter alloc] init];
        fmt12.locale = fmt8.locale;
        fmt12.timeZone = fmt8.timeZone;
        fmt12.dateFormat = @"yyyyMMddHHmm";

        fmt14 = [[NSDateFormatter alloc] init];
        fmt14.locale = fmt8.locale;
        fmt14.timeZone = fmt8.timeZone;
        fmt14.dateFormat = @"yyyyMMddHHmmss";
    });
    if (n == 14) {
        return [fmt14 dateFromString:s];
    }
    if (n == 12) {
        return [fmt12 dateFromString:s];
    }
    return [fmt8 dateFromString:s];
}

/// Parses unix epoch seconds/milliseconds, with sanity bounds to avoid confusing user ids for timestamps.
static NSDate *_Nullable SPKParseEpochDateFromString(NSString *s) {
    if (!SPKDigitsOnlyString(s)) {
        return nil;
    }
    if (s.length < 10 || s.length > 13) {
        return nil;
    }
    unsigned long long raw = strtoull(s.UTF8String, NULL, 10);
    if (raw == 0ULL) {
        return nil;
    }
    NSTimeInterval seconds = (s.length >= 13) ? ((NSTimeInterval)raw / 1000.0) : (NSTimeInterval)raw;
    // Keep plausible Instagram-era timestamps and avoid treating pk values as epochs.
    if (seconds < 946684800.0 || seconds > 4102444800.0) { // 2000-01-01 ... 2100-01-01
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

/// Recognizes slug segments matching `SPKGallerySourceSlug` output (feed, story, reel, ...).
/// Also recognizes Regram's own basename slugs (tv, dm-story, dm-note, post-audio, highlight-cover)
/// so imported Regram media strips the slug token instead of folding it into the username — see
/// SPKRegramImporter for the full source-value → slug table.
static BOOL SPKSourceFromBasenameSlug(NSString *low, SPKGallerySource *out) {
    if ([low isEqualToString:@"feed"]) {
        *out = SPKGallerySourceFeed;
        return YES;
    }
    if ([low isEqualToString:@"story"] || [low isEqualToString:@"stories"]) {
        *out = SPKGallerySourceStories;
        return YES;
    }
    if ([low isEqualToString:@"reel"] || [low isEqualToString:@"reels"] || [low isEqualToString:@"tv"]) {
        *out = SPKGallerySourceReels;
        return YES;
    }
    if ([low isEqualToString:@"profile"] || [low isEqualToString:@"profile-photo"] || [low isEqualToString:@"profilephoto"]) {
        *out = SPKGallerySourceProfile;
        return YES;
    }
    if ([low isEqualToString:@"dm"] || [low isEqualToString:@"dms"] || [low isEqualToString:@"dm-story"] ||
        [low isEqualToString:@"dm-note"]) {
        *out = SPKGallerySourceDMs;
        return YES;
    }
    if ([low isEqualToString:@"thumbnail"] || [low isEqualToString:@"thumb"] || [low isEqualToString:@"cover"] ||
        [low isEqualToString:@"highlight-cover"]) {
        *out = SPKGallerySourceThumbnail;
        return YES;
    }
    if ([low isEqualToString:@"instant"] || [low isEqualToString:@"instants"]) {
        *out = SPKGallerySourceInstants;
        return YES;
    }
    if ([low isEqualToString:@"audio"] || [low isEqualToString:@"audio-page"] || [low isEqualToString:@"audiopage"] ||
        [low isEqualToString:@"post-audio"]) {
        *out = SPKGallerySourceAudioPage;
        return YES;
    }
    if ([low isEqualToString:@"comment"] || [low isEqualToString:@"comments"]) {
        *out = SPKGallerySourceComments;
        return YES;
    }
    if ([low isEqualToString:@"other"]) {
        *out = SPKGallerySourceOther;
        return YES;
    }
    return NO;
}

void SPKGalleryApplyImportHeuristicsFromFilename(NSString *fileName, SPKGallerySaveMetadata *m) {
    if (!fileName.length || !m) {
        return;
    }
    NSString *stem = [fileName lastPathComponent].stringByDeletingPathExtension;
    if (stem.length == 0) {
        return;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *p in [stem componentsSeparatedByString:@"_"]) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length > 0) {
            [parts addObject:t];
        }
    }
    if (parts.count == 0) {
        return;
    }

    BOOL hasLeadEpoch = NO;
    NSDate *leadEpochDate = SPKParseEpochDateFromString(parts.firstObject);
    if (leadEpochDate) {
        hasLeadEpoch = YES;
        if (!m.importCapturedDate) {
            m.importCapturedDate = leadEpochDate;
        }
        [parts removeObjectAtIndex:0];
    }
    if (parts.count == 0) {
        return;
    }

    BOOL hasTrailDate = NO;
    NSDate *trailDate = SPKParseCompactDigitDateFromString(parts.lastObject);
    if (trailDate) {
        hasTrailDate = YES;
        if (!m.importPostedDate) {
            m.importPostedDate = trailDate;
        }
        // Backward-compatible fallback: if no epoch/save-time token exists, use trailing date.
        if (!m.importCapturedDate) {
            m.importCapturedDate = trailDate;
        }
        [parts removeLastObject];
    }
    if (parts.count == 0) {
        return;
    }

    NSString *slugLow = parts.lastObject.lowercaseString;
    SPKGallerySource slugSource = SPKGallerySourceOther;
    if (SPKSourceFromBasenameSlug(slugLow, &slugSource)) {
        if (m.source == (int16_t)SPKGallerySourceOther) {
            m.source = (int16_t)slugSource;
        }
        [parts removeLastObject];
    }
    if (parts.count == 0) {
        return;
    }

    // Only auto-fill a username when the filename matches Sparkle's own export layout
    // (epoch_user_slug_date — see SPKFileNameForMedia). For arbitrary Files, leave the username
    // blank rather than guessing a handle from an unrelated file name.
    if (!(hasLeadEpoch && hasTrailDate)) {
        return;
    }

    // The remaining parts are the username region. A leading digits-only token is the user pk;
    // rejoin everything after it with "_" so usernames containing underscores survive (this is
    // the inverse of SPKSanitizedGalleryUsername).
    NSUInteger usernameStart = 0;
    if (parts.count >= 2 && SPKDigitsOnlyString(parts[0])) {
        if (!m.sourceUserPK.length) {
            m.sourceUserPK = parts[0];
        }
        usernameStart = 1;
    }
    NSArray<NSString *> *usernameParts =
        [parts subarrayWithRange:NSMakeRange(usernameStart, parts.count - usernameStart)];
    NSString *username = [usernameParts componentsJoinedByString:@"_"];
    if (username.length == 0) {
        return;
    }
    if (SPKDigitsOnlyString(username)) {
        if (!m.sourceUserPK.length) {
            m.sourceUserPK = username;
        }
    } else if (!m.sourceUsername.length) {
        m.sourceUsername = username;
        [SPKGalleryOriginController populateProfileMetadata:m username:username user:nil];
    }
}

NSString *SPKFileNameForMedia(NSURL *fileURL,
                              SPKGalleryMediaType mediaType,
                              SPKGallerySaveMetadata *_Nullable metadata) {
    NSString *orig = fileURL.lastPathComponent ?: @"";
    NSString *origExt = orig.pathExtension;
    NSString *ext = SPKGalleryNormalizedExtension(origExt, mediaType);

    static NSDateFormatter *compactDateFmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        compactDateFmt = [[NSDateFormatter alloc] init];
        compactDateFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        compactDateFmt.timeZone = [NSTimeZone localTimeZone];
        compactDateFmt.dateFormat = @"yyyyMMddHHmmss";
    });
    NSDate *saveDate = metadata.importCapturedDate ?: [NSDate date];
    if (metadata && !metadata.importCapturedDate) {
        metadata.importCapturedDate = saveDate;
    }
    NSDate *postedDate = metadata.importPostedDate ?: saveDate;
    if (metadata && !metadata.importPostedDate) {
        metadata.importPostedDate = postedDate;
    }
    NSString *dateCompact = [compactDateFmt stringFromDate:postedDate];
    NSString *epoch = [NSString stringWithFormat:@"%lld", SPKEpochMillisecondsForDate(saveDate)];

    SPKGallerySource src = metadata ? (SPKGallerySource)metadata.source : SPKGallerySourceOther;
    NSString *slug = SPKGallerySourceSlug(src);
    NSString *user = @"media";

    if (metadata.importFileNameStem.length > 0) {
        NSString *sanitizedStem = SPKSanitizedGalleryUsername(metadata.importFileNameStem);
        if (sanitizedStem.length > 0) {
            user = sanitizedStem;
        }
    } else if (metadata.sourceUsername.length > 0) {
        NSString *sanitizedUser = SPKSanitizedGalleryUsername(metadata.sourceUsername);
        if (sanitizedUser.length > 0) {
            user = sanitizedUser;
        }
    }

    return [NSString stringWithFormat:@"%@_%@_%@_%@.%@", epoch, user, slug, dateCompact, ext];
}

@implementation SPKGalleryFile

@dynamic identifier;
@dynamic relativePath;
@dynamic mediaType;
@dynamic source;
@dynamic dateAdded;
@dynamic fileSize;
@dynamic isFavorite;
@dynamic isAutoSave;
@dynamic folderPath;
@dynamic customName;
@dynamic sourceUsername;
@dynamic sourceUserPK;
@dynamic sourceProfileURLString;
@dynamic sourceMediaPK;
@dynamic sourceMediaCode;
@dynamic sourceMediaURLString;
@dynamic pixelWidth;
@dynamic pixelHeight;
@dynamic durationSeconds;
@dynamic ownerAccountPK;
@dynamic ownerUsername;

#pragma mark - Save to Gallery

+ (SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                               source:(SPKGallerySource)source
                            mediaType:(SPKGalleryMediaType)mediaType
                                error:(NSError **)error {
    return [self saveFileToGallery:fileURL source:source mediaType:mediaType folderPath:nil metadata:nil error:error];
}

+ (SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                               source:(SPKGallerySource)source
                            mediaType:(SPKGalleryMediaType)mediaType
                           folderPath:(NSString *)folderPath
                                error:(NSError **)error {
    return [self saveFileToGallery:fileURL source:source mediaType:mediaType folderPath:folderPath metadata:nil error:error];
}

+ (void)applyMetadata:(nullable SPKGallerySaveMetadata *)metadata toFile:(SPKGalleryFile *)file fallbackSource:(SPKGallerySource)fallbackSource {
    if (metadata) {
        file.source = metadata.source;
        file.sourceUsername = metadata.sourceUsername.length ? metadata.sourceUsername : nil;
        file.sourceUserPK = metadata.sourceUserPK.length ? metadata.sourceUserPK : nil;
        file.sourceProfileURLString = metadata.sourceProfileURLString.length ? metadata.sourceProfileURLString : nil;
        file.sourceMediaPK = metadata.sourceMediaPK.length ? metadata.sourceMediaPK : nil;
        file.sourceMediaCode = metadata.sourceMediaCode.length ? metadata.sourceMediaCode : nil;
        file.sourceMediaURLString = metadata.sourceMediaURLString.length ? metadata.sourceMediaURLString : nil;
        file.pixelWidth = metadata.pixelWidth;
        file.pixelHeight = metadata.pixelHeight;
        file.durationSeconds = metadata.durationSeconds;
        file.customName = metadata.customName.length ? metadata.customName : nil;
        file.isAutoSave = metadata.isAutoSave;
    } else {
        file.source = fallbackSource;
        file.sourceUsername = nil;
        file.sourceUserPK = nil;
        file.sourceProfileURLString = nil;
        file.sourceMediaPK = nil;
        file.sourceMediaCode = nil;
        file.sourceMediaURLString = nil;
        file.pixelWidth = 0;
        file.pixelHeight = 0;
        file.durationSeconds = 0;
        file.customName = nil;
        file.isAutoSave = NO;
    }
}

+ (NSFetchRequest *)unassignedFetchRequest {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"SPKGalleryFile"];
    request.predicate = [NSPredicate predicateWithFormat:@"ownerAccountPK == nil OR ownerAccountPK == ''"];
    return request;
}

+ (NSUInteger)unassignedFileCount {
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSUInteger count = [ctx countForFetchRequest:[self unassignedFetchRequest] error:nil];
    return count == NSNotFound ? 0 : count;
}

+ (NSUInteger)claimUnassignedFilesForAccountPK:(NSString *)pk username:(NSString *)username {
    if (pk.length == 0)
        return 0;
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSArray<SPKGalleryFile *> *files = [ctx executeFetchRequest:[self unassignedFetchRequest] error:nil];
    for (SPKGalleryFile *file in files) {
        file.ownerAccountPK = pk;
        file.ownerUsername = username.length > 0 ? username : nil;
    }
    if (files.count > 0)
        [[SPKGalleryCoreDataStack shared] saveContext];
    return files.count;
}

+ (SPKGalleryMediaType)inferMediaTypeFromFileURL:(NSURL *)fileURL {
    NSString *e = fileURL.pathExtension.lowercaseString;
    static NSSet<NSString *> *videoExts;
    static NSSet<NSString *> *audioExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExts = [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v", @"webm" ]];
        audioExts = [NSSet setWithArray:@[ @"m4a", @"aac", @"mp3", @"wav", @"caf", @"aiff", @"flac", @"opus", @"ogg" ]];
    });
    if ([audioExts containsObject:e]) {
        return SPKGalleryMediaTypeAudio;
    }
    if ([videoExts containsObject:e]) {
        return SPKGalleryMediaTypeVideo;
    }
    return SPKGalleryMediaTypeImage;
}

+ (void)probeMediaAtPath:(NSString *)path mediaType:(SPKGalleryMediaType)mediaType file:(SPKGalleryFile *)file {
    if (mediaType == SPKGalleryMediaTypeImage) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!src) {
            return;
        }
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!props) {
            return;
        }
        NSNumber *w = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
        NSNumber *h = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
        if (file.pixelWidth <= 0 && [w respondsToSelector:@selector(intValue)]) {
            file.pixelWidth = (int32_t)w.intValue;
        }
        if (file.pixelHeight <= 0 && [h respondsToSelector:@selector(intValue)]) {
            file.pixelHeight = (int32_t)h.intValue;
        }
        CFRelease(props);
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    CMTime dur = asset.duration;
    if (file.durationSeconds <= 0.05 && CMTIME_IS_NUMERIC(dur)) {
        double sec = CMTimeGetSeconds(dur);
        if (sec > 0.05 && !isnan(sec)) {
            file.durationSeconds = sec;
        }
    }
    if (mediaType == SPKGalleryMediaTypeAudio) {
        return;
    }

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        return;
    }
    AVAssetTrack *track = tracks.firstObject;
    CGSize natural = track.naturalSize;
    CGAffineTransform tx = track.preferredTransform;
    CGSize rendered = CGSizeApplyAffineTransform(natural, tx);
    int32_t w = (int32_t)lround(fabs(rendered.width));
    int32_t h = (int32_t)lround(fabs(rendered.height));
    if (file.pixelWidth <= 0) {
        file.pixelWidth = w;
    }
    if (file.pixelHeight <= 0) {
        file.pixelHeight = h;
    }
}

+ (SPKGalleryFile *)saveFileToGallery:(NSURL *)fileURL
                               source:(SPKGallerySource)source
                            mediaType:(SPKGalleryMediaType)mediaType
                           folderPath:(NSString *)folderPath
                             metadata:(SPKGallerySaveMetadata *)metadata
                                error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:fileURL.path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPKGallery"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : SPKL(@"GALLERY_GALLERY_FILE_SOURCE_FILE_NOT_EXIST_TEXT")}];
        }
        return nil;
    }

    NSString *fileName = SPKFileNameForMedia(fileURL, mediaType, metadata);
    NSString *destPath = [[SPKGalleryPaths galleryMediaDirectory] stringByAppendingPathComponent:fileName];

    if ([fm fileExistsAtPath:destPath]) {
        NSString *stem = [fileName stringByDeletingPathExtension];
        NSString *ext = fileName.pathExtension;
        for (int n = 1; n < 100; n++) {
            NSString *candidate = [NSString stringWithFormat:@"%@-%d.%@", stem, n, ext];
            NSString *candidatePath = [[SPKGalleryPaths galleryMediaDirectory] stringByAppendingPathComponent:candidate];
            if (![fm fileExistsAtPath:candidatePath]) {
                fileName = candidate;
                destPath = candidatePath;
                break;
            }
        }
    }

    NSError *copyError;
    if (![fm copyItemAtPath:fileURL.path toPath:destPath error:&copyError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to copy file: %@", copyError);
        if (error)
            *error = copyError;
        return nil;
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:destPath error:nil];
    int64_t size = [attrs[NSFileSize] longLongValue];

    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    SPKGalleryFile *file = [NSEntityDescription insertNewObjectForEntityForName:@"SPKGalleryFile"
                                                         inManagedObjectContext:ctx];
    file.identifier = [NSUUID UUID].UUIDString;
    file.relativePath = fileName;
    file.mediaType = mediaType;
    file.dateAdded = metadata.importCapturedDate ?: metadata.importPostedDate ?
                                                                              : [NSDate date];
    file.fileSize = size;
    file.isFavorite = NO;
    file.folderPath = folderPath;

    [self applyMetadata:metadata toFile:file fallbackSource:source];
    // Tag with the saving account so the per-account gallery filter can scope it.
    // Editable afterwards via the file's edit-details sheet.
    NSString *ownerPK = [SPKAccountManager currentAccountPK];
    if (ownerPK.length > 0) {
        file.ownerAccountPK = ownerPK;
        file.ownerUsername = [SPKAccountManager currentAccountUsername];
    }
    [self probeMediaAtPath:destPath mediaType:mediaType file:file];

    NSError *saveError;
    if (![ctx save:&saveError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to save entity: %@", saveError);
        [fm removeItemAtPath:destPath error:nil];
        if (error)
            *error = saveError;
        return nil;
    }

    [self generateThumbnailForFile:file completion:nil];

    return file;
}

#pragma mark - Remove

- (BOOL)removeWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *mediaPath = [self filePath];
    if ([fm fileExistsAtPath:mediaPath]) {
        [fm removeItemAtPath:mediaPath error:nil];
    }

    NSString *thumbPath = [self thumbnailPath];
    if ([fm fileExistsAtPath:thumbPath]) {
        [fm removeItemAtPath:thumbPath error:nil];
    }

    NSManagedObjectContext *ctx = self.managedObjectContext;
    [ctx deleteObject:self];

    NSError *saveError;
    if (![ctx save:&saveError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to delete entity: %@", saveError);
        if (error)
            *error = saveError;
        return NO;
    }

    return YES;
}

- (BOOL)replaceMediaWithFileURL:(NSURL *)newURL
                      mediaType:(SPKGalleryMediaType)mediaType
                          error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!newURL || ![fm fileExistsAtPath:newURL.path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPKGallery"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : SPKL(@"GALLERY_GALLERY_FILE_REPLACEMENT_FILE_NOT_EXIST_TEXT")}];
        }
        return NO;
    }

    NSString *dir = [SPKGalleryPaths galleryMediaDirectory];
    NSString *oldMediaPath = [self filePath];
    NSString *thumbPath = [self thumbnailPath];

    NSString *stem = [self.relativePath stringByDeletingPathExtension];
    if (stem.length == 0) {
        stem = [NSUUID UUID].UUIDString;
    }
    NSString *newExt = SPKGalleryNormalizedExtension(newURL.pathExtension, mediaType);
    NSString *newName = [stem stringByAppendingPathExtension:newExt];
    NSString *newPath = [dir stringByAppendingPathComponent:newName];

    // Land on a path distinct from the existing media file so the copy can be
    // verified before the original is removed (a failed copy never destroys it).
    if ([newPath isEqualToString:oldMediaPath] || [fm fileExistsAtPath:newPath]) {
        for (int n = 1; n < 1000; n++) {
            NSString *candidate = [NSString stringWithFormat:@"%@-%d.%@", stem, n, newExt];
            NSString *candidatePath = [dir stringByAppendingPathComponent:candidate];
            if (![candidatePath isEqualToString:oldMediaPath] && ![fm fileExistsAtPath:candidatePath]) {
                newName = candidate;
                newPath = candidatePath;
                break;
            }
        }
    }

    NSError *copyError = nil;
    if (![fm copyItemAtPath:newURL.path toPath:newPath error:&copyError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to copy replacement file: %@", copyError);
        if (error)
            *error = copyError;
        return NO;
    }

    if (![oldMediaPath isEqualToString:newPath]) {
        [fm removeItemAtPath:oldMediaPath error:nil];
    }

    self.relativePath = newName;
    self.mediaType = mediaType;

    NSDictionary *attrs = [fm attributesOfItemAtPath:newPath error:nil];
    self.fileSize = [attrs[NSFileSize] longLongValue];
    // Reset so probeMediaAtPath (which only fills when <= 0) repopulates them.
    self.pixelWidth = 0;
    self.pixelHeight = 0;
    self.durationSeconds = 0;
    [[self class] probeMediaAtPath:newPath mediaType:mediaType file:self];

    // Thumbnail path is keyed by identifier (unchanged), so drop the stale
    // on-disk thumbnail and its cache entry before regenerating.
    [fm removeItemAtPath:thumbPath error:nil];
    [SPKGalleryThumbnailCache() removeObjectForKey:thumbPath];

    NSManagedObjectContext *ctx = self.managedObjectContext ?: [SPKGalleryCoreDataStack shared].viewContext;
    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to save replaced entity: %@", saveError);
        if (error)
            *error = saveError;
        return NO;
    }

    [[self class] generateThumbnailForFile:self completion:nil];
    return YES;
}

- (SPKGallerySaveMetadata *)saveMetadata {
    SPKGallerySaveMetadata *metadata = [[SPKGallerySaveMetadata alloc] init];
    metadata.source = self.source;
    metadata.sourceUsername = self.sourceUsername;
    metadata.sourceUserPK = self.sourceUserPK;
    metadata.sourceProfileURLString = self.sourceProfileURLString;
    metadata.sourceMediaPK = self.sourceMediaPK;
    metadata.sourceMediaCode = self.sourceMediaCode;
    metadata.sourceMediaURLString = self.sourceMediaURLString;
    metadata.customName = self.customName;
    // Keep the derived copy's date/filename aligned with the original.
    metadata.importCapturedDate = self.dateAdded;
    metadata.importPostedDate = self.dateAdded;
    // Dimensions/duration deliberately left unset — the trimmed file differs and
    // is probed fresh.
    return metadata;
}

- (void)markAddedNow {
    self.dateAdded = [NSDate date];
    NSManagedObjectContext *ctx = self.managedObjectContext ?: [SPKGalleryCoreDataStack shared].viewContext;
    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to stamp fresh date: %@", saveError);
    }
}

#pragma mark - Paths

- (NSString *)filePath {
    return [[SPKGalleryPaths galleryMediaDirectory] stringByAppendingPathComponent:self.relativePath];
}

- (NSURL *)fileURL {
    return [NSURL fileURLWithPath:[self filePath]];
}

- (BOOL)fileExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self filePath]];
}

- (NSString *)thumbnailPath {
    return [[SPKGalleryPaths galleryThumbnailsDirectory]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", self.identifier]];
}

- (BOOL)thumbnailExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self thumbnailPath]];
}

#pragma mark - Display helpers

- (NSString *)displayName {
    if (self.customName.length > 0)
        return self.customName;

    // relativePath: "<epochMs>_<rest>" — rest may be "user_slug_date.ext" or legacy "originalFilename".
    NSString *rel = self.relativePath ?: @"";
    NSRange sep = [rel rangeOfString:@"_"];
    if (sep.location != NSNotFound && sep.location + 1 < rel.length) {
        return [rel substringFromIndex:sep.location + 1];
    }
    return rel;
}

- (BOOL)isFromHighlight {
    if (self.source != SPKGallerySourceStories || self.sourceMediaURLString.length == 0)
        return NO;
    // A highlight's share link is /s/<token>/; a live story's is /stories/<user>/<pk>/.
    return [[NSURL URLWithString:self.sourceMediaURLString].path.lowercaseString hasPrefix:@"/s/"];
}

- (NSString *)sourceLabel {
    if ([self isFromHighlight])
        return SPKL(@"GALLERY_GALLERY_FILE_SOURCE_HIGHLIGHTS_TEXT");
    return [SPKGalleryFile labelForSource:(SPKGallerySource)self.source];
}

- (NSString *)sourceSymbolName {
    if ([self isFromHighlight])
        return @"highlights";
    return [SPKGalleryFile symbolNameForSource:(SPKGallerySource)self.source];
}

- (NSString *)listPrimaryTitle {
    if (self.sourceUsername.length) {
        return self.sourceUsername;
    }
    return [self displayName];
}

- (NSString *)listFormattedDuration {
    if (self.durationSeconds <= 0.05) {
        return @"";
    }
    NSInteger total = (NSInteger)llround(self.durationSeconds);
    NSInteger m = total / 60;
    NSInteger s = total % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

- (NSString *)listBitrateString {
    if (self.mediaType != SPKGalleryMediaTypeVideo && self.mediaType != SPKGalleryMediaTypeAudio) {
        return @"";
    }
    if (self.durationSeconds < 0.5 || self.fileSize <= 0) {
        return @"";
    }
    double mbps = (double)self.fileSize * 8.0 / self.durationSeconds / 1e6;
    if (mbps < 0.01) {
        return @"";
    }
    return [NSString stringWithFormat:@"%.1f Mbps", mbps];
}

- (NSString *)listTechnicalLine {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    BOOL isTimedMedia = (self.mediaType == SPKGalleryMediaTypeVideo || self.mediaType == SPKGalleryMediaTypeAudio);
    if (isTimedMedia) {
        NSString *d = [self listFormattedDuration];
        if (d.length) {
            [parts addObject:d];
        }
    }
    NSString *sz = [NSByteCountFormatter stringFromByteCount:self.fileSize
                                                  countStyle:NSByteCountFormatterCountStyleFile];
    if (sz.length) {
        [parts addObject:sz];
    }
    if (self.mediaType != SPKGalleryMediaTypeAudio && self.pixelWidth > 0 && self.pixelHeight > 0) {
        [parts addObject:[NSString stringWithFormat:@"%dx%d", self.pixelWidth, self.pixelHeight]];
    }
    if (isTimedMedia) {
        NSString *br = [self listBitrateString];
        if (br.length) {
            [parts addObject:br];
        }
    }
    return [parts componentsJoinedByString:@" • "];
}

- (NSString *)listDownloadDateString {
    return [SPKUtils spk_formattedDateTime:self.dateAdded includingYear:NO] ?: @"";
}

- (NSURL *)preferredProfileURL {
    if (self.sourceProfileURLString.length > 0) {
        NSURL *url = [NSURL URLWithString:self.sourceProfileURLString];
        if (url)
            return url;
    }
    if (self.sourceUsername.length > 0) {
        NSString *encodedUsername = [self.sourceUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        if (encodedUsername.length > 0) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://user?username=%@", encodedUsername]];
            if (url)
                return url;
        }
    }
    return nil;
}

- (NSString *)fullInstagramMediaID {
    NSString *rawMediaPK = self.sourceMediaPK ?: @"";

    // Already a composite "<mediaPK>_<userPK>" (e.g. captured from media.id)? Use as-is.
    NSArray<NSString *> *parts = [rawMediaPK componentsSeparatedByString:@"_"];
    if (parts.count == 2) {
        NSString *m = parts[0];
        NSString *u = parts[1];
        BOOL mDigits = m.length > 0 && [m rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
        BOOL uDigits = u.length > 0 && [u rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
        if (mDigits && uDigits)
            return rawMediaPK;
    }

    NSString *mediaPK = parts.firstObject ?: rawMediaPK;
    if (mediaPK.length == 0)
        return nil;
    if ([mediaPK rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
        return nil;

    NSString *userPK = [self.sourceUserPK componentsSeparatedByString:@"_"].lastObject ?: self.sourceUserPK;
    if (userPK.length == 0)
        return nil;
    if ([userPK rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
        return nil;

    return [NSString stringWithFormat:@"%@_%@", mediaPK, userPK];
}

- (NSURL *)preferredOriginalMediaURL {
    SPKGallerySource source = (SPKGallerySource)self.source;
    if (source != SPKGallerySourceFeed &&
        source != SPKGallerySourceStories &&
        source != SPKGallerySourceReels) {
        return nil;
    }

    // Stories are not posts: build https://www.instagram.com/stories/<username>/<pk>/ — never /p/, /reel/ or instagram://media (which all resolve to the feed viewer).
    if (self.source == SPKGallerySourceStories) {
        if (self.sourceMediaURLString.length > 0) {
            NSURL *stored = [NSURL URLWithString:self.sourceMediaURLString];
            NSString *scheme = stored.scheme.lowercaseString ?: @"";
            NSString *path = stored.path.lowercaseString ?: @"";
            BOOL validScheme = stored && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"instagram"]);
            // Reject stale post/reel links wrongly stored on story entries by older builds.
            BOOL stalePostURL = [path containsString:@"/p/"] || [path containsString:@"/reel/"] || [path containsString:@"/reels/"];
            if (validScheme && !stalePostURL) {
                SPKLog(@"General", @"[Sparkle Gallery] Open original using stored story URL url=%@", stored.absoluteString);
                return stored;
            }
            SPKLog(@"General", @"[Sparkle Gallery] Ignoring stored story URL (stale/invalid) url=%@", self.sourceMediaURLString);
        }

        NSString *identifier = [self.sourceMediaPK componentsSeparatedByString:@"_"].firstObject ?: self.sourceMediaPK;
        if (self.sourceUsername.length > 0 && identifier.length > 0) {
            NSString *encodedUsername = [self.sourceUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            NSString *encodedIdentifier = [identifier stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            if (encodedUsername.length > 0 && encodedIdentifier.length > 0) {
                NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/stories/%@/%@/", encodedUsername, encodedIdentifier]];
                SPKLog(@"General", @"[Sparkle Gallery] Open original built story URL username=%@ id=%@ url=%@", self.sourceUsername, identifier, url.absoluteString);
                return url;
            }
        }
        SPKLog(@"General", @"[Sparkle Gallery] Open original story missing username/pk username=%@ mediaPK=%@", self.sourceUsername, self.sourceMediaPK);
        return nil;
    }

    // Posts/reels: prefer the authenticated instagram://media?id= route. It hands the
    // media id straight to Instagram's in-app router, which opens the post on its own
    // single-post page. The https://instagram.com/<p|reel>/<code>/ permalink instead
    // travels through continueUserActivity:, which resolves the post into the *main
    // feed* and leaves it sitting on top of the timeline rather than on a page of its
    // own. So the web permalink is the fallback, used only when the composite
    // <mediaPK>_<userPK> id cannot be assembled (a bare media pk on its own resolves
    // to the home feed).
    NSString *fullMediaID = [self fullInstagramMediaID];
    if (fullMediaID.length > 0) {
        NSString *encodedID = [fullMediaID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        if (encodedID.length > 0) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://media?id=%@", encodedID]];
            SPKLog(@"General", @"[Sparkle Gallery] Open original using media deep link source=%d id=%@ url=%@", self.source, fullMediaID, url.absoluteString);
            return url;
        }
    }

    NSString *pathComponent = SPKGalleryPostPathComponentForSource((SPKGallerySource)self.source);
    if (self.sourceMediaCode.length > 0) {
        if (pathComponent.length == 0) {
            SPKLog(@"General", @"[Sparkle Gallery] Open original has code but no safe path source=%d code=%@", self.source, self.sourceMediaCode);
            return nil;
        }
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/%@/", pathComponent, self.sourceMediaCode]];
        SPKLog(@"General", @"[Sparkle Gallery] Open original generated from code source=%d code=%@ url=%@", self.source, self.sourceMediaCode, url.absoluteString);
        return url;
    }

    if (self.sourceMediaPK.length > 0 && pathComponent.length > 0) {
        NSString *code = [SPKUtils instagramShortcodeForMediaPK:self.sourceMediaPK];
        if (code.length > 0) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/%@/", pathComponent, code]];
            SPKLog(@"General", @"[Sparkle Gallery] Open original generated from media pk source=%d mediaPK=%@ code=%@ url=%@", self.source, self.sourceMediaPK, code, url.absoluteString);
            return url;
        }
        SPKLog(@"General", @"[Sparkle Gallery] Open original could not derive shortcode from media pk source=%d mediaPK=%@", self.source, self.sourceMediaPK);
    }

    // Stored permalink (typically a /p/ or /reel/ web link captured at save time).
    if (self.sourceMediaURLString.length > 0) {
        NSURL *url = [NSURL URLWithString:self.sourceMediaURLString];
        NSString *scheme = url.scheme.lowercaseString ?: @"";
        if (url && ([scheme isEqualToString:@"http"] ||
                    [scheme isEqualToString:@"https"] ||
                    [scheme isEqualToString:@"instagram"])) {
            SPKLog(@"General", @"[Sparkle Gallery] Open original using stored URL source=%d url=%@", self.source, url.absoluteString);
            return url;
        }
        SPKLog(@"General", @"[Sparkle Gallery] Ignoring invalid stored original URL source=%d raw=%@", self.source, self.sourceMediaURLString);
    }

    SPKLog(@"General", @"[Sparkle Gallery] Open original unavailable source=%d relativePath=%@", self.source, self.relativePath);
    return nil;
}

- (NSURL *)originalWebURL {
    SPKGallerySource source = (SPKGallerySource)self.source;
    if (source == SPKGallerySourceStories) {
        NSURL *url = [self preferredOriginalMediaURL];
        return [url.scheme.lowercaseString hasPrefix:@"http"] ? url : nil;
    }
    if (source != SPKGallerySourceFeed && source != SPKGallerySourceReels)
        return nil;

    NSString *pathComponent = SPKGalleryPostPathComponentForSource(source);
    NSString *code = self.sourceMediaCode.length > 0 ? self.sourceMediaCode : [SPKUtils instagramShortcodeForMediaPK:self.sourceMediaPK];
    if (pathComponent.length > 0 && code.length > 0)
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/%@/", pathComponent, code]];

    NSURL *stored = self.sourceMediaURLString.length > 0 ? [NSURL URLWithString:self.sourceMediaURLString] : nil;
    return [stored.scheme.lowercaseString hasPrefix:@"http"] ? stored : nil;
}

- (BOOL)hasOpenableProfile {
    return [self preferredProfileURL] != nil;
}

- (BOOL)hasOpenableOriginalMedia {
    return [self preferredOriginalMediaURL] != nil;
}

- (NSString *)openOriginalActionTitle {
    switch ((SPKGallerySource)self.source) {
    case SPKGallerySourceStories:
        return SPKL(@"GALLERY_GALLERY_FILE_OPEN_STORY_TEXT");
    case SPKGallerySourceReels:
        return SPKL(@"GALLERY_GALLERY_FILE_OPEN_REEL_TEXT");
    case SPKGallerySourceFeed:
    case SPKGallerySourceProfile:
        return SPKL(@"GALLERY_GALLERY_FILE_OPEN_POST_TEXT");
    default:
        return SPKL(@"ALERT_ACTION_OPEN_ORIGINAL_POST");
    }
}

+ (NSString *)labelForSource:(SPKGallerySource)source {
    switch (source) {
    case SPKGallerySourceFeed:
        return SPKL(@"FEED_TITLE");
    case SPKGallerySourceStories:
        return SPKL(@"STORIES_OTHER_STORIES_TITLE");
    case SPKGallerySourceReels:
        return SPKL(@"REELS_TITLE");
    case SPKGallerySourceProfile:
        return SPKL(@"PROFILE_TITLE");
    case SPKGallerySourceDMs:
        return SPKL(@"GALLERY_FILTER_MESSAGES_LABEL");
    case SPKGallerySourceThumbnail:
        return SPKL(@"GALLERY_GALLERY_FILE_THUMB_TEXT");
    case SPKGallerySourceInstants:
        return SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE");
    case SPKGallerySourceAudioPage:
        return SPKL(@"GALLERY_GALLERY_FILE_AUDIO_PAGE_TEXT");
    case SPKGallerySourceComments:
        return SPKL(@"GENERAL_COMMENTS_HEADER");
    case SPKGallerySourceOther:
    default:
        return SPKL(@"STORIES_OTHER_HEADER");
    }
}

+ (NSString *)symbolNameForSource:(SPKGallerySource)source {
    switch (source) {
    case SPKGallerySourceFeed:
        return @"feed";
    case SPKGallerySourceStories:
        return @"story";
    case SPKGallerySourceReels:
        return @"reels";
    case SPKGallerySourceProfile:
        return @"user_circle";
    case SPKGallerySourceDMs:
        return @"messages";
    case SPKGallerySourceThumbnail:
        return @"photo_gallery";
    case SPKGallerySourceInstants:
        return @"instants";
    case SPKGallerySourceAudioPage:
        return @"audio_page";
    case SPKGallerySourceComments:
        return @"comment";
    case SPKGallerySourceOther:
    default:
        return @"media";
    }
}

#pragma mark - Thumbnails

// Synchronous render core shared by the saved-file thumbnailer and the URL variant. Call off the
// main thread. Images are decoded + downscaled; videos yield a frame at the half-second mark.
+ (nullable UIImage *)renderThumbnailForURL:(NSURL *)url mediaType:(SPKGalleryMediaType)mediaType maxSize:(CGSize)maxSize {
    if (mediaType == SPKGalleryMediaTypeImage) {
        // Decode via ImageIO with downsampling: this handles formats -imageWithContentsOfFile: chokes
        // on (WebP, some HEIC/animated frames) and applies the EXIF orientation, so Regram exports and
        // odd Files imports render a thumbnail instead of falling back to the grey placeholder glyph.
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (source) {
            CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
            CGFloat maxPixel = MAX(maxSize.width, maxSize.height);
            if (maxPixel < 1.0) {
                maxPixel = 256.0 * scale;
            }
            NSDictionary *opts = @{
                (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
                (id)kCGImageSourceShouldCacheImmediately : @YES,
                (id)kCGImageSourceThumbnailMaxPixelSize : @(maxPixel),
            };
            CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
            CFRelease(source);
            if (cg) {
                UIImage *img = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
                return img;
            }
        }
        // Last resort for anything ImageIO couldn't thumbnail (e.g. a raw pixel buffer format).
        UIImage *full = [UIImage imageWithContentsOfFile:url.path];
        return full ? [self resizeImage:full toSize:maxSize] : nil;
    }
    if (mediaType == SPKGalleryMediaTypeVideo) {
        AVAsset *asset = [AVAsset assetWithURL:url];
        AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = maxSize;
        gen.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
        gen.requestedTimeToleranceAfter = kCMTimePositiveInfinity;

        // Prefer a frame ~0.5s in, but fall back to the very first frame for clips shorter than that
        // (a single grabbed frame is why some short reels/audio-cover videos showed no thumbnail).
        CMTime times[] = { CMTimeMakeWithSeconds(0.5, 600), kCMTimeZero };
        for (int i = 0; i < 2; i++) {
            CGImageRef cgImage = [gen copyCGImageAtTime:times[i] actualTime:NULL error:NULL];
            if (cgImage) {
                UIImage *img = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                return img;
            }
        }
    }
    return nil;
}

+ (void)generateThumbnailForURL:(NSURL *)url
                      mediaType:(SPKGalleryMediaType)mediaType
                           size:(CGSize)size
                     completion:(void (^)(UIImage *_Nullable))completion {
    if (!completion) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *thumb = [self renderThumbnailForURL:url mediaType:mediaType maxSize:size];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(thumb);
        });
    });
}

+ (void)generateThumbnailForFile:(SPKGalleryFile *)file completion:(void (^)(BOOL success))completion {
    int16_t mediaType = file.mediaType;
    if (mediaType == SPKGalleryMediaTypeAudio) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES);
            });
        }
        return;
    }

    NSString *filePath = [file filePath];
    NSString *thumbPath = [file thumbnailPath];
    NSCache<NSString *, UIImage *> *cache = SPKGalleryThumbnailCache();

    UIImage *cachedThumb = [cache objectForKey:thumbPath];
    if (cachedThumb || [file thumbnailExists]) {
        if (!cachedThumb) {
            cachedThumb = [UIImage imageWithContentsOfFile:thumbPath];
            if (cachedThumb) {
                cachedThumb = SPKGalleryDecodedImage(cachedThumb);
                SPKGalleryCacheThumbnail(cachedThumb, thumbPath);
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cachedThumb != nil);
            });
        }
        return;
    }

    __block BOOL shouldGenerate = NO;
    dispatch_sync(SPKGalleryThumbnailStateQueue(), ^{
        NSMutableDictionary<NSString *, NSMutableArray<void (^)(BOOL success)> *> *pending = SPKGalleryThumbnailCompletions();
        NSMutableArray<void (^)(BOOL success)> *callbacks = pending[thumbPath];
        if (callbacks) {
            if (completion) {
                [callbacks addObject:[completion copy]];
            }
            return;
        }

        shouldGenerate = YES;
        callbacks = [NSMutableArray array];
        if (completion) {
            [callbacks addObject:[completion copy]];
        }
        pending[thumbPath] = callbacks;
    });

    if (!shouldGenerate) {
        return;
    }

    // Also serial, and for a stronger reason than the load queue: generating a
    // video thumbnail spins up an AVAssetImageGenerator. Scrolling past a run of
    // videos that have no thumbnail yet would otherwise start one per file at
    // once and flatten the CPU.
    dispatch_async(SPKGalleryThumbnailRenderQueue(), ^{
        UIImage *thumb = [self renderThumbnailForURL:[NSURL fileURLWithPath:filePath]
                                           mediaType:(SPKGalleryMediaType)mediaType
                                             maxSize:CGSizeMake(kThumbnailSize, kThumbnailSize)];

        if (thumb) {
            NSData *jpegData = UIImageJPEGRepresentation(thumb, 0.8);
            [jpegData writeToFile:thumbPath atomically:YES];
            SPKGalleryCacheThumbnail(thumb, thumbPath);
        }

        __block NSArray<void (^)(BOOL success)> *callbacks = nil;
        dispatch_sync(SPKGalleryThumbnailStateQueue(), ^{
            callbacks = [[SPKGalleryThumbnailCompletions()[thumbPath] copy] ?: @[] copy];
            [SPKGalleryThumbnailCompletions() removeObjectForKey:thumbPath];
        });

        if (callbacks.count == 0) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL success = (thumb != nil);
            for (void (^callback)(BOOL success) in callbacks) {
                callback(success);
            }
        });
    });
}

// Draws the three rounded EQ bars (short / tall / short) centered in `size`,
// filled with `barColor`. Shared by the gallery grid's gray-card placeholder and
// the trim editor's audio pane (white bars on black).
static void SPKGalleryDrawAudioBars(CGSize size, UIColor *barColor) {
    [barColor setFill];

    CGFloat const w = 12.0;
    CGFloat const s = 28.0;
    CGFloat const h_middle = 130.0;
    CGFloat const h_side = 85.0;
    CGFloat const cx = size.width / 2.0;
    CGFloat const cy = size.height / 2.0;

    // Left bar
    CGRect leftRect = CGRectMake(cx - w / 2.0 - s - w, cy - h_side / 2.0, w, h_side);
    [[UIBezierPath bezierPathWithRoundedRect:leftRect cornerRadius:w / 2.0] fill];

    // Middle bar
    CGRect middleRect = CGRectMake(cx - w / 2.0, cy - h_middle / 2.0, w, h_middle);
    [[UIBezierPath bezierPathWithRoundedRect:middleRect cornerRadius:w / 2.0] fill];

    // Right bar
    CGRect rightRect = CGRectMake(cx + w / 2.0 + s, cy - h_side / 2.0, w, h_side);
    [[UIBezierPath bezierPathWithRoundedRect:rightRect cornerRadius:w / 2.0] fill];
}

static UIImage *SPKGalleryAudioPlaceholderImage(void) {
    UIUserInterfaceStyle style = [UITraitCollection currentTraitCollection].userInterfaceStyle;

    static NSMutableDictionary<NSNumber *, UIImage *> *cachedImages = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedImages = [NSMutableDictionary dictionary];
    });

    UIImage *cached = cachedImages[@(style)];
    if (cached) {
        return cached;
    }

    CGSize size = CGSizeMake(kThumbnailSize, kThumbnailSize);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
    [[SPKUtils SPKColor_InstagramTertiaryBackground] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    SPKGalleryDrawAudioBars(size, [SPKUtils SPKColor_InstagramSecondaryText]);
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (thumb) {
        cachedImages[@(style)] = thumb;
    }
    return thumb;
}

+ (UIImage *)audioGlyphImageWithBarColor:(UIColor *)barColor {
    CGSize size = CGSizeMake(kThumbnailSize, kThumbnailSize);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0); // transparent background
    SPKGalleryDrawAudioBars(size, barColor ?: [UIColor whiteColor]);
    UIImage *glyph = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return glyph;
}

+ (UIImage *)audioPlaceholderThumbnail {
    return SPKGalleryAudioPlaceholderImage();
}

+ (UIImage *)loadThumbnailForFile:(SPKGalleryFile *)file {
    if (file.mediaType == SPKGalleryMediaTypeAudio) {
        return SPKGalleryAudioPlaceholderImage();
    }

    NSString *thumbPath = [file thumbnailPath];
    UIImage *cached = [SPKGalleryThumbnailCache() objectForKey:thumbPath];
    if (cached) {
        return cached;
    }
    if ([file thumbnailExists]) {
        UIImage *image = [UIImage imageWithContentsOfFile:thumbPath];
        if (image) {
            image = SPKGalleryDecodedImage(image);
            SPKGalleryCacheThumbnail(image, thumbPath);
        }
        return image;
    }
    return nil;
}

+ (UIImage *)cachedThumbnailForFile:(SPKGalleryFile *)file {
    if (file.mediaType == SPKGalleryMediaTypeAudio) {
        return SPKGalleryAudioPlaceholderImage();
    }
    return [SPKGalleryThumbnailCache() objectForKey:[file thumbnailPath]];
}

+ (void)loadThumbnailAsyncForFile:(SPKGalleryFile *)file completion:(void (^)(UIImage *_Nullable))completion {
    if (!completion) {
        return;
    }
    if (file.mediaType == SPKGalleryMediaTypeAudio) {
        UIImage *placeholder = SPKGalleryAudioPlaceholderImage();
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(placeholder);
        });
        return;
    }

    // Snapshot the path on the caller's (main) thread: the background block must
    // never touch the managed object, whose context is main-queue confined.
    NSString *thumbPath = [file thumbnailPath];
    dispatch_async(SPKGalleryThumbnailLoadQueue(), ^{
        UIImage *cached = [SPKGalleryThumbnailCache() objectForKey:thumbPath];
        if (!cached && [[NSFileManager defaultManager] fileExistsAtPath:thumbPath]) {
            UIImage *image = [UIImage imageWithContentsOfFile:thumbPath];
            if (image) {
                cached = SPKGalleryDecodedImage(image);
                SPKGalleryCacheThumbnail(cached, thumbPath);
            }
        }

        if (cached) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached);
            });
            return;
        }

        // Nothing on disk yet. Generation reads the managed object, so hop back
        // to the main queue to kick it off.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self generateThumbnailForFile:file
                                completion:^(BOOL success) {
                                    completion(success ? [SPKGalleryThumbnailCache() objectForKey:thumbPath] : nil);
                                }];
        });
    });
}

+ (UIImage *)resizeImage:(UIImage *)image toSize:(CGSize)targetSize {
    // Guard against a zero/degenerate target (e.g. a not-yet-laid-out view passing a 0 width),
    // which would make UIGraphicsBeginImageContext assert on a {0,0} bitmap.
    if (!image || image.size.width < 1.0 || image.size.height < 1.0 ||
        targetSize.width < 1.0 || targetSize.height < 1.0) {
        return image;
    }
    CGFloat scale = MIN(targetSize.width / image.size.width, targetSize.height / image.size.height);
    CGSize newSize = CGSizeMake(image.size.width * scale, image.size.height * scale);

    UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return resized;
}

@end
