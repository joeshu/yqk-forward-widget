#import "NativeStartupTuner.h"
#import <objc/message.h>

@protocol CCTVBufferConfig <NSObject>
@property(nonatomic) int startBufferDuration;
@property(nonatomic) int highBufferDuration;
@end
@protocol CCTVConfigurableCore <NSObject>
- (id<CCTVBufferConfig>)getConfig;
- (void)setConfig:(id<CCTVBufferConfig>)config;
@end

@interface NativeStartupTuner ()
@property(nonatomic, weak) id<CCTVConfigurableCore> core;
@property(nonatomic) int originalStart;
@property(nonatomic) int originalHigh;
@property(nonatomic) BOOL applied;
@property(nonatomic, copy, readwrite) NSString *summary;
@end
@implementation NativeStartupTuner
// CNPlayer -> CNLiveCicadaPlayer -> CicadaPlayer. Reject unknown return ABIs.
- (id)coreFromPlayer:(id)player {
    Class coreClass=NSClassFromString(@"CicadaPlayer");
    for(NSUInteger depth=0;player && depth<3;depth++) {
        if(coreClass && [player isKindOfClass:coreClass])return player;
        SEL selector=NSSelectorFromString(@"playerCore");
        NSMethodSignature *signature=[player methodSignatureForSelector:selector];
        if(!signature || signature.numberOfArguments!=2 || signature.methodReturnType[0]!='@')return nil;
        player=((id (*)(id,SEL))objc_msgSend)(player,selector);
    }
    return nil;
}
- (id<CCTVBufferConfig>)configForCore:(id)core {
    if(![core respondsToSelector:@selector(getConfig)] || ![core respondsToSelector:@selector(setConfig:)])return nil;
    id config=[core getConfig];
    for(NSString *name in @[@"startBufferDuration",@"highBufferDuration",@"setStartBufferDuration:",@"setHighBufferDuration:"])
        if(![config respondsToSelector:NSSelectorFromString(name)])return nil;
    return config;
}
- (BOOL)applyToPlayer:(id)player {
    if(self.applied)return YES;
    @try {
        id<CCTVConfigurableCore> core=[self coreFromPlayer:player];
        id<CCTVBufferConfig> config=[self configForCore:core];
        if(!config){self.summary=@"当前内核不支持起播缓冲配置，保留 SDK 默认值";return NO;}
        self.originalStart=config.startBufferDuration;self.originalHigh=config.highBufferDuration;
        if(self.originalStart<=0 || self.originalHigh<self.originalStart){self.summary=@"缓冲参数不兼容，保留 SDK 默认值";return NO;}
        self.core=core;
        // Milliseconds. Only reduce thresholds during startup; retain max buffer,
        // timeout, URL headers, hardware decoding and every DRM/license field.
        int start=MIN(self.originalStart,150),high=MAX(start,MIN(self.originalHigh,1000));
        config.startBufferDuration=start;config.highBufferDuration=high;
        self.applied=YES;[core setConfig:config];
        id<CCTVBufferConfig> effective=[self configForCore:core];
        if(!effective || effective.startBufferDuration!=start || effective.highBufferDuration!=high){
            [self restore];self.summary=@"SDK 未接受缓冲配置，已尝试恢复默认值";return NO;
        }
        self.summary=[NSString stringWithFormat:@"起播缓冲 %d→%d ms · 再缓冲 %d→%d ms（首帧后恢复）",self.originalStart,start,self.originalHigh,high];
        return YES;
    } @catch(NSException *exception) {
        [self restore];self.summary=@"起播缓冲配置不可用，保留 SDK 播放流程";return NO;
    }
}
- (BOOL)restore {
    if(!self.applied)return NO;
    @try {
        id<CCTVBufferConfig> config=[self configForCore:self.core];
        if(!config)return NO;
        config.startBufferDuration=self.originalStart;config.highBufferDuration=self.originalHigh;
        [self.core setConfig:config];
        id<CCTVBufferConfig> effective=[self configForCore:self.core];
        BOOL restored=effective && effective.startBufferDuration==self.originalStart && effective.highBufferDuration==self.originalHigh;
        if(restored)self.applied=NO;
        return restored;
    } @catch(NSException *exception) {return NO;}
}
@end
