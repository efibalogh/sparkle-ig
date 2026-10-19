#import "SPKStrings.h"
#import "SPKActionDescriptor.h"
#import "ActionButtonCore.h"

@implementation SPKActionDescriptor

+ (instancetype)descriptorWithIdentifier:(NSString *)identifier
                                   title:(NSString *)title
                                iconName:(NSString *)iconName {
    SPKActionDescriptor *descriptor = [[self alloc] init];
    descriptor.identifier = identifier;
    descriptor.title = title;
    descriptor.iconName = iconName;
    return descriptor;
}

+ (NSArray<SPKActionDescriptor *> *)descriptors {
    static NSArray<SPKActionDescriptor *> *descriptors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptors = @[
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadLibrary
                                                    title:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT")
                                                 iconName:@"download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadShare
                                                    title:SPKL(@"ALERT_ACTION_SHARE")
                                                 iconName:@"share"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionCopyDownloadLink
                                                    title:SPKL(@"FEED_COMMENT_ACTIONS_COPY_DOWNLOAD_URL_TEXT")
                                                 iconName:@"link"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionCopyMedia
                                                    title:SPKL(@"ACTION_BUTTON_COPY_MEDIA_TITLE")
                                                 iconName:@"copy"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadGallery
                                                    title:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT")
                                                 iconName:@"sparkle_gallery"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionTrimSave
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_TRIM_SAVE_TEXT")
                                                 iconName:@"trim"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionEditSave
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_EDIT_SAVE_TEXT")
                                                 iconName:@"crop"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAudio
                                                    title:SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES")
                                                 iconName:@"audio_download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAudioShare
                                                    title:SPKL(@"ALERT_ACTION_SHARE_AUDIO")
                                                 iconName:@"share"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAudioGallery
                                                    title:SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY")
                                                 iconName:@"sparkle_gallery"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionPlayAudio
                                                    title:SPKL(@"ALERT_ACTION_PLAY_AUDIO")
                                                 iconName:@"play"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionCopyAudioURL
                                                    title:SPKL(@"ALERT_ACTION_COPY_AUDIO_DOWNLOAD_URL")
                                                 iconName:@"link"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAllLibrary
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SAVE_PHOTOS_TEXT")
                                                 iconName:@"download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAllShare
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SHARE_TEXT")
                                                 iconName:@"share"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAllGallery
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SAVE_GALLERY_TEXT")
                                                 iconName:@"sparkle_gallery"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAllClipboard
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_MEDIA_TEXT")
                                                 iconName:@"copy"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAllLinks
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_DOWNLOAD_URLS_TEXT")
                                                 iconName:@"link"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDownloadAll
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_DOWNLOAD_TEXT")
                                                 iconName:@"more"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionExpand
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_EXPAND_TEXT")
                                                 iconName:@"expand"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionViewThumbnail
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_VIEW_THUMBNAIL_TEXT")
                                                 iconName:@"photo_gallery"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionCopyCaption
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_CAPTION_TEXT")
                                                 iconName:@"caption"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionOpenTopicSettings
                                                    title:SPKL(@"DATA_GENERAL_SETTINGS_TITLE")
                                                 iconName:@"settings"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionDeletedMessagesLog
                                                    title:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                                 iconName:@"channels"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionRepost
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_REPOST_TEXT")
                                                 iconName:@"repost"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleStorySeenUserRule
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_TOGGLE_STORY_USER_RULE_TEXT")
                                                 iconName:@"eye"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleStoryAutoSaveUserRule
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_TOGGLE_STORY_AUTO_SAVE_TEXT")
                                                 iconName:@"download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleDirectAutoSaveThreadRule
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_TOGGLE_CHAT_AUTO_SAVE_TEXT")
                                                 iconName:@"download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleInstantsAutoSaveUserRule
                                                    title:SPKL(@"INSTANTS_ACTION_TOGGLE_TITLE")
                                                 iconName:@"download"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleInstantsManualSeenUserRule
                                                    title:SPKL(@"INSTANTS_ACTION_TOGGLE_MANUAL_SEEN_TITLE")
                                                 iconName:@"eye"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionInstantsMarkSeen
                                                    title:SPKL(@"INSTANTS_MARK_SEEN_TITLE")
                                                 iconName:@"eye"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleProfileStorySeenUserRule
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_TOGGLE_STORY_SEEN_TEXT")
                                                 iconName:@"eye"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionToggleProfileMessagesSeenUserRule
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_TOGGLE_MESSAGES_SEEN_MESSAGE")
                                                 iconName:@"eye"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionStoryMentionsSheet
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_STORY_MENTIONS_TEXT")
                                                 iconName:@"mention"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyInfo
                                                    title:SPKL(@"SETTINGS_PROFILE_COPY_INFO_TEXT")
                                                 iconName:@"info"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyID
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_ID_TEXT")
                                                 iconName:@"key"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyUsername
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_USERNAME_TEXT")
                                                 iconName:@"username"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyName
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_NAME_TEXT")
                                                 iconName:@"text"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyBio
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_BIO_TEXT")
                                                 iconName:@"caption"],
            [SPKActionDescriptor descriptorWithIdentifier:kSPKActionProfileCopyLink
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_PROFILE_URL_TEXT")
                                                 iconName:@"link"],
            [SPKActionDescriptor descriptorWithIdentifier:@"more"
                                                    title:SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT")
                                                 iconName:@"more"],
            [SPKActionDescriptor descriptorWithIdentifier:@"action"
                                                    title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_ACTIONS_ACTION")
                                                 iconName:@"action"]
        ];
    });
    return descriptors;
}

+ (nullable instancetype)descriptorForIdentifier:(NSString *)identifier {
    for (SPKActionDescriptor *descriptor in [self descriptors]) {
        if ([descriptor.identifier isEqualToString:identifier]) {
            return descriptor;
        }
    }
    return nil;
}

+ (NSArray<SPKActionDescriptor *> *)availableSectionIconDescriptors {
    return @[
        [SPKActionDescriptor descriptorWithIdentifier:@"action"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_ACTIONS_ACTION")
                                             iconName:@"action"],
        [SPKActionDescriptor descriptorWithIdentifier:@"copy"
                                                title:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT")
                                             iconName:@"copy"],
        [SPKActionDescriptor descriptorWithIdentifier:@"key"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_KEY_TEXT")
                                             iconName:@"key"],
        [SPKActionDescriptor descriptorWithIdentifier:@"caption"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_CAPTION_TEXT")
                                             iconName:@"caption"],
        [SPKActionDescriptor descriptorWithIdentifier:@"download"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_DOWNLOAD_TEXT")
                                             iconName:@"download"],
        [SPKActionDescriptor descriptorWithIdentifier:@"share"
                                                title:SPKL(@"ALERT_ACTION_SHARE")
                                             iconName:@"share"],
        [SPKActionDescriptor descriptorWithIdentifier:@"link"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_LINK_TEXT")
                                             iconName:@"link"],
        [SPKActionDescriptor descriptorWithIdentifier:@"media"
                                                title:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                             iconName:@"sparkle_gallery"],
        [SPKActionDescriptor descriptorWithIdentifier:@"expand"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_EXPAND_TEXT")
                                             iconName:@"expand"],
        [SPKActionDescriptor descriptorWithIdentifier:@"photo_gallery"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_THUMBNAIL_TEXT")
                                             iconName:@"photo_gallery"],
        [SPKActionDescriptor descriptorWithIdentifier:@"repost"
                                                title:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_REPOST_TEXT")
                                             iconName:@"repost"],
        [SPKActionDescriptor descriptorWithIdentifier:@"mention"
                                                title:SPKL(@"STORIES_STORY_MENTIONS_MENTIONS_TEXT")
                                             iconName:@"mention"],
        [SPKActionDescriptor descriptorWithIdentifier:@"feed"
                                                title:SPKL(@"FEED_TITLE")
                                             iconName:@"feed"],
        [SPKActionDescriptor descriptorWithIdentifier:@"reels"
                                                title:SPKL(@"REELS_TITLE")
                                             iconName:@"reels"],
        [SPKActionDescriptor descriptorWithIdentifier:@"story"
                                                title:SPKL(@"STORIES_OTHER_STORIES_TITLE")
                                             iconName:@"story"],
        [SPKActionDescriptor descriptorWithIdentifier:@"messages"
                                                title:SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE")
                                             iconName:@"messages"],
        [SPKActionDescriptor descriptorWithIdentifier:@"profile"
                                                title:SPKL(@"PROFILE_TITLE")
                                             iconName:@"user_circle"],
        [SPKActionDescriptor descriptorWithIdentifier:@"settings"
                                                title:SPKL(@"DATA_GENERAL_SETTINGS_TITLE")
                                             iconName:@"settings"],
        [SPKActionDescriptor descriptorWithIdentifier:@"more"
                                                title:SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT")
                                             iconName:@"more"]
    ];
}

@end

NSString *SPKActionDescriptorDisplayTitle(NSString *identifier, NSString *topicTitle) {
    if ([identifier isEqualToString:kSPKActionOpenTopicSettings] && topicTitle.length > 0) {
        return [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_VALUE_SETTINGS_FORMAT"), topicTitle];
    }
    SPKActionDescriptor *descriptor = [SPKActionDescriptor descriptorForIdentifier:identifier];
    return descriptor.title ?: SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_ACTION");
}

NSString *SPKActionDescriptorIconName(NSString *identifier) {
    SPKActionDescriptor *descriptor = [SPKActionDescriptor descriptorForIdentifier:identifier];
    return descriptor.iconName ?: @"action";
}
