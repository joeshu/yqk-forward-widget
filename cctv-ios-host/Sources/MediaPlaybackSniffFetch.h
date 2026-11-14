#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaPlaybackSniffFetch : NSObject
- (void)startWithRequest:(NSURLRequest *)request completion:(void (^)(NSData *data, NSURLResponse * _Nullable response, NSError * _Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
