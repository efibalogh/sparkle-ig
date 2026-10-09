#import "SPKStrings.h"
#import "SPKMediaQualityManager.h"
#include <UIKit/UIKit.h>

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Settings/SPKSetting.h"
#import "../../Settings/SPKSettingsTransferManager.h"
#import "../../Settings/SPKSettingsViewController.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "../../Utils.h"
#import "../Downloads/SPKDownloadDestinationWriter.h"
#import "../Downloads/SPKDownloadHelpers.h"
#import "../Downloads/SPKDownloadTypes.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../MediaPreview/SPKMediaItem.h"
#import "../MediaTrim/SPKTrimSourcePlan.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKSwitch.h"
#import "SPKDashParser.h"
#import "SPKMediaFFmpeg.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SPKMediaOptionKind) {
    SPKMediaOptionKindPhotoProgressive = 0,
    SPKMediaOptionKindVideoProgressive = 1,
    SPKMediaOptionKindVideoDashMerged = 2,
    SPKMediaOptionKindAudioDash = 3,
    SPKMediaOptionKindVideoDashOnly = 4,
};

@interface SPKMediaOption : NSObject
@property (nonatomic) SPKMediaOptionKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *qualityInfo;
@property (nonatomic, strong, nullable) NSURL *primaryURL;
@property (nonatomic, strong, nullable) NSURL *secondaryURL;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger bandwidth;
@property (nonatomic) NSInteger audioBandwidth;
@property (nonatomic) NSInteger fileSizeBytes;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, copy, nullable) NSString *codec;
@property (nonatomic, copy, nullable) NSString *audioCodec;
@property (nonatomic) BOOL selectable;
@property (nonatomic) BOOL isWeb;
@end

@implementation SPKMediaOption
@end

@interface SPKMediaOptionSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *options;
@end

@implementation SPKMediaOptionSection
@end

@interface SPKMediaAnalysis : NSObject
@property (nonatomic) BOOL isVideo;
@property (nonatomic) BOOL ffmpegAvailable;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong, nullable) SPKMediaOption *fallbackOption;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *photoOptions;
@property (nonatomic, copy) NSArray<SPKMediaOptionSection *> *photoSections;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *progressiveVideoOptions;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *mergedDashOptions;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *audioDashOptions;
@property (nonatomic, copy) NSArray<SPKMediaOption *> *videoDashOnlyOptions;
@property (nonatomic, copy) NSArray<SPKMediaOptionSection *> *videoSections;
@end

@implementation SPKMediaAnalysis
@end

static id SPKMediaObjectForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKMediaKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *SPKMediaNumberForSelector(id target, NSString *selectorName) {
    id value = SPKMediaObjectForSelector(target, selectorName);
    if ([value isKindOfClass:[NSNumber class]])
        return value;
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return @([value doubleValue]);
    }
    return nil;
}

static NSArray *SPKMediaArrayFromCollection(id value) {
    if ([value isKindOfClass:[NSArray class]])
        return value;
    if ([value isKindOfClass:[NSOrderedSet class]])
        return ((NSOrderedSet *)value).array;
    if ([value isKindOfClass:[NSSet class]])
        return ((NSSet *)value).allObjects;
    return nil;
}

static NSURL *SPKMediaURLFromValue(id value) {
    if ([value isKindOfClass:[NSURL class]])
        return value;
    if ([value isKindOfClass:[NSString class]] &&
        [(NSString *)value length] > 0) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *SPKWebPhotoCandidatesCache;
static NSMutableSet<NSString *> *SPKWebPhotoCandidatesFetchedPKs;
static dispatch_once_t SPKWebPhotoCandidatesOnceToken;

static void SPKInitializeWebPhotoCandidatesCacheIfNeeded(void) {
    dispatch_once(&SPKWebPhotoCandidatesOnceToken, ^{
        SPKWebPhotoCandidatesCache = [NSMutableDictionary dictionary];
        SPKWebPhotoCandidatesFetchedPKs = [NSMutableSet set];
    });
}

static NSString *SPKNormalizePK(NSString *pk) {
    if (pk.length == 0)
        return nil;
    NSRange range = [pk rangeOfString:@"_"];
    if (range.location != NSNotFound) {
        return [pk substringToIndex:range.location];
    }
    return pk;
}

static NSInteger SPKMediaIntegerValue(id value) {
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return 0;
}

static double SPKMediaDoubleValue(id value) {
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return [value doubleValue];
    }
    return 0.0;
}

static id SPKMediaIvarValue(id target, const char *name) {
    if (!target || !name)
        return nil;
    @try {
        Ivar ivar = NULL;
        for (Class cls = object_getClass(target); cls && !ivar;
             cls = class_getSuperclass(cls)) {
            ivar = class_getInstanceVariable(cls, name);
        }
        if (!ivar)
            return nil;

        const char *encoding = ivar_getTypeEncoding(ivar);
        if (!encoding || encoding[0] != '@') {
            return nil;
        }

        return object_getIvar(target, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *SPKMediaFirstNumberFromValues(NSArray *values) {
    for (id value in values) {
        if ([value respondsToSelector:@selector(doubleValue)]) {
            double numericValue = [value doubleValue];
            if (numericValue > 0.0) {
                return @(numericValue);
            }
        }
    }
    return nil;
}

static NSNumber *SPKMediaExtractCandidateFileSize(id rawValue) {
    if (!rawValue) return nil;

    if ([rawValue isKindOfClass:[NSArray class]]) {
        id last = [(NSArray *)rawValue lastObject];
        if ([last respondsToSelector:@selector(longLongValue)]) {
            long long val = [last longLongValue];
            if (val > 0) {
                // Progressive JPEG scan size arrays (estimated_scans_sizes) are reported in bits by IG
                return @(val / 8);
            }
        }
    }

    long long sizeVal = 0;
    if ([rawValue respondsToSelector:@selector(longLongValue)]) {
        sizeVal = [rawValue longLongValue];
    } else if ([rawValue isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)rawValue;
        NSNumber *nested = SPKMediaFirstNumberFromValues(@[
            dict[@"value"] ?: @0, dict[@"size"] ?: @0,
            dict[@"file_size"] ?: @0, dict[@"bytes"] ?: @0
        ]);
        sizeVal = nested.longLongValue;
    }

    if (sizeVal > 0) {
        // IG photo estimates > 4,000,000 are reported in bits
        if (sizeVal > 4000000) {
            sizeVal = sizeVal / 8;
        }
        return @(sizeVal);
    }
    return nil;
}

static NSArray<NSDictionary *> *
SPKMediaNormalizedAndSortedVariants(NSArray<NSDictionary *> *variants) {
    if (![variants isKindOfClass:[NSArray class]] || variants.count == 0)
        return @[];

    NSMutableArray<NSDictionary *> *deduped = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];
    for (NSDictionary *variant in variants) {
        NSURL *url = variant[@"url"];
        if (![url isKindOfClass:[NSURL class]] || url.absoluteString.length == 0 ||
            [seenURLs containsObject:url.absoluteString]) {
            continue;
        }
        [seenURLs addObject:url.absoluteString];
        [deduped addObject:variant];
    }

    [deduped sortUsingComparator:^NSComparisonResult(NSDictionary *lhs,
                                                     NSDictionary *rhs) {
        double lhsArea = [lhs[@"width"] doubleValue] * [lhs[@"height"] doubleValue];
        double rhsArea = [rhs[@"width"] doubleValue] * [rhs[@"height"] doubleValue];
        if (lhsArea > rhsArea)
            return NSOrderedAscending;
        if (lhsArea < rhsArea)
            return NSOrderedDescending;

        NSInteger lhsFileSize = [lhs[@"fileSizeBytes"] integerValue];
        NSInteger rhsFileSize = [rhs[@"fileSizeBytes"] integerValue];
        if (lhsFileSize > rhsFileSize)
            return NSOrderedAscending;
        if (lhsFileSize < rhsFileSize)
            return NSOrderedDescending;

        NSInteger lhsBandwidth = [lhs[@"bandwidth"] integerValue];
        NSInteger rhsBandwidth = [rhs[@"bandwidth"] integerValue];
        if (lhsBandwidth > rhsBandwidth)
            return NSOrderedAscending;
        if (lhsBandwidth < rhsBandwidth)
            return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return deduped;
}

static id SPKMediaFieldCacheValue(id obj, NSString *key) {
    if (!obj || key.length == 0)
        return nil;
    Ivar fieldCacheIvar = NULL;
    @try {
        for (Class cls = [obj class]; cls && !fieldCacheIvar;
             cls = class_getSuperclass(cls)) {
            fieldCacheIvar = class_getInstanceVariable(cls, "_fieldCache");
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (!fieldCacheIvar)
        return nil;

    id fieldCache = nil;
    @try {
        fieldCache = object_getIvar(obj, fieldCacheIvar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (![fieldCache isKindOfClass:[NSDictionary class]])
        return nil;

    id value = ((NSDictionary *)fieldCache)[key];
    if (!value || [value isKindOfClass:[NSNull class]])
        return nil;
    return value;
}

static NSString *SPKMediaDurationString(NSTimeInterval duration) {
    if (duration <= 0.0)
        return nil;
    NSInteger total = (NSInteger)llround(duration);
    NSInteger seconds = total % 60;
    NSInteger minutes = (total / 60) % 60;
    NSInteger hours = total / 3600;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours,
                                          (long)minutes, (long)seconds];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

static NSString *SPKMediaBitrateString(NSInteger bandwidth) {
    if (bandwidth <= 0)
        return nil;
    if (bandwidth >= 1000000) {
        return [NSString stringWithFormat:@"%.1f Mbps", bandwidth / 1000000.0];
    }
    return [NSString
        stringWithFormat:@"%ld Kbps", (long)llround(bandwidth / 1000.0)];
}

static NSString *SPKMediaEstimatedSizeString(NSInteger bandwidth,
                                             NSTimeInterval duration) {
    if (bandwidth <= 0 || duration <= 0.0)
        return nil;
    double megabytes = ((double)bandwidth * duration) / 8.0 / 1000.0 / 1000.0;
    if (megabytes >= 100.0) {
        return [NSString stringWithFormat:@"%.0f MB", megabytes];
    }
    if (megabytes >= 10.0) {
        return [NSString stringWithFormat:@"%.1f MB", megabytes];
    }
    return [NSString stringWithFormat:@"%.2f MB", megabytes];
}

static NSString *SPKMediaCodecSummary(NSString *codec) {
    if (codec.length == 0)
        return nil;
    NSString *head =
        [codec componentsSeparatedByString:@","].firstObject ?: codec;
    return [head componentsSeparatedByString:@"."].firstObject ?: head;
}

static NSArray *SPKMediaImageVersionsFromPhoto(id photo) {
    if (!photo)
        return nil;

    NSArray *versions = SPKMediaArrayFromCollection(
        SPKMediaObjectForSelector(photo, @"imageVersions"));
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection(
        [SPKUtils getIvarForObj:photo
                           name:"_originalImageVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection(
        SPKMediaObjectForSelector(photo, @"imageVersionDictionaries"));
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection([SPKUtils getIvarForObj:photo name:"_imageVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection(
        [SPKUtils getIvarForObj:photo
                           name:"_imageVersionDictionaries"]);
    return versions.count > 0 ? versions : nil;
}

static NSArray *SPKMediaVideoVersionsFromVideo(id video) {
    if (!video)
        return nil;

    NSArray *versions = SPKMediaArrayFromCollection(
        SPKMediaObjectForSelector(video, @"videoVersions"));
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection(
        SPKMediaObjectForSelector(video, @"videoVersionDictionaries"));
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection([SPKUtils getIvarForObj:video name:"_videoVersions"]);
    if (versions.count > 0)
        return versions;

    versions = SPKMediaArrayFromCollection(
        [SPKUtils getIvarForObj:video
                           name:"_videoVersionDictionaries"]);
    return versions.count > 0 ? versions : nil;
}

static NSArray<NSDictionary *> *
SPKMediaSortedVariantsFromVersions(NSArray *versions) {
    if (![versions isKindOfClass:[NSArray class]] || versions.count == 0)
        return @[];

    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    for (id version in versions) {
        id rawURL = nil;
        id widthValue = nil;
        id heightValue = nil;
        id bandwidthValue = nil;
        id fileSizeValue = nil;

        if ([version isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dictionary = (NSDictionary *)version;
            rawURL = dictionary[@"url"] ?: dictionary[@"urlString"];
            widthValue = SPKMediaFirstNumberFromValues(@[
                dictionary[@"width"] ?: @0, dictionary[@"original_width"] ?: @0,
                dictionary[@"config_width"] ?: @0, dictionary[@"source_width"] ?: @0,
                dictionary[@"max_width"] ?: @0, dictionary[@"cropped_width"] ?: @0
            ]);
            heightValue = SPKMediaFirstNumberFromValues(@[
                dictionary[@"height"] ?: @0, dictionary[@"original_height"] ?: @0,
                dictionary[@"config_height"] ?: @0, dictionary[@"source_height"] ?: @0,
                dictionary[@"max_height"] ?: @0, dictionary[@"cropped_height"] ?: @0
            ]);
            bandwidthValue = dictionary[@"bandwidth"];
            fileSizeValue = SPKMediaExtractCandidateFileSize(dictionary[@"file_size"] ?: dictionary[@"filesize"]            ?
                                                                                     : dictionary[@"estimated_file_size"]   ?
                                                                                     : dictionary[@"scans_sizes"]           ?
                                                                                     : dictionary[@"estimated_scans_sizes"] ?
                                                                                                                            : dictionary[@"size"]);
        } else {
            rawURL = SPKMediaObjectForSelector(version, @"url")
                         ?: SPKMediaObjectForSelector(version, @"urlString")
                            ?
                        : SPKMediaKVCObject(version, @"url")
                            ?
                        : SPKMediaKVCObject(version, @"urlString")
                            ?
                        : SPKMediaIvarValue(version, "_url")
                            ?
                            : SPKMediaIvarValue(version, "_urlString");
            widthValue = SPKMediaFirstNumberFromValues(@[
                SPKMediaNumberForSelector(version, @"width") ?: @0,
                SPKMediaNumberForSelector(version, @"originalWidth") ?: @0,
                SPKMediaNumberForSelector(version, @"configWidth") ?: @0,
                SPKMediaNumberForSelector(version, @"sourceWidth") ?: @0,
                SPKMediaNumberForSelector(version, @"maxWidth") ?: @0,
                SPKMediaKVCObject(version, @"width") ?: @0,
                SPKMediaKVCObject(version, @"originalWidth") ?: @0,
                SPKMediaKVCObject(version, @"configWidth") ?: @0,
                SPKMediaKVCObject(version, @"sourceWidth") ?: @0,
                SPKMediaKVCObject(version, @"maxWidth") ?: @0,
                SPKMediaIvarValue(version, "_width") ?: @0,
                SPKMediaIvarValue(version, "_originalWidth") ?: @0,
                SPKMediaIvarValue(version, "_configWidth") ?: @0
            ]);
            heightValue = SPKMediaFirstNumberFromValues(@[
                SPKMediaNumberForSelector(version, @"height") ?: @0,
                SPKMediaNumberForSelector(version, @"originalHeight") ?: @0,
                SPKMediaNumberForSelector(version, @"configHeight") ?: @0,
                SPKMediaNumberForSelector(version, @"sourceHeight") ?: @0,
                SPKMediaNumberForSelector(version, @"maxHeight") ?: @0,
                SPKMediaKVCObject(version, @"height") ?: @0,
                SPKMediaKVCObject(version, @"originalHeight") ?: @0,
                SPKMediaKVCObject(version, @"configHeight") ?: @0,
                SPKMediaKVCObject(version, @"sourceHeight") ?: @0,
                SPKMediaKVCObject(version, @"maxHeight") ?: @0,
                SPKMediaIvarValue(version, "_height") ?: @0,
                SPKMediaIvarValue(version, "_originalHeight") ?: @0,
                SPKMediaIvarValue(version, "_configHeight") ?: @0
            ]);
            bandwidthValue = SPKMediaNumberForSelector(version, @"bandwidth")
                                 ?: SPKMediaKVCObject(version, @"bandwidth")
                                    ?
                                    : SPKMediaIvarValue(version, "_bandwidth");
            fileSizeValue = SPKMediaExtractCandidateFileSize(
                SPKMediaObjectForSelector(version, @"fileSize")
                    ?: SPKMediaObjectForSelector(version, @"estimatedFileSize")
                    ?: SPKMediaObjectForSelector(version, @"scansSizes")
                    ?: SPKMediaObjectForSelector(version, @"estimatedScansSizes")
                    ?: SPKMediaKVCObject(version, @"fileSize")
                    ?: SPKMediaKVCObject(version, @"estimatedFileSize")
                    ?: SPKMediaKVCObject(version, @"scansSizes")
                    ?: SPKMediaKVCObject(version, @"estimatedScansSizes")
                    ?: SPKMediaKVCObject(version, @"size")
                    ?: SPKMediaIvarValue(version, "_fileSize")
                    ?: SPKMediaIvarValue(version, "_estimatedFileSize"));
        }

        NSURL *url = SPKMediaURLFromValue(rawURL);
        if (!url.absoluteString.length)
            continue;
        [variants addObject:@{
            @"url" : url,
            @"width" : @(SPKMediaDoubleValue(widthValue)),
            @"height" : @(SPKMediaDoubleValue(heightValue)),
            @"bandwidth" : @(SPKMediaIntegerValue(bandwidthValue)),
            @"fileSizeBytes" : @(SPKMediaIntegerValue(fileSizeValue))
        }];
    }
    return SPKMediaNormalizedAndSortedVariants(variants);
}

static NSArray<NSDictionary *> *
SPKMediaPhotoVariantDictionaries(id mediaObject) {
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];

    NSString *mediaPK = nil;
    for (NSString *selectorName in @[ @"pk", @"mediaID", @"id" ]) {
        id value = SPKMediaObjectForSelector(mediaObject, selectorName)
                       ?: SPKMediaKVCObject(mediaObject, selectorName);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            mediaPK = value;
            break;
        }
        if ([value respondsToSelector:@selector(stringValue)]) {
            mediaPK = [value stringValue];
            if (mediaPK.length > 0)
                break;
        }
    }

    if (mediaPK.length > 0) {
        SPKInitializeWebPhotoCandidatesCacheIfNeeded();
        NSString *norm = SPKNormalizePK(mediaPK);
        NSArray *webCandidates = SPKWebPhotoCandidatesCache[norm];
        if ([webCandidates isKindOfClass:[NSArray class]]) {
            NSArray *webVariants = SPKMediaSortedVariantsFromVersions(webCandidates);
            for (NSDictionary *v in webVariants) {
                NSMutableDictionary *m = [v mutableCopy];
                m[@"isWeb"] = @YES;
                [variants addObject:m];
            }
        }
    }

    id imageVersions = SPKMediaFieldCacheValue(mediaObject, @"image_versions2");
    id candidates = [imageVersions isKindOfClass:[NSDictionary class]]
                        ? ((NSDictionary *)imageVersions)[@"candidates"]
                        : nil;
    if (!candidates) {
        candidates = SPKMediaFieldCacheValue(mediaObject, @"candidates");
    }
    if ([candidates isKindOfClass:[NSArray class]]) {
        NSArray *mobileVariants = SPKMediaSortedVariantsFromVersions(candidates);
        for (NSDictionary *v in mobileVariants) {
            NSMutableDictionary *m = [v mutableCopy];
            m[@"isWeb"] = @NO;
            [variants addObject:m];
        }
    }

    id photoObject = SPKMediaObjectForSelector(mediaObject, @"photo")
                         ?: SPKMediaObjectForSelector(mediaObject, @"rawPhoto");
    if (photoObject) {
        NSArray *photoVariants = SPKMediaSortedVariantsFromVersions(SPKMediaImageVersionsFromPhoto(photoObject));
        for (NSDictionary *v in photoVariants) {
            NSMutableDictionary *m = [v mutableCopy];
            if (!m[@"isWeb"]) {
                m[@"isWeb"] = @NO;
            }
            [variants addObject:m];
        }
    }
    return SPKMediaNormalizedAndSortedVariants(variants);
}

static NSArray<NSDictionary *> *
SPKMediaVideoVariantDictionaries(id mediaObject) {
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    id fieldCacheVariants =
        SPKMediaFieldCacheValue(mediaObject, @"video_versions");
    if ([fieldCacheVariants isKindOfClass:[NSArray class]]) {
        [variants addObjectsFromArray:SPKMediaSortedVariantsFromVersions(
                                          fieldCacheVariants)];
    }

    id videoObject = SPKMediaObjectForSelector(mediaObject, @"video")
                         ?: SPKMediaObjectForSelector(mediaObject, @"rawVideo");
    if (videoObject) {
        [variants
            addObjectsFromArray:SPKMediaSortedVariantsFromVersions(
                                    SPKMediaVideoVersionsFromVideo(videoObject))];
    }
    return SPKMediaNormalizedAndSortedVariants(variants);
}

static NSTimeInterval SPKMediaDurationForObject(id mediaObject) {
    for (NSString *selectorName in @[
             @"videoDuration", @"videoDurationSeconds", @"duration",
             @"durationSeconds"
         ]) {
        NSNumber *value = SPKMediaNumberForSelector(mediaObject, selectorName);
        if (value.doubleValue > 0.0)
            return value.doubleValue;
    }

    id videoObject = SPKMediaObjectForSelector(mediaObject, @"video");
    for (NSString *selectorName in
         @[ @"duration", @"videoDuration", @"durationSeconds" ]) {
        NSNumber *value = SPKMediaNumberForSelector(videoObject, selectorName);
        if (value.doubleValue > 0.0)
            return value.doubleValue;
    }

    id fieldValue = SPKMediaFieldCacheValue(mediaObject, @"video_duration");
    if ([fieldValue respondsToSelector:@selector(doubleValue)] &&
        [fieldValue doubleValue] > 0.0) {
        return [fieldValue doubleValue];
    }

    return 0.0;
}

static NSString *SPKMediaResolutionLabel(NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0)
        return nil;
    NSInteger shortEdge = MIN(width, height);
    if (shortEdge > 0) {
        return [NSString stringWithFormat:@"%ldp", (long)shortEdge];
    }
    return [NSString stringWithFormat:@"%ld×%ld", (long)width, (long)height];
}

static NSString *SPKMediaSubtitle(NSInteger width, NSInteger height,
                                  NSInteger bandwidth, NSTimeInterval duration,
                                  NSString *codec, NSString *trailing) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (width > 0 && height > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld×%ld", (long)width,
                                                    (long)height]];
    }
    NSString *bitrate = SPKMediaBitrateString(bandwidth);
    if (bitrate.length > 0)
        [parts addObject:bitrate];
    NSString *size = SPKMediaEstimatedSizeString(bandwidth, duration);
    if (size.length > 0)
        [parts addObject:size];
    NSString *codecSummary = SPKMediaCodecSummary(codec);
    if (codecSummary.length > 0)
        [parts addObject:codecSummary];
    if (trailing.length > 0)
        [parts addObject:trailing];
    return [parts componentsJoinedByString:@" • "];
}

static NSString *SPKMediaFileSizeString(NSInteger fileSizeBytes) {
    if (fileSizeBytes <= 0)
        return nil;
    return [NSByteCountFormatter
        stringFromByteCount:fileSizeBytes
                 countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *SPKMediaMegapixelString(NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0)
        return nil;
    double mp = ((double)width * (double)height) / 1000000.0;
    if (mp <= 0.0)
        return nil;
    if (mp < 0.1)
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MEGAPIXELS_TEXT");
    return [NSString stringWithFormat:SPKL(@"MEDIA_DOWNLOAD_QUALITY_MEGAPIXELS_FORMAT"), mp];
}

static NSString *SPKMediaAspectRatioString(NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0)
        return nil;
    double ratio = (double)width / (double)height;
    // Snap to the aspect ratios Instagram media actually ships in.
    NSArray<NSArray *> *known = @[
        @[ @"1:1", @1.0 ], @[ @"4:5", @0.8 ], @[ @"5:4", @1.25 ],
        @[ @"3:4", @0.75 ], @[ @"4:3", @(4.0 / 3.0) ], @[ @"2:3", @(2.0 / 3.0) ],
        @[ @"3:2", @1.5 ], @[ @"9:16", @0.5625 ], @[ @"16:9", @(16.0 / 9.0) ]
    ];
    for (NSArray *entry in known) {
        double value = [entry[1] doubleValue];
        if (fabs(ratio - value) / value <= 0.03)
            return entry[0];
    }
    // Fall back to a reduced integer ratio when it stays tidy, else a decimal.
    NSInteger a = width, b = height;
    while (b != 0) {
        NSInteger t = b;
        b = a % b;
        a = t;
    }
    NSInteger rw = a > 0 ? width / a : width;
    NSInteger rh = a > 0 ? height / a : height;
    if (rw <= 32 && rh <= 32)
        return [NSString stringWithFormat:@"%ld:%ld", (long)rw, (long)rh];
    return [NSString stringWithFormat:@"%.2f:1", ratio];
}

static NSString *SPKMediaPhotoFormatFromURL(NSURL *url) {
    NSString *ext = url.path.pathExtension.lowercaseString;
    return ext.length > 0 ? ext : nil;
}

/// Relative quality tier for a photo candidate, judged against the largest
/// candidate's long edge. Titles still carry the exact resolution alongside.
static NSString *SPKMediaPhotoTierLabel(NSInteger longEdge,
                                        NSInteger maxLongEdge) {
    if (longEdge <= 0 || maxLongEdge <= 0)
        return nil;
    double fraction = (double)longEdge / (double)maxLongEdge;
    if (fraction >= 0.98)
        return SPKL(@"MENU_MAX");
    if (fraction >= 0.6)
        return SPKL(@"MENU_HIGH");
    if (fraction >= 0.35)
        return SPKL(@"MENU_MEDIUM");
    return SPKL(@"MENU_LOW");
}

static NSString *SPKMediaPhotoSubtitle(NSInteger width, NSInteger height,
                                       NSInteger fileSizeBytes) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *megapixels = SPKMediaMegapixelString(width, height);
    if (megapixels.length > 0)
        [parts addObject:megapixels];
    NSString *aspect = SPKMediaAspectRatioString(width, height);
    if (aspect.length > 0)
        [parts addObject:aspect];
    NSString *size = SPKMediaFileSizeString(fileSizeBytes);
    if (size.length > 0)
        [parts addObject:size];
    return [parts componentsJoinedByString:@" • "];
}

static NSString *SPKMediaQualityInfoForOption(SPKMediaOption *option) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (option.title.length > 0)
        [lines addObject:option.title];
    if (option.subtitle.length > 0)
        [lines addObject:option.subtitle];
    if (option.primaryURL.absoluteString.length > 0)
        [lines
            addObject:[NSString stringWithFormat:SPKL(@"MEDIA_DOWNLOAD_QUALITY_URL_FORMAT"),
                                                 option.primaryURL.absoluteString]];
    if (option.secondaryURL.absoluteString.length > 0)
        [lines addObject:[NSString
                             stringWithFormat:SPKL(@"MEDIA_DOWNLOAD_QUALITY_AUDIO_URL_FORMAT"),
                                              option.secondaryURL.absoluteString]];
    return [lines componentsJoinedByString:@"\n"];
}

static UIImage *SPKMediaIcon(NSString *name, CGFloat pointSize) {
    // menuIconNamed: avoids the UIGraphicsImageRenderer downscale that iOS 16's
    // UIMenu renders blank for vector-backed (.svg) glyphs. All callers use the
    // 22pt menu size; the button callers are image views that render it fine.
    (void)pointSize;
    return [SPKAssetUtils menuIconNamed:name];
}

static CGFloat const kSPKMediaOptionIconPointSize = 22.0;
static CGFloat const kSPKMediaOptionControlSize = 40.0;

static NSArray<SPKMediaOption *> *
SPKMediaBuildPhotoOptions(id mediaObject, NSURL *fallbackURL,
                          NSTimeInterval duration) {
    NSMutableArray<SPKMediaOption *> *options = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableSet<NSString *> *seenResolutions = [NSMutableSet set];

    NSArray<NSDictionary *> *variants =
        SPKMediaPhotoVariantDictionaries(mediaObject);

    // Identify max long edge and canonical aspect ratio from the leader
    NSInteger maxLongEdge = 0;
    double mainAspect = 0.0;
    for (NSDictionary *variant in variants) {
        NSInteger w = [variant[@"width"] integerValue];
        NSInteger h = [variant[@"height"] integerValue];
        NSInteger longEdge = MAX(w, h);
        if (longEdge > maxLongEdge) {
            maxLongEdge = longEdge;
            if (w > 0 && h > 0) {
                mainAspect = (double)w / (double)h;
            }
        }
    }

    // Identify max long edge for web variants and mobile variants
    NSInteger maxWebLongEdge = 0;
    NSInteger maxMobileLongEdge = 0;
    for (NSDictionary *variant in variants) {
        NSInteger w = [variant[@"width"] integerValue];
        NSInteger h = [variant[@"height"] integerValue];
        NSInteger longEdge = MAX(w, h);
        if ([variant[@"isWeb"] boolValue]) {
            if (longEdge > maxWebLongEdge) {
                maxWebLongEdge = longEdge;
            }
        } else {
            if (longEdge > maxMobileLongEdge) {
                maxMobileLongEdge = longEdge;
            }
        }
    }

    for (NSDictionary *variant in variants) {
        NSURL *url = variant[@"url"];
        if (!url.absoluteString.length || [seen containsObject:url.absoluteString])
            continue;

        NSInteger width = [variant[@"width"] integerValue];
        NSInteger height = [variant[@"height"] integerValue];

        // 1. Aspect Ratio Filter: exclude cropped variants (e.g. 1:1 grid thumbs on non-1:1 photos)
        if (mainAspect > 0.0 && width > 0 && height > 0) {
            double aspect = (double)width / (double)height;
            double aspectDiff = fabs(aspect - mainAspect) / mainAspect;
            if (aspectDiff > 0.05) {
                continue;
            }
        }

        BOOL isWeb = [variant[@"isWeb"] boolValue];

        // 2. Resolution Deduplication: per source (web vs mobile)
        NSString *resKey = (width > 0 && height > 0)
            ? [NSString stringWithFormat:@"%@-%ldx%ld", isWeb ? @"web" : @"mobile", (long)width, (long)height]
            : nil;
        if (resKey.length > 0 && [seenResolutions containsObject:resKey]) {
            continue;
        }
        if (resKey.length > 0) {
            [seenResolutions addObject:resKey];
        }

        [seen addObject:url.absoluteString];

        NSInteger fileSizeBytes = [variant[@"fileSizeBytes"] integerValue];
        SPKMediaOption *option = [[SPKMediaOption alloc] init];
        option.kind = SPKMediaOptionKindPhotoProgressive;
        option.primaryURL = url;
        option.width = width;
        option.height = height;
        option.fileSizeBytes = fileSizeBytes;
        option.duration = duration;
        option.codec = SPKMediaPhotoFormatFromURL(url);
        option.isWeb = isWeb;

        NSString *resolution =
            (width > 0 && height > 0)
                ? [NSString stringWithFormat:@"%ld×%ld", (long)width, (long)height]
                : (SPKMediaResolutionLabel(width, height) ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_IMAGE_TEXT"));

        NSString *tier = nil;
        if (isWeb) {
            NSInteger itemLongEdge = MAX(width, height);
            if (maxWebLongEdge > 0 && itemLongEdge >= (NSInteger)(maxWebLongEdge * 0.9)) {
                tier = SPKL(@"MENU_MAX");
            } else if (itemLongEdge >= 1080) {
                tier = SPKL(@"MENU_HIGH");
            } else if (itemLongEdge >= 720) {
                tier = SPKL(@"MENU_MEDIUM");
            } else if (itemLongEdge > 0) {
                tier = SPKL(@"MENU_LOW");
            } else {
                tier = SPKL(@"MENU_MAX");
            }
        } else if (maxMobileLongEdge > 0) {
            double fraction = (double)MAX(width, height) / (double)maxMobileLongEdge;
            if (fraction >= 0.9) {
                tier = SPKL(@"MENU_HIGH");
            } else if (fraction >= 0.5) {
                tier = SPKL(@"MENU_MEDIUM");
            } else {
                tier = SPKL(@"MENU_LOW");
            }
        }

        option.title = tier.length > 0
                           ? [NSString stringWithFormat:@"%@ · %@", tier, resolution]
                           : resolution;
        option.subtitle = SPKMediaPhotoSubtitle(width, height, option.fileSizeBytes);
        option.selectable = YES;
        option.qualityInfo = SPKMediaQualityInfoForOption(option);
        [options addObject:option];
    }

    if (fallbackURL.absoluteString.length > 0 &&
        ![seen containsObject:fallbackURL.absoluteString]) {
        SPKMediaOption *fallback = [[SPKMediaOption alloc] init];
        fallback.kind = SPKMediaOptionKindPhotoProgressive;
        fallback.primaryURL = fallbackURL;
        fallback.codec = SPKMediaPhotoFormatFromURL(fallbackURL);
        fallback.title = SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_IMAGE_TEXT");
        fallback.subtitle = SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_FALLBACK_SOURCE_TEXT");
        fallback.selectable = YES;
        fallback.qualityInfo = SPKMediaQualityInfoForOption(fallback);
        [options addObject:fallback];
    }

    return options;
}

static NSArray<SPKMediaOption *> *
SPKMediaBuildProgressiveVideoOptions(id mediaObject, NSURL *fallbackURL,
                                     NSTimeInterval duration) {
    NSMutableArray<SPKMediaOption *> *options = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSDictionary *variant in SPKMediaVideoVariantDictionaries(mediaObject)) {
        NSURL *url = variant[@"url"];
        if (!url.absoluteString.length || [seen containsObject:url.absoluteString])
            continue;
        [seen addObject:url.absoluteString];

        SPKMediaOption *option = [[SPKMediaOption alloc] init];
        option.kind = SPKMediaOptionKindVideoProgressive;
        option.primaryURL = url;
        option.width = [variant[@"width"] integerValue];
        option.height = [variant[@"height"] integerValue];
        option.bandwidth = [variant[@"bandwidth"] integerValue];
        option.duration = duration;
        option.title =
            SPKMediaResolutionLabel(option.width, option.height) ?: SPKL(@"COMMON_MEDIA_TYPE_VIDEO");
        option.subtitle =
            SPKMediaSubtitle(option.width, option.height, option.bandwidth,
                             duration, nil, SPKL(@"MEDIA_DOWNLOAD_QUALITY_PROGRESSIVE_LABEL"));
        option.selectable = YES;
        option.qualityInfo = SPKMediaQualityInfoForOption(option);
        [options addObject:option];
    }

    if (fallbackURL.absoluteString.length > 0 &&
        ![seen containsObject:fallbackURL.absoluteString]) {
        SPKMediaOption *fallback = [[SPKMediaOption alloc] init];
        fallback.kind = SPKMediaOptionKindVideoProgressive;
        fallback.primaryURL = fallbackURL;
        fallback.duration = duration;
        fallback.title = SPKL(@"COMMON_MEDIA_TYPE_VIDEO");
        fallback.subtitle = SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_FALLBACK_PROGRESSIVE_TEXT");
        fallback.selectable = YES;
        fallback.qualityInfo = SPKMediaQualityInfoForOption(fallback);
        [options addObject:fallback];
    }

    return options;
}

static NSArray<SPKDashRepresentation *> *
SPKMediaRepresentationsForType(NSArray<SPKDashRepresentation *> *reps,
                               NSString *type) {
    NSPredicate *predicate =
        [NSPredicate predicateWithBlock:^BOOL(
                         SPKDashRepresentation *evaluatedObject,
                         NSDictionary<NSString *, id> *_Nullable bindings) {
            (void)bindings;
            return [evaluatedObject.contentType isEqualToString:type];
        }];
    return [reps filteredArrayUsingPredicate:predicate];
}

static NSArray<SPKMediaOption *> *
SPKMediaBuildMergedDashOptions(NSArray<SPKDashRepresentation *> *videoReps,
                               SPKDashRepresentation *bestAudio,
                               NSTimeInterval duration, BOOL ffmpegAvailable) {
    NSMutableArray<SPKMediaOption *> *options = [NSMutableArray array];
    for (SPKDashRepresentation *videoRep in videoReps) {
        if (!videoRep.url)
            continue;
        SPKMediaOption *option = [[SPKMediaOption alloc] init];
        option.kind = SPKMediaOptionKindVideoDashMerged;
        option.primaryURL = videoRep.url;
        option.secondaryURL = bestAudio.url;
        option.width = videoRep.width;
        option.height = videoRep.height;
        option.bandwidth = videoRep.bandwidth;
        option.audioBandwidth = bestAudio.bandwidth;
        option.duration = duration;
        option.codec = videoRep.codecs;
        option.audioCodec = bestAudio.codecs;
        option.title = SPKMediaResolutionLabel(videoRep.width, videoRep.height)
                           ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MERGED_VIDEO_TEXT");
        option.subtitle =
            SPKMediaSubtitle(videoRep.width, videoRep.height,
                             videoRep.bandwidth + bestAudio.bandwidth, duration,
                             nil, bestAudio.url ? SPKL(@"MEDIA_DOWNLOAD_QUALITY_VIDEO_AUDIO_SECTION") : SPKL(@"COMMON_MEDIA_TYPE_VIDEO"));
        option.selectable = ffmpegAvailable;
        option.qualityInfo = SPKMediaQualityInfoForOption(option);
        [options addObject:option];
    }
    return options;
}

static NSArray<SPKMediaOption *> *
SPKMediaBuildVideoOnlyDashOptions(NSArray<SPKDashRepresentation *> *videoReps,
                                  NSTimeInterval duration) {
    NSMutableArray<SPKMediaOption *> *options = [NSMutableArray array];
    for (SPKDashRepresentation *videoRep in videoReps) {
        if (!videoRep.url)
            continue;
        SPKMediaOption *option = [[SPKMediaOption alloc] init];
        option.kind = SPKMediaOptionKindVideoDashOnly;
        option.primaryURL = videoRep.url;
        option.width = videoRep.width;
        option.height = videoRep.height;
        option.bandwidth = videoRep.bandwidth;
        option.duration = duration;
        option.codec = videoRep.codecs;
        option.title = SPKMediaResolutionLabel(videoRep.width, videoRep.height)
                           ?: SPKL(@"DOWNLOADS_QUALITY_VIDEO_ONLY_TITLE");
        option.subtitle =
            SPKMediaSubtitle(videoRep.width, videoRep.height, videoRep.bandwidth,
                             duration, nil, @"silent");
        option.selectable = YES;
        option.qualityInfo = SPKMediaQualityInfoForOption(option);
        [options addObject:option];
    }
    return options;
}

static NSArray<SPKMediaOption *> *
SPKMediaBuildAudioDashOptions(NSArray<SPKDashRepresentation *> *audioReps,
                              NSTimeInterval duration, BOOL includeAudio) {
    NSMutableArray<SPKMediaOption *> *options = [NSMutableArray array];
    for (SPKDashRepresentation *audioRep in audioReps) {
        if (!audioRep.url)
            continue;
        SPKMediaOption *option = [[SPKMediaOption alloc] init];
        option.kind = SPKMediaOptionKindAudioDash;
        option.primaryURL = audioRep.url;
        option.bandwidth = audioRep.bandwidth;
        option.duration = duration;
        option.codec = audioRep.codecs;
        option.title = SPKL(@"COMMON_MEDIA_TYPE_AUDIO");
        option.subtitle =
            SPKMediaSubtitle(0, 0, audioRep.bandwidth, duration, nil, nil);
        option.selectable = includeAudio;
        option.qualityInfo = SPKMediaQualityInfoForOption(option);
        [options addObject:option];
    }
    return options;
}

static NSInteger SPKMediaAudioCodecPreferenceScore(NSString *codec) {
    NSString *lower = codec.lowercaseString ?: @"";
    // Prefer AAC-LC and avoid xHE-AAC (mp4a.40.42), which fails on current FFmpeg
    // build.
    if ([lower containsString:@"mp4a.40.2"])
        return 300;
    if ([lower containsString:@"mp4a.40.5"])
        return 220;
    if ([lower containsString:@"mp4a.40.29"])
        return 200;
    if ([lower containsString:@"mp4a.40.42"])
        return -1000;
    if ([lower containsString:@"mp4a"])
        return 120;
    return 0;
}

static SPKDashRepresentation *SPKMediaBestMergeAudioRepresentation(
    NSArray<SPKDashRepresentation *> *audioReps) {
    if (audioReps.count == 0)
        return nil;

    NSArray<SPKDashRepresentation *> *sorted =
        [audioReps sortedArrayUsingComparator:^NSComparisonResult(
                       SPKDashRepresentation *lhs, SPKDashRepresentation *rhs) {
            NSInteger lhsScore = SPKMediaAudioCodecPreferenceScore(lhs.codecs);
            NSInteger rhsScore = SPKMediaAudioCodecPreferenceScore(rhs.codecs);
            if (lhsScore > rhsScore)
                return NSOrderedAscending;
            if (lhsScore < rhsScore)
                return NSOrderedDescending;

            // Within same codec preference, pick higher bitrate.
            if (lhs.bandwidth > rhs.bandwidth)
                return NSOrderedAscending;
            if (lhs.bandwidth < rhs.bandwidth)
                return NSOrderedDescending;
            return NSOrderedSame;
        }];
    return sorted.firstObject;
}

static SPKMediaOptionSection *
SPKMediaSection(NSString *title, NSArray<SPKMediaOption *> *options) {
    SPKMediaOptionSection *section = [[SPKMediaOptionSection alloc] init];
    section.title = title ?: @"";
    section.options = options ?: @[];
    return section;
}

static SPKMediaAnalysis *SPKMediaAnalyze(id mediaObject, NSURL *photoURL,
                                         NSURL *videoURL,
                                         SPKDownloadDestination destination,
                                         BOOL includeAudioOptions) {
    (void)destination;

    // Unwrap Sparkle's resolved-media wrappers (e.g. SPKInstantsResolvedSnap) to the real
    // IGMedia they carry. The wrapper only exposes single `sparkle*URL` properties, so
    // analysing it directly finds no imageVersions2/videoVersions candidates and the sheet
    // degrades to the lone "Fallback source" entry. The gallery origin controller unwraps
    // the same way.
    id backingMedia = SPKObjectForSelector(mediaObject, @"backingMedia") ?: SPKKVCObject(mediaObject, @"backingMedia");
    if (backingMedia)
        mediaObject = backingMedia;

    SPKMediaAnalysis *analysis = [[SPKMediaAnalysis alloc] init];
    analysis.ffmpegAvailable = [SPKMediaFFmpeg isAvailable];
    analysis.duration = SPKMediaDurationForObject(mediaObject);

    NSArray<SPKMediaOption *> *photoOptions =
        SPKMediaBuildPhotoOptions(mediaObject, photoURL, analysis.duration);
    NSArray<SPKMediaOption *> *progressiveVideoOptions =
        SPKMediaBuildProgressiveVideoOptions(mediaObject, videoURL,
                                             analysis.duration);

    NSString *manifest = [SPKDashParser dashManifestForMedia:mediaObject];
    NSArray<SPKDashRepresentation *> *representations =
        [SPKDashParser parseManifest:manifest ?: @""];
    NSArray<SPKDashRepresentation *> *dashVideo =
        SPKMediaRepresentationsForType(representations, @"video");
    NSArray<SPKDashRepresentation *> *dashAudio =
        SPKMediaRepresentationsForType(representations, @"audio");
    SPKDashRepresentation *bestAudio =
        SPKMediaBestMergeAudioRepresentation(dashAudio);

    NSArray<SPKMediaOption *> *mergedOptions = SPKMediaBuildMergedDashOptions(
        dashVideo, bestAudio, analysis.duration, analysis.ffmpegAvailable);
    NSArray<SPKMediaOption *> *videoOnlyOptions =
        SPKMediaBuildVideoOnlyDashOptions(dashVideo, analysis.duration);
    NSArray<SPKMediaOption *> *audioOptions = SPKMediaBuildAudioDashOptions(
        dashAudio, analysis.duration, includeAudioOptions);

    NSMutableArray<SPKMediaOption *> *webPhotoOptions = [NSMutableArray array];
    NSMutableArray<SPKMediaOption *> *mobilePhotoOptions = [NSMutableArray array];
    for (SPKMediaOption *opt in photoOptions) {
        if (opt.isWeb) {
            [webPhotoOptions addObject:opt];
        } else {
            [mobilePhotoOptions addObject:opt];
        }
    }

    NSMutableArray<SPKMediaOptionSection *> *photoSections = [NSMutableArray array];
    if (webPhotoOptions.count > 0) {
        [photoSections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_WEB_API_TEXT"), webPhotoOptions)];
    }
    if (mobilePhotoOptions.count > 0) {
        [photoSections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MOBILE_API_TEXT"), mobilePhotoOptions)];
    }
    if (photoSections.count == 0 && photoOptions.count > 0) {
        [photoSections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_QUALITY_PHOTOS_SECTION"), photoOptions)];
    }
    analysis.photoSections = photoSections;

    analysis.photoOptions = photoOptions;
    analysis.progressiveVideoOptions = progressiveVideoOptions;
    analysis.mergedDashOptions = mergedOptions;
    analysis.audioDashOptions = audioOptions;
    analysis.videoDashOnlyOptions = videoOnlyOptions;
    analysis.isVideo =
        (progressiveVideoOptions.count > 0 || mergedOptions.count > 0 ||
         videoOnlyOptions.count > 0 || videoURL != nil);
    analysis.fallbackOption = analysis.isVideo
                                  ? progressiveVideoOptions.firstObject
                                  : photoOptions.firstObject;

    NSMutableArray<SPKMediaOptionSection *> *sections = [NSMutableArray array];
    if (progressiveVideoOptions.count > 0)
        [sections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_READY_PLAY_TEXT"), progressiveVideoOptions)];
    if (mergedOptions.count > 0)
        [sections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_QUALITY_VIDEO_AUDIO_SECTION"), mergedOptions)];
    if (videoOnlyOptions.count > 0)
        [sections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VIDEO_ONLY_TEXT"), videoOnlyOptions)];
    if (audioOptions.count > 0 && includeAudioOptions)
        [sections addObject:SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_QUALITY_AUDIO_ONLY_SECTION"), audioOptions)];
    analysis.videoSections = sections;

    return analysis;
}

static SPKMediaOption *SPKMediaTieredOption(NSArray<SPKMediaOption *> *options, NSString *quality) {
    if (options.count == 0)
        return nil;
    if ([quality isEqualToString:@"high"])
        return options.firstObject;
    if ([quality isEqualToString:@"medium"])
        return options[(options.count - 1) / 2];
    if ([quality isEqualToString:@"low"])
        return options.lastObject;

    return nil;
}

static SPKMediaOption *
SPKMediaFirstSelectableOption(NSArray<SPKMediaOption *> *options) {
    for (SPKMediaOption *option in options ?: @[]) {
        if (option.selectable) {
            return option;
        }
    }
    return nil;
}

static SPKMediaOption *
SPKMediaFFmpegFreeHighOption(SPKMediaAnalysis *analysis) {
    return analysis.progressiveVideoOptions.firstObject
               ?: SPKMediaFirstSelectableOption(analysis.videoDashOnlyOptions)
                  ?
                  : SPKMediaFirstSelectableOption(analysis.mergedDashOptions);
}

// `qualityOverride` forces a tier instead of reading the user's download-quality
// preference. Callers that cannot surface the picker (trim, auto-save) pass one so
// this always resolves to a concrete option rather than returning nil to request a
// sheet. Pass nil for the normal, preference-driven behavior.
static SPKMediaOption *SPKMediaResolveDefaultOption(SPKMediaAnalysis *analysis,
                                                    NSString *qualityOverride) {
    NSString *preferenceKey = analysis.isVideo ? @"downloads_video_quality"
                                               : @"downloads_photo_quality";
    NSString *quality = qualityOverride;
    if (quality.length == 0) {
        quality = [SPKUtils getStringPref:preferenceKey];
    }
    if (quality.length == 0) {
        quality = analysis.isVideo ? @"always_ask" : @"high";
    }

    if (!analysis.isVideo) {
        if ([quality isEqualToString:@"always_ask"]) {
            return nil;
        }
        if ([quality isEqualToString:@"max"]) {
            return analysis.photoOptions.firstObject;
        }
        NSMutableArray<SPKMediaOption *> *mobileOptions = [NSMutableArray array];
        for (SPKMediaOption *opt in analysis.photoOptions) {
            if (!opt.isWeb) {
                [mobileOptions addObject:opt];
            }
        }
        NSArray<SPKMediaOption *> *targetOptions = (mobileOptions.count > 0) ? mobileOptions : analysis.photoOptions;
        return SPKMediaTieredOption(targetOptions, quality) ?: targetOptions.firstObject;
    }

    if (!analysis.ffmpegAvailable) {
        // Only correct the stored preference when it's what we actually read. An
        // override belongs to some other setting (auto-save's own quality), so
        // writing it here would silently rewrite the user's global download choice.
        if (qualityOverride.length == 0 && ![quality isEqualToString:@"high_ignore_dash"]) {
            [[NSUserDefaults standardUserDefaults] setObject:@"high_ignore_dash" forKey:preferenceKey];
        }
        return SPKMediaFFmpegFreeHighOption(analysis);
    }

    if ([quality isEqualToString:@"always_ask"]) {
        return nil;
    }

    if ([quality isEqualToString:@"high_ignore_dash"]) {
        return analysis.progressiveVideoOptions.firstObject ?: analysis.mergedDashOptions.firstObject ?
                                                                                                      : analysis.videoDashOnlyOptions.firstObject;
    }

    if ([quality isEqualToString:@"high"]) {
        return analysis.mergedDashOptions.firstObject ?: analysis.progressiveVideoOptions.firstObject ?
                                                                                                      : analysis.videoDashOnlyOptions.firstObject;
    }

    NSArray<SPKMediaOption *> *preferred = analysis.mergedDashOptions.count > 0
                                               ? analysis.mergedDashOptions
                                               : analysis.progressiveVideoOptions;
    return SPKMediaTieredOption(preferred, quality)
               ?: analysis.progressiveVideoOptions.firstObject
                  ?
              : analysis.mergedDashOptions.firstObject
                  ?
                  : analysis.videoDashOnlyOptions.firstObject;
}

// Builds a trim plan from a specific chosen option (used by both the
// settings-driven resolver and the "always ask" picker). The editor always
// scrubs a small muxed progressive; the final renders from `chosen`.
static SPKTrimSourcePlan *SPKMediaTrimPlanFromOption(SPKMediaOption *chosen, SPKMediaAnalysis *analysis, NSURL *videoURL) {
    NSURL *finalVideoURL = chosen.primaryURL ?: videoURL;
    if (!finalVideoURL) {
        return nil;
    }
    SPKTrimSourcePlan *plan = [[SPKTrimSourcePlan alloc] init];
    plan.editURL = analysis.progressiveVideoOptions.lastObject.primaryURL
                       ?: analysis.progressiveVideoOptions.firstObject.primaryURL
                          ?
                      : videoURL
                          ?
                          : finalVideoURL;
    plan.finalVideoURL = finalVideoURL;
    plan.finalAudioURL = chosen.secondaryURL;
    plan.needsMerge = (chosen.secondaryURL != nil);
    // Merged and video-only DASH reps are both separate (often AV1) streams that
    // must be fetched and rendered from the chosen quality — the editor scrubs
    // the progressive `editURL` preview instead. Progressive picks render the
    // edited file directly.
    plan.needsHighQualityFetch = (chosen.kind == SPKMediaOptionKindVideoDashMerged || chosen.kind == SPKMediaOptionKindVideoDashOnly);
    plan.sourceIsSilent = (chosen.kind == SPKMediaOptionKindVideoDashOnly);
    plan.width = chosen.width;
    plan.height = chosen.height;
    plan.duration = analysis.duration;
    return plan;
}

@interface SPKMediaSingleDownloadJob : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, copy) void (^progressBlock)(double progress, int64_t bytesWritten, int64_t totalBytesExpected);
@property (nonatomic, copy) void (^completionBlock)(NSURL *_Nullable fileURL, NSError *_Nullable error);
@property (nonatomic, copy) NSString *fileExtension;
@end

@implementation SPKMediaSingleDownloadJob

- (void)startWithURL:(NSURL *)url
    defaultExtension:(NSString *)defaultExtension
            progress:(void (^)(double progress, int64_t bytesWritten, int64_t totalBytesExpected))progress
          completion:(void (^)(NSURL *_Nullable fileURL, NSError *_Nullable error))completion {
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.fileExtension = url.pathExtension.length > 0
                             ? url.pathExtension.lowercaseString
                             : (defaultExtension.length > 0 ? defaultExtension : @"mp4");
    self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:nil];
    self.task = [self.session downloadTaskWithURL:url];
    [self.task resume];
}

- (void)cancel {
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.task = nil;
    self.session = nil;
}

- (NSURL *)cacheMoveURLForLocation:(NSURL *)location {
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(
                              NSCachesDirectory,
                              NSUserDomainMask,
                              YES)
                                  .firstObject
                              ?: NSTemporaryDirectory();
    NSURL *destination = [[NSURL fileURLWithPath:cachePath isDirectory:YES]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, self.fileExtension ?: @"mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&error]) {
        return nil;
    }
    return destination;
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)downloadTask;

    // Still report when the server omits Content-Length: the byte counts feed
    // download history (which falls back to bytesWritten), and the scheduler
    // ignores non-positive totals.
    double progress = 0.0;
    if (totalBytesExpectedToWrite > 0) {
        progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    }
    if (self.progressBlock) {
        self.progressBlock(MAX(0.0, MIN(1.0, progress)), totalBytesWritten, totalBytesExpectedToWrite);
    }
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    (void)downloadTask;
    NSURL *destination = [self cacheMoveURLForLocation:location];
    if (!destination && self.completionBlock) {
        self.completionBlock(nil, [SPKUtils errorWithDescription:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_FAILED_MOVE_DOWNLOADED_MEDIA_TEXT")]);
    } else if (self.completionBlock) {
        self.completionBlock(destination, nil);
    }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session;
    (void)task;
    if (!error)
        return;
    if (self.completionBlock) {
        self.completionBlock(nil, error);
    }
}

@end

// Condenses a raw codecs string (e.g. "av01.0.08M.10", "mp4a.40.2") into a
// short, scannable badge. Returns nil when the codec is unknown/absent.
static NSString *SPKMediaCodecBadge(NSString *codec) {
    NSString *lower = codec.lowercaseString ?: @"";
    if (lower.length == 0)
        return nil;
    if ([lower hasPrefix:@"avc"] || [lower containsString:@"h264"])
        return @"H.264";
    if ([lower hasPrefix:@"hvc"] || [lower hasPrefix:@"hev"] ||
        [lower containsString:@"hevc"] || [lower containsString:@"h265"])
        return @"HEVC";
    if ([lower hasPrefix:@"av01"] || [lower isEqualToString:@"av1"])
        return @"AV1";
    if ([lower hasPrefix:@"vp09"] || [lower hasPrefix:@"vp9"])
        return @"VP9";
    if ([lower hasPrefix:@"vp08"] || [lower hasPrefix:@"vp8"])
        return @"VP8";
    if ([lower containsString:@"mp4a"] || [lower containsString:@"aac"])
        return @"AAC";
    if ([lower containsString:@"opus"])
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_OPUS_TEXT");
    if ([lower containsString:@"mp3"])
        return @"MP3";
    // Photo formats (fed the file extension via SPKMediaOption.codec).
    if ([lower isEqualToString:@"jpg"] || [lower isEqualToString:@"jpeg"])
        return @"JPEG";
    if ([lower isEqualToString:@"heic"] || [lower isEqualToString:@"heif"])
        return @"HEIC";
    if ([lower isEqualToString:@"webp"])
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_WEBP_TEXT");
    if ([lower isEqualToString:@"png"])
        return @"PNG";
    if ([lower isEqualToString:@"gif"])
        return @"GIF";
    return [[lower componentsSeparatedByString:@"."].firstObject uppercaseString];
}

@interface _SPKMediaOptionCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *pillBackground;
@property (nonatomic, strong) UILabel *pillLabel;
@property (nonatomic, strong) UIButton *previewButton;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIView *highlightOverlay;
@property (nonatomic, strong) UIView *separatorLine;
@end

@implementation _SPKMediaOptionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;

    self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.contentView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    // Highlight overlay
    _highlightOverlay = [[UIView alloc] init];
    _highlightOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _highlightOverlay.backgroundColor = [SPKUtils SPKColor_ListRowPressedOverlay];
    _highlightOverlay.hidden = YES;
    [self.contentView addSubview:_highlightOverlay];

    // Separator line
    _separatorLine = [[UIView alloc] init];
    _separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    _separatorLine.backgroundColor = [SPKUtils SPKColor_InstagramSeparator];
    [self.contentView addSubview:_separatorLine];

    _previewButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _previewButton.translatesAutoresizingMaskIntoConstraints = NO;
    _previewButton.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _previewButton.backgroundColor =
        [SPKUtils SPKColor_InstagramSecondaryBackground];
    _previewButton.layer.cornerRadius = 8.0;
    _previewButton.layer.cornerCurve = kCACornerCurveContinuous;
    _previewButton.layer.masksToBounds = YES;
    _previewButton.adjustsImageWhenHighlighted = NO;
    [self.contentView addSubview:_previewButton];

    _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    _menuButton.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _menuButton.showsMenuAsPrimaryAction = YES;
    [_menuButton setImage:SPKMediaIcon(@"more", kSPKMediaOptionIconPointSize)
                 forState:UIControlStateNormal];
    [self.contentView addSubview:_menuButton];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12.0];
    _subtitleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _subtitleLabel.numberOfLines = 2;

    _pillBackground = [[UIView alloc] init];
    _pillBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _pillBackground.backgroundColor =
        [SPKUtils SPKColor_InstagramTertiaryBackground];
    _pillBackground.layer.cornerRadius = 5.0;
    _pillBackground.clipsToBounds = YES;

    _pillLabel = [[UILabel alloc] init];
    _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pillLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    _pillLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _pillLabel.numberOfLines = 1;
    [_pillBackground addSubview:_pillLabel];

    // Stack view for text info column
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _titleLabel, _subtitleLabel, _pillBackground
    ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentLeading;
    textStack.spacing = 3.0;
    [self.contentView addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [_highlightOverlay.topAnchor
            constraintEqualToAnchor:self.contentView.topAnchor],
        [_highlightOverlay.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor],
        [_highlightOverlay.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_highlightOverlay.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor],

        [_separatorLine.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor],
        [_separatorLine.leadingAnchor
            constraintEqualToAnchor:textStack.leadingAnchor],
        [_separatorLine.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_separatorLine.heightAnchor
            constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [_previewButton.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor
                           constant:16.0],
        [_previewButton.centerYAnchor
            constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_previewButton.widthAnchor constraintEqualToConstant:40.0],
        [_previewButton.heightAnchor constraintEqualToConstant:40.0],

        [_menuButton.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor
                           constant:-8.0],
        [_menuButton.centerYAnchor
            constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_menuButton.widthAnchor
            constraintEqualToConstant:kSPKMediaOptionControlSize],
        [_menuButton.heightAnchor
            constraintEqualToConstant:kSPKMediaOptionControlSize],

        [textStack.leadingAnchor
            constraintEqualToAnchor:_previewButton.trailingAnchor
                           constant:12.0],
        [textStack.trailingAnchor
            constraintLessThanOrEqualToAnchor:_menuButton.leadingAnchor
                                     constant:-10.0],
        [textStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                            constant:11.0],
        [textStack.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor
                           constant:-11.0],

        [_pillLabel.leadingAnchor
            constraintEqualToAnchor:_pillBackground.leadingAnchor
                           constant:8.0],
        [_pillLabel.trailingAnchor
            constraintEqualToAnchor:_pillBackground.trailingAnchor
                           constant:-8.0],
        [_pillLabel.topAnchor constraintEqualToAnchor:_pillBackground.topAnchor
                                             constant:3.0],
        [_pillLabel.bottomAnchor
            constraintEqualToAnchor:_pillBackground.bottomAnchor
                           constant:-3.0],
    ]];

    return self;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    if (animated) {
        [UIView animateWithDuration:highlighted ? 0.05 : 0.3
                         animations:^{
                             self.highlightOverlay.hidden = !highlighted;
                         }];
    } else {
        self.highlightOverlay.hidden = !highlighted;
    }
}

@end

@interface SPKMediaTextFieldViewController
    : UIViewController <UITextFieldDelegate>
@property (nonatomic, copy) NSString *defaultsKey;
@property (nonatomic, copy) NSString *placeholderText;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic, strong) UITextField *textField;
@end

@implementation SPKMediaTextFieldViewController

- (instancetype)initWithTitle:(NSString *)title
                  defaultsKey:(NSString *)defaultsKey
                  placeholder:(NSString *)placeholder
                       footer:(NSString *)footer {
    self = [super init];
    if (!self)
        return nil;
    self.title = title;
    self.defaultsKey = defaultsKey;
    self.placeholderText = placeholder ?: @"";
    self.footerText = footer ?: @"";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    footerLabel.numberOfLines = 0;
    footerLabel.font = [UIFont systemFontOfSize:13.0];
    footerLabel.text = self.footerText;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    card.layer.cornerRadius = 14.0;

    self.textField = [[UITextField alloc] init];
    self.textField.translatesAutoresizingMaskIntoConstraints = NO;
    self.textField.borderStyle = UITextBorderStyleRoundedRect;
    self.textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textField.returnKeyType = UIReturnKeyDone;
    self.textField.placeholder = self.placeholderText;
    self.textField.delegate = self;
    self.textField.text = [SPKUtils getStringPref:self.defaultsKey];

    [card addSubview:self.textField];
    [self.view addSubview:card];
    [self.view addSubview:footerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                           constant:24.0],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                           constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                            constant:-16.0],

        [self.textField.topAnchor constraintEqualToAnchor:card.topAnchor
                                                 constant:16.0],
        [self.textField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                     constant:16.0],
        [self.textField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                                      constant:-16.0],
        [self.textField.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                                    constant:-16.0],

        [footerLabel.topAnchor constraintEqualToAnchor:card.bottomAnchor
                                              constant:16.0],
        [footerLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [footerLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor]
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT")
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(saveTapped)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textField becomeFirstResponder];
}

- (void)saveTapped {
    NSString *value = [self.textField.text
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    [[NSUserDefaults standardUserDefaults] setObject:value ?: @""
                                              forKey:self.defaultsKey];
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self saveTapped];
    return YES;
}

@end

@interface SPKMediaEncodingSettingsViewController : SPKSettingsViewController
- (NSArray *)searchSections;
- (UIMenu *)speedMenu;
- (UIMenu *)codecMenu;
- (UIMenu *)presetMenu;
- (UIMenu *)profileMenu;
- (UIMenu *)levelMenu;
- (UIMenu *)maxResMenu;
- (UIMenu *)audioChannelsMenu;
@end

@implementation SPKMediaEncodingSettingsViewController

- (instancetype)init {
    if ((self = [super initWithTitle:SPKL(@"DOWNLOADS_DOWNLOADS_SETTINGS_ENCODING_SETTINGS_TITLE")
                            sections:[self buildSections]
                        reduceMargin:NO])) {
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)switchChanged:(UISwitch *)sender {
    [super switchChanged:sender];
    SPKSetting *row = [self settingForSender:sender];
    if ([row.defaultsKey isEqualToString:@"downloads_adv_encoding"]) {
        [self replaceSections:[self buildSections]];
    }
}

- (SPKSetting *)advancedEncodingRow {
    return SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_ADVANCED_ENCODING_TEXT")
                                                  defaultsKey:@"downloads_adv_encoding"],
                              SPKL(@"MEDIA_ENCODING_ADVANCED_HELP"));
}

- (SPKSetting *)speedRow {
    return SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_ENCODING_SPEED_TEXT")
                                                   subtitle:nil
                                                       menu:[self speedMenu]],
                              SPKL(@"MEDIA_ENCODING_SPEED_HELP"));
}

// Advanced rows grouped as on the page. `hideUnused` hides the libx264-only rows
// while VideoToolbox is selected, since that encoder ignores them; search keeps
// every row findable.
- (NSArray *)advancedSectionsHidingUnusedRows:(BOOL)hideUnused {
    BOOL (^notLibx264)(void) = hideUnused ? ^BOOL {
        return ![[SPKUtils getStringPref:@"downloads_encoding_vid_codec"] isEqualToString:@"libx264"];
    } : nil;

    SPKSetting *preset = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_PRESET_TEXT")
                                                                 subtitle:nil
                                                                     menu:[self presetMenu]],
                                            SPKL(@"MEDIA_ENCODING_PRESET_HELP"));
    SPKSetting *profile = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_H_PROFILE_TEXT")
                                                                  subtitle:nil
                                                                      menu:[self profileMenu]],
                                             SPKL(@"MEDIA_ENCODING_H264_PROFILE_HELP"));
    SPKSetting *level = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_H_LEVEL_TEXT")
                                                                subtitle:nil
                                                                    menu:[self levelMenu]],
                                           SPKL(@"MEDIA_ENCODING_H264_LEVEL_HELP"));
    SPKSetting *crf = SPKSettingWithHelp([SPKSetting textFieldCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_CRF_TEXT")
                                                                placeholder:SPKL(@"VC_PLACEHOLDER_AUTO")
                                                               keyboardType:UIKeyboardTypeNumberPad
                                                                defaultsKey:@"downloads_encoding_crf"],
                                         SPKL(@"MEDIA_ENCODING_CRF_HELP"));
    preset.hiddenProvider = notLibx264;
    profile.hiddenProvider = notLibx264;
    level.hiddenProvider = notLibx264;
    crf.hiddenProvider = notLibx264;

    // Every group explains its options in an info sheet, even when hiding the
    // libx264-only rows leaves a single row that would otherwise get a footer.
    return @[
        SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"COMMON_MEDIA_TYPE_VIDEO"),
                        @[
                            SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VIDEO_CODEC_TEXT")
                                                                    subtitle:nil
                                                                        menu:[self codecMenu]],
                                               SPKL(@"MEDIA_ENCODING_VIDEO_CODEC_HELP")),
                            preset, profile, level
                        ],
                        nil), YES),
        SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"AUTO_SAVE_AUTO_SAVE_SETTINGS_QUALITY_HEADER"),
                        @[
                            crf,
                            SPKSettingWithHelp([SPKSetting textFieldCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VIDEO_BITRATE_TEXT")
                                                                      placeholder:SPKL(@"VC_PLACEHOLDER_AUTO")
                                                                     keyboardType:UIKeyboardTypeNumberPad
                                                                      defaultsKey:@"downloads_encoding_vid_bitrate_kbps"],
                                               SPKL(@"MEDIA_ENCODING_VIDEO_BITRATE_HELP")),
                            SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MAX_RESOLUTION_TEXT")
                                                                    subtitle:nil
                                                                        menu:[self maxResMenu]],
                                               SPKL(@"MEDIA_ENCODING_MAX_RESOLUTION_HELP"))
                        ],
                        nil), YES),
        SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"COMMON_MEDIA_TYPE_AUDIO"),
                        @[
                            SPKSettingWithHelp([SPKSetting textFieldCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_AUDIO_BITRATE_TEXT")
                                                                      placeholder:@"128"
                                                                     keyboardType:UIKeyboardTypeNumberPad
                                                                      defaultsKey:@"downloads_encoding_audio_bitrate_kbps"],
                                               SPKL(@"MEDIA_ENCODING_AUDIO_BITRATE_HELP")),
                            SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_AUDIO_CHANNELS_TEXT")
                                                                    subtitle:nil
                                                                        menu:[self audioChannelsMenu]],
                                               SPKL(@"MEDIA_ENCODING_AUDIO_CHANNELS_HELP"))
                        ],
                        nil), YES)
    ];
}

- (SPKSetting *)ffmpegInfoRow {
    SPKSetting *ffmpegInfo = [SPKSetting
        linkCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_ABOUT_FFMPEG_ENCODING_TEXT")
                 subtitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_TAP_LEARN_MORE_TEXT")
                 imageUrl:@"https://ffmpeg.org/favicon.ico"
                      url:@"https://trac.ffmpeg.org/wiki/Encode/H.264"];
    ffmpegInfo.userInfo = @{@"remoteImageCircular" : @NO};
    return ffmpegInfo;
}

- (NSArray *)buildSections {
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:SPKTopicSection(@"", @[ [self advancedEncodingRow] ], nil)];

    if (![SPKUtils getBoolPref:@"downloads_adv_encoding"]) {
        [sections addObject:SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"COMMON_MEDIA_TYPE_VIDEO"), @[ [self speedRow] ], nil), YES)];
        return sections;
    }

    [sections addObjectsFromArray:[self advancedSectionsHidingUnusedRows:YES]];

    __weak typeof(self) weakSelf = self;
    SPKSetting *resetEncoding =
        [SPKSetting buttonCellWithTitle:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_RESET_ENCODING_SETTINGS_TEXT")
                               subtitle:nil
                                   icon:SPKSettingsIcon(@"arrow_ccw")
                                 action:^{
                                     [[SPKSettingsTransferManager sharedManager]
                                         resetConfigurationGroupFromController:weakSelf
                                                                         title:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_RESET_ENCODING_SETTINGS_TEXT")
                                                                       message:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_RESTORES_EVERY_ADVANCED_ENCODING_OPTION_DEFAULT_VALUE_ADVANCED_ENCODING_TEXT")
                                                                  confirmTitle:SPKL(@"DATA_RESET_HEADER")
                                                                          keys:@[
                                                                              @"downloads_encoding_speed",
                                                                              @"downloads_encoding_vid_codec",
                                                                              @"downloads_encoding_preset",
                                                                              @"downloads_encoding_h264_profile",
                                                                              @"downloads_encoding_h264_level",
                                                                              @"downloads_encoding_crf",
                                                                              @"downloads_encoding_vid_bitrate_kbps",
                                                                              @"downloads_encoding_max_resolution",
                                                                              @"downloads_encoding_audio_bitrate_kbps",
                                                                              @"downloads_encoding_audio_channels"
                                                                          ]
                                                                       onReset:^{
                                                                           [weakSelf replaceSections:[weakSelf buildSections]];
                                                                       }];
                                 }];
    resetEncoding.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    resetEncoding.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];
    [sections addObject:SPKTopicSection(@"", @[ resetEncoding ], nil)];
    [sections addObject:SPKTopicSection(@"", @[ [self ffmpegInfoRow] ], nil)];

    return sections;
}

- (NSArray *)searchSections {
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:SPKTopicSection(@"", @[ [self advancedEncodingRow] ], nil)];
    [sections addObject:SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"COMMON_MEDIA_TYPE_VIDEO"), @[ [self speedRow] ], nil), YES)];
    [sections addObjectsFromArray:[self advancedSectionsHidingUnusedRows:NO]];
    [sections addObject:SPKTopicSection(@"", @[ [self ffmpegInfoRow] ], nil)];
    return sections;
}

- (UIMenu *)speedMenu {
    return [self buildMenuForPref:@"downloads_encoding_speed"
                            items:@[
                                @{@"value" : @"ultrafast", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_ULTRAFAST_LABEL")},
                                @{@"value" : @"faster", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_FASTER_LABEL")},
                                @{@"value" : @"medium", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_MEDIUM_LABEL")},
                                @{@"value" : @"slower", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_SLOWER_LABEL")}
                            ]];
}

- (UIMenu *)codecMenu {
    return [self
        buildMenuForPref:@"downloads_encoding_vid_codec"
                   items:@[
                       @{@"value" : @"libx264", @"label" : SPKL(@"MEDIA_ENCODING_CODEC_SOFTWARE_LABEL")},
                       @{@"value" : @"videotoolbox", @"label" : SPKL(@"MEDIA_ENCODING_CODEC_HARDWARE_LABEL")}
                   ]];
}

- (UIMenu *)presetMenu {
    return [self buildMenuForPref:@"downloads_encoding_preset"
                            items:@[
                                @{@"value" : @"ultrafast", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_ULTRAFAST_LABEL")},
                                @{@"value" : @"superfast", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_SUPERFAST_TEXT")},
                                @{@"value" : @"veryfast", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VERY_FAST_TEXT")},
                                @{@"value" : @"faster", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_FASTER_LABEL")},
                                @{@"value" : @"fast", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_FAST_TEXT")},
                                @{@"value" : @"medium", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_MEDIUM_LABEL")},
                                @{@"value" : @"slow", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_SLOW_TEXT")},
                                @{@"value" : @"slower", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PRESET_SLOWER_LABEL")},
                                @{@"value" : @"veryslow", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VERY_SLOW_TEXT")}
                            ]];
}

- (UIMenu *)profileMenu {
    return [self buildMenuForPref:@"downloads_encoding_h264_profile"
                            items:@[
                                @{@"value" : @"baseline", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_BASELINE_TEXT")},
                                @{@"value" : @"main", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MAIN_TEXT")},
                                @{@"value" : @"high", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_PROFILE_HIGH_LABEL")}
                            ]];
}

- (UIMenu *)levelMenu {
    return [self buildMenuForPref:@"downloads_encoding_h264_level"
                            items:@[
                                @{@"value" : @"auto", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_LEVEL_AUTO_LABEL")},
                                @{@"value" : @"3.1", @"label" : @"3.1"},
                                @{@"value" : @"4.0", @"label" : @"4.0"},
                                @{@"value" : @"4.1", @"label" : @"4.1"},
                                @{@"value" : @"5.0", @"label" : @"5.0"}
                            ]];
}

- (UIMenu *)maxResMenu {
    return [self buildMenuForPref:@"downloads_encoding_max_resolution"
                            items:@[
                                @{@"value" : @"original", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_MAX_RESOLUTION_ORIGINAL_LABEL")},
                                @{@"value" : @"480", @"label" : @"480p"}, // SPK_I18N_IGNORE: resolution label
                                @{@"value" : @"720", @"label" : @"720p"}, // SPK_I18N_IGNORE: resolution label
                                @{@"value" : @"1080", @"label" : @"1080p"} // SPK_I18N_IGNORE: resolution label
                            ]];
}

- (UIMenu *)audioChannelsMenu {
    return [self buildMenuForPref:@"downloads_encoding_audio_channels"
                            items:@[
                                @{@"value" : @"original", @"label" : SPKL(@"MEDIA_DOWNLOAD_QUALITY_AUDIO_CHANNELS_ORIGINAL_LABEL")},
                                @{@"value" : @"stereo", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_STEREO_TEXT")},
                                @{@"value" : @"mono", @"label" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MONO_TEXT")}
                            ]];
}

- (UIMenu *)buildMenuForPref:(NSString *)prefKey
                       items:(NSArray<NSDictionary *> *)items {
    NSMutableArray<UICommand *> *commands = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *value = item[@"value"];
        NSString *label = item[@"label"];
        UICommand *command = [UICommand
            commandWithTitle:label
                       image:nil
                      action:@selector(menuChanged:)
                propertyList:@{@"defaultsKey" : prefKey, @"value" : value}];
        [commands addObject:command];
    }
    return [UIMenu menuWithTitle:@""
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:commands];
}

@end

@interface SPKMediaOptionsSheetViewController
    : UIViewController <UITableViewDataSource, UITableViewDelegate,
                        UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SPKMediaAnalysis *analysis;
@property (nonatomic) SPKDownloadDestination destination;
@property (nonatomic, copy) void (^selectionHandler)(SPKMediaOption *option);
/// Called when the sheet is dismissed (close button or swipe) WITHOUT a
/// selection. Lets callers (e.g. the trim flow) release their state.
@property (nonatomic, copy) void (^dismissHandler)(void);
@property (nonatomic, assign) BOOL spkDidSelect;
@end

@implementation SPKMediaOptionsSheetViewController

- (instancetype)initWithAnalysis:(SPKMediaAnalysis *)analysis
                     destination:(SPKDownloadDestination)destination
                selectionHandler:
                    (void (^)(SPKMediaOption *option))selectionHandler {
    self = [super init];
    if (!self)
        return nil;
    self.analysis = analysis;
    self.destination = destination;
    self.selectionHandler = selectionHandler;
    self.title = analysis.isVideo ? SPKL(@"AUTO_SAVE_AUTO_SAVE_SETTINGS_VIDEO_QUALITY_TITLE") : SPKL(@"AUTO_SAVE_AUTO_SAVE_SETTINGS_PHOTO_QUALITY_TITLE");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:_SPKMediaOptionCell.class
           forCellReuseIdentifier:@"option"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[SPKAssetUtils instagramIconNamed:@"xmark"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor =
        [SPKUtils SPKColor_InstagramPrimaryText];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [SPKUtils updateScrollingForFittedContent:self.tableView];
}

- (NSArray<SPKMediaOptionSection *> *)sections {
    if (self.analysis.isVideo) {
        return self.analysis.videoSections;
    }
    return self.analysis.photoSections ?: @[];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].options.count;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return self.sections[section].title;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    SPKMediaOptionSection *infoSection = self.sections[section];
    if (infoSection.options.firstObject.kind == SPKMediaOptionKindVideoDashMerged &&
        !self.analysis.ffmpegAvailable) {
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_FFMPEGKIT_NOT_AVAILABLE_ACTIVE_BUILD_SO_MERGED_DASH_ROWS_TEXT");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    _SPKMediaOptionCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"option"
                                        forIndexPath:indexPath];
    SPKMediaOption *option =
        self.sections[indexPath.section].options[indexPath.row];
    cell.titleLabel.text = option.title;
    cell.subtitleLabel.text = option.subtitle;
    NSString *codecBadge = SPKMediaCodecBadge(option.codec);
    cell.pillLabel.text = codecBadge;
    cell.pillBackground.hidden = (codecBadge.length == 0);
    cell.previewButton.tag = (indexPath.section << 16) | indexPath.row;
    [cell.previewButton removeTarget:nil
                              action:NULL
                    forControlEvents:UIControlEventTouchUpInside];
    // Only photo/audio rows offer a preview; video reps render black (raw DASH
    // streams are often AV1/VP9 that AVPlayer can't decode on older iOS) and the
    // media is already visible behind the sheet. Keep the glyph as a static icon.
    BOOL previewable = (option.kind == SPKMediaOptionKindPhotoProgressive ||
                        option.kind == SPKMediaOptionKindAudioDash);
    cell.previewButton.userInteractionEnabled = previewable;
    if (previewable) {
        [cell.previewButton addTarget:self
                               action:@selector(previewTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
    }
    NSString *previewIconName =
        option.kind == SPKMediaOptionKindPhotoProgressive ? @"photo"
        : option.kind == SPKMediaOptionKindAudioDash      ? @"audio"
                                                          : @"video";
    [cell.previewButton
        setImage:SPKMediaIcon(previewIconName, kSPKMediaOptionIconPointSize)
        forState:UIControlStateNormal];
    cell.menuButton.menu = [self menuForOption:option];
    cell.userInteractionEnabled = YES;
    cell.titleLabel.alpha = option.selectable ? 1.0 : 0.65;
    cell.subtitleLabel.alpha = option.selectable ? 1.0 : 0.65;
    cell.pillBackground.alpha = option.selectable ? 1.0 : 0.65;
    cell.accessoryType = option.selectable ? UITableViewCellAccessoryNone
                                           : UITableViewCellAccessoryNone;
    return cell;
}

- (void)previewTapped:(UIButton *)button {
    NSInteger sectionIndex = (button.tag >> 16) & 0xFFFF;
    NSInteger rowIndex = button.tag & 0xFFFF;
    if (sectionIndex >= self.sections.count)
        return;
    SPKMediaOptionSection *section = self.sections[sectionIndex];
    if (rowIndex >= section.options.count)
        return;
    [self previewOption:section.options[rowIndex]];
}

- (void)previewOption:(SPKMediaOption *)option {
    if (option.kind == SPKMediaOptionKindPhotoProgressive) {
        [SPKFullScreenMediaPlayer showRemoteImageURLPreview:option.primaryURL];
        return;
    }
    if (option.kind == SPKMediaOptionKindAudioDash) {
        SPKMediaItem *item = [SPKMediaItem itemWithFileURL:option.primaryURL];
        item.mediaType = SPKMediaItemTypeAudio;
        item.title = option.title.length > 0 ? option.title : SPKL(@"COMMON_MEDIA_TYPE_AUDIO");
        [SPKFullScreenMediaPlayer showMediaItems:@[ item ]
                                 startingAtIndex:0
                                        metadata:nil
                                  playbackSource:SPKFullScreenPlaybackSourceUnknown
                                      sourceView:self.view
                                      controller:self
                                   pausePlayback:nil
                                  resumePlayback:nil];
        return;
    }

    // Video reps aren't previewed — raw DASH streams (often AV1/VP9) render black
    // on older iOS, and the media is already visible behind the sheet.
}

- (UIMenu *)menuForOption:(SPKMediaOption *)option {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

    if (option.primaryURL.absoluteString.length > 0) {
        NSString *title =
            option.kind == SPKMediaOptionKindPhotoProgressive ? SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_COPY_PHOTO_DOWNLOAD_URL_TEXT")
            : option.kind == SPKMediaOptionKindAudioDash      ? SPKL(@"ALERT_ACTION_COPY_AUDIO_DOWNLOAD_URL")
                                                              : SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_COPY_VIDEO_DOWNLOAD_URL_TEXT");
        [children
            addObject:[UIAction
                          actionWithTitle:title
                                    image:SPKMediaIcon(@"link",
                                                       kSPKMediaOptionIconPointSize)
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                                      [UIPasteboard generalPasteboard].string =
                                          option.primaryURL.absoluteString;
                                  }]];
    }

    if (option.secondaryURL.absoluteString.length > 0) {
        [children
            addObject:[UIAction
                          actionWithTitle:SPKL(@"ALERT_ACTION_COPY_AUDIO_URL")
                                    image:SPKMediaIcon(@"audio",
                                                       kSPKMediaOptionIconPointSize)
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                                      [UIPasteboard generalPasteboard].string =
                                          option.secondaryURL.absoluteString;
                                  }]];
    }

    [children
        addObject:[UIAction
                      actionWithTitle:SPKL(@"ALERT_ACTION_COPY_QUALITY_INFO")
                                image:SPKMediaIcon(@"copy",
                                                   kSPKMediaOptionIconPointSize)
                           identifier:nil
                              handler:^(__unused UIAction *action) {
                                  [UIPasteboard generalPasteboard].string =
                                      option.qualityInfo ?: @"";
                              }]];

    if (option.kind == SPKMediaOptionKindPhotoProgressive) {
        [children
            addObject:[UIAction
                          actionWithTitle:SPKL(@"ALERT_ACTION_VIEW_IMAGE")
                                    image:SPKMediaIcon(@"photo",
                                                       kSPKMediaOptionIconPointSize)
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                                      [SPKFullScreenMediaPlayer
                                          showRemoteImageURLPreview:option.primaryURL];
                                  }]];
    } else if (option.kind == SPKMediaOptionKindAudioDash) {
        [children
            addObject:[UIAction
                          actionWithTitle:SPKL(@"ALERT_ACTION_PLAY_AUDIO")
                                    image:SPKMediaIcon(@"play",
                                                       kSPKMediaOptionIconPointSize)
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                                      [self previewOption:option];
                                  }]];
    }
    // Video rows expose copy actions only — no play/thumbnail preview (raw DASH
    // reps render black on older iOS; see previewOption).

    return [UIMenu menuWithChildren:children];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKMediaOption *option =
        self.sections[indexPath.section].options[indexPath.row];
    if (!option.selectable) {
        return;
    }
    self.spkDidSelect = YES;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (self.selectionHandler) {
                                     self.selectionHandler(option);
                                 }
                             }];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (!self.spkDidSelect && self.dismissHandler) {
                                     self.dismissHandler();
                                 }
                             }];
}

- (void)presentationControllerDidDismiss:
    (UIPresentationController *)presentationController {
    // Interactive swipe-to-dismiss.
    if (!self.spkDidSelect && self.dismissHandler) {
        self.dismissHandler();
    }
}

@end

static void
SPKMediaPresentOptionsSheet(UIViewController *presenter, UIView *sourceView,
                            SPKMediaAnalysis *analysis,
                            SPKDownloadDestination destination,
                            void (^selectionHandler)(SPKMediaOption *option),
                            void (^dismissHandler)(void)) {
    // Any prep pill (e.g. "Fetching 4K candidates...") has done its job once we stop
    // to ask the user: nothing downstream will adopt it, so it would otherwise hang
    // around forever when the sheet is dismissed without a choice.
    [[SPKNotificationCenter shared] dismissTransientProgressPill];
    SPKMediaOptionsSheetViewController *controller =
        [[SPKMediaOptionsSheetViewController alloc]
            initWithAnalysis:analysis
                 destination:destination
            selectionHandler:selectionHandler];
    controller.dismissHandler = dismissHandler;
    UINavigationController *nav = [[SPKChromeNavigationController alloc]
        initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[ [UISheetPresentationControllerDetent mediumDetent] ];
        sheet.prefersGrabberVisible = YES;
        sheet.selectedDetentIdentifier =
            UISheetPresentationControllerDetentIdentifierMedium;
    }
    // Route swipe-to-dismiss through the controller so `dismissHandler` fires.
    nav.presentationController.delegate = controller;
    if (nav.popoverPresentationController && sourceView) {
        nav.popoverPresentationController.sourceView = sourceView;
        nav.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [presenter presentViewController:nav animated:YES completion:nil];
}

static NSString *SPKMediaExtensionForOption(SPKMediaOption *option) {
    switch (option.kind) {
    case SPKMediaOptionKindPhotoProgressive:
        return option.primaryURL.pathExtension.length > 0
                   ? option.primaryURL.pathExtension
                   : @"jpg";
    case SPKMediaOptionKindAudioDash:
        return @"m4a";
    default:
        return @"mp4";
    }
}

static NSString *
SPKMediaCopyLocalFileToPasteboard(NSURL *fileURL, NSError **errorOut,
                                  BOOL showToast,
                                  NSString *notificationIdentifier) {
    NSString *identifier =
        notificationIdentifier.length > 0 ? notificationIdentifier : nil;
    if (!fileURL) {
        if (errorOut) {
            *errorOut = [SPKUtils errorWithDescription:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT")];
        }
        if (showToast && identifier.length > 0) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled",
                      SPKNotificationToneError);
        }
        return nil;
    }

    NSString *extension = fileURL.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"m4a"] ||
        [extension isEqualToString:@"aac"] ||
        [extension isEqualToString:@"mp3"]) {
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            [[UIPasteboard generalPasteboard] setData:data
                                    forPasteboardType:@"public.audio"];
            if (showToast && identifier.length > 0) {
                SPKNotify(identifier, SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_COPIED_AUDIO_CLIPBOARD_TEXT"), nil,
                          @"circle_check_filled", SPKNotificationToneSuccess);
            }
            return SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_COPIED_AUDIO_CLIPBOARD_TEXT");
        }
    } else if ([SPKDownloadDestinationWriter isVideoFileAtURL:fileURL]) {
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data) {
            [[UIPasteboard generalPasteboard] setData:data
                                    forPasteboardType:@"public.mpeg-4"];
            if (showToast && identifier.length > 0) {
                SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_VIDEO_CLIPBOARD_TEXT"), nil,
                          @"circle_check_filled", SPKNotificationToneSuccess);
            }
            return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_VIDEO_CLIPBOARD_TEXT");
        }
    } else {
        NSData *imageData = [NSData dataWithContentsOfURL:fileURL];
        UIImage *image = imageData ? [UIImage imageWithData:imageData] : nil;
        if (image) {
            [[UIPasteboard generalPasteboard] setImage:image];
            if (showToast && identifier.length > 0) {
                SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_PHOTO_CLIPBOARD_TEXT"), nil,
                          @"circle_check_filled", SPKNotificationToneSuccess);
            }
            return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_PHOTO_CLIPBOARD_TEXT");
        }
    }

    if (errorOut) {
        *errorOut =
            [SPKUtils errorWithDescription:SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_UNABLE_READ_SELECTED_FILE_TEXT")];
    }
    if (showToast && identifier.length > 0) {
        SPKNotify(identifier, SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_COPY_FAILED_TEXT"), SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_UNABLE_READ_SELECTED_FILE_TEXT"),
                  @"error_filled", SPKNotificationToneError);
    }
    return nil;
}

static NSString *SPKMediaSuggestedBasename(id mediaObject,
                                           SPKMediaOption *option) {
    NSString *identifier = nil;
    for (NSString *selectorName in @[ @"pk", @"mediaID", @"id" ]) {
        id value = SPKMediaObjectForSelector(mediaObject, selectorName)
                       ?: SPKMediaKVCObject(mediaObject, selectorName);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            identifier = value;
            break;
        }
        if ([value respondsToSelector:@selector(stringValue)]) {
            identifier = [value stringValue];
            if (identifier.length > 0)
                break;
        }
    }
    if (identifier.length == 0) {
        identifier = NSUUID.UUID.UUIDString;
    }
    NSString *suffix = option.kind == SPKMediaOptionKindPhotoProgressive
                           ? @"photo"
                       : option.kind == SPKMediaOptionKindAudioDash ? @"audio"
                                                                    : @"video";
    return [NSString stringWithFormat:@"sparkle_%@_%@", identifier, suffix];
}

static BOOL
SPKMediaShouldSkipDuplicateStart(SPKMediaOption *option,
                                 SPKDownloadDestination destination) {
    static NSString *lastKey = nil;
    static CFTimeInterval lastStartTime = 0.0;
    static dispatch_queue_t guardQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        guardQueue = dispatch_queue_create("com.sparkle.media.start-guard",
                                           DISPATCH_QUEUE_SERIAL);
    });

    __block BOOL shouldSkip = NO;
    NSString *key =
        [NSString stringWithFormat:@"%ld|%@|%@|%ld", (long)option.kind,
                                   option.primaryURL.absoluteString ?: @"",
                                   option.secondaryURL.absoluteString ?: @"",
                                   (long)destination];

    dispatch_sync(guardQueue, ^{
        CFTimeInterval now = CACurrentMediaTime();
        BOOL sameRequest = [lastKey isEqualToString:key];
        BOOL withinWindow = (now - lastStartTime) < 1.0;
        shouldSkip = sameRequest && withinWindow;
        if (!shouldSkip) {
            lastKey = [key copy];
            lastStartTime = now;
        }
    });
    return shouldSkip;
}

// DASH pair to merge if the CDN can't serve the ready-to-play file: the merged
// option closest in height, so the fallback matches what the user picked.
static SPKMediaOption *SPKMediaDashFallbackForProgressive(SPKMediaOption *option,
                                                          SPKMediaAnalysis *analysis) {
    if (option.kind != SPKMediaOptionKindVideoProgressive || !analysis.ffmpegAvailable)
        return nil;
    SPKMediaOption *best = nil;
    NSInteger bestDistance = NSIntegerMax;
    for (SPKMediaOption *candidate in analysis.mergedDashOptions) {
        if (!candidate.primaryURL || !candidate.selectable)
            continue;
        NSInteger distance = option.height > 0 ? labs(candidate.height - option.height) : 0;
        if (distance < bestDistance) {
            best = candidate;
            bestDistance = distance;
        }
    }
    return best;
}

static void SPKMediaPerformOptionDownload(
    SPKMediaOption *option, SPKMediaAnalysis *analysis, id mediaObject,
    SPKGallerySaveMetadata *galleryMetadata, SPKDownloadDestination destination,
    BOOL copyToClipboard, NSString *notificationIdentifier, BOOL showProgress,
    UIViewController *presenter, SPKDownloadSourceSurface sourceSurface) {
    if (copyToClipboard)
        destination = SPKDownloadDestinationClipboard;
    if (SPKMediaShouldSkipDuplicateStart(option, destination)) {
        return;
    }

    if (option.kind == SPKMediaOptionKindPhotoProgressive ||
        option.kind == SPKMediaOptionKindVideoProgressive) {
        SPKMediaOption *dashFallback = SPKMediaDashFallbackForProgressive(option, analysis);
        [SPKDownloadHelpers submitRemoteURL:option.primaryURL
                                  extension:SPKMediaExtensionForOption(option)
                                destination:destination
                                   metadata:galleryMetadata
                             notificationID:notificationIdentifier
                                  presenter:presenter
                                 anchorView:nil
                              sourceSurface:sourceSurface
                               showProgress:showProgress
                              configureItem:^(SPKDownloadItemRequest *item) {
                                  if (!dashFallback)
                                      return;
                                  item.dashFallbackURLString = dashFallback.primaryURL.absoluteString;
                                  item.dashSecondaryURLString = dashFallback.secondaryURL.absoluteString;
                                  item.dashOptionKind = dashFallback.kind;
                                  item.dashDuration = dashFallback.duration;
                                  item.dashWidth = dashFallback.width;
                                  item.dashHeight = dashFallback.height;
                                  item.dashBandwidth = dashFallback.bandwidth;
                              }];
        return;
    }

    [SPKDownloadHelpers
        submitDashDownloadWithPrimaryURL:option.primaryURL
                            secondaryURL:option.secondaryURL
                              optionKind:option.kind
                                basename:SPKMediaSuggestedBasename(mediaObject,
                                                                   option)
                                duration:option.duration
                                   width:option.width
                                  height:option.height
                           sourceBitrate:option.bandwidth
                               extension:SPKMediaExtensionForOption(option)
                                metadata:galleryMetadata
                             destination:destination
                          notificationID:notificationIdentifier
                               presenter:presenter
                           sourceSurface:sourceSurface
                            showProgress:showProgress];
}

@implementation SPKMediaQualityManager

+ (SPKTrimSourcePlan *)trimSourcePlanForMediaObject:(id)mediaObject
                                           photoURL:(NSURL *)photoURL
                                           videoURL:(NSURL *)videoURL
                                    qualityOverride:
                                        (NSString *)qualityOverride {
    // Trim never wants a standalone-audio option, so exclude those rows.
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(
        mediaObject, photoURL, videoURL, SPKDownloadDestinationGallery, NO);
    if (!analysis.isVideo) {
        return nil;
    }

    NSString *quality = qualityOverride.length > 0
                            ? qualityOverride
                            : [SPKUtils getStringPref:@"downloads_video_quality"];
    // Trim can't surface the full picker mid-flow, so treat an unset/"always_ask"
    // preference as best quality here (the caller prompts separately when set to
    // always_ask).
    if (quality.length == 0 || [quality isEqualToString:@"always_ask"]) {
        quality = @"high";
    }
    if (!analysis.ffmpegAvailable) {
        quality = @"high_ignore_dash";
    }

    SPKMediaOption *chosen;
    if ([quality isEqualToString:@"high_ignore_dash"]) {
        chosen = analysis.progressiveVideoOptions.firstObject ?: analysis.mergedDashOptions.firstObject ?
                                                                                                        : analysis.videoDashOnlyOptions.firstObject;
    } else if ([quality isEqualToString:@"high"]) {
        chosen = analysis.mergedDashOptions.firstObject ?: analysis.progressiveVideoOptions.firstObject ?
                                                                                                        : analysis.videoDashOnlyOptions.firstObject;
    } else {
        NSArray<SPKMediaOption *> *preferred =
            analysis.mergedDashOptions.count > 0 ? analysis.mergedDashOptions
                                                 : analysis.progressiveVideoOptions;
        chosen = SPKMediaTieredOption(preferred, quality)
                     ?: analysis.progressiveVideoOptions.firstObject
                        ?
                    : analysis.mergedDashOptions.firstObject
                        ?
                        : analysis.videoDashOnlyOptions.firstObject;
    }
    if (!chosen) {
        chosen = SPKMediaFFmpegFreeHighOption(analysis);
    }
    return SPKMediaTrimPlanFromOption(chosen, analysis, videoURL);
}

+ (void)presentTrimQualityPickerForMediaObject:(id)mediaObject
                                      photoURL:(NSURL *)photoURL
                                      videoURL:(NSURL *)videoURL
                                          from:(UIViewController *)presenter
                                    completion:
                                        (void (^)(SPKTrimSourcePlan *_Nullable))
                                            completion {
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(
        mediaObject, photoURL, videoURL, SPKDownloadDestinationGallery, NO);
    if (!analysis.isVideo || !presenter) {
        if (completion)
            completion(nil);
        return;
    }
    SPKMediaPresentOptionsSheet(
        presenter, nil, analysis, SPKDownloadDestinationGallery,
        ^(SPKMediaOption *option) {
            if (completion)
                completion(SPKMediaTrimPlanFromOption(option, analysis, videoURL));
        },
        ^{
            if (completion)
                completion(nil); // dismissed without choosing
        });
}

+ (void)runDashDownloadWithPrimaryURL:(NSURL *)primaryURL
                         secondaryURL:(NSURL *)secondaryURL
                           optionKind:(NSInteger)optionKind
                             basename:(NSString *)basename
                             duration:(double)duration
                                width:(NSInteger)width
                               height:(NSInteger)height
                        sourceBitrate:(NSInteger)bandwidth
                            extension:(NSString *)extension
                             progress:(void (^)(float, NSString *, int64_t,
                                                int64_t))progress
                              failure:(void (^)(NSString *, NSString *))failure
                              success:(void (^)(NSURL *))success
                            cancelOut:(void (^)(dispatch_block_t))cancelOut {
    (void)extension;
    NSURL *secondary = secondaryURL;
    __block SPKMediaSingleDownloadJob *videoJob = nil;
    __block SPKMediaSingleDownloadJob *audioJob = nil;
    __block dispatch_block_t ffmpegCancel = nil;

    if (cancelOut) {
        cancelOut(^{
            [videoJob cancel];
            [audioJob cancel];
            if (ffmpegCancel)
                ffmpegCancel();
        });
    }

    void (^report)(float, NSString *, int64_t, int64_t) =
        ^(float p, NSString *title, int64_t bw, int64_t total) {
            if (progress)
                progress(p, title, bw, total);
        };
    void (^fail)(NSString *, NSString *) =
        ^(NSString *title, NSString *subtitle) {
            if (failure)
                failure(title, subtitle);
        };
    void (^finishFile)(NSURL *) = ^(NSURL *fileURL) {
        if (success)
            success(fileURL);
    };

    void (^downloadAudioThenFinish)(NSURL *) = ^(NSURL *videoFileURL) {
        if (!secondary) {
            finishFile(videoFileURL);
            return;
        }
        audioJob = [[SPKMediaSingleDownloadJob alloc] init];
        report(0.46f, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT"), 0, 0);
        [audioJob startWithURL:secondary
            defaultExtension:@"m4a"
            progress:^(double jobProgress, int64_t bytesWritten,
                       int64_t totalBytesExpected) {
                report((float)(0.46 + (jobProgress * 0.22)), SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT"),
                       bytesWritten, totalBytesExpected);
            }
            completion:^(NSURL *audioFileURL, NSError *error) {
                if (error || !audioFileURL) {
                    fail(SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_AUDIO_DOWNLOAD_FAILED_TEXT"),
                         error.localizedDescription
                             ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_UNABLE_DOWNLOAD_DASH_AUDIO_TEXT"));
                    return;
                }
                report(0.72f, SPKL(@"DOWNLOAD_PROGRESS_MERGING"), 0, 0);
                [SPKMediaFFmpeg mergeVideoFileURL:videoFileURL
                    audioFileURL:audioFileURL
                    preferredBasename:basename
                    estimatedDuration:duration
                    width:width
                    height:height
                    sourceBitrate:bandwidth
                    progress:^(double mergeProgress, NSString *stage) {
                        NSString *title = [stage isEqualToString:@"re-encoding"]
                                              ? SPKL(@"MEDIA_DOWNLOAD_QUALITY_REENCODING_PROGRESS")
                                              : SPKL(@"DOWNLOAD_PROGRESS_MERGING");
                        report((float)(0.72 + (mergeProgress * 0.2)), title, 0, 0);
                    }
                    completion:^(NSURL *outputURL, NSError *error) {
                        if (error || !outputURL) {
                            fail(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_MERGE_FAILED_TEXT"),
                                 error.localizedDescription
                                     ?: SPKL(@"DOWNLOAD_ERROR_MERGE_FAILED"));
                            return;
                        }
                        finishFile(outputURL);
                    }
                    cancelOut:^(dispatch_block_t cancelBlock) {
                        ffmpegCancel = [cancelBlock copy];
                    }];
            }];
    };

    if (optionKind == SPKMediaOptionKindAudioDash) {
        audioJob = [[SPKMediaSingleDownloadJob alloc] init];
        report(0.1f, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT"), 0, 0);
        [audioJob startWithURL:primaryURL
            defaultExtension:@"m4a"
            progress:^(double jobProgress, int64_t bytesWritten,
                       int64_t totalBytesExpected) {
                report((float)(0.1 + (jobProgress * 0.65)), SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT"),
                       bytesWritten, totalBytesExpected);
            }
            completion:^(NSURL *audioFileURL, NSError *error) {
                if (error || !audioFileURL) {
                    fail(SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_AUDIO_DOWNLOAD_FAILED_TEXT"),
                         error.localizedDescription
                             ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_UNABLE_DOWNLOAD_DASH_AUDIO_TEXT"));
                    return;
                }
                report(0.8f, SPKL(@"MEDIA_DOWNLOAD_QUALITY_FINALIZING_FILE_PROGRESS"), 0, 0);
                [SPKMediaFFmpeg extractAudioFileURL:audioFileURL
                    preferredBasename:basename
                    progress:^(double extractProgress, NSString *stage) {
                        NSString *title = [stage isEqualToString:@"re-encoding"]
                                              ? SPKL(@"MEDIA_DOWNLOAD_QUALITY_REENCODING_PROGRESS")
                                              : SPKL(@"MEDIA_DOWNLOAD_QUALITY_FINALIZING_FILE_PROGRESS");
                        report((float)(0.8 + (extractProgress * 0.15)), title, 0, 0);
                    }
                    completion:^(NSURL *outputURL, NSError *error) {
                        if (error || !outputURL) {
                            finishFile(audioFileURL);
                            return;
                        }
                        finishFile(outputURL);
                    }
                    cancelOut:^(dispatch_block_t cancelBlock) {
                        ffmpegCancel = [cancelBlock copy];
                    }];
            }];
        return;
    }

    // Video-only DASH reps are frequently AV1/VP9, which older iOS (and Photos)
    // can't decode — saving the raw stream yields a black, unplayable file. When
    // FFmpeg is available, transcode the silent stream to H.264 (the same path
    // the merge flow uses, minus audio) so the result plays everywhere. Without
    // FFmpeg we save the raw stream as a best-effort fallback.
    BOOL transcodeVideoOnly = (optionKind == SPKMediaOptionKindVideoDashOnly &&
                               [SPKMediaFFmpeg isAvailable]);
    double videoDownloadSpan =
        secondary ? 0.28 : (transcodeVideoOnly ? 0.33 : 0.7);
    videoJob = [[SPKMediaSingleDownloadJob alloc] init];
    report(0.12f, SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_VIDEO_TEXT"), 0, 0);
    [videoJob startWithURL:primaryURL
        defaultExtension:@"mp4"
        progress:^(double jobProgress, int64_t bytesWritten,
                   int64_t totalBytesExpected) {
            report((float)(0.12 + (jobProgress * videoDownloadSpan)),
                   SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_VIDEO_TEXT"), bytesWritten, totalBytesExpected);
        }
        completion:^(NSURL *videoFileURL, NSError *error) {
            if (error || !videoFileURL) {
                fail(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_VIDEO_DOWNLOAD_FAILED_TEXT"),
                     error.localizedDescription ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_UNABLE_DOWNLOAD_VIDEO_TEXT"));
                return;
            }
            if (optionKind == SPKMediaOptionKindVideoDashOnly) {
                if (!transcodeVideoOnly) {
                    finishFile(videoFileURL);
                    return;
                }
                report(0.46f, SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT"), 0, 0);
                [SPKMediaFFmpeg mergeVideoFileURL:videoFileURL
                    audioFileURL:nil
                    preferredBasename:basename
                    estimatedDuration:duration
                    width:width
                    height:height
                    sourceBitrate:bandwidth
                    progress:^(double mergeProgress, NSString *stage) {
                        // Surface the true FFmpeg stage (Re-encoding / Normalizing /
                        // Finalizing) rather than a generic label.
                        report((float)(0.46 + (mergeProgress * 0.49)),
                               stage.length > 0 ? stage : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT"), 0, 0);
                    }
                    completion:^(NSURL *outputURL, NSError *mergeError) {
                        if (mergeError || !outputURL) {
                            fail(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_PROCESSING_FAILED_TEXT"), mergeError.localizedDescription
                                                           ?: SPKL(@"MEDIA_DOWNLOAD_QUALITY_UNABLE_PROCESS_VIDEO_ERROR"));
                            return;
                        }
                        finishFile(outputURL);
                    }
                    cancelOut:^(dispatch_block_t cancelBlock) {
                        ffmpegCancel = [cancelBlock copy];
                    }];
                return;
            }
            downloadAudioThenFinish(videoFileURL);
        }];
}

+ (BOOL)handleDownloadDestination:(SPKDownloadDestination)destination
                       identifier:(NSString *)identifier
                        presenter:(UIViewController *)presenter
                       sourceView:(UIView *)sourceView
                      mediaObject:(id)mediaObject
                         photoURL:(NSURL *)photoURL
                         videoURL:(NSURL *)videoURL
                  galleryMetadata:(SPKGallerySaveMetadata *)galleryMetadata
                     showProgress:(BOOL)showProgress
                    sourceSurface:(NSInteger)sourceSurface {
    return [self handleDownloadDestination:destination
                                identifier:identifier
                                 presenter:presenter
                                sourceView:sourceView
                               mediaObject:mediaObject
                                  photoURL:photoURL
                                  videoURL:videoURL
                           galleryMetadata:galleryMetadata
                              showProgress:showProgress
                             sourceSurface:sourceSurface
                           qualityOverride:nil];
}

+ (BOOL)handleDownloadDestination:(SPKDownloadDestination)destination
                       identifier:(NSString *)identifier
                        presenter:(UIViewController *)presenter
                       sourceView:(UIView *)sourceView
                      mediaObject:(id)mediaObject
                         photoURL:(NSURL *)photoURL
                         videoURL:(NSURL *)videoURL
                  galleryMetadata:(SPKGallerySaveMetadata *)galleryMetadata
                     showProgress:(BOOL)showProgress
                    sourceSurface:(NSInteger)sourceSurface
                  qualityOverride:(NSString *)qualityOverride {
    BOOL includeAudioOptions = (destination == SPKDownloadDestinationShare ||
                                destination == SPKDownloadDestinationGallery ||
                                destination == SPKDownloadDestinationCacheOnly ||
                                destination == SPKDownloadDestinationClipboard);
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(
        mediaObject, photoURL, videoURL, destination, includeAudioOptions);
    if (analysis.photoOptions.count == 0 &&
        analysis.progressiveVideoOptions.count == 0 &&
        analysis.mergedDashOptions.count == 0 &&
        analysis.videoDashOnlyOptions.count == 0 &&
        analysis.audioDashOptions.count == 0) {
        return NO;
    }

    SPKMediaOption *resolvedOption = SPKMediaResolveDefaultOption(analysis, qualityOverride);

    // Forced-quality callers (auto-save) run with no user present: resolve or bail,
    // and never fall through to the picker sheet. They also need no presenter --
    // it only exists to host that sheet.
    if (qualityOverride.length > 0) {
        if (!resolvedOption)
            return NO;
        SPKMediaPerformOptionDownload(resolvedOption, analysis, mediaObject, galleryMetadata,
                                      destination, NO, identifier, showProgress,
                                      presenter,
                                      (SPKDownloadSourceSurface)sourceSurface);
        return YES;
    }

    UIViewController *resolvedPresenter = presenter ?: topMostController();
    if (!resolvedPresenter) {
        return NO;
    }

    if (resolvedOption) {
        SPKMediaPerformOptionDownload(resolvedOption, analysis, mediaObject, galleryMetadata,
                                      destination, NO, identifier, showProgress,
                                      resolvedPresenter,
                                      (SPKDownloadSourceSurface)sourceSurface);
        return YES;
    }

    SPKMediaPresentOptionsSheet(
        resolvedPresenter, sourceView, analysis, destination,
        ^(SPKMediaOption *option) {
            SPKMediaPerformOptionDownload(option, analysis, mediaObject, galleryMetadata,
                                          destination, NO, identifier, showProgress,
                                          resolvedPresenter,
                                          (SPKDownloadSourceSurface)sourceSurface);
        },
        nil);
    return YES;
}

+ (BOOL)handleCopyActionWithIdentifier:(NSString *)identifier
                             presenter:(UIViewController *)presenter
                            sourceView:(UIView *)sourceView
                           mediaObject:(id)mediaObject
                              photoURL:(NSURL *)photoURL
                              videoURL:(NSURL *)videoURL
                       galleryMetadata:(SPKGallerySaveMetadata *)galleryMetadata
                          showProgress:(BOOL)showProgress
                         sourceSurface:(NSInteger)sourceSurface {
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(
        mediaObject, photoURL, videoURL, SPKDownloadDestinationClipboard, YES);
    if (analysis.photoOptions.count == 0 &&
        analysis.progressiveVideoOptions.count == 0 &&
        analysis.mergedDashOptions.count == 0 &&
        analysis.videoDashOnlyOptions.count == 0 &&
        analysis.audioDashOptions.count == 0) {
        return NO;
    }

    UIViewController *resolvedPresenter = presenter ?: topMostController();
    if (!resolvedPresenter) {
        return NO;
    }

    SPKMediaOption *resolvedOption = SPKMediaResolveDefaultOption(analysis, nil);
    if (resolvedOption) {
        SPKMediaPerformOptionDownload(resolvedOption, analysis, mediaObject, galleryMetadata,
                                      SPKDownloadDestinationClipboard, YES,
                                      identifier, showProgress, resolvedPresenter,
                                      (SPKDownloadSourceSurface)sourceSurface);
        return YES;
    }

    SPKMediaPresentOptionsSheet(
        resolvedPresenter, sourceView, analysis, SPKDownloadDestinationClipboard,
        ^(SPKMediaOption *option) {
            SPKMediaPerformOptionDownload(
                option, analysis, mediaObject, galleryMetadata,
                SPKDownloadDestinationClipboard, YES, identifier, showProgress,
                resolvedPresenter, (SPKDownloadSourceSurface)sourceSurface);
        },
        nil);
    return YES;
}

+ (BOOL)mediaObjectIsVideo:(id)mediaObject {
    if (!mediaObject) {
        return NO;
    }
    // A non-zero video duration is the most reliable signal across surfaces
    // (IGMedia exposes a non-nil `video` even for photos, so that alone over-
    // matches). Fall back to resolving an actual video URL.
    if (SPKMediaDurationForObject(mediaObject) > 0.0) {
        return YES;
    }
    return [SPKUtils getVideoUrlForMedia:mediaObject] != nil;
}

+ (NSURL *)resolvedURLForMediaObject:(id)mediaObject
                            photoURL:(NSURL *)photoURL
                            videoURL:(NSURL *)videoURL
                     qualityOverride:(NSString *)qualityOverride
                         destination:(SPKDownloadDestination)destination {
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(mediaObject, photoURL, videoURL, destination, NO);
    SPKMediaOption *option = SPKMediaResolveDefaultOption(analysis, qualityOverride);
    return option.primaryURL ?: photoURL ?: videoURL;
}

static NSURL *SPKMediaDownloadLinkURL(SPKMediaAnalysis *analysis, NSString *photoQualityOverride,
                                      NSURL *photoURL, NSURL *videoURL) {
    SPKMediaOption *option = nil;
    if (analysis.isVideo) {
        NSString *quality = [SPKUtils getStringPref:@"downloads_video_quality"];
        NSArray<SPKMediaOption *> *progressive = analysis.progressiveVideoOptions;
        option = SPKMediaTieredOption(progressive, quality) ?: progressive.firstObject;
    } else {
        NSString *quality = photoQualityOverride.length > 0 ? photoQualityOverride : [SPKUtils getStringPref:@"downloads_photo_quality"];
        option = SPKMediaResolveDefaultOption(analysis, [quality isEqualToString:@"always_ask"] ? @"max" : quality);
    }
    return option.primaryURL ?: videoURL ?: photoURL;
}

+ (NSURL *)downloadLinkURLForMediaObject:(id)mediaObject
                                photoURL:(NSURL *)photoURL
                                videoURL:(NSURL *)videoURL
                    photoQualityOverride:(NSString *)photoQualityOverride {
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(mediaObject, photoURL, videoURL, SPKDownloadDestinationClipboard, NO);
    return SPKMediaDownloadLinkURL(analysis, photoQualityOverride, photoURL, videoURL);
}

+ (void)resolveDownloadLinkForMediaObject:(id)mediaObject
                                 photoURL:(NSURL *)photoURL
                                 videoURL:(NSURL *)videoURL
                                presenter:(UIViewController *)presenter
                               sourceView:(UIView *)sourceView
                               completion:(void (^)(NSURL *url))completion {
    if (!completion)
        return;
    SPKMediaAnalysis *analysis = SPKMediaAnalyze(mediaObject, photoURL, videoURL, SPKDownloadDestinationClipboard, NO);
    NSString *quality = [SPKUtils getStringPref:analysis.isVideo ? @"downloads_video_quality" : @"downloads_photo_quality"];
    NSArray<SPKMediaOption *> *choices = analysis.isVideo ? analysis.progressiveVideoOptions : analysis.photoOptions;
    UIViewController *resolvedPresenter = presenter ?: topMostController();
    if (![quality isEqualToString:@"always_ask"] || !resolvedPresenter || choices.count < 2) {
        completion(SPKMediaDownloadLinkURL(analysis, nil, photoURL, videoURL));
        return;
    }

    // A link can only point at one file, so the video sheet drops the DASH sections.
    if (analysis.isVideo) {
        analysis.videoSections = @[ SPKMediaSection(SPKL(@"MEDIA_DOWNLOAD_MEDIA_QUALITY_MANAGER_READY_PLAY_TEXT"), choices) ];
    }
    SPKMediaPresentOptionsSheet(resolvedPresenter, sourceView, analysis, SPKDownloadDestinationClipboard,
                                ^(SPKMediaOption *option) {
                                    completion(option.primaryURL ?: videoURL ?: photoURL);
                                },
                                nil);
}

+ (UIViewController *)encodingSettingsViewController {
    return [[SPKMediaEncodingSettingsViewController alloc] init];
}

+ (NSArray *)encodingSettingsSearchSections {
    SPKMediaEncodingSettingsViewController *controller =
        [[SPKMediaEncodingSettingsViewController alloc] init];
    return [controller searchSections] ?: @[];
}

+ (BOOL)hasWebPhotoCandidatesFetchedForPK:(NSString *)pk {
    SPKInitializeWebPhotoCandidatesCacheIfNeeded();
    NSString *norm = SPKNormalizePK(pk);
    return norm.length > 0 && [SPKWebPhotoCandidatesFetchedPKs containsObject:norm];
}

+ (void)markWebPhotoCandidatesFetchedForPK:(NSString *)pk {
    SPKInitializeWebPhotoCandidatesCacheIfNeeded();
    NSString *norm = SPKNormalizePK(pk);
    if (norm.length > 0) {
        [SPKWebPhotoCandidatesFetchedPKs addObject:norm];
    }
}

+ (nullable NSArray<NSDictionary *> *)webPhotoCandidatesForPK:(NSString *)pk {
    SPKInitializeWebPhotoCandidatesCacheIfNeeded();
    NSString *norm = SPKNormalizePK(pk);
    return norm.length > 0 ? SPKWebPhotoCandidatesCache[norm] : nil;
}

+ (void)cacheWebCandidatesFromResponse:(NSDictionary *)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSArray *items = response[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        return;
    }
    NSDictionary *item = items[0];
    if (![item isKindOfClass:[NSDictionary class]]) {
        return;
    }

    SPKInitializeWebPhotoCandidatesCacheIfNeeded();

    NSString *topPK = nil;
    id rawTopPK = item[@"pk"] ?: item[@"id"] ?: item[@"media_id"];
    if ([rawTopPK isKindOfClass:[NSString class]]) {
        topPK = rawTopPK;
    } else if ([rawTopPK respondsToSelector:@selector(stringValue)]) {
        topPK = [rawTopPK stringValue];
    }

    NSArray *carouselMedia = item[@"carousel_media"];
    if ([carouselMedia isKindOfClass:[NSArray class]] && carouselMedia.count > 0) {
        for (NSDictionary *subItem in carouselMedia) {
            if (![subItem isKindOfClass:[NSDictionary class]])
                continue;
            NSString *subPK = nil;
            id rawSubPK = subItem[@"pk"] ?: subItem[@"id"];
            if ([rawSubPK isKindOfClass:[NSString class]]) {
                subPK = rawSubPK;
            } else if ([rawSubPK respondsToSelector:@selector(stringValue)]) {
                subPK = [rawSubPK stringValue];
            }
            id imageVersions = subItem[@"image_versions2"];
            id candidates = [imageVersions isKindOfClass:[NSDictionary class]] ? imageVersions[@"candidates"] : nil;
            if ([candidates isKindOfClass:[NSArray class]] && subPK.length > 0) {
                NSString *normSub = SPKNormalizePK(subPK);
                if (normSub.length > 0) {
                    SPKWebPhotoCandidatesCache[normSub] = candidates;
                }
            }
        }
    } else {
        id imageVersions = item[@"image_versions2"];
        id candidates = [imageVersions isKindOfClass:[NSDictionary class]] ? imageVersions[@"candidates"] : nil;
        if ([candidates isKindOfClass:[NSArray class]] && topPK.length > 0) {
            NSString *normTop = SPKNormalizePK(topPK);
            if (normTop.length > 0) {
                SPKWebPhotoCandidatesCache[normTop] = candidates;
            }
        }
    }
}

@end
