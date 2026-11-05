#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPKStoryContext : NSObject
@property (nonatomic, weak, nullable) UIView *overlayView;
@property (nonatomic, weak, nullable) UIViewController *viewerController;
@property (nonatomic, strong, nullable) id sectionController;
@property (nonatomic, strong, nullable) id markSeenTarget;
@property (nonatomic, strong, nullable) id media;
@property (nonatomic, strong, nullable) NSArray *allMedia;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *fullName;
@property (nonatomic, strong, nullable) NSURL *storyURL;
@end

#ifdef __cplusplus
extern "C" {
#endif

void SPKStorySetActiveOverlay(UIView *_Nullable overlayView);
UIView *_Nullable SPKStoryActiveOverlay(void);
SPKStoryContext *_Nullable SPKStoryContextFromOverlay(UIView *_Nullable overlayView);
SPKStoryContext *_Nullable SPKStoryContextFromView(UIView *_Nullable view);
SPKStoryContext *_Nullable SPKStoryContextFromMedia(id _Nullable media);
BOOL SPKStoryMarkContextAsSeen(SPKStoryContext *_Nullable context);
void SPKStoryAdvanceContextIfNeeded(SPKStoryContext *_Nullable context, NSString *_Nullable advancePrefKey);

NSString *_Nullable SPKStoryUsernameForContext(SPKStoryContext *_Nullable context);
NSString *_Nullable SPKStoryFullNameForContext(SPKStoryContext *_Nullable context);
NSURL *_Nullable SPKStoryURLForContext(SPKStoryContext *_Nullable context);
/// The reel the viewer is showing: a user PK for a live story, "highlight:<id>"
/// for a highlight, "archiveDay:<id>" for the archive.
NSString *_Nullable SPKStoryReelPKForContext(SPKStoryContext *_Nullable context);
BOOL SPKStoryReelPKIsHighlight(NSString *_Nullable reelPK);
/// Instagram's own share link for a highlight, optionally pinned to one story.
NSURL *_Nullable SPKStoryHighlightURLForReelPK(NSString *_Nullable reelPK, NSString *_Nullable mediaPK);
NSString *_Nullable SPKStoryMediaIdentifierForContext(SPKStoryContext *_Nullable context);

BOOL SPKStoryManualSeenAppliesToContext(SPKStoryContext *_Nullable context);
/// Manually Mark Seen is on in either the tap or the toggle mode.
BOOL SPKStoryManualSeenEnabled(void);
BOOL SPKStoryEyeButtonTogglesSeenReceipts(void);
BOOL SPKStorySeenReceiptsSessionEnabled(void);
/// Starts a seen-receipts session scoped to `viewer`, or ends it when nil.
void SPKStorySetSeenReceiptsSessionViewer(UIViewController *_Nullable viewer);
/// Ends the session if `viewer` owns it.
void SPKStoryEndSeenReceiptsSessionForViewer(UIViewController *viewer);
NSArray *SPKStoryManualSeenUserList(BOOL manualSeenEnabled);
void SPKStorySetManualSeenUserList(NSArray *users, BOOL manualSeenEnabled);
BOOL SPKStoryManualSeenListContainsUser(NSString *_Nullable pk, BOOL manualSeenEnabled);
NSString *_Nullable SPKStoryUserPKFromMediaObject(id _Nullable media);
NSString *SPKStoryManualSeenListTitle(BOOL manualSeenEnabled);
UIViewController *SPKStoryManualSeenListViewController(void);
NSString *_Nullable SPKStoryCurrentUserRuleActionTitle(SPKStoryContext *_Nullable context);
NSString *_Nullable SPKStoryCurrentUserRuleConfirmationTitle(SPKStoryContext *_Nullable context);
NSString *_Nullable SPKStoryCurrentUserRuleConfirmationMessage(SPKStoryContext *_Nullable context);
BOOL SPKStoryToggleCurrentUserRule(SPKStoryContext *_Nullable context, NSString *_Nullable *_Nullable notificationTitle, NSString *_Nullable *_Nullable notificationSubtitle);
void SPKStoryToggleUserRuleForPK(NSString *pk, NSString *username, NSString *_Nullable fullName, NSString *_Nullable profilePicUrl);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
