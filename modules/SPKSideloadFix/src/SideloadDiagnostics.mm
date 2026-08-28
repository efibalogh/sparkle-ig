#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#import "Header.h"

static NSString *const kSPKDiagnosticsDirectoryName = @"SparkleDiagnostics";
static NSString *const kSPKDiagnosticsGroupName = @"group.com.burbn.instagram";
static NSString *const kSPKDiagnosticsEnabledName = @".enabled";
static NSString *const kSPKDiagnosticsLogName = @"sideload-notifications.log";
static const off_t kSPKDiagnosticsMaximumBytes = 1024 * 1024;

static NSString *SPKDiagnosticsTimestamp(void) {
	static NSDateFormatter *formatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		formatter = [NSDateFormatter new];
		formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
		formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
	});
	@synchronized(formatter) {
		return [formatter stringFromDate:NSDate.date];
	}
}

void SPKSideloadWriteLogLine(NSString *line) {
	if (line.length == 0) return;

	// Resolving the signed app-group root emits its own diagnostics. Keep those
	// visible in Console without recursively trying to persist them.
	static __thread BOOL writingPersistentLog = NO;
	if (writingPersistentLog) return;
	writingPersistentLog = YES;

	@autoreleasepool {
		NSURL *sharedRoot = getAppGroupPathIfExists();
		NSURL *groupContainer = [sharedRoot URLByAppendingPathComponent:kSPKDiagnosticsGroupName isDirectory:YES];
		NSURL *directory = [groupContainer URLByAppendingPathComponent:kSPKDiagnosticsDirectoryName isDirectory:YES];
		NSURL *enabledURL = [directory URLByAppendingPathComponent:kSPKDiagnosticsEnabledName];
		if (!sharedRoot || ![[NSFileManager defaultManager] fileExistsAtPath:enabledURL.path]) {
			writingPersistentLog = NO;
			return;
		}

		[[NSFileManager defaultManager] createDirectoryAtURL:directory
			withIntermediateDirectories:YES
			attributes:nil
			error:nil];

		NSString *processName = NSProcessInfo.processInfo.processName ?: @"unknown";
		NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
		NSString *entry = [NSString stringWithFormat:@"%@ pid=%d process=%@ bundle=%@ %@\n",
			SPKDiagnosticsTimestamp(), getpid(), processName, bundleID, line];
		NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
		int fd = open([[directory URLByAppendingPathComponent:kSPKDiagnosticsLogName].path fileSystemRepresentation],
			O_WRONLY | O_CREAT | O_APPEND, 0600);
		if (fd >= 0) {
			flock(fd, LOCK_EX);
			struct stat info = {};
			if (fstat(fd, &info) == 0 && info.st_size >= kSPKDiagnosticsMaximumBytes) {
				ftruncate(fd, 0);
				lseek(fd, 0, SEEK_SET);
				NSString *rotation = [NSString stringWithFormat:@"%@ log rotated after 1 MiB\n", SPKDiagnosticsTimestamp()];
				NSData *rotationData = [rotation dataUsingEncoding:NSUTF8StringEncoding];
				write(fd, rotationData.bytes, rotationData.length);
			}
			write(fd, data.bytes, data.length);
			flock(fd, LOCK_UN);
			close(fd);
		}
	}

	writingPersistentLog = NO;
}
