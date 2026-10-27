#import "LocalServiceReadiness.h"
#import "PlaybackStartupTrace.h"
#import <Foundation/Foundation.h>
// The production recorder depends on UIKit/MetricKit. This standalone macOS
// harness supplies a diagnostic sink while exercising the real readiness code.
static NSMutableArray *probeEvents;
@interface RuntimeDiagnostics : NSObject
+ (instancetype)shared;
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary *)fields;
@end
@implementation RuntimeDiagnostics
+ (instancetype)shared {static RuntimeDiagnostics *sink;static dispatch_once_t once;dispatch_once(&once,^{sink=[self new];probeEvents=[NSMutableArray array];});return sink;}
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary *)fields {[probeEvents addObject:@{@"event":event,@"fields":fields?:@{}}];}
@end
static void check(BOOL ok, NSString *why) {
    if (!ok) {
        NSLog(@"FAILED: %@", why);
        exit(1);
    }
}
static void spinUntil(BOOL (^done)(void), NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        check(argc == 2, @"fixture port supplied");
        NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%s", argv[1]];
        PlaybackStartupTrace *trace = [[PlaybackStartupTrace alloc] initWithStartTime:100];
        check([trace record:@"itemReady" atTime:101], @"ready stage recorded");
        check(!trace.stages[@"frame"], @"ready is not a video frame");
        check(![trace record:@"itemReady" atTime:102], @"duplicates do not reset timing");
        check(![trace record:@"vdn" atTime:99], @"backwards timestamps rejected");
        check([trace record:@"frame" atTime:103.5], @"video stage recorded separately");
        check([trace.stages[@"frame"] doubleValue] == 3.5, @"end-to-end frame time correct");
        check([trace.summary containsString:@"itemReady=1.00s"] &&
                  [trace.summary containsString:@"frame=3.50s"],
              @"summary keeps distinct stages");
        PlaybackStartupTrace *stalled=[[PlaybackStartupTrace alloc] initWithStartTime:100];
        check(![stalled shouldRecoverMissingSetupAtTime:120 alreadyRetried:NO failed:NO], @"no retry before VDN success");
        [stalled record:@"vdn" atTime:102];
        check(![stalled shouldRecoverMissingSetupAtTime:107.9 alreadyRetried:NO failed:NO], @"allow VDN to finish creating core");
        check([stalled shouldRecoverMissingSetupAtTime:108 alreadyRetried:NO failed:NO], @"recover missing setup after grace period");
        check(![stalled shouldRecoverMissingSetupAtTime:120 alreadyRetried:YES failed:NO], @"at most one startup recovery");
        check(![stalled shouldRecoverMissingSetupAtTime:120 alreadyRetried:NO failed:YES], @"do not bypass failure or authentication rejection");
        [stalled record:@"setup" atTime:103];
        check(![stalled shouldRecoverMissingSetupAtTime:120 alreadyRetried:NO failed:NO], @"buffering after setup is not missing core");
        __block BOOL done = NO;
        __block NSInteger calls = 0;
        LocalServiceReadiness *ready = [[LocalServiceReadiness alloc]
                   initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/ready"]]
                       timeout:4
            requiresHealthJSON:YES];
        [ready start:^(NSError *error, NSTimeInterval elapsed) {
          check(NSThread.isMainThread, @"completion on main");
          check(!error, @"eventual readiness succeeds");
          check(elapsed >= 0.5, @"503 and JSON ok=false cannot start playback");
          calls++;
          done = YES;
        }];
        spinUntil(
            ^BOOL {
              return done;
            },
            5);
        check(done && calls == 1, @"one successful completion");
        done = NO;
        calls = 0;
        LocalServiceReadiness *timeout = [[LocalServiceReadiness alloc]
                   initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/never"]]
                       timeout:0.5
            requiresHealthJSON:YES];
        [timeout start:^(NSError *error, NSTimeInterval elapsed) {
          check(error != nil, @"unready service reports error");
          check(elapsed < 1.5, @"deadline bounded");
          calls++;
          done = YES;
        }];
        spinUntil(
            ^BOOL {
              return done;
            },
            2);
        check(done && calls == 1, @"timeout exactly once");
        __block BOOL cancelledCalled = NO;
        LocalServiceReadiness *cancelled = [[LocalServiceReadiness alloc]
                   initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/never"]]
                       timeout:0.1
            requiresHealthJSON:YES];
        [cancelled start:^(NSError *error, NSTimeInterval elapsed) {
          cancelledCalled = YES;
        }];
        [cancelled cancel];
        spinUntil(
            ^BOOL {
              return NO;
            },
            0.5);
        check(!cancelledCalled, @"cancelled attempt cannot resume playback");
        check(probeEvents.count==6,@"each readiness start has exactly one success, failure or cancellation");
        check([probeEvents[0][@"event"] isEqual:@"local_service_probe_started"]&&[probeEvents[1][@"event"] isEqual:@"local_service_probe_finished"],@"ready probe has complete lifecycle");
        check([probeEvents[3][@"fields"][@"reason"] isEqual:@"failed"]&&[probeEvents[5][@"event"] isEqual:@"local_service_probe_cancelled"],@"timeout and cancellation remain distinct");
        for(NSUInteger index=0;index<6;index+=2)check([probeEvents[index][@"fields"][@"probe_id"] isEqual:probeEvents[index+1][@"fields"][@"probe_id"]],@"probe lifecycle retains its ID");
        NSLog(@"Startup readiness, cancellation and timing checks passed");
    }
    return 0;
}
