#import "MediaAPIClient.h"
@interface MediaAPIClient ()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger port;
@end
@implementation MediaAPIClient
- (instancetype)initWithPort:(NSInteger)port {
    if((self=[super init])){_port=port;NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.timeoutIntervalForRequest=40;configuration.timeoutIntervalForResource=45;configuration.URLCache=nil;configuration.HTTPMaximumConnectionsPerHost=2;_session=[NSURLSession sessionWithConfiguration:configuration];}return self;
}
- (void)cancel { self.generation++;[self.task cancel];self.task=nil; }
- (void)dealloc { [self.task cancel];[self.session invalidateAndCancel]; }
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id,NSError *))completion {
    NSAssert(NSThread.isMainThread,@"Media client UI operations run on main thread");[self cancel];NSUInteger generation=self.generation;
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/api/v1/%@",(long)self.port,operation]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"POST";request.HTTPBody=[NSJSONSerialization dataWithJSONObject:arguments?:@{} options:0 error:NULL];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    __weak typeof(self) weakSelf=self;
    self.task=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *networkError){
        NSError *failure=networkError;id reply=nil;
        if(!failure && data.length && data.length<=2*1024*1024)reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:&failure];
        if(!failure && (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] boolValue])){
            id detail=[reply isKindOfClass:NSDictionary.class]?reply[@"error"]:nil;NSString *message=[detail isKindOfClass:NSDictionary.class]?detail[@"message"]:([detail isKindOfClass:NSString.class]?detail:nil);
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:2 userInfo:@{NSLocalizedDescriptionKey:message?:@"资源未返回有效结果，请查看插件日志"}];
        }
        id result=[reply isKindOfClass:NSDictionary.class]?reply[@"data"]:nil;
        dispatch_async(dispatch_get_main_queue(),^{MediaAPIClient *client=weakSelf;if(!client || client.generation!=generation)return;client.task=nil;if(completion)completion(result==NSNull.null?nil:result,failure);});
    }];[self.task resume];
}
@end
