#import "LocalServiceReadiness.h"
#import <QuartzCore/QuartzCore.h>
#import "RuntimeDiagnostics.h"
@interface LocalServiceReadiness ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, assign) NSTimeInterval timeout;
@property(nonatomic, assign) NSTimeInterval started;
@property(nonatomic, assign) BOOL requiresHealthJSON;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, copy) NSString *probeID;
@property(nonatomic, assign, readwrite) NSUInteger attemptCount;
@property(nonatomic, assign) NSInteger lastHTTPStatus;
@property(nonatomic, assign) NSUInteger lastResponseBytes;
@property(nonatomic, copy) NSString *lastContentType;
@property(nonatomic, copy) NSString *lastErrorDomain;
@property(nonatomic, assign) NSInteger lastErrorCode;
@property(nonatomic, copy) NSString *lastFailureKind;
@property(nonatomic, copy) NSString *lastObservedFailureKind;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) void (^completion)(NSError *, NSTimeInterval);
- (void)recordProbe:(NSString *)event reason:(NSString *)reason;
@end
@implementation LocalServiceReadiness
- (instancetype)initWithURL:(NSURL *)url timeout:(NSTimeInterval)timeout requiresHealthJSON:(BOOL)health {
    if (self = [super init]) {
        _url = url;
        _timeout = MAX(0.1, timeout);
        _requiresHealthJSON = health;
        _probeID = NSUUID.UUID.UUIDString.lowercaseString;
        _lastErrorDomain = @"";
        _lastFailureKind = @"none";
        _lastContentType = @"";
    }
    return self;
}
- (void)start:(void (^)(NSError *, NSTimeInterval))completion {
    [self cancel];
    self.cancelled = NO;
    self.probeID = NSUUID.UUID.UUIDString.lowercaseString;
    self.attemptCount = 0;
    self.lastHTTPStatus = 0;
    self.lastResponseBytes = 0;
    self.lastContentType = @"";
    self.lastErrorDomain = @"";
    self.lastErrorCode = 0;
    self.lastFailureKind = @"none";
    self.lastObservedFailureKind = @"none";
    self.started = CACurrentMediaTime();
    self.completion = completion;
    [self recordProbe:@"local_service_probe_started" reason:@"requested"];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 1;
    config.timeoutIntervalForResource = 1;
    self.session = [NSURLSession sessionWithConfiguration:config];
    [self poll:self.generation];
}
- (NSDictionary<NSString *,id> *)diagnosticSummary {
    return @{@"probe_id":self.probeID?:@"unknown",
             @"probe_attempts":@(self.attemptCount),
             @"last_http_status":@(self.lastHTTPStatus),
             @"last_response_bytes":@(self.lastResponseBytes),
             @"last_content_type":self.lastContentType?:@"",
             @"requires_health_json":@(self.requiresHealthJSON),
             @"last_error_domain":self.lastErrorDomain?:@"",
             @"last_error_code":@(self.lastErrorCode),
             @"last_observed_failure_kind":self.lastObservedFailureKind?:@"unknown",
             @"last_failure_kind":self.lastFailureKind?:@"unknown"};
}
- (void)finish:(NSError *)error {
    if(!self.completion)return;
    [self recordProbe:@"local_service_probe_finished" reason:error?@"failed":@"ready"];
    void (^done)(NSError *, NSTimeInterval) = self.completion;
    self.completion = nil;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    if (done)
        done(error, CACurrentMediaTime() - self.started);
}
- (void)poll:(NSUInteger)generation {
    if (self.cancelled || generation != self.generation)
        return;
    NSError *startupError=self.failureProvider?self.failureProvider():nil;
    if(startupError){self.lastErrorDomain=startupError.domain?:@"";self.lastErrorCode=startupError.code;self.lastFailureKind=@"process_failed";[self finish:startupError];return;}
    NSTimeInterval remaining = self.timeout - (CACurrentMediaTime() - self.started);
    if (remaining <= 0) {
        self.lastFailureKind=@"probe_timeout";
        [self finish:[NSError errorWithDomain:@"CCTVHostService"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"本机服务未在等待时间内就绪，请查看服务日志。"
                                     }]];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.url];
    request.timeoutInterval = MIN(1, remaining);
    self.attemptCount++;
    __weak typeof(self) weakSelf = self;
    self.task = [self.session
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              __strong typeof(weakSelf) self = weakSelf;
              if (!self || self.cancelled || generation != self.generation)
                  return;
              self.lastHTTPStatus=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
              self.lastResponseBytes=data.length;
              self.lastContentType=response.MIMEType?:@"";
              self.lastErrorDomain=error.domain?:@"";
              self.lastErrorCode=error.code;
              BOOL ready = !error && self.lastHTTPStatus == 200;
              if(error)self.lastFailureKind=@"network_error";
              else if(self.lastHTTPStatus!=200)self.lastFailureKind=@"http_status";
              NSDictionary *healthJSON = nil;
              if (ready && self.requiresHealthJSON) {
                  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                  if ([json isKindOfClass:NSDictionary.class]) healthJSON = json;
                  ready = [healthJSON isKindOfClass:NSDictionary.class] &&
                          [healthJSON[@"ok"] isKindOfClass:NSNumber.class] && [healthJSON[@"ok"] boolValue];
                  if(!ready)self.lastFailureKind=@"invalid_health_response";
              }
              // The in-app media server intentionally listens before a Spider
              // finishes its remote init(). Wait on its cheap health endpoint
              // instead of hammering /capabilities with repeated 503 BUSY calls.
              if (ready && [healthJSON[@"media"] respondsToSelector:@selector(boolValue)] &&
                  [healthJSON[@"media"] boolValue] &&
                  [healthJSON[@"runtime_ready"] isKindOfClass:NSNumber.class] &&
                  ![healthJSON[@"runtime_ready"] boolValue]) {
                  NSString *runtimeState = [healthJSON[@"runtime_state"] isKindOfClass:NSString.class]
                      ? healthJSON[@"runtime_state"] : @"starting";
                  if ([runtimeState isEqualToString:@"failed"] || [runtimeState isEqualToString:@"stopping"]) {
                      NSString *detail = [healthJSON[@"startup_error"] isKindOfClass:NSString.class]
                          ? healthJSON[@"startup_error"] : @"未知错误";
                      self.lastFailureKind = [runtimeState isEqualToString:@"failed"] ? @"runtime_failed" : @"runtime_stopping";
                      [self finish:[NSError errorWithDomain:@"CCTVHostMediaRuntime"
                                                       code:[runtimeState isEqualToString:@"failed"] ? 2 : 3
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                       [runtimeState isEqualToString:@"failed"]
                                                           ? [NSString stringWithFormat:@"影视脚本初始化失败（%@），请查看该插件日志。", detail]
                                                           : @"影视资源正在停止，请重新打开后重试。"}]];
                      return;
                  }
                  ready = NO;
                  self.lastFailureKind = @"runtime_preparing";
              }
              self.lastObservedFailureKind=self.lastFailureKind;
              if (ready) {
                  self.lastFailureKind=@"none";self.lastObservedFailureKind=@"none";
                  self.lastErrorDomain=@"";
                  self.lastErrorCode=0;
                  [self finish:nil];
                  return;
              }
              NSTimeInterval pollInterval = [self.lastFailureKind isEqualToString:@"runtime_preparing"] ? 0.75 : 0.3;
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                               [weakSelf poll:generation];
                             });
            });
          }];
    [self.task resume];
}
- (void)cancel {
    [self cancelWithReason:@"superseded_or_page_exit"];
}
- (void)recordProbe:(NSString *)event reason:(NSString *)reason {
    NSMutableDictionary *fields=[[self diagnosticSummary] mutableCopy];
    for(NSString *key in @[@"service_id",@"correlation_id",@"trigger",@"engine"]){id value=self.diagnosticContext[key];if([value isKindOfClass:NSString.class]&&[value length]<=128)fields[key]=value;}
    fields[@"port"]=self.url.port?:@0;fields[@"reason"]=reason?:@"unknown";
    fields[@"elapsed_ms"]=@((NSInteger)(MAX(0,CACurrentMediaTime()-self.started)*1000));
    [RuntimeDiagnostics.shared recordEvent:event category:@"service" fields:fields];
}
- (void)cancelWithReason:(NSString *)reason {
    if(self.completion)[self recordProbe:@"local_service_probe_cancelled" reason:reason];
    self.generation++;
    self.cancelled = YES;
    self.completion = nil;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
}
- (void)dealloc {
    [self.task cancel];
    [self.session invalidateAndCancel];
}
@end
