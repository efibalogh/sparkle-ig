#import "SPKStrings.h"
#import "SPKInstantsManualSeenUsers.h"

#import "../../Features/Instants/InstantsManualSeen.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../AutoSave/SPKAutoSaveFilter.h"
#import "../Messages/SPKDirectUserResolver.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKUserListViewController.h"

static NSString *const kSPKInstantsManualSeenEnabledKey = @"instants_manual_seen";

#pragma mark - Filter

SPKAutoSaveFilterConfig *SPKInstantsManualSeenUsersConfig(void) {
    static SPKAutoSaveFilterConfig *config = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [SPKAutoSaveFilterConfig new];
        config.enabledKey = kSPKInstantsManualSeenEnabledKey;
        config.allModeProvider = ^BOOL {
            return [SPKUtils getBoolPref:kSPKInstantsManualSeenEnabledKey];
        };
        config.excludedKey = @"instants_manual_seen_excluded";
        config.includedKey = @"instants_manual_seen_included";
        config.identityField = @"pk";
        config.sortField = @"username";
        config.subjectPlural = SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_USERS_TEXT");
        config.ruleNotificationIdentifier = kSPKNotificationInstantsMarkSeen;
        // Excluded / Included, the wording the Stories and Messages manual-seen lists use,
        // rather than auto-save's Selected.
        config.listTitleProvider = ^NSString * {
            return [SPKUtils getBoolPref:kSPKInstantsManualSeenEnabledKey] ? SPKL(@"INSTANTS_MANUAL_SEEN_LIST_EXCLUDED_TITLE")
                                                                            : SPKL(@"INSTANTS_MANUAL_SEEN_LIST_INCLUDED_TITLE");
        };
    });
    return config;
}

BOOL SPKInstantsManualSeenAllUsersMode(void) {
    return SPKAutoSaveFilterAllMode(SPKInstantsManualSeenUsersConfig());
}

NSUInteger SPKInstantsManualSeenUserCount(void) {
    return SPKAutoSaveFilterList(SPKInstantsManualSeenUsersConfig()).count;
}

BOOL SPKInstantsManualSeenCoversEveryone(void) {
    return SPKInstantsManualSeenAllUsersMode() && SPKInstantsManualSeenUserCount() == 0;
}

BOOL SPKInstantsManualSeenAppliesToAuthorPK(NSString *authorPK) {
    return SPKAutoSaveFilterApplies(SPKInstantsManualSeenUsersConfig(), authorPK);
}

SPKInstantsManualSeenAuthorTest SPKInstantsManualSeenMakeAuthorTest(void) {
    BOOL allMode = SPKInstantsManualSeenAllUsersMode();
    NSMutableSet<NSString *> *listed = [NSMutableSet set];
    for (NSDictionary *entry in SPKAutoSaveFilterList(SPKInstantsManualSeenUsersConfig())) {
        NSString *pk = SPKStringFromValue(entry[@"pk"]);
        if (pk.length > 0)
            [listed addObject:pk];
    }
    return ^BOOL(NSString *authorPK) {
        BOOL isListed = authorPK.length > 0 && [listed containsObject:authorPK];
        return allMode ? !isListed : isListed;
    };
}

#pragma mark - Current-user rule (action menu)

static NSDictionary *SPKInstantsManualSeenEntryForUsername(NSString *username) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return nil;
    for (NSDictionary *entry in SPKAutoSaveFilterList(SPKInstantsManualSeenUsersConfig())) {
        if ([SPKAutoSaveFilterNormalizedUsername(entry[@"username"]) isEqualToString:normalized])
            return entry;
    }
    // An entry added before a rename still matches through the pk the announcements map to.
    NSString *pk = SPKInstantsManualSeenAuthorPKForUsername(normalized);
    if (pk.length == 0)
        return nil;
    for (NSDictionary *entry in SPKAutoSaveFilterList(SPKInstantsManualSeenUsersConfig())) {
        if ([SPKStringFromValue(entry[@"pk"]) isEqualToString:pk])
            return entry;
    }
    return nil;
}

BOOL SPKInstantsManualSeenAppliesToUsername(NSString *username) {
    BOOL listed = SPKInstantsManualSeenEntryForUsername(username) != nil;
    return SPKInstantsManualSeenAllUsersMode() ? !listed : listed;
}

NSString *SPKInstantsManualSeenActionTitleForUsername(NSString *username) {
    if (SPKAutoSaveFilterNormalizedUsername(username).length == 0)
        return nil;
    return SPKInstantsManualSeenAppliesToUsername(username) ? SPKL(@"INSTANTS_ACTION_START_MARKING_SEEN_TITLE")
                                                            : SPKL(@"INSTANTS_ACTION_STOP_MARKING_SEEN_TITLE");
}

NSString *SPKInstantsManualSeenConfirmationMessageForUsername(NSString *username) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length == 0)
        return nil;
    NSString *format = SPKInstantsManualSeenAppliesToUsername(normalized)
                           ? SPKL(@"INSTANTS_ACTION_START_MARKING_SEEN_CONFIRMATION_MESSAGE_FORMAT")
                           : SPKL(@"INSTANTS_ACTION_STOP_MARKING_SEEN_CONFIRMATION_MESSAGE_FORMAT");
    return [NSString stringWithFormat:format, normalized];
}

static void SPKInstantsManualSeenFinishToggle(NSString *username, BOOL heldBefore,
                                              void (^completion)(BOOL, NSString *, NSString *)) {
    NSString *title = heldBefore
                          ? [NSString stringWithFormat:SPKL(@"INSTANTS_NOTIFICATION_MARKING_SEEN_ON_TITLE_FORMAT"), username]
                          : [NSString stringWithFormat:SPKL(@"INSTANTS_NOTIFICATION_MARKING_SEEN_OFF_TITLE_FORMAT"), username];
    if (completion)
        completion(YES, title, SPKInstantsManualSeenListTitle());
}

void SPKInstantsToggleManualSeenForUsername(NSString *username, void (^completion)(BOOL, NSString *, NSString *)) {
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    SPKAutoSaveFilterConfig *config = SPKInstantsManualSeenUsersConfig();
    if (normalized.length == 0) {
        if (completion)
            completion(NO, nil, nil);
        return;
    }
    BOOL heldBefore = SPKInstantsManualSeenAppliesToUsername(normalized);

    NSDictionary *existing = SPKInstantsManualSeenEntryForUsername(normalized);
    if (existing) {
        SPKAutoSaveFilterRemoveIdentity(config, existing[@"pk"]);
        SPKInstantsManualSeenFinishToggle(normalized, heldBefore, completion);
        return;
    }

    NSString *knownPK = SPKInstantsManualSeenAuthorPKForUsername(normalized);
    if (knownPK.length > 0) {
        SPKAutoSaveFilterToggleEntry(config, @{@"pk" : knownPK, @"username" : normalized});
        SPKInstantsManualSeenFinishToggle(normalized, heldBefore, completion);
    }

    // The lookup fills in the avatar and full name, and is the only source of the pk when the
    // author never appeared in an announcement.
    [SPKInstagramAPI resolveUserForUsername:normalized
                                 completion:^(NSDictionary *user, NSError *error) {
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         NSString *pk = [user isKindOfClass:NSDictionary.class] && !error
                                                            ? SPKStringFromValue(user[@"pk"] ?: user[@"id"])
                                                            : nil;
                                         if (pk.length == 0) {
                                             if (knownPK.length == 0 && completion)
                                                 completion(NO, nil, nil);
                                             return;
                                         }
                                         NSMutableDictionary *entry = [@{@"pk" : pk, @"username" : normalized} mutableCopy];
                                         NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]);
                                         NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);
                                         if (fullName.length > 0)
                                             entry[@"fullName"] = fullName;
                                         if (profilePicUrl.length > 0)
                                             entry[@"profilePicUrl"] = profilePicUrl;

                                         if (knownPK.length > 0) {
                                             // Already added above; enrich it in place unless the
                                             // user toggled it back off while this was in flight.
                                             if (!SPKAutoSaveFilterListContains(config, knownPK))
                                                 return;
                                             SPKAutoSaveFilterRemoveIdentity(config, knownPK);
                                             SPKAutoSaveFilterToggleEntry(config, entry);
                                             return;
                                         }
                                         SPKAutoSaveFilterToggleEntry(config, entry);
                                         SPKInstantsManualSeenFinishToggle(normalized, heldBefore, completion);
                                     });
                                 }];
}

NSString *SPKInstantsManualSeenListTitle(void) {
    return SPKAutoSaveFilterListTitle(SPKInstantsManualSeenUsersConfig());
}

#pragma mark - Users list

@interface SPKInstantsManualSeenUsersViewController : SPKAutoSaveFilterListViewController
@end

@implementation SPKInstantsManualSeenUsersViewController

- (instancetype)init {
    if ((self = [super initWithConfig:SPKInstantsManualSeenUsersConfig()])) {
        BOOL allUsers = SPKInstantsManualSeenAllUsersMode();
        self.showsAddButton = YES;
        self.infoText = allUsers ? SPKL(@"INSTANTS_MANUAL_SEEN_LIST_EXCLUDED_INFO")
                                 : SPKL(@"INSTANTS_MANUAL_SEEN_LIST_INCLUDED_INFO");
        self.emptyTitle = SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_NO_USERS_YET_TEXT");
        self.emptySubtitle = allUsers ? SPKL(@"INSTANTS_MANUAL_SEEN_LIST_EXCLUDED_EMPTY_SUBTITLE")
                                      : SPKL(@"INSTANTS_MANUAL_SEEN_LIST_INCLUDED_EMPTY_SUBTITLE");
    }
    return self;
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    NSString *username = SPKStringFromValue(entry[@"username"]);
    return username.length > 0 ? [@"@" stringByAppendingString:username] : nil;
}

// The base title is "<count> Selected"; keep the Excluded / Included title instead. The
// count is already on the settings row.
- (void)listDidUpdateItemCount:(NSUInteger)count {
    self.title = SPKInstantsManualSeenListTitle();
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
                                                         message:SPKL(@"INSTANTS_MANUAL_SEEN_LIST_ADD_USER_MESSAGE")
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

// The list keys on pk, which is what a snap's media PK carries, so a lookup that cannot
// produce one cannot produce a usable entry either.
- (void)lookupUsername:(NSString *)rawUsername {
    NSString *username = [SPKUtils sanitizedInstagramUsername:rawUsername];
    if (username.length == 0)
        return;

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
                                      NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                      if (pk.length == 0) {
                                          [strongSelf presentError:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_COULD_NOT_RESOLVE_USER_S_INSTAGRAM_ID_TEXT")];
                                          return;
                                      }

                                      NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: username;
                                      NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"";
                                      NSString *message = fullName.length > 0
                                                              ? [NSString stringWithFormat:@"@%@ (%@)", resolvedUsername, fullName]
                                                              : [@"@" stringByAppendingString:resolvedUsername];
                                      NSMutableDictionary *entry = [@{@"pk" : pk, @"username" : resolvedUsername, @"fullName" : fullName} mutableCopy];
                                      NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);
                                      if (profilePicUrl.length > 0)
                                          entry[@"profilePicUrl"] = profilePicUrl;

                                      [SPKIGAlertPresenter presentAlertFromViewController:strongSelf
                                                                                    title:SPKL(@"INSTANTS_MANUAL_SEEN_LIST_ADD_CONFIRM_TITLE")
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
    if (SPKAutoSaveFilterListContains(self.config, entry[@"pk"]))
        return;
    SPKAutoSaveFilterToggleEntry(self.config, entry);
    SPKNotify(kSPKNotificationInstantsMarkSeen,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKInstantsManualSeenListTitle(),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKInstantsManualSeenListViewController(void) {
    return [[SPKInstantsManualSeenUsersViewController alloc] init];
}
