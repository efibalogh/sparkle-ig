#import <UIKit/UIKit.h>

// Instagram draws the Instants header two ways, chosen per account
// (ig_ios_instants_native_header): an in-content QuickSnap header view, or a system
// navigation bar of bar button items. Sparkle's header buttons are built here once and
// placed by whichever host is on screen: InstantsActionButton.xm / InstantsGalleryUpload.xm
// for the header view, InstantsNavigationBarItems.xm for the navigation bar.

NS_ASSUME_NONNULL_BEGIN

/// YES while a snap is being viewed and the camera page is not up. The action and
/// mark-seen buttons belong only there; the camera page belongs to the gallery button.
FOUNDATION_EXPORT BOOL SPKInstantsWindowIsConsuming(UIWindow *_Nullable window);

/// The viewer's action button, menu not yet configured.
FOUNDATION_EXPORT UIButton *SPKInstantsNewActionButton(void);
/// Builds the action menu once per button; `anchor` is any view in the viewer's window.
FOUNDATION_EXPORT void SPKInstantsConfigureActionButtonIfNeeded(UIButton *button, UIView *anchor);

/// The eye button that releases the displayed Instant under Manual Mark Seen.
FOUNDATION_EXPORT UIButton *SPKInstantsNewMarkSeenButton(void);

/// The camera page's gallery button wrapped in its screen-capture-hiding canvas, sized 44x44.
FOUNDATION_EXPORT UIView *SPKInstantsNewGalleryButtonHost(void);
/// Re-applies the menu icon choice to a host from `SPKInstantsNewGalleryButtonHost`.
FOUNDATION_EXPORT void SPKInstantsRefreshGalleryButtonHost(UIView *host);
/// The button inside a host from `SPKInstantsNewGalleryButtonHost`: the view its menu morphs from.
FOUNDATION_EXPORT UIButton *_Nullable SPKInstantsGalleryButtonInHost(UIView *host);
/// YES while the camera page is up and no snap is being viewed.
FOUNDATION_EXPORT BOOL SPKInstantsWindowWantsGalleryButton(UIWindow *_Nullable window);

/// Re-evaluates which Sparkle bar items show in the navigation bar header. Coalesced.
FOUNDATION_EXPORT void SPKInstantsNavigationBarItemsSetNeedsUpdate(void);

NS_ASSUME_NONNULL_END
