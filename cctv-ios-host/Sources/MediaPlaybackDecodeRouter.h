// MediaPlaybackDecodeRouter.h
//
// VOD 解码路由：已验证媒体 → AVPlayer / CicadaPlayer。待解析网页返回 None。
//
// 纯 Foundation 逻辑，不引用任何播放器 SDK 符号，ui-smoke 构建也能链接。
// 格式覆盖表以 alivcffmpeg 构建的实际能力为准（见 .m 顶部注释）：
// 该构建的 demuxer 只有 flv / live_flv / mov / mpegts / matroska / mp3 / aac /
// h264 / webvtt / concat，decoder 只有 aac / h264 / hevc / mpeg4 / mp3 / pcm /
// ac3 / cavsaudio。没有 avi、asf（WMV）、rm（RMVB）demuxer，也没有
// vp8 / vp9 / av1 / h263 解码器；不以网页作为解码回退。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MediaPlaybackDecodeRoute) {
    MediaPlaybackDecodeRouteNone = 0,
    MediaPlaybackDecodeRouteAVPlayer,
    MediaPlaybackDecodeRouteCicadaPlayer,
    MediaPlaybackDecodeRouteWebView, // Legacy enum value; native playback never returns it.
};

// 已尝试过的路由位掩码（传给 MediaPlaybackDecodeRouteNextForResult，防回退循环）。
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedAVPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedWebView;

// 该结果是否可由 CicadaPlayer（ffmpeg 内核）解码。
// 判定依据：format / mime / URL 扩展名 / scheme（rtmp）。
// 包含 FLV、DASH/MPD、MKV、WebM、3GP、RTMP。
// 注意 WebM 只保证容器可解：VP8/VP9/Opus 无解码器，实际大多不可播，
// 失败后仅尝试另一原生引擎，仍失败时显示错误。
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsCicadaPlayer(NSDictionary * _Nullable result);

// 该结果是否两路原生引擎都明确不支持（AVI、WMV/ASF、RM/RMVB）；保留历史函数名。
FOUNDATION_EXPORT BOOL MediaPlaybackResultRequiresWebViewOnly(NSDictionary * _Nullable result);

// 按优先级返回下一个未尝试的路由；全部试过返回 MediaPlaybackDecodeRouteNone。
// 未解析页面和已知不支持的容器返回 None；调用方先完成解析和媒体验证。
// 已验证的 HLS/MP4 首选 AVPlayer；DASH/FLV/MKV 等首选 CicadaPlayer。
// attemptedRoutes 只用于防止两个原生引擎反复重试。
FOUNDATION_EXPORT MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult(NSDictionary * _Nullable result, NSUInteger attemptedRoutes);

// 供日志/诊断用：路由名（@"avplayer" / @"cicada" / @"webview" / @"none"）。
FOUNDATION_EXPORT NSString *MediaPlaybackDecodeRouteName(MediaPlaybackDecodeRoute route);
FOUNDATION_EXPORT BOOL MediaPlaybackCicadaErrorAllowsSoftwareRetry(NSError * _Nullable error);

NS_ASSUME_NONNULL_END
