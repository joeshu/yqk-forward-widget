#import "ResourceImportFetcher.h"

static const NSUInteger ResourceImportTextLimit = 8 * 1024 * 1024;
static const NSUInteger ResourceImportZIPLimit = 24 * 1024 * 1024;

@interface ResourceImportFetcher () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSFileHandle *bodyFile;
@property(nonatomic,strong) NSURL *bodyURL;
@property(nonatomic,strong) NSMutableData *prefix;
@property(nonatomic) NSUInteger receivedBytes;
@property(nonatomic) BOOL typeKnown;
@property(nonatomic) BOOL isZIP;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSURL *requestURL;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL completed;
@property(nonatomic) NSUInteger redirects;
-  (void)deliver:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error;
- (void)discardBody;
@end
@implementation ResourceImportFetcher
- (void)load:(NSURL *)url {
    @synchronized(self){
        if(self.started||self.cancelled)return;self.started=YES;self.requestURL=url;
        if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||url.user.length||url.password.length){self.failure=[NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源链接不是有效的 HTTP/HTTPS 地址"}];[self deliver:nil response:nil error:self.failure];return;}
        self.prefix=[NSMutableData dataWithCapacity:4];
        NSString *name=[NSString stringWithFormat:@"cctv-resource-fetch-%@.tmp",NSUUID.UUID.UUIDString];
        self.bodyURL=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        if(![NSFileManager.defaultManager createFileAtPath:self.bodyURL.path contents:nil attributes:@{NSFilePosixPermissions:@0600}]){
            self.failure=[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"无法创建资源下载暂存文件"}];
            [self deliver:nil response:nil error:self.failure];return;
        }
        NSError *fileError=nil;
        self.bodyFile=[NSFileHandle fileHandleForWritingToURL:self.bodyURL error:&fileError];
        if(!self.bodyFile){[self discardBody];self.failure=fileError?:[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"无法打开资源下载暂存文件"}];[self deliver:nil response:nil error:self.failure];return;}
        NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=30;
        NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
        self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
        [request setValue:ResourceImportUserAgent() forHTTPHeaderField:@"User-Agent"];
        self.task=[self.session dataTaskWithRequest:request];[self.task resume];
    }
}
- (void)cancel {
    NSURLSession *session=nil;
    @synchronized(self){self.cancelled=YES;self.completion=nil;self.fallbackDataProvider=nil;[self discardBody];session=self.session;self.session=nil;self.task=nil;}
    [session invalidateAndCancel];
}
- (void)discardBody {
    [self.bodyFile closeAndReturnError:NULL];
    self.bodyFile=nil;
    if(self.bodyURL)[NSFileManager.defaultManager removeItemAtURL:self.bodyURL error:NULL];
    self.bodyURL=nil;self.prefix=nil;
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
            valid=status>=200&&status<300&&response.expectedContentLength<=(long long)ResourceImportZIPLimit;
            if(!valid&&!self.failure){NSString *message=(status<200||status>=300)?[NSString stringWithFormat:@"资源返回 HTTP %ld",(long)status]:[NSString stringWithFormat:@"资源声明大小 %.1f MiB，超过 ZIP 24 MiB 上限",(double)response.expectedContentLength/(1024.0*1024.0)];self.failure=[NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
        }
    }
    completionHandler(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    BOOL stop=NO;
    @synchronized(self){
        if(self.cancelled||task!=self.task)return;
        if(!self.typeKnown){
            NSUInteger wanted=4-self.prefix.length;
            [self.prefix appendBytes:data.bytes length:MIN(wanted,data.length)];
            if(self.prefix.length==4){
                const unsigned char *bytes=self.prefix.bytes;
                self.isZIP=bytes[0]=='P'&&bytes[1]=='K'&&bytes[2]==3&&bytes[3]==4;
                self.typeKnown=YES;
            }
        }
        NSUInteger limit=self.typeKnown&&!self.isZIP?ResourceImportTextLimit:ResourceImportZIPLimit;
        long long expected=self.response.expectedContentLength;
        BOOL declaredTooLarge=self.typeKnown && expected>0 && (unsigned long long)expected>limit;
        if(data.length>limit-self.receivedBytes || declaredTooLarge){
            double size=(double)(declaredTooLarge?(unsigned long long)expected:(unsigned long long)self.receivedBytes+data.length)/(1024.0*1024.0);
            NSString *message=[NSString stringWithFormat:@"%@大小至少 %.1f MiB，超过 %lu MiB 上限%@",self.isZIP?@"ZIP 资源":@"资源",size,(unsigned long)(limit/(1024*1024)),self.isZIP?@"":@"；ZIP 可选择本地文件导入"];
            self.failure=[NSError errorWithDomain:@"ResourceImport" code:2 userInfo:@{NSLocalizedDescriptionKey:message}];stop=YES;
        }else{
            if([self.bodyFile writeData:data error:NULL])self.receivedBytes+=data.length;
            else{self.failure=[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"资源下载暂存失败，请检查可用空间后重试"}];stop=YES;}
        }
    }
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
    @synchronized(self){
        if(self.cancelled||task!=self.task)return;
        response=self.response;failure=self.failure?:error;fallback=[self.fallbackDataProvider copy];origin=self.requestURL;
        if(self.bodyFile&&![self.bodyFile closeAndReturnError:NULL]){if(!failure)failure=[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"资源下载暂存失败"}];}
        self.bodyFile=nil;
        if(!failure){NSError *readError=nil;data=[NSData dataWithContentsOfURL:self.bodyURL options:NSDataReadingMappedIfSafe error:&readError];if(!data)failure=readError?:[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"无法读取资源下载暂存文件"}];}
        [self discardBody];self.session=nil;self.task=nil;
    }
    [session finishTasksAndInvalidate];
    if((failure||!data.length)&&fallback){NSData *bundled=fallback(origin);if(bundled.length){data=bundled;failure=nil;}}
    [self deliver:data response:response error:failure];
}
@end
