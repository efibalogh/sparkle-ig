#import "SPKAppIconCatalog.h"
#import "SPKStrings.h"

static NSString *const kSPKAppIconPrimaryIdentifier = @"";
static NSString *const kSPKAppIconSelectionDefaultsKey = @"general_app_icon_identifier";

@implementation SPKAppIconItem
@end

static NSString *SPKAppIconDisplayNameFromIdentifier(NSString *identifier, BOOL primary) {
    if (primary || identifier.length == 0) {
        return SPKL(@"MENU_DEFAULT");
    }

    NSMutableString *displayName = [[identifier stringByReplacingOccurrencesOfString:@"_" withString:@" "] mutableCopy];
    [displayName replaceOccurrencesOfString:@"-" withString:@" " options:0 range:NSMakeRange(0, displayName.length)];
    [displayName replaceOccurrencesOfString:@"AppIcon" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, displayName.length)];
    [displayName replaceOccurrencesOfString:@"Icon" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, displayName.length)];
    NSString *trimmed = [displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed.capitalizedString : identifier;
}

static NSArray<NSString *> *SPKAppIconFilesFromDictionary(NSDictionary *dictionary) {
    NSMutableArray<NSString *> *iconFiles = [NSMutableArray array];
    NSString *iconName = dictionary[@"CFBundleIconName"];
    if ([iconName isKindOfClass:[NSString class]] && iconName.length > 0) {
        [iconFiles addObject:iconName];
    }

    NSArray *files = dictionary[@"CFBundleIconFiles"];
    if (![files isKindOfClass:[NSArray class]]) {
        return iconFiles;
    }

    for (id value in files) {
        if (![value isKindOfClass:[NSString class]])
            continue;
        NSString *file = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (file.length > 0 && ![iconFiles containsObject:file]) {
            [iconFiles addObject:file];
        }
    }
    return iconFiles;
}

static SPKAppIconItem *SPKAppIconItemFromDictionary(NSString *identifier, NSDictionary *dictionary, BOOL primary) {
    SPKAppIconItem *item = [[SPKAppIconItem alloc] init];
    item.identifier = primary ? kSPKAppIconPrimaryIdentifier : (identifier ?: @"");
    item.displayName = SPKAppIconDisplayNameFromIdentifier(identifier, primary);
    item.iconFiles = SPKAppIconFilesFromDictionary(dictionary);
    item.isPrimary = primary;
    return item;
}

static NSArray<NSDictionary *> *SPKAppIconIconDictionaries(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableArray<NSDictionary *> *dictionaries = [NSMutableArray array];
    NSDictionary *icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:[NSDictionary class]]) {
        [dictionaries addObject:icons];
    }

    NSDictionary *ipadIcons = info[@"CFBundleIcons~ipad"];
    if ([ipadIcons isKindOfClass:[NSDictionary class]]) {
        [dictionaries addObject:ipadIcons];
    }
    return dictionaries;
}

static UIImage *SPKAppIconImageNamed(NSString *name) {
    if (name.length == 0)
        return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:name];
    if ([name.pathExtension caseInsensitiveCompare:@"png"] != NSOrderedSame) {
        [candidates addObject:[name stringByAppendingPathExtension:@"png"]];
    }

    for (NSString *candidate in candidates) {
        UIImage *image = [UIImage imageNamed:candidate inBundle:NSBundle.mainBundle compatibleWithTraitCollection:nil];
        if (image)
            return image;

        NSString *resourceName = candidate.stringByDeletingPathExtension;
        NSString *extension = candidate.pathExtension.length > 0 ? candidate.pathExtension : nil;
        NSString *path = [NSBundle.mainBundle pathForResource:resourceName ofType:extension];
        if (path.length > 0) {
            image = [UIImage imageWithContentsOfFile:path];
            if (image)
                return image;
        }
    }

    return nil;
}

@implementation SPKAppIconCatalog

+ (NSArray<SPKAppIconItem *> *)availableAppIcons {
    NSMutableArray<SPKAppIconItem *> *items = [NSMutableArray array];
    NSArray<NSDictionary *> *iconDictionaries = SPKAppIconIconDictionaries();

    NSDictionary *primary = iconDictionaries.firstObject[@"CFBundlePrimaryIcon"];
    if ([primary isKindOfClass:[NSDictionary class]]) {
        [items addObject:SPKAppIconItemFromDictionary(@"", primary, YES)];
    } else {
        SPKAppIconItem *fallback = [[SPKAppIconItem alloc] init];
        fallback.identifier = kSPKAppIconPrimaryIdentifier;
        fallback.displayName = SPKL(@"MENU_DEFAULT");
        fallback.iconFiles = @[ @"Prod60x60", @"Icon-60-Prod", @"Prod" ];
        fallback.isPrimary = YES;
        [items addObject:fallback];
    }

    NSMutableDictionary<NSString *, NSDictionary *> *mergedAlternates = [NSMutableDictionary dictionary];
    for (NSDictionary *icons in iconDictionaries) {
        NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
        if (![alternates isKindOfClass:[NSDictionary class]])
            continue;
        for (NSString *identifier in alternates) {
            NSDictionary *dictionary = alternates[identifier];
            if (![dictionary isKindOfClass:[NSDictionary class]])
                continue;
            if (!mergedAlternates[identifier]) {
                mergedAlternates[identifier] = dictionary;
            }
        }
    }

    NSArray<NSString *> *sortedKeys = [[mergedAlternates allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *identifier in sortedKeys) {
        [items addObject:SPKAppIconItemFromDictionary(identifier, mergedAlternates[identifier], NO)];
    }

    return items;
}

+ (NSString *)currentAppIconIdentifier {
    // UIApplication.alternateIconName is unreliable on re-signed / injected
    // builds: it frequently reports nil even while an alternate icon is active
    // (the setter still works). So we trust our own persisted record first and
    // only fall back to the system value when we have nothing stored.
    NSString *stored = [self storedSelectedIdentifier];
    if (stored != nil) {
        // Validate against what's actually installable; if the stored icon no
        // longer exists in the bundle, drop back to the system value.
        if (stored.length == 0 || [self appIconWithIdentifier:stored] != nil) {
            return stored.length > 0 ? stored : kSPKAppIconPrimaryIdentifier;
        }
    }

    NSString *alternateIconName = UIApplication.sharedApplication.alternateIconName;
    return alternateIconName.length > 0 ? alternateIconName : kSPKAppIconPrimaryIdentifier;
}

+ (NSString *)storedSelectedIdentifier {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kSPKAppIconSelectionDefaultsKey];
    if (![value isKindOfClass:[NSString class]])
        return nil;
    // The dark and neutral Sparkle icons were folded into the single Sparkle
    // icon, which follows the system appearance itself.
    if ([value isEqualToString:@"sparkle-dark"] || [value isEqualToString:@"sparkle-neutral"])
        return @"sparkle";
    return value;
}

+ (void)setStoredSelectedIdentifier:(NSString *)identifier {
    [[NSUserDefaults standardUserDefaults] setObject:(identifier ?: kSPKAppIconPrimaryIdentifier)
                                              forKey:kSPKAppIconSelectionDefaultsKey];
}

+ (SPKAppIconItem *)currentAppIcon {
    return [self appIconWithIdentifier:[self currentAppIconIdentifier]];
}

+ (void)applyStoredIconIfNeeded {
    if (!UIApplication.sharedApplication.supportsAlternateIcons)
        return;

    NSString *stored = [self storedSelectedIdentifier];
    if (stored == nil)
        return; // nothing imported / never chosen

    // Resolve whether the stored identifier is the primary icon (which maps to
    // a nil alternate name). Fall back to the primary-identifier constant if the
    // icon isn't in the catalog.
    SPKAppIconItem *item = [self appIconWithIdentifier:stored];
    BOOL isPrimary = item ? item.isPrimary : (stored.length == 0 || [stored isEqualToString:kSPKAppIconPrimaryIdentifier]);
    NSString *desiredAlternateName = isPrimary ? nil : stored;

    NSString *currentAlternateName = UIApplication.sharedApplication.alternateIconName;
    BOOL alreadyApplied = (desiredAlternateName == nil)
                              ? (currentAlternateName.length == 0)
                              : [desiredAlternateName isEqualToString:currentAlternateName];
    if (alreadyApplied)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Best-effort: if the alternate icon can't be applied (e.g. the icon
        // asset isn't in this build) the stored pref still reflects the import.
        [UIApplication.sharedApplication setAlternateIconName:desiredAlternateName
                                            completionHandler:nil];
    });
}

+ (SPKAppIconItem *)appIconWithIdentifier:(NSString *)identifier {
    NSString *resolvedIdentifier = identifier.length > 0 ? identifier : kSPKAppIconPrimaryIdentifier;
    for (SPKAppIconItem *item in [self availableAppIcons]) {
        if ([item.identifier isEqualToString:resolvedIdentifier]) {
            return item;
        }
    }
    return nil;
}

+ (NSArray<UIImage *> *)appearancePreviewImagesForAppIcon:(SPKAppIconItem *)item {
    if (item.isPrimary || item.identifier.length == 0)
        return nil;

    // The default preview carries a light and a dark variant; pull both out
    // explicitly instead of letting the current appearance pick one.
    NSString *base = [@"SPKAppIconPreview-" stringByAppendingString:item.identifier];
    UIImage *image = SPKAppIconImageNamed(base);
    if (!image.imageAsset)
        return nil;
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    for (NSNumber *style in @[ @(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark) ]) {
        UITraitCollection *traits = [UITraitCollection traitCollectionWithTraitsFromCollections:@[
            UIScreen.mainScreen.traitCollection,
            [UITraitCollection traitCollectionWithUserInterfaceStyle:style.integerValue]
        ]];
        UIImage *variant = [image.imageAsset imageWithTraitCollection:traits];
        if (!variant.CGImage)
            return nil;
        // Rewrap the bitmap: an image still tied to its asset is re-resolved
        // by the image view for the current appearance.
        [images addObject:[UIImage imageWithCGImage:variant.CGImage scale:variant.scale orientation:variant.imageOrientation]];
    }

    // The clear look stays tied to its asset so it follows the appearance.
    UIImage *clear = SPKAppIconImageNamed([base stringByAppendingString:@"-Clear"]);
    if (!clear)
        return nil;
    [images addObject:clear];
    return images;
}

+ (UIImage *)imageForAppIcon:(SPKAppIconItem *)item {
    // Icon Composer icons are icon stacks, which UIImage cannot load; the build
    // renders an appearance-aware preview beside each one.
    if (!item.isPrimary) {
        UIImage *preview = SPKAppIconImageNamed([@"SPKAppIconPreview-" stringByAppendingString:item.identifier]);
        if (preview)
            return preview;
    }

    NSArray *files = item.iconFiles;
    for (NSString *file in [files reverseObjectEnumerator]) {
        UIImage *image = SPKAppIconImageNamed(file);
        if (image)
            return image;
    }

    if (item.isPrimary) {
        for (NSString *fallback in @[ @"Prod", @"Prod60x60", @"Icon-60-Prod" ]) {
            UIImage *image = SPKAppIconImageNamed(fallback);
            if (image)
                return image;
        }
    }

    return nil;
}

@end
