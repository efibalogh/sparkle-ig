#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "SPKTrimCrop.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPKTrimRenderProgressBlock)(double progress);
typedef void (^SPKTrimRenderCompletionBlock)(NSURL *_Nullable outputURL, NSError *_Nullable error);

/// Headless rendering for the trim editor. Keeps the editor UI agnostic of the
/// backend so the same flow can drive other media (e.g. audio uploads) later.
@interface SPKTrimRenderer : NSObject

/// Renders a frame-accurate trimmed clip to a temp mp4. Uses the FFmpeg pipeline
/// (libx264, honoring `downloads_encoding_*` prefs) when available, otherwise
/// falls back to `AVAssetExportSession`. A non-nil `crop` is applied in the same
/// pass (an FFmpeg filter chain, or a video composition on the fallback path).
+ (void)renderTrimForSourceURL:(NSURL *)sourceURL
                         asset:(nullable AVAsset *)asset
                  startSeconds:(NSTimeInterval)startSeconds
               durationSeconds:(NSTimeInterval)durationSeconds
                          crop:(nullable SPKTrimCrop *)crop
                      basename:(NSString *)basename
                      progress:(nullable SPKTrimRenderProgressBlock)progress
                    completion:(SPKTrimRenderCompletionBlock)completion
                     cancelOut:(nullable void (^)(dispatch_block_t cancel))cancelOut;

/// Single-pass trim + merge of a separate DASH video and audio stream (local or
/// remote). Used by the save-flow when the chosen quality is a DASH video that
/// needs its audio merged in. Delivers completion on the main thread.
+ (void)renderTrimMergeForVideoURL:(NSURL *)videoURL
                          audioURL:(NSURL *)audioURL
                      startSeconds:(NSTimeInterval)startSeconds
                   durationSeconds:(NSTimeInterval)durationSeconds
                              crop:(nullable SPKTrimCrop *)crop
                             width:(NSInteger)width
                            height:(NSInteger)height
                          basename:(NSString *)basename
                          progress:(nullable SPKTrimRenderProgressBlock)progress
                        completion:(SPKTrimRenderCompletionBlock)completion
                         cancelOut:(nullable void (^)(dispatch_block_t cancel))cancelOut;

/// Extracts a single still frame at `seconds` (precise) and writes it as HEIC,
/// falling back to JPEG. Always uses AVFoundation — exact and fast.
+ (void)renderFrameForAsset:(AVAsset *)asset
                  atSeconds:(NSTimeInterval)seconds
                   basename:(NSString *)basename
                 completion:(SPKTrimRenderCompletionBlock)completion;

/// Same as `renderFrameForAsset:` for a local file, but when AVFoundation can't
/// decode the video (AV1 on devices without a hardware decoder) the frame is
/// pulled with FFmpeg instead, so the still keeps the file's full resolution.
+ (void)renderFrameForVideoURL:(NSURL *)videoURL
                     atSeconds:(NSTimeInterval)seconds
                      basename:(NSString *)basename
                    completion:(SPKTrimRenderCompletionBlock)completion;

/// Renders `[startSeconds, startSeconds + durationSeconds)` of an audio source to
/// a temp `.m4a` (AAC) via `AVAssetExportSession` — native, exact, and the format
/// the DM voice-note sender expects. Delivers completion on the main thread.
+ (void)renderTrimAudioForSourceURL:(NSURL *)sourceURL
                              asset:(nullable AVAsset *)asset
                       startSeconds:(NSTimeInterval)startSeconds
                    durationSeconds:(NSTimeInterval)durationSeconds
                           basename:(NSString *)basename
                         completion:(SPKTrimRenderCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
