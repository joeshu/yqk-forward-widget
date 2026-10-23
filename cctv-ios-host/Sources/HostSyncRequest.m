#import "HostSyncRequest.h"

@interface HostSyncRequest () <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSHTTPURLResponse *response;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL cancelled;
@property(nonatomic, strong) NSURLSessionConfiguration *configuration;
@end
@implementation HostSyncRequest
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {if((self=[super init]))_configuration=configuration.copy;return self;}
- (NSDictionary *)performRequest:(NSURLRequest *)request {
    NSAssert(!NSThread.isMainThread,@"Synchronous plugin requests must stay off the UI thread");
    @synchronized(self){
        if(self.cancelled)return @{@"error":@"请求已取消"};
        self.body=[NSMutableData data];self.done=dispatch_semaphore_create(0);
        NSURLSessionConfiguration *configuration=self.configuration.copy?:NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=10;configuration.timeoutIntervalForResource=12;
        NSOperationQueue *delegate=[NSOperationQueue new];delegate.maxConcurrentOperationCount=1;
        self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegate];
        [[self.session dataTaskWithRequest:request] resume];
    }
    if(dispatch_semaphore_wait(self.done,dispatch_time(DISPATCH_TIME_NOW,13*NSEC_PER_SEC))!=0){self.failure=@"同步 JS 请求超时";[self cancel];}
    @synchronized(self){
        [self.session invalidateAndCancel];self.session=nil;
        if(self.failure.length)return @{@"error":self.failure};
        NSStringEncoding encoding=NSUTF8StringEncoding;NSString *charset=self.response.textEncodingName;
        if(charset.length){CFStringEncoding cf=CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)charset);if(cf!=kCFStringEncodingInvalidId)encoding=CFStringConvertEncodingToNSStringEncoding(cf);}
        NSString *text=[[NSString alloc] initWithData:self.body encoding:encoding]?:[[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding]?:@"";
        return @{@"code":@(self.response.statusCode),@"status":@(self.response.statusCode),@"url":self.response.URL.absoluteString?:@"",@"headers":self.response.allHeaderFields?:@{},@"content":text,@"base64":[self.body base64EncodedStringWithOptions:0]};
    }
}
- (void)finish:(NSString *)failure {
    @synchronized(self){if(self.finished)return;self.finished=YES;if(failure.length)self.failure=failure;if(self.done)dispatch_semaphore_signal(self.done);}
}
- (void)cancel {
    @synchronized(self){self.cancelled=YES;[self.session invalidateAndCancel];[self finish:@"请求已取消"];}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    BOOL valid=[response isKindOfClass:NSHTTPURLResponse.class] && response.expectedContentLength<=2*1024*1024;
    if(valid)self.response=(id)response;completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);if(!valid)[self finish:@"JS 响应无效或超过 2 MB"];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @synchronized(self){if(self.finished)return;if(self.body.length+data.length>2*1024*1024){[task cancel];[self finish:@"JS 响应超过 2 MB"];return;}[self.body appendData:data];}
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self finish:error.localizedDescription]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL allowed=[@[@"http",@"https"] containsObject:request.URL.scheme.lowercaseString] && !request.URL.user.length && !request.URL.password.length;
    NSMutableURLRequest *redirect=[request mutableCopy];if(![request.URL.host.lowercaseString isEqualToString:response.URL.host.lowercaseString] || ![request.URL.scheme.lowercaseString isEqual:response.URL.scheme.lowercaseString] || ![(request.URL.port?:@0) isEqual:(response.URL.port?:@0)]){[redirect setValue:nil forHTTPHeaderField:@"Authorization"];[redirect setValue:nil forHTTPHeaderField:@"Cookie"];}
    completion(allowed?redirect:nil);
}
@end
