#import "MediaPlaybackViewController.h"
#import "HostPlaybackProgress.h"
#import "MediaAPIClient.h"
#import "MediaWebViewController.h"
#import "MediaEpisodeSelectionViewController.h"
#import "MediaPlaybackHeaders.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackCicadaAdapter.h"
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

static void *CCTVPlayerItemStatusContext = &CCTVPlayerItemStatusContext;
static void *CCTVPlayerTimeControlContext = &CCTVPlayerTimeControlContext;
static void *CCTVPlayerLayerReadyContext = &CCTVPlayerLayerReadyContext;
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
    NSString *catalogID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");MediaAPIClient *client=MediaSourceUsesNativeCatalogAPI(source)?[[MediaAPIClient alloc] initWithTVBoxSource:source?:@{}]:[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue] catalogID:catalogID];
    client.playTimeoutMilliseconds=timeout;
    return client;
}
static NSString *MediaPlaybackSelectedParserID(NSDictionary *context) {
    NSDictionary *source=[context[@"source"] isKindOfClass:NSDictionary.class]?context[@"source"]:@{};NSString *sourceID=[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:([source[@"api"] isKindOfClass:NSString.class]?source[@"api"]:@"default");
    NSString *catalogID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!catalogID.length)return @"";
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
                                    @"(?i)(?:episode|ep)\\s*0*(\\d{1,4})"];
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

@interface MediaPlaybackViewController () <UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate, MediaPlaybackCicadaAdapterDelegate>
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerViewController *playerController;
@property(nonatomic,strong) UIView *videoView;
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
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UIButton *episodeButton;
@property(nonatomic,strong) UIButton *playbackSpeedButton;
@property(nonatomic,strong) UIStackView *playbackActionRow;
@property(nonatomic,strong) UIButton *skipButton;
@property(nonatomic,strong) UIButton *inlineRetryButton;
@property(nonatomic,strong) UIButton *inlineWebButton;
@property(nonatomic,strong) UIButton *inlineOptionsButton;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong,nullable) MediaPlaybackCicadaAdapter *cicadaAdapter;
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
@property(nonatomic) CFTimeInterval playbackStartedAt;
@property(nonatomic) NSUInteger playerGeneration;
@property(nonatomic) BOOL terminalPlaybackOutcomeRecorded;
@property(nonatomic) BOOL pendingScreenExit;
@property(nonatomic) BOOL hasVideoTrack;
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
@property(nonatomic) BOOL awaitingWebPlaybackReturn;
@property(nonatomic) BOOL episodeWebFallbackAvailable;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,copy) NSString *pendingResolutionReason;
@property(nonatomic,strong) UIBarButtonItem *playbackOptionsItem;
@property(nonatomic,strong) UIBarButtonItem *retryItem;
@property(nonatomic,strong) UIBarButtonItem *webFallbackItem;
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
- (void)stopObservingCurrentPlayback;
- (void)observePlayerLayerIfAvailable;
- (void)inspectVideoTracksForItem:(AVPlayerItem *)item generation:(NSUInteger)generation;
- (AVPlayerLayer *)playerLayerInLayerTree:(CALayer *)root;
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item;
- (void)buildQualityButtons;
- (void)updateEstimatedThroughput;
- (UIMenu *)mediaSelectionMenuForCharacteristic:(AVMediaCharacteristic)characteristic title:(NSString *)title;
- (void)selectAlternate:(UIButton *)sender;
- (void)setRetryAvailable:(BOOL)available;
- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage;
- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration;
- (void)teardownCicadaAdapter;
- (void)advanceFromCicadaFailureWithError:(NSError *)error;
- (void)handleCicadaFirstFrameTimeoutForAdapter:(id)adapter;
- (void)offerResumeForCicada;
- (void)applyPendingPlaybackSeekForCicada;
- (void)markCicadaFirstFrameReady;
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
- (instancetype)init {if((self=[super init])){_lineIndex=0;_episodeIndex=0;_selectedAlternateIndex=-1;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.autoSkippedIntroEpisodeIndex=-1;self.autoSkippedOutroEpisodeIndex=-1;
    self.diagnosticTraceID=[self.context[@"correlationID"] isKindOfClass:NSString.class]&&[self.context[@"correlationID"] length]?self.context[@"correlationID"]:NSUUID.UUID.UUIDString.lowercaseString;
    self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];
    if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;
    if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;
    [self resetAutomaticFallbackLines];
    self.title=self.context[@"detail"][@"name"]?:self.context[@"item"][@"name"]?:@"影视播放";
    NSDictionary *source=self.context[@"source"]?:@{};self.client=MediaPlaybackClientForSource(source);
    [self configurePlaybackOptions];

    self.videoView=[UIView new];self.videoView.translatesAutoresizingMaskIntoConstraints=NO;self.videoView.backgroundColor=UIColor.blackColor;self.videoView.layer.cornerRadius=10;self.videoView.clipsToBounds=YES;[self.view addSubview:self.videoView];
    self.playerController=[AVPlayerViewController new];self.playerController.delegate=self;self.playerController.allowsPictureInPicturePlayback=YES;[self addChildViewController:self.playerController];self.playerController.view.translatesAutoresizingMaskIntoConstraints=NO;[self.videoView addSubview:self.playerController.view];[self.playerController didMoveToParentViewController:self];
    [NSLayoutConstraint activateConstraints:@[[self.playerController.view.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[self.playerController.view.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[self.playerController.view.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[self.playerController.view.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];
    self.videoTopScrim=[CAGradientLayer layer];self.videoTopScrim.colors=@[(id)[UIColor colorWithWhite:0 alpha:0.82].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.62].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.0].CGColor];self.videoTopScrim.locations=@[@0.0,@0.66,@1.0];self.videoTopScrim.startPoint=CGPointMake(0.5,0);self.videoTopScrim.endPoint=CGPointMake(0.5,1);self.videoTopScrim.name=@"media-playback-top-scrim";[self.videoView.layer addSublayer:self.videoTopScrim];
    self.throughputLabel=[UILabel new];self.throughputLabel.translatesAutoresizingMaskIntoConstraints=NO;self.throughputLabel.text=@"测速中";self.throughputLabel.textColor=UIColor.whiteColor;self.throughputLabel.font=HostMonospacedDigitFont(11,UIFontWeightSemibold,UIFontTextStyleCaption2);self.throughputLabel.textAlignment=NSTextAlignmentCenter;self.throughputLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.68];self.throughputLabel.layer.cornerRadius=11;self.throughputLabel.layer.borderWidth=0.5;self.throughputLabel.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;self.throughputLabel.clipsToBounds=YES;self.throughputLabel.userInteractionEnabled=NO;self.throughputLabel.accessibilityIdentifier=@"media-playback-throughput";self.throughputLabel.hidden=self.embeddedMode;[self.videoView addSubview:self.throughputLabel];self.throughputPortraitTopConstraint=[self.throughputLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor constant:8];self.throughputViewportTopConstraint=[self.throughputLabel.topAnchor constraintEqualToAnchor:self.videoView.topAnchor constant:10];self.throughputViewportTopConstraint.active=NO;[NSLayoutConstraint activateConstraints:@[self.throughputPortraitTopConstraint,[self.throughputLabel.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor constant:-10],[self.throughputLabel.heightAnchor constraintGreaterThanOrEqualToConstant:24],[self.throughputLabel.widthAnchor constraintGreaterThanOrEqualToConstant:68]]];
    self.gestureFeedbackLabel=[UILabel new];self.gestureFeedbackLabel.translatesAutoresizingMaskIntoConstraints=NO;self.gestureFeedbackLabel.hidden=YES;self.gestureFeedbackLabel.textAlignment=NSTextAlignmentCenter;self.gestureFeedbackLabel.textColor=UIColor.whiteColor;self.gestureFeedbackLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];self.gestureFeedbackLabel.adjustsFontForContentSizeCategory=YES;self.gestureFeedbackLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.72];self.gestureFeedbackLabel.layer.cornerRadius=14;self.gestureFeedbackLabel.clipsToBounds=YES;self.gestureFeedbackLabel.isAccessibilityElement=NO;UIView *gestureSurface=self.videoView;[gestureSurface addSubview:self.gestureFeedbackLabel];self.gestureFeedbackPortraitTopConstraint=[self.gestureFeedbackLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor constant:8];self.gestureFeedbackViewportTopConstraint=[self.gestureFeedbackLabel.topAnchor constraintEqualToAnchor:gestureSurface.topAnchor constant:16];self.gestureFeedbackViewportTopConstraint.active=NO;[NSLayoutConstraint activateConstraints:@[[self.gestureFeedbackLabel.centerXAnchor constraintEqualToAnchor:gestureSurface.centerXAnchor],self.gestureFeedbackPortraitTopConstraint,[self.gestureFeedbackLabel.heightAnchor constraintEqualToConstant:34],[self.gestureFeedbackLabel.widthAnchor constraintGreaterThanOrEqualToConstant:112]]];
    self.inlineNowPlayingPill=[UIView new];self.inlineNowPlayingPill.translatesAutoresizingMaskIntoConstraints=NO;self.inlineNowPlayingPill.hidden=YES;self.inlineNowPlayingPill.userInteractionEnabled=NO;self.inlineNowPlayingPill.backgroundColor=[UIColor colorWithWhite:0 alpha:.72];self.inlineNowPlayingPill.layer.cornerRadius=9;self.inlineNowPlayingPill.layer.cornerCurve=kCACornerCurveContinuous;self.inlineNowPlayingPill.isAccessibilityElement=YES;self.inlineNowPlayingPill.accessibilityIdentifier=@"media-inline-now-playing";self.inlineNowPlayingPill.accessibilityHint=@"滚动影片详情时仍显示当前播放集数";[self.videoView addSubview:self.inlineNowPlayingPill];
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
    self.playbackSpeedButton=[UIButton buttonWithType:UIButtonTypeSystem];self.playbackSpeedButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.playbackSpeedButton,NO);MediaPlaybackApplyScaledPillFont(self.playbackSpeedButton);self.playbackSpeedButton.accessibilityIdentifier=@"media-playback-speed";self.playbackSpeedButton.accessibilityLabel=@"播放速度";self.playbackSpeedButton.showsMenuAsPrimaryAction=YES;double initialRate=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"] doubleValue]:1.0;NSString *initialRateLabel=fabs(initialRate*10-round(initialRate*10))<0.001?[NSString stringWithFormat:@"%.1f×",initialRate]:[NSString stringWithFormat:@"%.2f×",initialRate];[self.playbackSpeedButton setTitle:initialRateLabel forState:UIControlStateNormal];self.playbackSpeedButton.accessibilityValue=[NSString stringWithFormat:@"当前速度 %@",initialRateLabel];self.playbackSpeedButton.menu=[self playbackRateMenu];
    self.playbackActionRow=[UIStackView new];self.playbackActionRow.translatesAutoresizingMaskIntoConstraints=NO;self.playbackActionRow.axis=UILayoutConstraintAxisHorizontal;self.playbackActionRow.alignment=UIStackViewAlignmentFill;self.playbackActionRow.spacing=8;[self.controlPanel addSubview:self.playbackActionRow];
    self.skipButton=[UIButton buttonWithType:UIButtonTypeSystem];self.skipButton.translatesAutoresizingMaskIntoConstraints=NO;self.skipButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.skipButton.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(self.skipButton,YES);MediaPlaybackApplyScaledPillFont(self.skipButton);[self.skipButton addTarget:self action:@selector(performSkipAction) forControlEvents:UIControlEventTouchUpInside];self.skipButton.hidden=YES;
    self.inlineRetryButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineRetryButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.inlineRetryButton,YES);MediaPlaybackApplyScaledPillFont(self.inlineRetryButton);[self.inlineRetryButton setTitle:@"重试" forState:UIControlStateNormal];[self.inlineRetryButton addTarget:self action:@selector(retryCurrentEpisode) forControlEvents:UIControlEventTouchUpInside];self.inlineRetryButton.hidden=YES;self.inlineRetryButton.accessibilityLabel=@"重试当前影片";
    self.inlineWebButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineWebButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.inlineWebButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineWebButton);[self.inlineWebButton setTitle:@"网页尝试" forState:UIControlStateNormal];[self.inlineWebButton addTarget:self action:@selector(openWebPlaybackFallback) forControlEvents:UIControlEventTouchUpInside];self.inlineWebButton.hidden=YES;self.inlineWebButton.accessibilityLabel=@"尝试网页播放";
    self.inlineOptionsButton=[UIButton buttonWithType:UIButtonTypeSystem];self.inlineOptionsButton.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(self.inlineOptionsButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineOptionsButton);[self.inlineOptionsButton setTitle:@"更多" forState:UIControlStateNormal];self.inlineOptionsButton.accessibilityLabel=@"播放设置";self.inlineOptionsButton.menu=self.playbackOptionsItem.menu;self.inlineOptionsButton.showsMenuAsPrimaryAction=YES;
    [self.playbackActionRow addArrangedSubview:self.skipButton];if(self.embeddedMode){[self.playbackActionRow addArrangedSubview:self.inlineRetryButton];[self.playbackActionRow addArrangedSubview:self.inlineWebButton];[self.playbackActionRow addArrangedSubview:self.inlineOptionsButton];}else [self.playbackActionRow addArrangedSubview:self.episodeButton];[self.playbackActionRow addArrangedSubview:self.playbackSpeedButton];

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
            [self.inlineWebButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ];
        self.embeddedConstraints=[self.embeddedSurfaceConstraints arrayByAddingObjectsFromArray:self.embeddedControlConstraints];
        [NSLayoutConstraint activateConstraints:self.embeddedConstraints];
    }else [self updatePlaybackLayoutForSize:self.view.bounds.size];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self buildLines];[self buildQualityButtons];[self updateEpisodeTitle];self.pendingEpisodeResult=self.result;self.pendingEpisodeGeneration=self.generation;
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updatePlaybackLayoutForSize:self.view.bounds.size];self.videoTopScrim.frame=CGRectMake(0,0,CGRectGetWidth(self.videoView.bounds),MIN(168,MAX(72,CGRectGetHeight(self.videoView.bounds)*0.58)));if(!self.observingVideoLayer)[self observePlayerLayerIfAvailable];}
- (void)installFloatingInlineSurfaceInHost:(UIView *)videoHost controlsStack:(UIStackView *)controlsStack {
    if(!self.embeddedMode||self.floatingInlineSurfaceInstalled||!videoHost||!controlsStack||!self.isViewLoaded)return;
    self.floatingInlineSurfaceInstalled=YES;
    [NSLayoutConstraint deactivateConstraints:self.embeddedSurfaceConstraints?:@[]];
    self.videoAspectConstraint.active=NO;self.embeddedTallVideoAspectConstraint.active=NO;
    self.view.translatesAutoresizingMaskIntoConstraints=NO;[self.view removeFromSuperview];[videoHost addSubview:self.view];
    [NSLayoutConstraint activateConstraints:@[[self.view.leadingAnchor constraintEqualToAnchor:videoHost.leadingAnchor],[self.view.trailingAnchor constraintEqualToAnchor:videoHost.trailingAnchor],[self.view.topAnchor constraintEqualToAnchor:videoHost.topAnchor],[self.view.bottomAnchor constraintEqualToAnchor:videoHost.bottomAnchor],[self.videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.videoView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [self.controlPanel removeFromSuperview];[controlsStack insertArrangedSubview:self.controlPanel atIndex:0];
    self.inlineNowPlayingLabel.text=self.episodeTitle.text;self.inlineNowPlayingPill.accessibilityLabel=self.episodeTitle.accessibilityLabel?:self.episodeTitle.text;self.inlineNowPlayingPill.hidden=NO;
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
    self.gestureFeedbackLabel.text=[NSString stringWithFormat:@"   %@%@   ",prefix,text?:@""];
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
        [UIView animateWithDuration:0.20 animations:^{owner.gestureFeedbackLabel.alpha=0;} completion:^(BOOL finished){if(finished&&owner.gestureFeedbackGeneration==generation){owner.gestureFeedbackLabel.hidden=YES;owner.gestureFeedbackLabel.alpha=1.0;}}];
    });
}
- (void)toggleGestureLock {
    self.gestureLockActive=!self.gestureLockActive;
    [self.screenLockButton setImage:[UIImage systemImageNamed:self.gestureLockActive?@"lock.fill":@"lock.open"] forState:UIControlStateNormal];
    self.screenLockButton.backgroundColor=self.gestureLockActive?HostAccent():[UIColor colorWithWhite:0 alpha:0.58];
    self.controlPanel.userInteractionEnabled=!self.gestureLockActive;
    self.controlPanel.alpha=self.gestureLockActive?0.35:1.0;
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
    [self seekActiveEngineToTime:target completion:nil];[self updateSkipButtonForCurrentPosition];[self showGestureFeedback:delta<0?@"−10 秒":@"+10 秒"];
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
            NSTimeInterval delta=self.panTargetTime-self.panStartTime;[self showGestureFeedback:[NSString stringWithFormat:@"%@ %@",delta<0?@"后退至":@"快进至",[self formatMediaTime:self.panTargetTime]]];
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
    if(pending&&pendingGeneration==self.generation){[self playResult:pending];return;}
    if(self.awaitingWebPlaybackReturn){[self.spinner stopAnimating];self.status.text=@"网页播放已关闭 · 可尝试原生播放，或重新选择线路和分集";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];[self recordPlaybackAttemptOutcome:@"webview_returned" failureKind:nil httpStatus:0 terminal:YES];}
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
    self.pendingScreenExit=NO;
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;
    self.generation++;[self.client cancel];self.resolving=NO;
    self.awaitingWebPlaybackReturn=NO;self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;
    [self.spinner stopAnimating];[self clearCurrentPlayerItem];
    [self.player replaceCurrentItemWithPlayerItem:nil];
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
    if(size.width<=0||size.height<=0)return;
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
    if(self.isViewLoaded){[self persistPlaybackProgress];self.generation++;[self.client cancel];self.resolving=NO;self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;[self.spinner stopAnimating];}
    NSString *previousSourceID=[self.context[@"source"][@"id"] description]?:@"",*nextSourceID=[context[@"source"][@"id"] description]?:@"";self.context=[context copy]?:@{};self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];self.pendingEpisodeResult=nil;self.pendingEpisodeGeneration=0;[self resetAutomaticFallbackLines];
    if(!self.isViewLoaded){self.result=[result copy];self.pendingEpisodeResult=self.result;self.pendingEpisodeGeneration=self.generation;return;}
    if(!self.client||![previousSourceID isEqual:nextSourceID]){[self.client cancel];self.client=MediaPlaybackClientForSource(self.context[@"source"]?:@{});}self.basePlaybackHeaders=nil;self.selectedAlternateIndex=-1;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=nil;self.pendingPlaybackResumeEntry=nil;self.pendingQualityRestorePlaybackState=NO;self.resumePromptPending=NO;self.resumePromptShown=NO;self.stallRecoveryAttempts=0;self.attemptedRoutes=0;[self buildLines];if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;[self updateEpisodeTitle];self.playbackOptionsItem.menu=[self playbackOptionsMenu];
    [self playResult:result];
}
- (void)dealloc {
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;
    self.generation++;
    self.playerGeneration++;
    [self persistPlaybackProgress];
    if(self.progressTimeObserver&&self.player){@try{[self.player removeTimeObserver:self.progressTimeObserver];}@catch(NSException *exception){}self.progressTimeObserver=nil;}
    if(self.idleTimerOverrideActive){BOOL previousIdleTimerDisabled=self.previousIdleTimerDisabled;if(NSThread.isMainThread)UIApplication.sharedApplication.idleTimerDisabled=previousIdleTimerDisabled;else dispatch_async(dispatch_get_main_queue(),^{UIApplication.sharedApplication.idleTimerDisabled=previousIdleTimerDisabled;});}
    if(self.observingPlayer){@try{[self.player removeObserver:self forKeyPath:@"timeControlStatus" context:CCTVPlayerTimeControlContext];}@catch(NSException *exception){}}
    [self stopObservingCurrentPlayback];
    [NSNotificationCenter.defaultCenter removeObserver:self];[self.client cancel];[self.player pause];[self teardownCicadaAdapter];
}
- (void)updateEstimatedThroughput {
    if(!self.throughputLabel||self.embeddedMode)return;
    if(self.cicadaAdapter){double bytesPerSecond=self.cicadaAdapterDownloadBPS/8.0;NSString *speed=isfinite(bytesPerSecond)&&bytesPerSecond>0?(bytesPerSecond>=1024.0*1024.0?[NSString stringWithFormat:@"%.1f MB/s",bytesPerSecond/1024.0/1024.0]:[NSString stringWithFormat:@"%.0f KB/s",bytesPerSecond/1024.0]):@"等待网络";NSString *text=self.playbackFailureRecorded?@"测速暂停":speed;self.throughputLabel.text=[NSString stringWithFormat:@"  %@  ",text];self.throughputLabel.accessibilityLabel=text;return;}
    AVPlayerItemAccessLogEvent *event=self.player.currentItem.accessLog.events.lastObject;
    double bitsPerSecond=event.observedBitrate;
    NSString *text= self.playbackFailureRecorded ? @"测速暂停" : (isfinite(bitsPerSecond)&&bitsPerSecond>0 ? (bitsPerSecond/8.0>=1024.0*1024.0 ? [NSString stringWithFormat:@"估算 %.1f MB/s",bitsPerSecond/8.0/1024.0/1024.0] : [NSString stringWithFormat:@"估算 %.0f KB/s",bitsPerSecond/8.0/1024.0]) : (self.player.timeControlStatus==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate?@"等待网络":@"测速中"));
    self.throughputLabel.text=[NSString stringWithFormat:@"  %@  ",text];self.throughputLabel.accessibilityLabel=text;
}
- (void)stopObservingCurrentPlayback {
    // 每秒回调的 time observer 只在 dealloc 移除，clearCurrentPlayerItem /
    // viewDidDisappear 走这里清理时不移除会空转；新 item 由
    // installProgressObserverIfNeeded 重装。
    if(self.progressTimeObserver&&self.player){@try{[self.player removeTimeObserver:self.progressTimeObserver];}@catch(NSException *exception){}self.progressTimeObserver=nil;}
    if(self.playbackAttemptID.length&&!self.progressSummaryRecorded){
        self.progressSummaryRecorded=YES;
        [RuntimeDiagnostics.shared recordEvent:@"playback_progress_summary" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID,@"correlation_id":self.diagnosticTraceID?:@"",@"first_frame_observed":@(self.videoFrameReady),@"observed_playing_seconds":@(_progressEvidence.observed),@"progress_samples":@(_progressEvidence.samples),@"stall_notifications":@(self.diagnosticStallCount)}];
    }
    AVPlayerItem *item=self.observedItem;
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
        [owner updateSkipButtonForCurrentPosition];
    }];
}
- (void)persistPlaybackProgress {
    if(!self.context)return;
    NSTimeInterval position,duration;
    if(self.cicadaAdapter){position=self.cicadaAdapter.currentPosition;duration=self.cicadaAdapter.duration;}
    else{AVPlayerItem *item=self.observedItem;if(!item||item!=self.player.currentItem)return;position=CMTimeGetSeconds(self.player.currentTime);duration=CMTimeGetSeconds(item.duration);}
    if(!isfinite(position)||position<0)return;if(!isfinite(duration)||duration<0)duration=0;
    [MediaPlaybackStateStore recordContext:self.context lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:NO];
    self.lastPersistedPosition=position;
}
- (void)applicationDidEnterBackground:(NSNotification *)notification {[self persistPlaybackProgress];}
- (void)offerResumeForItem:(AVPlayerItem *)item {
    NSDictionary *entry=self.pendingPlaybackResumeEntry;if(!entry||self.resumePromptShown||item!=self.observedItem||item!=self.player.currentItem)return;
    NSTimeInterval position=[entry[@"position"] doubleValue];
    // 弹框时已有模态页或视图不在窗口内会丢提示、播放停在暂停态：直接从上次位置继续。
    if(self.presentedViewController||!self.view.window){self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=@(MAX(0,position));[self applyPendingPlaybackSeekForItem:item];return;}
    self.resumePromptShown=YES;self.resumePromptPending=YES;[self.player pause];
    NSString *episode=entry[@"episodeName"]?:@"上次分集";NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"继续上次播放？" message:[NSString stringWithFormat:@"%@ · %@",episode,[self formatMediaTime:position]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"从头播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;[owner.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);[owner.player play];[RuntimeDiagnostics.shared recordEvent:@"media_resume_declined" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续观看" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;CMTime target=CMTimeMakeWithSeconds(MAX(0,position),600);[owner.player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);[owner.player play];[owner.status setText:@"已从上次进度继续播放"];[RuntimeDiagnostics.shared recordEvent:@"media_resume_accepted" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyPendingPlaybackSeekForItem:(AVPlayerItem *)item {
    NSNumber *pending=self.pendingPlaybackSeekTime;if(!pending||item!=self.observedItem||item!=self.player.currentItem)return;
    self.pendingPlaybackSeekTime=nil;NSTimeInterval position=MAX(0,pending.doubleValue);NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    [self.player seekToTime:CMTimeMakeWithSeconds(position,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;[owner markAutoSkipFlagsForCurrentPosition];owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);BOOL shouldResume=!owner.pendingQualityRestorePlaybackState||owner.pendingQualityWasPlaying;owner.pendingQualityRestorePlaybackState=NO;if(shouldResume)[owner.player play];else[owner.player pause];[owner updateSkipButtonForCurrentPosition];});}];
}
- (void)offerResumeForCicada {
    NSDictionary *entry=self.pendingPlaybackResumeEntry;if(!entry||self.resumePromptShown||!self.cicadaAdapter)return;
    NSTimeInterval position=[entry[@"position"] doubleValue];
    // 弹框时已有模态页或视图不在窗口内会丢提示、播放停在暂停态：直接从上次位置继续。
    if(self.presentedViewController||!self.view.window){self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=@(MAX(0,position));[self applyPendingPlaybackSeekForCicada];return;}
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
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *loadError=nil;AVKeyValueStatus loadStatus=[asset statusOfValueForKey:@"tracks" error:&loadError];
        NSArray<AVAssetTrack *> *tracks=loadStatus==AVKeyValueStatusLoaded?[asset tracksWithMediaType:AVMediaTypeVideo]:@[];
        AVAssetTrack *videoTrack=tracks.firstObject;CGSize naturalSize=videoTrack.naturalSize;NSMutableOrderedSet<NSString *> *codecs=[NSMutableOrderedSet orderedSet];
        if(videoTrack){for(id description in videoTrack.formatDescriptions){CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)description;if(CMFormatDescriptionGetMediaType(format)!=kCMMediaType_Video)continue;FourCharCode code=CMFormatDescriptionGetMediaSubType(format);char name[5]={(char)((code>>24)&0xff),(char)((code>>16)&0xff),(char)((code>>8)&0xff),(char)(code&0xff),0};BOOL printable=YES;for(int i=0;i<4;i++)if(name[i]<32||name[i]>126)printable=NO;if(printable)[codecs addObject:[NSString stringWithUTF8String:name]];}}
        dispatch_async(dispatch_get_main_queue(),^{
            MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.observedItem||item!=owner.player.currentItem)return;
            CGSize presentation=item.presentationSize;CGFloat displayAspect=0;if(presentation.width>0&&presentation.height>0)displayAspect=presentation.width/presentation.height;else if(videoTrack){CGSize natural=videoTrack.naturalSize;CGRect transformed=CGRectStandardize(CGRectApplyAffineTransform(CGRectMake(0,0,fabs(natural.width),fabs(natural.height)),videoTrack.preferredTransform));if(transformed.size.width>0&&transformed.size.height>0)displayAspect=fabs(transformed.size.width)/fabs(transformed.size.height);}if(isfinite(displayAspect)&&displayAspect>0.1&&displayAspect<10.0){owner.videoAspectRatio=displayAspect;[owner updatePlaybackLayoutForSize:owner.view.bounds.size];if(owner.onVideoAspectRatioChanged)owner.onVideoAspectRatioChanged(displayAspect);}AVPlayerLayer *layer=owner.videoLayer;BOOL hasVideo=tracks.count>0||presentation.width>0||presentation.height>0||owner.videoFrameReady;owner.hasVideoTrack=hasVideo;
            NSMutableDictionary *fields=[@{@"playback_attempt_id":owner.playbackAttemptID?:@"",@"correlation_id":owner.diagnosticTraceID?:@"",@"track_load_status":loadStatus==AVKeyValueStatusLoaded?@"loaded":(loadStatus==AVKeyValueStatusFailed?@"failed":@"unavailable"),@"asset_video_track_count":@(tracks.count),@"video_track_state":hasVideo?@"present_video_track":(loadStatus==AVKeyValueStatusLoaded?@"no_video_track":@"unknown"),@"video_presentation_width":@(MAX(0,(NSInteger)llround(presentation.width))),@"video_presentation_height":@(MAX(0,(NSInteger)llround(presentation.height))),@"video_layer_ready_for_display":@(layer.readyForDisplay),@"video_layer_width":@(MAX(0,(NSInteger)llround(layer.bounds.size.width))),@"video_layer_height":@(MAX(0,(NSInteger)llround(layer.bounds.size.height)))} mutableCopy];
            if(videoTrack){fields[@"video_natural_width"]=@(MAX(0,(NSInteger)llround(fabs(naturalSize.width))));fields[@"video_natural_height"]=@(MAX(0,(NSInteger)llround(fabs(naturalSize.height))));}
            if(codecs.count)fields[@"video_codec_fourcc"]=codecs.array;
            if(loadError){fields[@"track_load_error_domain"]=loadError.domain?:@"";fields[@"track_load_error_code"]=@(loadError.code);}
            [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(owner.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_video_track_inspected" category:@"playback" fields:fields];
            if(owner.videoFrameReady)return;
            if(loadStatus==AVKeyValueStatusLoaded&&!hasVideo){
                owner.status.text=@"此线路没有可用视频轨 · 正在尝试其他线路";owner.status.accessibilityLabel=owner.status.text;[owner.spinner startAnimating];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    MediaPlaybackViewController *current=weakSelf;
                    if(!current||generation!=current.playerGeneration||item!=current.observedItem||item!=current.player.currentItem||current.videoFrameReady)return;
                    [current recordPlaybackAttemptOutcome:@"no_video_track" failureKind:@"no_video_track" httpStatus:0 terminal:NO];
                    if([current tryNextLineForAutomaticFallback:@"no_video_track"])return;
                    current.status.text=@"此资源没有可用视频轨道 · 其他线路已试完";current.status.accessibilityLabel=current.status.text;[current.spinner stopAnimating];[current setRetryAvailable:YES];
                });
            }
            else if(hasVideo){owner.status.text=@"视频轨道已确认 · 等待画面首帧";if(owner.player.timeControlStatus!=AVPlayerTimeControlStatusPaused)[owner.spinner startAnimating];}
            else owner.status.text=@"已收到媒体 · 正在检测视频轨道";
            owner.status.accessibilityLabel=owner.status.text;
        });
    }];
}
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item {
    if(!item||item!=self.observedItem||item!=self.player.currentItem||self.videoFrameReady)return;
    self.videoFrameReady=YES;self.hasVideoTrack=YES;[self.spinner stopAnimating];[self setRetryAvailable:NO];
    HostPlaybackProgressSample(&_progressEvidence,CACurrentMediaTime(),CMTimeGetSeconds(item.currentTime),self.player.rate,0);
    self.status.text=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying?@"视频首帧已就绪 · AVPlayer 正在播放":@"视频首帧已就绪 · 等待播放";self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_ready" category:@"playback" fields:fields];[self recordPlaybackAttemptOutcome:@"first_frame_ready" failureKind:nil httpStatus:0 terminal:NO];
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
    NSDictionary *parentResult=self.result;self.selectedAlternateIndex=sender.tag;NSMutableDictionary *selected=[parentResult mutableCopy];selected[@"url"]=url;selected[@"originalURL"]=originalURL;NSMutableDictionary *headers=[self.basePlaybackHeaders mutableCopy]?:[NSMutableDictionary dictionary];[headers addEntriesFromDictionary:MediaPlaybackHeadersFromResult(alternate)];selected[@"headers"]=headers.copy;[selected removeObjectForKey:@"header"];for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime",@"playbackEngine",@"nativePlayable",@"directMedia",@"requiresWebPlayback",@"parse",@"jx"]){[selected removeObjectForKey:key];if(alternate[key]!=nil)selected[key]=alternate[key];}NSURLComponents *alternateParts=[NSURLComponents componentsWithString:url];if(!alternateParts.path.pathExtension.length&&!MediaPlaybackResultSupportsNativePlayback(alternate)&&MediaPlaybackResultSupportsCicada(parentResult)){selected[@"playbackEngine"]=@"cicada";for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime"])if(!selected[key]&&parentResult[key])selected[key]=parentResult[key];}self.result=selected;[self buildQualityButtons];
    [self persistPlaybackProgress];NSTimeInterval current=[self activeEngineCurrentPosition];self.pendingQualitySeekTime=(isfinite(current)&&current>=0)?@(MAX(0,current)):nil;self.pendingQualityWasPlaying=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;self.pendingQualityRestorePlaybackState=YES;
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
    AVPlayerItem *item=self.player.currentItem;AVMediaSelectionGroup *group=item?[item.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;
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
    UIMenu *menu=[UIMenu menuWithChildren:@[[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicLegible title:@"字幕"],[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicAudible title:@"音轨"],danmaku,[self playbackRateMenu],[self playbackSleepTimerMenu],[UIMenu menuWithTitle:@"画面比例" children:gravityActions],autoNextAction,intro,outro,clear,awake]];if(self.inlineOptionsButton)self.inlineOptionsButton.menu=menu;return menu;
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
    if([action isEqual:@"outro"]&&self.episodeIndex+1<self.episodes.count){[self persistPlaybackProgress];self.episodeIndex++;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"skip_outro";[self updateEpisodeTitle];[self resolveAndPlay];}
}
- (void)setRetryAvailable:(BOOL)available {
    if(self.embeddedMode){BOOL nativeFallback=self.awaitingWebPlaybackReturn&&[self.result[@"url"] isKindOfClass:NSString.class];BOOL hasResolvedPage=[self.result[@"url"] isKindOfClass:NSString.class]&&[self.result[@"url"] length];self.inlineRetryButton.hidden=!available;[self.inlineRetryButton setTitle:nativeFallback?@"原生播放":@"重试" forState:UIControlStateNormal];self.inlineRetryButton.accessibilityLabel=nativeFallback?@"尝试原生播放器":@"重试当前影片";BOOL canTryWeb=available&&!nativeFallback&&(hasResolvedPage||self.episodeWebFallbackAvailable);self.inlineWebButton.hidden=!canTryWeb;if(canTryWeb){BOOL episodePageFallback=!hasResolvedPage;[self.inlineWebButton setTitle:episodePageFallback?@"打开网页":@"网页播放" forState:UIControlStateNormal];self.inlineWebButton.accessibilityLabel=episodePageFallback?@"打开分集网页尝试播放":@"尝试网页播放";[self.inlineWebButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];[self.inlineWebButton addTarget:self action:episodePageFallback?@selector(openEpisodePageWebFallback):@selector(openWebPlaybackFallback) forControlEvents:UIControlEventTouchUpInside];}return;}
    if(available){BOOL nativeFallback=self.awaitingWebPlaybackReturn&&[self.result[@"url"] isKindOfClass:NSString.class];if(!self.retryItem)self.retryItem=[[UIBarButtonItem alloc] initWithTitle:nativeFallback?@"尝试原生":@"重试" style:UIBarButtonItemStylePlain target:self action:nativeFallback?@selector(tryNativePlayback):@selector(retryCurrentEpisode)];self.retryItem.title=nativeFallback?@"尝试原生":@"重试";self.retryItem.target=self;self.retryItem.action=nativeFallback?@selector(tryNativePlayback):@selector(retryCurrentEpisode);NSMutableArray *items=[NSMutableArray arrayWithObject:self.retryItem];BOOL hasResolvedPage=[self.result[@"url"] isKindOfClass:NSString.class]&&[self.result[@"url"] length];if(!nativeFallback&&(hasResolvedPage||self.episodeWebFallbackAvailable)){if(!self.webFallbackItem){self.webFallbackItem=[[UIBarButtonItem alloc] initWithTitle:@"网页" style:UIBarButtonItemStylePlain target:self action:@selector(openWebPlaybackFallback)];self.webFallbackItem.accessibilityLabel=@"尝试网页播放";}if(!hasResolvedPage){self.webFallbackItem.title=@"网页尝试";self.webFallbackItem.accessibilityLabel=@"打开分集网页尝试播放";self.webFallbackItem.target=self;self.webFallbackItem.action=@selector(openEpisodePageWebFallback);}else{self.webFallbackItem.title=@"网页";self.webFallbackItem.accessibilityLabel=@"尝试网页播放";self.webFallbackItem.target=self;self.webFallbackItem.action=@selector(openWebPlaybackFallback);}[items addObject:self.webFallbackItem];}if(self.playbackOptionsItem)[items addObject:self.playbackOptionsItem];self.navigationItem.rightBarButtonItems=items;}
    else self.navigationItem.rightBarButtonItems=self.playbackOptionsItem?@[self.playbackOptionsItem]:@[];
}
- (void)clearCurrentPlayerItem {
    self.playerGeneration++;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];[self teardownCicadaAdapter];self.hasVideoTrack=NO;self.videoFrameReady=NO;
}
- (void)updateEpisodeTitle {
    NSArray *episodes=self.episodes;NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:nil;
    NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:@"";name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *spokenNumber=MediaPlaybackEpisodeNumber(name);NSString *number=spokenNumber.length?[NSString stringWithFormat:@"第 %@ 集",spokenNumber]:(episodes.count?[NSString stringWithFormat:@"第 %ld 集",(long)self.episodeIndex+1]:@"当前分集");
    NSString *title=name.length&&!MediaPlaybackEpisodeNamesMatch(name,number)?[NSString stringWithFormat:@"%@ · %@",number,name]:number;
    NSString *visibleTitle=[NSString stringWithFormat:@"正在播放 · %@",title];
    self.episodeTitle.text=visibleTitle;self.episodeTitle.accessibilityLabel=visibleTitle;
    self.inlineNowPlayingLabel.text=visibleTitle;self.inlineNowPlayingPill.accessibilityLabel=visibleTitle;self.inlineNowPlayingPill.hidden=!self.floatingInlineSurfaceInstalled;
    // Keep the selected episode visible in both the playback bar and the
    // navigation title; the series title alone is ambiguous during playback.
    self.title=title;
    NSString *line=self.lineIndex>=0&&self.lineIndex<self.lines.count?([self.lines[self.lineIndex][@"name"] isKindOfClass:NSString.class]?self.lines[self.lineIndex][@"name"]:@""):@"";
    NSString *label=line.length?[NSString stringWithFormat:@"选集 · %@ · %lu 集",line,(unsigned long)episodes.count]:@"选集";
    [self.episodeButton setTitle:label forState:UIControlStateNormal];self.episodeButton.enabled=episodes.count>0;self.episodeButton.alpha=episodes.count?1.0:0.55;[self updateSkipButtonForCurrentPosition];
    NSMutableDictionary *updatedContext=[self.context mutableCopy]?:[NSMutableDictionary dictionary];updatedContext[@"lineIndex"]=@(self.lineIndex);updatedContext[@"episodeIndex"]=@(self.episodeIndex);
    NSDictionary *selectedLine=self.lineIndex>=0&&self.lineIndex<self.lines.count?self.lines[self.lineIndex]:@{};updatedContext[@"lineID"]=[selectedLine[@"id"] description]?:@"";updatedContext[@"episodeID"]=[episode[@"id"] description]?:@"";updatedContext[@"episodeName"]=name?:@"";self.context=updatedContext;
    if(self.onEpisodeSelectionChanged)self.onEpisodeSelectionChanged(self.context);
}
- (void)openEpisodeSelection {
    if(!self.lines.count)return;
    self.generation++;[self.client cancel];if(self.resolving){self.resolving=NO;[self.spinner stopAnimating];self.status.text=@"解析已取消 · 请选择分集";self.status.accessibilityLabel=self.status.text;}
    MediaEpisodeSelectionViewController *page=[MediaEpisodeSelectionViewController new];page.item=self.context[@"item"]?:@{};page.source=self.context[@"source"]?:@{};page.provider=self.context[@"provider"]?:@"";page.detail=self.context[@"detail"]?:@{};page.correlationID=self.diagnosticTraceID;page.parserID=MediaPlaybackSelectedParserID(self.context);page.selectedLineIndex=self.lineIndex;page.selectedEpisodeIndex=self.episodeIndex;page.selectedSeasonIndex=[self.context[@"seasonIndex"] integerValue];page.selectionUpdatesPlayer=YES;page.client=MediaPlaybackClientForSource(page.source);
    __weak typeof(self) weakSelf=self;page.onSelectEpisode=^(NSDictionary *result,NSDictionary *context){MediaPlaybackViewController *owner=weakSelf;if(!owner)return;[owner persistPlaybackProgress];owner.stallRecoveryAttempts=0;owner.basePlaybackHeaders=nil;owner.context=context;owner.lineIndex=[context[@"lineIndex"] integerValue];owner.episodeIndex=[context[@"episodeIndex"] integerValue];owner.pendingEpisodeResult=result;owner.pendingEpisodeGeneration=owner.generation;owner.attemptedRoutes=0;[owner resetAutomaticFallbackLines];[owner buildLines];if(owner.lineIndex<0||owner.lineIndex>=owner.lines.count)owner.lineIndex=0;if(owner.episodeIndex<0||owner.episodeIndex>=owner.episodes.count)owner.episodeIndex=0;[owner updateEpisodeTitle];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)playResult:(NSDictionary *)result {
    // 新解析结果（URL 变化）开始时清零回退链状态；同 URL 重放不复位，
    // 由 resolveAndPlay / 画质切换 / 分集选择处的显式复位负责。
    NSString *incomingURL=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";
    NSString *previousURL=[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@"";
    if(![incomingURL isEqualToString:previousURL])self.attemptedRoutes=0;
    self.cicadaAdapterSoftwareDecodeFallbackAttempted=NO;self.resolving=NO;self.awaitingWebPlaybackReturn=NO;NSUInteger playerGeneration=++self.playerGeneration;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];[self teardownCicadaAdapter];self.hasVideoTrack=NO;self.videoTrackInspectionStarted=NO;self.videoFrameReady=NO;self.lastPersistedPosition=0;if(!self.embeddedMode)self.throughputLabel.text=@"  测速中  ";
    self.progressEvidence=(HostPlaybackProgress){0};self.progressMilestone=0;self.progressSummaryRecorded=NO;self.diagnosticStallCount=0;self.playbackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;self.terminalPlaybackOutcomeRecorded=NO;self.playbackFailureRecorded=NO;self.result=result;
    NSString *raw=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";NSURL *url=[NSURL URLWithString:raw];NSURL *sourceURL=MediaPlaybackOriginalSourceURL(result);NSString *serviceID=[self.context[@"source"][@"id"] isKindOfClass:NSString.class]?self.context[@"source"][@"id"]:@"";
    NSMutableDictionary *attemptFields=[@{@"playback_attempt_id":self.playbackAttemptID, @"active_playback_attempt_id":self.playbackAttemptID, @"active_playback_service_id":serviceID, @"active_playback_source_host":sourceURL.host.lowercaseString?:@"", @"active_playback_outcome":@"in_progress", @"last_playback_attempt_id":self.playbackAttemptID, @"last_playback_outcome":@"in_progress", @"last_playback_source_host":sourceURL.host.lowercaseString?:@"", @"last_playback_failure_kind":@"", @"last_playback_http_status":@0, @"last_playback_line_index":@(self.lineIndex), @"last_playback_episode_index":@(self.episodeIndex)} mutableCopy];
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"playback_attempt_started" fields:attemptFields];
    if(!url||raw.length>8192||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length||url.user.length||url.password.length||[raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[self.spinner stopAnimating];NSMutableDictionary *fields=[@{@"reason":@"invalid_media_url", @"failure_kind":@"invalid_media_url", @"playback_attempt_id":self.playbackAttemptID, @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];[RuntimeDiagnostics.shared recordEvent:@"episode_playback_rejected" category:@"playback" fields:fields];[self recordPlaybackAttemptOutcome:@"rejected" failureKind:@"invalid_media_url" httpStatus:0 terminal:YES];self.status.text=@"资源未返回有效的 HTTP/HTTPS 播放地址";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];return;}
    if(!self.basePlaybackHeaders)self.basePlaybackHeaders=[result[@"baseHeaders"] isKindOfClass:NSDictionary.class]?result[@"baseHeaders"]:MediaPlaybackHeadersFromResult(result);self.selectedAlternateIndex=-1;[self buildQualityButtons];self.resumeEntry=[MediaPlaybackStateStore historyEntryForContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex];self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.resumePromptShown=NO;
    NSNumber *qualityPosition=self.pendingQualitySeekTime;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=qualityPosition;if(!qualityPosition)self.pendingQualityRestorePlaybackState=NO;
    NSTimeInterval savedPosition=[self.resumeEntry[@"position"] doubleValue],savedDuration=[self.resumeEntry[@"duration"] doubleValue];BOOL hasResume=self.resumeEntry&&![self.resumeEntry[@"completed"] boolValue]&&savedPosition>=15&&(!isfinite(savedDuration)||savedDuration<=0||savedPosition<savedDuration-10);
    if(!qualityPosition&&hasResume){self.pendingPlaybackResumeEntry=self.resumeEntry;self.resumePromptPending=YES;self.pendingPlaybackSeekTime=nil;}
    BOOL directMedia=MediaPlaybackResultSupportsAVPlayer(result)||MediaPlaybackResultSupportsAVPlayer(@{@"url":raw});
    BOOL requiresWebPlayback=([result[@"requiresWebPlayback"] boolValue]||[result[@"parse"] integerValue]>0||[result[@"jx"] integerValue]>0)&&!directMedia;
    MediaPlaybackDecodeRoute initialRoute=MediaPlaybackDecodeRouteNextForResult(result,self.attemptedRoutes);
    if(self.onPlaybackWillStart)self.onPlaybackWillStart();
    [RuntimeDiagnostics.shared recordEvent:@"playback_owner_acquired" category:@"playback" fields:@{@"owner":@"vod",@"engine":MediaPlaybackDecodeRouteName(initialRoute),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"service_id":serviceID,@"correlation_id":self.diagnosticTraceID?:@""}];
    if(initialRoute==MediaPlaybackDecodeRouteWebView&&!requiresWebPlayback){[self openWebPlaybackFallback];return;}
    if(requiresWebPlayback && !directMedia){if(self.presentedViewController){self.status.text=@"已有页面正在显示 · 请关闭后重试";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];return;}self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedWebView;[self.spinner stopAnimating];self.status.text=@"正在打开来源网页播放器…";self.status.accessibilityLabel=self.status.text;self.awaitingWebPlaybackReturn=YES;[self setRetryAvailable:YES];NSMutableDictionary *fields=[@{@"player":@"webview", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:fields];[self recordPlaybackAttemptOutcome:@"webview_handoff" failureKind:nil httpStatus:0 terminal:NO];MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:result title:self.title];__weak typeof(self) weakSelf=self;web.correlationID=self.diagnosticTraceID;web.serviceID=self.context[@"source"][@"id"];web.playbackAttemptID=self.playbackAttemptID;web.onTryNativePlayback=^{[weakSelf tryNativePlayback];};web.onResolvedMedia=^(NSDictionary *resolved){MediaPlaybackViewController *owner=weakSelf;if(!owner||owner.playerGeneration!=playerGeneration)return;owner.basePlaybackHeaders=nil;[owner playResult:resolved];};UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:web];[self presentViewController:nav animated:YES completion:nil];return;}
    if(initialRoute==MediaPlaybackDecodeRouteCicadaPlayer){[self startCicadaPlaybackWithResult:result url:url sourceURL:sourceURL playerGeneration:playerGeneration];return;}
    if(initialRoute==MediaPlaybackDecodeRouteNone){[self.spinner stopAnimating];self.status.text=@"该资源没有可用的播放方式 · 可切换线路";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];[self recordPlaybackAttemptOutcome:@"rejected" failureKind:@"no_playback_route" httpStatus:0 terminal:YES];return;}
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedAVPlayer;
    NSMutableDictionary *handoffFields=[@{@"player":@"avplayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(result))];[handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();self.status.text=@"正在载入媒体…";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];[self setRetryAvailable:NO];
    NSDictionary *requestHeaders=MediaPlaybackHeadersFromResult(result);NSString *host=url.host.lowercaseString?:@"";BOOL localRelay=![sourceURL.absoluteString isEqualToString:raw]&&[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:host];if(localRelay)requestHeaders=@{};
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:requestHeaders.count?@{@"AVURLAssetHTTPHeaderFieldsKey":requestHeaders}:nil];AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
    // 默认清晰度只约束多码率 HLS 的自适应选线：单文件 MP4 只有一个码率，不受影响；央视直播走 SDK，不走这里。
    NSString *preferredQuality=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    if([preferredQuality isEqual:@"smooth"])item.preferredPeakBitRate=1500000;
    else if([preferredQuality isEqual:@"hd"])item.preferredPeakBitRate=4000000;
    else if([preferredQuality isEqual:@"uhd"])item.preferredPeakBitRate=8000000;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    if(!self.player){self.player=[AVPlayer playerWithPlayerItem:item];[self.player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerTimeControlContext];self.observingPlayer=YES;}else[self.player replaceCurrentItemWithPlayerItem:item];
    self.observedItem=item;[item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerItemStatusContext];self.player.automaticallyWaitsToMinimizeStalling=YES;self.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);self.playerController.videoGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;self.playerController.player=self.player;self.playbackOptionsItem.menu=[self playbackOptionsMenu];[self updateEstimatedThroughput];[self installProgressObserverIfNeeded];[self updateEpisodeTitle];
    __weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(owner&&playerGeneration==owner.playerGeneration)[owner observePlayerLayerIfAvailable];});
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime)[self.player play];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||playerGeneration!=owner.playerGeneration||item!=owner.player.currentItem||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.videoFrameReady||item.status==AVPlayerItemStatusFailed)return;NSTimeInterval position=CMTimeGetSeconds(owner.player.currentTime);NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":owner.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-owner.playbackStartedAt)*1000))), @"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"correlation_id":owner.diagnosticTraceID?:@"", @"time_control_status":@(owner.player.timeControlStatus), @"playback_position_seconds":@(isfinite(position)&&position>0?position:0), @"video_track_state":owner.hasVideoTrack?@"confirmed_video":@"unknown", @"video_layer_ready_for_display":@(owner.videoLayer.readyForDisplay), @"video_layer_width":@(MAX(0,(NSInteger)llround(owner.videoLayer.bounds.size.width))), @"video_layer_height":@(MAX(0,(NSInteger)llround(owner.videoLayer.bounds.size.height)))} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(owner.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_video_frame_timeout" category:@"playback" fields:fields];[owner recordPlaybackAttemptOutcome:@"first_frame_timeout" failureKind:@"first_frame_timeout" httpStatus:0 terminal:NO];if([owner tryNextLineForAutomaticFallback:@"first_frame_timeout"])return;[owner.spinner stopAnimating];owner.status.text=@"播放器尚未显示画面 · 可重试或手动切换线路";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];});
}
- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration {
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
    NSMutableDictionary *handoffFields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(result))];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];
    [RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();
    self.status.text=@"正在使用 ffmpeg 内核载入媒体…";self.status.accessibilityLabel=self.status.text;
    [self.spinner startAnimating];[self setRetryAvailable:NO];
    NSTimeInterval timeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;
    NSDictionary *requestHeaders=self.basePlaybackHeaders?:MediaPlaybackHeadersFromResult(result);
    MediaPlaybackCicadaAdapter *adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:url headers:requestHeaders networkTimeout:timeout];
    adapter.delegate=self;self.cicadaAdapter=adapter;self.cicadaPosition=0;self.cicadaDuration=0;
    UIView *playerView=adapter.playerView;playerView.translatesAutoresizingMaskIntoConstraints=NO;
    [self.videoView addSubview:playerView];
    [NSLayoutConstraint activateConstraints:@[[playerView.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[playerView.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[playerView.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[playerView.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];
    [self.playerController.view setHidden:YES];
    NSString *gravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    [adapter applyVideoGravity:gravity];
    // 硬解开关：软件解码重试时 cicadaAdapterSoftwareDecodeFallbackAttempted
    // 已置位，prepare 即用软件解码重建（见 advanceFromCicadaFailureWithError:）。
    [adapter prepareWithHardwareDecoder:!self.cicadaAdapterSoftwareDecodeFallbackAttempted];
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime)[adapter start];
    // 首帧看门狗（VC 侧后备；适配器内部另有 20 秒看门狗，二者走同一幂等回退）。
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||playerGeneration!=owner.playerGeneration||owner.cicadaAdapter!=adapter||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.videoFrameReady)return;[owner handleCicadaFirstFrameTimeoutForAdapter:adapter];});
}
- (BOOL)isCicadaEngineActive { return self.cicadaAdapter!=nil; }
- (NSTimeInterval)activeEngineCurrentPosition {
    if(self.cicadaAdapter)return self.cicadaAdapter.currentPosition;
    return CMTimeGetSeconds(self.player.currentTime);
}
- (NSTimeInterval)activeEngineDuration {
    if(self.cicadaAdapter)return self.cicadaAdapter.duration;
    return CMTimeGetSeconds(self.observedItem.duration);
}
- (void)seekActiveEngineToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion {
    if(self.cicadaAdapter){[self.cicadaAdapter seekToTime:time completion:completion];return;}
    [self.player seekToTime:CMTimeMakeWithSeconds(time,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completion];
}
- (void)setActiveEngineRate:(float)rate {
    if(self.cicadaAdapter){[self.cicadaAdapter setRate:rate];return;}
    self.player.defaultRate=rate;
}
- (void)pauseActiveEngine {
    if(self.cicadaAdapter){[self.cicadaAdapter pause];return;}
    [self.player pause];
}
- (void)playActiveEngine {
    if(self.cicadaAdapter){[self.cicadaAdapter start];return;}
    [self.player play];
}
- (void)teardownCicadaAdapter {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;self.cicadaAdapter=nil;
    if(!adapter)return;
    [adapter.playerView removeFromSuperview];
    [adapter destroy];
    [self.playerController.view setHidden:NO];
}
- (void)markCicadaFirstFrameReady {
    if(self.videoFrameReady)return;
    self.videoFrameReady=YES;self.hasVideoTrack=self.cicadaAdapter.hasVideoTrack;
    [self.spinner stopAnimating];
    self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"media_first_frame_ready" category:@"playback" fields:fields];
}
- (void)advanceFromCicadaFailureWithError:(NSError *)error {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;
    if(!adapter)return; // 已回退过或已拆解：幂等，不重复推进
    [self teardownCicadaAdapter];
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"failure_kind":@"cicada_playback_failed", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:@"cicada_playback_failed" httpStatus:0 terminal:NO];
    // 软件解码重试（移植自直连路径 handleCicadaFailure: 的解码关键词表）：
    // 报错指向解码且尚未试过软件解码时，用软件解码重建一次适配器，
    // 从上次位置续播（pendingPlaybackSeekTime 由 prepare 回调消费）。
    NSString *lowerMessage=(error.localizedDescription?:@"").lowercaseString;
    BOOL decoderFailure=[lowerMessage containsString:@"decode"]||[lowerMessage containsString:@"decoder"]||[lowerMessage containsString:@"codec"]||[lowerMessage containsString:@"avcodec"]||[lowerMessage containsString:@"解码"]||[lowerMessage containsString:@"硬件解码"];
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
    if(nextRoute==MediaPlaybackDecodeRouteWebView){[self openWebPlaybackFallback];return;}
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
    NSError *error=[NSError errorWithDomain:MediaPlaybackCicadaAdapterErrorDomain code:-1001 userInfo:@{NSLocalizedDescriptionKey:@"CicadaPlayer 20 秒内未显示首帧"}];
    [self advanceFromCicadaFailureWithError:error];
}
- (void)openWebPlaybackFallback {
    if(self.presentedViewController)return;
    if(![self.result[@"url"] isKindOfClass:NSString.class]||![self.result[@"url"] length])return;
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedWebView;
    [self persistPlaybackProgress];[self pauseActiveEngine];self.awaitingWebPlaybackReturn=YES;
    [RuntimeDiagnostics.shared recordEvent:@"playback_web_fallback_selected" category:@"playback" fields:@{@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"correlation_id":self.diagnosticTraceID?:@""}];
    [self recordPlaybackAttemptOutcome:@"webview_handoff" failureKind:nil httpStatus:0 terminal:NO];
    self.status.text=@"正在尝试网页播放…";self.status.accessibilityLabel=self.status.text;
    NSUInteger playerGeneration=self.playerGeneration;MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:self.result title:self.title];__weak typeof(self) weakSelf=self;
    web.correlationID=self.diagnosticTraceID;web.serviceID=self.context[@"source"][@"id"];web.playbackAttemptID=self.playbackAttemptID;web.onTryNativePlayback=^{[weakSelf tryNativePlayback];};web.onResolvedMedia=^(NSDictionary *resolved){MediaPlaybackViewController *owner=weakSelf;if(!owner||owner.playerGeneration!=playerGeneration)return;owner.basePlaybackHeaders=nil;[owner playResult:resolved];};
    web.onClose=^{MediaPlaybackViewController *owner=weakSelf;if(!owner)return;owner.status.text=@"网页播放已关闭 · 可尝试原生播放或切换线路";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];};
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:web];[self presentViewController:nav animated:YES completion:nil];
}
- (void)openEpisodePageWebFallback {
    NSArray *episodes=self.episodes;NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:nil;NSURL *url=MediaPlaybackEpisodePageFallbackURL(episode);
    if(!self.episodeWebFallbackAvailable||!url)return;
    if(self.presentedViewController)return;
    [self persistPlaybackProgress];[self pauseActiveEngine];self.awaitingWebPlaybackReturn=YES;
    NSString *episodeName=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:@"当前分集";
    NSMutableDictionary *webResult=[@{@"url":url.absoluteString,@"originalURL":url.absoluteString,@"parse":@1,@"requiresWebPlayback":@YES} mutableCopy];
    [RuntimeDiagnostics.shared recordEvent:@"playback_episode_page_fallback_selected" category:@"playback" fields:@{@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"fallback_kind":@"episode_page_after_no_media",@"correlation_id":self.diagnosticTraceID?:@"",@"source_host":url.host.lowercaseString?:@""}];
    self.status.text=@"正在打开分集网页…";self.status.accessibilityLabel=self.status.text;
    NSUInteger playerGeneration=self.playerGeneration;MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:webResult title:[NSString stringWithFormat:@"%@ · %@",self.title?:@"影视",episodeName]];__weak typeof(self) weakSelf=self;
    web.correlationID=self.diagnosticTraceID;web.serviceID=self.context[@"source"][@"id"];web.playbackAttemptID=self.playbackAttemptID;
    web.onTryNativePlayback=^{MediaPlaybackViewController *owner=weakSelf;if(owner){owner.awaitingWebPlaybackReturn=NO;owner.status.text=@"网页页面没有返回可供原生播放器使用的地址";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];}};
    web.onResolvedMedia=^(NSDictionary *resolved){MediaPlaybackViewController *owner=weakSelf;if(!owner||owner.playerGeneration!=playerGeneration)return;owner.awaitingWebPlaybackReturn=NO;owner.basePlaybackHeaders=nil;[owner playResult:resolved];};
    web.onClose=^{MediaPlaybackViewController *owner=weakSelf;if(!owner)return;owner.awaitingWebPlaybackReturn=NO;owner.status.text=@"分集网页已关闭 · 可重试解析或切换线路";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];};
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:web];[self presentViewController:nav animated:YES completion:nil];
}
- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage {
    if(!item||item!=self.observedItem||item!=self.player.currentItem||self.playbackFailureRecorded)return;
    self.playbackFailureRecorded=YES;[self updateEstimatedThroughput];[self.spinner stopAnimating];NSError *failure=error?:item.error;AVPlayerItemErrorLogEvent *networkError=item.errorLog.events.lastObject;NSString *kind=MediaPlaybackFailureKind(failure,networkError);
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"stage":stage?:@"unknown", @"failure_kind":kind, @"error_domain":failure.domain?:@"", @"error_code":@(failure.code), @"error_message":failure.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    if(networkError){fields[@"network_error_domain"]=networkError.errorDomain?:@"";fields[@"network_error_status_code"]=@(networkError.errorStatusCode);NSURL *networkURL=[NSURL URLWithString:networkError.URI?:@""];if(networkURL.host.length){fields[@"network_error_host"]=networkURL.host.lowercaseString;fields[@"network_error_extension"]=networkURL.pathExtension.lowercaseString?:@"";}}
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(self.result))];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];
    MediaPlaybackDecodeRoute nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
    if(nextRoute==MediaPlaybackDecodeRouteCicadaPlayer){
        // 新尝试：清掉本次失败标记，让 Cicada 路径有自己的失败上报。
        self.playbackFailureRecorded=NO;self.terminalPlaybackOutcomeRecorded=NO;
        self.resumePromptPending=NO;self.pendingPlaybackSeekTime=nil;
        NSURL *fallbackURL=[NSURL URLWithString:[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@""];
        [self startCicadaPlaybackWithResult:self.result url:fallbackURL sourceURL:MediaPlaybackOriginalSourceURL(self.result) playerGeneration:self.playerGeneration];
        return;
    }
    if(nextRoute==MediaPlaybackDecodeRouteWebView){[self openWebPlaybackFallback];return;}
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:kind httpStatus:networkError.errorStatusCode terminal:YES];
    BOOL offline=[failure.domain isEqualToString:NSURLErrorDomain]&&failure.code==NSURLErrorNotConnectedToInternet;
    if(!offline&&[self tryNextLineForAutomaticFallback:kind])return;
    self.status.text=MediaPlaybackFailureMessage(failure,networkError);self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if(context==CCTVPlayerItemStatusContext){AVPlayerItem *item=(AVPlayerItem *)object;if(item.status==AVPlayerItemStatusFailed){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=nil;[self recordPlaybackFailureForItem:item error:item.error stage:@"item_status_failed"];});}else if(item.status==AVPlayerItemStatusReadyToPlay){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.hasVideoTrack=self.videoFrameReady||(item.presentationSize.width>0&&item.presentationSize.height>0);for(AVPlayerItemTrack *track in item.tracks)if(track.assetTrack.mediaType==AVMediaTypeVideo){self.hasVideoTrack=YES;break;}NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"video_track_state":self.hasVideoTrack?@"confirmed_video":@"unknown", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,item);[RuntimeDiagnostics.shared recordEvent:@"media_item_ready" category:@"playback" fields:fields];[self inspectVideoTracksForItem:item generation:self.playerGeneration];self.playbackOptionsItem.menu=[self playbackOptionsMenu];if(self.pendingPlaybackSeekTime)[self applyPendingPlaybackSeekForItem:item];else if(self.resumePromptPending)[self offerResumeForItem:item];if(self.hasVideoTrack){if(!self.videoFrameReady){self.status.text=@"媒体已准备 · 等待视频首帧显示";self.status.accessibilityLabel=self.status.text;if(self.player.timeControlStatus==AVPlayerTimeControlStatusPaused)[self.spinner stopAnimating];else[self.spinner startAnimating];[self observePlayerLayerIfAvailable];}}else{[self.spinner stopAnimating];self.status.text=@"媒体已准备 · 视频轨道尚未确认";self.status.accessibilityLabel=self.status.text;}});}return;}
    if(context==CCTVPlayerLayerReadyContext){AVPlayerLayer *layer=(AVPlayerLayer *)object;AVPlayerItem *item=self.observedItem;NSUInteger generation=self.playerGeneration;if(layer==self.videoLayer&&layer.readyForDisplay){dispatch_async(dispatch_get_main_queue(),^{if(generation==self.playerGeneration&&item==self.observedItem&&layer==self.videoLayer&&layer.readyForDisplay)[self markFirstVideoFrameReadyForItem:item];});}return;}
    if(context==CCTVPlayerTimeControlContext){AVPlayerItem *reportedItem=self.player.currentItem;NSUInteger reportedGeneration=self.playerGeneration;AVPlayerTimeControlStatus state=self.player.timeControlStatus;dispatch_async(dispatch_get_main_queue(),^{if(!reportedItem||reportedGeneration!=self.playerGeneration||reportedItem!=self.observedItem||reportedItem!=self.player.currentItem||self.playbackFailureRecorded)return;if(!self.hasDiagnosticTimeControlStatus||self.lastDiagnosticTimeControlStatus!=(NSInteger)state){self.hasDiagnosticTimeControlStatus=YES;self.lastDiagnosticTimeControlStatus=(NSInteger)state;NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"video_track_state":self.hasVideoTrack?@"confirmed_video":@"unknown"} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];MediaPlaybackAddAccessLogFields(fields,self.observedItem);if(state==AVPlayerTimeControlStatusPlaying)[RuntimeDiagnostics.shared recordEvent:@"player_reports_playing" category:@"playback" fields:fields];else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){fields[@"wait_reason"]=self.player.reasonForWaitingToPlay?:@"unknown";[RuntimeDiagnostics.shared recordEvent:@"player_waiting_to_play" category:@"playback" fields:fields];}}if(self.resolving)return;if(state==AVPlayerTimeControlStatusPlaying){if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · AVPlayer 正在播放";[self.spinner stopAnimating];}else if(self.hasVideoTrack){self.status.text=@"AVPlayer 正在播放 · 等待视频首帧";[self.spinner startAnimating];}else{self.status.text=@"播放器报告播放中 · 视频画面未确认";[self.spinner stopAnimating];}}else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){self.status.text=@"正在缓冲 · 等待 AVPlayer";[self.spinner startAnimating];}else if(self.player.currentItem.status==AVPlayerItemStatusReadyToPlay){self.status.text=self.videoFrameReady?@"视频首帧已就绪 · 当前已暂停":(self.hasVideoTrack?@"媒体已准备 · 当前已暂停，等待视频首帧":@"媒体已准备 · 当前暂停");if(!self.videoFrameReady)[self.spinner stopAnimating];}self.status.accessibilityLabel=self.status.text;});return;}
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)playerItemStalled:(NSNotification *)notification {
    if(!NSThread.isMainThread){NSNotification *note=notification;dispatch_async(dispatch_get_main_queue(),^{[self playerItemStalled:note];});return;}
    AVPlayerItem *item=notification.object;if(item!=self.observedItem||item!=self.player.currentItem)return;
    self.diagnosticStallCount++;
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
    if(autoNext&&self.episodeIndex+1<self.episodes.count){NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"auto_advance";[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;
}
#pragma mark - MediaPlaybackCicadaAdapterDelegate
- (void)cicadaAdapterDidPrepare:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
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
    if(autoNext&&self.episodeIndex+1<self.episodes.count){NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;self.pendingResolutionReason=@"auto_advance";[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;
}
- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    if(adapter!=self.cicadaAdapter)return;
    self.cicadaPosition=position;self.cicadaDuration=duration;
    // 进度采样 + 里程碑（移植自直连路径 updateCicadaPosition:）：供诊断确认
    // “确实在播”，并驱动断点续播持久化与跳过按钮。
    BOOL playing=self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying&&self.videoFrameReady;
    HostPlaybackProgressSample(&self->_progressEvidence,CACurrentMediaTime(),position,self.cicadaAdapter.rate,playing);
    NSUInteger milestone=self->_progressEvidence.observed>=30?30:(self->_progressEvidence.observed>=5?5:0);
    if(milestone>self.progressMilestone){self.progressMilestone=milestone;[RuntimeDiagnostics.shared recordEvent:@"playback_progress_confirmed" category:@"playback" fields:@{@"playback_attempt_id":self.playbackAttemptID?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"observed_playing_seconds":@(self->_progressEvidence.observed),@"progress_samples":@(self->_progressEvidence.samples),@"milestone_seconds":@(milestone)}];}
    if(position-self.lastPersistedPosition>=10.0)[self persistPlaybackProgress];
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
    if(loading){self.status.text=@"正在缓冲 · 等待 CicadaPlayer";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];}
    else if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;[self.spinner stopAnimating];}
}
- (void)cicadaAdapterDidSeek:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    [self updateSkipButtonForCurrentPosition];
}
- (void)playerItemFailed:(NSNotification *)notification {if(!NSThread.isMainThread){NSNotification *note=notification;dispatch_async(dispatch_get_main_queue(),^{[self playerItemFailed:note];});return;}if(notification.object!=self.observedItem||notification.object!=self.player.currentItem)return;NSError *error=notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]?:self.observedItem.error;[self recordPlaybackFailureForItem:self.observedItem error:error stage:@"failed_to_play_to_end"]; }
- (void)retryCurrentEpisode {
    [RuntimeDiagnostics.shared recordEvent:@"playback_retry_requested" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"retry_source":@"user_action",@"had_resolved_result":@(self.result!=nil),@"had_media_address":@([self.result[@"url"] isKindOfClass:NSString.class]&&[self.result[@"url"] length]>0)}];
    [self persistPlaybackProgress];self.stallRecoveryAttempts=0;[self resetAutomaticFallbackLines];self.pendingResolutionReason=@"manual_retry";[self resolveAndPlay];
}
- (void)tryNativePlayback {
    if(!self.awaitingWebPlaybackReturn||![self.result[@"url"] isKindOfClass:NSString.class])return;
    NSMutableDictionary *candidate=[self.result mutableCopy];candidate[@"parse"]=@0;candidate[@"jx"]=@0;candidate[@"requiresWebPlayback"]=@NO;
    [RuntimeDiagnostics.shared recordEvent:@"playback_method_fallback_selected" category:@"playback" fields:@{@"method":@"avplayer",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"correlation_id":self.diagnosticTraceID?:@""}];
    self.awaitingWebPlaybackReturn=NO;[self playResult:candidate];
}
- (void)selectLine:(UIButton *)sender {
    if(sender.tag<0||sender.tag>=self.lines.count||sender.tag==self.lineIndex)return;
    NSInteger previousLine=self.lineIndex;NSArray *oldEpisodes=self.episodes;NSDictionary *oldEpisode=self.episodeIndex>=0&&self.episodeIndex<oldEpisodes.count?oldEpisodes[self.episodeIndex]:nil;NSString *oldID=[oldEpisode[@"id"] description]?:@"",*oldName=[[oldEpisode[@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";NSInteger oldIndex=self.episodeIndex;
    [self persistPlaybackProgress];self.lineIndex=sender.tag;NSArray *newEpisodes=self.episodes;NSInteger matched=-1;
    for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *candidate=newEpisodes[index];if(oldID.length&&[[candidate[@"id"] description] isEqual:oldID]){matched=index;break;}}
    if(matched<0&&oldName.length)for(NSUInteger index=0;index<newEpisodes.count;index++){NSString *name=[[newEpisodes[index][@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if([name localizedCaseInsensitiveCompare:oldName]==NSOrderedSame){matched=index;break;}}
    BOOL exactMatch=matched>=0;NSTimeInterval current=[self activeEngineCurrentPosition];BOOL wasPlaying=[self isCicadaEngineActive]?self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying:self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;if(exactMatch&&isfinite(current)&&current>=0){self.pendingQualitySeekTime=@(MAX(0,current));self.pendingQualityWasPlaying=wasPlaying;self.pendingQualityRestorePlaybackState=YES;}else{self.pendingQualitySeekTime=nil;self.pendingQualityRestorePlaybackState=NO;}if(!exactMatch)matched=newEpisodes.count?MIN(oldIndex,(NSInteger)newEpisodes.count-1):0;self.episodeIndex=matched;[self resetAutomaticFallbackLines];
    [RuntimeDiagnostics.shared recordEvent:@"playback_line_selected" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"from_line_index":@(previousLine),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"line_count":@(self.lines.count),@"episode_count":@(newEpisodes.count),@"episode_matched":@(exactMatch),@"position_preserved":@(exactMatch&&self.pendingQualitySeekTime!=nil),@"was_playing":@(wasPlaying),@"selection_source":@"player_ui"}];
    self.stallRecoveryAttempts=0;self.pendingResolutionReason=@"line_switch";[self buildLines];[self updateEpisodeTitle];if(!exactMatch&&newEpisodes.count)self.status.text=@"线路已切换 · 未能按名称确认分集，已按集数位置选择";[self resolveAndPlay];
}
- (void)resetAutomaticFallbackLines {
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
    for(NSUInteger offset=1;offset<alternates.count;offset++){
        NSUInteger candidateIndex=((NSUInteger)currentAlt+offset)%alternates.count;
        if([self.automaticFallbackTriedAlternateIndexes containsIndex:candidateIndex])continue;
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
        for(NSString *key in @[@"format",@"mediaType",@"playbackType",@"contentType",@"content_type",@"mimeType",@"mime",@"playbackEngine",@"nativePlayable",@"directMedia",@"requiresWebPlayback",@"parse",@"jx"]){[selected removeObjectForKey:key];if(alternate[key]!=nil)selected[key]=alternate[key];}
        NSString *candidateName=[alternate[@"name"] isKindOfClass:NSString.class]&&[alternate[@"name"] length]?alternate[@"name"]:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)candidateIndex+1];
        [RuntimeDiagnostics.shared recordEvent:@"playback_auto_alternate_fallback" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"from_alternate_index":@(currentAlt),@"alternate_index":@(candidateIndex),@"alternate_count":@(alternates.count),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"reason":reason?:@"automatic_compatibility"}];
        self.status.text=[NSString stringWithFormat:@"当前档位未就绪 · 正在尝试切换至 %@",candidateName];
        self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];
        self.attemptedRoutes=0;[self playResult:selected];
        return YES;
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
            if(MediaPlaybackEpisodeNamesMatch(candidateName,episodeName)){candidateEpisode=(NSInteger)index;break;}
        }
        BOOL episodeMatched=candidateEpisode>=0;
        if(candidateEpisode<0&&!episodeID.length&&!episodeName.length&&candidateEpisodes.count==previousEpisodes.count&&previousEpisode>=0&&previousEpisode<candidateEpisodes.count)candidateEpisode=previousEpisode;
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
    self.result=nil;self.basePlaybackHeaders=nil;self.selectedAlternateIndex=-1;self.automaticFallbackTriedAlternateIndexes=[NSMutableIndexSet indexSet];
    [self buildQualityButtons];[self setRetryAvailable:NO];[self clearCurrentPlayerItem];
    [self.spinner startAnimating];self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];
    self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@"",@"parserID":MediaPlaybackSelectedParserID(self.context)} mutableCopy];
    NSString *provider=self.context[@"provider"];if(provider.length)args[@"provider"]=provider;
    __weak typeof(self) weakSelf=self;
    [self.client cancel];
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaPlaybackViewController *owner=weakSelf;if(!owner)return;
        if(generation!=owner.generation){
            [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_response_discarded" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
                @"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":@"superseded_selection"}];
            return;
        }
        owner.resolving=NO;[owner.spinner stopAnimating];
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
            if(!owner.episodeWebFallbackAvailable&&[owner tryNextLineForAutomaticFallback:@"episode_resolve_failed"])return;
            owner.status.text=owner.episodeWebFallbackAvailable?@"来源未解析出媒体地址 · 可点右上角“网页尝试”打开分集页":(error.localizedDescription?:@"来源没有返回可播放结果");
            owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];
            return;
        }
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{
            @"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.context[@"source"][@"id"]?:@"",
            @"provider_id":owner.context[@"provider"]?:@"",@"line_index":@(owner.lineIndex),
            @"episode_index":@(owner.episodeIndex),@"request_generation":@(generation),
            @"result_has_media_url":@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0),
            @"result_parse_mode":@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0),
            @"result_alternate_count":@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0)}];
        owner.status.text=@"";[owner playResult:result];
    }];
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
    HostStylePillButton(self.playbackSpeedButton,NO);MediaPlaybackApplyScaledPillFont(self.playbackSpeedButton);
    HostStylePillButton(self.skipButton,YES);MediaPlaybackApplyScaledPillFont(self.skipButton);
    HostStylePillButton(self.inlineRetryButton,YES);MediaPlaybackApplyScaledPillFont(self.inlineRetryButton);
    HostStylePillButton(self.inlineWebButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineWebButton);
    HostStylePillButton(self.inlineOptionsButton,NO);MediaPlaybackApplyScaledPillFont(self.inlineOptionsButton);
    [self buildLines];
    [self buildQualityButtons];
}
@end
