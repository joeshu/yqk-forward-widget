// MediaPlaybackDecodeRouter.m
//
// 解码能力依据（证据链，勿凭印象改表）：
//   1) alivcffmpeg 构建配置串（Frameworks/alivcffmpeg.framework/alivcffmpeg 内嵌）：
//      --enable-demuxer=flv --enable-demuxer=live_flv --enable-demuxer=mov
//      --enable-demuxer=mpegts --enable-demuxer=matroska --enable-demuxer=mp3
//      --enable-demuxer=aac --enable-demuxer=h264 --enable-demuxer=webvtt
//      --enable-demuxer=concat --enable-demuxer=cavsaudio
//      --enable-decoder=aac --enable-decoder=h264 --enable-decoder=hevc
//      --enable-decoder=mpeg4 --enable-decoder=mp3 --enable-decoder=pcm_s16le
//      --enable-decoder=ac3_at --enable-decoder=cavsaudio
//      另有 Aliyun 自带 _ff_webm_dash_manifest_demuxer / dash_manifest_demuxer。
//      → 容器：FLV（含 live FLV）、MP4/MOV/3GP、MPEG-TS、Matroska（MKV/WebM）、
//        MP3/AAC、H.264 裸流、DASH 清单；
//        没有 avi、asf（WMV）、rm（RMVB）demuxer。
//      → 视频编码：H.264、H.265（HEVC）、MPEG-4 Part 2；
//        没有 vp8 / vp9 / av1 / h263 / wmv / rv 解码器。
//      → 协议：http / https / rtmp / udp / file。
//   2) CicadaPlayerSDK 二进制符号：-[CicadaPlayer seekToTime:seekMode:]、
//      -[CicadaPlayer setRate:]、-[CicadaPlayer getDuration]、currentPosition、
//      getMediaInfo，以及 CicadaOCHelper 转发的 onError:errorModel:、
//      onCurrentPositionUpdate:position:、onLoadingProgress:progress:、
//      onPlayerStatusChanged:oldStatus:newStatus:、
//      onVideoSizeChanged:width:height:rotation:（另见适配器文件注释）。
//   3) 因此：VP9 / AV1 / WMV / RMVB / AVI 在此构建上两路原生引擎都播不了，
//      只能走 WebView；WebM 只保证容器可解，常见 VP8/VP9/Opus 内容实际不可播，
//      仍先试 Cicada（极少数 H.264 内嵌的 WebM 能播），失败后进 WebView。
//   4) DASH/MPD：Aliyun 播放器层自带 DASH 支持（二进制含 dash_manifest_demuxer），
//      归入 Cicada 覆盖，但需真机验证（本机无 Xcode、无真机）。
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackHeaders.h"

const NSUInteger MediaPlaybackDecodeRouteAttemptedAVPlayer = 1 << 0;
const NSUInteger MediaPlaybackDecodeRouteAttemptedCicadaPlayer = 1 << 1;
const NSUInteger MediaPlaybackDecodeRouteAttemptedWebView = 1 << 2;

static NSString *MediaPlaybackDecodeLowerString(id value) {
    return [value isKindOfClass:NSString.class] ? [(NSString *)value lowercaseString] : @"";
}

static NSString *MediaPlaybackDecodeResultURLString(NSDictionary *result) {
    NSString *raw = [result[@"originalURL"] isKindOfClass:NSString.class] ? result[@"originalURL"] : result[@"url"];
    return [raw isKindOfClass:NSString.class] ? raw : @"";
}

static NSString *MediaPlaybackDecodeResultExtension(NSDictionary *result) {
    NSURLComponents *components = [NSURLComponents componentsWithString:MediaPlaybackDecodeResultURLString(result)];
    return components.path.pathExtension.lowercaseString ?: @"";
}

static NSString *MediaPlaybackDecodeResultMIME(NSDictionary *result) {
    NSString *mime = MediaPlaybackDecodeLowerString(result[@"contentType"] ?: result[@"content_type"] ?: result[@"mimeType"] ?: result[@"mime"]);
    NSRange semicolon = [mime rangeOfString:@";"];
    if (semicolon.location != NSNotFound) mime = [mime substringToIndex:semicolon.location];
    return mime;
}

static NSString *MediaPlaybackDecodeResultFormat(NSDictionary *result) {
    return MediaPlaybackDecodeLowerString(result[@"format"] ?: result[@"mediaType"] ?: result[@"playbackType"]);
}

BOOL MediaPlaybackResultSupportsCicadaPlayer(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return NO;
    if ([result[@"cicadaPlayable"] respondsToSelector:@selector(boolValue)] && [result[@"cicadaPlayable"] boolValue]) return YES;
    NSString *format = MediaPlaybackDecodeResultFormat(result);
    NSString *mime = MediaPlaybackDecodeResultMIME(result);
    // format 词：flv / live_flv / mpd / dash / mkv / matroska / webm / 3gp / rtmp
    NSSet *formats = [NSSet setWithArray:@[@"flv", @"live_flv", @"mpd", @"dash", @"mkv", @"matroska", @"webm", @"3gp", @"3gpp", @"rtmp"]];
    // mime 词：video/x-flv、application/dash+xml、video/x-matroska、video/webm、
    // video/3gpp、application/x-rtmp。video/mp2t 归 AVPlayer，不列入。
    NSSet *mimes = [NSSet setWithArray:@[@"video/x-flv", @"application/dash+xml", @"video/x-matroska", @"video/webm", @"video/3gpp", @"video/3gpp2", @"application/x-rtmp"]];
    if ([formats containsObject:format] || [mimes containsObject:mime]) return YES;
    NSString *raw = MediaPlaybackDecodeResultURLString(result);
    NSString *lowerRaw = raw.lowercaseString;
    if ([lowerRaw hasPrefix:@"rtmp://"] || [lowerRaw hasPrefix:@"rtmps://"]) return YES;
    NSString *extension = MediaPlaybackDecodeResultExtension(result);
    return [@[@"flv", @"mpd", @"mkv", @"webm", @"3gp", @"3gpp"] containsObject:extension];
}

BOOL MediaPlaybackResultRequiresWebViewOnly(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return NO;
    NSString *format = MediaPlaybackDecodeResultFormat(result);
    NSString *mime = MediaPlaybackDecodeResultMIME(result);
    // AVI：无 avi demuxer；WMV/ASF：无 asf demuxer、无 wmv 解码器；
    // RM/RMVB：无 rm demuxer、无 rv 解码器。AVPlayer 同样不支持这三类容器。
    NSSet *formats = [NSSet setWithArray:@[@"avi", @"wmv", @"asf", @"rm", @"rmvb"]];
    NSSet *mimes = [NSSet setWithArray:@[@"video/x-msvideo", @"video/x-ms-wmv", @"video/x-ms-asf", @"application/vnd.rn-realmedia", @"audio/x-pn-realaudio", @"video/vnd.rn-realvideo"]];
    if ([formats containsObject:format] || [mimes containsObject:mime]) return YES;
    NSString *extension = MediaPlaybackDecodeResultExtension(result);
    return [@[@"avi", @"wmv", @"asf", @"rm", @"rmvb"] containsObject:extension];
}

NSString *MediaPlaybackDecodeRouteName(MediaPlaybackDecodeRoute route) {
    switch (route) {
        case MediaPlaybackDecodeRouteAVPlayer: return @"avplayer";
        case MediaPlaybackDecodeRouteCicadaPlayer: return @"cicada";
        case MediaPlaybackDecodeRouteWebView: return @"webview";
        case MediaPlaybackDecodeRouteNone: default: return @"none";
    }
}

MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult(NSDictionary *result, NSUInteger attemptedRoutes) {
    if (![result isKindOfClass:NSDictionary.class]) return MediaPlaybackDecodeRouteNone;
    BOOL webOnly = MediaPlaybackResultRequiresWebViewOnly(result);
    BOOL directMedia = MediaPlaybackResultIsDirectMedia(result);
    BOOL avSupported = MediaPlaybackResultSupportsAVPlayer(result);
    BOOL cicadaSupported = MediaPlaybackResultSupportsCicadaPlayer(result);
    BOOL requiresWebPlayback = ([result[@"requiresWebPlayback"] boolValue] || [result[@"parse"] integerValue] > 0 || [result[@"jx"] integerValue] > 0) && !directMedia;

    // 候选优先级表（按结果特征），取第一个未尝试过的。
    MediaPlaybackDecodeRoute candidates[4];
    NSUInteger count = 0;
    if (webOnly) {
        // AVI/WMV/RMVB：两路原生引擎都明确不支持，只剩 WebView。
        candidates[count++] = MediaPlaybackDecodeRouteWebView;
    } else if (requiresWebPlayback) {
        // 需解析且非直连媒体：先 WebView；WebView 回原生时再试 Cicada/AVPlayer。
        candidates[count++] = MediaPlaybackDecodeRouteWebView;
        if (cicadaSupported) candidates[count++] = MediaPlaybackDecodeRouteCicadaPlayer;
        if (avSupported) candidates[count++] = MediaPlaybackDecodeRouteAVPlayer;
    } else if (cicadaSupported && !avSupported) {
        // Cicada 专属格式（FLV/DASH/MKV/WebM/3GP/RTMP）：AVPlayer 注定失败，跳过。
        candidates[count++] = MediaPlaybackDecodeRouteCicadaPlayer;
        candidates[count++] = MediaPlaybackDecodeRouteWebView;
    } else {
        // AVPlayer 支持、或格式未知/无扩展名、或其他：AVPlayer 先行，
        // 失败后让 ffmpeg 探测（扩展名撒谎、无扩展名地址都靠这一路），最后 WebView。
        candidates[count++] = MediaPlaybackDecodeRouteAVPlayer;
        candidates[count++] = MediaPlaybackDecodeRouteCicadaPlayer;
        candidates[count++] = MediaPlaybackDecodeRouteWebView;
    }
    for (NSUInteger i = 0; i < count; i++) {
        MediaPlaybackDecodeRoute route = candidates[i];
        NSUInteger bit = route == MediaPlaybackDecodeRouteAVPlayer ? MediaPlaybackDecodeRouteAttemptedAVPlayer
            : route == MediaPlaybackDecodeRouteCicadaPlayer ? MediaPlaybackDecodeRouteAttemptedCicadaPlayer
            : MediaPlaybackDecodeRouteAttemptedWebView;
        if ((attemptedRoutes & bit) == 0) return route;
    }
    return MediaPlaybackDecodeRouteNone;
}
