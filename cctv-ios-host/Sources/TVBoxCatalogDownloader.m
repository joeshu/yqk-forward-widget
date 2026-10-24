#import "TVBoxCatalogDownloader.h"
#import "TVBoxCatalogStore.h"
@interface TVBoxCatalogDownloader () <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,copy) NSString *source;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSError *);
@property(nonatomic) BOOL finished;
@end
@implementation TVBoxCatalogDownloader
- (NSError *)failure:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostTVBox" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (void)loadURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    self.completion=completion;self.source=url.absoluteString;NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![@[@"https",@"http"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length){[self finish:nil error:[self failure:@"请输入有效的 HTTP/HTTPS TVBox JSON 地址"]];return;}
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=20;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];self.data=[NSMutableData data];self.task=[self.session dataTaskWithURL:url];[self.task resume];
}
- (void)cancel {[self finish:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];}
- (void)finish:(NSDictionary *)catalog error:(NSError *)error { @synchronized(self){if(self.finished)return;self.finished=YES;}[self.session invalidateAndCancel];self.session=nil;self.task=nil;self.data=nil;void (^completion)(NSDictionary *,NSError *)=self.completion;self.completion=nil;if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(catalog,error);}); }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    BOOL valid=task==self.task&&[response isKindOfClass:NSHTTPURLResponse.class]&&((NSHTTPURLResponse *)response).statusCode==200&&response.expectedContentLength<=2*1024*1024;completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);if(!valid)[self finish:nil error:[self failure:@"配置请求失败、HTTP 状态异常或超过 2 MiB"]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {if(task!=self.task||self.finished)return;if(self.data.length+data.length>2*1024*1024){[task cancel];[self finish:nil error:[self failure:@"TVBox 配置超过 2 MiB 上限"]];return;}[self.data appendData:data];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completion {completion(nil);}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {if(task!=self.task||self.finished)return;if(error){[self finish:nil error:error];return;}NSError *parseError=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:self.data sourceURL:self.source error:&parseError];[self finish:catalog error:parseError];}
@end
