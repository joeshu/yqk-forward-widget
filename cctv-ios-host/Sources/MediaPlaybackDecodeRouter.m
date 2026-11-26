#import "MediaCapabilityRegistry.h"
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
//      本 App 的原生路由均无法保证播放，不应宣称 WebView 可补齐解码能力。
//      WebM 只保证容器可解；常见 VP8/VP9/Opus 内容实际不可播。
//      路由保留有界的原生尝试，失败后由调用方换线路或提示错误。
//   4) DASH/MPD：Aliyun 播放器层自带 DASH 支持（二进制含 dash_manifest_demuxer），
//      归入 Cicada 覆盖，但需真机验证（本机无 Xcode、无真机）。
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackHeaders.h"

const NSUInteger MediaPlaybackDecodeRouteAttemptedAVPlayer = 1 << 0;
const NSUInteger MediaPlaybackDecodeRouteAttemptedCicadaPlayer = 1 << 1;
const NSUInteger MediaPlaybackDecodeRouteAttemptedWebView = 1 << 2;
const NSUInteger MediaPlaybackDecodeRouteAttemptedMPV = 1 << 3;

static NSString *MediaPlaybackDecodeLowerString(id value) {
    return [value isKindOfClass:NSString.class] ? [[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString] : @"";
}

static NSString *MediaPlaybackDecodeResultURLString(NSDictionary *result) {
    NSString *raw = [result[@"originalURL"] isKindOfClass:NSString.class] ? result[@"originalURL"] : result[@"url"];
    return [raw isKindOfClass:NSString.class] ? raw : @"";
}

static NSString *MediaPlaybackDecodeResultExtension(NSDictionary *result) {
    NSURLComponents *components = [NSURLComponents componentsWithString:MediaPlaybackDecodeResultURLString(result)];
    return components.path.pathExtension.lowercaseString ?: @"";
}

NSString *MediaPlaybackSniffContainerFormat(NSData *headerBytes) {
    if (![headerBytes isKindOfClass:NSData.class] || headerBytes.length < 4) return nil;
    const uint8_t *b = (const uint8_t *)headerBytes.bytes;
    NSUInteger len = headerBytes.length;
    if (b[0] == 'F' && b[1] == 'L' && b[2] == 'V' && b[3] == 0x01) return @"flv";
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) return @"mkv";
    if (len >= 8 && (memcmp(b + 4, "ftyp", 4) == 0 || memcmp(b + 4, "styp", 4) == 0 ||
                     memcmp(b + 4, "moof", 4) == 0 || memcmp(b + 4, "moov", 4) == 0)) return @"mp4";
    if (b[0] == 0x47 && (len < 189 || b[188] == 0x47)) return @"ts";
    if (b[0] == 'f' && b[1] == 'L' && b[2] == 'a' && b[3] == 'C') return @"flac";
    if (len >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WAVE", 4) == 0) return @"wav";
    if ((b[0] == 'I' && b[1] == 'D' && b[2] == '3') || (b[0] == 0xFF && (b[1] == 0xFB || b[1] == 0xF3 || b[1] == 0xF2))) return @"mp3";
    if (b[0] == 0xFF && (b[1] == 0xF1 || b[1] == 0xF9)) return @"aac";
    NSUInteger offset = (len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
    while (offset < len && (b[offset] == ' ' || b[offset] == '\t' || b[offset] == '\r' || b[offset] == '\n')) offset++;
    if (len - offset >= 7 && memcmp(b + offset, "#EXTM3U", 7) == 0) return @"hls";
    // Inspect the XML root, not the declaration shared by XMLTV and error pages.
    NSString *prefix=[[NSString alloc] initWithBytes:b+offset length:MIN(len-offset,(NSUInteger)4096) encoding:NSUTF8StringEncoding];
    static NSRegularExpression *mpd=nil;
    static dispatch_once_t mpdOnce;
    dispatch_once(&mpdOnce,^{
        mpd=[NSRegularExpression regularExpressionWithPattern:@"^\\s*(?:<\\?xml[^>]*>\\s*)?(?:<!--[^>]*-->\\s*)*<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?MPD(?:\\s|>)" options:0 error:NULL];
    });
    if(prefix&&[mpd firstMatchInString:prefix options:0 range:NSMakeRange(0,prefix.length)])return @"dash";
    return nil;
}

static NSString *MediaPlaybackDecodeResultMIME(NSDictionary *result) {
    NSString *mime = MediaPlaybackDecodeLowerString(result[@"probedMIME"] ?: result[@"contentType"] ?: result[@"content_type"] ?: result[@"mimeType"] ?: result[@"mime"]);
    NSRange semicolon = [mime rangeOfString:@";"];
    if (semicolon.location != NSNotFound) mime = [mime substringToIndex:semicolon.location];
    return [mime stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *MediaPlaybackDecodeResultFormat(NSDictionary *result) {
    NSString *probed = MediaPlaybackDecodeLowerString(result[@"probedContainer"]);
    if (probed.length) return probed;
    if ([result[@"headerBytes"] isKindOfClass:NSData.class]) {
        NSString *sniffed = MediaPlaybackSniffContainerFormat(result[@"headerBytes"]);
        if (sniffed.length) return sniffed;
    }
    return MediaPlaybackDecodeLowerString(result[@"format"] ?: result[@"mediaType"] ?: result[@"playbackType"]);
}

static BOOL MediaPlaybackMPVUniversalAvailable(void);

BOOL MediaPlaybackMPVRouteEnabled(void) {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.mediaDecodeMPVEnabled.v1"] &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"cctv.mediaDecodeMPVEnabled.v1"]) return NO;
#if defined(CCTV_DISABLE_MPV)
    return NO;
#else
    return MediaPlaybackMPVUniversalAvailable();
#endif
}

static BOOL MediaPlaybackMPVUniversalAvailable(void) {
    Class cls = NSClassFromString(@"MediaPlaybackMPVAdapter");
    SEL sel = NSSelectorFromString(@"isAvailable");
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))[(id)cls methodForSelector:sel])(cls, sel);
}

BOOL MediaPlaybackResultSupportsCicadaPlayer(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return NO;
    if ([result[@"dashRemuxed"] boolValue]) return NO;
    if ([result[@"cicadaPlayable"] respondsToSelector:@selector(boolValue)] && [result[@"cicadaPlayable"] boolValue]) return YES;
    NSString *format = MediaPlaybackDecodeResultFormat(result);
    NSString *mime = MediaPlaybackDecodeResultMIME(result);
    // format 词：flv / live_flv / mpd / dash / mkv / matroska / webm / 3gp / rtmp
    NSSet *formats=[NSSet setWithArray:MediaCapabilityCicadaFormats()];
    // mime 词：video/x-flv、application/dash+xml、video/x-matroska、video/webm、
    // video/3gpp、application/x-rtmp。video/mp2t 归 AVPlayer，不列入。
    NSSet *mimes = [NSSet setWithArray:@[@"video/x-flv", @"application/dash+xml", @"video/x-matroska", @"video/webm", @"video/3gpp", @"video/3gpp2", @"application/x-rtmp"]];
    if ([formats containsObject:format] || [mimes containsObject:mime]) return YES;
    NSString *raw = MediaPlaybackDecodeResultURLString(result);
    NSString *lowerRaw = raw.lowercaseString;
    if ([lowerRaw hasPrefix:@"rtmp://"] || [lowerRaw hasPrefix:@"rtmps://"] || [lowerRaw hasPrefix:@"udp://"]) return YES;
    NSString *extension = MediaPlaybackDecodeResultExtension(result);
    if ([@[@"flv", @"mpd", @"mkv", @"webm", @"3gp", @"3gpp"] containsObject:extension]) return YES;
    if (MediaPlaybackMPVRouteEnabled()) {
        // MPV 已启用（非仅可用）时才由它覆盖这些 scheme；容器分支已删：
        // AVI/WMV/ASF/RM/RMVB 的前置拒绝由 RequiresWebViewOnly 按同一
        // 启用状态判定，这里不再与它矛盾地宣称 Cicada 可播。
        if ([lowerRaw hasPrefix:@"rtsp://"] || [lowerRaw hasPrefix:@"rtsps://"] || [lowerRaw hasPrefix:@"srt://"] || [lowerRaw hasPrefix:@"smb://"]) return YES;
    }
    if (!extension.length && lowerRaw.length) {
        if ([lowerRaw containsString:@".flv?"] || [lowerRaw containsString:@"format=flv"] || [lowerRaw containsString:@"type=flv"] || [lowerRaw containsString:@"format=mpd"] || [lowerRaw containsString:@".mpd?"]) return YES;
    }
    return NO;
}

static BOOL MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(NSDictionary *result, BOOL mpvBypassAllowed) {
    if (![result isKindOfClass:NSDictionary.class]) return NO;
    // MPV 已启用时这些容器可解，不拒绝；直播（mpvBypassAllowed=NO）不走
    // MPV，旁路关闭。
    if (mpvBypassAllowed && MediaPlaybackMPVRouteEnabled()) return NO;
    NSString *format = MediaPlaybackDecodeResultFormat(result);
    NSString *mime = MediaPlaybackDecodeResultMIME(result);
    // AVI：无 avi demuxer；WMV/ASF：无 asf demuxer、无 wmv 解码器；
    // RM/RMVB：无 rm demuxer、无 rv 解码器。AVPlayer 同样不支持这些容器。
    // 此函数保留历史名称，仅表示原生能力限制；不承诺 WebView 能播放。
    NSSet *formats=[NSSet setWithArray:MediaCapabilityUnsupportedContainers()];
    NSSet *mimes = [NSSet setWithArray:@[@"video/x-msvideo", @"video/x-ms-wmv", @"video/x-ms-asf", @"application/vnd.rn-realmedia", @"audio/x-pn-realaudio", @"video/vnd.rn-realvideo"]];
    if ([formats containsObject:format] || [mimes containsObject:mime]) return YES;
    NSString *extension = MediaPlaybackDecodeResultExtension(result);
    return [@[@"avi", @"wmv", @"asf", @"rm", @"rmvb"] containsObject:extension];
}

BOOL MediaPlaybackResultRequiresWebViewOnly(NSDictionary *result) {
    return MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(result, YES);
}

NSString *MediaPlaybackDecodeRouteName(MediaPlaybackDecodeRoute route) {
    switch (route) {
        case MediaPlaybackDecodeRouteAVPlayer: return @"avplayer";
        case MediaPlaybackDecodeRouteCicadaPlayer: return @"cicada";
        case MediaPlaybackDecodeRouteWebView: return @"webview";
        case MediaPlaybackDecodeRouteMPV: return @"mpv";
        case MediaPlaybackDecodeRouteNone: default: return @"none";
    }
}

NSString *MediaPlaybackDecodeRouteRejectionReasonForResult(NSDictionary *result) {
    return MediaPlaybackDecodeRouteRejectionReasonForResult(result, NO);
}

NSString *MediaPlaybackDecodeRouteRejectionReasonForResult(NSDictionary *result, BOOL forLive) {
    if (![result isKindOfClass:NSDictionary.class]) return @"unsupported_transport";
    // 与 MediaDescriptor 同一顺序：webOnly 容器 → 不支持编码 → 不支持传输。
    // 直播不走 MPV，容器旁路只在点播开。
    if (MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(result, !forLive)) return @"unsupported_container";
    // T11：vp8/vp9/av1/h263/wmv/rv 只是 AV/Cicada 不支持，MPV（ffmpeg）可解；
    // 点播且 MPV 已启用时不拒绝。直播不走 MPV，仍拒绝（无可用引擎）。
    // 旧代码无条件拒绝，与 MPV 候选链矛盾（MPV 开启时本应可播）。
    if ([result[@"videoCodec"] isKindOfClass:NSString.class] && [MediaCapabilityMPVOnlyVideoCodecs() containsObject:[result[@"videoCodec"] lowercaseString]] && (forLive || !MediaPlaybackMPVRouteEnabled())) return @"unsupported_video_codec";
    // 传输只看 result[@"url"]：红果 cenc 本地代理的 originalURL 是 cenc://，
    // 可播地址在 url 字段里，查 originalURL 会误杀它。
    NSURL *url = [NSURL URLWithString:[result[@"url"] isKindOfClass:NSString.class] ? result[@"url"] : @""];
    NSString *transport = url.scheme.lowercaseString ?: @"";
    if (![MediaCapabilityNetworkTransports() containsObject:transport] && !url.isFileURL) return @"unsupported_transport";
    return nil;
}

NSArray<NSDictionary *> *MediaPlaybackDecodeRouteCandidatesForResult(NSDictionary *result, NSUInteger attemptedRoutes, BOOL forLive) {
    if (![result isKindOfClass:NSDictionary.class]) return @[];
    // 入口门禁命中则无候选（与 MediaDescriptor 同一判定；直播用 forLive 门禁，
    // 直播不走 MPV，MPV 可解的容器/编码在直播下仍拒绝）。
    if (MediaPlaybackDecodeRouteRejectionReasonForResult(result, forLive)) return @[];
    BOOL directMedia = MediaPlaybackResultIsDirectMedia(result);
    BOOL avSupported = MediaPlaybackResultSupportsAVPlayer(result);
    BOOL requiresWebPlayback = ([result[@"requiresWebPlayback"] boolValue] || [result[@"parse"] integerValue] > 0 || [result[@"jx"] integerValue] > 0) && !directMedia;
    NSString *decodeMode = MediaPlaybackDecodeLowerString([[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaDecodeMode.v1"] ?: @"auto");
    NSString *probedContainer = MediaPlaybackDecodeLowerString(result[@"probedContainer"]);
    if (!probedContainer.length && [result[@"headerBytes"] isKindOfClass:NSData.class]) {
        probedContainer = MediaPlaybackSniffContainerFormat(result[@"headerBytes"]) ?: @"";
    }
    BOOL probedCicadaOnly = [@[@"flv", @"live_flv", @"mkv", @"matroska", @"webm", @"3gp", @"3gpp", @"rtmp", @"mpegts"] containsObject:probedContainer];
    NSString *urlExt = MediaPlaybackDecodeResultExtension(result);
    BOOL rawProgressiveTS = ([urlExt isEqualToString:@"ts"] && ![MediaPlaybackDecodeResultFormat(result) isEqualToString:@"hls"] && ![MediaPlaybackDecodeResultFormat(result) isEqualToString:@"m3u8"]);
    BOOL preferCicada = probedCicadaOnly || rawProgressiveTS || [decodeMode isEqualToString:@"cicada"] || [decodeMode isEqualToString:@"cicada_soft"] || [MediaPlaybackDecodeLowerString(result[@"playbackEngine"]) isEqualToString:@"cicada"];
    BOOL legacyCicada = [decodeMode isEqualToString:@"cicada_legacy"];
    NSString *cicadaDecodeMode = ([decodeMode isEqualToString:@"cicada_soft"] || [result[@"preferSoftwareDecode"] boolValue]) ? @"cicada_soft" : @"cicada";

    // Parser and platform watch pages are documents, not media resources. Send
    // them straight to the in-app browser instead of making both native players
    // probe an HTML page before the browser fallback can appear. Live has no
    // in-app web player, so a live parse page has no candidate at all.
    if (requiresWebPlayback) {
        if (forLive) return @[];
        if (attemptedRoutes & MediaPlaybackDecodeRouteAttemptedWebView) return @[];
        return @[@{@"route": @(MediaPlaybackDecodeRouteWebView), @"decodeMode": @"webview", @"reason": @"web_page"}];
    }

    // Ordered VOD fallback: AVPlayer → MPV → Cicada → WebView.
    MediaPlaybackDecodeRoute candidates[] = { MediaPlaybackDecodeRouteAVPlayer, MediaPlaybackDecodeRouteMPV, MediaPlaybackDecodeRouteCicadaPlayer, MediaPlaybackDecodeRouteWebView };
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        MediaPlaybackDecodeRoute route = candidates[i];
        if (route == MediaPlaybackDecodeRouteMPV && !MediaPlaybackMPVRouteEnabled()) continue;
        // cicada_legacy 是历史遗留值：MPV 不参与，Cicada 恒在链内。
        if (route == MediaPlaybackDecodeRouteMPV && legacyCicada) continue;
        // 直播默认不走实验中的 MPV，也没有网页播放器。
        if (forLive && (route == MediaPlaybackDecodeRouteMPV || route == MediaPlaybackDecodeRouteWebView)) continue;
        // 直连媒体不进 WebView：耗尽后返回 None，走统一终态。
        if (route == MediaPlaybackDecodeRouteWebView && directMedia) continue;
        // AVPlayer only leads the chain for formats it can decode. For Cicada-only
        // containers (FLV/DASH/MKV/WebM/RTMP) MediaPlaybackResultSupportsAVPlayer
        // returns NO; attempting AVPlayer first wastes a full startup-watchdog
        // budget on a deterministically-failing leg. Skip it so the ordered
        // chain starts at MPV/Cicada.
        if (route == MediaPlaybackDecodeRouteAVPlayer && !avSupported) continue;
        NSUInteger bit = route == MediaPlaybackDecodeRouteAVPlayer ? MediaPlaybackDecodeRouteAttemptedAVPlayer :
            route == MediaPlaybackDecodeRouteMPV ? MediaPlaybackDecodeRouteAttemptedMPV :
            route == MediaPlaybackDecodeRouteCicadaPlayer ? MediaPlaybackDecodeRouteAttemptedCicadaPlayer : MediaPlaybackDecodeRouteAttemptedWebView;
        if (attemptedRoutes & bit) continue;
        NSString *decodeModeForRoute = route == MediaPlaybackDecodeRouteAVPlayer ? @"av" :
            route == MediaPlaybackDecodeRouteMPV ? @"mpv" :
            route == MediaPlaybackDecodeRouteCicadaPlayer ? cicadaDecodeMode : @"webview";
        NSString *reason = route == MediaPlaybackDecodeRouteAVPlayer ? @"av_supported" :
            route == MediaPlaybackDecodeRouteMPV ? @"mpv_preferred" :
            route == MediaPlaybackDecodeRouteCicadaPlayer ? (preferCicada ? @"cicada_preferred" : @"cicada_fallback") : @"web_page";
        [out addObject:@{@"route": @(route), @"decodeMode": decodeModeForRoute, @"reason": reason}];
    }
    // preferCicada 时 Cicada 排 MPV 之前：交换两者在候选中的位置。
    if (preferCicada) {
        NSUInteger mpvIndex = [out indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) { return [entry[@"route"] integerValue] == MediaPlaybackDecodeRouteMPV; }];
        NSUInteger cicadaIndex = [out indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) { return [entry[@"route"] integerValue] == MediaPlaybackDecodeRouteCicadaPlayer; }];
        if (mpvIndex != NSNotFound && cicadaIndex != NSNotFound && cicadaIndex > mpvIndex) [out exchangeObjectAtIndex:mpvIndex withObjectAtIndex:cicadaIndex];
    }
    return out;
}

MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult(NSDictionary *result, NSUInteger attemptedRoutes) {
    NSArray<NSDictionary *> *candidates = MediaPlaybackDecodeRouteCandidatesForResult(result, attemptedRoutes, NO);
    return candidates.count ? (MediaPlaybackDecodeRoute)[candidates[0][@"route"] integerValue] : MediaPlaybackDecodeRouteNone;
}

MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForLiveResult(NSDictionary *result, NSUInteger attemptedRoutes) {
    NSArray<NSDictionary *> *candidates = MediaPlaybackDecodeRouteCandidatesForResult(result, attemptedRoutes, YES);
    return candidates.count ? (MediaPlaybackDecodeRoute)[candidates[0][@"route"] integerValue] : MediaPlaybackDecodeRouteNone;
}

BOOL MediaPlaybackCicadaErrorAllowsSoftwareRetry(NSError *error) {
    // The SDK code families are defined in CicadaErrorCode.h. Only the
    // 0x2004xxxx codec family can benefit from rebuilding the decoder.
    // 0x2003xxxx demux and 0x2005xxxx network errors must advance the route.
    if (!error || error.code < 0) return NO;
    if (((NSUInteger)error.code & 0xFFFF0000) == 0x20040000) return YES;
    if (((NSUInteger)error.code & 0xFFFF0000) == 0x20030000 ||
        ((NSUInteger)error.code & 0xFFFF0000) == 0x20050000) return NO;
    NSString *message = error.localizedDescription.lowercaseString ?: @"";
    return [message containsString:@"decoder"] || [message containsString:@"avcodec"] ||
        [message containsString:@"hardware decode"] || [message containsString:@"解码器"];
}
