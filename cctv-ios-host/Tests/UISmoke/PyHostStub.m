// Models process state only. The local HTTP fixture remains real.
#import "PyHost.h"
#import <objc/runtime.h>
static BOOL running, started;
static NSInteger port, starts;
static NSString *runningIdentifier;
@interface PyHost (SmokeProcess)
+ (BOOL)smokeRunning;
+ (BOOL)smokeStarted;
+ (NSInteger)smokePort;
+ (BOOL)smokeStart:(NSString *)path
              port:(NSInteger)value
           dataDir:(NSString *)directory
         arguments:(NSArray *)args
             error:(NSError **)error;
+ (BOOL)smokeStart:(NSString *)path identifier:(NSString *)identifier port:(NSInteger)value dataDir:(NSString *)directory arguments:(NSArray *)args error:(NSError **)error;
+ (BOOL)smokeIsRunningServiceIdentifier:(NSString *)identifier;
+ (BOOL)smokeStopServiceIdentifier:(NSString *)identifier error:(NSError **)error;
@end
@implementation PyHost (SmokeProcess)
+ (void)load {
    method_exchangeImplementations(class_getClassMethod(self, @selector(running)),
                                   class_getClassMethod(self, @selector(smokeRunning)));
    method_exchangeImplementations(class_getClassMethod(self, @selector(startedOnce)),
                                   class_getClassMethod(self, @selector(smokeStarted)));
    method_exchangeImplementations(class_getClassMethod(self, @selector(port)),
                                   class_getClassMethod(self, @selector(smokePort)));
    method_exchangeImplementations(
        class_getClassMethod(self, @selector(startScriptAtPath:port:dataDir:arguments:error:)),
        class_getClassMethod(self, @selector(smokeStart:port:dataDir:arguments:error:)));
    method_exchangeImplementations(
        class_getClassMethod(self, @selector(startScriptAtPath:identifier:port:dataDir:arguments:error:)),
        class_getClassMethod(self, @selector(smokeStart:identifier:port:dataDir:arguments:error:)));
    method_exchangeImplementations(class_getClassMethod(self, @selector(isRunningServiceIdentifier:)),
                                   class_getClassMethod(self, @selector(smokeIsRunningServiceIdentifier:)));
    method_exchangeImplementations(class_getClassMethod(self, @selector(stopServiceIdentifier:error:)),
                                   class_getClassMethod(self, @selector(smokeStopServiceIdentifier:error:)));
}
+ (BOOL)smokeRunning {
    return running;
}
+ (BOOL)smokeStarted {
    return started;
}
+ (NSInteger)smokePort {
    return port;
}
+ (BOOL)smokeStart:(NSString *)path
              port:(NSInteger)value
           dataDir:(NSString *)directory
         arguments:(NSArray *)args
             error:(NSError **)error {
    if (started)
        return NO;
    running = YES;
    started = YES;
    runningIdentifier = path.lastPathComponent;
    port = value;
    starts++;
    return YES;
}
+ (BOOL)smokeStart:(NSString *)path identifier:(NSString *)identifier port:(NSInteger)value dataDir:(NSString *)directory arguments:(NSArray *)args error:(NSError **)error {
    if (running) return [runningIdentifier isEqualToString:identifier];
    running = YES;started = YES;runningIdentifier=[identifier copy];port=value;starts++;return YES;
}
+ (BOOL)smokeIsRunningServiceIdentifier:(NSString *)identifier {return running&&[runningIdentifier isEqualToString:identifier];}
+ (BOOL)smokeStopServiceIdentifier:(NSString *)identifier error:(NSError **)error {if(![runningIdentifier isEqualToString:identifier])return YES;running=NO;started=NO;runningIdentifier=nil;return YES;}
+ (NSInteger)smokeStartCount {
    return starts;
}
@end
