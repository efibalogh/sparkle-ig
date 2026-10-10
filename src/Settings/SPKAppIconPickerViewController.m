#import "SPKStrings.h"
#import "SPKAppIconPickerViewController.h"

#import <errno.h>

#import "../AssetUtils.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKNotificationCenter.h"
#import "../Utils.h"
#import "SPKAppIconCatalog.h"

@interface SPKAppIconPickerViewController ()
@property (nonatomic, copy) void (^onSelect)(NSString *identifier);

- (void)spk_setAlternateIconName:(NSString *)name
                         attempt:(NSInteger)attempt
                     maxAttempts:(NSInteger)maxAttempts
                      completion:(void (^)(NSError *error))completion;
@end

@implementation SPKAppIconPickerViewController

- (instancetype)initWithSelectedIdentifier:(NSString *)selectedIdentifier
                                  onSelect:(void (^)(NSString *identifier))onSelect {
    self = [super init];
    if (self) {
        self.selectedIdentifier = [selectedIdentifier copy] ?: @"";
        _onSelect = [onSelect copy];
        self.title = SPKL(@"GENERAL_GENERAL_APP_ICON_TITLE");
    }
    return self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // The icon can change underneath us (or fail silently); resync from the system.
    self.selectedIdentifier = [SPKAppIconCatalog currentAppIconIdentifier];
    [self refreshSelectionHighlight];
}

#pragma mark - SPKIconPickerViewController

- (SPKIconPickerCellStyle)cellStyle {
    return SPKIconPickerCellStyleAppIcon;
}
- (NSInteger)columnCountForWidth:(CGFloat)width {
    return width >= 500.0 ? 4 : 3;
}

- (NSArray<SPKIconPickerSection *> *)buildSections {
    // Icons that restyle themselves with the system appearance get a row each,
    // previewing their looks, above the grid of Instagram's single-image icons.
    NSArray<NSString *> *appearanceTitles = @[
        SPKL(@"SETTINGS_APP_ICON_PICKER_APPEARANCE_DEFAULT_LABEL"),
        SPKL(@"SETTINGS_APP_ICON_PICKER_APPEARANCE_DARK_LABEL"),
        SPKL(@"SETTINGS_APP_ICON_PICKER_APPEARANCE_CLEAR_LABEL")
    ];
    NSMutableArray<SPKIconPickerSection *> *sections = [NSMutableArray array];
    NSMutableArray<SPKIconPickerItem *> *items = [NSMutableArray array];
    for (SPKAppIconItem *icon in [SPKAppIconCatalog availableAppIcons]) {
        NSString *search = [NSString stringWithFormat:@"%@ %@ %@",
                                                      icon.identifier ?: @"", icon.displayName ?: @"", [icon.iconFiles componentsJoinedByString:@" "]];
        SPKIconPickerItem *item = [SPKIconPickerItem itemWithIdentifier:icon.identifier ?: @""
                                                                  title:icon.displayName
                                                             searchText:search];
        item.userInfo = icon;

        NSArray<UIImage *> *previews = [SPKAppIconCatalog appearancePreviewImagesForAppIcon:icon];
        if (previews.count == appearanceTitles.count) {
            item.previewImages = previews;
            item.previewTitles = appearanceTitles;
            [sections addObject:[SPKIconPickerSection sectionWithTitle:icon.displayName items:@[ item ]]];
            continue;
        }
        [items addObject:item];
    }

    NSString *gridTitle = sections.count > 0 ? SPKL(@"ABOUT_INFORMATION_INSTAGRAM_TITLE") : nil;
    [sections addObject:[SPKIconPickerSection sectionWithTitle:gridTitle items:items]];
    return sections;
}

- (UIImage *)imageForItem:(SPKIconPickerItem *)item {
    SPKAppIconItem *icon = item.userInfo;
    return icon ? [SPKAppIconCatalog imageForAppIcon:icon] : nil;
}

- (void)didSelectItem:(SPKIconPickerItem *)item {
    SPKAppIconItem *appIcon = item.userInfo;
    NSString *identifier = item.identifier ?: @"";
    if (!appIcon)
        return;

    if ([identifier isEqualToString:self.selectedIdentifier]) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    BOOL supportsAlternate = UIApplication.sharedApplication.supportsAlternateIcons;
    SPKLog(@"AppIcon", @"[Sparkle] select id='%@' name='%@' primary=%d supportsAlternate=%d currentAlt='%@'",
           identifier, appIcon.displayName, appIcon.isPrimary, supportsAlternate,
           UIApplication.sharedApplication.alternateIconName ?: @"(nil)");

    // Verify the alternate's PNG files actually resolve inside this (re-signed)
    // bundle. A missing loose icon file is the classic cause of the POSIX 35
    // ("resource temporarily unavailable") failure from setAlternateIconName.
    for (NSString *file in appIcon.iconFiles) {
        NSString *resolved = [NSBundle.mainBundle pathForResource:file ofType:@"png"]
                                 ?: [NSBundle.mainBundle pathForResource:file ofType:nil];
        SPKLog(@"AppIcon", @"[Sparkle]  iconFile '%@' -> %@", file, resolved ?: @"MISSING");
    }

    if (!supportsAlternate) {
        SPKLog(@"AppIcon", @"[Sparkle] abort: supportsAlternateIcons == NO");
        [SPKIGAlertPresenter presentAlertFromViewController:self
                                                      title:SPKL(@"SETTINGS_APP_ICON_PICKER_APP_ICONS_UNAVAILABLE_TEXT")
                                                    message:SPKL(@"SETTINGS_APP_ICON_PICKER_DEVICE_APP_BUILD_NOT_ALLOW_ALTERNATE_APP_ICONS_TEXT")
                                                    actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleDefault handler:nil] ]];
        return;
    }

    NSString *alternateIconName = appIcon.isPrimary ? nil : identifier;
    __weak typeof(self) weakSelf = self;
    [self spk_setAlternateIconName:alternateIconName
                           attempt:1
                       maxAttempts:4
                        completion:^(NSError *error) {
                            __strong typeof(weakSelf) self = weakSelf;
                            if (!self)
                                return;

                            if (error) {
                                [SPKIGAlertPresenter presentAlertFromViewController:self
                                                                              title:SPKL(@"SETTINGS_APP_ICON_PICKER_CHANGING_APP_ICON_FAILED_TEXT")
                                                                            message:error.localizedDescription ?: SPKL(@"SETTINGS_APP_ICON_PICKER_UNABLE_CHANGE_APP_ICON_TEXT")
                                                                            actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleDefault handler:nil] ]];
                                return;
                            }

                            self.selectedIdentifier = identifier;
                            [SPKAppIconCatalog setStoredSelectedIdentifier:identifier];
                            if (self.onSelect)
                                self.onSelect(identifier);
                            [self refreshSelectionHighlight];
                            SPKNotify(@"settings_app_icon", SPKL(@"SETTINGS_APP_ICON_PICKER_APP_ICON_CHANGED_TEXT"), appIcon.displayName, @"circle_check_filled", SPKNotificationToneForIconResource(@"circle_check_filled"));
                            [self.navigationController popViewControllerAnimated:YES];
                        }];
}

// `setAlternateIconName:` frequently fails on sideloaded/iOS 26 installs with
// NSPOSIXErrorDomain code 35 (EAGAIN) because iconservicesagent transiently
// rejects the request — typically after a re-sideload churns the app's
// LaunchServices registration. The first (failed) call often wakes the daemon,
// so we back off and retry on the main thread; `completion` runs once, on main,
// with the final result.
- (void)spk_setAlternateIconName:(NSString *)name
                         attempt:(NSInteger)attempt
                     maxAttempts:(NSInteger)maxAttempts
                      completion:(void (^)(NSError *error))completion {
    SPKLog(@"AppIcon", @"[Sparkle] calling setAlternateIconName:'%@' (attempt %ld/%ld)",
           name ?: @"(nil=primary)", (long)attempt, (long)maxAttempts);
    __weak typeof(self) weakSelf = self;
    [UIApplication.sharedApplication setAlternateIconName:name
                                        completionHandler:^(NSError *error) {
                                            BOOL isEAGAIN = error && [error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == EAGAIN;
                                            SPKLog(@"AppIcon", @"[Sparkle] completion attempt %ld/%ld: domain='%@' code=%ld eagain=%d",
                                                   (long)attempt, (long)maxAttempts, error.domain ?: @"(none)", (long)error.code, isEAGAIN);

                                            if (isEAGAIN && attempt < maxAttempts) {
                                                NSTimeInterval delay = 0.4 * (NSTimeInterval)attempt; // 0.4s, 0.8s, 1.2s
                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                                               dispatch_get_main_queue(), ^{
                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                   if (!self)
                                                                       return;
                                                                   [self spk_setAlternateIconName:name attempt:attempt + 1 maxAttempts:maxAttempts completion:completion];
                                                               });
                                                return;
                                            }

                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                if (completion)
                                                    completion(error);
                                            });
                                        }];
}

@end
