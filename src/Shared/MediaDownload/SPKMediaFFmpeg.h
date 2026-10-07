#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPKMediaFFmpegProgressBlock)(double progress, NSString *stage);
typedef void (^SPKMediaFFmpegCompletionBlock)(NSURL *_Nullable outputURL, NSError *_Nullable error);
typedef void (^SPKMediaFFmpegCancelBlockPublisher)(dispatch_block_t cancelBlock);

@interface SPKMediaFFmpeg : NSObject

+ (BOOL)isAvailable;
+ (void)cancelAll;
+ (UIViewController *)logsViewController;

+ (void)mergeVideoFileURL:(NSURL *)videoFileURL
             audioFileURL:(nullable NSURL *)audioFileURL
        preferredBasename:(NSString *)preferredBasename
        estimatedDuration:(NSTimeInterval)estimatedDuration
                    width:(NSInteger)width
                   height:(NSInteger)height
            sourceBitrate:(NSInteger)sourceBitrate
                 progress:(nullable SPKMediaFFmpegProgressBlock)progress
               completion:(SPKMediaFFmpegCompletionBlock)completion
                cancelOut:(nullable SPKMediaFFmpegCancelBlockPublisher)cancelOut;

+ (void)extractAudioFileURL:(NSURL *)audioFileURL
          preferredBasename:(NSString *)preferredBasename
                   progress:(nullable SPKMediaFFmpegProgressBlock)progress
                 completion:(SPKMediaFFmpegCompletionBlock)completion
                  cancelOut:(nullable SPKMediaFFmpegCancelBlockPublisher)cancelOut;

/// `cropFilter` is an optional leading -vf fragment (see `SPKTrimCrop`); pass the
/// resulting picture size as `croppedSize` (or CGSizeZero) so max-resolution
/// scaling measures the cropped frame rather than the original.
/// Frame-accurate re-encode trim. Encodes `[startSeconds, startSeconds +
/// durationSeconds)` of the source with libx264 (preset from
/// `downloads_encoding_speed`), then relocates the moov atom (+faststart).
/// Audio is re-encoded to AAC, falling back to stream-copy then dropped if the
/// bundled FFmpeg can't decode the source track.
+ (void)trimVideoFileURL:(NSURL *)videoFileURL
            startSeconds:(NSTimeInterval)startSeconds
         durationSeconds:(NSTimeInterval)durationSeconds
              cropFilter:(nullable NSString *)cropFilter
             croppedSize:(CGSize)croppedSize
       preferredBasename:(NSString *)preferredBasename
                progress:(nullable SPKMediaFFmpegProgressBlock)progress
              completion:(SPKMediaFFmpegCompletionBlock)completion
               cancelOut:(nullable SPKMediaFFmpegCancelBlockPublisher)cancelOut;

/// Single-pass trim + merge of a separate DASH video and audio source (local
/// paths or remote http(s) URLs). With remote inputs the `-ss` input seek makes
/// FFmpeg fetch only the selected window via HTTP range requests, so cost scales
/// with the clip length, not the full video. Honors the encoding settings.
+ (void)trimMergeVideoURL:(NSURL *)videoURL
                 audioURL:(NSURL *)audioURL
             startSeconds:(NSTimeInterval)startSeconds
          durationSeconds:(NSTimeInterval)durationSeconds
               cropFilter:(nullable NSString *)cropFilter
        preferredBasename:(NSString *)preferredBasename
                    width:(NSInteger)width
                   height:(NSInteger)height
                 progress:(nullable SPKMediaFFmpegProgressBlock)progress
               completion:(SPKMediaFFmpegCompletionBlock)completion
                cancelOut:(nullable SPKMediaFFmpegCancelBlockPublisher)cancelOut;

/// Decodes the frame at `seconds` of a local video into a lossless PNG. For
/// codecs AVFoundation can't decode on every device (IG's high-resolution DASH
/// representations are AV1). Completion is delivered on FFmpegKit's thread.
+ (void)extractFrameFromVideoFileURL:(NSURL *)videoFileURL
                           atSeconds:(NSTimeInterval)seconds
                   preferredBasename:(NSString *)preferredBasename
                          completion:(SPKMediaFFmpegCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
