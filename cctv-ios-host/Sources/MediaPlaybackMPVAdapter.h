// MediaPlaybackMPVAdapter.h
//
// 全能解码内核适配器（方案 A）：基于符号隔离的 CCTVMPVCore.framework
// （MPVKit：mpv v0.41 + FFmpeg 8.x + VideoToolbox 硬解 + libass 字幕 +
// libplacebo/MoltenVK Metal 渲染 + avfoundation 音频输出）。
//
// 关键约束：
//   1) 本文件不 import、不静态链接任何 libmpv / FFmpeg 符号；运行时通过
//      dlopen(..., RTLD_NOW | RTLD_LOCAL) + dlsym 按需加载，彻底隔离 C 符号，
//      与 CNPlayerSDK（内置旧版 IJK FFmpeg）、alivcffmpeg、Python OpenSSL 零冲突。
//   2) ui-smoke / jar-smoke / 无 MPV 构建中 +isAvailable 返回 NO，绝不崩溃。
//   3) 复用 MediaPlaybackCicadaAdapterDelegate 协议与控制接口，可与
//      MediaPlaybackCicadaAdapter 无缝互换，同时额外提供外挂字幕（libass）能力。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "MediaPlaybackCicadaAdapter.h"
#import "CCTVPlaybackEngineProtocol.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MediaPlaybackMPVAdapterErrorDomain;

@interface MediaPlaybackMPVAdapter : NSObject <CCTVPlaybackEngine>

/// 运行时检测 CCTVMPVCore.framework 是否存在并成功通过 RTLD_LOCAL 加载。
+ (BOOL)isAvailable;

/// 供设置页与播放信息面板展示的内核名称。
+ (NSString *)engineDisplayName;

- (instancetype)initWithURL:(NSURL *)url
                    headers:(nullable NSDictionary<NSString *, NSString *> *)headers
             networkTimeout:(NSTimeInterval)timeoutSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<MediaPlaybackCicadaAdapterDelegate> delegate;
@property (nonatomic, readonly) UIView *playerView;
@property (nonatomic, readonly) MediaPlaybackCicadaAdapterState state;
@property (nonatomic, readonly) NSTimeInterval currentPosition;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSTimeInterval bufferedPosition;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL hasVideoTrack;
@property (nonatomic, readonly) NSInteger lastErrorCode;
@property (nonatomic, readonly) NSTimeInterval firstFrameTimeout;
@property (nonatomic) float rate;
/// 显式直播提示：点播为 NO（默认），直播为 YES。
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

/// 挂载外挂字幕（.ass / .ssa / .srt / .vtt），由 libass 原生渲染。
- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL;

/// 基于 AVSampleBufferDisplayLayer + AVPictureInPictureController 的全格式画中画桥接。
- (BOOL)isPictureInPictureSupported;
- (BOOL)isPictureInPictureActive;
- (void)startPictureInPicture;
- (void)stopPictureInPicture;

@end

NS_ASSUME_NONNULL_END
