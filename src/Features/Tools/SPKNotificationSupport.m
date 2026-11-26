#import "SPKNotificationSupport.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>

#import "../../Shared/i18n/SPKStrings.h"

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static NSString *const kSPKInstagramBundleID = @"com.burbn.instagram";
// Team prefix of Instagram's own App Store signature.
static NSString *const kSPKInstagramTeamPrefix = @"MH9GU9K5PX.";
static NSString *const kSPKSideloadFixImageName = @"SPKSideloadFix";
static NSString *const kSPKNotificationExtensionPath = @"PlugIns/InstagramNotificationExtension.appex/InstagramNotificationExtension";

static NSString *const kSPKEntAppID = @"application-identifier";
static NSString *const kSPKEntPush = @"aps-environment";
static NSString *const kSPKEntGroups = @"com.apple.security.application-groups";
static NSString *const kSPKEntKeychain = @"keychain-access-groups";
static NSString *const kSPKEntCommunication = @"com.apple.developer.usernotifications.communication";

static NSArray<NSString *> *SPKInstagramAppGroups(void) {
    return @[ @"group.com.burbn.instagram", @"group.com.facebook.family" ];
}

#pragma mark - Model

@implementation SPKNotificationCheckItem
@end

@implementation SPKNotificationCheckSection
@end

@implementation SPKNotificationSupportReport

- (NSString *)plainTextReport {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:self.verdictTitle];
    [lines addObject:self.verdictDetail];
    if (self.fix.length)
        [lines addObject:self.fix];
    for (SPKNotificationCheckSection *section in self.sections) {
        [lines addObject:@""];
        [lines addObject:[NSString stringWithFormat:@"[%@]", section.title]];
        for (SPKNotificationCheckItem *item in section.items) {
            if (item.privateValue)
                continue;
            NSString *mark = @"";
            switch (item.status) {
            case SPKNotificationCheckStatusPass: mark = @"OK"; break;
            case SPKNotificationCheckStatusWarn: mark = @"WARN"; break;
            case SPKNotificationCheckStatusFail: mark = @"FAIL"; break;
            case SPKNotificationCheckStatusInfo: mark = @"INFO"; break;
            }
            if (item.muted)
                mark = [mark stringByAppendingString:@" (follows)"];
            NSString *line = [NSString stringWithFormat:@"%@ %@: %@", mark, item.title, item.reportValue ?: item.value];
            if (item.note.length)
                line = [line stringByAppendingFormat:@" (%@)", item.note];
            [lines addObject:line];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end

#pragma mark - Code signature reader

// What an executable on disk was signed with, read straight from its load
// commands and embedded signature. The running process's own entitlements come
// from the kernel instead; this is what reaches the notification extension,
// which is a separate process the app cannot ask.
@interface SPKSignedImageInfo : NSObject
@property (nonatomic) BOOL exists;
@property (nonatomic) BOOL encrypted;
@property (nonatomic) BOOL hasCMSSignature;
/// Subject of the signing certificate, e.g. "iPhone Distribution: Name (TEAM)".
@property (nonatomic, copy, nullable) NSString *signerSummary;
@property (nonatomic, copy) NSDictionary *entitlements;
@property (nonatomic, copy) NSArray<NSString *> *linkedImageNames;
@end

@implementation SPKSignedImageInfo
@end

static NSData *SPKReadFileRange(NSFileHandle *handle, uint64_t offset, uint64_t length) {
    // Signatures and load commands are small; anything larger is a bad offset.
    if (length == 0 || length > 16 * 1024 * 1024)
        return nil;
    NSError *error = nil;
    if (![handle seekToOffset:offset error:&error])
        return nil;
    NSData *data = [handle readDataUpToLength:(NSUInteger)length error:&error];
    return data.length == length ? data : nil;
}

static uint32_t SPKBigEndian32(const uint8_t *bytes) {
    return OSSwapBigToHostInt32(*(const uint32_t *)bytes);
}

/// Offset of the arm64 slice, 0 for a thin binary. Returns NO when the file is
/// fat but has no arm64 slice.
static BOOL SPKArm64SliceOffset(NSFileHandle *handle, uint64_t *outOffset) {
    NSData *head = SPKReadFileRange(handle, 0, 8);
    if (!head)
        return NO;
    uint32_t magic = SPKBigEndian32(head.bytes);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) {
        *outOffset = 0;
        return YES;
    }
    BOOL wide = magic == FAT_MAGIC_64;
    uint32_t count = MIN(SPKBigEndian32((const uint8_t *)head.bytes + 4), 16u);
    size_t entrySize = wide ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
    NSData *table = SPKReadFileRange(handle, 8, entrySize * count);
    if (!table)
        return NO;
    const uint8_t *bytes = table.bytes;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *entry = bytes + i * entrySize;
        if ((cpu_type_t)SPKBigEndian32(entry) != CPU_TYPE_ARM64)
            continue;
        *outOffset = wide ? OSSwapBigToHostInt64(*(const uint64_t *)(entry + 8)) : SPKBigEndian32(entry + 8);
        return YES;
    }
    return NO;
}

static BOOL SPKIsDistributionSigner(NSString *summary) {
    return [summary hasPrefix:@"iPhone Distribution:"] || [summary hasPrefix:@"Apple Distribution:"];
}

static BOOL SPKIsDevelopmentSigner(NSString *summary) {
    return [summary hasPrefix:@"iPhone Developer:"] || [summary hasPrefix:@"Apple Development:"];
}

/// The leaf certificate among those carried in the CMS signature. The envelope
/// also holds Apple's intermediate and root, so the first certificate that
/// parses is not necessarily the signer's.
static NSString *SPKSignerSummary(NSData *cms) {
    const uint8_t *bytes = cms.bytes;
    NSUInteger length = cms.length;
    for (NSUInteger i = 0; i + 4 <= length; i++) {
        if (bytes[i] != 0x30 || bytes[i + 1] != 0x82) // DER SEQUENCE, two-byte length
            continue;
        NSUInteger total = 4 + (((NSUInteger)bytes[i + 2] << 8) | bytes[i + 3]);
        if (total < 256 || i + total > length)
            continue;
        SecCertificateRef certificate = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)[cms subdataWithRange:NSMakeRange(i, total)]);
        if (!certificate)
            continue;
        NSString *summary = CFBridgingRelease(SecCertificateCopySubjectSummary(certificate));
        CFRelease(certificate);
        if (SPKIsDistributionSigner(summary) || SPKIsDevelopmentSigner(summary) || [summary hasPrefix:@"Apple iPhone OS"])
            return summary;
        i += total - 1; // skip the certificate's contents
    }
    return nil;
}

static void SPKReadSignatureBlob(NSFileHandle *handle, uint64_t offset, uint32_t size, SPKSignedImageInfo *info) {
    NSData *blob = SPKReadFileRange(handle, offset, size);
    if (blob.length < 12)
        return;
    const uint8_t *bytes = blob.bytes;
    if (SPKBigEndian32(bytes) != 0xfade0cc0) // embedded signature super-blob
        return;
    uint32_t count = MIN(SPKBigEndian32(bytes + 8), 64u);
    for (uint32_t i = 0; i < count; i++) {
        size_t indexOffset = 12 + (size_t)i * 8;
        if (indexOffset + 8 > blob.length)
            break;
        uint32_t slot = SPKBigEndian32(bytes + indexOffset);
        uint32_t blobOffset = SPKBigEndian32(bytes + indexOffset + 4);
        if ((uint64_t)blobOffset + 8 > blob.length)
            continue;
        uint32_t blobMagic = SPKBigEndian32(bytes + blobOffset);
        uint32_t blobLength = SPKBigEndian32(bytes + blobOffset + 4);
        if (blobLength < 8 || (uint64_t)blobOffset + blobLength > blob.length)
            continue;
        if (slot == 5 && blobMagic == 0xfade7171) { // XML entitlements
            NSData *plist = [blob subdataWithRange:NSMakeRange(blobOffset + 8, blobLength - 8)];
            id value = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
            if ([value isKindOfClass:[NSDictionary class]])
                info.entitlements = value;
        } else if (slot == 0x10000 && blobMagic == 0xfade0b01) { // CMS wrapper
            // ldid leaves an empty wrapper when it signs without a certificate.
            info.hasCMSSignature = blobLength > 8;
            if (info.hasCMSSignature)
                info.signerSummary = SPKSignerSummary([blob subdataWithRange:NSMakeRange(blobOffset + 8, blobLength - 8)]);
        }
    }
}

static SPKSignedImageInfo *SPKReadSignedImage(NSString *path) {
    SPKSignedImageInfo *info = [SPKSignedImageInfo new];
    info.entitlements = @{};
    info.linkedImageNames = @[];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle)
        return info;
    info.exists = YES;

    @try {
        uint64_t slice = 0;
        if (!SPKArm64SliceOffset(handle, &slice))
            return info;
        NSData *headerData = SPKReadFileRange(handle, slice, sizeof(struct mach_header_64));
        if (!headerData)
            return info;
        const struct mach_header_64 *header = headerData.bytes;
        if (header->magic != MH_MAGIC_64)
            return info;
        NSData *commands = SPKReadFileRange(handle, slice + sizeof(struct mach_header_64), header->sizeofcmds);
        if (!commands)
            return info;

        NSMutableArray<NSString *> *names = [NSMutableArray array];
        const uint8_t *cursor = commands.bytes;
        const uint8_t *end = cursor + commands.length;
        for (uint32_t i = 0; i < header->ncmds && cursor + sizeof(struct load_command) <= end; i++) {
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > end)
                break;
            switch (command->cmd) {
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB:
            case LC_LAZY_LOAD_DYLIB: {
                const struct dylib_command *dylib = (const struct dylib_command *)command;
                uint32_t nameOffset = dylib->dylib.name.offset;
                if (nameOffset < command->cmdsize) {
                    const char *name = (const char *)cursor + nameOffset;
                    size_t length = strnlen(name, command->cmdsize - nameOffset);
                    NSString *path = [[NSString alloc] initWithBytes:name length:length encoding:NSUTF8StringEncoding];
                    if (path.lastPathComponent.length)
                        [names addObject:path.lastPathComponent];
                }
                break;
            }
            case LC_ENCRYPTION_INFO_64: {
                if (command->cmdsize >= sizeof(struct encryption_info_command_64))
                    info.encrypted = ((const struct encryption_info_command_64 *)command)->cryptid != 0;
                break;
            }
            case LC_CODE_SIGNATURE: {
                const struct linkedit_data_command *signature = (const struct linkedit_data_command *)command;
                SPKReadSignatureBlob(handle, slice + signature->dataoff, signature->datasize, info);
                break;
            }
            default:
                break;
            }
            cursor += command->cmdsize;
        }
        info.linkedImageNames = names;
    } @catch (__unused NSException *exception) {
    } @finally {
        [handle closeFile];
    }
    return info;
}

#pragma mark - Install facts

static NSDictionary *SPKProvisioningProfile(NSString *bundlePath) {
    NSData *data = [NSData dataWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (!data.length)
        return nil;
    // The profile is a CMS envelope around a plain XML plist.
    NSRange start = [data rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)];
    NSRange end = [data rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (start.location == NSNotFound || end.location == NSNotFound || NSMaxRange(end) <= start.location)
        return nil;
    NSData *plist = [data subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
    id value = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSDictionary *SPKRunningEntitlements(void) {
    NSMutableDictionary *entitlements = [NSMutableDictionary dictionary];
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task)
        return entitlements;
    for (NSString *key in @[ kSPKEntAppID, kSPKEntPush, kSPKEntGroups, kSPKEntKeychain, kSPKEntCommunication ]) {
        id value = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL));
        if (value)
            entitlements[key] = value;
    }
    CFRelease(task);
    return entitlements;
}

static NSString *SPKString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray<NSString *> *SPKStringArray(id value) {
    if (![value isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (id item in value)
        if ([item isKindOfClass:[NSString class]])
            [strings addObject:item];
    return strings;
}

/// The keychain group the app's login lives in: the first concrete group, or
/// the application identifier when there is none.
static NSString *SPKPrimaryKeychainGroup(NSDictionary *entitlements) {
    for (NSString *group in SPKStringArray(entitlements[kSPKEntKeychain])) {
        if ([group hasSuffix:@"*"] || [group isEqualToString:@"com.apple.token"])
            continue;
        return group;
    }
    return SPKString(entitlements[kSPKEntAppID]);
}

static BOOL SPKSideloadFixLoadedInProcess(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, kSPKSideloadFixImageName.UTF8String))
            return YES;
    }
    return NO;
}

static BOOL SPKImageListContainsSideloadFix(NSArray<NSString *> *names) {
    for (NSString *name in names)
        if ([name hasPrefix:kSPKSideloadFixImageName])
            return YES;
    return NO;
}

// LiveContainer runs a guest app inside its own process: it points
// NSBundle.mainBundle at the guest bundle and keeps its own bundle reachable
// through +[NSUserDefaults lcMainBundle]. The process keeps LiveContainer's
// signature, so APNs knows this install only by LiveContainer's identifier.
static NSBundle *SPKLiveContainerHostBundle(void) {
    SEL selector = NSSelectorFromString(@"lcMainBundle");
    if (![NSUserDefaults respondsToSelector:selector])
        return nil;
    NSBundle *(*getter)(id, SEL) = (NSBundle * (*)(id, SEL))[NSUserDefaults methodForSelector:selector];
    NSBundle *host = getter(NSUserDefaults.class, selector);
    if (![host isKindOfClass:[NSBundle class]] || [host.bundlePath isEqualToString:NSBundle.mainBundle.bundlePath])
        return nil;
    return host;
}

static BOOL SPKIsLiveContainerGuest(NSString *bundlePath) {
    return SPKLiveContainerHostBundle() != nil || getenv("LC_HOME_PATH") != NULL ||
           [bundlePath containsString:@"/Documents/Applications/"];
}

/// The identifier the process is really signed as, without its team prefix.
static NSString *SPKSignedBundleID(NSDictionary *entitlements) {
    NSString *applicationID = [entitlements[@"application-identifier"] isKindOfClass:[NSString class]] ? entitlements[@"application-identifier"] : nil;
    NSRange dot = [applicationID rangeOfString:@"."];
    return dot.location == NSNotFound ? nil : [applicationID substringFromIndex:NSMaxRange(dot)];
}

static BOOL SPKIsTrollStoreInstall(NSString *bundlePath) {
    NSString *container = bundlePath.stringByDeletingLastPathComponent;
    NSFileManager *files = NSFileManager.defaultManager;
    return [files fileExistsAtPath:[container stringByAppendingPathComponent:@"_TrollStore"]] ||
           [files fileExistsAtPath:[container stringByAppendingPathComponent:@"_TrollStoreLite"]];
}

#pragma mark - Checks

static SPKNotificationCheckItem *SPKItem(NSString *identifier, NSString *title, NSString *value, NSString *note, SPKNotificationCheckStatus status) {
    SPKNotificationCheckItem *item = [SPKNotificationCheckItem new];
    item.identifier = identifier;
    item.title = title;
    item.value = value ?: @"";
    item.note = note;
    item.status = status;
    return item;
}

static SPKNotificationCheckSection *SPKSection(NSString *title, NSArray<SPKNotificationCheckItem *> *items) {
    SPKNotificationCheckSection *section = [SPKNotificationCheckSection new];
    section.title = title;
    section.items = items;
    return section;
}

@implementation SPKNotificationSupport

+ (NSString *)installBundleIdentifier {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (SPKIsLiveContainerGuest(bundlePath)) {
        NSString *signedID = SPKSignedBundleID(SPKRunningEntitlements()) ?: SPKLiveContainerHostBundle().bundleIdentifier;
        if (signedID.length)
            return signedID;
    }
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    return SPKString(infoPlist[@"CFBundleIdentifier"]) ?: NSBundle.mainBundle.bundleIdentifier ?: @"";
}

+ (void)runWithCompletion:(void (^)(SPKNotificationSupportReport *report))completion {
    BOOL registered = UIApplication.sharedApplication.isRegisteredForRemoteNotifications;
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SPKNotificationSupportReport *report = [self reportWithSettings:settings registered:registered];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(report);
            });
        });
    }];
}

+ (SPKNotificationSupportReport *)reportWithSettings:(UNNotificationSettings *)settings registered:(BOOL)registered {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    // APNs addresses the identifier the install really has, not the one the
    // sideload fix reports at runtime.
    NSString *bundleID = [self installBundleIdentifier];

    SPKSignedImageInfo *app = SPKReadSignedImage(NSBundle.mainBundle.executablePath);
    NSMutableDictionary *appEntitlements = [app.entitlements mutableCopy];
    [appEntitlements addEntriesFromDictionary:SPKRunningEntitlements()];
    SPKSignedImageInfo *extension = SPKReadSignedImage([bundlePath stringByAppendingPathComponent:kSPKNotificationExtensionPath]);
    NSDictionary *profile = SPKProvisioningProfile(bundlePath);

    BOOL liveContainer = SPKIsLiveContainerGuest(bundlePath);
    BOOL originalSignature = [SPKString(appEntitlements[kSPKEntAppID]) hasPrefix:kSPKInstagramTeamPrefix];

    // Signing
    NSMutableArray<SPKNotificationCheckItem *> *signing = [NSMutableArray array];
    NSString *installValue;
    BOOL developmentSigned = NO;
    BOOL missingProfile = NO;
    NSDictionary *profileEntitlements = [profile[@"Entitlements"] isKindOfClass:[NSDictionary class]] ? profile[@"Entitlements"] : @{};
    if (liveContainer)
        installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_LIVECONTAINER_VALUE");
    else if (SPKIsTrollStoreInstall(bundlePath))
        installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_TROLLSTORE_VALUE");
    else if (originalSignature || (app.encrypted && !profile))
        installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_APP_STORE_VALUE");
    else if (profile) {
        if ([profile[@"ProvisionsAllDevices"] boolValue])
            installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_ENTERPRISE_VALUE");
        else if ([profileEntitlements[@"get-task-allow"] boolValue]) {
            installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_DEVELOPMENT_VALUE");
            developmentSigned = YES;
        } else if (profile[@"ProvisionedDevices"])
            installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_AD_HOC_VALUE");
        else
            installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_DISTRIBUTION_VALUE");
    } else if (app.hasCMSSignature) {
        // Some signers drop the provisioning profile, so the certificate, or
        // failing that the signed entitlements, tells distribution from development.
        missingProfile = YES;
        if (SPKIsDistributionSigner(app.signerSummary))
            developmentSigned = NO;
        else if (SPKIsDevelopmentSigner(app.signerSummary))
            developmentSigned = YES;
        else
            developmentSigned = [app.entitlements[@"get-task-allow"] boolValue];
        installValue = developmentSigned ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_DEVELOPMENT_VALUE") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_DISTRIBUTION_VALUE");
    } else
        installValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_FAKE_SIGNED_VALUE");
    // Every distribution signature reaches Instagram's production pushes; a
    // development one or LiveContainer's identity never does. Installs that
    // keep the entitlements as they are depend on the Push Entitlement row.
    SPKNotificationCheckStatus installStatus = SPKNotificationCheckStatusPass;
    if (liveContainer || developmentSigned)
        installStatus = SPKNotificationCheckStatusFail;
    else if (!app.hasCMSSignature && !originalSignature && !SPKIsTrollStoreInstall(bundlePath))
        installStatus = SPKNotificationCheckStatusInfo;
    [signing addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_TITLE"), installValue,
                               developmentSigned ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_DEVELOPMENT_NOTE") : nil, installStatus)];

    if (profile || missingProfile) {
        NSDate *expiry = [profile[@"ExpirationDate"] isKindOfClass:[NSDate class]] ? profile[@"ExpirationDate"] : nil;
        NSString *owner = app.signerSummary ?: SPKString(profile[@"TeamName"]) ?: SPKString(profile[@"Name"]) ?: SPKL(@"TOOLS_NOTIFICATION_SUPPORT_UNKNOWN_VALUE");
        SPKNotificationCheckItem *ownerItem = SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_CERTIFICATE_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_CERTIFICATE_TITLE"), owner, nil, SPKNotificationCheckStatusInfo);
        ownerItem.privateValue = YES;
        [signing addObject:ownerItem];
        if (missingProfile)
            [signing addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_PROFILE_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PROFILE_TITLE"),
                                       SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PROFILE_REMOVED_VALUE"), nil, SPKNotificationCheckStatusInfo)];
        if (expiry) {
            BOOL expired = expiry.timeIntervalSinceNow < 0;
            NSString *date = [NSDateFormatter localizedStringFromDate:expiry dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
            [signing addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_EXPIRES_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXPIRES_TITLE"), date,
                                       expired ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXPIRES_PAST_NOTE") : nil,
                                       expired ? SPKNotificationCheckStatusWarn : SPKNotificationCheckStatusInfo)];
        }
    }

    BOOL originalBundleID = !liveContainer && [bundleID isEqualToString:kSPKInstagramBundleID];
    NSString *bundleIDNote = nil;
    if (liveContainer)
        bundleIDNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_LIVECONTAINER_NOTE");
    else if (!originalBundleID)
        bundleIDNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_CUSTOM_NOTE");
    [signing addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_TITLE"), bundleID, bundleIDNote,
                               originalBundleID ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusFail)];

    NSString *pushEnvironment = SPKString(appEntitlements[kSPKEntPush]);
    BOOL productionPush = [pushEnvironment isEqualToString:@"production"];
    NSString *pushNote = nil;
    if (!pushEnvironment.length)
        pushNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PUSH_MISSING_NOTE");
    else if (!productionPush)
        pushNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PUSH_DEVELOPMENT_NOTE");
    [signing addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_PUSH_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PUSH_TITLE"),
                               pushEnvironment.length ? pushEnvironment.capitalizedString : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NONE_VALUE"),
                               pushNote, productionPush ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusFail)];

    // Notifications
    NSMutableArray<SPKNotificationCheckItem *> *notifications = [NSMutableArray array];
    UNAuthorizationStatus authorization = settings.authorizationStatus;
    BOOL allowed = authorization == UNAuthorizationStatusAuthorized || authorization == UNAuthorizationStatusProvisional ||
                   authorization == UNAuthorizationStatusEphemeral;
    NSString *permissionValue = allowed ? SPKL(@"MENU_ON")
                                        : (authorization == UNAuthorizationStatusNotDetermined ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_NOT_ASKED_VALUE") : SPKL(@"MENU_OFF"));
    [notifications addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_TITLE"), permissionValue,
                                     allowed ? nil : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_OFF_NOTE"),
                                     allowed ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusFail)];
    if (allowed) {
        UNShowPreviewsSetting previews = settings.showPreviewsSetting;
        NSString *previewsValue = previews == UNShowPreviewsSettingAlways ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_ALWAYS_VALUE")
                                 : previews == UNShowPreviewsSettingWhenAuthenticated ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_UNLOCKED_VALUE")
                                                                                      : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_NEVER_VALUE");
        [notifications addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_TITLE"), previewsValue,
                                         previews == UNShowPreviewsSettingNever ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_PREVIEWS_NEVER_NOTE") : nil,
                                         previews == UNShowPreviewsSettingNever ? SPKNotificationCheckStatusWarn : SPKNotificationCheckStatusPass)];
    }
    [notifications addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_REGISTERED_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_REGISTERED_TITLE"),
                                     (registered ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_YES_VALUE") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NO_VALUE")),
                                     registered ? nil : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_REGISTERED_NO_NOTE"),
                                     registered ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusWarn)];
    BOOL communication = [appEntitlements[kSPKEntCommunication] boolValue];
    [notifications addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_SENDER_PHOTOS_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SENDER_PHOTOS_TITLE"),
                                     (communication ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_YES_VALUE") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NO_VALUE")),
                                     communication ? nil : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SENDER_PHOTOS_NO_NOTE"),
                                     communication ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusWarn)];

    // Notification extension
    NSMutableArray<SPKNotificationCheckItem *> *extensionItems = [NSMutableArray array];
    BOOL extensionReady = NO;
    BOOL groupsReady = NO;
    BOOL fixReady = NO;
    if (liveContainer) {
        // The guest's extensions are copied along but never registered with iOS.
        [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE"), SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_NOT_USED_VALUE"),
                                          SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_LIVECONTAINER_NOTE"), SPKNotificationCheckStatusInfo)];
    } else if (!extension.exists) {
        [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE"), SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_MISSING_VALUE"),
                                          SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_MISSING_NOTE"), SPKNotificationCheckStatusFail)];
    } else {
        extensionReady = YES;
        [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_TITLE"), SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_PRESENT_VALUE"),
                                          nil, SPKNotificationCheckStatusPass)];

        NSArray<NSString *> *appGroups = SPKStringArray(appEntitlements[kSPKEntGroups]);
        NSArray<NSString *> *extensionGroups = SPKStringArray(extension.entitlements[kSPKEntGroups]);
        NSSet *instagramGroups = [NSSet setWithArray:SPKInstagramAppGroups()];
        BOOL keepsInstagramGroups = [instagramGroups isSubsetOfSet:[NSSet setWithArray:appGroups]] &&
                                    [instagramGroups isSubsetOfSet:[NSSet setWithArray:extensionGroups]];
        BOOL fixInApp = SPKSideloadFixLoadedInProcess() || SPKImageListContainsSideloadFix(app.linkedImageNames);
        BOOL fixInExtension = SPKImageListContainsSideloadFix(extension.linkedImageNames);
        // Without the sideload fix both processes open Instagram's own groups by
        // name. With it, every group is redirected into the first one each side
        // is signed with, so those first groups must be the same.
        BOOL nativeGroups = keepsInstagramGroups && !fixInApp && !fixInExtension;
        NSString *sharedGroup = nil;
        NSString *groupsNote = nil;
        if (nativeGroups) {
            sharedGroup = SPKInstagramAppGroups().firstObject;
        } else if (originalSignature) {
            groupsNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_ORIGINAL_MISSING_NOTE");
        } else if (!appGroups.count) {
            groupsNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_APP_NONE_NOTE");
        } else if (!extensionGroups.count) {
            groupsNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_EXTENSION_NONE_NOTE");
        } else if ([appGroups.firstObject isEqualToString:extensionGroups.firstObject]) {
            sharedGroup = appGroups.firstObject;
        } else {
            groupsNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_MISMATCH_NOTE");
        }
        groupsReady = sharedGroup != nil;
        // The group name can carry the signer's team ID, so the copied report
        // only says whether one is shared.
        SPKNotificationCheckItem *groupsItem = SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_TITLE"),
                                                       sharedGroup ?: SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_NOT_SHARED_VALUE"), groupsNote,
                                                       groupsReady ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusFail);
        if (groupsReady)
            groupsItem.reportValue = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_GROUPS_SHARED_VALUE");
        [extensionItems addObject:groupsItem];

        NSString *appKeychain = SPKPrimaryKeychainGroup(appEntitlements);
        NSString *extensionKeychain = SPKPrimaryKeychainGroup(extension.entitlements);
        BOOL sharedLogin = appKeychain.length && [appKeychain isEqualToString:extensionKeychain];
        [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_SHARED_LOGIN_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SHARED_LOGIN_TITLE"),
                                          (sharedLogin ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_YES_VALUE") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NO_VALUE")),
                                          sharedLogin ? nil : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SHARED_LOGIN_NO_NOTE"),
                                          sharedLogin ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusWarn)];

        // With Instagram's own groups both processes already reach the real
        // shared container, so nothing needs redirecting.
        if (originalSignature || nativeGroups) {
            fixReady = YES;
            [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_TITLE"),
                                              SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_NOT_NEEDED_VALUE"), nil, SPKNotificationCheckStatusInfo)];
        } else {
            BOOL inApp = fixInApp;
            BOOL inExtension = fixInExtension;
            fixReady = inApp && inExtension;
            NSString *fixNote = nil;
            if (!inExtension)
                fixNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_EXTENSION_MISSING_NOTE");
            else if (!inApp)
                fixNote = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_APP_MISSING_NOTE");
            [extensionItems addObject:SPKItem(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_TITLE", SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_TITLE"),
                                              (fixReady ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_ACTIVE_VALUE") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIDELOAD_FIX_MISSING_VALUE")),
                                              fixNote, fixReady ? SPKNotificationCheckStatusPass : SPKNotificationCheckStatusFail)];
        }
    }

    SPKNotificationSupportReport *report = [SPKNotificationSupportReport new];
    report.sections = @[
        SPKSection(SPKL(@"TOOLS_NOTIFICATION_SUPPORT_SIGNING_HEADER"), signing),
        SPKSection(SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NOTIFICATIONS_HEADER"), notifications),
        SPKSection(SPKL(@"TOOLS_NOTIFICATION_SUPPORT_EXTENSION_HEADER"), extensionItems),
    ];

    // Verdict. Pushes need all four of these; the extension decides how much of
    // each notification survives.
    // The checks that explain the verdict. When pushes cannot arrive at all,
    // every other problem is a consequence and loses its own warning.
    NSSet<NSString *> *rootCauses = nil;
    NSString *noneFix = nil;
    if (liveContainer) {
        noneFix = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_LIVECONTAINER");
        rootCauses = [NSSet setWithObjects:@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_TITLE", @"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_TITLE", nil];
    } else if (!originalBundleID) {
        noneFix = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_BUNDLE_ID");
        rootCauses = [NSSet setWithObject:@"TOOLS_NOTIFICATION_SUPPORT_BUNDLE_ID_TITLE"];
    } else if (!productionPush || developmentSigned) {
        noneFix = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_CERTIFICATE");
        rootCauses = [NSSet setWithObjects:@"TOOLS_NOTIFICATION_SUPPORT_INSTALL_TITLE", @"TOOLS_NOTIFICATION_SUPPORT_PUSH_TITLE", nil];
    } else if (!allowed) {
        noneFix = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_PERMISSION");
        rootCauses = [NSSet setWithObject:@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_TITLE"];
    }
    // iOS Settings only helps once nothing earlier already rules pushes out.
    report.permissionNeedsAttention = !allowed && (!rootCauses || [rootCauses containsObject:@"TOOLS_NOTIFICATION_SUPPORT_PERMISSION_TITLE"]);
    for (SPKNotificationCheckSection *section in report.sections) {
        for (SPKNotificationCheckItem *item in section.items) {
            BOOL problem = item.status == SPKNotificationCheckStatusFail || item.status == SPKNotificationCheckStatusWarn;
            item.muted = rootCauses && problem && ![rootCauses containsObject:item.identifier];
        }
    }

    if (noneFix) {
        report.level = SPKNotificationSupportLevelNone;
        report.verdictTitle = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_NONE_TITLE");
        report.verdictDetail = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_NONE_DETAIL");
        report.fix = noneFix;
    } else if (!extensionReady) {
        report.level = SPKNotificationSupportLevelPartial;
        report.verdictTitle = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_PARTIAL_TITLE");
        report.verdictDetail = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_NO_EXTENSION_DETAIL");
        report.fix = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_EXTENSION");
    } else if (!groupsReady || !fixReady) {
        report.level = SPKNotificationSupportLevelPartial;
        report.verdictTitle = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_PARTIAL_TITLE");
        report.verdictDetail = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_GENERIC_DETAIL");
        report.fix = (groupsReady ? SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_SIDELOAD_FIX") : SPKL(@"TOOLS_NOTIFICATION_SUPPORT_FIX_APP_GROUPS"));
    } else {
        report.level = SPKNotificationSupportLevelFull;
        report.verdictTitle = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_FULL_TITLE");
        report.verdictDetail = SPKL(@"TOOLS_NOTIFICATION_SUPPORT_VERDICT_FULL_DETAIL");
    }
    return report;
}

@end
