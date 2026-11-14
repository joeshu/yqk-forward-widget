#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "PlaybackCoordinator.h"
#import "PlaybackOverlayController.h"
static NSUInteger coordinatorFailures;
static void check(BOOL value,NSString *message){if(!value){NSLog(@"FAILED %@",message);coordinatorFailures++;}}
@interface FixtureSession : NSObject <PlaybackSession>
@property(nonatomic) BOOL playing;
@property(nonatomic) NSInteger steps;
@property(nonatomic) NSInteger resets;
@end
@implementation FixtureSession
- (BOOL)sessionHasContent{return YES;}
- (BOOL)sessionIsPlaying{return self.playing;}
- (void)sessionPlay{self.playing=YES;}
- (void)sessionPause{self.playing=NO;}
- (BOOL)sessionStep:(NSInteger)direction{self.steps+=direction;return YES;}
- (void)sessionMediaServicesReset{self.resets++;}
@end
static void drain(void){[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];}
BOOL PlaybackCoordinatorRunSmokeChecks(void){@autoreleasepool{
    coordinatorFailures=0;
    PlaybackCoordinator *coordinator=[PlaybackCoordinator shared];id<PlaybackSession> previous=coordinator.currentSession;if(previous)[coordinator releaseSession:previous];
    check([coordinator play]==MPRemoteCommandHandlerStatusNoSuchContent,@"no content returns an explicit status");
    FixtureSession *live=[FixtureSession new],*vod=[FixtureSession new];
    [coordinator acquireSession:live];check([coordinator togglePlayPause]==MPRemoteCommandHandlerStatusSuccess&&live.playing,@"remote toggle starts the current paused session");check([coordinator togglePlayPause]==MPRemoteCommandHandlerStatusSuccess&&!live.playing,@"remote toggle pauses the current playing session");[coordinator play];[coordinator play];check(live.playing,@"repeated play stays playing");
    [coordinator pause];[coordinator pause];check(!live.playing,@"repeated pause stays paused");
    [coordinator play];[coordinator acquireSession:vod];check(!live.playing,@"ownership transfer pauses live");
    [coordinator releaseSession:live];[coordinator play];check(vod.playing&&!live.playing,@"old owner cannot release or resume the current session");
    [coordinator step:1];check(vod.steps==1&&live.steps==0,@"next targets the current owner");
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)}];drain();check(!vod.playing,@"interruption pauses the owner");
    [coordinator pause];
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded),AVAudioSessionInterruptionOptionKey:@(AVAudioSessionInterruptionOptionShouldResume)}];drain();check(!vod.playing,@"explicit pause cancels automatic interruption resume");
    [coordinator play];[NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionRouteChangeNotification object:nil userInfo:@{AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}];drain();check(!vod.playing,@"unplugged headphones pause playback");
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionMediaServicesWereResetNotification object:nil];drain();check(vod.resets==1&&!vod.playing,@"audio reset does not silently restart playback");
    [coordinator releaseSession:vod];check([coordinator pause]==MPRemoteCommandHandlerStatusNoSuchContent,@"released content cannot be controlled");
    PlaybackOverlayController *overlay=[PlaybackOverlayController new];__block BOOL voiceOver=NO;overlay.voiceOverRunningProvider=^BOOL{return voiceOver;};[overlay show];[overlay hide];voiceOver=YES;[NSNotificationCenter.defaultCenter postNotificationName:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];check(overlay.visible,@"enabling VoiceOver reveals a previously hidden playback overlay");[overlay toggle];check(overlay.visible,@"toggling playback controls cannot hide them while VoiceOver is active");voiceOver=NO;[NSNotificationCenter.defaultCenter postNotificationName:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];[overlay invalidate];
    if(previous)[coordinator acquireSession:previous];return coordinatorFailures==0;
}}
