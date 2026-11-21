#import <Foundation/Foundation.h>

// Synchronous JS engines call this on their worker queue, never the UI thread.
// Networking uses an independent delegate queue, a bounded body and cancellation.
@interface HostSyncRequest : NSObject
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (NSDictionary *)performRequest:(NSURLRequest *)request;
- (void)cancel;
@end

// The caller owns resuming or cancelling the returned task.
FOUNDATION_EXPORT NSURLSessionDataTask *HostBoundedDataTask(
    NSURLRequest *request, NSUInteger maximumBytes,
    void (^completion)(NSData *, NSURLResponse *, NSError *));
