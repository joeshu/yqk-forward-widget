#import "TVBoxCatalogPackageExporter.h"
#import "TVBoxCatalogStore.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const TVBoxPackageTokenPlaceholder = @"__LYTVS_SUBSCRIPTION_TOKEN__";
static NSError *TVBoxPackageError(NSString *message) {return [NSError errorWithDomain:@"CCTVHostTVBoxExport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSString *TVBoxPackageMD5(NSData *data) {unsigned char digest[CC_MD5_DIGEST_LENGTH];CC_MD5(data.bytes,(CC_LONG)data.length,digest);NSMutableString *value=[NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];for(NSUInteger index=0;index<CC_MD5_DIGEST_LENGTH;index++)[value appendFormat:@"%02x",digest[index]];return value;}
static BOOL TVBoxPackageSameOrigin(NSURL *a,NSURL *b) {NSURLComponents *left=[NSURLComponents componentsWithURL:a resolvingAgainstBaseURL:NO],*right=[NSURLComponents componentsWithURL:b resolvingAgainstBaseURL:NO];BOOL samePort=(left.port==nil&&right.port==nil)||[left.port isEqual:right.port];return [left.scheme.lowercaseString isEqual:right.scheme.lowercaseString]&&[left.host.lowercaseString isEqual:right.host.lowercaseString]&&samePort;}
static NSString *TVBoxPackageSafeName(NSString *value) {
    NSString *name=[value isKindOfClass:NSString.class]?value:@"source";
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r"];
    NSMutableString *result=[NSMutableString string];
    [name enumerateSubstringsInRange:NSMakeRange(0,name.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange substringRange,NSRange enclosingRange,BOOL *stop){
        NSString *safe=([substring rangeOfCharacterFromSet:invalid].location==NSNotFound&&[substring rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound)?substring:@"_";
        [result appendString:safe];
        if(result.length>=48)*stop=YES;
    }];
    while([result containsString:@".."]) [result replaceOccurrencesOfString:@".." withString:@"_" options:0 range:NSMakeRange(0,result.length)];
    if([result hasPrefix:@"."])[result replaceCharactersInRange:NSMakeRange(0,1) withString:@"_"];
    return result.length?result:@"source";
}

@interface TVBoxCatalogPackageExporter () <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,copy) NSString *catalogID;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,copy) void (^completion)(NSURL *,NSUInteger,NSError *);
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSOperationQueue *delegateQueue;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *pending;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSMutableData *> *taskData;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSDictionary *> *taskEntries;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSNumber *> *redirectCounts;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSData *> *archiveFiles;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *manifestEntries;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *manifestFailures;
@property(nonatomic) NSUInteger totalBytes;
@property(nonatomic) NSUInteger totalCount;
@property(nonatomic) NSUInteger completedCount;
@property(nonatomic) NSUInteger failedCount;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@end

@implementation TVBoxCatalogPackageExporter
- (instancetype)initWithCatalogID:(NSString *)catalogID token:(NSString *)token {
    if((self=[super init])){_catalogID=[catalogID copy]?:@"";_token=[token copy]?:@"";_pending=[NSMutableArray array];_taskData=[NSMutableDictionary dictionary];_taskEntries=[NSMutableDictionary dictionary];_redirectCounts=[NSMutableDictionary dictionary];_archiveFiles=[NSMutableDictionary dictionary];_manifestEntries=[NSMutableArray array];_manifestFailures=[NSMutableArray array];}
    return self;
}
- (NSString *)resolvedURL:(NSString *)raw {
    if(![raw isKindOfClass:NSString.class])return @"";if(![raw containsString:TVBoxPackageTokenPlaceholder])return raw;if(!self.token.length)return @"";return [raw stringByReplacingOccurrencesOfString:TVBoxPackageTokenPlaceholder withString:self.token];
}
- (NSString *)fileExtensionForURL:(NSString *)value {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value];NSString *path=parts.path.lowercaseString?:@"";if([path hasSuffix:@".md5"])path=[path stringByDeletingPathExtension];NSString *extension=path.pathExtension.lowercaseString;return [@[@"py",@"js",@"mjs",@"cjs"] containsObject:extension]?extension:nil;
}
- (void)startWithCompletion:(void (^)(NSURL *,NSUInteger,NSError *))completion {
    if(self.finished)return;self.completion=[completion copy];NSDictionary *catalog=[TVBoxCatalogStore catalogForID:self.catalogID];if(!catalog){[self finish:nil error:TVBoxPackageError(@"找不到此资源合集")];return;}
    NSError *jsonError=nil;NSData *config=[TVBoxCatalogStore exportDataForCatalogID:self.catalogID error:&jsonError];if(!config){[self finish:nil error:jsonError?:TVBoxPackageError(@"无法读取资源合集 JSON")];return;}self.archiveFiles[@"config.json"]=config;
    NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSMutableSet *usedPaths=[NSMutableSet set];NSUInteger index=0;
    for(NSDictionary *site in sites){index++;NSString *raw=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";NSString *extension=[self fileExtensionForURL:raw];if(!extension)continue;NSString *resolved=[self resolvedURL:raw];NSString *name=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"source";NSString *key=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:[NSString stringWithFormat:@"%lu",(unsigned long)index];NSString *path=[NSString stringWithFormat:@"scripts/%03lu-%@-%@.%@",(unsigned long)index,TVBoxPackageSafeName(key),TVBoxPackageSafeName(name),extension];NSUInteger suffix=1;NSString *candidate=path;while([usedPaths containsObject:candidate]){candidate=[path stringByDeletingPathExtension];candidate=[candidate stringByAppendingFormat:@"-%lu.%@",(unsigned long)suffix++,extension];}path=candidate;[usedPaths addObject:path];
        NSMutableDictionary *record=[@{@"name":name,@"key":key,@"url":raw,@"file":path} mutableCopy];if(!resolved.length){record[@"status"]=@"需要本机令牌";self.failedCount++;[self.manifestFailures addObject:@{@"name":name,@"url":raw,@"reason":@"需要本机令牌"}];[self.manifestEntries addObject:record];continue;}
        NSURLComponents *parts=[NSURLComponents componentsWithString:resolved];if(!parts.URL||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length){record[@"status"]=@"地址无效";self.failedCount++;[self.manifestFailures addObject:@{@"name":name,@"url":raw,@"reason":@"地址无效"}];[self.manifestEntries addObject:record];continue;}
        BOOL checksum=[parts.path.lowercaseString hasSuffix:@".md5"];NSURLComponents *scriptParts=[parts copy];if(checksum)scriptParts.path=[scriptParts.path stringByDeletingPathExtension];NSDictionary *headers=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{};[self.pending addObject:@{@"url":parts.URL.absoluteString,@"scriptURL":scriptParts.URL.absoluteString?:parts.URL.absoluteString,@"checksumRequest":@(checksum),@"path":path,@"name":name,@"rawURL":raw,@"headers":headers,@"recordIndex":@(self.manifestEntries.count)}];[self.manifestEntries addObject:record];
    }
    self.totalCount=self.manifestEntries.count;if(self.progressHandler)dispatch_async(dispatch_get_main_queue(),^{self.progressHandler(0,self.totalCount,@"准备下载");});
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=30;self.delegateQueue=[NSOperationQueue new];self.delegateQueue.maxConcurrentOperationCount=1;self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:self.delegateQueue];__weak typeof(self) weakSelf=self;[self.delegateQueue addOperationWithBlock:^{[weakSelf pump];}];
}
- (void)pump {
    if(self.finished||self.cancelled)return;
    while(self.taskEntries.count<8&&self.pending.count){NSDictionary *entry=self.pending.firstObject;[self.pending removeObjectAtIndex:0];NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:entry[@"url"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];request.HTTPMethod=@"GET";[request setValue:@"CCTVHost Resource Export" forHTTPHeaderField:@"User-Agent"];
        NSDictionary *headers=entry[@"headers"];NSUInteger added=0;for(id key in headers){id value=headers[key];if(![key isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class]||added>=24||[(NSString *)key length]>128||[(NSString *)value length]>4096||[key caseInsensitiveCompare:@"Host"]==NSOrderedSame)continue;[request setValue:value forHTTPHeaderField:key];added++;}
        NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request];NSNumber *identifier=@(task.taskIdentifier);self.taskEntries[identifier]=entry;self.taskData[identifier]=[NSMutableData data];self.redirectCounts[identifier]=@0;[task resume];
    }
    if(!self.pending.count&&!self.taskEntries.count)[self finishArchive];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSNumber *identifier=@(task.taskIdentifier);BOOL isHTTP=[response isKindOfClass:NSHTTPURLResponse.class];NSInteger status=isHTTP?((NSHTTPURLResponse *)response).statusCode:0;BOOL valid=self.taskEntries[identifier]&&isHTTP&&status>=200&&status<300&&response.expectedContentLength<=8*1024*1024;completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);if(!valid&&self.taskEntries[identifier]){NSMutableDictionary *record=[self recordForTask:identifier];record[@"status"]=@"HTTP 状态异常或文件超过 8 MiB";record[@"errorCode"]=@(status);}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSNumber *identifier=@(task.taskIdentifier);NSMutableData *buffer=self.taskData[identifier];if(!buffer)return;if(buffer.length+data.length>8*1024*1024||self.totalBytes+data.length>128*1024*1024){NSMutableDictionary *record=[self recordForTask:identifier];record[@"status"]=@"超过文件包大小上限";[task cancel];return;}[buffer appendData:data];self.totalBytes+=data.length;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    NSNumber *identifier=@(task.taskIdentifier);NSUInteger count=[self.redirectCounts[identifier] unsignedIntegerValue]+1;self.redirectCounts[identifier]=@(count);NSURLComponents *from=[NSURLComponents componentsWithURL:response.URL resolvingAgainstBaseURL:NO],*to=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];BOOL valid=self.taskEntries[identifier]&&count<=5&&to.host.length&&!to.user.length&&!to.password.length&&[@[@"http",@"https"] containsObject:to.scheme.lowercaseString]&&!([from.scheme.lowercaseString isEqual:@"https"]&&[to.scheme.lowercaseString isEqual:@"http"]);
    NSMutableURLRequest *safe=[request mutableCopy];BOOL sameOrigin=TVBoxPackageSameOrigin(response.URL,request.URL);if(!sameOrigin)for(NSString *name in @[@"Authorization",@"Cookie",@"Proxy-Authorization"])[safe setValue:nil forHTTPHeaderField:name];completion(valid?safe:nil);
}
- (NSMutableDictionary *)recordForTask:(NSNumber *)identifier {
    NSDictionary *entry=self.taskEntries[identifier];NSUInteger index=[entry[@"recordIndex"] unsignedIntegerValue];if(index>=self.manifestEntries.count)return [NSMutableDictionary dictionary];NSMutableDictionary *record=[self.manifestEntries[index] mutableCopy];self.manifestEntries[index]=record;return record;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *identifier=@(task.taskIdentifier);NSDictionary *entry=self.taskEntries[identifier];if(!entry)return;NSMutableData *buffer=self.taskData[identifier];NSMutableDictionary *record=[self recordForTask:identifier];NSHTTPURLResponse *response=[task.response isKindOfClass:NSHTTPURLResponse.class]?(id)task.response:nil;
    BOOL succeeded=!error&&response.statusCode>=200&&response.statusCode<300&&buffer.length>0;
    if(succeeded&&[entry[@"checksumRequest"] boolValue]){
        NSString *text=[[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];NSString *hash=[[[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] firstObject] lowercaseString];NSRegularExpression *validHash=[NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]{32}$" options:0 error:NULL];BOOL valid=hash.length==32&&[validHash numberOfMatchesInString:hash options:0 range:NSMakeRange(0,hash.length)]==1;
        if(valid){NSMutableDictionary *next=[entry mutableCopy];NSURL *effective=task.response.URL;NSURLComponents *effectiveParts=[NSURLComponents componentsWithURL:effective resolvingAgainstBaseURL:NO];if([effectiveParts.path.lowercaseString hasSuffix:@".md5"])effectiveParts.path=[effectiveParts.path stringByDeletingPathExtension];next[@"url"]=effectiveParts.URL.absoluteString?:entry[@"scriptURL"];if(!TVBoxPackageSameOrigin([NSURL URLWithString:entry[@"url"]],effective)){NSMutableDictionary *safeHeaders=[entry[@"headers"] mutableCopy]?:[NSMutableDictionary dictionary];for(id key in [safeHeaders.allKeys copy])if([key isKindOfClass:NSString.class]&&([key caseInsensitiveCompare:@"Authorization"]==NSOrderedSame||[key caseInsensitiveCompare:@"Cookie"]==NSOrderedSame||[key caseInsensitiveCompare:@"Proxy-Authorization"]==NSOrderedSame))[safeHeaders removeObjectForKey:key];next[@"headers"]=safeHeaders;}next[@"checksumRequest"]=@NO;next[@"expectedMD5"]=hash;record[@"md5"]=hash;record[@"status"]=@"已读取 MD5 校验值";[self.pending insertObject:next atIndex:0];[self.taskEntries removeObjectForKey:identifier];[self.taskData removeObjectForKey:identifier];[self.redirectCounts removeObjectForKey:identifier];[self pump];return;}
        succeeded=NO;record[@"status"]=@"MD5 校验文件格式无效";
    }
    if(succeeded&&[entry[@"expectedMD5"] isKindOfClass:NSString.class]&&![entry[@"expectedMD5"] isEqual:TVBoxPackageMD5(buffer)]){succeeded=NO;record[@"status"]=@"脚本 MD5 校验失败";}
    if(succeeded){self.archiveFiles[entry[@"path"]]=buffer.copy;record[@"status"]=[entry[@"expectedMD5"] isKindOfClass:NSString.class]?@"已收集 · MD5 校验通过":@"已收集 · 未提供 MD5";record[@"bytes"]=@(buffer.length);}
    else {self.failedCount++;NSString *reason=record[@"status"]?: (error?[NSString stringWithFormat:@"%@ (%ld)",error.domain,(long)error.code]:[NSString stringWithFormat:@"HTTP %ld",(long)response.statusCode]);record[@"status"]=reason;NSMutableDictionary *failure=[@{@"name":entry[@"name"]?:@"资源",@"url":entry[@"rawURL"]?:@"",@"reason":reason} mutableCopy];[self.manifestFailures addObject:failure];}
    self.completedCount++;[self.taskEntries removeObjectForKey:identifier];[self.taskData removeObjectForKey:identifier];[self.redirectCounts removeObjectForKey:identifier];if(self.progressHandler)dispatch_async(dispatch_get_main_queue(),^{self.progressHandler(self.completedCount,self.totalCount,entry[@"name"]?:@"资源");});[self pump];
}
- (void)finishArchive {
    if(self.finished||self.cancelled)return;NSError *error=nil;NSData *manifest=[NSJSONSerialization dataWithJSONObject:@{@"format":@"CCTVHostTVBoxPackage",@"version":@1,@"files":self.manifestEntries,@"failures":self.manifestFailures} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];if(manifest)self.archiveFiles[@"source-manifest.json"]=manifest;NSString *readme=[NSString stringWithFormat:@"TVBox 资源合集完整导出\n\nconfig.json 是完整原始配置；scripts/ 内为按原站点 URL 获取的 PY/JS 文件；source-manifest.json 记录每个文件及未能下载的项目。\n\n文件：%lu 个 · 未能获取：%lu 个\n",(unsigned long)self.manifestEntries.count,(unsigned long)self.failedCount];self.archiveFiles[@"README.txt"]=[readme dataUsingEncoding:NSUTF8StringEncoding];NSURL *url=manifest?[TVBoxCatalogStore writeZIPArchiveForCatalogID:self.catalogID files:self.archiveFiles error:&error]:nil;if(!url&&!error)error=TVBoxPackageError(@"生成 ZIP 文件失败");[self finish:url error:error];
}
- (void)finish:(NSURL *)url error:(NSError *)error {
    if(self.finished)return;self.finished=YES;[self.session invalidateAndCancel];self.session=nil;void(^completion)(NSURL *,NSUInteger,NSError *)=self.completion;self.completion=nil;if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(url,self.failedCount,error);});
}
- (void)cancel {
    if(self.finished)return;__weak typeof(self) weakSelf=self;[self.delegateQueue addOperationWithBlock:^{TVBoxCatalogPackageExporter *owner=weakSelf;if(!owner||owner.finished)return;owner.cancelled=YES;[owner.session invalidateAndCancel];owner.session=nil;owner.finished=YES;void(^completion)(NSURL *,NSUInteger,NSError *)=owner.completion;owner.completion=nil;if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,owner.failedCount,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);});}];
}
@end
