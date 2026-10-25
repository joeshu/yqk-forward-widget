#import "LocalServiceReadiness.h"
#import <QuartzCore/QuartzCore.h>
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
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) void (^completion)(NSError *, NSTimeInterval);
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
    self.started = CACurrentMediaTime();
    self.completion = completion;
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
             @"last_failure_kind":self.lastFailureKind?:@"unknown"};
}
- (void)finish:(NSError *)error {
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
              if (ready && self.requiresHealthJSON) {
                  id json =
                      data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                  ready = [json isKindOfClass:NSDictionary.class] &&
                          [json[@"ok"] isKindOfClass:NSNumber.class] && [json[@"ok"] boolValue];
                  if(!ready)self.lastFailureKind=@"invalid_health_response";
              }
              if (ready) {
                  self.lastFailureKind=@"none";
                  self.lastErrorDomain=@"";
                  self.lastErrorCode=0;
                  [self finish:nil];
                  return;
              }
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                               [weakSelf poll:generation];
                             });
            });
          }];
    [self.task resume];
}
- (void)cancel {
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
