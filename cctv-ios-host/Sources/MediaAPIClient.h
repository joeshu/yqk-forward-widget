#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL MediaSourceUsesNativeCatalogAPI(NSDictionary *source);

@interface MediaAPIClient : NSObject
- (instancetype)initWithPort:(NSInteger)port;
- (instancetype)initWithPort:(NSInteger)port requestTimeout:(NSTimeInterval)requestTimeout;
- (instancetype)initWithTVBoxSource:(NSDictionary *)source;
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id result,NSError *error))completion;
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments correlationID:(nullable NSString *)correlationID completion:(void (^)(id result,NSError *error))completion;
- (void)cancel;
@end
