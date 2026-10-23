// Models process state only. The local HTTP fixture remains real.
#import "PyHost.h"
#import <objc/runtime.h>
static BOOL running, started;
static NSInteger port, starts;
@interface PyHost (SmokeProcess)
+ (BOOL)smokeRunning;
+ (BOOL)smokeStarted;
+ (NSInteger)smokePort;
+ (BOOL)smokeStart:(NSString *)path
              port:(NSInteger)value
           dataDir:(NSString *)directory
         arguments:(NSArray *)args
             error:(NSError **)error;
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
    port = value;
    starts++;
    return YES;
}
+ (NSInteger)smokeStartCount {
    return starts;
}
@end
