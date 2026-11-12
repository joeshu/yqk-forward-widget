#import "TVBoxCatalogDownloader.h"
#import "TVBoxCatalogStore.h"
static NSData *TVBoxBundledWeBoxIndexForURL(NSString *sourceURL) {
    if(![sourceURL isKindOfClass:NSString.class]||!sourceURL.length)return nil;
    NSString *lower=(sourceURL.stringByRemovingPercentEncoding?:sourceURL).lowercaseString;
    NSString *resName=nil;
    if([lower containsString:@"ddgksf2013.top/webox/index.json"]||[lower hasSuffix:@"/webox/index.json"]){
        resName=@"webox-index";
    }else if([lower containsString:@"gitee.com/cycod/tvbox"]||[lower containsString:@"cycod/tvbox/raw/master/api.json"]){
        resName=@"cycod-tvbox";
    }else if([lower containsString:@"cttv.vip/app/json/ctys.json"]||[lower containsString:@"cttv.vip/ys/json/ctys.json"]||[lower hasSuffix:@"/ctys.json"]){
        resName=@"cttv-ctys";
    }
    if(!resName.length)return nil;
    NSString *bundlePath=[NSBundle.mainBundle pathForResource:resName ofType:@"json" inDirectory:@"BuiltinMedia"];
    if(bundlePath.length){
        NSData *d=[NSData dataWithContentsOfFile:bundlePath options:NSDataReadingMappedIfSafe error:NULL];
        if(d.length)return d;
    }
    NSString *relPath=[NSString stringWithFormat:@"Resources/BuiltinMedia/%@.json",resName];
    if([NSFileManager.defaultManager fileExistsAtPath:relPath]){
        return [NSData dataWithContentsOfFile:relPath options:NSDataReadingMappedIfSafe error:NULL];
    }
    return nil;
}
@interface TVBoxCatalogDownloader () <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,copy) NSString *source;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSError *);
@property(nonatomic) BOOL finished;
@property(nonatomic) NSUInteger redirectCount;
@end
@implementation TVBoxCatalogDownloader
- (NSError *)failure:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostTVBox" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (void)loadURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    self.completion=completion;self.source=url.absoluteString;self.redirectCount=0;NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(!parts||![@[@"https",@"http"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length){[self finish:nil error:[self failure:@"请输入有效的 HTTP/HTTPS TVBox JSON 地址"]];return;}
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;NSTimeInterval savedTimeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;NSTimeInterval timeout=MIN(40,MAX(5,savedTimeout));config.timeoutIntervalForRequest=timeout;config.timeoutIntervalForResource=timeout+5;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];self.data=[NSMutableData data];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    [req setValue:@"okhttp/4.12.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
    self.task=[self.session dataTaskWithRequest:req];[self.task resume];
}
- (void)cancel {[self finish:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];}
- (void)finish:(NSDictionary *)catalog error:(NSError *)error { @synchronized(self){if(self.finished)return;self.finished=YES;}[self.session invalidateAndCancel];self.session=nil;self.task=nil;self.data=nil;void (^completion)(NSDictionary *,NSError *)=self.completion;self.completion=nil;if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(catalog,error);}); }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    BOOL valid=task==self.task&&[response isKindOfClass:NSHTTPURLResponse.class]&&((NSHTTPURLResponse *)response).statusCode==200&&response.expectedContentLength<=8*1024*1024;completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid){
        NSData *bundled=TVBoxBundledWeBoxIndexForURL(self.source);
        if(bundled.length){NSError *parseError=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:bundled sourceURL:self.source error:&parseError];if(catalog){[self finish:catalog error:nil];return;}}
        [self finish:nil error:[self failure:@"配置请求失败、HTTP 状态异常或超过 8 MiB"]];
    }else if(response.URL.absoluteString.length)self.source=response.URL.absoluteString;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {if(task!=self.task||self.finished)return;if(self.data.length+data.length>8*1024*1024){[task cancel];[self finish:nil error:[self failure:@"TVBox 配置超过 8 MiB 上限"]];return;}[self.data appendData:data];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    NSURLComponents *from=[NSURLComponents componentsWithURL:response.URL resolvingAgainstBaseURL:NO],*to=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    BOOL valid=task==self.task&&!self.finished&&++self.redirectCount<=5&&to.scheme.length&&[@[@"http",@"https"] containsObject:to.scheme.lowercaseString]&&to.host.length&&!to.user.length&&!to.password.length;
    if([from.scheme.lowercaseString isEqual:@"https"]&&[to.scheme.lowercaseString isEqual:@"http"])valid=NO;
    completion(valid?request:nil);if(!valid)[self finish:nil error:[self failure:@"TVBox 配置重定向无效、降级或超过 5 次"]];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(task!=self.task||self.finished)return;
    if(error){
        if(error.code!=NSURLErrorCancelled){
            NSData *bundled=TVBoxBundledWeBoxIndexForURL(self.source);
            if(bundled.length){NSError *parseError=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:bundled sourceURL:self.source error:&parseError];if(catalog){[self finish:catalog error:nil];return;}}
        }
        [self finish:nil error:error];return;
    }
    NSError *parseError=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:self.data sourceURL:self.source error:&parseError];
    if(!catalog){
        NSData *bundled=TVBoxBundledWeBoxIndexForURL(self.source);
        if(bundled.length)catalog=[TVBoxCatalogStore parseData:bundled sourceURL:self.source error:&parseError];
    }
    [self finish:catalog error:parseError];
}
@end
