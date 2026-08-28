#import <Foundation/Foundation.h>
#import <os/log.h>

extern void SPKSideloadWriteLogLine(NSString *line);

static inline void SPKSideloadLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void SPKSideloadLog(NSString *format, ...) {
	NSString *body = @"";
	if (format.length > 0) {
		va_list args;
		va_start(args, format);
		body = [[NSString alloc] initWithFormat:format arguments:args];
		va_end(args);
	}

	NSString *line = [NSString stringWithFormat:@"[Sparkle SideloadFix]: %@", body ?: @""];
	os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String);
	SPKSideloadWriteLogLine(line);
}

extern void rebindSecFuncs();

extern BOOL createDirectoryIfNotExists(NSString *path);
extern NSURL *getAppGroupPathIfExists();
extern BOOL isAppExtensionProcess(void);

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
