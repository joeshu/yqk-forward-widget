#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#import <CommonCrypto/CommonDigest.h>

typedef NS_ENUM(NSUInteger, PackageDownloadPhase) { PackageChecksum, PackageScript, PackageConfigChecksum, PackageConfig };
static NSString *PackageMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];CC_MD5(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[hash appendFormat:@"%02x",digest[i]];return hash;
}
@interface MediaPackageDownloader () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSData *scriptData;
@property(nonatomic,strong) NSURL *originalURL;
@property(nonatomic,strong) NSURL *targetURL;
@property(nonatomic,strong) NSURL *effectiveURL;
@property(nonatomic,copy) NSString *checksum;
@property(nonatomic,copy) NSString *configChecksum;
@property(nonatomic,copy) NSString *configContentChecksum;
@property(nonatomic,copy) NSString *configurationState;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSError *);
@property(atomic) BOOL finished;
@property(nonatomic) PackageDownloadPhase phase;
@property(nonatomic) NSInteger responseStatus;
@property(nonatomic) NSInteger redirects;
@property(nonatomic) int64_t expectedBytes;
@property(nonatomic) NSTimeInterval lastProgressTime;
@end
@implementation MediaPackageDownloader
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostImport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (BOOL)validURL:(NSURL *)url {return [@[@"http",@"https"] containsObject:url.scheme.lowercaseString]&&url.host.length&&!url.user.length&&!url.password.length;}
- (NSUInteger)limit {return (self.phase==PackageChecksum||self.phase==PackageConfigChecksum)?4096:(self.phase==PackageConfig?65536:([self.targetURL.pathExtension.lowercaseString isEqual:@"zip"]?24:8)*1024*1024);}
- (NSString *)stage {return @[@"读取资源校验值",@"下载主脚本 / 资源包",@"检查配套配置校验值",@"下载配套配置"][(NSUInteger)self.phase];}
- (void)progress:(NSString *)stage {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;if(self.lastProgressTime>0&&now-self.lastProgressTime<0.12)return;self.lastProgressTime=now;
    void(^callback)(NSString *,int64_t,int64_t)=[self.onProgress copy];int64_t received=self.body.length,expected=self.expectedBytes;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(stage,received,expected);});
}
- (void)importURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    self.completion=completion;self.originalURL=url;self.targetURL=url;self.configurationState=@"not_applicable";
    if(![self validURL:url]){[self finish:nil error:[self error:@"请输入有效的 HTTP/HTTPS 资源文件地址"]];return;}
    self.phase=[url.pathExtension.lowercaseString isEqual:@"md5"]?PackageChecksum:PackageScript;
    if(self.phase==PackageChecksum){NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];c.path=c.path.stringByDeletingPathExtension;self.targetURL=c.URL;}
    // A short checksum URL may redirect to the conventional index.js.md5 form;
    // validate the resolved script extension after reading the final checksum.
    if(self.phase!=PackageChecksum && ![@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:self.targetURL.pathExtension.lowercaseString]){[self finish:nil error:[self error:@"链接须指向 JS、Python、ZIP 或对应的 .md5 校验文件"]];return;}
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=60;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
    self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];[self begin:url];
}
- (void)begin:(NSURL *)url {
    if(self.finished)return;self.body=[NSMutableData data];self.responseStatus=0;self.redirects=0;self.expectedBytes=-1;self.lastProgressTime=0;
    self.task=[self.session dataTaskWithURL:url];[self progress:self.stage];[self.task resume];
}
- (NSURL *)configURL:(BOOL)checksum {
    NSURLComponents *c=[NSURLComponents componentsWithURL:self.effectiveURL resolvingAgainstBaseURL:NO];
    c.path=[c.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:checksum?@"index.config.js.md5":@"index.config.js"];c.fragment=nil;return c.URL;
}
- (void)cancel {[self finish:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];}
- (void)finish:(NSDictionary *)service error:(NSError *)error {
    @synchronized(self){if(self.finished)return;self.finished=YES;}
    [self.session invalidateAndCancel];self.session=nil;self.task=nil;self.body=nil;self.scriptData=nil;
    void (^callback)(NSDictionary *,NSError *)=self.completion;self.completion=nil;self.onProgress=nil;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(service,error);});
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if(self.finished||task!=self.task){completion(NSURLSessionResponseCancel);return;}
    self.responseStatus=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;self.expectedBytes=response.expectedContentLength;
    BOOL optional=self.phase==PackageConfigChecksum||self.phase==PackageConfig;
    BOOL missing=optional&&self.responseStatus==404;
    BOOL valid=missing||(self.responseStatus==200&&response.expectedContentLength<=(long long)self.limit);
    if(self.phase==PackageScript&&self.responseStatus==200)self.effectiveURL=response.URL;
    // A redirected checksum describes the script beside the final checksum URL.
    if(self.phase==PackageChecksum&&self.responseStatus==200){NSURLComponents *c=[NSURLComponents componentsWithURL:response.URL resolvingAgainstBaseURL:NO];if([c.path.pathExtension.lowercaseString isEqual:@"md5"]){c.path=c.path.stringByDeletingPathExtension;self.targetURL=c.URL;}}
    completion(valid&&!missing?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid)[self finish:nil error:[self error:[NSString stringWithFormat:@"%@失败：HTTP %ld，或响应超过大小上限",self.stage,(long)self.responseStatus]]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.finished||task!=self.task)return;
    if(self.body.length+data.length>self.limit){[task cancel];[self finish:nil error:[self error:[self.stage stringByAppendingString:@"超过大小上限"]]];return;}
    [self.body appendData:data];[self progress:self.stage];
}
- (NSString *)readChecksum {
    NSString *text=[[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    text=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *parts=[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSString *hash=parts.firstObject;
    return hash.length==32&&[hash rangeOfString:@"^[0-9a-fA-F]{32}$" options:NSRegularExpressionSearch].location!=NSNotFound?hash.lowercaseString:nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.finished||task!=self.task)return;BOOL missing=(self.phase==PackageConfigChecksum||self.phase==PackageConfig)&&self.responseStatus==404;
    if(error&&!(missing&&error.code==NSURLErrorCancelled)){[self finish:nil error:error];return;}
    if(self.phase==PackageChecksum||self.phase==PackageConfigChecksum){
        BOOL config=self.phase==PackageConfigChecksum;NSString *hash=self.responseStatus==404?nil:[self readChecksum];
        if(self.responseStatus!=404&&!hash){[self finish:nil error:[self error:config?@"配套配置 MD5 格式无效":@"资源 MD5 校验文件格式无效"]];return;}
        if(config){self.configChecksum=hash;self.phase=PackageConfig;[self begin:[self configURL:NO]];}
        else{self.checksum=hash;if(![@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:self.targetURL.pathExtension.lowercaseString]){[self finish:nil error:[self error:@"MD5 地址最终没有指向受支持的 JS、Python 或 ZIP 文件"]];return;}self.phase=PackageScript;[self begin:self.targetURL];}return;
    }
    if(self.phase==PackageConfig){
        if(self.responseStatus==404){if(self.configChecksum){[self finish:nil error:[self error:@"配置校验文件存在，但对应配置文件缺失，未安装"]];return;}self.configurationState=@"missing_using_defaults";[self install:@{}];return;}
        if(!self.body.length||![[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding]){[self finish:nil error:[self error:@"配套配置不是有效 UTF-8 文件"]];return;}
        if(self.configChecksum&&![PackageMD5(self.body) isEqual:self.configChecksum]){[self finish:nil error:[self error:@"配套配置与 MD5 校验值不一致，未安装"]];return;}
        self.configContentChecksum=PackageMD5(self.body);
        self.configurationState=self.configChecksum?@"verified":@"downloaded_without_checksum";
        [self install:@{@"index.config.js":[self.body copy]}];return;
    }
    if(self.checksum&&![PackageMD5(self.body) isEqual:self.checksum]){[self finish:nil error:[self error:@"资源与 MD5 校验值不一致，未安装"]];return;}
    self.scriptData=[self.body copy];
    NSString *text=[@[@"js",@"mjs",@"cjs"] containsObject:self.targetURL.pathExtension.lowercaseString]?[[NSString alloc] initWithData:self.scriptData encoding:NSUTF8StringEncoding]:nil;
    BOOL catpaw=[text containsString:@"/config"]&&[text containsString:@"/spider"]&&([text containsString:@"catServerFactory"]||[text containsString:@"createService"]||[text containsString:@"serverFactory"]);
    if(catpaw){self.phase=PackageConfigChecksum;[self begin:[self configURL:YES]];return;}
    [self install:@{}];
}
- (void)install:(NSDictionary<NSString *,NSData *> *)companions {
    if(self.finished)return;self.lastProgressTime=0;[self progress:@"识别并登记资源"];
    NSError *error=nil;NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];NSString *path=[directory stringByAppendingPathComponent:self.targetURL.lastPathComponent];NSDictionary *service=nil;
    if(!error&&[self.scriptData writeToFile:path options:NSDataWritingAtomic error:&error])service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] companionFiles:companions error:&error];
    [fm removeItemAtPath:directory error:NULL];
    if(self.finished){if(service)[ServiceStore remove:service[@"id"]];return;}
    if(service){NSMutableDictionary *saved=[service mutableCopy];saved[@"url"]=self.originalURL.absoluteString;
        if([@[@"index",@"main"] containsObject:[service[@"name"] lowercaseString]])saved[@"name"]=[NSString stringWithFormat:@"%@ · %@",self.originalURL.host,[service[@"protocol"] isEqual:@"catpaw-http"]?@"猫源":service[@"name"]];saved[@"downloadChecksum"]=self.checksum?:@"";saved[@"configDownloadChecksum"]=self.configChecksum?:@"";saved[@"configContentChecksum"]=self.configContentChecksum?:@"";saved[@"configurationState"]=self.configurationState;service=saved;}
    [self finish:service error:error];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL valid=task==self.task&&++self.redirects<=5&&[self validURL:request.URL];
    if(self.phase==PackageConfig||self.phase==PackageConfigChecksum){NSURL *base=self.effectiveURL;valid=valid&&[request.URL.scheme.lowercaseString isEqual:base.scheme.lowercaseString]&&[request.URL.host.lowercaseString isEqual:base.host.lowercaseString]&&[(request.URL.port?:@0) isEqual:(base.port?:@0)];}
    completion(valid?request:nil);if(!valid)[self finish:nil error:[self error:@"重定向次数过多，或配套配置跳转到其他来源"]];
}
@end
