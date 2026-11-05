#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What a story or highlight link points at.
///
///   /s/<base64("highlight:<id>")>/?story_media_id=<pk>   highlight, optional story
///   /stories/highlights/<id>/                            highlight
///   /stories/<username>/<pk>/                            an account's live story
///
/// A live-story link names the account by username only, so `reelPK` is nil for
/// it until the caller supplies the account's PK (a live reel's PK is its owner's).
@interface SPKStoryLink : NSObject
@property (nonatomic, copy, readonly, nullable) NSString *reelPK;
@property (nonatomic, copy, readonly, nullable) NSString *username;
@property (nonatomic, copy, readonly, nullable) NSString *mediaPK;
@property (nonatomic, readonly) BOOL isHighlight;
+ (nullable instancetype)linkWithURL:(nullable NSURL *)url;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Opens Instagram's story viewer on a reel, presented over `source`, without
/// routing through the app's URL handler. The reel does not have to be loaded:
/// Instagram fetches its items first. `mediaPK` picks the story to start on.
/// Returns NO when the viewer could not be requested at all; a reel that turns
/// out to be empty or expired is Instagram's to report.
BOOL SPKStoryOpenReel(NSString *reelPK, NSString *_Nullable mediaPK, UIViewController *source);

/// Finds the highlight on `userPK`'s profile that contains the story `mediaPK`,
/// for a story that outlived its 24 hours by being added to one. The account's
/// profile must be on screen: the highlight list is read from what Instagram
/// loaded for it, and the highlights not yet loaded are loaded through
/// Instagram's own data controller, three at a time, so no request is built
/// here. Still for an explicit user action only. `completion` runs on the main
/// queue with the highlight's reel PK, or nil when none holds the story.
/// `searched` is NO when the list or a load never arrived, so a nil result then
/// says nothing about whether the story is in a highlight.
void SPKStoryFindHighlightContainingMedia(NSString *userPK, NSString *mediaPK, void (^completion)(NSString *_Nullable reelPK, BOOL searched));

/// When a story was posted, read from its media PK (the PK's high bits are a
/// millisecond timestamp). Nil when the PK is not a plain number.
NSDate *_Nullable SPKStoryPostedDateForMediaPK(NSString *_Nullable mediaPK);

/// YES once a story is past the 24 hours it stays on its account's live reel.
/// Unknown ages count as still live.
BOOL SPKStoryMediaIsPastLiveWindow(NSString *_Nullable mediaPK);

/// The controller a viewer should be presented from over `presenter`: the top of
/// whatever is presented on it (a profile pushed over it), or `presenter` itself.
UIViewController *SPKStoryPresentationSourceOver(UIViewController *presenter);

/// Opens a story that has left its account's live reel, if a highlight still
/// holds it. The account's profile must already be on screen over `presenter`.
/// Shows the search pill, opens the viewer on a hit, and on a miss shows the
/// "not in a highlight" toast and remembers the miss for a week so the search is
/// not repeated. `completion` gets the highlight's reel PK on a hit, else nil.
void SPKStoryOpenExpiredStory(NSString *userPK, NSString *mediaPK, UIViewController *presenter, void (^_Nullable completion)(NSString *_Nullable highlightPK));

/// The name the account gave a highlight, once Instagram has loaded it.
NSString *_Nullable SPKStoryTitleForReelPK(NSString *reelPK);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
