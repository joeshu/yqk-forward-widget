// Behavioral SDK fixture only: this does not verify proprietary Cicada decoding.
#import "CicadaSDK.h"
#import "MediaPlaybackCicadaAdapter.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>
@interface CicadaConfig ()
@property(nonatomic) int startBufferDuration;
@property(nonatomic) int highBufferDuration;
@property(nonatomic) int maxBufferDuration;
@end
@implementation CicadaConfig
@end
@implementation CicadaUrlSource
- (instancetype)urlWithString:(NSString *)url{return self;}
@end
static CicadaPlayer *lastPlayer;
static CicadaConfig *lastConfig;
static NSUInteger starts;
@implementation CicadaPlayer
- (instancetype)init {if((self=[super init]))lastPlayer=self;return self;}
- (void)setConfig:(CicadaConfig *)config{lastConfig=config;}
- (void)setUrlSource:(CicadaUrlSource *)source{}
- (void)prepare{}
- (void)start{starts++;}
- (void)pause{}
- (void)stop{}
- (void)destroy{}
- (void)seekToTime:(int64_t)time seekMode:(CicadaSeekMode)mode{}
@end
@implementation CicadaPlayerView
@end
@implementation CicadaErrorModel
@end
@interface MediaPlaybackCicadaAdapter (Probe)
- (void)onPlayerEvent:(id)player eventType:(NSUInteger)type;
- (void)onVideoSizeChanged:(id)player width:(int)width height:(int)height rotation:(int)rotation;
- (void)onVideoRendered:(id)player timeMs:(int64_t)time pts:(int64_t)pts;
- (void)onError:(id)player errorModel:(id)error;
- (void)onPlayerStatusChanged:(id)player oldStatus:(NSInteger)oldStatus newStatus:(NSInteger)newStatus;
@end
@interface CicadaProbe : NSObject <MediaPlaybackCicadaAdapterDelegate>
@property(nonatomic,strong) MediaPlaybackCicadaAdapter *adapter;
@property(nonatomic,copy) void (^completion)(BOOL,NSString *);
@property(nonatomic) NSUInteger prepared;
@property(nonatomic) NSUInteger first;
@property(nonatomic) NSUInteger failures;
@property(nonatomic) NSUInteger seeks;
@property(nonatomic) NSUInteger completions;
@end
@implementation CicadaProbe
- (void)cicadaAdapterDidPrepare:(id)adapter{self.prepared++;}
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter{self.first++;}
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error{self.failures++;}
- (void)cicadaAdapterDidComplete:(id)adapter{self.completions++;}
- (void)finish:(BOOL)passed message:(NSString *)message{[self.adapter destroy];self.completion(passed,message);self.adapter=nil;}
- (void)run {
    starts=0;self.adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.test/video.mkv"] headers:@{} networkTimeout:10];self.adapter.delegate=self;
    // The host applies gravity before prepare; it must survive SDK creation.
    [self.adapter applyVideoGravity:AVLayerVideoGravityResizeAspectFill];
    [self.adapter prepare];[self.adapter start];
    lastPlayer.currentPosition=400001000;lastPlayer.duration=500002000;
    if(lastPlayer.scalingMode!=CICADA_SCALINGMODE_SCALEASPECTFILL||fabs(self.adapter.currentPosition-400001)>0.01||fabs(self.adapter.duration-500002)>0.01){[self finish:NO message:@"Gravity or long-running time unit contract failed"];return;}
    [self.adapter setRate:NAN];
    if(!isfinite(self.adapter.rate)){[self finish:NO message:@"Nonfinite playback rate reached SDK"];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(starts||self.prepared){[self finish:NO message:@"Cicada started before prepare callback"];return;}
        [self.adapter pause];[self.adapter onPlayerEvent:lastPlayer eventType:0];
        dispatch_async(dispatch_get_main_queue(),^{
            if(starts||self.prepared!=1){[self finish:NO message:@"Pause during preparation was lost"];return;}
            [self.adapter start];[self.adapter onVideoSizeChanged:lastPlayer width:320 height:180 rotation:0];
            dispatch_async(dispatch_get_main_queue(),^{
                if(starts!=1||self.first){[self finish:NO message:@"Video size counted as rendered frame"];return;}
                [self.adapter onVideoRendered:lastPlayer timeMs:1 pts:1];
                dispatch_async(dispatch_get_main_queue(),^{
                    if(self.first!=1||lastConfig.startBufferDuration>lastConfig.highBufferDuration||lastConfig.highBufferDuration>lastConfig.maxBufferDuration){[self finish:NO message:@"Cicada buffer/first-frame contract failed"];return;}
                    [self.adapter seekToTime:12 completion:^(BOOL finished){if(finished)self.seeks++;}];
                    [self.adapter onPlayerEvent:lastPlayer eventType:6];
                    CicadaErrorModel *error=[CicadaErrorModel new];error.code=0x20040001;error.message=@"fixture decoder error";[self.adapter onError:lastPlayer errorModel:error];
                    dispatch_async(dispatch_get_main_queue(),^{if(self.seeks!=1||self.failures!=1){[self finish:NO message:@"Cicada seek/error contract failed"];return;}[self runTerminalChecks];});
                });
            });
        });
    });
}
- (void)runTerminalChecks {
    // Late render/status/completion events cannot revive a failed engine.
    [self.adapter onPlayerEvent:lastPlayer eventType:2];
    [self.adapter onPlayerEvent:lastPlayer eventType:3];
    [self.adapter onPlayerStatusChanged:lastPlayer oldStatus:3 newStatus:4];
    dispatch_async(dispatch_get_main_queue(),^{
        if(self.adapter.state!=MediaPlaybackCicadaAdapterStateFailed||self.completions||self.first!=1||self.adapter.loading){[self finish:NO message:@"Late SDK events revived failed adapter"];return;}
        [self.adapter destroy];
        self.adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.test/stopped.mkv"] headers:nil networkTimeout:10];self.adapter.delegate=self;
        [self.adapter prepare];
        __block NSUInteger cancellations=0;
        [self.adapter seekToTime:10 completion:^(BOOL finished){if(!finished)cancellations++;}];
        [self.adapter stop];
        [self.adapter onPlayerEvent:lastPlayer eventType:0];
        [self.adapter onPlayerEvent:lastPlayer eventType:2];
        [self.adapter onPlayerEvent:lastPlayer eventType:3];
        dispatch_async(dispatch_get_main_queue(),^{
            if(cancellations!=1||self.adapter.state!=MediaPlaybackCicadaAdapterStateIdle||self.prepared!=1||self.first!=1||self.completions){[self finish:NO message:@"Stop did not cancel seek or suppress late callbacks"];return;}
            [self.adapter destroy];
            self.adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.test/destroyed.mkv"] headers:nil networkTimeout:10];
            [self.adapter prepare];
            [self.adapter seekToTime:10 completion:^(BOOL finished){if(!finished)cancellations++;}];
            [self.adapter destroy];[self.adapter destroy];
            if(cancellations!=2){[self finish:NO message:@"Destroy did not cancel pending seek exactly once"];return;}
            [self runSeekAfterCompletionCheck];
        });
    });
}
- (void)runSeekAfterCompletionCheck {
    self.adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.test/completed.mkv"] headers:nil networkTimeout:10];self.adapter.delegate=self;
    [self.adapter prepare];
    [self.adapter onPlayerEvent:lastPlayer eventType:0];
    [self.adapter onPlayerEvent:lastPlayer eventType:3];
    dispatch_async(dispatch_get_main_queue(),^{
        if(self.adapter.state!=MediaPlaybackCicadaAdapterStateCompleted){[self finish:NO message:@"Fixture did not reach completion"];return;}
        NSUInteger startsBeforeSeek=starts;
        __block BOOL seekFinished=NO;
        [self.adapter seekToTime:5 completion:^(BOOL finished){seekFinished=finished;}];
        [self.adapter onPlayerEvent:lastPlayer eventType:6];
        dispatch_async(dispatch_get_main_queue(),^{
            BOOL passed=seekFinished&&starts==startsBeforeSeek&&self.adapter.state==MediaPlaybackCicadaAdapterStatePaused;
            if(!passed){[self finish:NO message:@"Seek after completion failed or auto-started"];return;}
            [self runStartAfterCompletionCheck];
        });
    });
}
- (void)runStartAfterCompletionCheck {
    [self.adapter onPlayerEvent:lastPlayer eventType:3];
    dispatch_async(dispatch_get_main_queue(),^{
        if(self.adapter.state!=MediaPlaybackCicadaAdapterStateCompleted){[self finish:NO message:@"Fixture did not return to completion"];return;}
        NSUInteger startsBefore=starts,completionsBefore=self.completions;
        [self.adapter start];
        if(self.adapter.state!=MediaPlaybackCicadaAdapterStatePlaying||starts!=startsBefore+1){[self finish:NO message:@"Explicit start did not leave completion state"];return;}
        [self.adapter onPlayerEvent:lastPlayer eventType:3];
        dispatch_async(dispatch_get_main_queue(),^{
            BOOL passed=self.adapter.state==MediaPlaybackCicadaAdapterStateCompleted&&self.completions==completionsBefore+1;
            [self finish:passed message:@"Controlled DEX, AVPlayer rendering and Cicada adapter lifecycle verified"];
        });
    });
}
@end
void RunCicadaAdapterProbe(void (^completion)(BOOL,NSString *)){CicadaProbe *probe=[CicadaProbe new];probe.completion=completion;[probe run];}
