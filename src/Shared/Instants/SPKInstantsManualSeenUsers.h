#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SPKAutoSaveFilterConfig;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Who Manually Mark Seen applies to, keyed by author pk.
///
/// The mode follows the Manually Mark Seen switch, the same way the stories list does:
/// with the switch on every author is held unseen except the Excluded Users, and with it
/// off only the Included Users are. Keyed by pk because a snap's media PK already ends in
/// its author's pk (`<mediaId>_<userPK>`), so the check needs no model read at all.
SPKAutoSaveFilterConfig *SPKInstantsManualSeenUsersConfig(void);

/// The Manually Mark Seen switch. YES means the list holds exclusions.
BOOL SPKInstantsManualSeenAllUsersMode(void);
/// YES when the switch is on and nobody is excluded, the case where every seen mark can be
/// blocked wholesale.
BOOL SPKInstantsManualSeenCoversEveryone(void);
/// Entries in the list for the current mode.
NSUInteger SPKInstantsManualSeenUserCount(void);
/// Resolves mode and list for one author. A nil pk counts as an unlisted author.
BOOL SPKInstantsManualSeenAppliesToAuthorPK(NSString *_Nullable authorPK);

typedef BOOL (^SPKInstantsManualSeenAuthorTest)(NSString *_Nullable authorPK);
/// Same answer as `SPKInstantsManualSeenAppliesToAuthorPK`, with mode and list read once, for
/// loops that check many snaps in one pass.
SPKInstantsManualSeenAuthorTest SPKInstantsManualSeenMakeAuthorTest(void);

/// The action menu only knows the author's username (read off the label), so these match list
/// entries by username, which every entry stores beside its pk.
BOOL SPKInstantsManualSeenAppliesToUsername(NSString *_Nullable username);
/// "Start Marking Instants Seen" while the author is held, "Stop Marking Instants Seen" while
/// they are not. Nil without a username, which hides the action.
NSString *_Nullable SPKInstantsManualSeenActionTitleForUsername(NSString *_Nullable username);
NSString *_Nullable SPKInstantsManualSeenConfirmationMessageForUsername(NSString *_Nullable username);
/// Flips the author between held and not held by adding or removing their list entry. Adding
/// needs the pk: taken from the service announcements when known, otherwise looked up, which
/// is why this completes asynchronously. Always completes on the main queue.
void SPKInstantsToggleManualSeenForUsername(NSString *_Nullable username,
                                            void (^completion)(BOOL ok, NSString *_Nullable title, NSString *_Nullable subtitle));

NSString *SPKInstantsManualSeenListTitle(void);
UIViewController *SPKInstantsManualSeenListViewController(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
