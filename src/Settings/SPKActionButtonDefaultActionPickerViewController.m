#import "SPKActionButtonDefaultActionPickerViewController.h"
#import "SPKStrings.h"

#import "../AssetUtils.h"
#import "../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../Shared/ActionButton/SPKActionDescriptor.h"
#import "../Utils.h"
#import "SPKPreferences.h"
#import "SPKTopicSettingsSupport.h"

static NSString *const kSPKActionDefaultPickerCellIdentifier = @"SPKActionDefaultPickerCell";

static NSString *SPKActionButtonDefaultActionKeyForSource(SPKActionButtonSource source) {
    return SPKPrefActionButtonDefaultActionKey(SPKActionButtonTopicKeyForSource(source));
}

static NSDictionary<NSString *, NSString *> *SPKProfileLegacyDefaultActionMap(void) {
    return @{
        @"copy_info" : kSPKActionProfileCopyInfo,
        @"view_picture" : kSPKActionExpand,
        @"share_picture" : kSPKActionDownloadShare,
        @"save_picture_gallery" : kSPKActionDownloadGallery,
        @"profile_settings" : kSPKActionOpenTopicSettings
    };
}

NSString *SPKActionButtonDefaultActionIdentifierForSource(SPKActionButtonSource source) {
    NSArray<NSString *> *supportedActions = SPKActionButtonSupportedActionsForSource(source);
    id savedValue = SPKPreferenceObjectForKey(SPKActionButtonDefaultActionKeyForSource(source));
    NSString *saved = [savedValue isKindOfClass:[NSString class]] ? savedValue : nil;
    if (source == SPKActionButtonSourceProfile && saved.length > 0) {
        saved = SPKProfileLegacyDefaultActionMap()[saved] ?: saved;
    }

    if ([saved isEqualToString:kSPKActionNone])
        return kSPKActionNone;
    if ([supportedActions containsObject:saved])
        return saved;
    if (saved.length > 0 || source == SPKActionButtonSourceProfile)
        return kSPKActionNone;
    if ([supportedActions containsObject:kSPKActionDownloadLibrary])
        return kSPKActionDownloadLibrary;
    return supportedActions.firstObject ?: kSPKActionNone;
}

NSString *SPKActionButtonDefaultActionTitleForSource(SPKActionButtonSource source) {
    NSString *identifier = SPKActionButtonDefaultActionIdentifierForSource(source);
    if ([identifier isEqualToString:kSPKActionNone])
        return SPKL(@"FEED_HEADER_ACTION_BUTTON_OPEN_MENU_TEXT");
    return SPKActionDescriptorDisplayTitle(identifier, SPKActionButtonTopicTitleForSource(source));
}

NSString *SPKActionButtonDefaultActionIconNameForSource(SPKActionButtonSource source) {
    NSString *identifier = SPKActionButtonDefaultActionIdentifierForSource(source);
    return [identifier isEqualToString:kSPKActionNone] ? @"action" : SPKActionDescriptorIconName(identifier);
}

static NSArray<NSDictionary *> *SPKActionButtonDefaultActionSections(SPKActionButtonSource source) {
    NSArray<NSString *> *supportedActions = SPKActionButtonSupportedActionsForSource(source);
    NSArray<NSDictionary *> *groups = @[
        @{@"title" : SPKL(@"DOWNLOADS_GENERAL_DOWNLOADS_TITLE"),
          @"actions" : @[ kSPKActionDownloadLibrary, kSPKActionDownloadShare, kSPKActionDownloadGallery ]},
        @{@"title" : SPKL(@"FEED_MEDIA_HEADER"),
          @"actions" : @[ kSPKActionExpand, kSPKActionViewThumbnail, kSPKActionTrimSave, kSPKActionEditSave ]},
        @{@"title" : SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT"),
          @"actions" : @[ kSPKActionCopyDownloadLink, kSPKActionCopyMedia, kSPKActionCopyCaption, kSPKActionCopyLink, kSPKActionProfileCopyInfo ]},
        @{@"title" : SPKL(@"COMMON_MEDIA_TYPE_AUDIO"),
          @"actions" : @[ kSPKActionDownloadAudio, kSPKActionDownloadAudioShare, kSPKActionDownloadAudioGallery, kSPKActionPlayAudio, kSPKActionCopyAudioURL ]},
        @{@"title" : SPKL(@"STORIES_OTHER_HEADER"),
          @"actions" : @[ kSPKActionOpenTopicSettings, kSPKActionRepost, kSPKActionStoryMentionsSheet, kSPKActionToggleStorySeenUserRule, kSPKActionDeletedMessagesLog, kSPKActionNone ]}
    ];

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSDictionary *group in groups) {
        NSMutableArray<NSString *> *actions = [NSMutableArray array];
        for (NSString *identifier in group[@"actions"]) {
            if ([identifier isEqualToString:kSPKActionNone] || [supportedActions containsObject:identifier]) {
                [actions addObject:identifier];
            }
        }
        if (actions.count > 0) {
            [sections addObject:@{@"title" : group[@"title"], @"actions" : [actions copy]}];
        }
    }
    return [sections copy];
}

@interface SPKActionButtonDefaultActionPickerViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) SPKActionButtonSource source;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;

@end

@implementation SPKActionButtonDefaultActionPickerViewController

- (UIView *)selectionBackgroundView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    return view;
}

- (instancetype)initWithSource:(SPKActionButtonSource)source {
    self = [super init];
    if (self) {
        _source = source;
        _sections = SPKActionButtonDefaultActionSections(source);
        self.title = SPKL(@"SPKTOPICSETTINGSSUPPORT_GENERAL_DEFAULT_TAP_ACTION_TITLE");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kSPKActionDefaultPickerCellIdentifier];
    [self.view addSubview:self.tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"actions"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (NSString *)identifierAtIndexPath:(NSIndexPath *)indexPath {
    return self.sections[indexPath.section][@"actions"][indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSPKActionDefaultPickerCellIdentifier forIndexPath:indexPath];
    UIListContentConfiguration *config = cell.defaultContentConfiguration;
    NSString *identifier = [self identifierAtIndexPath:indexPath];
    BOOL isNone = [identifier isEqualToString:kSPKActionNone];

    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    cell.selectedBackgroundView = [self selectionBackgroundView];
    config.text = isNone ? SPKL(@"FEED_HEADER_ACTION_BUTTON_OPEN_MENU_TEXT") : SPKActionDescriptorDisplayTitle(identifier, SPKActionButtonTopicTitleForSource(self.source));
    config.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    config.image = SPKSettingsIcon(isNone ? @"action" : SPKActionDescriptorIconName(identifier));
    config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];

    if ([identifier isEqualToString:SPKActionButtonDefaultActionIdentifierForSource(self.source)]) {
        UIImageView *checkmarkView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled"]];
        checkmarkView.tintColor = [SPKUtils SPKColor_InstagramBlue];
        cell.accessoryView = checkmarkView;
    } else {
        cell.accessoryView = nil;
    }

    cell.contentConfiguration = config;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [self identifierAtIndexPath:indexPath];
    SPKPreferenceSetObject(identifier, SPKActionButtonDefaultActionKeyForSource(self.source));
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
