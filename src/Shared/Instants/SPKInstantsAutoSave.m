#import "SPKStrings.h"
#import "SPKInstantsAutoSave.h"

#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonCore.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../AutoSave/SPKAutoSave.h"
#import "../AutoSave/SPKAutoSaveFilter.h"
#import "../Downloads/SPKDownloadDuplicatePolicy.h"
#import "../Downloads/SPKDownloadTypes.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../Messages/SPKDirectUserResolver.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKUserListViewController.h"

static NSString *const kSPKInstantsAutoSaveEnabledKey = @"instants_auto_save";

#pragma mark - Filter

SPKAutoSaveFilterConfig *SPKInstantsAutoSaveFilterConfig(void) {
    static SPKAutoSaveFilterConfig *config = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [SPKAutoSaveFilterConfig new];
        config.enabledKey = kSPKInstantsAutoSaveEnabledKey;
        config.filterModeKey = @"instants_auto_save_filter_mode";
        config.excludedKey = @"instants_auto_save_excluded";
        config.includedKey = @"instants_auto_save_included";
        config.identityField = @"username";
        config.sortField = @"username";
        config.subject = SPKAutoSaveFilterSubjectUsers;
        config.ruleNotificationIdentifier = kSPKNotificationInstantsAutoSaveUserRule;
    });
    return config;
}

BOOL SPKInstantsAutoSaveAllUsersMode(void) {
    return SPKAutoSaveFilterAllMode(SPKInstantsAutoSaveFilterConfig());
}

NSString *SPKInstantsAutoSaveListTitle(void) {
    return SPKAutoSaveFilterListTitle(SPKInstantsAutoSaveFilterConfig());
}

BOOL SPKInstantsAutoSaveAppliesToUsername(NSString *username) {
    return SPKAutoSaveFilterApplies(SPKInstantsAutoSaveFilterConfig(), username);
}

NSString *SPKInstantsAutoSaveSettingsSummary(void) {
    return SPKAutoSaveFilterSummary(SPKInstantsAutoSaveFilterConfig());
}

#pragma mark - Current-user rule (action menu)

static NSMutableSet<NSString *> *SPKInstantsAutoSaveSessionKeys(void);

/// Fills in the pk, full name, and avatar for an entry that was added with only a
/// username, so a rule added from the viewer ends up looking like one added from
/// Settings. Fire-and-forget: the entry is already valid without any of this, so a
/// failed or slow lookup costs nothing but a plainer-looking row.
static void SPKInstantsAutoSaveEnrichEntryForUsername(NSString *username) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return;

    SPKAutoSaveFilterConfig *config = SPKInstantsAutoSaveFilterConfig();
    for (NSDictionary *entry in SPKAutoSaveFilterList(config)) {
        if ([SPKAutoSaveFilterNormalizedUsername(entry[@"username"]) isEqualToString:normalized]) {
            // Already enriched (added from Settings, or a repeat toggle).
            if (SPKStringFromValue(entry[@"pk"]).length > 0)
                return;
            break;
        }
    }

    [SPKInstagramAPI resolveUserForUsername:normalized
                                 completion:^(NSDictionary *user, NSError *error) {
                                     if (![user isKindOfClass:[NSDictionary class]] || error)
                                         return;
                                     NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                     NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]);
                                     NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);
                                     if (pk.length == 0 && fullName.length == 0 && profilePicUrl.length == 0)
                                         return;

                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         // Re-read rather than capture: the user may have
                                         // toggled the rule off, or switched Filter Mode to
                                         // the other list, while the lookup was in flight.
                                         NSArray<NSDictionary *> *current = SPKAutoSaveFilterList(config);
                                         NSMutableArray<NSDictionary *> *updated = [NSMutableArray arrayWithCapacity:current.count];
                                         BOOL changed = NO;
                                         for (NSDictionary *entry in current) {
                                             if (!changed && [SPKAutoSaveFilterNormalizedUsername(entry[@"username"]) isEqualToString:normalized]) {
                                                 NSMutableDictionary *enriched = [entry mutableCopy];
                                                 if (pk.length > 0)
                                                     enriched[@"pk"] = pk;
                                                 if (fullName.length > 0)
                                                     enriched[@"fullName"] = fullName;
                                                 if (profilePicUrl.length > 0)
                                                     enriched[@"profilePicUrl"] = profilePicUrl;
                                                 [updated addObject:enriched.copy];
                                                 changed = YES;
                                                 continue;
                                             }
                                             [updated addObject:entry];
                                         }
                                         if (changed)
                                             SPKAutoSaveFilterSetList(config, updated);
                                     });
                                 }];
}

// The menu action reads as "does auto-save currently apply to this user?", which in
// All Users mode means removing them from the exclusion list and in Selected Users
// mode means adding them to the inclusion list. Both are the same toggle underneath.
NSString *SPKInstantsAutoSaveActionTitleForUsername(NSString *username) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return nil;
    return SPKInstantsAutoSaveAppliesToUsername(normalized) ? SPKL(@"INSTANTS_ACTION_STOP_AUTO_SAVING_TITLE") : SPKL(@"INSTANTS_ACTION_START_AUTO_SAVING_TITLE");
}

NSString *SPKInstantsAutoSaveConfirmationTitleForUsername(NSString *username) {
    return SPKInstantsAutoSaveActionTitleForUsername(username);
}

NSString *SPKInstantsAutoSaveConfirmationMessageForUsername(NSString *username) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return nil;
    return SPKInstantsAutoSaveAppliesToUsername(normalized)
               ? [NSString stringWithFormat:SPKL(@"INSTANTS_ACTION_STOP_CONFIRMATION_MESSAGE_FORMAT"), normalized]
               : [NSString stringWithFormat:SPKL(@"INSTANTS_ACTION_START_CONFIRMATION_MESSAGE_FORMAT"), normalized];
}

BOOL SPKInstantsToggleAutoSaveForUsername(NSString *username,
                                          NSString **notificationTitle,
                                          NSString **notificationSubtitle) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return NO;

    BOOL appliedBefore = SPKInstantsAutoSaveAppliesToUsername(normalized);
    // An instant resolved from the view carries no author pk, so only the username is
    // known at this point. The entry is stored immediately on that alone -- the list
    // keys on username, so it is already complete as a rule -- and the pk, full name,
    // and avatar are filled in afterwards without blocking the toggle.
    BOOL listed = SPKAutoSaveFilterToggleEntry(SPKInstantsAutoSaveFilterConfig(), @{@"username" : normalized});
    if (listed)
        SPKInstantsAutoSaveEnrichEntryForUsername(normalized);

    // Users who just started auto-saving shouldn't have to tap forward to get the
    // instant they're looking at. The snap itself is re-considered by the caller,
    // which owns the view; all this can do is drop the "already seen" memos so the
    // next pass isn't short-circuited.
    if (!appliedBefore)
        [SPKInstantsAutoSaveSessionKeys() removeAllObjects];

    if (notificationTitle) {
        *notificationTitle = appliedBefore
                                 ? [NSString stringWithFormat:SPKL(@"INSTANTS_NOTIFICATION_AUTO_SAVE_OFF_TITLE_FORMAT"), normalized]
                                 : [NSString stringWithFormat:SPKL(@"INSTANTS_NOTIFICATION_AUTO_SAVE_ON_TITLE_FORMAT"), normalized];
    }
    if (notificationSubtitle)
        *notificationSubtitle = SPKInstantsAutoSaveListTitle();
    return YES;
}

#pragma mark - Auto-saver

// Snap keys already handled this viewer session -- both saved snaps and snaps rejected
// by the filter, so a rejected snap costs one list lookup rather than one per pass.
static NSMutableSet<NSString *> *SPKInstantsAutoSaveSessionKeys(void) {
    static NSMutableSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

void SPKInstantsAutoSaveViewerSessionDidEnd(void) {
    [SPKInstantsAutoSaveSessionKeys() removeAllObjects];
}

// Keys are usually 700-character CDN URLs; logs get the tail, which is enough to tell
// two snaps apart.
static NSString *SPKInstantsAutoSaveLoggableKey(NSString *key) {
    if (key.length <= 24)
        return key ?: @"(none)";
    return [NSString stringWithFormat:@"…%@", [key substringFromIndex:key.length - 24]];
}

void SPKInstantsAutoSaveConsiderSnap(id snap, NSString *username, NSString *snapKey) {
    if (!snap)
        return;
    if (![SPKUtils getBoolPref:kSPKInstantsAutoSaveEnabledKey])
        return;

    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return;

    if (snapKey.length == 0)
        return;

    NSMutableSet<NSString *> *sessionKeys = SPKInstantsAutoSaveSessionKeys();
    if ([sessionKeys containsObject:snapKey])
        return;

    if (!SPKInstantsAutoSaveAppliesToUsername(normalized)) {
        [sessionKeys addObject:snapKey];
        return;
    }

    // Claim the snap before any async work so a later pass over the same snap can't
    // queue a second download for it.
    [sessionKeys addObject:snapKey];

    NSURL *photoURL = nil;
    NSURL *videoURL = nil;
    SPKGallerySaveMetadata *metadata = nil;
    if (!SPKResolveGalleryDownloadForMedia(snap, SPKActionButtonSourceInstants, normalized,
                                           &photoURL, &videoURL, &metadata)) {
        SPKLog(@"Instants", @"[Sparkle AutoSave] No downloadable media for snap=%@ user=@%@", SPKInstantsAutoSaveLoggableKey(snapKey), normalized);
        return;
    }

    // Durable guard: the session set only covers this viewer session.
    SPKGalleryMediaType mediaType = videoURL ? SPKGalleryMediaTypeVideo : SPKGalleryMediaTypeImage;
    SPKDownloadDestination destination = SPKAutoSaveDestination();
    if ([SPKDownloadDuplicatePolicy destinationContainsMediaForMetadata:metadata
                                                              mediaType:mediaType
                                                            destination:destination]) {
        SPKLog(@"Instants", @"[Sparkle AutoSave] Already in %@, skipping snap=%@ user=@%@",
               SPKDownloadDestinationDisplayName(destination), SPKInstantsAutoSaveLoggableKey(snapKey), normalized);
        return;
    }

    SPKLog(@"Instants", @"[Sparkle AutoSave] Saving instant snap=%@ user=@%@ video=%d", SPKInstantsAutoSaveLoggableKey(snapKey), normalized, videoURL != nil);
    if (!SPKAutoSaveSubmitMedia(snap, SPKActionButtonSourceInstants, normalized, kSPKNotificationInstantsAutoSave)) {
        // Nothing was queued, so let the snap be retried while it's still displayed.
        [sessionKeys removeObject:snapKey];
        SPKLog(@"Instants", @"[Sparkle AutoSave] Failed to submit snap=%@ user=@%@", SPKInstantsAutoSaveLoggableKey(snapKey), normalized);
    }
}

#pragma mark - Auto-save users list

@interface SPKInstantsAutoSaveUsersViewController : SPKAutoSaveFilterListViewController
@end

@implementation SPKInstantsAutoSaveUsersViewController

- (instancetype)init {
    if ((self = [super initWithConfig:SPKInstantsAutoSaveFilterConfig()])) {
        BOOL allUsers = SPKInstantsAutoSaveAllUsersMode();
        self.showsAddButton = YES;
        self.infoText = allUsers
                            ? SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_FILTER_MODE_USERS_SO_EVERY_INSTANT_OPEN_SAVED_EXCEPT_TEXT")
                            : SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_FILTER_MODE_SELECTED_USERS_SO_ONLY_INSTANTS_USERS_LIST_TEXT");
        self.emptyTitle = SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_NO_USERS_YET_TEXT");
        self.emptySubtitle = allUsers
                                 ? SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADD_USERS_WHOSE_INSTANTS_SHOULD_NEVER_AUTO_SAVED_HERE_TEXT")
                                 : SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADD_USERS_WHOSE_INSTANTS_SHOULD_SAVED_AUTOMATICALLY_OPEN_HERE_TEXT");
    }
    return self;
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    NSString *username = SPKStringFromValue(entry[@"username"]);
    return username.length > 0 ? [@"@" stringByAppendingString:username] : nil;
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in SPKAutoSaveFilterList(self.config)) {
        NSString *username = SPKStringFromValue(entry[@"username"]);
        NSString *pk = SPKStringFromValue(entry[@"pk"]);
        NSString *fullName = SPKStringFromValue(entry[@"fullName"]);
        NSString *profilePicUrl = SPKStringFromValue(entry[@"profilePicUrl"]);
        if (profilePicUrl.length == 0 && pk.length > 0)
            profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

        SPKUserListItem *item = [SPKUserListItem new];
        item.pk = pk;
        item.title = username.length > 0 ? [@"@" stringByAppendingString:username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
        item.subtitle = fullName.length > 0 ? fullName : nil;
        item.avatarURLString = profilePicUrl;
        item.representedObject = entry;
        [items addObject:item];
    }
    return items;
}

- (void)presentError:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_UNABLE_ADD_USER_TEXT")
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleCancel handler:nil] ]];
}

- (void)didTapAdd {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                           title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADD_USER_TEXT")
                                                         message:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ENTER_INSTAGRAM_USERNAME_WHOSE_INSTANTS_SHOULD_AUTO_SAVED_TEXT")
                                                     placeholder:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USERNAME_TEXT")
                                                     initialText:nil
                                                 autocapitalized:NO
                                                    confirmTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        [weakSelf lookupUsername:text];
                                                    }
                                                     cancelBlock:nil];
}

// The list keys on username, so the lookup is only for the avatar, full name, and to
// catch typos -- a failed lookup still leaves a usable entry.
- (void)lookupUsername:(NSString *)rawUsername {
    NSString *username = [SPKUtils usernameFromUserInput:rawUsername];
    if (username.length == 0) {
        [self presentError:SPKL(@"NETWORK_INSTAGRAM_API_INVALID_USERNAME_TEXT")];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [SPKInstagramAPI resolveUserForUsername:username
                                  completion:^(NSDictionary *user, NSError *error) {
                                      __strong typeof(weakSelf) strongSelf = weakSelf;
                                      if (!strongSelf)
                                          return;
                                      if (![user isKindOfClass:[NSDictionary class]] || error) {
                                          [strongSelf presentError:[NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USER_VALUE_NOT_FOUND_FORMAT"), username]];
                                          return;
                                      }

                                      NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: username;
                                      NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"";
                                      NSString *message = fullName.length > 0
                                                              ? [NSString stringWithFormat:@"@%@ (%@)", resolvedUsername, fullName]
                                                              : [@"@" stringByAppendingString:resolvedUsername];
                                      NSMutableDictionary *entry = [@{@"username" : resolvedUsername, @"fullName" : fullName} mutableCopy];
                                      NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                      if (pk.length > 0)
                                          entry[@"pk"] = pk;
                                      NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);
                                      if (profilePicUrl.length > 0)
                                          entry[@"profilePicUrl"] = profilePicUrl;

                                      [SPKIGAlertPresenter presentAlertFromViewController:strongSelf
                                                                                    title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_AUTO_SAVE_INSTANTS_QUESTION")
                                                                                  message:message
                                                                                  actions:@[
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                  style:SPKIGAlertActionStyleCancel
                                                                                                                handler:nil],
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD")
                                                                                                                  style:SPKIGAlertActionStyleDefault
                                                                                                                handler:^{
                                                                                                                    [strongSelf addResolvedEntry:entry.copy username:resolvedUsername];
                                                                                                                }],
                                                                                  ]];
                                  }];
}

- (void)addResolvedEntry:(NSDictionary *)entry username:(NSString *)username {
    if (SPKAutoSaveFilterListContains(self.config, username))
        return;
    SPKAutoSaveFilterToggleEntry(self.config, entry);
    SPKNotify(kSPKNotificationInstantsAutoSaveUserRule,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKInstantsAutoSaveListTitle(),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKInstantsAutoSaveListViewController(void) {
    return [[SPKInstantsAutoSaveUsersViewController alloc] init];
}
