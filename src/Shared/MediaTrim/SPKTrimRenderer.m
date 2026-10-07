#import "SPKTrimRenderer.h"
#import "../../Utils.h"
#import "../MediaDownload/SPKMediaFFmpeg.h"
#import "SPKStrings.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>

static NSError *SPKTrimRendererError(NSString *description) {
    return [NSError errorWithDomain:@"Sparkle.TrimRenderer"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : description ?: SPKL(@"MEDIA_TRIM_TRIM_RENDERER_RENDER_FAILED_TEXT")}];
}

// The video's size as the viewer sees it — natural size with the track's
// display transform applied. Both crop backends work in this space.
static CGSize SPKTrimOrientedSize(AVAsset *asset) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track)
        return CGSizeZero;
    CGSize rendered = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    return CGSizeMake(fabs(rendered.width), fabs(rendered.height));
}

// Builds the video composition that realizes a crop on the AVFoundation fallback
// path. The transform is assembled in application order — orient, rotate, mirror,
// then shift the crop origin to (0,0) — because every step but the first needs a
// translation to keep the picture in the positive quadrant AVFoundation renders.
static AVVideoComposition *SPKTrimCropComposition(AVAsset *asset, SPKTrimCrop *crop) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track)
        return nil;
    CGSize oriented = SPKTrimOrientedSize(asset);
    if (oriented.width <= 0.0 || oriented.height <= 0.0)
        return nil;
    CGRect pixels = [crop pixelRectForOrientedSize:oriented];
    if (pixels.size.width <= 0.0 || pixels.size.height <= 0.0)
        return nil;

    // 1. natural -> oriented.
    CGAffineTransform t = track.preferredTransform;

    // 2. quarter turns clockwise. In AVFoundation's y-down render space a
    //    positive rotation is clockwise; each turn leaves the picture in a
    //    negative quadrant, so it is translated straight back.
    CGSize size = oriented;
    for (NSInteger i = 0; i < crop.rotationQuarters; i++) {
        t = CGAffineTransformConcat(t, CGAffineTransformMakeRotation((CGFloat)M_PI_2));
        t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(size.height, 0.0));
        size = CGSizeMake(size.height, size.width);
    }

    // 3. horizontal mirror within the rotated frame.
    if (crop.mirrored) {
        t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(-1.0, 1.0));
        t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(size.width, 0.0));
    }

    // 4. move the crop rect's origin to the render origin.
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(-pixels.origin.x, -pixels.origin.y));

    AVMutableVideoCompositionLayerInstruction *layer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:t atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    instruction.layerInstructions = @[ layer ];

    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = pixels.size;
    CMTime frameDuration = track.minFrameDuration;
    if (!CMTIME_IS_VALID(frameDuration) || CMTIME_COMPARE_INLINE(frameDuration, ==, kCMTimeZero)) {
        frameDuration = CMTimeMake(1, 30);
    }
    composition.frameDuration = frameDuration;
    composition.instructions = @[ instruction ];
    return composition;
}

@interface SPKTrimRenderer ()
+ (void)generateFrameForAsset:(AVAsset *)asset
                    atSeconds:(NSTimeInterval)seconds
                     basename:(NSString *)basename
               allowTolerance:(BOOL)allowTolerance
                   completion:(SPKTrimRenderCompletionBlock)completion;
@end

// Encodes a CGImage to a temp file. Prefers HEIC (much smaller — the whole
// point of reducing a "song over a photo" video to one frame), falls back to
// JPEG if the HEIC encoder is unavailable.
static NSURL *SPKTrimWriteCGImage(CGImageRef image, NSString *basename) {
    if (!image)
        return nil;
    NSString *tmp = NSTemporaryDirectory();

    NSURL *heicURL = [NSURL fileURLWithPath:[tmp stringByAppendingPathComponent:[basename stringByAppendingPathExtension:@"heic"]]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)heicURL, (CFStringRef) @"public.heic", 1, NULL);
    if (dest) {
        NSDictionary *props = @{(__bridge id)kCGImageDestinationLossyCompressionQuality : @0.9};
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
        BOOL ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        if (ok)
            return heicURL;
    }

    NSURL *jpgURL = [NSURL fileURLWithPath:[tmp stringByAppendingPathComponent:[basename stringByAppendingPathExtension:@"jpg"]]];
    NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:image], 0.85);
    if (data && [data writeToURL:jpgURL atomically:YES])
        return jpgURL;
    return nil;
}

@implementation SPKTrimRenderer

#pragma mark - Trim

+ (void)renderTrimForSourceURL:(NSURL *)sourceURL
                         asset:(AVAsset *)asset
                  startSeconds:(NSTimeInterval)startSeconds
               durationSeconds:(NSTimeInterval)durationSeconds
                          crop:(SPKTrimCrop *)crop
                      basename:(NSString *)basename
                      progress:(SPKTrimRenderProgressBlock)progress
                    completion:(SPKTrimRenderCompletionBlock)completion
                     cancelOut:(void (^)(dispatch_block_t))cancelOut {
    if (crop.isIdentity)
        crop = nil;
    CGSize oriented = SPKTrimOrientedSize(asset ?: [AVURLAsset URLAssetWithURL:sourceURL options:nil]);
    NSString *cropFilter = [crop ffmpegFilterForOrientedSize:oriented];
    CGRect cropPixels = crop ? [crop pixelRectForOrientedSize:oriented] : CGRectZero;

    if ([SPKMediaFFmpeg isAvailable]) {
        [SPKMediaFFmpeg trimVideoFileURL:sourceURL
            startSeconds:startSeconds
            durationSeconds:durationSeconds
            cropFilter:cropFilter
            croppedSize:cropPixels.size
            preferredBasename:basename
            progress:^(double p, NSString *stage) {
                if (progress)
                    progress(p);
            }
            completion:^(NSURL *outputURL, NSError *error) {
                // FFmpegKit delivers its completion on a
                // background thread; the caller (editor) does
                // UIKit work, so hop to main.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion)
                        completion(outputURL, error);
                });
            }
            cancelOut:cancelOut];
        return;
    }
    [self exportTrimWithAVFoundationForSourceURL:sourceURL
                                           asset:asset
                                    startSeconds:startSeconds
                                 durationSeconds:durationSeconds
                                            crop:crop
                                        basename:basename
                                      completion:completion];
}

// AVFoundation fallback for builds without the FFmpeg frameworks (e.g. some
// sideload configs). AVAssetExportSession re-encodes and is frame-accurate.
+ (void)exportTrimWithAVFoundationForSourceURL:(NSURL *)sourceURL
                                         asset:(AVAsset *)asset
                                  startSeconds:(NSTimeInterval)startSeconds
                               durationSeconds:(NSTimeInterval)durationSeconds
                                          crop:(SPKTrimCrop *)crop
                                      basename:(NSString *)basename
                                    completion:(SPKTrimRenderCompletionBlock)completion {
    AVAsset *workingAsset = asset ?: [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:workingAsset
                                                                    presetName:AVAssetExportPresetHighestQuality];
    if (!export) {
        if (completion)
            completion(nil, SPKTrimRendererError(SPKL(@"MEDIA_TRIM_TRIM_RENDERER_TRIMMING_NOT_AVAILABLE_VIDEO_TEXT")));
        return;
    }

    NSURL *output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[basename stringByAppendingPathExtension:@"mp4"]]];
    [[NSFileManager defaultManager] removeItemAtURL:output error:nil];

    CMTime start = CMTimeMakeWithSeconds(startSeconds, 600);
    CMTime duration = CMTimeMakeWithSeconds(durationSeconds, 600);
    export.outputURL = output;
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    export.timeRange = CMTimeRangeMake(start, duration);
    if (crop && !crop.isIdentity) {
        AVVideoComposition *composition = SPKTrimCropComposition(workingAsset, crop);
        if (composition)
            export.videoComposition = composition;
    }

    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (export.status == AVAssetExportSessionStatusCompleted) {
                if (completion)
                    completion(output, nil);
            } else {
                NSString *desc = export.error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_RENDERER_TRIM_COULD_NOT_COMPLETED_TEXT");
                if (completion)
                    completion(nil, SPKTrimRendererError(desc));
            }
        });
    }];
}

#pragma mark - Trim + merge (DASH)

+ (void)renderTrimMergeForVideoURL:(NSURL *)videoURL
                          audioURL:(NSURL *)audioURL
                      startSeconds:(NSTimeInterval)startSeconds
                   durationSeconds:(NSTimeInterval)durationSeconds
                              crop:(SPKTrimCrop *)crop
                             width:(NSInteger)width
                            height:(NSInteger)height
                          basename:(NSString *)basename
                          progress:(SPKTrimRenderProgressBlock)progress
                        completion:(SPKTrimRenderCompletionBlock)completion
                         cancelOut:(void (^)(dispatch_block_t))cancelOut {
    if (![SPKMediaFFmpeg isAvailable]) {
        if (completion)
            completion(nil, SPKTrimRendererError(SPKL(@"MEDIA_TRIM_TRIM_RENDERER_FFMPEG_REQUIRED_MERGE_QUALITY_TEXT")));
        return;
    }
    NSString *cropFilter = nil;
    if (crop && !crop.isIdentity) {
        CGSize oriented = (width > 0 && height > 0)
                              ? CGSizeMake(width, height)
                              : SPKTrimOrientedSize([AVURLAsset URLAssetWithURL:videoURL options:nil]);
        cropFilter = [crop ffmpegFilterForOrientedSize:oriented];
        CGRect pixels = [crop pixelRectForOrientedSize:oriented];
        width = (NSInteger)lround(pixels.size.width);
        height = (NSInteger)lround(pixels.size.height);
    }
    [SPKMediaFFmpeg trimMergeVideoURL:videoURL
        audioURL:audioURL
        startSeconds:startSeconds
        durationSeconds:durationSeconds
        cropFilter:cropFilter
        preferredBasename:basename
        width:width
        height:height
        progress:^(double p, NSString *stage) {
            if (progress)
                progress(p);
        }
        completion:^(NSURL *outputURL, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion)
                    completion(outputURL, error);
            });
        }
        cancelOut:cancelOut];
}

#pragma mark - Audio

+ (void)renderTrimAudioForSourceURL:(NSURL *)sourceURL
                              asset:(AVAsset *)asset
                       startSeconds:(NSTimeInterval)startSeconds
                    durationSeconds:(NSTimeInterval)durationSeconds
                           basename:(NSString *)basename
                         completion:(SPKTrimRenderCompletionBlock)completion {
    AVAsset *workingAsset = asset ?: [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:workingAsset
                                                                    presetName:AVAssetExportPresetAppleM4A];
    if (!export) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(nil, SPKTrimRendererError(SPKL(@"MEDIA_TRIM_TRIM_RENDERER_TRIMMING_NOT_AVAILABLE_AUDIO_TEXT")));
        });
        return;
    }

    NSURL *output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[basename stringByAppendingPathExtension:@"m4a"]]];
    [[NSFileManager defaultManager] removeItemAtURL:output error:nil];

    CMTime start = CMTimeMakeWithSeconds(startSeconds, 600);
    CMTime duration = CMTimeMakeWithSeconds(durationSeconds, 600);
    export.outputURL = output;
    export.outputFileType = AVFileTypeAppleM4A;
    export.timeRange = CMTimeRangeMake(start, duration);

    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (export.status == AVAssetExportSessionStatusCompleted) {
                if (completion)
                    completion(output, nil);
            } else {
                NSString *desc = export.error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_RENDERER_AUDIO_TRIM_COULD_NOT_COMPLETED_TEXT");
                if (completion)
                    completion(nil, SPKTrimRendererError(desc));
            }
        });
    }];
}

#pragma mark - Frame

+ (void)renderFrameForAsset:(AVAsset *)asset
                  atSeconds:(NSTimeInterval)seconds
                   basename:(NSString *)basename
                 completion:(SPKTrimRenderCompletionBlock)completion {
    // Load tracks + duration up front. DASH video representations downloaded as
    // standalone fragmented MP4s expose unreliable timing until their metadata
    // is loaded, which is a common cause of AVAssetImageGenerator failing on
    // them. With the duration known we can also clamp the requested time so a
    // playhead parked at the very end doesn't ask for a frame past EOF.
    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                         completionHandler:^{
                             NSTimeInterval clamped = seconds;
                             NSError *durationError = nil;
                             if ([asset statusOfValueForKey:@"duration" error:&durationError] == AVKeyValueStatusLoaded) {
                                 NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
                                 if (duration > 0 && clamped > duration - 0.05) {
                                     clamped = MAX(0.0, duration - 0.05);
                                 }
                             }
                             if (clamped < 0)
                                 clamped = 0;
                             [self generateFrameForAsset:asset
                                               atSeconds:clamped
                                                basename:basename
                                          allowTolerance:NO
                                              completion:completion];
                         }];
}

+ (void)renderFrameForVideoURL:(NSURL *)videoURL
                     atSeconds:(NSTimeInterval)seconds
                      basename:(NSString *)basename
                    completion:(SPKTrimRenderCompletionBlock)completion {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    [self renderFrameForAsset:asset
                    atSeconds:seconds
                     basename:basename
                   completion:^(NSURL *output, NSError *error) {
                       if (output || !videoURL.isFileURL || ![SPKMediaFFmpeg isAvailable]) {
                           if (completion)
                               completion(output, error);
                           return;
                       }
                       SPKLog(@"Trim", @"[Sparkle] AVFoundation frame extraction failed (%@), retrying with FFmpeg", error.localizedDescription);
                       [SPKMediaFFmpeg extractFrameFromVideoFileURL:videoURL
                                                          atSeconds:seconds
                                                  preferredBasename:basename
                                                         completion:^(NSURL *pngURL, NSError *ffmpegError) {
                                                             // Re-encode through the same writer so the
                                                             // still lands as HEIC like every other frame.
                                                             NSURL *frameURL = nil;
                                                             CGImageSourceRef source = pngURL ? CGImageSourceCreateWithURL((__bridge CFURLRef)pngURL, NULL) : NULL;
                                                             if (source) {
                                                                 CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                                                                 frameURL = SPKTrimWriteCGImage(image, basename);
                                                                 if (image)
                                                                     CGImageRelease(image);
                                                                 CFRelease(source);
                                                             }
                                                             if (pngURL)
                                                                 [[NSFileManager defaultManager] removeItemAtURL:pngURL error:nil];
                                                             dispatch_async(dispatch_get_main_queue(), ^{
                                                                 if (completion)
                                                                     completion(frameURL, frameURL ? nil : (ffmpegError ?: error));
                                                             });
                                                         }];
                   }];
}

// Photo only attempt. We first try an exact (zero-tolerance) extraction; on
// failure we retry once with a generous tolerance so AVFoundation can settle on
// the nearest decodable frame instead of giving up — exactness is irrelevant for
// a still, and zero tolerance is the usual reason DASH-derived clips fail here.
+ (void)generateFrameForAsset:(AVAsset *)asset
                    atSeconds:(NSTimeInterval)seconds
                     basename:(NSString *)basename
               allowTolerance:(BOOL)allowTolerance
                   completion:(SPKTrimRenderCompletionBlock)completion {
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    CMTime tolerance = allowTolerance ? CMTimeMakeWithSeconds(0.5, 600) : kCMTimeZero;
    generator.requestedTimeToleranceBefore = tolerance;
    generator.requestedTimeToleranceAfter = tolerance;

    CMTime cm = CMTimeMakeWithSeconds(seconds, 600);
    [generator generateCGImagesAsynchronouslyForTimes:@[ [NSValue valueWithCMTime:cm] ]
                                    completionHandler:^(CMTime requestedTime, CGImageRef _Nullable image,
                                                        CMTime actualTime, AVAssetImageGeneratorResult result,
                                                        NSError *_Nullable error) {
                                        NSURL *output = (result == AVAssetImageGeneratorSucceeded) ? SPKTrimWriteCGImage(image, basename) : nil;
                                        if (!output && result != AVAssetImageGeneratorCancelled && !allowTolerance) {
                                            // Exact extraction failed — retry once at the nearest decodable frame.
                                            [self generateFrameForAsset:asset
                                                              atSeconds:seconds
                                                               basename:basename
                                                         allowTolerance:YES
                                                             completion:completion];
                                            return;
                                        }
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            if (output) {
                                                if (completion)
                                                    completion(output, nil);
                                            } else {
                                                if (completion)
                                                    completion(nil, SPKTrimRendererError(SPKL(@"MEDIA_TRIM_TRIM_RENDERER_COULD_NOT_EXTRACT_SELECTED_FRAME_TEXT")));
                                            }
                                        });
                                    }];
}

@end
