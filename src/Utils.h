#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/log.h>

#import "InstagramHeaders.h"
#import "Shared/MediaPreview/SPKFullScreenMediaPlayer.h"
#import "Shared/UI/SPKNotificationCenter.h"

#import "Settings/SPKSettingsViewController.h"

FOUNDATION_EXPORT void SPKLogMessage(NSString *category,
                                     os_log_type_t type,
                                     NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

/// Master toggle for per-account preferences (global, default off).
FOUNDATION_EXPORT NSString *const kSPKPrefPerAccountSettings;
FOUNDATION_EXPORT NSNotificationName const SPKHideExploreGridPreferenceDidChangeNotification;

/// Maps a preference key to the key actually stored/read. When per-account mode
/// is on and the key isn't forced-global, returns a `u_<accountPK>_<key>`
/// namespaced key; otherwise returns `key` unchanged. Writers MUST route through
/// this so reads and writes stay in sync.
FOUNDATION_EXPORT NSString *SPKEffectivePreferenceKey(NSString *key);

/// Namespaced NSUserDefaults access for code that reads/writes preferences
/// directly (not via getBoolPref:/getStringPref:/...). Applies the same
/// per-account → global inheritance as the accessors.
FOUNDATION_EXPORT id SPKPreferenceObjectForKey(NSString *key);
FOUNDATION_EXPORT void SPKPreferenceSetObject(id _Nullable value, NSString *key);

/// Canonical "per-account mode is active" gate: the global toggle is on AND an
/// account PK is resolved. Single source of truth for whether per-account scoping
/// applies (export prompt, gallery/downloads filtering, etc.).
FOUNDATION_EXPORT BOOL SPKPerAccountModeActive(void);

/// YES when `key` is forced device-global (app icon, appearance, tab layout, ...) and
/// therefore never stored per-account. Used to decide what a per-account export carries.
FOUNDATION_EXPORT BOOL SPKPreferenceKeyIsGlobal(NSString *key);

/// Resolves the Reels vertical-UFI class across IG versions. On IG <=435 the class
/// was exposed to the ObjC runtime as plain `IGSundialViewerVerticalUFI`; on IG 436+
/// it moved into a Swift module and is registered under the mangled name
/// `_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI`. Hook groups bind
/// to the result via `%init(Group, IGSundialViewerVerticalUFI = SPKReelsVerticalUFIClass())`.
FOUNDATION_EXPORT Class _Nullable SPKReelsVerticalUFIClass(void);

/// Resolves an IG class whose ObjC runtime name changed between versions. Many
/// classes that were plain ObjC on IG <=435 became Swift classes on IG 436+, so
/// their runtime name is now the mangled `_TtC<len><Module><len><Class>` form and a
/// bare `%hook`/`NSClassFromString(@"Bare")` resolves to nil. Pass the IG 436+
/// Swift `@"Module.Class"` name as `qualified` and the legacy plain name as
/// `legacy`; returns whichever the runtime currently has (or nil). Hook groups bind
/// to it via `%init(Group, BareName = SPKResolveIGClass(@"Module.Class", @"BareName"))`.
FOUNDATION_EXPORT Class _Nullable SPKResolveIGClass(NSString *qualified, NSString *_Nullable legacy);

#define SPKLog(category, fmt, ...) SPKLogMessage((category), OS_LOG_TYPE_DEFAULT, (fmt), ##__VA_ARGS__)
#define SPKWarnLog(category, fmt, ...) SPKLogMessage((category), OS_LOG_TYPE_ERROR, (fmt), ##__VA_ARGS__)
#define SPKErrorLog(category, fmt, ...) SPKLogMessage((category), OS_LOG_TYPE_FAULT, (fmt), ##__VA_ARGS__)
#define SPKLogId(category, obj) SPKLog((category), @"%@", (obj))

/*
 *  System Versioning Preprocessor Macros
 */

#define SYSTEM_VERSION_EQUAL_TO(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedSame)
#define SYSTEM_VERSION_GREATER_THAN(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedDescending)
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedDescending)

@interface SPKUtils : NSObject

// Preferences
+ (BOOL)getBoolPref:(NSString *)key;
+ (double)getDoublePref:(NSString *)key;
+ (NSString *)getStringPref:(NSString *)key;

// Misc
+ (BOOL)tabOrderSetTo:(NSString *)ordering;
+ (NSString *)IGVersionString;

// Session / user
// Active IG user session (walks connected scenes for the first window with a
// non-nil `userSession`).
+ (nullable id)activeUserSession;
// PK string read from an IGUser object's `_pk` ivar (walks the superclass chain).
+ (nullable NSString *)pkFromIGUser:(nullable id)user;
// Current logged-in user's PK via the active session, or nil when unavailable.
+ (nullable NSString *)currentUserPK;
// Current logged-in user's identity (pk / username / full_name / profile_pic_url)
// read live from the active session's IGUser, or nil when unavailable. Values are
// only present when resolvable; useful for painting identity before any network fetch.
+ (nullable NSDictionary<NSString *, NSString *> *)currentUserIdentity;

/// IGDSLauncherConfig hooks: when Liquid Glass is on, returns YES; otherwise returns `fallback` (stock).
+ (_Bool)spk_liquidGlassLauncherPrefKey:(NSString *)key orig:(_Bool)fallback;

/// True when Liquid Glass is enabled and runtime suppression is inactive.
+ (BOOL)spk_isLiquidGlassEffectivelyEnabled;

+ (void)cleanCache;
+ (unsigned long long)cacheSizeBytes;
/// Last measured cache size, for display on the main thread. Starts a background
/// measurement when none exists or the last one is stale, and posts
/// SPKSettingAccessoryTextDidChangeNotification when the text changes. Nil until
/// the first measurement lands.
+ (nullable NSString *)cachedFormattedCacheSize;
/// Clears the cache on a background queue and calls `completion` on the main
/// thread. Returns NO without doing anything while a clear is already running.
+ (BOOL)cleanCacheInBackgroundWithCompletion:(nullable void (^)(unsigned long long freedBytes))completion;

/// Locale used for Sparkle-owned display formatting. Explicit overrides use the
/// selected Sparkle language; System Default preserves Instagram/system region.
+ (NSLocale *)spk_activeFormattingLocale;

/// Locale-aware absolute display strings. Combined date/time formatting uses a
/// single ICU skeleton so each language supplies its own order, punctuation and
/// joiner instead of source code inserting an English word such as "at".
+ (nullable NSString *)spk_formattedTime:(nullable NSDate *)date;
+ (nullable NSString *)spk_formattedDate:(nullable NSDate *)date includingYear:(BOOL)includeYear;
+ (nullable NSString *)spk_formattedDateTime:(nullable NSDate *)date includingYear:(BOOL)includeYear;

/// Recursively extracts the posted date (taken_at, created_at, upload_time, etc.) from an Instagram media object.
+ (nullable NSDate *)postedDateFromMediaObject:(nullable id)media;

/// Backward-compatible full date/time header using the shared formatter.
+ (nullable NSString *)spk_formattedDateHeader:(nullable NSDate *)date;


+ (NSString *)cacheAutoClearMode;
+ (BOOL)shouldAutomaticallyClearCacheNow;
+ (void)markCacheClearedNow;
+ (void)evaluateAutomaticCacheClearIfNeeded;

// Display View Controllers
+ (void)showShareVC:(id)item;
+ (void)showSettingsVC:(UIWindow *)window;
+ (void)showSettingsForTopicTitle:(NSString *)title;
+ (void)presentViewControllerInSheet:(UIViewController *)vc;

// Colours
+ (UIColor *)SPKColor_InstagramBlue;
+ (UIColor *)SPKColor_InstagramBackground;
+ (UIColor *)SPKColor_InstagramSecondaryBackground;
+ (UIColor *)SPKColor_InstagramTertiaryBackground;
+ (UIColor *)SPKColor_InstagramGroupedBackground;
+ (UIColor *)SPKColor_InstagramPrimaryText;
+ (UIColor *)SPKColor_InstagramSecondaryText;
+ (UIColor *)SPKColor_InstagramTertiaryText;
+ (UIColor *)SPKColor_InstagramSeparator;
+ (UIColor *)SPKColor_InstagramFavorite;
+ (UIColor *)SPKColor_InstagramDestructive;
+ (UIColor *)SPKColor_InstagramSuccess;
+ (UIColor *)SPKColor_InstagramPressedBackground;
+ (UIColor *)SPKColor_ListRowPressedOverlay;
+ (UIColor *)SPKColor_SettingsSwitchOnTintForTraitCollection:(UITraitCollection *)traitCollection;
+ (UIColor *)SPKColor_SettingsSwitchThumbTintForTraitCollection:(UITraitCollection *)traitCollection;

// Errors
+ (NSError *)errorWithDescription:(NSString *)errorDesc;
+ (NSError *)errorWithDescription:(NSString *)errorDesc code:(NSInteger)errorCode;
+ (BOOL)openURL:(NSURL *)url;
+ (void)dismissPresentedViewControllers;
+ (nullable NSString *)sanitizedInstagramUsername:(nullable NSString *)rawUsername;
+ (BOOL)openInstagramProfileForUsername:(NSString *)username;
+ (BOOL)openInstagramProfileForUsername:(NSString *)username fromViewController:(nullable UIViewController *)presentingVC;
+ (BOOL)openInstagramProfileForUser:(nullable id)user pk:(nullable NSString *)pk username:(nullable NSString *)username fromViewController:(nullable UIViewController *)presentingVC;
// Username -> pk, memoised for the session and showing the transient progress
// pill while it is in flight. Completion runs on the main thread, with nil when
// the username could not be resolved. Exposed so a caller that can PERSIST the
// answer (the gallery) never has to look it up twice.
//
// fullName is the display name the handle carries RIGHT NOW, so a caller holding
// a name from when the media was saved can tell whether the handle still belongs
// to the same person. It is nil on a memo hit, where the answer is already known.
+ (void)resolvePKForUsername:(NSString *)username
                  completion:(void (^)(NSString *_Nullable pk, NSString *_Nullable fullName))completion;
+ (BOOL)openInstagramMediaURL:(NSURL *)url;
/// As above, but `dismiss` NO leaves whatever is presented on screen. Only for
/// callers that intercept the resulting navigation themselves; with a modal still
/// up, the router's push lands behind it and is invisible.
+ (BOOL)openInstagramMediaURL:(NSURL *)url dismissingPresentedViewControllers:(BOOL)dismiss;

/// Presents an invisible full-screen host stack over `presentingVC` and pushes
/// `viewController` onto it, so the push runs IG's own navigation transition and
/// its swipe-back pops straight back to whatever was on screen. Returns NO when
/// IGNavigationController cannot be subclassed, leaving the caller to fall back.
+ (BOOL)pushViewControllerOnNativeHost:(UIViewController *)viewController
                    fromViewController:(nullable UIViewController *)presentingVC;
/// As above. `onDismiss` runs when the pushed screen is popped and the presenter is
/// live again -- the presenter gets no appearance callbacks of its own, because the
/// host sits over it rather than replacing it.
+ (BOOL)pushViewControllerOnNativeHost:(UIViewController *)viewController
                    fromViewController:(nullable UIViewController *)presentingVC
                             onDismiss:(nullable void (^)(void))onDismiss;
+ (BOOL)openPhotosApp;
+ (nullable NSURL *)sanitizedInstagramShareURL:(NSURL *)url;
+ (nullable NSString *)appendImgIndex:(NSInteger)imgIndex toURLString:(nullable NSString *)urlString;
+ (nullable NSString *)instagramShortcodeForMediaPK:(NSString *)mediaPK;

// Media
+ (NSURL *)getPhotoUrl:(IGPhoto *)photo;
+ (NSURL *)getPhotoUrlForMedia:(IGMedia *)media;
+ (NSURL *)getBestProfilePictureURLForUser:(id)user;

+ (NSURL *)getVideoUrl:(IGVideo *)video;
+ (NSURL *)getVideoUrlForMedia:(IGMedia *)media;

// Scroll Views
/// Lets `scrollView` scroll only while its content is taller than its viewport,
/// so a sheet whose contents already fit stays put instead of rubber banding.
/// Call from `viewDidLayoutSubviews` (and after a reload that changes height).
+ (void)updateScrollingForFittedContent:(nullable UIScrollView *)scrollView;

/// The sheet height that would show all of `scrollView`'s content at once, its
/// chrome included, or 0 while the scroll view has not been laid out yet.
///
/// Measured rather than estimated: the adjusted inset already carries the
/// navigation bar and the bottom safe area, so a detent resolver fed this value
/// lands on the exact height instead of a few points short.
+ (CGFloat)sheetHeightFittingContentOfScrollView:(nullable UIScrollView *)scrollView;

// View Controller Helpers
+ (UIViewController *)viewControllerForView:(UIView *)view;
+ (UIViewController *)viewControllerForAncestralView:(UIView *)view;
+ (UIViewController *)nearestViewControllerForView:(UIView *)view;

// Alerts
+ (BOOL)showConfirmation:(void (^)(void))okHandler title:(NSString *)title;
+ (BOOL)showConfirmation:(void (^)(void))okHandler title:(NSString *)title message:(NSString *)message;
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler title:(NSString *)title;
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler title:(NSString *)title message:(NSString *)message;
+ (BOOL)showConfirmation:(void (^)(void))okHandler;
+ (BOOL)showConfirmation:(void (^)(void))okHandler cancelHandler:(void (^)(void))cancelHandler;
+ (void)showRestartConfirmation;

// Math
+ (NSUInteger)decimalPlacesInDouble:(double)value;

// Dynamic selector helpers
+ (nullable NSNumber *)numericValueForObj:(id)obj selectorName:(NSString *)selectorName;

// Ivars
+ (id)getIvarForObj:(id)obj name:(const char *)name;
+ (void)setIvarForObj:(id)obj name:(const char *)name value:(id)value;

// Language-independent view/control matching. Prefer these over accessibilityLabel
// (which is localized) when identifying IG controls: an icon asset name and a
// control's tap target-action selector are both code symbols, stable across locales.
+ (nullable NSString *)igImageNameForImage:(nullable UIImage *)image;
+ (BOOL)control:(nullable UIControl *)control hasTapActionContaining:(NSString *)needle;

@end
