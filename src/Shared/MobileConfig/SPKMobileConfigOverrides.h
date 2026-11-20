#import <Foundation/Foundation.h>

// Answers chosen MobileConfig parameters with a fixed value while a preference
// is on, so a server-gated Instagram feature can be forced on or off.
//
// Parameter IDs are reassigned on every Instagram build, but each parameter's
// config number and index within the config are stable. Instagram ships a table
// mapping each (config, index) pair to the build's ID, so features name their
// parameters by that pair and the IDs are looked up at launch.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint16_t, SPKMobileConfigParamType) {
    SPKMobileConfigParamTypeBool = 1,
    SPKMobileConfigParamTypeInt = 2,
    SPKMobileConfigParamTypeString = 3,
    SPKMobileConfigParamTypeDouble = 4,
};

typedef struct {
    uint32_t index;
    SPKMobileConfigParamType type;
} SPKMobileConfigParamSpec;

#ifdef __cplusplus
extern "C" {
#endif

// Resolves every listed parameter of `config` into `outParams`, in order.
// Succeeds only when each parameter has exactly one consistent row of the
// expected type and all of them share one group; otherwise every output is 0
// and NO is returned, so a feature stays stock on a build that lacks or changed
// the config. Scans the table once per call; call it once per feature.
BOOL SPKMobileConfigResolveParams(uint32_t config, const SPKMobileConfigParamSpec *specs, size_t count,
                                  unsigned long long *outParams);

// Registers an override. The value is returned for the parameter on every read
// while `prefKey` is on, read at call time so the toggle needs no restart for
// gates Instagram re-reads. The first registration wraps the getters.
void SPKMobileConfigOverrideBool(unsigned long long param, NSString *prefKey, BOOL value);
void SPKMobileConfigOverrideDouble(unsigned long long param, NSString *prefKey, double value);

// Same, for a menu preference: the value is returned while the string
// preference `prefKey` equals `mode`, so one parameter can carry a different
// override per menu choice.
void SPKMobileConfigOverrideBoolForMode(unsigned long long param, NSString *prefKey, NSString *mode, BOOL value);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
