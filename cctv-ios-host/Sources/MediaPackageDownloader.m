#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import <CommonCrypto/CommonDigest.h>
@interface MediaPackageDownloader () <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSURL *originalURL;
@property(nonatomic, strong) NSURL *targetURL;
@property(nonatomic, copy) NSString *checksum;
@property(nonatomic, copy) void (^completion)(NSDictionary *,NSError *);
@property(atomic) BOOL finished;
@property(nonatomic) BOOL readingChecksum;
@end
@implementation MediaPackageDownloader
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostImport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (void)importURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    self.completion=completion;self.originalURL=url;
    if(![@[@"http",@"https"] containsObject:url.scheme.lowercaseString] || !url.host.length || url.user.length || url.password.length){[self finish:nil error:[self error:@"请输入有效的 HTTP/HTTPS 资源文件地址"]];return;}
    self.readingChecksum=[url.pathExtension.lowercaseString isEqual:@"md5"];self.targetURL=url;
    if(self.readingChecksum){NSURLComponents *components=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];components.path=components.path.stringByDeletingPathExtension;self.targetURL=components.URL;}
    if(![@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:self.targetURL.pathExtension.lowercaseString]){[self finish:nil error:[self error:@"链接须指向 JS、Python、ZIP 或对应的 .md5 校验文件"]];return;}
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=60;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    [self begin:url];
}
- (void)begin:(NSURL *)url {if(self.finished)return;self.body=[NSMutableData data];[[self.session dataTaskWithURL:url] resume];}
- (void)cancel {[self finish:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];}
- (void)finish:(NSDictionary *)service error:(NSError *)error {
    @synchronized(self){if(self.finished)return;self.finished=YES;}
    [self.session invalidateAndCancel];self.session=nil;self.body=nil;void (^callback)(NSDictionary *,NSError *)=self.completion;self.completion=nil;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(service,error);});
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSUInteger limit=self.readingChecksum?4096:24*1024*1024;
    BOOL valid=!self.finished && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode==200 && response.expectedContentLength<=(long long)limit;
    completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);if(!valid)[self finish:nil error:[self error:@"资源下载失败、HTTP 状态异常或文件过大"]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.finished)return;NSUInteger limit=self.readingChecksum?4096:24*1024*1024;
    if(self.body.length+data.length>limit){[task cancel];[self finish:nil error:[self error:@"资源下载超过大小上限"]];return;}[self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.finished)return;if(error){[self finish:nil error:error];return;}
    if(self.readingChecksum){
        NSString *text=[[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];NSString *hash=[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].firstObject;
        if([hash rangeOfString:@"^[0-9a-fA-F]{32}$" options:NSRegularExpressionSearch].location==NSNotFound || hash.length!=32){[self finish:nil error:[self error:@"MD5 校验文件格式无效"]];return;}
        self.checksum=hash.lowercaseString;self.readingChecksum=NO;[self begin:self.targetURL];return;
    }
    if(self.checksum){unsigned char digest[CC_MD5_DIGEST_LENGTH];CC_MD5(self.body.bytes,(CC_LONG)self.body.length,digest);NSMutableString *hash=[NSMutableString string];for(NSUInteger index=0;index<sizeof(digest);index++)[hash appendFormat:@"%02x",digest[index]];if(![hash isEqual:self.checksum]){[self finish:nil error:[self error:@"资源与 MD5 校验值不一致，未安装"]];return;}}
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *path=[directory stringByAppendingPathComponent:self.targetURL.lastPathComponent];
    NSDictionary *service=nil;if(!error && [self.body writeToFile:path options:NSDataWritingAtomic error:&error]){self.body=nil;service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] error:&error];}
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
    if(service){NSMutableDictionary *saved=[service mutableCopy];saved[@"url"]=self.originalURL.absoluteString;service=saved;}
    [self finish:service error:error];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {completion([@[@"http",@"https"] containsObject:request.URL.scheme.lowercaseString] && !request.URL.user.length && !request.URL.password.length?request:nil);}
@end
