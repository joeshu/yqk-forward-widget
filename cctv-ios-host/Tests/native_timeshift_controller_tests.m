#import <Foundation/Foundation.h>
#import "CCTVTimeshiftController.h"
#import "NativeTimeshiftSession.h"
static void check(BOOL ok,NSString *why){if(!ok){NSLog(@"FAILED: %@",why);exit(1);}}
static void drain(NSTimeInterval seconds){[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];}

// 模拟 SDK 播放器：时移 seek + 返回直播 + 版权预检。
@interface TimeshiftPlayer : NSObject
@property(nonatomic) double start,end;
@property(nonatomic) NSUInteger seekCalls,liveCalls,checkCalls;
@property(nonatomic) BOOL checkPublic; // 预检返回值
@property(nonatomic,copy) void (^seekCompletion)(BOOL);
@property(nonatomic,copy) void (^checkCompletion)(BOOL,id,NSError *);
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion;
- (void)backToLive;
- (void)checkPublicPlaytime:(double)playTime completionBlock:(void (^)(BOOL,id,NSError *))completionBlock;
@end
@implementation TimeshiftPlayer
- (instancetype)init{self=[super init];if(self)_checkPublic=YES;return self;}
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion{self.start=start;self.end=end;self.seekCompletion=completion;self.seekCalls++;}
- (void)backToLive{self.liveCalls++;}
- (void)checkPublicPlaytime:(double)playTime completionBlock:(void (^)(BOOL,id,NSError *))completionBlock{self.checkCalls++;self.checkCompletion=completionBlock;if(completionBlock)completionBlock(self.checkPublic,nil,nil);}
@end
// 无 checkPublicPlaytime：预检应跳过、直接 seek。
@interface NoCheckPlayer : NSObject
@property(nonatomic) NSUInteger seekCalls;
@property(nonatomic,copy) void (^seekCompletion)(BOOL);
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion;
- (void)backToLive;
@end
@implementation NoCheckPlayer
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion{self.seekCompletion=completion;self.seekCalls++;}
- (void)backToLive{}
@end
// 无 backToLive：返回直播应走宿主回退。
@interface NoLivePlayer : NSObject
@property(nonatomic) NSUInteger seekCalls;
@property(nonatomic,copy) void (^seekCompletion)(BOOL);
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion;
- (void)checkPublicPlaytime:(double)playTime completionBlock:(void (^)(BOOL,id,NSError *))completionBlock;
@end
@implementation NoLivePlayer
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion{self.seekCompletion=completion;self.seekCalls++;}
- (void)checkPublicPlaytime:(double)playTime completionBlock:(void (^)(BOOL,id,NSError *))completionBlock{if(completionBlock)completionBlock(YES,nil,nil);}
@end
int main(void){@autoreleasepool{
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    // 1. 防抖：连续两次请求只执行最后一次。
    TimeshiftPlayer *player=[TimeshiftPlayer new];
    CCTVTimeshiftController *controller=[[CCTVTimeshiftController alloc] initWithPlayer:player];
    __block NSUInteger completions=0;__block BOOL lastOK=NO;__block NSError *lastError=nil;
    void (^completion)(BOOL,NSError *)=^(BOOL ok,NSError *error){completions++;lastOK=ok;lastError=error;};
    [controller requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    [controller requestSeekToStart:now-120 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);
    check(player.seekCalls==1 && player.start==now-120,@"debounce keeps only the latest seek");
    check(player.checkCalls==1,@"copyright pre-check runs once for the debounced seek");
    player.seekCompletion(YES);drain(0.05);
    check(completions==1 && lastOK,@"seek accepted completion delivered once");
    check(controller.seekLatency>0,@"seek latency recorded");
    [controller noteLoadState:5]; // SeekSucceed
    check(controller.state==CCTVTimeshiftStatePlayingReplay,@"SeekSucceed moves to PlayingReplay");
    check(controller.seekFirstFrameLatency>0,@"seek first-frame latency recorded");
    // 2. 周期 tick 更新距直播。
    __block NSTimeInterval behind=0;__block NSTimeInterval position=0;
    controller.onProgress=^(NSTimeInterval b,NSTimeInterval p){behind=b;position=p;};
    [controller notePeriodicTick];
    check(behind>0 && position>0 && fabs(behind-position)<1.0,@"periodic tick reports behind-live and position");
    // 3. 回看中卡顿计数。
    [controller noteLoadState:11]; // Stalled
    check(controller.stallCount==1,@"stall during replay counted");
    [controller noteLoadState:12]; // StalledRecovery
    // 4. 播放中版权变动 → 失败并通知宿主。
    __block NSError *failure=nil;controller.onFailure=^(NSError *e){failure=e;};
    [controller noteCopyrightChanged:NO error:nil];
    check(controller.state==CCTVTimeshiftStateFailed && failure.code==4,@"copyright loss during replay fails with NoCopyright");
    // 5. 版权预检拒绝：不发 seek，直接失败。
    TimeshiftPlayer *blocked=[TimeshiftPlayer new];blocked.checkPublic=NO;
    CCTVTimeshiftController *blockedController=[[CCTVTimeshiftController alloc] initWithPlayer:blocked];
    completions=0;lastError=nil;
    [blockedController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);
    check(blocked.seekCalls==0 && completions==1 && !lastOK && lastError.code==4,@"copyright rejection fails fast without issuing a seek");
    // 6. 版权缓存：同一节目第二次 seek 不重复校验。
    TimeshiftPlayer *cached=[TimeshiftPlayer new];
    CCTVTimeshiftController *cachedController=[[CCTVTimeshiftController alloc] initWithPlayer:cached];
    completions=0;
    [cachedController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);cached.seekCompletion(YES);drain(0.05);
    [cachedController cancel];
    [cachedController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);
    check(cached.checkCalls==1 && cached.seekCalls==2,@"copyright check cached for the same program");
    // 7. 瞬时失败重试一次（预检通过时）。
    TimeshiftPlayer *flaky=[TimeshiftPlayer new];
    CCTVTimeshiftController *flakyController=[[CCTVTimeshiftController alloc] initWithPlayer:flaky];
    completions=0;lastOK=NO;
    [flakyController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);check(flaky.seekCalls==1,@"first seek issued");
    flaky.seekCompletion(NO);drain(0.05);
    check(flaky.seekCalls==2,@"transient rejection retried once on the same player");
    flaky.seekCompletion(YES);drain(0.05);
    check(completions==1 && lastOK,@"retry success completes once");
    // 8. 无预检接口：跳过预检、直接 seek。
    NoCheckPlayer *nocheck=[NoCheckPlayer new];
    CCTVTimeshiftController *nocheckController=[[CCTVTimeshiftController alloc] initWithPlayer:nocheck];
    completions=0;
    [nocheckController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.5);
    check(nocheck.seekCalls==1,@"player without checkPublicPlaytime still seeks (fail-open)");
    // 9. 返回直播回退：无 backToLive 时走宿主回退。
    NoLivePlayer *nolive=[NoLivePlayer new];
    CCTVTimeshiftController *noliveController=[[CCTVTimeshiftController alloc] initWithPlayer:nolive];
    __block BOOL fallback=NO;noliveController.onReturnToLiveFallback=^{fallback=YES;};
    [noliveController returnToLive];
    check(fallback && noliveController.state==CCTVTimeshiftStateFailed,@"unsupported backToLive falls back to host re-play");
    // 10. 返回直播成功 + 取消丢弃旧回调。
    TimeshiftPlayer *live=[TimeshiftPlayer new];
    CCTVTimeshiftController *liveController=[[CCTVTimeshiftController alloc] initWithPlayer:live];
    completions=0;
    [liveController requestSeekToStart:now-60 end:0 channelID:@"cctv1" completion:completion];
    [liveController cancel];drain(0.5);
    check(live.seekCalls==0 && completions==0,@"cancel during debounce drops the seek");
    [liveController returnToLive];
    check(live.liveCalls==1 && liveController.state==CCTVTimeshiftStateReturningToLive,@"backToLive issued");
    [liveController noteReturnedToLive];
    check(liveController.state==CCTVTimeshiftStateIdle,@"returned-to-live resets to idle");
    // 11. 无效范围直接拒绝。
    completions=0;lastError=nil;
    [liveController requestSeekToStart:now+60 end:0 channelID:@"cctv1" completion:completion];
    drain(0.05);
    check(completions==1 && !lastOK && lastError.code==2 && live.seekCalls==0,@"future start rejected without a seek");
    puts("native timeshift controller checks passed");
}return 0;}
