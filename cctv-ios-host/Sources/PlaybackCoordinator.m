#import "PlaybackCoordinator.h"
#import <AVFoundation/AVFoundation.h>
@interface PlaybackCoordinator ()
@property(nonatomic,weak,readwrite) id<PlaybackSession> currentSession;
@property(nonatomic,weak) id<PlaybackSession> interruptedSession;
@property(nonatomic) BOOL resumeAfterInterruption;
@end
@implementation PlaybackCoordinator
+ (instancetype)shared {static PlaybackCoordinator *value;static dispatch_once_t once;dispatch_once(&once,^{value=[self new];});return value;}
- (instancetype)init {
    if((self=[super init])){
        MPRemoteCommandCenter *commands=MPRemoteCommandCenter.sharedCommandCenter;
        [commands.playCommand addTarget:self action:@selector(handlePlay:)];
        [commands.pauseCommand addTarget:self action:@selector(handlePause:)];
        [commands.nextTrackCommand addTarget:self action:@selector(handleNext:)];
        [commands.previousTrackCommand addTarget:self action:@selector(handlePrevious:)];
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(mediaReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }return self;
}
- (void)acquireSession:(id<PlaybackSession>)session {
    NSAssert(NSThread.isMainThread,@"Playback ownership is main-thread confined");
    if(self.currentSession==session)return;
    [self.currentSession sessionPause];self.currentSession=session;
    self.interruptedSession=nil;self.resumeAfterInterruption=NO;
}
- (void)releaseSession:(id<PlaybackSession>)session {if(self.currentSession==session){self.currentSession=nil;MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;}}
- (MPRemoteCommandHandlerStatus)play {if(!self.currentSession||![self.currentSession sessionHasContent])return MPRemoteCommandHandlerNoSuchContent;[self.currentSession sessionPlay];return MPRemoteCommandHandlerStatusSuccess;}
- (MPRemoteCommandHandlerStatus)pause {self.resumeAfterInterruption=NO;if(!self.currentSession||![self.currentSession sessionHasContent])return MPRemoteCommandHandlerNoSuchContent;[self.currentSession sessionPause];return MPRemoteCommandHandlerStatusSuccess;}
- (MPRemoteCommandHandlerStatus)step:(NSInteger)direction {return [self.currentSession sessionStep:direction]?MPRemoteCommandHandlerStatusSuccess:MPRemoteCommandHandlerNoSuchContent;}
- (MPRemoteCommandHandlerStatus)handlePlay:(MPRemoteCommandEvent *)event {return [self onMain:^MPRemoteCommandHandlerStatus(void){return [self play];}];}
- (MPRemoteCommandHandlerStatus)handlePause:(MPRemoteCommandEvent *)event {return [self onMain:^MPRemoteCommandHandlerStatus(void){return [self pause];}];}
- (MPRemoteCommandHandlerStatus)handleNext:(MPRemoteCommandEvent *)event {return [self onMain:^MPRemoteCommandHandlerStatus(void){return [self step:1];}];}
- (MPRemoteCommandHandlerStatus)handlePrevious:(MPRemoteCommandEvent *)event {return [self onMain:^MPRemoteCommandHandlerStatus(void){return [self step:-1];}];}
- (MPRemoteCommandHandlerStatus)onMain:(MPRemoteCommandHandlerStatus(^)(void))action {if(NSThread.isMainThread)return action();__block MPRemoteCommandHandlerStatus result;dispatch_sync(dispatch_get_main_queue(),^{result=action();});return result;}
- (void)interruption:(NSNotification *)note {
    NSDictionary *info=note.userInfo;
    dispatch_async(dispatch_get_main_queue(),^{
        if([info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan){self.interruptedSession=self.currentSession;self.resumeAfterInterruption=[self.currentSession respondsToSelector:@selector(sessionWantsPlayback)]?[self.currentSession sessionWantsPlayback]:[self.currentSession sessionIsPlaying];[self.currentSession sessionPause];}
        else {BOOL resume=self.resumeAfterInterruption&&self.interruptedSession==self.currentSession&&([info[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue]&AVAudioSessionInterruptionOptionShouldResume);self.resumeAfterInterruption=NO;self.interruptedSession=nil;if(resume)[self.currentSession sessionPlay];}
    });
}
- (void)routeChanged:(NSNotification *)note {if([note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue]==AVAudioSessionRouteChangeReasonOldDeviceUnavailable)dispatch_async(dispatch_get_main_queue(),^{[self pause];});}
- (void)mediaReset:(NSNotification *)note {dispatch_async(dispatch_get_main_queue(),^{id<PlaybackSession> session=self.currentSession;self.resumeAfterInterruption=NO;[session sessionPause];if([session respondsToSelector:@selector(sessionMediaServicesReset)])[session sessionMediaServicesReset];});}
@end
