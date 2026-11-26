#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CCTVPlaybackEngineTypes.h"

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
@property (nonatomic) BOOL liveStreamHint;

- (void)prepare;
- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder;
- (void)start;
- (void)pause;
- (void)stop;
- (void)destroy;
- (void)seekToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion;
- (void)setMuted:(BOOL)muted;

@optional
/// 统一可选能力；调用方调用前必须使用 respondsToSelector: 检查。
@property (nonatomic) float rate;
/// 轨道列表（T09）。每项字典键：
///   @"type"     NSString，@"audio" / @"subtitle" / @"video"
///   @"index"    NSNumber，引擎内轨道编号（MPV：音频 id、字幕 id+10000、
///                视频 id+20000；Cicada：SDK trackIndex）
///   @"name"     NSString，显示名
///   @"selected" NSNumber BOOL（引擎真实上报的当前选中，如 MPV 的
///                track-list/N/selected）或字符串 @"unknown"（引擎不
///                暴露选中状态，如 Cicada——调用方不得把 unknown 当作未选中，
///                也不得把请求成功当作已切换）。
/// 菜单只在选择状态已知时提供"关闭"项；未知时只列轨道、不标当前选中。
- (NSArray<NSDictionary *> *)availableTracks;
- (BOOL)canSelectTracks;
/// 切换轨道。返回值 YES 只表示调用被引擎接受（MPV：set_property 同步
/// 成功即实际已切换，调用后可重查 availableTracks 验证；Cicada：只表示
/// SDK 调用已发出，实际切换无可查询的选中状态——调用方须把验证结果
/// 另外记录，不得只凭返回值宣称已切换）。
/// 关闭哨兵（仅 MPV 支持，Cicada 返回 NO）：index 0 = 关闭音频轨道，
/// index 10000 = 关闭字幕轨道（mpv 的 aid/sid 设为 "no"）。
- (BOOL)selectTrackWithIndex:(NSInteger)index;
- (void)applyVideoGravity:(NSString *)gravity;
/// Unified optional telemetry/error surface; adapters expose only data supported by their engine.
/// 播放统计快照（S5，T08 起填真实值）。统一键契约——值是 NSNumber 或
/// 字符串 @"unknown"（引擎不暴露该项时，绝不伪造数字）：
///   @"engine"             NSString，@"mpv" / @"cicada"
///   @"hwdec"              NSString，当前实际硬解（如 mpv 的 hwdec-current；
///                         Cicada adapter 不暴露则 @"unknown"）
///   @"videoBitrate"       NSNumber，bps；@"audioBitrate" NSNumber，bps
///   @"fps"                NSNumber，当前视频帧率
///   @"droppedFrames"      NSNumber，解码器累计丢帧
///   @"cacheSeconds"       NSNumber，解复用缓存时长（秒）
///   @"bufferedPosition"   NSNumber，缓存末尾包的绝对媒体时间戳（MPV 的
///                         demuxer-cache-time / Cicada 的 bufferedPosition）
///   @"bufferedAheadSeconds" NSNumber，MAX(0, bufferedPosition - currentPosition)
///   @"currentPosition"    NSNumber，@"duration" NSNumber，@"state" NSNumber（枚举值）
///   @"stallCount"         NSNumber，累计卡顿次数（未跟踪则 @"unknown"）
@property (nonatomic, readonly) NSInteger lastErrorCode;
- (NSDictionary<NSString *, id> *)playbackStatistics;
- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL;
/// PiP（T10/F1）。目前只有 AV 路径（系统 AVPlayerViewController）提供
/// 真实 PiP；MPV 返回 NO——控制骨架在、无视频供帧（供帧由 T24 实现后
/// 再开放）；Cicada/CN 不实现这组方法（respondsToSelector 为 NO 即不
/// 支持）。调用方不得以设备支持（isPictureInPictureSupported 系统值）
/// 冒充某引擎支持 PiP。
- (BOOL)isPictureInPictureSupported;
- (BOOL)isPictureInPictureActive;
- (void)startPictureInPicture;
- (void)stopPictureInPicture;

@end

NS_ASSUME_NONNULL_END
