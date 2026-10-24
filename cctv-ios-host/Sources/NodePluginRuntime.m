#import "NodePluginRuntime.h"
#include <dlfcn.h>
#include <stdlib.h>

@interface NodePluginRuntime ()
@property(nonatomic) BOOL launched;
@property(atomic, copy) NSString *bootError;
@property(atomic, copy) NSString *activeSession;
@property(nonatomic, copy) NSString *infoPath;
@property(nonatomic, copy) NSString *token;
@property(atomic) NSInteger controlPort;
@property(nonatomic, strong) NSURLSession *session;
@end
@implementation NodePluginRuntime
+ (instancetype)shared {static NodePluginRuntime *runtime;static dispatch_once_t once;dispatch_once(&once,^{runtime=[self new];});return runtime;}
- (BOOL)hasActivePlugin {return self.activeSession.length>0;}
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
        if(self.activeSession.length && ![self.activeSession isEqual:session]){if(error)*error=[self error:@"旧 Node 插件仍在运行或停止中"];return nil;}
        self.activeSession=session; // Reserve before I/O; a timed-out start must still be cleaned up.
    }else if([operation isEqual:@"stop"] && ![self.activeSession isEqual:session])return @"{\"ok\":true,\"result\":true}";
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/control",(long)self.controlPort]]];request.HTTPMethod=@"POST";[request setValue:self.token forHTTPHeaderField:@"X-CCTVHost-Token"];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"operation":operation,@"payload":payload} options:0 error:error];if(!request.HTTPBody)return nil;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *body;__block NSError *failure;
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *networkError){body=data;failure=networkError;dispatch_semaphore_signal(done);}];[task resume];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,36*NSEC_PER_SEC))!=0){[task cancel];if(error)*error=[self error:@"Node 插件调用超时，未假报停止"];return nil;}
    if(failure || body.length>2*1024*1024 || !body.length){if(error)*error=failure?:[self error:@"Node 返回结果无效或过大"];return nil;}
    id reply=[NSJSONSerialization JSONObjectWithData:body options:0 error:error];if(![reply isKindOfClass:NSDictionary.class])return nil;
    if([reply[@"ok"] boolValue]){if([operation isEqual:@"start"])self.activeSession=session;else if([operation isEqual:@"stop"] && [session isEqual:self.activeSession])self.activeSession=nil;}
    if([reply[@"logs"] isKindOfClass:NSArray.class] && self.logHandler)for(id line in reply[@"logs"])if([line isKindOfClass:NSString.class])self.logHandler(line);
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
}
- (BOOL)stopWithError:(NSError **)error {
    NSString *session=self.activeSession;if(!session.length)return YES;
    NSData *payload=[NSJSONSerialization dataWithJSONObject:@{@"session":session} options:0 error:NULL];
    NSError *failure=nil;NSString *reply=[self callOperation:@"stop" json:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] error:&failure];
    id value=reply?[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:nil;
    BOOL stopped=[value isKindOfClass:NSDictionary.class] && [value[@"ok"] boolValue];
    if(!stopped && error){NSString *message=[value isKindOfClass:NSDictionary.class] && [value[@"error"] isKindOfClass:NSString.class]?value[@"error"]:@"Node 插件尚未停止";*error=failure?:[self error:message];}
    return stopped;
}
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostNode" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
@end
