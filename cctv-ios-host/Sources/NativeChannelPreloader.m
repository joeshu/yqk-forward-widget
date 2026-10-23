#import "NativeChannelPreloader.h"
#import <objc/runtime.h>

@protocol CCTVMetadataPlayer <NSObject>
@property(nonatomic) BOOL autoPlay;
@property(nonatomic,weak) id delegate;
- (BOOL)playLIVEWithChannelID:(NSString *)channel delegate:(id)delegate configOptions:(NSDictionary *)options;
- (void)prepareRateItemToPlay_completionBlock:(void (^)(BOOL isPublic,NSError *error))completion;
- (void)reset;
@end
@interface NativeChannelPreloader ()
@property(nonatomic,copy) id (^factory)(void);
@property(nonatomic,copy) NSTimeInterval (^clock)(void);
@property(nonatomic,strong) id<CCTVMetadataPlayer> player;
@property(nonatomic,copy) NSString *channel;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL ready;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation NativeChannelPreloader
- (instancetype)initWithFactory:(id (^)(void))factory clock:(NSTimeInterval (^)(void))clock {
    if(self=[super init]){
        _factory=[factory copy];_clock=[clock copy];
        Protocol *protocol=NSProtocolFromString(@"CNPlayerCallbackProtocol");
        if(protocol)class_addProtocol(self.class,protocol);
    }return self;
}
- (void)prepareChannel:(NSString *)channel title:(NSString *)title {
    [self cancel];if(!channel.length)return;
    id<CCTVMetadataPlayer> player=self.factory();
    for(NSString *selector in @[@"playLIVEWithChannelID:delegate:configOptions:",@"prepareRateItemToPlay_completionBlock:",@"setAutoPlay:",@"setDelegate:",@"reset"])
        if(![player respondsToSelector:NSSelectorFromString(selector)])return;
    self.player=player;self.channel=channel;self.deadline=self.clock()+15;
    NSUInteger generation=self.generation;NSTimeInterval started=self.clock();
    @try {
        player.autoPlay=NO;
        if(![player playLIVEWithChannelID:channel delegate:self configOptions:@{@"CNPlayerConfigOptionKey_Title":title?:channel}]){[self cancel];return;}
        player.autoPlay=NO;
        __weak typeof(self) weakSelf=self;
        [player prepareRateItemToPlay_completionBlock:^(BOOL isPublic,NSError *error){
            dispatch_async(dispatch_get_main_queue(),^{
                NativeChannelPreloader *owner=weakSelf;
                if(!owner || generation!=owner.generation)return;
                if(error || !isPublic || owner.clock()>=owner.deadline){[owner cancel];return;}
                owner.ready=YES;
                if(owner.onLog)owner.onLog([NSString stringWithFormat:@"原生预解析 %@ 完成 %.2fs（未启动视频）",channel,owner.clock()-started]);
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            NativeChannelPreloader *owner=weakSelf;
            if(owner && generation==owner.generation)[owner cancel];
        });
    } @catch(NSException *exception){[self cancel];}
}
- (id)takeChannel:(NSString *)channel {
    if(!self.ready || ![self.channel isEqualToString:channel] || self.clock()>=self.deadline){[self cancel];return nil;}
    id<CCTVMetadataPlayer> player=self.player;
    // Transfer ownership WITHOUT reset/stop/reconfiguration, preserving CNPlayerItem.
    self.generation++;self.player=nil;self.channel=nil;self.ready=NO;
    player.delegate=nil;
    return player;
}
- (void)cancel {
    self.generation++;self.ready=NO;self.channel=nil;
    id<CCTVMetadataPlayer> player=self.player;self.player=nil;
    @try{player.delegate=nil;[player reset];}@catch(NSException *exception){}
}
- (void)dealloc { [self cancel]; }
// Defensive: metadata preparation is never allowed to create a second video session.
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self player:player statEvent:event value:value];});return;}
    if(event==3 && player==self.player)[self cancel];
}
@end
