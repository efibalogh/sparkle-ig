#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPKDirectThreadContext : NSObject
@property (nonatomic, copy, nullable) NSString *threadId;
@property (nonatomic, copy, nullable) NSString *threadName;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, copy) NSArray<NSDictionary *> *users;
@property (nonatomic, copy, nullable) NSString *groupPhotoUrl;
@end

#ifdef __cplusplus
extern "C" {
#endif

SPKDirectThreadContext *_Nullable SPKDirectThreadContextFromSource(id _Nullable source);
SPKDirectThreadContext *_Nullable SPKDirectThreadContextFromInboxViewModel(id _Nullable viewModel);
NSDictionary *_Nullable SPKDirectThreadEntryFromContext(SPKDirectThreadContext *_Nullable context);

/// Human-readable name for a thread: its own title, else the participants' names, else
/// nil. Callers own the "no name at all" fallback, since it reads differently in a list
/// row ("Unknown Chat") than in a sentence ("this chat"). Both DM thread lists and every
/// current-thread prompt name threads through here so they can never disagree.
NSString *_Nullable SPKDirectDisplayNameForThreadEntry(NSDictionary *_Nullable entry);

/// Handle-first name for a thread: "@username" for a 1:1, the group's own title for a
/// group. Sparkle's lists render handles, so anything else in Sparkle's UI that names a
/// chat uses this rather than switching to display names halfway through a flow.
NSString *_Nullable SPKDirectHandleNameForThreadEntry(NSDictionary *_Nullable entry);
NSString *_Nullable SPKDirectHandleNameForThreadContext(SPKDirectThreadContext *_Nullable context);
NSString *_Nullable SPKDirectDisplayNameForThreadContext(SPKDirectThreadContext *_Nullable context);

/// Row-tap behaviour shared by every DM thread list: a 1:1 opens the partner's profile,
/// a group does nothing (it has no single profile to open, and its name is not a handle).
void SPKDirectOpenProfileForThreadEntry(NSDictionary *_Nullable entry);

/// "N participants" for a group thread; nil for a 1:1 or when the roster is unknown.
/// Instagram's stored roster excludes the current user, so the count adds you back.
NSString *_Nullable SPKDirectParticipantSubtitleForThreadEntry(NSDictionary *_Nullable entry);

void SPKDirectSetActiveThreadContext(SPKDirectThreadContext *_Nullable context);
SPKDirectThreadContext *_Nullable SPKDirectActiveThreadContext(void);

NSArray<NSDictionary *> *SPKDirectManualSeenThreadList(BOOL manualSeenEnabled);
void SPKDirectSetManualSeenThreadList(NSArray<NSDictionary *> *threads, BOOL manualSeenEnabled);
BOOL SPKDirectManualSeenListContainsThreadId(NSString *_Nullable threadId, BOOL manualSeenEnabled);
void SPKDirectAddOrUpdateManualSeenThreadEntry(NSDictionary *entry, BOOL manualSeenEnabled);
void SPKDirectRemoveManualSeenThreadId(NSString *threadId, BOOL manualSeenEnabled);
NSString *SPKDirectManualSeenListTitle(BOOL manualSeenEnabled);
NSUInteger SPKDirectManualSeenThreadCount(BOOL manualSeenEnabled);
UIViewController *SPKDirectManualSeenListViewController(void);
NSDictionary *_Nullable SPKDirectManualSeenThreadEntryForUserPK(NSString *_Nullable pk, BOOL manualSeenEnabled);

BOOL SPKDirectManualSeenAppliesToSource(id _Nullable source);
BOOL SPKDirectShouldShowSeenButtonForSource(id _Nullable source);
NSString *_Nullable SPKDirectCurrentThreadRuleActionTitle(SPKDirectThreadContext *_Nullable context);
NSString *_Nullable SPKDirectCurrentThreadRuleConfirmationTitle(SPKDirectThreadContext *_Nullable context);
NSString *_Nullable SPKDirectCurrentThreadRuleConfirmationMessage(SPKDirectThreadContext *_Nullable context);
BOOL SPKDirectToggleCurrentThreadRule(SPKDirectThreadContext *_Nullable context, NSString *_Nullable *_Nullable notificationTitle, NSString *_Nullable *_Nullable notificationSubtitle);

extern BOOL SPKDirectSeenDebugPrintEnabled;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
