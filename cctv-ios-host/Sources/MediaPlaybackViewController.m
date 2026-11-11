#import "MediaPlaybackViewController.h"
#import "HostPlaybackProgress.h"
#import "MediaAPIClient.h"
#import "MediaNativePlaybackResolver.h"
#import "ServiceStore.h"
#import "MediaEpisodeSelectionViewController.h"
#import "MediaPlaybackHeaders.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackCicadaAdapter.h"
#import "MediaPlaybackBufferPolicy.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import "MediaPlaybackStateStore.h"
#import "TVBoxCatalogStore.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
static void MediaPlaybackApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

// A view-only fullscreen host keeps the same decoder, URL and playback session.
@interface MediaPlaybackFullscreenHost : UIViewController
@property(nonatomic,copy) dispatch_block_t onClose;
@end
@implementation MediaPlaybackFullscreenHost
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAllButUpsideDown;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];close.translatesAutoresizingMaskIntoConstraints=NO;close.tintColor=UIColor.whiteColor;close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];close.layer.cornerRadius=22;
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];close.accessibilityLabel=@"退出全屏";close.accessibilityIdentifier=@"media-cicada-close-fullscreen";[close addTarget:self action:@selector(closeFullscreen) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:close];
    [NSLayoutConstraint activateConstraints:@[[close.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],[close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],[close.widthAnchor constraintEqualToConstant:44],[close.heightAnchor constraintEqualToConstant:44]]];
}
- (void)closeFullscreen {__weak typeof(self) weakSelf=self;[self dismissViewControllerAnimated:YES completion:^{if(weakSelf.onClose)weakSelf.onClose();}];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isBeingDismissed&&self.onClose)self.onClose();}
@end

static void *CCTVPlayerItemStatusContext = &CCTVPlayerItemStatusContext;
static void *CCTVPlayerTimeControlContext = &CCTVPlayerTimeControlContext;
static void *CCTVPlayerLayerReadyContext = &CCTVPlayerLayerReadyContext;
static void *CCTVPlayerControllerReadyContext = &CCTVPlayerControllerReadyContext;
static NSUInteger const CCTVAutomaticRouteFallbackLimit = 16;
typedef NS_ENUM(NSInteger, MediaPlaybackPanMode) {
    MediaPlaybackPanModeNone,
    MediaPlaybackPanModeSeek,
    MediaPlaybackPanModeBrightness,
    MediaPlaybackPanModeVolume,
    MediaPlaybackPanModeUnsupported
};
static NSString *MediaPlaybackFailureKind(NSError *error, AVPlayerItemErrorLogEvent *networkError) {
    if (networkError.errorStatusCode >= 400) return @"upstream_http_error";
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut: return @"network_timeout";
            case NSURLErrorNotConnectedToInternet: return @"offline";
            case NSURLErrorResourceUnavailable: return @"resource_unavailable";
            case NSURLErrorFileDoesNotExist: return @"media_not_found";
            case NSURLErrorNoPermissionsToReadFile: return @"access_denied";
            default: return @"network_error";
        }
    }
    if([error.domain containsString:@"CoreMedia"])return @"media_stream_error";
    if([error.domain containsString:@"AVFoundation"]&&error.code==-11828)return @"media_open_failed";
    return @"player_error";
}
static NSString *MediaPlaybackFailureMessage(NSError *error, AVPlayerItemErrorLogEvent *networkError) {
    if (networkError.errorStatusCode >= 400)
        return [NSString stringWithFormat:@"上游媒体请求失败（HTTP %ld）· 请重试获取地址或切换线路", (long)networkError.errorStatusCode];
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut: return @"媒体请求超时 · 请检查网络或切换线路";
            case NSURLErrorResourceUnavailable: return @"此线路没有返回可用媒体资源 · 请重试或切换线路";
            case NSURLErrorFileDoesNotExist: return @"媒体地址已失效或不存在 · 请重试获取或切换线路";
            case NSURLErrorNoPermissionsToReadFile: return @"来源拒绝访问媒体 · 请重新获取播放地址或切换线路";
            case NSURLErrorNotConnectedToInternet: return @"当前网络不可用 · 恢复网络后重试";
            default: break;
        }
    }
    if([error.domain containsString:@"AVFoundation"]&&error.code==-11828)
        return @"iOS 无法打开这条媒体流 · 来源可能返回了不可解码内容或失效的清单/分片，请重试解析或切换线路";
    return [NSString stringWithFormat:@"媒体载入失败 · %@", error.localizedDescription.length ? error.localizedDescription : @"请重试或切换线路"];
}
static NSTimeInterval MediaPlaybackTimestamp(id value) {
    if(![value respondsToSelector:@selector(doubleValue)])return 0;
    NSTimeInterval timestamp=[value doubleValue];
    if(!isfinite(timestamp)||timestamp<=0)return 0;
    // Script APIs commonly return JavaScript Date.now() milliseconds while
    // native and Python plugins use Unix seconds. Normalize both here.
    if(timestamp>100000000000.0)timestamp/=1000.0;
    return timestamp;
}
static BOOL MediaPlaybackCachedResultIsFresh(NSDictionary *result, CFTimeInterval cachedAt) {
    if(!result||cachedAt<=0||CACurrentMediaTime()-cachedAt>=60.0)return NO;
    NSTimeInterval expires=MediaPlaybackTimestamp(result[@"expiresAt"]);
    return !isfinite(expires)||expires<=0||expires>NSDate.date.timeIntervalSince1970+15.0;
}
static NSInteger MediaPlaybackExplicitHTTPStatus(NSError *error) {
    if(!error)return 0;
    for(NSString *key in @[@"httpStatus",@"http_status",@"statusCode",@"status_code",@"HTTPStatus",@"network_error_status_code"]){
        id value=error.userInfo[key];
        if([value respondsToSelector:@selector(integerValue)]){
            NSInteger status=[value integerValue];
            if(status==401||status==403)return status;
        }
    }
    if(error.code==401||error.code==403)return error.code;
    NSString *message=error.localizedDescription?:@"";
    NSRegularExpression *expression=[NSRegularExpression regularExpressionWithPattern:@"(?i)(?:http(?:\\s+(?:status|code))?|status(?:\\s+code)?)\\s*[:=]?\\s*(401|403)\\b" options:0 error:NULL];
    NSTextCheckingResult *match=[expression firstMatchInString:message options:0 range:NSMakeRange(0,message.length)];
    return match.numberOfRanges>1?[[message substringWithRange:[match rangeAtIndex:1]] integerValue]:0;
}
static MediaAPIClient *MediaPlaybackClientForSource(NSDictionary *source) {
    id manifest=source[@"manifest"];
    id rawOptions=[manifest isKindOfClass:NSDictionary.class]?manifest[@"options"]:nil;
    if(!rawOptions)rawOptions=source[@"options"];
    NSDictionary *options=[rawOptions isKindOfClass:NSDictionary.class]?rawOptions:nil;
    if(!options&&[rawOptions isKindOfClass:NSString.class]){
        NSData *data=[rawOptions dataUsingEncoding:NSUTF8StringEncoding];
        id decoded=data.length<=65536?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if([decoded isKindOfClass:NSDictionary.class])options=decoded;
    }
    id rawTimeout=options[@"playTimeoutMs"];
    NSInteger timeout=15000;
    if([rawTimeout isKindOfClass:NSNumber.class])timeout=[rawTimeout integerValue];
    else if([rawTimeout isKindOfClass:NSString.class]){
        NSString *text=[rawTimeout stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner=[NSScanner scannerWithString:text];long long parsed=0;
        if(text.length&&[scanner scanLongLong:&parsed]&&scanner.isAtEnd&&parsed>0)timeout=parsed;
    }
    if(timeout<=0)timeout=15000;
    timeout=MIN(120000,MAX(1000,timeout));
    NSURL *scriptURL=[source[@"url"] isKindOfClass:NSString.class]?[NSURL URLWithString:source[@"url"]]:nil;
    if([scriptURL.host.lowercaseString isEqual:@"raw.githubusercontent.com"]&&[scriptURL.path.lowercaseString isEqual:@"/joeshu/for-adm/master/cctvhost/yqk.js"])timeout=MAX(timeout,60000);
    NSString *catalogID=[ServiceStore playbackParserCatalogIDForSource:source];MediaAPIClient *client=MediaSourceUsesNativeCatalogAPI(source)?[[MediaAPIClient alloc] initWithTVBoxSource:source?:@{}]:[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue] catalogID:catalogID];
    client.playTimeoutMilliseconds=timeout;
    return client;
}
static NSString *MediaPlaybackSelectedParserID(NSDictionary *context) {
    NSDictionary *source=[context[@"source"] isKindOfClass:NSDictionary.class]?context[@"source"]:@{};NSString *sourceID=[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:([source[@"api"] isKindOfClass:NSString.class]?source[@"api"]:@"default");
    NSString *catalogID=[ServiceStore playbackParserCatalogIDForSource:source];catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!catalogID.length)return @"";
    NSString *selected=[context[@"parserID"] isKindOfClass:NSString.class]?context[@"parserID"]:@"";if(!selected.length)selected=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"cctv.media.parser.%@",sourceID]]?:@"";
    for(NSDictionary *parser in [TVBoxCatalogStore playbackParsersForCatalogID:catalogID])if([parser[@"id"] isEqual:selected])return selected;return @"";
}
static NSDictionary *MediaPlaybackDiagnosticSourceFields(NSURL *url) {
    if(!RuntimeDiagnostics.shared.enabled||!url)return @{};
    NSString *host=url.host.lowercaseString?:@"";
    BOOL loopback=[host isEqualToString:@"127.0.0.1"]||[host isEqualToString:@"localhost"]||[host isEqualToString:@"::1"];
    NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];NSMutableOrderedSet<NSString *> *names=[NSMutableOrderedSet orderedSet];BOOL hasSignedParameter=NO;
    for(NSURLQueryItem *item in parts.queryItems?:@[]){NSString *name=item.name.lowercaseString?:@"";if(!name.length)continue;if(names.count<24)[names addObject:item.name];NSString *compact=[[name stringByReplacingOccurrencesOfString:@"_" withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];if([name hasPrefix:@"x-amz-"]||[name hasPrefix:@"x-oss-"]||[compact containsString:@"token"]||[compact containsString:@"sign"]||[compact containsString:@"auth"]||[compact containsString:@"ticket"]||[compact containsString:@"secret"]||[compact containsString:@"credential"]||[compact containsString:@"policy"]||[compact containsString:@"expires"]||[compact containsString:@"expire"]||[compact containsString:@"deadline"]||[compact containsString:@"hdnea"]||[compact hasSuffix:@"key"]||[@[@"key",@"keyid",@"apikey",@"hash",@"st",@"e"] containsObject:compact])hasSignedParameter=YES;}
    return @{@"source_scheme":url.scheme.lowercaseString?:@"",@"source_host":host,@"source_port":url.port?:@0,@"source_extension":url.pathExtension.lowercaseString?:@"",@"source_is_loopback":@(loopback),@"playback_parameter_count":@(parts.queryItems.count),@"playback_parameter_names":names.array,@"playback_has_signed_parameter":@(hasSignedParameter)};
}
static void MediaPlaybackAddAccessLogFields(NSMutableDictionary *fields, AVPlayerItem *item) {
    if (!fields || !item || !RuntimeDiagnostics.shared.enabled) return;
    fields[@"preferred_forward_buffer_seconds"]=@(MAX(0,item.preferredForwardBufferDuration));
    fields[@"playback_likely_to_keep_up"]=@(item.isPlaybackLikelyToKeepUp);
    double position=CMTimeGetSeconds(item.currentTime),buffered=0;
    if(isfinite(position))for(NSValue *value in item.loadedTimeRanges){CMTimeRange range=value.CMTimeRangeValue;double start=CMTimeGetSeconds(range.start),end=CMTimeGetSeconds(CMTimeRangeGetEnd(range));if(isfinite(start)&&isfinite(end)&&start<=position+0.1&&end>position)buffered=MAX(buffered,end-position);}
    fields[@"media_buffered_ahead_seconds"]=@(buffered);
    AVPlayerItemAccessLog *accessLog = item.accessLog;
    NSArray<AVPlayerItemAccessLogEvent *> *events = accessLog.events ?: @[];
    fields[@"access_log_event_count"] = @(events.count);
    AVPlayerItemAccessLogEvent *event = events.lastObject;
    if (event) {
        fields[@"media_requests"] = @(MAX(0, event.numberOfMediaRequests));
        fields[@"media_bytes_transferred"] = @(MAX(0, event.numberOfBytesTransferred));
        fields[@"media_stall_count"] = @(MAX(0, event.numberOfStalls));
        fields[@"media_dropped_video_frames"] = @(MAX(0, event.numberOfDroppedVideoFrames));
        double transferDuration = event.transferDuration;
        double observedBitrate = event.observedBitrate;
        double indicatedBitrate = event.indicatedBitrate;
        double startupTime = event.startupTime;
        if (isfinite(transferDuration) && transferDuration >= 0) fields[@"media_transfer_duration_seconds"] = @(transferDuration);
        if (isfinite(observedBitrate) && observedBitrate >= 0) fields[@"media_observed_bitrate_bps"] = @(observedBitrate);
        if (isfinite(indicatedBitrate) && indicatedBitrate >= 0) fields[@"media_indicated_bitrate_bps"] = @(indicatedBitrate);
        if (isfinite(startupTime) && startupTime >= 0) fields[@"media_reported_startup_seconds"] = @(startupTime);
    }
    CGSize size = item.presentationSize;
    if (isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0) {
        fields[@"video_presentation_width"] = @((NSInteger)llround(size.width));
        fields[@"video_presentation_height"] = @((NSInteger)llround(size.height));
    }
}
static NSURL *MediaPlaybackOriginalSourceURL(NSDictionary *result) {
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:nil;
    if(!raw.length)raw=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";
    return [NSURL URLWithString:raw];
}
static NSDictionary *MediaPlaybackAVAssetHeaders(NSDictionary *result, NSURL *url) {
    NSDictionary *headers=MediaPlaybackHeadersFromResult(result);
    NSString *host=url.host.lowercaseString?:@"";
    BOOL loopback=[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:host];
    // The local service already owns the upstream headers; do not send source
    // credentials back to loopback. Warming and playback must use identical options.
    if(loopback)return [MediaPlaybackOriginalSourceURL(result).absoluteString isEqualToString:url.absoluteString]?headers:@{};
    if(!headers.count)return @{@"User-Agent":@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"};
    return headers;
}
static NSURL *MediaPlaybackEpisodePageFallbackURL(NSDictionary *episode) {
    NSString *raw=[episode[@"id"] isKindOfClass:NSString.class]?episode[@"id"]:@"";
    if(!raw.length||raw.length>8192||[raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:raw];
    if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length)return nil;
    if(MediaPlaybackResultSupportsNativePlayback(@{@"url":raw}))return nil;
    return parts.URL;
}
static NSString *MediaPlaybackEpisodeNumber(NSString *value) {
    if(!value.length)return @"";
    NSArray<NSString *> *patterns=@[@"(?i)s\\d+\\s*e\\s*0*(\\d{1,4})",
                                    @"(?i)(?:第\\s*)?0*(\\d{1,4})\\s*(?:集|话|期)",
                                    @"(?i)(?:episode|ep)\\s*0*(\\d{1,4})",
                                    @"^\\s*0*(\\d{1,4})\\s*$"];
    for(NSString *pattern in patterns){
        NSRegularExpression *expression=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
        NSTextCheckingResult *match=[expression firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
        if(match.numberOfRanges>1){NSString *digits=[value substringWithRange:[match rangeAtIndex:1]];return [NSString stringWithFormat:@"%ld",(long)digits.integerValue];}
    }
    return @"";
}
static BOOL MediaPlaybackEpisodeNamesMatch(NSString *left,NSString *right) {
    if(!left.length||!right.length)return NO;
    if([left localizedCaseInsensitiveCompare:right]==NSOrderedSame)return YES;
    NSString *leftNumber=MediaPlaybackEpisodeNumber(left),*rightNumber=MediaPlaybackEpisodeNumber(right);
    return leftNumber.length&&[leftNumber isEqualToString:rightNumber];
}

static NSData *MediaPlaybackNormalizedAES128KeyData(NSData *rawData, NSString *fallbackHexOrB64) {
    NSString *candidate = nil;
    if (rawData.length == 16) return rawData;
    if (rawData.length > 0 && rawData.length <= 4096) {
        candidate = [[[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([candidate hasPrefix:@"{"] && [candidate hasSuffix:@"}"]) {
            NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:rawData options:0 error:NULL];
            if ([obj isKindOfClass:NSDictionary.class]) {
                id k = obj[@"key"] ?: obj[@"data"] ?: obj[@"k"];
                if ([k isKindOfClass:NSString.class]) candidate = [(NSString *)k stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            }
        }
    }
    if (!candidate.length && fallbackHexOrB64.length) {
        candidate = [fallbackHexOrB64 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (!candidate.length) return rawData;
    NSRange colon = [candidate rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound && colon.location + 1 < candidate.length) {
        candidate = [candidate substringFromIndex:colon.location + 1];
    }
    if ([candidate.lowercaseString hasPrefix:@"0x"]) candidate = [candidate substringFromIndex:2];
    if (candidate.length == 32) {
        NSMutableData *hexData = [NSMutableData dataWithCapacity:16];
        BOOL validHex = YES;
        for (NSUInteger i = 0; i < 32; i += 2) {
            unsigned int byteVal = 0;
            NSScanner *scanner = [NSScanner scannerWithString:[candidate substringWithRange:NSMakeRange(i, 2)]];
            if (![scanner scanHexInt:&byteVal]) { validHex = NO; break; }
            uint8_t b = (uint8_t)byteVal;
            [hexData appendBytes:&b length:1];
        }
        if (validHex && hexData.length == 16) return hexData.copy;
    }
    if (candidate.length >= 20 && candidate.length <= 28) {
        NSString *b64 = [[candidate stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        while (b64.length % 4 != 0) b64 = [b64 stringByAppendingString:@"="];
        NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (dec.length == 16) return dec;
    }
    return rawData;
}

@interface MediaPlaybackViewController () <UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate, MediaPlaybackCicadaAdapterDelegate, AVAssetResourceLoaderDelegate>
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerViewController *playerController;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIView *cicadaControls;
@property(nonatomic,strong) UIButton *cicadaPlayPauseButton;
@property(nonatomic,strong) UIButton *cicadaRewindButton;
@property(nonatomic,strong) UIButton *cicadaForwardButton;
@property(nonatomic,strong) UIButton *cicadaRateButton;
@property(nonatomic,strong) UIButton *cicadaOptionsButton;
@property(nonatomic,strong) UIButton *cicadaFullscreenButton;
@property(nonatomic,strong) UISlider *cicadaSeekSlider;
@property(nonatomic,strong) UILabel *cicadaElapsedLabel;
@property(nonatomic,strong) UILabel *cicadaDurationLabel;
@property(nonatomic) BOOL cicadaScrubbing;
@property(nonatomic) BOOL cicadaScrubWasPlaying;
@property(nonatomic,strong) MediaPlaybackFullscreenHost *cicadaFullscreenHost;
@property(nonatomic,weak) UIView *cicadaVideoOriginalSuperview;
@property(nonatomic) NSUInteger cicadaVideoOriginalIndex;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *cicadaFullscreenSavedConstraints;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *cicadaFullscreenConstraints;
@property(nonatomic,strong) UILabel *throughputLabel;
@property(nonatomic,strong) UIView *gestureSurface;
@property(nonatomic,strong) UILabel *gestureFeedbackLabel;
@property(nonatomic,strong) UIView *inlineNowPlayingPill;
@property(nonatomic,strong) UILabel *inlineNowPlayingLabel;
@property(nonatomic) NSUInteger gestureFeedbackGeneration;
@property(nonatomic) BOOL gestureRateActive;
@property(nonatomic) BOOL gestureLockActive;
@property(nonatomic,strong) UIButton *screenLockButton;
@property(nonatomic,strong) NSTimer *mediaSleepTimer;
@property(nonatomic) NSInteger mediaSleepMinutes;
@property(nonatomic) float gesturePreviousRate;
@property(nonatomic,strong) UIPanGestureRecognizer *playbackPanGesture;
@property(nonatomic,strong) UITapGestureRecognizer *playbackDoubleTapGesture;
@property(nonatomic,strong) UILongPressGestureRecognizer *playbackLongPressGesture;
@property(nonatomic,strong) MPVolumeView *volumeView;
@property(nonatomic,weak) UISlider *volumeSlider;
@property(nonatomic) CGPoint panStartPoint;
@property(nonatomic) NSTimeInterval panStartTime;
@property(nonatomic) NSTimeInterval panTargetTime;
@property(nonatomic) CGFloat panStartValue;
@property(nonatomic) MediaPlaybackPanMode panMode;
@property(nonatomic) CGFloat videoAspectRatio;
@property(nonatomic) BOOL tallVideoViewportLayout;
@property(nonatomic) CGFloat embeddedVideoAspectRatio;
@property(nonatomic,strong) UIView *controlPanel;
@property(nonatomic,strong) UIScrollView *lineScroll;
@property(nonatomic,strong) UIStackView *lineButtons;
@property(nonatomic,strong) UIStackView *qualityGroup;
@property(nonatomic,strong) UILabel *qualityLabel;
@property(nonatomic,strong) UIScrollView *qualityScroll;
@property(nonatomic,strong) UIStackView *qualityButtons;
@property(nonatomic,strong) UILabel *episodeTitle;
@property(nonatomic,strong) UIButton *episodeButton;
@property(nonatomic,strong) UIButton *nextEpisodeButton;
@property(nonatomic,strong) UIButton *playbackSpeedButton;
@property(nonatomic,strong) UIStackView *playbackActionRow;
@property(nonatomic,strong) UIButton *skipButton;
@property(nonatomic,strong) UIButton *inlineRetryButton;
@property(nonatomic,strong) UIButton *inlineParserButton;
@property(nonatomic,strong) UIButton *inlineOptionsButton;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong,nullable) MediaPlaybackCicadaAdapter *cicadaAdapter;
@property(nonatomic,strong,nullable) MediaNativePlaybackResolver *nativeResolver;
@property(nonatomic,strong,nullable) NSDictionary *validatedPlaybackResult;
@property(nonatomic) NSUInteger nativeLeaseGeneration;
@property(nonatomic) BOOL nativeSessionRefreshInFlight;
@property(nonatomic) BOOL nativeSessionRefreshAttempted;
@property(nonatomic,copy) NSString *nativeSessionRefreshURL;
@property(nonatomic) double cicadaAdapterDownloadBPS; // 适配器上报的下载速度，单位 bit/s（除以 8 得字节/秒）
@property(nonatomic) BOOL cicadaAdapterSoftwareDecodeFallbackAttempted; // 适配器路径已试过软件解码重试
@property(nonatomic) NSUInteger attemptedRoutes; // 已尝试的路由位掩码，见路由头文件
@property(nonatomic) NSTimeInterval cicadaPosition;
@property(nonatomic) NSTimeInterval cicadaDuration;
@property(nonatomic) NSInteger lineIndex;
@property(nonatomic) NSInteger episodeIndex;
@property(nonatomic) BOOL resolving;
@property(nonatomic) BOOL observingPlayer;
@property(nonatomic,strong) AVPlayerItem *observedItem;
@property(nonatomic) BOOL landscapeLayout;
@property(nonatomic) BOOL playbackLayoutInitialized;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *portraitConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *landscapeConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *embeddedConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *embeddedSurfaceConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *embeddedControlConstraints;
@property(nonatomic) BOOL floatingInlineSurfaceInstalled;
@property(nonatomic,strong) NSLayoutConstraint *videoAspectConstraint;
@property(nonatomic,strong) NSLayoutConstraint *portraitTallViewportHeightConstraint;
@property(nonatomic,strong) NSLayoutConstraint *landscapeTallViewportHeightConstraint;
@property(nonatomic,strong) NSLayoutConstraint *throughputPortraitTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *throughputViewportTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *gestureFeedbackPortraitTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *gestureFeedbackViewportTopConstraint;
@property(nonatomic,strong) CAGradientLayer *videoTopScrim;
@property(nonatomic,strong) NSLayoutConstraint *embeddedTallVideoAspectConstraint;
@property(nonatomic,copy) NSDictionary *pendingEpisodeResult;
@property(nonatomic) NSUInteger pendingEpisodeGeneration;
@property(nonatomic) BOOL pictureInPictureActive;
@property(nonatomic) BOOL pictureInPictureExitPending;
@property(nonatomic,strong) AVPlayerLayer *videoLayer;
@property(nonatomic) BOOL observingVideoLayer;
@property(nonatomic) BOOL observingPlayerControllerReady;
@property(nonatomic) CFTimeInterval playbackStartedAt;
@property(nonatomic,strong) NSTimer *avFirstFrameTimer;
@property(nonatomic) CFTimeInterval avFirstFrameLastCheck;
@property(nonatomic) NSTimeInterval avFirstFrameActiveWait;
@property(nonatomic) NSUInteger playerGeneration;
@property(nonatomic) BOOL terminalPlaybackOutcomeRecorded;
@property(nonatomic) BOOL pendingScreenExit;
@property(nonatomic) BOOL hasVideoTrack;
@property(nonatomic) BOOL confirmedAudioOnly;
@property(nonatomic) BOOL videoTrackInspectionStarted;
@property(nonatomic) BOOL videoFrameReady;
@property(nonatomic) HostPlaybackProgress progressEvidence;
@property(nonatomic) NSUInteger progressMilestone;
@property(nonatomic) NSUInteger diagnosticStallCount;
@property(nonatomic) BOOL progressSummaryRecorded;
@property(nonatomic,copy) NSString *playbackAttemptID;
@property(nonatomic) BOOL playbackFailureRecorded;
@property(nonatomic) NSInteger lastDiagnosticTimeControlStatus;
@property(nonatomic) BOOL hasDiagnosticTimeControlStatus;
@property(nonatomic) NSInteger selectedAlternateIndex;
@property(nonatomic,strong) NSMutableIndexSet *automaticFallbackTriedLineIndexes;
@property(nonatomic,strong) NSMutableIndexSet *automaticFallbackTriedAlternateIndexes;
@property(nonatomic) BOOL episodeWebFallbackAvailable;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,copy) NSString *pendingResolutionReason;
@property(nonatomic,strong) UIBarButtonItem *playbackOptionsItem;
@property(nonatomic,strong) UIBarButtonItem *retryItem;
@property(nonatomic,strong) UIBarButtonItem *parserSelectionItem;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *basePlaybackHeaders;
@property(nonatomic,strong) id progressTimeObserver;
@property(nonatomic,copy) NSDictionary *resumeEntry;
@property(nonatomic,copy) NSDictionary *pendingPlaybackResumeEntry;
@property(nonatomic,strong) NSNumber *pendingPlaybackSeekTime;
@property(nonatomic,strong) NSNumber *pendingQualitySeekTime;
@property(nonatomic) BOOL pendingQualityRestorePlaybackState;
@property(nonatomic) BOOL pendingQualityWasPlaying;
@property(nonatomic) NSUInteger stallRecoveryAttempts;
@property(nonatomic) NSTimeInterval lastPersistedPosition;
@property(nonatomic) BOOL resumePromptPending;
@property(nonatomic) BOOL resumePromptShown;
@property(nonatomic,copy) NSString *skipButtonAction;
@property(nonatomic) NSInteger autoSkippedIntroEpisodeIndex;
@property(nonatomic) NSInteger autoSkippedOutroEpisodeIndex;
@property(nonatomic,copy,nullable) NSDictionary *autoSkipContext;
@property(nonatomic) BOOL previousIdleTimerDisabled;
@property(nonatomic) BOOL idleTimerOverrideActive;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundAutoAdvanceTask;
@property(nonatomic) BOOL isAutoAdvancingEpisode;
@property(nonatomic,strong,nullable) MediaAPIClient *prefetchClient;
@property(nonatomic,strong) AVURLAsset *prefetchedAsset;
@property(nonatomic,copy) NSDictionary *prefetchedAssetHeaders;
@property(nonatomic,copy) NSString *prefetchedAssetIdentity;
@property(nonatomic) CFTimeInterval prefetchedAssetAt;
@property(nonatomic) NSTimeInterval prefetchedAssetExpiresAt;
@property(nonatomic,copy) NSString *prefetchedEpisodeIdentity;
@property(nonatomic) CFTimeInterval prefetchLastAttemptAt;
@property(nonatomic) BOOL startupBufferKickUsed;
@property(nonatomic) BOOL playbackMemoryConstrained;
@property(nonatomic) BOOL cicadaWasLoading;
@property(nonatomic) BOOL playbackSuspendedForVisibility;
@property(nonatomic,copy,nullable) NSDictionary *prefetchedEpisodeResult;
@property(nonatomic) NSInteger prefetchedLineIndex;
@property(nonatomic) NSInteger prefetchedEpisodeIndex;
@property(nonatomic) CFTimeInterval prefetchedAt;
@property(nonatomic) BOOL prefetchInFlight;
@property(nonatomic) NSUInteger prefetchGeneration;
@property(nonatomic,copy) NSString *prefetchRequestedIdentity;
@property(nonatomic) NSInteger prefetchRequestedLineIndex;
@property(nonatomic) NSInteger prefetchRequestedEpisodeIndex;
@property(nonatomic,copy) void (^promotedPrefetchCompletion)(id result,NSError *error);
- (void)prefetchNextEpisodeIfNeeded;
- (void)stopObservingCurrentPlayback;
- (void)observePlayerLayerIfAvailable;
- (void)inspectVideoTracksForItem:(AVPlayerItem *)item generation:(NSUInteger)generation;
- (AVPlayerLayer *)playerLayerInLayerTree:(CALayer *)root;
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item;
- (void)scheduleNativeSessionRefreshForResult:(NSDictionary *)result;
- (BOOL)refreshNativeSessionForReason:(NSString *)reason httpStatus:(NSInteger)httpStatus error:(NSError *)error;
- (void)buildQualityButtons;
- (void)updateEstimatedThroughput;
- (UIMenu *)mediaSelectionMenuForCharacteristic:(AVMediaCharacteristic)characteristic title:(NSString *)title;
- (void)selectAlternate:(UIButton *)sender;
- (void)setRetryAvailable:(BOOL)available;
- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage;
- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration;
- (void)watchAVPlayerFirstFrameForItem:(AVPlayerItem *)item generation:(NSUInteger)playerGeneration url:(NSURL *)url sourceURL:(NSURL *)sourceURL;
- (BOOL)isApplicationActiveForAVFirstFrameWatchdog;
- (void)teardownCicadaAdapter;
- (void)advanceFromCicadaFailureWithError:(NSError *)error;
- (void)handleCicadaFirstFrameTimeoutForAdapter:(id)adapter;
- (void)offerResumeForCicada;
- (void)applyPendingPlaybackSeekForCicada;
- (void)markCicadaFirstFrameReady;
- (void)installCicadaControls;
- (void)refreshCicadaControls;
- (void)restoreVideoFromCicadaFullscreen;
- (BOOL)isCicadaEngineActive;
- (NSTimeInterval)activeEngineCurrentPosition;
- (NSTimeInterval)activeEngineDuration;
- (void)seekActiveEngineToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion;
- (void)setActiveEngineRate:(float)rate;
- (void)pauseActiveEngine;
- (void)playActiveEngine;
- (void)recordPlaybackAttemptOutcome:(NSString *)outcome failureKind:(NSString *)failureKind httpStatus:(NSInteger)httpStatus terminal:(BOOL)terminal;
- (void)configurePlaybackOptions;
- (UIMenu *)playbackRateMenu;
- (void)updatePlaybackLayoutForSize:(CGSize)size;
- (void)handlePlaybackPan:(UIPanGestureRecognizer *)recognizer;
- (void)prepareVolumeSlider;
- (UISlider *)volumeSliderInView:(UIView *)view;
- (NSString *)formatMediaTime:(NSTimeInterval)time;
- (void)persistPlaybackProgress;
- (void)updateSkipButtonForCurrentPosition;
- (void)offerResumeForItem:(AVPlayerItem *)item;
- (void)resetAutomaticFallbackLines;
- (BOOL)tryNextAlternateForAutomaticFallback:(NSString *)reason;
- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason;
- (void)activateBackgroundAudioSessionIfNeeded;
- (void)beginBackgroundAutoAdvanceTaskIfNeeded;
- (void)endBackgroundAutoAdvanceTaskIfNeeded;
- (void)applicationWillEnterForeground:(NSNotification *)notification;
- (void)updateNowPlayingInfoCenter;
@end

@implementation MediaPlaybackViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAllButUpsideDown;}
- (NSDictionary *)currentSeason {
    NSDictionary *detail=[self.context[@"detail"] isKindOfClass:NSDictionary.class]?self.context[@"detail"]:@{};
    NSArray *seasons=[detail[@"seasons"] isKindOfClass:NSArray.class]?detail[@"seasons"]:@[];
    id seasonValue=self.context[@"seasonIndex"];
    if(![seasonValue respondsToSelector:@selector(integerValue)])return @{};
    NSInteger index=[seasonValue integerValue];
    return index>=0&&index<seasons.count&&[seasons[(NSUInteger)index] isKindOfClass:NSDictionary.class]?seasons[(NSUInteger)index]:@{};
}
- (NSArray *)lines {
    NSArray *seasonLines=[self.currentSeason[@"lines"] isKindOfClass:NSArray.class]?self.currentSeason[@"lines"]:@[];
    NSDictionary *detail=[self.context[@"detail"] isKindOfClass:NSDictionary.class]?self.context[@"detail"]:@{};
    NSArray *detailLines=[detail[@"lines"] isKindOfClass:NSArray.class]?detail[@"lines"]:@[];
    NSArray *raw=seasonLines.count?seasonLines:detailLines;
    NSMutableArray *clean=[NSMutableArray arrayWithCapacity:raw.count];for(id line in raw)[clean addObject:[line isKindOfClass:NSDictionary.class]?line:@{}];return clean;
}
- (NSArray *)episodes {
    NSArray *lines=self.lines;
    NSArray *raw=@[];
    if(self.lineIndex>=0&&self.lineIndex<lines.count){NSArray *lineEpisodes=[lines[(NSUInteger)self.lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[(NSUInteger)self.lineIndex][@"episodes"]:@[];if(lineEpisodes.count)raw=lineEpisodes;}
    if(!raw.count)raw=[self.currentSeason[@"episodes"] isKindOfClass:NSArray.class]?self.currentSeason[@"episodes"]:@[];
    NSMutableArray *clean=[NSMutableArray arrayWithCapacity:raw.count];for(id episode in raw)[clean addObject:[episode isKindOfClass:NSDictionary.class]?episode:@{}];return clean;
}
- (instancetype)init {if((self=[super init])){_lineIndex=0;_episodeIndex=0;_selectedAlternateIndex=-1;_prefetchedLineIndex=-1;_prefetchedEpisodeIndex=-1;_backgroundAutoAdvanceTask=UIBackgroundTaskInvalid;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.autoSkippedIntroEpisodeIndex=-1;self.autoSkippedOutroEpisodeIndex=-1;
    self.diagnosticTraceID=[self.context[@"correlationID"] isKindOfClass:NSString.class]&&[self.context[@"correlationID"] length]?self.context[@"correlationID"]:NSUUID.UUID.UUIDString.lowercaseString;
    self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];
    if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;
    if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;
    [self resetAutomaticFallbackLines];
    self.title=self.context[@"detail"][@"name"]?:self.context[@"item"][@"name"]?:@"影视播放";self.navigationItem.titleView=[UIView new];
    NSDictionary *source=self.context[@"source"]?:@{};self.client=MediaPlaybackClientForSource(source);
    [self configurePlaybackOptions];

    self.videoView=[UIView new];self.videoView.translatesAutoresizingMaskIntoConstraints=NO;self.videoView.backgroundColor=UIColor.blackColor;self.videoView.layer.cornerRadius=10;self.videoView.clipsToBounds=YES;[self.view addSubview:self.videoView];
    self.playerController=[AVPlayerViewController new];self.playerController.delegate=self;self.playerController.allowsPictureInPicturePlayback=YES;[self addChildViewController:self.playerController];self.playerController.view.translatesAutoresizingMaskIntoConstraints=NO;[self.videoView addSubview:self.playerController.view];[self.playerController didMoveToParentViewController:self];
    [NSLayoutConstraint activateConstraints:@[[self.playerController.view.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[self.playerController.view.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[self.playerController.view.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[self.playerController.view.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];
    [self installCicadaControls];
    self.videoTopScrim=[CAGradientLayer layer];self.videoTopScrim.colors=@[(id)UIColor.clearColor.CGColor,(id)UIColor.clearColor.CGColor];self.videoTopScrim.locations=@[@0.0,@1.0];self.videoTopScrim.startPoint=CGPointMake(0.5,0);self.videoTopScrim.endPoint=CGPointMake(0.5,1);self.videoTopScrim.hidden=YES;self.videoTopScrim.opacity=0.0f;self.videoTopScrim.name=@"media-playback-top-scrim";[self.videoView.layer addSublayer:self.videoTopScrim];
    self.throughputLabel=[UILabel new];self.throughputLabel.translatesAutoresizingMaskIntoConstraints=NO;self.throughputLabel.text=@"测速中";self.throughputLabel.textColor=UIColor.whiteColor;self.throughputLabel.font=HostMonospacedDigitFont(11,UIFontWeightSemibold,UIFontTextStyleCaption2);self.throughputLabel.textAlignment=NSTextAlignmentCenter;self.throughputLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.68];self.throughputLabel.layer.cornerRadius=11;self.throughputLabel.layer.borderWidth=0.5;self.throughputLabel.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;self.throughputLabel.clipsToBounds=YES;self.throughputLabel.userInteractionEnabled=NO;self.throughputLabel.accessibilityIdentifier=@"media-playback-throughput";self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;[self.videoView addSubview:self.throughputLabel];self.throughputPortraitTopConstraint=[self.throughputLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor constant:8];self.throughputViewportTopConstraint=[self.throughputLabel.topAnchor constraintEqualToAnchor:self.videoView.topAnchor constant:10];self.throughputViewportTopConstraint.active=NO;[NSLayoutConstraint activateConstraints:@[self.throughputPortraitTopConstraint,[self.throughputLabel.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor constant:-10],[self.throughputLabel.heightAnchor constraintGreaterThanOrEqualToConstant:24],[self.throughputLabel.widthAnchor constraintGreaterThanOrEqualToConstant:68]]];
    self.gestureFeedbackLabel=[UILabel new];self.gestureFeedbackLabel.translatesAutoresizingMaskIntoConstraints=NO;self.gestureFeedbackLabel.hidden=YES;self.gestureFeedbackLabel.textAlignment=NSTextAlignmentCenter;self.gestureFeedbackLabel.textColor=UIColor.whiteColor;self.gestureFeedbackLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];self.gestureFeedbackLabel.adjustsFontForContentSizeCategory=YES;self.gestureFeedbackLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.72];self.gestureFeedbackLabel.layer.cornerRadius=14;self.gestureFeedbackLabel.clipsToBounds=YES;self.gestureFeedbackLabel.isAccessibilityElement=NO;UIView *gestureSurface=self.videoView;[gestureSurface addSubview:self.gestureFeedbackLabel];self.gestureFeedbackPortraitTopConstraint=[self.gestureFeedbackLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor constant:8];self.gestureFeedbackViewportTopConstraint=[self.gestureFeedbackLabel.topAnchor constraintEqualToAnchor:gestureSurface.topAnchor constant:16];self.gestureFeedbackViewportTopConstraint.active=NO;[NSLayoutConstraint activateConstraints:@[[self.gestureFeedbackLabel.centerXAnchor constraintEqualToAnchor:gestureSurface.centerXAnchor],self.gestureFeedbackPortraitTopConstraint,[self.gestureFeedbackLabel.heightAnchor constraintEqualToConstant:34],[self.gestureFeedbackLabel.widthAnchor constraintGreaterThanOrEqualToConstant:112]]];
    self.inlineNowPlayingPill=[UIView new];self.inlineNowPlayingPill.translatesAutoresizingMaskIntoConstraints=NO;self.inlineNowPlayingPill.hidden=YES;self.inlineNowPlayingPill.alpha=0.0;self.inlineNowPlayingPill.userInteractionEnabled=NO;self.inlineNowPlayingPill.backgroundColor=[UIColor colorWithWhite:0 alpha:.72];self.inlineNowPlayingPill.layer.cornerRadius=9;self.inlineNowPlayingPill.layer.cornerCurve=kCACornerCurveContinuous;self.inlineNowPlayingPill.isAccessibilityElement=YES;self.inlineNowPlayingPill.accessibilityIdentifier=@"media-inline-now-playing";self.inlineNowPlayingPill.accessibilityHint=@"滚动影片详情时仍显示当前播放集数";[self.videoView addSubview:self.inlineNowPlayingPill];
    self.inlineNowPlayingLabel=[UILabel new];self.inlineNowPlayingLabel.translatesAutoresizingMaskIntoConstraints=NO;self.inlineNowPlayingLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];self.inlineNowPlayingLabel.textColor=UIColor.whiteColor;self.inlineNowPlayingLabel.numberOfLines=1;self.inlineNowPlayingLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.inlineNowPlayingLabel.isAccessibilityElement=NO;[self.inlineNowPlayingPill addSubview:self.inlineNowPlayingLabel];[self.inlineNowPlayingLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[[self.inlineNowPlayingPill.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor constant:12],[self.inlineNowPlayingPill.trailingAnchor constraintLessThanOrEqualToAnchor:self.videoView.trailingAnchor constant:-12],[self.inlineNowPlayingPill.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:-50],[self.inlineNowPlayingPill.heightAnchor constraintGreaterThanOrEqualToConstant:28],[self.inlineNowPlayingPill.widthAnchor constraintLessThanOrEqualToAnchor:self.videoView.widthAnchor constant:-24],[self.inlineNowPlayingLabel.leadingAnchor constraintEqualToAnchor:self.inlineNowPlayingPill.leadingAnchor constant:9],[self.inlineNowPlayingLabel.trailingAnchor constraintEqualToAnchor:self.inlineNowPlayingPill.trailingAnchor constant:-9],[self.inlineNowPlayingLabel.topAnchor constraintEqualToAnchor:self.inlineNowPlayingPill.topAnchor constant:5],[self.inlineNowPlayingLabel.bottomAnchor constraintEqualToAnchor:self.inlineNowPlayingPill.bottomAnchor constant:-5]]];
    self.screenLockButton=[UIButton buttonWithType:UIButtonTypeSystem];self.screenLockButton.translatesAutoresizingMaskIntoConstraints=NO;[self.screenLockButton setImage:[UIImage systemImageNamed:@"lock.open"] forState:UIControlStateNormal];self.screenLockButton.tintColor=UIColor.whiteColor;self.screenLockButton.backgroundColor=[UIColor colorWithWhite:0 alpha:0.58];self.screenLockButton.layer.cornerRadius=18;self.screenLockButton.layer.cornerCurve=kCACornerCurveContinuous;self.screenLockButton.layer.borderWidth=0.7;self.screenLockButton.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.2].CGColor;self.screenLockButton.accessibilityIdentifier=@"media-playback-lock-button";self.screenLockButton.accessibilityLabel=@"锁定或解锁播放画面手势";self.screenLockButton.hidden=self.embeddedMode;[self.screenLockButton addTarget:self action:@selector(toggleGestureLock) forControlEvents:UIControlEventTouchUpInside];[gestureSurface addSubview:self.screenLockButton];
    [NSLayoutConstraint activateConstraints:@[[self.screenLockButton.leadingAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.leadingAnchor constant:12],[self.screenLockButton.centerYAnchor constraintEqualToAnchor:self.videoView.centerYAnchor],[self.screenLockButton.widthAnchor constraintEqualToConstant:36],[self.screenLockButton.heightAnchor constraintEqualToConstant:36]]];
    self.gestureSurface=gestureSurface;self.playbackDoubleTapGesture=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlaybackDoubleTap:)];self.playbackDoubleTapGesture.numberOfTapsRequired=2;self.playbackDoubleTapGesture.cancelsTouchesInView=NO;self.playbackDoubleTapGesture.delaysTouchesBegan=NO;[gestureSurface addGestureRecognizer:self.playbackDoubleTapGesture];
    self.playbackLongPressGesture=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlaybackLongPress:)];self.playbackLongPressGesture.minimumPressDuration=0.48;self.playbackLongPressGesture.cancelsTouchesInView=NO;self.playbackLongPressGesture.allowableMovement=18;[gestureSurface addGestureRecognizer:self.playbackLongPressGesture];
    self.playbackPanGesture=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlaybackPan:)];self.playbackPanGesture.delegate=self;self.playbackPanGesture.cancelsTouchesInView=NO;self.playbackPanGesture.maximumNumberOfTouches=1;[gestureSurface addGestureRecognizer:self.playbackPanGesture];

    self.controlPanel=[UIView new];self.controlPanel.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(self.controlPanel,18);[self.view addSubview:self.controlPanel];
    self.lineScroll=[UIScrollView new];self.lineScroll.translatesAutoresizingMaskIntoConstraints=NO;self.lineScroll.showsHorizontalScrollIndicator=NO;[self.controlPanel addSubview:self.lineScroll];
    self.lineButtons=[UIStackView new];self.lineButtons.axis=UILayoutConstraintAxisHorizontal;self.lineButtons.spacing=8;self.lineButtons.translatesAutoresizingMaskIntoConstraints=NO;[self.lineScroll addSubview:self.lineButtons];
    self.qualityGroup=[UIStackView new];self.qualityGroup.translatesAutoresizingMaskIntoConstraints=NO;self.qualityGroup.axis=UILayoutConstraintAxisVertical;self.qualityGroup.spacing=3;[self.controlPanel addSubview:self.qualityGroup];
    self.qualityLabel=[UILabel new];self.qualityLabel.text=@"清晰度";self.qualityLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.qualityLabel.adjustsFontForContentSizeCategory=YES;self.qualityLabel.textColor=HostSecondaryText();[self.qualityGroup addArrangedSubview:self.qualityLabel];
    self.qualityScroll=[UIScrollView new];self.qualityScroll.translatesAutoresizingMaskIntoConstraints=NO;self.qualityScroll.showsHorizontalScrollIndicator=NO;[self.qualityGroup addArrangedSubview:self.qualityScroll];
    self.qualityButtons=[UIStackView new];self.qualityButtons.translatesAutoresizingMaskIntoConstraints=NO;self.qualityButtons.axis=UILayoutConstraintAxisHorizontal;self.qualityButtons.spacing=8;[self.qualityScroll addSubview:self.qualityButtons];
    NSLayoutConstraint *qualityScrollHeight=[self.qualityScroll.heightAnchor constraintEqualToConstant:44];qualityScrollHeight.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[qualityScrollHeight,[self.qualityButtons.leadingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.leadingAnchor],[self.qualityButtons.trailingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.trailingAnchor],[self.qualityButtons.topAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.topAnchor],[self.qualityButtons.bottomAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.bottomAnchor],[self.qualityButtons.heightAnchor constraintEqualToAnchor:self.qualityScroll.frameLayoutGuide.heightAnchor]]];
    self.episodeTitle=[UILabel new];self.episodeTitle.translatesAutoresizingMaskIntoConstraints=NO;self.episodeTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];self.episodeTitle.adjustsFontForContentSizeCategory=YES;self.episodeTitle.textColor=HostText();self.episodeTitle.numberOfLines=2;self.episodeTitle.accessibilityHint=@"双击画面左侧或右侧可前后跳转 10 秒；按住画面可临时使用 3 倍速";[self.controlPanel addSubview:self.episodeTitle];
    self.status=[UILabel new];self.status.translatesAutoresizingMaskIntoConstraints=NO;self.status.textColor=HostSecondaryText();self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.status.numberOfLines=3;self.status.adjustsFontForContentSizeCategory=YES;[self.controlPanel addSubview:self.status];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.controlPanel addSubview:self.spinner];
    self.episodeButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeButton.translatesAutoresizingMaskIntoConstraints=NO;[self.episodeButton setTitle:@"选择分集" forState:UIControlStateNormal];HostStylePillButton(self.episodeButton,YES);MediaPlaybackApplyScaledPillFont(self.episodeButton);[self.episodeButton addTarget:self action:@selector(openEpisodeSelection) forControlEvents:UIControlEventTouchUpInside];
    self.nextEpisodeButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextEpisodeButton.translatesAutoresizingMaskIntoConstraints=NO;[self.nextEpisodeButton setTitle:@"下一集 ⏭" forState:UIControlStateNormal];HostStylePillButton(self.nextEpisodeButton,NO);MediaPlaybackApplyScaledPillFont(self.nextEpisodeButton);self.nextEpisodeButton.accessibilityIdentifier=@"media-playback-next-episode";self.nextEpisodeButton.accessibilityLabel=@"播放下一集";[self.nextEpisodeButton addTarget:self action:@selector(playNextEpisodeManually) forControlEvents:UIControlEventTouchUpInside];self.nextEpisodeButton.hidden=YES;
    self.playbackSpeedButton=[UIButton buttonWithType:UIButtonTypeSystem];self.playbackSpeedButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.playbackSpeedButton,NO);MediaPlaybackApplyScaledPillFont(self.playbackSpeedButton);self.playbackSpeedButton.accessibilityIdentifier=@"media-playback-speed";self.playbackSpeedButton.accessibilityLabel=@"播放速度";self.playbackSpeedButton.showsMenuAsPrimaryAction=YES;double initialRate=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"] doubleValue]:1.0;NSString *initialRateLabel=fabs(initialRate*10-round(initialRate*10))<0.001?[NSString stringWithFormat:@"%.1f×",initialRate]:[NSString stringWithFormat:@"%.2f×",initialRate];[self.playbackSpeedButton setTitle:initialRateLabel forState:UIControlStateNormal];self.playbackSpeedButton.accessibilityValue=[NSString stringWithFormat:@"当前速度 %@",initialRateLabel];self.playbackSpeedButton.menu=[self playbackRateMenu];
    self.playbackActionRow=[UIStackView new];self.playbackActionRow.translatesAutoresizingMaskIntoConstraints=NO;self.playbackActionRow.axis=UILayoutConstraintAxisHorizontal;self.playbackActionRow.alignment=UIStackViewAlignmentFill;self.playbackActionRow.spacing=8;[self.controlPanel addSubview:self.playbackActionRow];
    self.skipButton=[UIButton buttonWithType:UIButtonTypeSystem];self.skipButton.translatesAutoresizingMaskIntoConstraints=NO;self.skipButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.skipButton.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(self.skipButton,YES);MediaPlaybackApplyScaledPillFont(self.skipButton);[self.skipButton addTarget:self action:@selector(performSkipAction) forControlEvents:UIControlEventTouchUpInside];self.skipButton.hidden=YES;
    self.inlineRetryButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineRetryButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.inlineRetryButton,YES);MediaPlaybackApplyScaledPillFont(self.inlineRetryButton);[self.inlineRetryButton setTitle:@"重试" forState:UIControlStateNormal];[self.inlineRetryButton addTarget:self action:@selector(retryCurrentEpisode) forControlEvents:UIControlEventTouchUpInside];self.inlineRetryButton.hidden=YES;self.inlineRetryButton.accessibilityLabel=@"重试当前影片";
    self.inlineParserButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineParserButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.inlineParserButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineParserButton);[self.inlineParserButton setTitle:@"切换解析器" forState:UIControlStateNormal];[self.inlineParserButton addTarget:self action:@selector(selectPlaybackParser) forControlEvents:UIControlEventTouchUpInside];self.inlineParserButton.hidden=YES;self.inlineParserButton.accessibilityLabel=@"选择当前来源的解析器";
    self.inlineOptionsButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineOptionsButton.translatesAutoresizingMaskIntoConstraints=NO;UIImageSymbolConfiguration *optSymCfg=[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];UIImage *optIcon=[[UIImage systemImageNamed:@"slider.horizontal.3" withConfiguration:optSymCfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];if(optIcon)[self.inlineOptionsButton setImage:optIcon forState:UIControlStateNormal];[self.inlineOptionsButton setTitle:@"更多" forState:UIControlStateNormal];HostStylePillButton(self.inlineOptionsButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineOptionsButton);self.inlineOptionsButton.tintColor=HostAccent();self.inlineOptionsButton.imageEdgeInsets=UIEdgeInsetsMake(0,-3,0,3);self.inlineOptionsButton.titleEdgeInsets=UIEdgeInsetsMake(0,3,0,-3);self.inlineOptionsButton.accessibilityLabel=@"播放设置";self.inlineOptionsButton.menu=self.playbackOptionsItem.menu;self.inlineOptionsButton.showsMenuAsPrimaryAction=YES;[self.playbackSpeedButton.widthAnchor constraintGreaterThanOrEqualToConstant:78].active=YES;[self.playbackSpeedButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.playbackActionRow addArrangedSubview:self.skipButton];if(self.embeddedMode){[self.playbackActionRow addArrangedSubview:self.inlineRetryButton];[self.playbackActionRow addArrangedSubview:self.inlineParserButton];[self.playbackActionRow addArrangedSubview:self.nextEpisodeButton];[self.playbackActionRow addArrangedSubview:self.inlineOptionsButton];}else{[self.playbackActionRow addArrangedSubview:self.episodeButton];[self.playbackActionRow addArrangedSubview:self.nextEpisodeButton];}[self.playbackActionRow addArrangedSubview:self.playbackSpeedButton];

    self.videoAspectRatio=16.0/9.0;self.videoAspectConstraint=[self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:0.5625];
    self.videoAspectConstraint.priority=UILayoutPriorityRequired;NSLayoutConstraint *videoAspect=self.videoAspectConstraint;
    self.portraitTallViewportHeightConstraint=[self.videoView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.50];self.portraitTallViewportHeightConstraint.priority=UILayoutPriorityDefaultHigh;
    self.landscapeTallViewportHeightConstraint=[self.videoView.heightAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.86];self.landscapeTallViewportHeightConstraint.priority=UILayoutPriorityDefaultHigh;
    self.portraitConstraints=@[
        [self.lineScroll.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:10],
        [self.lineScroll.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
        [self.lineScroll.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.lineScroll.heightAnchor constraintEqualToConstant:44],
        [self.lineButtons.leadingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.leadingAnchor],
        [self.lineButtons.trailingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.trailingAnchor],
        [self.lineButtons.topAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.topAnchor],
        [self.lineButtons.bottomAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.bottomAnchor],
        [self.lineButtons.heightAnchor constraintEqualToAnchor:self.lineScroll.frameLayoutGuide.heightAnchor],
        [self.qualityGroup.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:4],
        [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        videoAspect,
        [self.videoView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.56],
        [self.controlPanel.topAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:12],
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.controlPanel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.qualityGroup.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.playbackActionRow.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:12],
        [self.playbackActionRow.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.playbackActionRow.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.playbackActionRow.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-14],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.skipButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ];
    NSLayoutConstraint *landscapeWidth=[self.videoView.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:0.68];
    NSLayoutConstraint *landscapePanelWidth=[self.controlPanel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:0.34];
    self.landscapeConstraints=@[
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [self.videoView.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        landscapeWidth,
        videoAspect,
        [self.videoView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.94],
        [self.controlPanel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.videoView.trailingAnchor constant:8],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [self.controlPanel.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        landscapePanelWidth,
        [self.lineScroll.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:10],
        [self.lineScroll.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:10],
        [self.lineScroll.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-10],
        [self.lineScroll.heightAnchor constraintEqualToConstant:44],
        [self.lineButtons.leadingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.leadingAnchor],
        [self.lineButtons.trailingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.trailingAnchor],
        [self.lineButtons.topAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.topAnchor],
        [self.lineButtons.bottomAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.bottomAnchor],
        [self.lineButtons.heightAnchor constraintEqualToAnchor:self.lineScroll.frameLayoutGuide.heightAnchor],
        [self.qualityGroup.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:4],
        [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.qualityGroup.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.playbackActionRow.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
        [self.playbackActionRow.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
        [self.playbackActionRow.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.playbackActionRow.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-12],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.skipButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ];
    if(self.embeddedMode){
        self.view.backgroundColor=UIColor.clearColor;self.videoView.layer.cornerRadius=14;self.episodeTitle.hidden=NO;self.episodeTitle.numberOfLines=1;self.episodeTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.lineScroll.hidden=YES;self.episodeButton.hidden=YES;self.controlPanel.layer.cornerRadius=15;
        // Keep the controls compact when the video surface is pinned above
        // the scrolling detail content, especially when no alternate stream exists.
        [self.status setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [self.status setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        self.embeddedSurfaceConstraints=@[
            [self.videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],videoAspect,
            [self.controlPanel.topAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:8],
            [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.controlPanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ];
        self.embeddedControlConstraints=@[
            [self.qualityGroup.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:11],
            [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
            [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
            [self.episodeTitle.topAnchor constraintEqualToAnchor:self.qualityGroup.bottomAnchor constant:4],
            [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
            [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
            [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:4],
            [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
            [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-6],
            [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
            [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
            [self.playbackActionRow.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:8],
            [self.playbackActionRow.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
            [self.playbackActionRow.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
            [self.playbackActionRow.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-10],
            [self.playbackActionRow.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.inlineOptionsButton.widthAnchor constraintGreaterThanOrEqualToConstant:54],
            [self.inlineOptionsButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.inlineRetryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.inlineParserButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ];
        self.embeddedConstraints=[self.embeddedSurfaceConstraints arrayByAddingObjectsFromArray:self.embeddedControlConstraints];
        [NSLayoutConstraint activateConstraints:self.embeddedConstraints];
    }else [self updatePlaybackLayoutForSize:self.view.bounds.size];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self buildLines];[self buildQualityButtons];[self updateEpisodeTitle];self.pendingEpisodeResult=self.result;self.pendingEpisodeGeneration=self.generation;
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updatePlaybackLayoutForSize:self.view.bounds.size];self.videoTopScrim.frame=CGRectZero;self.videoTopScrim.hidden=YES;if(!self.observingVideoLayer)[self observePlayerLayerIfAvailable];}
- (void)installFloatingInlineSurfaceInHost:(UIView *)videoHost controlsStack:(UIStackView *)controlsStack {
    if(!self.embeddedMode||self.floatingInlineSurfaceInstalled||!videoHost||!controlsStack||!self.isViewLoaded)return;
    self.floatingInlineSurfaceInstalled=YES;
    [NSLayoutConstraint deactivateConstraints:self.embeddedSurfaceConstraints?:@[]];
    self.videoAspectConstraint.active=NO;self.embeddedTallVideoAspectConstraint.active=NO;
    self.view.translatesAutoresizingMaskIntoConstraints=NO;[self.view removeFromSuperview];[videoHost addSubview:self.view];
    [NSLayoutConstraint activateConstraints:@[[self.view.leadingAnchor constraintEqualToAnchor:videoHost.leadingAnchor],[self.view.trailingAnchor constraintEqualToAnchor:videoHost.trailingAnchor],[self.view.topAnchor constraintEqualToAnchor:videoHost.topAnchor],[self.view.bottomAnchor constraintEqualToAnchor:videoHost.bottomAnchor],[self.videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.videoView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [self.controlPanel removeFromSuperview];[controlsStack insertArrangedSubview:self.controlPanel atIndex:0];
    self.inlineNowPlayingLabel.text=self.episodeTitle.text;self.inlineNowPlayingPill.accessibilityLabel=self.episodeTitle.accessibilityLabel?:self.episodeTitle.text;self.inlineNowPlayingPill.hidden=NO;self.inlineNowPlayingPill.alpha=0.0;
}
- (CGFloat)preferredInlineVideoHeightForWidth:(CGFloat)width maximumHeight:(CGFloat)maximumHeight {
    if(!isfinite(width)||width<=0)return 0;
    CGFloat ratio=isfinite(self.videoAspectRatio)&&self.videoAspectRatio>0.1?self.videoAspectRatio:16.0/9.0;
    CGFloat height=width/ratio;
    CGFloat comfortableHeight=width/(16.0/9.0);
    height=MAX(comfortableHeight,height);
    if(isfinite(maximumHeight)&&maximumHeight>0)height=MIN(height,maximumHeight);
    return MAX(160,height);
}
- (void)showGestureFeedback:(NSString *)text {
    NSString *prefix=@"";
    if([text containsString:@"亮度"])prefix=@"☀︎ ";
    else if([text containsString:@"音量"])prefix=@"🔊 ";
    else if([text containsString:@"倍速"]||[text containsString:@"原速"])prefix=@"⚡ ";
    else if([text containsString:@"快进"]||[text containsString:@"+10"])prefix=@"⏩ ";
    else if([text containsString:@"后退"]||[text containsString:@"−10"])prefix=@"⏪ ";
    self.gestureFeedbackLabel.text=[NSString stringWithFormat:@"   %@%@   ",prefix,text?:@""];if(!self.embeddedMode)self.screenLockButton.alpha=1.0;
    self.gestureFeedbackLabel.layer.borderWidth=0.75;
    self.gestureFeedbackLabel.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;
    if(self.gestureFeedbackLabel.hidden){
        self.gestureFeedbackLabel.alpha=0;self.gestureFeedbackLabel.transform=CGAffineTransformMakeScale(0.92,0.92);
        self.gestureFeedbackLabel.hidden=NO;
        [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.gestureFeedbackLabel.alpha=1.0;self.gestureFeedbackLabel.transform=CGAffineTransformIdentity;
        } completion:nil];
    }
    NSUInteger generation=++self.gestureFeedbackGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,850*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        MediaPlaybackViewController *owner=weakSelf;if(!owner||owner.gestureFeedbackGeneration!=generation)return;
        [UIView animateWithDuration:0.20 animations:^{owner.gestureFeedbackLabel.alpha=0;if(owner.videoFrameReady&&!owner.gestureLockActive)owner.screenLockButton.alpha=0.0;} completion:^(BOOL finished){if(finished&&owner.gestureFeedbackGeneration==generation){owner.gestureFeedbackLabel.hidden=YES;owner.gestureFeedbackLabel.alpha=1.0;}}];
    });
}
- (void)toggleGestureLock {
    self.gestureLockActive=!self.gestureLockActive;
    [self.screenLockButton setImage:[UIImage systemImageNamed:self.gestureLockActive?@"lock.fill":@"lock.open"] forState:UIControlStateNormal];
    self.screenLockButton.backgroundColor=self.gestureLockActive?HostAccent():[UIColor colorWithWhite:0 alpha:0.58];
    self.controlPanel.userInteractionEnabled=!self.gestureLockActive;
    self.controlPanel.alpha=self.gestureLockActive?0.35:1.0;
    [self refreshCicadaControls];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.screenLockButton.transform=CGAffineTransformMakeScale(1.15,1.15);
    } completion:^(BOOL finished){
        [UIView animateWithDuration:0.18 animations:^{self.screenLockButton.transform=CGAffineTransformIdentity;}];
    }];
    [self showGestureFeedback:self.gestureLockActive?@"画面手势已锁定":@"画面手势已解锁"];
}
- (void)configureMediaSleepTimerMinutes:(NSInteger)minutes {
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;self.mediaSleepMinutes=minutes;
    if(minutes<=0){[self showGestureFeedback:@"已关闭睡眠定时"];self.playbackOptionsItem.menu=[self playbackOptionsMenu];return;}
    __weak typeof(self) weakSelf=self;
    self.mediaSleepTimer=[NSTimer scheduledTimerWithTimeInterval:minutes*60.0 repeats:NO block:^(__unused NSTimer *t){
        MediaPlaybackViewController *owner=weakSelf;if(!owner)return;owner.mediaSleepTimer=nil;owner.mediaSleepMinutes=0;
        [owner pauseActiveEngine];owner.status.text=@"已按睡眠定时自动暂停播放";[owner showGestureFeedback:@"睡眠定时已到 · 已暂停"];
        owner.playbackOptionsItem.menu=[owner playbackOptionsMenu];
    }];
    [self showGestureFeedback:[NSString stringWithFormat:@"%ld 分钟后自动暂停",(long)minutes]];
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (UIMenu *)playbackSleepTimerMenu {
    __weak typeof(self) weakSelf=self;NSMutableArray *items=[NSMutableArray array];
    for(NSNumber *candidate in @[@0,@15,@30,@60]){
        NSInteger mins=candidate.integerValue;NSString *title=mins==0?@"关闭定时":[NSString stringWithFormat:@"%ld 分钟",(long)mins];
        UIImage *mark=(self.mediaSleepMinutes==mins)?[UIImage systemImageNamed:@"checkmark"]:nil;
        [items addObject:[UIAction actionWithTitle:title image:mark identifier:nil handler:^(__unused UIAction *a){[weakSelf configureMediaSleepTimerMinutes:mins];}]];
    }
    return [UIMenu menuWithTitle:@"睡眠定时" image:[UIImage systemImageNamed:@"moon.zzz"] identifier:nil options:0 children:items];
}
- (void)handlePlaybackDoubleTap:(UITapGestureRecognizer *)recognizer {
    if(self.gestureLockActive){[self showGestureFeedback:@"画面已锁定 · 点按左侧锁图标解锁"];return;}
    if(recognizer.state!=UIGestureRecognizerStateRecognized||(!self.cicadaAdapter&&(!self.player.currentItem||!self.observedItem||self.player.currentItem!=self.observedItem)))return;
    CGPoint point=[recognizer locationInView:self.videoView];CGFloat width=CGRectGetWidth(self.videoView.bounds);if(width<=0||point.y>CGRectGetHeight(self.videoView.bounds)*0.84||(point.x>width*0.32&&point.x<width*0.68))return;
    NSTimeInterval current=[self activeEngineCurrentPosition],duration=[self activeEngineDuration];if(!isfinite(current)||current<0)return;
    NSTimeInterval delta=point.x<width*0.5?-10.0:10.0;NSTimeInterval target=MAX(0,current+delta);if(isfinite(duration)&&duration>0)target=MIN(target,duration);
    [self seekActiveEngineToTime:target completion:nil];[self updateSkipButtonForCurrentPosition];[self showGestureFeedback:[NSString stringWithFormat:@"%@ · %@",delta<0?@"−10 秒":@"+10 秒",[self formatMediaTime:target]]];
    [RuntimeDiagnostics.shared recordEvent:@"playback_gesture_seek" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"delta_seconds":@(delta),@"target_seconds_bucket":@((NSInteger)(target/30)*30)}];
}
- (void)handlePlaybackLongPress:(UILongPressGestureRecognizer *)recognizer {
    if(self.gestureLockActive)return;
    if(recognizer.state==UIGestureRecognizerStateBegan){BOOL playing=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;if((!self.cicadaAdapter&&!self.player.currentItem)||!playing||self.gestureRateActive)return;self.gesturePreviousRate=self.cicadaAdapter?(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0):(self.player.rate>0?self.player.rate:1.0f);self.gestureRateActive=YES;if(self.cicadaAdapter)[self.cicadaAdapter setRate:3.0f];else self.player.rate=3.0f;[self showGestureFeedback:@"按住 3× 倍速播放"];[RuntimeDiagnostics.shared recordEvent:@"playback_gesture_rate_started" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex)}];return;}
    if((recognizer.state==UIGestureRecognizerStateEnded||recognizer.state==UIGestureRecognizerStateCancelled||recognizer.state==UIGestureRecognizerStateFailed)&&self.gestureRateActive){float previous=self.gesturePreviousRate;self.gestureRateActive=NO;BOOL playing=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:(self.player.currentItem&&self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying);if(playing){if(self.cicadaAdapter)[self.cicadaAdapter setRate:previous];else self.player.rate=previous;}[self showGestureFeedback:@"已恢复原速"];[RuntimeDiagnostics.shared recordEvent:@"playback_gesture_rate_ended" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex)}];}
}
- (UISlider *)volumeSliderInView:(UIView *)view {
    if([view isKindOfClass:UISlider.class])return (UISlider *)view;
    for(UIView *child in view.subviews){UISlider *slider=[self volumeSliderInView:child];if(slider)return slider;}
    return nil;
}
- (void)prepareVolumeSlider {
    if(self.volumeSlider)return;
    if(!self.volumeView){self.volumeView=[[MPVolumeView alloc] initWithFrame:CGRectMake(-160,-80,120,40)];self.volumeView.showsRouteButton=NO;self.volumeView.showsVolumeSlider=YES;self.volumeView.alpha=0.01;self.volumeView.accessibilityElementsHidden=YES;[self.view addSubview:self.volumeView];}
    [self.volumeView sizeToFit];[self.volumeView layoutIfNeeded];self.volumeSlider=[self volumeSliderInView:self.volumeView];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *control=touch.view;
    while(control&&control!=self.videoView){if([control isKindOfClass:UIControl.class]||control==self.cicadaControls)return NO;control=control.superview;}
    if(gestureRecognizer!=self.playbackPanGesture)return YES;
    UIView *candidate=touch.view;BOOL belongsToVideo=NO;
    while(candidate){if(candidate==self.gestureSurface){belongsToVideo=YES;break;}if([candidate isKindOfClass:UIControl.class])return NO;candidate=candidate.superview;}
    if(!belongsToVideo)return NO;
    CGPoint point=[touch locationInView:self.gestureSurface];return point.y<CGRectGetHeight(self.gestureSurface.bounds)*0.84;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if(gestureRecognizer!=self.playbackPanGesture)return YES;
    CGPoint velocity=[(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.gestureSurface];
    if(self.embeddedMode)return fabs(velocity.x)>fabs(velocity.y)*1.25;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if(gestureRecognizer==self.playbackPanGesture)return otherGestureRecognizer==self.playbackDoubleTapGesture||otherGestureRecognizer==self.playbackLongPressGesture;
    if(otherGestureRecognizer==self.playbackPanGesture)return gestureRecognizer==self.playbackDoubleTapGesture||gestureRecognizer==self.playbackLongPressGesture;
    return NO;
}
- (void)handlePlaybackPan:(UIPanGestureRecognizer *)recognizer {
    if(!self.gestureSurface||self.gestureRateActive||self.gestureLockActive)return;
    CGPoint translation=[recognizer translationInView:self.gestureSurface];CGSize size=self.gestureSurface.bounds.size;
    if(recognizer.state==UIGestureRecognizerStateBegan){
        self.panMode=MediaPlaybackPanModeNone;self.panStartPoint=[recognizer locationInView:self.gestureSurface];self.panStartValue=0;
        NSTimeInterval current=[self activeEngineCurrentPosition];self.panStartTime=isfinite(current)&&current>=0?current:0;self.panTargetTime=self.panStartTime;return;
    }
    if(recognizer.state==UIGestureRecognizerStateChanged){
        if(self.panMode==MediaPlaybackPanModeNone&&hypot(translation.x,translation.y)>=10){
            if(fabs(translation.x)>=fabs(translation.y)){
                NSTimeInterval duration=[self activeEngineDuration];
                if((!self.cicadaAdapter&&!self.player.currentItem)||!isfinite(duration)||duration<=0){self.panMode=MediaPlaybackPanModeUnsupported;[self showGestureFeedback:@"直播内容不支持拖动进度"];return;}
                self.panMode=MediaPlaybackPanModeSeek;
            }else if(self.embeddedMode){self.panMode=MediaPlaybackPanModeUnsupported;return;}
            else if(self.panStartPoint.x<size.width*0.5){self.panMode=MediaPlaybackPanModeBrightness;self.panStartValue=UIScreen.mainScreen.brightness;}
            else{self.panMode=MediaPlaybackPanModeVolume;[self prepareVolumeSlider];if(!self.volumeSlider){self.panMode=MediaPlaybackPanModeUnsupported;[self showGestureFeedback:@"音量手势暂不可用"];return;}self.panStartValue=self.volumeSlider.value;}
        }
        if(self.panMode==MediaPlaybackPanModeSeek){
            NSTimeInterval duration=[self activeEngineDuration],range=MIN(180.0,MAX(30.0,duration*0.25));self.panTargetTime=MIN(duration,MAX(0,self.panStartTime+translation.x/MAX(1,size.width)*range));
            NSTimeInterval delta=self.panTargetTime-self.panStartTime;[self showGestureFeedback:[NSString stringWithFormat:@"%@ %@ / %@ (%@%.0fs)",delta<0?@"后退至":@"快进至",[self formatMediaTime:self.panTargetTime],[self formatMediaTime:duration],delta>=0?@"+":@"",delta]];
        }else if(self.panMode==MediaPlaybackPanModeBrightness){
            CGFloat value=MIN(1.0,MAX(0.0,self.panStartValue-translation.y/MAX(1,size.height)*0.8));UIScreen.mainScreen.brightness=value;[self showGestureFeedback:[NSString stringWithFormat:@"亮度 %.0f%%",value*100.0]];
        }else if(self.panMode==MediaPlaybackPanModeVolume&&self.volumeSlider){
            CGFloat value=MIN(self.volumeSlider.maximumValue,MAX(self.volumeSlider.minimumValue,self.panStartValue-translation.y/MAX(1,size.height)*0.8));self.volumeSlider.value=value;[self.volumeSlider sendActionsForControlEvents:UIControlEventValueChanged];[self showGestureFeedback:[NSString stringWithFormat:@"音量 %.0f%%",value*100.0]];
        }
        return;
    }
    if(recognizer.state==UIGestureRecognizerStateEnded){
        if(self.panMode==MediaPlaybackPanModeSeek&&fabs(self.panTargetTime-self.panStartTime)>=0.75){
            NSTimeInterval delta=self.panTargetTime-self.panStartTime;[self seekActiveEngineToTime:self.panTargetTime completion:nil];[self updateSkipButtonForCurrentPosition];
            [RuntimeDiagnostics.shared recordEvent:@"playback_gesture_swipe_seek" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"delta_seconds":@(delta),@"target_seconds_bucket":@((NSInteger)(self.panTargetTime/30)*30)}];
        }
        self.panMode=MediaPlaybackPanModeNone;return;
    }
    if(recognizer.state==UIGestureRecognizerStateCancelled||recognizer.state==UIGestureRecognizerStateFailed)self.panMode=MediaPlaybackPanModeNone;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];self.pendingScreenExit=NO;NSDictionary *pending=self.pendingEpisodeResult;NSUInteger pendingGeneration=self.pendingEpisodeGeneration;self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;
    if(!self.idleTimerOverrideActive){self.previousIdleTimerDisabled=UIApplication.sharedApplication.idleTimerDisabled;self.idleTimerOverrideActive=YES;}
    BOOL keepAwake=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaKeepScreenAwake"]?[NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaKeepScreenAwake"]:YES;UIApplication.sharedApplication.idleTimerDisabled=keepAwake;
    if(pending&&pendingGeneration==self.generation){self.playbackSuspendedForVisibility=NO;[self playResult:pending];return;}
}
- (void)viewWillDisappear:(BOOL)animated {
    [self persistPlaybackProgress];
    self.pendingScreenExit=self.isMovingFromParentViewController||self.isBeingDismissed||self.navigationController.isBeingDismissed;
    // 仅真正离页时恢复 idleTimer；被网页播放模态页覆盖时恢复会让屏幕在播放中熄灭。
    if(self.pendingScreenExit&&self.idleTimerOverrideActive){UIApplication.sharedApplication.idleTimerDisabled=self.previousIdleTimerDisabled;self.idleTimerOverrideActive=NO;}
    [super viewWillDisappear:animated];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(!self.pendingScreenExit)return;
    // 画中画进行中时页面离场不应杀掉播放：先挂起清理，等 PiP 停止时再执行。
    if(self.pictureInPictureActive){self.pictureInPictureExitPending=YES;return;}
    [self teardownAfterScreenExit];[self teardownCicadaAdapter];
}
- (void)teardownAfterScreenExit {
    if(self.cicadaFullscreenHost){[self.cicadaFullscreenHost dismissViewControllerAnimated:NO completion:nil];[self restoreVideoFromCicadaFullscreen];}
    self.pendingScreenExit=NO;
    [self cancelNativeResolution];
    [self endBackgroundAutoAdvanceTaskIfNeeded];
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;
    self.generation++;[self.client cancel];self.resolving=NO;
    self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;
    [self.spinner stopAnimating];[self clearCurrentPlayerItem];
    [self.prefetchedAsset cancelLoading];self.prefetchedAsset=nil;self.prefetchedAssetHeaders=nil;
    [RuntimeDiagnostics.shared recordEvent:@"playback_screen_requests_cancelled" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"request_generation":@(self.generation),@"player_generation":@(self.playerGeneration)}];
    if(self.playbackAttemptID.length){
        [RuntimeDiagnostics.shared recordEvent:@"playback_screen_closed" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID, @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""}];
        [self recordPlaybackAttemptOutcome:@"screen_closed" failureKind:nil httpStatus:0 terminal:YES];
    }
}
- (void)playerViewControllerDidStartPictureInPicture:(AVPlayerViewController *)playerViewController {self.pictureInPictureActive=YES;}
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)playerViewController {
    self.pictureInPictureActive=NO;
    if(self.pictureInPictureExitPending){self.pictureInPictureExitPending=NO;[self teardownAfterScreenExit];}
}
- (void)playerViewController:(AVPlayerViewController *)playerViewController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    // PiP 停止后点按悬浮窗需要回到播放页；若页面已不在导航栈中则告知系统无法恢复。
    if(self.navigationController&&[self.navigationController.viewControllers containsObject:self]){
        [self.navigationController popToViewController:self animated:YES];
        if(completionHandler)completionHandler(YES);
        return;
    }
    if(completionHandler)completionHandler(NO);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];UINavigationBar *bar=self.navigationController.navigationBar;
    if(bar){UINavigationBarAppearance *immersive=[UINavigationBarAppearance new];[immersive configureWithTransparentBackground];immersive.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor,NSFontAttributeName:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};immersive.largeTitleTextAttributes=immersive.titleTextAttributes;immersive.backgroundColor=UIColor.clearColor;immersive.shadowColor=UIColor.clearColor;bar.standardAppearance=immersive;bar.scrollEdgeAppearance=immersive;bar.compactAppearance=immersive;if(@available(iOS 15.0,*))bar.compactScrollEdgeAppearance=immersive;bar.translucent=YES;bar.tintColor=HostAccent();bar.prefersLargeTitles=NO;}
    if(@available(iOS 16.0,*))[self setNeedsUpdateOfSupportedInterfaceOrientations];else [UIViewController attemptRotationToDeviceOrientation];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];[coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){[self updatePlaybackLayoutForSize:size];} completion:nil];}
- (void)updatePlaybackLayoutForSize:(CGSize)size {
    if(self.cicadaFullscreenHost||size.width<=0||size.height<=0)return;
    if(self.floatingInlineSurfaceInstalled)return;
    BOOL tallVideo=self.videoAspectRatio>0.0&&self.videoAspectRatio<0.95;
    if(self.embeddedMode){
        BOOL aspectChanged=tallVideo&&fabs(self.videoAspectRatio-self.embeddedVideoAspectRatio)>0.05;
        if(self.playbackLayoutInitialized&&self.tallVideoViewportLayout==tallVideo&&!aspectChanged)return;
        self.playbackLayoutInitialized=YES;self.tallVideoViewportLayout=tallVideo;self.embeddedVideoAspectRatio=self.videoAspectRatio;
        self.videoAspectConstraint.active=NO;self.embeddedTallVideoAspectConstraint.active=NO;
        if(tallVideo){CGFloat multiplier=MIN(1.25,1.0/MAX(0.5,self.videoAspectRatio));self.embeddedTallVideoAspectConstraint=[self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:multiplier];self.embeddedTallVideoAspectConstraint.priority=UILayoutPriorityRequired;self.embeddedTallVideoAspectConstraint.active=YES;}
        else self.videoAspectConstraint.active=YES;
        [self.view setNeedsLayout];return;
    }
    BOOL landscape=size.width>size.height;
    // 横屏控制栏高度紧张：大字体下标题/状态多行会顶出安全区，横屏时收窄行数，竖屏恢复。
    self.episodeTitle.numberOfLines=landscape?1:2;self.status.numberOfLines=landscape?2:3;
    if(self.playbackLayoutInitialized&&self.landscapeLayout==landscape&&self.tallVideoViewportLayout==tallVideo)return;
    self.playbackLayoutInitialized=YES;self.landscapeLayout=landscape;self.videoView.layer.cornerRadius=landscape?10:0;self.throughputPortraitTopConstraint.active=!landscape;self.throughputViewportTopConstraint.active=landscape;self.gestureFeedbackPortraitTopConstraint.active=!landscape;self.gestureFeedbackViewportTopConstraint.active=landscape;
    [NSLayoutConstraint deactivateConstraints:self.portraitConstraints];[NSLayoutConstraint deactivateConstraints:self.landscapeConstraints];
    [NSLayoutConstraint deactivateConstraints:@[self.videoAspectConstraint,self.portraitTallViewportHeightConstraint,self.landscapeTallViewportHeightConstraint]];
    [NSLayoutConstraint activateConstraints:landscape?self.landscapeConstraints:self.portraitConstraints];
    if(tallVideo){self.videoAspectConstraint.active=NO;[NSLayoutConstraint activateConstraints:@[landscape?self.landscapeTallViewportHeightConstraint:self.portraitTallViewportHeightConstraint]];}
    else [NSLayoutConstraint activateConstraints:@[self.videoAspectConstraint]];
    self.tallVideoViewportLayout=tallVideo;
    [self.view setNeedsLayout];
}
- (void)playInlineResult:(NSDictionary *)result context:(NSDictionary *)context {
    if(!NSThread.isMainThread){NSDictionary *resultCopy=[result copy],*contextCopy=[context copy];dispatch_async(dispatch_get_main_queue(),^{[self playInlineResult:resultCopy context:contextCopy];});return;}
    self.playbackSuspendedForVisibility=NO;
    if(self.isViewLoaded){[self persistPlaybackProgress];self.generation++;[self.client cancel];self.prefetchGeneration++;[self.prefetchClient cancel];self.prefetchInFlight=NO;self.prefetchedEpisodeResult=nil;self.prefetchedLineIndex=-1;self.prefetchedEpisodeIndex=-1;self.resolving=NO;self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;[self.spinner stopAnimating];}
    NSString *previousSourceID=[self.context[@"source"][@"id"] description]?:@"",*nextSourceID=[context[@"source"][@"id"] description]?:@"";self.context=[context copy]?:@{};self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;[self resetAutomaticFallbackLines];
    if(!self.isViewLoaded){self.result=[result copy];self.pendingEpisodeResult=self.result;self.pendingEpisodeGeneration=self.generation;return;}
    if(!self.client||![previousSourceID isEqual:nextSourceID]){[self.client cancel];self.client=MediaPlaybackClientForSource(self.context[@"source"]?:@{});self.prefetchGeneration++;[self.prefetchClient cancel];self.prefetchClient=nil;}self.basePlaybackHeaders=nil;self.selectedAlternateIndex=-1;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=nil;self.pendingPlaybackResumeEntry=nil;self.pendingQualityRestorePlaybackState=NO;self.resumePromptPending=NO;self.resumePromptShown=NO;self.stallRecoveryAttempts=0;self.attemptedRoutes=0;[self buildLines];if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;[self updateEpisodeTitle];self.playbackOptionsItem.menu=[self playbackOptionsMenu];
    [self playResult:result];
}
- (void)dealloc {
    [self endBackgroundAutoAdvanceTaskIfNeeded];
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;
    self.generation++;
    self.playerGeneration++;
    [self persistPlaybackProgress];
    if(self.progressTimeObserver&&self.player){@try{[self.player removeTimeObserver:self.progressTimeObserver];}@catch(NSException *exception){}self.progressTimeObserver=nil;}
    if(self.idleTimerOverrideActive){BOOL previousIdleTimerDisabled=self.previousIdleTimerDisabled;if(NSThread.isMainThread)UIApplication.sharedApplication.idleTimerDisabled=previousIdleTimerDisabled;else dispatch_async(dispatch_get_main_queue(),^{UIApplication.sharedApplication.idleTimerDisabled=previousIdleTimerDisabled;});}
    if(self.observingPlayer){@try{[self.player removeObserver:self forKeyPath:@"timeControlStatus" context:CCTVPlayerTimeControlContext];}@catch(NSException *exception){}}
    [self stopObservingCurrentPlayback];
    [NSNotificationCenter.defaultCenter removeObserver:self];[self.client cancel];self.prefetchGeneration++;[self.prefetchClient cancel];[self.prefetchedAsset cancelLoading];[self.player pause];[self teardownCicadaAdapter];
}
- (void)updateEstimatedThroughput {
    if(!self.throughputLabel||self.embeddedMode)return;
    if(self.cicadaAdapter){double bytesPerSecond=self.cicadaAdapterDownloadBPS/8.0;NSString *speed=isfinite(bytesPerSecond)&&bytesPerSecond>0?(bytesPerSecond>=1024.0*1024.0?[NSString stringWithFormat:@"%.1f MB/s",bytesPerSecond/1024.0/1024.0]:[NSString stringWithFormat:@"%.0f KB/s",bytesPerSecond/1024.0]):@"等待网络";NSString *text=self.playbackFailureRecorded?@"测速暂停":speed;self.throughputLabel.text=[NSString stringWithFormat:@"  %@  ",text];self.throughputLabel.accessibilityLabel=text;self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;return;}
    AVPlayerItemAccessLogEvent *event=self.player.currentItem.accessLog.events.lastObject;
    double bitsPerSecond=event.observedBitrate;
    NSString *text= self.playbackFailureRecorded ? @"测速暂停" : (isfinite(bitsPerSecond)&&bitsPerSecond>0 ? (bitsPerSecond/8.0>=1024.0*1024.0 ? [NSString stringWithFormat:@"估算 %.1f MB/s",bitsPerSecond/8.0/1024.0/1024.0] : [NSString stringWithFormat:@"估算 %.0f KB/s",bitsPerSecond/8.0/1024.0]) : (self.player.timeControlStatus==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate?@"等待网络":@"测速中"));
    self.throughputLabel.text=[NSString stringWithFormat:@"  %@  ",text];self.throughputLabel.accessibilityLabel=text;self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;
}
- (void)stopObservingCurrentPlayback {
    [self.avFirstFrameTimer invalidate];self.avFirstFrameTimer=nil;
    // 每秒回调的 time observer 只在 dealloc 移除，clearCurrentPlayerItem /
    // viewDidDisappear 走这里清理时不移除会空转；新 item 由
    // installProgressObserverIfNeeded 重装。
    if(self.progressTimeObserver&&self.player){@try{[self.player removeTimeObserver:self.progressTimeObserver];}@catch(NSException *exception){}self.progressTimeObserver=nil;}
    if(self.playbackAttemptID.length&&!self.progressSummaryRecorded){
        self.progressSummaryRecorded=YES;
        [RuntimeDiagnostics.shared recordEvent:@"playback_progress_summary" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID,@"correlation_id":self.diagnosticTraceID?:@"",@"first_frame_observed":@(self.videoFrameReady),@"observed_playing_seconds":@(_progressEvidence.observed),@"progress_samples":@(_progressEvidence.samples),@"stall_notifications":@(self.diagnosticStallCount)}];
    }
    AVPlayerItem *item=self.observedItem;
    if(self.observingPlayerControllerReady){[self.playerController removeObserver:self forKeyPath:@"readyForDisplay" context:CCTVPlayerControllerReadyContext];self.observingPlayerControllerReady=NO;}
    if(self.observingVideoLayer&&self.videoLayer){@try{[self.videoLayer removeObserver:self forKeyPath:@"readyForDisplay" context:CCTVPlayerLayerReadyContext];}@catch(NSException *exception){}self.observingVideoLayer=NO;}
    self.videoLayer=nil;
    if(item){@try{[item removeObserver:self forKeyPath:@"status" context:CCTVPlayerItemStatusContext];}@catch(NSException *exception){}[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:item];[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];self.observedItem=nil;}
}
- (void)installProgressObserverIfNeeded {
    if(!self.player||self.progressTimeObserver)return;__weak typeof(self) weakSelf=self;
    self.progressTimeObserver=[self.player addPeriodicTimeObserverForInterval:CMTimeMake(1,1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time){
        MediaPlaybackViewController *owner=weakSelf;if(!owner||!owner.observedItem||owner.observedItem!=owner.player.currentItem)return;
        [owner updateEstimatedThroughput];
        NSTimeInterval position=CMTimeGetSeconds(time);if(!isfinite(position)||position<0)return;
        HostPlaybackProgressSample(&owner->_progressEvidence,CACurrentMediaTime(),position,owner.player.rate,owner.videoFrameReady&&owner.player.timeControlStatus==AVPlayerTimeControlStatusPlaying&&!owner.pendingPlaybackSeekTime);
        NSUInteger milestone=owner->_progressEvidence.observed>=30?30:(owner->_progressEvidence.observed>=5?5:0);
        if(milestone>owner.progressMilestone){owner.progressMilestone=milestone;[RuntimeDiagnostics.shared recordEvent:@"playback_progress_confirmed" category:@"playback" fields:@{@"playback_attempt_id":owner.playbackAttemptID?:@"",@"correlation_id":owner.diagnosticTraceID?:@"",@"observed_playing_seconds":@(owner->_progressEvidence.observed),@"progress_samples":@(owner->_progressEvidence.samples),@"milestone_seconds":@(milestone)}];}
        if(position-owner.lastPersistedPosition>=10.0){[owner persistPlaybackProgress];owner.lastPersistedPosition=position;}
        if(owner.videoFrameReady&&owner->_progressEvidence.observed>=5)[owner updateForwardBufferForItem:owner.observedItem];
        if(owner.videoFrameReady&&owner->_progressEvidence.observed>=2)[owner prefetchNextEpisodeIfNeeded];
        [owner updateSkipButtonForCurrentPosition];
    }];
}
- (void)persistPlaybackProgress {
    if(!self.context)return;
    NSTimeInterval position,duration;
    if(self.cicadaAdapter){position=self.cicadaAdapter.currentPosition;duration=self.cicadaAdapter.duration;}
    else{AVPlayerItem *item=self.observedItem;if(!item||item!=self.player.currentItem||item.status!=AVPlayerItemStatusReadyToPlay)return;position=CMTimeGetSeconds(self.player.currentTime);duration=[item.asset statusOfValueForKey:@"duration" error:NULL]==AVKeyValueStatusLoaded?CMTimeGetSeconds(item.duration):0;}
    if(!isfinite(position)||position<0)return;if(!isfinite(duration)||duration<0)duration=0;
    [MediaPlaybackStateStore recordContext:self.context lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:NO];
    self.lastPersistedPosition=position;
}
- (void)activateBackgroundAudioSessionIfNeeded {
    AVAudioSession *session=[AVAudioSession sharedInstance];
    @try{
        [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:nil];
        [session setActive:YES error:nil];
    }@catch(NSException *exception){}
}
- (void)beginBackgroundAutoAdvanceTaskIfNeeded {
    UIApplication *app=UIApplication.sharedApplication;
    if(self.backgroundAutoAdvanceTask!=UIBackgroundTaskInvalid){[app endBackgroundTask:self.backgroundAutoAdvanceTask];self.backgroundAutoAdvanceTask=UIBackgroundTaskInvalid;}
    __weak typeof(self) weakSelf=self;
    self.backgroundAutoAdvanceTask=[app beginBackgroundTaskWithName:@"cctv.media.autoAdvanceEpisode" expirationHandler:^{
        MediaPlaybackViewController *owner=weakSelf;if(!owner)return;
        [owner endBackgroundAutoAdvanceTaskIfNeeded];
    }];
}
- (void)endBackgroundAutoAdvanceTaskIfNeeded {
    if(self.backgroundAutoAdvanceTask==UIBackgroundTaskInvalid)return;
    UIBackgroundTaskIdentifier task=self.backgroundAutoAdvanceTask;
    self.backgroundAutoAdvanceTask=UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:task];
}
- (void)updateNowPlayingInfoCenter {
    NSString *seriesTitle=[self.context[@"detail"][@"name"] isKindOfClass:NSString.class]?self.context[@"detail"][@"name"]:([self.context[@"item"][@"name"] isKindOfClass:NSString.class]?self.context[@"item"][@"name"]:@"影视播放");
    NSString *episodeTitle=self.title.length?self.title:(self.episodeTitle.text?:seriesTitle);
    NSMutableDictionary *info=[[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy]?:[NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle]=episodeTitle?:@"";
    info[MPMediaItemPropertyAlbumTitle]=seriesTitle?:@"";
    NSTimeInterval position=[self activeEngineCurrentPosition],duration=[self activeEngineDuration];
    if(isfinite(position)&&position>=0)info[MPNowPlayingInfoPropertyElapsedPlaybackTime]=@(position);
    if(isfinite(duration)&&duration>0)info[MPMediaItemPropertyPlaybackDuration]=@(duration);
    float rate=self.cicadaAdapter?self.cicadaAdapter.rate:(self.player?self.player.rate:1.0f);
    info[MPNowPlayingInfoPropertyPlaybackRate]=@(isfinite(rate)?rate:1.0f);
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo=info;
}
- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self persistPlaybackProgress];
    if(!self.pictureInPictureActive){
        self.playbackSuspendedForVisibility=YES;
        [self setRetryAvailable:YES];
        [self pauseActiveEngine];
        [RuntimeDiagnostics.shared recordEvent:@"playback_paused_when_app_backgrounded" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"engine":self.cicadaAdapter?@"cicada":@"avplayer"}];
        return;
    }
    [self activateBackgroundAudioSessionIfNeeded];
    if(self.player&&!self.pictureInPictureActive)self.playerController.player=nil;
    [self updateNowPlayingInfoCenter];
}
- (void)pauseForBackground {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self pauseForBackground];});return;}
    if(!self.embeddedMode||self.pictureInPictureActive)return;
    self.playbackSuspendedForVisibility=YES;
    [self setRetryAvailable:YES];
    [self persistPlaybackProgress];
    [self pauseActiveEngine];
    [RuntimeDiagnostics.shared recordEvent:@"inline_playback_paused_when_hidden" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"reason":@"detail_page_hidden_or_app_background"}];
}
- (void)applicationWillEnterForeground:(NSNotification *)notification {
    if(self.player&&!self.cicadaAdapter&&self.playerController.player!=self.player)self.playerController.player=self.player;
    [self observePlayerLayerIfAvailable];
}
- (void)offerResumeForItem:(AVPlayerItem *)item {
    NSDictionary *entry=self.pendingPlaybackResumeEntry;if(!entry||self.resumePromptShown||item!=self.observedItem||item!=self.player.currentItem)return;
    NSTimeInterval position=[entry[@"position"] doubleValue];
    // 弹框时已有模态页或视图不在窗口内会丢提示、播放停在暂停态：直接从上次位置继续。
    if(self.presentedViewController||!self.view.window||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=@(MAX(0,position));[self applyPendingPlaybackSeekForItem:item];return;}
    self.resumePromptShown=YES;self.resumePromptPending=YES;[self.player pause];
    NSString *episode=entry[@"episodeName"]?:@"上次分集";NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"继续上次播放？" message:[NSString stringWithFormat:@"%@ · %@",episode,[self formatMediaTime:position]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"从头播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;[owner.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);{if(!owner.playbackSuspendedForVisibility)[owner.player play];}[RuntimeDiagnostics.shared recordEvent:@"media_resume_declined" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续观看" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;CMTime target=CMTimeMakeWithSeconds(MAX(0,position),600);[owner.player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);{if(!owner.playbackSuspendedForVisibility)[owner.player play];}[owner.status setText:@"已从上次进度继续播放"];[RuntimeDiagnostics.shared recordEvent:@"media_resume_accepted" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyPendingPlaybackSeekForItem:(AVPlayerItem *)item {
    NSNumber *pending=self.pendingPlaybackSeekTime;if(!pending||item!=self.observedItem||item!=self.player.currentItem)return;
    self.pendingPlaybackSeekTime=nil;NSTimeInterval position=MAX(0,pending.doubleValue);NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    [self.player seekToTime:CMTimeMakeWithSeconds(position,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);BOOL shouldResume=!owner.pendingQualityRestorePlaybackState||owner.pendingQualityWasPlaying;owner.pendingQualityRestorePlaybackState=NO;if(shouldResume){if(!owner.playbackSuspendedForVisibility)[owner.player play];}else[owner.player pause];[owner updateSkipButtonForCurrentPosition];});}];
}
- (void)offerResumeForCicada {
    NSDictionary *entry=self.pendingPlaybackResumeEntry;if(!entry||self.resumePromptShown||!self.cicadaAdapter)return;
    NSTimeInterval position=[entry[@"position"] doubleValue];
    // 弹框时已有模态页或视图不在窗口内会丢提示、播放停在暂停态：直接从上次位置继续。
    if(self.presentedViewController||!self.view.window||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=@(MAX(0,position));[self applyPendingPlaybackSeekForCicada];return;}
    self.resumePromptShown=YES;self.resumePromptPending=YES;[self pauseActiveEngine];
    NSString *episode=entry[@"episodeName"]?:@"上次分集";NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"继续上次播放？" message:[NSString stringWithFormat:@"%@ · %@",episode,[self formatMediaTime:position]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"从头播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||!owner.cicadaAdapter)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;[owner seekActiveEngineToTime:0 completion:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&owner.cicadaAdapter){[owner markAutoSkipFlagsForCurrentPosition];[owner setActiveEngineRate:(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0)];[owner playActiveEngine];[RuntimeDiagnostics.shared recordEvent:@"media_resume_declined" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续观看" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||!owner.cicadaAdapter)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;[owner seekActiveEngineToTime:MAX(0,position) completion:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&owner.cicadaAdapter){[owner markAutoSkipFlagsForCurrentPosition];[owner setActiveEngineRate:(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0)];[owner playActiveEngine];[owner.status setText:@"已从上次进度继续播放"];[RuntimeDiagnostics.shared recordEvent:@"media_resume_accepted" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyPendingPlaybackSeekForCicada {
    NSNumber *pending=self.pendingPlaybackSeekTime;if(!pending||!self.cicadaAdapter)return;
    self.pendingPlaybackSeekTime=nil;NSTimeInterval position=MAX(0,pending.doubleValue);NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    [self seekActiveEngineToTime:position completion:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||!owner.cicadaAdapter)return;[owner markAutoSkipFlagsForCurrentPosition];[owner setActiveEngineRate:(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0)];BOOL shouldResume=!owner.pendingQualityRestorePlaybackState||owner.pendingQualityWasPlaying;owner.pendingQualityRestorePlaybackState=NO;if(shouldResume)[owner playActiveEngine];else[owner pauseActiveEngine];[owner updateSkipButtonForCurrentPosition];});}];
}
- (AVPlayerLayer *)playerLayerInLayerTree:(CALayer *)root {
    if([root isKindOfClass:AVPlayerLayer.class]&&((AVPlayerLayer *)root).player==self.player)return (AVPlayerLayer *)root;
    for(CALayer *child in root.sublayers){AVPlayerLayer *found=[self playerLayerInLayerTree:child];if(found)return found;}
    return nil;
}
- (void)observePlayerLayerIfAvailable {
    if(self.playerController&&!self.observingPlayerControllerReady){self.observingPlayerControllerReady=YES;[self.playerController addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerControllerReadyContext];}
    AVPlayerLayer *layer=self.playerController.isViewLoaded?[self playerLayerInLayerTree:self.playerController.view.layer]:nil;
    if(layer&&layer!=self.videoLayer){
        if(self.observingVideoLayer){@try{[self.videoLayer removeObserver:self forKeyPath:@"readyForDisplay" context:CCTVPlayerLayerReadyContext];}@catch(NSException *exception){}}
        self.videoLayer=layer;self.observingVideoLayer=YES;
        [layer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerLayerReadyContext];
    }
    if(layer.readyForDisplay)[self markFirstVideoFrameReadyForItem:self.observedItem];
}
- (void)inspectVideoTracksForItem:(AVPlayerItem *)item generation:(NSUInteger)generation {
    if(!item||item!=self.observedItem||generation!=self.playerGeneration||self.videoTrackInspectionStarted)return;
    self.videoTrackInspectionStarted=YES;
    AVAsset *asset=item.asset;__weak typeof(self) weakSelf=self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"availableMediaCharacteristicsWithMediaSelectionOptions",@"duration"] completionHandler:^{
        NSError *loadError=nil;AVKeyValueStatus loadStatus=[asset statusOfValueForKey:@"tracks" error:&loadError];
        NSArray<AVAssetTrack *> *tracks=loadStatus==AVKeyValueStatusLoaded?[asset tracksWithMediaType:AVMediaTypeVideo]:@[];
        BOOL hasAudio=loadStatus==AVKeyValueStatusLoaded&&[asset tracksWithMediaType:AVMediaTypeAudio].count>0;
        AVAssetTrack *videoTrack=tracks.firstObject;CGSize naturalSize=videoTrack?videoTrack.naturalSize:CGSizeZero;CGAffineTransform preferredTransform=videoTrack?videoTrack.preferredTransform:CGAffineTransformIdentity;NSMutableOrderedSet<NSString *> *codecs=[NSMutableOrderedSet orderedSet];
        if(videoTrack){for(id description in videoTrack.formatDescriptions){CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)description;if(CMFormatDescriptionGetMediaType(format)!=kCMMediaType_Video)continue;FourCharCode code=CMFormatDescriptionGetMediaSubType(format);char name[5]={(char)((code>>24)&0xff),(char)((code>>16)&0xff),(char)((code>>8)&0xff),(char)(code&0xff),0};BOOL printable=YES;for(int i=0;i<4;i++)if(name[i]<32||name[i]>126)printable=NO;if(printable)[codecs addObject:[NSString stringWithUTF8String:name]];}}
        dispatch_async(dispatch_get_main_queue(),^{
            MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.observedItem||item!=owner.player.currentItem)return;
            owner.playbackOptionsItem.menu=[owner playbackOptionsMenu];
            CGSize presentation=item.presentationSize;CGFloat displayAspect=0;if(presentation.width>0&&presentation.height>0)displayAspect=presentation.width/presentation.height;else if(videoTrack){CGRect transformed=CGRectStandardize(CGRectApplyAffineTransform(CGRectMake(0,0,fabs(naturalSize.width),fabs(naturalSize.height)),preferredTransform));if(transformed.size.width>0&&transformed.size.height>0)displayAspect=fabs(transformed.size.width)/fabs(transformed.size.height);}if(isfinite(displayAspect)&&displayAspect>0.1&&displayAspect<10.0){owner.videoAspectRatio=displayAspect;[owner updatePlaybackLayoutForSize:owner.view.bounds.size];if(owner.onVideoAspectRatioChanged)owner.onVideoAspectRatioChanged(displayAspect);}AVPlayerLayer *layer=owner.videoLayer;BOOL hasVideo=tracks.count>0||presentation.width>0||presentation.height>0||owner.videoFrameReady;owner.hasVideoTrack=hasVideo;owner.confirmedAudioOnly=loadStatus==AVKeyValueStatusLoaded&&!hasVideo&&hasAudio;
            NSMutableDictionary *fields=[@{@"playback_attempt_id":owner.playbackAttemptID?:@"",@"correlation_id":owner.diagnosticTraceID?:@"",@"track_load_status":loadStatus==AVKeyValueStatusLoaded?@"loaded":(loadStatus==AVKeyValueStatusFailed?@"failed":@"unavailable"),@"asset_video_track_count":@(tracks.count),@"video_track_state":hasVideo?@"present_video_track":(loadStatus==AVKeyValueStatusLoaded?@"no_video_track":@"unknown"),@"video_presentation_width":@(MAX(0,(NSInteger)llround(presentation.width))),@"video_presentation_height":@(MAX(0,(NSInteger)llround(presentation.height))),@"video_layer_ready_for_display":@(layer.readyForDisplay),@"video_layer_width":@(MAX(0,(NSInteger)llround(layer.bounds.size.width))),@"video_layer_height":@(MAX(0,(NSInteger)llround(layer.bounds.size.height)))} mutableCopy];
            if(videoTrack){fields[@"video_natural_width"]=@(MAX(0,(NSInteger)llround(fabs(naturalSize.width))));fields[@"video_natural_height"]=@(MAX(0,(NSInteger)llround(fabs(naturalSize.height))));}
            if(codecs.count)fields[@"video_codec_fourcc"]=codecs.array;
            if(loadError){fields[@"track_load_error_domain"]=loadError.domain?:@"";fields[@"track_load_error_code"]=@(loadError.code);}
            [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(owner.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_video_track_inspected" category:@"playback" fields:fields];
            if(owner.videoFrameReady)return;
            if(loadStatus==AVKeyValueStatusLoaded&&!hasVideo&&!hasAudio){
                owner.status.text=@"此线路没有可用视频轨 · 正在尝试其他线路";owner.status.accessibilityLabel=owner.status.text;[owner.spinner startAnimating];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    MediaPlaybackViewController *current=weakSelf;
                    if(!current||generation!=current.playerGeneration||item!=current.observedItem||item!=current.player.currentItem||current.videoFrameReady)return;
                    [current recordPlaybackAttemptOutcome:@"no_video_track" failureKind:@"no_video_track" httpStatus:0 terminal:NO];
                    if([current tryNextLineForAutomaticFallback:@"no_video_track"])return;
                    current.status.text=@"此资源没有可用视频轨道 · 其他线路已试完";current.status.accessibilityLabel=current.status.text;[current.spinner stopAnimating];[current setRetryAvailable:YES];
                });
            }
            else if(owner.confirmedAudioOnly){owner.status.text=owner.player.timeControlStatus==AVPlayerTimeControlStatusPlaying?@"AVPlayer 正在播放音频":@"音频轨道已确认";[owner.spinner stopAnimating];}
            else if(hasVideo){owner.status.text=@"视频轨道已确认 · 等待画面首帧";if(owner.player.timeControlStatus!=AVPlayerTimeControlStatusPaused)[owner.spinner startAnimating];}
            else owner.status.text=@"已收到媒体 · 正在检测视频轨道";
            owner.status.accessibilityLabel=owner.status.text;
        });
    }];
}
- (NSTimeInterval)bufferedAheadForItem:(AVPlayerItem *)item {
    if(!item)return 0;double position=CMTimeGetSeconds(item.currentTime);if(!isfinite(position))return 0;
    double end=position;
    for(NSValue *value in item.loadedTimeRanges){CMTimeRange range=value.CMTimeRangeValue;double start=CMTimeGetSeconds(range.start),stop=CMTimeGetSeconds(CMTimeRangeGetEnd(range));if(isfinite(start)&&isfinite(stop)&&start<=position+0.1&&stop>position)end=MAX(end,stop);}
    return MAX(0,end-position);
}
- (BOOL)playbackBufferConstrained {return self.playbackMemoryConstrained||NSProcessInfo.processInfo.lowPowerModeEnabled;}
- (void)updateForwardBufferForItem:(AVPlayerItem *)item {
    if(!item||item!=self.observedItem)return;
    BOOL fast=[NSUserDefaults.standardUserDefaults objectForKey:@"fastNativeStartup"]?[NSUserDefaults.standardUserDefaults boolForKey:@"fastNativeStartup"]:YES;
    NSTimeInterval target=MediaPlaybackForwardBuffer(self.videoFrameReady,fast,self.player.defaultRate,self.diagnosticStallCount,[self playbackBufferConstrained]);
    if(target>item.preferredForwardBufferDuration&&!MediaPlaybackCanGrowForwardBuffer(self->_progressEvidence.observed,[self bufferedAheadForItem:item],target,self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying))return;
    if(fabs(item.preferredForwardBufferDuration-target)>0.1){
        NSTimeInterval previous=item.preferredForwardBufferDuration;item.preferredForwardBufferDuration=target;
        [RuntimeDiagnostics.shared recordEvent:@"playback_buffer_target_changed" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"from_seconds":@(previous),@"to_seconds":@(target),@"observed_playing_seconds":@(self->_progressEvidence.observed),@"buffered_ahead_seconds":@([self bufferedAheadForItem:item])}];
    }
}
- (void)startAVPlayerFromReadyBufferIfNeeded:(AVPlayerItem *)item {
    if(self.playbackSuspendedForVisibility)return;
    if(self.startupBufferKickUsed||!item||item!=self.observedItem||self.player.timeControlStatus!=AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate||self.resumePromptPending||self.pendingPlaybackSeekTime||!self.videoFrameReady||[self bufferedAheadForItem:item]<MAX(1.5,1.5*self.player.defaultRate))return;
    self.startupBufferKickUsed=YES;
    [self.player playImmediatelyAtRate:self.player.defaultRate>0?self.player.defaultRate:1.0f];
}
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];self.playbackMemoryConstrained=YES;
    // A promoted resolution now belongs to the user's selection; cancelling
    // speculative work must not leave its foreground completion waiting forever.
    if(!self.promotedPrefetchCompletion){self.prefetchGeneration++;[self.prefetchClient cancel];self.prefetchInFlight=NO;}
    [self.prefetchedAsset cancelLoading];self.prefetchedAsset=nil;self.prefetchedAssetHeaders=nil;self.prefetchedEpisodeResult=nil;
    [self updateForwardBufferForItem:self.observedItem];
}
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item {
    if(!item||item!=self.observedItem||item!=self.player.currentItem||self.videoFrameReady)return;
    self.nativeSessionRefreshInFlight=NO;self.nativeSessionRefreshAttempted=NO;self.nativeSessionRefreshURL=nil;
    self.videoFrameReady=YES;self.hasVideoTrack=YES;self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;self.inlineNowPlayingPill.alpha=0.0;if(!self.gestureLockActive)self.screenLockButton.alpha=0.0;[self.spinner stopAnimating];[self setRetryAvailable:NO];
    [self startAVPlayerFromReadyBufferIfNeeded:item];
    HostPlaybackProgressSample(&_progressEvidence,CACurrentMediaTime(),CMTimeGetSeconds(item.currentTime),self.player.rate,0);
    self.status.text=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying?@"视频首帧已就绪 · AVPlayer 正在播放":(self.player.timeControlStatus==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate?@"视频首帧已就绪 · 正在缓冲 · 等待 AVPlayer":@"视频首帧已就绪 · 等待播放");self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_ready" category:@"playback" fields:fields];[self recordPlaybackAttemptOutcome:@"first_frame_ready" failureKind:nil httpStatus:0 terminal:NO];
}
- (void)scheduleNativeSessionRefreshForResult:(NSDictionary *)result {
    if(result!=self.result||![result[@"_nativeValidated"] boolValue])return;
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSTimeInterval expires=MediaPlaybackTimestamp(result[@"expiresAt"]);
    NSTimeInterval refreshAfter=MediaPlaybackTimestamp(result[@"refreshAfter"]);
    NSTimeInterval due=expires>0?MAX(now+1.0,expires-15.0):0;
    if(refreshAfter>0)due=due>0?MIN(due,refreshAfter):refreshAfter;
    if(due<=0)return;
    NSUInteger lease=++self.nativeLeaseGeneration;
    NSString *url=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";
    NSDictionary *identity=[[self nativePlaybackResolutionIdentity] copy];
    NSTimeInterval delay=MIN(86400.0,MAX(0.5,due-now));
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        MediaPlaybackViewController *owner=weakSelf;
        if(!owner)return;
        NSString *currentURL=[owner.result[@"url"] isKindOfClass:NSString.class]?owner.result[@"url"]:@"";
        if(lease!=owner.nativeLeaseGeneration||owner.result!=result||![url isEqual:currentURL]||![identity isEqual:[owner nativePlaybackResolutionIdentity]])return;
        [owner refreshNativeSessionForReason:@"native_expiry" httpStatus:0 error:nil];
    });
}
- (BOOL)refreshNativeSessionForReason:(NSString *)reason httpStatus:(NSInteger)httpStatus error:(NSError *)error {
    if(self.nativeSessionRefreshInFlight)return YES;
    BOOL expiryTrigger=[reason isEqual:@"native_expiry"]||[reason isEqual:@"native_session_refresh"];
    if(!expiryTrigger&&httpStatus!=401&&httpStatus!=403)return NO;
    if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count||self.lineIndex<0||self.lineIndex>=self.lines.count)return NO;
    NSString *url=[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@"";
    if(!url.length)return NO;
    if(self.nativeSessionRefreshAttempted)return NO;
    NSTimeInterval position=self.videoFrameReady?[self activeEngineCurrentPosition]:0;
    if(!isfinite(position)||position<0)position=0;
    BOOL wasPlaying=self.videoFrameReady?([self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus!=AVPlayerTimeControlStatusPaused):NO;
    self.nativeSessionRefreshAttempted=YES;self.nativeSessionRefreshInFlight=YES;self.nativeSessionRefreshURL=url;
    self.pendingQualitySeekTime=@(position);self.pendingQualityWasPlaying=wasPlaying;self.pendingQualityRestorePlaybackState=YES;
    self.pendingResolutionReason=@"native_session_refresh";
    [RuntimeDiagnostics.shared recordEvent:@"native_session_refresh_started" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.context[@"source"][@"id"]?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"http_status":@(httpStatus),@"position_seconds":@(position),@"was_playing":@(wasPlaying),@"reason":reason?:@"http_auth",@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"attempt":@1}];
    self.status.text=expiryTrigger?@"播放地址即将过期 · 正在刷新当前分集…":@"播放地址授权失效 · 正在刷新当前分集…";self.status.accessibilityLabel=self.status.text;
    [self resolveAndPlay];
    return YES;
}
- (void)recordPlaybackAttemptOutcome:(NSString *)outcome failureKind:(NSString *)failureKind httpStatus:(NSInteger)httpStatus terminal:(BOOL)terminal {
    if(!self.playbackAttemptID.length||!outcome.length)return;
    if(self.terminalPlaybackOutcomeRecorded)return;
    if(terminal)self.terminalPlaybackOutcomeRecorded=YES;
    NSURL *sourceURL=MediaPlaybackOriginalSourceURL(self.result);NSString *serviceID=[self.context[@"source"][@"id"] isKindOfClass:NSString.class]?self.context[@"source"][@"id"]:@"";
    NSMutableDictionary *fields=[@{@"active_playback_attempt_id":terminal?@"":self.playbackAttemptID, @"active_playback_service_id":terminal?@"":serviceID, @"active_playback_source_host":terminal?@"":(sourceURL.host.lowercaseString?:@""), @"active_playback_outcome":terminal?@"":outcome, @"last_playback_attempt_id":self.playbackAttemptID, @"last_playback_outcome":outcome, @"last_playback_source_host":sourceURL.host.lowercaseString?:@"", @"last_playback_failure_kind":failureKind?:@"", @"last_playback_line_index":@(self.lineIndex), @"last_playback_episode_index":@(self.episodeIndex), @"last_playback_http_status":@(MAX(0,httpStatus))} mutableCopy];
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:(terminal?@"playback_attempt_finished":@"playback_attempt_progressed") fields:fields];
}
- (void)buildLines {
    for(UIView *view in self.lineButtons.arrangedSubviews.copy){[self.lineButtons removeArrangedSubview:view];[view removeFromSuperview];}
    NSArray *lines=self.lines;
    for(NSUInteger idx=0;idx<lines.count;idx++){NSDictionary *line=lines[idx];NSString *lineName=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:nil;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:lineName.length?lineName:[NSString stringWithFormat:@"线路 %lu",(unsigned long)idx+1] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];HostStylePillButton(button,idx==self.lineIndex);MediaPlaybackApplyScaledPillFont(button);button.tag=idx;[button addTarget:self action:@selector(selectLine:) forControlEvents:UIControlEventTouchUpInside];[self.lineButtons addArrangedSubview:button];}
}
- (void)buildQualityButtons {
    NSArray *alternates=[self.result[@"alternates"] isKindOfClass:NSArray.class]?self.result[@"alternates"]:@[];
    for(UIView *view in self.qualityButtons.arrangedSubviews.copy){[self.qualityButtons removeArrangedSubview:view];[view removeFromSuperview];}
    BOOL available=alternates.count>0;self.qualityGroup.spacing=available?3:0;self.qualityLabel.hidden=!available;self.qualityScroll.hidden=!available;self.qualityLabel.text=alternates.count==1?@"清晰度（仅此档可用）":@"清晰度";
    if(!available){self.selectedAlternateIndex=-1;return;}
    NSString *currentURL=[self.result[@"originalURL"] isKindOfClass:NSString.class]?self.result[@"originalURL"]:([self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@"");
    if(self.selectedAlternateIndex<0||self.selectedAlternateIndex>=alternates.count){self.selectedAlternateIndex=-1;for(NSUInteger index=0;index<alternates.count;index++){NSDictionary *alternate=alternates[index];NSString *original=[alternate[@"originalURL"] isKindOfClass:NSString.class]?alternate[@"originalURL"]:alternate[@"url"];if([original isEqual:currentURL]){self.selectedAlternateIndex=index;break;}}if(self.selectedAlternateIndex<0&&alternates.count==1)self.selectedAlternateIndex=0;}
    for(NSUInteger index=0;index<alternates.count;index++){
        NSDictionary *alternate=[alternates[index] isKindOfClass:NSDictionary.class]?alternates[index]:nil;if(!alternate)continue;NSString *name=[alternate[@"name"] isKindOfClass:NSString.class]?alternate[@"name"]:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-quality-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.enabled=alternates.count>1;if(!button.enabled)[button setTitleColor:HostText() forState:UIControlStateDisabled];button.accessibilityLabel=name;button.accessibilityHint=alternates.count==1?@"当前资源仅提供这一档可播放清晰度":@"切换到此视频清晰度";HostStylePillButton(button,(NSInteger)index==self.selectedAlternateIndex);HostInstallPressFeedback(button);MediaPlaybackApplyScaledPillFont(button);[button addTarget:self action:@selector(selectAlternate:) forControlEvents:UIControlEventTouchUpInside];[self.qualityButtons addArrangedSubview:button];
    }
}
- (void)selectAlternate:(UIButton *)sender {
    NSArray *alternates=[self.result[@"alternates"] isKindOfClass:NSArray.class]?self.result[@"alternates"]:@[];if(alternates.count<2||sender.tag<0||sender.tag>=(NSInteger)alternates.count)return;
    NSDictionary *alternate=[alternates[sender.tag] isKindOfClass:NSDictionary.class]?alternates[sender.tag]:nil;if(!alternate)return;NSString *url=[alternate[@"url"] isKindOfClass:NSString.class]?alternate[@"url"]:@"";NSString *originalURL=[alternate[@"originalURL"] isKindOfClass:NSString.class]?alternate[@"originalURL"]:url;if(!url.length)return;
    if(!self.basePlaybackHeaders){NSDictionary *base=[self.result[@"baseHeaders"] isKindOfClass:NSDictionary.class]?self.result[@"baseHeaders"]:MediaPlaybackHeadersFromResult(self.result);self.basePlaybackHeaders=base.copy;}
    NSDictionary *parentResult=self.result;self.selectedAlternateIndex=sender.tag;NSMutableDictionary *selected=[parentResult mutableCopy];selected[@"url"]=url;selected[@"originalURL"]=originalURL;NSMutableDictionary *headers=[self.basePlaybackHeaders mutableCopy]?:[NSMutableDictionary dictionary];[headers addEntriesFromDictionary:MediaPlaybackHeadersFromResult(alternate)];selected[@"headers"]=headers.copy;[selected removeObjectForKey:@"header"];for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime",@"playbackEngine",@"nativePlayable",@"directMedia",@"requiresWebPlayback",@"parse",@"jx",@"dashRemuxed"]){[selected removeObjectForKey:key];if(alternate[key]!=nil)selected[key]=alternate[key];}NSURLComponents *alternateParts=[NSURLComponents componentsWithString:url];if(!alternateParts.path.pathExtension.length&&!MediaPlaybackResultSupportsNativePlayback(alternate)&&MediaPlaybackResultSupportsCicada(parentResult)){selected[@"playbackEngine"]=@"cicada";for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime"])if(!selected[key]&&parentResult[key])selected[key]=parentResult[key];}self.result=selected;[self buildQualityButtons];
    [self persistPlaybackProgress];NSTimeInterval current=[self activeEngineCurrentPosition];self.pendingQualitySeekTime=(isfinite(current)&&current>=0)?@(MAX(0,current)):nil;self.pendingQualityWasPlaying=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus!=AVPlayerTimeControlStatusPaused;self.pendingQualityRestorePlaybackState=YES;
    [RuntimeDiagnostics.shared recordEvent:@"playback_quality_selected" category:@"playback" fields:@{@"alternate_index":@(sender.tag),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"parse_mode":@([selected[@"parse"] integerValue]),@"requires_web_playback":@([selected[@"requiresWebPlayback"] boolValue]),@"native_playable_declared":@([selected[@"nativePlayable"] boolValue]),@"correlation_id":self.diagnosticTraceID?:@""}];self.attemptedRoutes=0;[self playResult:selected];
}
- (void)configurePlaybackOptions {
    UIImage *image=[UIImage systemImageNamed:@"ellipsis.circle"];
    self.playbackOptionsItem=[[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:nil action:nil];
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
    self.playbackOptionsItem.accessibilityLabel=@"播放设置";
    self.navigationItem.rightBarButtonItems=@[self.playbackOptionsItem];
}
- (UIMenu *)mediaSelectionMenuForCharacteristic:(AVMediaCharacteristic)characteristic title:(NSString *)title {
    AVPlayerItem *item=self.player.currentItem;BOOL ready=item&&item.status==AVPlayerItemStatusReadyToPlay&&[item.asset statusOfValueForKey:@"availableMediaCharacteristicsWithMediaSelectionOptions" error:NULL]==AVKeyValueStatusLoaded;AVMediaSelectionGroup *group=ready?[item.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;
    if(!group.options.count){UIAction *unavailable=[UIAction actionWithTitle:[NSString stringWithFormat:@"当前视频未提供%@轨道",title] image:nil identifier:nil handler:^(UIAction *action){}];unavailable.attributes=UIMenuElementAttributesDisabled;return [UIMenu menuWithTitle:title children:@[unavailable]];}
    NSMutableArray *actions=[NSMutableArray array];AVMediaSelection *selection=item.currentMediaSelection;AVMediaSelectionOption *selected=[selection selectedMediaOptionInMediaSelectionGroup:group];__weak typeof(self) weakSelf=self;
    if(group.allowsEmptySelection){UIAction *off=[UIAction actionWithTitle:@"关闭" image:selected?nil:[UIImage systemImageNamed:@"checkmark"] identifier:nil handler:^(UIAction *action){AVPlayerItem *current=weakSelf.player.currentItem;AVMediaSelectionGroup *currentGroup=current?[current.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;if(current&&currentGroup)[current selectMediaOption:nil inMediaSelectionGroup:currentGroup];}];[actions addObject:off];}
    for(AVMediaSelectionOption *option in group.options){NSString *name=option.displayName.length?option.displayName:@"默认";UIImage *mark=[selected isEqual:option]?[UIImage systemImageNamed:@"checkmark"]:nil;[actions addObject:[UIAction actionWithTitle:name image:mark identifier:nil handler:^(UIAction *action){AVPlayerItem *current=weakSelf.player.currentItem;AVMediaSelectionGroup *currentGroup=current?[current.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;if(current&&currentGroup)[current selectMediaOption:option inMediaSelectionGroup:currentGroup];}]];}
    return [UIMenu menuWithTitle:title children:actions];
}
- (UIMenu *)playbackRateMenu {
    __weak typeof(self) weakSelf=self;NSMutableArray *rateActions=[NSMutableArray array];
    NSArray<NSNumber *> *rates=@[@0.5,@0.75,@1.0,@1.25,@1.5,@1.75,@2.0];double currentRate=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"] doubleValue]:1.0;
    for(NSNumber *candidate in rates){double rate=candidate.doubleValue;NSString *title=rate==1.0?@"正常速度": [NSString stringWithFormat:@"%.2gx",rate];UIImage *mark=fabs(currentRate-rate)<0.01?[UIImage systemImageNamed:@"checkmark"]:nil;[rateActions addObject:[UIAction actionWithTitle:title image:mark identifier:nil handler:^(UIAction *action){[weakSelf setPlaybackRate:rate];}]];}
    return [UIMenu menuWithTitle:@"播放速度" children:rateActions];
}
- (UIMenu *)playbackOptionsMenu {
    __weak typeof(self) weakSelf=self;
    NSArray *gravityValues=@[@{ @"title":@"画面适应", @"value":AVLayerVideoGravityResizeAspect },@{ @"title":@"铺满裁切", @"value":AVLayerVideoGravityResizeAspectFill },@{ @"title":@"拉伸填满", @"value":AVLayerVideoGravityResize }];
    NSMutableArray *gravityActions=[NSMutableArray array];NSString *currentGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    for(NSDictionary *option in gravityValues){NSString *value=option[@"value"];UIImage *mark=[currentGravity isEqual:value]?[UIImage systemImageNamed:@"checkmark"]:nil;[gravityActions addObject:[UIAction actionWithTitle:option[@"title"] image:mark identifier:nil handler:^(UIAction *action){[weakSelf setVideoGravity:value];}]];}
    UIAction *intro=[UIAction actionWithTitle:@"将当前时间记为片头结束" image:[UIImage systemImageNamed:@"forward.end"] identifier:nil handler:^(UIAction *action){[weakSelf rememberIntroEnd];}];
    UIAction *outro=[UIAction actionWithTitle:@"将剩余时间记为片尾" image:[UIImage systemImageNamed:@"forward.end.fill"] identifier:nil handler:^(UIAction *action){[weakSelf rememberOutroSkip];}];
    BOOL keepAwake=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaKeepScreenAwake"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaKeepScreenAwake"]:YES;
    UIAction *awake=[UIAction actionWithTitle:keepAwake?@"关闭屏幕常亮":@"保持屏幕常亮" image:[UIImage systemImageNamed:keepAwake?@"moon":@"sun.max"] identifier:nil handler:^(UIAction *action){[weakSelf setKeepScreenAwake:!keepAwake];}];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    UIAction *autoNextAction=[UIAction actionWithTitle:autoNext?@"关闭自动连播下一集":@"开启自动连播下一集" image:[UIImage systemImageNamed:autoNext?@"forward.end":@"forward.end.fill"] identifier:nil handler:^(UIAction *action){[NSUserDefaults.standardUserDefaults setBool:!autoNext forKey:@"cctv.mediaAutoPlayNext"];weakSelf.playbackOptionsItem.menu=[weakSelf playbackOptionsMenu];weakSelf.status.text=!autoNext?@"已开启自动连播下一集":@"已关闭自动连播下一集";}];
    UIAction *clear=[UIAction actionWithTitle:@"清除本片跳过位置" image:[UIImage systemImageNamed:@"eraser"] identifier:nil handler:^(UIAction *action){[MediaPlaybackStateStore clearSkipPointsForContext:weakSelf.context?:@{}];[weakSelf updateSkipButtonForCurrentPosition];weakSelf.status.text=@"已清除本片的片头片尾位置";}];
    UIAction *danmaku=[UIAction actionWithTitle:@"弹幕 · 当前视频未提供弹幕轨道" image:[UIImage systemImageNamed:@"text.bubble"] identifier:nil handler:^(UIAction *action){}];danmaku.attributes=UIMenuElementAttributesDisabled;
    NSString *currentDecodeMode=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaDecodeMode.v1"]?:@"auto";
    NSArray *decodeModes=@[@{@"title":@"自动（AVPlayer → Cicada 硬解 → 软解 cc）",@"value":@"auto"},@{@"title":@"优先 CicadaPlayer 硬解",@"value":@"cicada"},@{@"title":@"强制 CicadaPlayer 软解码 (cc)",@"value":@"cicada_soft"}];
    NSMutableArray *decodeActions=[NSMutableArray array];
    for(NSDictionary *modeOpt in decodeModes){
        NSString *val=modeOpt[@"value"];
        UIImage *mark=[currentDecodeMode isEqualToString:val]?[UIImage systemImageNamed:@"checkmark"]:nil;
        [decodeActions addObject:[UIAction actionWithTitle:modeOpt[@"title"] image:mark identifier:nil handler:^(__unused UIAction *a){
            MediaPlaybackViewController *owner=weakSelf;if(!owner)return;
            [[NSUserDefaults standardUserDefaults] setObject:val forKey:@"cctv.mediaDecodeMode.v1"];
            owner.playbackOptionsItem.menu=[owner playbackOptionsMenu];
            if(owner.result){
                NSTimeInterval pos=[owner activeEngineCurrentPosition];
                if(isfinite(pos)&&pos>0){owner.pendingQualitySeekTime=@(pos);owner.pendingQualityWasPlaying=YES;owner.pendingQualityRestorePlaybackState=YES;}
                owner.attemptedRoutes=0;
                [owner playResult:owner.result];
            }
        }]];
    }
    UIMenu *decodeMenu=[UIMenu menuWithTitle:@"解码模式 (原生 / 软解 cc)" image:[UIImage systemImageNamed:@"cpu"] identifier:nil options:0 children:decodeActions];
    UIAction *copyDiag=[UIAction actionWithTitle:@"复制当前流媒体诊断信息" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){[weakSelf copyCurrentStreamDiagnostics];}];
    NSMutableArray *topChildren=[NSMutableArray arrayWithObjects:decodeMenu,[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicLegible title:@"字幕"],[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicAudible title:@"音轨"],danmaku,[self playbackRateMenu],[self playbackSleepTimerMenu],[UIMenu menuWithTitle:@"画面比例" children:gravityActions],autoNextAction,intro,outro,clear,awake,copyDiag,nil];
    if(self.episodeIndex+1<self.episodes.count){
        UIAction *nextEpAct=[UIAction actionWithTitle:@"播放下一集" image:[UIImage systemImageNamed:@"forward.end.fill"] identifier:nil handler:^(__unused UIAction *a){[weakSelf playNextEpisodeManually];}];
        [topChildren insertObject:nextEpAct atIndex:0];
    }
    if(self.episodeIndex>0&&self.episodes.count>1){
        UIAction *prevEpAct=[UIAction actionWithTitle:@"播放上一集" image:[UIImage systemImageNamed:@"backward.end.fill"] identifier:nil handler:^(__unused UIAction *a){[weakSelf playPreviousEpisodeManually];}];
        [topChildren insertObject:prevEpAct atIndex:0];
    }
    UIMenu *menu=[UIMenu menuWithChildren:topChildren];if(self.inlineOptionsButton)self.inlineOptionsButton.menu=menu;return menu;
}
- (void)playNextEpisodeManually {
    if(self.episodeIndex+1>=self.episodes.count)return;
    [self persistPlaybackProgress];
    self.episodeIndex++;
    self.stallRecoveryAttempts=0;
    [self resetAutomaticFallbackLines];
    self.pendingResolutionReason=@"manual_next_episode";
    [self updateEpisodeTitle];
    [self showGestureFeedback:[NSString stringWithFormat:@"切换至第 %ld 集",(long)self.episodeIndex+1]];
    [self resolveAndPlay];
}
- (void)playPreviousEpisodeManually {
    if(self.episodeIndex<=0||!self.episodes.count)return;
    [self persistPlaybackProgress];
    self.episodeIndex--;
    self.stallRecoveryAttempts=0;
    [self resetAutomaticFallbackLines];
    self.pendingResolutionReason=@"manual_previous_episode";
    [self updateEpisodeTitle];
    [self showGestureFeedback:[NSString stringWithFormat:@"切换至第 %ld 集",(long)self.episodeIndex+1]];
    [self resolveAndPlay];
}
- (void)copyCurrentStreamDiagnostics {
    NSString *engine=self.cicadaAdapter?(self.cicadaAdapterSoftwareDecodeFallbackAttempted?@"CicadaPlayer (ffmpeg 软解 cc)":@"CicadaPlayer (硬解)"):@"AVPlayer (Apple 原生)";
    NSURL *origURL=MediaPlaybackOriginalSourceURL(self.result);
    NSString *host=origURL.host?:@"未知";
    NSTimeInterval pos=[self activeEngineCurrentPosition],dur=[self activeEngineDuration];
    NSString *summary=[NSString stringWithFormat:@"片名：%@\n内核：%@\n线路：%ld/%lu · 分集：%ld/%lu\n进度：%@ / %@\n源站域名：%@\n跟踪ID：%@",self.title?:@"未知",engine,(long)self.lineIndex+1,(unsigned long)self.lines.count,(long)self.episodeIndex+1,(unsigned long)self.episodes.count,[self formatMediaTime:pos],[self formatMediaTime:dur],host,self.diagnosticTraceID?:@""];
    UIPasteboard.generalPasteboard.string=summary;
    [self showGestureFeedback:@"已复制播放诊断信息"];
}
- (void)setPlaybackRate:(double)rate {
    rate=MIN(2.0,MAX(0.5,rate));[NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];[self setActiveEngineRate:(float)rate];
    if(self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying)self.player.rate=(float)rate;
    NSString *rateLabel=fabs(rate*10-round(rate*10))<0.001?[NSString stringWithFormat:@"%.1f×",rate]:[NSString stringWithFormat:@"%.2f×",rate];[self.playbackSpeedButton setTitle:rateLabel forState:UIControlStateNormal];self.playbackSpeedButton.accessibilityValue=[NSString stringWithFormat:@"当前速度 %@",rateLabel];self.playbackSpeedButton.menu=[self playbackRateMenu];
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)setVideoGravity:(NSString *)gravity {
    if(![@[AVLayerVideoGravityResizeAspect,AVLayerVideoGravityResizeAspectFill,AVLayerVideoGravityResize] containsObject:gravity])return;
    [NSUserDefaults.standardUserDefaults setObject:gravity forKey:@"cctv.mediaVideoGravity"];self.playerController.videoGravity=gravity;[self.cicadaAdapter applyVideoGravity:gravity];self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)setKeepScreenAwake:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"cctv.mediaKeepScreenAwake"];
    if(self.view.window){if(!self.idleTimerOverrideActive){self.previousIdleTimerDisabled=UIApplication.sharedApplication.idleTimerDisabled;self.idleTimerOverrideActive=YES;}UIApplication.sharedApplication.idleTimerDisabled=enabled;}
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)rememberIntroEnd {
    NSTimeInterval position=[self activeEngineCurrentPosition];if(!isfinite(position)||position<5||position>600){self.status.text=@"片头结束位置需在 5 秒到 10 分钟之间";return;}
    [MediaPlaybackStateStore setIntroEnd:position forContext:self.context?:@{}];self.status.text=[NSString stringWithFormat:@"已记住片头结束位置 %.0f 秒",position];[self.playbackOptionsItem setMenu:[self playbackOptionsMenu]];
}
- (void)rememberOutroSkip {
    NSTimeInterval position=[self activeEngineCurrentPosition],duration=[self activeEngineDuration],remaining=duration-position;if(!isfinite(remaining)||remaining<5||remaining>600){self.status.text=@"片尾位置需在结束前 5 秒到 10 分钟之间";return;}
    [MediaPlaybackStateStore setOutroSkip:remaining forContext:self.context?:@{}];self.status.text=[NSString stringWithFormat:@"已记住片尾约 %.0f 秒，可点按跳过按钮切换下一集",remaining];[self.playbackOptionsItem setMenu:[self playbackOptionsMenu]];
}
// 续播/恢复 seek 到已过片头的位置后起播：把本集的自动跳过标记置位，
// 之后用户手动拉回片头区间不再被自动拉走（跳过按钮仍可手动点按）。
// 片尾同理：已在片尾区间内起播时置位，避免刚起播就被切到下一集。
- (void)markAutoSkipFlagsForCurrentPosition {
    NSTimeInterval position=[self activeEngineCurrentPosition],duration=[self activeEngineDuration];
    if(!isfinite(position)||position<0)return;
    NSDictionary *context=self.context?:@{};
    if(![self.autoSkipContext isEqualToDictionary:context]){self.autoSkipContext=[context copy];self.autoSkippedIntroEpisodeIndex=-1;self.autoSkippedOutroEpisodeIndex=-1;}
    NSTimeInterval intro=[MediaPlaybackStateStore introEndForContext:context];
    if(intro>5&&position>=intro-2)self.autoSkippedIntroEpisodeIndex=self.episodeIndex;
    NSTimeInterval outro=[MediaPlaybackStateStore outroSkipForContext:context];
    NSTimeInterval remaining=duration-position;
    if(outro>0&&isfinite(remaining)&&remaining>0&&remaining<=outro&&self.episodeIndex+1<self.episodes.count)self.autoSkippedOutroEpisodeIndex=self.episodeIndex;
}
- (void)updateSkipButtonForCurrentPosition {
    if(!self.skipButton){self.skipButton.hidden=YES;return;}
    if(!self.cicadaAdapter&&(!self.observedItem||self.observedItem!=self.player.currentItem)){self.skipButton.hidden=YES;return;}
    NSTimeInterval position=[self activeEngineCurrentPosition],duration=[self activeEngineDuration];if(!isfinite(position)||position<0){self.skipButton.hidden=YES;return;}
    // 换片后重置本集自动跳过标记，否则同一集号在另一部影片里会被误判为已跳过。
    NSDictionary *context=self.context?:@{};
    if(![self.autoSkipContext isEqualToDictionary:context]){self.autoSkipContext=[context copy];self.autoSkippedIntroEpisodeIndex=-1;self.autoSkippedOutroEpisodeIndex=-1;}
    BOOL autoSkip=[[NSUserDefaults standardUserDefaults] boolForKey:@"cctv.mediaAutoSkipIntroOutro"];
    NSTimeInterval intro=[MediaPlaybackStateStore introEndForContext:self.context?:@{}];if(intro>5&&position<intro-2){self.skipButtonAction=@"intro";if(autoSkip&&self.episodeIndex!=self.autoSkippedIntroEpisodeIndex){self.autoSkippedIntroEpisodeIndex=self.episodeIndex;[self performSkipAction];return;}[self.skipButton setTitle:[NSString stringWithFormat:@"跳过片头 · %@",[self formatMediaTime:intro-position]] forState:UIControlStateNormal];self.skipButton.hidden=NO;return;}
    NSTimeInterval outro=[MediaPlaybackStateStore outroSkipForContext:self.context?:@{}];BOOL hasNext=self.episodeIndex+1<self.episodes.count;NSTimeInterval remaining=duration-position;
    if(outro>0&&isfinite(remaining)&&remaining>0&&remaining<=outro&&hasNext){self.skipButtonAction=@"outro";if(autoSkip&&self.episodeIndex!=self.autoSkippedOutroEpisodeIndex){self.autoSkippedOutroEpisodeIndex=self.episodeIndex;[self performSkipAction];return;}[self.skipButton setTitle:@"跳过片尾 · 下一集" forState:UIControlStateNormal];self.skipButton.hidden=NO;return;}
    self.skipButtonAction=nil;self.skipButton.hidden=YES;
}
- (NSString *)formatMediaTime:(NSTimeInterval)time {NSUInteger value=(NSUInteger)MAX(0,time);return value>=3600?[NSString stringWithFormat:@"%lu:%02lu:%02lu",(unsigned long)(value/3600),(unsigned long)((value%3600)/60),(unsigned long)(value%60)]:[NSString stringWithFormat:@"%02lu:%02lu",(unsigned long)(value/60),(unsigned long)(value%60)];}
- (void)performSkipAction {
    NSString *action=self.skipButtonAction;if([action isEqual:@"intro"]){NSTimeInterval target=[MediaPlaybackStateStore introEndForContext:self.context?:@{}];if(target>0)[self seekActiveEngineToTime:target completion:nil];self.skipButton.hidden=YES;return;}
    if([action isEqual:@"outro"]&&self.episodeIndex+1<self.episodes.count){[self persistPlaybackProgress];self.isAutoAdvancingEpisode=YES;[self activateBackgroundAudioSessionIfNeeded];[self beginBackgroundAutoAdvanceTaskIfNeeded];self.episodeIndex++;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"skip_outro";[self updateEpisodeTitle];[self resolveAndPlay];}
}
- (void)setRetryAvailable:(BOOL)available {
    NSDictionary *source=[self.context[@"source"] isKindOfClass:NSDictionary.class]?self.context[@"source"]:@{};
    BOOL hasParsers=[TVBoxCatalogStore playbackParsersForCatalogID:[ServiceStore playbackParserCatalogIDForSource:source]].count>0;
    self.inlineRetryButton.hidden=!available;
    [self.inlineRetryButton setTitle:@"重试" forState:UIControlStateNormal];
    self.inlineParserButton.hidden=!(available&&hasParsers);
    if(self.embeddedMode)return;
    NSMutableArray *items=[NSMutableArray array];
    if(available){
        if(!self.retryItem)self.retryItem=[[UIBarButtonItem alloc] initWithTitle:@"重试" style:UIBarButtonItemStylePlain target:self action:@selector(retryCurrentEpisode)];
        [items addObject:self.retryItem];
        if(hasParsers){
            if(!self.parserSelectionItem)self.parserSelectionItem=[[UIBarButtonItem alloc] initWithTitle:@"解析器" style:UIBarButtonItemStylePlain target:self action:@selector(selectPlaybackParser)];
            [items addObject:self.parserSelectionItem];
        }
    }
    if(self.playbackOptionsItem)[items addObject:self.playbackOptionsItem];
    self.navigationItem.rightBarButtonItems=items;
}
- (void)selectPlaybackParser {
    NSDictionary *source=[self.context[@"source"] isKindOfClass:NSDictionary.class]?self.context[@"source"]:@{};
    NSArray *parsers=[TVBoxCatalogStore playbackParsersForCatalogID:[ServiceStore playbackParserCatalogIDForSource:source]];
    if(!parsers.count)return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"选择解析器" message:@"使用当前来源的解析合集，保持当前分集" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    void (^choose)(NSString *)=^(NSString *identifier){
        MediaPlaybackViewController *owner=weakSelf;if(!owner)return;
        NSString *sourceID=[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:([source[@"api"] isKindOfClass:NSString.class]?source[@"api"]:@"");
        if(sourceID.length)[NSUserDefaults.standardUserDefaults setObject:identifier?:@"" forKey:[NSString stringWithFormat:@"cctv.media.parser.%@",sourceID]];
        NSMutableDictionary *context=[owner.context mutableCopy]?:[NSMutableDictionary dictionary];context[@"parserID"]=identifier?:@"";owner.context=context;
        [owner retryCurrentEpisode];
    };
    [sheet addAction:[UIAlertAction actionWithTitle:@"自动（最多两个）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){choose(@"");}]];
    for(NSDictionary *parser in parsers){
        NSString *type=[[parser[@"type"] description] lowercaseString];
        if(![@[@"0",@"web",@"html",@"1",@"json",@"api"] containsObject:type])continue;
        [sheet addAction:[UIAlertAction actionWithTitle:parser[@"name"]?:@"解析接口" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){choose(parser[@"id"]); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(sheet.popoverPresentationController){sheet.popoverPresentationController.sourceView=self.inlineParserButton.window?self.inlineParserButton:self.view;sheet.popoverPresentationController.sourceRect=sheet.popoverPresentationController.sourceView.bounds;}
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)cancelNativeResolution {
    MediaNativePlaybackResolver *resolver=self.nativeResolver;self.nativeResolver=nil;[resolver cancel];
}
- (NSDictionary *)nativePlaybackResolutionIdentity {
    NSDictionary *source=[self.context[@"source"] isKindOfClass:NSDictionary.class]?self.context[@"source"]:@{};
    NSArray *episodes=self.episodes;
    NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:@{};
    NSDictionary *line=self.lineIndex>=0&&self.lineIndex<self.lines.count?self.lines[self.lineIndex]:@{};
    return @{@"sourceID":[source[@"id"] description]?:@"",@"catalogID":[ServiceStore playbackParserCatalogIDForSource:source]?:@"",@"provider":[self.context[@"provider"] description]?:@"",@"detailID":[self.context[@"detail"][@"id"] description]?:[self.context[@"item"][@"id"] description]?:@"",@"lineID":[line[@"id"] description]?:@"",@"episodeID":[episode[@"id"] description]?:[self.context[@"episodeID"] description]?:@"",@"parserID":MediaPlaybackSelectedParserID(self.context),@"generation":@(self.generation)};
}
- (void)resolveNativePlaybackResult:(NSDictionary *)result {
    [self clearCurrentPlayerItem];
    self.result=result;self.validatedPlaybackResult=nil;self.resolving=YES;
    self.status.text=@"正在解析播放地址…";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];[self setRetryAvailable:NO];
    NSDictionary *identity=[self nativePlaybackResolutionIdentity];NSUInteger generation=self.playerGeneration;
    MediaNativePlaybackResolver *resolver=[[MediaNativePlaybackResolver alloc] initWithHostView:self.view];self.nativeResolver=resolver;
    __weak typeof(self) weakSelf=self;__weak MediaNativePlaybackResolver *weakResolver=resolver;
    [resolver resolveResult:result identity:identity progress:^(NSDictionary *progress){
        MediaPlaybackViewController *owner=weakSelf;if(!owner||owner.nativeResolver!=weakResolver||owner.playerGeneration!=generation)return;
        NSString *name=[progress[@"parserName"] isKindOfClass:NSString.class]?progress[@"parserName"]:@"";
        NSString *stage=[progress[@"stage"] isKindOfClass:NSString.class]?progress[@"stage"]:@"resolving";
        owner.status.text=name.length?[NSString stringWithFormat:@"正在解析 · %@",name]:@"正在验证播放地址…";owner.status.accessibilityLabel=owner.status.text;
        [RuntimeDiagnostics.shared recordEvent:@"native_resolution_progress" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":identity[@"sourceID"],@"stage":stage,@"parser_name":name,@"request_generation":@(generation)}];
    } completion:^(NSDictionary *media,NSError *error){
        MediaPlaybackViewController *owner=weakSelf;
        if(!owner||owner.nativeResolver!=weakResolver||owner.playerGeneration!=generation||![identity isEqual:[owner nativePlaybackResolutionIdentity]])return;
        owner.nativeResolver=nil;owner.resolving=NO;[owner.spinner stopAnimating];
        if(error||![media[@"_nativeValidated"] boolValue]){
            NSString *code=[error.userInfo[@"resolutionCode"] isKindOfClass:NSString.class]?error.userInfo[@"resolutionCode"]:@"NO_MEDIA";
            owner.nativeSessionRefreshInFlight=NO;
            if([code isEqual:@"AUTH_REQUIRED"]&&[owner refreshNativeSessionForReason:@"native_auth_required" httpStatus:MediaPlaybackExplicitHTTPStatus(error) error:error])return;
            owner.status.text=error.localizedDescription?:@"来源未返回可验证的视频 · 可重试或切换解析器";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];
            [RuntimeDiagnostics.shared recordEvent:@"native_resolution_failed" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":identity[@"sourceID"],@"failure_code":code,@"http_status":@(MediaPlaybackExplicitHTTPStatus(error)),@"request_generation":@(generation)}];
            [owner endBackgroundAutoAdvanceTaskIfNeeded];return;
        }
        owner.nativeSessionRefreshInFlight=NO;
        NSMutableDictionary *validated=[media mutableCopy];validated[@"resolutionIdentity"]=identity;
        owner.validatedPlaybackResult=validated.copy;owner.basePlaybackHeaders=nil;
        [RuntimeDiagnostics.shared recordEvent:@"native_resolution_succeeded" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":identity[@"sourceID"],@"parser_name":[media[@"parserName"] isKindOfClass:NSString.class]?media[@"parserName"]:@"",@"request_generation":@(generation)}];
        [owner playResult:owner.validatedPlaybackResult];
    }];
}
- (void)clearCurrentPlayerItem {
    [self clearCurrentPlayerItemPreservingPrefetch:NO];
}
- (void)clearCurrentPlayerItemPreservingPrefetch:(BOOL)preservePrefetch {
    [self cancelNativeResolution];
    self.playerGeneration++;self.nativeLeaseGeneration++;
    if(!preservePrefetch){self.prefetchGeneration++;[self.prefetchClient cancel];self.prefetchInFlight=NO;self.promotedPrefetchCompletion=nil;}
    AVPlayerItem *oldItem=self.player.currentItem;
    [self.player pause];self.playerController.player=nil;
    [self stopObservingCurrentPlayback];
    [oldItem cancelPendingSeeks];[oldItem.asset cancelLoading];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [self teardownCicadaAdapter];self.hasVideoTrack=NO;self.confirmedAudioOnly=NO;self.videoFrameReady=NO;
}
- (void)updateEpisodeTitle {
    NSArray *episodes=self.episodes;NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:nil;
    NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:@"";name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *spokenNumber=MediaPlaybackEpisodeNumber(name);NSString *number=spokenNumber.length?[NSString stringWithFormat:@"第 %@ 集",spokenNumber]:(episodes.count?[NSString stringWithFormat:@"第 %ld 集",(long)self.episodeIndex+1]:@"当前分集");
    NSString *title=name.length&&!MediaPlaybackEpisodeNamesMatch(name,number)?[NSString stringWithFormat:@"%@ · %@",number,name]:number;
    NSString *visibleTitle=[NSString stringWithFormat:@"正在播放 · %@",title];
    self.episodeTitle.text=visibleTitle;self.episodeTitle.accessibilityLabel=visibleTitle;
    self.inlineNowPlayingLabel.text=visibleTitle;self.inlineNowPlayingPill.accessibilityLabel=visibleTitle;self.inlineNowPlayingPill.hidden=!self.floatingInlineSurfaceInstalled;self.inlineNowPlayingPill.alpha=0.0;
    // Keep the selected episode visible in both the playback bar and the
    // navigation title; the series title alone is ambiguous during playback.
    self.title=title;
    NSString *line=self.lineIndex>=0&&self.lineIndex<self.lines.count?([self.lines[self.lineIndex][@"name"] isKindOfClass:NSString.class]?self.lines[self.lineIndex][@"name"]:@""):@"";
    NSString *label=line.length?[NSString stringWithFormat:@"选集 · %@ · %lu 集",line,(unsigned long)episodes.count]:@"选集";
    [self.episodeButton setTitle:label forState:UIControlStateNormal];self.episodeButton.enabled=episodes.count>0;self.episodeButton.alpha=episodes.count?1.0:0.55;self.nextEpisodeButton.hidden=(self.episodeIndex+1>=(NSInteger)episodes.count);[self updateSkipButtonForCurrentPosition];
    NSMutableDictionary *updatedContext=[self.context mutableCopy]?:[NSMutableDictionary dictionary];updatedContext[@"lineIndex"]=@(self.lineIndex);updatedContext[@"episodeIndex"]=@(self.episodeIndex);
    NSDictionary *selectedLine=self.lineIndex>=0&&self.lineIndex<self.lines.count?self.lines[self.lineIndex]:@{};updatedContext[@"lineID"]=[selectedLine[@"id"] description]?:@"";updatedContext[@"episodeID"]=[episode[@"id"] description]?:@"";updatedContext[@"episodeName"]=name?:@"";self.context=updatedContext;
    [self updateNowPlayingInfoCenter];
    if(self.onEpisodeSelectionChanged)self.onEpisodeSelectionChanged(self.context);
}
- (void)openEpisodeSelection {
    if(!self.lines.count)return;
    self.generation++;[self.client cancel];[self cancelNativeResolution];if(self.resolving){self.resolving=NO;[self.spinner stopAnimating];self.status.text=@"解析已取消 · 请选择分集";self.status.accessibilityLabel=self.status.text;}
    MediaEpisodeSelectionViewController *page=[MediaEpisodeSelectionViewController new];page.item=self.context[@"item"]?:@{};page.source=self.context[@"source"]?:@{};page.provider=self.context[@"provider"]?:@"";page.detail=self.context[@"detail"]?:@{};page.correlationID=self.diagnosticTraceID;page.parserID=MediaPlaybackSelectedParserID(self.context);page.selectedLineIndex=self.lineIndex;page.selectedEpisodeIndex=self.episodeIndex;page.selectedSeasonIndex=[self.context[@"seasonIndex"] integerValue];page.selectionUpdatesPlayer=YES;page.client=MediaPlaybackClientForSource(page.source);
    __weak typeof(self) weakSelf=self;page.onSelectEpisode=^(NSDictionary *result,NSDictionary *context){MediaPlaybackViewController *owner=weakSelf;if(!owner)return;[owner persistPlaybackProgress];owner.stallRecoveryAttempts=0;owner.basePlaybackHeaders=nil;owner.context=context;owner.lineIndex=[context[@"lineIndex"] integerValue];owner.episodeIndex=[context[@"episodeIndex"] integerValue];owner.pendingEpisodeResult=result;owner.pendingEpisodeGeneration=owner.generation;owner.attemptedRoutes=0;[owner resetAutomaticFallbackLines];[owner buildLines];if(owner.lineIndex<0||owner.lineIndex>=owner.lines.count)owner.lineIndex=0;if(owner.episodeIndex<0||owner.episodeIndex>=owner.episodes.count)owner.episodeIndex=0;[owner updateEpisodeTitle];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)playResult:(NSDictionary *)result {
    if(self.playbackSuspendedForVisibility)return;
    BOOL validated=result==self.validatedPlaybackResult&&[result[@"_nativeValidated"] boolValue]&&[result[@"_nativeValidatedURL"] isEqual:result[@"url"]]&&[result[@"resolutionIdentity"] isEqual:[self nativePlaybackResolutionIdentity]];
    if(!validated){[self resolveNativePlaybackResult:result?:@{}];return;}
    // 新解析结果（URL 变化）开始时清零回退链状态；同 URL 重放不复位，
    // 由 resolveAndPlay / 画质切换 / 分集选择处的显式复位负责。
    NSString *incomingURL=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";
    NSString *previousURL=[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@"";
    if(![incomingURL isEqualToString:previousURL])self.attemptedRoutes=0;
    NSString *decodeModePref=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaDecodeMode.v1"]?:@"auto";
    BOOL forceSoftDecode=[decodeModePref isEqualToString:@"cicada_soft"]||[result[@"preferSoftwareDecode"] boolValue];
    [self cancelNativeResolution];
    self.cicadaAdapterSoftwareDecodeFallbackAttempted=forceSoftDecode;self.resolving=NO;[self clearCurrentPlayerItem];NSUInteger playerGeneration=self.playerGeneration;self.videoTrackInspectionStarted=NO;self.lastPersistedPosition=0;if(!self.embeddedMode)self.throughputLabel.text=@"  测速中  ";
    self.progressEvidence=(HostPlaybackProgress){0};self.progressMilestone=0;self.progressSummaryRecorded=NO;self.diagnosticStallCount=0;self.cicadaWasLoading=NO;self.playbackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;self.terminalPlaybackOutcomeRecorded=NO;self.playbackFailureRecorded=NO;self.result=result;
    [self scheduleNativeSessionRefreshForResult:result];
    NSString *raw=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";NSURL *url=[NSURL URLWithString:raw];NSURL *sourceURL=MediaPlaybackOriginalSourceURL(result);NSString *serviceID=[self.context[@"source"][@"id"] isKindOfClass:NSString.class]?self.context[@"source"][@"id"]:@"";
    NSMutableDictionary *attemptFields=[@{@"playback_attempt_id":self.playbackAttemptID, @"active_playback_attempt_id":self.playbackAttemptID, @"active_playback_service_id":serviceID, @"active_playback_source_host":sourceURL.host.lowercaseString?:@"", @"active_playback_outcome":@"in_progress", @"last_playback_attempt_id":self.playbackAttemptID, @"last_playback_outcome":@"in_progress", @"last_playback_source_host":sourceURL.host.lowercaseString?:@"", @"last_playback_failure_kind":@"", @"last_playback_http_status":@0, @"last_playback_line_index":@(self.lineIndex), @"last_playback_episode_index":@(self.episodeIndex)} mutableCopy];
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"playback_attempt_started" fields:attemptFields];
    if(!url||raw.length>8192||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length||url.user.length||url.password.length||[raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[self.spinner stopAnimating];NSMutableDictionary *fields=[@{@"reason":@"invalid_media_url", @"failure_kind":@"invalid_media_url", @"playback_attempt_id":self.playbackAttemptID, @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];[RuntimeDiagnostics.shared recordEvent:@"episode_playback_rejected" category:@"playback" fields:fields];[self recordPlaybackAttemptOutcome:@"rejected" failureKind:@"invalid_media_url" httpStatus:0 terminal:YES];self.status.text=@"资源未返回有效的 HTTP/HTTPS 播放地址";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];return;}
    if(!self.basePlaybackHeaders)self.basePlaybackHeaders=[result[@"baseHeaders"] isKindOfClass:NSDictionary.class]?result[@"baseHeaders"]:MediaPlaybackHeadersFromResult(result);self.selectedAlternateIndex=-1;[self buildQualityButtons];self.resumeEntry=[MediaPlaybackStateStore historyEntryForContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex];self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.resumePromptShown=NO;
    NSNumber *qualityPosition=self.pendingQualitySeekTime;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=qualityPosition;if(!qualityPosition)self.pendingQualityRestorePlaybackState=NO;
    BOOL autoAdvancing=self.isAutoAdvancingEpisode;self.isAutoAdvancingEpisode=NO;
    NSTimeInterval savedPosition=[self.resumeEntry[@"position"] doubleValue],savedDuration=[self.resumeEntry[@"duration"] doubleValue];BOOL hasResume=self.resumeEntry&&![self.resumeEntry[@"completed"] boolValue]&&savedPosition>=15&&(!isfinite(savedDuration)||savedDuration<=0||savedPosition<savedDuration-10);
    if(!qualityPosition&&hasResume&&!autoAdvancing&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive){self.pendingPlaybackResumeEntry=self.resumeEntry;self.resumePromptPending=YES;self.pendingPlaybackSeekTime=nil;}
    MediaPlaybackDecodeRoute initialRoute=MediaPlaybackDecodeRouteNextForResult(result,self.attemptedRoutes);
    if(self.onPlaybackWillStart)self.onPlaybackWillStart();
    [RuntimeDiagnostics.shared recordEvent:@"playback_owner_acquired" category:@"playback" fields:@{@"owner":@"vod",@"engine":MediaPlaybackDecodeRouteName(initialRoute),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"service_id":serviceID,@"correlation_id":self.diagnosticTraceID?:@""}];
    if(initialRoute==MediaPlaybackDecodeRouteCicadaPlayer){[self startCicadaPlaybackWithResult:result url:url sourceURL:sourceURL playerGeneration:playerGeneration];return;}
    if(initialRoute==MediaPlaybackDecodeRouteNone){[self.spinner stopAnimating];self.status.text=@"该资源没有可用的播放方式 · 可切换线路";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];[self recordPlaybackAttemptOutcome:@"rejected" failureKind:@"no_playback_route" httpStatus:0 terminal:YES];return;}
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedAVPlayer;
    NSMutableDictionary *handoffFields=[@{@"player":@"avplayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(result))];[handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();self.status.text=@"正在载入媒体…";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];[self setRetryAvailable:NO];
    NSDictionary *requestHeaders=MediaPlaybackAVAssetHeaders(result,url);
    AVURLAsset *asset=[self consumePrefetchedAssetForURL:url headers:requestHeaders];
    BOOL preparedAssetReused=asset!=nil;
    if(!asset)asset=[self assetForPlaybackURL:url headers:requestHeaders];
    [RuntimeDiagnostics.shared recordEvent:@"playback_asset_selected" category:@"playback" fields:@{@"prepared_asset_reused":@(preparedAssetReused),@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@""}];
    self.startupBufferKickUsed=NO;
    [asset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
    item.canUseNetworkResourcesForLiveStreamingWhilePaused=YES;
    BOOL fastStartup=[[NSUserDefaults standardUserDefaults] objectForKey:@"fastNativeStartup"]?[[NSUserDefaults standardUserDefaults] boolForKey:@"fastNativeStartup"]:YES;
    item.preferredForwardBufferDuration=MediaPlaybackForwardBuffer(NO,fastStartup,[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"],0,[self playbackBufferConstrained]);
    // 默认清晰度只约束多码率 HLS 的自适应选线：单文件 MP4 只有一个码率，不受影响；央视直播走 SDK，不走这里。
    NSString *preferredQuality=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    if([preferredQuality isEqual:@"smooth"])item.preferredPeakBitRate=1500000;
    else if([preferredQuality isEqual:@"hd"])item.preferredPeakBitRate=4000000;
    else if([preferredQuality isEqual:@"uhd"])item.preferredPeakBitRate=8000000;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [self activateBackgroundAudioSessionIfNeeded];
    if(!self.player){self.player=[AVPlayer playerWithPlayerItem:item];[self.player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerTimeControlContext];self.observingPlayer=YES;}else[self.player replaceCurrentItemWithPlayerItem:item];
    if(@available(iOS 15.0,*))self.player.audiovisualBackgroundPlaybackPolicy=AVPlayerAudiovisualBackgroundPlaybackPolicyContinuesIfPossible;
    self.observedItem=item;[item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerItemStatusContext];self.player.automaticallyWaitsToMinimizeStalling=YES;self.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);self.playerController.videoGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;BOOL attachViewPlayer=(UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground||self.pictureInPictureActive);self.playerController.player=attachViewPlayer?self.player:nil;self.playbackOptionsItem.menu=[self playbackOptionsMenu];[self updateEstimatedThroughput];[self installProgressObserverIfNeeded];[self updateEpisodeTitle];
    __weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(owner&&playerGeneration==owner.playerGeneration)[owner observePlayerLayerIfAvailable];});
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime){if(!self.playbackSuspendedForVisibility)[self.player play];}[self watchAVPlayerFirstFrameForItem:item generation:playerGeneration url:url sourceURL:sourceURL];
}

- (void)watchAVPlayerFirstFrameForItem:(AVPlayerItem *)item generation:(NSUInteger)playerGeneration url:(NSURL *)url sourceURL:(NSURL *)sourceURL {
    [self.avFirstFrameTimer invalidate];self.avFirstFrameLastCheck=CACurrentMediaTime();self.avFirstFrameActiveWait=0;
    NSTimeInterval timeout=[sourceURL.scheme.lowercaseString isEqualToString:@"cenc"]?45:20;
    __weak typeof(self) weakSelf=self;
    self.avFirstFrameTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
        MediaPlaybackViewController *owner=weakSelf;
        if(!owner||playerGeneration!=owner.playerGeneration||item!=owner.observedItem||item!=owner.player.currentItem||owner.videoFrameReady||owner.confirmedAudioOnly||item.status==AVPlayerItemStatusFailed){[timer invalidate];if(owner.avFirstFrameTimer==timer)owner.avFirstFrameTimer=nil;return;}
        CFTimeInterval now=CACurrentMediaTime(),delta=MAX(0,now-owner.avFirstFrameLastCheck);owner.avFirstFrameLastCheck=now;
        // A user deciding whether to resume, a seek, or an intentional pause does
        // not consume the startup budget. The same timer continues after resume.
        if(owner.playbackSuspendedForVisibility||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.player.timeControlStatus==AVPlayerTimeControlStatusPaused||![owner isApplicationActiveForAVFirstFrameWatchdog])return;
        owner.avFirstFrameActiveWait+=MIN(delta,2.0);
        if(owner.avFirstFrameActiveWait<timeout)return;
        [timer invalidate];owner.avFirstFrameTimer=nil;
        NSTimeInterval position=CMTimeGetSeconds(owner.player.currentTime);NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":owner.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-owner.playbackStartedAt)*1000))), @"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"correlation_id":owner.diagnosticTraceID?:@"", @"time_control_status":@(owner.player.timeControlStatus), @"playback_position_seconds":@(isfinite(position)&&position>0?position:0), @"video_track_state":owner.hasVideoTrack?@"confirmed_video":@"unknown", @"video_layer_ready_for_display":@(owner.videoLayer.readyForDisplay), @"video_layer_width":@(MAX(0,(NSInteger)llround(owner.videoLayer.bounds.size.width))), @"video_layer_height":@(MAX(0,(NSInteger)llround(owner.videoLayer.bounds.size.height)))} mutableCopy];fields[@"controller_ready_for_display"]=@(owner.playerController.readyForDisplay);fields[@"controller_player_attached"]=@(owner.playerController.player==owner.player);fields[@"controller_view_in_window"]=@(owner.playerController.isViewLoaded&&owner.playerController.view.window!=nil);fields[@"controller_view_width"]=@(CGRectGetWidth(owner.playerController.view.bounds));fields[@"controller_view_height"]=@(CGRectGetHeight(owner.playerController.view.bounds));fields[@"controller_video_width"]=@(CGRectGetWidth(owner.playerController.videoBounds));fields[@"controller_video_height"]=@(CGRectGetHeight(owner.playerController.videoBounds));fields[@"embedded_mode"]=@(owner.embeddedMode);fields[@"wait_reason"]=owner.player.reasonForWaitingToPlay?:@"";[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(owner.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_video_frame_timeout" category:@"playback" fields:fields];[owner recordPlaybackAttemptOutcome:@"first_frame_timeout" failureKind:@"first_frame_timeout" httpStatus:0 terminal:NO];if(MediaPlaybackDecodeRouteNextForResult(owner.result,owner.attemptedRoutes)==MediaPlaybackDecodeRouteCicadaPlayer){[owner clearCurrentPlayerItem];owner.playbackFailureRecorded=NO;owner.terminalPlaybackOutcomeRecorded=NO;[owner startCicadaPlaybackWithResult:owner.result url:url sourceURL:sourceURL playerGeneration:owner.playerGeneration];return;}if([owner tryNextLineForAutomaticFallback:@"first_frame_timeout"])return;[owner.spinner stopAnimating];owner.status.text=@"播放器尚未显示画面 · 可重试或手动切换线路";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];
    }];
    self.avFirstFrameTimer.tolerance=0.2;
}
- (BOOL)isApplicationActiveForAVFirstFrameWatchdog {return UIApplication.sharedApplication.applicationState==UIApplicationStateActive;}

- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration {
    if(self.playbackSuspendedForVisibility)return;
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
    NSMutableDictionary *handoffFields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(result))];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];
    [RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();
    self.status.text=self.cicadaAdapterSoftwareDecodeFallbackAttempted?@"正在使用 CicadaPlayer 软解码 (cc) 载入媒体…":@"正在使用 ffmpeg 内核载入媒体…";self.status.accessibilityLabel=self.status.text;
    [self.spinner startAnimating];[self setRetryAvailable:NO];
    NSTimeInterval timeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;
    NSDictionary *requestHeaders=MediaPlaybackHeadersFromResult(@{
        @"headers":self.basePlaybackHeaders?:@{},
        @"header":result[@"baseHeaders"]?:@{},
        @"customHeaders":MediaPlaybackHeadersFromResult(result)});
    NSURL *effectiveURL=url;
    NSString *urlHost=url.host.lowercaseString?:@"";
    BOOL isLoopbackRelay=[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:urlHost]&&sourceURL&&[@[@"http",@"https"] containsObject:sourceURL.scheme.lowercaseString]&&![sourceURL.absoluteString isEqualToString:url.absoluteString];
    // Only the explicit clear-DASH remux bridge may be bypassed. Other local
    // URLs implement headers, cookies, key handling or disguised segment repair.
    if(isLoopbackRelay&&[result[@"dashRemuxed"] boolValue])effectiveURL=sourceURL;
    MediaPlaybackCicadaAdapter *adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:effectiveURL headers:requestHeaders networkTimeout:timeout];
    adapter.delegate=self;self.cicadaAdapter=adapter;self.cicadaPosition=0;self.cicadaDuration=0;
    UIView *playerView=adapter.playerView;playerView.translatesAutoresizingMaskIntoConstraints=NO;
    [self.videoView addSubview:playerView];
    [NSLayoutConstraint activateConstraints:@[[playerView.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[playerView.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[playerView.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[playerView.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];
    [self.playerController.view setHidden:YES];
    [self refreshCicadaControls];
    NSString *gravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    [adapter applyVideoGravity:gravity];
    // 硬解开关：软件解码重试时 cicadaAdapterSoftwareDecodeFallbackAttempted
    // 已置位，prepare 即用软件解码重建（见 advanceFromCicadaFailureWithError:）。
    [adapter prepareWithHardwareDecoder:!self.cicadaAdapterSoftwareDecodeFallbackAttempted];
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime)[adapter start];
    [self refreshCicadaControls];
    // 视图控制器与适配器使用同一超时，避免短超时抢先结束网络准备。
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(adapter.firstFrameTimeout*NSEC_PER_SEC)),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||playerGeneration!=owner.playerGeneration||owner.cicadaAdapter!=adapter||owner.playbackSuspendedForVisibility||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.videoFrameReady)return;[owner handleCicadaFirstFrameTimeoutForAdapter:adapter];});
}
- (UIButton *)cicadaControlButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tintColor=UIColor.whiteColor;button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];button.accessibilityLabel=label;
    if(symbol.length)[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];else[button setTitle:label forState:UIControlStateNormal];
    if(action)[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;return button;
}
- (void)installCicadaControls {
    self.cicadaControls=[UIView new];self.cicadaControls.translatesAutoresizingMaskIntoConstraints=NO;self.cicadaControls.backgroundColor=[UIColor colorWithWhite:0 alpha:0.76];self.cicadaControls.layer.cornerRadius=12;self.cicadaControls.hidden=YES;self.cicadaControls.accessibilityIdentifier=@"media-cicada-controls";[self.videoView addSubview:self.cicadaControls];
    self.cicadaRewindButton=[self cicadaControlButton:@"gobackward.10" label:@"后退10秒" action:@selector(cicadaRewind)];
    self.cicadaPlayPauseButton=[self cicadaControlButton:@"pause.fill" label:@"暂停" action:@selector(toggleCicadaPlayback)];self.cicadaPlayPauseButton.accessibilityIdentifier=@"media-cicada-play-pause";
    self.cicadaForwardButton=[self cicadaControlButton:@"goforward.10" label:@"快进10秒" action:@selector(cicadaForward)];
    self.cicadaRateButton=[self cicadaControlButton:nil label:@"倍速" action:NULL];self.cicadaRateButton.showsMenuAsPrimaryAction=YES;
    self.cicadaOptionsButton=[self cicadaControlButton:@"slider.horizontal.3" label:@"画面比例与播放设置" action:NULL];self.cicadaOptionsButton.showsMenuAsPrimaryAction=YES;
    self.cicadaFullscreenButton=[self cicadaControlButton:@"arrow.up.left.and.arrow.down.right" label:@"全屏" action:@selector(toggleCicadaFullscreen)];self.cicadaFullscreenButton.accessibilityIdentifier=@"media-cicada-fullscreen";
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[self.cicadaRewindButton,self.cicadaPlayPauseButton,self.cicadaForwardButton,self.cicadaRateButton,self.cicadaOptionsButton,self.cicadaFullscreenButton]];buttons.distribution=UIStackViewDistributionFillEqually;buttons.spacing=2;
    self.cicadaElapsedLabel=[UILabel new];self.cicadaDurationLabel=[UILabel new];
    for(UILabel *label in @[self.cicadaElapsedLabel,self.cicadaDurationLabel]){label.textColor=UIColor.whiteColor;label.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];[label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];}
    self.cicadaSeekSlider=[UISlider new];self.cicadaSeekSlider.minimumValue=0;self.cicadaSeekSlider.maximumValue=1;self.cicadaSeekSlider.minimumTrackTintColor=UIColor.whiteColor;self.cicadaSeekSlider.accessibilityLabel=@"播放进度";self.cicadaSeekSlider.accessibilityIdentifier=@"media-cicada-progress";
    [self.cicadaSeekSlider addTarget:self action:@selector(beginCicadaScrubbing) forControlEvents:UIControlEventTouchDown];[self.cicadaSeekSlider addTarget:self action:@selector(changeCicadaScrubbing) forControlEvents:UIControlEventValueChanged];[self.cicadaSeekSlider addTarget:self action:@selector(endCicadaScrubbing) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];[self.cicadaSeekSlider addTarget:self action:@selector(cancelCicadaScrubbing) forControlEvents:UIControlEventTouchCancel];
    UIStackView *timeline=[[UIStackView alloc] initWithArrangedSubviews:@[self.cicadaElapsedLabel,self.cicadaSeekSlider,self.cicadaDurationLabel]];timeline.spacing=8;timeline.alignment=UIStackViewAlignmentCenter;[timeline.heightAnchor constraintEqualToConstant:28].active=YES;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[buttons,timeline]];stack.translatesAutoresizingMaskIntoConstraints=NO;stack.axis=UILayoutConstraintAxisVertical;[self.cicadaControls addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[self.cicadaControls.leadingAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.leadingAnchor constant:8],[self.cicadaControls.trailingAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.trailingAnchor constant:-8],[self.cicadaControls.bottomAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.bottomAnchor constant:-8],[stack.leadingAnchor constraintEqualToAnchor:self.cicadaControls.leadingAnchor constant:8],[stack.trailingAnchor constraintEqualToAnchor:self.cicadaControls.trailingAnchor constant:-8],[stack.topAnchor constraintEqualToAnchor:self.cicadaControls.topAnchor constant:2],[stack.bottomAnchor constraintEqualToAnchor:self.cicadaControls.bottomAnchor constant:-4]]];
}
- (void)refreshCicadaControls {
    BOOL active=self.cicadaAdapter!=nil;self.cicadaControls.hidden=!active;
    if(!active)return;
    [self.videoView bringSubviewToFront:self.cicadaControls];[self.videoView bringSubviewToFront:self.screenLockButton];[self.videoView bringSubviewToFront:self.gestureFeedbackLabel];
    self.cicadaControls.userInteractionEnabled=!self.gestureLockActive;self.cicadaControls.alpha=self.gestureLockActive?0.35:1;
    BOOL ready=self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying||self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePaused||self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStateCompleted;
    BOOL playing=self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying;
    [self.cicadaPlayPauseButton setImage:[UIImage systemImageNamed:playing?@"pause.fill":@"play.fill"] forState:UIControlStateNormal];self.cicadaPlayPauseButton.accessibilityLabel=playing?@"暂停":@"播放";self.cicadaPlayPauseButton.enabled=ready&&!self.resumePromptPending;
    double duration=self.cicadaAdapter.duration,position=self.cicadaAdapter.currentPosition;if(!isfinite(position)||position<0)position=0;BOOL seekable=ready&&isfinite(duration)&&duration>0;
    self.cicadaSeekSlider.enabled=seekable;self.cicadaRewindButton.enabled=seekable;self.cicadaForwardButton.enabled=seekable;
    if(!self.cicadaScrubbing){self.cicadaSeekSlider.value=seekable?(float)MIN(1,MAX(0,position/duration)):0;self.cicadaElapsedLabel.text=[self formatMediaTime:isfinite(position)?MAX(0,position):0];}
    self.cicadaDurationLabel.text=seekable?[self formatMediaTime:duration]:(ready?@"直播":@"--:--");
    if(!self.cicadaRateButton.menu)self.cicadaRateButton.menu=[self playbackRateMenu];[self.cicadaRateButton setTitle:[NSString stringWithFormat:@"%.2g×",self.cicadaAdapter.rate] forState:UIControlStateNormal];self.cicadaOptionsButton.menu=self.playbackOptionsItem.menu?:[self playbackOptionsMenu];
    self.cicadaSeekSlider.accessibilityValue=[NSString stringWithFormat:@"%@ / %@",self.cicadaElapsedLabel.text,self.cicadaDurationLabel.text];
}
- (void)toggleCicadaPlayback {
    if(!self.cicadaAdapter||self.gestureLockActive)return;
    if(self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying)[self pauseActiveEngine];
    else if(self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStateCompleted){id adapter=self.cicadaAdapter;[self seekActiveEngineToTime:0 completion:^(BOOL finished){if(finished&&adapter==self.cicadaAdapter)[self playActiveEngine];}];}
    else[self playActiveEngine];
    [self refreshCicadaControls];
}
- (void)seekCicadaBy:(NSTimeInterval)delta {if(!self.cicadaAdapter||!self.cicadaSeekSlider.enabled||self.gestureLockActive)return;double duration=self.cicadaAdapter.duration,target=MIN(duration,MAX(0,self.cicadaAdapter.currentPosition+delta));id adapter=self.cicadaAdapter;[self seekActiveEngineToTime:target completion:^(BOOL finished){if(adapter==self.cicadaAdapter)[self refreshCicadaControls];}];}
- (void)cicadaRewind {[self seekCicadaBy:-10];}
- (void)cicadaForward {[self seekCicadaBy:10];}
- (void)beginCicadaScrubbing {if(!self.cicadaSeekSlider.enabled)return;self.cicadaScrubbing=YES;self.cicadaScrubWasPlaying=self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying;}
- (void)changeCicadaScrubbing {if(!self.cicadaSeekSlider.enabled)return;if(!self.cicadaScrubbing)[self beginCicadaScrubbing];self.cicadaElapsedLabel.text=[self formatMediaTime:self.cicadaSeekSlider.value*self.cicadaAdapter.duration];}
- (void)cancelCicadaScrubbing {self.cicadaScrubbing=NO;[self refreshCicadaControls];}
- (void)endCicadaScrubbing {
    if(!self.cicadaScrubbing||!self.cicadaAdapter)return;self.cicadaScrubbing=NO;id adapter=self.cicadaAdapter;NSUInteger generation=self.playerGeneration;BOOL wasPlaying=self.cicadaScrubWasPlaying;double target=self.cicadaSeekSlider.value*self.cicadaAdapter.duration;
    [self seekActiveEngineToTime:target completion:^(BOOL finished){if(generation!=self.playerGeneration||adapter!=self.cicadaAdapter)return;if(finished){if(wasPlaying)[self playActiveEngine];else[self pauseActiveEngine];}[self refreshCicadaControls];}];
}
- (void)toggleCicadaFullscreen {
    if(self.cicadaFullscreenHost){[self.cicadaFullscreenHost closeFullscreen];return;}
    if(!self.cicadaAdapter||self.presentedViewController||!self.videoView.window)return;
    UIView *original=self.videoView.superview;if(!original)return;
    self.cicadaVideoOriginalSuperview=original;self.cicadaVideoOriginalIndex=[original.subviews indexOfObject:self.videoView];
    NSMutableArray *constraints=[NSMutableArray array];
    for(UIView *ancestor=original;ancestor;ancestor=ancestor.superview)for(NSLayoutConstraint *constraint in ancestor.constraints)if(constraint.active&&(constraint.firstItem==self.videoView||constraint.secondItem==self.videoView))[constraints addObject:constraint];
    for(NSLayoutConstraint *constraint in self.videoView.constraints)if(constraint.active&&constraint.firstItem==self.videoView&&(constraint.secondItem==self.videoView||!constraint.secondItem))[constraints addObject:constraint];
    self.cicadaFullscreenSavedConstraints=constraints.copy;[NSLayoutConstraint deactivateConstraints:constraints];
    MediaPlaybackFullscreenHost *host=[MediaPlaybackFullscreenHost new];host.modalPresentationStyle=UIModalPresentationOverFullScreen;self.cicadaFullscreenHost=host;__weak typeof(self) weakSelf=self;host.onClose=^{[weakSelf restoreVideoFromCicadaFullscreen];};
    [host loadViewIfNeeded];[self.videoView removeFromSuperview];[host.view insertSubview:self.videoView atIndex:0];
    self.cicadaFullscreenConstraints=@[[self.videoView.leadingAnchor constraintEqualToAnchor:host.view.leadingAnchor],[self.videoView.trailingAnchor constraintEqualToAnchor:host.view.trailingAnchor],[self.videoView.topAnchor constraintEqualToAnchor:host.view.topAnchor],[self.videoView.bottomAnchor constraintEqualToAnchor:host.view.bottomAnchor]];[NSLayoutConstraint activateConstraints:self.cicadaFullscreenConstraints];
    [self presentViewController:host animated:YES completion:nil];
}
- (void)restoreVideoFromCicadaFullscreen {
    if(!self.cicadaFullscreenHost)return;
    [NSLayoutConstraint deactivateConstraints:self.cicadaFullscreenConstraints?:@[]];
    UIView *original=self.cicadaVideoOriginalSuperview;[self.videoView removeFromSuperview];if(original)[original insertSubview:self.videoView atIndex:MIN(self.cicadaVideoOriginalIndex,original.subviews.count)];
    self.cicadaFullscreenHost.onClose=nil;self.cicadaFullscreenHost=nil;self.cicadaFullscreenConstraints=nil;
    if(original)[NSLayoutConstraint activateConstraints:self.cicadaFullscreenSavedConstraints?:@[]];self.cicadaFullscreenSavedConstraints=nil;self.cicadaVideoOriginalSuperview=nil;self.playbackLayoutInitialized=NO;
    [self updatePlaybackLayoutForSize:self.view.bounds.size];[self refreshCicadaControls];
}
- (BOOL)isCicadaEngineActive { return self.cicadaAdapter!=nil; }
- (NSTimeInterval)activeEngineCurrentPosition {
    if(self.cicadaAdapter)return self.cicadaAdapter.currentPosition;
    return CMTimeGetSeconds(self.player.currentTime);
}
- (NSTimeInterval)activeEngineDuration {
    if(self.cicadaAdapter)return self.cicadaAdapter.duration;
    AVPlayerItem *item=self.observedItem;
    if(!item||item.status!=AVPlayerItemStatusReadyToPlay||[item.asset statusOfValueForKey:@"duration" error:NULL]!=AVKeyValueStatusLoaded)return 0;
    return CMTimeGetSeconds(item.duration);
}
- (void)seekActiveEngineToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion {
    if(self.cicadaAdapter){[self.cicadaAdapter seekToTime:time completion:completion];return;}
    [self.player seekToTime:CMTimeMakeWithSeconds(time,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completion?:^(BOOL finished){}];
}
- (void)setActiveEngineRate:(float)rate {
    if(self.cicadaAdapter){[self.cicadaAdapter setRate:rate];[self refreshCicadaControls];return;}
    self.player.defaultRate=rate;[self updateForwardBufferForItem:self.observedItem];
}
- (void)pauseActiveEngine {
    if(self.cicadaAdapter){[self.cicadaAdapter pause];[self refreshCicadaControls];return;}
    [self.player pause];
}
- (void)playActiveEngine {
    if(self.playbackSuspendedForVisibility)return;
    if(self.cicadaAdapter){[self.cicadaAdapter start];[self refreshCicadaControls];return;}
    {if(!self.playbackSuspendedForVisibility)[self.player play];}
}
- (void)teardownCicadaAdapter {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;self.cicadaAdapter=nil;
    self.cicadaScrubbing=NO;[self refreshCicadaControls];
    if(!adapter)return;
    [adapter.playerView removeFromSuperview];
    [adapter destroy];
    [self.playerController.view setHidden:NO];
}
- (void)markCicadaFirstFrameReady {
    if(self.videoFrameReady)return;
    self.nativeSessionRefreshInFlight=NO;self.nativeSessionRefreshAttempted=NO;self.nativeSessionRefreshURL=nil;
    self.videoFrameReady=YES;self.hasVideoTrack=self.cicadaAdapter.hasVideoTrack;self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;self.inlineNowPlayingPill.alpha=0.0;if(!self.gestureLockActive)self.screenLockButton.alpha=0.0;
    [self.spinner stopAnimating];
    self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"media_first_frame_ready" category:@"playback" fields:fields];
}
- (void)advanceFromCicadaFailureWithError:(NSError *)error {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;
    if(!adapter)return; // 已回退过或已拆解：幂等，不重复推进
    NSInteger httpStatus=MediaPlaybackExplicitHTTPStatus(error);
    if((httpStatus==401||httpStatus==403)&&[self refreshNativeSessionForReason:@"native_auth_required" httpStatus:httpStatus error:error])return;
    [self teardownCicadaAdapter];
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"failure_kind":@"cicada_playback_failed", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:@"cicada_playback_failed" httpStatus:0 terminal:NO];
    // 软件解码重试（移植自直连路径 handleCicadaFailure: 的解码关键词表）：
    // 报错指向解码且尚未试过软件解码时，用软件解码重建一次适配器，
    // 从上次位置续播（pendingPlaybackSeekTime 由 prepare 回调消费）。
    BOOL decoderFailure=MediaPlaybackCicadaErrorAllowsSoftwareRetry(error);
    if(!self.cicadaAdapterSoftwareDecodeFallbackAttempted&&decoderFailure){
        self.cicadaAdapterSoftwareDecodeFallbackAttempted=YES;
        NSTimeInterval position=self.cicadaPosition;
        self.pendingPlaybackSeekTime=@(isfinite(position)&&position>0?position:0);self.pendingQualityWasPlaying=YES;self.pendingQualityRestorePlaybackState=YES;
        NSMutableDictionary *retryFields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"software_decode_fallback_available":@YES, @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
        [retryFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
        [RuntimeDiagnostics.shared recordEvent:@"cicada_software_decode_fallback" category:@"playback" fields:retryFields];
        [self recordPlaybackAttemptOutcome:@"software_decode_fallback" failureKind:@"hardware_decoder_error" httpStatus:0 terminal:NO];
        NSURL *retryURL=[NSURL URLWithString:[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@""];
        [self startCicadaPlaybackWithResult:self.result url:retryURL sourceURL:MediaPlaybackOriginalSourceURL(self.result) playerGeneration:self.playerGeneration];
        return;
    }
    MediaPlaybackDecodeRoute nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
    NSString *failedSourceExt=MediaPlaybackOriginalSourceURL(self.result).pathExtension.lowercaseString?:@"";
    BOOL avIncompatibleContainer=[@[@"mpd",@"flv",@"mkv",@"webm"] containsObject:failedSourceExt];
    if(nextRoute==MediaPlaybackDecodeRouteAVPlayer&&avIncompatibleContainer&&![self.result[@"dashRemuxed"] boolValue]){
        self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedAVPlayer;
        nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
    }
    if(nextRoute==MediaPlaybackDecodeRouteAVPlayer){
        NSMutableDictionary *avCandidate=[self.result mutableCopy]?:[NSMutableDictionary dictionary];
        avCandidate[@"playbackEngine"]=@"avplayer";avCandidate[@"requiresWebPlayback"]=@NO;avCandidate[@"parse"]=@0;avCandidate[@"jx"]=@0;
        [self playResult:avCandidate.copy];
        return;
    }
    // 无下一路时也自动试下一条线路（与 AVPlayer/直连路径同款回退）。
    if([self tryNextLineForAutomaticFallback:@"cicada_playback_failed"])return;
    // 无下一路：显示失败（与 AVPlayer 最终失败同一文案风格）。
    [self.spinner stopAnimating];
    self.status.text=@"ffmpeg 内核也无法播放此资源 · 可重试或切换线路";self.status.accessibilityLabel=self.status.text;
    [self setRetryAvailable:YES];
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:@"cicada_playback_failed" httpStatus:0 terminal:YES];
}
- (void)handleCicadaFirstFrameTimeoutForAdapter:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    NSError *error=[NSError errorWithDomain:MediaPlaybackCicadaAdapterErrorDomain code:-1001 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"CicadaPlayer %.0f 秒内未显示首帧",self.cicadaAdapter.firstFrameTimeout]}];
    [self advanceFromCicadaFailureWithError:error];
}
- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage {
    if(!item||item!=self.observedItem||item!=self.player.currentItem||self.playbackFailureRecorded)return;
    self.playbackFailureRecorded=YES;[self updateEstimatedThroughput];[self.spinner stopAnimating];NSError *failure=error?:item.error;AVPlayerItemErrorLogEvent *networkError=item.errorLog.events.lastObject;NSString *kind=MediaPlaybackFailureKind(failure,networkError);
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"stage":stage?:@"unknown", @"failure_kind":kind, @"error_domain":failure.domain?:@"", @"error_code":@(failure.code), @"error_message":failure.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    if(networkError){fields[@"network_error_domain"]=networkError.errorDomain?:@"";fields[@"network_error_status_code"]=@(networkError.errorStatusCode);NSURL *networkURL=[NSURL URLWithString:networkError.URI?:@""];if(networkURL.host.length){fields[@"network_error_host"]=networkURL.host.lowercaseString;fields[@"network_error_extension"]=networkURL.pathExtension.lowercaseString?:@"";}}
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(self.result))];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];
    if((networkError.errorStatusCode==401||networkError.errorStatusCode==403)&&[self refreshNativeSessionForReason:@"native_auth_required" httpStatus:networkError.errorStatusCode error:failure])return;
    MediaPlaybackDecodeRoute nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
    if(nextRoute==MediaPlaybackDecodeRouteCicadaPlayer){
        // 新尝试：清掉本次失败标记，让 Cicada 路径有自己的失败上报。
        NSTimeInterval position=CMTimeGetSeconds(item.currentTime);
        if(!self.pendingPlaybackSeekTime&&isfinite(position)&&position>0)self.pendingPlaybackSeekTime=@(position);
        self.playbackFailureRecorded=NO;self.terminalPlaybackOutcomeRecorded=NO;
        self.resumePromptPending=NO;
        [self clearCurrentPlayerItem];
        NSURL *fallbackURL=[NSURL URLWithString:[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@""];
        [self startCicadaPlaybackWithResult:self.result url:fallbackURL sourceURL:MediaPlaybackOriginalSourceURL(self.result) playerGeneration:self.playerGeneration];
        return;
    }
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:kind httpStatus:networkError.errorStatusCode terminal:YES];
    BOOL offline=[failure.domain isEqualToString:NSURLErrorDomain]&&failure.code==NSURLErrorNotConnectedToInternet;
    if(!offline&&[self tryNextLineForAutomaticFallback:kind])return;
    self.status.text=MediaPlaybackFailureMessage(failure,networkError);self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if(context==CCTVPlayerItemStatusContext){AVPlayerItem *item=(AVPlayerItem *)object;if(item.status==AVPlayerItemStatusFailed){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=nil;[self recordPlaybackFailureForItem:item error:item.error stage:@"item_status_failed"];});}else if(item.status==AVPlayerItemStatusReadyToPlay){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.hasVideoTrack=self.videoFrameReady||(item.presentationSize.width>0&&item.presentationSize.height>0);if(!self.hasVideoTrack&&[item.asset statusOfValueForKey:@"tracks" error:NULL]==AVKeyValueStatusLoaded){for(AVPlayerItemTrack *track in item.tracks)if(track.assetTrack.mediaType==AVMediaTypeVideo){self.hasVideoTrack=YES;break;}}NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"video_track_state":self.hasVideoTrack?@"confirmed_video":@"unknown", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"media_item_ready" category:@"playback" fields:fields];[self inspectVideoTracksForItem:item generation:self.playerGeneration];self.playbackOptionsItem.menu=[self playbackOptionsMenu];if(self.pendingPlaybackSeekTime)[self applyPendingPlaybackSeekForItem:item];else if(self.resumePromptPending)[self offerResumeForItem:item];else{[self activateBackgroundAudioSessionIfNeeded];{if(!self.playbackSuspendedForVisibility)[self.player play];}[self startAVPlayerFromReadyBufferIfNeeded:item];[self updateNowPlayingInfoCenter];}if((self.playerController.readyForDisplay||self.videoLayer.readyForDisplay)&&!self.videoFrameReady)[self markFirstVideoFrameReadyForItem:item];if(self.hasVideoTrack){if(!self.videoFrameReady){self.status.text=@"媒体已准备 · 等待视频首帧显示";self.status.accessibilityLabel=self.status.text;if(self.player.timeControlStatus==AVPlayerTimeControlStatusPaused)[self.spinner stopAnimating];else[self.spinner startAnimating];[self observePlayerLayerIfAvailable];}}else{[self.spinner stopAnimating];self.status.text=@"媒体已准备 · 视频轨道尚未确认";self.status.accessibilityLabel=self.status.text;}});}return;}
    if(context==CCTVPlayerControllerReadyContext){AVPlayerViewController *controller=(AVPlayerViewController *)object;AVPlayerItem *item=self.observedItem;NSUInteger generation=self.playerGeneration;if(controller==self.playerController&&controller.readyForDisplay){dispatch_async(dispatch_get_main_queue(),^{if(generation==self.playerGeneration&&item==self.observedItem&&item==self.player.currentItem&&controller==self.playerController&&controller.readyForDisplay)[self markFirstVideoFrameReadyForItem:item];});}return;}
    if(context==CCTVPlayerLayerReadyContext){AVPlayerLayer *layer=(AVPlayerLayer *)object;AVPlayerItem *item=self.observedItem;NSUInteger generation=self.playerGeneration;if(layer==self.videoLayer&&layer.readyForDisplay){dispatch_async(dispatch_get_main_queue(),^{if(generation==self.playerGeneration&&item==self.observedItem&&layer==self.videoLayer&&layer.readyForDisplay)[self markFirstVideoFrameReadyForItem:item];});}return;}
    if(context==CCTVPlayerTimeControlContext){AVPlayerItem *reportedItem=self.player.currentItem;NSUInteger reportedGeneration=self.playerGeneration;AVPlayerTimeControlStatus state=self.player.timeControlStatus;dispatch_async(dispatch_get_main_queue(),^{if(!reportedItem||reportedGeneration!=self.playerGeneration||reportedItem!=self.observedItem||reportedItem!=self.player.currentItem||self.playbackFailureRecorded)return;if(!self.hasDiagnosticTimeControlStatus||self.lastDiagnosticTimeControlStatus!=(NSInteger)state){self.hasDiagnosticTimeControlStatus=YES;self.lastDiagnosticTimeControlStatus=(NSInteger)state;NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"video_track_state":self.hasVideoTrack?@"confirmed_video":@"unknown"} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,self.observedItem);if(state==AVPlayerTimeControlStatusPlaying){[self endBackgroundAutoAdvanceTaskIfNeeded];[self updateNowPlayingInfoCenter];[RuntimeDiagnostics.shared recordEvent:@"player_reports_playing" category:@"playback" fields:fields];}else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){fields[@"wait_reason"]=self.player.reasonForWaitingToPlay?:@"unknown";[RuntimeDiagnostics.shared recordEvent:@"player_waiting_to_play" category:@"playback" fields:fields];}}if(self.resolving)return;if(state==AVPlayerTimeControlStatusPlaying){if(self.confirmedAudioOnly){self.status.text=@"AVPlayer 正在播放音频";[self.spinner stopAnimating];}else if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · AVPlayer 正在播放";[self.spinner stopAnimating];}else if(self.hasVideoTrack){self.status.text=@"AVPlayer 正在播放 · 等待视频首帧";[self.spinner startAnimating];}else{self.status.text=@"播放器报告播放中 · 视频画面未确认";[self.spinner stopAnimating];}}else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){if(self.videoFrameReady&&!self.startupBufferKickUsed&&!self.resumePromptPending&&!self.pendingPlaybackSeekTime&&[self bufferedAheadForItem:reportedItem]>=1.0){[self startAVPlayerFromReadyBufferIfNeeded:reportedItem];self.status.text=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying?@"视频首帧已就绪 · AVPlayer 正在播放":@"视频首帧已就绪 · 正在缓冲 · 等待 AVPlayer";[self.spinner stopAnimating];}else if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · 正在缓冲 · 等待 AVPlayer";[self.spinner startAnimating];}else{self.status.text=@"正在缓冲 · 等待 AVPlayer";[self.spinner startAnimating];}}else if(self.player.currentItem.status==AVPlayerItemStatusReadyToPlay){self.status.text=self.videoFrameReady?@"视频首帧已就绪 · 当前已暂停":(self.hasVideoTrack?@"媒体已准备 · 当前已暂停，等待视频首帧":@"媒体已准备 · 当前暂停");if(!self.videoFrameReady)[self.spinner stopAnimating];}self.status.accessibilityLabel=self.status.text;});return;}
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)playerItemStalled:(NSNotification *)notification {
    if(!NSThread.isMainThread){NSNotification *note=notification;dispatch_async(dispatch_get_main_queue(),^{[self playerItemStalled:note];});return;}
    AVPlayerItem *item=notification.object;if(item!=self.observedItem||item!=self.player.currentItem)return;
    self.diagnosticStallCount++;[self updateForwardBufferForItem:item];
    self.status.text=@"媒体缓冲中 · 等待网络数据";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];
    NSUInteger generation=self.playerGeneration;NSTimeInterval stalledAt=CMTimeGetSeconds(self.player.currentTime);if(!isfinite(stalledAt)||stalledAt<0)stalledAt=0;
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"video_track_state":self.hasVideoTrack?@"confirmed_video":@"unknown"} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_stalled" category:@"playback" fields:fields];
    __weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        MediaPlaybackViewController *owner=weakSelf;
        if(!owner||generation!=owner.playerGeneration||item!=owner.observedItem||item!=owner.player.currentItem)return;
        NSTimeInterval now=CMTimeGetSeconds(owner.player.currentTime);if(!isfinite(now)||now<0)now=0;
        NSString *skipReason=nil;
        if(owner.resolving)skipReason=@"already_resolving";
        else if(owner.stallRecoveryAttempts>=1)skipReason=@"attempt_limit_reached";
        else if(owner.player.timeControlStatus!=AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate)skipReason=@"player_no_longer_waiting";
        else if(fabs(now-stalledAt)>0.5)skipReason=@"playback_progress_resumed";
        if(skipReason){[RuntimeDiagnostics.shared recordEvent:@"playback_stall_recovery_skipped" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"playback_attempt_id":owner.playbackAttemptID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex),@"reason":skipReason,@"stalled_position_seconds":@(stalledAt),@"current_position_seconds":@(now),@"attempts_used":@(owner.stallRecoveryAttempts)}];return;}
        owner.stallRecoveryAttempts++;owner.pendingQualitySeekTime=@(stalledAt);owner.pendingQualityWasPlaying=YES;owner.pendingQualityRestorePlaybackState=YES;owner.pendingResolutionReason=@"stall_recovery";owner.status.text=@"网络长时间未推进 · 正在重新获取当前分集";
        [RuntimeDiagnostics.shared recordEvent:@"playback_stall_recovery_started" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"playback_attempt_id":owner.playbackAttemptID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex),@"attempt":@(owner.stallRecoveryAttempts),@"stalled_position_seconds":@(stalledAt),@"current_position_seconds":@(now)}];
        [owner resolveAndPlay];
    });
}
- (void)playerItemEnded:(NSNotification *)notification {
    if(!NSThread.isMainThread){NSNotification *note=notification;dispatch_async(dispatch_get_main_queue(),^{[self playerItemEnded:note];});return;}
    if(notification.object!=self.observedItem||notification.object!=self.player.currentItem)return;
    NSTimeInterval position=CMTimeGetSeconds(self.player.currentTime),duration=CMTimeGetSeconds(self.observedItem.duration);if(!isfinite(position)||position<0)position=0;if(!isfinite(duration)||duration<0)duration=0;
    [MediaPlaybackStateStore recordContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:YES];[self.spinner stopAnimating];[self recordPlaybackAttemptOutcome:@"completed" failureKind:nil httpStatus:0 terminal:YES];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    if(autoNext&&self.episodeIndex+1<self.episodes.count){self.isAutoAdvancingEpisode=YES;[self activateBackgroundAudioSessionIfNeeded];[self beginBackgroundAutoAdvanceTaskIfNeeded];NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"auto_advance";[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    [self endBackgroundAutoAdvanceTaskIfNeeded];
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;[self refreshCicadaControls];
}
#pragma mark - MediaPlaybackCicadaAdapterDelegate
- (void)cicadaAdapterDidPrepare:(id)adapter {
    if(adapter!=self.cicadaAdapter||self.playbackSuspendedForVisibility)return;
    [self refreshCicadaControls];
    [self.cicadaAdapter setRate:(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0)];
    if(self.pendingPlaybackSeekTime)[self applyPendingPlaybackSeekForCicada];
    else if(self.resumePromptPending)[self offerResumeForCicada];
}
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    [self markCicadaFirstFrameReady];
}
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error {
    if(adapter!=self.cicadaAdapter)return;
    [self advanceFromCicadaFailureWithError:error];
}
- (void)cicadaAdapterDidComplete:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    NSTimeInterval position=self.cicadaPosition,duration=self.cicadaDuration;
    [MediaPlaybackStateStore recordContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:YES];
    [self.spinner stopAnimating];[self recordPlaybackAttemptOutcome:@"completed" failureKind:nil httpStatus:0 terminal:YES];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]?[NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    if(autoNext&&self.episodeIndex+1<self.episodes.count){self.isAutoAdvancingEpisode=YES;[self activateBackgroundAudioSessionIfNeeded];[self beginBackgroundAutoAdvanceTaskIfNeeded];NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;self.pendingResolutionReason=@"auto_advance";[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    [self endBackgroundAutoAdvanceTaskIfNeeded];
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;[self refreshCicadaControls];
}
- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    if(adapter!=self.cicadaAdapter)return;
    self.cicadaPosition=position;self.cicadaDuration=duration;[self refreshCicadaControls];
    // 进度采样 + 里程碑（移植自直连路径 updateCicadaPosition:）：供诊断确认
    // “确实在播”，并驱动断点续播持久化与跳过按钮。
    BOOL playing=self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying&&self.videoFrameReady;
    HostPlaybackProgressSample(&self->_progressEvidence,CACurrentMediaTime(),position,self.cicadaAdapter.rate,playing);
    NSUInteger milestone=self->_progressEvidence.observed>=30?30:(self->_progressEvidence.observed>=5?5:0);
    if(milestone>self.progressMilestone){self.progressMilestone=milestone;[RuntimeDiagnostics.shared recordEvent:@"playback_progress_confirmed" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"observed_playing_seconds":@(self->_progressEvidence.observed),@"progress_samples":@(self->_progressEvidence.samples),@"milestone_seconds":@(milestone)}];}
    if(position-self.lastPersistedPosition>=10.0)[self persistPlaybackProgress];
    if(self.videoFrameReady&&self->_progressEvidence.observed>=2)[self prefetchNextEpisodeIfNeeded];
    [self updateSkipButtonForCurrentPosition];
}
- (void)cicadaAdapter:(id)adapter didUpdateDownloadSpeed:(double)bitsPerSecond {
    if(adapter!=self.cicadaAdapter)return;
    self.cicadaAdapterDownloadBPS=MAX(0,bitsPerSecond);
    [self updateEstimatedThroughput];
}
- (void)cicadaAdapter:(id)adapter didUpdateVideoSize:(CGSize)size rotation:(NSInteger)rotation {
    if(adapter!=self.cicadaAdapter||size.width<=0||size.height<=0)return;
    // 与直连路径 onVideoSizeChanged: 同款换算：旋转 90/270 时宽高对调。
    CGFloat ratio=size.width/size.height;
    if(rotation==90||rotation==270)ratio=1.0/ratio;
    if(isfinite(ratio)&&ratio>0.1&&ratio<10){self.videoAspectRatio=ratio;[self updatePlaybackLayoutForSize:self.view.bounds.size];if(self.onVideoAspectRatioChanged)self.onVideoAspectRatioChanged(ratio);}
}
- (void)cicadaAdapter:(id)adapter didUpdateLoading:(BOOL)loading progress:(float)progress {
    if(adapter!=self.cicadaAdapter)return;
    [self refreshCicadaControls];
    BOOL began=loading&&!self.cicadaWasLoading;self.cicadaWasLoading=loading;
    if(began&&self.videoFrameReady){
        self.diagnosticStallCount++;
        double stalledAt=[self activeEngineCurrentPosition];if(!isfinite(stalledAt)||stalledAt<0)stalledAt=0;
        NSUInteger generation=self.playerGeneration;
        [RuntimeDiagnostics.shared recordEvent:@"playback_stalled" category:@"playback" fields:@{@"player":@"cicada",@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"media_stall_count":@(self.diagnosticStallCount),@"media_buffered_ahead_seconds":@(MAX(0,self.cicadaAdapter.bufferedPosition-stalledAt))}];
        __weak typeof(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            MediaPlaybackViewController *owner=weakSelf;
            if(!owner||generation!=owner.playerGeneration||owner.cicadaAdapter!=adapter||!owner.cicadaAdapter.loading||owner.cicadaAdapter.state!=MediaPlaybackCicadaAdapterStatePlaying||owner.resolving||owner.stallRecoveryAttempts>=1)return;
            double position=[owner activeEngineCurrentPosition];if(!isfinite(position)||fabs(position-stalledAt)>0.5)return;
            owner.stallRecoveryAttempts++;owner.pendingQualitySeekTime=@(stalledAt);owner.pendingQualityWasPlaying=YES;owner.pendingQualityRestorePlaybackState=YES;owner.pendingResolutionReason=@"stall_recovery";
            [RuntimeDiagnostics.shared recordEvent:@"playback_stall_recovery_started" category:@"playback" fields:@{@"player":@"cicada",@"playback_attempt_id":owner.playbackAttemptID?:@"",@"correlation_id":owner.diagnosticTraceID?:@"",@"attempt":@(owner.stallRecoveryAttempts),@"stalled_position_seconds":@(stalledAt)}];
            [owner resolveAndPlay];
        });
    }
    if(loading){self.status.text=@"正在缓冲 · 等待 CicadaPlayer";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];}
    else if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;[self.spinner stopAnimating];}
}
- (void)cicadaAdapterDidSeek:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    [self updateSkipButtonForCurrentPosition];
}
- (void)playerItemFailed:(NSNotification *)notification {if(!NSThread.isMainThread){NSNotification *note=notification;dispatch_async(dispatch_get_main_queue(),^{[self playerItemFailed:note];});return;}if(notification.object!=self.observedItem||notification.object!=self.player.currentItem)return;NSError *error=notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]?:self.observedItem.error;[self recordPlaybackFailureForItem:self.observedItem error:error stage:@"failed_to_play_to_end"]; }
- (void)retryCurrentEpisode {
    self.playbackSuspendedForVisibility=NO;
    [RuntimeDiagnostics.shared recordEvent:@"playback_retry_requested" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"retry_source":@"user_action",@"had_resolved_result":@(self.result!=nil),@"had_media_address":@([self.result[@"url"] isKindOfClass:NSString.class]&&[self.result[@"url"] length]>0)}];
    [self persistPlaybackProgress];self.stallRecoveryAttempts=0;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"manual_retry";[self resolveAndPlay];
}
- (void)selectLine:(UIButton *)sender {
    if(sender.tag<0||sender.tag>=self.lines.count||sender.tag==self.lineIndex)return;
    self.playbackSuspendedForVisibility=NO;
    NSInteger previousLine=self.lineIndex;NSArray *oldEpisodes=self.episodes;NSDictionary *oldEpisode=self.episodeIndex>=0&&self.episodeIndex<oldEpisodes.count?oldEpisodes[self.episodeIndex]:nil;NSString *oldID=[oldEpisode[@"id"] description]?:@"",*oldName=[[oldEpisode[@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";NSInteger oldIndex=self.episodeIndex;
    [self persistPlaybackProgress];self.lineIndex=sender.tag;NSArray *newEpisodes=self.episodes;NSInteger matched=-1;
    for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *candidate=newEpisodes[index];if(oldID.length&&[[candidate[@"id"] description] isEqual:oldID]){matched=index;break;}}
    if(matched<0&&oldName.length)for(NSUInteger index=0;index<newEpisodes.count;index++){NSString *name=[[newEpisodes[index][@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if([name localizedCaseInsensitiveCompare:oldName]==NSOrderedSame){matched=index;break;}}
    BOOL exactMatch=matched>=0;
    if(!exactMatch){self.episodeIndex=-1;self.result=nil;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=nil;self.pendingQualityRestorePlaybackState=NO;[self clearCurrentPlayerItem];[self resetAutomaticFallbackLines];[self buildLines];[self updateEpisodeTitle];[self.spinner stopAnimating];self.status.text=@"线路已切换 · 无法确认对应分集，请点选集重新选择";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:NO];return;}
    NSTimeInterval current=[self activeEngineCurrentPosition];BOOL wasPlaying=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;if(exactMatch&&isfinite(current)&&current>=0){self.pendingQualitySeekTime=@(MAX(0,current));self.pendingQualityWasPlaying=wasPlaying;self.pendingQualityRestorePlaybackState=YES;}else{self.pendingQualitySeekTime=nil;self.pendingQualityRestorePlaybackState=NO;}if(!exactMatch)matched=newEpisodes.count?MIN(oldIndex,(NSInteger)newEpisodes.count-1):0;self.episodeIndex=matched;[self resetAutomaticFallbackLines];
    [RuntimeDiagnostics.shared recordEvent:@"playback_line_selected" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"from_line_index":@(previousLine),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"line_count":@(self.lines.count),@"episode_count":@(newEpisodes.count),@"episode_matched":@(exactMatch),@"position_preserved":@(exactMatch&&self.pendingQualitySeekTime!=nil),@"was_playing":@(wasPlaying),@"selection_source":@"player_ui"}];
    self.stallRecoveryAttempts=0;self.pendingResolutionReason=@"line_switch";[self buildLines];[self updateEpisodeTitle];if(!exactMatch&&newEpisodes.count)self.status.text=@"线路已切换 · 未能按名称确认分集，已按集数位置选择";[self resolveAndPlay];
}
- (void)resetAutomaticFallbackLines {
    NSArray *episodes=self.episodes;
    BOOL selectedPrefetch=self.prefetchInFlight&&self.prefetchRequestedLineIndex==self.lineIndex&&self.prefetchRequestedEpisodeIndex==self.episodeIndex&&self.episodeIndex>=0&&self.episodeIndex<(NSInteger)episodes.count&&[self.prefetchRequestedIdentity isEqual:[self prefetchIdentityForEpisode:episodes[(NSUInteger)self.episodeIndex]]];
    if(!selectedPrefetch){self.prefetchGeneration++;[self.prefetchClient cancel];self.prefetchInFlight=NO;self.promotedPrefetchCompletion=nil;}
    self.automaticFallbackTriedLineIndexes=[NSMutableIndexSet indexSet];
    self.automaticFallbackTriedAlternateIndexes=[NSMutableIndexSet indexSet];
    if(self.lineIndex>=0&&self.lineIndex<self.lines.count)[self.automaticFallbackTriedLineIndexes addIndex:(NSUInteger)self.lineIndex];
}
- (BOOL)tryNextAlternateForAutomaticFallback:(NSString *)reason {
    NSArray *alternates=[self.result[@"alternates"] isKindOfClass:NSArray.class]?self.result[@"alternates"]:@[];
    if(alternates.count<2)return NO;
    if(!self.automaticFallbackTriedAlternateIndexes)self.automaticFallbackTriedAlternateIndexes=[NSMutableIndexSet indexSet];
    NSInteger currentAlt=self.selectedAlternateIndex>=0&&self.selectedAlternateIndex<(NSInteger)alternates.count?self.selectedAlternateIndex:0;
    [self.automaticFallbackTriedAlternateIndexes addIndex:(NSUInteger)currentAlt];
    NSUInteger limit=MIN(alternates.count,(NSUInteger)5);
    if(self.automaticFallbackTriedAlternateIndexes.count>=limit)return NO;
    NSURL *failedOrigURL=MediaPlaybackOriginalSourceURL(self.result);
    NSString *failedAltHost=failedOrigURL.host.lowercaseString?:@"";
    NSString *failedAltExt=failedOrigURL.pathExtension.lowercaseString?:@"";
    for(NSUInteger pass=0;pass<2;pass++){
      for(NSUInteger offset=1;offset<alternates.count;offset++){
        NSUInteger candidateIndex=((NSUInteger)currentAlt+offset)%alternates.count;
        if([self.automaticFallbackTriedAlternateIndexes containsIndex:candidateIndex])continue;
        if(pass==0&&failedAltHost.length){
            NSDictionary *peekAlt=[alternates[candidateIndex] isKindOfClass:NSDictionary.class]?alternates[candidateIndex]:nil;
            NSString *peekRaw=[peekAlt[@"originalURL"] isKindOfClass:NSString.class]?peekAlt[@"originalURL"]:([peekAlt[@"url"] isKindOfClass:NSString.class]?peekAlt[@"url"]:@"");
            NSURL *peekURL=[NSURL URLWithString:peekRaw];
            if([peekURL.host.lowercaseString isEqualToString:failedAltHost]&&[(peekURL.pathExtension.lowercaseString?:@"") isEqualToString:failedAltExt])continue;
        }
        NSDictionary *alternate=[alternates[candidateIndex] isKindOfClass:NSDictionary.class]?alternates[candidateIndex]:nil;
        NSString *url=[alternate[@"url"] isKindOfClass:NSString.class]?alternate[@"url"]:@"";
        if(!url.length){[self.automaticFallbackTriedAlternateIndexes addIndex:candidateIndex];continue;}
        [self.automaticFallbackTriedAlternateIndexes addIndex:candidateIndex];
        NSString *originalURL=[alternate[@"originalURL"] isKindOfClass:NSString.class]?alternate[@"originalURL"]:url;
        if(!self.basePlaybackHeaders){NSDictionary *base=[self.result[@"baseHeaders"] isKindOfClass:NSDictionary.class]?self.result[@"baseHeaders"]:MediaPlaybackHeadersFromResult(self.result);self.basePlaybackHeaders=base.copy;}
        NSDictionary *parentResult=self.result;self.selectedAlternateIndex=(NSInteger)candidateIndex;
        NSMutableDictionary *selected=[parentResult mutableCopy];selected[@"url"]=url;selected[@"originalURL"]=originalURL;
        NSMutableDictionary *headers=[self.basePlaybackHeaders mutableCopy]?:[NSMutableDictionary dictionary];
        [headers addEntriesFromDictionary:MediaPlaybackHeadersFromResult(alternate)];
        selected[@"headers"]=headers.copy;[selected removeObjectForKey:@"header"];
        for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime",@"playbackEngine",@"nativePlayable",@"directMedia",@"requiresWebPlayback",@"parse",@"jx",@"dashRemuxed"]){[selected removeObjectForKey:key];if(alternate[key]!=nil)selected[key]=alternate[key];}
        NSString *candidateName=[alternate[@"name"] isKindOfClass:NSString.class]&&[alternate[@"name"] length]?alternate[@"name"]:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)candidateIndex+1];
        [RuntimeDiagnostics.shared recordEvent:@"playback_auto_alternate_fallback" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"from_alternate_index":@(currentAlt),@"alternate_index":@(candidateIndex),@"alternate_count":@(alternates.count),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"reason":reason?:@"automatic_compatibility"}];
        self.status.text=[NSString stringWithFormat:@"当前档位未就绪 · 正在尝试切换至 %@",candidateName];
        self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];
        if(!self.pendingQualitySeekTime&&self.pendingPlaybackSeekTime)self.pendingQualitySeekTime=self.pendingPlaybackSeekTime;
        self.attemptedRoutes=0;[self playResult:selected];
        return YES;
      }
    }
    return NO;
}
- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason {
    if([self tryNextAlternateForAutomaticFallback:reason])return YES;
    NSArray *lines=self.lines;NSUInteger lineCount=lines.count;
    if(lineCount<2||self.lineIndex<0||self.lineIndex>=lines.count)return NO;
    if(!self.automaticFallbackTriedLineIndexes)[self resetAutomaticFallbackLines];
    NSUInteger limit=MIN(lineCount,CCTVAutomaticRouteFallbackLimit);
    if(self.automaticFallbackTriedLineIndexes.count>=limit)return NO;
    NSInteger previousLine=self.lineIndex,previousEpisode=self.episodeIndex;
    NSArray *previousEpisodes=self.episodes;
    NSDictionary *currentEpisode=previousEpisode>=0&&previousEpisode<previousEpisodes.count?previousEpisodes[previousEpisode]:nil;
    NSString *episodeID=[currentEpisode[@"id"] description]?:@"";
    NSString *episodeName=[[currentEpisode[@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
    for(NSUInteger offset=1;offset<lineCount;offset++){
        NSUInteger candidateLine=((NSUInteger)previousLine+offset)%lineCount;
        if([self.automaticFallbackTriedLineIndexes containsIndex:candidateLine])continue;
        NSArray *candidateEpisodes=[lines[candidateLine][@"episodes"] isKindOfClass:NSArray.class]?lines[candidateLine][@"episodes"]:@[];
        if(!candidateEpisodes.count){[self.automaticFallbackTriedLineIndexes addIndex:candidateLine];continue;}
        NSInteger candidateEpisode=-1;
        if(episodeID.length)for(NSUInteger index=0;index<candidateEpisodes.count;index++)if([[candidateEpisodes[index][@"id"] description] isEqual:episodeID]){candidateEpisode=(NSInteger)index;break;}
        if(candidateEpisode<0&&episodeName.length)for(NSUInteger index=0;index<candidateEpisodes.count;index++){
            NSString *candidateName=[[candidateEpisodes[index][@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if([candidateName localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame){candidateEpisode=(NSInteger)index;break;}
        }
        BOOL episodeMatched=candidateEpisode>=0;

        if(candidateEpisode<0){[self.automaticFallbackTriedLineIndexes addIndex:candidateLine];continue;}
        [self.automaticFallbackTriedLineIndexes addIndex:(NSUInteger)previousLine];
        [self.automaticFallbackTriedLineIndexes addIndex:candidateLine];
        self.lineIndex=(NSInteger)candidateLine;self.episodeIndex=candidateEpisode;self.selectedAlternateIndex=-1;
        self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=nil;self.pendingQualityRestorePlaybackState=NO;self.stallRecoveryAttempts=0;
        self.pendingResolutionReason=reason.length?reason:@"automatic_compatibility";
        [RuntimeDiagnostics.shared recordEvent:@"playback_auto_line_fallback" category:@"playback" fields:@{
            @"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",
            @"from_line_index":@(previousLine),@"line_index":@(candidateLine),@"line_count":@(lineCount),
            @"from_episode_index":@(previousEpisode),@"episode_index":@(candidateEpisode),
            @"episode_matched":@(episodeMatched),@"reason":self.pendingResolutionReason,
            @"attempted_line_count":@(self.automaticFallbackTriedLineIndexes.count)}];
        [self buildLines];[self updateEpisodeTitle];
        self.status.text=[NSString stringWithFormat:@"当前线路未显示画面 · 正在尝试线路 %lu/%lu",(unsigned long)candidateLine+1,(unsigned long)lineCount];
        self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];
        [self resolveAndPlay];return YES;
    }
    return NO;
}
- (void)resolveAndPlay {
    self.attemptedRoutes=0;
    NSArray *lines=self.lines,*episodes=self.episodes;
    if(self.lineIndex<0||self.lineIndex>=lines.count||self.episodeIndex<0||self.episodeIndex>=episodes.count){
        self.status.text=@"没有可选分集 · 请返回详情页重新加载或更换来源";self.status.accessibilityLabel=self.status.text;
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_unavailable" category:@"media_api" fields:@{
            @"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.context[@"source"][@"id"]?:@"",
            @"provider_id":self.context[@"provider"]?:@"",@"line_index":@(self.lineIndex),
            @"episode_index":@(self.episodeIndex),@"line_count":@(lines.count),@"episode_count":@(episodes.count),
            @"reason":@"selected_index_out_of_range"}];
        return;
    }
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||self.isAutoAdvancingEpisode){[self activateBackgroundAudioSessionIfNeeded];[self beginBackgroundAutoAdvanceTaskIfNeeded];}
    NSDictionary *line=lines[self.lineIndex],*episode=episodes[self.episodeIndex];
    self.resolving=YES;self.episodeWebFallbackAvailable=NO;
    NSUInteger generation=++self.generation;
    NSString *reason=self.pendingResolutionReason.length?self.pendingResolutionReason:@"playback_start";
    self.pendingResolutionReason=nil;
    [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.context[@"source"][@"id"]?:@"",
        @"provider_id":self.context[@"provider"]?:@"",@"line_index":@(self.lineIndex),
        @"episode_index":@(self.episodeIndex),@"request_generation":@(generation),
        @"line_count":@(lines.count),@"episode_count":@(episodes.count),
        @"episode_has_id":@([[episode[@"id"] description] length]>0),
        @"line_has_id":@([[line[@"id"] description] length]>0),@"resolve_reason":reason}];
    if(![reason isEqualToString:@"native_session_refresh"]){self.nativeSessionRefreshInFlight=NO;self.nativeSessionRefreshAttempted=NO;self.nativeSessionRefreshURL=nil;}
    BOOL freshResolution=[reason isEqualToString:@"manual_retry"]||[reason isEqualToString:@"stall_recovery"]||[reason isEqualToString:@"native_session_refresh"];
    BOOL promotePrefetch=!freshResolution&&self.prefetchInFlight&&self.prefetchRequestedLineIndex==self.lineIndex&&self.prefetchRequestedEpisodeIndex==self.episodeIndex&&[self.prefetchRequestedIdentity isEqual:[self prefetchIdentityForEpisode:episode]];
    if(freshResolution){[self.prefetchedAsset cancelLoading];self.prefetchedAsset=nil;self.prefetchedAssetHeaders=nil;self.prefetchedAssetIdentity=nil;}
    self.result=nil;self.basePlaybackHeaders=nil;self.selectedAlternateIndex=-1;self.automaticFallbackTriedAlternateIndexes=[NSMutableIndexSet indexSet];
    [self buildQualityButtons];[self setRetryAvailable:NO];[self clearCurrentPlayerItemPreservingPrefetch:promotePrefetch];
    [self.spinner startAnimating];self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];
    self.status.accessibilityLabel=self.status.text;
    if(self.prefetchedEpisodeResult&&self.prefetchedLineIndex==self.lineIndex&&self.prefetchedEpisodeIndex==self.episodeIndex&&[self.prefetchedEpisodeIdentity isEqual:[self prefetchIdentityForEpisode:self.episodes[(NSUInteger)self.episodeIndex]]]&&MediaPlaybackCachedResultIsFresh(self.prefetchedEpisodeResult,self.prefetchedAt)&&![reason isEqualToString:@"manual_retry"]&&![reason isEqualToString:@"stall_recovery"]&&![reason isEqualToString:@"native_session_refresh"]){
        NSDictionary *cachedResult=self.prefetchedEpisodeResult;
        self.prefetchedEpisodeResult=nil;self.prefetchedLineIndex=-1;self.prefetchedEpisodeIndex=-1;
        self.resolving=NO;[self.spinner stopAnimating];
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{
            @"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.context[@"source"][@"id"]?:@"",
            @"provider_id":self.context[@"provider"]?:@"",@"line_index":@(self.lineIndex),
            @"episode_index":@(self.episodeIndex),@"request_generation":@(generation),
            @"result_has_media_url":@([cachedResult[@"url"] isKindOfClass:NSString.class]&&[cachedResult[@"url"] length]>0),
            @"result_parse_mode":@([cachedResult[@"parse"] respondsToSelector:@selector(integerValue)]?[cachedResult[@"parse"] integerValue]:0),
            @"result_alternate_count":@([cachedResult[@"alternates"] isKindOfClass:NSArray.class]?[cachedResult[@"alternates"] count]:0)}];
        self.status.text=@"";[self playResult:cachedResult];
        return;
    }
    NSString *vodTitle=[self.context[@"detail"][@"name"] isKindOfClass:NSString.class]&&[self.context[@"detail"][@"name"] length]?self.context[@"detail"][@"name"]:([self.context[@"item"][@"name"] isKindOfClass:NSString.class]?self.context[@"item"][@"name"]:@"");NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@"",@"parserID":MediaPlaybackSelectedParserID(self.context),@"vodName":vodTitle,@"episodeName":[episode[@"name"] description]?:@"",@"episodeIndex":@(self.episodeIndex),@"detailId":self.context[@"detail"][@"id"]?:self.context[@"item"][@"id"]?:@""} mutableCopy];
    NSString *provider=self.context[@"provider"];if(provider.length)args[@"provider"]=provider;
    __weak typeof(self) weakSelf=self;
    [self.client cancel];
    CFTimeInterval resolutionStartedAt=CACurrentMediaTime();
    void (^completion)(id,NSError *)=^(id result,NSError *error){
        MediaPlaybackViewController *owner=weakSelf;if(!owner)return;
        if(generation!=owner.generation){
            [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_response_discarded" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
                @"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":@"superseded_selection"}];
            return;
        }
        owner.resolving=NO;owner.nativeSessionRefreshInFlight=NO;[owner.spinner stopAnimating];
        if(error||![result isKindOfClass:NSDictionary.class]){
            NSMutableDictionary *fields=[@{
                @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
                @"provider_id":owner.context[@"provider"]?:@"",@"line_index":@(owner.lineIndex),
                @"episode_index":@(owner.episodeIndex),@"request_generation":@(generation),
                @"error_domain":error.domain?:@"",@"error_code":@(error.code),
                @"error_message":error.localizedDescription?:@"",@"result_received":@([result isKindOfClass:NSDictionary.class])} mutableCopy];
            if([error.userInfo[@"service_request_id"] isKindOfClass:NSString.class])fields[@"service_request_id"]=error.userInfo[@"service_request_id"];
            if([error.userInfo[@"service_failure_stage"] isKindOfClass:NSString.class])fields[@"service_failure_stage"]=error.userInfo[@"service_failure_stage"];
            NSArray *currentEpisodes=owner.episodes;
            NSDictionary *currentEpisode=owner.episodeIndex>=0&&owner.episodeIndex<currentEpisodes.count?currentEpisodes[owner.episodeIndex]:nil;
            NSString *pluginCode=[error.userInfo[@"plugin_error_code"] isKindOfClass:NSString.class]?error.userInfo[@"plugin_error_code"]:@"";
            BOOL noMediaFailure=[pluginCode isEqualToString:@"NO_MEDIA"]||[error.userInfo[@"service_failure_stage"] isEqual:@"no_media"];
            NSURL *pageURL=noMediaFailure?MediaPlaybackEpisodePageFallbackURL(currentEpisode):nil;
            owner.episodeWebFallbackAvailable=pageURL!=nil;
            if(pageURL){
                [RuntimeDiagnostics.shared recordEvent:@"episode_web_fallback_available" category:@"playback" fields:@{
                    @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
                    @"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex),
                    @"failure_code":@"NO_MEDIA",@"fallback_kind":@"episode_page",@"source_host":pageURL.host.lowercaseString?:@""}];
            }
            [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:fields];
            if(owner.episodeWebFallbackAvailable&&pageURL){
                NSMutableDictionary *sniffCandidate=[@{@"url":pageURL.absoluteString,@"originalURL":pageURL.absoluteString,@"parse":@1,@"requiresWebPlayback":@YES} mutableCopy];
                [owner playResult:sniffCandidate];
                return;
            }
            [owner endBackgroundAutoAdvanceTaskIfNeeded];
            owner.status.text=owner.episodeWebFallbackAvailable?@"来源未解析出媒体地址 · 可重试或切换解析器":(error.localizedDescription?:@"来源没有返回可播放结果");
            owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];
            return;
        }
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{
            @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
            @"provider_id":owner.context[@"provider"]?:@"",@"line_index":@(owner.lineIndex),
            @"episode_index":@(owner.episodeIndex),@"request_generation":@(generation),
            @"resolve_elapsed_ms":@((NSInteger)((CACurrentMediaTime()-resolutionStartedAt)*1000)),@"prefetch_promoted":@(promotePrefetch),
            @"result_has_media_url":@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0),
            @"result_parse_mode":@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0),
            @"result_alternate_count":@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0)}];
        owner.status.text=@"";[owner playResult:result];
    };
    if(promotePrefetch){
        self.promotedPrefetchCompletion=completion;
        [RuntimeDiagnostics.shared recordEvent:@"episode_prefetch_promoted" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"request_generation":@(generation),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex)}];
        return;
    }
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:completion];
}
- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    HostStyleGlassCard(self.controlPanel,18);
    self.qualityLabel.textColor=HostSecondaryText();
    self.episodeTitle.textColor=HostText();
    self.status.textColor=HostSecondaryText();
    HostStylePillButton(self.episodeButton,YES);MediaPlaybackApplyScaledPillFont(self.episodeButton);
    if(self.nextEpisodeButton){HostStylePillButton(self.nextEpisodeButton,NO);MediaPlaybackApplyScaledPillFont(self.nextEpisodeButton);}
    HostStylePillButton(self.playbackSpeedButton,NO);MediaPlaybackApplyScaledPillFont(self.playbackSpeedButton);
    HostStylePillButton(self.skipButton,YES);MediaPlaybackApplyScaledPillFont(self.skipButton);
    HostStylePillButton(self.inlineRetryButton,YES);MediaPlaybackApplyScaledPillFont(self.inlineRetryButton);
    HostStylePillButton(self.inlineParserButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineParserButton);
    HostStylePillButton(self.inlineOptionsButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineOptionsButton);
    [self buildLines];
    [self buildQualityButtons];
}
- (NSString *)prefetchIdentityForEpisode:(NSDictionary *)episode {
    NSArray *parts=@[self.context[@"source"][@"id"]?:@"",[ServiceStore playbackParserCatalogIDForSource:self.context[@"source"]?:@{}]?:@"",self.context[@"detail"][@"id"]?:self.context[@"item"][@"id"]?:@"",self.context[@"provider"]?:@"",MediaPlaybackSelectedParserID(self.context),@(self.lineIndex),[episode[@"id"] description]?:@""];
    NSData *json=[NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL];return json?[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]:@"";
}
- (AVURLAsset *)consumePrefetchedAssetForURL:(NSURL *)url headers:(NSDictionary *)headers {
    NSArray *episodes=self.episodes;
    NSString *identity=self.episodeIndex>=0&&self.episodeIndex<(NSInteger)episodes.count?[self prefetchIdentityForEpisode:episodes[(NSUInteger)self.episodeIndex]]:@"";
    BOOL fresh=self.prefetchedAssetAt>0&&CACurrentMediaTime()-self.prefetchedAssetAt<60.0&&(self.prefetchedAssetExpiresAt<=0||self.prefetchedAssetExpiresAt>NSDate.date.timeIntervalSince1970+15.0);
    BOOL matches=fresh&&[self.prefetchedAssetIdentity isEqual:identity]&&[self.prefetchedAsset.URL isEqual:url]&&[self.prefetchedAssetHeaders isEqual:headers];
    AVURLAsset *asset=matches?self.prefetchedAsset:nil;
    if(!matches)[self.prefetchedAsset cancelLoading];
    self.prefetchedAsset=nil;self.prefetchedAssetHeaders=nil;self.prefetchedAssetIdentity=nil;self.prefetchedAssetAt=0;self.prefetchedAssetExpiresAt=0;
    return asset;
}
- (AVURLAsset *)assetForPlaybackURL:(NSURL *)url headers:(NSDictionary *)headers {
    return [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey":headers?:@{},@"AVURLAssetPreferPreciseDurationAndTimingKey":@NO}];
}
- (void)prepareAssetForPrefetchedResult:(NSDictionary *)result identity:(NSString *)identity {
    [self.prefetchedAsset cancelLoading];self.prefetchedAsset=nil;self.prefetchedAssetHeaders=nil;self.prefetchedAssetIdentity=nil;self.prefetchedAssetAt=0;self.prefetchedAssetExpiresAt=0;
    if([self playbackBufferConstrained])return;
    NSURL *url=[NSURL URLWithString:[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@""];
    if(!url||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length||url.user.length||url.password.length)return;
    // Custom key loading depends on the active result; do not bind the next
    // episode to the current episode's key delegate while it is still playing.
    if([result[@"drmKey"] isKindOfClass:NSString.class]&&[result[@"drmKey"] length])return;
    if(!MediaPlaybackResultSupportsAVPlayer(result)||MediaPlaybackDecodeRouteNextForResult(result,0)!=MediaPlaybackDecodeRouteAVPlayer)return;
    NSDictionary *headers=MediaPlaybackAVAssetHeaders(result,url);
    self.prefetchedAsset=[self assetForPlaybackURL:url headers:headers];
    self.prefetchedAssetHeaders=headers;self.prefetchedAssetIdentity=identity;self.prefetchedAssetAt=CACurrentMediaTime();self.prefetchedAssetExpiresAt=[result[@"expiresAt"] doubleValue];
    // Metadata only: keep one reusable asset, never issue blind Range fetches
    // or download whole media. Local HLS relay URLs use the same path as playback.
    [self.prefetchedAsset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{}];
}
- (void)prefetchNextEpisodeIfNeeded {
    if(self.resolving||self.prefetchInFlight||!self.videoFrameReady||self.pendingPlaybackSeekTime||self.resumePromptPending)return;
    double buffered=self.cicadaAdapter?MAX(0,self.cicadaAdapter.bufferedPosition-self.cicadaAdapter.currentPosition):[self bufferedAheadForItem:self.observedItem];
    BOOL waiting=self.cicadaAdapter?(self.cicadaAdapter.loading||self.cicadaAdapter.state!=MediaPlaybackCicadaAdapterStatePlaying):self.player.timeControlStatus!=AVPlayerTimeControlStatusPlaying;
    if(!MediaPlaybackShouldPrefetch([self activeEngineCurrentPosition],[self activeEngineDuration],buffered,waiting,[self playbackBufferConstrained]))return;
    if(self.prefetchLastAttemptAt>0&&CACurrentMediaTime()-self.prefetchLastAttemptAt<30)return;
    NSArray *lines=self.lines,*episodes=self.episodes;
    NSInteger nextEpIndex=self.episodeIndex+1;
    if(self.lineIndex<0||self.lineIndex>=(NSInteger)lines.count||nextEpIndex<0||nextEpIndex>=(NSInteger)episodes.count)return;
    if(self.prefetchedEpisodeResult&&self.prefetchedLineIndex==self.lineIndex&&self.prefetchedEpisodeIndex==nextEpIndex&&[self.prefetchedEpisodeIdentity isEqual:[self prefetchIdentityForEpisode:episodes[(NSUInteger)nextEpIndex]]]&&MediaPlaybackCachedResultIsFresh(self.prefetchedEpisodeResult,self.prefetchedAt))return;
    NSDictionary *source=[self.context[@"source"] isKindOfClass:NSDictionary.class]?self.context[@"source"]:nil;
    if(!source.count)return;
    NSDictionary *line=lines[(NSUInteger)self.lineIndex],*episode=episodes[(NSUInteger)nextEpIndex];
    NSString *epID=[episode[@"id"] description]?:@"";
    if(!epID.length)return;
    if(!self.prefetchClient)self.prefetchClient=MediaPlaybackClientForSource(source);
    if(!self.prefetchClient)return;
    self.prefetchInFlight=YES;self.prefetchLastAttemptAt=CACurrentMediaTime();
    NSInteger targetLine=self.lineIndex;NSUInteger prefetchGeneration=++self.prefetchGeneration;
    NSString *targetIdentity=[self prefetchIdentityForEpisode:episode];
    self.prefetchRequestedIdentity=targetIdentity;self.prefetchRequestedLineIndex=targetLine;self.prefetchRequestedEpisodeIndex=nextEpIndex;
    NSString *vodTitle=[self.context[@"detail"][@"name"] isKindOfClass:NSString.class]&&[self.context[@"detail"][@"name"] length]?self.context[@"detail"][@"name"]:([self.context[@"item"][@"name"] isKindOfClass:NSString.class]?self.context[@"item"][@"name"]:@"");
    NSMutableDictionary *args=[@{@"id":epID,@"lineId":line[@"id"]?:@"",@"parserID":MediaPlaybackSelectedParserID(self.context),@"vodName":vodTitle,@"episodeName":[episode[@"name"] description]?:@"",@"episodeIndex":@(nextEpIndex),@"detailId":self.context[@"detail"][@"id"]?:self.context[@"item"][@"id"]?:@""} mutableCopy];
    NSString *provider=self.context[@"provider"];if([provider isKindOfClass:NSString.class]&&provider.length)args[@"provider"]=provider;
    __weak typeof(self) weakSelf=self;
    [self.prefetchClient call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaPlaybackViewController *owner=weakSelf;if(!owner||prefetchGeneration!=owner.prefetchGeneration)return;
        owner.prefetchInFlight=NO;
        void (^promotedCompletion)(id,NSError *)=owner.promotedPrefetchCompletion;
        owner.promotedPrefetchCompletion=nil;
        if(!error&&[result isKindOfClass:NSDictionary.class]&&[result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0){
            owner.prefetchedEpisodeResult=[result copy];
            owner.prefetchedLineIndex=targetLine;
            owner.prefetchedEpisodeIndex=nextEpIndex;
            owner.prefetchedAt=CACurrentMediaTime();owner.prefetchedEpisodeIdentity=targetIdentity;
            [owner prepareAssetForPrefetchedResult:result identity:targetIdentity];
        }
        if(promotedCompletion)promotedCompletion(result,error);
    }];
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *reqURL = loadingRequest.request.URL;
    NSString *scheme = reqURL.scheme.lowercaseString ?: @"";
    NSString *drmKey = [self.result[@"drmKey"] isKindOfClass:NSString.class] ? self.result[@"drmKey"] : @"";
    if ([scheme isEqualToString:@"hex"] || [scheme isEqualToString:@"base64"] || [scheme isEqualToString:@"cenc"] || (drmKey.length && [scheme isEqualToString:@"skd"])) {
        NSString *payload = reqURL.resourceSpecifier ?: @"";
        if ([payload hasPrefix:@"//"]) payload = [payload substringFromIndex:2];
        NSData *keyData = MediaPlaybackNormalizedAES128KeyData(nil, payload.length ? payload : drmKey);
        if (keyData.length == 16) {
            loadingRequest.contentInformationRequest.contentType = @"application/octet-stream";
            loadingRequest.contentInformationRequest.contentLength = 16;
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
            [loadingRequest.dataRequest respondWithData:keyData];
            [loadingRequest finishLoading];
            return YES;
        }
    }
    if ([scheme isEqualToString:@"key"] || [scheme isEqualToString:@"keys"] || [scheme isEqualToString:@"skd"]) {
        NSString *targetScheme = [scheme isEqualToString:@"key"] ? @"http" : @"https";
        NSURLComponents *parts = [NSURLComponents componentsWithURL:reqURL resolvingAgainstBaseURL:NO];
        parts.scheme = targetScheme;
        NSURL *httpURL = parts.URL;
        if (!httpURL) return NO;
        static NSCache<NSString *, NSData *> *loaderKeyCache;
        static dispatch_once_t keyCacheOnce;
        dispatch_once(&keyCacheOnce, ^{ loaderKeyCache = [NSCache new]; loaderKeyCache.countLimit = 128; });
        NSData *cachedNormKey = [loaderKeyCache objectForKey:httpURL.absoluteString];
        if (cachedNormKey.length == 16) {
            loadingRequest.contentInformationRequest.contentType = @"application/octet-stream";
            loadingRequest.contentInformationRequest.contentLength = 16;
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
            [loadingRequest.dataRequest respondWithData:cachedNormKey];
            [loadingRequest finishLoading];
            return YES;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:httpURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
        NSDictionary *headers = self.basePlaybackHeaders ?: MediaPlaybackHeadersFromResult(self.result);
        for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || !data.length) {
                    NSData *fallbackKey = drmKey.length ? MediaPlaybackNormalizedAES128KeyData(nil, drmKey) : nil;
                    if (fallbackKey.length == 16) {
                        loadingRequest.contentInformationRequest.contentType = @"application/octet-stream";
                        loadingRequest.contentInformationRequest.contentLength = 16;
                        [loadingRequest.dataRequest respondWithData:fallbackKey];
                        [loadingRequest finishLoading];
                    } else {
                        [loadingRequest finishLoadingWithError:err];
                    }
                    return;
                }
                NSData *normKey = MediaPlaybackNormalizedAES128KeyData(data, drmKey);
                if (normKey.length == 16) [loaderKeyCache setObject:normKey forKey:httpURL.absoluteString];
                loadingRequest.contentInformationRequest.contentType = @"application/octet-stream";
                loadingRequest.contentInformationRequest.contentLength = normKey.length;
                loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
                [loadingRequest.dataRequest respondWithData:normKey];
                [loadingRequest finishLoading];
            });
        }] resume];
        return YES;
    }
    return NO;
}
@end
