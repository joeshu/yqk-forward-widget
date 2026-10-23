#import "LocalServiceReadiness.h"
#import <QuartzCore/QuartzCore.h>
@interface LocalServiceReadiness ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, assign) NSTimeInterval timeout;
@property(nonatomic, assign) NSTimeInterval started;
@property(nonatomic, assign) BOOL requiresHealthJSON;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, assign) NSUInteger generation;
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
    }
    return self;
}
- (void)start:(void (^)(NSError *, NSTimeInterval))completion {
    [self cancel];
    self.cancelled = NO;
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
    NSTimeInterval remaining = self.timeout - (CACurrentMediaTime() - self.started);
    if (remaining <= 0) {
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
    __weak typeof(self) weakSelf = self;
    self.task = [self.session
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              __strong typeof(weakSelf) self = weakSelf;
              if (!self || self.cancelled || generation != self.generation)
                  return;
              BOOL ready = !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
                           [(NSHTTPURLResponse *)response statusCode] == 200;
              if (ready && self.requiresHealthJSON) {
                  id json =
                      data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                  ready = [json isKindOfClass:NSDictionary.class] &&
                          [json[@"ok"] isKindOfClass:NSNumber.class] && [json[@"ok"] boolValue];
              }
              if (ready) {
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
