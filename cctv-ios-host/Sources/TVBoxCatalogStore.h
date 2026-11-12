#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogStore : NSObject
+ (nullable NSDictionary *)parseData:(NSData *)data sourceURL:(nullable NSString *)sourceURL error:(NSError **)error;
+ (nullable NSDictionary *)parseBundleArchiveData:(NSData *)data fileURL:(nullable NSURL *)fileURL sourceURL:(nullable NSString *)sourceURL error:(NSError **)error;
+ (nullable NSDictionary *)parseBundleDirectoryAtURL:(NSURL *)directoryURL error:(NSError **)error;
+ (nullable NSData *)sanitizeJSONData:(NSData *)data;
+ (nullable NSString *)decodeQiaojiExtString:(NSString *)rawExt;
+ (nullable NSDictionary *)catalogWithMacCMSAPIURL:(NSString *)apiURL name:(nullable NSString *)name error:(NSError **)error;
+ (NSArray<NSDictionary *> *)catalogs;
+ (NSArray<NSDictionary *> *)playbackParsers;
+ (NSArray<NSDictionary *> *)playbackParsersForCatalogID:(nullable NSString *)catalogID;
+ (void)saveCatalog:(NSDictionary *)catalog;
+ (nullable NSDictionary *)catalogForID:(NSString *)identifier;
+ (void)removeCatalog:(NSString *)identifier;
+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:(NSDictionary *)catalog;
+ (nullable NSData *)exportDataForCatalogID:(NSString *)identifier error:(NSError **)error;
+ (nullable NSData *)exportSingleResourceForCatalogID:(NSString *)identifier kind:(NSString *)kind index:(NSUInteger)index error:(NSError **)error;
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier error:(NSError **)error;
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier files:(nullable NSDictionary<NSString *,NSData *> *)files error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
