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
    [callback callWithArguments:@[@{@"status":@(response.statusCode),@"url":response.URL.absoluteString?:@"",@"headers":response.allHeaderFields?:@{},@"base64":[data base64EncodedStringWithOptions:0]?:@""}]];
}
- (NSNumber *)fetch:(NSString *)url options:(NSString *)options callback:(JSValue *)callback {
    NSNumber *key=@(++self.sequence);
    if(url.length>8192 || options.length>2*1024*1024){[callback callWithArguments:@[@{@"error":@"JS 请求参数超过限制"}]];return key;}
    NSURL *target=[NSURL URLWithString:url];
    if(![self allowedURL:target] || self.requests.count>=8){[callback callWithArguments:@[@{@"error":@"JS 网络地址不受支持或并发已满"}]];return key;}
    NSData *bytes=[options dataUsingEncoding:NSUTF8StringEncoding];NSDictionary *opts=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
    if(![opts isKindOfClass:NSDictionary.class])opts=@{};
    NSString *method=[opts[@"method"] isKindOfClass:NSString.class]?[opts[@"method"] uppercaseString]:@"GET";
    if((!self.genericMode && ![method isEqual:@"GET"]) || ![@[@"GET",@"POST",@"PUT",@"PATCH",@"DELETE",@"HEAD",@"OPTIONS"] containsObject:method]){[callback callWithArguments:@[@{@"error":@"不支持的 HTTP 方法"}]];return key;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
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
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request];
    self.requests[key]=[@{@"callback":callback,@"task":task,@"data":[NSMutableData data]} mutableCopy];
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
    NSNumber *key=[self keyForTask:task];if(key)[self fetchFinished:key error:error.localizedDescription];
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
        if(!text){JSContext.currentContext.exception=[JSValue valueWithNewErrorFromMessage:@"JS 包文件不存在、越界或不是 UTF-8 文本" inContext:JSContext.currentContext];return @"";}return text;
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
    self.context[@"__hostAbortFetch"]=^(NSNumber *key){JSPluginRuntime *s=weak;[s.requests[key][@"task"] cancel];[s fetchFinished:key error:@"AbortError"];};
    self.context[@"__hostSetTimeout"]=^NSNumber *(JSValue *callback,double ms){
        JSPluginRuntime *s=weak;if(!s || s.timers.count>=128)return @0;
        NSNumber *key=@(++s.sequence);NSUInteger generation=s.generation;s.timers[key]=callback;
        double delay=isfinite(ms)?MAX(0,MIN(ms,2147483647)):0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_MSEC)),s.queue,^{
            @autoreleasepool {JSPluginRuntime *r=weak;if(r.generation!=generation)return;JSValue *fn=r.timers[key];[r.timers removeObjectForKey:key];if(fn)[fn callWithArguments:@[]];}
        });return key;
    };
    self.context[@"__hostClearTimeout"]=^(NSNumber *key){[weak.timers removeObjectForKey:key];};
    NSURLSessionConfiguration *config=self.networkConfiguration.copy?:NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.HTTPCookieStorage=nil;config.HTTPMaximumConnectionsPerHost=4;config.timeoutIntervalForRequest=12;config.timeoutIntervalForResource=15;
    NSOperationQueue *delegate=[NSOperationQueue new];delegate.maxConcurrentOperationCount=1;delegate.underlyingQueue=self.queue;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegate];
    NSString *path=self.scriptURL.path?:[NSBundle.mainBundle pathForResource:self.genericMode?@"js-runtime.bundle":@"yangshipin.bundle" ofType:@"js"];
    NSString *source=path?[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]:nil;
    if(!source.length)return @"未找到对应的本机 JavaScript 引擎";
    [self.context evaluateScript:source withSourceURL:[NSURL fileURLWithPath:path]];
    if(self.context.exception)return self.context.exception.toString;
    if(self.context[@"__cctvInvoke"].isUndefined)return @"JS 插件入口无效";
    return nil;
}
- (void)finishCall:(NSString *)identifier answer:(NSString *)answer { void (^reply)(NSString *)=self.calls[identifier];[self.calls removeObjectForKey:identifier];if(reply)reply(answer); }
- (void)dispose {
    self.generation++;self.activeSession=nil;[self.session invalidateAndCancel];self.session=nil;
    [self.requests removeAllObjects];[self.timers removeAllObjects];self.context=nil;
    self.packageRoot=nil;self.genericMode=NO;
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
            NSString *failure=[self initializeContext];if(failure){[self dispose];answer=[self encodedError:failure];dispatch_semaphore_signal(done);return;}self.activeSession=session;
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
        dispatch_async(self.queue,^{[self.calls removeObjectForKey:identifier];});
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
