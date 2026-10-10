#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPKAppIconItem : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSArray<NSString *> *iconFiles;
@property (nonatomic) BOOL isPrimary;

@end

@interface SPKAppIconCatalog : NSObject

+ (NSArray<SPKAppIconItem *> *)availableAppIcons;
+ (nullable SPKAppIconItem *)currentAppIcon;
+ (NSString *)currentAppIconIdentifier;
+ (nullable SPKAppIconItem *)appIconWithIdentifier:(nullable NSString *)identifier;
+ (nullable UIImage *)imageForAppIcon:(SPKAppIconItem *)item;

/// Previews of an icon that restyles itself with the system appearance:
/// default, dark, and clear (which itself follows the current appearance).
/// Nil for icons that ship as one image.
+ (nullable NSArray<UIImage *> *)appearancePreviewImagesForAppIcon:(SPKAppIconItem *)item;

/// Persist the user's chosen icon so the picker stays accurate even when
/// UIApplication.alternateIconName reads nil on re-signed/injected builds.
+ (void)setStoredSelectedIdentifier:(nullable NSString *)identifier;

/// Applies the persisted icon selection to the live app icon when it differs
/// from what's currently active. Used after a settings import, where the pref
/// is restored but UIApplication still shows the old icon (otherwise the user
/// would have to re-pick the icon to actually apply it).
+ (void)applyStoredIconIfNeeded;

@end

NS_ASSUME_NONNULL_END
