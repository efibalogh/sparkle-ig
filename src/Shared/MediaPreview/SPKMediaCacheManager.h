#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SPKMediaItem;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SPKMediaCacheErrorDomain;

/// The item points at a local file that is no longer on disk (for a Gallery item:
/// its row survived, its media file did not). Retrying cannot help.
static const NSInteger SPKMediaCacheErrorLocalFileMissing = -6;

/// YES for SPKMediaCacheErrorLocalFileMissing.
FOUNDATION_EXPORT BOOL SPKMediaCacheErrorIsLocalFileMissing(NSError *_Nullable error);

@interface SPKMediaCacheManager : NSObject

+ (instancetype)sharedManager;

- (nullable NSURL *)bestAvailableFileURLForItem:(SPKMediaItem *)item;
- (nullable NSURL *)cachedFileURLForRemoteURL:(NSURL *)url;

- (void)fetchLocalFileURLForItem:(SPKMediaItem *)item
                      completion:(void (^)(NSURL *_Nullable localURL, NSError *_Nullable error))completion;

- (void)loadImageForItem:(SPKMediaItem *)item
              completion:(void (^)(UIImage *_Nullable image, NSError *_Nullable error))completion;

- (void)loadThumbnailForVideoItem:(SPKMediaItem *)item
                       completion:(void (^)(UIImage *_Nullable image))completion;

- (void)prefetchItem:(SPKMediaItem *)item;

@end

NS_ASSUME_NONNULL_END
