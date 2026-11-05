#import "SPKStrings.h"
#import "SPKFlexLoader.h"

#import <dlfcn.h>
#import <objc/message.h>

#import "../Utils.h"

FOUNDATION_EXPORT void SPKInstallFlexLoadedCompatibilityHooksIfNeeded(void);

static void *sSPKFlexHandle = NULL;
static id (*sSPKFlexGetManager)(void) = NULL;
static SEL (*sSPKFlexRevealSEL)(void) = NULL;
static Class (*sSPKFlexWindowClassGetter)(void) = NULL;
static id sSPKFlexManager = nil;
static SEL sSPKFlexShowSelector = NULL;
static NSString *sSPKFlexLoadedPath = nil;
static NSString *sSPKFlexLoadError = nil;
static NSTimeInterval sSPKFlexLastShowAttempt = 0.0;
static NSString *sSPKFlexLastShowTrigger = nil;

static dispatch_queue_t SPKFlexLoaderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.sparkle.flex-loader", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void SPKAppendFlexPath(NSMutableArray<NSString *> *paths, NSString *path) {
    if (path.length == 0) {
        return;
    }

    if (![paths containsObject:path]) {
        [paths addObject:path];
    }
}

static NSString *SPKDylibDirectory(void) {
    Dl_info info;
    if (dladdr((void *)SPKDylibDirectory, &info) && info.dli_fname) {
        return [@(info.dli_fname) stringByDeletingLastPathComponent];
    }
    return nil;
}

static void SPKAppendLiveContainerApplicationFlexPaths(NSMutableArray<NSString *> *paths) {
    NSString *dylibDirectory = SPKDylibDirectory();
    if (dylibDirectory.length == 0) {
        return;
    }

    NSString *documentsPath = nil;
    NSRange tweaksRange = [dylibDirectory rangeOfString:@"/Documents/Tweaks/" options:NSBackwardsSearch];
    if (tweaksRange.location != NSNotFound) {
        documentsPath = [dylibDirectory substringToIndex:tweaksRange.location + @"/Documents".length];
    } else {
        NSRange documentsRange = [dylibDirectory rangeOfString:@"/Documents/" options:NSBackwardsSearch];
        if (documentsRange.location != NSNotFound) {
            documentsPath = [dylibDirectory substringToIndex:documentsRange.location + @"/Documents".length];
        }
    }

    if (documentsPath.length == 0) {
        return;
    }

    NSString *applicationsPath = [documentsPath stringByAppendingPathComponent:@"Applications"];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:applicationsPath error:nil];
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"app"]) {
            continue;
        }

        NSString *candidate = [[[applicationsPath stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:@"Frameworks"]
            stringByAppendingPathComponent:@"libFLEX.dylib"];
        SPKAppendFlexPath(paths, candidate);
    }
}

static NSArray<NSString *> *SPKFlexCandidatePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if (bundlePath.length > 0) {
        SPKAppendFlexPath(paths, [bundlePath stringByAppendingPathComponent:@"Frameworks/libFLEX.dylib"]);
    }

    NSString *executablePath = NSProcessInfo.processInfo.arguments.firstObject;
    NSString *executableDirectory = executablePath.stringByDeletingLastPathComponent;
    if (executableDirectory.length > 0) {
        SPKAppendFlexPath(paths, [executableDirectory stringByAppendingPathComponent:@"Frameworks/libFLEX.dylib"]);
    }

    NSString *dylibDirectory = SPKDylibDirectory();
    if (dylibDirectory.length > 0) {
        SPKAppendFlexPath(paths, [dylibDirectory stringByAppendingPathComponent:@"libFLEX.dylib"]);
        SPKAppendFlexPath(paths, [dylibDirectory stringByAppendingPathComponent:@"libflex.dylib"]);
    }

    SPKAppendLiveContainerApplicationFlexPaths(paths);

    // Jailbreak package locations.
    SPKAppendFlexPath(paths, @"/var/jb/Library/MobileSubstrate/DynamicLibraries/libFLEX.dylib");
    SPKAppendFlexPath(paths, @"/Library/MobileSubstrate/DynamicLibraries/libFLEX.dylib");

    return paths;
}

static NSString *SPKFlexBundledPath(void) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *path in SPKFlexCandidatePaths()) {
        if ([fileManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

BOOL SPKFlexIsBundled(void) {
    return SPKFlexBundledPath() != nil;
}

BOOL SPKFlexIsLoaded(void) {
    return sSPKFlexManager != nil && sSPKFlexShowSelector != NULL;
}

BOOL SPKFlexLoadIfNeeded(void) {
    if (SPKFlexIsLoaded()) {
        return YES;
    }

    NSString *path = SPKFlexBundledPath();
    if (path.length == 0) {
        sSPKFlexLoadError = SPKL(@"FLEX_ERROR_NOT_BUNDLED");
        SPKLog(@"FLEX", @"FLEX unavailable: %@", sSPKFlexLoadError);
        return NO;
    }

    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *error = dlerror();
        sSPKFlexLoadError = error ? @(error) : @"dlopen failed";
        SPKLog(@"FLEX", @"FLEX dlopen failed at %@: %@", path, sSPKFlexLoadError);
        return NO;
    }

    sSPKFlexHandle = handle;
    sSPKFlexGetManager = (id (*)(void))dlsym(handle, "FLXGetManager");
    sSPKFlexRevealSEL = (SEL (*)(void))dlsym(handle, "FLXRevealSEL");
    sSPKFlexWindowClassGetter = (Class (*)(void))dlsym(handle, "FLXWindowClass");

    if (!sSPKFlexGetManager || !sSPKFlexRevealSEL) {
        sSPKFlexLoadError = SPKL(@"FLEX_ERROR_SYMBOLS_NOT_EXPORTED");
        SPKLog(@"FLEX", @"FLEX symbol resolution failed at %@", path);
        return NO;
    }

    sSPKFlexManager = sSPKFlexGetManager();
    sSPKFlexShowSelector = sSPKFlexRevealSEL();
    sSPKFlexLoadedPath = path;
    sSPKFlexLoadError = nil;

    SPKInstallFlexLoadedCompatibilityHooksIfNeeded();

    SPKLog(@"FLEX", @"FLEX loaded lazily from %@", sSPKFlexLoadedPath);
    return SPKFlexIsLoaded();
}

Class SPKFlexWindowClass(void) {
    if (!SPKFlexIsLoaded() || !sSPKFlexWindowClassGetter) {
        return Nil;
    }
    return sSPKFlexWindowClassGetter();
}

static BOOL SPKFlexShouldSuppressDuplicateShow(NSString *trigger) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    BOOL duplicateLaunchFocus = [trigger isEqualToString:@"focus"] &&
                                [sSPKFlexLastShowTrigger isEqualToString:@"launch"] &&
                                now - sSPKFlexLastShowAttempt < 2.0;

    if (!duplicateLaunchFocus) {
        sSPKFlexLastShowAttempt = now;
        sSPKFlexLastShowTrigger = [trigger copy];
    }

    return duplicateLaunchFocus;
}

static void SPKFlexShowMissingPill(NSString *trigger) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *subtitle = SPKL(@"APP_FLEX_LOADER_REBUILD_FLEX_TEXT");
        if (sSPKFlexLoadError.length > 0 && ![sSPKFlexLoadError isEqualToString:@"libFLEX.dylib was not bundled"]) {
            subtitle = sSPKFlexLoadError;
        }

        SPKLog(@"FLEX", @"FLEX show requested by %@ but unavailable: %@", trigger, subtitle);
        SPKNotify(kSPKNotificationFlexUnavailable, SPKL(@"APP_FLEX_LOADER_FLEX_UNAVAILABLE_TEXT"), subtitle, @"warning_filled", SPKNotificationToneInfo);
    });
}

void SPKFlexShowExplorer(NSString *trigger) {
    NSString *showTrigger = trigger ?: @"unknown";
    if (SPKFlexShouldSuppressDuplicateShow(showTrigger)) {
        SPKLog(@"FLEX", @"Skipping duplicate FLEX show for trigger %@", showTrigger);
        return;
    }

    if (SPKFlexIsLoaded()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sSPKFlexManager && sSPKFlexShowSelector) {
                ((void (*)(id, SEL))objc_msgSend)(sSPKFlexManager, sSPKFlexShowSelector);
            }
        });
        return;
    }

    dispatch_async(SPKFlexLoaderQueue(), ^{
        if (!SPKFlexLoadIfNeeded()) {
            SPKFlexShowMissingPill(showTrigger);
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (sSPKFlexManager && sSPKFlexShowSelector) {
                ((void (*)(id, SEL))objc_msgSend)(sSPKFlexManager, sSPKFlexShowSelector);
            }
        });
    });
}
