#import <UIKit/UIKit.h>

// Shared, bounded loader for channel logos. Methods are called on the main thread.
@interface HostImageLoader : NSObject
+ (instancetype)shared;
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView;
- (void)cancelPending;
- (void)clearCache;
@end
