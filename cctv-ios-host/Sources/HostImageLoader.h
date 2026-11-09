#import <UIKit/UIKit.h>

typedef void (^HostImageLoadCompletion)(BOOL succeeded, NSTimeInterval retryAfter);

// Shared, bounded loader for channel logos and film artwork. Methods are called on the main thread.
@interface HostImageLoader : NSObject
+ (instancetype)shared;
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView;
- (void)loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView;
- (void)loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView completion:(nullable HostImageLoadCompletion)completion;
- (void)prefetchPosterURLs:(NSArray<NSString *> *)urls;
- (void)cancelPending;
- (void)clearCache;
@end
