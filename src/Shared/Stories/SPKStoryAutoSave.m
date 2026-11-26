#import "SPKStrings.h"
#import "SPKStoryAutoSave.h"

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
#import "SPKStoryContext.h"

static NSString *const kSPKStoryAutoSaveEnabledKey = @"stories_auto_save";
static NSString *const kSPKStoryAutoSaveFilterModeKey = @"stories_auto_save_filter_mode";

#pragma mark - Filter

// Stories key their list by user pk. The list keys predate the shared filter layer and
// are unchanged, so existing users' lists carry over untouched.
SPKAutoSaveFilterConfig *SPKStoryAutoSaveFilterConfig(void) {
    static SPKAutoSaveFilterConfig *config = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [SPKAutoSaveFilterConfig new];
        config.enabledKey = kSPKStoryAutoSaveEnabledKey;
        config.filterModeKey = kSPKStoryAutoSaveFilterModeKey;
        config.excludedKey = @"stories_auto_save_excluded";
        config.includedKey = @"stories_auto_save_included";
        config.identityField = @"pk";
        config.sortField = @"username";
        config.subject = SPKAutoSaveFilterSubjectUsers;
        config.ruleNotificationIdentifier = kSPKNotificationStoryAutoSaveUserRule;
    });
    return config;
}

BOOL SPKStoryAutoSaveAllUsersMode(void) {
    return SPKAutoSaveFilterAllMode(SPKStoryAutoSaveFilterConfig());
}

NSString *SPKStoryAutoSaveListTitle(void) {
    return SPKAutoSaveFilterListTitle(SPKStoryAutoSaveFilterConfig());
}

NSArray<NSDictionary *> *SPKStoryAutoSaveUserList(void) {
    return SPKAutoSaveFilterList(SPKStoryAutoSaveFilterConfig());
}

BOOL SPKStoryAutoSaveListContainsUser(NSString *pk) {
    return SPKAutoSaveFilterListContains(SPKStoryAutoSaveFilterConfig(), pk);
}

BOOL SPKStoryAutoSaveAppliesToUser(NSString *pk) {
    return SPKAutoSaveFilterApplies(SPKStoryAutoSaveFilterConfig(), pk);
}

void SPKStoryToggleAutoSaveForPK(NSString *pk, NSString *username, NSString *fullName, NSString *profilePicUrl) {
    if (pk.length == 0)
        return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"pk"] = pk;
    NSString *normalized = SPKAutoSaveFilterNormalizedUsername(username);
    if (normalized.length > 0)
        entry[@"username"] = normalized;
    entry[@"fullName"] = fullName ?: @"";
    if (profilePicUrl.length > 0)
        entry[@"profilePicUrl"] = profilePicUrl;
    SPKAutoSaveFilterToggleEntry(SPKStoryAutoSaveFilterConfig(), entry);
}

#pragma mark - Auto-saver

// Media IDs already handled this viewer session -- both saved items and items
// rejected by the allow-list, so a rejected item costs one list lookup rather
// than one per `-layoutSubviews` pass.
static NSMutableSet<NSString *> *SPKStoryAutoSaveSessionKeys(void) {
    static NSMutableSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

void SPKStoryAutoSaveViewerSessionDidEnd(void) {
    [SPKStoryAutoSaveSessionKeys() removeAllObjects];
}

void SPKStoryAutoSaveConsiderOverlay(UIView *overlayView) {
    if (!overlayView)
        return;
    if (![SPKUtils getBoolPref:kSPKStoryAutoSaveEnabledKey])
        return;

    // Memoized per displayed item on the overlay, so this is cheap on repeat passes.
    SPKStoryContext *context = SPKStoryContextFromOverlay(overlayView);
    if (!context.media)
        return;

    NSString *mediaID = SPKStoryMediaIdentifierForContext(context);
    if (mediaID.length == 0)
        return;

    NSMutableSet<NSString *> *sessionKeys = SPKStoryAutoSaveSessionKeys();
    if ([sessionKeys containsObject:mediaID])
        return;

    NSString *userPK = SPKStoryUserPKFromMediaObject(context.media);
    if (!SPKStoryAutoSaveAppliesToUser(userPK)) {
        [sessionKeys addObject:mediaID];
        return;
    }

    // Claim the item before any async work so later passes over the same item
    // can't queue a second download for it.
    [sessionKeys addObject:mediaID];

    NSString *username = SPKStoryUsernameForContext(context);
    NSURL *videoURL = nil;
    SPKGallerySaveMetadata *metadata = nil;
    if (!SPKResolveGalleryDownloadForMedia(context.media, SPKActionButtonSourceStories, username,
                                           NULL, &videoURL, &metadata)) {
        SPKLog(@"Stories", @"[Sparkle AutoSave] No downloadable media for story mediaID=%@ user=@%@", mediaID, username);
        return;
    }
    BOOL isVideo = (videoURL != nil);

    // Durable guard: the session set only covers this viewer session.
    SPKGalleryMediaType mediaType = isVideo ? SPKGalleryMediaTypeVideo : SPKGalleryMediaTypeImage;
    SPKDownloadDestination destination = SPKAutoSaveDestination();
    if ([SPKDownloadDuplicatePolicy destinationContainsMediaForMetadata:metadata
                                                              mediaType:mediaType
                                                            destination:destination]) {
        SPKLog(@"Stories", @"[Sparkle AutoSave] Already in %@, skipping mediaID=%@ user=@%@",
               SPKDownloadDestinationDisplayName(destination), mediaID, username);
        return;
    }

    SPKLog(@"Stories", @"[Sparkle AutoSave] Saving story mediaID=%@ user=@%@ video=%d", mediaID, username, isVideo);
    if (!SPKAutoSaveSubmitMedia(context.media, SPKActionButtonSourceStories, username, kSPKNotificationStoryAutoSave)) {
        // Nothing was queued, so let the item be retried next time it's displayed.
        [sessionKeys removeObject:mediaID];
        SPKLog(@"Stories", @"[Sparkle AutoSave] Failed to submit mediaID=%@ user=@%@", mediaID, username);
    }
}

#pragma mark - Current-user rule (story action menu)

static BOOL SPKStoryAutoSaveResolveCurrentUser(SPKStoryContext *context, NSString **outUsername, NSString **outPK) {
    NSString *username = SPKStoryUsernameForContext(context);
    if (username.length == 0)
        return NO;
    NSString *pk = SPKStoryUserPKFromMediaObject(context.media);
    if (pk.length == 0)
        return NO;
    if (outUsername)
        *outUsername = username;
    if (outPK)
        *outPK = pk;
    return YES;
}

BOOL SPKStoryAutoSaveAppliesToCurrentUser(SPKStoryContext *context) {
    NSString *pk = nil;
    if (!SPKStoryAutoSaveResolveCurrentUser(context, NULL, &pk) || pk.length == 0)
        return NO;
    return SPKStoryAutoSaveAppliesToUser(pk);
}

// The menu action reads as "does auto-save currently apply to this user?", which in
// All Users mode means removing them from the exclusion list and in Selected Users
// mode means adding them to the inclusion list. Both are the same toggle underneath.
NSString *SPKStoryAutoSaveCurrentUserActionTitle(SPKStoryContext *context) {
    NSString *pk = nil;
    if (!SPKStoryAutoSaveResolveCurrentUser(context, NULL, &pk))
        return nil;
    return SPKStoryAutoSaveAppliesToCurrentUser(context) ? SPKL(@"STORIES_STORY_AUTO_SAVE_STOP_AUTO_SAVING_STORIES_TEXT") : SPKL(@"STORIES_STORY_AUTO_SAVE_AUTO_SAVE_STORIES_TEXT");
}

NSString *SPKStoryAutoSaveCurrentUserConfirmationTitle(SPKStoryContext *context) {
    return SPKStoryAutoSaveCurrentUserActionTitle(context);
}

NSString *SPKStoryAutoSaveCurrentUserConfirmationMessage(SPKStoryContext *context) {
    NSString *username = nil;
    NSString *pk = nil;
    if (!SPKStoryAutoSaveResolveCurrentUser(context, &username, &pk))
        return nil;
    return SPKStoryAutoSaveAppliesToUser(pk)
               ? [NSString stringWithFormat:SPKL(@"STORIES_STORY_AUTO_SAVE_STOP_AUTO_SAVING_STORIES_VALUE_FORMAT"), username]
               : [NSString stringWithFormat:SPKL(@"STORIES_STORY_AUTO_SAVE_AUTO_SAVE_EVERY_STORY_VALUE_FORMAT"), username];
}

BOOL SPKStoryToggleAutoSaveCurrentUser(SPKStoryContext *context, NSString **notificationTitle, NSString **notificationSubtitle) {
    NSString *username = nil;
    NSString *pk = nil;
    if (!SPKStoryAutoSaveResolveCurrentUser(context, &username, &pk))
        return NO;

    BOOL appliedBefore = SPKStoryAutoSaveAppliesToUser(pk);
    NSString *fullName = SPKStoryFullNameForContext(context);
    // A nil avatar here is fine: -buildItems re-resolves it by PK on each load.
    NSString *profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

    SPKStoryToggleAutoSaveForPK(pk, username, fullName, profilePicUrl);

    // Users who just started auto-saving shouldn't have to wait for the next item:
    // drop this item's "already considered" memo and re-check the story on screen.
    // Only this key is dropped, so other users' memos survive the toggle.
    if (!appliedBefore) {
        NSString *mediaID = SPKStoryMediaIdentifierForContext(context);
        if (mediaID.length > 0)
            [SPKStoryAutoSaveSessionKeys() removeObject:mediaID];
        SPKStoryAutoSaveConsiderOverlay(context.overlayView);
    }

    if (notificationTitle) {
        *notificationTitle = appliedBefore
                                 ? [NSString stringWithFormat:SPKL(@"STORIES_STORY_AUTO_SAVE_AUTO_SAVE_OFF_VALUE_FORMAT"), username]
                                 : [NSString stringWithFormat:SPKL(@"STORIES_STORY_AUTO_SAVE_AUTO_SAVE_VALUE_FORMAT"), username];
    }
    if (notificationSubtitle)
        *notificationSubtitle = SPKStoryAutoSaveListTitle();
    return YES;
}

#pragma mark - Auto-save users list

@interface SPKStoryAutoSaveUsersViewController : SPKAutoSaveFilterListViewController
@end

@implementation SPKStoryAutoSaveUsersViewController

- (instancetype)init {
    if ((self = [super initWithConfig:SPKStoryAutoSaveFilterConfig()])) {
        BOOL allUsers = SPKStoryAutoSaveAllUsersMode();
        self.showsAddButton = YES;
        self.infoText = allUsers
                            ? SPKL(@"STORIES_STORY_AUTO_SAVE_FILTER_MODE_USERS_SO_EVERY_STORY_WATCH_SAVED_EXCEPT_TEXT")
                            : SPKL(@"STORIES_STORY_AUTO_SAVE_FILTER_MODE_SELECTED_USERS_SO_ONLY_STORIES_USERS_LIST_TEXT");
        self.emptyTitle = SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_NO_USERS_YET_TEXT");
        self.emptySubtitle = allUsers
                                 ? SPKL(@"STORIES_STORY_AUTO_SAVE_ADD_USERS_WHOSE_STORIES_SHOULD_NEVER_AUTO_SAVED_TEXT")
                                 : SPKL(@"STORIES_STORY_AUTO_SAVE_ADD_USERS_WHOSE_STORIES_SHOULD_SAVED_AUTOMATICALLY_WATCH_TEXT");
    }
    return self;
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    NSString *username = SPKStringFromValue(entry[@"username"]);
    return username.length > 0 ? [@"@" stringByAppendingString:username] : nil;
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in SPKStoryAutoSaveUserList()) {
        NSString *username = entry[@"username"];
        NSString *pk = [entry[@"pk"] isKindOfClass:[NSString class]] ? entry[@"pk"] : nil;
        NSString *fullName = entry[@"fullName"];
        NSString *profilePicUrl = entry[@"profilePicUrl"];
        if (profilePicUrl.length == 0 && pk.length > 0)
            profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

        SPKUserListItem *item = [SPKUserListItem new];
        item.pk = pk;
        item.title = username.length ? [@"@" stringByAppendingString:username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
        item.subtitle = fullName.length ? fullName : nil;
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
                                                         message:SPKL(@"STORIES_STORY_AUTO_SAVE_ENTER_INSTAGRAM_USERNAME_WHOSE_STORIES_SHOULD_AUTO_SAVED_TEXT")
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

                                      NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                      if (pk.length == 0) {
                                          [strongSelf presentError:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_COULD_NOT_RESOLVE_USER_S_INSTAGRAM_ID_TEXT")];
                                          return;
                                      }
                                      NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: username;
                                      NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"";
                                      NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);

                                      NSString *message = fullName.length > 0
                                                              ? [NSString stringWithFormat:@"@%@ (%@)", resolvedUsername, fullName]
                                                              : [@"@" stringByAppendingString:resolvedUsername];

                                      [SPKIGAlertPresenter presentAlertFromViewController:strongSelf
                                                                                    title:SPKL(@"STORIES_STORY_AUTO_SAVE_AUTO_SAVE_STORIES_QUESTION")
                                                                                  message:message
                                                                                  actions:@[
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                  style:SPKIGAlertActionStyleCancel
                                                                                                                handler:nil],
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD")
                                                                                                                  style:SPKIGAlertActionStyleDefault
                                                                                                                handler:^{
                                                                                                                    [strongSelf addResolvedUserPK:pk username:resolvedUsername fullName:fullName profilePicUrl:profilePicUrl];
                                                                                                                }],
                                                                                  ]];
                                   }];
}

- (void)addResolvedUserPK:(NSString *)pk username:(NSString *)username fullName:(NSString *)fullName profilePicUrl:(NSString *)profilePicUrl {
    if (SPKStoryAutoSaveListContainsUser(pk))
        return;
    SPKStoryToggleAutoSaveForPK(pk, username, fullName, profilePicUrl);
    SPKNotify(kSPKNotificationStoryAutoSaveUserRule,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKStoryAutoSaveListTitle(),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKStoryAutoSaveListViewController(void) {
    return [[SPKStoryAutoSaveUsersViewController alloc] init];
}

NSString *SPKStoryAutoSaveSettingsSummary(void) {
    return SPKAutoSaveFilterSummary(SPKStoryAutoSaveFilterConfig());
}
