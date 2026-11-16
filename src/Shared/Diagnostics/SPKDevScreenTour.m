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
#import <objc/runtime.h>
#include <dlfcn.h>
#include <sys/sysctl.h>

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
#import "../Playback/SPKPlaybackPanel.h"
#import "../Location/SPKFakeLocationPickerViewController.h"
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
        // Pages with their own controller expose their rows through the search provider.
        NSArray *children = row.navSections.count ? row.navSections : (row.searchSectionsProvider ? row.searchSectionsProvider() : nil);
        if (children.count)
            SPKDevTourCollect(children, path, paths, depth + 1);
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
static void SPKDevTourOpenStoryInTray(NSInteger index) {
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

static IGTabBarController *SPKDevTourTabBarController(void) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    if (SPKDevTourWindow().rootViewController)
        [queue addObject:SPKDevTourWindow().rootViewController];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        if ([queue[i] isKindOfClass:NSClassFromString(@"IGTabBarController")])
            return (IGTabBarController *)queue[i];
        [queue addObjectsFromArray:queue[i].childViewControllers];
    }
    return nil;
}

static UITabBarController *SPKDevTourNativeTabBarController(void) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    if (SPKDevTourWindow().rootViewController)
        [queue addObject:SPKDevTourWindow().rootViewController];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        if ([queue[i] isKindOfClass:UITabBarController.class])
            return (UITabBarController *)queue[i];
        [queue addObjectsFromArray:queue[i].childViewControllers];
    }
    return nil;
}

static NSString *SPKDevTourSurfaceList(id surfaces) {
    if (![surfaces isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"%@", surfaces];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id surface in (NSArray *)surfaces) {
        NSString *tab = [surface respondsToSelector:@selector(tabStringFromSurfaceIntent)] ? [surface tabStringFromSurfaceIntent] : nil;
        NSNumber *subtype = nil;
        @try {
            subtype = [surface valueForKey:@"_subtype"];
        } @catch (__unused NSException *e) {
        }
        [names addObject:tab.length ? tab : [NSString stringWithFormat:@"sub%@", subtype]];
    }
    return [names componentsJoinedByString:@","];
}

// Native tab bar state, for the system tab bar audit.
static NSString *SPKDevTourTabs(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    IGTabBarController *tabs = SPKDevTourTabBarController();
    Ivar flag = tabs ? class_getInstanceVariable(object_getClass(tabs), "_usesNativeTabBarController") : NULL;
    BOOL native = flag && *((uint8_t *)(__bridge void *)tabs + ivar_getOffset(flag));
    [lines addObject:[NSString stringWithFormat:@"native=%d sizeClass=%ld safe=%@ style=%@", native, (long)tabs.traitCollection.horizontalSizeClass,
                                                NSStringFromUIEdgeInsets(tabs.view.safeAreaInsets),
                                                [tabs respondsToSelector:@selector(tabBarStyle)] ? @(tabs.tabBarStyle) : @"?"]];
    [lines addObject:[@"surfaces=" stringByAppendingString:SPKDevTourSurfaceList([SPKUtils getIvarForObj:tabs name:"_tabBarSurfaces"])]];
    [lines addObject:[@"compact=" stringByAppendingString:SPKDevTourSurfaceList([SPKUtils getIvarForObj:tabs name:"_nativeCompactTabBarSurfaces"])]];
    SEL ordered = NSSelectorFromString(@"_nativeOrderedSurfacesForHorizontalSizeClass:");
    if ([tabs respondsToSelector:ordered]) {
        for (NSInteger sizeClass = 1; sizeClass <= 2; sizeClass++)
            [lines addObject:[NSString stringWithFormat:@"ordered[%ld]=%@", (long)sizeClass,
                                                        SPKDevTourSurfaceList(((id (*)(id, SEL, NSInteger))objc_msgSend)(tabs, ordered, sizeClass))]];
    }
    SEL rendered = NSSelectorFromString(@"_renderedTabBarSurfaces");
    if ([tabs respondsToSelector:rendered])
        [lines addObject:[@"rendered=" stringByAppendingString:SPKDevTourSurfaceList(((id (*)(id, SEL))objc_msgSend)(tabs, rendered))]];
    SEL descriptors = NSSelectorFromString(@"_nativeTabDescriptors");
    if ([tabs respondsToSelector:descriptors]) {
        NSArray *list = ((id (*)(id, SEL))objc_msgSend)(tabs, descriptors);
        id first = list.firstObject;
        if (first) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(object_getClass(first), &count);
            NSMutableArray *names = [NSMutableArray array];
            for (unsigned int i = 0; i < count; i++)
                [names addObject:@(ivar_getName(ivars[i]))];
            free(ivars);
            [lines addObject:[NSString stringWithFormat:@"descriptor %@ ivars=%@", NSStringFromClass(object_getClass(first)), [names componentsJoinedByString:@","]]];
        }
        for (id d in list)
            [lines addObject:[NSString stringWithFormat:@"  %@", [d description]]];
    }
    [lines addObject:[@"selectedSurface=" stringByAppendingString:SPKDevTourSurfaceList(@[ [tabs selectedTabBarSurface] ?: NSNull.null ])]];
    UITabBarController *system = SPKDevTourNativeTabBarController();
    if (system) {
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        if ([system respondsToSelector:NSSelectorFromString(@"tabs")]) {
            for (id tab in ((NSArray * (*)(id, SEL)) objc_msgSend)(system, NSSelectorFromString(@"tabs")))
                [items addObject:[NSString stringWithFormat:@"%@[%@]%@", [tab valueForKey:@"title"], [tab valueForKey:@"identifier"],
                                                            [[tab valueForKey:@"hidden"] boolValue] ? @"(hidden)" : @""]];
        }
        [lines addObject:[NSString stringWithFormat:@"system tabs=%@ selectedIndex=%lu", [items componentsJoinedByString:@" | "], (unsigned long)system.selectedIndex]];
        UITabBar *bar = system.tabBar;
        [lines addObject:[NSString stringWithFormat:@"bar %@ frame=%@ hidden=%d items=%lu sizeClass=%ld", NSStringFromClass(bar.class),
                                                    NSStringFromCGRect([bar convertRect:bar.bounds toView:nil]), bar.hidden,
                                                    (unsigned long)bar.items.count, (long)system.traitCollection.horizontalSizeClass]];
        SEL minimize = NSSelectorFromString(@"tabBarMinimizeBehavior");
        if ([system respondsToSelector:minimize])
            [lines addObject:[NSString stringWithFormat:@"minimize=%ld", (long)((NSInteger (*)(id, SEL))objc_msgSend)(system, minimize)]];
        [lines addObject:[NSString stringWithFormat:@"standardAppearance bg=%@ effect=%@ shadow=%@", bar.standardAppearance.backgroundColor,
                                                    bar.standardAppearance.backgroundEffect, bar.standardAppearance.shadowColor]];
        for (NSString *name in @[ @"_nativeTabBarAppearance", @"_nativeTabBarHidden" ]) {
            Ivar ivar = class_getInstanceVariable(object_getClass(tabs), name.UTF8String);
            if (ivar)
                [lines addObject:[NSString stringWithFormat:@"%@=%d", name, *((uint8_t *)(__bridge void *)tabs + ivar_getOffset(ivar))]];
        }
    } else {
        [lines addObject:@"system=none"];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// Selects a tab through the tab bar controller's own button handler.
static void SPKDevTourSelectTab(SEL handler) {
    IGTabBarController *tabs = SPKDevTourTabBarController();
    if ([tabs respondsToSelector:handler])
        ((void (*)(id, SEL))objc_msgSend)(tabs, handler);
}

// Opens the first conversation of the Direct inbox, the way a tap does.
static void SPKDevTourOpenFirstThread(void) {
    SPKDevTourSelectTab(@selector(_directInboxButtonPressed));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
        for (NSUInteger i = 0; i < queue.count && i < 20000; i++) {
            UIView *view = queue[i];
            [queue addObjectsFromArray:view.subviews];
            if (![view isKindOfClass:UICollectionView.class] || !view.window)
                continue;
            UICollectionView *list = (UICollectionView *)view;
            for (UICollectionViewCell *cell in [list.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
                     return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
                 }]) {
                if (![NSStringFromClass(cell.class) containsString:@"InboxThread"] && ![NSStringFromClass(cell.class) containsString:@"ThreadCell"])
                    continue;
                NSIndexPath *path = [list indexPathForCell:cell];
                if (path && [list.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                    [list.delegate collectionView:list didSelectItemAtIndexPath:path];
                    return;
                }
            }
        }
    });
}

// The tray lives on the home feed, so switch there first.
static void SPKDevTourOpenStory(NSInteger index) {
    SPKDevTourSelectTab(@selector(_timelineButtonPressed));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKDevTourOpenStoryInTray(index);
    });
}

FOUNDATION_EXPORT void SPKPresentStoryMentionsSheet(UIView *overlayView);

static NSDictionary<NSString *, dispatch_block_t> *SPKDevTourScreens(void) {
    return @{
        @"ig/feed" : ^{
            SPKDevTourSelectTab(@selector(_timelineButtonPressed));
        },
        @"ig/reels" : ^{
            SPKDevTourSelectTab(@selector(_discoverVideoButtonPressed));
        },
        @"ig/inbox" : ^{
            SPKDevTourSelectTab(@selector(_directInboxButtonPressed));
        },
        @"ig/explore" : ^{
            SPKDevTourSelectTab(@selector(_exploreButtonPressed));
        },
        @"ig/profile" : ^{
            SPKDevTourSelectTab(@selector(_profileButtonPressed));
        },
        @"ig/thread" : ^{
            SPKDevTourOpenFirstThread();
        },
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        @"screen/fake-location-picker" : ^{
            [SPKFakeLocationPickerViewController presentFromViewController:nil initialPlace:nil title:@"Location" completion:^(SPKFakeLocationPlace *place){}];
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
    SPKPlaybackPanelDismiss(NO);
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

// Lists every visible view whose class or accessibility identifier contains the
// needle, with its window frame, recognizers, and nearest ancestors.
// Lists every live view controller's navigation bar items, with the identifiers
// and labels found inside each custom view.
static NSString *SPKDevTourDescribeBarItem(UIBarButtonItem *item) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *custom = item.customView;
    if (custom) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:custom];
        for (NSUInteger i = 0; i < queue.count && i < 60; i++) {
            UIView *view = queue[i];
            [queue addObjectsFromArray:view.subviews];
            if (view.accessibilityIdentifier.length || view.accessibilityLabel.length)
                [parts addObject:[NSString stringWithFormat:@"%@[%@|%@]", NSStringFromClass(view.class), view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @""]];
        }
    }
    return [NSString stringWithFormat:@"<%@ %p custom=%@ title=%@ id=%@ %@>", NSStringFromClass(item.class), item, NSStringFromClass(custom.class),
                                      item.title ?: @"", item.accessibilityIdentifier ?: @"", [parts componentsJoinedByString:@" "]];
}

static void SPKDevTourCollectNavItems(UIViewController *vc, NSMutableArray<NSString *> *lines, NSUInteger depth) {
    if (!vc || depth > 12 || !vc.isViewLoaded || !vc.view.window)
        return;
    UINavigationItem *item = vc.navigationItem;
    if (item.leftBarButtonItems.count || item.rightBarButtonItems.count) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0], NSStringFromClass(vc.class)]];
        for (UIBarButtonItem *bar in item.leftBarButtonItems)
            [lines addObject:[NSString stringWithFormat:@"   L %@", SPKDevTourDescribeBarItem(bar)]];
        for (UIBarButtonItem *bar in item.rightBarButtonItems)
            [lines addObject:[NSString stringWithFormat:@"   R %@", SPKDevTourDescribeBarItem(bar)]];
    }
    for (UIViewController *child in vc.childViewControllers)
        SPKDevTourCollectNavItems(child, lines, depth + 1);
    if (vc.presentedViewController && vc.presentedViewController.presentingViewController == vc)
        SPKDevTourCollectNavItems(vc.presentedViewController, lines, depth + 1);
}

static NSString *SPKDevTourNavItems(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    SPKDevTourCollectNavItems(SPKDevTourWindow().rootViewController, lines, 0);
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"none";
}

static NSString *SPKDevTourFind(NSString *needle) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *lower = needle.lowercaseString;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
            for (NSUInteger i = 0; i < queue.count && i < 30000; i++) {
                UIView *view = queue[i];
                [queue addObjectsFromArray:view.subviews];
                NSString *name = NSStringFromClass(view.class);
                NSString *identifier = view.accessibilityIdentifier ?: @"";
                if (![name.lowercaseString containsString:lower] && ![identifier.lowercaseString containsString:lower])
                    continue;
                CGRect frame = [window convertRect:view.bounds fromView:view];
                [lines addObject:[NSString stringWithFormat:@"%@ id=%@ %@ hidden=%d alpha=%.2f ui=%d", name, identifier, NSStringFromCGRect(frame), view.hidden, view.alpha, view.userInteractionEnabled]];
                for (UIGestureRecognizer *gesture in view.gestureRecognizers)
                    [lines addObject:[NSString stringWithFormat:@"    gr %@", gesture.description]];
                if ([view isKindOfClass:UIControl.class]) {
                    for (id target in ((UIControl *)view).allTargets)
                        [lines addObject:[NSString stringWithFormat:@"    target %@ %@", NSStringFromClass([target class]), [((UIControl *)view) actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]]];
                }
                NSMutableArray<NSString *> *chain = [NSMutableArray array];
                UIView *walker = view.superview;
                for (NSUInteger depth = 0; walker && depth < 10; depth++, walker = walker.superview)
                    [chain addObject:NSStringFromClass(walker.class)];
                [lines addObject:[NSString stringWithFormat:@"    in %@", [chain componentsJoinedByString:@" < "]]];
            }
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"none";
}

// Fires the long-press targets whose action contains `actionNeedle` on the first
// visible view whose class or accessibility identifier contains `viewNeedle`, as
// if the press had just begun.
static NSString *SPKDevTourLongPress(NSString *viewNeedle, NSString *actionNeedle) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
    for (NSUInteger i = 0; i < queue.count && i < 30000; i++) {
        UIView *view = queue[i];
        [queue addObjectsFromArray:view.subviews];
        if (view.hidden || view.alpha < 0.01 || !view.window)
            continue;
        NSString *name = [NSStringFromClass(view.class) stringByAppendingFormat:@" %@", view.accessibilityIdentifier ?: @""];
        if ([name rangeOfString:viewNeedle options:NSCaseInsensitiveSearch].location == NSNotFound)
            continue;
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (![gesture isKindOfClass:UILongPressGestureRecognizer.class])
                continue;
            Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
            NSArray *targets = targetsIvar ? object_getIvar(gesture, targetsIvar) : nil;
            for (id entry in targets) {
                Ivar targetIvar = class_getInstanceVariable([entry class], "_target");
                Ivar actionIvar = class_getInstanceVariable([entry class], "_action");
                if (!targetIvar || !actionIvar)
                    continue;
                id target = object_getIvar(entry, targetIvar);
                SEL action = *(SEL *)((uint8_t *)(__bridge void *)entry + ivar_getOffset(actionIvar));
                if ([NSStringFromSelector(action) rangeOfString:actionNeedle options:NSCaseInsensitiveSearch].location == NSNotFound)
                    continue;
                [gesture setValue:@(UIGestureRecognizerStateBegan) forKey:@"state"];
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, gesture);
                [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                return [NSString stringWithFormat:@"ok %@ -[%@ %@]", NSStringFromClass(view.class), NSStringFromClass([target class]), NSStringFromSelector(action)];
            }
        }
    }
    return @"error no matching long press";
}

static void SPKDevTourHandle(void) {
    NSString *command = [NSString stringWithContentsOfURL:SPKDevTourFile(@"spk-dev-tour.cmd") encoding:NSUTF8StringEncoding error:nil];
    command = [command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSFileManager.defaultManager removeItemAtURL:SPKDevTourFile(@"spk-dev-tour.out") error:nil];
    if ([command isEqualToString:@"list"]) {
        SPKDevTourFinish(SPKDevTourList());
    } else if ([command hasPrefix:@"hit "]) {
        // The view a touch at window point "x y" lands on.
        NSArray<NSString *> *parts = [[command substringFromIndex:4] componentsSeparatedByString:@" "];
        UIWindow *window = SPKDevTourWindow();
        CGPoint point = CGPointMake(parts.firstObject.doubleValue, parts.lastObject.doubleValue);
        UIView *hit = [window hitTest:point withEvent:nil];
        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        for (UIView *view = hit; view && chain.count < 6; view = view.superview)
            [chain addObject:NSStringFromClass(view.class)];
        SPKDevTourFinish([chain componentsJoinedByString:@" < "]);
    } else if ([command isEqualToString:@"tallbar"]) {
        // Instagram's tall navigation bar: where its trailing items go.
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        Class tallClass = NSClassFromString(@"IGTallNavigationBarView");
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
        for (NSUInteger i = 0; i < queue.count && i < 20000; i++) {
            UIView *view = queue[i];
            [queue addObjectsFromArray:view.subviews];
            if (!tallClass || ![view isKindOfClass:tallClass])
                continue;
            id bar = [SPKUtils getIvarForObj:view name:"_navigationBar"];
            UINavigationItem *item = [SPKUtils getIvarForObj:view name:"_navigationItem"];
            [lines addObject:[NSString stringWithFormat:@"tall %@ bar=%@", NSStringFromCGRect(view.frame), NSStringFromClass([bar class])]];
            for (NSString *name in @[ @"_trailingButtonsInVerticalBar", @"_backButtonInVerticalBar" ]) {
                Ivar ivar = bar ? class_getInstanceVariable([bar class], name.UTF8String) : NULL;
                if (ivar)
                    [lines addObject:[NSString stringWithFormat:@"  %@=%d", name, *(BOOL *)((__bridge void *)bar + ivar_getOffset(ivar))]];
            }
            for (NSString *selName in @[ @"isPresentedInVerticalBar", @"allowsVerticalBarButtonItems" ]) {
                SEL sel = NSSelectorFromString(selName);
                if ([bar respondsToSelector:sel])
                    [lines addObject:[NSString stringWithFormat:@"  %@=%d", selName, ((BOOL (*)(id, SEL))objc_msgSend)(bar, sel)]];
            }
            for (UIBarButtonItem *bbi in item.rightBarButtonItems)
                [lines addObject:[NSString stringWithFormat:@"  item R %@", SPKDevTourDescribeBarItem(bbi)]];
            SEL trailing = NSSelectorFromString(@"ig_headerTrailingBarButtonItems");
            if ([bar respondsToSelector:trailing])
                for (UIBarButtonItem *bbi in ((NSArray * (*)(id, SEL)) objc_msgSend)(bar, trailing))
                    [lines addObject:[NSString stringWithFormat:@"  trailing %@", SPKDevTourDescribeBarItem(bbi)]];
        }
        SPKDevTourFinish(lines.count ? [lines componentsJoinedByString:@"\n"] : @"none");
    } else if ([command isEqualToString:@"navitems"]) {
        SPKDevTourFinish(SPKDevTourNavItems());
    } else if ([command isEqualToString:@"chrome"]) {
        SPKDevTourFinish(SPKDevTourChrome());
    } else if ([command hasPrefix:@"story "]) {
        NSInteger index = [[command substringFromIndex:6] integerValue];
        SPKDevTourDismissAll(^{
            SPKDevTourOpenStory(index);
            SPKDevTourFinish(SPKDevTourOK());
        });
    } else if ([command hasPrefix:@"longpress "]) {
        NSArray<NSString *> *parts = [[command substringFromIndex:10] componentsSeparatedByString:@" "];
        SPKDevTourFinish(parts.count == 2 ? SPKDevTourLongPress(parts[0], parts[1]) : @"error usage: longpress <view> <action>");
    } else if ([command hasPrefix:@"pref "]) {
        // pref <key> <value>: persists a preference (1/0 = bool, numbers, else string).
        NSArray<NSString *> *parts = [[command substringFromIndex:5] componentsSeparatedByString:@" "];
        if (parts.count < 2) {
            SPKDevTourFinish(@"error usage: pref <key> <value>");
            return;
        }
        NSString *raw = parts[1];
        id value = raw;
        if ([raw isEqualToString:@"1"] || [raw isEqualToString:@"0"] || [raw isEqualToString:@"true"] || [raw isEqualToString:@"false"])
            value = @([raw isEqualToString:@"1"] || [raw isEqualToString:@"true"]);
        else if ([raw rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"].invertedSet].location == NSNotFound)
            value = @(raw.doubleValue);
        NSString *key = SPKEffectivePreferenceKey(parts[0]);
        [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
        SPKDevTourFinish([NSString stringWithFormat:@"ok %@ = %@", key, value]);
    } else if ([command hasPrefix:@"scroll "]) {
        // Scrolls the largest visible vertical scroll view of the key window by dy points.
        CGFloat dy = [[command substringFromIndex:7] doubleValue];
        UIScrollView *best = nil;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:SPKDevTourWindow()];
        for (NSUInteger i = 0; i < queue.count && i < 20000; i++) {
            UIView *view = queue[i];
            [queue addObjectsFromArray:view.subviews];
            if (![view isKindOfClass:UIScrollView.class] || view.hidden || view.alpha < 0.01 || !view.window)
                continue;
            UIScrollView *scroll = (UIScrollView *)view;
            if (scroll.contentSize.height <= CGRectGetHeight(scroll.bounds))
                continue;
            if (!best || CGRectGetWidth(scroll.bounds) * CGRectGetHeight(scroll.bounds) > CGRectGetWidth(best.bounds) * CGRectGetHeight(best.bounds))
                best = scroll;
        }
        CGFloat maxY = MAX(best.contentSize.height - CGRectGetHeight(best.bounds) + best.adjustedContentInset.bottom, -best.adjustedContentInset.top);
        [best setContentOffset:CGPointMake(best.contentOffset.x, MIN(MAX(best.contentOffset.y + dy, -best.adjustedContentInset.top), maxY)) animated:NO];
        SPKDevTourFinish(best ? [NSString stringWithFormat:@"ok %@ %.0f", NSStringFromClass(best.class), best.contentOffset.y] : @"error no scroll view");
    } else if ([command hasPrefix:@"clip "]) {
        // Sets the app's pasteboard directly; the host clipboard sync overwrites simctl pbcopy.
        UIPasteboard.generalPasteboard.string = [command substringFromIndex:5];
        SPKDevTourFinish([NSString stringWithFormat:@"ok %@", UIPasteboard.generalPasteboard.string]);
    } else if ([command isEqualToString:@"adaptive"]) {
        // Every argument-free BOOL class method of Instagram's adaptive layout classes.
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *name in @[ @"_TtC22IGAdaptivePresentation22IGAdaptivePresentation", @"_TtC22IGAdaptivePresentation19IGAdaptiveStatusBar" ]) {
            Class cls = NSClassFromString(name);
            unsigned int count = 0;
            Method *methods = cls ? class_copyMethodList(object_getClass(cls), &count) : NULL;
            for (unsigned int i = 0; i < count; i++) {
                const char *type = method_getTypeEncoding(methods[i]);
                SEL sel = method_getName(methods[i]);
                if (!type || type[0] != 'B' || method_getNumberOfArguments(methods[i]) != 2)
                    continue;
                BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(cls, sel);
                Dl_info info = {0};
                dladdr((const void *)method_getImplementation(methods[i]), &info);
                [lines addObject:[NSString stringWithFormat:@"%@ %@ = %d imp=+0x%lx", [name substringFromIndex:24], NSStringFromSelector(sel), value,
                                                            (unsigned long)((uintptr_t)method_getImplementation(methods[i]) - (uintptr_t)info.dli_fbase)]];
            }
            free(methods);
        }
        int (*sdkCheck)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "METAIsIOS27_1SDKAndRuntime");
        [lines addObject:[NSString stringWithFormat:@"METAIsIOS27_1SDKAndRuntime = %d", sdkCheck ? sdkCheck() : -1]];
        for (NSString *key in @[ @"kern.osproductversion", @"kern.iossupportversion", @"kern.osversion" ]) {
            char buffer[64] = {0};
            size_t length = sizeof(buffer);
            int rc = sysctlbyname(key.UTF8String, buffer, &length, NULL, 0);
            [lines addObject:[NSString stringWithFormat:@"%@ rc=%d '%s'", key, rc, buffer]];
        }
        [lines addObject:[NSString stringWithFormat:@"SIMULATOR_RUNTIME_VERSION=%s", getenv("SIMULATOR_RUNTIME_VERSION") ?: "(null)"]];
        SPKDevTourFinish([lines componentsJoinedByString:@"\n"]);
    } else if ([command isEqualToString:@"mc"]) {
        FOUNDATION_EXPORT NSString *SPKDevMobileConfigProbeDump(void);
        SPKDevTourFinish(SPKDevMobileConfigProbeDump());
    } else if ([command hasPrefix:@"mcset "]) {
        // mcset <hex id> <value|clear>
        FOUNDATION_EXPORT NSString *SPKDevMobileConfigProbeSet(NSString *, NSNumber *);
        NSArray<NSString *> *parts = [[command substringFromIndex:6] componentsSeparatedByString:@" "];
        if (parts.count != 2) {
            SPKDevTourFinish(@"error usage: mcset <hex id> <value|clear>");
            return;
        }
        SPKDevTourFinish(SPKDevMobileConfigProbeSet(parts[0], [parts[1] isEqualToString:@"clear"] ? nil : @(parts[1].longLongValue)));
    } else if ([command isEqualToString:@"tabs"]) {
        SPKDevTourFinish(SPKDevTourTabs());
    } else if ([command hasPrefix:@"tabsel "]) {
        // Selects the native tab at an index the way a finger on it does.
        UITabBarController *system = SPKDevTourNativeTabBarController();
        NSUInteger index = (NSUInteger)[[command substringFromIndex:7] integerValue];
        NSArray<UITabBarItem *> *items = system.tabBar.items;
        SEL click = NSSelectorFromString(@"_tabBarItemClicked:");
        if (index >= items.count || ![system respondsToSelector:click]) {
            SPKDevTourFinish(@"error no such native tab");
            return;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(system, click, items[index]);
        SPKDevTourFinish([NSString stringWithFormat:@"ok %@", items[index].title]);
    } else if ([command isEqualToString:@"tabtap"]) {
        // Re-taps the selected tab of the native tab bar the way UIKit's own
        // item click does, which is what a finger on the selected tab sends.
        UITabBarController *native = nil;
        NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
        if (SPKDevTourWindow().rootViewController)
            [queue addObject:SPKDevTourWindow().rootViewController];
        for (NSUInteger i = 0; i < queue.count && i < 400 && !native; i++) {
            if ([queue[i] isKindOfClass:UITabBarController.class])
                native = (UITabBarController *)queue[i];
            [queue addObjectsFromArray:queue[i].childViewControllers];
        }
        SEL click = NSSelectorFromString(@"_tabBarItemClicked:");
        UITabBarItem *item = native.tabBar.selectedItem;
        if (!item || ![native respondsToSelector:click]) {
            SPKDevTourFinish(@"error no native tab bar");
            return;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(native, click, item);
        SPKDevTourFinish([NSString stringWithFormat:@"ok %@", item.title]);
    } else if ([command hasPrefix:@"tabhold "]) {
        // tabhold <explore|FEED|CLIPS|DIRECT|SEARCH|PROFILE>: drives the native
        // tab bar's hold the way its coordinator does: asks whether the tab can
        // be held, then sends the began and ended phases.
        IGTabBarController *tabs = SPKDevTourTabBarController();
        NSString *wanted = [command substringFromIndex:8].uppercaseString;
        if ([wanted isEqualToString:@"EXPLORE"])
            wanted = @"SEARCH";
        id surface = nil;
        for (id candidate in (NSArray *)[SPKUtils getIvarForObj:tabs name:"_tabBarSurfaces"]) {
            if ([[candidate tabStringFromSurfaceIntent] isEqualToString:wanted])
                surface = candidate;
        }
        SEL identifierSelector = NSSelectorFromString(@"_nativeIdentifierForSurface:");
        id identifier = surface && [tabs respondsToSelector:identifierSelector]
                            ? ((id (*)(id, SEL, id))objc_msgSend)(tabs, identifierSelector, surface)
                            : nil;
        if (!identifier) {
            SPKDevTourFinish(@"error no such native tab");
            return;
        }
        NSString *action = [tabs _nativeLongPressAccessibilityActionNameForSurface:surface];
        BOOL canHold = [tabs nativeTabBarControllerCoordinator:nil canLongPressIdentifier:identifier];
        if (canHold) {
            [tabs nativeTabBarControllerCoordinator:nil didUpdateLongPressIdentifier:identifier phase:0];
            [tabs nativeTabBarControllerCoordinator:nil didUpdateLongPressIdentifier:identifier phase:2];
        }
        SPKDevTourFinish([NSString stringWithFormat:@"ok identifier=%@ canHold=%d action=%@", identifier, canHold, action]);
    } else if ([command isEqualToString:@"back"]) {
        // Pops the selected tab's navigation stack, as its back button would.
        // The deepest navigation controller with something to pop: Direct
        // pushes threads onto a navigation controller nested inside the tab's.
        UINavigationController *navigation = nil;
        NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
        if (SPKDevTourTabBarController().selectedViewController)
            [queue addObject:SPKDevTourTabBarController().selectedViewController];
        for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
            UIViewController *candidate = queue[i];
            if ([candidate isKindOfClass:UINavigationController.class] && ((UINavigationController *)candidate).viewControllers.count > 1)
                navigation = (UINavigationController *)candidate;
            [queue addObjectsFromArray:candidate.childViewControllers];
        }
        UIViewController *popped = [navigation popViewControllerAnimated:YES];
        SPKDevTourFinish(popped ? [NSString stringWithFormat:@"ok popped %@", NSStringFromClass(popped.class)] : @"error nothing to pop");
    } else if ([command hasPrefix:@"find "]) {
        SPKDevTourFinish(SPKDevTourFind([command substringFromIndex:5]));
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
