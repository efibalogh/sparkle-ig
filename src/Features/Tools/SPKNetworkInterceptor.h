// Network interceptor: records Instagram's own HTTP traffic (REST, GraphQL and
// CDN media) for inspection inside the app.
//
// FLEX's network observer only sees NSURLSession, which carries a handful of
// SDK requests. Instagram sends everything else through its own Tigon stack, and
// every one of those requests passes the bottom of the IGNetworkLayer chain:
// -[IGTigonNetworkLayer startRequest:policy:callbacks:]. The request is read
// there through KVC (on 450+ it is an IGNetworkingRequest, a devirtualized value
// object with no ObjC accessors, but its valueForKey: answers URL, HTTPMethod,
// allHTTPHeaderFields and body), and the response is taken from the callbacks
// object that rides along with it.
//
// MQTT realtime traffic (Direct delivery, typing, presence) does not use HTTP
// and is not captured.
//
// Nothing is hooked until recording is first turned on. The recording holds auth
// headers and private data, and lives in memory only.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Global (not per-account) dev preference: whether recording is on.
FOUNDATION_EXPORT NSString *const kSPKNetworkInterceptorRecordingKey;

/// Posted on the main queue, coalesced, whenever entries are added or change.
FOUNDATION_EXPORT NSNotificationName const SPKNetworkInterceptorDidChangeNotification;

typedef NS_ENUM(NSInteger, SPKNetworkEntryKind) {
    SPKNetworkEntryKindAPI,
    SPKNetworkEntryKindGraphQL,
    SPKNetworkEntryKindMedia,
    SPKNetworkEntryKindOther,
};

typedef NS_ENUM(NSInteger, SPKNetworkEntryState) {
    SPKNetworkEntryStatePending,
    SPKNetworkEntryStateSucceeded,
    SPKNetworkEntryStateFailed,
};

@interface SPKNetworkEntry : NSObject

@property (nonatomic, readonly) NSUInteger identifier;
@property (atomic, readonly) NSDate *startDate;
@property (atomic, readonly, copy) NSString *method;
@property (atomic, readonly, nullable) NSURL *URL;
@property (atomic, readonly, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
/// Decompressed when the request body was gzip.
@property (atomic, readonly, nullable) NSData *requestBody;
@property (atomic, readonly) BOOL requestBodyWasGzip;
/// Set instead of requestBody for file uploads and streamed bodies.
@property (atomic, readonly, copy, nullable) NSString *requestBodyNote;
@property (atomic, readonly, copy, nullable) NSString *graphQLName;
@property (atomic, readonly, copy, nullable) NSString *graphQLDocumentID;
@property (atomic, readonly, copy, nullable) NSString *surface;

@property (atomic, readonly) SPKNetworkEntryKind kind;
@property (atomic, readonly) SPKNetworkEntryState state;
@property (atomic, readonly) NSInteger statusCode;
@property (atomic, readonly, copy, nullable) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (atomic, readonly, copy, nullable) NSString *MIMEType;
@property (atomic, readonly) long long responseBytes;
@property (atomic, readonly) NSTimeInterval duration;
@property (atomic, readonly, copy, nullable) NSString *errorDescription;
/// YES when the response body was deliberately not buffered (media).
@property (atomic, readonly) BOOL responseBodySkipped;
/// YES when the buffered body hit the per-response cap.
@property (atomic, readonly) BOOL responseBodyTruncated;
/// Whether the response callbacks could be observed for this request.
@property (atomic, readonly) BOOL responseObserved;

/// Thread-safe copy of the buffered response body.
- (nullable NSData *)responseBodySnapshot;
/// GraphQL name, else the URL path.
- (NSString *)displayTitle;
/// A runnable cURL command reproducing the request, auth headers included.
- (NSString *)curlCommand;

@end

/// Installs the hooks if recording is on. Called from the launch-critical stage
/// so requests made during startup are captured.
FOUNDATION_EXPORT void SPKNetworkInterceptorInstallIfEnabled(void);

FOUNDATION_EXPORT BOOL SPKNetworkInterceptorIsRecording(void);
/// Persists the preference and installs the hooks on first enable.
FOUNDATION_EXPORT void SPKNetworkInterceptorSetRecording(BOOL recording);

/// Snapshot, newest first.
FOUNDATION_EXPORT NSArray<SPKNetworkEntry *> *SPKNetworkInterceptorEntries(void);
FOUNDATION_EXPORT void SPKNetworkInterceptorClear(void);

/// Pretty-printed when the data is JSON (an anti-hijacking `for (;;);` prefix is
/// tolerated), UTF-8 text otherwise, nil for binary.
FOUNDATION_EXPORT NSString *_Nullable SPKNetworkInterceptorReadableBody(NSData *_Nullable data);


NS_ASSUME_NONNULL_END
