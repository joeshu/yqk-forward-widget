#import "JSPluginRuntime.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <Security/Security.h>
#include <math.h>

static NSUInteger const JSMaxBody = 1024 * 1024;
@interface JSPluginRuntime () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) JSContext *context;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableDictionary *> *requests;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, JSValue *> *timers;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSString *)> *calls;
@property(nonatomic, strong) NSURL *scriptURL;
@property(nonatomic, strong) NSURLSessionConfiguration *networkConfiguration;
@property(nonatomic, copy) NSString *activeSession;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) NSUInteger generation;
@end
@implementation JSPluginRuntime
+ (instancetype)shared { static JSPluginRuntime *r; static dispatch_once_t once; dispatch_once(&once, ^{ r=[self new]; }); return r; }
- (instancetype)init { return [self initWithScriptURL:nil configuration:nil]; }
- (instancetype)initWithScriptURL:(NSURL *)url configuration:(NSURLSessionConfiguration *)configuration { if((self=[super init])) { _scriptURL=url;_networkConfiguration=configuration; _queue=dispatch_queue_create("cctvhost.javascript", DISPATCH_QUEUE_SERIAL);_requests=[NSMutableDictionary dictionary];_timers=[NSMutableDictionary dictionary];_calls=[NSMutableDictionary dictionary]; } return self; }
- (void)log:(NSString *)text { @autoreleasepool { if(text.length>4096)text=[text substringToIndex:4096];if(self.logHandler)self.logHandler(text); } }
- (BOOL)allowedURL:(NSURL *)url {
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
    NSURL *target=[NSURL URLWithString:url];
    if(![self allowedURL:target] || self.requests.count>=8){[callback callWithArguments:@[@{@"error":@"JS 网络地址不受支持或并发已满"}]];return key;}
    NSData *bytes=[options dataUsingEncoding:NSUTF8StringEncoding];NSDictionary *opts=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
    if(![opts isKindOfClass:NSDictionary.class])opts=@{};
    if(opts[@"method"] && ![opts[@"method"] isEqual:@"GET"]){[callback callWithArguments:@[@{@"error":@"此提取器桥接仅支持 GET"}]];return key;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    NSDictionary *headers=opts[@"headers"];
    if([headers isKindOfClass:NSDictionary.class])for(NSString *name in headers){
        if([name isKindOfClass:NSString.class] && [headers[name] isKindOfClass:NSString.class] &&
           [@[@"accept",@"user-agent",@"referer",@"content-type"] containsObject:name.lowercaseString])
            [request setValue:headers[name] forHTTPHeaderField:name];
    }
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request];
    self.requests[key]=[@{@"callback":callback,@"task":task,@"data":[NSMutableData data]} mutableCopy];
    [task resume];return key;
}
- (NSNumber *)keyForTask:(NSURLSessionTask *)task { for(NSNumber *key in self.requests)if(self.requests[key][@"task"]==task)return key;return nil; }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSNumber *key=[self keyForTask:task];
    if(!key || response.expectedContentLength>(long long)JSMaxBody || ![response isKindOfClass:NSHTTPURLResponse.class]){
        completion(NSURLSessionResponseCancel);if(key)[self fetchFinished:key error:@"JS 上游响应过大或无效"];return;
    }
    self.requests[key][@"response"]=response;completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSNumber *key=[self keyForTask:task];if(!key)return;
    NSMutableData *body=self.requests[key][@"data"];
    if(body.length+data.length>JSMaxBody){[task cancel];[self fetchFinished:key error:@"JS 上游响应超过 1MB"];return;}[body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key=[self keyForTask:task];if(key)[self fetchFinished:key error:error.localizedDescription];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL allowed=[self allowedURL:request.URL] && task.countOfBytesReceived<JSMaxBody;
    completion(allowed?request:nil);
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
    NSString *path=self.scriptURL.path?:[NSBundle.mainBundle pathForResource:@"yangshipin.bundle" ofType:@"js"];
    NSString *source=path?[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]:nil;
    if(!source.length)return @"未找到央视频 JS 包";
    [self.context evaluateScript:source withSourceURL:[NSURL fileURLWithPath:path]];
    if(self.context.exception)return self.context.exception.toString;
    if(self.context[@"__cctvInvoke"].isUndefined)return @"JS 插件入口无效";
    return nil;
}
- (void)finishCall:(NSString *)identifier answer:(NSString *)answer { void (^reply)(NSString *)=self.calls[identifier];[self.calls removeObjectForKey:identifier];if(reply)reply(answer); }
- (void)dispose {
    self.generation++;self.activeSession=nil;[self.session invalidateAndCancel];self.session=nil;
    [self.requests removeAllObjects];[self.timers removeAllObjects];self.context=nil;
    for(NSString *key in self.calls.allKeys)[self finishCall:key answer:@"{\"ok\":false,\"error\":\"JS 服务已停止\"}"];
}
- (NSString *)callOperation:(NSString *)operation json:(NSString *)json timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if(NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:1 userInfo:@{NSLocalizedDescriptionKey:@"JS 服务须从后台调用"}];return nil;}
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
        dispatch_async(self.queue,^{[self.calls removeObjectForKey:identifier];});
        if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:2 userInfo:@{NSLocalizedDescriptionKey:@"JS 插件调用超时"}];return nil;
    }
    return answer;
}
- (NSString *)encodedError:(NSString *)message {NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"ok":@NO,@"error":message?:@"JS 错误"} options:0 error:NULL];return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];}
@end
