#import "SPKDestinations.h"
#import "SPKStrings.h"

#import "../../Features/Messages/DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import "../../Features/Profile/ProfileAnalyzer/SPKProfileAnalyzerViewController.h"
#import "../../Utils.h"
#import "../Downloads/SPKDownloadService.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../Instants/SPKInstantsSavedUsersViewController.h"

NSString *const SPKDestinationSettings = @"settings";
NSString *const SPKDestinationGallery = @"gallery";
NSString *const SPKDestinationAnalyzer = @"analyzer";
NSString *const SPKDestinationDeletedMessages = @"deleted";
NSString *const SPKDestinationDownloads = @"downloads";
NSString *const SPKDestinationSavedInstants = @"saved_instants";
NSString *const SPKDestinationInstagramSaved = @"ig_saved";
NSString *const SPKDestinationClipboardLink = @"clipboard_link";
NSString *const SPKDestinationClipboardLinkOrUsername = @"clipboard_username";

// Implemented next to the hooks that own them: Saved goes through the same
// Instagram route the Saved tab uses, and the clipboard holds through the
// Search tab hold's resolver.
#ifdef __cplusplus
extern "C" {
#endif
BOOL SPKOpenInstagramSavedHome(void);
void SPKOpenInstagramLinkFromClipboard(BOOL includeUsername);
#ifdef __cplusplus
}
#endif

@interface SPKDestination ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, nullable) NSString *compactTitle;
@property (nonatomic, copy, readwrite) NSString *iconName;
@property (nonatomic, readwrite) SPKDestinationGroup group;
@property (nonatomic, readwrite) SPKDestinationPlacement placements;
@property (nonatomic, copy) void (^opener)(UIWindow *_Nullable window);
@property (nonatomic, copy, nullable) UIViewController *_Nullable (^tabRootBuilder)(void);
@end

@implementation SPKDestination

+ (instancetype)destinationWithIdentifier:(NSString *)identifier
                                    title:(NSString *)title
                                 iconName:(NSString *)iconName
                                    group:(SPKDestinationGroup)group
                               placements:(SPKDestinationPlacement)placements
                                   opener:(void (^)(UIWindow *_Nullable))opener {
    SPKDestination *destination = [SPKDestination new];
    destination.identifier = identifier;
    destination.title = title;
    destination.iconName = iconName;
    destination.group = group;
    destination.placements = placements;
    destination.opener = opener;
    return destination;
}

- (NSString *)shortTitle {
    return self.compactTitle ?: self.title;
}

- (void)openFromWindow:(UIWindow *)window {
    SPKLog(@"Destinations", @"[Sparkle] Opening destination %@", self.identifier);
    if (self.opener)
        self.opener(window);
}

- (UIViewController *)makeTabRootViewController {
    return self.tabRootBuilder ? self.tabRootBuilder() : nil;
}

@end

NSArray<SPKDestination *> *SPKAllDestinations(void) {
    static NSArray<SPKDestination *> *destinations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKDestinationPlacement everywhere = SPKDestinationPlacementHold | SPKDestinationPlacementHeaderButton;
        destinations = @[
            [SPKDestination destinationWithIdentifier:SPKDestinationGallery
                                                title:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                             iconName:@"sparkle_gallery"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   [SPKGalleryViewController presentGallery];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationAnalyzer
                                                title:SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE")
                                             iconName:@"profile_analyzer"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   [SPKProfileAnalyzerViewController presentFromTop];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationDeletedMessages
                                                title:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                             iconName:@"channels"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   [SPKDeletedMessagesViewController presentFromViewController:nil];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationDownloads
                                                title:SPKL(@"DOWNLOADS_GENERAL_DOWNLOADS_TITLE")
                                             iconName:@"download"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   [SPKDownloadService presentDownloadsHistorySheet];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationSavedInstants
                                                title:SPKL(@"INSTANTS_INSTANTS_SAVED_USERS_SAVED_INSTANTS_TEXT")
                                             iconName:@"instants"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   [SPKInstantsSavedUsersViewController presentFromViewController:nil];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationSettings
                                                title:SPKL(@"FEED_DESTINATIONS_SPARKLE_SETTINGS_TITLE")
                                             iconName:@"settings"
                                                group:SPKDestinationGroupSparkle
                                           placements:everywhere
                                               opener:^(UIWindow *window) {
                                                   UIWindow *host = window ?: UIApplication.sharedApplication.keyWindow;
                                                   if (host)
                                                       [SPKUtils showSettingsVC:host];
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationInstagramSaved
                                                title:SPKL(@"TAB_SAVED")
                                             iconName:@"save"
                                                group:SPKDestinationGroupInstagram
                                           placements:everywhere
                                               opener:^(__unused UIWindow *window) {
                                                   if (!SPKOpenInstagramSavedHome())
                                                       SPKLog(@"Destinations", @"[Sparkle] Saved could not be opened from here");
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationClipboardLink
                                                title:SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_LINK_TITLE")
                                             iconName:@"link"
                                                group:SPKDestinationGroupAction
                                           placements:SPKDestinationPlacementHold
                                               opener:^(__unused UIWindow *window) {
                                                   SPKOpenInstagramLinkFromClipboard(NO);
                                               }],
            [SPKDestination destinationWithIdentifier:SPKDestinationClipboardLinkOrUsername
                                                title:SPKL(@"INTERFACE_TAB_BAR_HOLD_CLIPBOARD_LINK_OR_USERNAME")
                                             iconName:@"mention"
                                                group:SPKDestinationGroupAction
                                           placements:SPKDestinationPlacementHold
                                               opener:^(__unused UIWindow *window) {
                                                   SPKOpenInstagramLinkFromClipboard(YES);
                                               }],
        ];
        for (SPKDestination *destination in destinations) {
            if ([destination.identifier isEqualToString:SPKDestinationClipboardLink])
                destination.compactTitle = SPKL(@"INTERFACE_TAB_BAR_HOLD_CLIPBOARD_LINK_SHORT");
            else if ([destination.identifier isEqualToString:SPKDestinationClipboardLinkOrUsername])
                destination.compactTitle = SPKL(@"INTERFACE_TAB_BAR_HOLD_CLIPBOARD_LINK_OR_USERNAME_SHORT");
        }
    });
    return destinations;
}

NSArray<SPKDestination *> *SPKDestinationsForPlacement(SPKDestinationPlacement placement) {
    NSMutableArray<SPKDestination *> *matches = [NSMutableArray array];
    for (SPKDestination *destination in SPKAllDestinations()) {
        if (destination.placements & placement)
            [matches addObject:destination];
    }
    return matches;
}

SPKDestination *SPKDestinationForIdentifier(NSString *identifier) {
    if (identifier.length == 0)
        return nil;
    for (SPKDestination *destination in SPKAllDestinations()) {
        if ([destination.identifier isEqualToString:identifier])
            return destination;
    }
    return nil;
}
