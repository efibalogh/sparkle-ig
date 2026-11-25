#import "SPKNewBadges.h"

#import <objc/runtime.h>

#import "SPKStrings.h"
#import "../Shared/UI/SPKFont.h"
#import "../Tweak.h"
#import "../Utils.h"
#import "SPKSettingsViewController.h"

NSString *const kSPKPrefSettingsNewBadges = @"tools_settings_new_badges";
NSNotificationName const SPKNewBadgesDidChangeNotification = @"SPKNewBadgesDidChangeNotification";

// Device-global UI state, like app_first_run: { row identifier : version it was new in }.
// Keyed by version too, so a row re-tagged for a later release badges again.
static NSString *const kSPKNewBadgesSeenKey = @"app_settings_new_badges_seen";

typedef NS_ENUM(NSInteger, SPKNewBadgesMode) {
    SPKNewBadgesModeUntilSeen,
    SPKNewBadgesModeKeep,
    SPKNewBadgesModeOff,
};

static SPKNewBadgesMode SPKNewBadgesCurrentMode(void) {
    NSString *mode = [SPKUtils getStringPref:kSPKPrefSettingsNewBadges];
    if ([mode isEqualToString:@"off"])
        return SPKNewBadgesModeOff;
    if ([mode isEqualToString:@"keep"])
        return SPKNewBadgesModeKeep;
    return SPKNewBadgesModeUntilSeen;
}

// major * 1000 + minor of "v1.7.0" / "1.7"; -1 when unparseable.
static NSInteger SPKNewBadgeVersionFamily(NSString *version) {
    if (![version isKindOfClass:[NSString class]])
        return -1;
    NSString *trimmed = [version hasPrefix:@"v"] ? [version substringFromIndex:1] : version;
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"."];
    if (parts.count < 2)
        return -1;
    return parts[0].integerValue * 1000 + parts[1].integerValue;
}

static BOOL SPKNewBadgeVersionIsCurrent(NSString *version) {
    NSInteger family = SPKNewBadgeVersionFamily(version);
    // Later than the installed version only happens on dev builds of the next release.
    return family >= 0 && family >= SPKNewBadgeVersionFamily(SPKVersionString);
}

static NSString *SPKNewBadgeIdentifier(SPKSetting *setting) {
    return setting.addedBadgeIdentifier.length ? setting.addedBadgeIdentifier : setting.defaultsKey;
}

static NSDictionary<NSString *, NSString *> *SPKNewBadgesSeen(void) {
    NSDictionary *seen = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKNewBadgesSeenKey];
    return [seen isKindOfClass:[NSDictionary class]] ? seen : @{};
}

NSDictionary<NSString *, NSString *> *SPKNewBadgeItemVersions(void) {
    // Items on custom pages, which are not SPKSetting rows: { identifier : version }.
    // The page draws its own badge with SPKNewBadgeItemIsNew and marks it seen with
    // SPKNewBadgesMarkItemsSeen; the row that opens the page lists the identifier
    // in `addedContentItems` so the dot leads there.
    return @{
        @"profile_analyzer_auto_refresh" : @"v1.7.0",
        @"tab_bar_hold_shortcuts" : @"v1.7.0",
        @"interface_native_tab_bar" : @"v1.7.0",
        SPKNewBadgeActionItemIdentifier(SPKActionButtonSourceStories, kSPKActionCopyLink) : @"v1.7.0",
    };
}

NSString *SPKNewBadgeActionItemIdentifier(SPKActionButtonSource source, NSString *actionIdentifier) {
    return [NSString stringWithFormat:@"action.%ld.%@", (long)source, actionIdentifier];
}

NSArray<NSString *> *SPKNewBadgeActionItemsForSource(SPKActionButtonSource source) {
    NSString *prefix = [NSString stringWithFormat:@"action.%ld.", (long)source];
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSString *identifier in SPKNewBadgeItemVersions()) {
        if ([identifier hasPrefix:prefix])
            [items addObject:identifier];
    }
    return items;
}

SPKSetting *SPKSettingMarkedNew(SPKSetting *setting, NSString *version) {
    setting.addedInVersion = version;
    return setting;
}

SPKSetting *SPKSettingMarkedNewWithID(SPKSetting *setting, NSString *version, NSString *identifier) {
    setting.addedInVersion = version;
    setting.addedBadgeIdentifier = identifier;
    return setting;
}

static BOOL SPKSettingIsShowable(SPKSetting *setting) {
    if (setting.hiddenProvider && setting.hiddenProvider())
        return NO;
    return YES;
}

static BOOL SPKIdentifierIsNew(NSString *identifier, NSString *version, SPKNewBadgesMode mode, NSDictionary<NSString *, NSString *> *seen) {
    if (identifier.length == 0 || version.length == 0 || !SPKNewBadgeVersionIsCurrent(version))
        return NO;
    if (mode == SPKNewBadgesModeKeep)
        return YES;
    return ![seen[identifier] isEqual:version];
}

static BOOL SPKSettingRowIsNew(SPKSetting *setting, SPKNewBadgesMode mode, NSDictionary<NSString *, NSString *> *seen) {
    return SPKIdentifierIsNew(SPKNewBadgeIdentifier(setting), setting.addedInVersion, mode, seen);
}

static BOOL SPKSectionsContainNew(NSArray *sections, SPKNewBadgesMode mode, NSDictionary<NSString *, NSString *> *seen, NSUInteger depth);
static char kSPKNewBadgeSearchSectionsKey;

// Whether anything behind this row (its own page, or a custom page it opens) is new.
static BOOL SPKSettingContainsNew(SPKSetting *setting, SPKNewBadgesMode mode, NSDictionary<NSString *, NSString *> *seen, NSUInteger depth) {
    NSDictionary<NSString *, NSString *> *items = SPKNewBadgeItemVersions();
    for (NSString *identifier in setting.addedContentItems) {
        if (SPKIdentifierIsNew(identifier, items[identifier], mode, seen))
            return YES;
    }
    if (setting.navSections.count)
        return SPKSectionsContainNew(setting.navSections, mode, seen, depth + 1);
    // A settings page subclass pushed as a view controller: its rows are built at init.
    if ([setting.navViewController isKindOfClass:[SPKSettingsViewController class]])
        return SPKSectionsContainNew(((SPKSettingsViewController *)setting.navViewController).sections, mode, seen, depth + 1);
    // A custom page that leads to settings (Downloads opens its history first) exposes
    // them for search; built once per row, since the provider makes fresh pages.
    if (setting.searchSectionsProvider) {
        NSArray *sections = objc_getAssociatedObject(setting, &kSPKNewBadgeSearchSectionsKey);
        if (!sections) {
            sections = setting.searchSectionsProvider() ?: @[];
            objc_setAssociatedObject(setting, &kSPKNewBadgeSearchSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return SPKSectionsContainNew(sections, mode, seen, depth + 1);
    }
    return NO;
}

static BOOL SPKSectionsContainNew(NSArray *sections, SPKNewBadgesMode mode, NSDictionary<NSString *, NSString *> *seen, NSUInteger depth) {
    if (depth > 8 || ![sections isKindOfClass:[NSArray class]])
        return NO;
    for (NSDictionary *section in sections) {
        if (![section isKindOfClass:[NSDictionary class]])
            continue;
        NSArray *rows = section[@"rows"];
        if (![rows isKindOfClass:[NSArray class]])
            continue;
        for (SPKSetting *row in rows) {
            if (![row isKindOfClass:[SPKSetting class]] || !SPKSettingIsShowable(row))
                continue;
            if (SPKSettingRowIsNew(row, mode, seen) || SPKSettingContainsNew(row, mode, seen, depth))
                return YES;
        }
    }
    return NO;
}

SPKNewBadgeState SPKNewBadgeStateForSetting(SPKSetting *setting) {
    SPKNewBadgesMode mode = SPKNewBadgesCurrentMode();
    if (mode == SPKNewBadgesModeOff || ![setting isKindOfClass:[SPKSetting class]])
        return SPKNewBadgeStateNone;
    NSDictionary *seen = mode == SPKNewBadgesModeUntilSeen ? SPKNewBadgesSeen() : @{};
    if (SPKSettingRowIsNew(setting, mode, seen))
        return SPKNewBadgeStateRow;
    if (SPKSettingContainsNew(setting, mode, seen, 0))
        return SPKNewBadgeStateContainsNew;
    return SPKNewBadgeStateNone;
}

BOOL SPKNewBadgeSectionsContainNew(NSArray *sections) {
    SPKNewBadgesMode mode = SPKNewBadgesCurrentMode();
    if (mode == SPKNewBadgesModeOff)
        return NO;
    NSDictionary *seen = mode == SPKNewBadgesModeUntilSeen ? SPKNewBadgesSeen() : @{};
    return SPKSectionsContainNew(sections, mode, seen, 0);
}

BOOL SPKNewBadgeItemIsNew(NSString *identifier) {
    SPKNewBadgesMode mode = SPKNewBadgesCurrentMode();
    if (mode == SPKNewBadgesModeOff)
        return NO;
    NSDictionary *seen = mode == SPKNewBadgesModeUntilSeen ? SPKNewBadgesSeen() : @{};
    return SPKIdentifierIsNew(identifier, SPKNewBadgeItemVersions()[identifier], mode, seen);
}

static void SPKNewBadgesStoreSeen(NSDictionary<NSString *, NSString *> *entries, id sender) {
    if (entries.count == 0 || SPKNewBadgesCurrentMode() != SPKNewBadgesModeUntilSeen)
        return;

    NSMutableDictionary<NSString *, NSString *> *seen = [NSMutableDictionary dictionary];
    // Drop entries from releases that no longer badge, so the store stays small.
    [SPKNewBadgesSeen() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *version, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && SPKNewBadgeVersionIsCurrent(version))
            seen[key] = version;
    }];

    __block BOOL changed = NO;
    [entries enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSString *version, BOOL *stop) {
        if (identifier.length && version.length && ![seen[identifier] isEqual:version]) {
            seen[identifier] = version;
            changed = YES;
        }
    }];
    if (!changed)
        return;

    [[NSUserDefaults standardUserDefaults] setObject:seen forKey:kSPKNewBadgesSeenKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKNewBadgesDidChangeNotification object:sender];
}

void SPKNewBadgesMarkSeen(NSArray<SPKSetting *> *settings, id sender) {
    NSMutableDictionary<NSString *, NSString *> *entries = [NSMutableDictionary dictionary];
    for (SPKSetting *setting in settings) {
        NSString *identifier = SPKNewBadgeIdentifier(setting);
        if (identifier.length && setting.addedInVersion.length)
            entries[identifier] = setting.addedInVersion;
    }
    SPKNewBadgesStoreSeen(entries, sender);
}

void SPKNewBadgesMarkItemsSeen(NSArray<NSString *> *identifiers, id sender) {
    NSDictionary<NSString *, NSString *> *items = SPKNewBadgeItemVersions();
    NSMutableDictionary<NSString *, NSString *> *entries = [NSMutableDictionary dictionary];
    for (NSString *identifier in identifiers) {
        if (items[identifier])
            entries[identifier] = items[identifier];
    }
    SPKNewBadgesStoreSeen(entries, sender);
}

// MARK: - Drawing

static UIImage *SPKNewBadgePillImage(UIFont *titleFont, UITraitCollection *traits) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
    });

    NSString *text = SPKL(@"SETTINGS_ROW_NEW_BADGE_TEXT");
    UIFont *probe = [SPKFont fontForStyle:SPKFontStyleBadge weight:UIFontWeightBold];
    NSString *cacheKey = [NSString stringWithFormat:@"pill|%@|%@|%.1f|%ld", text, probe.fontName, probe.pointSize, (long)traits.userInterfaceStyle];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached)
        return cached;

    // Sparkle's pill size; follows the chosen font and Dynamic Type like other pills.
    UIFont *font = [SPKFont fontForStyle:SPKFontStyleBadge weight:UIFontWeightBold];
    NSDictionary *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSKernAttributeName : @(0.3),
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGFloat horizontalInset = round(font.pointSize * 0.55);
    CGFloat verticalInset = round(font.pointSize * 0.22);
    CGSize size = CGSizeMake(ceil(textSize.width) + horizontalInset * 2.0, ceil(textSize.height) + verticalInset * 2.0);
    UIColor *fill = [[SPKUtils SPKColor_InstagramBlue] resolvedColorWithTraitCollection:traits];

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:traits];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:size.height / 2.0] fill];
        [text drawAtPoint:CGPointMake(horizontalInset, verticalInset) withAttributes:attributes];
    }];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [cache setObject:image forKey:cacheKey];
    return image;
}

static UIImage *SPKNewBadgeDotImage(UIFont *titleFont, UITraitCollection *traits) {
    CGFloat diameter = MAX(7.0, round(titleFont.pointSize * 0.45));
    UIColor *fill = [[SPKUtils SPKColor_InstagramBlue] resolvedColorWithTraitCollection:traits];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:traits];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [fill setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] fill];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

NSAttributedString *SPKNewBadgeAttributedTitle(NSString *title, UIFont *font, UIColor *color, SPKNewBadgeState state, UITraitCollection *traits) {
    NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:title ?: @"" attributes:attributes];
    if (state == SPKNewBadgeStateNone)
        return result;

    UIImage *image = state == SPKNewBadgeStateRow ? SPKNewBadgePillImage(font, traits) : SPKNewBadgeDotImage(font, traits);
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    // Centered on the capitals of the title.
    attachment.bounds = CGRectMake(0, round((font.capHeight - image.size.height) / 2.0), image.size.width, image.size.height);

    // A no-break space keeps the badge on the same line as the title's last word.
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attributes]];
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    return result;
}

UIImage *SPKNewBadgeIconWithDot(UIImage *icon, UIColor *iconColor, UITraitCollection *traits) {
    if (!icon)
        return icon;
    UIColor *resolvedIconColor = [iconColor resolvedColorWithTraitCollection:traits];
    UIColor *fill = [[SPKUtils SPKColor_InstagramBlue] resolvedColorWithTraitCollection:traits];
    CGSize size = icon.size;
    CGFloat diameter = MAX(7.0, round(size.width * 0.3));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:traits];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *tinted = [icon imageWithTintColor:resolvedIconColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [tinted drawInRect:CGRectMake(0, 0, size.width, size.height)];
        CGRect dot = CGRectMake(size.width - diameter, 0, diameter, diameter);
        // Clear a ring around the dot so it reads against the glyph.
        CGContextSetBlendMode(context.CGContext, kCGBlendModeClear);
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(dot, -1.5, -1.5)] fill];
        CGContextSetBlendMode(context.CGContext, kCGBlendModeNormal);
        [fill setFill];
        [[UIBezierPath bezierPathWithOvalInRect:dot] fill];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

NSString *SPKNewBadgeAccessibilityText(SPKNewBadgeState state) {
    switch (state) {
    case SPKNewBadgeStateRow:
        return SPKL(@"SETTINGS_ROW_NEW_BADGE_ACCESSIBILITY");
    case SPKNewBadgeStateContainsNew:
        return SPKL(@"SETTINGS_ROW_CONTAINS_NEW_ACCESSIBILITY");
    case SPKNewBadgeStateNone:
        return @"";
    }
    return @"";
}
