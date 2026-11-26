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
    MediaPlaybackDecodeRouteMPV,
};

// 已尝试过的路由位掩码（传给 MediaPlaybackDecodeRouteNextForResult，防回退循环）。
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedAVPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedWebView;
FOUNDATION_EXPORT const NSUInteger MediaPlaybackDecodeRouteAttemptedMPV;
FOUNDATION_EXPORT BOOL MediaPlaybackMPVRouteEnabled(void);

// 该结果是否可由 CicadaPlayer（ffmpeg 内核）解码。
// 判定依据：format / mime / URL 扩展名 / scheme（rtmp）。
// 包含 FLV、DASH/MPD、MKV、WebM、3GP、RTMP。
// 注意 WebM 只保证容器可解：VP8/VP9/Opus 无解码器，实际大多不可播，
// 失败后由运行时回退链继续走到 WebView。
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsCicadaPlayer(NSDictionary * _Nullable result);

// 该结果是否两路原生引擎都明确不支持（AVI、WMV/ASF、RM/RMVB）：只能走 WebView。
FOUNDATION_EXPORT BOOL MediaPlaybackResultRequiresWebViewOnly(NSDictionary * _Nullable result);

// 按优先级返回下一个未尝试的路由；全部试过返回 MediaPlaybackDecodeRouteNone。
// 单一候选计算见 MediaPlaybackDecodeRouteCandidatesForResult：解析页 →
// [WebView]；直连媒体 → 原生候选 [AVPlayer, MPV, CicadaPlayer]（preferCicada
// 时 Cicada 在 MPV 之前），WebView 不进候选；直播（forLive=YES）排除 MPV
// 与 WebView。attemptedRoutes 为上面四个位掩码的或；传 0 表示从头开始。
FOUNDATION_EXPORT MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult(NSDictionary * _Nullable result, NSUInteger attemptedRoutes);
// 下一路（直播）：同上，但 MPV 与 WebView 不进候选。
FOUNDATION_EXPORT MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForLiveResult(NSDictionary * _Nullable result, NSUInteger attemptedRoutes);
// 单一候选计算：返回有序候选字典数组，每项含 @"route"
// （NSNumber(MediaPlaybackDecodeRoute)）、@"decodeMode"（@"av" / @"mpv" /
// @"cicada" / @"cicada_soft" / @"webview"）、@"reason"（诊断用原因：
// @"av_supported" / @"mpv_preferred" / @"cicada_preferred" /
// @"cicada_fallback" / @"web_page"）。门禁命中（见下）或已尝试过的路由不
// 进候选；直连媒体不含 WebView；直播（forLive=YES）不含 MPV 与 WebView。
FOUNDATION_EXPORT NSArray<NSDictionary *> *MediaPlaybackDecodeRouteCandidatesForResult(NSDictionary * _Nullable result, NSUInteger attemptedRoutes, BOOL forLive);
// 入口门禁原因：nil 表示可尝试；否则为 @"unsupported_container" /
// @"unsupported_video_codec" / @"unsupported_transport"。检查顺序与
// MediaDescriptor 一致（webOnly 容器 → 不支持编码 → 不支持传输）；
// 传输检查只看 result[@"url"]（不看 originalURL：红果 cenc 本地代理的
// originalURL 是 cenc://，可播地址在 url 字段里）。
FOUNDATION_EXPORT NSString * _Nullable MediaPlaybackDecodeRouteRejectionReasonForResult(NSDictionary * _Nullable result);

// 供日志/诊断用：路由名（@"avplayer" / @"cicada" / @"webview" / @"none"）。
FOUNDATION_EXPORT NSString *MediaPlaybackDecodeRouteName(MediaPlaybackDecodeRoute route);
FOUNDATION_EXPORT BOOL MediaPlaybackCicadaErrorAllowsSoftwareRetry(NSError * _Nullable error);
FOUNDATION_EXPORT NSString * _Nullable MediaPlaybackSniffContainerFormat(NSData * _Nullable headerBytes);

NS_ASSUME_NONNULL_END
