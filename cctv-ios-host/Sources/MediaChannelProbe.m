#import "MediaChannelProbe.h"
#import <QuartzCore/QuartzCore.h>

static const NSUInteger MediaChannelProbeByteLimit = 4096;

@interface MediaChannelProbe () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,copy) void (^completion)(NSDictionary<NSString *,id> *);
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic) CFTimeInterval responseAt;
@property(nonatomic) NSUInteger byteCount;
@property(nonatomic) NSInteger statusCode;
@property(nonatomic) NSUInteger redirectCount;
@property(nonatomic) BOOL finished;
@end

@implementation MediaChannelProbe
- (void)startWithURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    NSAssert(NSThread.isMainThread, @"Channel probes are started on the main thread");
    NSString *scheme=url.scheme.lowercaseString;
    if(!url.host.length||(![scheme isEqual:@"http"]&&![scheme isEqual:@"https"])){
        if(completion)completion(@{@"ok":@NO,@"status":@0,@"requestMs":@0,@"sampleBytes":@0,@"sampleKBps":@0});
        return;
    }
    self.completion=completion;
    self.startedAt=CACurrentMediaTime();
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=3.0;
    configuration.timeoutIntervalForResource=3.5;
    configuration.HTTPMaximumConnectionsPerHost=1;
    configuration.URLCache=nil;
    configuration.HTTPCookieStorage=nil;
    configuration.HTTPShouldSetCookies=NO;
    self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    request.HTTPMethod=@"GET";
    request.HTTPShouldHandleCookies=NO;
    [request setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"CCTVHost/1" forHTTPHeaderField:@"User-Agent"];
    self.task=[self.session dataTaskWithRequest:request];
    [self.task resume];
}
- (void)cancel {
    if(self.finished)return;
    self.finished=YES;
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.completion=nil;self.task=nil;self.session=nil;
}
- (void)finishWithError:(NSError *)error {
    if(self.finished)return;
    self.finished=YES;
    BOOL ok=!error&&self.statusCode>=200&&self.statusCode<300;
    double requestMs=self.responseAt>0?MAX(0,(self.responseAt-self.startedAt)*1000.0):MAX(0,(CACurrentMediaTime()-self.startedAt)*1000.0);
    double elapsed=self.responseAt>0?MAX(0.001,CACurrentMediaTime()-self.responseAt):MAX(0.001,CACurrentMediaTime()-self.startedAt);
    double sampleKBps=self.byteCount>0?(self.byteCount/1024.0)/elapsed:0;
    NSDictionary *result=@{@"ok":@(ok),@"status":@(self.statusCode),@"requestMs":@(requestMs),@"sampleBytes":@(self.byteCount),@"sampleKBps":@(sampleKBps),@"error":@(error!=nil)};
    void (^completion)(NSDictionary *)=self.completion;
    self.completion=nil;
    [self.session finishTasksAndInvalidate];
    self.session=nil;self.task=nil;
    if(completion)completion(result);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if([response isKindOfClass:NSHTTPURLResponse.class])self.statusCode=[(NSHTTPURLResponse *)response statusCode];
    self.responseAt=CACurrentMediaTime();
    if(self.statusCode<200||self.statusCode>=300){completionHandler(NSURLSessionResponseCancel);[self finishWithError:nil];return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    self.byteCount=MIN(MediaChannelProbeByteLimit,self.byteCount+data.length);
    if(self.byteCount>=MediaChannelProbeByteLimit){[task cancel];[self finishWithError:nil];}
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *target=request.URL;
    NSString *scheme=target.scheme.lowercaseString;
    self.redirectCount++;
    if(self.redirectCount>5||!target.host.length||(![scheme isEqual:@"http"]&&![scheme isEqual:@"https"])||([response.URL.scheme.lowercaseString isEqual:@"https"]&&[scheme isEqual:@"http"])){
        completionHandler(nil);[self finishWithError:nil];return;
    }
    NSMutableURLRequest *safe=[request mutableCopy];
    safe.HTTPMethod=@"GET";
    safe.HTTPBody=nil;
    safe.HTTPShouldHandleCookies=NO;
    [safe setValue:@"CCTVHost/1" forHTTPHeaderField:@"User-Agent"];
    [safe setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [safe setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    for(NSString *header in @[@"Authorization",@"Proxy-Authorization",@"Cookie",@"Referer",@"Origin",@"X-API-Key",@"X-Auth",@"X-Session"])[safe setValue:nil forHTTPHeaderField:header];
    completionHandler(safe);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.finished)return;
    [self finishWithError:error];
}
@end
