#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A single bounded request. Completes exactly once on main, including cancellation.
@interface MediaKeyRequest : NSObject <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
- (void)loadURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
