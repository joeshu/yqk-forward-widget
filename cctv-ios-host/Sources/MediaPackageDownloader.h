#import <Foundation/Foundation.h>
@interface MediaPackageDownloader : NSObject
@property(nonatomic, copy) void (^onProgress)(NSString *stage, int64_t receivedBytes, int64_t expectedBytes);
- (void)importURL:(NSURL *)url completion:(void (^)(NSDictionary *service,NSError *error))completion;
- (void)cancel;
@end
