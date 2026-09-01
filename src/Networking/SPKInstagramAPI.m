#import "SPKStrings.h"
// Reusable IG private API helper. Uses active session auth header.

#import "SPKInstagramAPI.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "../Utils.h"
#import <objc/message.h>
#import <sys/sysctl.h>

#define SPK_API_BASE @"https://i.instagram.com/api/v1/"
#define SPK_APP_ID @"124024574287414"

static NSString *spkUserAgent(void) {
    static NSString *ua = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"426.0.0";
        char machine[64] = {0};
        size_t size = sizeof(machine);
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        NSString *device = machine[0] ? [NSString stringWithUTF8String:machine] : @"iPhone15,2";
        NSString *iosVersion = [[UIDevice currentDevice].systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        NSString *locale = [NSLocale currentLocale].localeIdentifier ?: @"en_US";
        NSString *language = [[NSLocale preferredLanguages] firstObject] ?: @"en";
        UIScreen *screen = [UIScreen mainScreen];
        ua = [NSString stringWithFormat:@"Instagram %@ (%@; iOS %@; %@; %@; scale=%.2f; %.0fx%.0f; 0)",
                                        version,
                                        device,
                                        iosVersion,
                                        locale,
                                        language,
                                        screen.scale,
                                        screen.nativeBounds.size.width,
                                        screen.nativeBounds.size.height];
    });
    return ua;
}

static id spkCurrentUserSession(void) {
    @try {
        UIApplication *application = [UIApplication sharedApplication];
        NSMutableArray *windows = [NSMutableArray array];
        if (application.keyWindow) {
            [windows addObject:application.keyWindow];
        }
        for (UIWindow *window in application.windows) {
            if (window)
                [windows addObject:window];
        }
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]])
                continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window)
                    [windows addObject:window];
            }
        }
        for (id window in windows) {
            if ([window respondsToSelector:@selector(userSession)]) {
                id session = [window valueForKey:@"userSession"];
                if (session)
                    return session;
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSString *spkAuthHeader(void) {
    @try {
        id session = spkCurrentUserSession();
        SEL authHeaderManagerSel = NSSelectorFromString(@"authHeaderManager");
        if (!session || ![session respondsToSelector:authHeaderManagerSel])
            return nil;
        id manager = ((id (*)(id, SEL))objc_msgSend)(session, authHeaderManagerSel);
        SEL authHeaderSel = NSSelectorFromString(@"authHeader");
        if (!manager || ![manager respondsToSelector:authHeaderSel])
            return nil;
        id header = ((id (*)(id, SEL))objc_msgSend)(manager, authHeaderSel);
        if ([header isKindOfClass:[NSString class]] && [(NSString *)header length] > 0) {
            return (NSString *)header;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSString *spkFormEncode(NSDictionary *params) {
    if (!params.count)
        return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    for (NSString *key in params) {
        NSString *value = [NSString stringWithFormat:@"%@", params[key]];
        NSString *encodedKey = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
        NSString *encodedValue = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
        [parts addObject:[NSString stringWithFormat:@"%@=%@", encodedKey, encodedValue]];
    }
    return [parts componentsJoinedByString:@"&"];
}

static NSMutableURLRequest *spkBuildRequest(NSString *method, NSURL *url, NSDictionary *body) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method ?: @"GET";

    [request setValue:spkUserAgent() forHTTPHeaderField:@"User-Agent"];
    [request setValue:SPK_APP_ID forHTTPHeaderField:@"X-IG-App-ID"];
    [request setValue:@"WIFI" forHTTPHeaderField:@"X-IG-Connection-Type"];
    [request setValue:@"en-US" forHTTPHeaderField:@"Accept-Language"];

    NSString *auth = spkAuthHeader();
    if (auth.length > 0) {
        [request setValue:auth forHTTPHeaderField:@"Authorization"];
    }

    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]) {
        if ([cookie.name isEqualToString:@"csrftoken"]) {
            [request setValue:cookie.value forHTTPHeaderField:@"X-CSRFToken"];
            break;
        }
    }

    if (body) {
        request.HTTPBody = [spkFormEncode(body) dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8"
            forHTTPHeaderField:@"Content-Type"];
    }

    return request;
}

static void spkPerformRequest(NSMutableURLRequest *request, SPKAPICompletion completion) {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *transportError) {
                                                                     // An HTTP failure is not a transport error, and a rejected or retired
                                                                     // endpoint often answers with no JSON at all. Without this, callers
                                                                     // read "no error, no body" as success.
                                                                     NSError *error = transportError;
                                                                     NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
                                                                                                ? ((NSHTTPURLResponse *)response).statusCode
                                                                                                : 0;
                                                                     if (!error && statusCode >= 400) {
                                                                         error = [NSError errorWithDomain:@"SPKInstagramAPI"
                                                                                                     code:statusCode
                                                                                                 userInfo:@{
                                                                                                     NSLocalizedDescriptionKey : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]
                                                                                                 }];
                                                                     }
                                                                     NSDictionary *parsedResponse = nil;
                                                                     if (data.length > 0) {
                                                                         @try {
                                                                             id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                                                                             if ([parsed isKindOfClass:[NSDictionary class]]) {
                                                                                 parsedResponse = (NSDictionary *)parsed;
                                                                             }
                                                                         } @catch (__unused NSException *exception) {
                                                                         }
                                                                     }

                                                                     if (!completion)
                                                                         return;
                                                                     dispatch_async(dispatch_get_main_queue(), ^{
                                                                         completion(parsedResponse, error);
                                                                     });
                                                                 }];
    [task resume];
}

@implementation SPKInstagramAPI

+ (void)sendRequestWithMethod:(NSString *)method
                         path:(NSString *)path
                         body:(NSDictionary *)body
                   completion:(SPKAPICompletion)completion {
    NSString *cleanPath = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSURL *url = [NSURL URLWithString:[SPK_API_BASE stringByAppendingString:cleanPath ?: @""]];
    if (!url) {
        if (completion)
            completion(nil, nil);
        return;
    }
    spkPerformRequest(spkBuildRequest(method, url, body), completion);
}

+ (void)followUserPK:(NSString *)pk completion:(SPKAPICompletion)completion {
    if (pk.length == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }
    [self sendRequestWithMethod:@"POST"
                           path:[NSString stringWithFormat:@"friendships/create/%@/", pk]
                           body:@{@"user_id" : pk, @"radio_type" : @"wifi-none"}
                     completion:completion];
}

+ (void)unfollowUserPK:(NSString *)pk completion:(SPKAPICompletion)completion {
    if (pk.length == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }
    [self sendRequestWithMethod:@"POST"
                           path:[NSString stringWithFormat:@"friendships/destroy/%@/", pk]
                           body:@{@"user_id" : pk, @"radio_type" : @"wifi-none"}
                     completion:completion];
}

+ (void)fetchFriendshipStatusesForPKs:(NSArray<NSString *> *)pks
                           completion:(SPKAPIStatusesCompletion)completion {
    if (pks.count == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }
    [self sendRequestWithMethod:@"POST"
                           path:@"friendships/show_many/"
                           body:@{@"user_ids" : [pks componentsJoinedByString:@","]}
                     completion:^(NSDictionary *response, NSError *error) {
                         NSDictionary *statuses = nil;
                         id raw = response[@"friendship_statuses"];
                         if ([raw isKindOfClass:[NSDictionary class]]) {
                             statuses = (NSDictionary *)raw;
                         }
                         if (completion)
                             completion(statuses, error);
                     }];
}

+ (void)resolveProfilePicURLForPK:(NSString *)pk
                       completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    if (pk.length == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }
    [self sendRequestWithMethod:@"GET"
                           path:[NSString stringWithFormat:@"users/%@/info/", pk]
                           body:nil
                     completion:^(NSDictionary *response, NSError *error) {
                         NSString *url = nil;
                         id user = response[@"user"];
                         if ([user isKindOfClass:[NSDictionary class]]) {
                             id hd = ((NSDictionary *)user)[@"hd_profile_pic_url_info"];
                             if ([hd isKindOfClass:[NSDictionary class]] && [((NSDictionary *)hd)[@"url"] isKindOfClass:[NSString class]]) {
                                 url = ((NSDictionary *)hd)[@"url"];
                             }
                             if (url.length == 0 && [((NSDictionary *)user)[@"profile_pic_url"] isKindOfClass:[NSString class]]) {
                                 url = ((NSDictionary *)user)[@"profile_pic_url"];
                             }
                         }
                         if (completion)
                             completion(url.length > 0 ? url : nil, error);
                     }];
}

+ (void)spk_postThreadAction:(NSString *)action
                    threadId:(NSString *)threadId
                  parameters:(NSDictionary *)parameters
                  completion:(SPKAPICompletion)completion {
    if (threadId.length == 0) {
        if (completion)
            completion(nil, nil);
        return;
    }
    // Empty (not nil) body: these endpoints reject a bodyless POST.
    NSString *path = [NSString stringWithFormat:@"direct_v2/threads/%@/%@/", threadId, action];
    [self sendRequestWithMethod:@"POST"
                           path:path
                           body:parameters ?: @{}
                     completion:^(NSDictionary *response, NSError *error) {
                         // The mute endpoints are the one place Sparkle writes account
                         // state that it cannot read back from the UI, so the server's
                         // own answer is logged verbatim.
                         // Flattened: a dictionary description spans lines, and os_log
                         // keeps only the first one.
                         NSString *body = response ? [[[response description]
                                                         stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                                                         stringByReplacingOccurrencesOfString:@"  " withString:@""]
                                                   : @"(no body)";
                         SPKLog(@"Messages", @"[Sparkle DirectAPI] %@ -> %@ error=%@", path, body,
                                error.localizedDescription ?: @"(none)");
                         if (completion)
                             completion(response, error);
                     }];
}

+ (void)setThreadMuted:(BOOL)muted threadId:(NSString *)threadId completion:(SPKAPICompletion)completion {
    [self spk_postThreadAction:muted ? @"mute" : @"unmute" threadId:threadId parameters:nil completion:completion];
}

+ (void)setThreadCallsMuted:(BOOL)muted threadId:(NSString *)threadId completion:(SPKAPICompletion)completion {
    [self setThreadCallsMuted:muted threadId:threadId parameters:nil completion:completion];
}

+ (void)setThreadCallsMuted:(BOOL)muted
                   threadId:(NSString *)threadId
                 parameters:(NSDictionary *)parameters
                 completion:(SPKAPICompletion)completion {
    [self spk_postThreadAction:muted ? @"mute_video_call" : @"unmute_video_call"
                      threadId:threadId
                    parameters:parameters
                    completion:completion];
}

static NSNumber *spkThreadFlag(NSDictionary *thread, NSArray<NSString *> *keys, NSString **matchedKey) {
    for (NSString *key in keys) {
        id value = thread[key];
        if (![value respondsToSelector:@selector(boolValue)])
            continue;
        if (matchedKey)
            *matchedKey = key;
        return @([value boolValue]);
    }
    return nil;
}

+ (void)fetchThreadMuteStateForThreadId:(NSString *)threadId
                             completion:(void (^)(NSNumber *_Nullable, NSNumber *_Nullable, NSError *_Nullable))completion {
    if (!completion)
        return;
    if (threadId.length == 0) {
        completion(nil, nil, nil);
        return;
    }
    // limit=0 asks for the thread's metadata without its message page.
    [self sendRequestWithMethod:@"GET"
                           path:[NSString stringWithFormat:@"direct_v2/threads/%@/?limit=0", threadId]
                           body:nil
                     completion:^(NSDictionary *response, NSError *error) {
                         NSDictionary *thread = [response[@"thread"] isKindOfClass:[NSDictionary class]] ? response[@"thread"] : nil;
                         // The calls flag has gone by more than one name across
                         // versions, and is absent entirely on threads that cannot
                         // take calls.
                         NSString *callsKey = nil;
                         NSNumber *callsMuted = spkThreadFlag(thread, @[ @"vc_muted", @"video_call_muted", @"is_video_call_muted" ], &callsKey);
                         SPKLog(@"Messages", @"[Sparkle DirectAPI] thread %@ callsMuteKey=%@", threadId, callsKey ?: @"(none)");
                         completion(spkThreadFlag(thread, @[ @"muted" ], NULL), callsMuted, error);
                     }];
}

static NSString *spkNormalizePK(NSString *pk) {
    if (pk.length == 0)
        return nil;
    NSRange range = [pk rangeOfString:@"_"];
    if (range.location != NSNotFound) {
        return [pk substringToIndex:range.location];
    }
    return pk;
}

+ (void)fetchWebMediaInfoForPK:(NSString *)mediaPK
                    completion:(nullable SPKAPICompletion)completion {
    if (mediaPK.length == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"SPKInstagramAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: SPKL(@"NETWORK_INSTAGRAM_API_EMPTY_PK_TEXT")}]);
        }
        return;
    }
    
    NSString *normPK = spkNormalizePK(mediaPK);
    
    static NSMutableDictionary<NSString *, NSMutableArray<SPKAPICompletion> *> *pendingCompletions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pendingCompletions = [NSMutableDictionary dictionary];
    });

    @synchronized (pendingCompletions) {
        NSMutableArray<SPKAPICompletion> *callbacks = pendingCompletions[normPK];
        if (callbacks) {
            if (completion) {
                [callbacks addObject:completion];
            }
            return;
        }
        callbacks = [NSMutableArray array];
        if (completion) {
            [callbacks addObject:completion];
        }
        pendingCompletions[normPK] = callbacks;
    }
    
    // WKHTTPCookieStore must be accessed on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        WKHTTPCookieStore *cookieStore = [WKWebsiteDataStore defaultDataStore].httpCookieStore;
        [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *webkitCookies) {
            
            NSString *urlString = [NSString stringWithFormat:@"https://www.instagram.com/api/v1/media/%@/info/", normPK];
            NSURL *url = [NSURL URLWithString:urlString];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            request.HTTPMethod = @"GET";

            // Mimic the web client headers
            [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
            [request setValue:@"936619743392459" forHTTPHeaderField:@"X-IG-App-ID"];
            [request setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
            [request setValue:@"https://www.instagram.com/" forHTTPHeaderField:@"Referer"];

            // Merge cookies from both shared HTTP cookie storage and WebKit cookie store
            NSMutableDictionary<NSString *, NSString *> *cookieDict = [NSMutableDictionary dictionary];
            for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]) {
                if ([cookie.domain containsString:@"instagram.com"]) {
                    cookieDict[cookie.name] = cookie.value;
                }
            }
            for (NSHTTPCookie *cookie in webkitCookies) {
                if ([cookie.domain containsString:@"instagram.com"]) {
                    cookieDict[cookie.name] = cookie.value;
                }
            }

            // Extract sessionid and ds_user_id from the mobile Authorization bearer token
            NSString *authHeader = spkAuthHeader();
            if ([authHeader hasPrefix:@"Bearer IGT:"]) {
                NSRange range = [authHeader rangeOfString:@":" options:NSBackwardsSearch];
                if (range.location != NSNotFound && range.location + 1 < authHeader.length) {
                    NSString *base64Part = [authHeader substringFromIndex:range.location + 1];
                    while (base64Part.length % 4 != 0) {
                        base64Part = [base64Part stringByAppendingString:@"="];
                    }
                    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Part options:NSDataBase64DecodingIgnoreUnknownCharacters];
                    if (data) {
                        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                        if ([parsed isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *json = (NSDictionary *)parsed;
                            NSString *sessionIDValue = json[@"sessionid"];
                            NSString *dsUserIDValue = json[@"ds_user_id"];
                            if (sessionIDValue.length > 0) {
                                cookieDict[@"sessionid"] = sessionIDValue;
                            }
                            if (dsUserIDValue.length > 0) {
                                cookieDict[@"ds_user_id"] = dsUserIDValue;
                            }
                        }
                    }
                }
            }

            // Fallback in case we found it as a merged cookie named "authorization"
            if (cookieDict[@"authorization"] && !cookieDict[@"sessionid"]) {
                NSString *authCookieVal = cookieDict[@"authorization"];
                if ([authCookieVal hasPrefix:@"Bearer IGT:"]) {
                    NSRange range = [authCookieVal rangeOfString:@":" options:NSBackwardsSearch];
                    if (range.location != NSNotFound && range.location + 1 < authCookieVal.length) {
                        NSString *base64Part = [authCookieVal substringFromIndex:range.location + 1];
                        while (base64Part.length % 4 != 0) {
                            base64Part = [base64Part stringByAppendingString:@"="];
                        }
                        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Part options:NSDataBase64DecodingIgnoreUnknownCharacters];
                        if (data) {
                            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if ([parsed isKindOfClass:[NSDictionary class]]) {
                                NSDictionary *json = (NSDictionary *)parsed;
                                if (json[@"sessionid"]) cookieDict[@"sessionid"] = json[@"sessionid"];
                                if (json[@"ds_user_id"]) cookieDict[@"ds_user_id"] = json[@"ds_user_id"];
                            }
                        }
                    }
                }
            }

            NSMutableArray<NSString *> *cookieHeaders = [NSMutableArray array];
            NSString *csrfToken = cookieDict[@"csrftoken"];
            for (NSString *name in cookieDict) {
                if ([name isEqualToString:@"authorization"]) {
                    continue; // Skip mobile-only authorization cookie
                }
                [cookieHeaders addObject:[NSString stringWithFormat:@"%@=%@", name, cookieDict[name]]];
            }

            if (cookieHeaders.count > 0) {
                [request setValue:[cookieHeaders componentsJoinedByString:@"; "] forHTTPHeaderField:@"Cookie"];
            }
            if (csrfToken.length > 0) {
                [request setValue:csrfToken forHTTPHeaderField:@"X-CSRFToken"];
            }

#ifdef SPK_DEV
            SPKLog(@"Downloads", @"[4K Debug] Cookies merged count: %lu", (unsigned long)cookieDict.count);
            for (NSString *name in cookieDict) {
                SPKLog(@"Downloads", @"[4K Debug] Merged Cookie: %@ = %@", name, cookieDict[name]);
            }
            SPKLog(@"Downloads", @"[4K Debug] Request headers: %@", request.allHTTPHeaderFields);
#else
            SPKLog(@"Downloads", @"[4K] Merged cookies count: %lu", (unsigned long)cookieDict.count);
#endif

            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                                             NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                                                                             NSInteger statusCode = httpResponse.statusCode;
                                                                             SPKLog(@"Downloads", @"[4K] fetchWebMediaInfoForPK request finished. Status: %ld", (long)statusCode);
#ifdef SPK_DEV
                                                                             if (error) {
                                                                                 SPKLog(@"Downloads", @"[4K Debug] Request error: %@", error);
                                                                             }
                                                                             if (httpResponse) {
                                                                                 SPKLog(@"Downloads", @"[4K Debug] Response headers: %@", httpResponse.allHeaderFields);
                                                                             }
#endif

                                                                             NSDictionary *parsedResponse = nil;
                                                                             if (data.length > 0) {
                                                                                 @try {
                                                                                     id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                                                                                     if ([parsed isKindOfClass:[NSDictionary class]]) {
                                                                                         parsedResponse = (NSDictionary *)parsed;
                                                                                     } else {
#ifdef SPK_DEV
                                                                                         NSString *rawString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                                                                                         SPKLog(@"Downloads", @"[4K Debug] Response data is not a dictionary. Raw data snippet: %@", 
                                                                                                (rawString.length > 1000 ? [rawString substringToIndex:1000] : rawString));
#endif
                                                                                     }
                                                                                 } @catch (__unused NSException *exception) {
#ifdef SPK_DEV
                                                                                     NSString *rawString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                                                                                     SPKLog(@"Downloads", @"[4K Debug] JSON parsing exception. Raw data snippet: %@", 
                                                                                            (rawString.length > 1000 ? [rawString substringToIndex:1000] : rawString));
#endif
                                                                                 }
                                                                             } else {
#ifdef SPK_DEV
                                                                                 SPKLog(@"Downloads", @"[4K Debug] Response data is empty");
#endif
                                                                             }
                                                                             
                                                                             NSArray<SPKAPICompletion> *callbacksToInvoke = nil;
                                                                             @synchronized (pendingCompletions) {
                                                                                 callbacksToInvoke = [pendingCompletions[normPK] copy];
                                                                                 [pendingCompletions removeObjectForKey:normPK];
                                                                             }
                                                                             
                                                                             dispatch_async(dispatch_get_main_queue(), ^{
                                                                                 for (SPKAPICompletion cb in callbacksToInvoke) {
                                                                                     cb(parsedResponse, error);
                                                                                 }
                                                                             });
                                                                         }];
            [task resume];
        }];
    });
}

+ (void)resolveUserForUsername:(NSString *)username
                    completion:(void (^)(NSDictionary *_Nullable userDict, NSError *_Nullable error))completion {
    NSString *cleanUsername = [SPKUtils sanitizedInstagramUsername:username];
    if (cleanUsername.length == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"SPKInstagramAPI" code:400 userInfo:@{NSLocalizedDescriptionKey: SPKL(@"NETWORK_INSTAGRAM_API_INVALID_USERNAME_TEXT")}]);
        }
        return;
    }

    id session = [SPKUtils activeUserSession];
    if (session) {
        id userStore = [session respondsToSelector:@selector(userStore)] ? [session valueForKey:@"userStore"] : nil;
        if (!userStore && [session respondsToSelector:@selector(userMap)]) {
            userStore = [session valueForKey:@"userMap"];
        }
        if (userStore) {
            id cachedUser = nil;
            @try {
                if ([userStore respondsToSelector:@selector(userWithUsername:)]) {
                    cachedUser = [userStore performSelector:@selector(userWithUsername:) withObject:cleanUsername];
                } else if ([userStore respondsToSelector:@selector(storedUserWithUsername:)]) {
                    cachedUser = [userStore performSelector:@selector(storedUserWithUsername:) withObject:cleanUsername];
                }
            } @catch (__unused id e) {}

            if (cachedUser) {
                NSString *pk = [SPKUtils pkFromIGUser:cachedUser];
                if (pk.length > 0) {
                    NSString *un = [SPKUtils sanitizedInstagramUsername:[cachedUser valueForKey:@"username"]] ?: cleanUsername;
                    NSString *fullName = nil;
                    @try {
                        fullName = [cachedUser valueForKey:@"fullName"] ?: [cachedUser valueForKey:@"full_name"];
                    } @catch (__unused id e) {}
                    NSString *pic = nil;
                    @try {
                        pic = [cachedUser valueForKey:@"profilePicURL"] ?: [cachedUser valueForKey:@"profile_pic_url"];
                        if ([pic isKindOfClass:[NSURL class]]) pic = [(NSURL *)pic absoluteString];
                    } @catch (__unused id e) {}

                    if (completion) {
                        completion(@{
                            @"pk": pk,
                            @"username": un,
                            @"full_name": fullName ?: @"",
                            @"profile_pic_url": pic ?: @""
                        }, nil);
                    }
                    return;
                }
            }
        }
    }

    NSString *encodedUsername = [cleanUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    [self sendRequestWithMethod:@"GET"
                           path:[NSString stringWithFormat:@"users/%@/username_info/", encodedUsername]
                           body:nil
                     completion:^(NSDictionary *response, NSError *error) {
                         NSDictionary *user = [response[@"user"] isKindOfClass:[NSDictionary class]] ? response[@"user"] : nil;
                         if (user && (user[@"pk"] || user[@"id"])) {
                             NSMutableDictionary *mUser = [user mutableCopy];
                             if (!mUser[@"pk"] && mUser[@"id"]) mUser[@"pk"] = [mUser[@"id"] description];
                             if (completion) completion(mUser, nil);
                             return;
                         }

                         [self sendRequestWithMethod:@"GET"
                                                path:[NSString stringWithFormat:@"users/search/?q=%@", encodedUsername]
                                                body:nil
                                          completion:^(NSDictionary *searchResp, NSError *searchErr) {
                             NSArray *users = [searchResp[@"users"] isKindOfClass:[NSArray class]] ? searchResp[@"users"] : nil;
                             for (NSDictionary *u in users) {
                                 if ([u isKindOfClass:[NSDictionary class]]) {
                                     NSString *uName = [u[@"username"] description].lowercaseString;
                                     if ([uName isEqualToString:cleanUsername]) {
                                         NSMutableDictionary *mUser = [u mutableCopy];
                                         if (!mUser[@"pk"] && mUser[@"id"]) mUser[@"pk"] = [mUser[@"id"] description];
                                         if (completion) completion(mUser, nil);
                                         return;
                                     }
                                 }
                             }

                             [self sendRequestWithMethod:@"GET"
                                                    path:[NSString stringWithFormat:@"users/web_profile_info/?username=%@", encodedUsername]
                                                    body:nil
                                              completion:^(NSDictionary *webResp, NSError *webErr) {
                                 NSDictionary *webUser = [webResp[@"data"][@"user"] isKindOfClass:[NSDictionary class]] ? webResp[@"data"][@"user"] : webResp[@"user"];
                                 if ([webUser isKindOfClass:[NSDictionary class]] && (webUser[@"id"] || webUser[@"pk"])) {
                                     NSMutableDictionary *mUser = [webUser mutableCopy];
                                     if (!mUser[@"pk"] && mUser[@"id"]) mUser[@"pk"] = [mUser[@"id"] description];
                                     if (completion) completion(mUser, nil);
                                 } else {
                                     if (completion) completion(nil, webErr ?: searchErr ?: error);
                                 }
                             }];
                         }];
                     }];
}

@end
