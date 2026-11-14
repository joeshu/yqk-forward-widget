#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaChannelProbe : NSObject
- (void)startWithURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
