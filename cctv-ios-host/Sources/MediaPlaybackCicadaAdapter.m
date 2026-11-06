// MediaPlaybackCicadaAdapter.m
//
// 实现说明与证据链：
//   1) SDK 符号一律运行时查找（NSClassFromString + respondsToSelector +
//      objc_msgSend），本文件不得出现 CicadaSDK.h 的 import 与任何
//      CicadaPlayer / CicadaConfig / CicadaUrlSource 类型引用——ui-smoke
//      构建不链接 CicadaPlayerSDK，且无 -Wl,-undefined,dynamic_lookup，
//      直接引用会在链接期失败。Tests/test_decode_router.py 会断言这一点。
//   2) 以下 API 在 CicadaPlayerSDK 二进制符号中已确认存在：
//      setConfig: / setUrlSource: / setPlayerView: / setDelegate: /
//      setEnableHardwareDecoder: / prepare / start / pause / stop / destroy /
//      reset / seekToTime:seekMode: / setRate: / getDuration / duration /
//      currentPosition / setAutoPlay: / setScalingMode: / setVolume: /
//      CicadaConfig 的 setNetworkTimeout: / setNetworkRetryCount: /
//      setHttpHeaders: / setUserAgent: / setReferer: /
//      CicadaUrlSource 的 +urlWithString:。
//   3) Delegate 回调：以下 5 个 selector 在二进制中以字符串形式确认：
//      onError:errorModel:、onCurrentPositionUpdate:position:、
//      onLoadingProgress:progress:、onPlayerStatusChanged:oldStatus:newStatus:、
//      onVideoSizeChanged:width:height:rotation:。
//      其余 6 个（onPrepared:、onFirstFrameShow:、onCompletion:、
//      onLoadingStart:、onLoadingEnd:、onSeekEnd:）只在 C++ 层
//      （CicadaOCHelper）中确认，ObjC selector 拼写未在二进制中直接确认，
//      故实现为 best-effort，并用 1 秒位置轮询兜底：位置推进即视为首帧已出，
//      位置到达时长末尾即视为播放完成。回调缺失时绝不静默黑屏。
//      onCurrentDownLoadSpeed:progress: 按 CicadaSDK.h 的声明实现
//      （float speed，单位 bit/s），二进制中未直接确认，属 best-effort；
//      onVideoSizeChanged 的宽高/旋转按头文件声明的 int 读取。
//   4) 时长/位置单位：CicadaPlayer 的 duration / currentPosition 按秒计；
//      为防个别构建返回毫秒，>360000 的值按毫秒折算（见归一化函数）。
//      网络超时单位：CicadaConfig.networkTimeout 按毫秒计（仓库内证据：
//      直连路径传 15000，Tests/native_buffer_tests.m 里 networkTimeout=
//      15000 与 500/3000/20000 毫秒级缓冲时长并列）。公开 API 的
//      networkTimeout 参数仍按秒收，prepare 里 ×1000 再传给 SDK。
//   5) seekMode 传 CICADA_SEEKMODE_ACCURATE（0x01，见 CicadaSDK.h）、
//      scalingMode 按 CicadaScalingMode 枚举（0=SCALETOFILL、
//      1=SCALEASPECTFIT、2=SCALEASPECTFILL，见 CicadaSDK.h）；
//      二进制中未直接确认，需真机验证。
//   6) CNPlayer 的 startPlayerSDK 已在 App 启动时调用（RootViewController
//      1617 行附近），Cicada 内核随之初始化；本适配器不再重复初始化。
#import "MediaPlaybackCicadaAdapter.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const MediaPlaybackCicadaAdapterErrorDomain = @"MediaPlaybackCicadaAdapterErrorDomain";

static const NSTimeInterval MediaPlaybackCicadaFirstFrameTimeout = 20.0;
static const NSTimeInterval MediaPlaybackCicadaPositionPollInterval = 1.0;
static const NSTimeInterval MediaPlaybackCicadaPreparedFallbackDelay = 0.5;
static const NSTimeInterval MediaPlaybackCicadaSeekCallbackTimeout = 3.0;

// ---------- 运行时调用小工具（全部先 respondsToSelector，再 @try） ----------

static Class MediaPlaybackCicadaClass(NSString *name) {
    return NSClassFromString(name);
}

static void CicadaCallVoid(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) {}
}

static void CicadaCallVoidObject(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg); } @catch (NSException *e) {}
}

static void CicadaCallVoidBool(id target, SEL sel, BOOL arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, arg); } @catch (NSException *e) {}
}

static void CicadaCallVoidDouble(id target, SEL sel, double arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, double))objc_msgSend)(target, sel, arg); } @catch (NSException *e) {}
}

static void CicadaCallVoidInt(id target, SEL sel, int arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, int))objc_msgSend)(target, sel, arg); } @catch (NSException *e) {}
}

static void CicadaCallVoidDoubleLong(id target, SEL sel, double first, long second) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, double, long))objc_msgSend)(target, sel, first, second); } @catch (NSException *e) {}
}

static double CicadaCallDouble(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return 0;
    @try { return ((double (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) { return 0; }
}

static NSTimeInterval MediaPlaybackCicadaNormalizeTimeValue(id value) {
    double seconds = 0;
    if ([value respondsToSelector:@selector(doubleValue)]) seconds = [value doubleValue];
    if (!isfinite(seconds) || seconds < 0) return 0;
    // 个别构建返回毫秒：超过 100 小时的一律按毫秒折算。
    if (seconds > 360000) seconds /= 1000.0;
    return seconds;
}

static NSString *MediaPlaybackCicadaStringFromModel(id model, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        SEL sel = NSSelectorFromString(key);
        if (![model respondsToSelector:sel]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(model, sel);
            if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSInteger MediaPlaybackCicadaCodeFromModel(id model) {
    for (NSString *key in @[@"errorCode", @"code", @"error_code"]) {
        SEL sel = NSSelectorFromString(key);
        if (![model respondsToSelector:sel]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(model, sel);
            if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
        } @catch (NSException *e) {}
    }
    return -1;
}

@interface MediaPlaybackCicadaAdapter ()
// state 对外只读，内部可写（公开头文件里是 readonly）。
@property (nonatomic, readwrite) MediaPlaybackCicadaAdapterState state;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic) NSTimeInterval networkTimeout;
@property (nonatomic, strong, nullable) id player;
@property (nonatomic, strong, nullable) id config;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *firstFrameWatchdog;
@property (nonatomic, strong, nullable) NSTimer *preparedFallbackTimer;
@property (nonatomic, strong, nullable) NSTimer *seekTimeoutTimer;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL preparedReported;
@property (nonatomic) BOOL firstFrameReported;
@property (nonatomic) BOOL completedReported;
@property (nonatomic) BOOL startRequested;
@property (nonatomic) BOOL loading;
@property (nonatomic) float pendingRate;
@property (nonatomic) BOOL hasPendingRate;
@property (nonatomic, copy, nullable) void (^pendingSeekCompletion)(BOOL finished);
@property (nonatomic) NSTimeInterval lastPolledPosition;
@property (nonatomic) BOOL destroyed;
@property (nonatomic) BOOL enableHardwareDecoder;
@end

@implementation MediaPlaybackCicadaAdapter

+ (BOOL)isAvailable {
    return MediaPlaybackCicadaClass(@"CicadaPlayer") != nil;
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers networkTimeout:(NSTimeInterval)timeoutSeconds {
    if (self = [super init]) {
        _url = url;
        _headers = [headers copy];
        _networkTimeout = MIN(40, MAX(5, timeoutSeconds > 0 ? timeoutSeconds : 20));
        _playerView = [UIView new];
        _playerView.backgroundColor = UIColor.blackColor;
        _playerView.clipsToBounds = YES;
        _state = MediaPlaybackCicadaAdapterStateIdle;
        _pendingRate = 1.0f;
    }
    return self;
}

- (void)dealloc {
    [self destroy];
}

// ---------- 生命周期 ----------

- (void)prepare {
    [self prepareWithHardwareDecoder:YES];
}

- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder {
    if (self.destroyed || self.player) return;
    self.enableHardwareDecoder = enableHardwareDecoder;
    Class playerClass = MediaPlaybackCicadaClass(@"CicadaPlayer");
    Class configClass = MediaPlaybackCicadaClass(@"CicadaConfig");
    Class sourceClass = MediaPlaybackCicadaClass(@"CicadaUrlSource");
    if (!playerClass || !configClass || !sourceClass) {
        [self reportErrorWithCode:-1002 message:@"当前构建未包含 CicadaPlayer，无法使用 ffmpeg 回退"];
        return;
    }
    id player = nil;
    @try { player = [[playerClass alloc] init]; } @catch (NSException *e) { player = nil; }
    if (!player) {
        [self reportErrorWithCode:-1002 message:@"创建 CicadaPlayer 失败"];
        return;
    }
    self.player = player;
    self.generation++;
    self.state = MediaPlaybackCicadaAdapterStatePreparing;

    // 配置：网络超时读设置（调用方传入，已钳制 5–40 秒）；重试 2 次；
    // 请求头 / UA / Referer 由播放结果带入（猫源常需 Referer 才能出流）。
    // 注意：CicadaConfig.networkTimeout 单位是毫秒，公开 API 的秒数要 ×1000。
    id config = nil;
    @try { config = [[configClass alloc] init]; } @catch (NSException *e) { config = nil; }
    self.config = config;
    if (config) {
        CicadaCallVoidInt(config, NSSelectorFromString(@"setNetworkTimeout:"), (int)llround(self.networkTimeout * 1000.0));
        CicadaCallVoidInt(config, NSSelectorFromString(@"setNetworkRetryCount:"), 2);
        if (self.headers.count) {
            CicadaCallVoidObject(config, NSSelectorFromString(@"setHttpHeaders:"), self.headers);
            NSString *userAgent = self.headers[@"User-Agent"] ?: self.headers[@"user-agent"];
            NSString *referer = self.headers[@"Referer"] ?: self.headers[@"referer"];
            if (userAgent.length) CicadaCallVoidObject(config, NSSelectorFromString(@"setUserAgent:"), userAgent);
            if (referer.length) CicadaCallVoidObject(config, NSSelectorFromString(@"setReferer:"), referer);
        }
        CicadaCallVoidObject(player, NSSelectorFromString(@"setConfig:"), config);
    }
    CicadaCallVoidBool(player, NSSelectorFromString(@"setEnableHardwareDecoder:"), self.enableHardwareDecoder);
    CicadaCallVoidBool(player, NSSelectorFromString(@"setAutoPlay:"), NO);
    id source = nil;
    @try {
        if ([sourceClass respondsToSelector:NSSelectorFromString(@"urlWithString:")]) {
            source = ((id (*)(id, SEL, id))objc_msgSend)(sourceClass, NSSelectorFromString(@"urlWithString:"), self.url.absoluteString);
        }
    } @catch (NSException *e) { source = nil; }
    if (!source) {
        [self reportErrorWithCode:-1002 message:@"创建播放地址失败"];
        return;
    }
    CicadaCallVoidObject(player, NSSelectorFromString(@"setUrlSource:"), source);
    CicadaCallVoidObject(player, NSSelectorFromString(@"setPlayerView:"), self.playerView);
    CicadaCallVoidObject(player, NSSelectorFromString(@"setDelegate:"), self);
    CicadaCallVoid(player, NSSelectorFromString(@"prepare"));

    // 首帧看门狗：20 秒内无首帧即报错，交给路由走下一路（WebView）。
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = self.generation;
    self.firstFrameWatchdog = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackCicadaFirstFrameTimeout repeats:NO block:^(NSTimer *timer) {
        MediaPlaybackCicadaAdapter *owner = weakSelf;
        if (!owner || generation != owner.generation || owner.destroyed) return;
        if (owner.firstFrameReported || owner.state == MediaPlaybackCicadaAdapterStateFailed || owner.state == MediaPlaybackCicadaAdapterStateCompleted) return;
        [owner reportErrorWithCode:-1001 message:@"CicadaPlayer 20 秒内未显示首帧"];
    }];
    // onPrepared 回调的 selector 拼写未在二进制中直接确认：0.5 秒后无论是否收到
    // 回调都按已准备处理，保证起播不会因回调缺失而卡住。
    self.preparedFallbackTimer = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackCicadaPreparedFallbackDelay repeats:NO block:^(NSTimer *timer) {
        MediaPlaybackCicadaAdapter *owner = weakSelf;
        if (!owner || generation != owner.generation || owner.destroyed) return;
        [owner handlePrepared];
    }];
    [self startPollTimer];
}

- (void)start {
    if (self.destroyed || !self.player) return;
    if (!self.preparedReported) {
        // 尚未准备好：先记下，准备就绪（回调或 0.5 秒兜底）后自动起播。
        self.startRequested = YES;
        return;
    }
    self.startRequested = NO;
    CicadaCallVoid(self.player, NSSelectorFromString(@"start"));
    if (self.hasPendingRate) [self applyPendingRate];
    if (self.state != MediaPlaybackCicadaAdapterStateFailed && self.state != MediaPlaybackCicadaAdapterStateCompleted) {
        self.state = MediaPlaybackCicadaAdapterStatePlaying;
    }
}

- (void)pause {
    if (self.destroyed || !self.player) return;
    CicadaCallVoid(self.player, NSSelectorFromString(@"pause"));
    if (self.state == MediaPlaybackCicadaAdapterStatePlaying) self.state = MediaPlaybackCicadaAdapterStatePaused;
}

- (void)stop {
    if (self.destroyed || !self.player) return;
    self.startRequested = NO;
    CicadaCallVoid(self.player, NSSelectorFromString(@"stop"));
    if (self.state != MediaPlaybackCicadaAdapterStateFailed) self.state = MediaPlaybackCicadaAdapterStateIdle;
}

- (void)destroy {
    if (self.destroyed && !self.player) return;
    self.destroyed = YES;
    self.generation++;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    [self.preparedFallbackTimer invalidate]; self.preparedFallbackTimer = nil;
    [self.seekTimeoutTimer invalidate]; self.seekTimeoutTimer = nil;
    self.pendingSeekCompletion = nil;
    id player = self.player;
    self.player = nil;
    self.config = nil;
    if (player) {
        // 先摘 delegate 再停，避免拆解过程中的回调落到已释放的适配器。
        CicadaCallVoidObject(player, NSSelectorFromString(@"setDelegate:"), nil);
        CicadaCallVoid(player, NSSelectorFromString(@"stop"));
        CicadaCallVoid(player, NSSelectorFromString(@"destroy"));
    }
    self.state = MediaPlaybackCicadaAdapterStateIdle;
}

// ---------- 控制 ----------

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL))completion {
    if (self.destroyed || !self.player) {
        if (completion) completion(NO);
        return;
    }
    self.pendingSeekCompletion = completion;
    // CICADA_SEEKMODE_ACCURATE（0x01，见 CicadaSDK.h）：直连路径同值。
    CicadaCallVoidDoubleLong(self.player, NSSelectorFromString(@"seekToTime:seekMode:"), MAX(0, time), 0x01);
    // onSeekEnd 回调的 selector 拼写未在二进制中直接确认：3 秒后无论是否收到
    // 回调都按完成处理，避免调用方永久等待。
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = self.generation;
    [self.seekTimeoutTimer invalidate];
    self.seekTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackCicadaSeekCallbackTimeout repeats:NO block:^(NSTimer *timer) {
        MediaPlaybackCicadaAdapter *owner = weakSelf;
        if (!owner || generation != owner.generation || owner.destroyed) return;
        [owner finishPendingSeekWithFinished:NO];
    }];
}

- (void)setRate:(float)rate {
    // 上限 3.0：长按手势请求 3.0x（见 VC handlePlaybackLongPress:），
    // 旧钳制 2.0 会把它静默截断；设置菜单的持久倍速仍由调用方钳制在 2.0。
    self.pendingRate = MIN(3.0f, MAX(0.5f, rate));
    self.hasPendingRate = YES;
    [self applyPendingRate];
}

- (float)rate {
    return self.pendingRate;
}

- (void)applyPendingRate {
    if (!self.player || !self.hasPendingRate) return;
    CicadaCallVoidDouble(self.player, NSSelectorFromString(@"setRate:"), (double)self.pendingRate);
}

- (void)applyVideoGravity:(NSString *)gravity {
    if (!self.player) return;
    // CicadaScalingMode（见 CicadaSDK.h）：0=SCALETOFILL、1=SCALEASPECTFIT、
    // 2=SCALEASPECTFILL。旧映射把 ResizeAspect 错写成 0、Resize 错写成 2，
    // 与直连路径用的命名常量正好颠倒。
    int mode = 1;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) mode = 2;
    else if ([gravity isEqualToString:AVLayerVideoGravityResize]) mode = 0;
    CicadaCallVoidInt(self.player, NSSelectorFromString(@"setScalingMode:"), mode);
}

// ---------- 位置 / 时长（轮询 + 回调双通道） ----------

- (NSTimeInterval)currentPosition {
    if (!self.player) return 0;
    NSTimeInterval position = CicadaCallDouble(self.player, NSSelectorFromString(@"currentPosition"));
    return MediaPlaybackCicadaNormalizeTimeValue(@(position));
}

- (NSTimeInterval)duration {
    if (!self.player) return 0;
    NSTimeInterval duration = CicadaCallDouble(self.player, NSSelectorFromString(@"duration"));
    if (duration <= 0) duration = CicadaCallDouble(self.player, NSSelectorFromString(@"getDuration"));
    return MediaPlaybackCicadaNormalizeTimeValue(@(duration));
}

- (void)startPollTimer {
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = self.generation;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackCicadaPositionPollInterval repeats:YES block:^(NSTimer *timer) {
        MediaPlaybackCicadaAdapter *owner = weakSelf;
        if (!owner || generation != owner.generation || owner.destroyed || !owner.player) return;
        NSTimeInterval position = owner.currentPosition;
        NSTimeInterval duration = owner.duration;
        owner.lastPolledPosition = position;
        if ([owner.delegate respondsToSelector:@selector(cicadaAdapter:didUpdatePosition:duration:)]) {
            [owner.delegate cicadaAdapter:owner didUpdatePosition:position duration:duration];
        }
        // 首帧兜底：位置推进即视为画面已出（onFirstFrameShow 未到时也生效）。
        if (!owner.firstFrameReported && position > 0.5) [owner handleFirstFrame];
        // 完成兜底：位置到达时长末尾即视为播完（onCompletion 未到时也生效）。
        if (!owner.completedReported && duration > 0 && position >= duration - 1.0) [owner handleCompletion];
    }];
}

// ---------- 内部状态机（主线程） ----------

- (void)handlePrepared {
    if (self.preparedReported || self.destroyed) return;
    self.preparedReported = YES;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidPrepare:)]) {
        [self.delegate cicadaAdapterDidPrepare:self];
    }
    if (self.startRequested) [self start];
}

- (void)handleFirstFrame {
    if (self.firstFrameReported || self.destroyed) return;
    self.firstFrameReported = YES;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidShowFirstFrame:)]) {
        [self.delegate cicadaAdapterDidShowFirstFrame:self];
    }
}

- (void)handleCompletion {
    if (self.completedReported || self.destroyed) return;
    self.completedReported = YES;
    self.state = MediaPlaybackCicadaAdapterStateCompleted;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidComplete:)]) {
        [self.delegate cicadaAdapterDidComplete:self];
    }
}

- (void)finishPendingSeekWithFinished:(BOOL)finished {
    [self.seekTimeoutTimer invalidate]; self.seekTimeoutTimer = nil;
    void (^completion)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    if (completion) completion(finished);
    if (finished && [self.delegate respondsToSelector:@selector(cicadaAdapterDidSeek:)]) {
        [self.delegate cicadaAdapterDidSeek:self];
    }
}

- (void)reportErrorWithCode:(NSInteger)code message:(NSString *)message {
    if (self.destroyed || self.state == MediaPlaybackCicadaAdapterStateFailed) return;
    self.state = MediaPlaybackCicadaAdapterStateFailed;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    NSError *error = [NSError errorWithDomain:MediaPlaybackCicadaAdapterErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message ?: @"CicadaPlayer 播放失败",
                                                @"extension": self.url.pathExtension.lowercaseString ?: @""}];
    if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didFailWithError:)]) {
        [self.delegate cicadaAdapter:self didFailWithError:error];
    }
}

// ---------- SDK Delegate 回调 ----------
//
// 以下 5 个 selector 在 CicadaPlayerSDK 二进制中以字符串形式确认；
// 其余 6 个只在 C++ 层（CicadaOCHelper）确认，拼写为 best-effort。
// SDK 可能在非主线程回调，一律先切主线程、再按 generation 过滤。

- (void)onError:(id)player errorModel:(id)errorModel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        NSInteger code = MediaPlaybackCicadaCodeFromModel(errorModel);
        NSString *message = MediaPlaybackCicadaStringFromModel(errorModel, @[@"errorMsg", @"message", @"localizedDescription"]);
        [self reportErrorWithCode:code message:message ?: @"CicadaPlayer 播放失败"];
    });
}

- (void)onCurrentPositionUpdate:(id)player position:(id)position {
    // 注意：position 参数的类型（NSNumber 还是原始 double）无法从二进制确认；
    // 这里不读它，改走轮询读到的 currentPosition，避免类型猜错导致崩溃。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        NSTimeInterval seconds = self.currentPosition;
        self.lastPolledPosition = seconds;
        if (!self.firstFrameReported && seconds > 0.5) [self handleFirstFrame];
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdatePosition:duration:)]) {
            [self.delegate cicadaAdapter:self didUpdatePosition:seconds duration:self.duration];
        }
    });
}

- (void)onLoadingProgress:(id)player progress:(id)progress {
    // progress 参数类型未确认，不读它；只上报“正在缓冲”。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:YES progress:0];
        }
    });
}

- (void)onPlayerStatusChanged:(id)player oldStatus:(id)oldStatus newStatus:(id)newStatus {
    // 状态值未确认，不读参数；缓冲提示由 onLoadingStart/End 覆盖，
    // 播放/暂停由调用方显式控制。这里只作代收点，不产生状态上报。
}

- (void)onCurrentDownLoadSpeed:(id)player progress:(float)speed {
    // Best-effort 回调（见文件头注释 3）：speed 单位 bit/s（CicadaSDK.h
    // 声明为 float；直连路径同样按 float 读，并除以 8 得字节/秒）。
    // 适配器此前未实现它——SDK 若无 respondsToSelector 守卫就调用，
    // 会因 unrecognized selector 崩溃；现在实现并转发给调用方更新测速。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateDownloadSpeed:)]) {
            [self.delegate cicadaAdapter:self didUpdateDownloadSpeed:MAX(0, (double)speed)];
        }
    });
}

- (void)onVideoSizeChanged:(id)player width:(int)width height:(int)height rotation:(int)rotation {
    // 宽高/旋转按 CicadaSDK.h 声明的 int 读取（此前声明为 id 且不读参数，
    // 调用方拿不到尺寸，无法更新画面比例）；SDK 上报尺寸变化本身即证明有视频轨。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        _hasVideoTrack = YES;
        if (!self.firstFrameReported) [self handleFirstFrame];
        if (width > 0 && height > 0 && [self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateVideoSize:rotation:)]) {
            [self.delegate cicadaAdapter:self didUpdateVideoSize:CGSizeMake(width, height) rotation:rotation];
        }
    });
}

// Best-effort 回调（selector 拼写未在二进制中直接确认，见文件头注释）。
- (void)onPrepared:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.destroyed) [self handlePrepared];
    });
}

- (void)onFirstFrameShow:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.destroyed) [self handleFirstFrame];
    });
}

- (void)onCompletion:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.destroyed) [self handleCompletion];
    });
}

- (void)onLoadingStart:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        self.loading = YES;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:YES progress:0];
        }
    });
}

- (void)onLoadingEnd:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        self.loading = NO;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:NO progress:1.0f];
        }
    });
}

- (void)onSeekEnd:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.destroyed) [self finishPendingSeekWithFinished:YES];
    });
}

@end
