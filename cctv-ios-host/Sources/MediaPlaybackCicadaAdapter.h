// MediaPlaybackCicadaAdapter.h
//
// CicadaPlayer 适配器：把 ffmpeg 内核的 CicadaPlayer 包装成 VOD 可用的播放器。
//
// 关键约束：本文件不 import、不链接 CicadaSDK 的任何符号（ui-smoke 构建不链接
// CicadaPlayerSDK，且无 -Wl,-undefined,dynamic_lookup）。所有 SDK 交互都走
// NSClassFromString + respondsToSelector + objc_msgSend 运行时调用；
// SDK 不存在时 +isAvailable 返回 NO，绝不崩溃。
// 另见集成补丁说明（cctv-ios-host/Docs/CICADA-VOD-INTEGRATION-PATCH.md）与
// Tests/test_decode_router.py。
//
// 能力边界（以 CicadaPlayerSDK / alivcffmpeg 二进制为准，见 .m 注释）：
//   可解：FLV（含 live FLV）、DASH/MPD、MKV、3GP、RTMP、MP4/MOV、MPEG-TS；
//         视频 H.264 / H.265 / MPEG-4，音频 AAC / MP3 / PCM / AC-3。
//   不可解：AVI、WMV/ASF、RM/RMVB（无 demuxer）；VP8 / VP9 / AV1 / H.263
//         （无解码器）。WebM 容器可解，但常见 VP8/VP9/Opus 内容实际不可播。
//   控制：播放/暂停、seek（seekToTime:seekMode:）、倍速（setRate:）、
//         时长/进度（duration / currentPosition）、首帧（onFirstFrameShow +
//         位置轮询兜底）、错误（onError:errorModel:）、完成（onCompletion +
//         位置轮询兜底）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MediaPlaybackCicadaAdapterErrorDomain;

typedef NS_ENUM(NSInteger, MediaPlaybackCicadaAdapterState) {
    MediaPlaybackCicadaAdapterStateIdle = 0,
    MediaPlaybackCicadaAdapterStatePreparing,
    MediaPlaybackCicadaAdapterStatePlaying,
    MediaPlaybackCicadaAdapterStatePaused,
    MediaPlaybackCicadaAdapterStateCompleted,
    MediaPlaybackCicadaAdapterStateFailed,
};

@protocol MediaPlaybackCicadaAdapterDelegate <NSObject>
@optional
- (void)cicadaAdapterDidPrepare:(id)adapter;
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter;
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error;
- (void)cicadaAdapterDidComplete:(id)adapter;
- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration;
- (void)cicadaAdapter:(id)adapter didUpdateLoading:(BOOL)loading progress:(float)progress;
- (void)cicadaAdapterDidSeek:(id)adapter;
@end

@interface MediaPlaybackCicadaAdapter : NSObject

// SDK 类是否存在（NSClassFromString(@"CicadaPlayer")）。ui-smoke 构建里为 NO。
+ (BOOL)isAvailable;

- (instancetype)initWithURL:(NSURL *)url
                    headers:(nullable NSDictionary<NSString *, NSString *> *)headers
             networkTimeout:(NSTimeInterval)timeoutSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<MediaPlaybackCicadaAdapterDelegate> delegate;
// 播放器渲染面：调用方把它加进视频容器（满屏约束），不要直接改它的 frame。
@property (nonatomic, readonly) UIView *playerView;
@property (nonatomic, readonly) MediaPlaybackCicadaAdapterState state;
@property (nonatomic, readonly) NSTimeInterval currentPosition;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) BOOL hasVideoTrack;

- (void)prepare;
- (void)start;
- (void)pause;
- (void)stop;
- (void)destroy;
// seekMode 传 0（精确 seek，Aliyun 约定；未在二进制中确认，需真机验证）。
- (void)seekToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion;
- (void)setRate:(float)rate;
// gravity 取 AVLayerVideoGravityResizeAspect / ResizeAspectFill / Resize；
// 映射到 CicadaPlayer scalingMode（0=AspectFit、1=AspectFill，Aliyun 约定，
// 未在二进制中确认，需真机验证）。SDK 不支持时静默保留默认。
- (void)applyVideoGravity:(NSString *)gravity;

@end

NS_ASSUME_NONNULL_END
