#import "SPKStrings.h"
#import "SPKDirectAutoSave.h"

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
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKUserListViewController.h"
#import "SPKDirectAddThreadPrompt.h"
#import "SPKDirectSeenContext.h"
#import "SPKDirectUserResolver.h"

static NSString *const kSPKDirectAutoSaveEnabledKey = @"msgs_auto_save";

#pragma mark - Filter

SPKAutoSaveFilterConfig *SPKDirectAutoSaveFilterConfig(void) {
    static SPKAutoSaveFilterConfig *config = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [SPKAutoSaveFilterConfig new];
        config.enabledKey = kSPKDirectAutoSaveEnabledKey;
        config.filterModeKey = @"msgs_auto_save_filter_mode";
        config.excludedKey = @"msgs_auto_save_excluded";
        config.includedKey = @"msgs_auto_save_included";
        config.identityField = @"threadId";
        config.sortField = @"threadName";
        config.subjectPlural = @"Chats";
        config.ruleNotificationIdentifier = kSPKNotificationDirectAutoSaveThreadRule;
    });
    return config;
}

BOOL SPKDirectAutoSaveAllChatsMode(void) {
    return SPKAutoSaveFilterAllMode(SPKDirectAutoSaveFilterConfig());
}

NSString *SPKDirectAutoSaveListTitle(void) {
    return SPKAutoSaveFilterListTitle(SPKDirectAutoSaveFilterConfig());
}

BOOL SPKDirectAutoSaveAppliesToThread(NSString *threadId) {
    return SPKAutoSaveFilterApplies(SPKDirectAutoSaveFilterConfig(), threadId);
}

NSString *SPKDirectAutoSaveSettingsSummary(void) {
    return SPKAutoSaveFilterSummary(SPKDirectAutoSaveFilterConfig());
}

#pragma mark - Auto-saver

// Item keys already handled this viewer session -- both saved items and items rejected
// by the filter, so a rejected item costs one list lookup rather than one per callback.
static NSMutableSet<NSString *> *SPKDirectAutoSaveSessionKeys(void) {
    static NSMutableSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

void SPKDirectAutoSaveViewerSessionDidEnd(void) {
    [SPKDirectAutoSaveSessionKeys() removeAllObjects];
}

void SPKDirectAutoSaveConsiderController(UIViewController *controller) {
    if (!controller)
        return;
    if (![SPKUtils getBoolPref:kSPKDirectAutoSaveEnabledKey])
        return;

    SPKDirectThreadContext *thread = SPKDirectThreadContextFromSource(controller);
    NSString *threadId = SPKStringFromValue(thread.threadId);
    if (threadId.length == 0)
        return;
    if (!SPKDirectAutoSaveAppliesToThread(threadId))
        return;

    id media = SPKDirectResolvedMediaFromController(controller);
    if (!media)
        return;

    NSString *username = SPKDirectUsernameFromController(controller);
    NSURL *photoURL = nil;
    NSURL *videoURL = nil;
    SPKGallerySaveMetadata *metadata = nil;
    if (!SPKResolveGalleryDownloadForMedia(media, SPKActionButtonSourceDirect, username,
                                           &photoURL, &videoURL, &metadata)) {
        SPKLog(@"Messages", @"[Sparkle AutoSave] No downloadable media for DM thread=%@ user=@%@", threadId, username);
        return;
    }
    BOOL isVideo = (videoURL != nil);

    // View-once media has no stable server id in every payload, so fall back to the
    // resolved URL: it's per-item and stable for the life of the viewer session.
    NSString *itemKey = SPKStringFromValue(metadata.sourceMediaPK);
    if (itemKey.length == 0)
        itemKey = (videoURL ?: photoURL).absoluteString;
    if (itemKey.length == 0)
        return;

    NSMutableSet<NSString *> *sessionKeys = SPKDirectAutoSaveSessionKeys();
    if ([sessionKeys containsObject:itemKey])
        return;
    // Claim the item before any async work so a later callback for the same item
    // can't queue a second download for it.
    [sessionKeys addObject:itemKey];

    // Durable guard: the session set only covers this viewer session.
    SPKGalleryMediaType mediaType = isVideo ? SPKGalleryMediaTypeVideo : SPKGalleryMediaTypeImage;
    SPKDownloadDestination destination = SPKAutoSaveDestination();
    if ([SPKDownloadDuplicatePolicy destinationContainsMediaForMetadata:metadata
                                                              mediaType:mediaType
                                                            destination:destination]) {
        SPKLog(@"Messages", @"[Sparkle AutoSave] Already in %@, skipping DM item thread=%@ user=@%@",
               SPKDownloadDestinationDisplayName(destination), threadId, username);
        return;
    }

    SPKLog(@"Messages", @"[Sparkle AutoSave] Saving DM media thread=%@ user=@%@ video=%d", threadId, username, isVideo);
    if (!SPKAutoSaveSubmitMedia(media, SPKActionButtonSourceDirect, username, kSPKNotificationDirectAutoSave)) {
        // Nothing was queued, so let the item be retried next time it's displayed.
        [sessionKeys removeObject:itemKey];
        SPKLog(@"Messages", @"[Sparkle AutoSave] Failed to submit DM item thread=%@ user=@%@", threadId, username);
    }
}

#pragma mark - Current-thread rule (DM viewer action menu)

// Never prefixes "@": the resolved name is a group title, a full name, or an already
// "@"-prefixed username, and only the last of those is a handle.
static NSString *SPKDirectAutoSaveThreadDisplayName(SPKDirectThreadContext *context) {
    NSString *name = SPKDirectDisplayNameForThreadContext(context);
    if (name.length > 0)
        return name;
    return context.isGroup ? SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_GROUP_TEXT") : SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_CHAT_TEXT");
}

BOOL SPKDirectAutoSaveAppliesToCurrentThread(SPKDirectThreadContext *context) {
    NSString *threadId = SPKStringFromValue(context.threadId);
    if (threadId.length == 0)
        return NO;
    return SPKDirectAutoSaveAppliesToThread(threadId);
}

// The menu action reads as "does auto-save currently apply to this chat?", which in All
// Chats mode means removing it from the exclusion list and in Selected Chats mode means
// adding it to the inclusion list. Both are the same toggle underneath.
NSString *SPKDirectAutoSaveCurrentThreadActionTitle(SPKDirectThreadContext *context) {
    NSString *threadId = SPKStringFromValue(context.threadId);
    if (threadId.length == 0)
        return nil;
    return SPKDirectAutoSaveAppliesToCurrentThread(context) ? SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_STOP_AUTO_SAVING_CHAT_TEXT") : SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_AUTO_SAVE_CHAT_TEXT");
}

NSString *SPKDirectAutoSaveCurrentThreadConfirmationTitle(SPKDirectThreadContext *context) {
    return SPKDirectAutoSaveCurrentThreadActionTitle(context);
}

NSString *SPKDirectAutoSaveCurrentThreadConfirmationMessage(SPKDirectThreadContext *context) {
    NSString *threadId = SPKStringFromValue(context.threadId);
    if (threadId.length == 0)
        return nil;
    NSString *name = SPKDirectAutoSaveThreadDisplayName(context);
    return SPKDirectAutoSaveAppliesToThread(threadId)
               ? [NSString stringWithFormat:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_STOP_AUTO_SAVING_VIEW_ONCE_MEDIA_VALUE_FORMAT"), name]
               : [NSString stringWithFormat:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_AUTO_SAVE_EVERY_VIEW_ONCE_PHOTO_VIDEO_VALUE_FORMAT"), name];
}

BOOL SPKDirectToggleAutoSaveCurrentThread(SPKDirectThreadContext *context,
                                          NSString **notificationTitle,
                                          NSString **notificationSubtitle) {
    NSDictionary *entry = SPKDirectThreadEntryFromContext(context);
    if (!entry)
        return NO;

    NSString *threadId = SPKStringFromValue(context.threadId);
    BOOL appliedBefore = SPKDirectAutoSaveAppliesToThread(threadId);
    SPKAutoSaveFilterToggleEntry(SPKDirectAutoSaveFilterConfig(), entry);

    NSString *name = SPKDirectAutoSaveThreadDisplayName(context);
    if (notificationTitle) {
        *notificationTitle = appliedBefore ? [NSString stringWithFormat:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_AUTO_SAVE_OFF_VALUE_FORMAT"), name]
                                           : [NSString stringWithFormat:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_AUTO_SAVE_VALUE_FORMAT"), name];
    }
    if (notificationSubtitle)
        *notificationSubtitle = SPKDirectAutoSaveListTitle();
    return YES;
}

void SPKDirectPresentAutoSaveThreadRuleToggle(SPKDirectThreadContext *context) {
    NSString *title = SPKDirectAutoSaveCurrentThreadConfirmationTitle(context);
    NSString *message = SPKDirectAutoSaveCurrentThreadConfirmationMessage(context);
    if (title.length == 0 || message.length == 0) {
        SPKNotify(kSPKNotificationDirectAutoSaveThreadRule, SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_CHAT_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }

    [SPKUtils
        showConfirmation:^{
            NSString *notificationTitle = nil;
            NSString *notificationSubtitle = nil;
            if (!SPKDirectToggleAutoSaveCurrentThread(context, &notificationTitle, &notificationSubtitle)) {
                SPKNotify(kSPKNotificationDirectAutoSaveThreadRule, SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_CHAT_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                return;
            }
            SPKNotify(kSPKNotificationDirectAutoSaveThreadRule, notificationTitle, notificationSubtitle, @"circle_check_filled",
                      SPKNotificationToneSuccess);
            // The item on screen was already skipped this session, so turning the rule
            // on only takes effect from the next one.
        }
                   title:title
                 message:message];
}

#pragma mark - Auto-save chats list

@interface SPKDirectAutoSaveChatsViewController : SPKAutoSaveFilterListViewController
@end

@implementation SPKDirectAutoSaveChatsViewController

- (instancetype)init {
    if ((self = [super initWithConfig:SPKDirectAutoSaveFilterConfig()])) {
        BOOL allChats = SPKDirectAutoSaveAllChatsMode();
        self.showsAddButton = YES;
        self.infoText = allChats
                            ? SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_FILTER_MODE_CHATS_SO_EVERY_VIEW_ONCE_PHOTO_VIDEO_TEXT")
                            : SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_FILTER_MODE_SELECTED_CHATS_SO_ONLY_VIEW_ONCE_MEDIA_TEXT");
        self.emptyTitle = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_NO_CHATS_YET_TEXT");
        self.emptySubtitle = allChats
                                 ? SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_ADD_CHATS_WHOSE_VIEW_ONCE_MEDIA_SHOULD_NEVER_AUTO_TEXT")
                                 : SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_ADD_CHATS_WHOSE_VIEW_ONCE_MEDIA_SHOULD_SAVED_AUTOMATICALLY_TEXT");
    }
    return self;
}

- (NSString *)displayNameForEntry:(NSDictionary *)entry {
    return SPKDirectDisplayNameForThreadEntry(entry) ?: SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_UNKNOWN_CHAT_TEXT");
}

- (NSString *)removalDisplayNameForEntry:(NSDictionary *)entry {
    return [self displayNameForEntry:entry];
}

// Without this the base class would treat a group's *name* as a handle and try to open
// a profile for it.
- (void)didSelectItem:(SPKUserListItem *)item {
    SPKDirectOpenProfileForThreadEntry(item.representedObject);
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in SPKAutoSaveFilterList(self.config)) {
        SPKUserListItem *item = [SPKUserListItem new];
        item.representedObject = entry;

        if ([entry[@"isGroup"] boolValue]) {
            item.isGroup = YES;
            item.title = [self displayNameForEntry:entry];
            item.subtitle = SPKDirectParticipantSubtitleForThreadEntry(entry);
            NSString *threadId = SPKStringFromValue(entry[@"threadId"]);
            // Shared cache key matches the manual-seen thread list; a synthetic "grp_"
            // PK can't self-heal, but SPKAvatarView draws the group glyph.
            if (threadId.length > 0)
                item.pk = [@"grp_" stringByAppendingString:threadId];
            item.avatarURLString = SPKStringFromValue(entry[@"groupPhotoUrl"]);
            [items addObject:item];
            continue;
        }

        NSArray *users = [entry[@"users"] isKindOfClass:[NSArray class]] ? entry[@"users"] : @[];
        NSDictionary *user = users.firstObject;
        NSString *pk = SPKStringFromValue(user[@"pk"]);
        NSString *username = SPKStringFromValue(user[@"username"]);
        NSString *fullName = SPKStringFromValue(user[@"fullName"]);
        NSString *profilePicUrl = SPKStringFromValue(user[@"profilePicUrl"]);
        if (profilePicUrl.length == 0 && pk.length > 0)
            profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

        item.pk = pk;
        item.title = username.length > 0 ? [@"@" stringByAppendingString:username] : [self displayNameForEntry:entry];
        item.subtitle = fullName.length > 0 ? fullName : nil;
        item.avatarURLString = profilePicUrl;
        [items addObject:item];
    }
    return items;
}

- (void)didTapAdd {
    SPKDirectAddThreadPromptCopy *copy = [SPKDirectAddThreadPromptCopy new];
    copy.promptTitle = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_ADD_CHAT_TEXT");
    copy.promptMessage = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_ENTER_INSTAGRAM_USERNAME_DM_THREAD_GROUP_CHATS_CAN_ADDED_TEXT");
    copy.confirmTitle = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_AUTO_SAVE_CHAT_QUESTION");
    copy.errorTitle = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_UNABLE_ADD_CHAT_TEXT");
    copy.userNotFoundFormat = SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USER_VALUE_NOT_FOUND_FORMAT");
    copy.noThreadFormat = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_NO_DM_THREAD_FOUND_VALUE_FORMAT");
    copy.unresolvedUserText = SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_COULD_NOT_RESOLVE_USER_S_INSTAGRAM_ID_TEXT");

    __weak typeof(self) weakSelf = self;
    SPKDirectPresentAddThreadPrompt(self, copy, ^(NSDictionary *entry, NSString *username) {
        [weakSelf addResolvedEntry:entry username:username];
    });
}

- (void)addResolvedEntry:(NSDictionary *)entry username:(NSString *)username {
    if (SPKAutoSaveFilterListContains(self.config, entry[@"threadId"]))
        return;
    SPKAutoSaveFilterToggleEntry(self.config, entry);
    SPKNotify(kSPKNotificationDirectAutoSaveThreadRule,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKDirectAutoSaveListTitle(),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKDirectAutoSaveListViewController(void) {
    return [[SPKDirectAutoSaveChatsViewController alloc] init];
}
