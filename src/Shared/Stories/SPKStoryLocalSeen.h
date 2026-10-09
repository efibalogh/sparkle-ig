#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Keep Seen Locally is on and Manually Mark Seen is active.
BOOL SPKStoryLocalSeenEnabled(void);

/// Marks `item` seen in Instagram's own seen state only, for a story whose seen
/// receipt was just blocked. `viewer` is the story viewer, `sectionController`
/// the story's fullscreen section controller.
void SPKStoryLocalSeenMarkItem(id _Nullable viewer, id _Nullable sectionController, id _Nullable item);

/// Records that `item` was really marked seen (eye button or a receipts
/// session), so Reset Local Seen leaves it seen.
void SPKStoryLocalSeenNoteItemSent(id _Nullable viewer, id _Nullable sectionController, id _Nullable item);

/// People the current account has seen stories from locally.
NSUInteger SPKStoryLocalSeenUserCount(void);

/// Lists those people with how many of their stories are seen locally. Swiping a
/// person or the trash button makes their stories unseen again.
UIViewController *SPKStoryLocalSeenListViewController(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
