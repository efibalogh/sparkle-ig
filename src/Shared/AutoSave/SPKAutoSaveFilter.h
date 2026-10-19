#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "../UI/SPKUserListViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// The "who does auto-save apply to" half of the feature, shared by every surface.
///
/// Each surface has the same shape -- a Filter Mode (All / Selected) over a pair of
/// lists -- but keys its list differently: stories by user pk, DMs by thread id,
/// Instants by username. Rather than clone the mode/storage/toggle/list machinery per
/// surface, each one hands over a config describing its keys and wording.
///
/// Lists are per-surface and never shared: excluding a user from story auto-save says
/// nothing about their DMs. Instants' Manually-Mark-Seen list reuses the machinery with its
/// own keys, its mode following its on/off switch through `allModeProvider`.

@interface SPKAutoSaveFilterConfig : NSObject

/// Master switch for the surface (e.g. `stories_auto_save`).
@property (nonatomic, copy) NSString *enabledKey;
/// Holds `all` or `selected`.
@property (nonatomic, copy) NSString *filterModeKey;
/// Overrides `filterModeKey` when set: YES selects the exclusion list, NO the inclusion
/// list. For surfaces whose mode follows another preference rather than a mode menu.
@property (nonatomic, copy, nullable) BOOL (^allModeProvider)(void);
/// Overrides the generated "Excluded Users" / "Selected Users" title, for lists that have to
/// match another surface's wording.
@property (nonatomic, copy, nullable) NSString * (^listTitleProvider)(void);
/// The two lists. Separate keys per mode, so switching Filter Mode back and forth
/// doesn't destroy the list built for the other mode.
@property (nonatomic, copy) NSString *excludedKey;
@property (nonatomic, copy) NSString *includedKey;

/// Entry field holding the identity: `pk`, `threadId`, or `username`. Entries are
/// deduped on it, and it's what `…Applies` is asked about.
@property (nonatomic, copy) NSString *identityField;
/// Entry field the list is sorted on (`username` / `threadName`).
@property (nonatomic, copy) NSString *sortField;
/// Plural subject for generated titles: "Users", "Chats".
@property (nonatomic, copy) NSString *subjectPlural;
/// Identifier for list-change notifications (add/remove/toggle).
@property (nonatomic, copy) NSString *ruleNotificationIdentifier;
/// Stores the include/exclude lists under the active account namespace even when
/// Sparkle's general Per-Account Settings switch is off.
@property (nonatomic, assign) BOOL alwaysAccountScopedLists;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Lowercased, @-stripped, whitespace-trimmed. Usernames are stored and compared in
/// this form, so a list entry added as "@Foo " still matches a resolved "foo".
NSString *SPKAutoSaveFilterNormalizedUsername(NSString *_Nullable username);

BOOL SPKAutoSaveFilterEnabled(SPKAutoSaveFilterConfig *config);
/// YES when Filter Mode is "All" (list = exclusions), NO when "Selected"
/// (list = inclusions).
BOOL SPKAutoSaveFilterAllMode(SPKAutoSaveFilterConfig *config);
/// "Excluded Users" / "Selected Chats" -- the active list for the current mode.
NSString *SPKAutoSaveFilterListTitle(SPKAutoSaveFilterConfig *config);

NSArray<NSDictionary *> *SPKAutoSaveFilterList(SPKAutoSaveFilterConfig *config);
void SPKAutoSaveFilterSetList(SPKAutoSaveFilterConfig *config, NSArray<NSDictionary *> *entries);
BOOL SPKAutoSaveFilterListContains(SPKAutoSaveFilterConfig *config, NSString *_Nullable identity);
/// Resolves mode + list into the actual decision for `identity`.
BOOL SPKAutoSaveFilterApplies(SPKAutoSaveFilterConfig *config, NSString *_Nullable identity);

/// Adds `entry` when absent, removes it when present. Returns YES when it ended up
/// listed. `entry` must carry the config's `identityField`.
BOOL SPKAutoSaveFilterToggleEntry(SPKAutoSaveFilterConfig *config, NSDictionary *entry);
void SPKAutoSaveFilterRemoveIdentity(SPKAutoSaveFilterConfig *config, NSString *_Nullable identity);

/// One-line state for the Downloads > Auto-Save surfaces row: "Off", "All Users",
/// "All · 2 excluded", "3 Selected".
NSString *SPKAutoSaveFilterSummary(SPKAutoSaveFilterConfig *config);

/// YES while any auto-save list screen is on-screen, so list-change notifications
/// don't offer a redundant "tap to open the list" affordance.
BOOL SPKAutoSaveFilterListUIVisible(void);

#ifdef __cplusplus
}
#endif

/// Shared base for the per-surface list screens. Handles on-screen tracking, the
/// count-aware title, and deletion; subclasses supply `buildItems` and their own
/// add flow.
@interface SPKAutoSaveFilterListViewController : SPKUserListViewController
@property (nonatomic, strong, readonly) SPKAutoSaveFilterConfig *config;
- (instancetype)initWithConfig:(SPKAutoSaveFilterConfig *)config;
/// Name shown in the "Removed X" toast for `entry` (e.g. "@user", a thread name).
- (nullable NSString *)removalDisplayNameForEntry:(NSDictionary *)entry;
@end

NS_ASSUME_NONNULL_END
