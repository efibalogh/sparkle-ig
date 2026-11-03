#import "SPKStrings.h"
#import "SPKMediaCacheManager.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "../Gallery/SPKGalleryFile.h"
#import "SPKMediaItem.h"

static NSString *SPKSHA256String(NSString *value) {
    if (value.length == 0)
        return @"";

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}

/// Decoded byte cost of an image, so the caches can be bounded by memory rather
/// than by entry count.
static NSUInteger SPKImageCacheCost(UIImage *image) {
    if (!image)
        return 0;
    CGImageRef cgImage = image.CGImage;
    if (cgImage) {
        return (NSUInteger)(CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage));
    }
    CGFloat scale = image.scale > 0 ? image.scale : 1.0;
    return (NSUInteger)(image.size.width * scale * image.size.height * scale * 4.0);
}

static NSString *SPKFileKeyForURL(NSURL *url) {
    return url.absoluteString ?: url.path ?
                                          : @"";
}

@interface SPKMediaCacheManager ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnailCache;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSURL *_Nullable, NSError *_Nullable)> *> *downloadCompletions;

@end

NSErrorDomain const SPKMediaCacheErrorDomain = @"SPKMediaCacheManager";

BOOL SPKMediaCacheErrorIsLocalFileMissing(NSError *error) {
    return [error.domain isEqualToString:SPKMediaCacheErrorDomain] && error.code == SPKMediaCacheErrorLocalFileMissing;
}

@implementation SPKMediaCacheManager

+ (instancetype)sharedManager {
    static SPKMediaCacheManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[SPKMediaCacheManager alloc] initPrivate];
    });
    return manager;
}

- (instancetype)init {
    [NSException raise:NSInternalInconsistencyException format:@"Use +sharedManager"];
    return nil;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:(24 * 1024 * 1024)
                                                        diskCapacity:(200 * 1024 * 1024)
                                                            diskPath:@"com.sparkle.media-preview.url-cache"];
        _session = [NSURLSession sessionWithConfiguration:config];

        _imageCache = [[NSCache alloc] init];
        _imageCache.name = @"com.sparkle.media-preview.image-cache";
        // These are full-size photos: a single 12 MP frame is ~48 MB decoded, so a
        // count limit alone let the cache grow to gigabytes. Bound it by bytes and
        // keep the count modest -- anything evicted reloads from disk.
        _imageCache.countLimit = 12;
        _imageCache.totalCostLimit = 96 * 1024 * 1024; // 96 MB

        _thumbnailCache = [[NSCache alloc] init];
        _thumbnailCache.name = @"com.sparkle.media-preview.thumbnail-cache";
        _thumbnailCache.countLimit = 64;
        _thumbnailCache.totalCostLimit = 16 * 1024 * 1024; // 16 MB

        _stateQueue = dispatch_queue_create("com.sparkle.media-preview.cache-state", DISPATCH_QUEUE_SERIAL);
        _downloadCompletions = [NSMutableDictionary dictionary];

        [self ensureDirectoriesExist];
    }
    return self;
}

- (NSURL *)cacheRootURL {
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [caches URLByAppendingPathComponent:@"SparkleMediaPreview" isDirectory:YES];
}

- (NSURL *)fileCacheDirectoryURL {
    return [[self cacheRootURL] URLByAppendingPathComponent:@"Files" isDirectory:YES];
}

- (void)ensureDirectoriesExist {
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:[self fileCacheDirectoryURL]
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&error];
}

- (nullable NSURL *)bestAvailableFileURLForItem:(SPKMediaItem *)item {
    if (!item)
        return nil;

    [self ensureDirectoriesExist];

    NSURL *resolvedURL = item.resolvedFileURL;
    if (resolvedURL.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:resolvedURL.path]) {
        return resolvedURL;
    }

    NSURL *fileURL = item.fileURL;
    if (fileURL.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
        item.resolvedFileURL = fileURL;
        return fileURL;
    }

    NSURL *cachedURL = [self cachedFileURLForRemoteURL:fileURL];
    if (cachedURL) {
        item.resolvedFileURL = cachedURL;
        return cachedURL;
    }

    return nil;
}

- (nullable NSURL *)cachedFileURLForRemoteURL:(NSURL *)url {
    if (!url || url.isFileURL)
        return nil;

    NSString *key = SPKFileKeyForURL(url);
    if (key.length == 0)
        return nil;

    NSString *hash = SPKSHA256String(key);
    NSString *ext = url.pathExtension.lowercaseString;
    if (ext.length == 0) {
        ext = [self inferredDefaultExtensionForURL:url];
    }

    NSString *fileName = ext.length > 0 ? [NSString stringWithFormat:@"%@.%@", hash, ext] : hash;
    NSURL *candidate = [[self fileCacheDirectoryURL] URLByAppendingPathComponent:fileName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:candidate.path]) {
        return candidate;
    }
    return nil;
}

- (NSString *)inferredDefaultExtensionForURL:(NSURL *)url {
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path containsString:@".mp4"] || [path containsString:@".mov"] || [path containsString:@".m4v"]) {
        return @"mp4";
    }
    return @"jpg";
}

- (void)fetchLocalFileURLForItem:(SPKMediaItem *)item
                      completion:(void (^)(NSURL *_Nullable localURL, NSError *_Nullable error))completion {
    if (!item) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"SPKMediaCacheManager"
                                                code:-1
                                            userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_MISSING_MEDIA_ITEM_ERROR")}]);
        }
        return;
    }

    NSURL *existingURL = [self bestAvailableFileURLForItem:item];
    if (existingURL) {
        if (completion)
            completion(existingURL, nil);
        return;
    }

    NSURL *remoteURL = item.fileURL;
    if (remoteURL.isFileURL) {
        // bestAvailableFileURLForItem: already looked for it on disk.
        NSString *message = item.galleryFile ? SPKL(@"MEDIA_PREVIEW_GALLERY_FILE_MISSING_MESSAGE")
                                             : SPKL(@"MEDIA_PREVIEW_LOCAL_FILE_MISSING_MESSAGE");
        if (completion)
            completion(nil, [NSError errorWithDomain:SPKMediaCacheErrorDomain
                                                code:SPKMediaCacheErrorLocalFileMissing
                                            userInfo:@{NSLocalizedDescriptionKey : message}]);
        return;
    }
    if (!remoteURL) {
        if (completion)
            completion(nil, [NSError errorWithDomain:@"SPKMediaCacheManager"
                                                code:-2
                                            userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_MEDIA_CACHE_MANAGER_MISSING_REMOTE_MEDIA_URL_TEXT")}]);
        return;
    }

    NSString *key = SPKFileKeyForURL(remoteURL);
    if (key.length == 0) {
        if (completion)
            completion(nil, [NSError errorWithDomain:@"SPKMediaCacheManager"
                                                code:-3
                                            userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_MEDIA_CACHE_MANAGER_INVALID_REMOTE_MEDIA_URL_TEXT")}]);
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.stateQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSMutableArray *existingCompletions = strongSelf.downloadCompletions[key];
        void (^wrappedCompletion)(NSURL *_Nullable, NSError *_Nullable) = ^(NSURL *_Nullable localURL, NSError *_Nullable error) {
            if (localURL) {
                item.resolvedFileURL = localURL;
            }
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(localURL, error);
                });
            }
        };

        if (existingCompletions) {
            [existingCompletions addObject:[wrappedCompletion copy]];
            return;
        }

        strongSelf.downloadCompletions[key] = [NSMutableArray arrayWithObject:[wrappedCompletion copy]];

        NSURLRequest *request = [NSURLRequest requestWithURL:remoteURL
                                                 cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                             timeoutInterval:60.0];

        NSURLSessionDownloadTask *task = [strongSelf.session downloadTaskWithRequest:request
                                                                   completionHandler:^(NSURL *tempURL, NSURLResponse *response, NSError *error) {
                                                                       NSURL *finalURL = nil;
                                                                       NSError *finalError = error;

                                                                       if (!finalError && tempURL) {
                                                                           [strongSelf ensureDirectoriesExist];

                                                                           NSString *hash = SPKSHA256String(key);
                                                                           NSString *ext = remoteURL.pathExtension.lowercaseString;
                                                                           if (ext.length == 0) {
                                                                               ext = response.suggestedFilename.pathExtension.lowercaseString;
                                                                           }
                                                                           if (ext.length == 0) {
                                                                               ext = [strongSelf inferredDefaultExtensionForURL:remoteURL];
                                                                           }

                                                                           NSString *fileName = ext.length > 0 ? [NSString stringWithFormat:@"%@.%@", hash, ext] : hash;
                                                                           NSURL *destinationURL = [[strongSelf fileCacheDirectoryURL] URLByAppendingPathComponent:fileName];
                                                                           [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
                                                                           if ([[NSFileManager defaultManager] moveItemAtURL:tempURL toURL:destinationURL error:&finalError]) {
                                                                               finalURL = destinationURL;
                                                                           }
                                                                       }

                                                                       dispatch_async(strongSelf.stateQueue, ^{
                                                                           NSArray<void (^)(NSURL *_Nullable, NSError *_Nullable)> *callbacks = [strongSelf.downloadCompletions[key] copy] ?: @[];
                                                                           [strongSelf.downloadCompletions removeObjectForKey:key];
                                                                           for (void (^callback)(NSURL *_Nullable, NSError *_Nullable) in callbacks) {
                                                                               callback(finalURL, finalError);
                                                                           }
                                                                       });
                                                                   }];
        [task resume];
    });
}

- (void)loadImageForItem:(SPKMediaItem *)item
              completion:(void (^)(UIImage *_Nullable image, NSError *_Nullable error))completion {
    if (!item) {
        if (completion)
            completion(nil, [NSError errorWithDomain:@"SPKMediaCacheManager"
                                                code:-4
                                            userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_MISSING_MEDIA_ITEM_ERROR")}]);
        return;
    }

    if (item.image) {
        if (completion)
            completion(item.image, nil);
        return;
    }

    NSURL *bestURL = [self bestAvailableFileURLForItem:item];
    NSString *cacheKey = SPKFileKeyForURL(bestURL ?: item.fileURL);
    if (cacheKey.length > 0) {
        UIImage *cachedImage = [self.imageCache objectForKey:cacheKey];
        if (cachedImage) {
            item.image = cachedImage;
            if (completion)
                completion(cachedImage, nil);
            return;
        }
    }

    __weak typeof(self) weakSelf = self;
    void (^decodeImageAtURL)(NSURL *) = ^(NSURL *localURL) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *image = nil;
            if (localURL.isFileURL) {
                image = [UIImage imageWithContentsOfFile:localURL.path];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (image) {
                    item.image = image;
                    if (cacheKey.length > 0) {
                        [strongSelf.imageCache setObject:image
                                                  forKey:cacheKey
                                                    cost:SPKImageCacheCost(image)];
                    }
                    if (completion)
                        completion(image, nil);
                } else if (completion) {
                    completion(nil, [NSError errorWithDomain:@"SPKMediaCacheManager"
                                                        code:-5
                                                    userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_PREVIEW_MEDIA_CACHE_MANAGER_FAILED_DECODE_IMAGE_TEXT")}]);
                }
            });
        });
    };

    if (bestURL.isFileURL) {
        decodeImageAtURL(bestURL);
        return;
    }

    [self fetchLocalFileURLForItem:item
                        completion:^(NSURL *_Nullable localURL, NSError *_Nullable error) {
                            if (!localURL || error) {
                                if (completion)
                                    completion(nil, error);
                                return;
                            }
                            decodeImageAtURL(localURL);
                        }];
}

- (void)loadThumbnailForVideoItem:(SPKMediaItem *)item
                       completion:(void (^)(UIImage *_Nullable image))completion {
    if (!item || item.mediaType != SPKMediaItemTypeVideo) {
        if (completion)
            completion(nil);
        return;
    }

    if (item.thumbnail) {
        if (completion)
            completion(item.thumbnail);
        return;
    }

    NSString *cacheKey = SPKFileKeyForURL(item.fileURL);
    if (cacheKey.length > 0) {
        UIImage *cachedImage = [self.thumbnailCache objectForKey:cacheKey];
        if (cachedImage) {
            item.thumbnail = cachedImage;
            if (completion)
                completion(cachedImage);
            return;
        }
    }

    // Gallery files already have a thumbnail on disk; read that instead of
    // spinning up an AVAssetImageGenerator over the whole video.
    if (item.galleryFile) {
        SPKGalleryFile *file = item.galleryFile;
        __weak typeof(self) weakSelf = self;
        [SPKGalleryFile loadThumbnailAsyncForFile:file
                                       completion:^(UIImage *_Nullable thumbnail) {
                                           if (!thumbnail) {
                                               // No thumbnail on disk and none could be
                                               // generated: fall through to the generic path.
                                               [weakSelf loadVideoThumbnailFromAssetForItem:item
                                                                                   cacheKey:cacheKey
                                                                                 completion:completion];
                                               return;
                                           }
                                           item.thumbnail = thumbnail;
                                           if (cacheKey.length > 0) {
                                               [weakSelf.thumbnailCache setObject:thumbnail
                                                                           forKey:cacheKey
                                                                             cost:SPKImageCacheCost(thumbnail)];
                                           }
                                           if (completion)
                                               completion(thumbnail);
                                       }];
        return;
    }

    [self loadVideoThumbnailFromAssetForItem:item cacheKey:cacheKey completion:completion];
}

- (void)loadVideoThumbnailFromAssetForItem:(SPKMediaItem *)item
                                  cacheKey:(NSString *)cacheKey
                                completion:(void (^)(UIImage *_Nullable image))completion {

    NSURL *sourceURL = [self bestAvailableFileURLForItem:item] ?: item.fileURL;
    if (!sourceURL) {
        if (completion)
            completion(nil);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVAsset *asset = [AVAsset assetWithURL:sourceURL];
        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(720.0, 720.0);

        NSError *error = nil;
        CGImageRef imageRef = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
        UIImage *thumbnail = imageRef ? [UIImage imageWithCGImage:imageRef] : nil;
        if (imageRef) {
            CGImageRelease(imageRef);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (thumbnail) {
                item.thumbnail = thumbnail;
                if (cacheKey.length > 0) {
                    [self.thumbnailCache setObject:thumbnail
                                            forKey:cacheKey
                                              cost:SPKImageCacheCost(thumbnail)];
                }
            }
            if (completion)
                completion(thumbnail);
        });
    });
}

- (void)prefetchItem:(SPKMediaItem *)item {
    if (!item)
        return;

    if (item.mediaType == SPKMediaItemTypeImage) {
        [self loadImageForItem:item
                    completion:^(__unused UIImage *image, __unused NSError *error){
                    }];
        return;
    }

    [self fetchLocalFileURLForItem:item
                        completion:^(__unused NSURL *localURL, __unused NSError *error){
                        }];
    [self loadThumbnailForVideoItem:item
                         completion:^(__unused UIImage *image){
                         }];
}

@end
