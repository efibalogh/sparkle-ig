#import <objc/message.h>
#import <objc/runtime.h>
#import "SPKStrings.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"

// Pin people and groups to the top of the share sheet. Holding a person's photo or
// name toggles their pin. Holding a group keeps Instagram's own member preview and
// adds a pin button beneath the members. Pinned recipients move to the first
// recipient slot and carry a small pin badge on their photo.

static NSString *const kSPKShareSheetPinsEnabledKey = @"general_share_sheet_pins";
// Per account, most recently pinned first. A person is @{ pk, username }, a group is
// @{ thread, title }. The display names are kept so a future management list can
// render the pins without a network lookup.
static NSString *const kSPKShareSheetPinnedKey = @"general_share_sheet_pinned";
static NSString *const kSPKShareSheetPinPKKey = @"pk";
static NSString *const kSPKShareSheetPinUsernameKey = @"username";
static NSString *const kSPKShareSheetPinThreadKey = @"thread";
static NSString *const kSPKShareSheetPinTitleKey = @"title";
// Group identities share the pin list with user pks, so they carry a prefix no pk has.
static NSString *const kSPKShareSheetGroupIdentityPrefix = @"thread:";

static BOOL SPKShareSheetPinsEnabled(void) {
    return [SPKUtils getBoolPref:kSPKShareSheetPinsEnabledKey];
}

#pragma mark - Storage

static NSString *SPKShareSheetIdentityForEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]])
        return nil;
    id pk = entry[kSPKShareSheetPinPKKey];
    if ([pk isKindOfClass:[NSString class]] && [pk length] > 0)
        return pk;
    id thread = entry[kSPKShareSheetPinThreadKey];
    if ([thread isKindOfClass:[NSString class]] && [thread length] > 0)
        return [kSPKShareSheetGroupIdentityPrefix stringByAppendingString:thread];
    return nil;
}

static NSArray<NSDictionary *> *SPKShareSheetPinEntries(void) {
    id stored = SPKPreferenceObjectForKey(kSPKShareSheetPinnedKey);
    if (![stored isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:[stored count]];
    for (id entry in (NSArray *)stored) {
        if (SPKShareSheetIdentityForEntry(entry))
            [entries addObject:entry];
    }
    return entries;
}

// Cell layout reads the pins on every pass, so they are cached per effective key: the
// key changes with the active account, and a toggle drops the cache.
static NSArray<NSString *> *SPKShareSheetCachedPins;
static NSString *SPKShareSheetCachedPinsKey;

/// Pinned identities, most recently pinned first.
static NSArray<NSString *> *SPKShareSheetPinnedIdentities(void) {
    NSString *effectiveKey = SPKEffectivePreferenceKey(kSPKShareSheetPinnedKey);
    if (SPKShareSheetCachedPins && [SPKShareSheetCachedPinsKey isEqualToString:effectiveKey])
        return SPKShareSheetCachedPins;
    NSMutableArray<NSString *> *identities = [NSMutableArray array];
    for (NSDictionary *entry in SPKShareSheetPinEntries())
        [identities addObject:SPKShareSheetIdentityForEntry(entry)];
    SPKShareSheetCachedPins = [identities copy];
    SPKShareSheetCachedPinsKey = [effectiveKey copy];
    return SPKShareSheetCachedPins;
}

static BOOL SPKShareSheetIsPinned(NSString *identity) {
    return identity.length > 0 && [SPKShareSheetPinnedIdentities() containsObject:identity];
}

#pragma mark - Recipient resolution

/// What a pin is made from: the identity it is stored under, the entry that stores it,
/// and the name the toast shows.
@interface SPKShareSheetPinTarget : NSObject
@property (nonatomic, copy) NSString *identity;
@property (nonatomic, copy) NSDictionary *entry;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic) BOOL isGroup;
@end

@implementation SPKShareSheetPinTarget
@end

static id SPKShareSheetRecipientForObject(id object) {
    if (![object respondsToSelector:@selector(recipient)])
        return nil;
    id recipient = nil;
    @try {
        recipient = ((id (*)(id, SEL))objc_msgSend)(object, @selector(recipient));
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return [recipient respondsToSelector:@selector(users)] ? recipient : nil;
}

static BOOL SPKShareSheetRecipientFlag(id recipient, SEL selector) {
    return [recipient respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(recipient, selector);
}

static NSString *SPKShareSheetRecipientString(id recipient, SEL selector) {
    if (![recipient respondsToSelector:selector])
        return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(recipient, selector);
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

/// A person by pk, a group by thread id. Channels are left out: they are not a
/// conversation the user shares into the way a chat is.
static SPKShareSheetPinTarget *SPKShareSheetPinTargetForObject(id object) {
    id recipient = SPKShareSheetRecipientForObject(object);
    if (!recipient || SPKShareSheetRecipientFlag(recipient, @selector(isBroadcastChannel)))
        return nil;
    NSArray *users = ((NSArray *(*)(id, SEL))objc_msgSend)(recipient, @selector(users));
    if (![users isKindOfClass:[NSArray class]])
        users = @[];

    SPKShareSheetPinTarget *target = [SPKShareSheetPinTarget new];
    if (!SPKShareSheetRecipientFlag(recipient, @selector(isGroupThread)) && users.count == 1) {
        id user = users.firstObject;
        NSString *pk = [SPKUtils pkFromIGUser:user];
        if (pk.length == 0)
            return nil;
        NSString *username = [user respondsToSelector:@selector(username)] ? [(IGUser *)user username] : nil;
        target.identity = pk;
        target.entry = @{kSPKShareSheetPinPKKey : pk, kSPKShareSheetPinUsernameKey : username ?: @""};
        target.displayName = username.length > 0 ? [@"@" stringByAppendingString:username] : nil;
        return target;
    }

    NSString *threadID = SPKShareSheetRecipientString(recipient, @selector(threadID));
    if (threadID.length == 0)
        return nil;
    NSString *title = SPKShareSheetRecipientString(recipient, @selector(threadName));
    target.identity = [kSPKShareSheetGroupIdentityPrefix stringByAppendingString:threadID];
    target.entry = @{kSPKShareSheetPinThreadKey : threadID, kSPKShareSheetPinTitleKey : title ?: @""};
    target.displayName = title;
    target.isGroup = YES;
    return target;
}

static NSString *SPKShareSheetIdentityForObject(id object) {
    return SPKShareSheetPinTargetForObject(object).identity;
}

static id SPKShareSheetObjectAtIndexPath(IGDirectRecipientListViewController *controller, NSIndexPath *indexPath) {
    id adapter = controller.listAdapter;
    if (!indexPath || ![adapter respondsToSelector:@selector(objectAtSection:)])
        return nil;
    @try {
        return ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, @selector(objectAtSection:), indexPath.section);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark - Ordering

/// Moves each pinned recipient's first appearance to the first recipient slot, leaving
/// whatever Instagram places ahead of the recipients (story targets, headers) alone.
static NSArray *SPKShareSheetApplyPins(NSArray *objects) {
    if (!SPKShareSheetPinsEnabled() || ![objects isKindOfClass:[NSArray class]] || objects.count < 2)
        return objects;
    NSArray<NSString *> *pins = SPKShareSheetPinnedIdentities();
    if (pins.count == 0)
        return objects;

    NSUInteger firstRecipientIndex = NSNotFound;
    NSMutableDictionary<NSString *, id> *pinnedObjects = [NSMutableDictionary dictionary];
    NSMutableArray *rest = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        if (firstRecipientIndex == NSNotFound && SPKShareSheetRecipientForObject(object))
            firstRecipientIndex = rest.count;
        NSString *identity = SPKShareSheetIdentityForObject(object);
        if (identity && !pinnedObjects[identity] && [pins containsObject:identity]) {
            pinnedObjects[identity] = object;
            continue;
        }
        [rest addObject:object];
    }
    if (pinnedObjects.count == 0)
        return objects;

    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:pinnedObjects.count];
    for (NSString *identity in pins) {
        id object = pinnedObjects[identity];
        if (object)
            [ordered addObject:object];
    }
    NSUInteger insertionIndex = firstRecipientIndex == NSNotFound ? 0 : MIN(firstRecipientIndex, rest.count);
    [rest insertObjects:ordered atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertionIndex, ordered.count)]];
    return rest;
}

#pragma mark - Pin badge

static const void *kSPKShareSheetPinBadgeKey = &kSPKShareSheetPinBadgeKey;

static BOOL SPKShareSheetViewIsShown(UIView *view, UIView *root) {
    for (UIView *current = view; current && current != root; current = current.superview) {
        if (current.hidden || current.alpha < 0.01)
            return NO;
    }
    return YES;
}

/// The photo that is actually drawn. The cell's core view keeps more than one image
/// view (a direct avatar and a lazily created image view, used for different kinds
/// of recipient), and the one not in use sits elsewhere in the cell, so the photo is
/// picked by what is shown: the largest visible square in the cell.
static UIView *SPKShareSheetPhotoViewInCell(UICollectionViewCell *cell, UIView *badge) {
    UIView *best = nil;
    CGFloat bestSide = 0.0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:cell.contentView.subviews];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view == badge || view.hidden || view.alpha < 0.01)
            continue;
        CGSize size = view.bounds.size;
        if (size.width >= 30.0 && fabs(size.width - size.height) < 1.0 && size.width > bestSide + 0.5 &&
            SPKShareSheetViewIsShown(view, cell.contentView)) {
            best = view;
            bestSide = size.width;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

// Instagram's selection check on the same photo, as measured on device: a 21pt disc
// in a 27.5pt ring of the sheet colour, centred just outside the 45 degree rim point.
static const CGFloat kSPKShareSheetPinDiscSize = 21.0;
static const CGFloat kSPKShareSheetPinBadgeSize = 27.5;
static const CGFloat kSPKShareSheetPinGlyphSize = 12.0;
static const CGFloat kSPKShareSheetPinCentreFraction = 0.765;
static const NSInteger kSPKShareSheetPinRingTag = 0x5350524E;
static const NSInteger kSPKShareSheetPinDiscTag = 0x53505244;
static const NSInteger kSPKShareSheetPinGlyphTag = 0x53505247;

/// The selection check's fill (#455EFE): unlike the text accent it is the same blue
/// in light and dark mode.
static UIColor *SPKShareSheetPinDiscColor(void) {
    return [UIColor colorWithRed:0x45 / 255.0 green:0x5E / 255.0 blue:0xFE / 255.0 alpha:1.0];
}

/// Mirrors Instagram's selection check at the other end of its diagonal: a blue disc
/// with a pin cut through it, ringed in the sheet's background colour so it reads as cut out
/// of the photo. Everything sits in a capture-redacted canvas, ring included, so Hide
/// UI on Capture removes the badge without leaving a hole in the photo.
static UIView *SPKShareSheetMakePinBadge(void) {
    UIView *badge = [UIView new];
    badge.userInteractionEnabled = NO;
    badge.isAccessibilityElement = NO;

    SPKChromeCanvas *canvas = [SPKChromeCanvas new];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    canvas.userInteractionEnabled = NO;
    [badge addSubview:canvas];

    UIView *ring = [UIView new];
    ring.tag = kSPKShareSheetPinRingTag;
    ring.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *disc = [UIView new];
    disc.tag = kSPKShareSheetPinDiscTag;
    disc.translatesAutoresizingMaskIntoConstraints = NO;
    disc.backgroundColor = SPKShareSheetPinDiscColor();

    UIImage *glyph = [SPKAssetUtils instagramIconNamed:@"pin_filled" pointSize:12.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *glyphView = [[UIImageView alloc] initWithImage:glyph];
    glyphView.translatesAutoresizingMaskIntoConstraints = NO;
    glyphView.tag = kSPKShareSheetPinGlyphTag;
    glyphView.contentMode = UIViewContentModeScaleAspectFit;

    // Constrained to the canvas itself: it moves its content into the secure layer
    // once attached, and only constraints to the canvas survive that move.
    [canvas.contentContainer addSubview:ring];
    [canvas.contentContainer addSubview:disc];
    [canvas.contentContainer addSubview:glyphView];
    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:badge.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:badge.bottomAnchor],
        [ring.leadingAnchor constraintEqualToAnchor:canvas.leadingAnchor],
        [ring.trailingAnchor constraintEqualToAnchor:canvas.trailingAnchor],
        [ring.topAnchor constraintEqualToAnchor:canvas.topAnchor],
        [ring.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor],
        [disc.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
        [disc.centerYAnchor constraintEqualToAnchor:canvas.centerYAnchor],
        [disc.widthAnchor constraintEqualToConstant:kSPKShareSheetPinDiscSize],
        [disc.heightAnchor constraintEqualToConstant:kSPKShareSheetPinDiscSize],
        [glyphView.centerXAnchor constraintEqualToAnchor:disc.centerXAnchor],
        [glyphView.centerYAnchor constraintEqualToAnchor:disc.centerYAnchor],
        [glyphView.widthAnchor constraintEqualToConstant:kSPKShareSheetPinGlyphSize],
        [glyphView.heightAnchor constraintEqualToConstant:kSPKShareSheetPinGlyphSize],
    ]];
    return badge;
}

/// The colour the photo sits on: the first opaque background above the grid.
static UIColor *SPKShareSheetBackdropColor(UIView *view) {
    for (UIView *current = view.superview; current; current = current.superview) {
        UIColor *color = current.backgroundColor;
        CGFloat alpha = 0.0;
        if (color && [color getRed:NULL green:NULL blue:NULL alpha:&alpha] && alpha > 0.95)
            return color;
    }
    return UIColor.systemBackgroundColor;
}

static void SPKShareSheetRoundBadgeParts(UIView *badge, UIColor *ringColor) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:badge];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        // The glyph takes the ring's colour too, so like the check it reads as cut
        // through the disc to the sheet behind.
        if (view.tag == kSPKShareSheetPinRingTag)
            view.backgroundColor = ringColor;
        if (view.tag == kSPKShareSheetPinGlyphTag)
            view.tintColor = ringColor;
        if (view.tag == kSPKShareSheetPinRingTag || view.tag == kSPKShareSheetPinDiscTag)
            view.layer.cornerRadius = CGRectGetWidth(view.bounds) / 2.0;
        [queue addObjectsFromArray:view.subviews];
    }
}

/// Hosted inside the photo view rather than the cell. Instagram moves the photo
/// within a recycled cell after the cell's own layout pass (its inset depends on the
/// grid column), so a position copied from it goes stale; as the photo's own subview
/// the badge moves with it, and its place in the photo's bounds never changes.
static void SPKShareSheetLayoutPinBadge(UICollectionViewCell *cell) {
    UIView *badge = objc_getAssociatedObject(cell, kSPKShareSheetPinBadgeKey);
    BOOL pinned = NO;
    if (SPKShareSheetPinsEnabled()) {
        id viewModel = [SPKUtils getIvarForObj:cell name:"recipientCellViewModel"];
        pinned = SPKShareSheetIsPinned(SPKShareSheetIdentityForObject(viewModel));
    }
    if (!pinned) {
        badge.hidden = YES;
        return;
    }
    [cell.contentView layoutIfNeeded];
    UIView *photo = SPKShareSheetPhotoViewInCell(cell, badge);
    if (!photo) {
        badge.hidden = YES;
        return;
    }
    if (!badge) {
        badge = SPKShareSheetMakePinBadge();
        objc_setAssociatedObject(cell, kSPKShareSheetPinBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superview != photo)
        [photo addSubview:badge];

    CGFloat side = CGRectGetWidth(photo.bounds);
    CGFloat offset = side / 2.0 * kSPKShareSheetPinCentreFraction;
    badge.bounds = CGRectMake(0, 0, kSPKShareSheetPinBadgeSize, kSPKShareSheetPinBadgeSize);
    badge.center = CGPointMake(CGRectGetMidX(photo.bounds) - offset, CGRectGetMidY(photo.bounds) - offset);
    badge.hidden = NO;
    [photo bringSubviewToFront:badge];
    [badge layoutIfNeeded];
    SPKShareSheetRoundBadgeParts(badge, SPKShareSheetBackdropColor(cell));
}

static const void *kSPKShareSheetPinBadgePendingKey = &kSPKShareSheetPinBadgePendingKey;

/// Instagram binds a recipient to a cell and sizes its photo after the cell's first
/// layout pass, and nothing lays the cell out again until the next interaction, so
/// a freshly shown pinned cell is checked once more on the next turn of the run
/// loop. Layout passes within one turn share that check.
static void SPKShareSheetSchedulePinBadge(UICollectionViewCell *cell) {
    SPKShareSheetLayoutPinBadge(cell);
    if (objc_getAssociatedObject(cell, kSPKShareSheetPinBadgePendingKey))
        return;
    objc_setAssociatedObject(cell, kSPKShareSheetPinBadgePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UICollectionViewCell *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionViewCell *strongCell = weakCell;
        if (!strongCell)
            return;
        objc_setAssociatedObject(strongCell, kSPKShareSheetPinBadgePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SPKShareSheetLayoutPinBadge(strongCell);
    });
}

#pragma mark - Toggling

static __weak IGDirectRecipientListViewController *SPKShareSheetActiveList;

static void SPKShareSheetReloadList(IGDirectRecipientListViewController *controller) {
    id adapter = controller.listAdapter;
    SEL performUpdates = @selector(performUpdatesAnimated:completion:);
    if ([adapter respondsToSelector:performUpdates])
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, performUpdates, YES, nil);
    for (UICollectionViewCell *cell in controller.collectionView.visibleCells)
        [cell setNeedsLayout];
}

static void SPKShareSheetTogglePin(SPKShareSheetPinTarget *target, IGDirectRecipientListViewController *controller) {
    if (target.identity.length == 0)
        return;
    NSMutableArray<NSDictionary *> *entries = [SPKShareSheetPinEntries() mutableCopy];
    NSUInteger existing = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, __unused NSUInteger idx, __unused BOOL *stop) {
        return [SPKShareSheetIdentityForEntry(entry) isEqualToString:target.identity];
    }];
    BOOL pinned = existing == NSNotFound;
    if (pinned)
        [entries insertObject:target.entry atIndex:0];
    else
        [entries removeObjectAtIndex:existing];
    SPKPreferenceSetObject(entries, kSPKShareSheetPinnedKey);
    SPKShareSheetCachedPins = nil;

    SPKLog(@"Messages", @"[Sparkle ShareSheetPins] %@ %@", pinned ? @"pinned" : @"unpinned", target.identity);
    SPKNotify(kSPKNotificationShareSheetPin,
              pinned ? SPKL(@"GENERAL_SHARING_PIN_RECIPIENTS_TOAST_PINNED") : SPKL(@"GENERAL_SHARING_PIN_RECIPIENTS_TOAST_UNPINNED"),
              target.displayName,
              pinned ? @"pin_filled" : @"pin_off",
              SPKNotificationToneInfo);
    SPKShareSheetReloadList(controller);
}

#pragma mark - Group member preview

// The group whose member preview is about to open. Recorded when the hold begins,
// since the preview is handed only Instagram's member view models.
static SPKShareSheetPinTarget *SPKShareSheetPendingGroup;
static CFAbsoluteTime SPKShareSheetPendingGroupTime;

static void SPKShareSheetNoteHeldObject(id object) {
    SPKShareSheetPinTarget *target = SPKShareSheetPinTargetForObject(object);
    if (!target.isGroup)
        return;
    SPKShareSheetPendingGroup = target;
    SPKShareSheetPendingGroupTime = CFAbsoluteTimeGetCurrent();
}

static SPKShareSheetPinTarget *SPKShareSheetConsumePendingGroup(void) {
    SPKShareSheetPinTarget *target = SPKShareSheetPendingGroup;
    SPKShareSheetPendingGroup = nil;
    // A preview opening long after the hold came from somewhere else.
    if (CFAbsoluteTimeGetCurrent() - SPKShareSheetPendingGroupTime > 3.0)
        return nil;
    return target;
}

static const void *kSPKShareSheetGroupTargetKey = &kSPKShareSheetGroupTargetKey;
static const void *kSPKShareSheetGroupButtonKey = &kSPKShareSheetGroupButtonKey;
static const void *kSPKShareSheetGroupHandlerKey = &kSPKShareSheetGroupHandlerKey;

@interface SPKShareSheetGroupPinButtonTarget : NSObject
@property (nonatomic, weak) UIViewController *preview;
@end

@implementation SPKShareSheetGroupPinButtonTarget

- (void)buttonTapped {
    UIViewController *preview = self.preview;
    SPKShareSheetPinTarget *target = preview ? objc_getAssociatedObject(preview, kSPKShareSheetGroupTargetKey) : nil;
    if (!target)
        return;
    SPKShareSheetTogglePin(target, SPKShareSheetActiveList);
    // Closed through Instagram's own outside-tap handler, so its dismissal and
    // bookkeeping run exactly as they would for a tap on the backdrop.
    SEL dismiss = NSSelectorFromString(@"handleTapGesture");
    if ([preview respondsToSelector:dismiss])
        ((void (*)(id, SEL))objc_msgSend)(preview, dismiss);
    else
        [preview dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIButton *SPKShareSheetMakeGroupPinButton(SPKShareSheetPinTarget *target, UIViewController *preview) {
    BOOL pinned = SPKShareSheetIsPinned(target.identity);
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = pinned ? SPKL(@"GENERAL_SHARING_PIN_RECIPIENTS_GROUP_UNPIN_ACTION") : SPKL(@"GENERAL_SHARING_PIN_RECIPIENTS_GROUP_PIN_ACTION");
    configuration.image = [SPKAssetUtils instagramIconNamed:pinned ? @"pin_off" : @"pin_filled"
                                                  pointSize:18.0
                                              renderingMode:UIImageRenderingModeAlwaysTemplate];
    configuration.imagePadding = 8.0;
    configuration.baseBackgroundColor = [SPKUtils SPKColor_InstagramBackground];
    configuration.baseForegroundColor = [SPKUtils SPKColor_InstagramPrimaryText];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *updated = [attributes mutableCopy];
        updated[NSFontAttributeName] = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        return updated;
    };

    SPKShareSheetGroupPinButtonTarget *handler = [SPKShareSheetGroupPinButtonTarget new];
    handler.preview = preview;
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    [button addTarget:handler action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, kSPKShareSheetGroupHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

/// Sits under the member card, matching its width, the way a context menu's actions sit
/// under its preview.
static void SPKShareSheetLayoutGroupPinButton(UIViewController *preview) {
    UIButton *button = objc_getAssociatedObject(preview, kSPKShareSheetGroupButtonKey);
    if (!button)
        return;
    UICollectionView *members = nil;
    for (UIView *subview in preview.view.subviews) {
        if ([subview isKindOfClass:[UICollectionView class]]) {
            members = (UICollectionView *)subview;
            break;
        }
    }
    if (!members) {
        button.hidden = YES;
        return;
    }
    if (button.superview != preview.view)
        [preview.view addSubview:button];
    CGFloat height = 50.0;
    CGFloat maxY = CGRectGetHeight(preview.view.bounds) - preview.view.safeAreaInsets.bottom - 12.0;
    CGFloat y = MIN(CGRectGetMaxY(members.frame) + 12.0, maxY - height);
    button.frame = CGRectMake(CGRectGetMinX(members.frame), y, CGRectGetWidth(members.frame), height);
    button.hidden = NO;
    [preview.view bringSubviewToFront:button];
}

#pragma mark - Long press

static const void *kSPKShareSheetPinGestureKey = &kSPKShareSheetPinGestureKey;

@interface SPKShareSheetPinGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) IGDirectRecipientListViewController *controller;
@end

@implementation SPKShareSheetPinGestureTarget

- (id)objectForRecognizer:(UIGestureRecognizer *)recognizer {
    UICollectionView *collectionView = self.controller.collectionView;
    if (!collectionView)
        return nil;
    NSIndexPath *indexPath = [collectionView indexPathForItemAtPoint:[recognizer locationInView:collectionView]];
    return SPKShareSheetObjectAtIndexPath(self.controller, indexPath);
}

// Begins only on a person. A group hold is noted for the member preview it opens and
// then left to Instagram.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (!SPKShareSheetPinsEnabled())
        return NO;
    SPKShareSheetPinTarget *target = SPKShareSheetPinTargetForObject([self objectForRecognizer:recognizer]);
    if (target.isGroup) {
        SPKShareSheetPendingGroup = target;
        SPKShareSheetPendingGroupTime = CFAbsoluteTimeGetCurrent();
        return NO;
    }
    return target != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The grid's own scrolling must keep working; a press that starts moving fails
    // this recogniser on its own movement allowance.
    return YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    SPKShareSheetPinTarget *target = SPKShareSheetPinTargetForObject([self objectForRecognizer:recognizer]);
    if (!target || target.isGroup)
        return;
    SPKShareSheetTogglePin(target, self.controller);
}

@end

static void SPKShareSheetAttachPinGesture(IGDirectRecipientListViewController *controller) {
    UICollectionView *collectionView = controller.collectionView;
    if (![collectionView isKindOfClass:[UICollectionView class]] ||
        objc_getAssociatedObject(collectionView, kSPKShareSheetPinGestureKey))
        return;
    SPKShareSheetPinGestureTarget *target = [SPKShareSheetPinGestureTarget new];
    target.controller = controller;
    UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                            action:@selector(handleLongPress:)];
    recognizer.delegate = target;
    // Cancels touches so the press that pins never also lands as a tap, which in this
    // grid would select or one-tap send to the person being pinned.
    recognizer.cancelsTouchesInView = YES;
    [collectionView addGestureRecognizer:recognizer];
    // The recogniser holds its target weakly; the collection view keeps both alive.
    objc_setAssociatedObject(collectionView, kSPKShareSheetPinGestureKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Instagram's own hold on a person is swallowed while pinning owns that gesture. A
/// group hold always reaches Instagram, which opens the member preview.
static BOOL SPKShareSheetHandleNativeLongPress(id viewModel) {
    if (!SPKShareSheetPinsEnabled())
        return NO;
    SPKShareSheetPinTarget *target = SPKShareSheetPinTargetForObject(viewModel);
    if (target.isGroup) {
        SPKShareSheetNoteHeldObject(viewModel);
        return NO;
    }
    return target != nil;
}

#pragma mark - Hooks

%group SPKShareSheetPinsHooks

%hook IGDirectRecipientListViewController

- (void)viewDidLoad {
    %orig;
    SPKShareSheetAttachPinGesture(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // The collection view is not always in place by viewDidLoad.
    SPKShareSheetAttachPinGesture(self);
    SPKShareSheetActiveList = self;
}

- (id)objectsForListAdapter:(id)adapter {
    return SPKShareSheetApplyPins(%orig);
}

- (void)v3RecipientDidLongPress:(id)viewModel {
    SPKShareSheetActiveList = self;
    if (SPKShareSheetHandleNativeLongPress(viewModel))
        return;
    %orig;
}

- (void)recipientSectionController:(id)controller didLongPressViewModel:(id)viewModel {
    SPKShareSheetActiveList = self;
    if (SPKShareSheetHandleNativeLongPress(viewModel))
        return;
    %orig;
}

%end

%hook IGDirectSupershareV3Cell

- (void)layoutSubviews {
    %orig;
    SPKShareSheetSchedulePinBadge((UICollectionViewCell *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window)
        SPKShareSheetSchedulePinBadge((UICollectionViewCell *)self);
}

%end

%end

%group SPKShareSheetGroupPreviewHooks

%hook IGDirectSharesheetRevealGroupMembersViewController

- (void)viewDidLoad {
    %orig;
    if (!SPKShareSheetPinsEnabled())
        return;
    SPKShareSheetPinTarget *target = SPKShareSheetConsumePendingGroup();
    if (!target)
        return;
    UIViewController *preview = (UIViewController *)self;
    objc_setAssociatedObject(preview, kSPKShareSheetGroupTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(preview, kSPKShareSheetGroupButtonKey, SPKShareSheetMakeGroupPinButton(target, preview), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)viewDidLayoutSubviews {
    %orig;
    SPKShareSheetLayoutGroupPinButton((UIViewController *)self);
}

%end

%end

// Installed unconditionally: the toggle and the pins are per account, so both are
// read at call time instead of deciding the install.
void SPKInstallShareSheetPinsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cell = SPKResolveIGClass(@"IGDirectSupershareSwiftV3.IGDirectSupershareV3Cell", nil);
        if (NSClassFromString(@"IGDirectRecipientListViewController") && cell)
            %init(SPKShareSheetPinsHooks, IGDirectSupershareV3Cell = cell);
        Class preview = SPKResolveIGClass(@"IGDirectSharesheetRevealGroupMembersViewController.IGDirectSharesheetRevealGroupMembersViewController", nil);
        if (preview)
            %init(SPKShareSheetGroupPreviewHooks, IGDirectSharesheetRevealGroupMembersViewController = preview);
    });
}
