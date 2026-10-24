#import "NodePluginRuntime.h"
#include <dlfcn.h>
#include <stdlib.h>

@interface NodePluginRuntime ()
@property(nonatomic) BOOL launched;
@property(atomic, copy) NSString *bootError;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *activeSessions;
@property(nonatomic, strong) NSMutableSet<NSString *> *startingSessions;
@property(nonatomic, strong) NSMutableSet<NSString *> *confirmedSessions;
@property(nonatomic, strong) NSMutableSet<NSString *> *uncertainSessions;
@property(nonatomic, copy) NSString *infoPath;
@property(nonatomic, copy) NSString *token;
@property(atomic) NSInteger controlPort;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSString *)> *sessionLogHandlers;
@end
@implementation NodePluginRuntime
+ (instancetype)shared {static NodePluginRuntime *runtime;static dispatch_once_t once;dispatch_once(&once,^{runtime=[self new];});return runtime;}
- (instancetype)init {if((self=[super init])){_activeSessions=[NSMutableDictionary dictionary];_startingSessions=[NSMutableSet set];_confirmedSessions=[NSMutableSet set];_uncertainSessions=[NSMutableSet set];_sessionLogHandlers=[NSMutableDictionary dictionary];}return self;}
- (void)setLogHandler:(void (^)(NSString *))handler forServiceIdentifier:(NSString *)identifier {@synchronized(self){if(identifier.length&&handler)self.sessionLogHandlers[identifier]=[handler copy];else if(identifier.length)[self.sessionLogHandlers removeObjectForKey:identifier];}}
- (NSArray<NSString *> *)activeSessionIdentifiers {@synchronized(self){NSMutableOrderedSet *ids=[NSMutableOrderedSet orderedSet];for(NSString *session in self.confirmedSessions){NSString *serviceID=self.activeSessions[session];if(serviceID.length)[ids addObject:serviceID];}return ids.array.copy?:@[];}}
- (NSArray<NSString *> *)managedServiceIdentifiers {@synchronized(self){return [NSSet setWithArray:self.activeSessions.allValues].allObjects;}}
- (BOOL)hasActivePlugin {@synchronized(self){return self.confirmedSessions.count>0;}}
- (BOOL)isRunningSession:(NSString *)identifier {@synchronized(self){return identifier.length&&[self.confirmedSessions containsObject:identifier];}}
- (BOOL)isManagedSession:(NSString *)identifier {@synchronized(self){return identifier.length&&self.activeSessions[identifier]!=nil;}}
- (BOOL)isRunningServiceIdentifier:(NSString *)identifier {@synchronized(self){if(!identifier.length)return NO;for(NSString *session in self.confirmedSessions)if([self.activeSessions[session] isEqual:identifier])return YES;return NO;}}
- (BOOL)isStartingServiceIdentifier:(NSString *)identifier {@synchronized(self){if(!identifier.length)return NO;for(NSString *session in self.startingSessions)if([self.activeSessions[session] isEqual:identifier])return YES;return NO;}}
- (BOOL)hasUncertainSessionForServiceIdentifier:(NSString *)identifier {@synchronized(self){if(!identifier.length)return NO;for(NSString *session in self.uncertainSessions)if([self.activeSessions[session] isEqual:identifier])return YES;return NO;}}
- (void)markStartUncertain:(NSString *)session {@synchronized(self){if(self.activeSessions[session]){[self.startingSessions removeObject:session];[self.uncertainSessions addObject:session];}}}
- (void)removeManagedSession:(NSString *)session {@synchronized(self){[self.activeSessions removeObjectForKey:session];[self.startingSessions removeObject:session];[self.confirmedSessions removeObject:session];[self.uncertainSessions removeObject:session];}}
- (BOOL)boot:(NSError **)error {
    NSAssert(!NSThread.isMainThread,@"Node boots on a background worker");
    @synchronized(self){
        if(!self.launched){
            NSString *framework=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"NodeMobile.framework/NodeMobile"];
            NSString *script=[NSBundle.mainBundle pathForResource:@"node-plugin-host" ofType:@"cjs"];
            if(![NSFileManager.defaultManager fileExistsAtPath:framework] || !script){if(error)*error=[self error:@"此构建未包含 Node.js Mobile 本机运行时"];return NO;}
            self.launched=YES;self.infoPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".node.json"]];self.token=[NSUUID.UUID.UUIDString stringByAppendingString:NSUUID.UUID.UUIDString];
            NSString *root=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Services"];
            [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
            NSArray *arguments=@[@"node",script,self.infoPath,self.token,root];
            [NSThread detachNewThreadWithBlock:^{@autoreleasepool {
                void *library=dlopen(framework.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
                if(!library){self.bootError=@"Node.js Mobile 框架无法加载";return;}
                int (*start)(int,char **)=(int (*)(int,char **))dlsym(library,"node_start");
                if(!start){self.bootError=@"Node.js Mobile 缺少 node_start 入口";return;}
                char **argv=calloc(arguments.count+1,sizeof(char *));for(NSUInteger index=0;index<arguments.count;index++)argv[index]=strdup([arguments[index] UTF8String]);
                int result=start((int)arguments.count,argv);
                for(NSUInteger index=0;index<arguments.count;index++)free(argv[index]);free(argv);
                self.bootError=[NSString stringWithFormat:@"Node 运行时已结束（%d），请重启 App",result];
            }}];
            NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=35;configuration.HTTPMaximumConnectionsPerHost=8;
            self.session=[NSURLSession sessionWithConfiguration:configuration];
        }
    }
    for(NSUInteger attempt=0;attempt<500;attempt++){
        if(self.bootError.length){if(error)*error=[self error:self.bootError];return NO;}
        if(self.controlPort)return YES;
        NSData *data=[NSData dataWithContentsOfFile:self.infoPath];id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if([value isKindOfClass:NSDictionary.class] && [value[@"port"] integerValue]>0){@synchronized(self){self.controlPort=[value[@"port"] integerValue];}return YES;}
        [NSThread sleepForTimeInterval:.02];
    }
    if(error)*error=[self error:@"Node 运行时启动尚未完成，请稍后重试"];return NO;
}
- (NSString *)callOperation:(NSString *)operation json:(NSString *)json error:(NSError **)error {
    if(NSThread.isMainThread){if(error)*error=[self error:@"Node 服务须从后台调用"];return nil;}
    if(![self boot:error])return nil;
    NSData *input=[json dataUsingEncoding:NSUTF8StringEncoding];id payload=input?[NSJSONSerialization JSONObjectWithData:input options:0 error:NULL]:nil;if(![payload isKindOfClass:NSDictionary.class]){if(error)*error=[self error:@"Node 请求参数无效"];return nil;}
    NSString *session=payload[@"session"];
    if(![session isKindOfClass:NSString.class] || !session.length){if(error)*error=[self error:@"Node 会话标识无效"];return nil;}
    if([operation isEqual:@"start"]){
        NSString *root=[payload[@"packageRoot"] isKindOfClass:NSString.class]?payload[@"packageRoot"]:nil;
        NSString *allowed=[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Services"] stringByAppendingString:@"/"];
        if(!root.length || ![[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path hasPrefix:allowed]){if(error)*error=[self error:@"Node 入口不在已安装资源目录中"];return nil;}
        NSString *serviceID=[payload[@"serviceID"] isKindOfClass:NSString.class]?payload[@"serviceID"]:session;
        @synchronized(self){if(self.activeSessions[session]){if(error)*error=[self error:@"该 Node 会话已运行或启动结果待确认，请先停止后重试"];return nil;}self.activeSessions[session]=serviceID;[self.startingSessions addObject:session];} // Reserve before I/O so a timed-out start remains stoppable.
    }else if([operation isEqual:@"stop"] && ![self isManagedSession:session])return @"{\"ok\":true,\"result\":true}";
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/control",(long)self.controlPort]]];request.HTTPMethod=@"POST";[request setValue:self.token forHTTPHeaderField:@"X-CCTVHost-Token"];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"operation":operation,@"payload":payload} options:0 error:error];if(!request.HTTPBody){if([operation isEqual:@"start"])[self removeManagedSession:session];return nil;}
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *body;__block NSError *failure;
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *networkError){body=data;failure=networkError;dispatch_semaphore_signal(done);}];[task resume];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,36*NSEC_PER_SEC))!=0){[task cancel];if([operation isEqual:@"start"]||[operation isEqual:@"stop"])[self markStartUncertain:session];if(error)*error=[self error:@"Node 操作超时；会话结果未知，可尝试停止后重试"];return nil;}
    if(failure || body.length>2*1024*1024 || !body.length){if([operation isEqual:@"start"]||[operation isEqual:@"stop"])[self markStartUncertain:session];if(error)*error=failure?:[self error:@"Node 返回结果无效或过大"];return nil;}
    id reply=[NSJSONSerialization JSONObjectWithData:body options:0 error:error];if(![reply isKindOfClass:NSDictionary.class]){if([operation isEqual:@"start"]||[operation isEqual:@"stop"])[self markStartUncertain:session];return nil;}
    if([operation isEqual:@"start"]){if([reply[@"ok"] boolValue]){@synchronized(self){[self.startingSessions removeObject:session];[self.uncertainSessions removeObject:session];[self.confirmedSessions addObject:session];}}else [self removeManagedSession:session];}
    else if([operation isEqual:@"stop"]&&[reply[@"ok"] boolValue])[self removeManagedSession:session];
    NSString *logIdentifier=[payload[@"serviceID"] isKindOfClass:NSString.class]?payload[@"serviceID"]:session;void(^logger)(NSString *)=nil;@synchronized(self){logger=[self.sessionLogHandlers[logIdentifier] copy]?:[self.logHandler copy];}
    if([reply[@"logs"] isKindOfClass:NSArray.class] && logger)for(id line in reply[@"logs"])if([line isKindOfClass:NSString.class])logger(line);
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
}
- (BOOL)stopWithError:(NSError **)error {
    NSArray *sessions=nil;@synchronized(self){sessions=self.activeSessions.allKeys.copy;}BOOL result=YES;NSError *first=nil;
    for(NSString *session in sessions){NSError *failure=nil;if(![self stopSession:session error:&failure]){result=NO;if(!first)first=failure;}}
    if(!result&&error)*error=first;return result;
}
- (BOOL)stopSession:(NSString *)session error:(NSError **)error {
    if(!session.length)return YES;
    if(![self isManagedSession:session])return YES;
    NSString *serviceID=nil;@synchronized(self){serviceID=self.activeSessions[session];}
    NSMutableDictionary *body=[@{@"session":session} mutableCopy];if(serviceID.length)body[@"serviceID"]=serviceID;
    NSData *payload=[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSError *failure=nil;NSString *reply=[self callOperation:@"stop" json:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] error:&failure];
    id value=reply?[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;
    BOOL stopped=[value isKindOfClass:NSDictionary.class] && [value[@"ok"] boolValue];
    if(!stopped && error){NSString *message=[value isKindOfClass:NSDictionary.class] && [value[@"error"] isKindOfClass:NSString.class]?value[@"error"]:@"Node 插件尚未停止";*error=failure?:[self error:message];}
    return stopped;
}
- (BOOL)stopSessionsForServiceIdentifier:(NSString *)identifier error:(NSError **)error {
    NSArray *sessions=nil;@synchronized(self){NSMutableArray *values=[NSMutableArray array];for(NSString *session in self.activeSessions)if([self.activeSessions[session] isEqual:identifier])[values addObject:session];sessions=values.copy;}
    BOOL success=YES;NSError *first=nil;for(NSString *session in sessions){NSError *failure=nil;if(![self stopSession:session error:&failure]){success=NO;if(!first)first=failure;}}
    if(!success&&error)*error=first;return success;
}
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostNode" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
@end
