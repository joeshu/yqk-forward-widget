// MediaPlaybackDecodeRouter.h
//
// VOD 解码路由：AVPlayer → CicadaPlayer → WebView。
//
// 纯 Foundation 逻辑，不引用任何播放器 SDK 符号，ui-smoke 构建也能链接。
// 格式覆盖表以 alivcffmpeg 构建的实际能力为准（见 .m 顶部注释）：
// 该构建的 demuxer 只有 flv / live_flv / mov / mpegts / matroska / mp3 / aac /
// h264 / webvtt / concat，decoder 只有 aac / h264 / hevc / mpeg4 / mp3 / pcm /
// ac3 / cavsaudio。没有 avi、asf（WMV）、rm（RMVB）demuxer，也没有
// vp8 / vp9 / av1 / h263 解码器——这些格式两路原生引擎都播不了，只能走 WebView。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MediaPlaybackDecodeRoute) {
    MediaPlaybackDecodeRouteNone = 0,
    MediaPlaybackDecodeRouteAVPlayer,
    MediaPlaybackDecodeRouteCicadaPlayer,
    MediaPlaybackDecodeRouteWebView,
};

// 已尝试过的路由位掩码（传给 MediaPlaybackDecodeRouteNextForResult，防回退循环）。
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedAVPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedWebView;

// 该结果是否可由 CicadaPlayer（ffmpeg 内核）解码。
// 判定依据：format / mime / URL 扩展名 / scheme（rtmp）。
// 包含 FLV、DASH/MPD、MKV、WebM、3GP、RTMP。
// 注意 WebM 只保证容器可解：VP8/VP9/Opus 无解码器，实际大多不可播，
// 失败后由运行时回退链继续走到 WebView。
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsCicadaPlayer(NSDictionary * _Nullable result);

// 该结果是否两路原生引擎都明确不支持（AVI、WMV/ASF、RM/RMVB）：只能走 WebView。
FOUNDATION_EXPORT BOOL MediaPlaybackResultRequiresWebViewOnly(NSDictionary * _Nullable result);

// 按优先级返回下一个未尝试的路由；全部试过返回 MediaPlaybackDecodeRouteNone。
// 优先级（按结果特征）：
//   WebView-only（AVI/WMV/RMVB）        → [WebView]
//   需解析且非直连媒体（parse/jx>0）   → [WebView, Cicada（若候选）, AVPlayer（若支持）]
//   Cicada 专属格式（FLV/DASH/MKV…）   → [CicadaPlayer, WebView]
//   AVPlayer 支持                      → [AVPlayer, CicadaPlayer, WebView]
//   直连媒体但格式未知/无扩展名        → [AVPlayer, CicadaPlayer, WebView]
//   其他                               → [AVPlayer, CicadaPlayer, WebView]
// attemptedRoutes 为上面三个位掩码的或；传 0 表示从头开始。
FOUNDATION_EXPORT MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult(NSDictionary * _Nullable result, NSUInteger attemptedRoutes);

// 供日志/诊断用：路由名（@"avplayer" / @"cicada" / @"webview" / @"none"）。
FOUNDATION_EXPORT NSString *MediaPlaybackDecodeRouteName(MediaPlaybackDecodeRoute route);
FOUNDATION_EXPORT BOOL MediaPlaybackCicadaErrorAllowsSoftwareRetry(NSError * _Nullable error);

NS_ASSUME_NONNULL_END
