#import "SPKNetworkInterceptor.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <substrate.h>
#import <zlib.h>

#import "../../Utils.h"

NSString *const kSPKNetworkInterceptorRecordingKey = @"tools_netlog_recording";
NSNotificationName const SPKNetworkInterceptorDidChangeNotification = @"SPKNetworkInterceptorDidChangeNotification";

// Bounds on what a recording session can hold. Media bodies are never buffered,
// so these only ever fill with API / GraphQL JSON.
static const NSUInteger kSPKNetworkMaxEntries = 1000;
static const NSUInteger kSPKNetworkMaxResponseBody = 2 * 1024 * 1024;
static const NSUInteger kSPKNetworkMaxRequestBody = 1024 * 1024;
static const NSUInteger kSPKNetworkBodyBudget = 48 * 1024 * 1024;

static atomic_bool spkNetworkRecording = false;
static atomic_uint spkNetworkNextIdentifier = 1;
static atomic_bool spkNetworkChangePending = false;

// Guards the entry list, the body budget and every entry's mutable state.
// Callbacks arrive on Tigon's threads while the UI reads on main.
static os_unfair_lock spkNetworkLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<SPKNetworkEntry *> *spkNetworkEntries = nil;
static NSUInteger spkNetworkBufferedBytes = 0;

static char kSPKNetworkEntryAssociationKey;

static void SPKNetworkPostChange(void);

// MARK: - Helpers

static id SPKNetworkKV(id object, NSString *key) {
    if (!object)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *SPKNetworkHeader(NSDictionary<NSString *, NSString *> *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = headers[key];
            return [value isKindOfClass:NSString.class] ? value : [value description];
        }
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *SPKNetworkStringDictionary(id value) {
    if (![value isKindOfClass:NSDictionary.class])
        return @{};
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
        out[[key description]] = [obj isKindOfClass:NSString.class] ? obj : [obj description];
    }];
    return out;
}

static BOOL SPKNetworkIsGzip(NSData *data) {
    if (data.length < 2)
        return NO;
    const uint8_t *bytes = data.bytes;
    return bytes[0] == 0x1f && bytes[1] == 0x8b;
}

// zlib is in the shared cache but not linked by the tweak; resolving it at run
// time keeps a dev-only need out of the release load commands.
static NSData *SPKNetworkGunzip(NSData *data) {
    typedef int (*InflateInit2Fn)(z_streamp, int, const char *, int);
    typedef int (*InflateFn)(z_streamp, int);
    typedef int (*InflateEndFn)(z_streamp);
    static InflateInit2Fn inflateInit2Fn;
    static InflateFn inflateFn;
    static InflateEndFn inflateEndFn;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY);
        if (!handle)
            return;
        inflateInit2Fn = (InflateInit2Fn)dlsym(handle, "inflateInit2_");
        inflateFn = (InflateFn)dlsym(handle, "inflate");
        inflateEndFn = (InflateEndFn)dlsym(handle, "inflateEnd");
    });
    if (!inflateInit2Fn || !inflateFn || !inflateEndFn || data.length == 0)
        return nil;

    z_stream stream = {0};
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    // 16 + MAX_WBITS: expect a gzip header.
    if (inflateInit2Fn(&stream, 16 + MAX_WBITS, ZLIB_VERSION, (int)sizeof(z_stream)) != Z_OK)
        return nil;

    NSMutableData *output = [NSMutableData dataWithLength:MAX(data.length * 4, (NSUInteger)4096)];
    int status = Z_OK;
    while (status == Z_OK) {
        if (stream.total_out >= output.length) {
            if (output.length >= kSPKNetworkMaxRequestBody * 4)
                break;
            [output increaseLengthBy:output.length];
        }
        stream.next_out = (Bytef *)output.mutableBytes + stream.total_out;
        stream.avail_out = (uInt)(output.length - stream.total_out);
        status = inflateFn(&stream, Z_SYNC_FLUSH);
    }
    inflateEndFn(&stream);
    if (status != Z_STREAM_END && status != Z_OK)
        return nil;
    output.length = stream.total_out;
    return output;
}

static NSString *SPKNetworkMethodName(id value) {
    if ([value isKindOfClass:NSString.class])
        return [(NSString *)value uppercaseString];
    if ([value isKindOfClass:NSNumber.class]) {
        // 0 and 1 are confirmed on device; other values have not been observed.
        switch ([(NSNumber *)value integerValue]) {
        case 0:
            return @"GET";
        case 1:
            return @"POST";
        default:
            return [NSString stringWithFormat:@"METHOD %@", value];
        }
    }
    return @"?";
}

static NSString *SPKNetworkPercentDecode(NSString *value) {
    NSString *spaced = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [spaced stringByRemovingPercentEncoding] ?: spaced;
}

static NSArray<NSArray<NSString *> *> *SPKNetworkFormPairs(NSString *body) {
    if (body.length == 0 || [body rangeOfString:@"="].location == NSNotFound)
        return nil;
    if ([body hasPrefix:@"{"] || [body hasPrefix:@"["])
        return nil;
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *component in [body componentsSeparatedByString:@"&"]) {
        if (component.length == 0)
            continue;
        NSRange equals = [component rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? component : [component substringToIndex:equals.location];
        NSString *value = equals.location == NSNotFound ? @"" : [component substringFromIndex:equals.location + 1];
        [pairs addObject:@[ SPKNetworkPercentDecode(key), SPKNetworkPercentDecode(value) ]];
    }
    return pairs;
}

static NSString *SPKNetworkFormValue(NSArray<NSArray<NSString *> *> *pairs, NSArray<NSString *> *keys) {
    for (NSString *wanted in keys) {
        for (NSArray<NSString *> *pair in pairs) {
            if ([pair[0] isEqualToString:wanted] && pair[1].length > 0)
                return pair[1];
        }
    }
    return nil;
}

// MARK: - Redaction

// Captures get copied, exported and screenshotted to share with others, so the
// credentials and device identifiers that ride along with every request are removed
// as they are recorded. Nothing secret is ever held, and every way out of the log is
// covered at once. The cURL copy loses its session as a result and cannot be replayed
// as is.
static NSString *const kSPKNetworkRedacted = @"<redacted>";

static BOOL SPKNetworkIsSensitiveHeader(NSString *name) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"authorization", @"cookie", @"set-cookie", @"proxy-authorization",
            @"ig-intended-user-id", @"ig-u-ds-user-id", @"ig-u-rur", @"ig-u-ig-direct-region-hint", @"ig-u-shbid", @"ig-u-shbts",
            @"x-mid", @"x-ig-www-claim", @"x-ig-set-www-claim", @"x-cloud-trust-token",
            @"x-ig-device-id", @"x-ig-family-device-id", @"x-ig-android-id", @"x-pigeon-session-id",
            @"x-fb-client-ip-forwarded", @"x-fb-client-ip", @"x-forwarded-for",
        ]];
    });
    NSString *lower = name.lowercaseString;
    // Responses hand out fresh credentials as ig-set-authorization, ig-set-x-mid, ...
    return [names containsObject:lower] || [lower hasPrefix:@"ig-set-"];
}

static NSDictionary<NSString *, NSString *> *SPKNetworkRedactedHeaders(NSDictionary<NSString *, NSString *> *headers) {
    NSMutableDictionary<NSString *, NSString *> *out = [headers mutableCopy];
    for (NSString *name in headers) {
        if (SPKNetworkIsSensitiveHeader(name))
            out[name] = kSPKNetworkRedacted;
    }
    return out;
}

// Body and query fields that carry credentials or identify the device.
static NSString *const kSPKNetworkSensitiveFieldPattern =
    @"_?uuid|_?uid|device_id|android_id|phone_id|family_device_id|guid|adid|advertising_id|"
    @"access_token|authorization|password|enc_password|sessionid|session_id|csrftoken|ds_user_id|"
    @"mid|machine_id|www_claim|nonce|two_factor_identifier|verification_code";

static BOOL SPKNetworkIsSensitiveField(NSString *name) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *pattern = [NSString stringWithFormat:@"^(?:%@)$", kSPKNetworkSensitiveFieldPattern];
        regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return name.length > 0 && [regex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

/// Blanks sensitive fields in JSON text, including JSON escaped inside a JSON string
/// (signed_body payloads and GraphQL variables).
static NSString *SPKNetworkRedactedText(NSString *text) {
    static NSRegularExpression *plain, *escaped;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *plainPattern = [NSString stringWithFormat:@"(\"(?:%@)\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|-?[0-9]+)", kSPKNetworkSensitiveFieldPattern];
        NSString *escapedPattern = [NSString stringWithFormat:@"(\\\\\"(?:%@)\\\\\"\\s*:\\s*)(\\\\\"[^\"\\\\]*\\\\\"|-?[0-9]+)", kSPKNetworkSensitiveFieldPattern];
        plain = [NSRegularExpression regularExpressionWithPattern:plainPattern options:NSRegularExpressionCaseInsensitive error:nil];
        escaped = [NSRegularExpression regularExpressionWithPattern:escapedPattern options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (text.length == 0 || [text rangeOfString:@":"].location == NSNotFound)
        return text;
    NSString *out = [plain stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                               withTemplate:[NSString stringWithFormat:@"$1\"%@\"", kSPKNetworkRedacted]];
    return [escaped stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length)
                                        withTemplate:[NSString stringWithFormat:@"$1\\\\\"%@\\\\\"", kSPKNetworkRedacted]];
}

static NSString *SPKNetworkFormEncode(NSString *value) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
        [set addCharactersInString:@"-._*"];
        allowed = [set copy];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: value;
}

/// A urlencoded form keeps its encoding: sensitive fields are blanked, and any other
/// value is decoded, redacted as text and re-encoded only when that changed it.
static NSString *SPKNetworkRedactedForm(NSString *body) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [body componentsSeparatedByString:@"&"]) {
        NSRange equals = [component rangeOfString:@"="];
        if (equals.location == NSNotFound) {
            [components addObject:component];
            continue;
        }
        NSString *rawKey = [component substringToIndex:equals.location];
        NSString *rawValue = [component substringFromIndex:NSMaxRange(equals)];
        if (SPKNetworkIsSensitiveField(SPKNetworkPercentDecode(rawKey))) {
            [components addObject:[NSString stringWithFormat:@"%@=%@", rawKey, SPKNetworkFormEncode(kSPKNetworkRedacted)]];
            continue;
        }
        NSString *value = SPKNetworkPercentDecode(rawValue);
        NSString *redacted = SPKNetworkRedactedText(value);
        [components addObject:[redacted isEqualToString:value] ? component : [NSString stringWithFormat:@"%@=%@", rawKey, SPKNetworkFormEncode(redacted)]];
    }
    return [components componentsJoinedByString:@"&"];
}

static NSData *SPKNetworkRedactedBody(NSData *body) {
    if (body.length == 0)
        return body;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text)
        return body; // binary (multipart, thrift): shown only as a byte count
    NSString *redacted = SPKNetworkFormPairs(text) ? SPKNetworkRedactedForm(text) : SPKNetworkRedactedText(text);
    return redacted == text ? body : [redacted dataUsingEncoding:NSUTF8StringEncoding];
}

static NSURL *SPKNetworkRedactedURL(NSURL *url) {
    if (!url.query.length)
        return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    BOOL changed = NO;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if (SPKNetworkIsSensitiveField(item.name)) {
            [items addObject:[NSURLQueryItem queryItemWithName:item.name value:kSPKNetworkRedacted]];
            changed = YES;
        } else {
            [items addObject:item];
        }
    }
    if (!changed)
        return url;
    components.queryItems = items;
    return components.URL ?: url;
}

static BOOL SPKNetworkIsMediaHost(NSString *host) {
    host = host.lowercaseString;
    return [host hasSuffix:@"fbcdn.net"] || [host hasSuffix:@"cdninstagram.com"] || [host hasSuffix:@"fbsbx.com"];
}

static BOOL SPKNetworkIsMediaMIME(NSString *mime) {
    mime = mime.lowercaseString;
    return [mime hasPrefix:@"image/"] || [mime hasPrefix:@"video/"] || [mime hasPrefix:@"audio/"];
}

static BOOL SPKNetworkIsTextualMIME(NSString *mime) {
    if (mime.length == 0)
        return YES;
    mime = mime.lowercaseString;
    return [mime hasPrefix:@"text/"] || [mime containsString:@"json"] || [mime containsString:@"javascript"] ||
           [mime containsString:@"xml"] || [mime containsString:@"x-www-form-urlencoded"] || [mime containsString:@"graphql"];
}

static NSString *SPKNetworkShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

NSString *SPKNetworkInterceptorReadableBody(NSData *data) {
    if (data.length == 0)
        return nil;
    NSData *jsonData = data;
    static NSData *hijackPrefix;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hijackPrefix = [@"for (;;);" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if (data.length > hijackPrefix.length &&
        [[data subdataWithRange:NSMakeRange(0, hijackPrefix.length)] isEqualToData:hijackPrefix])
        jsonData = [data subdataWithRange:NSMakeRange(hijackPrefix.length, data.length - hijackPrefix.length)];

    id object = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingFragmentsAllowed error:nil];
    if (object && ([object isKindOfClass:NSDictionary.class] || [object isKindOfClass:NSArray.class])) {
        NSJSONWritingOptions options = NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
        options |= NSJSONWritingWithoutEscapingSlashes;
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:object options:options error:nil];
        NSString *string = pretty ? [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding] : nil;
        if (string)
            return string;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text)
        return nil;
    // Treat mostly-control-character payloads as binary even when they decode.
    NSUInteger sample = MIN(text.length, (NSUInteger)512), control = 0;
    for (NSUInteger i = 0; i < sample; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < 0x20 && c != '\n' && c != '\r' && c != '\t')
            control++;
    }
    return (sample > 0 && control * 10 > sample) ? nil : text;
}

// MARK: - Entry

@interface SPKNetworkEntry ()
@property (nonatomic, readwrite) NSUInteger identifier;
@property (atomic, readwrite) NSDate *startDate;
@property (atomic, readwrite, copy) NSString *method;
@property (atomic, readwrite, nullable) NSURL *URL;
@property (atomic, readwrite, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (atomic, readwrite, nullable) NSData *requestBody;
@property (atomic, readwrite) BOOL requestBodyWasGzip;
@property (atomic, readwrite, copy, nullable) NSString *requestBodyNote;
@property (atomic, readwrite, copy, nullable) NSString *graphQLName;
@property (atomic, readwrite, copy, nullable) NSString *graphQLDocumentID;
@property (atomic, readwrite, copy, nullable) NSString *surface;
@property (atomic, readwrite) SPKNetworkEntryKind kind;
@property (atomic, readwrite) SPKNetworkEntryState state;
@property (atomic, readwrite) NSInteger statusCode;
@property (atomic, readwrite, copy, nullable) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (atomic, readwrite, copy, nullable) NSString *MIMEType;
@property (atomic, readwrite) long long responseBytes;
@property (atomic, readwrite) NSTimeInterval duration;
@property (atomic, readwrite, copy, nullable) NSString *errorDescription;
@property (atomic, readwrite) BOOL responseBodySkipped;
@property (atomic, readwrite) BOOL responseBodyTruncated;
@property (atomic, readwrite) BOOL responseObserved;
@end

@implementation SPKNetworkEntry {
    NSMutableData *_responseBody; // guarded by spkNetworkLock
    CFAbsoluteTime _startTime;
}

- (nullable NSData *)responseBodySnapshot {
    os_unfair_lock_lock(&spkNetworkLock);
    NSData *copy = [_responseBody copy];
    os_unfair_lock_unlock(&spkNetworkLock);
    // Kept raw while it streams in, since a field can straddle two chunks.
    return SPKNetworkRedactedBody(copy);
}

- (NSString *)displayTitle {
    if (self.graphQLName.length > 0)
        return self.graphQLName;
    NSString *path = self.URL.path;
    return path.length > 0 ? path : (self.URL.absoluteString ?: @"?");
}

- (NSString *)curlCommand {
    NSMutableString *command = [NSMutableString stringWithFormat:@"curl -X %@ %@", self.method, SPKNetworkShellQuote(self.URL.absoluteString ?: @"")];
    NSArray<NSString *> *names = [self.requestHeaders.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *name in names) {
        // The body below is the decompressed one, so its framing headers no longer apply.
        if (self.requestBodyWasGzip && ([name caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame ||
                                        [name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame))
            continue;
        [command appendFormat:@" \\\n  -H %@", SPKNetworkShellQuote([NSString stringWithFormat:@"%@: %@", name, self.requestHeaders[name]])];
    }
    NSData *body = self.requestBody;
    if (body.length > 0) {
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (text)
            [command appendFormat:@" \\\n  --data-binary %@", SPKNetworkShellQuote(text)];
        else
            [command appendFormat:@" \\\n  # binary body (%lu bytes) omitted", (unsigned long)body.length];
    }
    return command;
}

- (void)spk_beginWithRequest:(id)request policy:(id)policy {
    _startTime = CFAbsoluteTimeGetCurrent();
    self.startDate = [NSDate date];

    id url = SPKNetworkKV(request, @"URL");
    if ([url isKindOfClass:NSString.class])
        url = [NSURL URLWithString:url];
    self.URL = [url isKindOfClass:NSURL.class] ? SPKNetworkRedactedURL(url) : nil;
    self.method = SPKNetworkMethodName(SPKNetworkKV(request, @"HTTPMethod"));
    self.requestHeaders = SPKNetworkRedactedHeaders(SPKNetworkStringDictionary(SPKNetworkKV(request, @"allHTTPHeaderFields")));

    id surface = SPKNetworkKV(policy, @"surface");
    self.surface = [surface isKindOfClass:NSString.class] && [surface length] > 0 ? surface : nil;

    id body = SPKNetworkKV(request, @"body");
    if (body) {
        id data = SPKNetworkKV(body, @"dataBodyData");
        if ([data isKindOfClass:NSData.class] && [data length] > 0) {
            NSData *bodyData = data;
            if (SPKNetworkIsGzip(bodyData)) {
                NSData *inflated = SPKNetworkGunzip(bodyData);
                if (inflated) {
                    bodyData = inflated;
                    self.requestBodyWasGzip = YES;
                }
            }
            if (bodyData.length > kSPKNetworkMaxRequestBody) {
                self.requestBodyNote = [NSString stringWithFormat:@"%lu bytes", (unsigned long)bodyData.length];
                bodyData = [bodyData subdataWithRange:NSMakeRange(0, kSPKNetworkMaxRequestBody)];
            }
            self.requestBody = SPKNetworkRedactedBody(bodyData);
        } else {
            id file = SPKNetworkKV(body, @"fileURLFileURL") ?: SPKNetworkKV(body, @"tailingFileURLTailingFileURL");
            if ([file isKindOfClass:NSURL.class])
                self.requestBodyNote = [@"file " stringByAppendingString:[(NSURL *)file lastPathComponent] ?: @"?"];
            else if (SPKNetworkKV(body, @"httpBodyGenerator"))
                self.requestBodyNote = @"stream";
        }
    }

    NSString *name = SPKNetworkHeader(self.requestHeaders, @"X-FB-Friendly-Name");
    NSString *documentID = SPKNetworkHeader(self.requestHeaders, @"X-Client-Doc-Id");
    if ((!name || !documentID) && self.requestBody.length > 0 && self.requestBody.length < 256 * 1024) {
        NSString *text = [[NSString alloc] initWithData:self.requestBody encoding:NSUTF8StringEncoding];
        NSArray *pairs = SPKNetworkFormPairs(text);
        name = name ?: SPKNetworkFormValue(pairs, @[ @"fb_api_req_friendly_name" ]);
        documentID = documentID ?: SPKNetworkFormValue(pairs, @[ @"client_doc_id", @"doc_id" ]);
    }
    self.graphQLName = name;
    self.graphQLDocumentID = documentID;

    NSString *host = self.URL.host ?: @"";
    NSString *path = self.URL.path.lowercaseString ?: @"";
    if (SPKNetworkIsMediaHost(host))
        self.kind = SPKNetworkEntryKindMedia;
    else if (name.length > 0 || [path containsString:@"graphql"])
        self.kind = SPKNetworkEntryKindGraphQL;
    else if ([host.lowercaseString hasSuffix:@"instagram.com"] || [path hasPrefix:@"/api/"])
        self.kind = SPKNetworkEntryKindAPI;
    else
        self.kind = SPKNetworkEntryKindOther;
}

- (void)spk_handleResponse:(id)response {
    self.responseObserved = YES;
    if (![response isKindOfClass:NSHTTPURLResponse.class])
        return;
    NSHTTPURLResponse *http = response;
    self.statusCode = http.statusCode;
    self.responseHeaders = SPKNetworkRedactedHeaders(SPKNetworkStringDictionary(http.allHeaderFields));
    self.MIMEType = http.MIMEType;
    if (!self.URL)
        self.URL = SPKNetworkRedactedURL(http.URL);
    if (SPKNetworkIsMediaMIME(http.MIMEType))
        self.kind = SPKNetworkEntryKindMedia;
    if (self.kind == SPKNetworkEntryKindMedia || !SPKNetworkIsTextualMIME(http.MIMEType))
        self.responseBodySkipped = YES;
    SPKNetworkPostChange();
}

- (void)spk_appendBytes:(const char *)bytes length:(unsigned long long)length {
    self.responseObserved = YES;
    self.responseBytes += (long long)length;
    if (!bytes || length == 0 || self.kind == SPKNetworkEntryKindMedia || self.responseBodySkipped)
        return;
    os_unfair_lock_lock(&spkNetworkLock);
    NSUInteger current = _responseBody.length;
    if (current < kSPKNetworkMaxResponseBody) {
        NSUInteger take = (NSUInteger)MIN((unsigned long long)(kSPKNetworkMaxResponseBody - current), length);
        if (!_responseBody)
            _responseBody = [NSMutableData dataWithCapacity:(NSUInteger)MIN(length, (unsigned long long)65536)];
        [_responseBody appendBytes:bytes length:take];
        spkNetworkBufferedBytes += take;
        if (take < length)
            self.responseBodyTruncated = YES;
    } else {
        self.responseBodyTruncated = YES;
    }
    os_unfair_lock_unlock(&spkNetworkLock);
}

- (void)spk_finishWithError:(id)error {
    self.responseObserved = YES;
    self.duration = CFAbsoluteTimeGetCurrent() - _startTime;
    if (error) {
        self.state = SPKNetworkEntryStateFailed;
        self.errorDescription = [error isKindOfClass:NSError.class] ? [(NSError *)error localizedDescription] : [error description];
    } else {
        self.state = SPKNetworkEntryStateSucceeded;
    }
    SPKNetworkPostChange();
}

// Called with spkNetworkLock held.
- (NSUInteger)spk_dropBodyLocked {
    NSUInteger freed = _responseBody.length;
    _responseBody = nil;
    return freed;
}

@end

// MARK: - Store

static void SPKNetworkPostChange(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&spkNetworkChangePending, &expected, true))
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        atomic_store(&spkNetworkChangePending, false);
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKNetworkInterceptorDidChangeNotification object:nil];
    });
}

static void SPKNetworkStoreAdd(SPKNetworkEntry *entry) {
    os_unfair_lock_lock(&spkNetworkLock);
    if (!spkNetworkEntries)
        spkNetworkEntries = [NSMutableArray array];
    [spkNetworkEntries addObject:entry];
    while (spkNetworkEntries.count > kSPKNetworkMaxEntries || (spkNetworkBufferedBytes > kSPKNetworkBodyBudget && spkNetworkEntries.count > 1)) {
        SPKNetworkEntry *oldest = spkNetworkEntries.firstObject;
        NSUInteger freed = [oldest spk_dropBodyLocked];
        spkNetworkBufferedBytes -= MIN(freed, spkNetworkBufferedBytes);
        [spkNetworkEntries removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&spkNetworkLock);
    SPKNetworkPostChange();
}

NSArray<SPKNetworkEntry *> *SPKNetworkInterceptorEntries(void) {
    os_unfair_lock_lock(&spkNetworkLock);
    NSArray *snapshot = spkNetworkEntries.reverseObjectEnumerator.allObjects ?: @[];
    os_unfair_lock_unlock(&spkNetworkLock);
    return snapshot;
}

void SPKNetworkInterceptorClear(void) {
    os_unfair_lock_lock(&spkNetworkLock);
    for (SPKNetworkEntry *entry in spkNetworkEntries)
        [entry spk_dropBodyLocked];
    [spkNetworkEntries removeAllObjects];
    spkNetworkBufferedBytes = 0;
    os_unfair_lock_unlock(&spkNetworkLock);
    SPKNetworkPostChange();
}

// MARK: - Callback hooks
//
// The response reaches the callbacks object IG passes with the request. On 454
// that is always IGCompositeNetworkCallbacks, but the class is hooked from the
// instance actually seen, so a different callbacks class on another IG version
// is covered too. Each replacement IMP is remembered so an inherited method that
// is already ours is never wrapped twice (which would record every byte twice).

static os_unfair_lock spkNetworkHookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSValue *> *spkNetworkOurImps = nil;
static NSMutableSet<Class> *spkNetworkHookedCallbackClasses = nil;

static SPKNetworkEntry *SPKNetworkEntryFor(id callbacks) {
    return objc_getAssociatedObject(callbacks, &kSPKNetworkEntryAssociationKey);
}

// Called with spkNetworkHookLock held. Returns a heap slot that receives the
// original IMP, pre-filled before the swap so a call racing the hook still
// reaches the original.
static IMP *SPKNetworkHookSlot(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return NULL;
    IMP current = method_getImplementation(method);
    if ([spkNetworkOurImps containsObject:[NSValue valueWithPointer:(const void *)current]])
        return NULL;
    IMP *slot = calloc(1, sizeof(IMP));
    *slot = current;
    return slot;
}

static void SPKNetworkInstall(Class cls, SEL selector, IMP *slot, id block) {
    IMP replacement = imp_implementationWithBlock(block);
    [spkNetworkOurImps addObject:[NSValue valueWithPointer:(const void *)replacement]];
    MSHookMessageEx(cls, selector, replacement, slot);
}

static void SPKNetworkHookCallbacksClass(Class cls) {
    if (!cls)
        return;
    os_unfair_lock_lock(&spkNetworkHookLock);
    if ([spkNetworkHookedCallbackClasses containsObject:cls]) {
        os_unfair_lock_unlock(&spkNetworkHookLock);
        return;
    }
    [spkNetworkHookedCallbackClasses addObject:cls];

    SEL responseSel = @selector(responseReceived:);
    IMP *responseSlot = SPKNetworkHookSlot(cls, responseSel, nil);
    if (responseSlot) {
        SPKNetworkInstall(cls, responseSel, responseSlot, ^(id self, id response) {
            SPKNetworkEntry *entry = SPKNetworkEntryFor(self);
            if (entry)
                [entry spk_handleResponse:response];
            ((void (*)(id, SEL, id))*responseSlot)(self, responseSel, response);
        });
    }

    SEL bytesSel = @selector(bytesReceived:len:totalBytesExpectedToReceive:);
    IMP *bytesSlot = SPKNetworkHookSlot(cls, bytesSel, nil);
    if (bytesSlot) {
        SPKNetworkInstall(cls, bytesSel, bytesSlot, ^(id self, const char *bytes, unsigned long long length, long long expected) {
            SPKNetworkEntry *entry = SPKNetworkEntryFor(self);
            if (entry)
                [entry spk_appendBytes:bytes length:length];
            ((void (*)(id, SEL, const char *, unsigned long long, long long))*bytesSlot)(self, bytesSel, bytes, length, expected);
        });
    }

    SEL successSel = @selector(success:);
    IMP *successSlot = SPKNetworkHookSlot(cls, successSel, nil);
    if (successSlot) {
        SPKNetworkInstall(cls, successSel, successSlot, ^(id self, id summary) {
            SPKNetworkEntry *entry = SPKNetworkEntryFor(self);
            if (entry)
                [entry spk_finishWithError:nil];
            ((void (*)(id, SEL, id))*successSlot)(self, successSel, summary);
        });
    }

    SEL failureSel = @selector(failure:summary:);
    IMP *failureSlot = SPKNetworkHookSlot(cls, failureSel, nil);
    if (failureSlot) {
        SPKNetworkInstall(cls, failureSel, failureSlot, ^(id self, id error, id summary) {
            SPKNetworkEntry *entry = SPKNetworkEntryFor(self);
            if (entry)
                [entry spk_finishWithError:error ?: @"failure"];
            ((void (*)(id, SEL, id, id))*failureSlot)(self, failureSel, error, summary);
        });
    }
    os_unfair_lock_unlock(&spkNetworkHookLock);
    SPKLog(@"NetLog", @"tapped callbacks class %@", NSStringFromClass(cls));
}

// MARK: - Layer hook

static id (*orig_IGTigonNetworkLayer_startRequest)(id, SEL, id, id, id);

static id hook_IGTigonNetworkLayer_startRequest(id self, SEL _cmd, id request, id policy, id callbacks) {
    if (atomic_load(&spkNetworkRecording) && request) {
        @try {
            SPKNetworkEntry *entry = [SPKNetworkEntry new];
            entry.identifier = atomic_fetch_add(&spkNetworkNextIdentifier, 1);
            [entry spk_beginWithRequest:request policy:policy];
            if (callbacks) {
                SPKNetworkHookCallbacksClass(object_getClass(callbacks));
                objc_setAssociatedObject(callbacks, &kSPKNetworkEntryAssociationKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            SPKNetworkStoreAdd(entry);
        } @catch (NSException *exception) {
            SPKLog(@"NetLog", @"capture failed: %@", exception);
        }
    }
    return orig_IGTigonNetworkLayer_startRequest(self, _cmd, request, policy, callbacks);
}

static void SPKNetworkInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        spkNetworkOurImps = [NSMutableSet set];
        spkNetworkHookedCallbackClasses = [NSMutableSet set];
        Class layer = NSClassFromString(@"IGTigonNetworkLayer");
        SEL selector = @selector(startRequest:policy:callbacks:);
        if (!layer || !class_getInstanceMethod(layer, selector)) {
            SPKLog(@"NetLog", @"IGTigonNetworkLayer startRequest:policy:callbacks: not found; nothing to intercept");
            return;
        }
        MSHookMessageEx(layer, selector, (IMP)hook_IGTigonNetworkLayer_startRequest, (IMP *)&orig_IGTigonNetworkLayer_startRequest);
        SPKLog(@"NetLog", @"hooked IGTigonNetworkLayer startRequest:policy:callbacks:");
    });
}

void SPKNetworkInterceptorInstallIfEnabled(void) {
    if (![SPKUtils getBoolPref:kSPKNetworkInterceptorRecordingKey])
        return;
    atomic_store(&spkNetworkRecording, true);
    SPKNetworkInstallHooks();
}

BOOL SPKNetworkInterceptorIsRecording(void) {
    return atomic_load(&spkNetworkRecording);
}

void SPKNetworkInterceptorSetRecording(BOOL recording) {
    SPKPreferenceSetObject(@(recording), kSPKNetworkInterceptorRecordingKey);
    if (recording)
        SPKNetworkInstallHooks();
    atomic_store(&spkNetworkRecording, recording);
    SPKNetworkPostChange();
}
