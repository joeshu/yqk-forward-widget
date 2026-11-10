#import <Foundation/Foundation.h>

@interface MediaJARRequest : NSObject
- (void)cancel;
@end
@interface MediaJARRuntime : NSObject
+ (BOOL)available;
+ (MediaJARRequest *)requestSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id raw,NSError *error))completion;
@end
