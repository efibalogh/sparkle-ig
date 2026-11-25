#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a destination may be offered. A screen that only makes sense as an
/// action (opening the clipboard link) is not offered as a tab, and a screen
/// Sparkle cannot host inside a tab is not offered there either.
typedef NS_OPTIONS(NSUInteger, SPKDestinationPlacement) {
    SPKDestinationPlacementHold = 1 << 0,
    SPKDestinationPlacementHeaderButton = 1 << 1,
    SPKDestinationPlacementTab = 1 << 2,
};

typedef NS_ENUM(NSInteger, SPKDestinationGroup) {
    SPKDestinationGroupSparkle = 0,
    SPKDestinationGroupInstagram,
    SPKDestinationGroupAction,
};

FOUNDATION_EXPORT NSString *const SPKDestinationSettings;
FOUNDATION_EXPORT NSString *const SPKDestinationGallery;
FOUNDATION_EXPORT NSString *const SPKDestinationAnalyzer;
FOUNDATION_EXPORT NSString *const SPKDestinationDeletedMessages;
FOUNDATION_EXPORT NSString *const SPKDestinationDownloads;
FOUNDATION_EXPORT NSString *const SPKDestinationSavedInstants;
FOUNDATION_EXPORT NSString *const SPKDestinationInstagramSaved;
FOUNDATION_EXPORT NSString *const SPKDestinationClipboardLink;
FOUNDATION_EXPORT NSString *const SPKDestinationClipboardLinkOrUsername;

/// One screen or action that Sparkle can open from a shortcut: a tab hold, the
/// feed header button, or a tab of its own.
@interface SPKDestination : NSObject
/// Stable identifier, stored in preferences. Never rename one.
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
/// The title where space is tight (the chosen value beside a row). Same as
/// `title` unless the destination gives a shorter one.
@property (nonatomic, copy, readonly) NSString *shortTitle;
/// Settings icon name (SPKSettingsIcon / the asset map).
@property (nonatomic, copy, readonly) NSString *iconName;
@property (nonatomic, readonly) SPKDestinationGroup group;
@property (nonatomic, readonly) SPKDestinationPlacement placements;
/// Opens the destination. `window` is the window the shortcut fired in, when known.
- (void)openFromWindow:(nullable UIWindow *)window;
/// A fresh root controller for hosting the screen inside a tab, or nil when the
/// destination has no tab presentation of its own.
- (nullable UIViewController *)makeTabRootViewController;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Every destination, in display order: Sparkle screens, then Instagram's, then actions.
NSArray<SPKDestination *> *SPKAllDestinations(void);
NSArray<SPKDestination *> *SPKDestinationsForPlacement(SPKDestinationPlacement placement);
SPKDestination *_Nullable SPKDestinationForIdentifier(NSString *_Nullable identifier);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
