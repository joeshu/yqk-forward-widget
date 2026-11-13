#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
NS_ASSUME_NONNULL_BEGIN
/// Main-thread session contract. A session is never retained by the coordinator.
@protocol PlaybackSession <NSObject>
- (BOOL)sessionHasContent;
- (BOOL)sessionIsPlaying;
- (void)sessionPlay;
- (void)sessionPause;
- (BOOL)sessionStep:(NSInteger)direction;
@optional
- (BOOL)sessionWantsPlayback;
- (void)sessionMediaServicesReset;
@end
@interface PlaybackCoordinator : NSObject
@property(nonatomic,weak,readonly,nullable) id<PlaybackSession> currentSession;
+ (instancetype)shared;
- (void)acquireSession:(id<PlaybackSession>)session;
- (void)releaseSession:(id<PlaybackSession>)session;
- (MPRemoteCommandHandlerStatus)play;
- (MPRemoteCommandHandlerStatus)pause;
- (MPRemoteCommandHandlerStatus)step:(NSInteger)direction;
@end
NS_ASSUME_NONNULL_END
