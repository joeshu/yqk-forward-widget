#import <Foundation/Foundation.h>

// Synchronous JS engines call this on their worker queue, never the UI thread.
// Networking uses an independent delegate queue, a bounded body and cancellation.
@interface HostSyncRequest : NSObject
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (NSDictionary *)performRequest:(NSURLRequest *)request;
- (void)cancel;
@end
