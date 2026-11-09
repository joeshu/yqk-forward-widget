#import "JSPluginRuntime.h"
#import "HostSyncRequest.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <Security/Security.h>
#include <math.h>

static NSUInteger const JSMaxBody = 1024 * 1024;
static NSUInteger const JSMaxGenericResponse = 4 * 1024 * 1024;
@interface JSPluginRuntime () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) JSContext *context;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *requests;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, JSValue *> *timers;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSString *)> *calls;
@property(nonatomic) BOOL unresponsive;
@property(nonatomic, strong) NSURL *scriptURL;
@property(nonatomic, strong) NSURLSessionConfiguration *networkConfiguration;
@property(atomic, copy) NSString *activeSession;
@property(nonatomic, copy) NSString *packageRoot;
@property(nonatomic) BOOL genericMode;
@property(atomic) BOOL stopRequested;
@property(nonatomic, strong) NSMutableSet<HostSyncRequest *> *syncRequests;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL router;
@property(nonatomic, strong) NSMutableDictionary<NSString *, JSPluginRuntime *> *sessionRuntimes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSString *)> *sessionLogHandlers;
@property(nonatomic, copy) NSString *serviceIdentifier;
@property(nonatomic, copy) NSString *hostFetchURL;
@property(nonatomic, copy) NSString *hostFetchToken;
@property(nonatomic, copy) NSString *activeModuleType;
@property(nonatomic, copy) NSString *activeProtocol;
@property(nonatomic, strong) id activeOptions;
@end
@implementation JSPluginRuntime
+ (instancetype)shared { static JSPluginRuntime *r; static dispatch_once_t once; dispatch_once(&once, ^{ r=[self routerWithScriptURL:nil configuration:nil]; }); return r; }
+ (instancetype)routerWithScriptURL:(NSURL *)url configuration:(NSURLSessionConfiguration *)configuration { JSPluginRuntime *r=[[self alloc] initWithScriptURL:url configuration:configuration];r.router=YES;r.sessionRuntimes=[NSMutableDictionary dictionary];r.sessionLogHandlers=[NSMutableDictionary dictionary];return r; }
- (instancetype)init { return [self initWithScriptURL:nil configuration:nil]; }
- (instancetype)initWithScriptURL:(NSURL *)url configuration:(NSURLSessionConfiguration *)configuration { if((self=[super init])) { _scriptURL=url;_networkConfiguration=configuration; _queue=dispatch_queue_create("cctvhost.javascript", DISPATCH_QUEUE_SERIAL);_requests=[NSMutableDictionary dictionary];_syncRequests=[NSMutableSet set];_timers=[NSMutableDictionary dictionary];_calls=[NSMutableDictionary dictionary];_sessionLogHandlers=[NSMutableDictionary dictionary]; } return self; }
- (NSArray<NSString *> *)activeSessionIdentifiers { if(!self.router)return self.activeSession.length?@[(self.serviceIdentifier.length?self.serviceIdentifier:self.activeSession)]:@[];@synchronized(self){NSMutableOrderedSet *ids=[NSMutableOrderedSet orderedSet];for(JSPluginRuntime *runtime in self.sessionRuntimes.allValues)if(runtime.activeSession.length)[ids addObject:runtime.serviceIdentifier.length?runtime.serviceIdentifier:runtime.activeSession];return ids.array.copy?:@[];} }
- (NSArray<NSString *> *)managedServiceIdentifiers {if(!self.router)return self.serviceIdentifier.length?@[self.serviceIdentifier]:@[];@synchronized(self){NSMutableOrderedSet *ids=[NSMutableOrderedSet orderedSet];for(JSPluginRuntime *runtime in self.sessionRuntimes.allValues)if(runtime.serviceIdentifier.length)[ids addObject:runtime.serviceIdentifier];return ids.array.copy?:@[];}}
- (void)setLogHandler:(void (^)(NSString *))handler forServiceIdentifier:(NSString *)identifier {@synchronized(self){if(identifier.length&&handler)self.sessionLogHandlers[identifier]=[handler copy];else if(identifier.length)[self.sessionLogHandlers removeObjectForKey:identifier];}}
- (BOOL)stopSessionsForServiceIdentifier:(NSString *)identifier error:(NSError **)error {
    if(NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:5 userInfo:@{NSLocalizedDescriptionKey:@"JavaScriptCore 服务停止需要在后台线程执行。"}];return NO;}
    if(!self.router){if(!self.activeSession.length||![self.serviceIdentifier isEqual:identifier])return YES;NSDictionary *payload=@{@"session":self.activeSession,@"serviceID":identifier?:@""};NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];NSString *reply=[self callOperation:@"stop" json:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] timeout:10 error:error];id value=reply?[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;return [value isKindOfClass:NSDictionary.class]&&[value[@"ok"] boolValue];}
    NSArray<NSString *> *sessions=nil;@synchronized(self){NSMutableArray *values=[NSMutableArray array];for(NSString *session in self.sessionRuntimes)if([self.sessionRuntimes[session].serviceIdentifier isEqual:identifier])[values addObject:session];sessions=values.copy;}
    for(NSString *session in sessions){NSDictionary *payload=@{@"session":session,@"serviceID":identifier?:@""};NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];NSString *reply=[self callOperation:@"stop" json:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] timeout:10 error:error];id value=reply?[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;if(![value isKindOfClass:NSDictionary.class]||![value[@"ok"] boolValue])return NO;}
    return YES;
}
- (void)log:(NSString *)text { @autoreleasepool { if(text.length>4096)text=[text substringToIndex:4096];if(self.logHandler)self.logHandler(text); } }
- (BOOL)allowedURL:(NSURL *)url {
    if(self.genericMode)return [@[@"http",@"https"] containsObject:url.scheme.lowercaseString] && url.host.length && !url.user.length && !url.password.length;
    if(![url.scheme.lowercaseString isEqualToString:@"https"] || url.user.length || url.password.length)return NO;
    NSString *host=url.host.lowercaseString;
    for(NSString *root in @[@"cctv.cn",@"cctv.com",@"yangshipin.cn"])
        if([host isEqualToString:root] || [host hasSuffix:[@"." stringByAppendingString:root]])return YES;
    return NO;
}
- (void)fetchFinished:(NSNumber *)key error:(NSString *)error {
    NSMutableDictionary *record=self.requests[key];if(!record)return;
    [self.requests removeObjectForKey:key];
    JSValue *callback=record[@"callback"];
    if(error){[callback callWithArguments:@[@{@"error":error}]];return;}
    NSHTTPURLResponse *response=record[@"response"];NSData *data=record[@"data"];
    NSDictionary *respHeaders=response.allHeaderFields?:@{};
    NSString *finalURL=[respHeaders[@"X-CCTVHost-Final-URL"] isKindOfClass:NSString.class]?respHeaders[@"X-CCTVHost-Final-URL"]:([respHeaders[@"x-cctvhost-final-url"] isKindOfClass:NSString.class]?respHeaders[@"x-cctvhost-final-url"]:(response.URL.absoluteString?:(record[@"originalURL"]?:@"")));
    [callback callWithArguments:@[@{@"status":@(response.statusCode),@"url":finalURL,@"headers":respHeaders,@"base64":[data base64EncodedStringWithOptions:0]?:@""}]];
}
- (NSNumber *)fetch:(NSString *)url options:(NSString *)options callback:(JSValue *)callback {
    NSNumber *key=@(++self.sequence);
    if(url.length>8192 || options.length>2*1024*1024){[callback callWithArguments:@[@{@"error":@"JS 请求参数超过限制"}]];return key;}
    NSURL *target=[NSURL URLWithString:url];
    if(![self allowedURL:target] || self.requests.count>=24){[callback callWithArguments:@[@{@"error":@"JS 网络地址不受支持或并发已满"}]];return key;}
    NSData *bytes=[options dataUsingEncoding:NSUTF8StringEncoding];NSDictionary *opts=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
    if(![opts isKindOfClass:NSDictionary.class])opts=@{};
    NSString *method=[opts[@"method"] isKindOfClass:NSString.class]?[opts[@"method"] uppercaseString]:@"GET";
    if((!self.genericMode && ![method isEqual:@"GET"]) || ![@[@"GET",@"POST",@"PUT",@"PATCH",@"DELETE",@"HEAD",@"OPTIONS"] containsObject:method]){[callback callWithArguments:@[@{@"error":@"不支持的 HTTP 方法"}]];return key;}
    NSTimeInterval timeout=12;id rawTimeout=opts[@"timeout"];
    if([rawTimeout isKindOfClass:NSNumber.class]){double configured=[rawTimeout doubleValue];if(configured>120)configured/=1000.0;if(isfinite(configured)&&configured>0)timeout=MIN(120.0,MAX(1.0,configured));}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    request.HTTPMethod=method;
    if(self.genericMode){
        if([opts[@"body"] isKindOfClass:NSString.class])request.HTTPBody=[opts[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
        else if([opts[@"bodyBase64"] isKindOfClass:NSString.class])request.HTTPBody=[[NSData alloc] initWithBase64EncodedString:opts[@"bodyBase64"] options:0];
        if(request.HTTPBody.length>JSMaxBody){[callback callWithArguments:@[@{@"error":@"JS 请求内容超过 1 MB"}]];return key;}
    }
    NSDictionary *headers=opts[@"headers"];
    if([headers isKindOfClass:NSDictionary.class] && headers.count<=64)for(NSString *name in headers){
        if([name isKindOfClass:NSString.class] && [headers[name] isKindOfClass:NSString.class] &&
           name.length && name.length<=128 && [headers[name] length]<=16384 &&
           [name rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location==NSNotFound &&
           [headers[name] rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound &&
           (self.genericMode?![@[@"host",@"content-length",@"connection",@"transfer-encoding"] containsObject:name.lowercaseString]:[@[@"accept",@"user-agent",@"referer",@"content-type"] containsObject:name.lowercaseString]))
            [request setValue:headers[name] forHTTPHeaderField:name];
    }
    if(!callback)return key;
    if(!self.session){[callback callWithArguments:@[@{@"error":@"JS 服务已停止"}]];return key;}
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request];
    if(!task){[callback callWithArguments:@[@{@"error":@"JS 服务已停止"}]];return key;}
    self.requests[key]=[@{@"callback":callback,@"task":task,@"data":[NSMutableData data],@"originalURL":url?:@"",@"method":method?:@"GET",@"headers":request.allHTTPHeaderFields?:@{},@"bodyData":request.HTTPBody?:[NSData data],@"timeout":@(timeout)} mutableCopy];
    [task resume];return key;
}
- (NSNumber *)keyForTask:(NSURLSessionTask *)task { for(NSNumber *key in self.requests)if(self.requests[key][@"task"]==task)return key;return nil; }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSNumber *key=[self keyForTask:task];
    NSUInteger limit=self.genericMode?JSMaxGenericResponse:JSMaxBody;
    if(!key || response.expectedContentLength>(long long)limit || ![response isKindOfClass:NSHTTPURLResponse.class]){
        completion(NSURLSessionResponseCancel);if(key)[self fetchFinished:key error:@"JS 上游响应过大或无效"];return;
    }
    self.requests[key][@"response"]=response;completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSNumber *key=[self keyForTask:task];if(!key)return;
    NSMutableData *body=self.requests[key][@"data"];
    NSUInteger limit=self.genericMode?JSMaxGenericResponse:JSMaxBody;
    if(body.length+data.length>limit){[task cancel];[self fetchFinished:key error:self.genericMode?@"JS 上游响应超过 4MB":@"JS 上游响应超过 1MB"];return;}[body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key=[self keyForTask:task];if(!key)return;
    NSMutableDictionary *record=self.requests[key];
    NSString *origURL=[record[@"originalURL"] isKindOfClass:NSString.class]?record[@"originalURL"]:@"";
    if(error && self.genericMode && self.session && self.hostFetchURL.length && self.hostFetchToken.length && ![record[@"retriedHostFetch"] boolValue] && ![record[@"aborted"] boolValue] && [origURL.lowercaseString hasPrefix:@"https://"]){
        NSURL *bridgeURL=[NSURL URLWithString:self.hostFetchURL];
        if(bridgeURL){
            record[@"retriedHostFetch"]=@YES;
            record[@"data"]=[NSMutableData data];
            [record removeObjectForKey:@"response"];
            NSTimeInterval timeout=[record[@"timeout"] doubleValue]>0?[record[@"timeout"] doubleValue]:15.0;
            NSData *bodyData=[record[@"bodyData"] isKindOfClass:NSData.class]?record[@"bodyData"]:nil;
            NSDictionary *bridgePayload=@{
                @"url":origURL,
                @"method":record[@"method"]?:@"GET",
                @"headers":record[@"headers"]?:@{},
                @"bodyBase64":bodyData.length?[bodyData base64EncodedStringWithOptions:0]:@"",
                @"timeoutMs":@((NSInteger)(timeout*1000)),
                @"followRedirects":@YES
            };
            NSMutableURLRequest *bridgeReq=[NSMutableURLRequest requestWithURL:bridgeURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout+2.0];
            bridgeReq.HTTPMethod=@"POST";
            [bridgeReq setValue:self.hostFetchToken forHTTPHeaderField:@"X-CCTVHost-Host-Fetch"];
            [bridgeReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            bridgeReq.HTTPBody=[NSJSONSerialization dataWithJSONObject:bridgePayload options:0 error:NULL];
            NSURLSessionDataTask *retryTask=[self.session dataTaskWithRequest:bridgeReq];
            if(retryTask){
                record[@"task"]=retryTask;
                [retryTask resume];
                return;
            }
        }
    }
    [self fetchFinished:key error:error.localizedDescription];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if(self.genericMode && [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] && challenge.protectionSpace.serverTrust){
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL allowed=[self allowedURL:request.URL] && task.countOfBytesReceived<JSMaxBody;
    NSMutableURLRequest *redirect=[request mutableCopy];
    if(![request.URL.host.lowercaseString isEqual:response.URL.host.lowercaseString] || ![request.URL.scheme.lowercaseString isEqual:response.URL.scheme.lowercaseString] || ![(request.URL.port?:@0) isEqual:(response.URL.port?:@0)]){[redirect setValue:nil forHTTPHeaderField:@"Authorization"];[redirect setValue:nil forHTTPHeaderField:@"Cookie"];}
    completion(allowed?redirect:nil);
}
- (NSString *)initializeContext {
    self.generation++;
    self.context=[JSContext new];__weak typeof(self) weak=self;
    self.context.exceptionHandler=^(JSContext *context, JSValue *exception){[weak log:[NSString stringWithFormat:@"JS 异常：%@",exception.toString]];};
    self.context[@"__hostRandomBytes"]=^NSArray *(NSUInteger n){
        if(n>65536){[JSContext currentContext].exception=[JSValue valueWithNewErrorFromMessage:@"randomBytes 超出上限" inContext:JSContext.currentContext];return @[];}
        NSMutableData *data=[NSMutableData dataWithLength:n];
        if(SecRandomCopyBytes(kSecRandomDefault,n,data.mutableBytes)!=errSecSuccess){[JSContext currentContext].exception=[JSValue valueWithNewErrorFromMessage:@"随机数生成失败" inContext:JSContext.currentContext];return @[];}
        NSMutableArray *result=[NSMutableArray arrayWithCapacity:n];const unsigned char *p=data.bytes;for(NSUInteger i=0;i<n;i++)[result addObject:@(p[i])];return result;
    };
    self.context[@"__hostUUID"]=^NSString *{return NSUUID.UUID.UUIDString;};
    self.context[@"__hostListPackageFiles"]=^NSArray *{
        JSPluginRuntime *s=weak;NSMutableArray *files=[NSMutableArray array];NSUInteger total=0;
        for(NSString *name in [NSFileManager.defaultManager enumeratorAtPath:s.packageRoot]){
            NSString *path=[s packageFile:name];if(!path)continue;
            total+=[[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL] fileSize];
            if(files.count>=2048 || total>64*1024*1024){JSContext.currentContext.exception=[JSValue valueWithNewErrorFromMessage:@"JS 资源包超出文件数量或大小限制" inContext:JSContext.currentContext];return @[];}
            [files addObject:name];
        }return files;
    };
    self.context[@"__hostReadPackageFile"]=^NSString *(NSString *name){
        NSString *path=[weak packageFile:name];NSString *text=path?[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]:nil;
        if(!text){JSContext.currentContext.exception=[JSValue valueWithNewErrorFromMessage:@"JS 包文件不存在、越界或不是 UTF-8 文本" inContext:JSContext.currentContext];return @"";}
        NSDictionary *weboxBuiltinMap=@{@"user.4kvm":@"webox-4kvm",@"moe.hstream.webox":@"webox-hstream",@"dev.webox.native.guazi":@"webox-guazi",@"video.rou.webox":@"webox-rou"};
        for(NSString *marker in weboxBuiltinMap){
            if([text containsString:marker]){
                NSString *bPath=[NSBundle.mainBundle pathForResource:weboxBuiltinMap[marker] ofType:@"js" inDirectory:@"BuiltinMedia"];
                NSString *bText=bPath?[NSString stringWithContentsOfFile:bPath encoding:NSUTF8StringEncoding error:NULL]:nil;
                if(bText.length){text=bText;break;}
            }
        }
        if([text containsString:@"joeshu.yqk"]){
            if([text containsString:@"function parseLink(link) {"] && ![text containsString:@"__cctv_yqk_norm"]){
                NSString *norm=[text containsString:@"yqk:"]
                    ? @"function parseLink(link) { var __cctv_yqk_norm = 1; if (link && typeof link === 'object') link = link.link || link.id || link.vod_id || ''; link = String(link || '').trim(); var __m = link.match(new RegExp('(?:^|/play/|yqk://vod/)([0-9]+)(?:[?]([^#]*))?$', 'i')); if (__m) link = 'yqk://vod/' + __m[1] + (__m[2] ? ('?' + __m[2]) : '');"
                    : @"function parseLink(link) { var __cctv_yqk_norm = 1; if (link && typeof link === 'object') link = link.link || link.id || link.vod_id || ''; link = String(link || '').trim(); var __yqkSite = (typeof YQK === 'object' && YQK && YQK.site) ? YQK.site : 'https://m.yqk3hxe.com'; var __m = link.match(new RegExp('(?:^|/play/|yqk://vod/)([0-9]+)(?:[?]([^#]*))?$', 'i')); if (__m) link = __yqkSite + '/play/' + __m[1] + (__m[2] ? ('?' + __m[2]) : '');";
                text=[text stringByReplacingOccurrencesOfString:@"function parseLink(link) {" withString:norm];
            }
            // __cctv_yqk_fast_probe is injected by JSPlugins/generic/entry.mjs; keep runtime patches limited to timeout caps.
            text=[text stringByReplacingOccurrencesOfString:@"timeout:yqkRequestTimeout(budget,15000)" withString:@"timeout:yqkRequestTimeout(budget,4500)"];
            text=[text stringByReplacingOccurrencesOfString:@"timeout:yqkRequestTimeout(budget,12000)" withString:@"timeout:yqkRequestTimeout(budget,4500)"];
            text=[text stringByReplacingOccurrencesOfString:@"timeout:yqkRequestTimeout(budget,5500)" withString:@"timeout:yqkRequestTimeout(budget,4500)"];
            text=[text stringByReplacingOccurrencesOfString:@"Math.min(20000," withString:@"Math.min(4500,"];
            text=[text stringByReplacingOccurrencesOfString:@"Math.min(5500," withString:@"Math.min(4500,"];
        }
        JSPluginRuntime *s=weak;
        if(s && s.genericMode && s.context && !s.context[@"__cctvTransformSource"].isUndefined){
            JSValue *transformed=[s.context[@"__cctvTransformSource"] callWithArguments:@[text, s.activeModuleType?:@"", s.activeProtocol?:@"", name?:@""]];
            if(transformed.isString && !s.context.exception)text=transformed.toString;
            s.context.exception=nil;
        }
        return text;
    };
    self.context[@"__hostFetchSync"]=^NSDictionary *(NSString *url,NSString *raw){
        JSPluginRuntime *s=weak;if(!s.genericMode || s.stopRequested || url.length>8192 || raw.length>2*1024*1024)return @{@"error":@"JS 同步请求不可用或参数过大"};
        NSURL *target=[NSURL URLWithString:url];if(![s allowedURL:target])return @{@"error":@"不支持的 JS 请求地址"};
        id options=[NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];if(![options isKindOfClass:NSDictionary.class])options=@{};
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target];request.timeoutInterval=10;
        NSString *method=[options[@"method"] isKindOfClass:NSString.class]?[options[@"method"] uppercaseString]:@"GET";
        if(![@[@"GET",@"POST",@"PUT",@"PATCH",@"DELETE",@"HEAD",@"OPTIONS"] containsObject:method])return @{@"error":@"不支持的 HTTP 方法"};request.HTTPMethod=method;
        if([options[@"body"] isKindOfClass:NSString.class])request.HTTPBody=[options[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
        if(request.HTTPBody.length>1024*1024)return @{@"error":@"请求内容超过 1 MB"};
        NSDictionary *headers=[options[@"headers"] isKindOfClass:NSDictionary.class]?options[@"headers"]:@{};
        if(headers.count>64)return @{@"error":@"请求头过多"};
        for(NSString *key in headers)if([headers[key] isKindOfClass:NSString.class] && key.length && key.length<128 && [headers[key] length]<=16384 && ![@[@"host",@"content-length",@"connection",@"transfer-encoding"] containsObject:key.lowercaseString] && [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location==NSNotFound && [headers[key] rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)[request setValue:headers[key] forHTTPHeaderField:key];
        HostSyncRequest *operation=[[HostSyncRequest alloc] initWithConfiguration:s.networkConfiguration];@synchronized(s.syncRequests){[s.syncRequests addObject:operation];if(s.stopRequested)[operation cancel];}
        NSDictionary *reply=[operation performRequest:request];@synchronized(s.syncRequests){[s.syncRequests removeObject:operation];}return reply;
    };
    self.context[@"__hostStorage"]=^NSString *(NSString *action,NSString *key,NSString *value){
        JSPluginRuntime *s=weak;if(!s.packageRoot.length || key.length>1024 || value.length>65536)return nil;
        NSArray *parts=s.packageRoot.pathComponents;NSUInteger index=[parts indexOfObject:@"Services"];
        NSString *identifier=index!=NSNotFound && index+1<parts.count?parts[index+1]:s.packageRoot.lastPathComponent;
        NSString *name=[@"CCTVJSStorage:" stringByAppendingString:identifier];NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *store=[[defaults dictionaryForKey:name]?:@{} mutableCopy];
        if([action isEqual:@"get"])return store[key];
        if([action isEqual:@"remove"])[store removeObjectForKey:key];else if([action isEqual:@"set"] && value)store[key]=value;else return nil;
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:store options:0 error:NULL];
        if(store.count>256 || bytes.length>1024*1024){JSContext.currentContext.exception=[JSValue valueWithNewErrorFromMessage:@"插件存储超过限制" inContext:JSContext.currentContext];return nil;}
        [defaults setObject:store forKey:name];return value;
    };
    self.context[@"__hostLog"]=^(NSString *line){[weak log:line];};
    self.context[@"__hostFetch"]=^NSNumber *(NSString *url,NSString *options,JSValue *callback){return [weak fetch:url options:options callback:callback];};
    self.context[@"__hostAbortFetch"]=^(NSNumber *key){JSPluginRuntime *s=weak;s.requests[key][@"aborted"]=@YES;[s.requests[key][@"task"] cancel];[s fetchFinished:key error:@"AbortError"];};
    self.context[@"__hostSetTimeout"]=^NSNumber *(JSValue *callback,double ms){
        JSPluginRuntime *s=weak;if(!s || s.timers.count>=128)return @0;
        NSNumber *key=@(++s.sequence);NSUInteger generation=s.generation;s.timers[key]=callback;
        double delay=isfinite(ms)?MAX(0,MIN(ms,2147483647)):0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_MSEC)),s.queue,^{
            @autoreleasepool {JSPluginRuntime *r=weak;if(r.generation!=generation)return;JSValue *fn=r.timers[key];[r.timers removeObjectForKey:key];if(fn)[fn callWithArguments:@[]];}
        });return key;
    };
    self.context[@"__hostClearTimeout"]=^(NSNumber *key){[weak.timers removeObjectForKey:key];};
    NSURLSessionConfiguration *config=self.networkConfiguration.copy?:NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPMaximumConnectionsPerHost=4;config.timeoutIntervalForRequest=12;config.timeoutIntervalForResource=self.genericMode?120:15;
    NSOperationQueue *delegate=[NSOperationQueue new];delegate.maxConcurrentOperationCount=1;delegate.underlyingQueue=self.queue;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegate];
    NSString *path=self.scriptURL.path?:[NSBundle.mainBundle pathForResource:self.genericMode?@"js-runtime.bundle":@"yangshipin.bundle" ofType:@"js"];
    NSString *source=path?[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]:nil;
    if(!source.length)return @"未找到对应的本机 JavaScript 引擎";
    [self.context evaluateScript:source withSourceURL:[NSURL fileURLWithPath:path]];
    if(self.context.exception)return self.context.exception.toString;
    if(self.genericMode){
        NSString *compatBootstrap =
        @"(function(g){\n"
        @"  const makeCatLib = function(){\n"
        @"    const C = g.CryptoJS || {};\n"
        @"    const ch = g.cheerio || {};\n"
        @"    const isObj = function(v){ return v !== null && typeof v === 'object'; };\n"
        @"    const _ = function(v){ return v; };\n"
        @"    Object.assign(_, {\n"
        @"      Crypto: C, CryptoJS: C, cheerio: ch, load: ch.load ? ch.load.bind(ch) : undefined,\n"
        @"      isEmpty: function(v){ if (v == null) return true; if (Array.isArray(v) || typeof v === 'string') return v.length === 0; if (isObj(v)) return Object.keys(v).length === 0; return false; },\n"
        @"      isArray: Array.isArray, isObject: isObj, isPlainObject: isObj,\n"
        @"      isString: function(v){ return typeof v === 'string'; },\n"
        @"      isFunction: function(v){ return typeof v === 'function'; },\n"
        @"      isNumber: function(v){ return typeof v === 'number' && !Number.isNaN(v); },\n"
        @"      isBoolean: function(v){ return typeof v === 'boolean'; },\n"
        @"      isUndefined: function(v){ return v === undefined; },\n"
        @"      isNull: function(v){ return v === null; },\n"
        @"      isNil: function(v){ return v == null; },\n"
        @"      isEqual: function(a, b){ try { return JSON.stringify(a) === JSON.stringify(b); } catch(_e) { return a === b; } },\n"
        @"      each: function(col, fn){ if (Array.isArray(col)) col.forEach(function(v, i){ fn(v, i, col); }); else if (isObj(col)) Object.keys(col).forEach(function(k){ fn(col[k], k, col); }); return col; },\n"
        @"      forEach: function(col, fn){ return _.each(col, fn); },\n"
        @"      map: function(col, fn){ if (Array.isArray(col)) return col.map(function(v, i){ return typeof fn === 'function' ? fn(v, i, col) : (v && v[fn]); }); if (isObj(col)) return Object.keys(col).map(function(k){ return typeof fn === 'function' ? fn(col[k], k, col) : (col[k] && col[k][fn]); }); return []; },\n"
        @"      filter: function(col, fn){ const arr = Array.isArray(col) ? col : (isObj(col) ? Object.values(col) : []); return arr.filter(function(v, i){ return typeof fn === 'function' ? fn(v, i) : Boolean(v && v[fn]); }); },\n"
        @"      find: function(col, fn){ const arr = Array.isArray(col) ? col : (isObj(col) ? Object.values(col) : []); return arr.find(function(v, i){ return typeof fn === 'function' ? fn(v, i) : Boolean(v && v[fn]); }); },\n"
        @"      some: function(col, fn){ const arr = Array.isArray(col) ? col : (isObj(col) ? Object.values(col) : []); return arr.some(function(v, i){ return typeof fn === 'function' ? fn(v, i) : Boolean(v); }); },\n"
        @"      every: function(col, fn){ const arr = Array.isArray(col) ? col : (isObj(col) ? Object.values(col) : []); return arr.every(function(v, i){ return typeof fn === 'function' ? fn(v, i) : Boolean(v); }); },\n"
        @"      includes: function(col, val){ if (Array.isArray(col) || typeof col === 'string') return col.includes(val); if (isObj(col)) return Object.values(col).includes(val); return false; },\n"
        @"      contains: function(col, val){ return _.includes(col, val); },\n"
        @"      pluck: function(col, key){ return (Array.isArray(col) ? col : []).map(function(v){ return v && v[key]; }); },\n"
        @"      uniq: function(arr, fn){ if (!Array.isArray(arr)) return []; if (typeof fn !== 'function') return Array.from(new Set(arr)); const seen = new Set(); return arr.filter(function(v, i){ const k = fn(v, i); if (seen.has(k)) return false; seen.add(k); return true; }); },\n"
        @"      unique: function(arr, fn){ return _.uniq(arr, fn); },\n"
        @"      flatten: function(arr){ return Array.isArray(arr) ? arr.flat(Infinity) : []; },\n"
        @"      compact: function(arr){ return Array.isArray(arr) ? arr.filter(Boolean) : []; },\n"
        @"      without: function(arr){ const vals = Array.prototype.slice.call(arguments, 1); return Array.isArray(arr) ? arr.filter(function(v){ return !vals.includes(v); }) : []; },\n"
        @"      range: function(start, stop, step){ if (stop === undefined) { stop = start; start = 0; } step = step || 1; const out = []; for (let i = start; step > 0 ? i < stop : i > stop; i += step) out.push(i); return out; },\n"
        @"      extend: Object.assign, assign: Object.assign,\n"
        @"      defaults: function(target){ target = Object(target); for (let i = 1; i < arguments.length; i++) { const src = arguments[i]; if (isObj(src)) for (const k of Object.keys(src)) if (target[k] === undefined) target[k] = src[k]; } return target; },\n"
        @"      clone: function(v){ if (Array.isArray(v)) return v.slice(); if (isObj(v)) return Object.assign({}, v); return v; },\n"
        @"      cloneDeep: function(v){ try { return JSON.parse(JSON.stringify(v)); } catch(_e) { return _.clone(v); } },\n"
        @"      keys: function(v){ return isObj(v) ? Object.keys(v) : []; },\n"
        @"      values: function(v){ return isObj(v) ? Object.values(v) : []; },\n"
        @"      entries: function(v){ return isObj(v) ? Object.entries(v) : []; },\n"
        @"      pairs: function(v){ return isObj(v) ? Object.entries(v) : []; },\n"
        @"      fromPairs: function(arr){ return Array.isArray(arr) ? Object.fromEntries(arr) : {}; },\n"
        @"      pick: function(obj){ const flat = Array.prototype.slice.call(arguments, 1).flat(); const out = {}; if (isObj(obj)) for (const k of flat) if (k in obj) out[k] = obj[k]; return out; },\n"
        @"      omit: function(obj){ const flat = new Set(Array.prototype.slice.call(arguments, 1).flat()); const out = {}; if (isObj(obj)) for (const k of Object.keys(obj)) if (!flat.has(k)) out[k] = obj[k]; return out; },\n"
        @"      has: function(obj, k){ return isObj(obj) && Object.prototype.hasOwnProperty.call(obj, k); },\n"
        @"      get: function(obj, path, def){ const parts = Array.isArray(path) ? path : String(path || '').split('.').filter(Boolean); let cur = obj; for (const p of parts) { if (cur == null) return def; cur = cur[p]; } return cur === undefined ? def : cur; },\n"
        @"      trim: function(s){ return String(s == null ? '' : s).trim(); },\n"
        @"      random: function(min, max){ if (min === undefined) min = 0; if (max === undefined) { max = min; min = 0; } return Math.floor(Math.random() * (max - min + 1)) + min; },\n"
        @"      now: function(){ return Date.now(); },\n"
        @"      noop: function(){},\n"
        @"      identity: function(v){ return v; },\n"
        @"      jinja2: function(tpl, data){ return String(tpl == null ? '' : tpl).replace(/\\{\\{\\s*([^}]+?)\\s*\\}\\}/g, function(_m, expr){ try { return _.get(data, expr.trim(), ''); } catch(_e) { return ''; } }); }\n"
        @"    });\n"
        @"    _.default = _;\n"
        @"    return _;\n"
        @"  };\n"
        @"  g.__cctvImport = function(spec){\n"
        @"    const id = String(spec || '').trim();\n"
        @"    const lower = id.toLowerCase();\n"
        @"    if (lower.includes('cat.js') || lower === 'underscore' || lower === 'lodash') return makeCatLib();\n"
        @"    if (lower.includes('crypto-js') || lower === 'crypto') {\n"
        @"      const c = g.CryptoJS || (g.__cctvBuiltins && g.__cctvBuiltins['crypto-js']) || {};\n"
        @"      if (c && typeof c === 'object' && !c.default) { try { c.default = c; c.Crypto = c; } catch(_e){} }\n"
        @"      return c;\n"
        @"    }\n"
        @"    if (lower.includes('cheerio')) {\n"
        @"      const ch = g.cheerio || (g.__cctvBuiltins && g.__cctvBuiltins.cheerio) || {};\n"
        @"      const loadFn = ch.load ? ch.load.bind(ch) : function(){ return function(){ return { text: function(){ return ''; }, attr: function(){ return ''; } }; }; };\n"
        @"      if (!loadFn.load) loadFn.load = loadFn;\n"
        @"      if (!loadFn.default) loadFn.default = ch;\n"
        @"      if (!loadFn.jinja2) loadFn.jinja2 = function(tpl, obj){ return String(tpl == null ? '' : tpl).replace(/\\{\\{\\s*([^}]+?)\\s*\\}\\}/g, function(_m, k){ const parts = k.trim().split('.'); let cur = obj; for (const p of parts) cur = cur && cur[p]; return cur == null ? '' : cur; }); };\n"
        @"      return Object.assign(loadFn, ch);\n"
        @"    }\n"
        @"    if (lower.includes('jsencrypt')) {\n"
        @"      function JSEncrypt(){ this.pub = ''; this.priv = ''; }\n"
        @"      JSEncrypt.prototype.setPublicKey = function(k){ this.pub = k; };\n"
        @"      JSEncrypt.prototype.setPrivateKey = function(k){ this.priv = k; };\n"
        @"      JSEncrypt.prototype.encrypt = function(v){ return (g.RSA && g.RSA.encode) ? g.RSA.encode(v, this.pub) : String(v || ''); };\n"
        @"      JSEncrypt.prototype.decrypt = function(v){ return (g.RSA && g.RSA.decode) ? g.RSA.decode(v, this.priv) : String(v || ''); };\n"
        @"      JSEncrypt.default = JSEncrypt;\n"
        @"      return JSEncrypt;\n"
        @"    }\n"
        @"    if (lower.includes('template.js') || lower.includes('模板.js')) {\n"
        @"      const m = g['模板'] || { getMubans: function(){ return {}; } };\n"
        @"      m.default = m;\n"
        @"      return m;\n"
        @"    }\n"
        @"    if (lower.includes('gbk.js') || lower === 'gbk') {\n"
        @"      const iconv = g.__cctvBuiltins && g.__cctvBuiltins['iconv-lite'];\n"
        @"      const tool = function(){ return { encode: function(s){ return iconv ? Array.from(iconv.encode(String(s || ''), 'gbk')) : []; }, decode: function(b){ return iconv ? iconv.decode(g.Buffer.from(b || []), 'gbk') : ''; } }; };\n"
        @"      tool.default = tool;\n"
        @"      return tool;\n"
        @"    }\n"
        @"    const clean = id.replace(/^node:/, '');\n"
        @"    if (g.__cctvBuiltins && g.__cctvBuiltins[clean]) {\n"
        @"      const b = g.__cctvBuiltins[clean];\n"
        @"      return b && typeof b === 'object' && !('default' in b) ? Object.assign({}, b, { default: b }) : b;\n"
        @"    }\n"
        @"    if (typeof g.__cctvRequire === 'function') {\n"
        @"      try {\n"
        @"        const r = g.__cctvRequire(id);\n"
        @"        return r && typeof r === 'object' && !('default' in r) ? Object.assign({}, r, { default: r }) : r;\n"
        @"      } catch(_e){}\n"
        @"    }\n"
        @"    return makeCatLib();\n"
        @"  };\n"
        @"  g.__JS_SPIDER__ = null;\n"
        @"  g.__cctvAdaptRuleOrHjsPlugin = function(cand){\n"
        @"    if (!cand || typeof cand !== \"object\") return cand;\n"
        @"    const aliasMap = { home: \"getHome\", category: \"getCategory\", search: \"getSearch\", detail: \"getDetail\", play: \"getPlay\", homeContent: \"home_content\", categoryContent: \"category_content\", detailContent: \"detail_content\", playerContent: \"player_content\", searchContent: \"search_content\" };\n"
        @"    for (const k of Object.keys(aliasMap)) { if (typeof cand[k] !== \"function\" && typeof cand[aliasMap[k]] === \"function\") cand[k] = cand[aliasMap[k]]; }\n"
        @"    if (typeof cand.home !== \"function\" && typeof cand.list === \"function\") {\n"
        @"      cand.home = function(args){ return cand.list(args || {}); };\n"
        @"      if (typeof cand.category !== \"function\") cand.category = function(args){ return cand.list(args || {}); };\n"
        @"    }\n"
        @"    const hasMethod = [\"home\",\"homeContent\",\"category\",\"categoryContent\",\"search\",\"searchContent\",\"detail\",\"detailContent\",\"play\",\"playerContent\",\"channels\",\"catalog\",\"resolve\"].some(function(k){ return typeof cand[k] === \"function\"; });\n"
        @"    if (hasMethod && cand.rule) { cand._cctvRule = cand.rule; try { delete cand.rule; } catch(_e){} return cand; }\n"
        @"    if (hasMethod) return cand;\n"
        @"    const r = (cand.rule && typeof cand.rule === \"object\") ? cand.rule : cand;\n"
        @"    if (r && typeof r === \"object\" && (r[\"一级\"] || r[\"二级\"] || r[\"分类url\"] || r.class_name || r.host || r.url || Array.isArray(r.categories))) {\n"
        @"      const rawHost = String(r.host || r.url || r.homeUrl || \"\").trim().replace(/\\/$/, \"\");\n"
        @"      const parseCats = function(){\n"
        @"        if (Array.isArray(r.categories)) return r.categories;\n"
        @"        const cn = String(r.class_name || r[\"分类\"] || \"\").trim();\n"
        @"        const cu = String(r.class_url || \"\").trim();\n"
        @"        const out = [];\n"
        @"        if (cn && cn.includes(\"$\")) {\n"
        @"          cn.split(\"#\").forEach(function(p){ const kv = p.split(\"$\"); if (kv.length >= 2) out.push({ id: kv[1].trim(), name: kv[0].trim(), type_id: kv[1].trim(), type_name: kv[0].trim() }); });\n"
        @"        } else if (cn && cu) {\n"
        @"          const ns = cn.split(\"&\"), us = cu.split(\"&\");\n"
        @"          for (let i = 0; i < Math.min(ns.length, us.length); i++) if (ns[i]) out.push({ id: us[i].trim(), name: ns[i].trim(), type_id: us[i].trim(), type_name: ns[i].trim() });\n"
        @"        }\n"
        @"        return out.length ? out : [{ id: \"1\", name: \"精选\", type_id: \"1\", type_name: \"精选\" }];\n"
        @"      };\n"
        @"      const fetchList = async function(tid, pg, kw){\n"
        @"        if (!rawHost) return [];\n"
        @"        let target = rawHost;\n"
        @"        const tpl = String(kw ? (r.searchUrl || r[\"搜索url\"] || \"\") : (r.url || r[\"分类url\"] || \"\")).trim();\n"
        @"        if (tpl) {\n"
        @"          target = (tpl.startsWith(\"http\") ? tpl : (rawHost + (tpl.startsWith(\"/\") ? \"\" : \"/\") + tpl)).replace(/fyclass|\\{cateId\\}/g, String(tid || \"1\")).replace(/fypage|\\{catePg\\}|\\{pg\\}/g, String(pg || \"1\")).replace(/\\*\\*|\\{wd\\}/g, encodeURIComponent(String(kw || \"\")));\n"
        @"        }\n"
        @"        if (typeof g.request !== \"function\") return [];\n"
        @"        try {\n"
        @"          const html = await g.request(target, { headers: r.headers || {} });\n"
        @"          if (html && typeof html === \"string\" && html.trim().startsWith(\"{\")) {\n"
        @"            const j = JSON.parse(html);\n"
        @"            const arr = Array.isArray(j.list) ? j.list : (Array.isArray(j.data) ? j.data : []);\n"
        @"            if (arr.length) return arr;\n"
        @"          }\n"
        @"        } catch(_e){}\n"
        @"        return [];\n"
        @"      };\n"
        @"      return {\n"
        @"        apiVersion: 3,\n"
        @"        meta: { name: String(r.title || r.name || \"规则站点\") },\n"
        @"        home: async function(){ const cats = parseCats(); const list = await fetchList(cats[0].id, 1, \"\"); return { categories: cats, class: cats, items: list, list: list }; },\n"
        @"        category: async function(args){ const tid = typeof args === \"object\" ? (args.categoryId || args.id || \"1\") : String(args || \"1\"); const pg = typeof args === \"object\" ? (args.page || 1) : 1; const list = await fetchList(tid, pg, \"\"); return { page: Number(pg) || 1, items: list, list: list }; },\n"
        @"        search: async function(args){ const kw = typeof args === \"object\" ? (args.keyword || args.wd || \"\") : String(args || \"\"); const list = await fetchList(\"1\", 1, kw); return { page: 1, items: list, list: list }; },\n"
        @"        detail: async function(args){ const id = typeof args === \"object\" ? (args.id || args.itemId || \"\") : String(args || \"\"); return { id: String(id), name: String(r.title || id), lines: [{ id: \"default\", name: \"默认线路\", episodes: [{ id: String(id), name: \"正片\", url: String(id) }] }] }; },\n"
        @"        play: async function(args){ const id = typeof args === \"object\" ? (args.id || args.url || \"\") : String(args || \"\"); return { url: String(id), parse: /^https?:\\/\\//i.test(String(id)) && !/\\.(?:m3u8|mp4)(?:$|[?#])/i.test(String(id)) ? 1 : 0 }; },\n"
        @"        resolve: async function(args){ const id = typeof args === \"object\" ? (args.url || args.id || \"\") : String(args || \"\"); return { url: String(id) }; }\n"
        @"      };\n"
        @"    }\n"
        @"    return cand;\n"
        @"  };\n"
        @"  g.__cctvTransformSource = function(rawText, moduleType, protocol){\n"
        @"    let text = String(rawText == null ? \"\" : rawText);\n"
        @"    if (!text) return text;\n"
        @"    if (text.includes(\"async function sitePrepareImageDomains(value)\")) {\n"
        @"      text = text.replace(\"cacheAge=cached&&cached.domain?1800000:60000\", \"cacheAge=cached&&cached.domain?1800000:300000\");\n"
        @"      text = text.replace(\"offset+=3){var probes=await Promise.all(mirrors.slice(offset,offset+3)\", \"offset+=6){var probes=await Promise.all(mirrors.slice(offset,offset+6)\");\n"
        @"      text = text.replace(\"timeout:3000,headers:{Referer:Source.origin+'/'\", \"timeout:1200,headers:{Referer:Source.origin+'/'\");\n"
        @"      text = text.replace(\"var d=siteDetails[id]||await adapter.detail(id);await sitePrepareImageDomains(d);var lines=\", \"var d=siteDetails[id]||await adapter.detail(id);await Promise.race([sitePrepareImageDomains(d),new Promise(function(r){setTimeout(r,800);})]);var lines=\");\n"
        @"    }\n"
        @"    if (text.includes(\"assets://js/lib/cheerio.min.js\") && (/\\b(?:let|var|const)\\s+rule\\s*=\\s*\\{\\s*\\}|[,;]\\s*rule\\s*=\\s*\\{\\s*\\}/.test(text) || text.includes(\"DRPY\") || text.includes(\"gbk.js\") || text.includes(\"init_test\"))) {\n"
        @"      return \"var rule = (function(){\\n\" +\n"
        @"        \"  var opt = globalThis.__cctvActiveOptions;\\n\" +\n"
        @"        \"  var ext = typeof opt === 'string' ? opt.trim() : (opt && typeof opt === 'object' ? String(opt.ext || opt.extend || opt.rule || '').trim() : '');\\n\" +\n"
        @"        \"  if (!ext && opt && typeof opt === 'object' && (opt.host || opt.title || opt['一级'] || opt['二级'])) return opt;\\n\" +\n"
        @"        \"  if (!ext) throw new Error('此 drpy 站点仅提供引擎壳（drpy2.min.js），未在合集 ext 中提供规则地址或内容');\\n\" +\n"
        @"        \"  var code = /^https?:\\\\/\\\\//i.test(ext) ? (typeof request === 'function' ? request(ext, {method: 'GET'}) : '') : ext;\\n\" +\n"
        @"        \"  if (!code || typeof code !== 'string' || !code.trim()) throw new Error('无法加载 drpy 远端规则：' + ext);\\n\" +\n"
        @"        \"  var rule;\\n\" +\n"
        @"        \"  eval(code.replace(/^\\\\s*export\\\\s+default\\\\s+/, 'rule = ').replace(/\\\\b(?:var|let|const)\\\\s+rule\\\\s*=/, 'rule ='));\\n\" +\n"
        @"        \"  return rule;\\n\" +\n"
        @"        \"})();\\n\";\n"
        @"    }\n"
        @"    const mapSpecList = function(specList){\n"
        @"      return specList.split(\",\").map(function(s){ return s.trim(); }).filter(Boolean).map(function(s){\n"
        @"        const m = s.match(/^([A-Za-z0-9_$]+)\\s+as\\s+([A-Za-z0-9_$]+)$/);\n"
        @"        return m ? (m[1] + \": \" + m[2]) : s;\n"
        @"      }).join(\", \");\n"
        @"    };\n"
        @"    const replaceImportClause = function(clause, modExpr){\n"
        @"      clause = clause.trim();\n"
        @"      if (clause.startsWith(\"*\")) {\n"
        @"        const m = clause.match(/^\\*\\s+as\\s+([A-Za-z0-9_$]+)$/);\n"
        @"        if (m) return \"var \" + m[1] + \" = \" + modExpr + \";\";\n"
        @"      }\n"
        @"      if (clause.startsWith(\"{\") && clause.endsWith(\"}\")) {\n"
        @"        return \"var {\" + mapSpecList(clause.slice(1, -1)) + \"} = \" + modExpr + \";\";\n"
        @"      }\n"
        @"      if (clause.includes(\",\")) {\n"
        @"        const braceIdx = clause.indexOf(\"{\");\n"
        @"        if (braceIdx > 0 && clause.endsWith(\"}\")) {\n"
        @"          const defName = clause.slice(0, braceIdx).replace(/,/g, \"\").trim();\n"
        @"          const named = mapSpecList(clause.slice(braceIdx + 1, -1));\n"
        @"          return \"var \" + defName + \" = (\" + modExpr + \" && \" + modExpr + \".default) || \" + modExpr + \", {\" + named + \"} = \" + modExpr + \";\";\n"
        @"        }\n"
        @"      }\n"
        @"      return \"var \" + clause + \" = (\" + modExpr + \" && \" + modExpr + \".default) || \" + modExpr + \";\";\n"
        @"    };\n"
        @"    for (let pass = 0; pass < 4; pass++) {\n"
        @"      text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*import(?:\\s+|\\s*(?=[{*]))([^;\\r\\n]+?)(?:\\s+|(?<=\\})\\s*)from\\s*(['\"])(assets:\\/\\/[^'\"]+)\\3\\s*;?/g, function(_m, pre, clause, _q, spec){\n"
        @"        return pre + replaceImportClause(clause, \"globalThis.__cctvImport(\" + JSON.stringify(spec) + \")\");\n"
        @"      });\n"
        @"    }\n"
        @"    const leadMatch = text.match(/^(?:\\uFEFF)?(?:\\s|\\/\\/[^\\r\\n]*|\\/\\*[\\s\\S]*?\\*\\/)*/);\n"
        @"    const leadLen = leadMatch ? leadMatch[0].length : 0;\n"
        @"    const body = text.slice(leadLen).trim();\n"
        @"    if (/^\\{\\s*(?:['\"][^'\"]+['\"]|[A-Za-z_$][\\w$]*)\\s*:/.test(body) && /\\}\\s*;?\\s*$/.test(body)) {\n"
        @"      const cleanBody = body.replace(/;\\s*$/, \"\");\n"
        @"      text = text.slice(0, leadLen) +\n"
        @"        \"var plugin = (\\n\" + cleanBody + \"\\n);\\n\" +\n"
        @"        \"if (plugin && typeof plugin === \\\"object\\\" && !plugin.home && !plugin.homeContent && !plugin.detail && !plugin.detailContent && !plugin.play && !plugin.playerContent && !plugin.resolve && (plugin.msg || plugin.message || plugin.error || (plugin.code && Number(plugin.code) >= 400))) {\\n\" +\n"
        @"        \"  throw new Error(\\\"源站返回异常：\\\" + String(plugin.msg || plugin.message || plugin.error || (\\\"HTTP \\\" + plugin.code)));\\n\" +\n"
        @"        \"}\\n\" +\n"
        @"        \"if (plugin && typeof globalThis.__cctvAdaptRuleOrHjsPlugin === \\\"function\\\") { plugin = globalThis.__cctvAdaptRuleOrHjsPlugin(plugin); }\\n\" +\n"
        @"        (moduleType === \"esm\" ? \"export default plugin;\\n\" : \"\");\n"
        @"      return text;\n"
        @"    }\n"
        @"    const isScriptLike = moduleType !== \"esm\" || protocol === \"drpy\" || text.includes(\"__jsEvalReturn\") || text.includes(\"__JS_SPIDER__\");\n"
        @"    if (isScriptLike) {\n"
        @"      for (let pass = 0; pass < 4; pass++) {\n"
        @"        text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*import(?:\\s+|\\s*(?=[{*]))([^;\\r\\n]+?)(?:\\s+|(?<=\\})\\s*)from\\s*(['\"])([^'\"]+)\\3\\s*;?/g, function(_m, pre, clause, _q, spec){\n"
        @"          return pre + replaceImportClause(clause, \"globalThis.__cctvImport(\" + JSON.stringify(spec) + \")\");\n"
        @"        });\n"
        @"        text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*import\\s*(['\"])([^'\"]+)\\2\\s*;?/g, function(_m, pre, _q, spec){\n"
        @"          return pre + \"globalThis.__cctvImport(\" + JSON.stringify(spec) + \");\";\n"
        @"        });\n"
        @"      }\n"
        @"      let hadDefaultExport = false;\n"
        @"      text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*export\\s+default\\s+/g, function(_m, pre){\n"
        @"        hadDefaultExport = true;\n"
        @"        return pre + \"var __cctvDefaultExport = \";\n"
        @"      });\n"
        @"      text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*export\\s+(async\\s+function|function|class|const|let|var)\\b/g, function(_m, pre, kw){\n"
        @"        return pre + (kw === \"const\" || kw === \"let\" ? \"var\" : kw);\n"
        @"      });\n"
        @"      text = text.replace(/(^|[\\r\\n;}]|\\*\\/)\\s*export\\s*\\{([^}]*)\\}\\s*;?/g, function(_m, pre, list){\n"
        @"        const pairs = list.split(\",\").map(function(s){ return s.trim(); }).filter(Boolean).map(function(s){\n"
        @"          const m = s.match(/^([A-Za-z0-9_$]+)\\s+as\\s+([A-Za-z0-9_$]+)$/);\n"
        @"          return m ? (JSON.stringify(m[2]) + \": \" + m[1]) : (JSON.stringify(s) + \": \" + s);\n"
        @"        }).join(\", \");\n"
        @"        return pre + \"var __cctvNamedExports = {\" + pairs + \"}; if (typeof plugin === \\\"undefined\\\") var plugin = __cctvNamedExports.default || (typeof __cctvNamedExports.__jsEvalReturn === \\\"function\\\" ? __cctvNamedExports.__jsEvalReturn() : __cctvNamedExports);\";\n"
        @"      });\n"
        @"      if (hadDefaultExport) {\n"
        @"        text += \"\\nif (typeof __cctvDefaultExport !== \\\"undefined\\\" && typeof plugin === \\\"undefined\\\") { var plugin = __cctvDefaultExport; }\\n\";\n"
        @"      }\n"
        @"      if (text.includes(\"__jsEvalReturn\")) {\n"
        @"        text += \"\\nif (typeof __jsEvalReturn === \\\"function\\\" && typeof plugin === \\\"undefined\\\") { var plugin = __jsEvalReturn(); }\\n\";\n"
        @"      }\n"
        @"      if (text.includes(\"__JS_SPIDER__\")) {\n"
        @"        text = \"var __JS_SPIDER__ = globalThis.__JS_SPIDER__ || null;\\n\" + text + \"\\nif (typeof __JS_SPIDER__ !== \\\"undefined\\\" && __JS_SPIDER__) { globalThis.__JS_SPIDER__ = __JS_SPIDER__; if (typeof plugin === \\\"undefined\\\" || !plugin) var plugin = __JS_SPIDER__; }\\n\";\n"
        @"      }\n"
        @"      if (protocol !== \"drpy\") {\n"
        @"        text = \"var module = typeof module !== \\\"undefined\\\" ? module : { exports: {} }, exports = module.exports;\\n\" + text +\n"
        @"          \"\\n;(function(){\\n\" +\n"
        @"          \"  var cand = typeof plugin !== \\\"undefined\\\" && plugin ? plugin : (typeof spider !== \\\"undefined\\\" && spider ? spider : (typeof __JS_SPIDER__ !== \\\"undefined\\\" && __JS_SPIDER__ ? __JS_SPIDER__ : (globalThis.__JS_SPIDER__ ? globalThis.__JS_SPIDER__ : (typeof hawk !== \\\"undefined\\\" && hawk ? hawk : (typeof hamo !== \\\"undefined\\\" && hamo ? hamo : (typeof source !== \\\"undefined\\\" && source && typeof source === \\\"object\\\" ? source : (module && module.exports && Object.keys(module.exports).length ? (module.exports.default || module.exports) : (typeof rule !== \\\"undefined\\\" && rule ? rule : null))))))));\\n\" +\n"
        @"          \"  if (cand && typeof globalThis.__cctvAdaptRuleOrHjsPlugin === \\\"function\\\") { plugin = globalThis.__cctvAdaptRuleOrHjsPlugin(cand); }\\n\" +\n"
        @"          \"})();\\n\";\n"
        @"      }\n"
        @"      if (moduleType === \"esm\" && !/\\bexport\\s+default\\b/.test(text)) {\n"
        @"        text += \"\\nexport default (typeof plugin !== \\\"undefined\\\" ? plugin : (globalThis.__JS_SPIDER__ || {}));\\n\";\n"
        @"      }\n"
        @"    }\n"
        @"    return text;\n"
        @"  };\n"
        @"})(globalThis);";
        [self.context evaluateScript:compatBootstrap];
        self.context.exception = nil;
    }
    if(self.context[@"__cctvInvoke"].isUndefined)return @"JS 插件入口无效";
    return nil;
}
- (void)finishCall:(NSString *)identifier answer:(NSString *)answer { void (^reply)(NSString *)=self.calls[identifier];[self.calls removeObjectForKey:identifier];if(reply)reply(answer); }
- (void)dispose {
    self.generation++;self.activeSession=nil;[self.session invalidateAndCancel];self.session=nil;
    // 在途 fetch 不在这里逐项回调：JS 回调会跑进正在拆除的 context，Promise
    // 微任务未必能在 context 置空前跑完，还可能重入 fetch（见 26d40e9 的
    // CI：回调重入曾让 fetch 拿到 nil task 崩溃，改守卫后又改变了待决
    // resolve 的结算结果）。在途调用方由下面 finishCall 的 ok:false
    // 统一唤醒，fetch 记录直接丢弃即可。
    [self.requests removeAllObjects];[self.timers removeAllObjects];self.context=nil;self.unresponsive=NO;
    self.packageRoot=nil;self.genericMode=NO;self.hostFetchURL=nil;self.hostFetchToken=nil;self.activeModuleType=nil;self.activeProtocol=nil;self.activeOptions=nil;
    for(NSString *key in self.calls.allKeys)[self finishCall:key answer:@"{\"ok\":false,\"error\":\"JS 服务已停止\"}"];
}
- (NSString *)callOperation:(NSString *)operation json:(NSString *)json timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if(self.router){
        NSData *input=[json dataUsingEncoding:NSUTF8StringEncoding];id payload=input?[NSJSONSerialization JSONObjectWithData:input options:0 error:NULL]:nil;
        NSString *session=[payload isKindOfClass:NSDictionary.class]&&[payload[@"session"] isKindOfClass:NSString.class]?payload[@"session"]:@"";
        if(!session.length){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:3 userInfo:@{NSLocalizedDescriptionKey:@"JS 会话标识无效"}];return nil;}
        JSPluginRuntime *runtime=nil;
        @synchronized(self){runtime=self.sessionRuntimes[session];if([operation isEqual:@"start"]&&!runtime){runtime=[[JSPluginRuntime alloc] initWithScriptURL:self.scriptURL configuration:self.networkConfiguration];runtime.serviceIdentifier=[payload[@"serviceID"] isKindOfClass:NSString.class]?payload[@"serviceID"]:session;void(^logger)(NSString *)=[self.sessionLogHandlers[runtime.serviceIdentifier] copy]?:[self.logHandler copy];runtime.logHandler=^(NSString *line){if(logger)logger(line);};self.sessionRuntimes[session]=runtime;}}
        if(!runtime && [operation isEqual:@"stop"])return @"{\"ok\":true,\"result\":true}";
        if(!runtime){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:4 userInfo:@{NSLocalizedDescriptionKey:@"JS 会话尚未启动"}];return nil;}
        NSString *answer=[runtime callOperation:operation json:json timeout:timeout error:error];
        id result=answer?[NSJSONSerialization JSONObjectWithData:[answer dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;
        BOOL failedStart=[operation isEqual:@"start"]&&(!answer||([result isKindOfClass:NSDictionary.class]&&![result[@"ok"] boolValue]));
        if(failedStart){
            // A bridge timeout does not cancel the queued JSC work. Keep the session owner
            // reachable and queue an ordered stop; only release it after stop is confirmed.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                NSDictionary *stopPayload=@{@"session":session,@"serviceID":runtime.serviceIdentifier?:@""};NSData *stopData=[NSJSONSerialization dataWithJSONObject:stopPayload options:0 error:NULL];NSError *stopError=nil;
                NSString *stopAnswer=[runtime callOperation:@"stop" json:[[NSString alloc] initWithData:stopData encoding:NSUTF8StringEncoding] timeout:15 error:&stopError];id stopReply=stopAnswer?[NSJSONSerialization JSONObjectWithData:[stopAnswer dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;
                if([stopReply isKindOfClass:NSDictionary.class]&&[stopReply[@"ok"] boolValue]){@synchronized(self){if(self.sessionRuntimes[session]==runtime)[self.sessionRuntimes removeObjectForKey:session];}}
            });
        }
        if([operation isEqual:@"stop"] && answer){id reply=[NSJSONSerialization JSONObjectWithData:[answer dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];if([reply isKindOfClass:NSDictionary.class]&&[reply[@"ok"] boolValue])@synchronized(self){if(self.sessionRuntimes[session]==runtime)[self.sessionRuntimes removeObjectForKey:session];}}
        return answer;
    }
    if(NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:1 userInfo:@{NSLocalizedDescriptionKey:@"JS 服务须从后台调用"}];return nil;}
    if(self.unresponsive&&![operation isEqual:@"stop"]){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:7 userInfo:@{NSLocalizedDescriptionKey:@"此 JavaScript 会话有调用超时且仍占用运行队列；请先停止会话，其他服务不受影响。"}];return nil;}
    if([operation isEqual:@"stop"]){
        id payload=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if([payload isKindOfClass:NSDictionary.class] && [self.activeSession isEqualToString:payload[@"session"]]){self.stopRequested=YES;@synchronized(self.syncRequests){for(HostSyncRequest *request in self.syncRequests)[request cancel];}}
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSString *answer=nil;NSString *identifier=NSUUID.UUID.UUIDString;
    dispatch_async(self.queue,^{@autoreleasepool {
        NSData *data=[json dataUsingEncoding:NSUTF8StringEncoding];id payload=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:@{};
        if(![payload isKindOfClass:NSDictionary.class])payload=@{};
        NSString *session=[payload[@"session"] isKindOfClass:NSString.class]?payload[@"session"]:@"";
        if([operation isEqualToString:@"stop"]){
            if([self.activeSession isEqualToString:session]){if(self.context)[self.context[@"CCTVHostJS"][@"stop"] callWithArguments:@[]];[self dispose];}
            answer=@"{\"ok\":true,\"result\":true}";dispatch_semaphore_signal(done);return;
        }
        if([operation isEqualToString:@"start"] && session.length && !self.context){
            self.stopRequested=NO;
            NSString *root=[payload[@"packageRoot"] isKindOfClass:NSString.class]?payload[@"packageRoot"]:nil;
            if(root.length){
                NSString *canonical=[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path;
                NSString *allowed=[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Services"] stringByAppendingString:@"/"];
                if(!self.scriptURL && ![canonical hasPrefix:allowed]){answer=[self encodedError:@"JS 入口不在已安装资源目录中"];dispatch_semaphore_signal(done);return;}
                self.packageRoot=canonical;self.genericMode=YES;
            }
            self.hostFetchURL=[payload[@"hostFetchURL"] isKindOfClass:NSString.class]?payload[@"hostFetchURL"]:nil;
            self.hostFetchToken=[payload[@"hostFetchToken"] isKindOfClass:NSString.class]?payload[@"hostFetchToken"]:nil;
            self.activeModuleType=[payload[@"moduleType"] isKindOfClass:NSString.class]?payload[@"moduleType"]:@"";
            self.activeProtocol=[payload[@"protocol"] isKindOfClass:NSString.class]?payload[@"protocol"]:@"";
            self.activeOptions=payload[@"options"];
            NSString *failure=[self initializeContext];if(failure){[self dispose];answer=[self encodedError:failure];dispatch_semaphore_signal(done);return;}self.activeSession=session;
        }
        if([operation isEqualToString:@"start"] && self.context){
            self.activeModuleType=[payload[@"moduleType"] isKindOfClass:NSString.class]?payload[@"moduleType"]:(self.activeModuleType?:@"");
            self.activeProtocol=[payload[@"protocol"] isKindOfClass:NSString.class]?payload[@"protocol"]:(self.activeProtocol?:@"");
            self.activeOptions=payload[@"options"];
            self.context[@"__cctvActiveOptions"]=self.activeOptions?:@{};
            self.context[@"__cctvActiveModuleType"]=self.activeModuleType?:@"";
            self.context[@"__cctvActiveProtocol"]=self.activeProtocol?:@"";
        }
        if(!self.context || ![self.activeSession isEqualToString:session]){answer=[self encodedError:@"JS 会话已停止或不匹配"];dispatch_semaphore_signal(done);return;}
        if(self.calls.count>=16){answer=[self encodedError:@"JS 调用并发已满"];dispatch_semaphore_signal(done);return;}
        self.calls[identifier]=^(NSString *reply){answer=reply;dispatch_semaphore_signal(done);};
        __weak typeof(self) weak=self;
        self.context.exception=nil;
        [self.context[@"__cctvInvoke"] callWithArguments:@[operation,payload,^(NSString *reply){[weak finishCall:identifier answer:reply];}]];
        if(self.context.exception){[self finishCall:identifier answer:[self encodedError:self.context.exception.toString]];self.context.exception=nil;}
    }});
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)))!=0){
        self.unresponsive=YES;
        // 超时调用仍占着串行队列：把复位排在队列尾，等它执行完再恢复，
        // 调用方此后可重新使用本会话；若 JS 死循环占住队列则永不复位，语义正确。
        dispatch_async(self.queue,^{
            [self.calls removeObjectForKey:identifier];
            if(![operation isEqualToString:@"start"] && self.calls.count==0 && self.requests.count>0){
                for(NSNumber *reqKey in self.requests.allKeys.copy){
                    NSMutableDictionary *rec=self.requests[reqKey];
                    rec[@"aborted"]=@YES;
                    [rec[@"task"] cancel];
                    [self fetchFinished:reqKey error:@"AbortError"];
                }
            }
            self.unresponsive=NO;
        });
        if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:2 userInfo:@{NSLocalizedDescriptionKey:@"JS 插件调用超时"}];return nil;
    }
    return answer;
}
- (NSString *)packageFile:(NSString *)name {
    if(!self.packageRoot.length || ![name isKindOfClass:NSString.class] || !name.length || [name hasPrefix:@"/"])return nil;
    NSString *path=[NSURL fileURLWithPath:[self.packageRoot stringByAppendingPathComponent:name]].URLByResolvingSymlinksInPath.path;
    if(![path hasPrefix:[self.packageRoot stringByAppendingString:@"/"]])return nil;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    return [attributes[NSFileType] isEqual:NSFileTypeRegular] && attributes.fileSize<=8*1024*1024?path:nil;
}
- (NSString *)encodedError:(NSString *)message {NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"ok":@NO,@"error":message?:@"JS 错误"} options:0 error:NULL];return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];}
@end
