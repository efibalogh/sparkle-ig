#import "SPKMobileConfigOverrides.h"

#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <substrate.h>

#import "../../Utils.h"

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
} SPKMCParamLookup;

static void SPKMCScanRows(const uint8_t *data, size_t size, uint32_t config, const SPKMobileConfigParamSpec *specs,
                          size_t count, SPKMCParamLookup *lookups) {
    if (!data || size < 40)
        return;
    const uint32_t *words = (const uint32_t *)data;
    size_t wordCount = size / sizeof(uint32_t);
    for (size_t k = 9; k < wordCount; k++) {
        if (words[k] != config)
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
            if (specs[i].index != index)
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

BOOL SPKMobileConfigResolveParams(uint32_t config, const SPKMobileConfigParamSpec *specs, size_t count,
                                  unsigned long long *outParams) {
    if (!specs || !outParams || count == 0)
        return NO;
    for (size_t i = 0; i < count; i++)
        outParams[i] = 0;
    SPKMCParamLookup *lookups = (SPKMCParamLookup *)calloc(count, sizeof(SPKMCParamLookup));
    if (!lookups)
        return NO;

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
        SPKMCScanRows(data, size, config, specs, count, lookups);
        data = getsectiondata(header, "__TEXT", "__const", &size);
        SPKMCScanRows(data, size, config, specs, count, lookups);
    }

    BOOL valid = YES;
    for (size_t i = 0; i < count; i++) {
        SPKMCParamLookup lookup = lookups[i];
        if (!lookup.matches || lookup.conflict || lookup.type != specs[i].type || lookup.group != lookups[0].group) {
            SPKLog(@"MobileConfig", @"Config %u param %u not resolved (%lu rows%@, type %u, expected %u)", config,
                   specs[i].index, (unsigned long)lookup.matches, lookup.conflict ? @", conflicting" : @"",
                   lookup.type, specs[i].type);
            valid = NO;
        }
    }
    if (valid) {
        for (size_t i = 0; i < count; i++) {
            outParams[i] = lookups[i].param;
            SPKLog(@"MobileConfig", @"Config %u param %u: 0x%016llx", config, specs[i].index, lookups[i].param);
        }
    }
    free(lookups);
    return valid;
}

// MARK: - Override registry

// A handful of entries in a fixed array: every MobileConfig read Instagram
// makes passes through the lookup, so it stays a short lock-free scan. Entries
// are written before the count is published and never change afterwards.
#define SPK_MC_MAX_OVERRIDES 32

typedef struct {
    unsigned long long param;
    __unsafe_unretained NSString *prefKey;
    BOOL isDouble;
    BOOL boolValue;
    double doubleValue;
} SPKMCOverride;

static SPKMCOverride sSPKMCOverrides[SPK_MC_MAX_OVERRIDES];
static _Atomic size_t sSPKMCOverrideCount = 0;

static const SPKMCOverride *SPKMCActiveOverride(unsigned long long param, BOOL isDouble) {
    size_t count = atomic_load_explicit(&sSPKMCOverrideCount, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        const SPKMCOverride *entry = &sSPKMCOverrides[i];
        // The parameter is compared first so preferences are read only for the
        // overridden parameters, never on the hot path of every other read.
        if (entry->param != param || entry->isDouble != isDouble)
            continue;
        if ([SPKUtils getBoolPref:entry->prefKey])
            return entry;
    }
    return NULL;
}

// MARK: - Getter hooks

static BOOL SPKMCClassOwnsMethod(Class cls, SEL selector) {
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

typedef NS_ENUM(NSInteger, SPKMCReadShape) {
    SPKMCReadShapePlain,              // getX:(param)
    SPKMCReadShapeDefault,            // getX:(param) withDefault:(value)
    SPKMCReadShapeOptions,            // getX:(param) withOptions:(options)
    SPKMCReadShapeOptionsAndDefault,  // getX:(param) withOptions:(options) withDefault:(value)
};

static id SPKMCBoolBlock(SPKMCReadShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKMCReadShapePlain:
        return ^BOOL(id self, unsigned long long param) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, NO);
            if (entry)
                return entry->boolValue;
            return ((BOOL (*)(id, SEL, unsigned long long))*orig)(self, sel, param);
        };
    case SPKMCReadShapeDefault:
        return ^BOOL(id self, unsigned long long param, BOOL fallback) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, NO);
            if (entry)
                return entry->boolValue;
            return ((BOOL (*)(id, SEL, unsigned long long, BOOL))*orig)(self, sel, param, fallback);
        };
    case SPKMCReadShapeOptions:
        return ^BOOL(id self, unsigned long long param, id options) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, NO);
            if (entry)
                return entry->boolValue;
            return ((BOOL (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options);
        };
    case SPKMCReadShapeOptionsAndDefault:
        return ^BOOL(id self, unsigned long long param, id options, BOOL fallback) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, NO);
            if (entry)
                return entry->boolValue;
            return ((BOOL (*)(id, SEL, unsigned long long, id, BOOL))*orig)(self, sel, param, options, fallback);
        };
    }
    return nil;
}

static id SPKMCDoubleBlock(SPKMCReadShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKMCReadShapePlain:
        return ^double(id self, unsigned long long param) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, YES);
            if (entry)
                return entry->doubleValue;
            return ((double (*)(id, SEL, unsigned long long))*orig)(self, sel, param);
        };
    case SPKMCReadShapeDefault:
        return ^double(id self, unsigned long long param, double fallback) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, YES);
            if (entry)
                return entry->doubleValue;
            return ((double (*)(id, SEL, unsigned long long, double))*orig)(self, sel, param, fallback);
        };
    case SPKMCReadShapeOptions:
        return ^double(id self, unsigned long long param, id options) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, YES);
            if (entry)
                return entry->doubleValue;
            return ((double (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options);
        };
    case SPKMCReadShapeOptionsAndDefault:
        return ^double(id self, unsigned long long param, id options, double fallback) {
            const SPKMCOverride *entry = SPKMCActiveOverride(param, YES);
            if (entry)
                return entry->doubleValue;
            return ((double (*)(id, SEL, unsigned long long, id, double))*orig)(self, sel, param, options, fallback);
        };
    }
    return nil;
}

// Every MobileConfig context class Instagram reads through, and every getter
// variant each one implements itself (an inherited one is covered by its
// superclass), so no read path sees the server value while another sees the
// override.
static void SPKMCInstallReadHooks(void) {
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
        SPKMCReadShape shape;
        BOOL isDouble;
    } const getters[] = {
        {"getBool:", SPKMCReadShapePlain, NO},
        {"getBoolWithoutLogging:", SPKMCReadShapePlain, NO},
        {"getBool:withDefault:", SPKMCReadShapeDefault, NO},
        {"getBoolWithoutLogging:withDefault:", SPKMCReadShapeDefault, NO},
        {"getBool:withOptions:", SPKMCReadShapeOptions, NO},
        {"getBool:withOptions:withDefault:", SPKMCReadShapeOptionsAndDefault, NO},
        {"getDouble:", SPKMCReadShapePlain, YES},
        {"getDoubleWithoutLogging:", SPKMCReadShapePlain, YES},
        {"getDouble:withDefault:", SPKMCReadShapeDefault, YES},
        {"getDoubleWithoutLogging:withDefault:", SPKMCReadShapeDefault, YES},
        {"getDouble:withOptions:", SPKMCReadShapeOptions, YES},
        {"getDouble:withOptions:withDefault:", SPKMCReadShapeOptionsAndDefault, YES},
    };

    NSUInteger hooked = 0;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls)
            continue;
        for (size_t i = 0; i < sizeof(getters) / sizeof(getters[0]); i++) {
            SEL sel = sel_registerName(getters[i].selector);
            if (!SPKMCClassOwnsMethod(cls, sel))
                continue;
            // Each hook keeps its own original; the slot lives as long as the process.
            IMP *orig = (IMP *)calloc(1, sizeof(IMP));
            id block = getters[i].isDouble ? SPKMCDoubleBlock(getters[i].shape, sel, orig)
                                           : SPKMCBoolBlock(getters[i].shape, sel, orig);
            MSHookMessageEx(cls, sel, imp_implementationWithBlock(block), orig);
            hooked++;
        }
    }
    SPKLog(@"MobileConfig", @"Wrapped %lu MobileConfig getters", (unsigned long)hooked);
}

static void SPKMCRegister(SPKMCOverride entry) {
    if (!entry.param || !entry.prefKey)
        return;
    // Registration runs from the startup installers on the main thread; the
    // lock only guards against a stray background caller.
    static NSLock *lock;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        lock = [[NSLock alloc] init];
    });
    [lock lock];
    size_t count = atomic_load_explicit(&sSPKMCOverrideCount, memory_order_relaxed);
    if (count >= SPK_MC_MAX_OVERRIDES) {
        [lock unlock];
        SPKLog(@"MobileConfig", @"Override table full; 0x%016llx not registered", entry.param);
        return;
    }
    // The registry holds the key without retaining it; keep it alive for the process.
    entry.prefKey = (__bridge NSString *)CFBridgingRetain([entry.prefKey copy]);
    sSPKMCOverrides[count] = entry;
    atomic_store_explicit(&sSPKMCOverrideCount, count + 1, memory_order_release);
    [lock unlock];

    static dispatch_once_t hooksOnce;
    dispatch_once(&hooksOnce, ^{
        SPKMCInstallReadHooks();
    });
}

void SPKMobileConfigOverrideBool(unsigned long long param, NSString *prefKey, BOOL value) {
    SPKMCRegister((SPKMCOverride){.param = param, .prefKey = prefKey, .isDouble = NO, .boolValue = value});
}

void SPKMobileConfigOverrideDouble(unsigned long long param, NSString *prefKey, double value) {
    SPKMCRegister((SPKMCOverride){.param = param, .prefKey = prefKey, .isDouble = YES, .doubleValue = value});
}
