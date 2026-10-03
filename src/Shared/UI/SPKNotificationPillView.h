#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, SPKNotificationTone) {
    SPKNotificationToneSuccess = 0,
    SPKNotificationToneError = 1,
    SPKNotificationToneInfo = 2
};

@interface SPKNotificationPillView : UIView

+ (instancetype)progressPill;
+ (instancetype)toastPillWithTitle:(NSString *)title
                          subtitle:(nullable NSString *)subtitle
                              icon:(nullable UIImage *)icon
                              tone:(SPKNotificationTone)tone;

- (void)setPresentationTopConstraint:(NSLayoutConstraint *)constraint;

/// YES when the pill is drawn as Instagram's own toast (the Instagram notification style).
@property (nonatomic, readonly) BOOL instagramSkin;

/// Updates progress (0.0 – 1.0) for progress-style pills.
- (void)setProgress:(float)progress animated:(BOOL)animated;
- (void)setProgress:(float)progress
          bytesWritten:(int64_t)bytesWritten
    totalBytesExpected:(int64_t)totalBytesExpected
              animated:(BOOL)animated;
- (void)updateProgressTitle:(nullable NSString *)title subtitle:(nullable NSString *)subtitle;

/// Presents unmeasurable work: the ring spins and the percentage subtitle is dropped.
/// Any progress or title update returns the pill to the determinate presentation, so
/// call this last when setting a pill up.
- (void)setProgressIndeterminate:(BOOL)indeterminate;

/// Transitions the pill to a success state.
- (void)showSuccess;
- (void)showSuccessWithTitle:(nullable NSString *)title
                    subtitle:(nullable NSString *)subtitle
                        icon:(nullable UIImage *)icon;

/// Transitions the pill to an error state.
- (void)showError:(NSString *)message;
- (void)showErrorWithTitle:(nullable NSString *)title
                  subtitle:(nullable NSString *)subtitle
                      icon:(nullable UIImage *)icon;

/// Transitions the pill to an info state (for progress context).
- (void)showInfoWithTitle:(nullable NSString *)title
                 subtitle:(nullable NSString *)subtitle
                     icon:(nullable UIImage *)icon;

/// Dismisses the pill immediately.
- (void)dismiss;

/// Called when user taps the close button while a progress operation is running.
@property (nonatomic, copy) void (^onCancel)(void);

/// Called when user taps the pill body to retry while in error state.
@property (nonatomic, copy) void (^onRetry)(void);

/// Called when user taps the pill body after success state is shown.
@property (nonatomic, copy) void (^onTapWhenCompleted)(void);

/// Called when user taps the pill body while a progress operation is still
/// running. Does not dismiss the pill (unlike the completed/toast taps).
@property (nonatomic, copy) void (^onTapWhenProgress)(void);

/// Called when a progress pill transitions to a visible terminal tone.
@property (nonatomic, copy) void (^onTonePresented)(SPKNotificationTone tone);

/// Called after the pill has been fully removed from its superview.
@property (nonatomic, copy) void (^onDidDismiss)(void);

@end
