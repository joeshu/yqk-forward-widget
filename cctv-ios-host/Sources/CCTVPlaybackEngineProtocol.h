#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "MediaPlaybackCicadaAdapter.h"

NS_ASSUME_NONNULL_BEGIN

/// 统一播放引擎协议（P2-1）：收拢直播与点播多内核控制接口（MPV / Cicada / 未来引擎）。
@protocol CCTVPlaybackEngine <NSObject>

@property (nonatomic, weak, nullable) id<MediaPlaybackCicadaAdapterDelegate> delegate;
@property (nonatomic, readonly) UIView *playerView;
@property (nonatomic, readonly) MediaPlaybackCicadaAdapterState state;
@property (nonatomic, readonly) NSTimeInterval currentPosition;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSTimeInterval bufferedPosition;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL hasVideoTrack;
@property (nonatomic, readonly) float rate;
@property (nonatomic) BOOL liveStreamHint;

- (void)prepare;
- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder;
- (void)start;
- (void)pause;
- (void)stop;
- (void)destroy;
- (void)seekToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion;
- (void)setRate:(float)rate;
- (void)setMuted:(BOOL)muted;
- (NSArray<NSDictionary *> *)availableTracks;
- (BOOL)canSelectTracks;
- (BOOL)selectTrackWithIndex:(NSInteger)index;
- (void)applyVideoGravity:(NSString *)gravity;

@optional
- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL;
- (BOOL)isPictureInPictureSupported;
- (BOOL)isPictureInPictureActive;
- (void)startPictureInPicture;
- (void)stopPictureInPicture;

@end

NS_ASSUME_NONNULL_END
