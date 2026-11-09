#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"

// * Hold to pause reels
// Instagram is rolling out a long-press menu on reels from its servers: on
// accounts that have it, holding a reel opens the playback sheet from the more
// menu instead of pausing, after a longer press. Both are driven by one
// MobileConfig config, ig_reels_long_press_overflow_menu (config 121815):
//   param 0 (bool)   gates the menu in the reel's long-press handler.
//   param 2 (double) the press duration. When it is not positive, the reel cell
//                    takes its classic branch: a 0.15s hold and untouched tap
//                    timeouts, so a hold is instant and never reads as a tap.
// With the preference on Sparkle answers false and 0 for those two reads, which
// is exactly what an account outside the rollout sees, so the classic hold
// (pause, 2x on the sides, scrubbing) runs as Instagram's own code.
//
// Parameter IDs are reassigned on every build, but the config number and the
// parameter index are stable. Instagram ships a table that maps each pair to
// the build's ID (it uses it to migrate stored values across app updates), so
// the IDs are looked up there at launch. When the config or either parameter
// is missing or ambiguous nothing is hooked and Instagram stays stock.

static NSString *const kSPKReelsHoldPausePrefKey = @"reels_hold_to_pause";

static uint32_t const kSPKReelsHoldConfig = 121815;
static uint32_t const kSPKReelsHoldMenuGateIndex = 0;
static uint32_t const kSPKReelsHoldPressDurationIndex = 2;

enum : uint16_t {
    kSPKMCTypeBool = 1,
    kSPKMCTypeDouble = 4,
};

// Resolved full parameter IDs; 0 while unresolved.
static unsigned long long sSPKReelsHoldMenuGateParam = 0;
static unsigned long long sSPKReelsHoldPressDurationParam = 0;

// MARK: - Parameter table

// One 40-byte row per parameter:
//   u32 version, u32 flags, u32 version, u32 flags, u32 param index,
//   u16 group, u16 param index, u16 slot, u16 type, u32, u32, u32 config number.
// The config number ends the row (word 9), the specifier is words 5 and 6.
// The full ID that getBool: and friends take is
//   (0x80 | type) << 48 | group << 32 | param index << 16 | slot.
typedef struct {
    unsigned long long param;
    uint16_t type;
    uint16_t group;
    NSUInteger matches;
    BOOL conflict;
} SPKReelsHoldParamLookup;

static void SPKReelsHoldScanRows(const uint8_t *data, size_t size, SPKReelsHoldParamLookup *lookups,
                                 const uint32_t *indexes, size_t count) {
    if (!data || size < 40)
        return;
    const uint32_t *words = (const uint32_t *)data;
    size_t wordCount = size / sizeof(uint32_t);
    for (size_t k = 9; k < wordCount; k++) {
        if (words[k] != kSPKReelsHoldConfig)
            continue;
        const uint32_t *row = words + k - 9;
        if (row[0] != row[2])
            continue;
        uint32_t index = row[4];
        const uint16_t *specifier = (const uint16_t *)(row + 5);
        uint16_t group = specifier[0], rowIndex = specifier[1], slot = specifier[2], type = specifier[3];
        if (rowIndex != index || type < 1 || type > 4)
            continue;
        for (size_t i = 0; i < count; i++) {
            if (indexes[i] != index)
                continue;
            unsigned long long param = ((unsigned long long)(0x80 | type) << 48) |
                                       ((unsigned long long)group << 32) | ((unsigned long long)index << 16) | slot;
            if (lookups[i].matches && lookups[i].param != param)
                lookups[i].conflict = YES;
            lookups[i].param = param;
            lookups[i].type = type;
            lookups[i].group = group;
            lookups[i].matches++;
        }
    }
}

static void SPKReelsHoldResolveParams(void) {
    uint32_t const indexes[] = {kSPKReelsHoldMenuGateIndex, kSPKReelsHoldPressDurationIndex};
    SPKReelsHoldParamLookup lookups[2] = {};

    // The table ships in the shared framework; the main executable is scanned
    // too in case a build moves it.
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name)
            continue;
        BOOL isShared = strstr(name, "/FBSharedFramework.framework/FBSharedFramework") != NULL;
        BOOL isMain = i == 0 && strstr(name, ".app/") != NULL;
        if (!isShared && !isMain)
            continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        unsigned long size = 0;
        const uint8_t *data = getsectiondata(header, "__DATA_CONST", "__const", &size);
        SPKReelsHoldScanRows(data, size, lookups, indexes, 2);
        data = getsectiondata(header, "__TEXT", "__const", &size);
        SPKReelsHoldScanRows(data, size, lookups, indexes, 2);
    }

    SPKReelsHoldParamLookup gate = lookups[0], duration = lookups[1];
    BOOL valid = gate.matches && !gate.conflict && gate.type == kSPKMCTypeBool && duration.matches &&
                 !duration.conflict && duration.type == kSPKMCTypeDouble && gate.group == duration.group;
    if (!valid) {
        SPKLog(@"ReelsHold", @"Config %u not resolved (gate %lu%@, duration %lu%@); keeping Instagram's hold",
               kSPKReelsHoldConfig, (unsigned long)gate.matches, gate.conflict ? @" conflicting" : @"",
               (unsigned long)duration.matches, duration.conflict ? @" conflicting" : @"");
        return;
    }
    sSPKReelsHoldMenuGateParam = gate.param;
    sSPKReelsHoldPressDurationParam = duration.param;
    SPKLog(@"ReelsHold", @"Config %u: gate 0x%016llx, press duration 0x%016llx", kSPKReelsHoldConfig, gate.param,
           duration.param);
}

// MARK: - MobileConfig reads

// The parameter is compared first so the preference is read only for the two
// overridden parameters, never on the hot path of every other MobileConfig read.
static inline BOOL SPKReelsHoldOverridesBool(unsigned long long param) {
    return param == sSPKReelsHoldMenuGateParam && [SPKUtils getBoolPref:kSPKReelsHoldPausePrefKey];
}

static inline BOOL SPKReelsHoldOverridesDouble(unsigned long long param) {
    return param == sSPKReelsHoldPressDurationParam && [SPKUtils getBoolPref:kSPKReelsHoldPausePrefKey];
}

static BOOL SPKReelsHoldClassOwnsMethod(Class cls, SEL selector) {
    BOOL owns = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);
    return owns;
}

typedef NS_ENUM(NSInteger, SPKReelsHoldReadShape) {
    SPKReelsHoldReadShapePlain,              // getX:(param)
    SPKReelsHoldReadShapeDefault,            // getX:(param) withDefault:(value)
    SPKReelsHoldReadShapeOptions,            // getX:(param) withOptions:(options)
    SPKReelsHoldReadShapeOptionsAndDefault,  // getX:(param) withOptions:(options) withDefault:(value)
};

static id SPKReelsHoldBoolBlock(SPKReelsHoldReadShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKReelsHoldReadShapePlain:
        return ^BOOL(id self, unsigned long long param) {
            if (SPKReelsHoldOverridesBool(param))
                return NO;
            return ((BOOL (*)(id, SEL, unsigned long long))*orig)(self, sel, param);
        };
    case SPKReelsHoldReadShapeDefault:
        return ^BOOL(id self, unsigned long long param, BOOL fallback) {
            if (SPKReelsHoldOverridesBool(param))
                return NO;
            return ((BOOL (*)(id, SEL, unsigned long long, BOOL))*orig)(self, sel, param, fallback);
        };
    case SPKReelsHoldReadShapeOptions:
        return ^BOOL(id self, unsigned long long param, id options) {
            if (SPKReelsHoldOverridesBool(param))
                return NO;
            return ((BOOL (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options);
        };
    case SPKReelsHoldReadShapeOptionsAndDefault:
        return ^BOOL(id self, unsigned long long param, id options, BOOL fallback) {
            if (SPKReelsHoldOverridesBool(param))
                return NO;
            return ((BOOL (*)(id, SEL, unsigned long long, id, BOOL))*orig)(self, sel, param, options, fallback);
        };
    }
    return nil;
}

static id SPKReelsHoldDoubleBlock(SPKReelsHoldReadShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKReelsHoldReadShapePlain:
        return ^double(id self, unsigned long long param) {
            if (SPKReelsHoldOverridesDouble(param))
                return 0;
            return ((double (*)(id, SEL, unsigned long long))*orig)(self, sel, param);
        };
    case SPKReelsHoldReadShapeDefault:
        return ^double(id self, unsigned long long param, double fallback) {
            if (SPKReelsHoldOverridesDouble(param))
                return 0;
            return ((double (*)(id, SEL, unsigned long long, double))*orig)(self, sel, param, fallback);
        };
    case SPKReelsHoldReadShapeOptions:
        return ^double(id self, unsigned long long param, id options) {
            if (SPKReelsHoldOverridesDouble(param))
                return 0;
            return ((double (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options);
        };
    case SPKReelsHoldReadShapeOptionsAndDefault:
        return ^double(id self, unsigned long long param, id options, double fallback) {
            if (SPKReelsHoldOverridesDouble(param))
                return 0;
            return ((double (*)(id, SEL, unsigned long long, id, double))*orig)(self, sel, param, options, fallback);
        };
    }
    return nil;
}

// Every MobileConfig context class Instagram reads through, and every getter
// variant each one implements itself (an inherited one is covered by its
// superclass), so no read path sees the server value while another sees the
// override.
static void SPKReelsHoldInstallReadHooks(void) {
    NSArray<NSString *> *classNames = @[
        @"IGMobileConfigUserSessionContextManager",
        @"IGMobileConfigSessionlessContextManager",
        @"IGMobileConfigContextManager",
        @"FBMobileConfigUserSessionContextManager",
        @"FBMobileConfigSessionlessContextManager",
        @"FBMobileConfigContextManager",
        @"FBMobileConfigContextObjcImpl",
    ];
    struct {
        const char *selector;
        SPKReelsHoldReadShape shape;
        BOOL isDouble;
    } const getters[] = {
        {"getBool:", SPKReelsHoldReadShapePlain, NO},
        {"getBoolWithoutLogging:", SPKReelsHoldReadShapePlain, NO},
        {"getBool:withDefault:", SPKReelsHoldReadShapeDefault, NO},
        {"getBoolWithoutLogging:withDefault:", SPKReelsHoldReadShapeDefault, NO},
        {"getBool:withOptions:", SPKReelsHoldReadShapeOptions, NO},
        {"getBool:withOptions:withDefault:", SPKReelsHoldReadShapeOptionsAndDefault, NO},
        {"getDouble:", SPKReelsHoldReadShapePlain, YES},
        {"getDoubleWithoutLogging:", SPKReelsHoldReadShapePlain, YES},
        {"getDouble:withDefault:", SPKReelsHoldReadShapeDefault, YES},
        {"getDoubleWithoutLogging:withDefault:", SPKReelsHoldReadShapeDefault, YES},
        {"getDouble:withOptions:", SPKReelsHoldReadShapeOptions, YES},
        {"getDouble:withOptions:withDefault:", SPKReelsHoldReadShapeOptionsAndDefault, YES},
    };

    NSUInteger hooked = 0;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls)
            continue;
        for (size_t i = 0; i < sizeof(getters) / sizeof(getters[0]); i++) {
            SEL sel = sel_registerName(getters[i].selector);
            if (!SPKReelsHoldClassOwnsMethod(cls, sel))
                continue;
            // Each hook keeps its own original; the slot lives as long as the process.
            IMP *orig = (IMP *)calloc(1, sizeof(IMP));
            id block = getters[i].isDouble ? SPKReelsHoldDoubleBlock(getters[i].shape, sel, orig)
                                           : SPKReelsHoldBoolBlock(getters[i].shape, sel, orig);
            MSHookMessageEx(cls, sel, imp_implementationWithBlock(block), orig);
            hooked++;
        }
    }
    SPKLog(@"ReelsHold", @"Wrapped %lu MobileConfig getters", (unsigned long)hooked);
}

extern "C" void SPKInstallReelsHoldToPauseHooksIfNeeded(void) {
    // Installed regardless of the preference; the getters re-check it on every
    // read of the two parameters, so the toggle applies to reels opened after it.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKReelsHoldResolveParams();
        if (!sSPKReelsHoldMenuGateParam || !sSPKReelsHoldPressDurationParam)
            return;
        SPKReelsHoldInstallReadHooks();
    });
}
