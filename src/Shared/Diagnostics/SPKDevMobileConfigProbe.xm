#if SPK_DEV
// Dev-only MobileConfig probe. Records every boolean or integer read of the
// watched parameter groups with the value Instagram got, and answers chosen
// parameters with an override instead. Driven from the dev screen tour
// ("mc", "mcset <hex id> <value|clear>"); overrides apply from the next launch,
// since most gates are read once.
//
// The groups watched are the adaptive layout universes (foldables, regular
// width): their gates decide where chrome goes on a foldable, and a simulator
// that is only told it is foldable may not receive them from the server.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"
#include "../../../modules/SPKSideloadFix/fishhook/fishhook.h"

static NSString *const kSPKDevMCOverridesKey = @"dev_mc_overrides";

static NSMutableDictionary<NSString *, NSString *> *sSPKDevMCReads;
static NSDictionary<NSString *, NSNumber *> *sSPKDevMCOverrides;
static NSLock *sSPKDevMCLock;

static BOOL SPKDevMCWatched(unsigned long long param) {
    uint16_t group = (uint16_t)(param >> 32);
    return group == 0x0C55 || group == 0x0CFE;
}

// The type byte and flags differ between read sites for the same parameter, so
// a parameter is keyed by group, index and slot only.
static NSString *SPKDevMCKey(unsigned long long param) {
    return [NSString stringWithFormat:@"%012llx", param & 0xFFFFFFFFFFFFULL];
}

static void SPKDevMCRecord(unsigned long long param, long long value, BOOL overridden) {
    [sSPKDevMCLock lock];
    sSPKDevMCReads[SPKDevMCKey(param)] = [NSString stringWithFormat:@"%016llx = %lld%@", param, value, overridden ? @" (override)" : @""];
    [sSPKDevMCLock unlock];
}

static NSNumber *SPKDevMCOverride(unsigned long long param) {
    return sSPKDevMCOverrides[SPKDevMCKey(param)];
}

static BOOL SPKDevMCClassOwnsMethod(Class cls, SEL selector) {
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

typedef NS_ENUM(NSInteger, SPKDevMCShape) {
    SPKDevMCShapePlain,
    SPKDevMCShapeDefault,
    SPKDevMCShapeOptions,
    SPKDevMCShapeOptionsAndDefault,
};

#define SPK_DEV_MC_FILTER(TYPE, CALL)                                   \
    if (!SPKDevMCWatched(param))                                        \
        return CALL;                                                    \
    NSNumber *forced = SPKDevMCOverride(param);                         \
    TYPE value = forced ? (TYPE)forced.longLongValue : CALL;            \
    SPKDevMCRecord(param, (long long)value, forced != nil);             \
    return value;

static id SPKDevMCBoolBlock(SPKDevMCShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKDevMCShapePlain:
        return ^BOOL(id self, unsigned long long param) {
            SPK_DEV_MC_FILTER(BOOL, ((BOOL (*)(id, SEL, unsigned long long))*orig)(self, sel, param))
        };
    case SPKDevMCShapeDefault:
        return ^BOOL(id self, unsigned long long param, BOOL fallback) {
            SPK_DEV_MC_FILTER(BOOL, ((BOOL (*)(id, SEL, unsigned long long, BOOL))*orig)(self, sel, param, fallback))
        };
    case SPKDevMCShapeOptions:
        return ^BOOL(id self, unsigned long long param, id options) {
            SPK_DEV_MC_FILTER(BOOL, ((BOOL (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options))
        };
    case SPKDevMCShapeOptionsAndDefault:
        return ^BOOL(id self, unsigned long long param, id options, BOOL fallback) {
            SPK_DEV_MC_FILTER(BOOL, ((BOOL (*)(id, SEL, unsigned long long, id, BOOL))*orig)(self, sel, param, options, fallback))
        };
    }
    return nil;
}

static id SPKDevMCIntBlock(SPKDevMCShape shape, SEL sel, IMP *orig) {
    switch (shape) {
    case SPKDevMCShapePlain:
        return ^long long(id self, unsigned long long param) {
            SPK_DEV_MC_FILTER(long long, ((long long (*)(id, SEL, unsigned long long))*orig)(self, sel, param))
        };
    case SPKDevMCShapeDefault:
        return ^long long(id self, unsigned long long param, long long fallback) {
            SPK_DEV_MC_FILTER(long long, ((long long (*)(id, SEL, unsigned long long, long long))*orig)(self, sel, param, fallback))
        };
    case SPKDevMCShapeOptions:
        return ^long long(id self, unsigned long long param, id options) {
            SPK_DEV_MC_FILTER(long long, ((long long (*)(id, SEL, unsigned long long, id))*orig)(self, sel, param, options))
        };
    case SPKDevMCShapeOptionsAndDefault:
        return ^long long(id self, unsigned long long param, id options, long long fallback) {
            SPK_DEV_MC_FILTER(long long, ((long long (*)(id, SEL, unsigned long long, id, long long))*orig)(self, sel, param, options, fallback))
        };
    }
    return nil;
}

extern "C" NSString *SPKDevMobileConfigProbeDump(void) {
    [sSPKDevMCLock lock];
    NSArray<NSString *> *keys = [sSPKDevMCReads.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *key in keys)
        [lines addObject:sSPKDevMCReads[key]];
    [sSPKDevMCLock unlock];
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"no reads recorded";
}

// Stored for the next launch. value nil clears the override.
extern "C" NSString *SPKDevMobileConfigProbeSet(NSString *hexID, NSNumber *value) {
    unsigned long long param = strtoull(hexID.UTF8String, NULL, 16);
    if (!param)
        return @"error bad id";
    NSMutableDictionary *overrides = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kSPKDevMCOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    overrides[SPKDevMCKey(param)] = value;
    [NSUserDefaults.standardUserDefaults setObject:overrides forKey:kSPKDevMCOverridesKey];
    return [NSString stringWithFormat:@"ok %@ = %@ (next launch)", SPKDevMCKey(param), value ?: @"cleared"];
}

// Swift reads skip the Objective-C context managers and call the C cache
// getters, which the main executable imports, so they are rebound as well.
// The parameter argument position is not known for every build, so each
// argument that carries a watched group is treated as the parameter.
static BOOL (*orig_MCIGetBool)(void *, unsigned long long, unsigned long long, unsigned long long);
static BOOL hook_MCIGetBool(void *a0, unsigned long long a1, unsigned long long a2, unsigned long long a3) {
    unsigned long long param = SPKDevMCWatched(a1) ? a1 : SPKDevMCWatched(a2) ? a2 : SPKDevMCWatched(a3) ? a3 : 0;
    if (!param)
        return orig_MCIGetBool(a0, a1, a2, a3);
    NSNumber *forced = SPKDevMCOverride(param);
    BOOL value = forced ? forced.boolValue : orig_MCIGetBool(a0, a1, a2, a3);
    SPKDevMCRecord(param, value, forced != nil);
    return value;
}

static long long (*orig_MCIGetInt64)(void *, unsigned long long, unsigned long long, unsigned long long);
static long long hook_MCIGetInt64(void *a0, unsigned long long a1, unsigned long long a2, unsigned long long a3) {
    unsigned long long param = SPKDevMCWatched(a1) ? a1 : SPKDevMCWatched(a2) ? a2 : SPKDevMCWatched(a3) ? a3 : 0;
    if (!param)
        return orig_MCIGetInt64(a0, a1, a2, a3);
    NSNumber *forced = SPKDevMCOverride(param);
    long long value = forced ? forced.longLongValue : orig_MCIGetInt64(a0, a1, a2, a3);
    SPKDevMCRecord(param, value, forced != nil);
    return value;
}

%ctor {
    sSPKDevMCLock = [[NSLock alloc] init];
    sSPKDevMCReads = [NSMutableDictionary dictionary];
    sSPKDevMCOverrides = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kSPKDevMCOverridesKey] copy] ?: @{};

    NSArray<NSString *> *classNames = @[
        @"IGMobileConfigUserSessionContextManager", @"IGMobileConfigSessionlessContextManager", @"IGMobileConfigContextManager",
        @"FBMobileConfigUserSessionContextManager", @"FBMobileConfigSessionlessContextManager", @"FBMobileConfigContextManager",
        @"FBMobileConfigContextObjcImpl",
    ];
    struct {
        const char *selector;
        SPKDevMCShape shape;
        BOOL isInt;
    } const getters[] = {
        {"getBool:", SPKDevMCShapePlain, NO},
        {"getBoolWithoutLogging:", SPKDevMCShapePlain, NO},
        {"getBool:withDefault:", SPKDevMCShapeDefault, NO},
        {"getBoolWithoutLogging:withDefault:", SPKDevMCShapeDefault, NO},
        {"getBool:withOptions:", SPKDevMCShapeOptions, NO},
        {"getBool:withOptions:withDefault:", SPKDevMCShapeOptionsAndDefault, NO},
        {"getInt64:", SPKDevMCShapePlain, YES},
        {"getInt64WithoutLogging:", SPKDevMCShapePlain, YES},
        {"getInt64:withDefault:", SPKDevMCShapeDefault, YES},
        {"getInt64WithoutLogging:withDefault:", SPKDevMCShapeDefault, YES},
        {"getInt64:withOptions:", SPKDevMCShapeOptions, YES},
        {"getInt64:withOptions:withDefault:", SPKDevMCShapeOptionsAndDefault, YES},
    };
    NSUInteger hooked = 0;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls)
            continue;
        for (size_t i = 0; i < sizeof(getters) / sizeof(getters[0]); i++) {
            SEL sel = sel_registerName(getters[i].selector);
            if (!SPKDevMCClassOwnsMethod(cls, sel))
                continue;
            IMP *orig = (IMP *)calloc(1, sizeof(IMP));
            id block = getters[i].isInt ? SPKDevMCIntBlock(getters[i].shape, sel, orig) : SPKDevMCBoolBlock(getters[i].shape, sel, orig);
            MSHookMessageEx(cls, sel, imp_implementationWithBlock(block), orig);
            hooked++;
        }
    }
    int rebound = rebind_symbols((struct rebinding[]){
                                     {"MCIExperimentCacheGetMobileConfigBoolean", (void *)hook_MCIGetBool, (void **)&orig_MCIGetBool},
                                     {"MCIExperimentCacheGetMobileConfigInt64", (void *)hook_MCIGetInt64, (void **)&orig_MCIGetInt64},
                                 },
                                 2);
    SPKLog(@"DevMC", @"C getters rebound=%d", rebound);
    SPKLog(@"DevMC", @"probe wrapped %lu getters, %lu overrides", (unsigned long)hooked, (unsigned long)sSPKDevMCOverrides.count);
}
#endif
