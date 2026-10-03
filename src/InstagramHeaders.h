#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#include <objc/NSObject.h>

#ifdef __cplusplus
#define _Bool bool
#endif

@class IGMainAppSurfaceIntent;

@interface NSURL ()
- (id)normalizedURL; // method provided by Instagram app
@end

@interface IGActionableConfirmationToastViewModel : NSObject
- (id)identifier;
@end

// Sparkle renders this view itself, in its own notification window, for the
// Instagram notification style. The model is filled through KVC (see
// SPKNotificationPillView): 410 has no factory for the case it uses.
@interface IGActionableConfirmationToastView : UIView
- (void)configureWithViewModel:(id)model;
@end

@interface IGActionableConfirmationToastPresenter : NSObject
- (void)_showAlertWithViewModel:(id)model presentationContext:(id)context isAnimated:(_Bool)animated animationDuration:(double)duration presentationPriority:(long long)priority origin:(unsigned long long)origin toastType:(unsigned long long)type tapActionBlock:(id)tap tapToastBlock:(id)tapToast presentedHandler:(id)presented dismissedHandler:(id)dismissed;
- (void)hideAlert;
@end

@interface IGSundialViewerInteractionCoordinator : NSObject
- (void)presentAudioUnavailableToastFor:(id)media;
@end

@interface _TtC30IGStorySectionAudioCoordinator30IGStorySectionAudioCoordinator : NSObject
- (void)showAudioUnavailableToast;
@end

@interface IGRootViewController : UIViewController
- (IGActionableConfirmationToastPresenter *)toastPresenter;

- (void)addHandleLongPress;                                     // new
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender; // new
@end

@interface IGViewController : UIViewController
- (void)_superPresentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(id)completion;
@end

@interface IGDSDefaultPartialModalSheetViewController : UIViewController
- (void)_didPan:(UIPanGestureRecognizer *)pan; // target of _verticalPanGesture
- (BOOL)disablePanToClose;
- (BOOL)disableVerticalPan;
@end

@interface IGMainFeedAppHeaderController : UIViewController
- (void)_superPresentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(id)completion; // new
@end

@interface IGShimmeringGridView : UIView
@end

@interface IGExploreGridViewController : IGViewController
- (void)spk_updateExploreGridVisibility;
@end

@interface IGExploreViewController : IGViewController
- (void)spk_updateExploreShimmerVisibility;
@end

@interface UIImage ()
- (NSString *)ig_imageName;
@end

// Built only by ivar injection -- see SPKUtils spk_userReferenceForUser:. The
// factory methods you would expect (+user:, +username:, ...) are Swift-only and
// throw "unrecognized selector sent to class", so they are deliberately absent.
@interface IGUserReference : NSObject
- (nullable NSString *)pk;
- (nullable NSString *)username;
- (nullable id)user;
@end

@interface IGURLHandler : NSObject
+ (BOOL)openInternalURL:(id)url presentationConfig:(nullable id)config controller:(nullable id)controller animated:(BOOL)animated userSession:(id)session annotation:(nullable id)annotation;
+ (void)openURL:(id)url userSession:(id)session completionHandler:(nullable id /* block */)handler;
@end

@interface IGProfileConfig : NSObject
- (instancetype)initWithUserReference:(id)userReference userSession:(id)userSession previousAnalyticsModule:(nullable NSString *)module;
- (instancetype)initWithUserReference:(id)userReference userSession:(id)userSession;
@end

@interface IGProfileViewController : UIViewController
- (instancetype)initWithConfiguration:(id)configuration accountSwitcherPresenter:(nullable id)presenter isMainProfileSurface:(BOOL)isMainProfileSurface;
- (nullable id)user;
// TabManager category. Page identifiers are NSNumber profile tab types.
- (nullable id)dynamicPageViewController:(id)pageController viewControllerForPageWithIdentifier:(id)identifier;
- (BOOL)dynamicPageViewController:(id)pageController canDisplayPlaceholderViewForPageWithIdentifier:(id)identifier;
- (void)_tabControlValueChanged:(id)control;
@end

// Profile tab strip on builds without the Swift tabs plugin (410).
@interface IGSegmentedTabControl : UIControl
@property (copy, nonatomic) NSArray *segments;
@property (nonatomic) long long selectedIndex;
@property (weak, nonatomic) id delegate;
@end

@interface IGDynamicPageViewController : UIViewController
@property (weak, nonatomic) id dataSource;
@property (readonly, nonatomic) UICollectionView *collectionView;
- (NSArray *)objectsForListAdapter:(id)listAdapter;
@end

// Owner collections config for the Saved page (same initializer on 410 and 446+).
@interface IGSavedMediaCollectionsOwnerDataSourceConfiguration : NSObject
- (instancetype)initWithUser:(id)user andLauncherSet:(id)launcherSet showOnlyPublicCollections:(BOOL)showOnlyPublicCollections;
@end

// Instagram's Saved collections page. Still conforms to IGProfileTabViewController.
// The first initializer is 446+, the second is 410.
@interface IGSavedMediaCollectionsViewController : IGViewController
@property (nonatomic, weak) id profileTabDelegate;
- (instancetype)initWithUserSession:(id)userSession
            dataSourceConfiguration:(id)configuration
                preferredEdgeInsets:(nullable id)preferredEdgeInsets
                 disableFeedPreview:(BOOL)disableFeedPreview
                               type:(unsigned long long)type;
- (instancetype)initWithUserSession:(id)userSession
            dataSourceConfiguration:(id)configuration
               enableAddPlaceholder:(BOOL)enableAddPlaceholder
                        entryModule:(nullable id)entryModule
                preferredEdgeInsets:(nullable id)preferredEdgeInsets
                 disableFeedPreview:(BOOL)disableFeedPreview
                               type:(unsigned long long)type;
- (void)updateContentInsets;
- (void)viewDidLayoutSubviews;
- (nullable UIScrollView *)scrollView;
- (void)setRefreshControlBackgroundColor:(id)color;
@end

@interface IGProfileMenuSheetViewController : IGViewController
@end

@interface IGTabBar : UIView
- (instancetype)initWithFrame:(CGRect)frame
                defaultConfig:(id)defaultConfig
              immersiveConfig:(id)immersiveConfig
               backgroundView:(id)backgroundView
                  launcherSet:(id)launcherSet;
@end

@interface IGLiquidGlassInteractiveTabBar : UIView
- (instancetype)initWithFrame:(CGRect)frame;
- (void)setConfig:(id)config;
- (void)setImmersiveConfig:(id)config;
@end

@interface IGTabBarControllerSwipeCoordinator : NSObject
@end

// Mirrors Instagram's IGTabBarViewRepresentable. Every bar implementation (the
// classic IGTabBar, IGNativeTabBar and the iOS 26 Liquid Glass bar) conforms to
// it, so the tab bar view can be driven without caring which one is installed.
@protocol SPKTabBarViewRepresentable <NSObject>
@property (readonly, nonatomic) NSArray *buttons;
- (void)addTabButton:(id)button;
- (void)clearTabButtons;
- (void)setSelectedTabBarItemIndex:(NSInteger)index;
@end

@interface IGTabBarController : UIViewController
@property (readonly, nonatomic) UIView *tabBar;
- (id)_buttonForTabBarSurface:(id)surface;
- (IGMainAppSurfaceIntent *)selectedTabBarSurface;
@property (readonly, nonatomic) UIViewController *selectedViewController;
- (NSInteger)tabBarStyle;
- (void)_createAndConfigureReelsButtonIfNeeded;
- (void)_timelineButtonPressed;
- (void)_discoverVideoButtonPressed;
- (void)_directInboxButtonPressed;
- (void)_exploreButtonPressed;
- (void)_profileButtonPressed;
- (UINavigationController *)discoverVideoNavigationController;
- (UINavigationController *)navigationViewControllerForAppSurfaceIntent:(IGMainAppSurfaceIntent *)intent;
- (void)setSelectedTabBarSurface:(IGMainAppSurfaceIntent *)surface animated:(BOOL)animated;
- (void)_exploreButtonLongPressed:(id)gesture;
- (void)_updateTabBarVisibilityForController:(id)controller;
@end

@interface IGTabBarViewControllerManager : NSObject
@property (readonly, nonatomic) UINavigationController *savedCollectionsNavigationController;
@end

@interface IGSaveHomeIntentTarget : NSObject
- (instancetype)initWithEntryModule:(NSString *)entryModule;
- (instancetype)initWithEntryModule:(NSString *)entryModule selectedTab:(nullable NSString *)selectedTab;
@end

@protocol FBIntentHandler <NSObject>
- (void)handleIntent:(id)intent;
@end

@interface UIViewController (FBIntentNavigation)
- (id<FBIntentHandler>)fb_intentHandler;
@end

@interface IGMainAppScrollingContainerViewController : UIViewController
@end

@interface IGDirectInboxNavigationHeaderView : UIView
@property (readonly, nonatomic) UIButton *messageButton;
// v410's legacy Obj-C header additionally exposes cameraButton; used to detect
// that older header shape (v439's Swift header does not respond to this).
@property (readonly, nonatomic) UIButton *cameraButton;
@end

@interface IGTableViewCell : UITableViewCell
- (id)initWithReuseIdentifier:(NSString *)identifier;
@end

@interface IGProfileSheetTableViewCell : IGTableViewCell
@end

@interface IGTallNavigationBarView : UIView
@end

@interface UIView (RCTViewUnmounting)
@property (retain, nonatomic) UIViewController *viewController;
- (UIView *)_rootView;
@end

// Instagram's design-system font entry points. Every label in the app resolves its
// typeface through one of these rather than through UIKit directly, which makes them
// the seam for replacing the app-wide font. Present on 410 through 442; the branded,
// script, and monospaced-digit members of the category are deliberately omitted here
// because replacing those would corrupt the logo, the story text tool, and any
// column-aligned numerals.
@interface UIFont (Instagram)
+ (UIFont *)ig_systemFontOfSize:(CGFloat)size weight:(CGFloat)weight;
+ (UIFont *)ig_systemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_lightSystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_mediumSystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_semiboldSystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_boldSystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_heavySystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_italicSystemFontOfSize:(CGFloat)size;
+ (UIFont *)ig_systemDynamicFontOfSize:(CGFloat)size;
+ (UIFont *)ig_systemDynamicFontOfSize:(CGFloat)size weight:(CGFloat)weight;
+ (UIFont *)ig_lightSystemDynamicFontOfSize:(CGFloat)size;
+ (UIFont *)ig_semiboldSystemDynamicFontOfSize:(CGFloat)size;
+ (UIFont *)ig_boldSystemDynamicFontOfSize:(CGFloat)size;
+ (UIFont *)ig_heavySystemDynamicFontOfSize:(CGFloat)size;
@end

@interface IGImageSpecifier : NSObject
@property (readonly, nonatomic) NSURL *url;
@end

@interface IGVideo : NSObject
- (id)sortedVideoURLsBySize; // Before Instagram v398
- (id)allVideoURLs;          // After Instagram v398
@end

@interface IGPhoto : NSObject
- (id)imageURLForWidth:(CGFloat)width;
@end

@interface IGBaseMedia : NSObject
@property (retain, nonatomic) id explorePostInFeed;
@end

@interface IGMedia : IGBaseMedia
@property (readonly) IGVideo *video;
@property (readonly) IGPhoto *photo;
- (BOOL)isClipsMedia;
- (BOOL)isIGTVMedia;
- (BOOL)isFeedPost;
@end

@interface IGPostItem : NSObject
@property (readonly) IGVideo *video;
@property (readonly) IGPhoto *photo;
@end

@interface IGPageMediaView : UIView
@property (readonly) NSMutableArray<IGPostItem *> *items;
- (IGPostItem *)currentMediaItem;
@end

@interface IGFeedItem : NSObject
@property long long likeCount;
@property (readonly) IGVideo *video;
- (BOOL)isSponsored;
- (BOOL)isSponsoredApp;
@end

@interface IGImageView : UIImageView
@property (retain, nonatomic) IGImageSpecifier *imageSpecifier;
@end

@interface IGFeedItemPagePhotoCell : UICollectionViewCell
@property (nonatomic, strong) id post;
@property (nonatomic, strong) IGPostItem *pagePhotoPost;
@end

@interface IGProfilePicturePreviewViewController : UIViewController {
    IGImageView *_profilePictureView;
}
- (void)addHandleLongPress;                                     // new
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender; // new
@end

@interface IGFeedItemMediaCell : UICollectionViewCell
@property (retain, nonatomic) IGMedia *post;
- (UIImage *)mediaCellCurrentlyDisplayedImage;
@end

@interface IGFeedItemPhotoCell : IGFeedItemMediaCell
@end

@interface IGFeedItemPhotoCellConfiguration : NSObject
@end

@interface IGFeedPhotoView : UIView
@property (nonatomic, strong) id delegate;
@end

@interface IGFeedItemVideoView : UIView
@property (nonatomic, strong) id delegate;
@end

@interface IGModernFeedVideoCell : UIView
- (id)mediaCellFeedItem;
@end

@interface IGSundialViewerVideoCell : UIView
@property (readonly, nonatomic) IGMedia *video;
- (void)playWithReason:(long long)reason;
- (void)pauseWithReason:(long long)reason;
- (void)gestureController:(id)controller didObserveSingleTap:(id)tap;
- (void)videoViewDidPlayThroughToCompletion:(id)videoView;
@end

@interface IGSundialViewerPhotoCell : UIView
@end

@interface IGSundialViewerCarouselCell : UIView
@end

@interface IGSundialViewerPhotoView : UIView
@end

@interface IGImageProgressView : UIView
@property (retain, nonatomic) IGImageSpecifier *imageSpecifier;
@end

// Reels player on 410; 448 uses the Swift _TtC21IGVideoPlayerKitSwift13IGVideoPlayer
// with the same play and seek selectors plus isLoopingOverride.
@interface IGStatefulVideoPlayer : NSObject
- (void)playWithReason:(long long)reason callsiteContext:(id)context;
- (void)seekToTime:(double)time preciseTime:(BOOL)preciseTime;
@end

@interface IGStoryPhotoView : UIView
- (id)item;
@end

@interface IGStoryFullscreenSectionController : NSObject
@property (nonatomic, strong, readwrite) IGMedia *currentStoryItem;
- (BOOL)audioEnabled;
- (void)setAudioEnabled:(BOOL)enabled reason:(long long)reason;
- (void)didUpdateToObject:(id)object;
- (void)didSelectItemAtIndex:(long long)index;
- (id)overlayView;
@end

@interface IGStoriesMidcardsController : NSObject
- (void)fetchMidcards;
- (BOOL)_isEligibleForAYPromo;
- (BOOL)_isEligibleForSUMidcard;
- (void)fetchMidcardsWithLness28Score:(id)score;
- (BOOL)_isEligibleForSUMidcardWithLness28Score:(id)score;
@end

@interface IGStoryVideoView : UIView
@property (nonatomic, weak, readwrite) IGStoryFullscreenSectionController *captionDelegate;
@property (nonatomic, readonly) BOOL isAudioAvailable;
@end

@interface IGStoryModernVideoView : UIView
@property (nonatomic, readonly) IGMedia *item;
@end

@interface IGStoryFullscreenOverlayView : UIView
@property (nonatomic, weak, readwrite) id gestureDelegate;
- (id)gestureDelegate;
- (void)setChromeHidden:(BOOL)hidden;
- (void)hideOverlaysExcludingSponsoredStory:(BOOL)excludingSponsoredStory;
@end

// Real superclass is IGViewController; UIViewController is enough for the
// appearance callbacks Sparkle hooks here.
@interface IGStoryViewerViewController : UIViewController
@end

@interface IGAudioStatusAnnouncer : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isAudioEnabledForSoundBehavior:(long long)behavior;
- (void)_announceForDeviceStateChangesIfNeededForAudioEnabled:(BOOL)enabled reason:(long long)reason;
@end

@interface IGDirectVisualMessageViewerController : UIViewController
@end

// Full-screen viewer for permanent DM media (camera-roll photos/videos, chat-menu
// media). Sparkle installs its action button here; see AggregatedMediaActionButton.xm.
@interface IGDirectAggregatedMediaViewerViewController : UIViewController
- (void)scrollViewDidEndDecelerating:(id)scrollView;
@end

@interface IGDirectVisualMessageViewerViewModeAwareDataSource : NSObject
@end

@interface IGDirectVisualMessage : NSObject
- (id)rawVideo;
@end

// Receives every realtime presence update for users IG tracks. The selector is
// unchanged across 410.1.0 through 438.0.0; only the owning framework moved.
//
// Note this is only the realtime *push* path. IG also populates presence by
// fetching (see the periodic scheduler and inbox fetch), and those updates never
// reach this callback, so it is not a complete view of what IG knows.
@interface IGPresenceManager : NSObject
- (void)presenceRealtimeDataProvider:(id)provider
             didReceiveUpdateForUserPk:(id)pk
                              isActive:(BOOL)isActive
                      lastActivityAtMs:(double)lastActivityAtMs
                          capabilities:(unsigned long long)capabilities
                         correlationId:(id)correlationId
                         isCloseFriend:(BOOL)isCloseFriend;
// The store IG itself reads to draw activity dots, regardless of how the state
// got there. Values are IGPresenceState, an opaque value object.
- (id)presenceStatesByUserPk;
- (id)presenceStateForUser:(id)user;
@end

// Presence poll timer owned by IGPresenceManager. IG picks the interval at
// session setup; Sparkle updates the stored interval and restarts this timer
// when the active account's accuracy settings change.
@interface IGPresencePeriodicScheduler : NSObject
- (id)initWithIntervalInSeconds:(unsigned long long)seconds block:(id)block;
- (void)stop;
- (void)start;
@end

// Server-driven gating values for Direct. `activeNowGracePeriod` is how long IG
// keeps drawing someone as active after their last activity, which is why the
// green dot outlives the actual session. Absent before 411, where the grace
// period is not exposed as a gate at all.
@interface IGDirectGatingService : NSObject
- (long long)activeNowGracePeriod;
// Some builds synthesize this cached getter at runtime even though it is omitted
// from their dumped declaration. The selector is probed before its hook group
// is installed.
- (NSNumber *)activeNowGracePeriodCacheValue;
@end

// One typing event. Carries the sender pk directly, so typing does not have to be
// resolved through the thread it arrived on. Identical across 410.1.0 and 443.0.0.
@interface IGDirectTypingStatus : NSObject
@property (readonly, nonatomic) NSString *threadId;
@property (readonly, nonatomic) NSString *userPk;
@property (readonly, nonatomic) NSDate *sentDate;
@property (readonly, nonatomic) BOOL isActive;
@property (readonly, nonatomic) double lifetime;
@end

// Instagram's UNUserNotificationCenterDelegate. Decides what happens to a
// notification that arrives while the app is in the foreground; it recognizes only
// its own, so anything else is presented as nothing at all.
@interface IGAppCoordinator : NSObject
- (void)userNotificationCenter:(id)center willPresentNotification:(id)notification withCompletionHandler:(id)handler;
@end

// Holds the live typing state for every thread. The dictionary is replaced
// wholesale on each change, so its setter is the one funnel every incoming typing
// update passes through. Value shape is not contractual, hence the defensive walk
// in the hook.
@interface IGDirectTypingStatusService : NSObject
@property (copy) NSDictionary *threadIdToTypingStatuses;
- (id)updatedTypingStatusesForThreadId:(id)threadId;
@end

@interface IGUser : NSObject
@property NSInteger followStatus;
@property (copy) NSString *username;
@property BOOL followsCurrentUser;
@end

@interface IGFollowController : NSObject
@property IGUser *user;
@end

// The follow controller ships as an Objective-C class on older builds and as a Swift class on newer
// ones. Both expose this, so Sparkle asks whichever is present through a shared shape.
@protocol SPKFollowControlling <NSObject>
@property (nonatomic, readonly) BOOL canShowRelationshipSheetWhenFollowing;
// Set by the surfaces whose follow control turns into a Message button once the account is
// followed. Only newer builds expose it to the Objective-C runtime.
@property (nonatomic, readonly) BOOL showMessageButtonWhenFollowing;
@end

@class IGStyledString;

@interface IGCoreTextView : UIView
@property (nonatomic, copy) IGStyledString *styledString;
@property (nonatomic, weak) id linkHandler;
@property (nonatomic, strong) NSString *text;
- (void)addHandleLongPress;                                     // new
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender; // new
@end

@interface IGFeedItemHeaderCoreTextView : UIView
@property (nonatomic, copy) IGStyledString *styledString;
@end

@interface IGFeedItemTextCell : UIView
@property (readonly, nonatomic) IGCoreTextView *coreTextView;
@property (readonly, nonatomic) IGStyledString *styledString;
- (void)setStyledString:(IGStyledString *)styledString;
- (void)updateStyledString;
@end

@interface IGUnifiedVideoCaptionView : UIView
@property (retain, nonatomic) id viewModel;
- (CGSize)sizeThatFits:(CGSize)size;
- (void)prepareForAnimationToExpansionPercentage:(double)percentage;
@end

@interface IGCommentComposerView : UIView
@property (weak, nonatomic) id delegate;
@property (retain, nonatomic) UIView *emojiBar;
@end

// Runtime-resolved Swift class used by expanded post and Reels caption sheets.
@interface IGCommentRichCaptionView : UIView
- (void)configureWith:(id)viewModel;
- (void)setCoreTextLinkHandler:(id)handler;
@end

// Runtime-resolved to IGCommentCell on 410 and
// IGCommentCells.IGCommentCell on newer Instagram builds.
@interface IGCommentCell : UIView
@property (readonly, nonatomic) UIView *commentView;
- (void)bindViewModel:(id)viewModel;
@end

@interface IGUserSession : NSObject
@property (readonly, nonatomic) IGUser *user;
// Category on IGUserSession in IG, so it is only present once the presence
// subsystem is linked in; always respondsToSelector: before calling.
- (id)presenceManager;
@end

@interface IGWindow : UIWindow
@property (nonatomic) __weak IGUserSession *userSession;
@end

@interface IGShakeWindow : UIWindow
@property (nonatomic) __weak IGUserSession *userSession;
@end

@interface IGStyledString : NSObject
@property (retain, nonatomic) NSMutableAttributedString *attributedString;
- (void)appendString:(id)arg1;
- (void)setURL:(id)url range:(NSRange)range;
- (void)setColor:(id)color range:(NSRange)range;
@end

@interface IGInstagramAppDelegate : NSObject <UIApplicationDelegate>
@end

@interface IGDirectInboxSearchAIAgentsPillsContainerCell : UIView
@end

@interface IGTapButton : UIButton
- (void)setEDR:(_Bool)edr;
@end

// Your-own-story viewer list (swipe up on your story). `_item` is the
// id<IGStoryItemType> whose media pk we resolve to fetch the full viewer list.
@interface IGStoryViewersListViewController : UIViewController
@end

// Collection section-header view used for the "Who viewed this story" label in
// the viewer list — we pin the Sparkle viewer-search button to its trailing edge.
@interface IGLabelSupplementaryView : UICollectionReusableView
@end

@interface IGLabel : UILabel
@end

@interface IGLabelItemViewModel : NSObject
@end

@interface IGDirectInboxSuggestedThreadCellViewModel : NSObject
@end

// Backs the main DM inbox list. ObjC on IG 410, migrated to a Swift class of the
// same bare name on newer builds, so it is always resolved through
// SPKResolveIGClass rather than referenced directly.
@interface IGDirectInboxListAdapterDataSource : NSObject
- (id)objectsForListAdapter:(id)adapter;
@end

@interface IGDirectInboxViewController : UIViewController
@end

// Same inbox screen, rebuilt in Swift. Not a subclass of the above.
@interface IGDirectInboxSwiftViewController : UIViewController
@end

// Swift class (IGDirectInboxViewControllerSwift module), resolved through
// SPKResolveIGClass. Owns the inbox's Instants peek presentation.
@interface IGDirectInboxCameraMediaCoordinator : NSObject
- (void)tryShowQuickSnapPeek;
@end

// Swift class (IGQuickSnapExperimentation module). The class methods are thin
// @objc thunks; Swift callers inline the gate, so only ObjC call sites see a hook.
@interface IGQuickSnapExperimentationHelper : NSObject
+ (BOOL)isQuicksnapEnabledInInbox:(id)session;
@end

// Swift class (IGQuickSnapPresentationManager module). The card view is shared
// between the Direct inbox and the profile corner stack.
@interface IGQuickSnapPresentationManager : NSObject
@property (readonly, nonatomic) UIView *cardView;
@end

// Category on IGUserSession in IG; always respondsToSelector: before calling.
@interface IGUserSession (SPKQuickSnapPresentation)
- (IGQuickSnapPresentationManager *)quickSnapPresentationManager;
@end

// Swift class (IGSundialAutoScroll module) behind the reels auto scroll toggle.
// 410 exposes a writable isEnabled; newer builds make it a computed getter and
// route the user's choice through setUserEnabled:. respondsToSelector: first.
@interface _TtC19IGSundialAutoScroll19IGSundialAutoScroll : NSObject
@property (nonatomic, readonly) BOOL isEnabled;
- (void)setIsEnabled:(BOOL)enabled;
- (void)setUserEnabled:(BOOL)enabled;
@end

// Category on IGUserSession in IG; lazily creates the session's auto scroll controller.
@interface IGUserSession (SPKSundialAutoScroll)
- (_TtC19IGSundialAutoScroll19IGSundialAutoScroll *)autoScrollController;
@end

// Aggregate unread counts behind the app's badges. The two Direct fields are the
// only ones Sparkle touches.
@interface IGBadgeData : NSObject
@property (readonly, nonatomic) unsigned long long directMessagesServerCalculated;
@property (readonly, nonatomic) NSNumber *directMessagesClientCalculated;
@end

@interface IGDirectInboxHeaderCellViewModel : NSObject
- (id)title;
@end

@interface IGSearchResultViewModel : NSObject
- (id)title;
- (NSUInteger)itemType;
@end

@interface IGDirectShareRecipient : NSObject
@property (copy, nonatomic) NSString *threadID;
@property (readonly, nonatomic) NSArray *users;
- (NSString *)threadName;
- (BOOL)isBroadcastChannel;
- (BOOL)isGroupThread;
@end

// The share sheet's recipient grid, and its own IGListAdapter data source.
@interface IGDirectRecipientListViewController : UIViewController
@property (readonly, nonatomic) UICollectionView *collectionView;
@property (readonly, nonatomic) id listAdapter;
- (id)objectsForListAdapter:(id)adapter;
- (void)v3RecipientDidLongPress:(id)viewModel;
- (void)recipientSectionController:(id)controller didLongPressViewModel:(id)viewModel;
@end

@interface IGDirectRecipientCellViewModel : NSObject
- (id)recipient;
- (NSInteger)sectionType;
@end

@interface IGDirectInboxSearchAIAgentsSuggestedPromptRowCell : UIView
@end

// Chat header title view — holds the "Active now" / "Active Xh ago" presence
// subtitle we rewrite into an absolute timestamp (Full Last Active feature).
@interface IGDirectLeftAlignedTitleView : UIView
@property (nonatomic, retain) id titleViewModel;
- (id)delegate;
- (id)_currentSubtitleViewModel;
- (void)setTitleViewModel:(id)titleViewModel;
- (void)animationCoordinatorDidUpdate:(id)coordinator;
@end

// Header of the reply sheet opened from a reel's "reposted this" bubble; the
// Repost Date feature places the repost's creation date beside its title.
@interface IGDirectMessageModalTitleView : UIView
@end

@interface IGDate : NSObject
@property (readonly, nonatomic) long long microseconds;
@property (readonly, nonatomic) NSDate *date;
@end

@interface IGRepostModel : NSObject
@property (readonly, copy, nonatomic) NSString *pk;
@property (readonly, copy, nonatomic) NSString *mediaId;
@property (readonly, copy, nonatomic) IGDate *createdAtDate;
@end

// Inbox row view model — its `socialContextText` carries the "Active Xh ago"
// presence line rendered into the cell's social-context label (Full Last Active).
@interface IGDSSegmentedPillBarView : UIView
- (id)delegate;
- (CGSize)sizeThatFits:(CGSize)size expanded:(BOOL)expanded;
@end

@interface IGExploreChipBarView : UIView
- (void)configureWith:(id)topics;
- (CGSize)sizeThatFits:(CGSize)size expanded:(BOOL)expanded;
@end

@interface IGImageWithAccessoryButton : IGTapButton
- (void)addLongPressGestureRecognizer;                      // new
- (void)handleLongPress:(UILongPressGestureRecognizer *)gr; // new
@end

@interface IGHomeFeedHeaderView : UIView
@end

@interface IGHomeFeedHeaderViewController
- (void)headerDidLongPressLogo:(id)arg1;
@end

@interface IGSearchBarDonutButton : UIView
@end

@interface IGAnimatablePlaceholderTextField : UITextField
@end

@interface IGDirectCommandSystemViewModel : NSObject
- (id)row;
@end

@interface IGDirectCommandSystemRow : NSObject
@end

@interface IGDirectCommandSystemResult : NSObject
- (id)title;
- (id)commandString;
@end

@interface IGGrowingTextView : UIView
- (id)placeholderText;
- (void)setPlaceholderText:(id)arg1;
@end

@interface IGUnifiedVideoCollectionView : UICollectionView
@end

@interface IGBadgedNavigationButton : UIView
- (void)addLongPressGestureRecognizer; // new
@end

@interface IGSearchBar : UIView
- (NSObject *)sanitizePlaceholderForConfig:(NSObject *)config; // new
@end

@interface IGSearchBarConfig : NSObject
@end

@interface IGDirectComposer : UIView
- (NSObject *)patchConfig:(NSObject *)config; // new
- (void)menuDidDismiss;
- (void)_didTapMore:(id)more;
- (void)_didTapRedesignOverflowButton:(id)button;
- (void)_didTapPlusButton:(id)button;
- (void)_didTapOpenTrayButton:(id)button;
@end

@interface IGDirectComposerConfig : NSObject
@end

@interface IGAnimatablePlaceholderTextFieldContainer : UIView
@end

@interface IGDirectInboxConfig : NSObject
@end

@interface IGDirectInboxFeatureManager : NSObject
- (BOOL)_isChatPeekEligibleForThreadId:(id)threadId;
@end

@interface _TtC29IGConsumerSubsDirectChatPeeks35IGDirectInboxChatPeekPreviewHandler : NSObject
- (id)previewViewControllerForThreadId:(id)threadId userSession:(id)session containerWidth:(double)width;
@end

@interface _TtC39IGDirectLightweightThreadViewController39IGDirectLightweightThreadViewController : UIViewController
- (id)initWithUserSession:(id)session threadId:(id)threadId onLoadCompletion:(id)completion;
- (void)setShouldHideHeader:(BOOL)shouldHideHeader;
- (void)setBypassSeenStateUpdate:(BOOL)bypassSeenStateUpdate;
- (void)setShouldSkipScrollToNewMessagesSeparator:(BOOL)shouldSkip;
@end

@interface IGDirectMediaPickerConfig : NSObject
@end

@interface IGDirectMediaPickerGalleryConfig : NSObject
@end

@interface IGStoryEyedropperToggleButton : UIControl
@property (nonatomic, strong, readwrite) UIColor *color;

- (void)setPushedDown:(BOOL)pushedDown;

- (void)addLongPressGestureRecognizer; // new
@end

@interface IGStoryTextEntryViewController : UIViewController
- (void)textViewControllerDidUpdateWithColor:(id)color colorSource:(NSInteger)source;
- (void)textViewControllerDidUpdateWithColor:(id)color colorSource:(NSInteger)source textColorEffect:(id)effect; // 446+
@end

@interface IGStoryColorPaletteView : UIView
@end

@interface IGProfilePictureImageView : UIView
@property (nonatomic, readonly) IGUser *userGQL;
@end

@interface IGImageRequest : NSObject
- (id)url;
@end

@interface IGDiscoveryGridItem : NSObject
- (id)model;
@end

@interface IGStoryTextEntryControlsOverlayView : UIView

@property (readonly, nonatomic) NSMutableArray *animationTypes;
@property (readonly, nonatomic) NSMutableArray *effectTypes;

- (void)reloadData;

@end

@interface _TtC27IGGalleryDestinationToolbar31IGGalleryDestinationToolbarView : UIView
@property (nonatomic, copy, readwrite) NSArray *tools;
@end

// IGConsumerSubsStoryPeekDirectPlugin.IGConsumerSubsStoryPeekDirectManager — the
// DM-inbox story peek entry. It calls presentPeek… (real) or presentPeekUpsell…
// (subscribe dead-end) based on entitlement. IG 440 and earlier only; 441 folded
// it into the unified manager below.
@interface _TtC35IGConsumerSubsStoryPeekDirectPlugin36IGConsumerSubsStoryPeekDirectManager : NSObject
- (void)presentPeekWithSourceView:(id)view reelPK:(id)pk presenting:(id)presenting onTapToOpenStory:(id)onTapToOpenStory onViewProfile:(id)onViewProfile;
- (void)presentPeekUpsellWithSourceView:(id)view reelPK:(id)pk presenting:(id)presenting onSubscribeToInstagramPlus:(id)onSubscribe onViewProfile:(id)onViewProfile;
@end

// IGConsumerSubsStoryPeekPlugin.IGConsumerSubsStoryPeekManager — IG 441+. The
// per-surface Direct and Profile plugins were replaced by this single manager,
// and the upsell is no longer a separate presenter: both entry points call one
// presentPeek… and pass the real-vs-upsell decision in `peekMode` (0 = real).
// IG 447 changed `peekMode` from an integer to an
// IGConsumerSubsStoryPeekModeObjc instance, so the hooks declare it per version.
@interface _TtC29IGConsumerSubsStoryPeekPlugin30IGConsumerSubsStoryPeekManager : NSObject
@end

// IGConsumerSubsStoryPeekManaging.IGConsumerSubsStoryPeekModeObjc — IG 447+ boxed
// peek mode. Wraps a Swift enum (standard/freemium × nux/peek/upsell) that is not
// readable from Obj-C; the factories build the standard cases.
@interface _TtC31IGConsumerSubsStoryPeekManaging31IGConsumerSubsStoryPeekModeObjc : NSObject
+ (instancetype)peek;
+ (instancetype)nux;
+ (instancetype)upsell;
@end

// IGConsumerSubsStoryPeekManaging.IGConsumerSubsStoryPeekEligibilityDecision — IG 448
// eligibility result the post-header presenter hands its long-press arbiter.
@interface _TtC31IGConsumerSubsStoryPeekManaging42IGConsumerSubsStoryPeekEligibilityDecision : NSObject
@property (nonatomic, readonly) BOOL isPeekEligible;
@property (nonatomic, readonly) BOOL isUpsellEligible;
- (instancetype)initWithIsPeekEligible:(BOOL)peekEligible isUpsellEligible:(BOOL)upsellEligible;
@end

// IGFeedItemHeaderControllerStoryPeek.IGConsumerSubsStoryPeekFeedPostHeaderPresenter — IG 448.
@interface _TtC35IGFeedItemHeaderControllerStoryPeek46IGConsumerSubsStoryPeekFeedPostHeaderPresenter : NSObject
- (id)evaluateEligibilityWithReelViewModel:(id)model userSession:(id)session;
@end

@interface IGUFIInteractionCountsView : UIView
@end

@interface IGUFIButtonWithCountsView : UIView
@end

@interface IGLazyView : NSObject
@property (nonatomic) _Bool isHidden;
- (void)hide;
- (UIView *)viewIfLoaded;
@end

@interface IGUFIButtonBarView : UIView
- (void)updateUFIWithButtonsConfig:(id)config interactionCountProvider:(id)provider;
@end

@interface IGSundialViewerVerticalUFI : UIView
// Native like control used as the source of the reel UFI's HDR/EDR tint.
@property (readonly, nonatomic) UIButton *ufiLikeButton;
- (void)_didTapLikeButton:(id)arg1;
- (void)_didTapRepostButton:(id)arg1;
// IG 436+ renamed handlers (no underscore prefix, no argument).
- (void)didTapRepostButton;
- (void)didTapLikeButton;
@end

// Reels viewer footer. IG 443+ uses the Swift feed-footer implementation and
// represents the fake comment composer with a dedicated config/content pair.
@interface _TtC19IGSundialFeedFooter30IGSundialViewerBottomBarConfig : NSObject
@end

@interface _TtC19IGSundialFeedFooter37IGSundialViewerBottomBarCommentConfig : _TtC19IGSundialFeedFooter30IGSundialViewerBottomBarConfig
@end

@interface _TtC19IGSundialFeedFooter24IGSundialViewerBottomBar : UIView
@property (nonatomic, retain) _TtC19IGSundialFeedFooter30IGSundialViewerBottomBarConfig *config;
@end

@interface _TtC19IGSundialFeedFooter42IGSundialViewerBottomBarCommentContentView : UIView
@end

// IG 410 uses one Objective-C bottom bar. Its initializer already exposes the
// native switch that removes only the fake comment composer while preserving a
// CTA when one is present.
@interface IGSundialViewerBottomBar : UIView
- (instancetype)initWithCTAButtonType:(NSInteger)type
                   fakeComposerEnabled:(BOOL)enabled
                      commentBarDisabled:(BOOL)disabled;
@end

@interface IGMainAppSurfaceIntent : NSObject
- (id)tabStringFromSurfaceIntent;
@end

@protocol IGSundialFeedSource <NSObject>
@property (readonly, nonatomic) BOOL isReelsHomeOrTab;
@end

@interface IGSundialFeedDataSource : NSObject
- (NSArray *)objectsForListAdapter:(id)adapter;
@end

@interface IGSundialFeedViewController : UIViewController
- (void)refreshControlDidEndFinishLoadingAnimation:(id)arg1;
- (void)finishPullToRefreshLoading;
@end

@interface IGRefreshControl : UIControl
@property (readonly, nonatomic) long long refreshState;
- (void)finishLoading;
@end

@interface IGDirectThreadViewDrawingViewController : UIViewController
- (void)drawingControls:controls didSelectColor:color;
@end

@interface IGSundialViewerNavigationBarOld : UIView
@end

@interface IGFeedItemUFICell : UIView
- (void)UFIButtonBarDidTapOnRepost:(id)arg1;
@end

@interface IGStoryTrayViewModel : NSObject
@property (nonatomic, readonly) NSString *pk;
@property (nonatomic, readonly) BOOL isUnseenNux;
- (id)diffIdentifier;
@end

// One reel inside the story viewer. Resurfaced highlights carry a reelPK of the
// form "highlightRewind:<id>".
@interface IGStoryViewerViewModel : NSObject
@property (nonatomic, readonly, copy) NSString *reelPK;
@end

// Backing store for the reel list the story viewer pages through. The view
// controller keeps its own copy for tap-forward navigation, while horizontal
// swipes are driven by the list adapter reading this store.
@interface IGStoryViewerDataStore : NSObject
- (id)modelItems;
- (void)replaceModelItems:(id)items;
- (void)replaceModelItems:(id)items maxCount:(long long)count;
@end

@interface _TtC32IGSundialOrganicCTAContainerView32IGSundialOrganicCTAContainerView : UIView
@end

@interface IGCommentThreadViewController : UIViewController
@end

@interface IGSeeAllItemConfiguration : NSObject
@property (readonly, nonatomic) long long destination;
@end

@interface IGDSMenuItem : NSObject
@end

@interface IGDirectThreadViewController : UIViewController
- (void)markLastMessageAsSeen;
- (void)inputView:(id)view didTapMoreButton:(id)button;
- (void)inputView:(id)view didTapPlusButton:(id)button isExpanded:(_Bool)expanded layoutSpec:(id)layoutSpec;
- (void)composerOverflowButtonMenuWillPrepareExpandWithPlusButton:(id)button;
- (void)composerOverflowButtonMenuWillExpandWithPlusButton:(id)button;
@end

@interface IGTabBarButton : UIButton
- (void)addHandleLongPress; // new
@end

@interface IGStoryFullscreenDefaultFooterView : NSObject
@end

@interface IGDirectThreadThemePickerOption : NSObject
@end

@interface IGCreationActionBarButton : UIButton
@end

@interface IGCreationActionBarLabeledButton : NSObject
@property (readonly, nonatomic) IGCreationActionBarButton *button;
@end

@interface IGCommentThreadConfiguration : NSObject
@end

@interface IGDirectRealtimeIrisDelta : NSObject
@end

@interface IGDirectRealtimeIrisDeltaPayload : NSObject
@end

@interface IGDirectRealtimeIrisThreadDeltaPayload : NSObject
@end

@interface IGDirectRealtimeIrisThreadDelta : NSObject
@end

@interface IGDirectMessageContentMutation : NSObject
@end

@interface IGStickerGalleryViewController : UIViewController
@property (retain, nonatomic) NSArray *preferredMediaTypes;
@end

@interface IGGalleryDataSource : NSObject
@property (retain, nonatomic) NSArray *preferredMediaTypes;
@end

@interface IGGalleryAssetProvider : NSObject
@property (retain, nonatomic) NSArray *preferredMediaTypes;
@end

@interface IGStoryGalleryConfiguration : NSObject
@property (readonly, copy, nonatomic) NSArray *preferredMediaTypes;
@end

@interface IGGalleryImageStickerView : UIView
- (id)initWithImage:(id)image showStyleEducation:(_Bool)education isCroppingEnabled:(_Bool)enabled;
@end

@interface IGVideoClip : NSObject
@property (nonatomic) CMTime endTime;
@property (nonatomic) CMTimeRange compositionTimeRange;
@property (nonatomic) CGRect cropRect;
@property (nonatomic) CGSize renderSize;
- (id)initWithAsset:(id)asset position:(long long)position sourceType:(long long)type;
- (id)initWithAsset:(id)asset position:(long long)position sourceType:(long long)type shouldBeSquare:(_Bool)square;
@end

@interface IGGalleryVideoStickerModel : NSObject
- (id)initWithVideoClip:(id)clip;
@end

@interface IGGalleryVideoStickerView : UIView
- (id)initWithModel:(id)model;
@end

@interface IGStoryMediaCompositionEditingViewController : UIViewController
@property (readonly, nonatomic) id stickerController;
- (void)didAddSticker:(id)sticker;
- (void)setEditingControlsOverlayViewHidden:(_Bool)hidden animated:(_Bool)animated;
/// Composition playback. Used to quiet the canvas while a Sparkle sheet covers it,
/// since IG's overFullScreen tray presentation leaves the editor mounted and live.
- (void)pause;
- (void)play;
@end

@interface IGStoryStickerTrayViewController : UIViewController
@end

/// Outer container for the story editor. Hosts IGStoryMediaCompositionEditingViewController
/// as a child and is what actually presents the sticker tray / sticker gallery.
@interface IGStoryPostCaptureEditingViewController : UIViewController
@end

/////////////////////////////////////////////////////////////////////////////

static BOOL is_iPad() {
    if ([(NSString *)[UIDevice currentDevice].model hasPrefix:@"iPad"]) {
        return YES;
    }
    return NO;
}

/////////////////////////////////////////////////////////////////////////////

static UIViewController *_Nullable _topMostController(UIViewController *_Nonnull cont) {
    UIViewController *topController = cont;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    if ([topController isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)topController).visibleViewController;
        if (visible) {
            topController = visible;
        }
    }
    return (topController != cont ? topController : nil);
}
static UIViewController *_Nonnull topMostController() {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIViewController *next = nil;
    while ((next = _topMostController(topController)) != nil) {
        topController = next;
    }
    return topController;
}

@class FLEXAlert, FLEXAlertAction;

typedef void (^FLEXAlertReveal)(void);
typedef void (^FLEXAlertBuilder)(FLEXAlert *make);
typedef FLEXAlert *_Nonnull (^FLEXAlertStringProperty)(NSString *_Nullable);
typedef FLEXAlert *_Nonnull (^FLEXAlertStringArg)(NSString *_Nullable);
typedef FLEXAlert *_Nonnull (^FLEXAlertTextField)(void (^configurationHandler)(UITextField *textField));
typedef FLEXAlertAction *_Nonnull (^FLEXAlertAddAction)(NSString *title);
typedef FLEXAlertAction *_Nonnull (^FLEXAlertActionStringProperty)(NSString *_Nullable);
typedef FLEXAlertAction *_Nonnull (^FLEXAlertActionProperty)(void);
typedef FLEXAlertAction *_Nonnull (^FLEXAlertActionBOOLProperty)(BOOL);
typedef FLEXAlertAction *_Nonnull (^FLEXAlertActionHandler)(void (^handler)(NSArray<NSString *> *strings));

@interface FLEXAlert : NSObject

// Shows a simple alert with one button which says "Dismiss"
+ (void)showAlert:(NSString *_Nullable)title message:(NSString *_Nullable)message from:(UIViewController *)viewController;

// Shows a simple alert with no buttons and only a title, for half a second
+ (void)showQuickAlert:(NSString *)title from:(UIViewController *)viewController;

// Construct and display an alert
+ (void)makeAlert:(FLEXAlertBuilder)block showFrom:(UIViewController *)viewController;
// Construct and display an action sheet-style alert
+ (void)makeSheet:(FLEXAlertBuilder)block
         showFrom:(UIViewController *)viewController
           source:(id)viewOrBarItem;

// Construct an alert
+ (UIAlertController *)makeAlert:(FLEXAlertBuilder)block;
// Construct an action sheet-style alert
+ (UIAlertController *)makeSheet:(FLEXAlertBuilder)block;

// Set the alert's title.
///
// Call in succession to append strings to the title.
@property (nonatomic, readonly) FLEXAlertStringProperty title;
// Set the alert's message.
///
// Call in succession to append strings to the message.
@property (nonatomic, readonly) FLEXAlertStringProperty message;
// Add a button with a given title with the default style and no action.
@property (nonatomic, readonly) FLEXAlertAddAction button;
// Add a text field with the given (optional) placeholder text.
@property (nonatomic, readonly) FLEXAlertStringArg textField;
// Add and configure the given text field.
///
// Use this if you need to more than set the placeholder, such as
// supply a delegate, make it secure entry, or change other attributes.
@property (nonatomic, readonly) FLEXAlertTextField configuredTextField;

@end

@interface FLEXAlertAction : NSObject

// Set the action's title.
///
// Call in succession to append strings to the title.
@property (nonatomic, readonly) FLEXAlertActionStringProperty title;
// Make the action destructive. It appears with red text.
@property (nonatomic, readonly) FLEXAlertActionProperty destructiveStyle;
// Make the action cancel-style. It appears with a bolder font.
@property (nonatomic, readonly) FLEXAlertActionProperty cancelStyle;
// Enable or disable the action. Enabled by default.
@property (nonatomic, readonly) FLEXAlertActionBOOLProperty enabled;
// Give the button an action. The action takes an array of text field strings.
@property (nonatomic, readonly) FLEXAlertActionHandler handler;
// Access the underlying UIAlertAction, should you need to change it while
// the encompassing alert is being displayed. For example, you may want to
// enable or disable a button based on the input of some text fields in the alert.
// Do not call this more than once per instance.
@property (nonatomic, readonly) UIAlertAction *action;

@end
@interface FLEXManager : NSObject
+ (instancetype)sharedManager;
- (void)showExplorer;
- (void)hideExplorer;
- (void)toggleExplorer;
@end

@interface IGAccountSwitcher : NSObject
- (long long)switchToUser:(id)user destinationAppSurface:(id)surface destinationURL:(id)url entryPoint:(long long)point loggingData:(id)data;
- (long long)switchToUserWithPK:(id)pk destinationAppSurface:(id)surface destinationURL:(id)url entryPoint:(long long)point loggingData:(id)data;
@end

// Instagram's follow control. Declared as a protocol because the class itself is
// plain Objective-C on older builds and a Swift class on newer ones, so it is
// resolved by name at runtime and messaged through this contract. Mirrors
// IGFollowButtonConforming; the control is a UIControl, not a UIButton, and it
// renders its own attributed title, so setTitle:forState: does not exist on it.
@protocol SPKIGFollowButtonConforming <NSObject>
- (instancetype)initWithViewConfiguration:(id)configuration;
- (void)setViewConfiguration:(id)configuration;
@property (nonatomic) long long buttonState;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic) double minimumWidth;
@property (nonatomic) double maximumWidth;
- (void)setIsShimmering:(BOOL)shimmering;
@end

// Value object describing the follow control's appearance. Stays Objective-C on
// every supported build; the category carrying the default factory was renamed
// between versions but the selector itself did not change.
@interface IGFollowButtonViewConfiguration : NSObject
+ (instancetype)defaultButtonConfiguration;
@end

// Grid thumbnail cell section controller (profile, tagged and saved grids). Its
// item size is where the tall 4:5 grid turns into a cell height on every build.
typedef struct {
    CGFloat columnSpacing;
    CGFloat rowSpacing;
    UIEdgeInsets insets;
    CGFloat mediasPerRow;
    CGFloat aspectRatio;
    CGFloat cellCornerRadius;
} SPKGridLayoutConfiguration;

// Loading placeholder for media grids; its layout configuration sets the
// placeholder tile shape independently of the real thumbnails.
@interface IGDSShimmeringGridModel : NSObject
- (instancetype)initWithLayoutConfiguration:(SPKGridLayoutConfiguration)configuration pattern:(id)pattern contentInset:(UIEdgeInsets)inset shimmering:(BOOL)shimmering;
@end

@interface IGDSShimmeringGridView : UIView
- (CGSize)layoutDataSourceCollectionView:(id)view layout:(id)layout sizeForItemAtIndexPath:(NSIndexPath *)path;
@end

// Explore grid tile section controllers (photos and Reels). Explore's waterfall
// layout places tiles from these item sizes.
@interface IGDiscoveryMediaSectionController : NSObject
- (CGSize)sizeForItemAtIndex:(NSInteger)index;
@end

@interface IGDiscoveryTopReelsSectionController : NSObject
- (CGSize)sizeForItemAtIndex:(NSInteger)index;
@end

@interface IGMediaThumbnailSectionController : NSObject
@property (nonatomic, readonly, weak) UIViewController *viewController;
- (CGSize)sizeForItemAtIndex:(NSInteger)index;
@end

// Instagram's location stack (FBSharedFramework). IGThreadedLocationManager owns
// the CLLocationManager on a private thread and is its delegate; IGLocationManager
// sits on top as the threaded manager's delegate and caches the last fix that
// features such as the Friends Map read and upload.
@interface IGThreadedLocationManager : NSObject <CLLocationManagerDelegate>
@property (readonly, copy, nonatomic) CLLocation *location;
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations;
@end

@interface IGLocationManager : NSObject
@property (retain) CLLocation *lastLocation;
- (void)locationManager:(id)manager didUpdateLocations:(NSArray<CLLocation *> *)locations;
@end

// IGFriendsMapSecondaryButtonsStackController.IGFriendsMapSecondaryButtonsStackView:
// the column of round chrome buttons (locate, settings) on the Friends Map. Swift,
// laid out by hand; bound in hook groups through SPKResolveIGClass.
@interface IGFriendsMapSecondaryButtonsStackView : UIView
- (void)didTapLocateButton;
@end

// Instagram's in-app browser. IGBrowserSession carries the request (usually an
// l.instagram.com redirect) and the ads/sign-in context; IGBrowserController
// presents it, and IGBrowserNavigationController is the presented container.
@interface IGBrowserSession : NSObject
@property (readonly) id webAuthenticationRequest;
@property (retain, nonatomic) NSNumber *leadGenFormId;
@end

@interface IGBrowserController : NSObject
- (void)presentBrowserWithBrowserSession:(IGBrowserSession *)session viewController:(UIViewController *)controller presentingPanGesture:(id)gesture forceFreshLoad:(BOOL)forceFreshLoad;
@end

@interface IGBrowserNavigationController : UINavigationController
@property (readonly, nonatomic) IGBrowserSession *browserSession;
@end
