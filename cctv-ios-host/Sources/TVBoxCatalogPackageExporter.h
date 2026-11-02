#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogPackageExporter : NSObject
@property(nonatomic,copy,nullable) void (^progressHandler)(NSUInteger completed,NSUInteger total,NSString *currentName);
- (instancetype)initWithCatalogID:(NSString *)catalogID token:(nullable NSString *)token;
- (void)startWithCompletion:(void (^)(NSURL * _Nullable archiveURL,NSUInteger failedCount,NSError * _Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
