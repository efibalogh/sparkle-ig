#import <UIKit/UIKit.h>

@class SPKGalleryFile, SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKMediaItemType) {
    SPKMediaItemTypeImage = 1,
    SPKMediaItemTypeVideo = 2,
    SPKMediaItemTypeAudio = 3,
};

@interface SPKMediaItem : NSObject

@property (nonatomic) SPKMediaItemType mediaType;
@property (nonatomic, strong, nullable) NSURL *fileURL;
@property (nonatomic, strong, nullable) NSURL *resolvedFileURL;
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, strong, nullable) UIImage *thumbnail;
@property (nonatomic, strong, nullable) id sourceMediaObject;
/// The post a carousel child belongs to, for post-level metadata and 4K lookups in bulk saves.
@property (nonatomic, strong, nullable) id parentMediaObject;
@property (nonatomic, copy, nullable) NSString *title;
/// When >= 0, `SPKGallerySaveMetadata.source` uses this value (`SPKGallerySource`). Default -1 = not set.
@property (nonatomic, assign) NSInteger gallerySaveSource;
@property (nonatomic, strong, nullable) SPKGallerySaveMetadata *galleryMetadata;
@property (nonatomic, strong, nullable) SPKGalleryFile *galleryFile;
@property (nonatomic, assign) BOOL isFromGallery;

+ (instancetype)itemWithFileURL:(NSURL *)url;
+ (instancetype)itemWithImage:(UIImage *)image;
+ (instancetype)itemWithGalleryFile:(SPKGalleryFile *)file;
+ (SPKMediaItemType)mediaTypeForFileExtension:(NSString *)extension;

@end

NS_ASSUME_NONNULL_END
