#import <Foundation/Foundation.h>
@interface MediaPackageDownloader : NSObject
- (void)importURL:(NSURL *)url completion:(void (^)(NSDictionary *service,NSError *error))completion;
- (void)cancel;
@end
