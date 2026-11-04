#import "SPKStrings.h"
#import "SPKAudioDownloadCoordinator.h"

#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../Downloads/SPKDownloadHelpers.h"
#import "../Downloads/SPKDownloadRequest.h"
#import "../Downloads/SPKDownloadService.h"
#import "../Downloads/SPKDownloadTypes.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../MediaDownload/SPKDashParser.h"
#import "../MediaDownload/SPKMediaFFmpeg.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../MediaPreview/SPKMediaItem.h"
#import "../UI/SPKNotificationCenter.h"

static id SPKAudioObjectForSelector(id target, NSString *selectorName) {
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

static id SPKAudioKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKAudioFieldCacheValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;
    Ivar fieldCacheIvar = NULL;
    for (Class cls = [object class]; cls && !fieldCacheIvar;
         cls = class_getSuperclass(cls)) {
        fieldCacheIvar = class_getInstanceVariable(cls, "_fieldCache");
    }
    if (!fieldCacheIvar)
        return nil;
    id fieldCache = nil;
    @try {
        fieldCache = object_getIvar(object, fieldCacheIvar);
    } @catch (__unused NSException *exception) {
        fieldCache = nil;
    }
    if (![fieldCache isKindOfClass:NSDictionary.class])
        return nil;
    return ((NSDictionary *)fieldCache)[key];
}

static id SPKAudioIvarValue(id target, const char *name) {
    if (!target || !name)
        return nil;
    @try {
        for (Class cls = [target class]; cls && cls != NSObject.class;
             cls = class_getSuperclass(cls)) {
            Ivar ivar = class_getInstanceVariable(cls, name);
            if (!ivar)
                continue;
            const char *encoding = ivar_getTypeEncoding(ivar);
            if (encoding && encoding[0] == '@') {
                return object_getIvar(target, ivar);
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSString *SPKAudioStringValue(id value) {
    if ([value isKindOfClass:NSString.class])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *string = [value stringValue];
        return string.length > 0 ? string : nil;
    }
    return nil;
}

static NSURL *SPKAudioURLFromValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        NSURL *url = value;
        if (url.scheme.length > 0 || url.isFileURL)
            return url;
        return nil;
    }
    NSString *string = SPKAudioStringValue(value);
    if (string.length == 0)
        return nil;

    NSString *trimmed = [string
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return nil;
    if ([trimmed hasPrefix:@"//"]) {
        trimmed = [@"https:" stringByAppendingString:trimmed];
    }

    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url && ![trimmed containsString:@"://"]) {
        url = [NSURL fileURLWithPath:trimmed];
    }
    if (!url.scheme.length && !url.isFileURL)
        return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme.length > 0 &&
        ![@[ @"http", @"https", @"file" ] containsObject:scheme])
        return nil;
    return url;
}

static NSURL *SPKAudioURLFromCollectionValue(id collection) {
    if (!collection)
        return nil;
    if ([collection isKindOfClass:NSURL.class] ||
        [collection isKindOfClass:NSString.class]) {
        return SPKAudioURLFromValue(collection);
    }

    NSArray *items = nil;
    if ([collection isKindOfClass:NSArray.class]) {
        items = collection;
    } else if ([collection isKindOfClass:NSSet.class]) {
        items = [(NSSet *)collection allObjects];
    } else if ([collection isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = collection;
        NSURL *direct = SPKAudioURLFromValue(dict[@"url"] ?: dict[@"src"] ?
                                                                          : dict[@"uri"]);
        if (direct)
            return direct;
        id candidates = dict[@"candidates"] ?: dict[@"items"] ?
                                                              : dict[@"urls"];
        if ([candidates isKindOfClass:NSArray.class] ||
            [candidates isKindOfClass:NSSet.class]) {
            return SPKAudioURLFromCollectionValue(candidates);
        }
        return nil;
    }

    for (id item in items ?: @[]) {
        NSURL *url = nil;
        if ([item isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = item;
            url = SPKAudioURLFromValue(dict[@"url"] ?: dict[@"src"] ?
                                                                    : dict[@"uri"]);
        } else {
            url = SPKAudioURLFromValue(SPKAudioObjectForSelector(item, @"url")
                                           ?: SPKAudioKVCObject(item, @"url"));
            if (!url)
                url =
                    SPKAudioURLFromValue(SPKAudioObjectForSelector(item, @"urlString")
                                             ?: SPKAudioKVCObject(item, @"urlString"));
            if (!url)
                url = SPKAudioURLFromValue(item);
        }
        if (url)
            return url;
    }
    return nil;
}

static NSURL *SPKAudioURLForNames(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSURL *url = SPKAudioURLFromValue(SPKAudioObjectForSelector(object, name));
        if (!url)
            url = SPKAudioURLFromValue(SPKAudioKVCObject(object, name));
        if (url)
            return url;
    }
    return nil;
}

static NSURL *SPKAudioCollectionURLForNames(id object,
                                            NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSURL *url =
            SPKAudioURLFromCollectionValue(SPKAudioObjectForSelector(object, name));
        if (!url)
            url = SPKAudioURLFromCollectionValue(SPKAudioKVCObject(object, name));
        if (url)
            return url;
    }
    return nil;
}

static NSString *SPKAudioManifestString(id value) {
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 10)
        return value;
    if ([value isKindOfClass:NSData.class] && [(NSData *)value length] > 10) {
        NSString *string = [[NSString alloc] initWithData:value
                                                 encoding:NSUTF8StringEncoding];
        return string.length > 10 ? string : nil;
    }
    return nil;
}

static NSURL *SPKAudioURLFromDashManifest(NSString *manifest) {
    NSArray<SPKDashRepresentation *> *representations =
        [SPKDashParser parseManifest:manifest ?: @""];
    SPKDashRepresentation *best = nil;
    for (SPKDashRepresentation *rep in representations) {
        if (![rep.contentType.lowercaseString containsString:@"audio"] || !rep.url)
            continue;
        if (!best || rep.bandwidth > best.bandwidth)
            best = rep;
    }
    return best.url;
}

static NSURL *SPKAudioDashAudioURLFromObject(id object) {
    for (NSString *name in @[
             @"dashManifestData", @"videoDashManifest", @"dashManifest",
             @"audioDashManifest"
         ]) {
        NSString *manifest =
            SPKAudioManifestString(SPKAudioObjectForSelector(object, name));
        if (!manifest)
            manifest = SPKAudioManifestString(SPKAudioKVCObject(object, name));
        NSURL *url = SPKAudioURLFromDashManifest(manifest);
        if (url)
            return url;
    }

    for (NSString *key in
         @[ @"dash_manifest", @"video_dash_manifest", @"audio_dash_manifest" ]) {
        NSURL *url = SPKAudioURLFromDashManifest(
            SPKAudioManifestString(SPKAudioFieldCacheValue(object, key)));
        if (url)
            return url;
    }

    id ivarValue = SPKAudioIvarValue(object, "_dashManifestData");
    return SPKAudioURLFromDashManifest(SPKAudioManifestString(ivarValue));
}

static BOOL SPKAudioObjectLooksAudioLike(id object) {
    if (!object)
        return NO;
    NSString *className = NSStringFromClass([object class]);
    return [className containsString:@"Audio"] ||
           [className containsString:@"Music"] ||
           [className containsString:@"Sound"] ||
           [className containsString:@"Track"];
}

static BOOL SPKAudioKeyLooksAudioLike(NSString *key) {
    NSString *lower = key.lowercaseString;
    return [lower containsString:@"audio"] || [lower containsString:@"music"] ||
           [lower containsString:@"sound"] || [lower containsString:@"track"] ||
           [lower containsString:@"dash"] || [lower containsString:@"manifest"];
}

static BOOL SPKAudioKeyLooksGenericURLLike(NSString *key) {
    NSString *lower = key.lowercaseString;
    return [lower containsString:@"url"] || [lower containsString:@"uri"] ||
           [lower containsString:@"download"] ||
           [lower containsString:@"progressive"];
}

static BOOL SPKAudioDictionaryLooksAudioLike(NSDictionary *dict) {
    for (id key in dict.allKeys) {
        if ([key isKindOfClass:NSString.class] &&
            SPKAudioKeyLooksAudioLike((NSString *)key)) {
            return YES;
        }
    }
    return NO;
}

static BOOL SPKAudioBoolValue(id value) {
    if (!value)
        return NO;
    if ([value respondsToSelector:@selector(boolValue)])
        return [value boolValue];
    return NO;
}

static NSURL *SPKAudioBestVideoURLFromVersions(id versions) {
    NSArray *items = nil;
    if ([versions isKindOfClass:NSArray.class]) {
        items = versions;
    } else if ([versions isKindOfClass:NSDictionary.class]) {
        id candidates = ((NSDictionary *)versions)[@"candidates"]
                            ?: ((NSDictionary *)versions)[@"items"];
        if ([candidates isKindOfClass:NSArray.class])
            items = candidates;
    }

    NSURL *bestURL = nil;
    NSInteger bestArea = -1;
    for (id item in items ?: @[]) {
        id urlValue = nil;
        NSInteger width = 0;
        NSInteger height = 0;
        if ([item isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = item;
            urlValue = dict[@"url"] ?: dict[@"src"];
            width = [dict[@"width"] integerValue];
            height = [dict[@"height"] integerValue];
        } else {
            urlValue = SPKAudioObjectForSelector(item, @"url")
                           ?: SPKAudioKVCObject(item, @"url");
            id widthValue = SPKAudioObjectForSelector(item, @"width")
                                ?: SPKAudioKVCObject(item, @"width");
            id heightValue = SPKAudioObjectForSelector(item, @"height")
                                 ?: SPKAudioKVCObject(item, @"height");
            width = [widthValue integerValue];
            height = [heightValue integerValue];
        }
        NSURL *url = SPKAudioURLFromValue(urlValue);
        if (!url)
            continue;
        NSInteger area = width * height;
        if (!bestURL || area > bestArea) {
            bestURL = url;
            bestArea = area;
        }
    }
    return bestURL;
}

static BOOL SPKAudioMediaHasAudio(id object, NSMutableSet<NSValue *> *visited,
                                  NSUInteger depth) {
    if (!object || depth > 4)
        return NO;
    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return NO;
    [visited addObject:identity];

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = object;
        for (NSString *key in @[
                 @"has_audio", @"hasAudio", @"audio_enabled", @"contains_audio",
                 @"audio_detected", @"is_audio_detected", @"audio_available",
                 @"is_audio_available", @"has_original_audio"
             ]) {
            if (SPKAudioBoolValue(dict[key]))
                return YES;
        }
        for (id value in dict.allValues) {
            if (SPKAudioMediaHasAudio(value, visited, depth + 1))
                return YES;
        }
        return NO;
    }
    if ([object isKindOfClass:NSArray.class] ||
        [object isKindOfClass:NSSet.class]) {
        for (id value in object) {
            if (SPKAudioMediaHasAudio(value, visited, depth + 1))
                return YES;
        }
        return NO;
    }

    for (NSString *name in @[
             @"hasAudio", @"audioEnabled", @"containsAudio", @"isAudioDetected",
             @"audioDetected", @"isAudioAvailable", @"audioAvailable",
             @"hasOriginalAudio"
         ]) {
        id value = SPKAudioObjectForSelector(object, name)
                       ?: SPKAudioKVCObject(object, name);
        if (SPKAudioBoolValue(value))
            return YES;
    }

    for (NSString *key in @[
             @"has_audio", @"audio_enabled", @"contains_audio", @"audio_detected",
             @"is_audio_detected", @"audio_available", @"is_audio_available",
             @"has_original_audio"
         ]) {
        if (SPKAudioBoolValue(SPKAudioFieldCacheValue(object, key)))
            return YES;
    }

    for (NSString *name in @[
             @"media", @"item", @"video", @"rawVideo", @"clipsMedia", @"clipsItem",
             @"post", @"clipsMetadata", @"musicInfo", @"musicMetadata",
             @"originalAudio", @"originalAudioInfo", @"originalSoundInfo",
             @"audioTrack"
         ]) {
        id nested = SPKAudioObjectForSelector(object, name)
                        ?: SPKAudioKVCObject(object, name);
        if (nested && nested != object &&
            SPKAudioMediaHasAudio(nested, visited, depth + 1))
            return YES;
    }
    for (NSString *key in @[
             @"clips_metadata", @"music_info", @"music_metadata", @"original_audio",
             @"original_audio_info", @"original_sound_info", @"audio",
             @"audio_track", @"video"
         ]) {
        id nested = SPKAudioFieldCacheValue(object, key);
        if (nested && nested != object &&
            SPKAudioMediaHasAudio(nested, visited, depth + 1))
            return YES;
    }
    return NO;
}

static NSURL *SPKAudioVideoURLFromObject(id object,
                                         NSMutableSet<NSValue *> *visited,
                                         NSUInteger depth) {
    if (!object || depth > 4)
        return nil;
    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return nil;
    [visited addObject:identity];

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = object;
        NSURL *direct = SPKAudioURLFromValue(dict[@"video_url"] ?: dict[@"videoURL"] ?
                                                                                     : dict[@"url"]);
        if (direct)
            return direct;
        NSURL *versionURL = SPKAudioBestVideoURLFromVersions(
            dict[@"video_versions"] ?: dict[@"videoVersions"]);
        if (versionURL)
            return versionURL;
        for (id value in dict.allValues) {
            NSURL *url = SPKAudioVideoURLFromObject(value, visited, depth + 1);
            if (url)
                return url;
        }
        return nil;
    }
    if ([object isKindOfClass:NSArray.class] ||
        [object isKindOfClass:NSSet.class]) {
        for (id value in object) {
            NSURL *url = SPKAudioVideoURLFromObject(value, visited, depth + 1);
            if (url)
                return url;
        }
        return nil;
    }

    NSURL *mediaVideoURL = [SPKUtils getVideoUrlForMedia:object];
    if (mediaVideoURL)
        return mediaVideoURL;

    NSURL *direct = SPKAudioURLForNames(object, @[
        @"videoURL", @"videoUrl", @"playableURL", @"playableUrl",
        @"progressiveDownloadURL"
    ]);
    if (direct)
        return direct;

    NSURL *fieldCacheURL = SPKAudioBestVideoURLFromVersions(
        SPKAudioFieldCacheValue(object, @"video_versions"));
    if (fieldCacheURL)
        return fieldCacheURL;

    for (NSString *name in @[
             @"media", @"item", @"video", @"rawVideo", @"clipsMedia", @"clipsItem",
             @"post", @"clipsMetadata"
         ]) {
        id nested = SPKAudioObjectForSelector(object, name)
                        ?: SPKAudioKVCObject(object, name);
        if (nested && nested != object) {
            NSURL *url = SPKAudioVideoURLFromObject(nested, visited, depth + 1);
            if (url)
                return url;
        }
    }
    for (NSString *key in @[ @"video", @"video_versions", @"clips_metadata" ]) {
        id nested = SPKAudioFieldCacheValue(object, key);
        if (nested && nested != object) {
            NSURL *url = SPKAudioVideoURLFromObject(nested, visited, depth + 1);
            if (url)
                return url;
        }
    }
    return nil;
}

static NSURL *SPKAudioFallbackVideoURLFromMediaObject(id mediaObject) {
    if (!SPKAudioMediaHasAudio(mediaObject, [NSMutableSet set], 0))
        return nil;
    return SPKAudioVideoURLFromObject(mediaObject, [NSMutableSet set], 0);
}

static BOOL SPKAudioShouldTraverseObject(id object) {
    if (!object)
        return NO;
    if ([object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSURL.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:UIImage.class] ||
        [object isKindOfClass:UIView.class] ||
        [object isKindOfClass:UIViewController.class]) {
        return NO;
    }
    NSString *name = NSStringFromClass([object class]);
    return [name containsString:@"Direct"] || [name containsString:@"Audio"] ||
           [name containsString:@"Message"] || [name containsString:@"Media"] ||
           [name containsString:@"GraphQL"] || [name containsString:@"GQL"] ||
           [name containsString:@"Model"];
}

static NSURL *SPKAudioBestURLFromObject(id mediaObject,
                                        NSMutableSet<NSValue *> *visited,
                                        NSUInteger depth) {
    if (!mediaObject || depth > 5)
        return nil;
    if ([mediaObject isKindOfClass:NSURL.class] ||
        [mediaObject isKindOfClass:NSString.class]) {
        return depth == 0 ? SPKAudioURLFromValue(mediaObject) : nil;
    }

    NSValue *identity = [NSValue valueWithNonretainedObject:mediaObject];
    if ([visited containsObject:identity])
        return nil;
    [visited addObject:identity];

    NSURL *direct = SPKAudioURLForNames(mediaObject, @[
        @"audioFileUrl", @"audioFileURL", @"playableAudioURL", @"audioURL",
        @"audioUrl", @"progressiveDownloadURL", @"progressiveDownloadUrl",
        @"progressiveAudioURL", @"progressiveAudioUrl", @"_progressiveAudioUrl",
        @"audioSrc"
    ]);
    if (direct)
        return direct;

    NSURL *collectionURL = SPKAudioCollectionURLForNames(mediaObject, @[
        @"_audioUrls", @"audioUrls", @"audioURLs", @"allAudioURLs",
        @"_allDashAudioURLs", @"allDashAudioURLs", @"sortedAudioURLsBySize"
    ]);
    if (collectionURL)
        return collectionURL;

    NSURL *dashAudioURL = SPKAudioDashAudioURLFromObject(mediaObject);
    if (dashAudioURL)
        return dashAudioURL;

    if (SPKAudioObjectLooksAudioLike(mediaObject)) {
        NSURL *genericAudioURL = SPKAudioURLForNames(
            mediaObject,
            @[ @"mediaUrl", @"mediaURL", @"downloadUrl", @"downloadURL", @"url" ]);
        if (genericAudioURL)
            return genericAudioURL;
    }

    if ([mediaObject isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)mediaObject;
        NSURL *direct = SPKAudioURLFromValue(dict[@"audioFileUrl"] ?: dict[@"audioFileURL"]         ?
                                                                  : dict[@"playableAudioURL"]       ?
                                                                  : dict[@"audioURL"]               ?
                                                                  : dict[@"audioUrl"]               ?
                                                                  : dict[@"progressiveAudioURL"]    ?
                                                                  : dict[@"progressiveAudioUrl"]    ?
                                                                  : dict[@"progressiveDownloadURL"] ?
                                                                                                    : dict[@"progressiveDownloadUrl"]);
        if (direct)
            return direct;
        if (!SPKAudioDictionaryLooksAudioLike(dict))
            return nil;
        for (id value in dict.allValues) {
            NSURL *url = SPKAudioBestURLFromObject(value, visited, depth + 1);
            if (url)
                return url;
        }
    } else if ([mediaObject isKindOfClass:NSArray.class] ||
               [mediaObject isKindOfClass:NSSet.class]) {
        for (id value in mediaObject) {
            NSURL *url = SPKAudioBestURLFromObject(value, visited, depth + 1);
            if (url)
                return url;
        }
    }

    for (NSString *name in @[
             @"audio",
             @"audioAsset",
             @"music",
             @"originalAudio",
             @"originalAudioInfo",
             @"clipsAudio",
             @"sound",
             @"musicInfo",
             @"musicMetadata",
             @"originalSoundInfo",
             @"audioTrack",
             @"sundialMusicAsset",
             @"sundialOriginalAudioAsset",
             @"videoURLProvider",
             @"asMusicInfoFragment",
             @"musicAssetInfo",
             @"musicConsumptionInfo",
             @"media",
             @"item",
             @"viewModel",
             @"message",
             @"messageCellViewModel",
             @"audioMessageViewModel",
             @"messageMetadata"
         ]) {
        id nested = SPKAudioObjectForSelector(mediaObject, name)
                        ?: SPKAudioKVCObject(mediaObject, name);
        if (nested && nested != mediaObject) {
            NSURL *url = SPKAudioKeyLooksAudioLike(name)
                             ? (SPKAudioURLFromValue(nested)
                                    ?: SPKAudioURLFromCollectionValue(nested))
                             : nil;
            if (!url)
                url = SPKAudioBestURLFromObject(nested, visited, depth + 1);
            if (url)
                return url;
        }
    }

    for (NSString *key in @[
             @"audio", @"audio_asset", @"music", @"music_info", @"music_metadata",
             @"music_asset_info", @"audio_asset_info", @"clips_audio",
             @"clips_metadata", @"original_audio", @"original_audio_info",
             @"original_sound_info", @"audio_track"
         ]) {
        id nested = SPKAudioFieldCacheValue(mediaObject, key);
        if (nested && nested != mediaObject) {
            NSURL *url = SPKAudioURLFromValue(nested)
                             ?: SPKAudioBestURLFromObject(nested, visited, depth + 1);
            if (url)
                return url;
        }
    }

    if (SPKAudioShouldTraverseObject(mediaObject)) {
        for (Class cls = [mediaObject class]; cls && cls != NSObject.class;
             cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                Ivar ivar = ivars[i];
                const char *encoding = ivar_getTypeEncoding(ivar);
                if (!encoding || encoding[0] != '@')
                    continue;
                id value = nil;
                @try {
                    value = object_getIvar(mediaObject, ivar);
                } @catch (__unused NSException *exception) {
                    value = nil;
                }

                NSString *ivarName =
                    [NSString stringWithUTF8String:ivar_getName(ivar) ?: ""];
                BOOL ivarIsAudioURL = SPKAudioKeyLooksAudioLike(ivarName) ||
                                      (SPKAudioObjectLooksAudioLike(mediaObject) &&
                                       SPKAudioKeyLooksGenericURLLike(ivarName));
                NSURL *url = ivarIsAudioURL
                                 ? (SPKAudioURLFromValue(value)
                                        ?: SPKAudioURLFromCollectionValue(value))
                                 : nil;
                if (!url)
                    url = SPKAudioBestURLFromObject(value, visited, depth + 1);
                if (url) {
                    free(ivars);
                    return url;
                }
            }
            free(ivars);
        }
    }

    return nil;
}

static NSTimeInterval SPKAudioDurationForObject(id object) {
    for (NSString *name in @[
             @"duration", @"durationSeconds", @"audioDuration",
             @"audioDurationSeconds", @"videoDuration"
         ]) {
        id value = SPKAudioObjectForSelector(object, name)
                       ?: SPKAudioKVCObject(object, name);
        if ([value respondsToSelector:@selector(doubleValue)] &&
            [value doubleValue] > 0.0) {
            return [value doubleValue];
        }
    }
    return 0.0;
}

static SPKGallerySaveMetadata *
SPKAudioMetadataFromItem(SPKAudioItem *item, SPKGallerySaveMetadata *metadata) {
    SPKGallerySaveMetadata *resolved =
        metadata ?: [[SPKGallerySaveMetadata alloc] init];
    resolved.source = (int16_t)[item gallerySource];
    if (!resolved.sourceUsername.length) {
        resolved.sourceUsername = item.artist.length > 0 ? item.artist : @"audio";
    }
    if (!resolved.sourceMediaPK.length) {
        resolved.sourceMediaPK = item.mediaIdentifier;
    }
    if (!resolved.sourceMediaURLString.length) {
        NSString *rawURL = item.sourceURLString ?: item.url.absoluteString;
        // Normalize by stripping query/fragment for stable duplicate detection (CDN params change)
        if (rawURL.length > 0) {
            NSURLComponents *components = [NSURLComponents componentsWithString:rawURL];
            if (components) {
                components.query = nil;
                components.fragment = nil;
                resolved.sourceMediaURLString = components.string ?: rawURL;
            } else {
                resolved.sourceMediaURLString = rawURL;
            }
        }
    }
    if (!resolved.customName.length && item.title.length > 0) {
        resolved.customName = item.title;
    }
    if (resolved.durationSeconds <= 0.05) {
        resolved.durationSeconds = item.duration;
    }
    return resolved;
}

static NSString *SPKAudioNotificationIdentifier(NSString *provided,
                                                SPKAudioAction action) {
    if (provided.length > 0)
        return provided;
    switch (action) {
    case SPKAudioActionSaveToGallery:
    case SPKAudioActionConvertAndSaveToGallery:
        return kSPKNotificationDownloadGallery;
    case SPKAudioActionCopyURL:
        return kSPKNotificationDownloadShare;
    case SPKAudioActionSaveToFiles:
        return kSPKNotificationDownloadAudio;
    case SPKAudioActionShare:
    case SPKAudioActionConvertAndShare:
    case SPKAudioActionPlay:
    default:
        return kSPKNotificationDownloadShare;
    }
}

static void SPKAudioConvertToM4A(NSURL *sourceURL, NSString *basename,
                                 void (^progress)(float, NSString *),
                                 void (^completion)(NSURL *, NSError *)) {
    NSString *safeBase = basename.length > 0 ? basename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL
        fileURLWithPath:[NSTemporaryDirectory()
                            stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.m4a", safeBase]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    void (^runFFmpegFallback)(NSError *) = ^(NSError *avError) {
        if (![SPKMediaFFmpeg isAvailable]) {
            if (completion)
                completion(
                    nil,
                    avError
                        ?: [SPKUtils errorWithDescription:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT")]);
            return;
        }
        if (progress)
            progress(0.1f, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_FINALIZING_AUDIO_TEXT"));
        [SPKMediaFFmpeg extractAudioFileURL:sourceURL
            preferredBasename:safeBase
            progress:^(double ffmpegProgress, NSString *stage) {
                if (progress)
                    progress(0.1f + (float)(ffmpegProgress * 0.85),
                             stage.length > 0 ? stage : SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_FINALIZING_AUDIO_TEXT"));
            }
            completion:^(NSURL *_Nullable ffmpegURL,
                         NSError *_Nullable ffmpegError) {
                if (ffmpegURL && !ffmpegError) {
                    if (completion)
                        completion(ffmpegURL, nil);
                    return;
                }
                if (completion)
                    completion(nil, ffmpegError ?: avError ?
                                                           : [SPKUtils errorWithDescription:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT")]);
            }
            cancelOut:nil];
    };

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetExportSession *export =
        [[AVAssetExportSession alloc] initWithAsset:asset
                                         presetName:AVAssetExportPresetAppleM4A];
    if (!export) {
        runFFmpegFallback(
            [SPKUtils errorWithDescription:
                          SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_AUDIO_CONVERSION_NOT_AVAILABLE_FILE_TEXT")]);
        return;
    }
    export.outputURL = outputURL;
    export.outputFileType = AVFileTypeAppleM4A;
    export.shouldOptimizeForNetworkUse = YES;
    if (progress)
        progress(0.05f, SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT"));
    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (export.status == AVAssetExportSessionStatusCompleted &&
                [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
                if (completion)
                    completion(outputURL, nil);
                return;
            }
            NSError *error =
                export.error
                    ?: [SPKUtils errorWithDescription:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT")];
            runFFmpegFallback(error);
        });
    }];
}

static BOOL SPKAudioShouldConvertURL(NSURL *url, BOOL explicitConvert) {
    if (explicitConvert)
        return YES;
    NSString *ext = url.pathExtension.lowercaseString;
    if (ext.length == 0)
        return YES;
    return ![@[ @"m4a", @"mp3", @"aac", @"caf", @"wav" ] containsObject:ext];
}

static NSString *SPKAudioBasename(SPKAudioItem *item) {
    NSString *identifier = item.mediaIdentifier.length > 0
                               ? item.mediaIdentifier
                               : NSUUID.UUID.UUIDString;
    return [NSString stringWithFormat:@"sparkle_audio_%@", identifier];
}

static void SPKAudioPresentSaveToFiles(NSURL *fileURL,
                                       UIViewController *presenter,
                                       UIView *sourceView,
                                       NSString *identifier) {
    if (!fileURL.isFileURL)
        return;
    UIViewController *controller = presenter ?: topMostController();
    if (!controller) {
        SPKNotify(identifier, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_COULD_NOT_OPEN_FILES_TEXT"), nil, @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ fileURL ]
                                                              asCopy:YES];
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    if (sourceView) {
        picker.popoverPresentationController.sourceView = sourceView;
        picker.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [controller presentViewController:picker animated:YES completion:nil];
}

static void SPKAudioDownloadForSaveToFiles(SPKAudioItem *item, BOOL convert,
                                           UIViewController *presenter,
                                           UIView *sourceView,
                                           NSString *identifier) {
    BOOL showProgress = SPKNotificationIsEnabled(identifier);
    // Cancelling stops the download; a conversion already running finishes on
    // its own, but nothing is presented once the pill was cancelled.
    __block BOOL cancelled = NO;
    __block NSURLSessionDownloadTask *task = nil;
    __block SPKNotificationPillView *pill =
        showProgress ? SPKNotifyProgress(identifier, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT"), ^{
            cancelled = YES;
            [task cancel];
            [pill dismiss];
        })
                     : nil;

    void (^finishWithError)(NSString *, NSString *) =
        ^(NSString *title, NSString *subtitle) {
            if (cancelled)
                return;
            if (pill) {
                [pill showErrorWithTitle:title subtitle:subtitle icon:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(SPKNotificationPillDuration() *
                                                       NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   [pill dismiss];
                               });
            } else {
                SPKNotify(identifier, title, subtitle, @"error_filled",
                          SPKNotificationToneError);
            }
        };

    void (^presentFile)(NSURL *) = ^(NSURL *fileURL) {
        if (cancelled)
            return;
        if (pill)
            [pill dismiss];
        SPKAudioPresentSaveToFiles(fileURL, presenter, sourceView, identifier);
    };

    void (^processDownloadedFile)(NSURL *) = ^(NSURL *sourceURL) {
        if (cancelled)
            return;
        if (SPKAudioShouldConvertURL(sourceURL, convert)) {
            if (pill)
                [pill updateProgressTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT") subtitle:nil];
            SPKAudioConvertToM4A(
                sourceURL, SPKAudioBasename(item),
                ^(float progress, NSString *title) {
                    (void)title;
                    if (pill)
                        [pill setProgress:0.75f + progress * 0.2f animated:YES];
                },
                ^(NSURL *outputURL, NSError *convertError) {
                    if (outputURL)
                        presentFile(outputURL);
                    else
                        finishWithError(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT"),
                                        convertError.localizedDescription
                                            ?: SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_UNABLE_CONVERT_AUDIO_TEXT"));
                });
            return;
        }
        presentFile(sourceURL);
    };

    if (item.url.isFileURL) {
        processDownloadedFile(item.url);
        return;
    }

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    task = [session
        downloadTaskWithURL:item.url
          completionHandler:^(NSURL *location, NSURLResponse *response,
                              NSError *error) {
              (void)response;
              NSURL *movedTempURL = nil;
              NSError *moveError = nil;
              if (location && !error) {
                  NSString *ext = item.url.pathExtension.length > 0
                                      ? item.url.pathExtension
                                      : @"m4a";
                  movedTempURL = [NSURL
                      fileURLWithPath:[NSTemporaryDirectory()
                                          stringByAppendingPathComponent:
                                              [NSString
                                                  stringWithFormat:@"%@-raw.%@",
                                                                   SPKAudioBasename(
                                                                       item),
                                                                   ext]]];
                  [[NSFileManager defaultManager] removeItemAtURL:movedTempURL
                                                            error:nil];
                  if (![[NSFileManager defaultManager] moveItemAtURL:location
                                                               toURL:movedTempURL
                                                               error:&moveError]) {
                      movedTempURL = nil;
                  }
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                  if (error || !movedTempURL) {
                      finishWithError(SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_AUDIO_DOWNLOAD_FAILED_TEXT"), error.localizedDescription ?: moveError.localizedDescription ?
                                                                                                                             : SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_REFRESH_SOURCE_TRY_AGAIN_IF_URL_EXPIRED_TEXT"));
                      return;
                  }
                  if (pill)
                      [pill setProgress:0.7f animated:YES];
                  processDownloadedFile(movedTempURL);
              });
          }];
    [task resume];
}

@implementation SPKAudioDownloadCoordinator

+ (NSString *)processingBasenameForAudioItem:(SPKAudioItem *)item {
    return SPKAudioBasename(item);
}

+ (void)convertAudioAtURL:(NSURL *)sourceURL
                 basename:(NSString *)basename
                 progress:(void (^)(float, NSString *))progress
               completion:(void (^)(NSURL *, NSError *))completion {
    SPKAudioConvertToM4A(sourceURL, basename, progress, completion);
}

+ (NSURL *)bestAudioURLFromMediaObject:(id)mediaObject {
    if (!mediaObject)
        return nil;
    NSURL *direct = SPKAudioBestURLFromObject(mediaObject, [NSMutableSet set], 0);
    if (direct)
        return direct;

    return SPKAudioURLFromDashManifest(
        [SPKDashParser dashManifestForMedia:mediaObject]);
}

+ (NSURL *)bestAudioDownloadURLFromMediaObject:(id)mediaObject {
    return [self bestAudioURLFromMediaObject:mediaObject]
               ?: SPKAudioFallbackVideoURLFromMediaObject(mediaObject);
}

+ (SPKAudioItem *)audioItemFromMediaObject:(id)mediaObject
                                    source:(SPKAudioSource)source {
    return [self audioItemFromMediaObject:mediaObject
                                   source:source
                       allowVideoFallback:NO];
}

+ (SPKAudioItem *)audioItemFromMediaObject:(id)mediaObject
                                    source:(SPKAudioSource)source
                        allowVideoFallback:(BOOL)allowVideoFallback {
    NSURL *url = [self bestAudioURLFromMediaObject:mediaObject];
    if (!url && allowVideoFallback) {
        url = SPKAudioFallbackVideoURLFromMediaObject(mediaObject);
    }
    if (!url)
        return nil;
    SPKAudioItem *item = [SPKAudioItem itemWithURL:url source:source];
    item.duration = SPKAudioDurationForObject(mediaObject);
    item.title = SPKAudioStringValue(SPKAudioObjectForSelector(mediaObject, @"title") ?: SPKAudioKVCObject(mediaObject, @"title") ?
                                                                                                                                  : SPKAudioObjectForSelector(mediaObject, @"displayTitle"));
    item.artist = SPKAudioStringValue(SPKAudioObjectForSelector(mediaObject, @"artistDisplayName") ?: SPKAudioKVCObject(mediaObject, @"artistDisplayName") ?
                                                                                                  : SPKAudioObjectForSelector(mediaObject, @"username")    ?
                                                                                                                                                           : SPKAudioKVCObject(mediaObject, @"username"));
    item.mediaIdentifier = SPKAudioStringValue(SPKAudioObjectForSelector(mediaObject, @"audioAssetId") ?: SPKAudioKVCObject(mediaObject, @"audioAssetId") ?
                                                                                                      : SPKAudioObjectForSelector(mediaObject, @"pk")     ?
                                                                                                      : SPKAudioKVCObject(mediaObject, @"pk")             ?
                                                                                                      : SPKAudioObjectForSelector(mediaObject, @"id")     ?
                                                                                                                                                          : SPKAudioKVCObject(mediaObject, @"id"));
    item.sourceURLString = url.absoluteString;
    return item;
}

+ (void)performAction:(SPKAudioAction)action
                      item:(SPKAudioItem *)item
                 presenter:(UIViewController *)presenter
                sourceView:(UIView *)sourceView
                  metadata:(SPKGallerySaveMetadata *)metadata
    notificationIdentifier:(NSString *)notificationIdentifier {
    [self performAction:action
                          item:item
                     presenter:presenter
                    sourceView:sourceView
                      metadata:metadata
        notificationIdentifier:notificationIdentifier
                playbackSource:SPKFullScreenPlaybackSourceUnknown
                 pausePlayback:nil
                resumePlayback:nil];
}

+ (void)performAction:(SPKAudioAction)action
                      item:(SPKAudioItem *)item
                 presenter:(UIViewController *)presenter
                sourceView:(UIView *)sourceView
                  metadata:(SPKGallerySaveMetadata *)metadata
    notificationIdentifier:(NSString *)notificationIdentifier
            playbackSource:(SPKFullScreenPlaybackSource)playbackSource
             pausePlayback:(SPKMediaPreviewPlaybackBlock)pausePlayback
            resumePlayback:(SPKMediaPreviewPlaybackBlock)resumePlayback {
    if (!item.url) {
        SPKNotify(SPKAudioNotificationIdentifier(notificationIdentifier, action),
                  SPKL(@"GENERAL_AUDIO_PAGE_DOWNLOAD_COULD_NOT_FIND_AUDIO_URL_TEXT"), nil, @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    NSString *identifier =
        SPKAudioNotificationIdentifier(notificationIdentifier, action);
    if (action == SPKAudioActionCopyURL) {
        UIPasteboard.generalPasteboard.string = item.url.absoluteString;
        SPKNotify(identifier, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_COPIED_AUDIO_URL_TEXT"), nil, @"copy_filled",
                  SPKNotificationToneSuccess);
        return;
    }

    if (action == SPKAudioActionPlay) {
        SPKMediaItem *previewItem = [SPKMediaItem itemWithFileURL:item.url];
        previewItem.mediaType = SPKMediaItemTypeAudio;
        previewItem.galleryMetadata = SPKAudioMetadataFromItem(item, metadata);
        previewItem.title = item.title.length > 0 ? item.title : SPKL(@"COMMON_MEDIA_TYPE_AUDIO");
        [SPKFullScreenMediaPlayer showMediaItems:@[ previewItem ]
                                 startingAtIndex:0
                                        metadata:previewItem.galleryMetadata
                                  playbackSource:playbackSource
                                      sourceView:sourceView
                                      controller:presenter
                                   pausePlayback:pausePlayback
                                  resumePlayback:resumePlayback];
        return;
    }

    BOOL saveToFilesAction = (action == SPKAudioActionSaveToFiles);
    BOOL convert = (action == SPKAudioActionConvertAndShare ||
                    action == SPKAudioActionConvertAndSaveToGallery);
    SPKDownloadDestination destination =
        saveToFilesAction ? SPKDownloadDestinationCacheOnly
                          : ((action == SPKAudioActionSaveToGallery ||
                              action == SPKAudioActionConvertAndSaveToGallery)
                                 ? SPKDownloadDestinationGallery
                                 : SPKDownloadDestinationShare);
    SPKGallerySaveMetadata *resolvedMetadata =
        SPKAudioMetadataFromItem(item, metadata);

    NSString *scheme = item.url.scheme.lowercaseString;
    if (!item.url.isFileURL && ![@[ @"http", @"https" ] containsObject:scheme]) {
        SPKNotify(identifier, SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_AUDIO_DOWNLOAD_FAILED_TEXT"),
                  SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_INSTAGRAM_EXPOSED_UNSUPPORTED_AUDIO_URL_REFRESH_THREAD_TRY_AGAIN_TEXT"),
                  @"error_filled", SPKNotificationToneError);
        return;
    }

    if (saveToFilesAction) {
        if (item.url.isFileURL && !SPKAudioShouldConvertURL(item.url, convert)) {
            SPKAudioPresentSaveToFiles(item.url, presenter, sourceView, identifier);
            return;
        }
        SPKAudioDownloadForSaveToFiles(item, convert, presenter, sourceView,
                                       identifier);
        return;
    }

    if (!SPKAudioShouldConvertURL(item.url, convert)) {
        NSString *extension = [item preferredFileExtension];
        SPKDownloadItemRequest *itemRequest = item.url.isFileURL
                                                  ? [SPKDownloadItemRequest itemWithLocalPath:item.url.path
                                                                                    mediaKind:SPKDownloadMediaKindAudio]
                                                  : [SPKDownloadItemRequest itemWithRemoteURL:item.url
                                                                                    mediaKind:SPKDownloadMediaKindAudio];
        itemRequest.preferredFileExtension = extension;
        itemRequest.metadata = resolvedMetadata;
        itemRequest.expectedFilenameStem =
            [[SPKDownloadHelpers preferredFilenameForURL:item.url
                                               mediaKind:SPKDownloadMediaKindAudio
                                                metadata:resolvedMetadata] stringByDeletingPathExtension];
        SPKDownloadRequest *request =
            [SPKDownloadRequest requestWithItems:@[ itemRequest ]
                                     destination:destination];
        request.metadata = resolvedMetadata;
        request.notificationIdentifier = identifier;
        request.presenter = presenter;
        request.anchorView = sourceView;
        request.sourceSurface = SPKDownloadSourceSurfaceAudioPage;
        request.titleOverride = item.title.length > 0 ? item.title : nil;
        request.presentationMode = SPKNotificationIsEnabled(identifier) ? SPKDownloadPresentationModeQueuePill
                                                               : SPKDownloadPresentationModeErrorsOnly;
        [[SPKDownloadService shared] submitRequest:request completion:nil];
        return;
    }

    SPKDownloadItemRequest *itemRequest =
        [SPKDownloadItemRequest itemWithRemoteURL:item.url
                                        mediaKind:SPKDownloadMediaKindAudio];
    itemRequest.preferredFileExtension = @"m4a";
    itemRequest.metadata = resolvedMetadata;
    itemRequest.requiresAudioConversion = YES;
    itemRequest.audioProcessingBasename =
        [self processingBasenameForAudioItem:item];
    SPKDownloadRequest *request =
        [SPKDownloadRequest requestWithItems:@[ itemRequest ]
                                 destination:destination];
    request.metadata = resolvedMetadata;
    request.notificationIdentifier = identifier;
    request.presenter = presenter;
    request.anchorView = sourceView;
    request.sourceSurface = SPKDownloadSourceSurfaceAudioPage;
    request.titleOverride = item.title.length > 0 ? item.title : nil;
    request.presentationMode = SPKNotificationIsEnabled(identifier) ? SPKDownloadPresentationModeQueuePill
                                                               : SPKDownloadPresentationModeErrorsOnly;
    [[SPKDownloadService shared] submitRequest:request completion:nil];
}

@end
