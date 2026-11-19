#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaChannelProbe : NSObject
- (void)startWithURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
- (void)startWithURL:(NSURL *)url headers:(nullable NSDictionary<NSString *, NSString *> *)headers completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
