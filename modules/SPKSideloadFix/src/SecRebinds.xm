#import <Security/Security.h>
#import <objc/runtime.h>

#import "Header.h"
#import "../fishhook/fishhook.h"

static OSStatus (*origSecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*origSecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*origSecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*origSecItemDelete)(CFDictionaryRef query);

static NSString *SPKStringFromEntitlementValue(id value) {
	if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
		return value;
	}
	if ([value isKindOfClass:[NSArray class]]) {
		for (id entry in (NSArray *)value) {
			if ([entry isKindOfClass:[NSString class]] && [entry length] > 0) {
				return entry;
			}
		}
	}
	return nil;
}

static NSString *SPKAccessGroupFromEntitlements(void) {
	LSBundleProxy *bundleProxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
	NSDictionary *entitlements = bundleProxy.entitlements;
	if (![entitlements isKindOfClass:[NSDictionary class]]) {
		return nil;
	}

	NSString *accessGroup = SPKStringFromEntitlementValue(entitlements[@"keychain-access-groups"]);
	if (accessGroup.length > 0) {
		return accessGroup;
	}

	NSString *applicationIdentifier = SPKStringFromEntitlementValue(entitlements[@"application-identifier"]);
	return applicationIdentifier.length > 0 ? applicationIdentifier : nil;
}

static NSString *SPKAccessGroupFromSentinelKeychainItem(OSStatus *statusOut) {
	if (!origSecItemCopyMatching || !origSecItemAdd) {
		if (statusOut) *statusOut = errSecUnimplemented;
		return nil;
	}

	NSDictionary *query = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: @"SPKSideloadFixGenericEntry",
		(__bridge NSString *)kSecAttrService: @"SPKSideloadFix",
		(__bridge NSString *)kSecReturnAttributes: (id)kCFBooleanTrue,
	};
	NSMutableDictionary *attributes = [query mutableCopy];
	attributes[(__bridge NSString *)kSecValueData] = [NSData data];

	CFTypeRef result = nil;
	OSStatus status = origSecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	if (status == errSecItemNotFound) {
		status = origSecItemAdd((__bridge CFDictionaryRef)attributes, &result);
	}
	if (statusOut) *statusOut = status;
	if (status != errSecSuccess || !result) {
		if (result) CFRelease(result);
		return nil;
	}

	id resultObject = (__bridge id)result;
	NSString *accessGroup = [resultObject isKindOfClass:[NSDictionary class]]
		? [resultObject objectForKey:(__bridge NSString *)kSecAttrAccessGroup]
		: nil;
	accessGroup = [accessGroup copy];
	CFRelease(result);
	return accessGroup.length > 0 ? accessGroup : nil;
}

static NSString *SPKSideloadAccessGroup(void) {
	static NSString *accessGroup;
	static NSObject *resolutionLock;
	static BOOL loggedResolutionFailure = NO;
	static dispatch_once_t lockOnceToken;
	dispatch_once(&lockOnceToken, ^{
		resolutionLock = [NSObject new];
	});

	@synchronized (resolutionLock) {
		if (accessGroup.length > 0) {
			return accessGroup;
		}

		OSStatus sentinelStatus = errSecSuccess;
		NSString *sentinelGroup = SPKAccessGroupFromSentinelKeychainItem(&sentinelStatus);
		NSString *entitlementGroup = sentinelGroup.length == 0 ? SPKAccessGroupFromEntitlements() : nil;
		NSString *resolvedGroup = sentinelGroup.length > 0 ? sentinelGroup : entitlementGroup;
		if (resolvedGroup.length > 0) {
			accessGroup = [resolvedGroup copy];
			SPKSideloadLog(@"Resolved usable keychain access group source=%@ sentinelStatus=%d",
				sentinelGroup.length > 0 ? @"sentinel" : @"runtime-entitlements",
				(int)sentinelStatus);
			return accessGroup;
		}

		if (!loggedResolutionFailure) {
			loggedResolutionFailure = YES;
			SPKSideloadLog(@"No usable keychain access group resolved sentinelStatus=%d; operation will pass through unchanged",
				(int)sentinelStatus);
		}
		return nil;
	}
}

typedef struct {
	BOOL validDictionary;
	BOOL originalGroupPresent;
	BOOL patchApplied;
	BOOL usableGroupDiscovered;
} SPKAccessGroupPatchInfo;

static CFDictionaryRef SPKCopyDictionaryByReplacingAccessGroup(CFDictionaryRef dictionary,
	BOOL injectWhenMissing,
	SPKAccessGroupPatchInfo *info) {
	SPKAccessGroupPatchInfo patchInfo = {0};
	NSDictionary *source = (__bridge NSDictionary *)dictionary;
	if (![source isKindOfClass:[NSDictionary class]]) {
		if (info) *info = patchInfo;
		return NULL;
	}
	patchInfo.validDictionary = YES;

	id existingAccessGroup = source[(__bridge NSString *)kSecAttrAccessGroup];
	patchInfo.originalGroupPresent = existingAccessGroup != nil;

	NSString *accessGroup = SPKSideloadAccessGroup();
	patchInfo.usableGroupDiscovered = accessGroup.length > 0;
	if (accessGroup.length == 0 || (!patchInfo.originalGroupPresent && !injectWhenMissing)) {
		if (info) *info = patchInfo;
		return NULL;
	}

	NSMutableDictionary *mutableDictionary = [source mutableCopy];
	if (!mutableDictionary) {
		if (info) *info = patchInfo;
		return NULL;
	}

	mutableDictionary[(__bridge NSString *)kSecAttrAccessGroup] = accessGroup;
	patchInfo.patchApplied = YES;
	if (info) *info = patchInfo;
	return (CFDictionaryRef)CFBridgingRetain(mutableDictionary);
}

static NSString *SPKBooleanLogValue(BOOL value) {
	return value ? @"yes" : @"no";
}

static void SPKLogSecOperation(NSString *operation,
	OSStatus status,
	CFAbsoluteTime startedAt,
	SPKAccessGroupPatchInfo queryInfo,
	const SPKAccessGroupPatchInfo *updateInfo) {
	static NSMutableDictionary<NSString *, NSNumber *> *lastLogTimes;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		lastLogTimes = [NSMutableDictionary dictionary];
	});

	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	NSString *key = [NSString stringWithFormat:@"%@:%d:%d:%d:%d:%d:%d:%d",
		operation,
		(int)status,
		queryInfo.originalGroupPresent,
		queryInfo.patchApplied,
		queryInfo.usableGroupDiscovered,
		updateInfo ? updateInfo->originalGroupPresent : NO,
		updateInfo ? updateInfo->patchApplied : NO,
		updateInfo ? updateInfo->usableGroupDiscovered : NO];
	@synchronized (lastLogTimes) {
		NSNumber *last = lastLogTimes[key];
		if (last && now - last.doubleValue < 2.0 && status == errSecSuccess) {
			return;
		}
		lastLogTimes[key] = @(now);
	}

	if (updateInfo) {
		SPKSideloadLog(@"Keychain %@ status=%d duration=%.2fms mainThread=%@ usableSignedGroup=%@ queryOriginalGroup=%@ queryGroupReplaced=%@ queryGroupInjected=%@ updateOriginalGroup=%@ updateGroupReplaced=%@",
			operation,
			(int)status,
			(now - startedAt) * 1000.0,
			[NSThread isMainThread] ? @"yes" : @"no",
			SPKBooleanLogValue(queryInfo.usableGroupDiscovered || updateInfo->usableGroupDiscovered),
			SPKBooleanLogValue(queryInfo.originalGroupPresent),
			SPKBooleanLogValue(queryInfo.originalGroupPresent && queryInfo.patchApplied),
			SPKBooleanLogValue(!queryInfo.originalGroupPresent && queryInfo.patchApplied),
			SPKBooleanLogValue(updateInfo->originalGroupPresent),
			SPKBooleanLogValue(updateInfo->originalGroupPresent && updateInfo->patchApplied));
		return;
	}

	SPKSideloadLog(@"Keychain %@ status=%d duration=%.2fms mainThread=%@ usableSignedGroup=%@ originalGroup=%@ groupReplaced=%@ groupInjected=%@",
		operation,
		(int)status,
		(now - startedAt) * 1000.0,
		[NSThread isMainThread] ? @"yes" : @"no",
		SPKBooleanLogValue(queryInfo.usableGroupDiscovered),
		SPKBooleanLogValue(queryInfo.originalGroupPresent),
		SPKBooleanLogValue(queryInfo.originalGroupPresent && queryInfo.patchApplied),
		SPKBooleanLogValue(!queryInfo.originalGroupPresent && queryInfo.patchApplied));
}

static OSStatus zxSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
	CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
	SPKAccessGroupPatchInfo patchInfo = {0};
	CFDictionaryRef patchedAttributes = SPKCopyDictionaryByReplacingAccessGroup(attributes, YES, &patchInfo);
	OSStatus status = origSecItemAdd(patchedAttributes ?: attributes, result);
	if (patchedAttributes) CFRelease(patchedAttributes);
	SPKLogSecOperation(@"SecItemAdd", status, startedAt, patchInfo, NULL);
	return status;
}

static OSStatus zxSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
	CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
	SPKAccessGroupPatchInfo patchInfo = {0};
	CFDictionaryRef patchedQuery = SPKCopyDictionaryByReplacingAccessGroup(query, YES, &patchInfo);
	OSStatus status = origSecItemCopyMatching(patchedQuery ?: query, result);
	if (patchedQuery) CFRelease(patchedQuery);
	SPKLogSecOperation(@"SecItemCopyMatching", status, startedAt, patchInfo, NULL);
	return status;
}

static OSStatus zxSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
	CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
	SPKAccessGroupPatchInfo queryInfo = {0};
	SPKAccessGroupPatchInfo updateInfo = {0};
	CFDictionaryRef patchedQuery = SPKCopyDictionaryByReplacingAccessGroup(query, YES, &queryInfo);
	CFDictionaryRef patchedAttributes = SPKCopyDictionaryByReplacingAccessGroup(attributesToUpdate, NO, &updateInfo);
	OSStatus status = origSecItemUpdate(patchedQuery ?: query, patchedAttributes ?: attributesToUpdate);
	if (patchedQuery) CFRelease(patchedQuery);
	if (patchedAttributes) CFRelease(patchedAttributes);
	SPKLogSecOperation(@"SecItemUpdate", status, startedAt, queryInfo, &updateInfo);
	return status;
}

static OSStatus zxSecItemDelete(CFDictionaryRef query) {
	CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
	SPKAccessGroupPatchInfo patchInfo = {0};
	CFDictionaryRef patchedQuery = SPKCopyDictionaryByReplacingAccessGroup(query, YES, &patchInfo);
	OSStatus status = origSecItemDelete(patchedQuery ?: query);
	if (patchedQuery) CFRelease(patchedQuery);
	SPKLogSecOperation(@"SecItemDelete", status, startedAt, patchInfo, NULL);
	return status;
}

void rebindSecFuncs() {
	struct rebinding rebinds[4] = {
		{"SecItemAdd", (void *)zxSecItemAdd, (void **)&origSecItemAdd},
		{"SecItemCopyMatching", (void *)zxSecItemCopyMatching, (void **)&origSecItemCopyMatching},
		{"SecItemUpdate", (void *)zxSecItemUpdate, (void **)&origSecItemUpdate},
		{"SecItemDelete", (void *)zxSecItemDelete, (void **)&origSecItemDelete}
	};
	SPKSideloadLog(@"rebind_symbols result=%d", rebind_symbols(rebinds, 4));
}
