#import <UIKit/UIKit.h>
#import "SPKStrings.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// Sparkle's injection point for IG's native Direct menus: the composer's plus/
// overflow menu and the per-message long-press menu. Each row's domain logic
// lives in a coordinator or resolver; this file only decides which rows exist
// and splices them into IG's element arrays.

#import "../../AssetUtils.h"
#import "../../Shared/Audio/SPKAudioDMUploadCoordinator.h"
#import "../../Shared/Audio/SPKAudioDownloadCoordinator.h"
#import "../../Shared/Audio/SPKAudioItem.h"
#import "../../Shared/Gallery/SPKGallerySaveMetadata.h"
#import "../../Shared/MediaUpload/SPKMediaDMUploadCoordinator.h"
#import "../../Shared/Messages/SPKDirectAudioResolver.h"
#import "../../Shared/Messages/SPKDirectMenuElement.h"
#import "../../Shared/Messages/SPKDirectReflection.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "DMGifTitle.h"

static __unsafe_unretained id sSPKDMComposerForOverflowMenu = nil;
// Tracked per row: IGDSMenu renders through a prism menu it builds itself, so the
// same composer menu passes through both injection points and each row must be
// claimed by exactly one of them.
static BOOL sSPKDMComposerAudioInjected = NO;
static BOOL sSPKDMComposerMediaInjected = NO;
static BOOL sSPKDMAudioRowPending = NO;
static id sSPKDMAudioRowViewModel = nil;

static id (*orig_SPKDMPrismMenuViewInit3)(id, SEL, NSArray *, id, BOOL);
static id (*orig_SPKDMPrismMenuViewInit5)(id, SEL, NSArray *, id, BOOL, BOOL, BOOL);
static id (*orig_SPKDMPrismMenuInit3)(id, SEL, NSArray *, id, BOOL);
static id (*orig_SPKDMPrismMenuInit6)(id, SEL, NSArray *, id, BOOL, BOOL, BOOL, BOOL);


static id SPKDMComposerSenderTarget(id composer) {
    if ([composer respondsToSelector:@selector(buttonDelegate)]) {
        return ((id (*)(id, SEL))objc_msgSend)(composer, @selector(buttonDelegate));
    }
    // IG 435+: the overflow controller holds a delegate that may be a wrapper
    // around the composer rather than the composer itself.
    id innerComposer = SPKDirectValueForSelectorNamed(composer, @"composer");
    if ([innerComposer respondsToSelector:@selector(buttonDelegate)]) {
        return ((id (*)(id, SEL))objc_msgSend)(innerComposer, @selector(buttonDelegate));
    }
    return nil;
}

// The overflow controller's link back to the composer: `_composer` up to IG 434,
// `_delegate` from IG 435 (which is the composer, conforming to the new
// IGDirectComposerOverflowControllerDelegate protocol).
static id SPKDMComposerFromOverflowController(id overflowController) {
    return SPKDirectIvarValue(overflowController, "_composer")
               ?: SPKDirectIvarValue(overflowController, "_delegate");
}

static BOOL SPKDMUploadMenuEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_upload_audio_messages"] ||
           [SPKUtils getBoolPref:@"msgs_upload_gallery_media"];
}

static id SPKDMComposerFromView(id view) {
    if ([view isKindOfClass:%c(IGDirectComposer)])
        return view;
    if ([view isKindOfClass:UIView.class]) {
        for (UIView *candidate = (UIView *)view; candidate; candidate = candidate.superview) {
            if ([candidate isKindOfClass:%c(IGDirectComposer)])
                return candidate;
        }
    }
    return nil;
}

static id SPKDMMenuItem(NSString *title, UIImage *image, void (^handler)(id item)) {
    Class menuItemClass = NSClassFromString(@"IGDSMenuItem");
    SEL titleImageHandler = NSSelectorFromString(@"menuItemWithTitle:image:handler:");
    if (menuItemClass && [menuItemClass respondsToSelector:titleImageHandler]) {
        return ((id (*)(id, SEL, id, id, id))objc_msgSend)(menuItemClass, titleImageHandler, title, image, handler);
    }

    SEL initTitleImageHandler = NSSelectorFromString(@"initWithTitle:image:handler:");
    if (menuItemClass && [menuItemClass instancesRespondToSelector:initTitleImageHandler]) {
        return ((id (*)(id, SEL, id, id, id))objc_msgSend)([menuItemClass alloc], initTitleImageHandler, title, image, handler);
    }

    SEL initTitleImageStyleHandler = NSSelectorFromString(@"initWithTitle:image:style:handler:");
    if (menuItemClass && [menuItemClass instancesRespondToSelector:initTitleImageStyleHandler]) {
        return ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)([menuItemClass alloc], initTitleImageStyleHandler, title, image, 0, handler);
    }

    SEL itemTitleStyleBlock = NSSelectorFromString(@"itemWithTitle:style:block:");
    if (menuItemClass && [menuItemClass respondsToSelector:itemTitleStyleBlock]) {
        return ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(menuItemClass, itemTitleStyleBlock, title, 0, handler);
    }
    return nil;
}

static id SPKDMUploadAudioMenuItemForComposer(id composer) {
    id senderTarget = SPKDMComposerSenderTarget(composer);
    BOOL supports = [SPKAudioDMUploadCoordinator senderTargetSupportsAudioUpload:senderTarget];
    if (!supports) {
        SPKWarnLog(@"AudioUpload", @"Missing direct audio sender on composer delegate: %@", senderTarget);
        return nil;
    }

    __weak id weakComposer = composer;
    return SPKDMMenuItem(SPKL(@"MESSAGES_AUDIO_UPLOAD_AUDIO_TITLE"), [SPKAssetUtils instagramIconNamed:@"audio_upload" pointSize:24.0], ^(__unused id item) {
        id strongComposer = weakComposer;
        if (!strongComposer)
            return;
        UIView *composerView = [strongComposer isKindOfClass:UIView.class] ? (UIView *)strongComposer : nil;
        UIViewController *presenter = (composerView ? [SPKUtils viewControllerForAncestralView:composerView] : nil) ?: topMostController();
        [SPKAudioDMUploadCoordinator presentUploadPickerForSenderTarget:senderTarget
                                                              presenter:presenter
                                                             sourceView:composerView];
    });
}

static id SPKDMUploadMediaMenuItemForComposer(id composer) {
    id senderTarget = SPKDMComposerSenderTarget(composer);
    BOOL supports = [SPKMediaDMUploadCoordinator senderTargetSupportsMediaUpload:senderTarget];
    if (!supports) {
        SPKWarnLog(@"MediaUpload", @"Missing direct media sender on composer delegate: %@", senderTarget);
        return nil;
    }

    __weak id weakComposer = composer;
    return SPKDMMenuItem(SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_UPLOAD_PHOTO_TEXT"), [SPKAssetUtils instagramIconNamed:@"photo" pointSize:24.0], ^(__unused id item) {
        id strongComposer = weakComposer;
        if (!strongComposer)
            return;
        UIView *composerView = [strongComposer isKindOfClass:UIView.class] ? (UIView *)strongComposer : nil;
        UIViewController *presenter = (composerView ? [SPKUtils viewControllerForAncestralView:composerView] : nil) ?: topMostController();
        [SPKMediaDMUploadCoordinator presentGalleryUploadPickerForSenderTarget:senderTarget
                                                                     presenter:presenter
                                                                    sourceView:composerView];
    });
}

// Builds the Sparkle items appended to the composer overflow (+) menu, in order.
//
// IGDSMenu carries plain items with no submenu case, but it renders through a
// prism menu it builds from them, so the audio row is left to that later stage
// whenever it can be a submenu there.
static NSArray *SPKDMComposerExtraMenuItems(id composer) {
    NSMutableArray *items = [NSMutableArray array];
    BOOL audioPref = [SPKUtils getBoolPref:@"msgs_upload_audio_messages"];
    BOOL mediaPref = [SPKUtils getBoolPref:@"msgs_upload_gallery_media"];
    if (audioPref && !sSPKDMComposerAudioInjected && !SPKDirectPrismSubmenuAvailable()) {
        id audioItem = SPKDMUploadAudioMenuItemForComposer(composer);
        if (audioItem) {
            [items addObject:audioItem];
            sSPKDMComposerAudioInjected = YES;
        }
    }
    if (mediaPref && !sSPKDMComposerMediaInjected) {
        id mediaItem = SPKDMUploadMediaMenuItemForComposer(composer);
        if (mediaItem) {
            [items addObject:mediaItem];
            sSPKDMComposerMediaInjected = YES;
        }
    }
    return items;
}

// The audio rows, in the order they appear in both the submenu and the fallback
// action sheet. Resolution is deferred to tap time so building the menu stays cheap.
static void SPKDMRunAudioAction(id viewModel, SPKAudioAction action, NSString *notificationIdentifier);

static NSArray<SPKDirectMenuAction *> *SPKDMAudioActionsForViewModel(id viewModel) {
    __strong id capturedViewModel = viewModel;
    NSArray<NSArray *> *specs = @[
        @[ SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES"), @"audio_download", @(SPKAudioActionSaveToFiles), kSPKNotificationDownloadAudio ],
        @[ SPKL(@"ALERT_ACTION_SHARE_AUDIO"), @"share", @(SPKAudioActionConvertAndShare), kSPKNotificationDownloadAudioShare ],
        @[ SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY"), @"sparkle_gallery", @(SPKAudioActionConvertAndSaveToGallery), kSPKNotificationDownloadAudioGallery ],
        @[ SPKL(@"ALERT_ACTION_PLAY_AUDIO"), @"play", @(SPKAudioActionPlay), kSPKNotificationPlayAudio ],
        @[ SPKL(@"ALERT_ACTION_COPY_AUDIO_DOWNLOAD_URL"), @"link", @(SPKAudioActionCopyURL), kSPKNotificationCopyAudioURL ],
    ];

    NSMutableArray<SPKDirectMenuAction *> *actions = [NSMutableArray arrayWithCapacity:specs.count];
    for (NSArray *spec in specs) {
        NSString *title = spec[0];
        SPKAudioAction action = (SPKAudioAction)[spec[2] integerValue];
        NSString *notificationIdentifier = spec[3];
        SPKDirectMenuAction *menuAction =
            [SPKDirectMenuAction actionWithTitle:title
                                           image:[SPKAssetUtils instagramIconNamed:spec[1] pointSize:24.0]
                                         handler:^{
                                             SPKDMRunAudioAction(capturedViewModel, action, notificationIdentifier);
                                         }];
        if (menuAction)
            [actions addObject:menuAction];
    }
    return [actions copy];
}

static void SPKDMRunAudioAction(id viewModel, SPKAudioAction action, NSString *notificationIdentifier) {
    UIViewController *presenter = topMostController();
    UIView *sourceView = presenter.view;
    SPKAudioItem *audioItem = [SPKAudioDownloadCoordinator audioItemFromMediaObject:viewModel source:SPKAudioSourceDMs];
    if (!audioItem) {
        SPKNotify(kSPKNotificationDownloadShare,
                  SPKL(@"GENERAL_AUDIO_PAGE_DOWNLOAD_COULD_NOT_FIND_AUDIO_URL_TEXT"),
                  SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_REFRESH_THREAD_TRY_AGAIN_IF_URL_EXPIRED_TEXT"),
                  @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    SPKGallerySaveMetadata *metadata = [[SPKGallerySaveMetadata alloc] init];
    NSString *username = SPKDirectAudioResolvedUsername(viewModel);
    metadata.source = (int16_t)[audioItem gallerySource];
    metadata.sourceUsername = username.length > 0 ? username : (audioItem.artist.length > 0 ? audioItem.artist : @"direct");
    metadata.sourceMediaPK = audioItem.mediaIdentifier;
    metadata.sourceMediaURLString = audioItem.sourceURLString ?: audioItem.url.absoluteString;

    [SPKAudioDownloadCoordinator performAction:action
                                          item:audioItem
                                     presenter:presenter
                                    sourceView:sourceView
                                      metadata:metadata
                        notificationIdentifier:notificationIdentifier];
}

// Fallback for builds where the menu cannot carry a submenu.
static void SPKDMPresentDownloadAudioActionsForViewModel(id viewModel) {
    UIViewController *presenter = topMostController();
    if (![SPKAudioDownloadCoordinator bestAudioURLFromMediaObject:viewModel]) {
        SPKNotify(kSPKNotificationDownloadShare,
                  SPKL(@"GENERAL_AUDIO_PAGE_DOWNLOAD_COULD_NOT_FIND_AUDIO_URL_TEXT"),
                  SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_REFRESH_THREAD_TRY_AGAIN_IF_URL_EXPIRED_TEXT"),
                  @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    NSMutableArray<SPKIGAlertAction *> *alertActions = [NSMutableArray array];
    for (SPKDirectMenuAction *action in SPKDMAudioActionsForViewModel(viewModel)) {
        void (^handler)(void) = action.handler;
        [alertActions addObject:[SPKIGAlertAction actionWithTitle:action.title
                                                            style:SPKIGAlertActionStyleDefault
                                                          handler:handler]];
    }
    [alertActions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                        style:SPKIGAlertActionStyleCancel
                                                      handler:nil]];

    [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                        title:SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_TITLE")
                                                      message:nil
                                                      actions:[alertActions copy]];
}

static id SPKDMDownloadAudioMenuItemForViewModel(id viewModel) {
    if (![SPKUtils getBoolPref:@"downloads_audio_enabled"])
        return nil;
    if (![SPKUtils getBoolPref:@"msgs_download_audio_messages"])
        return nil;
    if (![SPKAudioDownloadCoordinator bestAudioURLFromMediaObject:viewModel])
        return nil;

    __strong id capturedViewModel = viewModel;
    return SPKDMMenuItem(SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_ACTIONS_ACTION"), [SPKAssetUtils instagramIconNamed:@"action" pointSize:24.0], ^(__unused id item) {
        SPKDMPresentDownloadAudioActionsForViewModel(capturedViewModel);
    });
}

static id SPKDMPrismAudioDownloadElement(id templateElement, id viewModel) {
    Class builderClass = NSClassFromString(@"IGDSPrismMenuItemBuilder");
    if (!builderClass || !templateElement || !viewModel)
        return nil;

    // Preferred shape: the actions expand in place, the way IG's own "More" row
    // does, instead of covering the thread with an action sheet.
    id submenu = SPKDirectPrismSubmenuElement(templateElement,
                                              SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_ACTIONS_ACTION"),
                                              [SPKAssetUtils instagramIconNamed:@"action" pointSize:24.0],
                                              SPKDMAudioActionsForViewModel(viewModel));
    if (submenu)
        return submenu;

    SEL initSelector = @selector(initWithTitle:);
    SEL imageSelector = @selector(withImage:);
    SEL handlerSelector = @selector(withHandler:);
    SEL buildSelector = @selector(build);
    if (![builderClass instancesRespondToSelector:initSelector] ||
        ![builderClass instancesRespondToSelector:imageSelector] ||
        ![builderClass instancesRespondToSelector:handlerSelector] ||
        ![builderClass instancesRespondToSelector:buildSelector]) {
        return nil;
    }

    __strong id capturedViewModel = viewModel;
    void (^handler)(void) = ^{
        SPKDMPresentDownloadAudioActionsForViewModel(capturedViewModel);
    };

    id builder = ((id (*)(id, SEL, id))objc_msgSend)([builderClass alloc], initSelector, SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_ACTIONS_ACTION"));
    builder = ((id (*)(id, SEL, id))objc_msgSend)(builder, imageSelector, [SPKAssetUtils instagramIconNamed:@"action" pointSize:24.0]);
    builder = ((id (*)(id, SEL, id))objc_msgSend)(builder, handlerSelector, handler);
    id menuItem = ((id (*)(id, SEL))objc_msgSend)(builder, buildSelector);
    if (!menuItem)
        return nil;

    id element = [[templateElement class] new];
    Ivar subtypeIvar = class_getInstanceVariable([templateElement class], "_subtype");
    Ivar itemIvar = class_getInstanceVariable([templateElement class], "_item_menuItem");
    if (!element || !subtypeIvar || !itemIvar)
        return nil;

    ptrdiff_t subtypeOffset = ivar_getOffset(subtypeIvar);
    *(uint64_t *)((uint8_t *)(__bridge void *)element + subtypeOffset) =
        *(uint64_t *)((uint8_t *)(__bridge void *)templateElement + subtypeOffset);
    object_setIvar(element, itemIvar, menuItem);
    return element;
}

// The three audio sources as submenu rows, each opening its picker directly.
static NSArray<SPKDirectMenuAction *> *SPKDMAudioUploadSourceActionsForComposer(id composer, id senderTarget) {
    NSArray<NSArray *> *specs = @[
        @[ SPKL(@"ALERT_ACTION_SELECT_PHOTOS"), @"photo", @(SPKAudioDMUploadSourcePhotos) ],
        @[ SPKL(@"ALERT_ACTION_SELECT_GALLERY"), @"sparkle_gallery", @(SPKAudioDMUploadSourceGallery) ],
        @[ SPKL(@"ALERT_ACTION_SELECT_FILES"), @"folder", @(SPKAudioDMUploadSourceFiles) ],
    ];

    __weak id weakComposer = composer;
    NSMutableArray<SPKDirectMenuAction *> *actions = [NSMutableArray arrayWithCapacity:specs.count];
    for (NSArray *spec in specs) {
        SPKAudioDMUploadSource source = (SPKAudioDMUploadSource)[spec[2] integerValue];
        SPKDirectMenuAction *action =
            [SPKDirectMenuAction actionWithTitle:spec[0]
                                           image:[SPKAssetUtils instagramIconNamed:spec[1] pointSize:24.0]
                                         handler:^{
                                             id strongComposer = weakComposer;
                                             if (!strongComposer)
                                                 return;
                                             UIView *composerView = [strongComposer isKindOfClass:UIView.class] ? (UIView *)strongComposer : nil;
                                             UIViewController *presenter = (composerView ? [SPKUtils viewControllerForAncestralView:composerView] : nil) ?: topMostController();
                                             [SPKAudioDMUploadCoordinator presentUploadPickerForSource:source
                                                                                          senderTarget:senderTarget
                                                                                             presenter:presenter
                                                                                            sourceView:composerView];
                                         }];
        if (action)
            [actions addObject:action];
    }
    return [actions copy];
}

static NSArray *SPKDMPrismUploadElementsForComposer(id composer, id templateElement) {
    if (!composer || !templateElement)
        return @[];

    id senderTarget = SPKDMComposerSenderTarget(composer);
    NSMutableArray *elements = [NSMutableArray array];

    if (!sSPKDMComposerAudioInjected &&
        [SPKUtils getBoolPref:@"msgs_upload_audio_messages"] &&
        [SPKAudioDMUploadCoordinator senderTargetSupportsAudioUpload:senderTarget]) {
        __weak id weakComposer = composer;
        // The source picker is a submenu where the menu supports one, so choosing
        // a source no longer costs an extra action sheet.
        id audioElement = SPKDirectPrismSubmenuElement(templateElement,
                                                       SPKL(@"MESSAGES_AUDIO_UPLOAD_AUDIO_TITLE"),
                                                       [SPKAssetUtils instagramIconNamed:@"audio_upload" pointSize:24.0],
                                                       SPKDMAudioUploadSourceActionsForComposer(composer, senderTarget));
        if (!audioElement) {
            audioElement = SPKDirectPrismMenuElement(templateElement,
                                                SPKL(@"MESSAGES_AUDIO_UPLOAD_AUDIO_TITLE"),
                                                [SPKAssetUtils instagramIconNamed:@"audio_upload"
                                                                        pointSize:24.0],
                                                ^{
                                                    id strongComposer = weakComposer;
                                                    if (!strongComposer)
                                                        return;
                                                    UIView *composerView = [strongComposer isKindOfClass:UIView.class] ? (UIView *)strongComposer : nil;
                                                    UIViewController *presenter = (composerView ? [SPKUtils viewControllerForAncestralView:composerView] : nil) ?: topMostController();
                                                    [SPKAudioDMUploadCoordinator presentUploadPickerForSenderTarget:senderTarget
                                                                                                          presenter:presenter
                                                                                                         sourceView:composerView];
                                                });
        }
        if (audioElement) {
            [elements addObject:audioElement];
            sSPKDMComposerAudioInjected = YES;
        }
    }

    if (!sSPKDMComposerMediaInjected &&
        [SPKUtils getBoolPref:@"msgs_upload_gallery_media"] &&
        [SPKMediaDMUploadCoordinator senderTargetSupportsMediaUpload:senderTarget]) {
        __weak id weakComposer = composer;
        id mediaElement = SPKDirectPrismMenuElement(templateElement,
                                                SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_UPLOAD_PHOTO_TEXT"),
                                                [SPKAssetUtils instagramIconNamed:@"photo"
                                                                        pointSize:24.0],
                                                ^{
                                                    id strongComposer = weakComposer;
                                                    if (!strongComposer)
                                                        return;
                                                    UIView *composerView = [strongComposer isKindOfClass:UIView.class] ? (UIView *)strongComposer : nil;
                                                    UIViewController *presenter = (composerView ? [SPKUtils viewControllerForAncestralView:composerView] : nil) ?: topMostController();
                                                    [SPKMediaDMUploadCoordinator presentGalleryUploadPickerForSenderTarget:senderTarget
                                                                                                                 presenter:presenter
                                                                                                                sourceView:composerView];
                                                });
        if (mediaElement) {
            [elements addObject:mediaElement];
            sSPKDMComposerMediaInjected = YES;
        }
    }

    return elements;
}

static NSArray *SPKDMPrismMenuElementsWithAudioDownload(NSArray *elements) {
    if (!sSPKDMAudioRowPending)
        return elements;
    sSPKDMAudioRowPending = NO;

    id viewModel = sSPKDMAudioRowViewModel;
    sSPKDMAudioRowViewModel = nil;
    if (![SPKUtils getBoolPref:@"msgs_download_audio_messages"] || ![elements isKindOfClass:NSArray.class] || elements.count == 0) {
        return elements;
    }

    id newElement = SPKDMPrismAudioDownloadElement(elements.firstObject, viewModel);
    if (!newElement)
        return elements;

    // A submenu row goes last, where IG puts its own: the overflow panel is
    // anchored to the parent row and expands from the bottom of the menu, so a
    // submenu placed first lands on top of the menu it belongs to.
    NSMutableArray *updated = [NSMutableArray arrayWithArray:elements];
    if (SPKDirectMenuContainsSparkleSubmenu(@[ newElement ])) {
        [updated addObject:newElement];
    } else {
        [updated insertObject:newElement atIndex:0];
    }
    return [updated copy];
}

static NSArray *SPKDMPrismMenuElementsWithGifTitle(NSArray *elements) {
    if (![elements isKindOfClass:NSArray.class] || elements.count == 0)
        return elements;

    NSArray *titleElements = SPKDMGifTitleElementsForMenu(elements);
    if (titleElements.count == 0)
        return elements;

    NSMutableArray *updated = [NSMutableArray arrayWithArray:titleElements];
    [updated addObjectsFromArray:elements];
    return [updated copy];
}

static NSArray *SPKDMPrismMenuElementsWithInjections(NSArray *elements) {
    NSArray *updated = SPKDMPrismMenuElementsWithGifTitle(elements);
    updated = SPKDMPrismMenuElementsWithAudioDownload(updated);
    if (!SPKDMUploadMenuEnabled() || !sSPKDMComposerForOverflowMenu ||
        ![updated isKindOfClass:NSArray.class] || updated.count == 0) {
        return updated;
    }

    NSArray *uploadElements = SPKDMPrismUploadElementsForComposer(sSPKDMComposerForOverflowMenu, updated.firstObject);
    if (uploadElements.count == 0)
        return updated;

    NSMutableArray *merged = [NSMutableArray arrayWithArray:updated];
    [merged addObjectsFromArray:uploadElements];
    return [merged copy];
}

// IG's overflow panel inherits the parent menu's width, which clips Sparkle rows
// that are longer than IG's own. The view can size a submenu to its contents.
static void SPKDMAllowSubmenuDynamicWidth(id view, NSArray *elements) {
    SEL selector = @selector(setShouldAllowSubmenuDynamicWidth:);
    if (!SPKDirectMenuContainsSparkleSubmenu(elements) || ![view respondsToSelector:selector])
        return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(view, selector, YES);
}

static id SPKDMPrismMenuViewInit3(id self, SEL _cmd, NSArray *elements, id headerText, BOOL edrEnabled) {
    NSArray *injected = SPKDMPrismMenuElementsWithInjections(elements);
    id view = orig_SPKDMPrismMenuViewInit3(self, _cmd, injected, headerText, edrEnabled);
    SPKDMAllowSubmenuDynamicWidth(view, injected);
    SPKDMGifTitleRegisterMenuView(view);
    return view;
}

static id SPKDMPrismMenuViewInit5(id self, SEL _cmd, NSArray *elements, id headerText, BOOL edrEnabled, BOOL allowScrollingItems, BOOL allowMixedTextAlignment) {
    NSArray *injected = SPKDMPrismMenuElementsWithInjections(elements);
    id view = orig_SPKDMPrismMenuViewInit5(self, _cmd, injected, headerText, edrEnabled, allowScrollingItems, allowMixedTextAlignment);
    SPKDMAllowSubmenuDynamicWidth(view, injected);
    SPKDMGifTitleRegisterMenuView(view);
    return view;
}

static id SPKDMPrismMenuInit3(id self, SEL _cmd, NSArray *elements, id headerText, BOOL edrEnabled) {
    id menu = orig_SPKDMPrismMenuInit3(self, _cmd, SPKDMPrismMenuElementsWithInjections(elements), headerText, edrEnabled);
    SPKDMGifTitleRegisterMenuView(menu);
    return menu;
}

// The init IGDSMenu uses for the prism menu behind a composer menu.
static id SPKDMPrismMenuInit6(id self,
                              SEL _cmd,
                              NSArray *elements,
                              id headerText,
                              BOOL edrEnabled,
                              BOOL allowScrollingItems,
                              BOOL allowMixedTextAlignment,
                              BOOL enableScrollToDismiss) {
    id menu = orig_SPKDMPrismMenuInit6(self,
                                       _cmd,
                                       SPKDMPrismMenuElementsWithInjections(elements),
                                       headerText,
                                       edrEnabled,
                                       allowScrollingItems,
                                       allowMixedTextAlignment,
                                       enableScrollToDismiss);
    SPKDMGifTitleRegisterMenuView(menu);
    return menu;
}

static void SPKDMSetUploadComposerContext(id composer) {
    sSPKDMComposerForOverflowMenu = composer;
    sSPKDMComposerAudioInjected = NO;
    sSPKDMComposerMediaInjected = NO;
}

static void SPKDMClearUploadComposerContext(void) {
    sSPKDMComposerForOverflowMenu = nil;
    sSPKDMComposerAudioInjected = NO;
    sSPKDMComposerMediaInjected = NO;
}

// Records the message a long-press menu is being built for, so the prism menu
// init that follows can add the rows that depend on it.
static void SPKDMNoteMessageMenuViewModel(id viewModel) {
    SPKDMGifTitleNoteMenuViewModel(viewModel);
    if ([SPKUtils getBoolPref:@"downloads_audio_enabled"] &&
        [SPKUtils getBoolPref:@"msgs_download_audio_messages"] &&
        [SPKAudioDownloadCoordinator bestAudioURLFromMediaObject:viewModel]) {
        sSPKDMAudioRowPending = YES;
        sSPKDMAudioRowViewModel = viewModel;
    }
}

%group SPKDirectMessageMenuHooks

%hook IGDirectComposerOverflowController

- (id)_setupMenuItemGroup {
    id composer = SPKDMComposerFromOverflowController(self);
    if (!SPKDMUploadMenuEnabled() || !composer) {
        return %orig;
    }

    SPKDMSetUploadComposerContext(composer);
    id result = %orig;
    SPKDMClearUploadComposerContext();
    return result;
}

%end

%hook IGDirectComposer

- (void)menuDidDismiss {
    SPKDMClearUploadComposerContext();
    %orig;
}

- (void)_didTapRedesignOverflowButton:(id)button {
    if (!SPKDMUploadMenuEnabled()) {
        %orig;
        return;
    }
    SPKDMSetUploadComposerContext(self);
    %orig;
}

%end

%hook IGDirectThreadViewController

- (void)inputView:(id)view didTapMoreButton:(id)button {
    id composer = SPKDMComposerFromView(view);
    if (!SPKDMUploadMenuEnabled() || !composer) {
        %orig;
        return;
    }
    SPKDMSetUploadComposerContext(composer);
    %orig;
}

- (void)inputView:(id)view didTapPlusButton:(id)button isExpanded:(_Bool)expanded layoutSpec:(id)layoutSpec {
    id composer = SPKDMComposerFromView(view);
    if (!SPKDMUploadMenuEnabled() || !composer) {
        if (!expanded)
            SPKDMClearUploadComposerContext();
        %orig;
        return;
    }
    if (expanded) {
        SPKDMSetUploadComposerContext(composer);
        %orig;
        return;
    }
    %orig;
    SPKDMClearUploadComposerContext();
}

- (void)composerOverflowButtonMenuWillPrepareExpandWithPlusButton:(id)button {
    id composer = SPKDMComposerFromView(button);
    if (!composer && [button isKindOfClass:UIView.class]) {
        for (UIView *candidate = (UIView *)button; candidate; candidate = candidate.superview) {
            composer = SPKDMComposerFromView(candidate);
            if (composer)
                break;
        }
    }
    if (SPKDMUploadMenuEnabled() && composer) {
        SPKDMSetUploadComposerContext(composer);
    }
    %orig;
}

%end

static id SPKDMProcessMenuItems(id menuItems) {
    if (sSPKDMComposerForOverflowMenu && [menuItems isKindOfClass:NSArray.class]) {
        NSArray *extraItems = SPKDMComposerExtraMenuItems(sSPKDMComposerForOverflowMenu);
        if (extraItems.count > 0) {
            NSMutableArray *mutableItems = [(NSArray *)menuItems mutableCopy];
            [mutableItems addObjectsFromArray:extraItems];
            return [mutableItems copy];
        }
    }
    return menuItems;
}

%hook IGDSMenu

- (id)initWithMenuItems:(id)menuItems {
    return %orig(SPKDMProcessMenuItems(menuItems));
}

- (id)initWithMenuItems:(id)menuItems edr:(_Bool)edr {
    return %orig(SPKDMProcessMenuItems(menuItems), edr);
}

- (id)initWithMenuItems:(id)menuItems edr:(_Bool)edr headerLabelText:(id)headerLabelText {
    return %orig(SPKDMProcessMenuItems(menuItems), edr, headerLabelText);
}

- (id)initWithMenuItems:(id)menuItems edr:(_Bool)edr headerLabelText:(id)headerLabelText enableScrollToDismiss:(_Bool)enableScrollToDismiss {
    return %orig(SPKDMProcessMenuItems(menuItems), edr, headerLabelText, enableScrollToDismiss);
}

- (id)initWithMenuItemsWithoutUIWindow:(id)menuItems edr:(_Bool)edr headerLabelText:(id)headerLabelText {
    return %orig(SPKDMProcessMenuItems(menuItems), edr, headerLabelText);
}

%end

%hook _TtC32IGDirectMessageMenuConfiguration32IGDirectMessageMenuConfiguration

+ (id)menuConfigurationWithEligibleOptions:(id)options
                          messageViewModel:(id)viewModel
                               contentType:(id)contentType
                                 isSticker:(_Bool)isSticker
                            isMusicSticker:(_Bool)isMusicSticker
                          directNuxManager:(id)directNuxManager
                       sessionUserDefaults:(id)sessionUserDefaults
                               launcherSet:(id)launcherSet
                               userSession:(id)userSession
                                tapHandler:(id)tapHandler {
    id config = %orig(options, viewModel, contentType, isSticker, isMusicSticker, directNuxManager, sessionUserDefaults, launcherSet, userSession, tapHandler);
    SPKDMNoteMessageMenuViewModel(viewModel);
    return config;
}

// IG 448 renamed the launcherSet: argument to mobileConfig: with the same shape.
+ (id)menuConfigurationWithEligibleOptions:(id)options
                          messageViewModel:(id)viewModel
                               contentType:(id)contentType
                                 isSticker:(_Bool)isSticker
                            isMusicSticker:(_Bool)isMusicSticker
                          directNuxManager:(id)directNuxManager
                       sessionUserDefaults:(id)sessionUserDefaults
                              mobileConfig:(id)mobileConfig
                               userSession:(id)userSession
                                tapHandler:(id)tapHandler {
    id config = %orig(options, viewModel, contentType, isSticker, isMusicSticker, directNuxManager, sessionUserDefaults, mobileConfig, userSession, tapHandler);
    SPKDMNoteMessageMenuViewModel(viewModel);
    return config;
}

%end

%end

extern "C" void SPKInstallDirectMessageMenuHooksIfNeeded(void) {
    // Audio download/upload features sit behind the audio-downloads master switch;
    // gallery photo upload is independent of it.
    BOOL audioFeatureEnabled = [SPKUtils getBoolPref:@"downloads_audio_enabled"] &&
                               ([SPKUtils getBoolPref:@"msgs_download_audio_messages"] ||
                                [SPKUtils getBoolPref:@"msgs_download_notes_audio"] ||
                                [SPKUtils getBoolPref:@"msgs_upload_audio_messages"]);
    BOOL mediaUploadEnabled = [SPKUtils getBoolPref:@"msgs_upload_gallery_media"];
    if (!audioFeatureEnabled && !mediaUploadEnabled && !SPKDMGifTitleEnabled())
        return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDirectMessageMenuHooks);
        Class prismMenuViewClass = objc_getClass("IGDSPrismMenu.IGDSPrismMenuView");
        SEL init3 = @selector(initWithMenuElements:headerText:edrEnabled:);
        if (prismMenuViewClass && [prismMenuViewClass instancesRespondToSelector:init3]) {
            MSHookMessageEx(prismMenuViewClass,
                            init3,
                            (IMP)SPKDMPrismMenuViewInit3,
                            (IMP *)&orig_SPKDMPrismMenuViewInit3);
        }
        SEL init5 = @selector(initWithMenuElements:headerText:edrEnabled:allowScrollingItems:allowMixedTextAlignment:);
        if (prismMenuViewClass && [prismMenuViewClass instancesRespondToSelector:init5]) {
            MSHookMessageEx(prismMenuViewClass,
                            init5,
                            (IMP)SPKDMPrismMenuViewInit5,
                            (IMP *)&orig_SPKDMPrismMenuViewInit5);
        }
        Class prismMenuClass = objc_getClass("IGDSPrismMenu.IGDSPrismMenu");
        if (prismMenuClass && [prismMenuClass instancesRespondToSelector:init3]) {
            MSHookMessageEx(prismMenuClass,
                            init3,
                            (IMP)SPKDMPrismMenuInit3,
                            (IMP *)&orig_SPKDMPrismMenuInit3);
        }
        SEL init6 = @selector(initWithMenuElements:headerText:edrEnabled:allowScrollingItems:allowMixedTextAlignment:enableScrollToDismiss:);
        if (prismMenuClass && [prismMenuClass instancesRespondToSelector:init6]) {
            MSHookMessageEx(prismMenuClass,
                            init6,
                            (IMP)SPKDMPrismMenuInit6,
                            (IMP *)&orig_SPKDMPrismMenuInit6);
        }
    });
}
