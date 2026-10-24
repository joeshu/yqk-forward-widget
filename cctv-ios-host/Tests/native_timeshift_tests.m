#import <Foundation/Foundation.h>
#import <math.h>
#import "NativeTimeshiftSession.h"
static void check(BOOL ok,NSString *why){if(!ok){NSLog(@"FAILED: %@",why);exit(1);}}
static void drain(void){[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];}
@interface ShiftPlayer : NSObject
@property(nonatomic) double start,end;
@property(nonatomic) NSUInteger calls,liveCalls;
@property(nonatomic,copy) void (^completion)(BOOL);
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion;
- (void)backToLive;
@end
@implementation ShiftPlayer
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion{self.start=start;self.end=end;self.completion=completion;self.calls++;}
- (void)backToLive{self.liveCalls++;}
@end
@interface WrongShift : NSObject
- (void)seekToStartTime:(id)start endTime:(id)end completionHandler:(id)completion;
@end
@implementation WrongShift
- (void)seekToStartTime:(id)start endTime:(id)end completionHandler:(id)completion{abort();}
@end
int main(void){@autoreleasepool{
    ShiftPlayer *player=[ShiftPlayer new];NativeTimeshiftSession *session=[[NativeTimeshiftSession alloc] initWithPlayer:player];
    __block NSUInteger calls=0;__block BOOL last=NO;
    void (^completion)(BOOL,NSError *)=^(BOOL allowed,NSError *error){check(NSThread.isMainThread,@"completion on main thread");check(!error,@"no fabricated error");calls++;last=allowed;};
    check([session seekStart:940 end:0 now:1000 completion:completion],@"live timeshift accepted");
    check(player.start==940 && player.end==0 && player.calls==1,@"double time values passed exactly, end zero selects timeshift");
    player.completion(YES);player.completion(YES);drain();check(calls==1 && last,@"single successful completion");
    check([session seekStart:800 end:900 now:1000 completion:completion],@"bounded lookback accepted");
    check(player.start==800 && player.end==900,@"lookback range passed");
    player.completion(NO);drain();check(calls==2 && !last,@"copyright rejection propagated");
    check(![session seekStart:1001 end:0 now:1000 completion:completion],@"future start rejected");
    check(![session seekStart:NAN end:0 now:1000 completion:completion],@"NaN rejected");
    check(![session seekStart:900 end:800 now:1000 completion:completion],@"reversed range rejected");
    check(![session seekStart:900 end:1001 now:1000 completion:completion],@"future end rejected");
    check([session seekStart:900 end:0 now:1000 completion:completion],@"pending seek accepted");void (^old)(BOOL)=player.completion;
    [session cancel];old(YES);drain();check(calls==2,@"cancelled callback ignored");
    [session seekStart:900 end:0 now:1000 completion:completion];old=player.completion;
    check([session backToLive] && player.liveCalls==1,@"SDK back-to-live called once");old(YES);drain();check(calls==2,@"back to live invalidates pending seek");
    WrongShift *wrongPlayer=[WrongShift new];NativeTimeshiftSession *wrong=[[NativeTimeshiftSession alloc] initWithPlayer:wrongPlayer];
    check(![wrong seekStart:900 end:0 now:1000 completion:completion],@"object ABI rejected before SDK call");
    check(![wrong backToLive],@"unsupported return-to-live rejected");
    puts("native timeshift ABI and lifecycle checks passed");
}return 0;}
