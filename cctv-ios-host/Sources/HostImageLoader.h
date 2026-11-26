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
- (void)clearDiskCache;
// T18/PERF-03：分别计费的快照（内存缓存/在途压缩体/磁盘缓存各一栏 + 命中与淘汰计数）。
- (NSDictionary<NSString *, id> *)statisticsSnapshot;
@end
