#import "ResourceImportFetcher.h"
@interface ResourceImportFetcher () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSURL *requestURL;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL completed;
@property(nonatomic) NSUInteger redirects;
@end
@implementation ResourceImportFetcher
- (void)load:(NSURL *)url {
    @synchronized(self){
        if(self.started||self.cancelled)return;self.started=YES;self.requestURL=url;
        if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||url.user.length||url.password.length){self.failure=[NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源链接不是有效的 HTTP/HTTPS 地址"}];[self deliver:nil response:nil error:self.failure];return;}
        self.body=[NSMutableData data];
        NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=30;
        NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
        self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 CCTVHost/1.0" forHTTPHeaderField:@"User-Agent"];
        self.task=[self.session dataTaskWithRequest:request];[self.task resume];
    }
}
- (void)cancel {
    NSURLSession *session=nil;
    @synchronized(self){self.cancelled=YES;self.completion=nil;self.fallbackDataProvider=nil;self.body=nil;session=self.session;self.session=nil;self.task=nil;}
    [session invalidateAndCancel];
}
- (void)deliver:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    @synchronized(self){if(self.completed||self.cancelled)return;self.completed=YES;}
    dispatch_async(dispatch_get_main_queue(),^{
        void (^completion)(NSData *,NSURLResponse *,NSError *)=nil;
        @synchronized(self){if(self.cancelled)return;completion=self.completion;self.completion=nil;self.fallbackDataProvider=nil;}
        if(completion)completion(data,response,error);
    });
}
// Default NSURLSession server-trust handling is intentional; never accept every certificate.
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BOOL valid=NO;
    @synchronized(self){
        if(!self.cancelled&&task==self.task){self.response=response;NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
            valid=status>=200&&status<300&&response.expectedContentLength<=8*1024*1024;
            if(!valid)self.failure=[NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:response.expectedContentLength>8*1024*1024?@"资源超过 8 MiB 上限":[NSString stringWithFormat:@"资源返回 HTTP %ld",(long)status]}];
        }
    }
    completionHandler(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    BOOL stop=NO;
    @synchronized(self){if(self.cancelled||task!=self.task)return;if(self.body.length+data.length>8*1024*1024){self.failure=[NSError errorWithDomain:@"ResourceImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"资源超过 8 MiB 上限"}];stop=YES;}else[self.body appendData:data];}
    if(stop)[task cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BOOL valid=NO;
    @synchronized(self){NSURL *url=request.URL;valid=!self.cancelled&&task==self.task&&++self.redirects<=5&&url.host.length&&!url.user.length&&!url.password.length&&[@[@"http",@"https"] containsObject:url.scheme.lowercaseString]&&!([response.URL.scheme.lowercaseString isEqual:@"https"]&&![url.scheme.lowercaseString isEqual:@"https"]);
        if(!valid&&!self.cancelled)self.failure=[NSError errorWithDomain:@"ResourceImport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源重定向无效、降级或超过 5 次"}];
    }
    completionHandler(valid?request:nil);if(!valid)[task cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSData *data=nil;NSURLResponse *response=nil;NSError *failure=nil;NSData *(^fallback)(NSURL *)=nil;NSURL *origin=nil;
    @synchronized(self){if(self.cancelled||task!=self.task)return;data=[self.body copy];self.body=nil;response=self.response;failure=self.failure?:error;fallback=[self.fallbackDataProvider copy];origin=self.requestURL;self.session=nil;self.task=nil;}
    [session finishTasksAndInvalidate];
    if((failure||!data.length)&&fallback){NSData *bundled=fallback(origin);if(bundled.length){data=bundled;failure=nil;}}
    [self deliver:data response:response error:failure];
}
@end
