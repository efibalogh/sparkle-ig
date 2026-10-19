#import <Foundation/Foundation.h>

@class UIView;

/// Manually Mark Seen: keeps viewed Instants locally unseen so they stay in the tray until
/// you choose to release one.
///
/// Instagram derives the available snap list as `timeOrderedQuicksnaps` minus `seenSnapPks`,
/// and hydrates `seenSnapPks` from `kIGQuickSnapSeenStateKey` in the session `IGUserDefaults`.
/// It works in three parts, and all three are load bearing:
///
/// 1. Every media PK the viewer consumes is stripped back out of that stored key, silently,
///    so the persisted seen state never records the view.
/// 2. The held snaps never reach the server as seen. When every author is held the seen sync
///    is suppressed outright; when only some are (the users list), the sync runs and the held
///    ids are filtered out of the seen request it builds.
/// 3. When the viewer closes, the list is refetched. This is the step that actually restores
///    the tray: Instagram purges the consumed media out of `timeOrderedQuicksnaps` when the
///    viewer closes, so reloading the seen state alone has nothing left to un-filter
///    (`availableTimeOrderedSnaps` reads 0 at that point, device-confirmed). The refetch
///    brings them back, and 1 and 2 are what make them come back unseen.
///
/// No address arithmetic and no Swift-internal hooks.

/// YES when the switch is on, or when it is off with Included Users listed. Re-read at call
/// time. Which authors are actually held is `SPKInstantsManualSeenAppliesToAuthorPK`.
FOUNDATION_EXPORT BOOL SPKInstantsManualSeenIsEnabled(void);

/// Author pk for a username seen in a service announcement, or nil. Lets the action menu,
/// which only has the author label, add a user to the pk-keyed list without a network lookup.
FOUNDATION_EXPORT NSString *SPKInstantsManualSeenAuthorPKForUsername(NSString *username);

/// Records every snap the service announces so the feature knows which PKs to keep unseen.
/// Cheap: PK reads only, no media resolution.
FOUNDATION_EXPORT void SPKInstantsManualSeenNoteServiceMedia(NSArray *mediaList);

/// Strips every protected PK from the persisted seen state. Call this on every service
/// update: Instagram rewrites that key as it consumes snaps, so keeping it clean has to be
/// continuous rather than a single pass at the end.
///
/// While the viewer is open this only rewrites the stored value and does not ask Instagram
/// to reload it. Reloading mid-session pushes the snap back into the live available list
/// under the viewer, which makes a consumed Instant reappear instead of letting the viewer
/// finish and close.
FOUNDATION_EXPORT void SPKInstantsManualSeenHoldUnseen(id service);

/// Tells the feature whether the consumption viewer is on screen, which is what decides between
/// the silent write above and an immediate reload.
FOUNDATION_EXPORT void SPKInstantsManualSeenSetViewerOpen(BOOL open);

/// Closes a viewing session: strips anything left over, reloads the seen state, then forces a
/// refetch so the tray picks the Instants back up. This is the only point at which the feature
/// makes snaps reappear, so the viewer plays through to the end and dismisses normally.
FOUNDATION_EXPORT void SPKInstantsManualSeenEndViewerSession(id service);

/// Installs the seen-sync block, so a tray refetch does not come back with the Instants
/// already marked seen server-side.
FOUNDATION_EXPORT void SPKInstallInstantsManualSeenHooksIfEnabled(void);

/// Whether the eye button belongs on the Instant on screen. Read on every header layout, so it
/// only returns a cached decision: the author check runs on the viewer's open and tap events
/// (below), never on layout. With every author held it is simply YES.
FOUNDATION_EXPORT BOOL SPKInstantsManualSeenShouldShowEyeButton(void);

/// The header the eye button lives in, so a decision that lands after layout can ask it to
/// lay out again.
FOUNDATION_EXPORT void SPKInstantsManualSeenRegisterEyeButtonHost(UIView *header);

/// The displayed snap may have changed: the viewer appeared (`expectsChange` NO) or a tap
/// advanced it (YES). Resolves the author off the main path with a short retry, then updates
/// the eye button decision.
FOUNDATION_EXPORT void SPKInstantsManualSeenDisplayedSnapMayHaveChanged(UIView *viewInHierarchy, BOOL expectsChange);

/// The viewer closed: drops the decision and strands in-flight resolves.
FOUNDATION_EXPORT void SPKInstantsManualSeenDisplayedSnapSessionEnded(void);

/// Releases one snap: stops protecting it and marks it seen for real. This is the manual
/// half of the feature, so a held Instant can be cleared deliberately.
FOUNDATION_EXPORT void SPKInstantsManualSeenMarkMediaPK(NSString *mediaPK);

