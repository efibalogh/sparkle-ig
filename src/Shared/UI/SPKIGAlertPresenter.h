#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKIGAlertActionStyle) {
    SPKIGAlertActionStyleDefault = 0,
    SPKIGAlertActionStyleCancel = 1,
    SPKIGAlertActionStyleDestructive = 2,
};

typedef void (^SPKIGAlertActionHandler)(void);
typedef void (^SPKIGAlertTextHandler)(NSString *_Nullable text);

@interface SPKIGAlertAction : NSObject

@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, assign, readonly) SPKIGAlertActionStyle style;
@property (nonatomic, copy, nullable, readonly) SPKIGAlertActionHandler handler;

+ (instancetype)actionWithTitle:(NSString *)title
                          style:(SPKIGAlertActionStyle)style
                        handler:(nullable SPKIGAlertActionHandler)handler;

@end

@interface SPKIGAlertPresenter : NSObject

+ (BOOL)presentAlertFromViewController:(nullable UIViewController *)presenter
                                 title:(nullable NSString *)title
                               message:(nullable NSString *)message
                               actions:(NSArray<SPKIGAlertAction *> *)actions;

+ (BOOL)presentActionSheetFromViewController:(nullable UIViewController *)presenter
                                       title:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     actions:(NSArray<SPKIGAlertAction *> *)actions;

+ (BOOL)presentActionSheetFromViewController:(nullable UIViewController *)presenter
                                       title:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     actions:(NSArray<SPKIGAlertAction *> *)actions
                                  forceSheet:(BOOL)forceSheet;

+ (BOOL)presentTextInputAlertFromViewController:(nullable UIViewController *)presenter
                                          title:(nullable NSString *)title
                                        message:(nullable NSString *)message
                                    placeholder:(nullable NSString *)placeholder
                                    initialText:(nullable NSString *)initialText
                                autocapitalized:(BOOL)autocapitalized
                                   confirmTitle:(NSString *)confirmTitle
                                    cancelTitle:(NSString *)cancelTitle
                                   confirmStyle:(SPKIGAlertActionStyle)confirmStyle
                                   confirmBlock:(SPKIGAlertTextHandler)confirmBlock
                                    cancelBlock:(nullable SPKIGAlertActionHandler)cancelBlock;

/// Same, with a masked field when `secure` is YES (passwords).
+ (BOOL)presentTextInputAlertFromViewController:(nullable UIViewController *)presenter
                                          title:(nullable NSString *)title
                                        message:(nullable NSString *)message
                                    placeholder:(nullable NSString *)placeholder
                                    initialText:(nullable NSString *)initialText
                                autocapitalized:(BOOL)autocapitalized
                                secureTextEntry:(BOOL)secure
                                   confirmTitle:(NSString *)confirmTitle
                                    cancelTitle:(NSString *)cancelTitle
                                   confirmStyle:(SPKIGAlertActionStyle)confirmStyle
                                   confirmBlock:(SPKIGAlertTextHandler)confirmBlock
                                    cancelBlock:(nullable SPKIGAlertActionHandler)cancelBlock;

@end

NS_ASSUME_NONNULL_END
