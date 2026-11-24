#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Instagram's own person row for `user`, built the way its search builds one: a result
/// data model in `sectionType` turned into a view model by the default provider.
/// Nil when this build lacks either. Defined in SearchPins.x.
FOUNDATION_EXPORT id _Nullable SPKSearchPersonRow(id user, NSString *_Nullable sectionType, NSString *module,
                                                  unsigned long long sourceType, NSString *identifier, id session);

NS_ASSUME_NONNULL_END
