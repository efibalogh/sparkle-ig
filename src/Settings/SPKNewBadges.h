#import <UIKit/UIKit.h>

#import "../Shared/ActionButton/ActionButtonCore.h"
#import "SPKSetting.h"

NS_ASSUME_NONNULL_BEGIN

/// `tools_settings_new_badges`: `until_seen` (default), `keep` or `off`.
FOUNDATION_EXPORT NSString *const kSPKPrefSettingsNewBadges;

/// Posted on the main thread after rows are marked seen, so pages further down the
/// navigation stack drop the dots that pointed at them. The object is the page that
/// marked them.
FOUNDATION_EXPORT NSNotificationName const SPKNewBadgesDidChangeNotification;

typedef NS_ENUM(NSInteger, SPKNewBadgeState) {
    SPKNewBadgeStateNone,
    /// The row itself is new: NEW pill after its title.
    SPKNewBadgeStateRow,
    /// A row somewhere inside this navigation row's page is new: dot after its title.
    SPKNewBadgeStateContainsNew,
};

/// Tags a row as introduced in `version` (`v1.7.0`). The row's `defaultsKey` is its
/// seen identity; rows without one (navigation, buttons) must use the ID variant.
///
/// A row is new while its version's major.minor is the installed one or later, so
/// every v1.7.x build badges v1.7.0 rows and the badges retire on v1.8.0 by
/// themselves. Badges ignore how long Sparkle has been installed: a user moving
/// between installs has no reliable upgrade history.
SPKSetting *SPKSettingMarkedNew(SPKSetting *setting, NSString *version);
SPKSetting *SPKSettingMarkedNewWithID(SPKSetting *setting, NSString *version, NSString *identifier);

SPKNewBadgeState SPKNewBadgeStateForSetting(SPKSetting *setting);

/// New items on custom pages that are not settings rows, { identifier : version }.
NSDictionary<NSString *, NSString *> *SPKNewBadgeItemVersions(void);
/// Identifier for an action newly offered in one action button's action list.
NSString *SPKNewBadgeActionItemIdentifier(SPKActionButtonSource source, NSString *actionIdentifier);
/// The registered action items for a source, for its Configure Actions row.
NSArray<NSString *> *SPKNewBadgeActionItemsForSource(SPKActionButtonSource source);
BOOL SPKNewBadgeItemIsNew(NSString *identifier);
/// Whether any row in these sections, or behind them, is new.
BOOL SPKNewBadgeSectionsContainNew(NSArray *sections);
/// `icon` drawn in `iconColor` with the dot at its top trailing corner, for a bar
/// button that leads to new settings.
UIImage *SPKNewBadgeIconWithDot(UIImage *icon, UIColor *iconColor, UITraitCollection *traits);
/// Records custom-page items the user has seen. No-op unless the mode is `until_seen`.
void SPKNewBadgesMarkItemsSeen(NSArray<NSString *> *identifiers, id _Nullable sender);

/// Records rows the user has seen. No-op unless the mode is `until_seen`.
void SPKNewBadgesMarkSeen(NSArray<SPKSetting *> *settings, id _Nullable sender);

/// The row title with the pill or dot appended, in the given font and color. The
/// badge is drawn for `traits` (light or dark).
NSAttributedString *SPKNewBadgeAttributedTitle(NSString *title, UIFont *font, UIColor *color, SPKNewBadgeState state, UITraitCollection *traits);

/// Spoken after the title for VoiceOver.
NSString *SPKNewBadgeAccessibilityText(SPKNewBadgeState state);

NS_ASSUME_NONNULL_END
