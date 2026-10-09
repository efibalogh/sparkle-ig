#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "SPKDownloadTypes.h"

@class SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

@interface SPKDownloadItemRequest : NSObject <NSCopying>
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, copy, nullable) NSString *remoteURLString;
@property (nonatomic, copy, nullable) NSString *localSourcePath;
@property (nonatomic, assign) SPKDownloadMediaKind mediaKind;
@property (nonatomic, copy, nullable) NSString *preferredFileExtension;
@property (nonatomic, copy, nullable) NSString *expectedFilenameStem;
@property (nonatomic, copy, nullable) NSString *linkString;
@property (nonatomic, strong, nullable) SPKGallerySaveMetadata *metadata;
@property (nonatomic, assign) NSInteger index;
/// When YES, scheduler downloads the remote URL then converts to M4A before finalizing (audio page).
@property (nonatomic, assign) BOOL requiresAudioConversion;
@property (nonatomic, copy, nullable) NSString *audioProcessingBasename;
/// When YES, scheduler runs DASH download + FFmpeg merge (SPKMediaQualityManager).
@property (nonatomic, assign) BOOL requiresDashMerge;
@property (nonatomic, copy, nullable) NSString *dashSecondaryURLString;
@property (nonatomic, assign) NSInteger dashOptionKind;
@property (nonatomic, assign) double dashDuration;
@property (nonatomic, assign) NSInteger dashWidth;
@property (nonatomic, assign) NSInteger dashHeight;
@property (nonatomic, assign) NSInteger dashBandwidth;
/// Ready-to-play items only: DASH video URL to merge instead when the CDN can't
/// serve the progressive file. Uses the dash* fields above for the rest.
@property (nonatomic, copy, nullable) NSString *dashFallbackURLString;

+ (instancetype)itemWithRemoteURL:(NSURL *)url mediaKind:(SPKDownloadMediaKind)kind;
+ (instancetype)itemWithLocalPath:(NSString *)path mediaKind:(SPKDownloadMediaKind)kind;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

@interface SPKDownloadRequest : NSObject <NSCopying>
@property (nonatomic, copy) NSString *requestID;
@property (nonatomic, assign) NSTimeInterval createdAt;
@property (nonatomic, assign) SPKDownloadSourceSurface sourceSurface;
@property (nonatomic, assign) SPKDownloadDestination destination;
@property (nonatomic, assign) SPKDownloadPresentationMode presentationMode;
@property (nonatomic, copy) NSArray<SPKDownloadItemRequest *> *items;
@property (nonatomic, strong, nullable) SPKGallerySaveMetadata *metadata;
@property (nonatomic, copy, nullable) NSString *notificationIdentifier;
@property (nonatomic, weak, nullable) UIViewController *presenter;
@property (nonatomic, weak, nullable) UIView *anchorView;
@property (nonatomic, assign) SPKDownloadDuplicatePolicyMode duplicatePolicy;
@property (nonatomic, assign) SPKDownloadQualityPolicy qualityPolicy;
@property (nonatomic, copy, nullable) NSString *titleOverride;
/// Carousel share: download items to cache, present one share sheet when the job finishes.
@property (nonatomic, assign) BOOL finalizeAsBatchShare;
/// Carousel copy: download items to cache, copy all to the pasteboard when the job finishes.
@property (nonatomic, assign) BOOL finalizeAsBatchClipboard;

+ (instancetype)requestWithItems:(NSArray<SPKDownloadItemRequest *> *)items
                     destination:(SPKDownloadDestination)destination;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

NS_ASSUME_NONNULL_END
