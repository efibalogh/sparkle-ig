#import "SPKStrings.h"
#import "SPKDeletedMessagesStorageViewController.h"

#import "../../../Settings/SPKTopicSettingsSupport.h"
#import "../../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../../Utils.h"
#import "SPKDeletedMessagesModels.h"
#import "SPKDeletedMessagesStorage.h"
#import "../../../Shared/UI/SPKNotificationCenter.h"

@interface SPKDeletedMessagesStorageViewController ()
@property (nonatomic, copy) NSString *ownerPK;
@property (nonatomic, assign) NSUInteger messageCount;
@property (nonatomic, assign) NSUInteger senderCount;
@property (nonatomic, assign) NSUInteger textCount;
@property (nonatomic, assign) NSUInteger mediaCount;
@property (nonatomic, assign) NSUInteger voiceCount;
@property (nonatomic, assign) NSUInteger otherCount;
@property (nonatomic, assign) unsigned long long mediaBytes;
@property (nonatomic, assign) unsigned long long stagedMediaBytes;
@end

@implementation SPKDeletedMessagesStorageViewController

static NSString *SPKDMStorageOwnerPK(void) {
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            id session = nil;
            @try {
                session = [window valueForKey:@"userSession"];
            } @catch (__unused id e) {
            }
            id user = nil;
            @try {
                user = [session valueForKey:@"user"];
            } @catch (__unused id e) {
            }
            for (NSString *key in @[ @"pk", @"instagramUserID", @"instagramUserId", @"userID", @"userId" ]) {
                id value = nil;
                @try {
                    value = [user valueForKey:key];
                } @catch (__unused id e) {
                }
                if ([value isKindOfClass:NSString.class] && [value length])
                    return value;
                if ([value isKindOfClass:NSNumber.class])
                    return [value stringValue];
            }
        }
    } @catch (__unused id e) {
    }
    NSArray<NSString *> *owners = [SPKDeletedMessagesStorage allOwnerPKs];
    return owners.firstObject ?: @"anon";
}

- (instancetype)init {
    return [super initWithTitle:SPKL(@"ALERT_ACTION_STORAGE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadStatsAndRebuild) name:SPKDeletedMessagesDidChangeNotification object:nil];
    [self reloadStatsAndRebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadStatsAndRebuild];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadStatsAndRebuild {
    [self reloadStats];
    [self rebuildSections];
}

- (void)reloadStats {
    self.ownerPK = SPKDMStorageOwnerPK();
    NSArray<SPKDeletedMessage *> *messages = [SPKDeletedMessagesStorage allMessagesForOwnerPK:self.ownerPK];
    self.messageCount = messages.count;

    NSMutableSet<NSString *> *senders = [NSMutableSet set];
    NSUInteger text = 0, media = 0, voice = 0, other = 0;
    for (SPKDeletedMessage *message in messages) {
        if (message.senderPk.length)
            [senders addObject:message.senderPk];
        switch (message.kind) {
        case SPKDeletedMessageKindText:
            text++;
            break;
        case SPKDeletedMessageKindPhoto:
        case SPKDeletedMessageKindVideo:
        case SPKDeletedMessageKindGif:
        case SPKDeletedMessageKindSticker:
            media++;
            break;
        case SPKDeletedMessageKindVoice:
        case SPKDeletedMessageKindAudioShare:
            voice++;
            break;
        default:
            other++;
            break;
        }
    }
    self.senderCount = senders.count;
    self.textCount = text;
    self.mediaCount = media;
    self.voiceCount = voice;
    self.otherCount = other;
    self.mediaBytes = [SPKDeletedMessagesStorage mediaSizeBytesForOwnerPK:self.ownerPK];
    self.stagedMediaBytes = [SPKDeletedMessagesStorage stagedMediaSizeBytesForOwnerPK:self.ownerPK];
}

- (NSString *)formattedSize:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)rebuildSections {
    NSMutableArray *sections = [NSMutableArray array];

    unsigned long long totalDisk = self.mediaBytes + self.stagedMediaBytes;
    NSString *overviewSubtitle = [NSString stringWithFormat:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_VALUE_MESSAGE_VALUE_VALUE_SENDER_VALUE_VALUE_MESSAGE"),
                                                            SPKLP(@"COMMON_MESSAGE_COUNT", (NSInteger)self.messageCount),
                                                            SPKLP(@"COMMON_SENDER_COUNT", (NSInteger)self.senderCount),
                                                            [self formattedSize:totalDisk]];

    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_OVERVIEW_HEADER"), @[
                  [SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_LOGGED_TEXT")
                                        subtitle:overviewSubtitle
                                            icon:SPKSettingsIcon(@"history")],
              ],
                                        nil)];

    NSMutableArray *breakdown = [NSMutableArray array];
    [breakdown addObject:[SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_TEXT") subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)self.textCount] icon:SPKSettingsIcon(@"message")]];
    [breakdown addObject:[SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_PHOTOS_VIDEOS_TEXT") subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)self.mediaCount] icon:SPKSettingsIcon(@"photo")]];
    [breakdown addObject:[SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_VOICE_AUDIO_TEXT") subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)self.voiceCount] icon:SPKSettingsIcon(@"microphone")]];
    if (self.otherCount > 0) {
        [breakdown addObject:[SPKSetting valueCellWithTitle:SPKL(@"STORIES_OTHER_HEADER") subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)self.otherCount] icon:SPKSettingsIcon(@"messages")]];
    }
    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE"), breakdown, nil)];

    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_DISK_USAGE_TEXT"), @[
                  [SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CAPTURED_MEDIA_TEXT")
                                        subtitle:[self formattedSize:self.mediaBytes]
                                            icon:SPKSettingsIcon(@"media")],
                  [SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_MEDIA_RECOVERY_CACHE_TEXT")
                                        subtitle:[self formattedSize:self.stagedMediaBytes]
                                            icon:SPKSettingsIcon(@"clock")],
              ],
                                        SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_VIEW_ONCE_VIEW_TWICE_GIF_STICKER_MEDIA_CACHED_DEVICE_TEXT"))];

    __weak typeof(self) weakSelf = self;

    SPKSetting *clearMedia = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_CAPTURED_MEDIA_TEXT")
                                                    subtitle:nil
                                                        icon:SPKSettingsIcon(@"media")
                                                      action:^{
                                                          [weakSelf confirmClearMedia];
                                                      }];
    clearMedia.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearMedia.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    SPKSetting *clearStaged = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_MEDIA_RECOVERY_CACHE_TEXT")
                                                     subtitle:nil
                                                         icon:SPKSettingsIcon(@"clock")
                                                       action:^{
                                                           [weakSelf confirmClearStagedMedia];
                                                       }];
    clearStaged.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearStaged.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    SPKSetting *clearLog = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_ENTIRE_LOG_TEXT")
                                                  subtitle:nil
                                                      icon:SPKSettingsIcon(@"trash")
                                                    action:^{
                                                        [weakSelf confirmClearLog];
                                                    }];
    clearLog.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearLog.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_MAINTENANCE_TEXT"), @[ clearMedia, clearStaged, clearLog ],
                                        SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEARING_MEDIA_RECOVERY_CACHE_KEEPS_LIGHTWEIGHT_MESSAGE_METADATA_BEST_TEXT"))];

    [self replaceSections:sections];
}

#pragma mark - Actions

- (void)confirmClearMedia {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_CAPTURED_MEDIA_QUESTION")
                                                message:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_REMOVES_CAPTURED_MEDIA_PHOTOS_VIDEOS_VOICE_NOTES_BUT_KEEPS_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_MEDIA")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  for (SPKDeletedMessage *message in [SPKDeletedMessagesStorage allMessagesForOwnerPK:self.ownerPK]) {
                                                                                      NSString *media = [SPKDeletedMessagesStorage absolutePathForRelativePath:message.mediaPath ownerPK:self.ownerPK];
                                                                                      NSString *thumb = [SPKDeletedMessagesStorage absolutePathForRelativePath:message.thumbnailPath ownerPK:self.ownerPK];
                                                                                      if (media.length)
                                                                                          [NSFileManager.defaultManager removeItemAtPath:media error:nil];
                                                                                      if (thumb.length)
                                                                                          [NSFileManager.defaultManager removeItemAtPath:thumb error:nil];
                                                                                      message.mediaPath = nil;
                                                                                      message.thumbnailPath = nil;
                                                                                      [SPKDeletedMessagesStorage saveMessage:message forOwnerPK:self.ownerPK];
                                                                                  }
                                                                                  [self reloadStatsAndRebuild];
                                                                                  SPKNotify(kSPKNotificationDeletedMessagesClear, SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_MEDIA_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (void)confirmClearLog {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_ENTIRE_LOG_QUESTION")
                                                message:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_REMOVES_EVERY_LOGGED_DELETED_MESSAGE_CAPTURED_MEDIA_ACCOUNT_MESSAGE")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [SPKDeletedMessagesStorage resetForOwnerPK:self.ownerPK];
                                                                                  [self reloadStatsAndRebuild];
                                                                                  SPKNotify(kSPKNotificationDeletedMessagesClear, SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_LOG_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

- (void)confirmClearStagedMedia {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_CLEAR_MEDIA_RECOVERY_CACHE_QUESTION")
                                                message:SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_REMOVES_PRE_CACHED_VIEW_ONCE_VIEW_TWICE_GIF_STICKER_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR_MEDIA")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [SPKDeletedMessagesStorage clearStagedMediaForOwnerPK:self.ownerPK];
                                                                                  [self reloadStatsAndRebuild];
                                                                                  SPKNotify(kSPKNotificationDeletedMessagesClear, SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_RECOVERY_CACHE_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

@end
