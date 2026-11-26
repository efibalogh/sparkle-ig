#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKNotificationCheckStatus) {
    SPKNotificationCheckStatusPass,
    SPKNotificationCheckStatusWarn,
    SPKNotificationCheckStatusFail,
    SPKNotificationCheckStatusInfo,
};

typedef NS_ENUM(NSInteger, SPKNotificationSupportLevel) {
    SPKNotificationSupportLevelFull,
    SPKNotificationSupportLevelPartial,
    SPKNotificationSupportLevelNone,
};

@interface SPKNotificationCheckItem : NSObject
/// Stable identifier of the check, independent of the interface language.
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *value;
/// Replaces the value in the copied report when the value itself is personal.
@property (nonatomic, copy, nullable) NSString *reportValue;
@property (nonatomic, copy, nullable) NSString *note;
@property (nonatomic) SPKNotificationCheckStatus status;
/// Kept out of the copied report (personal details such as the certificate owner).
@property (nonatomic) BOOL privateValue;
/// A problem that only follows from the verdict's root cause, so it is shown
/// without its own warning.
@property (nonatomic) BOOL muted;
@end

@interface SPKNotificationCheckSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SPKNotificationCheckItem *> *items;
@end

@interface SPKNotificationSupportReport : NSObject
@property (nonatomic) SPKNotificationSupportLevel level;
@property (nonatomic, copy) NSString *verdictTitle;
@property (nonatomic, copy) NSString *verdictDetail;
@property (nonatomic, copy, nullable) NSString *fix;
@property (nonatomic, copy) NSArray<SPKNotificationCheckSection *> *sections;
/// Notification permission is off or was never asked, so iOS Settings is the fix.
@property (nonatomic) BOOL permissionNeedsAttention;
- (NSString *)plainTextReport;
@end

/// Works out whether this install can receive Instagram's push notifications,
/// from the code signatures of the app and its notification extension, the
/// provisioning profile, and the current notification settings. Read-only.
@interface SPKNotificationSupport : NSObject
/// The identifier this install really has: LiveContainer's signed identifier
/// when running inside it, otherwise the one in the app's Info.plist on disk
/// (the sideload fix reports Instagram's at runtime).
+ (NSString *)installBundleIdentifier;
/// Runs the checks off the main thread and calls back on the main queue.
+ (void)runWithCompletion:(void (^)(SPKNotificationSupportReport *report))completion;
@end

NS_ASSUME_NONNULL_END
