#import "MediaPlaybackSniffFetch.h"
#import "MediaPlaybackHeaders.h"

static const NSUInteger MediaPlaybackSniffMaximumBytes=2*1024*1024;

@interface MediaPlaybackSniffFetch () <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong,nullable) NSURLResponse *response;
@property(nonatomic,copy) void (^completion)(NSData *,NSURLResponse *,NSError *);
@property(nonatomic) NSUInteger redirectCount;
@property(nonatomic) BOOL finished;
@end

@implementation MediaPlaybackSniffFetch
- (void)startWithRequest:(NSURLRequest *)request completion:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
    NSAssert(NSThread.isMainThread,@"Media page sniffing starts on the main thread");
    self.completion=completion;self.body=[NSMutableData data];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=3.5;configuration.timeoutIntervalForResource=8.0;
    configuration.HTTPMaximumConnectionsPerHost=1;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.HTTPShouldSetCookies=NO;
    self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    NSMutableURLRequest *safe=[request mutableCopy];safe.HTTPShouldHandleCookies=NO;safe.timeoutInterval=3.5;
    self.task=[self.session dataTaskWithRequest:safe];[self.task resume];
}
- (void)cancel {if(self.finished)return;self.finished=YES;[self.task cancel];[self.session invalidateAndCancel];self.completion=nil;self.task=nil;self.session=nil;self.response=nil;self.body=nil;}
- (BOOL)isDirectMediaResponse:(NSURLResponse *)response {
    NSString *mime=response.MIMEType.lowercaseString?:@"";
    return [mime hasPrefix:@"video/"]||[mime hasPrefix:@"audio/"]||[mime containsString:@"mpegurl"]||[mime containsString:@"dash+xml"];
}
- (void)finishWithError:(NSError *)error {
    if(self.finished)return;self.finished=YES;
    NSData *data=[self.body copy]?:[NSData data];NSURLResponse *response=self.response;
    void (^completion)(NSData *,NSURLResponse *,NSError *)=self.completion;self.completion=nil;
    [self.session finishTasksAndInvalidate];self.session=nil;self.task=nil;
    if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(data,response,error);});
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.response=response;
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(status<200||status>=300){completionHandler(NSURLSessionResponseCancel);[self finishWithError:[NSError errorWithDomain:@"MediaPlaybackSniffFetch" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Media page returned an unsuccessful HTTP status"}]];return;}
    if([self isDirectMediaResponse:response]){completionHandler(NSURLSessionResponseCancel);[self finishWithError:nil];return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(data.length>MediaPlaybackSniffMaximumBytes-self.body.length){[task cancel];[self finishWithError:[NSError errorWithDomain:@"MediaPlaybackSniffFetch" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Media page exceeded the 2 MiB extraction limit"}]];return;}
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *from=response.URL,*to=request.URL;NSString *scheme=to.scheme.lowercaseString;
    self.redirectCount++;
    if(self.redirectCount>5||!to.host.length||(![scheme isEqual:@"http"]&&![scheme isEqual:@"https"])||([from.scheme.lowercaseString isEqual:@"https"]&&[scheme isEqual:@"http"])){
        completionHandler(nil);[self finishWithError:[NSError errorWithDomain:@"MediaPlaybackSniffFetch" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Media page redirect was rejected"}]];return;
    }
    NSMutableURLRequest *safe=[request mutableCopy];
    safe.allHTTPHeaderFields=MediaPlaybackHeadersScopedToURL(request.allHTTPHeaderFields?:@{},from,to);
    safe.HTTPShouldHandleCookies=NO;
    completionHandler(safe);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.finished)return;
    [self finishWithError:error];
}
@end
