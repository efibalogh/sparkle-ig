#import "SPKStrings.h"
#import "SPKNewBadges.h"
#import "SPKEditActionsListViewController.h"
#include <UIKit/UIKit.h>

#import "../AssetUtils.h"
#import "../Shared/ActionButton/SPKActionDescriptor.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Shared/UI/SPKSwitch.h"
#import "../Utils.h"
#import "SPKActionSectionEditViewController.h"
#import "SPKBulkActionMenuEditViewController.h"
#import "SPKPreferences.h"
#import "SPKSettingsTransferManager.h"
#import "SPKTopicSettingsSupport.h"
#import "../Shared/UI/SPKFont.h"

static char kSPKActionsListSwitchAssocKey;

@interface SPKEditActionsListViewController () <UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SPKActionButtonConfiguration *configuration;
@property (nonatomic, assign) SPKActionButtonSource source;
/// Badge items for actions whose NEW pill was shown, marked seen on leaving.
@property (nonatomic, strong) NSMutableSet<NSString *> *shownNewActionItems;

@end

@implementation SPKEditActionsListViewController

- (UIView *)selectionBackgroundView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    return view;
}

- (instancetype)initWithSource:(SPKActionButtonSource)source topicTitle:(NSString *)topicTitle {
    self = [super init];
    if (self) {
        _source = source;
        _configuration = [SPKActionButtonConfiguration configurationForSource:source
                                                                   topicTitle:topicTitle
                                                             supportedActions:SPKActionButtonSupportedActionsForSource(source)
                                                              defaultSections:SPKActionButtonDefaultSectionsForSource(source)];
        self.title = SPKL(@"SPKTOPICSETTINGSSUPPORT_GENERAL_CONFIGURE_ACTIONS_TITLE");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ SPKMediaChromeTopBarButtonItem(@"plus", self, @selector(addSectionTapped)) ]);
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];
    [self.view addSubview:self.tableView];
}

- (NSArray<NSString *> *)bulkEditorKinds {
    // Download All / Copy All are derived from the single-item action config and
    // are no longer separately configurable. Only the profile Copy Info submenu
    // remains editable here.
    NSMutableArray<NSString *> *kinds = [NSMutableArray array];
    if (self.source == SPKActionButtonSourceProfile) {
        [kinds addObject:@"copy_info"];
    }
    return kinds;
}

- (BOOL)hasBulkEditorSection {
    return [self bulkEditorKinds].count > 0;
}

- (NSInteger)bulkEditorSectionIndex {
    return [self hasBulkEditorSection] ? 1 : NSNotFound;
}

- (NSInteger)unassignedSectionIndex {
    return [self hasBulkEditorSection] ? 2 : 1;
}

- (NSInteger)availableSectionIndex {
    return [self hasBulkEditorSection] ? 3 : 2;
}

- (NSInteger)resetSectionIndex {
    return [self hasBulkEditorSection] ? 4 : 3;
}

- (NSString *)bulkEditorKindForRow:(NSInteger)row {
    NSArray<NSString *> *kinds = [self bulkEditorKinds];
    if (row < 0 || row >= (NSInteger)kinds.count) {
        return nil;
    }
    return kinds[row];
}

- (NSString *)bulkEditorTitleForKind:(NSString *)kind {
    if ([kind isEqualToString:@"copy_info"]) {
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_CONFIGURE_COPY_INFO_MENU_TEXT");
    }
    return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_CONFIGURE_MENU_TEXT");
}

- (NSString *)bulkEditorSubtitleForKind:(NSString *)kind {
    (void)kind;
    return nil;
}

- (SPKBulkActionMenuEditViewController *)bulkEditorControllerForKind:(NSString *)kind {
    if ([kind isEqualToString:@"copy_info"]) {
        return [[SPKBulkActionMenuEditViewController alloc] initWithTitle:SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_COPY_INFO_MENU_TEXT")
                                                                   source:self.source
                                                         supportedActions:SPKProfileCopyInfoSupportedActions()
                                                        configuredActions:SPKProfileConfiguredCopyInfoActions()
                                                                   onSave:^(NSArray<NSString *> *actions) {
                                                                       SPKProfileSetConfiguredCopyInfoActions(actions);
                                                                   }];
    }

    return nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ([self hasBulkEditorSection] ? 4 : 3) + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0)
        return self.configuration.sections.count;
    if (section == [self bulkEditorSectionIndex])
        return [self bulkEditorKinds].count;
    if (section == [self unassignedSectionIndex])
        return self.configuration.unassignedActions.count;
    if (section == [self resetSectionIndex])
        return 1;
    return self.configuration.supportedActions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0)
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_MENU_SECTIONS_TEXT");
    if (section == [self bulkEditorSectionIndex])
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_MENUS_TEXT");
    if (section == [self unassignedSectionIndex])
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_UNASSIGNED_ACTIONS_ACTION");
    if (section == [self resetSectionIndex])
        return nil;
    return SPKL(@"SETTINGS_ACTION_SECTION_EDIT_AVAILABLE_ACTIONS_ACTION");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_LONG_PRESS_DRAG_REORDER_SECTIONS_TEXT");
    if (section == [self unassignedSectionIndex])
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_ACTIONS_HERE_SUPPORTED_BUT_NOT_APPEAR_RUNTIME_MENU_ACTION");
    if (section == [self availableSectionIndex])
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_DISABLED_ACTIONS_HIDDEN_EVEN_IF_THEY_REMAIN_ASSIGNED_SECTION_ACTION");
    if (section == [self resetSectionIndex])
        return SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_RESTORES_SURFACE_S_MENU_SECTIONS_DEFAULT_ACTION_BULK_MENUS_TEXT");
    return nil;
}

// YES when the section still holds an action whose enable switch is off — that action
// stays assigned but is hidden from the runtime menu, so we flag the section row.
- (BOOL)sectionHasDisabledAction:(SPKActionMenuSection *)section {
    for (NSString *identifier in section.actions) {
        if ([self.configuration.disabledActions containsObject:identifier])
            return YES;
    }
    return NO;
}

- (void)spk_applyNewBadgeForAction:(NSString *)identifier toConfiguration:(UIListContentConfiguration *)config cell:(UITableViewCell *)cell {
    NSString *item = SPKNewBadgeActionItemIdentifier(self.source, identifier);
    if (!SPKNewBadgeItemIsNew(item) || config.text.length == 0)
        return;
    NSString *title = config.text;
    UIFont *font = config.textProperties.font ?: [SPKFont fontForStyle:SPKFontStyleBody];
    config.attributedText = SPKNewBadgeAttributedTitle(title, font, config.textProperties.color, SPKNewBadgeStateRow, self.tableView.traitCollection);
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, SPKNewBadgeAccessibilityText(SPKNewBadgeStateRow)];
    if (!self.shownNewActionItems)
        self.shownNewActionItems = [NSMutableSet set];
    [self.shownNewActionItems addObject:item];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.shownNewActionItems.count) {
        NSArray<NSString *> *items = self.shownNewActionItems.allObjects;
        [self.shownNewActionItems removeAllObjects];
        SPKNewBadgesMarkItemsSeen(items, self);
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    UIListContentConfiguration *config = cell.defaultContentConfiguration;
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    cell.selectedBackgroundView = [self selectionBackgroundView];
    config.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    config.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];

    if (indexPath.section == 0) {
        SPKActionMenuSection *section = self.configuration.sections[indexPath.row];
        config.text = section.title;
        NSString *stateText = section.collapsible ? SPKL(@"SETTINGS_ACTION_SECTION_EDIT_COLLAPSIBLE_TEXT") : SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_INLINE_TEXT");
        if ([self sectionHasDisabledAction:section]) {
            // Prefix the Collapsible/Inline subtitle with an amber warning triangle so
            // it's obvious — while arranging sections — that this section contains an
            // action switched off in "Available Actions" (hidden from the runtime menu).
            UIFont *font = config.secondaryTextProperties.font ?: [SPKFont fontForStyle:SPKFontStyleSubheadline];
            UIImage *warning = [[SPKAssetUtils instagramIconNamed:@"warning_filled" pointSize:16.0]
                imageWithTintColor:[UIColor systemOrangeColor]
                     renderingMode:UIImageRenderingModeAlwaysOriginal];
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = warning;
            CGFloat yOffset = (font.capHeight - warning.size.height) / 2.0;
            attachment.bounds = CGRectMake(0.0, round(yOffset), warning.size.width, warning.size.height);
            NSMutableAttributedString *subtitle = [[NSMutableAttributedString alloc] init];
            [subtitle appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            [subtitle appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:stateText]
                                                                             attributes:@{
                                                                                 NSForegroundColorAttributeName : [SPKUtils SPKColor_InstagramSecondaryText],
                                                                                 NSFontAttributeName : font
                                                                             }]];
            config.secondaryAttributedText = subtitle;
        } else {
            config.secondaryText = stateText;
        }
        config.image = SPKSettingsIcon(section.iconName);
        config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.showsReorderControl = YES;
    } else if (indexPath.section == [self bulkEditorSectionIndex]) {
        NSString *kind = [self bulkEditorKindForRow:indexPath.row];
        config.text = [self bulkEditorTitleForKind:kind];
        config.secondaryText = [self bulkEditorSubtitleForKind:kind];
        config.image = SPKSettingsIcon([kind isEqualToString:@"download"] ? @"download" : @"copy");
        config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == [self resetSectionIndex]) {
        config.text = SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_RESET_DEFAULT_TEXT");
        config.textProperties.color = [SPKUtils SPKColor_InstagramDestructive];
        config.image = SPKSettingsIcon(@"arrow_ccw");
        config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramDestructive];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == [self unassignedSectionIndex]) {
        NSString *identifier = self.configuration.unassignedActions[indexPath.row];
        config.text = SPKActionDescriptorDisplayTitle(identifier, self.configuration.topicTitle);
        [self spk_applyNewBadgeForAction:identifier toConfiguration:config cell:cell];
        config.image = SPKSettingsIcon(SPKActionDescriptorIconName(identifier));
        config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    } else {
        NSString *identifier = self.configuration.supportedActions[indexPath.row];
        config.text = SPKActionDescriptorDisplayTitle(identifier, self.configuration.topicTitle);
        [self spk_applyNewBadgeForAction:identifier toConfiguration:config cell:cell];
        config.image = SPKSettingsIcon(SPKActionDescriptorIconName(identifier));
        config.imageProperties.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];

        SPKSwitch *toggle = [[SPKSwitch alloc] init];
        toggle.on = ![self.configuration.disabledActions containsObject:identifier];
        objc_setAssociatedObject(toggle, &kSPKActionsListSwitchAssocKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [toggle addTarget:self action:@selector(disabledSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    cell.contentConfiguration = config;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0)
        return @[];
    SPKActionMenuSection *section = self.configuration.sections[indexPath.row];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:section.identifier]];
    item.localObject = section.identifier;
    return @[ item ];
}

- (BOOL)tableView:(UITableView *)tableView dragSessionAllowsMoveOperation:(id<UIDragSession>)session {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView dragSessionIsRestrictedToDraggingApplication:(id<UIDragSession>)session {
    return YES;
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession == nil || destinationIndexPath.section != 0) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    NSIndexPath *destinationIndexPath = coordinator.destinationIndexPath;
    id<UITableViewDropItem> dropItem = coordinator.items.firstObject;
    NSIndexPath *sourceIndexPath = dropItem.sourceIndexPath;
    if (!destinationIndexPath ||
        !sourceIndexPath ||
        sourceIndexPath.section != 0 ||
        destinationIndexPath.section != 0)
        return;

    NSInteger rowCount = self.configuration.sections.count;
    NSInteger destinationRow = MIN(MAX(0, destinationIndexPath.row), MAX(0, rowCount - 1));
    NSIndexPath *target = [NSIndexPath indexPathForRow:destinationRow inSection:0];

    [tableView
        performBatchUpdates:^{
            [self.configuration moveSectionFromIndex:sourceIndexPath.row toIndex:target.row];
            [self.configuration save];
            [tableView moveRowAtIndexPath:sourceIndexPath toIndexPath:target];
        }
                 completion:nil];
    [coordinator dropItem:dropItem.dragItem toRowAtIndexPath:target];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == [self resetSectionIndex]) {
        [self resetConfigurationTapped];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if (indexPath.section == [self bulkEditorSectionIndex]) {
        NSString *kind = [self bulkEditorKindForRow:indexPath.row];
        UIViewController *controller = [self bulkEditorControllerForKind:kind];
        if (controller) {
            [self.navigationController pushViewController:controller animated:YES];
        }
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if (indexPath.section == 0) {
        SPKActionMenuSection *section = self.configuration.sections[indexPath.row];
        __weak typeof(self) weakSelf = self;
        SPKActionSectionEditViewController *controller = [[SPKActionSectionEditViewController alloc] initWithConfiguration:self.configuration
                                                                                                         sectionIdentifier:section.identifier
                                                                                                                  onChange:^{
                                                                                                                      [weakSelf.configuration save];
                                                                                                                      [weakSelf.tableView reloadData];
                                                                                                                  }];
        [self.navigationController pushViewController:controller animated:YES];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (void)removeSectionAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)self.configuration.sections.count)
        return;

    SPKActionMenuSection *section = self.configuration.sections[indexPath.row];
    for (NSString *identifier in section.actions) {
        if (![self.configuration.unassignedActions containsObject:identifier]) {
            [self.configuration.unassignedActions addObject:identifier];
        }
    }
    [self.configuration.sections removeObjectAtIndex:indexPath.row];
    [self.configuration save];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    [self removeSectionAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath])
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:nil
                                                                             handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
                                                                                 [weakSelf removeSectionAtIndexPath:indexPath];
                                                                                 completionHandler(YES);
                                                                             }];
    deleteAction.image = [SPKAssetUtils menuIconNamed:@"trash"];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_REMOVE_SECTION_TEXT");
    return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
}

- (void)addSectionTapped {
    SPKActionMenuSection *section = [SPKActionMenuSection sectionWithIdentifier:NSUUID.UUID.UUIDString
                                                                          title:[NSString stringWithFormat:SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_SECTION_VALUE_FORMAT"), (unsigned long)(self.configuration.sections.count + 1)]
                                                                       iconName:@"more"
                                                                    collapsible:YES
                                                                        actions:@[]];
    [self.configuration.sections addObject:section];
    [self.configuration save];
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    SPKActionSectionEditViewController *controller = [[SPKActionSectionEditViewController alloc] initWithConfiguration:self.configuration
                                                                                                     sectionIdentifier:section.identifier
                                                                                                              onChange:^{
                                                                                                                  [weakSelf.configuration save];
                                                                                                                  [weakSelf.tableView reloadData];
                                                                                                              }];
    [self.navigationController pushViewController:controller animated:YES];
}

- (NSArray<NSString *> *)configurationResetKeys {
    NSString *topic = SPKActionButtonTopicKeyForSource(self.source);
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithArray:@[
        SPKPrefActionButtonConfigKey(topic),
        SPKPrefActionButtonDefaultActionKey(topic),
        SPKPrefActionButtonBulkDownloadKey(topic),
        SPKPrefActionButtonBulkCopyKey(topic)
    ]];
    // The profile Copy Info submenu and its default copy action are edited from this
    // surface too, so fold them into the profile reset.
    if (self.source == SPKActionButtonSourceProfile) {
        [keys addObject:@"profile_action_btn_copy_info_submenu_actions"];
        [keys addObject:@"profile_action_btn_default_copy_info_action"];
    }
    return keys;
}

- (void)resetConfigurationTapped {
    __weak typeof(self) weakSelf = self;
    [[SPKSettingsTransferManager sharedManager]
        resetConfigurationGroupFromController:self
                                        title:SPKL(@"SETTINGS_EDIT_ACTIONS_LIST_RESET_DEFAULT_TEXT")
                                      message:SPKL(@"ACTION_BUTTON_EDITOR_RESET_CONFIRMATION_MESSAGE")
                                 confirmTitle:SPKL(@"DATA_RESET_HEADER")
                                         keys:[self configurationResetKeys]
                                      onReset:^{
                                          typeof(self) strongSelf = weakSelf;
                                          if (!strongSelf)
                                              return;
                                          strongSelf.configuration = [SPKActionButtonConfiguration configurationForSource:strongSelf.source
                                                                                                               topicTitle:strongSelf.configuration.topicTitle
                                                                                                         supportedActions:SPKActionButtonSupportedActionsForSource(strongSelf.source)
                                                                                                          defaultSections:SPKActionButtonDefaultSectionsForSource(strongSelf.source)];
                                          [strongSelf.tableView reloadData];
                                      }];
}

- (void)disabledSwitchChanged:(UISwitch *)sender {
    NSString *identifier = objc_getAssociatedObject(sender, &kSPKActionsListSwitchAssocKey);
    if (identifier.length == 0)
        return;

    if (sender.isOn) {
        [self.configuration.disabledActions removeObject:identifier];
    } else if (![self.configuration.disabledActions containsObject:identifier]) {
        [self.configuration.disabledActions addObject:identifier];
    }
    [self.configuration save];

    // Refresh the section rows so the "disabled action" warning triangle appears/clears
    // as this action is toggled. Reloading section 0 (the switch lives in a different
    // section, so its toggle animation is untouched).
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

@end
