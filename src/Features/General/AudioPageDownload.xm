#import "SPKStrings.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/Audio/SPKAudioDownloadCoordinator.h"
#import "../../Shared/Audio/SPKAudioItem.h"
#import "../../Shared/Gallery/SPKGallerySaveMetadata.h"
#import "../../Shared/MediaDownload/SPKDashParser.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static NSInteger const kSPKAudioPageDownloadButtonTag = 1351;
static const void *kSPKAudioPageButtonKey = &kSPKAudioPageButtonKey;
static NSString *const kSPKAudioPageDefaultActionKey = @"downloads_audio_page_default_action";
static NSString *const kSPKAudioPageActionFiles = @"files";
static NSString *const kSPKAudioPageActionShare = @"share";
static NSString *const kSPKAudioPageActionConvertShare = @"convert_share";
static NSString *const kSPKAudioPageActionGallery = @"gallery";
static NSString *const kSPKAudioPageActionConvertGallery = @"convert_gallery";
static NSString *const kSPKAudioPageActionPlay = @"play";
static NSString *const kSPKAudioPageActionCopyURL = @"copy_url";

static id SPKAudioPageReadIvar(id object, const char *name) {
    if (!object || !name)
        return nil;
    for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar)
            return object_getIvar(object, ivar);
    }
    return nil;
}

static NSString *SPKAudioPageString(id value) {
    if ([value isKindOfClass:NSString.class])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)])
        return [value stringValue];
    return nil;
}

static id SPKAudioPageCall(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSURL *SPKAudioPageURL(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = SPKAudioPageCall(object, name);
        if (!value) {
            @try {
                value = [object valueForKey:name];
            } @catch (__unused NSException *exception) {
            }
        }
        if ([value isKindOfClass:NSURL.class])
            return value;
        NSString *string = SPKAudioPageString(value);
        if (string.length > 0) {
            NSURL *url = [NSURL URLWithString:string];
            if (url)
                return url;
        }
    }
    return nil;
}

static NSURL *SPKAudioPageResolveAudioURL(id asset) {
    NSURL *url = SPKAudioPageURL(asset, @[ @"audioFileUrl", @"audioFileURL", @"progressiveDownloadURL", @"playableAudioURL", @"audioURL" ]);
    if (url)
        return url;
    NSData *manifestData = SPKAudioPageReadIvar(asset, "_dashManifestData");
    if ([manifestData isKindOfClass:NSData.class] && manifestData.length > 0) {
        NSString *xml = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
        NSArray<SPKDashRepresentation *> *reps = [SPKDashParser parseManifest:xml ?: @""];
        SPKDashRepresentation *best = nil;
        for (SPKDashRepresentation *rep in reps) {
            if (![rep.contentType.lowercaseString containsString:@"audio"])
                continue;
            if (!best || rep.bandwidth > best.bandwidth)
                best = rep;
        }
        return best.url;
    }
    return nil;
}

static NSString *SPKAudioPageStringForAsset(id asset, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSString *string = SPKAudioPageString(SPKAudioPageCall(asset, name));
        if (string.length > 0)
            return string;
        @try {
            string = SPKAudioPageString([asset valueForKey:name]);
            if (string.length > 0)
                return string;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static UIViewController *SPKAudioPageControllerForView(UIView *view) {
    Class cls = NSClassFromString(@"IGAudioPageViewController");
    if (!cls)
        return nil;
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:cls])
            return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static SPKAudioItem *SPKAudioPageItem(NSURL *url, SPKGallerySaveMetadata *metadata) {
    SPKAudioItem *item = [SPKAudioItem itemWithURL:url source:SPKAudioSourceAudioPage];
    item.artist = metadata.sourceUsername;
    item.title = metadata.customName;
    item.mediaIdentifier = metadata.sourceMediaPK;
    item.sourceURLString = url.absoluteString;
    return item;
}

static void SPKAudioPageRunAction(NSString *action, NSURL *url, UIView *sourceView, SPKGallerySaveMetadata *metadata) {
    if (![SPKUtils getBoolPref:@"downloads_audio_enabled"] && ![action isEqualToString:kSPKAudioPageActionPlay]) {
        SPKNotify(kSPKNotificationDownloadShare, SPKL(@"GENERAL_AUDIO_PAGE_DOWNLOAD_AUDIO_DOWNLOADS_DISABLED_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }
    SPKAudioItem *item = SPKAudioPageItem(url, metadata);
    UIViewController *presenter = SPKAudioPageControllerForView(sourceView) ?: topMostController();
    if ([action isEqualToString:kSPKAudioPageActionFiles]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionSaveToFiles item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationDownloadAudio];
    } else if ([action isEqualToString:kSPKAudioPageActionGallery]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionConvertAndSaveToGallery item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationDownloadAudioGallery];
    } else if ([action isEqualToString:kSPKAudioPageActionConvertGallery]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionConvertAndSaveToGallery item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationDownloadAudioGallery];
    } else if ([action isEqualToString:kSPKAudioPageActionPlay]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionPlay item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationPlayAudio];
    } else if ([action isEqualToString:kSPKAudioPageActionCopyURL]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionCopyURL item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationCopyAudioURL];
    } else if ([action isEqualToString:kSPKAudioPageActionConvertShare]) {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionConvertAndShare item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationDownloadAudioShare];
    } else {
        [SPKAudioDownloadCoordinator performAction:SPKAudioActionConvertAndShare item:item presenter:presenter sourceView:sourceView metadata:metadata notificationIdentifier:kSPKNotificationDownloadAudioShare];
    }
}

static NSString *SPKAudioPageIconForAction(NSString *action) {
    if ([action isEqualToString:kSPKAudioPageActionFiles])
        return @"audio_download";
    if ([action isEqualToString:kSPKAudioPageActionGallery])
        return @"sparkle_gallery";
    if ([action isEqualToString:kSPKAudioPageActionConvertGallery])
        return @"sparkle_gallery";
    if ([action isEqualToString:kSPKAudioPageActionConvertShare])
        return @"share";
    if ([action isEqualToString:kSPKAudioPageActionPlay])
        return @"play";
    if ([action isEqualToString:kSPKAudioPageActionCopyURL])
        return @"link";
    return @"action";
}

static UIImage *SPKAudioPageMenuIcon(NSString *iconName) {
    return [[[SPKAssetUtils menuIconNamed:iconName] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] imageWithTintColor:[UIColor labelColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *SPKAudioPageActionIcon(NSString *identifier, NSString *fallbackIconName) {
    UIImage *actionButtonIcon = SPKActionButtonMenuIconForIdentifier(identifier, 22.0);
    if (actionButtonIcon)
        return actionButtonIcon;
    return SPKAudioPageMenuIcon(fallbackIconName);
}

static NSDictionary *SPKAudioPageResolvedPayload(UIView *sourceView) {
    UIViewController *vc = SPKAudioPageControllerForView(sourceView);
    id asset = SPKAudioPageReadIvar(vc, "_audioAsset") ?: SPKAudioPageReadIvar(vc, "_music") ?
                                                                                             : SPKAudioPageReadIvar(vc, "_originalAudio");
    NSURL *url = SPKAudioPageResolveAudioURL(asset);
    if (!url) {
        SPKNotify(kSPKNotificationDownloadShare, SPKL(@"GENERAL_AUDIO_PAGE_DOWNLOAD_COULD_NOT_FIND_AUDIO_URL_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return nil;
    }

    SPKGallerySaveMetadata *metadata = [[SPKGallerySaveMetadata alloc] init];
    metadata.source = (int16_t)SPKGallerySourceAudioPage;
    // `artist` is the owning account (an IGUser on 410, a user fragment on newer
    // builds); `artistDisplayName` is a display name ("Taylor Swift") for songs,
    // which is not a username and must not become one.
    id artist = SPKAudioPageCall(asset, @"artist");
    NSString *username = [SPKUtils sanitizedInstagramUsername:SPKAudioPageStringForAsset(artist, @[ @"username" ])];
    if (username.length > 0) {
        metadata.sourceUsername = username;
        metadata.sourceUserPK = SPKAudioPageStringForAsset(artist, @[ @"pk" ]);
    } else {
        NSString *rawArtist = SPKAudioPageStringForAsset(asset, @[ @"artistDisplayName", @"username", @"displayArtist" ]);
        metadata.sourceUsername = [SPKUtils sanitizedInstagramUsername:rawArtist];
        // A name that is not a handle still names the file; it is never used as
        // profile attribution.
        if (metadata.sourceUsername.length == 0 && rawArtist.length > 0)
            metadata.importFileNameStem = rawArtist;
    }
    metadata.customName = SPKAudioPageStringForAsset(asset, @[ @"title", @"originalAudioTitle" ]);
    metadata.sourceMediaPK = SPKAudioPageStringForAsset(asset, @[ @"audioAssetId", @"pk", @"id" ]);
    return @{@"url" : url, @"metadata" : metadata};
}

static UIAction *SPKAudioPageMenuAction(NSString *title, NSString *action, NSString *iconIdentifier, NSString *fallbackIconName, UIView *sourceView) {
    return [UIAction actionWithTitle:title
                               image:SPKAudioPageActionIcon(iconIdentifier, fallbackIconName)
                          identifier:nil
                             handler:^(__unused UIAction *menuAction) {
                                 NSDictionary *payload = SPKAudioPageResolvedPayload(sourceView);
                                 NSURL *url = payload[@"url"];
                                 SPKGallerySaveMetadata *metadata = payload[@"metadata"];
                                 if (!url || !metadata)
                                     return;
                                 SPKAudioPageRunAction(action, url, sourceView, metadata);
                             }];
}

static UIMenu *SPKAudioPageMenuForButton(UIButton *button) {
    return [UIMenu menuWithTitle:@""
                           image:nil
                      identifier:nil
                         options:0
                        children:@[
                            SPKAudioPageMenuAction(SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES"), kSPKAudioPageActionFiles, kSPKActionDownloadAudio, @"audio_download", button),
                            SPKAudioPageMenuAction(SPKL(@"ALERT_ACTION_SHARE_AUDIO"), kSPKAudioPageActionShare, kSPKActionDownloadAudioShare, @"share", button),
                            SPKAudioPageMenuAction(SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY"), kSPKAudioPageActionGallery, kSPKActionDownloadAudioGallery, @"sparkle_gallery", button),
                            SPKAudioPageMenuAction(SPKL(@"ALERT_ACTION_PLAY_AUDIO"), kSPKAudioPageActionPlay, kSPKActionPlayAudio, @"play", button),
                            SPKAudioPageMenuAction(SPKL(@"ALERT_ACTION_COPY_AUDIO_DOWNLOAD_URL"), kSPKAudioPageActionCopyURL, kSPKActionCopyAudioURL, @"link", button)
                        ]];
}

static void SPKAudioPageRunDefaultAction(UIView *sourceView) {
    NSString *action = [SPKUtils getStringPref:kSPKAudioPageDefaultActionKey];
    if (action.length == 0)
        action = kSPKAudioPageActionShare;

    NSDictionary *payload = SPKAudioPageResolvedPayload(sourceView);
    NSURL *url = payload[@"url"];
    SPKGallerySaveMetadata *metadata = payload[@"metadata"];
    if (!url || !metadata)
        return;
    SPKAudioPageRunAction(action, url, sourceView, metadata);
}

static UIView *SPKAudioPageButtonAnchor(UIView *bar) {
    UIView *share = SPKAudioPageReadIvar(bar, "shareButton");
    UIView *save = SPKAudioPageReadIvar(bar, "saveButton");
    BOOL shareValid = share && !share.hidden && !CGRectIsEmpty(share.frame);
    BOOL saveValid = save && !save.hidden && !CGRectIsEmpty(save.frame);
    if (shareValid && saveValid) {
        return CGRectGetMinX(save.frame) <= CGRectGetMinX(share.frame) ? save : share;
    }
    return saveValid ? save : (shareValid ? share : nil);
}

static UIColor *SPKAudioPageBackgroundColorFromAnchor(UIView *anchor) {
    UIColor *color = anchor.backgroundColor;
    if (color && CGColorGetAlpha(color.CGColor) > 0.01)
        return color;
    if (anchor.layer.backgroundColor && CGColorGetAlpha(anchor.layer.backgroundColor) > 0.01) {
        return [UIColor colorWithCGColor:anchor.layer.backgroundColor];
    }
    return [SPKUtils SPKColor_InstagramSecondaryBackground];
}

static void SPKAudioPagePinEdges(UIView *view, UIView *host) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];
}

static UIButton *SPKAudioPageButtonForHost(UIView *host) {
    return objc_getAssociatedObject(host, kSPKAudioPageButtonKey);
}

static void SPKAudioPageInstallButton(UIView *bar) {
    // Master audio-downloads toggle also gates the audio-page button entirely.
    if (![SPKUtils getBoolPref:@"downloads_audio_enabled"] ||
        ![SPKUtils getBoolPref:@"downloads_audio_page_button"]) {
        [[bar viewWithTag:kSPKAudioPageDownloadButtonTag] removeFromSuperview];
        return;
    }
    UIView *anchor = SPKAudioPageButtonAnchor(bar);
    UIView *host = [bar viewWithTag:kSPKAudioPageDownloadButtonTag];
    UIButton *button = [host isKindOfClass:UIView.class] ? SPKAudioPageButtonForHost(host) : nil;
    if (![button isKindOfClass:UIButton.class] || [button isKindOfClass:SPKChromeButton.class]) {
        if (host)
            [host removeFromSuperview];
        host = [UIView new];
        host.tag = kSPKAudioPageDownloadButtonTag;
        host.translatesAutoresizingMaskIntoConstraints = YES;
        host.clipsToBounds = NO;

        SPKChromeCanvas *canvas = [SPKChromeCanvas new];
        canvas.userInteractionEnabled = YES;
        [host addSubview:canvas];
        SPKAudioPagePinEdges(canvas, host);

        // Keep a native UIButton as the menu source so iOS 26 can morph the
        // button image with the menu, but put it inside SPKChromeCanvas so
        // Hide UI on Capture redacts it instead of removing it from screen.
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.showsMenuAsPrimaryAction = NO;
        button.adjustsImageWhenHighlighted = YES;
        [button addTarget:bar action:@selector(spk_audioPageDownloadTapped:) forControlEvents:UIControlEventTouchUpInside];
        [canvas.contentContainer addSubview:button];
        SPKAudioPagePinEdges(button, canvas.contentContainer);
        objc_setAssociatedObject(host, kSPKAudioPageButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [bar addSubview:host];
    }
    if (!anchor) {
        if (CGRectIsEmpty(host.frame)) {
            host.hidden = YES;
        }
        return;
    }

    NSString *defaultAction = [SPKUtils getStringPref:kSPKAudioPageDefaultActionKey];
    if (defaultAction.length == 0)
        defaultAction = kSPKAudioPageActionShare;

    CGFloat side = MAX(28.0, CGRectGetHeight(anchor.frame));

    UIImage *icon = [SPKAssetUtils instagramIconNamed:SPKAudioPageIconForAction(defaultAction)
                                            pointSize:24.0
                                        renderingMode:UIImageRenderingModeAlwaysTemplate];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = SPKAudioPageBackgroundColorFromAnchor(anchor);
    button.layer.cornerRadius = side / 2.0;
    button.clipsToBounds = YES;
    if (!button.menu) {
        button.menu = SPKAudioPageMenuForButton(button);
    }
    BOOL isNone = [defaultAction isEqualToString:@"none"];
    button.showsMenuAsPrimaryAction = isNone;

    host.frame = CGRectMake(CGRectGetMinX(anchor.frame) - side - 8.0, CGRectGetMidY(anchor.frame) - side / 2.0, side, side);
    button.hidden = NO;
    host.hidden = NO;
    [bar bringSubviewToFront:host];
}

%group SPKAudioPageDownloadHooks

%hook UIView
%new - (void)spk_audioPageDownloadTapped:(UIButton *)sender {
if (sender.showsMenuAsPrimaryAction)
    return;
SPKAudioPageRunDefaultAction(sender ?: (UIView *)self);
}
%end

%hook _TtC16IGAudioPageSwift26IGAudioPageHeaderActionBar
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"AudioPageDownload.layoutSubviews");
    // Only install/reposition if the button doesn't exist yet or the anchor moved.
    // Avoid touching the button mid-animation (menu morph) which breaks Liquid Glass.
    UIView *existing = [(UIView *)self viewWithTag:kSPKAudioPageDownloadButtonTag];
    if ([existing isKindOfClass:UIView.class] && !existing.hidden && !CGRectIsEmpty(existing.frame)) {
        UIView *anchor = SPKAudioPageButtonAnchor((UIView *)self);
        if (anchor) {
            CGFloat side = MAX(28.0, CGRectGetHeight(anchor.frame));
            CGRect expected = CGRectMake(CGRectGetMinX(anchor.frame) - side - 8.0,
                                         CGRectGetMidY(anchor.frame) - side / 2.0,
                                         side, side);
            if (CGRectEqualToRect(existing.frame, expected)) {
                return; // Nothing changed, don't touch the button.
            }
        }
    }
    SPKAudioPageInstallButton((UIView *)self);
}
%end

%end

extern "C" void SPKInstallAudioPageDownloadHooksIfNeeded(void) {
    if (![SPKUtils getBoolPref:@"downloads_audio_enabled"])
        return;
    if (![SPKUtils getBoolPref:@"downloads_audio_page_button"])
        return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKAudioPageDownloadHooks);
    });
}
