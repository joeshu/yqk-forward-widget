// Behavioral SDK fixture only: this does not verify proprietary Cicada decoding.
#import "CicadaSDK.h"
#import "MediaPlaybackCicadaAdapter.h"
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
@end
@interface CicadaProbe : NSObject <MediaPlaybackCicadaAdapterDelegate>
@property(nonatomic,strong) MediaPlaybackCicadaAdapter *adapter;
@property(nonatomic,copy) void (^completion)(BOOL,NSString *);
@property(nonatomic) NSUInteger prepared;
@property(nonatomic) NSUInteger first;
@property(nonatomic) NSUInteger failures;
@property(nonatomic) NSUInteger seeks;
@end
@implementation CicadaProbe
- (void)cicadaAdapterDidPrepare:(id)adapter{self.prepared++;}
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter{self.first++;}
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error{self.failures++;}
- (void)finish:(BOOL)passed message:(NSString *)message{[self.adapter destroy];self.completion(passed,message);self.adapter=nil;}
- (void)run {
    starts=0;self.adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.test/video.mkv"] headers:@{} networkTimeout:10];self.adapter.delegate=self;
    [self.adapter prepare];[self.adapter start];
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
                    dispatch_async(dispatch_get_main_queue(),^{[self finish:self.seeks==1&&self.failures==1 message:@"Controlled DEX, AVPlayer rendering and Cicada adapter behavior verified"];});
                });
            });
        });
    });
}
@end
void RunCicadaAdapterProbe(void (^completion)(BOOL,NSString *)){CicadaProbe *probe=[CicadaProbe new];probe.completion=completion;[probe run];}
