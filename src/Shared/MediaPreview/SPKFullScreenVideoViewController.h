#import "SPKFullScreenImageViewController.h"
#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>

@class SPKMediaItem;

NS_ASSUME_NONNULL_BEGIN

@interface SPKFullScreenVideoViewController : UIViewController

@property (nonatomic, strong, readonly) SPKMediaItem *mediaItem;
@property (nonatomic, weak) id<SPKFullScreenContentDelegate> delegate;
@property (nonatomic, strong, readonly, nullable) UIView *contentOverlayView;
@property (nonatomic, readonly) BOOL isZoomed;

- (instancetype)initWithMediaItem:(SPKMediaItem *)item;
- (void)preloadContent;
- (void)prepareForDisplay;
/// Rebuilds the AVPlayer from `url`, discarding the currently-loaded asset. Used
/// after an in-place Gallery Replace, where the media on disk changed but the
/// live player still holds the old asset.
- (void)reloadWithFileURL:(NSURL *)url;
- (void)cleanup;
- (void)resetZoomIfNeeded;
- (void)setPlayerControlOverlayInsets:(UIEdgeInsets)insets animated:(BOOL)animated;
/// Keeps AVKit's transport controls above the supplied bottom boundary while
/// accounting for any safe area that UIKit already propagated to the player.
- (void)synchronizePlayerControlsToBottomBoundaryInset:(CGFloat)bottomInset
                                              animated:(BOOL)animated;
- (void)applyMediaContentInsets:(UIEdgeInsets)insets;
- (void)play;
- (void)pause;

@end

NS_ASSUME_NONNULL_END
