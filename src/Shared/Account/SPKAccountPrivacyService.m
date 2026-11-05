#import "SPKAccountPrivacyService.h"

#import "SPKStrings.h"

#import "../../Utils.h"

#import <objc/message.h>
#import <objc/runtime.h>

NSString *const SPKAccountPrivacyErrorDomain = @"SPKAccountPrivacyErrorDomain";
NSString *const SPKAccountPrivacyServerMessageKey = @"SPKAccountPrivacyServerMessage";

static NSString *const kSPKAccountPrivacyFollowListsId = @"hide_followers_following_list";
static NSString *const kSPKAccountPrivacySelfInListsId = @"hide_self_from_others_lists";
// The same callsite Instagram's own account privacy screen reports.
static NSString *const kSPKAccountPrivacyCallsite = @"account_privacy";

// A Pando request completes through the token it returns, and nothing else
// retains that token once this function returns, so keep it alive until the
// update or failure callback fires.
static NSMutableSet *SPKAccountPrivacyActiveTokens(void) {
    static NSMutableSet *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSMutableSet set];
    });
    return tokens;
}

static NSError *SPKAccountPrivacyError(SPKAccountPrivacyErrorCode code, NSString *detail, NSString *serverMessage) {
    SPKLog(@"AccountPrivacy", @"Request failed (%ld): %@", (long)code, detail ?: @"");
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSDebugDescriptionErrorKey] = detail ?: @"";
    if (serverMessage.length > 0)
        userInfo[SPKAccountPrivacyServerMessageKey] = serverMessage;
    return [NSError errorWithDomain:SPKAccountPrivacyErrorDomain code:code userInfo:userInfo];
}

static NSString *SPKAccountPrivacySettingIdentifier(SPKAccountPrivacySetting setting) {
    return setting == SPKAccountPrivacySettingSelfInLists ? kSPKAccountPrivacySelfInListsId
                                                          : kSPKAccountPrivacyFollowListsId;
}

static id SPKAccountPrivacyBuilder(SPKAccountPrivacySetting setting, BOOL mutation, BOOL value) {
    Class builderClass = NSClassFromString(mutation ? @"IGSettingsBooleanMutationBuilder"
                                                    : @"IGSettingsBooleanQueryBuilder");
    if (!builderClass)
        return nil;

    NSString *identifier = SPKAccountPrivacySettingIdentifier(setting);
    @try {
        if (mutation) {
            SEL selector = NSSelectorFromString(@"builderWithAllowErrorCodes:callsite:settingId:value:");
            if (![builderClass respondsToSelector:selector])
                return nil;
            return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(builderClass,
                                                                  selector,
                                                                  @YES,
                                                                  kSPKAccountPrivacyCallsite,
                                                                  identifier,
                                                                  @(value));
        }

        SEL selector = NSSelectorFromString(@"builderWithSettingId:");
        if (![builderClass respondsToSelector:selector])
            return nil;
        return ((id (*)(id, SEL, id))objc_msgSend)(builderClass, selector, identifier);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Pando models can hand a field back boxed: a wrapper object that keeps the
// scalar in its `_fieldValue` ivar, or the PNNull sentinel for an absent
// field. Peel those layers off so callers only ever see a plain value or nil.
static id SPKAccountPrivacyUnwrap(id value) {
    Class pnNullClass = NSClassFromString(@"PNNull");
    for (NSUInteger depth = 0; value && depth < 4; depth++) {
        if (value == [NSNull null] || (pnNullClass && [value isKindOfClass:pnNullClass]))
            return nil;
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]])
            return value;

        Ivar ivar = class_getInstanceVariable([value class], "_fieldValue");
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (!type || type[0] != '@')
            return value;
        value = object_getIvar(value, ivar);
    }
    return value;
}

// Reads one schema field off a generated Pando model. The typed property is the
// normal path; `field_UNTYPED:` takes the raw schema name and answers for any
// field the model was generated with; KVC covers models that only expose either
// name as a key.
static id SPKAccountPrivacyField(id model, NSString *camel, NSString *snake) {
    if (!model)
        return nil;

    SEL camelSelector = NSSelectorFromString(camel);
    if ([model respondsToSelector:camelSelector]) {
        @try {
            id value = SPKAccountPrivacyUnwrap(((id (*)(id, SEL))objc_msgSend)(model, camelSelector));
            if (value)
                return value;
        } @catch (__unused NSException *exception) {
        }
    }

    SEL untypedSelector = NSSelectorFromString(@"field_UNTYPED:");
    if ([model respondsToSelector:untypedSelector]) {
        @try {
            id value = SPKAccountPrivacyUnwrap(((id (*)(id, SEL, id))objc_msgSend)(model, untypedSelector, snake));
            if (value)
                return value;
        } @catch (__unused NSException *exception) {
        }
    }

    for (NSString *key in @[ camel, snake ]) {
        @try {
            id value = SPKAccountPrivacyUnwrap([model valueForKey:key]);
            if (value)
                return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

// The response wraps the payload in one root field named after the API call.
// If no root field answers, the callback may already hand over the payload.
static id SPKAccountPrivacyRootModel(id response, BOOL mutation) {
    if (!response)
        return nil;

    id model = mutation
        ? SPKAccountPrivacyField(response, @"xdtApi_V1_Settings_SetBool", @"xdt_api__v1__settings__set_bool")
        : SPKAccountPrivacyField(response, @"xdtApi_V1_Settings_GetBool", @"xdt_api__v1__settings__get_bool");
    return model ?: response;
}

static NSNumber *SPKAccountPrivacyBoolValue(id value) {
    if ([value isKindOfClass:[NSNumber class]])
        return @([(NSNumber *)value boolValue]);

    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value lowercaseString];
        if ([text isEqualToString:@"true"] || [text isEqualToString:@"1"])
            return @YES;
        if ([text isEqualToString:@"false"] || [text isEqualToString:@"0"])
            return @NO;
    }
    return nil;
}

static NSString *SPKAccountPrivacyStringValue(id value) {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
        return (NSString *)value;
    if ([value isKindOfClass:[NSNumber class]])
        return [(NSNumber *)value stringValue];
    return nil;
}

// Runs the builder's request through whichever service path this build exposes.
// Instagram 410 to 454 all keep the pando accessor; the graphQLService fallback
// covers builds where the pando object is missing for the active session.
static void SPKAccountPrivacyDispatch(id builder, BOOL mutation, SPKAccountPrivacyResult completion) {
    id session = [SPKUtils activeUserSession];
    if (!session) {
        completion(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorRequestFailed, @"No active Instagram session", nil));
        return;
    }

    id request = nil;
    @try {
        SEL requestSelector = NSSelectorFromString(@"request");
        if ([builder respondsToSelector:requestSelector])
            request = ((id (*)(id, SEL))objc_msgSend)(builder, requestSelector);
    } @catch (__unused NSException *exception) {
        request = nil;
    }
    if (!request) {
        completion(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorRequestFailed, @"Could not build the settings request", nil));
        return;
    }

    __block id activeToken = nil;
    __block BOOL finished = NO;
    void (^finish)(NSNumber *, NSError *) = ^(NSNumber *value, NSError *error) {
        if (finished)
            return;
        finished = YES;
        if (activeToken) {
            id token = activeToken;
            activeToken = nil;
            @synchronized(SPKAccountPrivacyActiveTokens()) {
                [SPKAccountPrivacyActiveTokens() removeObject:token];
            }
        }
        completion(value, error);
    };

    // Pando calls back with the response model plus a second object argument.
    void (^updateCallback)(id, id) = ^(id response, __unused id extra) {
        id model = SPKAccountPrivacyRootModel(response, mutation);
        NSString *errorName = SPKAccountPrivacyStringValue(SPKAccountPrivacyField(model, @"errorNameValue", @"error_name_value"));
        NSString *fallback = SPKAccountPrivacyStringValue(SPKAccountPrivacyField(model, @"fallbackMessage", @"fallback_message"));
        NSNumber *value = SPKAccountPrivacyBoolValue(SPKAccountPrivacyField(model, @"value", @"value"));

        if (errorName.length > 0) {
            finish(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorServerRefused, errorName, fallback));
            return;
        }
        if (!value) {
            NSString *detail = [NSString stringWithFormat:@"No value in %@", NSStringFromClass([model class])];
            finish(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorNoValue, detail, nil));
            return;
        }
        finish(value, nil);
    };

    void (^failureCallback)(id) = ^(id error) {
        NSString *detail = [error isKindOfClass:[NSError class]] ? [(NSError *)error description]
                                                                 : SPKAccountPrivacyStringValue(error);
        finish(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorRequestFailed, detail ?: @"Request failed", nil));
    };

    SEL initiateSelector = NSSelectorFromString(@"initiateRequest:initialData:updateCallback:failureCallback:callbackQueue:");
    SEL handleSelector = NSSelectorFromString(@"handleWithService:updateCallback:failureCallback:callbackQueue:");

    SEL pandoSelector = NSSelectorFromString(@"pandoGraphQLService");
    id pandoService = nil;
    @try {
        if ([session respondsToSelector:pandoSelector])
            pandoService = ((id (*)(id, SEL))objc_msgSend)(session, pandoSelector);
    } @catch (__unused NSException *exception) {
        pandoService = nil;
    }

    id token = nil;
    @try {
        if (pandoService && [pandoService respondsToSelector:initiateSelector]) {
            token = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(pandoService,
                                                                       initiateSelector,
                                                                       request,
                                                                       nil,
                                                                       updateCallback,
                                                                       failureCallback,
                                                                       dispatch_get_main_queue());
        } else {
            SEL graphQLSelector = NSSelectorFromString(@"graphQLService");
            id graphQLService = nil;
            if ([session respondsToSelector:graphQLSelector])
                graphQLService = ((id (*)(id, SEL))objc_msgSend)(session, graphQLSelector);

            if (!graphQLService || ![request respondsToSelector:handleSelector]) {
                finish(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorUnsupported, @"No settings service on this build", nil));
                return;
            }
            token = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(request,
                                                                   handleSelector,
                                                                   graphQLService,
                                                                   updateCallback,
                                                                   failureCallback,
                                                                   dispatch_get_main_queue());
        }
    } @catch (NSException *exception) {
        finish(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorUnsupported, exception.reason, nil));
        return;
    }

    // A callback can fire before the call returns; only park the token while
    // the request is still outstanding, or nothing would ever release it.
    if (token && !finished) {
        activeToken = token;
        @synchronized(SPKAccountPrivacyActiveTokens()) {
            [SPKAccountPrivacyActiveTokens() addObject:token];
        }
    }
}

#if SPK_DEV
// Dev builds only: forces each failure path so the page's error states can be
// checked on an account where the real requests always succeed.
static NSString *SPKAccountPrivacySimulationMode(void) {
    NSString *mode = [SPKUtils getStringPref:@"dev_account_privacy_simulate"];
    return mode.length > 0 ? mode : @"off";
}

// YES when the simulation answered the call; NO lets the real request run.
static BOOL SPKAccountPrivacySimulate(BOOL mutation, SPKAccountPrivacyResult done) {
    NSString *mode = SPKAccountPrivacySimulationMode();
    NSError *error = nil;
    NSTimeInterval delay = 0.6;

    if ([mode isEqualToString:@"slow"]) {
        // Real request, answered late, so the loading state stays up.
        return NO;
    } else if ([mode isEqualToString:@"read_failed"] && !mutation) {
        error = SPKAccountPrivacyError(SPKAccountPrivacyErrorRequestFailed, @"Simulated read failure", nil);
    } else if ([mode isEqualToString:@"write_refused"] && mutation) {
        error = SPKAccountPrivacyError(SPKAccountPrivacyErrorServerRefused, @"Simulated refusal",
                                       SPKL(@"ACCOUNT_PRIVACY_DEV_SIMULATED_REASON"));
    } else if ([mode isEqualToString:@"write_refused_silent"] && mutation) {
        error = SPKAccountPrivacyError(SPKAccountPrivacyErrorServerRefused, @"Simulated silent refusal", nil);
    } else if ([mode isEqualToString:@"write_failed"] && mutation) {
        error = SPKAccountPrivacyError(SPKAccountPrivacyErrorRequestFailed, @"Simulated write failure", nil);
    } else {
        return NO;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        done(nil, error);
    });
    return YES;
}

static SPKAccountPrivacyResult SPKAccountPrivacySlowed(SPKAccountPrivacyResult done) {
    if (![SPKAccountPrivacySimulationMode() isEqualToString:@"slow"])
        return done;
    return ^(NSNumber *value, NSError *error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            done(value, error);
        });
    };
}
#endif

@implementation SPKAccountPrivacyService

+ (BOOL)isSupported {
    return NSClassFromString(@"IGSettingsBooleanQueryBuilder") != nil &&
           NSClassFromString(@"IGSettingsBooleanMutationBuilder") != nil;
}

+ (void)fetchSetting:(SPKAccountPrivacySetting)setting completion:(SPKAccountPrivacyResult)completion {
    if (!completion)
        return;

    SPKAccountPrivacyResult done = ^(NSNumber *value, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(value, error);
        });
    };

#if SPK_DEV
    if (SPKAccountPrivacySimulate(NO, done))
        return;
    done = SPKAccountPrivacySlowed(done);
#endif

    id builder = SPKAccountPrivacyBuilder(setting, NO, NO);
    if (!builder) {
        done(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorUnsupported, @"No settings builder on this build", nil));
        return;
    }
    SPKAccountPrivacyDispatch(builder, NO, done);
}

+ (void)setSetting:(SPKAccountPrivacySetting)setting value:(BOOL)value completion:(SPKAccountPrivacyResult)completion {
    if (!completion)
        return;

    SPKAccountPrivacyResult done = ^(NSNumber *resultValue, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(resultValue ?: (error ? nil : @(value)), error);
        });
    };

#if SPK_DEV
    if (SPKAccountPrivacySimulate(YES, done))
        return;
    done = SPKAccountPrivacySlowed(done);
#endif

    id builder = SPKAccountPrivacyBuilder(setting, YES, value);
    if (!builder) {
        done(nil, SPKAccountPrivacyError(SPKAccountPrivacyErrorUnsupported, @"No settings builder on this build", nil));
        return;
    }
    SPKAccountPrivacyDispatch(builder, YES, done);
}

@end
