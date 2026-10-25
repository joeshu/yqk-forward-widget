#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogStore : NSObject
+ (nullable NSDictionary *)parseData:(NSData *)data sourceURL:(nullable NSString *)sourceURL error:(NSError **)error;
+ (nullable NSDictionary *)catalogWithMacCMSAPIURL:(NSString *)apiURL name:(nullable NSString *)name error:(NSError **)error;
+ (NSArray<NSDictionary *> *)catalogs;
+ (void)saveCatalog:(NSDictionary *)catalog;
+ (nullable NSDictionary *)catalogForID:(NSString *)identifier;
+ (void)removeCatalog:(NSString *)identifier;
+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:(NSDictionary *)catalog;
@end
NS_ASSUME_NONNULL_END
