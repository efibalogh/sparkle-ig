#if SPK_DEV

// Dev-only screen tour: opens Sparkle screens on command so a host script can
// screenshot every one of them in each display configuration.
//
// Protocol, all files under the app's Library/Caches:
//   spk-dev-tour.cmd   written by the host: "list", "dismiss" or "open <path>"
//   spk-dev-tour.out   written here when the command finishes: "ok", "error ..."
//                      or, for "list", one path per line
// The host posts the Darwin notification "com.sparkle.dev.tour" after writing
// the command.
//
// A path is either "settings" plus row slugs ("settings/interface/tab-bar"),
// opened by selecting each row through the real table delegate so every push,
// gate and sheet runs exactly as it does for a tap, or "screen/<name>" for
// screens that live outside Settings.

#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "../../InstagramHeaders.h"
#import "../../Settings/SPKSetting.h"
#import "../../Settings/SPKSettingsViewController.h"
#import "../../Settings/TweakSettings.h"
#import "../../Utils.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../../Features/Tools/SPKNetworkInterceptorViewController.h"
#import "../../Features/Profile/ProfileAnalyzer/SPKProfileAnalyzerViewController.h"
#import "../../Features/Messages/DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import "../../Settings/SPKOnboardingViewController.h"
#import "../../Settings/SPKWhatsNewViewController.h"
#import "../Gallery/SPKGalleryCoreDataStack.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../Gallery/SPKGalleryFileDetailsViewController.h"
#import "../PhotoEdit/SPKPhotoEditorViewController.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "../UI/SPKNotificationPillView.h"
#import "../UI/SPKUserListViewController.h"
#import "../Gallery/SPKGalleryImportViewController.h"
#import "../Gallery/SPKGalleryPickerViewController.h"
#import "../ActionButton/SPKBulkMediaSelectionViewController.h"
#import "../MediaTrim/SPKTrimEditorViewController.h"
#import "../MediaTrim/SPKVideoCropViewController.h"

// A filled user list for the list layout; the real lists are empty on a fresh install.
@interface SPKDevTourUserList : SPKUserListViewController
@end

@implementation SPKDevTourUserList
- (NSArray<SPKUserListItem *> *)buildItems {
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 1; i <= 14; i++) {
        SPKUserListItem *item = [SPKUserListItem new];
        item.title = [NSString stringWithFormat:@"@sample.user.%lu", (unsigned long)i];
        item.subtitle = [NSString stringWithFormat:@"Sample User %lu", (unsigned long)i];
        item.isVerified = i % 4 == 0;
        [items addObject:item];
    }
    return items;
}
@end

static NSString *const kSPKDevTourNotification = @"com.sparkle.dev.tour";
static const NSTimeInterval kSPKDevTourStepDelay = 0.7;

static NSURL *SPKDevTourFile(NSString *name) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:name];
}

static UIWindow *SPKDevTourWindow(void);

// "ok" carries the active display so the host knows which one to capture:
// "ok <native width>x<native height> <h size class><v size class>".
static NSString *SPKDevTourOK(void) {
    UIWindow *window = SPKDevTourWindow();
    CGRect native = window.windowScene.screen.nativeBounds;
    UITraitCollection *traits = window.traitCollection;
    return [NSString stringWithFormat:@"ok %.0fx%.0f %@%@", native.size.width, native.size.height,
                                      traits.horizontalSizeClass == UIUserInterfaceSizeClassRegular ? @"R" : @"C",
                                      traits.verticalSizeClass == UIUserInterfaceSizeClassRegular ? @"R" : @"C"];
}

static void SPKDevTourFinish(NSString *result) {
    [result writeToURL:SPKDevTourFile(@"spk-dev-tour.out") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPKLog(@"DevTour", @"%@", [result componentsSeparatedByString:@"\n"].firstObject);
}

static NSString *SPKDevTourSlug(NSString *title) {
    NSMutableString *slug = [NSMutableString string];
    BOOL dash = NO;
    for (NSUInteger i = 0; i < title.length; i++) {
        unichar c = [title characterAtIndex:i];
        if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) {
            if (dash && slug.length)
                [slug appendString:@"-"];
            [slug appendString:[[NSString stringWithCharacters:&c length:1] lowercaseString]];
            dash = NO;
        } else {
            dash = YES;
        }
    }
    return slug.length ? slug : @"row";
}

static BOOL SPKDevTourRowVisible(SPKSetting *row) {
    return !(row.hiddenProvider && row.hiddenProvider());
}

// Navigation rows of one page with their slugs. Slugs repeat only when titles
// do, so the repeat gets an index suffix.
static NSArray<NSArray *> *SPKDevTourNavigationRows(NSArray *sections) {
    NSMutableArray *result = [NSMutableArray array];
    NSCountedSet *seen = [NSCountedSet set];
    for (NSDictionary *section in sections) {
        for (SPKSetting *row in section[@"rows"]) {
            if (![row isKindOfClass:SPKSetting.class] || row.type != SPKTableCellNavigation || !SPKDevTourRowVisible(row))
                continue;
            NSString *slug = SPKDevTourSlug(row.title ?: @"");
            [seen addObject:slug];
            NSUInteger count = [seen countForObject:slug];
            if (count > 1)
                slug = [slug stringByAppendingFormat:@"-%lu", (unsigned long)count];
            [result addObject:@[ slug, row ]];
        }
    }
    return result;
}

static void SPKDevTourCollect(NSArray *sections, NSString *prefix, NSMutableArray<NSString *> *paths, NSUInteger depth) {
    if (depth > 6)
        return;
    for (NSArray *entry in SPKDevTourNavigationRows(sections)) {
        NSString *path = [prefix stringByAppendingFormat:@"/%@", entry[0]];
        [paths addObject:path];
        SPKSetting *row = entry[1];
        if (row.navSections.count)
            SPKDevTourCollect(row.navSections, path, paths, depth + 1);
    }
}

// Newest Gallery file of a media type, the sample for the media screens.
static SPKGalleryFile *SPKDevTourGalleryFile(int16_t type) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"SPKGalleryFile"];
    request.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", type];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO] ];
    request.fetchLimit = 1;
    SPKGalleryFile *file = [[SPKGalleryCoreDataStack shared].viewContext executeFetchRequest:request error:nil].firstObject;
    if (!file)
        SPKLog(@"DevTour", @"no gallery file of type %d", type);
    return file;
}

// The same viewer the expand action uses.
static void SPKDevTourPreviewGalleryFile(int16_t type) {
    SPKGalleryFile *file = SPKDevTourGalleryFile(type);
    if (file)
        [SPKFullScreenMediaPlayer showGalleryFiles:@[ file ] startingAtIndex:0 fromViewController:topMostController()];
}

static NSArray<SPKGalleryFile *> *SPKDevTourGalleryFiles(NSUInteger limit) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"SPKGalleryFile"];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:NO] ];
    request.fetchLimit = limit;
    return [[SPKGalleryCoreDataStack shared].viewContext executeFetchRequest:request error:nil] ?: @[];
}

// The gallery on top after presentGallery, to drive its own actions.
static void SPKDevTourGalleryAction(SEL action) {
    [SPKGalleryViewController presentGallery];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = topMostController();
        if ([top isKindOfClass:UINavigationController.class])
            top = ((UINavigationController *)top).topViewController;
        if ([top respondsToSelector:action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [top performSelector:action];
#pragma clang diagnostic pop
        } else {
            SPKLog(@"DevTour", @"%@ does not respond to %@", top.class, NSStringFromSelector(action));
        }
    });
}

// Notification prefs the tour changes, with their values before the first change,
// put back on the next dismiss.
static NSMutableDictionary<NSString *, id> *SPKDevTourSavedPrefs;

static void SPKDevTourSetDefault(NSString *effective, id value) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!SPKDevTourSavedPrefs)
        SPKDevTourSavedPrefs = [NSMutableDictionary dictionary];
    if (!SPKDevTourSavedPrefs[effective])
        SPKDevTourSavedPrefs[effective] = [defaults objectForKey:effective] ?: NSNull.null;
    [defaults setObject:value forKey:effective];
}

static void SPKDevTourSetPref(NSString *key, id value) {
    SPKDevTourSetDefault(SPKEffectivePreferenceKey(key), value);
}

static void SPKDevTourRestorePrefs(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [SPKDevTourSavedPrefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (value == NSNull.null)
            [defaults removeObjectForKey:key];
        else
            [defaults setObject:value forKey:key];
    }];
    [SPKDevTourSavedPrefs removeAllObjects];
}

static void SPKDevTourNotify(NSString *style, NSString *position, BOOL progress) {
    SPKDevTourSetPref(kSPKNotificationStyleKey, style);
    SPKDevTourSetPref(kSPKNotificationPillPositionKey, position);
    SPKDevTourSetPref(kSPKNotificationPillDurationKey, @6.0);
    if (progress) {
        SPKNotificationPillView *pill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:@"Downloading" onCancel:^{}];
        [pill setProgress:0.42f animated:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [pill dismiss];
        });
    } else {
        SPKNotify(kSPKNotificationDownloadGallery, @"Saved to Gallery", @"Tap to open", @"download_filled", SPKNotificationToneSuccess);
    }
}

static void SPKDevTourVideo(void (^use)(NSURL *url)) {
    SPKGalleryFile *file = SPKDevTourGalleryFile(SPKGalleryMediaTypeVideo);
    if (file.filePath)
        use([NSURL fileURLWithPath:file.filePath]);
}

// Opens the story at `index` of the home feed's tray through the tray's own
// selection delegate, the same path a tap takes.
static void SPKDevTourOpenStory(NSInteger index) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
    for (NSUInteger i = 0; i < queue.count && i < 4000; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:UICollectionView.class] && view.window) {
            for (UIView *up = view.superview; up; up = up.superview) {
                if (![NSStringFromClass(up.class) containsString:@"StoryTray"])
                    continue;
                UICollectionView *tray = (UICollectionView *)view;
                // One section per tray item (list adapter), or one section of items.
                BOOL perSection = tray.numberOfSections > 1;
                NSInteger section = perSection ? index : 0, item = perSection ? 0 : index;
                if (tray.numberOfSections <= section || [tray numberOfItemsInSection:section] <= item)
                    break;
                NSIndexPath *path = [NSIndexPath indexPathForItem:item inSection:section];
                if ([tray.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)])
                    [tray.delegate collectionView:tray didSelectItemAtIndexPath:path];
                return;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

FOUNDATION_EXPORT void SPKPresentStoryMentionsSheet(UIView *overlayView);

static NSDictionary<NSString *, dispatch_block_t> *SPKDevTourScreens(void) {
    return @{
        @"ig/story-own" : ^{
            SPKDevTourOpenStory(0);
        },
        @"ig/story-other" : ^{
            SPKDevTourOpenStory(1);
        },
        @"ig/story-third" : ^{
            SPKDevTourOpenStory(2);
        },
        @"ig/story-mentions" : ^{
            SPKDevTourOpenStory(2);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                Class overlayClass = NSClassFromString(@"IGStoryFullscreenOverlayView");
                NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
                for (NSUInteger i = 0; i < queue.count && i < 20000; i++) {
                    if ([queue[i] isKindOfClass:overlayClass] && queue[i].window) {
                        SPKPresentStoryMentionsSheet(queue[i]);
                        return;
                    }
                    [queue addObjectsFromArray:queue[i].subviews];
                }
            });
        },
        @"screen/home" : ^{
        },
        @"screen/gallery-list" : ^{
            // The gallery reads its layout from this raw default when it opens.
            SPKDevTourSetDefault(@"gallery_view_mode", @1);
            [SPKGalleryViewController presentGallery];
        },
        @"screen/gallery-select" : ^{
            SPKDevTourGalleryAction(@selector(enterSelectionMode));
        },
        @"screen/gallery-sort" : ^{
            SPKDevTourGalleryAction(@selector(presentSort));
        },
        @"screen/gallery-filter" : ^{
            SPKDevTourGalleryAction(@selector(presentFilter));
        },
        @"screen/gallery-picker" : ^{
            [SPKGalleryPickerViewController presentFromViewController:topMostController() title:nil allowedMediaTypes:nil allowsMultipleSelection:YES completion:^(NSArray<SPKGalleryFile *> *files){}];
        },
        @"screen/gallery-import" : ^{
            SPKGalleryImportViewController *import = [[SPKGalleryImportViewController alloc] initWithDestinationFolderPath:nil];
            UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:import];
            [topMostController() presentViewController:nav animated:YES completion:nil];
            NSMutableArray<NSURL *> *urls = [NSMutableArray array];
            for (SPKGalleryFile *file in SPKDevTourGalleryFiles(4)) {
                if (file.filePath)
                    [urls addObject:[NSURL fileURLWithPath:file.filePath]];
            }
            SEL pick = @selector(documentPicker:didPickDocumentsAtURLs:);
            if (urls.count && [import respondsToSelector:pick])
                ((void (*)(id, SEL, id, id))objc_msgSend)(import, pick, nil, urls);
        },
        @"screen/bulk-select" : ^{
            NSMutableArray *items = [NSMutableArray array];
            for (SPKGalleryFile *file in SPKDevTourGalleryFiles(6)) {
                UIImage *image = file.mediaType == SPKGalleryMediaTypeImage ? [UIImage imageWithContentsOfFile:file.filePath] : nil;
                [items addObject:[SPKBulkSelectionItem itemWithThumbnailImage:image isVideo:file.mediaType == SPKGalleryMediaTypeVideo]];
            }
            NSArray *destinations = @[
                [SPKBulkSelectionDestination destinationWithIdentifier:@"photos" title:@"Photos" iconName:@"download"],
                [SPKBulkSelectionDestination destinationWithIdentifier:@"share" title:@"Share" iconName:@"share"],
                [SPKBulkSelectionDestination destinationWithIdentifier:@"copy" title:@"Copy" iconName:@"copy"],
                [SPKBulkSelectionDestination destinationWithIdentifier:@"gallery" title:@"Gallery" iconName:@"media"],
                [SPKBulkSelectionDestination destinationWithIdentifier:@"links" title:@"Copy Links" iconName:@"link"],
            ];
            [SPKBulkMediaSelectionViewController presentFromViewController:topMostController() items:items destinations:destinations completion:^(NSIndexSet *indexes, NSString *destination){}];
        },
        @"screen/trim-editor" : ^{
            SPKDevTourVideo(^(NSURL *url) {
                SPKTrimConfiguration *configuration = [SPKTrimConfiguration configurationWithVideoURL:url];
                configuration.allowsFrameOnly = YES;
                configuration.allowsCrop = YES;
                [SPKTrimEditorViewController presentWithConfiguration:configuration from:topMostController() completion:nil];
            });
        },
        @"screen/video-crop" : ^{
            SPKDevTourVideo(^(NSURL *url) {
                [SPKVideoCropViewController presentForVideoURL:url lockedAspectRatio:0 initialCrop:nil title:nil from:topMostController() completion:^(SPKTrimCrop *crop){}];
            });
        },
        @"screen/user-list" : ^{
            SPKDevTourUserList *list = [SPKDevTourUserList new];
            list.title = @"Users";
            list.showsAddButton = YES;
            UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:list];
            [topMostController() presentViewController:nav animated:YES completion:nil];
        },
        @"notify/pill-top" : ^{
            SPKDevTourNotify(@"pill", @"top", NO);
        },
        @"notify/pill-bottom" : ^{
            SPKDevTourNotify(@"pill", @"bottom", NO);
        },
        @"notify/pill-progress" : ^{
            SPKDevTourNotify(@"pill", @"top", YES);
        },
        @"notify/instagram-top" : ^{
            SPKDevTourNotify(@"instagram", @"top", NO);
        },
        @"notify/instagram-bottom" : ^{
            SPKDevTourNotify(@"instagram", @"bottom", NO);
        },
        @"notify/instagram-progress" : ^{
            SPKDevTourNotify(@"instagram", @"bottom", YES);
        },
        @"screen/gallery" : ^{
            [SPKGalleryViewController presentGallery];
        },
        @"screen/network-interceptor" : ^{
            [SPKNetworkInterceptorViewController present];
        },
        @"screen/profile-analyzer" : ^{
            [SPKProfileAnalyzerViewController presentFromTop];
        },
        @"screen/whats-new" : ^{
            [SPKWhatsNewViewController presentFromViewController:nil onFinish:nil];
        },
        @"screen/onboarding" : ^{
            [SPKOnboardingViewController presentFromViewController:nil onFinish:nil];
        },
        @"screen/preview-photo" : ^{
            SPKDevTourPreviewGalleryFile(SPKGalleryMediaTypeImage);
        },
        @"screen/preview-video" : ^{
            SPKDevTourPreviewGalleryFile(SPKGalleryMediaTypeVideo);
        },
        @"screen/photo-editor" : ^{
            SPKGalleryFile *file = SPKDevTourGalleryFile(SPKGalleryMediaTypeImage);
            UIImage *image = file ? [UIImage imageWithContentsOfFile:file.filePath] : nil;
            if (image)
                [SPKPhotoEditorViewController presentWithSourceImage:image configuration:nil from:topMostController() completion:^(UIImage *edited){}];
        },
        @"screen/file-details" : ^{
            SPKGalleryFile *file = SPKDevTourGalleryFile(SPKGalleryMediaTypeImage);
            if (!file)
                return;
            UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:[[SPKGalleryFileDetailsViewController alloc] initWithFile:file]];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [topMostController() presentViewController:nav animated:YES completion:nil];
        },
        @"screen/deleted-messages" : ^{
            [SPKDeletedMessagesViewController presentFromViewController:nil];
        },
    };
}

static NSString *SPKDevTourList(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:@"settings"];
    SPKDevTourCollect([SPKTweakSettings sections], @"settings", paths, 0);
    [paths addObjectsFromArray:[SPKDevTourScreens().allKeys sortedArrayUsingSelector:@selector(compare:)]];
    return [paths componentsJoinedByString:@"\n"];
}

static UIWindow *SPKDevTourWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow)
                return window;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static void SPKDevTourRestorePrefs(void);

// Clears toasts left by the previous screen so captures never stack them.
static void SPKDevTourClearNotifications(void) {
    SPKNotificationCenter *center = [SPKNotificationCenter shared];
    [(NSMutableArray *)[center valueForKey:@"queue"] removeAllObjects];
    for (id slot in [(NSArray *)[center valueForKey:@"visible"] copy])
        [(SPKNotificationPillView *)[slot valueForKey:@"pill"] dismiss];
}

static void SPKDevTourDismissAll(dispatch_block_t completion) {
    SPKDevTourRestorePrefs();
    SPKDevTourClearNotifications();
    UIViewController *root = SPKDevTourWindow().rootViewController;
    if (root.presentedViewController)
        [root dismissViewControllerAnimated:NO completion:completion];
    else
        completion();
}

static SPKSettingsViewController *SPKDevTourTopSettings(void) {
    UIViewController *top = topMostController();
    return [top isKindOfClass:SPKSettingsViewController.class] ? (SPKSettingsViewController *)top : nil;
}

// Selects the next row of the path on the settings page on top, then waits for
// the push or presentation before taking the following step.
static void SPKDevTourStep(NSArray<NSString *> *slugs, NSUInteger index, NSString *path) {
    if (index >= slugs.count) {
        SPKDevTourFinish(SPKDevTourOK());
        return;
    }
    SPKSettingsViewController *page = SPKDevTourTopSettings();
    if (!page) {
        SPKDevTourFinish([NSString stringWithFormat:@"error %@: no settings page on top at %@", path, slugs[index]]);
        return;
    }
    NSArray<NSArray *> *rows = SPKDevTourNavigationRows(page.sections);
    SPKSetting *target = nil;
    for (NSArray *entry in rows) {
        if ([entry[0] isEqualToString:slugs[index]]) {
            target = entry[1];
            break;
        }
    }
    NSIndexPath *indexPath = nil;
    for (NSUInteger s = 0; target && !indexPath && s < page.sections.count; s++) {
        NSUInteger r = [page.sections[s][@"rows"] indexOfObjectIdenticalTo:target];
        if (r != NSNotFound)
            indexPath = [NSIndexPath indexPathForRow:r inSection:s];
    }
    if (!indexPath) {
        SPKDevTourFinish([NSString stringWithFormat:@"error %@: no row %@", path, slugs[index]]);
        return;
    }
    [page.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    [page tableView:page.tableView didSelectRowAtIndexPath:indexPath];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKDevTourStepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKDevTourStep(slugs, index + 1, path);
    });
}

static void SPKDevTourOpen(NSString *path) {
    SPKDevTourDismissAll(^{
        dispatch_block_t screen = SPKDevTourScreens()[path];
        if (screen) {
            screen();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKDevTourStepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPKDevTourFinish(SPKDevTourOK());
            });
            return;
        }
        NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
        if (![components.firstObject isEqualToString:@"settings"]) {
            SPKDevTourFinish([NSString stringWithFormat:@"error %@: unknown path", path]);
            return;
        }
        [SPKUtils showSettingsVC:SPKDevTourWindow()];
        NSArray<NSString *> *slugs = [components subarrayWithRange:NSMakeRange(1, components.count - 1)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKDevTourStepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPKDevTourStep(slugs, 0, path);
        });
    });
}

// Describes the story viewer's vertical bar wiring for layout debugging.
static NSString *SPKDevTourChrome(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
            for (NSUInteger i = 0; i < queue.count && i < 20000; i++) {
                UIView *view = queue[i];
                NSString *name = NSStringFromClass(view.class);
                CGRect frame = [window convertRect:view.bounds fromView:view];
                BOOL inColumn = CGRectGetMinX(frame) >= CGRectGetWidth(window.bounds) - window.safeAreaInsets.right - 8.0 &&
                                CGRectGetWidth(frame) < 80.0 && !view.hidden;
                if (inColumn || [name containsString:@"VerticalBar"] || [name containsString:@"SPK"] || [name hasPrefix:@"_UIBarButton"] ||
                    [name containsString:@"FullscreenOverlayView"]) {
                    [lines addObject:[NSString stringWithFormat:@"%@ %@ hidden=%d alpha=%.2f", name, NSStringFromCGRect(frame), view.hidden, view.alpha]];
                }
                if ([view respondsToSelector:NSSelectorFromString(@"foldedDuoVerticalBarHeaderButtons")]) {
                    [lines addObject:[NSString stringWithFormat:@"  ^ duo content %@", name]];
                    for (NSString *ivarName in @[ @"_mediaView", @"_footerContainerView", @"_hypeFaceswarmView" ]) {
                        UIView *sub = [SPKUtils getIvarForObj:view name:ivarName.UTF8String];
                        if ([sub isKindOfClass:UIView.class])
                            [lines addObject:[NSString stringWithFormat:@"  %@ %@ in-overlay %@ hidden=%d", ivarName, NSStringFromClass(sub.class), NSStringFromCGRect([view convertRect:sub.bounds fromView:sub]), sub.hidden]];
                    }
                    NSMutableArray<UIView *> *inner = [NSMutableArray arrayWithObject:view];
                    for (NSUInteger j = 0; j < inner.count && j < 4000; j++) {
                        UIView *sub = inner[j];
                        NSString *subName = NSStringFromClass(sub.class);
                        if (!sub.hidden && ([subName containsString:@"Composer"] || [subName containsString:@"Reply"] || [subName containsString:@"TextField"] || [subName containsString:@"Footer"]))
                            [lines addObject:[NSString stringWithFormat:@"    %@ in-overlay %@", subName, NSStringFromCGRect([view convertRect:sub.bounds fromView:sub])]];
                        [inner addObjectsFromArray:sub.subviews];
                    }
                    for (NSString *selName in @[ @"foldedDuoVerticalBarHeaderButtons", @"foldedDuoVerticalBarItems" ]) {
                        SEL sel = NSSelectorFromString(selName);
                        if ([view respondsToSelector:sel])
                            [lines addObject:[NSString stringWithFormat:@"  %@ = %@", selName, ((id (*)(id, SEL))objc_msgSend)(view, sel)]];
                    }
                    for (UIViewController *vc = [SPKUtils nearestViewControllerForView:view]; vc; vc = vc.parentViewController)
                        [lines addObject:[NSString stringWithFormat:@"  vc %@ left=%@ right=%@", NSStringFromClass(vc.class), vc.navigationItem.leftBarButtonItems, vc.navigationItem.rightBarButtonItems]];
                }
                [queue addObjectsFromArray:view.subviews];
            }
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void SPKDevTourHandle(void) {
    NSString *command = [NSString stringWithContentsOfURL:SPKDevTourFile(@"spk-dev-tour.cmd") encoding:NSUTF8StringEncoding error:nil];
    command = [command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSFileManager.defaultManager removeItemAtURL:SPKDevTourFile(@"spk-dev-tour.out") error:nil];
    if ([command isEqualToString:@"list"]) {
        SPKDevTourFinish(SPKDevTourList());
    } else if ([command isEqualToString:@"chrome"]) {
        SPKDevTourFinish(SPKDevTourChrome());
    } else if ([command isEqualToString:@"dismiss"]) {
        SPKDevTourDismissAll(^{
            SPKDevTourFinish(SPKDevTourOK());
        });
    } else if ([command hasPrefix:@"open "]) {
        SPKDevTourOpen([[command substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    } else {
        SPKDevTourFinish([NSString stringWithFormat:@"error unknown command: %@", command]);
    }
}

static void SPKDevTourNotified(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKDevTourHandle();
    });
}

__attribute__((constructor)) static void SPKDevTourInstall(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SPKDevTourNotified, (__bridge CFStringRef)kSPKDevTourNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

#endif
