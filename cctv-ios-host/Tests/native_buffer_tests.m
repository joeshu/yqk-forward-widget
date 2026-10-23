#import <Foundation/Foundation.h>
#import "NativeStartupTuner.h"
static void check(BOOL ok,NSString *why){if(!ok){NSLog(@"FAILED: %@",why);exit(1);}}
@interface TestConfig : NSObject <NSCopying>
@property(nonatomic) int startBufferDuration,highBufferDuration,maxBufferDuration,networkTimeout;
@property(nonatomic) BOOL isNeedUDRMDecrypt_pvt;
@property(nonatomic,copy) NSString *license,*referer;
@end
@implementation TestConfig
- (id)copyWithZone:(NSZone *)zone {
    TestConfig *c=[TestConfig new];c.startBufferDuration=self.startBufferDuration;c.highBufferDuration=self.highBufferDuration;
    c.maxBufferDuration=self.maxBufferDuration;c.networkTimeout=self.networkTimeout;c.isNeedUDRMDecrypt_pvt=self.isNeedUDRMDecrypt_pvt;
    c.license=self.license;c.referer=self.referer;return c;
}
@end
@interface CicadaPlayer : NSObject
@property(nonatomic,strong) TestConfig *config;
@property(nonatomic) BOOL reject;
@property(nonatomic) NSUInteger writes;
- (TestConfig *)getConfig;
- (void)setConfig:(TestConfig *)config;
@end
@implementation CicadaPlayer
- (instancetype)init {if(self=[super init]){_config=[TestConfig new];_config.startBufferDuration=500;_config.highBufferDuration=3000;_config.maxBufferDuration=20000;_config.networkTimeout=15000;_config.isNeedUDRMDecrypt_pvt=YES;_config.license=@"license";_config.referer=@"referer";}return self;}
- (TestConfig *)getConfig{return [self.config copy];}
- (void)setConfig:(TestConfig *)config {self.writes++;if(!self.reject)_config=[config copy];}
@end
@interface Wrapper : NSObject
@property(nonatomic,strong) id playerCore;
@end
@implementation Wrapper
@end
@interface WrongABI : NSObject
- (int)playerCore;
@end
@implementation WrongABI
- (int)playerCore{return 42;}
@end
int main(void){@autoreleasepool{
    CicadaPlayer *core=[CicadaPlayer new];Wrapper *inner=[Wrapper new],*outer=[Wrapper new];inner.playerCore=core;outer.playerCore=inner;
    NativeStartupTuner *tuner=[NativeStartupTuner new];
    check([tuner applyToPlayer:outer],@"nested SDK core resolved");
    check(core.config.startBufferDuration==150 && core.config.highBufferDuration==1000,@"startup thresholds applied in milliseconds");
    check(core.config.isNeedUDRMDecrypt_pvt && [core.config.license isEqual:@"license"] && [core.config.referer isEqual:@"referer"],@"DRM and headers survive tuning");
    check(core.config.maxBufferDuration==20000 && core.config.networkTimeout==15000,@"max buffer and timeout unchanged");
    check([tuner applyToPlayer:outer] && core.writes==1,@"duplicate setup does not rewrite config");
    core.config.license=@"renewed"; // SDK may update its config between setup and frame.
    check([tuner restore],@"steady buffers restored");
    check(core.config.startBufferDuration==500 && core.config.highBufferDuration==3000 && [core.config.license isEqual:@"renewed"],@"restore uses current config, preserves renewed license");
    check(![tuner restore] && core.writes==2,@"duplicate frame does not rewrite config");
    check(![[NativeStartupTuner new] applyToPlayer:[NSObject new]],@"unsupported core ignored");
    check(![[NativeStartupTuner new] applyToPlayer:[WrongABI new]],@"integer getter never called as object getter");
    core=[CicadaPlayer new];core.reject=YES;tuner=[NativeStartupTuner new];
    check(![tuner applyToPlayer:core],@"readback detects rejected config");
    check(core.config.startBufferDuration==500,@"rejected tuning leaves default intact");
    core=[CicadaPlayer new];core.config.startBufferDuration=100;core.config.highBufferDuration=200;tuner=[NativeStartupTuner new];
    check([tuner applyToPlayer:core] && core.config.startBufferDuration==100 && core.config.highBufferDuration==200,@"already smaller buffers never increased");
    check([tuner restore],@"nonstandard original values restored");
    core=[CicadaPlayer new];core.config.startBufferDuration=4000;core.config.highBufferDuration=3000;
    check(![[NativeStartupTuner new] applyToPlayer:core] && core.writes==0,@"invalid SDK buffer ordering ignored");
    __weak CicadaPlayer *released;
    tuner=[NativeStartupTuner new];
    @autoreleasepool {CicadaPlayer *temporary=[CicadaPlayer new];released=temporary;[tuner applyToPlayer:temporary];}
    check(released==nil && ![tuner restore],@"tuner does not retain retired decoder or write after stop");
    puts("buffer preservation and fallback checks passed");
}return 0;}
