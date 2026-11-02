#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVBoxCatalogBulkImporter : NSObject
@property(nonatomic,copy,nullable) void (^onProgress)(NSUInteger completed, NSUInteger total, NSUInteger succeeded, NSUInteger failed, NSString *currentSiteName);
@property(nonatomic,readonly) BOOL downloadLimitReached;
- (void)importSites:(NSArray<NSDictionary *> *)sites catalogID:(NSString *)catalogID completion:(void (^)(NSArray<NSDictionary *> *imported, NSArray<NSDictionary *> *failures, BOOL cancelled))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
