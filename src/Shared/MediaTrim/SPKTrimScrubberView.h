#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SPKTrimScrubberView;

@protocol SPKTrimScrubberViewDelegate <NSObject>
@optional
/// Fired when the user first touches a handle or the track.
- (void)trimScrubberDidBeginInteraction:(SPKTrimScrubberView *)scrubber;
/// Selection start (in) moved. `startTime` is seconds on the source timeline.
- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didChangeStartTime:(NSTimeInterval)startTime;
/// Selection end (out) moved.
- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didChangeEndTime:(NSTimeInterval)endTime;
/// Playhead (or single-frame marker) scrubbed to `time`.
- (void)trimScrubber:(SPKTrimScrubberView *)scrubber didScrubToTime:(NSTimeInterval)time;
/// Fired when the active touch ends.
- (void)trimScrubberDidEndInteraction:(SPKTrimScrubberView *)scrubber;
@end

/// Photos-style trim bar: a filmstrip of thumbnails with two draggable in/out
/// handles, a dimmed region outside the selection, and a draggable playhead.
/// Dragging inside the selection slides it along the clip, and dragging away
/// from the track vertically slows every drag down for fine placement. A pinch
/// zooms the track in on part of the clip, and the handle being moved shows its
/// exact time above it. Toggling `frameOnlyMode` collapses the UI to a
/// frame-picker marker.
@interface SPKTrimScrubberView : UIView

@property (nonatomic, weak) id<SPKTrimScrubberViewDelegate> delegate;

/// Total asset duration in seconds. Set once the asset is loaded.
@property (nonatomic, assign) NSTimeInterval duration;
/// Shortest selectable clip in seconds.
@property (nonatomic, assign) NSTimeInterval minimumDuration;
/// Longest selectable clip in seconds; 0 means no ceiling. Dragging a handle past
/// it pushes the opposite handle along instead of widening the selection, so the
/// window slides rather than growing.
@property (nonatomic, assign) NSTimeInterval maximumDuration;

@property (nonatomic, assign, readonly) NSTimeInterval startTime;
@property (nonatomic, assign, readonly) NSTimeInterval endTime;

/// Moves the playhead indicator without notifying the delegate. Use to reflect
/// playback position. In frame only mode this is the picked frame time.
@property (nonatomic, assign) NSTimeInterval playheadTime;

/// When YES, hides the in/out handles and shows a frame-picker marker.
@property (nonatomic, assign, getter=isFrameOnlyMode) BOOL frameOnlyMode;

/// When YES, the track renders an audio waveform instead of a video filmstrip.
/// Set implicitly by `loadWaveformForAsset:`. Frame only mode is not used with
/// audio.
@property (nonatomic, assign, getter=isWaveformMode) BOOL waveformMode;

/// Convenience: the frame time when in frame only mode (== playheadTime).
@property (nonatomic, assign, readonly) NSTimeInterval frameTime;

/// Kicks off async thumbnail generation for the filmstrip.
- (void)loadThumbnailsForAsset:(AVAsset *)asset;

/// Kicks off async waveform sampling for the audio track and switches the track
/// into waveform mode. Use instead of `loadThumbnailsForAsset:` for audio.
- (void)loadWaveformForAsset:(AVAsset *)asset;

/// Moves whatever was last dragged (the in point, the out point, or the
/// playhead / frame marker) by `delta` seconds, with the same limits as a drag,
/// and tells the delegate. The playhead is the default target.
- (void)stepActiveTargetBy:(NSTimeInterval)delta;

/// Sets both handles at once (e.g. to initialize the full range).
- (void)setStartTime:(NSTimeInterval)start endTime:(NSTimeInterval)end;

@end

NS_ASSUME_NONNULL_END
