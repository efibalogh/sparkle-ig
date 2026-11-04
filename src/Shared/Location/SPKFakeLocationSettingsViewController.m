#import "SPKFakeLocationSettingsViewController.h"

#import "../../AssetUtils.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../i18n/SPKStrings.h"
#import "SPKFakeLocationPickerViewController.h"
#import "../UI/SPKNotificationCenter.h"

static NSString *const kSPKFakeLocationRowPlaceIDKey = @"spkFakeLocationPlaceID";

NSString *SPKFakeLocationSettingsSummary(void) {
    if (![SPKFakeLocation isActive])
        return SPKL(@"MENU_OFF");
    return [SPKFakeLocation currentPlace].name ?: SPKL(@"MENU_ON");
}

void SPKFakeLocationPromptToSavePlace(UIViewController *presenter, SPKFakeLocationPlace *place) {
    if (!place)
        return;
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:presenter ?: SPKSettingsTopPresenter()
                                                           title:SPKL(@"MESSAGES_FAKE_LOCATION_NAME_PLACE_TITLE")
                                                         message:[place displaySubtitle]
                                                     placeholder:SPKL(@"MESSAGES_FAKE_LOCATION_NAME_PLACEHOLDER")
                                                     initialText:place.name
                                                 autocapitalized:YES
                                                    confirmTitle:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT")
                                                     cancelTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        NSString *name = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                                        SPKFakeLocationPlace *saved = [SPKFakeLocationPlace placeWithName:name.length ? name : place.name
                                                                                                                   address:place.address
                                                                                                                coordinate:place.coordinate];
                                                        [SPKFakeLocation addSavedPlace:saved];
                                                        SPKNotify(kSPKNotificationFakeLocation, SPKL(@"MESSAGES_FAKE_LOCATION_PLACE_SAVED_TOAST"), saved.name, @"location_filled", SPKNotificationToneSuccess);
                                                    }
                                                     cancelBlock:nil];
}

static BOOL SPKFakeLocationCurrentIsSaved(void) {
    for (SPKFakeLocationPlace *place in [SPKFakeLocation savedPlaces]) {
        if ([SPKFakeLocation savedPlaceMatchesCurrent:place])
            return YES;
    }
    return NO;
}

static SPKSetting *SPKFakeLocationSavedPlaceRow(SPKFakeLocationPlace *place) {
    BOOL current = [SPKFakeLocation savedPlaceMatchesCurrent:place];
    SPKSetting *row = [SPKSetting buttonCellWithTitle:place.name.length ? place.name : [place displaySubtitle]
                                             subtitle:place.name.length ? [place displaySubtitle] : nil
                                                 icon:SPKSettingsIcon(current ? @"location_filled" : @"location")
                                               action:^{
                                                   [SPKFakeLocation applyPlace:place enable:YES];
                                               }];
    if (current)
        SPKSettingApplyIconTint(row, [SPKUtils SPKColor_InstagramBlue]);
    row.userInfo = @{kSPKFakeLocationRowPlaceIDKey : place.identifier};
    return row;
}

NSArray *SPKFakeLocationSettingsSections(void) {
    SPKFakeLocationPlace *currentPlace = [SPKFakeLocation currentPlace];

    SPKSetting *enabled = [SPKSetting switchCellWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_ENABLED_TITLE")
                                                     icon:SPKSettingsIcon(@"location")
                                              defaultsKey:@""];
    enabled.helpText = SPKL(@"MESSAGES_FAKE_LOCATION_ENABLED_HELP");
    enabled.switchValueProvider = ^BOOL {
        return [SPKFakeLocation isActive];
    };
    enabled.switchChangeHandler = ^(BOOL isOn) {
        if ([SPKFakeLocation setEnabled:isOn])
            return;
        // Nothing to spoof yet: send the user to the picker, and let the switch fall
        // back to off if they leave it without choosing.
        UIViewController *presenter = SPKSettingsTopPresenter();
        SPKSettingsReloadPresenter(presenter);
        [SPKFakeLocationPickerViewController presentFromViewController:presenter
                                                          initialPlace:nil
                                                                 title:SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_TITLE")
                                                            completion:^(SPKFakeLocationPlace *place) {
                                                                [SPKFakeLocation applyPlace:place enable:YES];
                                                            }];
    };

    SPKSetting *location = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_LOCATION_TITLE")
                                                  subtitle:currentPlace ? [currentPlace displaySubtitle] : nil
                                                      icon:SPKSettingsIcon(@"map_pin")
                                                    action:^{
                                                        [SPKFakeLocationPickerViewController presentFromViewController:SPKSettingsTopPresenter()
                                                                                                          initialPlace:[SPKFakeLocation currentPlace]
                                                                                                                 title:SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_TITLE")
                                                                                                            completion:^(SPKFakeLocationPlace *place) {
                                                                                                                [SPKFakeLocation applyPlace:place enable:NO];
                                                                                                            }];
                                                    }];
    location.userInfo = @{@"accessoryText" : currentPlace.name.length ? currentPlace.name : SPKL(@"COMMON_NOT_SET_LABEL")};
    location.helpText = SPKL(@"MESSAGES_FAKE_LOCATION_LOCATION_HELP");

    SPKSetting *mapButton = [SPKSetting switchCellWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_MAP_BUTTON_TITLE")
                                                       icon:SPKSettingsIcon(@"map")
                                                defaultsKey:kSPKFakeLocationMapButtonKey];
    mapButton.helpText = SPKL(@"MESSAGES_FAKE_LOCATION_MAP_BUTTON_HELP");
    mapButton.action = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKFakeLocationDidChangeNotification object:nil];
    };

    NSMutableArray *savedActions = [NSMutableArray array];
    SPKSetting *addPlace = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_ADD_PLACE_TITLE")
                                                  subtitle:nil
                                                      icon:SPKSettingsIcon(@"location_add")
                                                    action:^{
                                                        UIViewController *presenter = SPKSettingsTopPresenter();
                                                        [SPKFakeLocationPickerViewController presentFromViewController:presenter
                                                                                                          initialPlace:[SPKFakeLocation currentPlace]
                                                                                                                 title:SPKL(@"MESSAGES_FAKE_LOCATION_ADD_PLACE_TITLE")
                                                                                                            completion:^(SPKFakeLocationPlace *place) {
                                                                                                                SPKFakeLocationPromptToSavePlace(SPKSettingsTopPresenter(), place);
                                                                                                            }];
                                                    }];
    [savedActions addObject:addPlace];

    if (currentPlace && !SPKFakeLocationCurrentIsSaved()) {
        SPKSetting *saveCurrent = [SPKSetting buttonCellWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_SAVE_CURRENT_TITLE")
                                                         subtitle:nil
                                                             icon:SPKSettingsIcon(@"save")
                                                           action:^{
                                                               SPKFakeLocationPromptToSavePlace(SPKSettingsTopPresenter(), [SPKFakeLocation currentPlace]);
                                                           }];
        [savedActions addObject:saveCurrent];
    }

    NSMutableArray *placeRows = [NSMutableArray array];
    for (SPKFakeLocationPlace *place in [SPKFakeLocation savedPlaces])
        [placeRows addObject:SPKFakeLocationSavedPlaceRow(place)];

    NSMutableArray *sections = [NSMutableArray arrayWithObjects:
                                                   SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"MESSAGES_FAKE_LOCATION_TITLE"), @[ enabled, location ], nil), YES),
                                                   SPKTopicSection(SPKL(@"MESSAGES_FAKE_LOCATION_FRIENDS_MAP_HEADER"), @[ mapButton ], nil),
                                                   nil];
    // The places themselves continue the Saved Places section in a block of their
    // own, below the actions that add to it. The footer explains the place rows,
    // so it sits under them when there are any.
    NSString *footer = SPKL(@"MESSAGES_FAKE_LOCATION_SAVED_FOOTER");
    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_FAKE_LOCATION_SAVED_HEADER"), savedActions, placeRows.count ? nil : footer)];
    if (placeRows.count)
        [sections addObject:SPKTopicSection(@"", placeRows, footer)];
    return sections;
}

@implementation SPKFakeLocationSettingsViewController {
    id _changeObserver;
}

- (instancetype)init {
    return [super initWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_TITLE") sections:SPKFakeLocationSettingsSections() reduceMargin:NO];
}

- (void)dealloc {
    if (_changeObserver)
        [[NSNotificationCenter defaultCenter] removeObserver:_changeObserver];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Changes also arrive from the Friends Map menu and from the picker, which
    // outlive the row that started them, so the page follows the store instead.
    __weak typeof(self) weakSelf = self;
    _changeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:SPKFakeLocationDidChangeNotification
                                                                        object:nil
                                                                         queue:[NSOperationQueue mainQueue]
                                                                    usingBlock:^(__unused NSNotification *note) {
                                                                        [weakSelf spk_reloadIfVisible];
                                                                    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self replaceSections:SPKFakeLocationSettingsSections()];
}

- (void)spk_reloadIfVisible {
    if (!self.viewIfLoaded.window)
        return;
    // A reload rebuilds the switch cells without animation; let a toggle that
    // triggered this change finish sliding first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self replaceSections:SPKFakeLocationSettingsSections()];
    });
}

- (SPKSetting *)spk_rowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count)
        return nil;
    NSArray *rows = self.sections[indexPath.section][@"rows"];
    return indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
}

- (NSString *)spk_placeIdentifierAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [self spk_rowAtIndexPath:indexPath].userInfo[kSPKFakeLocationRowPlaceIDKey];
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

// The base page reports no editing style for any row, which also withholds swipe
// actions; saved places are the one kind of row here that can be swiped.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self spk_placeIdentifierAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKSetting *row = [self spk_rowAtIndexPath:indexPath];
    NSString *identifier = [self spk_placeIdentifierAtIndexPath:indexPath];
    if (!identifier)
        return [UISwipeActionsConfiguration configurationWithActions:@[]];

    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:nil
                                                                       handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
                                                                           [SPKFakeLocation removeSavedPlaceWithIdentifier:identifier];
                                                                           completion(YES);
                                                                       }];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:nil
                                                                       handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
                                                                           completion(YES);
                                                                           [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                                                                                                  title:SPKL(@"MESSAGES_FAKE_LOCATION_RENAME_TITLE")
                                                                                                                                message:nil
                                                                                                                            placeholder:SPKL(@"MESSAGES_FAKE_LOCATION_NAME_PLACEHOLDER")
                                                                                                                            initialText:row.title
                                                                                                                        autocapitalized:YES
                                                                                                                           confirmTitle:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT")
                                                                                                                            cancelTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                           confirmStyle:SPKIGAlertActionStyleDefault
                                                                                                                           confirmBlock:^(NSString *text) {
                                                                                                                               [SPKFakeLocation renameSavedPlaceWithIdentifier:identifier toName:text ?: @""];
                                                                                                                           }
                                                                                                                            cancelBlock:nil];
                                                                       }];
    delete.image = [SPKAssetUtils menuIconNamed:@"trash"];
    delete.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    delete.accessibilityLabel = SPKL(@"ALERT_ACTION_DELETE");
    rename.image = [SPKAssetUtils menuIconNamed:@"edit"];
    rename.backgroundColor = [SPKUtils SPKColor_InstagramBlue];
    rename.accessibilityLabel = SPKL(@"GALLERY_GALLERY_RENAME_TEXT");
    return [UISwipeActionsConfiguration configurationWithActions:@[ delete, rename ]];
}

@end
