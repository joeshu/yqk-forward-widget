#import <Foundation/Foundation.h>

@interface MediaAPIClient : NSObject
- (instancetype)initWithPort:(NSInteger)port;
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id result,NSError *error))completion;
- (void)cancel;
@end
