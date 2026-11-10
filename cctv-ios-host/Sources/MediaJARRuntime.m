#import "MediaJARRuntime.h"
#import "MediaJARSource.h"
#import <CommonCrypto/CommonDigest.h>
#ifndef CCTV_JAR_ENABLED
#define CCTV_JAR_ENABLED 0
#endif
#if CCTV_JAR_ENABLED
extern char *TVAppleRuntimeRequest(const char *,const char *);
#endif
static NSError *JARError(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostJARRuntime" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *JARHash(NSData *data,BOOL md5) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if(md5)CC_MD5(data.bytes,(CC_LONG)data.length,digest);else CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];
    for(NSUInteger i=0;i<(md5?CC_MD5_DIGEST_LENGTH:CC_SHA256_DIGEST_LENGTH);i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
static NSString *JARRoot(void) {
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *root=[support stringByAppendingPathComponent:@"JARRuntime"];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSURL fileURLWithPath:root] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    return root;
}
static NSDictionary *JARInvoke(NSDictionary *input) {
#if CCTV_JAR_ENABLED
    NSData *json=[NSJSONSerialization dataWithJSONObject:input options:0 error:NULL];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    char *output=TVAppleRuntimeRequest(NSBundle.mainBundle.resourcePath.UTF8String,text.UTF8String);
    if(!output)return @{@"errorCode":@"empty_response"};
    NSData *data=[NSData dataWithBytes:output length:strlen(output)];free(output);
    id response=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [response isKindOfClass:NSDictionary.class]?response:@{@"errorCode":@"invalid_response"};
#else
    return @{@"errorCode":@"missing_runtime"};
#endif
}
// Requests need a larger native stack for the interpreter and deep DEX conversion.
static void JARThread(void (^work)(void)) {
    NSThread *thread=[[NSThread alloc] initWithBlock:work];thread.name=@"CCTVHost JAR";thread.stackSize=8*1024*1024;[thread start];
}
@interface MediaJARRequest () <NSURLSessionDataDelegate>
@property(atomic) BOOL cancelled;
@property(atomic) BOOL executing;
@property(atomic,strong) NSURLSessionDataTask *download;
@property(atomic,strong) dispatch_source_t watchdog;
@property(nonatomic,strong) NSMutableData *bytes;
@property(nonatomic,strong) NSError *downloadError;
@property(nonatomic,strong) dispatch_semaphore_t downloaded;
@property(nonatomic,copy) NSString *requestID;
@end
@implementation MediaJARRequest
- (void)cancel {
    self.cancelled=YES;if(self.watchdog){dispatch_source_cancel(self.watchdog);self.watchdog=nil;}[self.download cancel];
    if(self.executing){NSString *requestID=self.requestID;JARThread(^{JARInvoke(@{@"command":@"cancel",@"request":requestID});});}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(status<200||status>=300){self.downloadError=JARError(status,[NSString stringWithFormat:@"JAR 下载返回 HTTP %ld",(long)status]);completion(NSURLSessionResponseCancel);return;}
    if(response.expectedContentLength>64*1024*1024){self.downloadError=JARError(2,@"JAR 超过 64 MiB 限制");completion(NSURLSessionResponseCancel);return;}
    completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.bytes.length+data.length>64*1024*1024){self.downloadError=JARError(2,@"JAR 超过 64 MiB 限制");[task cancel];return;}
    [self.bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(!self.downloadError)self.downloadError=error;dispatch_semaphore_signal(self.downloaded);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    NSURL *from=task.originalRequest.URL,*to=request.URL;
    if(![@[@"http",@"https"] containsObject:to.scheme.lowercaseString]||to.user.length||to.password.length||([from.scheme isEqual:@"https"]&&![to.scheme isEqual:@"https"])){completion(nil);return;}
    NSMutableURLRequest *safe=[request mutableCopy];
    BOOL same=[from.scheme.lowercaseString isEqual:to.scheme.lowercaseString]&&[from.host.lowercaseString isEqual:to.host.lowercaseString]&&[(from.port?:([from.scheme isEqual:@"https"]?@443:@80)) isEqual:(to.port?:([to.scheme isEqual:@"https"]?@443:@80))];
    if(!same)for(NSString *name in safe.allHTTPHeaderFields.allKeys)if(![@[@"user-agent",@"accept"] containsObject:name.lowercaseString])[safe setValue:nil forHTTPHeaderField:name];
    completion(safe);
}
@end
@implementation MediaJARRuntime
+ (BOOL)available {
#if CCTV_JAR_ENABLED
    return [NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"JavaHost/host.jar"]] && [NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"lib/lib/modules"]];
#else
    return NO;
#endif
}
+ (MediaJARRequest *)requestSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id,NSError *))completion {
    MediaJARRequest *ticket=[MediaJARRequest new];ticket.requestID=NSUUID.UUID.UUIDString;
    static NSOperationQueue *queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=[NSOperationQueue new];queue.name=@"CCTVHost JAR requests";queue.maxConcurrentOperationCount=2;});
    if(queue.operationCount>=4){dispatch_async(dispatch_get_main_queue(),^{if(!ticket.cancelled&&completion)completion(nil,JARError(12,@"JAR 准备队列已满，请稍候重试"));});return ticket;}
    dispatch_source_t watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    ticket.watchdog=watchdog;
    dispatch_source_set_timer(watchdog,dispatch_time(DISPATCH_TIME_NOW,900*NSEC_PER_SEC),DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
    __weak MediaJARRequest *weakTicket=ticket;
    dispatch_source_set_event_handler(watchdog,^{MediaJARRequest *active=weakTicket;if(!active||active.cancelled)return;[active cancel];if(completion)completion(nil,JARError(13,@"JAR 首次准备超过 15 分钟，已取消请求；已完成的转换缓存会保留"));});
    dispatch_resume(watchdog);
    // Cancelled queued requests perform no download, initialization or plugin work.
    [queue addOperationWithBlock:^{
        if(ticket.cancelled)return;
        dispatch_semaphore_t finished=dispatch_semaphore_create(0);
        JARThread(^{@autoreleasepool {
            NSError *error=nil;id result=nil;
            @try {result=[self perform:source operation:operation arguments:arguments ticket:ticket error:&error];}
            @catch(NSException *exception){error=JARError(3,@"JAR 运行时请求失败，请查看诊断日志");}
            dispatch_async(dispatch_get_main_queue(),^{if(ticket.watchdog){dispatch_source_cancel(ticket.watchdog);ticket.watchdog=nil;}if(!ticket.cancelled&&completion)completion(result,error);});
            dispatch_semaphore_signal(finished);
        }});
        dispatch_semaphore_wait(finished,DISPATCH_TIME_FOREVER);
    }];
    return ticket;
}
+ (id)perform:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments ticket:(MediaJARRequest *)ticket error:(NSError **)error {
    if(!self.available){if(error)*error=JARError(4,@"此构建未包含 JAR 运行时，请安装完整版本");return nil;}
    NSDictionary *params=MediaJARParameters(operation,arguments);
    if(!params){if(error)*error=JARError(5,@"JAR 操作不受支持");return nil;}
    NSDictionary *reference=source[@"jar"];
    NSString *rawURL=[reference[@"url"] isKindOfClass:NSString.class]?reference[@"url"]:@"";
    NSString *fingerprint=[reference[@"md5"] isKindOfClass:NSString.class]?reference[@"md5"]:@"";
    NSDictionary *validated=MediaJARReference(fingerprint.length?[rawURL stringByAppendingFormat:@";md5;%@",fingerprint]:rawURL,nil);
    if(!validated||!MediaJARClass(source[@"api"]).length){if(error)*error=JARError(6,@"订阅缺少有效 JAR 地址或爬虫类名");return nil;}
    NSString *root=JARRoot(),*url=validated[@"url"];
    // Include headers and fingerprint in download identity; never reuse another account's archive.
    NSDictionary *headers=[source[@"header"] isKindOfClass:NSDictionary.class]?source[@"header"]:@{};
    NSData *identity=[NSJSONSerialization dataWithJSONObject:@{ @"url":url,@"headers":headers,@"md5":reference[@"md5"]?:@"" } options:NSJSONWritingSortedKeys error:NULL];
    NSString *recordPath=[root stringByAppendingPathComponent:[JARHash(identity,NO) stringByAppendingString:@".json"]];
    NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:recordPath]?:[NSData data] options:0 error:NULL];
    NSString *digest=[record[@"digest"] isKindOfClass:NSString.class]?record[@"digest"]:@"";
    if(digest.length!=64||[digest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)digest=@"";
    NSString *jar=[root stringByAppendingPathComponent:[digest stringByAppendingString:@".jar"]];
    NSData *data=digest.length?[NSData dataWithContentsOfFile:jar options:NSDataReadingMappedIfSafe error:NULL]:nil;
    BOOL cached=data.length&&[JARHash(data,NO) isEqual:digest]&&NSDate.date.timeIntervalSince1970-[record[@"time"] doubleValue]<300;
    if(!cached){
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45];
        for(id name in headers){id value=headers[name];if([name isKindOfClass:NSString.class]&&[value isKindOfClass:NSString.class]&&[name length]<=128&&[value length]<=4096&&[name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound&&[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound&&![name isEqual:@"Host"])[request setValue:value forHTTPHeaderField:name];}
        ticket.bytes=[NSMutableData data];ticket.downloaded=dispatch_semaphore_create(0);
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.timeoutIntervalForResource=60;
        NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration delegate:ticket delegateQueue:nil];
        ticket.download=[session dataTaskWithRequest:request];if(!ticket.cancelled)[ticket.download resume];else[ticket.download cancel];
        dispatch_semaphore_wait(ticket.downloaded,DISPATCH_TIME_FOREVER);[session invalidateAndCancel];ticket.download=nil;
        if(ticket.downloadError||ticket.cancelled){if(error)*error=ticket.downloadError?:JARError(NSURLErrorCancelled,@"请求已取消");return nil;}
        data=ticket.bytes;ticket.bytes=nil;
        if(data.length<4||memcmp(data.bytes,"PK\003\004",4)!=0){if(error)*error=JARError(7,@"JAR 下载未返回 ZIP/JAR 文件，可能是登录页或访问限制");return nil;}
        digest=JARHash(data,NO);jar=[root stringByAppendingPathComponent:[digest stringByAppendingString:@".jar"]];
    }
    NSString *md5=[reference[@"md5"] isKindOfClass:NSString.class]?reference[@"md5"]:@"";
    if(md5.length&&![JARHash(data,YES) isEqual:md5.lowercaseString]){if(error)*error=JARError(8,@"JAR 的 MD5 与订阅不符，请刷新订阅");return nil;}
    if(!cached){if(![data writeToFile:jar options:NSDataWritingAtomic error:error])return nil;
        [[NSJSONSerialization dataWithJSONObject:@{@"digest":digest,@"time":@(NSDate.date.timeIntervalSince1970)} options:0 error:NULL] writeToFile:recordPath atomically:YES];}
    if(ticket.cancelled)return nil;
    NSData *profileData=[NSJSONSerialization dataWithJSONObject:@{@"api":source[@"api"]?:@"",@"ext":MediaJARExtension(source),@"key":source[@"tvboxSiteKey"]?:source[@"id"]?:@"",@"origin":source[@"subscriptionURL"]?:@"",@"headers":headers} options:NSJSONWritingSortedKeys error:NULL];
    // Avoid keeping another full 64 MiB download alive while Zero prepares the plugin.
    data=nil;
    NSString *profile=JARHash(profileData,NO),*sessionKey=[profile stringByAppendingFormat:@"-%@",digest];
    NSString *cache=[root stringByAppendingPathComponent:sessionKey];[NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableDictionary *input=[@{@"request":ticket.requestID,@"session":sessionKey,@"runtime":digest,@"runtimeCache":[root stringByAppendingPathComponent:[@"Runtimes/" stringByAppendingString:digest]],@"jar":jar,@"cache":cache,@"profile":[root stringByAppendingPathComponent:[profile stringByAppendingString:@"/profile"]],@"conversionCache":[root stringByAppendingPathComponent:@"Converted"],@"api":source[@"api"],@"key":source[@"tvboxSiteKey"]?:@"",@"ext":MediaJARExtension(source),@"subscription":source[@"subscriptionURL"]?:@"",@"params":params,@"deadline":@([operation isEqual:@"play"]?90:([operation isEqual:@"search"]?60:150))} mutableCopy];
    ticket.executing=YES;
    if(ticket.cancelled){ticket.executing=NO;return nil;}
    NSDictionary *envelope=JARInvoke(input);ticket.executing=NO;
    if(envelope[@"error"]||envelope[@"errorCode"]){
        // Plugin errors may contain signed URLs or ext secrets. Export only a stable category.
        NSString *code=[envelope[@"errorCode"] isKindOfClass:NSString.class]?envelope[@"errorCode"]:@"plugin_failure";
        if(code.length>80||[code rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"].invertedSet].location!=NSNotFound)code=@"plugin_failure";
        if(error)*error=JARError(9,[NSString stringWithFormat:@"JAR 爬虫执行失败（%@）。首次准备可能较慢；需要 Android 界面或未适配依赖的站点仍不可用。",code]);return nil;
    }
    id raw=envelope[@"result"];
    if([raw isKindOfClass:NSString.class])raw=[NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if(![raw isKindOfClass:NSDictionary.class]){if(error)*error=JARError(10,@"JAR 爬虫未返回有效 JSON 对象");return nil;}
    return raw;
}
@end
