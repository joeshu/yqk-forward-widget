#import "MediaChannelProbe.h"
#import "MediaPlaybackHeaders.h"
#import <QuartzCore/QuartzCore.h>

static const NSUInteger MediaChannelProbeByteLimit = 8192;
static const NSUInteger MediaChannelProbeSegmentByteLimit = 65536;

@interface MediaChannelProbe () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,copy) void (^completion)(NSDictionary<NSString *,id> *);
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *customHeaders;
@property(nonatomic,strong) NSMutableData *buffer;
@property(nonatomic,copy) NSString *contentType;
@property(nonatomic,strong) NSURL *finalURL;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic) CFTimeInterval responseAt;
@property(nonatomic) NSUInteger byteCount;
@property(nonatomic) NSUInteger byteLimit;
@property(nonatomic) NSInteger statusCode;
@property(nonatomic) NSUInteger redirectCount;
@property(nonatomic) BOOL probingSegment;
@property(nonatomic) double manifestRequestMs;
@property(nonatomic) BOOL finished;
- (void)startRequestForURL:(NSURL *)url rangeLimit:(NSUInteger)limit;
@end

static NSURL *MediaChannelProbeExtractFirstHLSSegment(NSString *playlist, NSURL *baseURL) {
    if (!playlist.length || !baseURL) return nil;
    __block NSURL *found = nil;
    [playlist enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!trimmed.length || [trimmed hasPrefix:@"#"]) return;
        NSURL *resolved = [NSURL URLWithString:trimmed relativeToURL:baseURL].absoluteURL;
        NSString *scheme = resolved.scheme.lowercaseString;
        if (resolved.host.length && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
            found = resolved;
            *stop = YES;
        }
    }];
    return found;
}

@implementation MediaChannelProbe
- (void)startWithURL:(NSURL *)url completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    [self startWithURL:url headers:nil completion:completion];
}

- (void)startWithURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary<NSString *,id> *))completion {
    NSAssert(NSThread.isMainThread, @"Channel probes are started on the main thread");
    NSString *scheme=url.scheme.lowercaseString;
    if(!url.host.length||(![scheme isEqual:@"http"]&&![scheme isEqual:@"https"])){
        if(completion)completion(@{@"ok":@NO,@"status":@0,@"requestMs":@0,@"sampleBytes":@0,@"sampleKBps":@0});
        return;
    }
    self.completion=completion;
    self.customHeaders=headers.count?MediaPlaybackHeadersFromResult(@{@"headers":headers}):@{};
    self.buffer=[NSMutableData data];
    self.byteLimit=MediaChannelProbeByteLimit;
    self.probingSegment=NO;
    self.startedAt=CACurrentMediaTime();
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=3.0;
    configuration.timeoutIntervalForResource=4.0;
    configuration.HTTPMaximumConnectionsPerHost=1;
    configuration.URLCache=nil;
    configuration.HTTPCookieStorage=nil;
    configuration.HTTPShouldSetCookies=NO;
    self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    [self startRequestForURL:url rangeLimit:self.byteLimit];
}

- (void)startRequestForURL:(NSURL *)url rangeLimit:(NSUInteger)limit {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    request.HTTPMethod=@"GET";
    request.HTTPShouldHandleCookies=NO;
    for(NSString *key in self.customHeaders){
        [request setValue:self.customHeaders[key] forHTTPHeaderField:key];
    }
    if(![request valueForHTTPHeaderField:@"User-Agent"])[request setValue:@"CCTVHost/1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"bytes=0-%lu",(unsigned long)(limit-1)] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request];
    @synchronized(self){
        self.task=task;
    }
    [task resume];
}

- (void)dealloc {[self cancel];}
- (void)cancel {
    NSURLSessionDataTask *task=nil;
    NSURLSession *session=nil;
    @synchronized(self){
        if(self.finished)return;
        self.finished=YES;
        task=self.task;
        session=self.session;
        self.completion=nil;self.task=nil;self.session=nil;self.buffer=nil;
    }
    [task cancel];
    [session invalidateAndCancel];
}
- (void)finishWithError:(NSError *)error {
    void (^completion)(NSDictionary *)=nil;
    NSURLSession *session=nil;
    NSDictionary *result=nil;
    @synchronized(self){
        if(self.finished)return;
        self.finished=YES;
        BOOL ok=!error&&self.statusCode>=200&&self.statusCode<300;
        double requestMs=self.manifestRequestMs>0?self.manifestRequestMs:(self.responseAt>0?MAX(0,(self.responseAt-self.startedAt)*1000.0):MAX(0,(CACurrentMediaTime()-self.startedAt)*1000.0));
        double elapsed=self.responseAt>0?MAX(0.001,CACurrentMediaTime()-self.responseAt):MAX(0.001,CACurrentMediaTime()-self.startedAt);
        double sampleKBps=self.byteCount>0?(self.byteCount/1024.0)/elapsed:0;
        NSMutableDictionary *dict=[@{@"ok":@(ok),@"status":@(self.statusCode),@"requestMs":@(requestMs),@"sampleBytes":@(self.byteCount),@"sampleKBps":@(sampleKBps),@"error":@(error!=nil)} mutableCopy];
        if(self.contentType.length)dict[@"contentType"]=self.contentType;
        if(self.buffer.length>0&&!self.probingSegment){
            dict[@"headerBytes"]=[self.buffer subdataWithRange:NSMakeRange(0,MIN(self.buffer.length,(NSUInteger)512))];
        }
        result=dict.copy;
        completion=self.completion;
        self.completion=nil;
        session=self.session;
        self.session=nil;self.task=nil;self.buffer=nil;
    }
    [session finishTasksAndInvalidate];
    if(completion){if(NSThread.isMainThread)completion(result);else dispatch_async(dispatch_get_main_queue(),^{completion(result);});}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger code=0;
    @synchronized(self){
        if(task!=self.task){completionHandler(NSURLSessionResponseCancel);return;}
        if([response isKindOfClass:NSHTTPURLResponse.class])self.statusCode=[(NSHTTPURLResponse *)response statusCode];
        self.responseAt=CACurrentMediaTime();
        if(!self.probingSegment){
            self.contentType=response.MIMEType?:@"";
            self.finalURL=response.URL;
        }
        code=self.statusCode;
    }
    if(code<200||code>=300){completionHandler(NSURLSessionResponseCancel);[self finishWithError:nil];return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    BOOL reachedLimit=NO;
    NSURL *nextSegmentURL=nil;
    @synchronized(self){
        if(task!=self.task)return;
        NSUInteger remaining=self.byteLimit>self.byteCount?(self.byteLimit-self.byteCount):0;
        NSUInteger toTake=MIN(remaining,data.length);
        if(toTake>0&&!self.probingSegment&&self.buffer.length<MediaChannelProbeByteLimit){
            [self.buffer appendBytes:data.bytes length:MIN(toTake,MediaChannelProbeByteLimit-self.buffer.length)];
        }
        self.byteCount+=toTake;
        reachedLimit=(self.byteCount>=self.byteLimit);
        if(reachedLimit&&!self.probingSegment&&self.buffer.length>=7){
            NSString *prefix=[[NSString alloc] initWithData:self.buffer encoding:NSUTF8StringEncoding];
            if([prefix containsString:@"#EXTM3U"]){
                nextSegmentURL=MediaChannelProbeExtractFirstHLSSegment(prefix,self.finalURL);
                if(nextSegmentURL){
                    self.probingSegment=YES;
                    self.manifestRequestMs=self.responseAt>0?MAX(0,(self.responseAt-self.startedAt)*1000.0):0;
                    self.byteCount=0;
                    self.byteLimit=MediaChannelProbeSegmentByteLimit;
                    self.startedAt=CACurrentMediaTime();
                    self.responseAt=0;
                    self.redirectCount=0;
                }
            }
        }
    }
    if(nextSegmentURL){
        [task cancel];
        [self startRequestForURL:nextSegmentURL rangeLimit:MediaChannelProbeSegmentByteLimit];
        return;
    }
    if(reachedLimit){[task cancel];[self finishWithError:nil];}
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *target=request.URL;
    NSString *scheme=target.scheme.lowercaseString;
    NSUInteger redirects=0;
    NSUInteger currentLimit=MediaChannelProbeByteLimit;
    @synchronized(self){
        if(task!=self.task){completionHandler(nil);return;}
        self.redirectCount++;
        redirects=self.redirectCount;
        currentLimit=self.byteLimit;
    }
    if(redirects>5||!target.host.length||(![scheme isEqual:@"http"]&&![scheme isEqual:@"https"])||([response.URL.scheme.lowercaseString isEqual:@"https"]&&[scheme isEqual:@"http"])){
        completionHandler(nil);[self finishWithError:nil];return;
    }
    NSMutableURLRequest *safe=[request mutableCopy];
    safe.HTTPMethod=@"GET";
    safe.HTTPBody=nil;
    safe.HTTPShouldHandleCookies=NO;
    NSDictionary *scoped=MediaPlaybackHeadersScopedToURL(self.customHeaders?:@{},response.URL,target);
    for(NSString *header in @[@"Authorization",@"Proxy-Authorization",@"Cookie",@"Referer",@"Origin",@"X-API-Key",@"X-Auth",@"X-Session"])[safe setValue:nil forHTTPHeaderField:header];
    for(NSString *k in scoped)[safe setValue:scoped[k] forHTTPHeaderField:k];
    if(![safe valueForHTTPHeaderField:@"User-Agent"])[safe setValue:@"CCTVHost/1" forHTTPHeaderField:@"User-Agent"];
    [safe setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [safe setValue:[NSString stringWithFormat:@"bytes=0-%lu",(unsigned long)(currentLimit-1)] forHTTPHeaderField:@"Range"];
    completionHandler(safe);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSURL *nextSegmentURL=nil;
    @synchronized(self){
        if(self.finished||task!=self.task)return;
        if(!error&&!self.probingSegment&&self.statusCode>=200&&self.statusCode<300&&self.buffer.length>=7){
            NSString *prefix=[[NSString alloc] initWithData:self.buffer encoding:NSUTF8StringEncoding];
            if([prefix containsString:@"#EXTM3U"]){
                nextSegmentURL=MediaChannelProbeExtractFirstHLSSegment(prefix,self.finalURL);
                if(nextSegmentURL){
                    self.probingSegment=YES;
                    self.manifestRequestMs=self.responseAt>0?MAX(0,(self.responseAt-self.startedAt)*1000.0):0;
                    self.byteCount=0;
                    self.byteLimit=MediaChannelProbeSegmentByteLimit;
                    self.startedAt=CACurrentMediaTime();
                    self.responseAt=0;
                    self.redirectCount=0;
                }
            }
        }
    }
    if(nextSegmentURL){
        [self startRequestForURL:nextSegmentURL rangeLimit:MediaChannelProbeSegmentByteLimit];
        return;
    }
    [self finishWithError:error];
}
@end
