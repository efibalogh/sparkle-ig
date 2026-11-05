#import "SPKStrings.h"
#import "SPKGalleryFileDetailsViewController.h"
#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryFile.h"

typedef NS_ENUM(NSInteger, SPKDetailsEditRow) {
    SPKDetailsEditRowName = 0,
    SPKDetailsEditRowUsername,
    SPKDetailsEditRowAccount,
    SPKDetailsEditRowDate,
    SPKDetailsEditRowCount,
};

@interface SPKGalleryFileDetailsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) SPKGalleryFile *file;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UIDatePicker *datePicker;
// Pending owner-account selection (applied on save). nil PK = unassigned.
@property (nonatomic, copy, nullable) NSString *selectedOwnerPK;
@property (nonatomic, copy, nullable) NSString *selectedOwnerUsername;
// Read-only (label, value) info pairs.
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *infoRows;
// The item's original link, shown as the last info row and copied on tap.
@property (nonatomic, strong, nullable) NSURL *originalLink;
@end

@implementation SPKGalleryFileDetailsViewController

- (instancetype)initWithFile:(SPKGalleryFile *)file {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _file = file;
        _selectedOwnerPK = file.ownerAccountPK.length > 0 ? file.ownerAccountPK : nil;
        _selectedOwnerUsername = file.ownerUsername.length > 0 ? file.ownerUsername : nil;
        [self buildControls];
        [self buildInfoRows];
    }
    return self;
}

- (void)buildControls {
    _nameField = [self editableField];
    _nameField.text = self.file.customName;
    _nameField.placeholder = SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DISPLAY_NAME_TEXT");
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;

    _usernameField = [self editableField];
    _usernameField.text = self.file.sourceUsername;
    _usernameField.placeholder = SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT");
    _usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _usernameField.autocorrectionType = UITextAutocorrectionTypeNo;

    _datePicker = [[UIDatePicker alloc] init];
    _datePicker.datePickerMode = UIDatePickerModeDateAndTime;
    _datePicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    _datePicker.date = self.file.dateAdded ?: [NSDate date];
    _datePicker.tintColor = [SPKUtils SPKColor_InstagramBlue];
}

- (UITextField *)editableField {
    UITextField *field = [[UITextField alloc] init];
    field.delegate = self;
    field.returnKeyType = UIReturnKeyDone;
    field.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    field.textAlignment = NSTextAlignmentRight;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    return field;
}

- (void)buildInfoRows {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSString *typeName = @"Photo";
    if (self.file.mediaType == SPKGalleryMediaTypeVideo)
        typeName = @"Video";
    else if (self.file.mediaType == SPKGalleryMediaTypeAudio)
        typeName = @"Audio";
    [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_TYPE_TEXT"), typeName ]];
    if (self.file.pixelWidth > 0 && self.file.pixelHeight > 0) {
        [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DIMENSIONS_TEXT"), [NSString stringWithFormat:@"%d × %d", self.file.pixelWidth, self.file.pixelHeight] ]];
    }
    if (self.file.mediaType == SPKGalleryMediaTypeVideo && self.file.durationSeconds > 0) {
        NSInteger total = (NSInteger)llround(self.file.durationSeconds);
        [rows addObject:@[ SPKL(@"NOTIFICATION_APPEARANCE_DURATION_TITLE"), [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)] ]];
    }
    if (self.file.fileSize > 0) {
        [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SIZE_TEXT"), [NSByteCountFormatter stringFromByteCount:self.file.fileSize countStyle:NSByteCountFormatterCountStyleFile] ]];
    }
    NSString *folder = self.file.folderPath.length > 0 ? [self.file.folderPath lastPathComponent] : SPKL(@"GALLERY_TITLE");
    [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_FOLDER_TEXT"), folder ]];
    if (self.file.sourceMediaCode.length > 0) {
        [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_MEDIA_CODE_TEXT"), self.file.sourceMediaCode ]];
    }
    self.originalLink = [self.file originalWebURL];
    if (self.originalLink) {
        // Without the scheme and "www.", which say nothing and push the part
        // that identifies the link out of a one-line cell.
        NSString *shown = self.originalLink.absoluteString;
        for (NSString *prefix in @[ @"https://", @"http://", @"www." ]) {
            if ([shown hasPrefix:prefix])
                shown = [shown substringFromIndex:prefix.length];
        }
        [rows addObject:@[ SPKL(@"GALLERY_GALLERY_FILE_DETAILS_LINK_TEXT"), shown ]];
    }
    self.infoRows = rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"ALERT_ACTION_EDIT_DETAILS");
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];

    UIBarButtonItem *cancelItem = SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(cancel));
    cancelItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
    UIBarButtonItem *saveItem = SPKMediaChromeTopBarButtonItemWithStyle(@"check", self, @selector(save), UIBarButtonItemStyleDone, [SPKUtils SPKColor_InstagramBlue], SPKL(@"GALLERY_GALLERY_FILE_DETAILS_SAVE_TEXT"));
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ saveItem ]);
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)save {
    [self.view endEditing:YES];
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *username = [self.usernameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.file.customName = name.length > 0 ? name : nil;
    self.file.sourceUsername = username.length > 0 ? username : nil;
    self.file.dateAdded = self.datePicker.date;
    self.file.ownerAccountPK = self.selectedOwnerPK.length > 0 ? self.selectedOwnerPK : nil;
    self.file.ownerUsername = self.selectedOwnerPK.length > 0 ? self.selectedOwnerUsername : nil;
    [[SPKGalleryCoreDataStack shared] saveContext];
    if (self.onSaved) {
        self.onSaved();
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DETAILS_TEXT") : SPKL(@"GALLERY_GALLERY_FILE_DETAILS_INFO_TEXT");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? SPKDetailsEditRowCount : (NSInteger)self.infoRows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.textLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.detailTextLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];

    if (indexPath.section == 0) {
        switch ((SPKDetailsEditRow)indexPath.row) {
        case SPKDetailsEditRowName:
            cell.textLabel.text = SPKL(@"SETTINGS_PROFILE_NAME_TEXT");
            [self embedAccessory:self.nameField inCell:cell];
            break;
        case SPKDetailsEditRowUsername:
            cell.textLabel.text = SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT");
            [self embedAccessory:self.usernameField inCell:cell];
            break;
        case SPKDetailsEditRowAccount: {
            cell.textLabel.text = SPKL(@"GALLERY_GALLERY_FILE_DETAILS_ACCOUNT_TEXT");
            cell.detailTextLabel.text = [self ownerDisplayText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            UIView *selectedBackground = [[UIView alloc] init];
            selectedBackground.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
            cell.selectedBackgroundView = selectedBackground;
            break;
        }
        case SPKDetailsEditRowDate:
            cell.textLabel.text = SPKL(@"GALLERY_GALLERY_FILE_DETAILS_DATE_TEXT");
            [self embedAccessory:self.datePicker inCell:cell];
            break;
        default:
            break;
        }
    } else {
        NSArray<NSString *> *row = self.infoRows[indexPath.row];
        cell.textLabel.text = row.firstObject;
        cell.detailTextLabel.text = row.lastObject;
        if ([self isLinkRowAtIndexPath:indexPath]) {
            // The one info row that does something: tapping it copies the link.
            cell.detailTextLabel.textColor = [SPKUtils SPKColor_InstagramBlue];
            cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            UIView *selectedBackground = [[UIView alloc] init];
            selectedBackground.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
            cell.selectedBackgroundView = selectedBackground;
            cell.accessibilityTraits |= UIAccessibilityTraitButton;
            cell.accessibilityHint = SPKL(@"ALERT_ACTION_COPY_LINK");
        }
    }
    return cell;
}

- (NSString *)ownerDisplayText {
    if (self.selectedOwnerPK.length == 0)
        return SPKL(@"ALERT_ACTION_UNASSIGNED");
    NSString *username = self.selectedOwnerUsername.length > 0
                             ? self.selectedOwnerUsername
                             : [SPKAccountManager usernameForPK:self.selectedOwnerPK];
    return username.length > 0 ? [@"@" stringByAppendingString:username] : self.selectedOwnerPK;
}

// Accounts offered in the picker: the roster of seen accounts, plus the file's
// current owner if it isn't in the roster (so an external/edited owner stays
// selectable).
- (NSArray<NSDictionary *> *)pickerAccounts {
    NSMutableArray<NSDictionary *> *accounts = [[SPKAccountManager knownAccounts] mutableCopy];
    BOOL hasSelected = NO;
    for (NSDictionary *account in accounts) {
        if ([account[@"pk"] isEqualToString:self.selectedOwnerPK]) {
            hasSelected = YES;
            break;
        }
    }
    if (self.selectedOwnerPK.length > 0 && !hasSelected) {
        [accounts addObject:@{@"pk" : self.selectedOwnerPK, @"username" : self.selectedOwnerUsername ?: @""}];
    }
    return accounts;
}

- (void)presentAccountPicker {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<SPKIGAlertAction *> *actions = [NSMutableArray array];
    for (NSDictionary *account in [self pickerAccounts]) {
        NSString *pk = account[@"pk"];
        NSString *username = account[@"username"];
        if (![pk isKindOfClass:[NSString class]] || pk.length == 0)
            continue;
        NSString *title = username.length > 0 ? [@"@" stringByAppendingString:username] : pk;
        [actions addObject:[SPKIGAlertAction actionWithTitle:title
                                                       style:SPKIGAlertActionStyleDefault
                                                     handler:^{
                                                         weakSelf.selectedOwnerPK = pk;
                                                         weakSelf.selectedOwnerUsername = username.length > 0 ? username : nil;
                                                         [weakSelf.tableView reloadData];
                                                     }]];
    }
    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_UNASSIGNED")
                                                   style:SPKIGAlertActionStyleDestructive
                                                 handler:^{
                                                     weakSelf.selectedOwnerPK = nil;
                                                     weakSelf.selectedOwnerUsername = nil;
                                                     [weakSelf.tableView reloadData];
                                                 }]];
    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:SPKIGAlertActionStyleCancel handler:nil]];

    [SPKIGAlertPresenter presentActionSheetFromViewController:self
                                                        title:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_CHANGE_FILE_OWNER_TEXT")
                                                      message:SPKL(@"GALLERY_GALLERY_FILE_DETAILS_ACCOUNT_FILE_BELONG_QUESTION")
                                                      actions:actions];
}

- (BOOL)isLinkRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.originalLink && indexPath.section == 1 && indexPath.row == (NSInteger)self.infoRows.count - 1;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isLinkRowAtIndexPath:indexPath]) {
        UIPasteboard.generalPasteboard.string = self.originalLink.absoluteString;
        SPKNotify(kSPKNotificationGalleryOpenOriginal, SPKL(@"GALLERY_GALLERY_FILE_DETAILS_COPIED_LINK_TEXT"), nil, @"copy_filled",
                  SPKNotificationToneSuccess);
        return;
    }
    if (indexPath.section == 0 && (SPKDetailsEditRow)indexPath.row == SPKDetailsEditRowAccount) {
        [self.view endEditing:YES];
        [self presentAccountPicker];
    }
}

- (void)embedAccessory:(UIView *)view inCell:(UITableViewCell *)cell {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    cell.accessoryView = nil;
    [cell.contentView addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:cell.textLabel.trailingAnchor
                                           constant:12],
        [view.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [view.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
