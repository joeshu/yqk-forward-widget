#import <QuartzCore/QuartzCore.h>
#import <limits.h>
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
//      CicadaUrlSource 的 -init / -urlWithString: / -setPlayerUrl:。
//   3) Delegate 回调：以下 6 个 selector 在二进制中以字符串形式确认：
//      onPlayerEvent:eventType:、onError:errorModel:、
//      onCurrentPositionUpdate:position:、onLoadingProgress:progress:、
//      onPlayerStatusChanged:oldStatus:newStatus:、
//      onVideoSizeChanged:width:height:rotation:。
//      其余 6 个（onPrepared:、onFirstFrameShow:、onCompletion:、
//      onLoadingStart:、onLoadingEnd:、onSeekEnd:）只在 C++ 层
//      （CicadaOCHelper）中确认，ObjC selector 拼写未在二进制中直接确认，
//      故实现为 best-effort。首帧只接受真实渲染事件；位置轮询仅补充
//      进度与到达末尾的完成判定，避免音频进度被误认成视频画面。
//      onCurrentDownLoadSpeed:progress: 按 CicadaSDK.h 的声明实现
//      （float speed，单位 bit/s），二进制中未直接确认，属 best-effort；
//      onVideoSizeChanged 的宽高/旋转按头文件声明的 int 读取。
//   4) 时长/位置单位：CicadaPlayerSDK 二进制属性编码为 Tq（int64_t 毫秒），
//      读取时通过 methodSignatureForSelector 自动识别整型返回值并折算为秒；
//      网络超时单位：CicadaConfig.networkTimeout 按毫秒计（仓库内证据：
//      直连路径传 15000，Tests/native_buffer_tests.m 里 networkTimeout=
//      15000 与 500/3000/20000 毫秒级缓冲时长并列）。公开 API 的
//      networkTimeout 参数仍按秒收，prepare 里 ×1000 再传给 SDK。
//   5) seekMode 传 CICADA_SEEKMODE_ACCURATE（0x01，见 CicadaSDK.h）、
//      scalingMode 按 CicadaScalingMode 枚举（0=SCALETOFILL、
//      1=SCALEASPECTFIT、2=SCALEASPECTFILL，见 CicadaSDK.h）。
//   6) CNPlayer 的 startPlayerSDK 已在 App 启动时调用（RootViewController
//      1617 行附近），Cicada 内核随之初始化；本适配器不再重复初始化。
#import "MediaPlaybackCicadaAdapter.h"
#import "MediaPlaybackBufferPolicy.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const MediaPlaybackCicadaAdapterErrorDomain = @"MediaPlaybackCicadaAdapterErrorDomain";

static const NSTimeInterval MediaPlaybackCicadaFirstFrameTimeout = 20.0;
static const NSTimeInterval MediaPlaybackCicadaPositionPollInterval = 0.4;
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
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *argType = (sig && sig.numberOfArguments > 2) ? [sig getArgumentTypeAtIndex:2] : NULL;
        if (argType && argType[0] == 'f') {
            ((void (*)(id, SEL, float))objc_msgSend)(target, sel, (float)arg);
            return;
        }
        ((void (*)(id, SEL, double))objc_msgSend)(target, sel, arg);
    } @catch (NSException *e) {}
}

static void CicadaCallVoidInt(id target, SEL sel, int arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *argType = (sig && sig.numberOfArguments > 2) ? [sig getArgumentTypeAtIndex:2] : NULL;
        while (argType && (argType[0] == 'r' || argType[0] == 'n' || argType[0] == 'N' || argType[0] == 'o' || argType[0] == 'O' || argType[0] == 'R' || argType[0] == 'V')) argType++;
        if (argType && (argType[0] == 'q' || argType[0] == 'Q' || argType[0] == 'l' || argType[0] == 'L')) {
            ((void (*)(id, SEL, int64_t))objc_msgSend)(target, sel, (int64_t)arg);
            return;
        }
        ((void (*)(id, SEL, int))objc_msgSend)(target, sel, arg);
    } @catch (NSException *e) {}
}

static void CicadaCallVoidDoubleLong(id target, SEL sel, double first, long second) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *argType = (sig && sig.numberOfArguments > 2) ? [sig getArgumentTypeAtIndex:2] : NULL;
        if (argType && (argType[0] == 'q' || argType[0] == 'Q' || argType[0] == 'l' || argType[0] == 'L')) {
            int64_t timeMs = (int64_t)llround(MAX(0.0, first) * 1000.0);
            ((void (*)(id, SEL, int64_t, NSUInteger))objc_msgSend)(target, sel, timeMs, (NSUInteger)second);
            return;
        }
        ((void (*)(id, SEL, double, long))objc_msgSend)(target, sel, first, second);
    } @catch (NSException *e) {}
}

static double CicadaCallDouble(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return 0;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        const char *retType = sig ? sig.methodReturnType : NULL;
        if (retType && (retType[0] == 'q' || retType[0] == 'Q' || retType[0] == 'l' || retType[0] == 'L')) {
            int64_t raw = ((int64_t (*)(id, SEL))objc_msgSend)(target, sel);
            return raw > 0 ? ((double)raw / 1000.0) : 0;
        }
        if (retType && (retType[0] == 'i' || retType[0] == 'I')) {
            int raw = ((int (*)(id, SEL))objc_msgSend)(target, sel);
            return raw > 0 ? ((double)raw / 1000.0) : 0;
        }
        if (retType && retType[0] == 'f') {
            return (double)((float (*)(id, SEL))objc_msgSend)(target, sel);
        }
        return ((double (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *e) { return 0; }
}

static NSTimeInterval MediaPlaybackCicadaNormalizeTimeValue(double seconds) {
    if (!isfinite(seconds) || seconds < 0) return 0;
    // Unit conversion belongs to CicadaCallDouble and the typed SDK callbacks.
    // Magnitude is not a unit: long-running live streams can exceed 100 hours.
    return seconds;
}

static NSString *MediaPlaybackCicadaStringFromModel(id model, NSArray<NSString *> *keys) {
    if (!model) return nil;
    if ([model isKindOfClass:NSDictionary.class]) {
        for (NSString *key in keys) {
            id value = [(NSDictionary *)model objectForKey:key];
            if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
        }
    }
    for (NSString *key in keys) {
        SEL sel = NSSelectorFromString(key);
        if (![model respondsToSelector:sel]) continue;
        @try {
            NSMethodSignature *sig = [model methodSignatureForSelector:sel];
            const char *retType = sig ? sig.methodReturnType : NULL;
            while (retType && (retType[0] == 'r' || retType[0] == 'n' || retType[0] == 'N' || retType[0] == 'o' || retType[0] == 'O' || retType[0] == 'R' || retType[0] == 'V')) retType++;
            if (!retType || retType[0] != '@') continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(model, sel);
            if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSInteger MediaPlaybackCicadaCodeFromModel(id model) {
    if (!model) return -1;
    if ([model isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"errorCode", @"code", @"error_code"]) {
            id value = [(NSDictionary *)model objectForKey:key];
            if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
        }
    }
    for (NSString *key in @[@"errorCode", @"code", @"error_code"]) {
        SEL sel = NSSelectorFromString(key);
        if (![model respondsToSelector:sel]) continue;
        @try {
            // CicadaErrorModel.code 在二进制中返回标量 Q (uint64_t, 如 0x20050001)，
            // 绝不可直接强转为 id 返回，否则 ARC 调用 objc_retainAutoreleasedReturnValue
            // 将错误码当作对象指针解引用，触发 libobjc.A.dylib offset=4724 SIGSEGV 崩溃。
            NSMethodSignature *sig = [model methodSignatureForSelector:sel];
            const char *retType = sig ? sig.methodReturnType : NULL;
            while (retType && (retType[0] == 'r' || retType[0] == 'n' || retType[0] == 'N' || retType[0] == 'o' || retType[0] == 'O' || retType[0] == 'R' || retType[0] == 'V')) retType++;
            if (!retType) continue;
            if (retType[0] == 'q' || retType[0] == 'Q' || retType[0] == 'l' || retType[0] == 'L') {
                return (NSInteger)((int64_t (*)(id, SEL))objc_msgSend)(model, sel);
            }
            if (retType[0] == 'i' || retType[0] == 'I' || retType[0] == 's' || retType[0] == 'S' || retType[0] == 'c' || retType[0] == 'C') {
                return (NSInteger)((int (*)(id, SEL))objc_msgSend)(model, sel);
            }
            if (retType[0] == '@') {
                id value = ((id (*)(id, SEL))objc_msgSend)(model, sel);
                if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
            }
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
@property (nonatomic, strong, nullable) NSTimer *seekTimeoutTimer;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL preparedReported;
@property (atomic) BOOL firstFrameReported;
@property (nonatomic) BOOL completedReported;
@property (nonatomic) BOOL startRequested;
@property (nonatomic, readwrite) BOOL loading;
@property (nonatomic) NSUInteger stallCount;
@property (nonatomic) NSTimeInterval bufferedTime;
@property (nonatomic) CFTimeInterval lastPositionEmission;
@property (nonatomic) BOOL playbackRequested;
@property (nonatomic) float pendingRate;
@property (nonatomic) BOOL hasPendingRate;
@property (nonatomic, copy, nullable) void (^pendingSeekCompletion)(BOOL finished);
@property (nonatomic) NSTimeInterval lastPolledPosition;
@property (nonatomic) BOOL destroyed;
@property (nonatomic) BOOL enableHardwareDecoder;
@property (nonatomic, copy) NSString *pendingVideoGravity;
@property(nonatomic) BOOL pendingMuted;
@property(nonatomic) NSTimeInterval firstFrameRemaining;
@property(nonatomic) CFTimeInterval firstFrameBudgetStarted;
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
        Class viewClass = MediaPlaybackCicadaClass(@"CicadaPlayerView") ?: UIView.class;
        _playerView = [[viewClass alloc] initWithFrame:CGRectZero];
        _playerView.backgroundColor = UIColor.blackColor;
        _playerView.clipsToBounds = YES;
        _state = MediaPlaybackCicadaAdapterStateIdle;
        _pendingRate = 1.0f;
        _pendingVideoGravity = AVLayerVideoGravityResizeAspect;
        _firstFrameRemaining=self.firstFrameTimeout;
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
        [self updateBufferConfiguration];
        if (self.headers.count) {
            NSMutableArray<NSString *> *headerLines = [NSMutableArray arrayWithCapacity:self.headers.count];
            for (NSString *key in self.headers) {
                NSString *value = [self.headers[key] description];
                if (key.length && value.length) {
                    [headerLines addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
                }
            }
            CicadaCallVoidObject(config, NSSelectorFromString(@"setHttpHeaders:"), headerLines);
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
        NSString *urlString = self.url.absoluteString;
        if (urlString.length) {
            id instance = [[sourceClass alloc] init];
            if (instance && [instance respondsToSelector:NSSelectorFromString(@"urlWithString:")]) {
                source = ((id (*)(id, SEL, id))objc_msgSend)(instance, NSSelectorFromString(@"urlWithString:"), urlString);
                if (!source) source = instance;
            } else if ([sourceClass respondsToSelector:NSSelectorFromString(@"urlWithString:")]) {
                source = ((id (*)(id, SEL, id))objc_msgSend)(sourceClass, NSSelectorFromString(@"urlWithString:"), urlString);
            } else if (instance && [instance respondsToSelector:NSSelectorFromString(@"setPlayerUrl:")]) {
                CicadaCallVoidObject(instance, NSSelectorFromString(@"setPlayerUrl:"), self.url);
                source = instance;
            }
        }
    } @catch (NSException *e) { source = nil; }
    if (!source) {
        [self reportErrorWithCode:-1002 message:@"创建播放地址失败"];
        return;
    }
    // Some SDK versions synchronously report errors while assigning the source.
    CicadaCallVoidObject(player, NSSelectorFromString(@"setDelegate:"), self);
    CicadaCallVoidObject(player, NSSelectorFromString(@"setUrlSource:"), source);
    CicadaCallVoidObject(player, NSSelectorFromString(@"setPlayerView:"), self.playerView);
    [self applyVideoGravity:self.pendingVideoGravity];[self setMuted:self.pendingMuted];
    CicadaCallVoid(player, NSSelectorFromString(@"prepare"));
}

- (void)armFirstFrameWatchdog {
    if(self.firstFrameWatchdog||self.firstFrameReported||self.destroyed)return;
    __weak typeof(self) weakSelf=self;NSUInteger generation=self.generation;
    self.firstFrameBudgetStarted=CACurrentMediaTime();
    self.firstFrameWatchdog=[NSTimer scheduledTimerWithTimeInterval:MAX(.01,self.firstFrameRemaining) repeats:NO block:^(NSTimer *timer){
        MediaPlaybackCicadaAdapter *owner=weakSelf;if(!owner||generation!=owner.generation||owner.destroyed)return;
        owner.firstFrameWatchdog=nil;owner.firstFrameRemaining=0;
        if(owner.playbackRequested&&!owner.firstFrameReported&&owner.state!=MediaPlaybackCicadaAdapterStateFailed&&owner.state!=MediaPlaybackCicadaAdapterStateCompleted)[owner reportErrorWithCode:-1001 message:[NSString stringWithFormat:@"CicadaPlayer %.0f 秒内未显示首帧",owner.firstFrameTimeout]];
    }];
}
- (NSTimeInterval)firstFrameTimeout {
    return MAX(MediaPlaybackCicadaFirstFrameTimeout, self.networkTimeout + 10.0);
}
- (void)updateBufferConfiguration {
    if(!self.config||!self.player)return;
    BOOL constrained=NSProcessInfo.processInfo.lowPowerModeEnabled;
    double steady=MediaPlaybackForwardBuffer(YES,YES,self.pendingRate,self.stallCount,constrained);
    int high=2500;
    if(self.stallCount)high=MIN(8000,high+(int)MIN(self.stallCount,(NSUInteger)3)*1000);
    CicadaCallVoidInt(self.config,NSSelectorFromString(@"setStartBufferDuration:"),300);
    CicadaCallVoidInt(self.config,NSSelectorFromString(@"setHighBufferDuration:"),high);
    CicadaCallVoidInt(self.config,NSSelectorFromString(@"setMaxBufferDuration:"),MAX(high*2,(int)llround(steady*1000)));
    CicadaCallVoidObject(self.player,NSSelectorFromString(@"setConfig:"),self.config);
}
- (void)start {
    if (self.destroyed || !self.player || self.state==MediaPlaybackCicadaAdapterStateFailed || self.state==MediaPlaybackCicadaAdapterStateIdle) return;
    self.playbackRequested=YES;[self armFirstFrameWatchdog];
    if (!self.preparedReported) {
        // 尚未准备好：先记下，准备就绪（回调或 SDK 准备回调）后自动起播。
        self.startRequested = YES;
        return;
    }
    self.startRequested = NO;
    self.completedReported = NO;
    // Explicit start leaves EOF before invoking the SDK, so callbacks are live.
    // Position is owned by the caller: replay from zero requires seekToTime:0.
    self.state = MediaPlaybackCicadaAdapterStatePlaying;
    [self startPollTimer];
    CicadaCallVoid(self.player, NSSelectorFromString(@"start"));
    if (self.hasPendingRate) [self applyPendingRate];
}

- (void)pause {
    if (self.destroyed || !self.player || self.state==MediaPlaybackCicadaAdapterStateFailed || self.state==MediaPlaybackCicadaAdapterStateCompleted || self.state==MediaPlaybackCicadaAdapterStateIdle) return;
    if(self.firstFrameWatchdog)self.firstFrameRemaining=MAX(0,self.firstFrameRemaining-(CACurrentMediaTime()-self.firstFrameBudgetStarted));
    self.startRequested=NO;self.playbackRequested=NO;[self.firstFrameWatchdog invalidate];self.firstFrameWatchdog=nil;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    CicadaCallVoid(self.player, NSSelectorFromString(@"pause"));
    if (self.state != MediaPlaybackCicadaAdapterStateFailed) self.state = MediaPlaybackCicadaAdapterStatePaused;
}

- (void)stop {
    if (self.destroyed || !self.player) return;
    self.startRequested = NO;self.playbackRequested=NO;
    self.loading = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    if (self.state != MediaPlaybackCicadaAdapterStateFailed) self.state = MediaPlaybackCicadaAdapterStateIdle;
    CicadaCallVoid(self.player, NSSelectorFromString(@"stop"));
    [self finishPendingSeekWithFinished:NO];
}

static dispatch_queue_t MediaPlaybackCicadaQuarantineQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("cctvhost.cicada.quarantine", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

- (void)destroy {
    if (self.destroyed && !self.player) return;
    self.destroyed = YES;
    self.generation++;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    [self.seekTimeoutTimer invalidate]; self.seekTimeoutTimer = nil;
    void (^cancelledSeek)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    self.loading = NO;
    id player = self.player;
    self.player = nil;
    self.config = nil;
    if (player) {
        // 先摘 delegate 与 playerView 再停，并将 reset/destroy 移入隔离队列延迟 350ms，
        // 避免 HLSStream::openSegment 后台线程在 open_callback (0xd0e9c) 解引用空指针。
        CicadaCallVoidObject(player, NSSelectorFromString(@"setDelegate:"), nil);
        CicadaCallVoidObject(player, NSSelectorFromString(@"setPlayerView:"), nil);
        CicadaCallVoid(player, NSSelectorFromString(@"stop"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), MediaPlaybackCicadaQuarantineQueue(), ^{
            @autoreleasepool {
                CicadaCallVoid(player, NSSelectorFromString(@"reset"));
                CicadaCallVoid(player, NSSelectorFromString(@"destroy"));
            }
        });
    }
    self.state = MediaPlaybackCicadaAdapterStateIdle;
    if (cancelledSeek) cancelledSeek(NO);
}

// ---------- 控制 ----------

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL))completion {
    if (self.destroyed || !self.player || !isfinite(time) || time >= (double)INT64_MAX / 1000.0 || self.state==MediaPlaybackCicadaAdapterStateFailed || self.state==MediaPlaybackCicadaAdapterStateIdle || ![self.player respondsToSelector:NSSelectorFromString(@"seekToTime:seekMode:")]) {
        if (completion) completion(NO);
        return;
    }
    [self finishPendingSeekWithFinished:NO];
    if (self.state == MediaPlaybackCicadaAdapterStateCompleted) {
        // Seeking after EOF is an explicit new position request, not autoplay.
        self.completedReported = NO;
        self.state = MediaPlaybackCicadaAdapterStatePaused;
    }
    self.pendingSeekCompletion = completion;
    // CICADA_SEEKMODE_ACCURATE（0x01，见 CicadaSDK.h）：直连路径同值。
    CicadaCallVoidDoubleLong(self.player, NSSelectorFromString(@"seekToTime:seekMode:"), MAX(0, time), 0x01);
    // If the SDK never reports seek completion, fail after three seconds rather
    // than claiming success or leaving the caller waiting indefinitely.
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
    if (!isfinite(rate)) return;
    self.pendingRate = MIN(3.0f, MAX(0.5f, rate));
    self.hasPendingRate = YES;
    [self applyPendingRate];[self updateBufferConfiguration];
}

- (float)rate {
    return self.pendingRate;
}

- (void)applyPendingRate {
    if (!self.player || !self.hasPendingRate) return;
    CicadaCallVoidDouble(self.player, NSSelectorFromString(@"setRate:"), (double)self.pendingRate);
}

- (void)setMuted:(BOOL)muted {self.pendingMuted=muted;CicadaCallVoidBool(self.player,NSSelectorFromString(@"setMuted:"),muted);}
- (BOOL)canSelectTracks {return !self.destroyed&&[self.player respondsToSelector:NSSelectorFromString(@"getMediaInfo")]&&[self.player respondsToSelector:NSSelectorFromString(@"selectTrack:")];}
- (NSArray<NSDictionary *> *)availableTracks {
    if(![self canSelectTracks])return @[];
    @try {
        id info=[self.player valueForKey:@"mediaInfo"];id tracks=[info valueForKey:@"tracks"];if(![tracks isKindOfClass:NSArray.class])return @[];
        NSMutableArray *result=[NSMutableArray array];
        for(id track in tracks){if(result.count>=128)break;NSNumber *index=[track valueForKey:@"trackIndex"],*type=[track valueForKey:@"trackType"];if(![index respondsToSelector:@selector(integerValue)]||![type respondsToSelector:@selector(integerValue)]||index.integerValue<0||index.integerValue>INT_MAX)continue;
            NSString *kind=type.integerValue==1?@"audio":(type.integerValue==2?@"subtitle":@"video");NSString *name=MediaPlaybackCicadaStringFromModel(track,@[@"title",@"audioLang",@"subtitleLang",@"language"]);if(!name.length)name=[NSString stringWithFormat:@"%@ %ld",kind,(long)index.integerValue];[result addObject:@{@"index":index,@"type":kind,@"name":name}];
        }return result.copy;
    }@catch(NSException *error){return @[];}
}
- (BOOL)selectTrackWithIndex:(NSInteger)index {
    if(![self canSelectTracks])return NO;
    for(NSDictionary *track in [self availableTracks])if([track[@"index"] integerValue]==index){CicadaCallVoidInt(self.player,NSSelectorFromString(@"selectTrack:"),(int)index);return YES;}
    return NO;
}
- (void)applyVideoGravity:(NSString *)gravity {
    self.pendingVideoGravity = [gravity copy] ?: AVLayerVideoGravityResizeAspect;
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
    return MediaPlaybackCicadaNormalizeTimeValue(position);
}

- (NSTimeInterval)bufferedPosition {return MAX(self.bufferedTime,MediaPlaybackCicadaNormalizeTimeValue(CicadaCallDouble(self.player,NSSelectorFromString(@"bufferedPosition"))));}

- (NSTimeInterval)duration {
    if (!self.player) return 0;
    NSTimeInterval duration = CicadaCallDouble(self.player, NSSelectorFromString(@"duration"));
    if (duration <= 0) duration = CicadaCallDouble(self.player, NSSelectorFromString(@"getDuration"));
    return MediaPlaybackCicadaNormalizeTimeValue(duration);
}

- (void)reportPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    CFTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(now-self.lastPositionEmission<0.35)return;
    self.lastPositionEmission=now;
    if([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdatePosition:duration:)])[self.delegate cicadaAdapter:self didUpdatePosition:position duration:duration];
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
        [owner reportPosition:position duration:duration];
        // Position advancement can be audio-only. Only render callbacks prove a video frame.
        // 完成兜底：位置到达时长末尾即视为播完（onCompletion 未到时也生效）。
        if (!owner.completedReported && owner.playbackRequested && owner.state==MediaPlaybackCicadaAdapterStatePlaying && duration > 0 && position >= duration - 0.1) [owner handleCompletion];
    }];
}

// ---------- 内部状态机（主线程） ----------

- (void)handlePrepared {
    if (self.preparedReported || self.destroyed || self.state==MediaPlaybackCicadaAdapterStateFailed) return;
    self.preparedReported = YES;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidPrepare:)]) {
        [self.delegate cicadaAdapterDidPrepare:self];
    }
    if (self.startRequested) [self start];
}

- (void)handleFirstFrame {
    if (self.firstFrameReported || ![self acceptsCallbacksFromPlayer:self.player]) return;
    // Keep the startup configuration through first render. Changing the SDK
    // high-water mark here can freeze the first frame while it buffers again.
    self.firstFrameReported = YES;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidShowFirstFrame:)]) {
        [self.delegate cicadaAdapterDidShowFirstFrame:self];
    }
}

- (void)handleCompletion {
    if (self.completedReported || ![self acceptsCallbacksFromPlayer:self.player]) return;
    self.completedReported = YES;
    self.playbackRequested = NO;
    self.startRequested = NO;
    self.loading = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    self.state = MediaPlaybackCicadaAdapterStateCompleted;
    [self.seekTimeoutTimer invalidate]; self.seekTimeoutTimer = nil;
    void (^cancelledSeek)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    if ([self.delegate respondsToSelector:@selector(cicadaAdapterDidComplete:)]) {
        [self.delegate cicadaAdapterDidComplete:self];
    }
    if (cancelledSeek) cancelledSeek(NO);
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
    self.startRequested=NO;self.playbackRequested=NO;
    self.state = MediaPlaybackCicadaAdapterStateFailed;
    self.loading = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.firstFrameWatchdog invalidate]; self.firstFrameWatchdog = nil;
    [self.seekTimeoutTimer invalidate]; self.seekTimeoutTimer = nil;
    void (^cancelledSeek)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    NSError *error = [NSError errorWithDomain:MediaPlaybackCicadaAdapterErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message ?: @"CicadaPlayer 播放失败",
                                                @"extension": self.url.pathExtension.lowercaseString ?: @""}];
    if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didFailWithError:)]) {
        [self.delegate cicadaAdapter:self didFailWithError:error];
    }
    if (cancelledSeek) cancelledSeek(NO);
}

- (BOOL)acceptsCallbacksFromPlayer:(id)player {
    return !self.destroyed && player && player == self.player &&
        self.state != MediaPlaybackCicadaAdapterStateIdle &&
        self.state != MediaPlaybackCicadaAdapterStateFailed &&
        self.state != MediaPlaybackCicadaAdapterStateCompleted;
}

// ---------- SDK Delegate 回调 ----------
//
// 以下 6 个 selector 在 CicadaPlayerSDK 二进制中以字符串形式确认；
// 其余 6 个只在 C++ 层（CicadaOCHelper）确认，拼写为 best-effort。
// SDK 可能在非主线程回调，一律先切主线程、再按 generation 过滤。

- (void)onPlayerEvent:(id)player eventType:(NSUInteger)eventType {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        switch (eventType) {
            case 0: // CicadaEventPrepareDone
                [self handlePrepared];
                break;
            case 2: // CicadaEventFirstRenderedStart
                [self handleFirstFrame];
                break;
            case 3: // CicadaEventCompletion
                [self handleCompletion];
                break;
            case 4: // CicadaEventLoadingStart
                if(!self.loading&&self.firstFrameReported){self.stallCount++;[self updateBufferConfiguration];}
                self.loading = YES;
                if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
                    [self.delegate cicadaAdapter:self didUpdateLoading:YES progress:0];
                }
                break;
            case 5: // CicadaEventLoadingEnd
                self.loading = NO;
                if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
                    [self.delegate cicadaAdapter:self didUpdateLoading:NO progress:1.0f];
                }
                break;
            case 6: // CicadaEventSeekEnd
                [self finishPendingSeekWithFinished:YES];
                break;
            default:
                break;
        }
    });
}

- (void)onError:(id)player errorModel:(id)errorModel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        NSInteger code = MediaPlaybackCicadaCodeFromModel(errorModel);
        NSString *message = MediaPlaybackCicadaStringFromModel(errorModel, @[@"errorMsg", @"message", @"localizedDescription"]);
        [self reportErrorWithCode:code message:message ?: @"CicadaPlayer 播放失败"];
    });
}

- (void)onCurrentPositionUpdate:(id)player position:(int64_t)position {
    // position 在二进制中为 int64_t 毫秒，必须声明为非对象标量 int64_t，
    // 否则 ARC 会在函数序言/尾声对原始整数调用 objc_retain/objc_release 导致 SIGSEGV 崩溃。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        NSTimeInterval seconds = MAX(0,(double)position/1000.0);
        self.lastPolledPosition = seconds;
        [self reportPosition:seconds duration:self.duration];
    });
}

- (void)onBufferedPositionUpdate:(id)player position:(int64_t)position {
    // position 在二进制中为 int64_t 毫秒（非对象标量）。
    dispatch_async(dispatch_get_main_queue(),^{if([self acceptsCallbacksFromPlayer:player])self.bufferedTime=MAX(0,(double)position/1000.0);});
}

- (void)onLoadingProgress:(id)player progress:(float)progress {
    // progress 在二进制中由浮点寄存器 S0 传入（float），绝不可声明为 id。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        float clamped = isfinite(progress) ? MAX(0.0f, MIN(1.0f, progress / 100.0f)) : 0.0f;
        self.loading=clamped<1.0f;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:self.loading progress:clamped];
        }
    });
}

- (void)onPlayerStatusChanged:(id)player oldStatus:(NSInteger)oldStatus newStatus:(NSInteger)newStatus {
    // oldStatus/newStatus 在二进制中由 X3/X4 传入 CicadaStatus 整数（如 1=Initialized），
    // 声明为 id 会触发 ARC objc_storeStrong(0x1) 导致 SIGSEGV (offset 48888) 崩溃。
    dispatch_async(dispatch_get_main_queue(),^{
        if(![self acceptsCallbacksFromPlayer:player])return;
        if(newStatus==2)[self handlePrepared];
        else if(newStatus==4&&!self.playbackRequested)self.state=MediaPlaybackCicadaAdapterStatePaused;
        else if(newStatus==6)[self handleCompletion];
    });
}

- (void)onCurrentDownLoadSpeed:(id)player progress:(float)speed {
    // Best-effort 回调（见文件头注释 3）：speed 单位 bit/s（CicadaSDK.h
    // 声明为 float；直连路径同样按 float 读，并除以 8 得字节/秒）。
    // 适配器此前未实现它——SDK 若无 respondsToSelector 守卫就调用，
    // 会因 unrecognized selector 崩溃；现在实现并转发给调用方更新测速。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateDownloadSpeed:)]) {
            [self.delegate cicadaAdapter:self didUpdateDownloadSpeed:isfinite(speed) ? MAX(0, (double)speed) : 0];
        }
    });
}

- (void)onVideoSizeChanged:(id)player width:(int)width height:(int)height rotation:(int)rotation {
    // 宽高/旋转按 CicadaSDK.h 声明的 int 读取（此前声明为 id 且不读参数，
    // 调用方拿不到尺寸，无法更新画面比例）；SDK 上报尺寸变化本身即证明有视频轨。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        _hasVideoTrack = width>0&&height>0;
        // Dimensions prove a video track exists, not that a frame was rendered.
        if (width > 0 && height > 0 && [self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateVideoSize:rotation:)]) {
            [self.delegate cicadaAdapter:self didUpdateVideoSize:CGSizeMake(width, height) rotation:rotation];
        }
    });
}

- (void)onVideoRendered:(id)player timeMs:(int64_t)timeMs pts:(int64_t)pts {
    if(self.firstFrameReported)return; // Avoid a main-queue block for every rendered frame.
    dispatch_async(dispatch_get_main_queue(),^{if([self acceptsCallbacksFromPlayer:player]){_hasVideoTrack=YES;[self handleFirstFrame];}});
}

// Best-effort 回调（selector 拼写未在二进制中直接确认，见文件头注释）。
- (void)onPrepared:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self acceptsCallbacksFromPlayer:player]) [self handlePrepared];
    });
}

- (void)onFirstFrameShow:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self acceptsCallbacksFromPlayer:player]) [self handleFirstFrame];
    });
}

- (void)onCompletion:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self acceptsCallbacksFromPlayer:player]) [self handleCompletion];
    });
}

- (void)onLoadingStart:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        self.loading = YES;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:YES progress:0];
        }
    });
}

- (void)onLoadingEnd:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self acceptsCallbacksFromPlayer:player]) return;
        self.loading = NO;
        if ([self.delegate respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
            [self.delegate cicadaAdapter:self didUpdateLoading:NO progress:1.0f];
        }
    });
}

- (void)onSeekEnd:(id)player {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self acceptsCallbacksFromPlayer:player]) [self finishPendingSeekWithFinished:YES];
    });
}

@end
