#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SPKTabLayoutDefault;
FOUNDATION_EXPORT NSString *const SPKTabLayoutCustom;
FOUNDATION_EXPORT NSString *const SPKTabLayoutClassic;

FOUNDATION_EXPORT NSString *const SPKTabIdentifierFeed;
FOUNDATION_EXPORT NSString *const SPKTabIdentifierClips;
FOUNDATION_EXPORT NSString *const SPKTabIdentifierDirect;
FOUNDATION_EXPORT NSString *const SPKTabIdentifierSearch;
FOUNDATION_EXPORT NSString *const SPKTabIdentifierProfile;
/// The Create launcher. It is only a tab in the Classic layout and is never a
/// navigable destination, so it is deliberately outside the canonical order.
FOUNDATION_EXPORT NSString *const SPKTabIdentifierCreate;
/// Saved. Instagram has no Saved surface of its own, so this entry is drawn by
/// borrowing a hidden native tab (the "carrier"): the carrier keeps its surface
/// and swipe slot while its icon and destination become Saved. That is why
/// enabling Saved requires hiding one of the five native destinations, and why
/// the bar never exceeds five tabs.
FOUNDATION_EXPORT NSString *const SPKTabIdentifierSaved;

FOUNDATION_EXPORT NSString *const SPKTabSavedCarrierNone;

FOUNDATION_EXPORT NSString *const SPKPrefTabLayout;
FOUNDATION_EXPORT NSString *const SPKPrefCustomTabOrder;
FOUNDATION_EXPORT NSString *const SPKPrefSavedTabCarrier;
/// Hide the tab bar entirely once the configuration leaves a single tab. The key
/// still carries its original "messages only" name so existing installs keep
/// their setting; the behaviour is no longer limited to Messages.
FOUNDATION_EXPORT NSString *const SPKPrefHideTabBarWhenSingle;
/// Show the Sparkle shortcut in the Direct inbox header. Messages-specific by
/// nature: that is the header it lives in.
FOUNDATION_EXPORT NSString *const SPKPrefInboxHeaderShortcut;
/// One-shot marker: the legacy "replace Reels with Saved" bar has been expressed
/// as a Saved entry in the order array.

#ifdef __cplusplus
extern "C" {
#endif

/// The five navigable destinations, in Instagram's standard order.
NSArray<NSString *> *SPKCanonicalTabIdentifiers(void);
/// Everything with a visibility toggle: the canonical destinations plus Create.
NSArray<NSString *> *SPKTabEditableIdentifiers(void);
/// The identifiers an order array may contain: the canonical five plus Saved.
NSArray<NSString *> *SPKTabOrderableIdentifiers(void);
/// Which hidden bar slot Saved should borrow for a given layout, most to least
/// preferred. Reels comes first outside Classic: it is the slot Saved has always
/// used. Classic swaps the set because its bar is a different shape - Create is
/// a real bar item there (and the cheapest slot to give up), while Messages is
/// only the feed header link and owns no slot to lend.
NSArray<NSString *> *SPKTabSavedCarrierPreferenceForLayout(NSString *layout);
/// The union of every layout's candidates, for validation only.
NSArray<NSString *> *SPKTabSavedCarrierPreference(void);
/// Whether the identifier occupies a tab bar slot in this layout. Create is a
/// bar item only in Classic; Messages is a bar item everywhere except Classic.
BOOL SPKTabOccupiesBarSlot(NSString *identifier, NSString *layout);
NSArray<NSString *> *SPKNormalizeTabOrder(id _Nullable value);
NSString *SPKNormalizedTabLayout(id _Nullable value);
NSString *SPKNormalizedSavedCarrier(id _Nullable value);

/// The slot Saved is drawing in right now, or `SPKTabSavedCarrierNone`. Saved is
/// a Custom-layout entry that borrows a hidden tab's slot, so the stored carrier
/// only counts while that layout is active and that tab is actually hidden.
NSString *SPKEffectiveSavedCarrier(void);

/// The identifier of the only destination the tab bar would show, or nil when it
/// would show none or several. Saved counts as a destination (it answers for its
/// carrier), Create does not - it is a launcher, but while it is visible the bar
/// still has a second button, so the bar is not single-tab either.
/// `hidden` holds the identifiers whose hide flag is set.
NSString *_Nullable SPKSingleVisibleTabIdentifier(NSString *layout,
                                                  NSSet<NSString *> *hidden,
                                                  NSString *savedCarrier);
/// The same answer for the configuration currently stored in preferences.
NSString *_Nullable SPKSingleVisibleTabIdentifierFromPreferences(void);
/// Whether the tab bar may be hidden when only `identifier` remains. Hiding it
/// removes the long-press that opens Sparkle Settings, so it is only offered for
/// tabs that keep another way in: Messages (long-press the composer button) and
/// Feed (the header shortcut button).
BOOL SPKSingleTabAllowsHidingTabBar(NSString *_Nullable identifier);

NSString *SPKTabTitle(NSString *identifier);
NSString *SPKTabIconName(NSString *identifier);
NSString *SPKTabHidePreferenceKey(NSString *identifier);
NSString *SPKTabLaunchPreferenceValue(NSString *identifier);
NSString *_Nullable SPKTabIdentifierForLaunchPreference(NSString *value);
/// The tab Instagram will be showing once launch finishes, resolved from
/// preferences alone so it can be asked before the tab bar exists. Follows the
/// same rules as the launch selection: a chosen tab that is hidden falls back to
/// the first visible one, and "default" means the first arranged tab in Custom
/// and Feed elsewhere unless it is hidden. Saved is returned as Saved, not as
/// its carrier. Nil when no destination is visible.
NSString *_Nullable SPKEffectiveLaunchTabIdentifierFromPreferences(void);

/// Migrates legacy order presets and the old Reels-only Saved toggle, then
/// normalizes persisted custom arrays. Safe to call repeatedly.
void SPKMigrateTabConfigurationIfNeeded(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
