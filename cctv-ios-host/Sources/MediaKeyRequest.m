#import "MediaKeyRequest.h"
#import "MediaPlaybackHeaders.h"
@interface MediaKeyRequest ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,copy) void (^completion)(NSData *,NSError *);
@property(nonatomic,strong) NSError *failure;
@property(nonatomic) NSUInteger redirects;
@property(nonatomic) BOOL started;
@end
static BOOL MediaKeyURLIsValid(NSURL *url) {
    return url.host.length && !url.user.length && !url.password.length &&
        [@[@"http", @"https"] containsObject:url.scheme.lowercaseString];
}
@implementation MediaKeyRequest
- (void)loadURL:(NSURL *)url headers:(NSDictionary *)headers completion:(void (^)(NSData *,NSError *))completion {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self loadURL:url headers:headers completion:completion];});return;}
    if(self.started){if(completion)completion(nil,[NSError errorWithDomain:@"CCTVHostKey" code:4 userInfo:@{NSLocalizedDescriptionKey:@"密钥请求对象只能使用一次"}]);return;}
    self.started=YES;
    if(!MediaKeyURLIsValid(url)){if(completion)completion(nil,[NSError errorWithDomain:@"CCTVHostKey" code:3 userInfo:@{NSLocalizedDescriptionKey:@"密钥地址无效"}]);return;}
    self.completion=completion;self.data=[NSMutableData data];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=6;config.timeoutIntervalForResource=8;config.HTTPCookieStorage=nil;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.allHTTPHeaderFields=MediaPlaybackHeadersFromResult(@{@"headers":headers?:@{}});request.HTTPShouldHandleCookies=NO;request.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    [[self.session dataTaskWithRequest:request] resume];
}
- (void)cancel {if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self cancel];});return;}[self.session invalidateAndCancel];}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(status<200||status>=300||response.expectedContentLength>4096){self.failure=[NSError errorWithDomain:@"CCTVHostKey" code:status?:1 userInfo:@{NSLocalizedDescriptionKey:@"密钥响应无效或超过 4 KiB"}];completion(NSURLSessionResponseCancel);}else completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.data.length+data.length>4096){self.failure=[NSError errorWithDomain:@"CCTVHostKey" code:2 userInfo:@{NSLocalizedDescriptionKey:@"密钥响应超过 4 KiB"}];[task cancel];return;}[self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    NSURL *from=response.URL,*to=request.URL;
    if(++self.redirects>5||!MediaKeyURLIsValid(to)||([from.scheme.lowercaseString isEqual:@"https"]&&![to.scheme.lowercaseString isEqual:@"https"])){self.failure=[NSError errorWithDomain:@"CCTVHostKey" code:3 userInfo:@{NSLocalizedDescriptionKey:@"密钥重定向被拒绝"}];completion(nil);return;}
    NSMutableURLRequest *safe=[request mutableCopy];
    NSDictionary *headers=MediaPlaybackHeadersScopedToURL(request.allHTTPHeaderFields?:@{},from,to);
    // Clear fields explicitly: replacing allHTTPHeaderFields on a redirected
    // CFNetwork request can retain fields inherited from the original request.
    for(NSString *name in safe.allHTTPHeaderFields.allKeys)[safe setValue:nil forHTTPHeaderField:name];
    for(NSString *name in headers)[safe setValue:headers[name] forHTTPHeaderField:name];
    safe.HTTPShouldHandleCookies=NO;
    completion(safe);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^completion)(NSData *,NSError *)=self.completion;self.completion=nil;
    NSError *failure=self.failure?:error;if(completion)completion(failure?nil:self.data,failure);
    [session finishTasksAndInvalidate];self.session=nil;self.data=nil;
}
@end
