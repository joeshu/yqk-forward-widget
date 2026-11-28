#import "MediaPlaybackMPVAdapter.h"
#import "HostMPVLifecycle.h"
#import "RuntimeDiagnostics.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <stdatomic.h>
#import <stdint.h>

NSString * const MediaPlaybackMPVAdapterErrorDomain = @"CCTVHost.MediaPlaybackMPVAdapter";

/// S2/S3：MPV 首帧与 seek 的真实证据口径。
/// - 视频首帧只在观测到视频轨道（video-params 宽/高 > 0）且播放重启或
///   time-pos 前进时报告；time-pos 前进而无视频轨道不算视频首帧。
/// - 纯音频：time-pos 超过 1.0 秒仍无视频轨道时报 audio-only（见
///   MediaPlaybackCicadaAdapterDelegate 的 cicadaAdapterDidStartAudioOnly:），
///   视频随后出现仍可再报视频首帧。
/// - seek：每个请求有独立 id + 目标 + 3 秒 deadline；重启或 time-pos 落在
///   目标 ±1.0 秒内才完成一次，超时/取消/停止/失败完成 NO。
/// - 首帧预算暂停时冻结（与 Cicada adapter 的 firstFrameRemaining 同款）。
static NSTimeInterval const MediaPlaybackMPVFirstFrameTimeout = 20.0;
static NSTimeInterval const MediaPlaybackMPVSeekTimeout = 3.0;
static NSTimeInterval const MediaPlaybackMPVAudioOnlyPositionThreshold = 1.0;
static NSTimeInterval const MediaPlaybackMPVSeekPositionTolerance = 1.0;
// T20/S4：高频事件（time-pos / cache-speed / demuxer-cache-time）向主队
// 列合并的窗口：约 4Hz（方案 §8.1）。终态、首帧、seek 完成、缓冲状态
// 变化不受此窗口影响，始终即时派发。
// T20：命令队列重入守卫 key——runOnCommandQueueSync 在队列上调用时
// 直接执行，不 dispatch_sync（否则自锁）。
static const void *kMediaPlaybackMPVCommandQueueKey = &kMediaPlaybackMPVCommandQueueKey;
static NSTimeInterval const MediaPlaybackMPVEventCoalesceInterval = 0.25;
// If the consumer takes this long to exit, wake it again. The handle
// remains alive until the background teardown confirms consumer exit.
static int const MediaPlaybackMPVDestroyEventExitTimeoutMs = 2000;

// ---- Minimal libmpv v2 C ABI declarations (loaded dynamically via dlopen RTLD_LOCAL) ----
typedef struct mpv_handle mpv_handle;

typedef enum {
    MPV_FORMAT_NONE   = 0,
    MPV_FORMAT_STRING = 1,
    MPV_FORMAT_FLAG   = 3,
    MPV_FORMAT_INT64  = 4,
    MPV_FORMAT_DOUBLE = 5,
} cctv_mpv_format;

typedef enum {
    MPV_EVENT_NONE             = 0,
    MPV_EVENT_SHUTDOWN         = 1,
    MPV_EVENT_START_FILE       = 6,
    MPV_EVENT_END_FILE         = 7,
    MPV_EVENT_FILE_LOADED      = 8,
    MPV_EVENT_SEEK             = 20,
    MPV_EVENT_PLAYBACK_RESTART = 21,
    MPV_EVENT_PROPERTY_CHANGE  = 22,
} cctv_mpv_event_id;

typedef enum {
    MPV_END_FILE_REASON_EOF      = 0,
    MPV_END_FILE_REASON_STOP     = 2,
    MPV_END_FILE_REASON_QUIT     = 3,
    MPV_END_FILE_REASON_ERROR    = 4,
    MPV_END_FILE_REASON_REDIRECT = 5,
} cctv_mpv_end_file_reason;

typedef struct {
    const char *name;
    cctv_mpv_format format;
    void *data;
} cctv_mpv_event_property;

typedef struct {
    int reason;
    int error;
    int64_t playlist_entry_id;
    int64_t playlist_insert_id;
    int playlist_insert_num_entries;
} cctv_mpv_event_end_file;

typedef struct {
    cctv_mpv_event_id event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} cctv_mpv_event;

typedef unsigned long (*mpv_client_api_version_fn)(void);
typedef const char * (*mpv_error_string_fn)(int error);
typedef void (*mpv_free_fn)(void *data);
typedef mpv_handle * (*mpv_create_fn)(void);
typedef int (*mpv_initialize_fn)(mpv_handle *ctx);
typedef void (*mpv_terminate_destroy_fn)(mpv_handle *ctx);
typedef int (*mpv_set_option_fn)(mpv_handle *ctx, const char *name, cctv_mpv_format format, void *data);
typedef int (*mpv_set_option_string_fn)(mpv_handle *ctx, const char *name, const char *data);
typedef int (*mpv_command_fn)(mpv_handle *ctx, const char **args);
typedef int (*mpv_command_async_fn)(mpv_handle *ctx, uint64_t reply_userdata, const char **args);
typedef int (*mpv_set_property_fn)(mpv_handle *ctx, const char *name, cctv_mpv_format format, void *data);
typedef int (*mpv_set_property_string_fn)(mpv_handle *ctx, const char *name, const char *data);
typedef int (*mpv_get_property_fn)(mpv_handle *ctx, const char *name, cctv_mpv_format format, void *data);
typedef char * (*mpv_get_property_string_fn)(mpv_handle *ctx, const char *name);
typedef int (*mpv_observe_property_fn)(mpv_handle *ctx, uint64_t reply_userdata, const char *name, cctv_mpv_format format);
typedef cctv_mpv_event * (*mpv_wait_event_fn)(mpv_handle *ctx, double timeout);
typedef void (*mpv_wakeup_fn)(mpv_handle *ctx);

typedef struct {
    BOOL loaded;
    void *handle;
    mpv_client_api_version_fn client_api_version;
    mpv_error_string_fn error_string;
    mpv_free_fn free_mem;
    mpv_create_fn create;
    mpv_initialize_fn initialize;
    mpv_terminate_destroy_fn terminate_destroy;
    mpv_set_option_fn set_option;
    mpv_set_option_string_fn set_option_string;
    mpv_command_fn command;
    mpv_command_async_fn command_async;
    mpv_set_property_fn set_property;
    mpv_set_property_string_fn set_property_string;
    mpv_get_property_fn get_property;
    mpv_get_property_string_fn get_property_string;
    mpv_observe_property_fn observe_property;
    mpv_wait_event_fn wait_event;
    mpv_wakeup_fn wakeup;
} CCTVMPVSymbolTable;

static const CCTVMPVSymbolTable *CCTVMPVLoadSymbols(void) {
    static CCTVMPVSymbolTable table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *privateFrameworks = NSBundle.mainBundle.privateFrameworksPath;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if (privateFrameworks.length) {
            [candidates addObject:[privateFrameworks stringByAppendingPathComponent:@"CCTVMPVCore.framework/CCTVMPVCore"]];
        }
        [candidates addObject:@"@rpath/CCTVMPVCore.framework/CCTVMPVCore"];

        void *dl = NULL;
        for (NSString *path in candidates) {
            // RTLD_LOCAL keeps every internal FFmpeg/libass/OpenSSL symbol isolated
            // from CNPlayerSDK (IJK FFmpeg), alivcffmpeg, and Python.framework.
            dl = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (dl) break;
        }
        if (!dl) {
            const char *dlErr = dlerror();
            NSLog(@"[CCTVHost] MPV dlopen failed: %s", dlErr ? dlErr : "unknown");
            return;
        }

#define LOAD_MPV_SYM(field, sym) table.field = dlsym(dl, sym); if (!table.field) { const char *dlErr = dlerror(); NSLog(@"[CCTVHost] MPV dlsym(%s) failed: %s", sym, dlErr ? dlErr : "unknown"); dlclose(dl); memset(&table, 0, sizeof(table)); return; }
        LOAD_MPV_SYM(client_api_version, "mpv_client_api_version");
        LOAD_MPV_SYM(error_string, "mpv_error_string");
        LOAD_MPV_SYM(free_mem, "mpv_free");
        LOAD_MPV_SYM(create, "mpv_create");
        LOAD_MPV_SYM(initialize, "mpv_initialize");
        LOAD_MPV_SYM(terminate_destroy, "mpv_terminate_destroy");
        LOAD_MPV_SYM(set_option, "mpv_set_option");
        LOAD_MPV_SYM(set_option_string, "mpv_set_option_string");
        LOAD_MPV_SYM(command, "mpv_command");
        LOAD_MPV_SYM(command_async, "mpv_command_async");
        LOAD_MPV_SYM(set_property, "mpv_set_property");
        LOAD_MPV_SYM(set_property_string, "mpv_set_property_string");
        LOAD_MPV_SYM(get_property, "mpv_get_property");
        LOAD_MPV_SYM(get_property_string, "mpv_get_property_string");
        LOAD_MPV_SYM(observe_property, "mpv_observe_property");
        LOAD_MPV_SYM(wait_event, "mpv_wait_event");
        LOAD_MPV_SYM(wakeup, "mpv_wakeup");
#undef LOAD_MPV_SYM

        unsigned long apiVersion = table.client_api_version();
        if (apiVersion < (2UL << 16)) {
            dlclose(dl);
            memset(&table, 0, sizeof(table));
            return;
        }
        table.handle = dl;
        table.loaded = YES;
    });
    return table.loaded ? &table : NULL;
}

// ---- CAMetalLayer-backed rendering view for libmpv gpu-next / MoltenVK ----
@interface CCTVMPVMetalLayerView : UIView
@end

@implementation CCTVMPVMetalLayerView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
    // MoltenVK changes CAMetalLayer swapchain properties on its render thread.
    // This view has no implicit animations, so don't route those changes through
    // UIView's default delegate callback, which asserts that it runs on main.
    (void)layer;
    (void)event;
    return (id<CAAction>)NSNull.null;
}
- (instancetype)initWithFrame:(CGRect)frame {
    CGRect initialFrame = (frame.size.width > 0 && frame.size.height > 0) ? frame : CGRectMake(0, 0, 1, 1);
    if ((self = [super initWithFrame:initialFrame])) {
        self.backgroundColor = UIColor.blackColor;
        CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 2.0;
        self.contentScaleFactor = scale;
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.contentsScale = scale;
        metalLayer.framebufferOnly = YES;
        metalLayer.drawableSize = CGSizeMake(MAX(2,ceil(initialFrame.size.width * scale)), MAX(2,ceil(initialFrame.size.height * scale)));
    }
    return self;
}
- (void)syncMetalDrawableMetrics {
    UIWindow *window=self.window;
    if(!window)return;
    // Ignore transient UIKit layout sizes. MoltenVK can still use its own
    // 1x1 surface update to finish outstanding presentations at teardown.
    CGSize boundsSize=self.bounds.size;
    if(!isfinite(boundsSize.width)||!isfinite(boundsSize.height)||boundsSize.width<=1||boundsSize.height<=1)return;
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale=window.screen.scale;
    if(!isfinite(scale)||scale<=0)scale=2.0;
    CGSize drawableSize=CGSizeMake(ceil(boundsSize.width*scale),ceil(boundsSize.height*scale));
    if(self.contentScaleFactor==scale&&metalLayer.contentsScale==scale&&CGSizeEqualToSize(metalLayer.drawableSize,drawableSize))return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(self.contentScaleFactor!=scale)self.contentScaleFactor=scale;
    if(metalLayer.contentsScale!=scale)metalLayer.contentsScale=scale;
    if(!CGSizeEqualToSize(metalLayer.drawableSize,drawableSize))metalLayer.drawableSize=drawableSize;
    [CATransaction commit];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self syncMetalDrawableMetrics];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self syncMetalDrawableMetrics];
}
@end

static NSString *CCTVMPVSanitizeHeaderValue(NSString *value) {
    NSString *clean = [value stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    return [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

enum {
    CCTVMPVReplyTimePos = 1,
    CCTVMPVReplyDuration = 2,
    CCTVMPVReplyCacheTime = 3,
    CCTVMPVReplyPausedForCache = 4,
    CCTVMPVReplyCacheSpeed = 5,
    CCTVMPVReplyVideoWidth = 6,
    CCTVMPVReplyVideoHeight = 7,
    CCTVMPVReplyVideoRotate = 8,
    CCTVMPVReplyEOFReached = 9,
    // T20：轨道数变化——轨道缓存重建的触发器（选中态变化不改总数，
    // 由 selectTrack 成功后乐观更新缓存，见 rebuildCachedTracks）。
    CCTVMPVReplyTrackListCount = 10,
};

@interface MediaPlaybackMPVAdapter () <AVPictureInPictureSampleBufferPlaybackDelegate> {
    // Terminal lifecycle core (T02/S1): heap-allocated and atomically
    // refcounted so the background teardown in destroy can outlive the
    // adapter object; the adapter holds one reference, released in dealloc.
    host_mpv_lifecycle_t *_lifecycle;
    _Atomic(BOOL) _destroyedFlag;
}
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic) NSTimeInterval networkTimeout;
@property (nonatomic, strong) CCTVMPVMetalLayerView *metalView;
@property (nonatomic, strong, nullable) CALayer *metalLayer;
@property (nonatomic, strong, nullable) AVSampleBufferDisplayLayer *pipDisplayLayer;
@property (nonatomic, strong, nullable) AVPictureInPictureController *pipController;
@property (nonatomic) MediaPlaybackCicadaAdapterState state;
@property (nonatomic) NSTimeInterval currentPosition;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval bufferedPosition;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL hasVideoTrack;
@property (nonatomic, readwrite) NSInteger lastErrorCode;
@property (nonatomic) BOOL muted;
@property (nonatomic, copy) NSString *pendingGravity;
@property (nonatomic) BOOL destroyed;
@property (nonatomic) BOOL preparedNotified;
@property (nonatomic) BOOL firstFrameNotified;
@property (nonatomic) BOOL audioOnlyNotified;
@property (nonatomic) BOOL hasInitialPosition;
@property (nonatomic) double initialPosition;
@property (nonatomic) BOOL pausedByUser;
@property (nonatomic) BOOL seekEventObserved;
@property (nonatomic) BOOL videoDisabledForBackground;
@property (nonatomic, copy, nullable) NSString *savedVidBeforeBackground;
@property (nonatomic) NSTimeInterval firstFrameRemaining;
@property (nonatomic) CFTimeInterval firstFrameBudgetStarted;
@property (nonatomic) BOOL completionNotified;
@property (nonatomic) BOOL wantStartAfterPrepare;
@property (nonatomic) CGSize lastVideoSize;
@property (nonatomic) NSInteger lastVideoRotation;
@property (nonatomic, strong, nullable) NSTimer *firstFrameWatchdog;
@property (nonatomic, copy, nullable) void (^pendingSeekCompletion)(BOOL finished);
@property (nonatomic) NSUInteger pendingSeekID;
@property (nonatomic) NSTimeInterval pendingSeekTarget;
@property (nonatomic, strong, nullable) NSTimer *seekTimeoutTimer;
@property (nonatomic, strong, nullable) NSThread *eventThread;
@property (nonatomic, strong) NSLock *mpvLock;
@property (nonatomic, assign) mpv_handle *mpvHandle;
@property (nonatomic, assign) const CCTVMPVSymbolTable *syms;
// Prepare-time snapshots captured on caller thread before dispatching to commandQueue.
@property (nonatomic, copy, nullable) NSString *prepareGravitySnapshot;
@property (nonatomic) BOOL prepareLiveHintSnapshot;
@property (nonatomic) float prepareRateSnapshot;
@property (nonatomic) BOOL prepareMutedSnapshot;
// T20/S4：串行命令队列——全部 handle 触碰（创建/初始化/属性/命令/
// 轨道枚举/统计读取）只在这里执行，调用线程（常为主线程）不再同步
// 碰 handle。fire-and-forget 控制用 dispatch_async；需返回值的
// selectTrack / 统计读取 / addExternalSubtitle 用
// runOnCommandQueueSync（handle 未发布时走 fast path 直接返回，
// 不等队列）。destroy 的 quit/terminate 仍走 T02 原有路径，不经此队列。
@property (nonatomic, strong) dispatch_queue_t commandQueue;
// T20：轨道缓存——availableTracks 只读此缓存，不再每次枚举（旧实现
// 每读一次做约 300 次 mpv IPC 往返）。缓存只在命令队列上写
// （FILE_LOADED 与 track-list/count 变化时重建；select 成功后乐观
// 更新选中态），读经 mpvLock；元素形态与旧枚举完全一致
// （type/index/name/selected），T09 菜单验证直接复用。
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *cachedTracks;
// T20：本次 prepare 里被引擎拒绝的 option 名（仅命令队列触碰）。
// 初始化成功后一次性记 mpv_option_failed 诊断事件，不阻塞 prepare。
@property (nonatomic, strong, nullable) NSMutableArray<NSString *> *failedOptionNames;
// T20：高频事件合并状态——只由事件线程读写（事件循环与 flush 共用），
// runOnMain 的 block 只按值捕获待派发的数据，不共享这些字段。
@property (nonatomic) CFTimeInterval lastPositionDispatchAt;
@property (nonatomic) double pendingPosition;
@property (nonatomic) BOOL hasPendingPosition;
@property (nonatomic) CFTimeInterval lastSpeedDispatchAt;
@property (nonatomic) double pendingSpeedBytesPerSec;
@property (nonatomic) BOOL hasPendingSpeed;
@property (nonatomic) CFTimeInterval lastCacheTimeDispatchAt;
@property (nonatomic) double pendingCacheTime;
@property (nonatomic) BOOL hasPendingCacheTime;
@property (nonatomic) double lastForwardedDuration;
@property (nonatomic) BOOL hasForwardedDuration;

- (void)runOnMain:(dispatch_block_t)block;
- (void)prepareHandleWithSymbols:(const CCTVMPVSymbolTable *)syms enableHardwareDecoder:(BOOL)enableHardwareDecoder;
- (void)runOnCommandQueue:(dispatch_block_t)block;
- (void)runOnCommandQueueSync:(dispatch_block_t)block;
- (void)rebuildCachedTracksOnCommandQueue;
- (NSArray<NSDictionary *> *)enumerateTracksFromHandle:(mpv_handle *)ctx syms:(const CCTVMPVSymbolTable *)syms;
- (void)updateCachedTrackSelectionForIndex:(NSInteger)index kind:(NSString *)kind selected:(BOOL)selected;
- (int)mpvSetOptionString:(mpv_handle *)ctx name:(const char *)name value:(const char *)value;
- (int)mpvSetOptionInt:(mpv_handle *)ctx name:(const char *)name value:(int64_t)value;
- (int)mpvObserveProperty:(mpv_handle *)ctx tag:(uint64_t)tag name:(const char *)name format:(int)format;
- (int)mpvSetProperty:(mpv_handle *)ctx name:(const char *)name format:(int)format value:(void *)value operation:(NSString *)operation;
- (int)mpvSetPropertyString:(mpv_handle *)ctx name:(const char *)name value:(const char *)value operation:(NSString *)operation;
- (void)recordMPVControlFailure:(NSString *)operation property:(NSString *)property;
- (void)dispatchPositionUpdate:(double)pos;
- (void)dispatchDownloadSpeedUpdate:(double)bytesPerSec;
- (void)dispatchCacheTimeUpdate:(double)buf;
- (void)flushPendingCoalescedEventsIfDue;
- (void)flushPendingPositionImmediately;
- (void)armFirstFrameWatchdog;
- (void)cancelFirstFrameWatchdog;
- (void)handleFirstFrameTimeout;
- (void)handleAudioOnlyOnMain;
- (void)maybeCompletePendingSeek;
- (void)handleSeekTimeoutForID:(NSUInteger)seekID;
- (void)configureHTTPHeadersOnHandle:(mpv_handle *)ctx;
- (void)applyBufferOptionsOnHandle:(mpv_handle *)ctx;
- (void)applyGravity:(NSString *)gravity onHandle:(mpv_handle *)ctx;
- (void)eventLoopMain:(NSValue *)handleValue;
- (void)handleFileLoadedOnMain;
- (void)handleFirstFrameOnMain;
- (void)handleCompletionOnMain;
- (void)handleFailureWithCode:(NSInteger)code message:(NSString *)message;
- (void)handleVideoGeometryUpdate;
- (void)finishPendingSeek:(BOOL)finished;
- (void)handleApplicationDidEnterBackground:(NSNotification *)note;
- (void)handleApplicationDidBecomeActive:(NSNotification *)note;
@end

@implementation MediaPlaybackMPVAdapter

- (BOOL)destroyed {
    return atomic_load_explicit(&_destroyedFlag, memory_order_acquire);
}

- (void)setDestroyed:(BOOL)destroyed {
    atomic_store_explicit(&_destroyedFlag, destroyed, memory_order_release);
}

+ (BOOL)isAvailable {
    return CCTVMPVLoadSymbols() != NULL;
}

+ (NSString *)engineDisplayName {
    return @"MPV Universal (FFmpeg 8 + VideoToolbox + libass)";
}

- (instancetype)initWithURL:(NSURL *)url
                    headers:(NSDictionary<NSString *, NSString *> *)headers
             networkTimeout:(NSTimeInterval)timeoutSeconds {
    if ((self = [super init])) {
        _url = url;
        _headers = headers ? [headers copy] : @{};
        _networkTimeout = timeoutSeconds > 0 ? timeoutSeconds : 15.0;
        _metalView = [[CCTVMPVMetalLayerView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        _metalView.translatesAutoresizingMaskIntoConstraints = NO;
        _metalLayer = _metalView.layer;
        _state = MediaPlaybackCicadaAdapterStateIdle;
        _rate = 1.0f;
        _pendingGravity = AVLayerVideoGravityResizeAspect;
        _mpvLock = [NSLock new];
        _lifecycle = host_mpv_lifecycle_create();
        atomic_init(&_destroyedFlag, NO);
        // T20/S4：串行命令队列（见扩展注释）。
        _commandQueue = dispatch_queue_create("com.cctvhost.mpv.command", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_commandQueue, kMediaPlaybackMPVCommandQueueKey,
                                    (void *)kMediaPlaybackMPVCommandQueueKey, NULL);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(handleApplicationDidEnterBackground:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(handleApplicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(handleApplicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)note {
    (void)note;
    if (self.destroyed || self.videoDisabledForBackground) return;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    self.videoDisabledForBackground = YES;
    if(self.firstFrameWatchdog){
        self.firstFrameRemaining=MAX(0,self.firstFrameRemaining-(CACurrentMediaTime()-self.firstFrameBudgetStarted));
        [self cancelFirstFrameWatchdog];
    }
    // Synchronously (bounded) disable video output before returning from background notification
    // so MoltenVK/Metal does not submit GPU command buffers while backgrounded (prevents iOS SIGKILL).
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (strongSelf && host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) {
            [strongSelf.mpvLock lock];
            mpv_handle *ctx = strongSelf.mpvHandle;
            const CCTVMPVSymbolTable *syms = strongSelf.syms;
            if (ctx && syms) {
                char *curVid = syms->get_property_string(ctx, "vid");
                if (curVid) {
                    strongSelf.savedVidBeforeBackground = [NSString stringWithUTF8String:curVid];
                    syms->free_mem(curVid);
                }
                [strongSelf mpvSetPropertyString:ctx name:"vid" value:"no" operation:@"backgroundQuiesce"];
                int flag = 1;
                [strongSelf mpvSetProperty:ctx name:"pause" format:MPV_FORMAT_FLAG value:&flag operation:@"backgroundQuiesce"];
            }
            [strongSelf.mpvLock unlock];
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)));
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    if (self.destroyed || !self.videoDisabledForBackground) return;
    self.videoDisabledForBackground = NO;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        NSString *restoreVid=strongSelf.savedVidBeforeBackground?:@"auto";
        strongSelf.savedVidBeforeBackground=nil;
        if (ctx) {
            [strongSelf mpvSetPropertyString:ctx name:"vid" value:restoreVid.UTF8String operation:@"foregroundRestore"];
        }
        [strongSelf.mpvLock unlock];
    }];
    if(self.wantStartAfterPrepare&&self.state!=MediaPlaybackCicadaAdapterStateCompleted&&self.state!=MediaPlaybackCicadaAdapterStateFailed)[self start];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self destroy];
    // Drop the adapter's own lifecycle reference; a teardown block that
    // is still waiting holds its own reference and frees the object.
    if (_lifecycle) host_mpv_lifecycle_release(_lifecycle);
}

- (UIView *)playerView {
    return self.metalView;
}

- (NSTimeInterval)firstFrameTimeout {
    return MediaPlaybackMPVFirstFrameTimeout;
}

- (void)runOnMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

- (void)runOnCommandQueue:(dispatch_block_t)block {
    dispatch_async(self.commandQueue, block);
}

- (void)runOnCommandQueueSync:(dispatch_block_t)block {
    // 队列上直接执行（重入守卫）；队列外 dispatch_sync 等前面的
    // 短命令排空——prepare 的 loadfile 已是 async，队列无长任务。
    if (dispatch_get_specific(kMediaPlaybackMPVCommandQueueKey)) block();
    else dispatch_sync(self.commandQueue, block);
}

// T20/S4：受检的 option/observe 调用——失败只记录（failedOptionNames
// 供 prepare 末尾一次性上报 mpv_option_failed），不改变旧的"静默
// 忽略并继续"策略；失败策略变更不在 T20 范围。
- (int)mpvSetOptionString:(mpv_handle *)ctx name:(const char *)name value:(const char *)value {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return -1;
    int err = syms->set_option_string(ctx, name, value);
    if (err < 0) {
        NSLog(@"[CCTVHost] MPV option %s rejected (%d)", name, err);
        [self.failedOptionNames addObject:[NSString stringWithUTF8String:name] ?: @"?"];
    }
    return err;
}

- (int)mpvSetOptionInt:(mpv_handle *)ctx name:(const char *)name value:(int64_t)value {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return -1;
    int64_t v = value;
    int err = syms->set_option(ctx, name, MPV_FORMAT_INT64, &v);
    if (err < 0) {
        NSLog(@"[CCTVHost] MPV option %s rejected (%d)", name, err);
        [self.failedOptionNames addObject:[NSString stringWithUTF8String:name] ?: @"?"];
    }
    return err;
}

- (int)mpvObserveProperty:(mpv_handle *)ctx tag:(uint64_t)tag name:(const char *)name format:(int)format {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return -1;
    int err = syms->observe_property(ctx, tag, name, format);
    if (err < 0) {
        NSLog(@"[CCTVHost] MPV observe %s rejected (%d)", name, err);
        [self.failedOptionNames addObject:[NSString stringWithFormat:@"observe:%s", name]];
    }
    return err;
}

// T20：受检的 set_property / set_property_string——失败记
// mpv_control_failed 诊断事件（诊断开启时）+ NSLog；调用方仍按
// 旧语义处理返回值（不新增失败分支）。
- (int)mpvSetProperty:(mpv_handle *)ctx name:(const char *)name format:(int)format value:(void *)value operation:(NSString *)operation {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return -1;
    int err = syms->set_property(ctx, name, format, value);
    if (err < 0) [self recordMPVControlFailure:operation property:[NSString stringWithUTF8String:name] ?: @"?"];
    return err;
}

- (int)mpvSetPropertyString:(mpv_handle *)ctx name:(const char *)name value:(const char *)value operation:(NSString *)operation {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return -1;
    int err = syms->set_property_string(ctx, name, value);
    if (err < 0) [self recordMPVControlFailure:operation property:[NSString stringWithUTF8String:name] ?: @"?"];
    return err;
}

- (void)recordMPVControlFailure:(NSString *)operation property:(NSString *)property {
    NSLog(@"[CCTVHost] MPV control %@ failed on %@", operation, property);
    if (RuntimeDiagnostics.shared.enabled) {
        [RuntimeDiagnostics.shared recordEvent:@"mpv_control_failed" category:@"playback" fields:@{@"engine": @"mpv", @"operation": operation ?: @"", @"property": property ?: @""}];
    }
}

- (void)prepare {
    [self prepareWithHardwareDecoder:YES];
}

- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder {
    if (self.destroyed) return;
    // Single-owner prepare (T02/S1): a second prepare while a handle is
    // live is a silent no-op instead of orphaning the first handle and
    // its event thread. Prepare after destroy is rejected the same way.
    if (!host_mpv_lifecycle_begin_prepare(_lifecycle)) return;
    const CCTVMPVSymbolTable *syms = CCTVMPVLoadSymbols();
    if (!syms) {
        host_mpv_lifecycle_abandon_prepare(_lifecycle);
        [self handleFailureWithCode:-1000 message:@"CCTVMPVCore 全能内核未打包或不可用"];
        return;
    }
    if (!self.url.absoluteString.length) {
        host_mpv_lifecycle_abandon_prepare(_lifecycle);
        [self handleFailureWithCode:-1001 message:@"播放地址为空"];
        return;
    }

    self.syms = syms;
    self.state = MediaPlaybackCicadaAdapterStatePreparing;
    self.loading = YES;
    self.preparedNotified = NO;
    self.firstFrameNotified = NO;
    self.audioOnlyNotified = NO;
    self.firstFrameRemaining = MediaPlaybackMPVFirstFrameTimeout;
    [self cancelFirstFrameWatchdog];
    [self.seekTimeoutTimer invalidate];
    self.seekTimeoutTimer = nil;
    self.pendingSeekCompletion = nil;
    self.pendingSeekID = 0;
    self.pendingSeekTarget = 0;
    self.completionNotified = NO;
    self.hasVideoTrack = NO;
    self.failedOptionNames = [NSMutableArray array];
    self.hasForwardedDuration = NO;
    self.hasInitialPosition = NO;
    self.initialPosition = 0;
    self.pausedByUser = NO;
    self.seekEventObserved = NO;
    if (!self.metalLayer && NSThread.isMainThread) {
        self.metalLayer = self.metalView.layer;
    }
    [self.mpvLock lock];
    self.prepareGravitySnapshot = [self.pendingGravity copy];
    self.prepareLiveHintSnapshot = self.liveStreamHint;
    self.prepareRateSnapshot = self.rate;
    self.prepareMutedSnapshot = self.muted;
    [self.mpvLock unlock];

    // T20/S4：创建句柄、全部 set_option、initialize、observe 与 loadfile
    // 不再在调用线程（常为主线程）同步执行——mpv_initialize 与网络
    // open 都可能耗时。重活进串行命令队列；状态复位已在上面完成，
    // 失败仍经 handleFailure（主线程）上报，语义与旧同步版一致。
    // loadfile 改 command_async：命令队列永不因网络 open 而堵住，
    // 加载失败由 MPV_EVENT_END_FILE（ERROR）上报（原同步 loadErr
    // 路径只剩句柄本身被拒的极少数情况）。
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.commandQueue, ^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Gate 1：排队期间 destroy 可能已认领 teardown（此时 lifecycle
        // 不再是 PREPARED，destroy 认领时句柄尚未发布、已直接收尾）——
        // 此时绝不创建句柄，静默返回；不要调 abandon_prepare（teardown
        // 已归 destroy 所有）。
        if (host_mpv_lifecycle_state(strongSelf->_lifecycle) != HOST_MPV_LC_PREPARED) return;
        [strongSelf prepareHandleWithSymbols:syms enableHardwareDecoder:enableHardwareDecoder];
    });
}

// T20：prepare 的重活（只在命令队列上跑）。Gate 2 在 initialize 之后、
// 发布句柄之前再查一次 lifecycle：destroy 若在 init 期间认领了
// teardown，刚建好的 ctx 由本块自行 terminate_destroy（destroy 那
// 边认领时句柄还是 NULL，不会再释放它）。
- (void)prepareHandleWithSymbols:(const CCTVMPVSymbolTable *)syms enableHardwareDecoder:(BOOL)enableHardwareDecoder {
    mpv_handle *ctx = syms->create();
    if (!ctx) {
        host_mpv_lifecycle_abandon_prepare(_lifecycle);
        [self handleFailureWithCode:-1002 message:@"无法创建 libmpv 播放上下文"];
        return;
    }

    // Video output: Metal via libplacebo + MoltenVK (CAMetalLayer wid captured on main thread)
    CALayer *metalLayer = self.metalLayer;
    int64_t wid = (int64_t)(uintptr_t)(__bridge void *)metalLayer;
    [self mpvSetOptionInt:ctx name:"wid" value:wid];
    [self mpvSetOptionString:ctx name:"vo" value:"gpu-next"];
    [self mpvSetOptionString:ctx name:"gpu-api" value:"vulkan"];
    [self mpvSetOptionString:ctx name:"gpu-context" value:"moltenvk"];
    [self mpvSetOptionString:ctx name:"ao" value:"avfoundation"];
    [self mpvSetOptionString:ctx name:"hwdec" value:(enableHardwareDecoder ? "videotoolbox" : "no")];
    [self mpvSetOptionString:ctx name:"hwdec-codecs" value:"all"];
    [self mpvSetOptionString:ctx name:"deinterlace" value:"auto"];
    [self mpvSetOptionString:ctx name:"ytdl" value:"no"];
    [self mpvSetOptionString:ctx name:"keep-open" value:"no"];
    [self mpvSetOptionString:ctx name:"sub-auto" value:"no"];
    [self mpvSetOptionString:ctx name:"subs-with-matching-audio" value:"yes"];
    [self mpvSetOptionString:ctx name:"sub-ass" value:"yes"];
    [self mpvSetOptionString:ctx name:"pause" value:"yes"];

    [self.mpvLock lock];
    NSString *gravitySnapshot = self.prepareGravitySnapshot ?: AVLayerVideoGravityResizeAspect;
    float rateSnapshot = self.prepareRateSnapshot;
    BOOL mutedSnapshot = self.prepareMutedSnapshot;
    [self.mpvLock unlock];

    [self applyBufferOptionsOnHandle:ctx];
    [self configureHTTPHeadersOnHandle:ctx];
    [self applyGravity:gravitySnapshot onHandle:ctx];

    int initStatus = syms->initialize(ctx);
    if (initStatus < 0) {
        const char *errStr = syms->error_string(initStatus);
        NSString *msg = errStr ? [NSString stringWithUTF8String:errStr] : @"libmpv 初始化失败";
        syms->terminate_destroy(ctx);
        // Handle already released inline; no event thread was started,
        // so the lifecycle returns to IDLE (a fresh prepare may retry).
        host_mpv_lifecycle_abandon_prepare(_lifecycle);
        [self handleFailureWithCode:initStatus message:msg];
        return;
    }

    // Gate 2（见方法注释）。
    if (host_mpv_lifecycle_state(_lifecycle) != HOST_MPV_LC_PREPARED) {
        syms->terminate_destroy(ctx);
        return;
    }

    [self mpvObserveProperty:ctx tag:CCTVMPVReplyTimePos name:"time-pos" format:MPV_FORMAT_DOUBLE];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyDuration name:"duration" format:MPV_FORMAT_DOUBLE];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyCacheTime name:"demuxer-cache-time" format:MPV_FORMAT_DOUBLE];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyPausedForCache name:"paused-for-cache" format:MPV_FORMAT_FLAG];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyCacheSpeed name:"cache-speed" format:MPV_FORMAT_INT64];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyVideoWidth name:"video-params/w" format:MPV_FORMAT_INT64];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyVideoHeight name:"video-params/h" format:MPV_FORMAT_INT64];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyVideoRotate name:"video-params/rotate" format:MPV_FORMAT_INT64];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyEOFReached name:"eof-reached" format:MPV_FORMAT_FLAG];
    [self mpvObserveProperty:ctx tag:CCTVMPVReplyTrackListCount name:"track-list/count" format:MPV_FORMAT_INT64];

    // T20：初始化成功后一次性上报本次被拒的 option/observe（诊断开启
    // 时），不阻塞 prepare——被拒项只是记录，不改失败策略（旧行为是
    // 静默忽略；失败策略变更不在 T20 范围）。放 observe 之后上报，
    // observe 的失败也进同一事件。
    if (self.failedOptionNames.count && RuntimeDiagnostics.shared.enabled) {
        [RuntimeDiagnostics.shared recordEvent:@"mpv_option_failed" category:@"playback" fields:@{@"engine": @"mpv", @"options": [self.failedOptionNames componentsJoinedByString:@","]}];
    }
    [self.failedOptionNames removeAllObjects];

    // Hold mpvLock across final lifecycle gate, handle publication, event thread start,
    // and initial loadfile/rate/mute commands so destroy cannot interleave and UAF ctx.
    int loadErr = 0;
    [self.mpvLock lock];
    if (host_mpv_lifecycle_state(_lifecycle) != HOST_MPV_LC_PREPARED) {
        [self.mpvLock unlock];
        syms->terminate_destroy(ctx);
        return;
    }
    self.mpvHandle = ctx;

    // Spawn dedicated background event-loop thread using weakSelf so NSThread never retains self.
    __weak typeof(self) weakSelf = self;
    host_mpv_lifecycle_t *threadLC = host_mpv_lifecycle_retain(_lifecycle);
    NSValue *handleVal = [NSValue valueWithPointer:ctx];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf eventLoopMain:handleVal];
        } else {
            host_mpv_lifecycle_note_event_thread_exited(threadLC);
        }
        host_mpv_lifecycle_release(threadLC);
    }];
    thread.name = @"com.cctvhost.mpv.events";
    self.eventThread = thread;
    host_mpv_lifecycle_note_event_thread_started(_lifecycle);
    [thread start];

    NSString *loadTarget = self.url.isFileURL ? self.url.path : self.url.absoluteString;
    const char *loadCmd[] = {"loadfile", loadTarget.UTF8String, "replace", NULL};
    loadErr = syms->command_async(ctx, 0, loadCmd);
    if (loadErr >= 0) {
        if (rateSnapshot != 1.0f) {
            double speed = (double)rateSnapshot;
            [self mpvSetProperty:ctx name:"speed" format:MPV_FORMAT_DOUBLE value:&speed operation:@"setRate"];
        }
        if (mutedSnapshot) {
            int flag = 1;
            [self mpvSetProperty:ctx name:"mute" format:MPV_FORMAT_FLAG value:&flag operation:@"setMuted"];
        }
    }
    [self.mpvLock unlock];

    if (loadErr < 0) {
        const char *errStr = syms->error_string(loadErr);
        [self handleFailureWithCode:loadErr message:(errStr ? [NSString stringWithUTF8String:errStr] : @"加载媒体失败")];
        return;
    }

    // NSTimer 必须挂在有 runloop 的线程——命令队列没有 runloop，
    // 故回主线程 arm（旧语义：loadfile 发出后开始计首帧预算；pausedByUser 在方法内守卫）。
    [self runOnMain:^{ [self armFirstFrameWatchdog]; }];
}

- (void)applyBufferOptionsOnHandle:(mpv_handle *)ctx {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return;
    NSString *timeoutStr = [NSString stringWithFormat:@"%.0f", MAX(5.0, self.networkTimeout)];
    [self mpvSetOptionString:ctx name:"network-timeout" value:timeoutStr.UTF8String];
    [self mpvSetOptionString:ctx name:"cache" value:"yes"];
    if (self.prepareLiveHintSnapshot) {
        [self mpvSetOptionString:ctx name:"profile" value:"low-latency"];
        [self mpvSetOptionString:ctx name:"demuxer-max-bytes" value:"16MiB"];
        [self mpvSetOptionString:ctx name:"demuxer-readahead-secs" value:"12"];
    } else {
        [self mpvSetOptionString:ctx name:"demuxer-max-bytes" value:"64MiB"];
        [self mpvSetOptionString:ctx name:"demuxer-readahead-secs" value:"45"];
    }
}

- (void)configureHTTPHeadersOnHandle:(mpv_handle *)ctx {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx || !self.headers.count) return;
    for (NSString *rawKey in self.headers) {
        if (![rawKey isKindOfClass:NSString.class]) continue;
        NSString *rawVal = [self.headers[rawKey] isKindOfClass:NSString.class] ? self.headers[rawKey] : @"";
        NSString *key = CCTVMPVSanitizeHeaderValue(rawKey);
        NSString *val = CCTVMPVSanitizeHeaderValue(rawVal);
        if (!key.length || !val.length) continue;
        if ([key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@": \t"]].location != NSNotFound) continue;
        NSString *lower = key.lowercaseString;
        if ([lower isEqualToString:@"user-agent"]) {
            [self mpvSetOptionString:ctx name:"user-agent" value:val.UTF8String];
        } else if ([lower isEqualToString:@"referer"]) {
            [self mpvSetOptionString:ctx name:"referrer" value:val.UTF8String];
        } else {
            NSString *field = [NSString stringWithFormat:@"%@: %@", key, val];
            // Use http-header-fields-append per header so commas inside Accept/Cookie/Date values are not split.
            [self mpvSetOptionString:ctx name:"http-header-fields-append" value:field.UTF8String];
        }
    }
}

- (void)start {
    if (self.destroyed) return;
    self.pausedByUser = NO;
    self.wantStartAfterPrepare = YES;
    if(self.videoDisabledForBackground)return;
    // S2：暂停后恢复重新按剩余预算计时（watchdog 已存在时 arm 是 no-op；
    // prepare 尚未完成时不 arm，预算从 prepare 末尾开始计）。
    if (self.preparedNotified) [self armFirstFrameWatchdog];
    // Media commands may only touch the handle while the lifecycle is
    // PREPARED (T02/S1): after destroy the handle is gone.
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    // T20：状态转移仍在调用方同步做（旧语义：句柄未发布时不置 Playing，
    // 交给 FILE_LOADED 后的 start 再置）；set_property 进命令队列，
    // 锁内取句柄、锁内调用（与 destroy 的认领互斥，见旧代码纪律）。
    BOOL handleLive = NO;
    [self.mpvLock lock];
    handleLive = (self.mpvHandle != NULL);
    [self.mpvLock unlock];
    if (handleLive && (self.state == MediaPlaybackCicadaAdapterStatePaused || self.preparedNotified)) {
        self.state = MediaPlaybackCicadaAdapterStatePlaying;
    }
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        if (ctx) {
            int flag = 0;
            [strongSelf mpvSetProperty:ctx name:"pause" format:MPV_FORMAT_FLAG value:&flag operation:@"start"];
        }
        [strongSelf.mpvLock unlock];
    }];
}

- (void)pause {
    if (self.destroyed) return;
    self.pausedByUser = YES;
    self.wantStartAfterPrepare = NO;
    // S2：暂停/后台/等待用户确认时冻结首帧预算，不计启动超时（与 Cicada
    // adapter 的 firstFrameRemaining 同款；start 时按剩余预算重 arm）。
    if (self.firstFrameWatchdog) {
        self.firstFrameRemaining = MAX(0, self.firstFrameRemaining - (CACurrentMediaTime() - self.firstFrameBudgetStarted));
        [self cancelFirstFrameWatchdog];
    }
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    BOOL handleLive = NO;
    [self.mpvLock lock];
    handleLive = (self.mpvHandle != NULL);
    [self.mpvLock unlock];
    if (handleLive && self.state == MediaPlaybackCicadaAdapterStatePlaying) {
        self.state = MediaPlaybackCicadaAdapterStatePaused;
    }
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        if (ctx) {
            int flag = 1;
            [strongSelf mpvSetProperty:ctx name:"pause" format:MPV_FORMAT_FLAG value:&flag operation:@"pause"];
        }
        [strongSelf.mpvLock unlock];
    }];
}

- (void)stop {
    if (self.destroyed) return;
    self.preparedNotified = NO;
    self.wantStartAfterPrepare = NO;
    self.loading = NO;
    [self cancelFirstFrameWatchdog];
    [self finishPendingSeek:NO];
    // T20：stop 命令进命令队列（排在已发出的 seek/控制之后有序执行）；
    // 状态仍在调用方同步置 Idle（旧语义）。
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        const CCTVMPVSymbolTable *syms = strongSelf.syms;
        if (ctx && syms) {
            const char *stopCmd[] = {"stop", NULL};
            syms->command_async(ctx, 0, stopCmd);
        }
        [strongSelf.mpvLock unlock];
    }];
    self.state = MediaPlaybackCicadaAdapterStateIdle;
}

- (void)destroy {
    // Single-owner, idempotent teardown (T02/S1): exactly one caller
    // owns the release; concurrent or repeated destroy calls return
    // immediately. The teardown reference keeps the lifecycle object
    // alive until the background release finishes, so this block never
    // touches the adapter itself and may outlive it.
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_retain(_lifecycle);
    if (!host_mpv_lifecycle_begin_destroy(lc)) {
        host_mpv_lifecycle_release(lc);
        return;
    }
    self.destroyed = YES;
    self.delegate = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // T20：轨道缓存随 teardown 失效（availableTracks 本就以 lifecycle
    // 门禁，destroy 后返回 @[]；清缓存不让旧轨道名残留）。
    [self.mpvLock lock];
    self.cachedTracks = nil;
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    self.mpvHandle = NULL;
    self.eventThread = nil;
    UIView *retainedMetalView = self.metalView;
    [self.mpvLock unlock];

    if (NSThread.isMainThread) {
        [self cancelFirstFrameWatchdog];
        [self finishPendingSeek:NO];
    } else {
        NSTimer *watchdog = self.firstFrameWatchdog;
        self.firstFrameWatchdog = nil;
        NSTimer *seekTimer = self.seekTimeoutTimer;
        self.seekTimeoutTimer = nil;
        void (^cb)(BOOL) = self.pendingSeekCompletion;
        self.pendingSeekCompletion = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [watchdog invalidate];
            [seekTimer invalidate];
            if (cb) cb(NO);
        });
    }

    if (ctx && syms) {
        const char *quitCmd[] = {"quit", NULL};
        syms->command_async(ctx, 0, quitCmd);
        syms->wakeup(ctx);
        // Release the handle only after the event consumer has left
        // wait_event, on a background queue so teardown never blocks
        // the caller or the UI. Keep the Metal view and its backing layer
        // alive until MoltenVK has finished destroying the swapchain.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int exited = host_mpv_lifecycle_wait_event_thread_exit(lc, MediaPlaybackMPVDestroyEventExitTimeoutMs);
            if (!exited) {
                syms->wakeup(ctx);
                exited = host_mpv_lifecycle_wait_event_thread_exit(lc, MediaPlaybackMPVDestroyEventExitTimeoutMs);
                if (!exited) {
                    NSLog(@"[CCTVHost] MPV teardown deferred until the event thread exits");
                    exited = host_mpv_lifecycle_wait_event_thread_exit(lc, -1);
                }
            }
            if (exited) {
                syms->terminate_destroy(ctx);
                host_mpv_lifecycle_finish_destroy(lc);
            }
            host_mpv_lifecycle_release(lc);
            dispatch_async(dispatch_get_main_queue(), ^{ (void)retainedMetalView; });
        });
    } else {
        host_mpv_lifecycle_finish_destroy(lc);
        host_mpv_lifecycle_release(lc);
    }
}

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL finished))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self seekToTime:time completion:completion]; });
        return;
    }
    if (self.destroyed) {
        if (completion) completion(NO);
        return;
    }
    if (!isfinite(time) || !host_mpv_lifecycle_command_allowed(_lifecycle)) {
        if (completion) completion(NO);
        return;
    }
    // S3：新请求取消旧请求（完成 NO，一次且仅一次）；每个请求独立 id +
    // 目标 + 3 秒 deadline，过期未落点也完成 NO，不无限等待。
    // Reserve this request before notifying the previous caller. That callback
    // may synchronously start a newer seek or destroy this adapter.
    NSUInteger seekID = ++self.pendingSeekID;
    [self finishPendingSeek:NO];
    if (self.destroyed || self.pendingSeekID != seekID || !host_mpv_lifecycle_command_allowed(_lifecycle)) {
        if (completion) completion(NO);
        return;
    }
    self.pendingSeekCompletion = completion;
    self.pendingSeekTarget = MAX(0.0, time);
    self.seekEventObserved = NO;
    __weak typeof(self) weakSelf = self;
    [self runOnMain:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.destroyed || strongSelf.pendingSeekID != seekID) return;
        [strongSelf.seekTimeoutTimer invalidate];
        strongSelf.seekTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackMPVSeekTimeout
                                                                      repeats:NO
                                                                        block:^(__unused NSTimer *timer) {
            [weakSelf handleSeekTimeoutForID:seekID];
        }];
    }];
    NSTimeInterval clamped = MAX(0.0, time);
    NSString *target = [NSString stringWithFormat:@"%.3f", clamped];
    // T20：seek 命令进命令队列（与其它控制有序执行）。命令被拒时在主线
    // 程按 seekID 守卫完成 NO——排队期间新请求可能已替换本次请求，
    // 不得误完成新请求（旧同步版无此窗口）。
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) {
            if (strongSelf) [strongSelf runOnMain:^{
                if (!strongSelf.destroyed && strongSelf.pendingSeekID == seekID) [strongSelf finishPendingSeek:NO];
            }];
            return;
        }
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        const CCTVMPVSymbolTable *syms = strongSelf.syms;
        int err = -1;
        if (ctx && syms) {
            const char *seekCmd[] = {"seek", target.UTF8String, "absolute+exact", NULL};
            err = syms->command_async(ctx, 0, seekCmd);
        }
        [strongSelf.mpvLock unlock];
        if (err < 0) {
            [strongSelf runOnMain:^{
                if (!strongSelf.destroyed && strongSelf.pendingSeekID == seekID) [strongSelf finishPendingSeek:NO];
            }];
        }
    }];
}

- (void)setRate:(float)rate {
    float clamped = MIN(3.0f, MAX(0.5f, isfinite(rate) ? rate : 1.0f));
    _rate = clamped;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        if (ctx) {
            double speed = (double)clamped;
            [strongSelf mpvSetProperty:ctx name:"speed" format:MPV_FORMAT_DOUBLE value:&speed operation:@"setRate"];
        }
        [strongSelf.mpvLock unlock];
    }];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        if (ctx) {
            int flag = muted ? 1 : 0;
            [strongSelf mpvSetProperty:ctx name:"mute" format:MPV_FORMAT_FLAG value:&flag operation:@"setMuted"];
        }
        [strongSelf.mpvLock unlock];
    }];
}

- (BOOL)canSelectTracks {
    return host_mpv_lifecycle_command_allowed(_lifecycle);
}

- (NSArray<NSDictionary *> *)availableTracks {
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return @[];
    // T20：只读缓存（见扩展注释）——旧实现每次读都做约 300 次 mpv
    // IPC 往返（64 条 × type/id/title/lang/codec/selected），菜单
    // 打开时直接跑在主线程；现在重建只在命令队列上发生。
    [self.mpvLock lock];
    NSArray<NSDictionary *> *cached = self.cachedTracks ?: @[];
    [self.mpvLock unlock];
    return cached;
}

// T20：轨道枚举（旧 availableTracks 的本体，现只在命令队列上跑）。
// 仍是最多 64 条、同一字典形态；选中态取引擎同步值。
- (NSArray<NSDictionary *> *)enumerateTracksFromHandle:(mpv_handle *)ctx syms:(const CCTVMPVSymbolTable *)syms {
    if (!ctx || !syms) return @[];
    int64_t count = 0;
    syms->get_property(ctx, "track-list/count", MPV_FORMAT_INT64, &count);
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    for (int64_t i = 0; i < count && i < 64; i++) {
        NSString *prefix = [NSString stringWithFormat:@"track-list/%lld", i];
        char *rawType = syms->get_property_string(ctx, [prefix stringByAppendingString:@"/type"].UTF8String);
        if (!rawType) continue;
        NSString *typeStr = [NSString stringWithUTF8String:rawType] ?: @"";
        syms->free_mem(rawType);
        NSString *kind = nil;
        if ([typeStr isEqualToString:@"audio"]) kind = @"audio";
        else if ([typeStr isEqualToString:@"sub"]) kind = @"subtitle";
        else if ([typeStr isEqualToString:@"video"]) kind = @"video";
        if (!kind) continue;

        int64_t trackId = 0;
        syms->get_property(ctx, [prefix stringByAppendingString:@"/id"].UTF8String, MPV_FORMAT_INT64, &trackId);
        char *rawTitle = syms->get_property_string(ctx, [prefix stringByAppendingString:@"/title"].UTF8String);
        char *rawLang = syms->get_property_string(ctx, [prefix stringByAppendingString:@"/lang"].UTF8String);
        char *rawCodec = syms->get_property_string(ctx, [prefix stringByAppendingString:@"/codec"].UTF8String);
        NSString *title = rawTitle ? [NSString stringWithUTF8String:rawTitle] : @"";
        NSString *lang = rawLang ? [NSString stringWithUTF8String:rawLang] : @"";
        NSString *codec = rawCodec ? [NSString stringWithUTF8String:rawCodec] : @"";
        if (rawTitle) syms->free_mem(rawTitle);
        if (rawLang) syms->free_mem(rawLang);
        if (rawCodec) syms->free_mem(rawCodec);

        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (title.length) [parts addObject:title];
        if (lang.length) [parts addObject:lang.uppercaseString];
        if (codec.length) [parts addObject:codec.uppercaseString];
        NSString *display = parts.count ? [parts componentsJoinedByString:@" · "] : [NSString stringWithFormat:@"%@ #%lld", kind, trackId];
        // T09：真实选中状态（track-list/N/selected，引擎同步值），供菜单
        // 标当前选中与验证切换结果；未知时不填 BOOL、不伪造。
        int selectedFlag = 0;
        int selectedErr = syms->get_property(ctx, [prefix stringByAppendingString:@"/selected"].UTF8String, MPV_FORMAT_FLAG, &selectedFlag);
        // Encode type in upper bits so selectTrackWithIndex: knows aid vs sid vs vid.
        NSInteger encodedIndex = (NSInteger)trackId;
        if ([kind isEqualToString:@"subtitle"]) encodedIndex += 10000;
        else if ([kind isEqualToString:@"video"]) encodedIndex += 20000;
        if (selectedErr >= 0) {
            [tracks addObject:@{@"type": kind, @"index": @(encodedIndex), @"name": display, @"selected": @(selectedFlag != 0)}];
        } else {
            [tracks addObject:@{@"type": kind, @"index": @(encodedIndex), @"name": display, @"selected": @"unknown"}];
        }
    }
    return tracks.copy;
}

// T20：FILE_LOADED 与 track-list/count 变化时在命令队列上重建缓存
// （与控制命令串行，不与 select 的乐观更新交错）。
- (void)rebuildCachedTracksOnCommandQueue {
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        const CCTVMPVSymbolTable *syms = strongSelf.syms;
        NSArray<NSDictionary *> *tracks = [strongSelf enumerateTracksFromHandle:ctx syms:syms];
        if (ctx && syms) strongSelf.cachedTracks = tracks;
        [strongSelf.mpvLock unlock];
    }];
}

// T20：select 成功后乐观更新缓存选中态——T09 验证（verifyTrack*）
// 重查 availableTracks，必须看到本次切换的结果；只改同 kind 的
// selected 位，其它字段不动。下一次重建（轨道数变化时）再与引擎
// 同步一次，收敛残余偏差。调用方已持有 mpvLock（在命令队列内原子更新）。
- (void)updateCachedTrackSelectionLockedForIndex:(NSInteger)index kind:(NSString *)kind selected:(BOOL)selected {
    NSArray<NSDictionary *> *cached = self.cachedTracks;
    if (!cached.count) return;
    NSMutableArray<NSDictionary *> *updated = [NSMutableArray arrayWithCapacity:cached.count];
    for (NSDictionary *track in cached) {
        if (![track[@"type"] isEqual:kind]) { [updated addObject:track]; continue; }
        NSMutableDictionary *copy = [track mutableCopy];
        BOOL isTarget = [track[@"index"] integerValue] == index;
        copy[@"selected"] = @(selected && isTarget);
        [updated addObject:copy];
    }
    self.cachedTracks = updated.copy;
}

- (void)updateCachedTrackSelectionForIndex:(NSInteger)index kind:(NSString *)kind selected:(BOOL)selected {
    [self.mpvLock lock];
    [self updateCachedTrackSelectionLockedForIndex:index kind:kind selected:selected];
    [self.mpvLock unlock];
}

- (BOOL)selectTrackWithIndex:(NSInteger)index {
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return NO;
    // T20：set_property 在命令队列上同步执行（runOnCommandQueueSync），
    // 返回时切换已下发——T09 验证（verifyTrack*，重查 availableTracks）
    // 的时序与旧同步版一致。句柄未发布时直接 NO，不等队列。
    // 成功后在命令队列持锁状态下原子更新缓存选中态，避免与 rebuild 交错。
    [self.mpvLock lock];
    BOOL handleLive = (self.mpvHandle != NULL);
    [self.mpvLock unlock];
    if (!handleLive) return NO;
    // T09：关闭哨兵——0 = 关闭音频轨道，10000 = 关闭字幕轨道，20000 = 关闭视频轨道
    // （mpv 的 aid/sid/vid 设为 "no"；set_property_string 同步返回即实际切换结果）。
    __block int err = -1;
    if (index == 0 || index == 10000 || index == 20000) {
        const char *prop = (index == 0) ? "aid" : (index == 10000 ? "sid" : "vid");
        NSString *kind = (index == 0) ? @"audio" : (index == 10000 ? @"subtitle" : @"video");
        [self runOnCommandQueueSync:^{
            [self.mpvLock lock];
            mpv_handle *ctx = self.mpvHandle;
            if (ctx) err = [self mpvSetPropertyString:ctx name:prop value:"no" operation:@"selectTrack"];
            [self.mpvLock unlock];
            if (err >= 0) [self updateCachedTrackSelectionForIndex:index kind:kind selected:NO];
        }];
        return err >= 0;
    }
    if (index < 0) return NO;
    const char *prop = "aid";
    int64_t trackId = index;
    NSString *kind = @"audio";
    if (index > 20000) {
        prop = "vid";
        trackId = index - 20000;
        kind = @"video";
    } else if (index > 10000) {
        prop = "sid";
        trackId = index - 10000;
        kind = @"subtitle";
    }
    [self runOnCommandQueueSync:^{
        [self.mpvLock lock];
        mpv_handle *ctx = self.mpvHandle;
        if (ctx) err = [self mpvSetProperty:ctx name:prop format:MPV_FORMAT_INT64 value:&trackId operation:@"selectTrack"];
        [self.mpvLock unlock];
        if (err >= 0) [self updateCachedTrackSelectionForIndex:index kind:kind selected:YES];
    }];
    return err >= 0;
}

- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL {
    if (!subtitleURL.absoluteString.length || self.destroyed) return NO;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return NO;
    // T20：唯一调用方（VC 外挂字幕）不读返回值；sub-add 进命令队列
    // 异步下发，返回值只表示"已接受下发"（与 Cicada 的约定同款）。
    // 句柄未发布时直接 NO。
    [self.mpvLock lock];
    BOOL handleLive = (self.mpvHandle != NULL);
    [self.mpvLock unlock];
    if (!handleLive) return NO;
    NSURL *urlCopy = subtitleURL;
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        const CCTVMPVSymbolTable *syms = strongSelf.syms;
        if (ctx && syms) {
            NSString *subTarget = urlCopy.isFileURL ? urlCopy.path : urlCopy.absoluteString;
            const char *cmd[] = {"sub-add", subTarget.UTF8String, "select", NULL};
            int err = syms->command_async(ctx, 0, cmd);
            if (err < 0) [strongSelf recordMPVControlFailure:@"addExternalSubtitle" property:@"sub-add"];
        }
        [strongSelf.mpvLock unlock];
    }];
    return YES;
}

- (void)applyVideoGravity:(NSString *)gravity {
    NSString *gravityCopy = [gravity ?: AVLayerVideoGravityResizeAspect copy];
    [self.mpvLock lock];
    self.pendingGravity = gravityCopy;
    self.prepareGravitySnapshot = gravityCopy;
    [self.mpvLock unlock];
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    __weak typeof(self) weakSelf = self;
    [self runOnCommandQueue:^{
        MediaPlaybackMPVAdapter *strongSelf = weakSelf;
        if (!strongSelf || !host_mpv_lifecycle_command_allowed(strongSelf->_lifecycle)) return;
        [strongSelf.mpvLock lock];
        mpv_handle *ctx = strongSelf.mpvHandle;
        if (ctx) [strongSelf applyGravity:gravityCopy onHandle:ctx];
        [strongSelf.mpvLock unlock];
    }];
}

- (void)applyGravity:(NSString *)gravity onHandle:(mpv_handle *)ctx {
    if (!ctx) return;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        [self mpvSetPropertyString:ctx name:"keepaspect" value:"yes" operation:@"applyGravity"];
        double panscan = 1.0;
        [self mpvSetProperty:ctx name:"panscan" format:MPV_FORMAT_DOUBLE value:&panscan operation:@"applyGravity"];
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        [self mpvSetPropertyString:ctx name:"keepaspect" value:"no" operation:@"applyGravity"];
        double panscan = 0.0;
        [self mpvSetProperty:ctx name:"panscan" format:MPV_FORMAT_DOUBLE value:&panscan operation:@"applyGravity"];
    } else {
        [self mpvSetPropertyString:ctx name:"keepaspect" value:"yes" operation:@"applyGravity"];
        double panscan = 0.0;
        [self mpvSetProperty:ctx name:"panscan" format:MPV_FORMAT_DOUBLE value:&panscan operation:@"applyGravity"];
    }
}

- (void)armFirstFrameWatchdog {
    // S2：只按剩余预算 arm 一次；暂停冻结后 start 按剩余重 arm，已有
    // 计时器/已报首帧/已报纯音频/已销毁/用户暂停态时是 no-op。
    if (self.firstFrameWatchdog || self.firstFrameNotified || self.audioOnlyNotified || self.destroyed || self.pausedByUser || self.videoDisabledForBackground) return;
    __weak typeof(self) weakSelf = self;
    self.firstFrameBudgetStarted = CACurrentMediaTime();
    self.firstFrameWatchdog = [NSTimer scheduledTimerWithTimeInterval:MAX(0.01, self.firstFrameRemaining)
                                                              repeats:NO
                                                                block:^(__unused NSTimer *timer) {
        [weakSelf handleFirstFrameTimeout];
    }];
}

- (void)cancelFirstFrameWatchdog {
    [self.firstFrameWatchdog invalidate];
    self.firstFrameWatchdog = nil;
}

- (void)handleFirstFrameTimeout {
    if (self.destroyed || self.firstFrameNotified || self.audioOnlyNotified) return;
    [self handleFailureWithCode:-1008 message:@"MPV 全能内核首帧渲染超时"];
}

- (void)handleAudioOnlyOnMain {
    // S2：纯音频开始——时间在前进但始终无视频轨道。不是视频首帧：
    // videoFrameReady 保持 NO；视频随后出现仍可再报首帧。
    if (self.destroyed || self.firstFrameNotified || self.audioOnlyNotified) return;
    self.audioOnlyNotified = YES;
    self.loading = NO;
    [self cancelFirstFrameWatchdog];
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapterDidStartAudioOnly:)]) {
        [d cicadaAdapterDidStartAudioOnly:self];
    }
}

- (void)maybeCompletePendingSeek {
    // S3：只有落点在目标 ±1.0 秒内（或 seek 已触发且目标超出尾帧被钳位到 duration 附近）才算完成；无关重启不完成本次请求。
    if (!self.pendingSeekCompletion) return;
    BOOL withinTarget = fabs(self.currentPosition - self.pendingSeekTarget) <= MediaPlaybackMPVSeekPositionTolerance;
    BOOL clampedAtEnd = (self.seekEventObserved && self.duration > 0 &&
                         self.pendingSeekTarget >= self.duration - MediaPlaybackMPVSeekPositionTolerance &&
                         self.currentPosition >= self.duration - 2.0);
    if (withinTarget || clampedAtEnd) {
        [self finishPendingSeek:YES];
    }
}

- (void)handleSeekTimeoutForID:(NSUInteger)seekID {
    if (self.destroyed || self.pendingSeekID != seekID) return;
    [self finishPendingSeek:NO];
}

// T20/S4：高频事件向主线程的合并派发——三个 helper 与旧分支内的
// runOnMain block 本体完全一致，只是调用点受 250ms 窗口节流；
// 终态/首帧/seek 完成/缓冲状态变化不走这里，始终即时派发。
- (void)dispatchPositionUpdate:(double)pos {
    [self runOnMain:^{
        if (self.destroyed || !isfinite(pos) || pos < 0) return;
        if (!self.hasInitialPosition) {
            self.initialPosition = pos;
            self.hasInitialPosition = YES;
        }
        self.currentPosition = pos;
        double elapsedFromStart = MAX(0.0, pos - self.initialPosition);
        // S2：time-pos 前进 ≠ 视频首帧——只有观测到视频
        // 轨道时才报首帧；无视频轨道且相对起始 PTS 前进超过 1.0 秒
        // 时报纯音频（免疫非零 PTS 直播流误判）。
        if (!self.firstFrameNotified && self.hasVideoTrack && pos > 0.05) {
            [self handleFirstFrameOnMain];
        } else if (!self.firstFrameNotified && !self.audioOnlyNotified && !self.hasVideoTrack && pos > MediaPlaybackMPVAudioOnlyPositionThreshold && elapsedFromStart > MediaPlaybackMPVAudioOnlyPositionThreshold) {
            [self handleAudioOnlyOnMain];
        }
        // S3：仅在收到 seek 事件后（或目标不在旧位置窗口内）由 time-pos 完成 seek。
        if (self.seekEventObserved) {
            [self maybeCompletePendingSeek];
        }
        id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(cicadaAdapter:didUpdatePosition:duration:)]) {
            [d cicadaAdapter:self didUpdatePosition:self.currentPosition duration:self.duration];
        }
    }];
}

- (void)dispatchDownloadSpeedUpdate:(double)bytesPerSec {
    [self runOnMain:^{
        if (self.destroyed || bytesPerSec < 0) return;
        id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(cicadaAdapter:didUpdateDownloadSpeed:)]) {
            [d cicadaAdapter:self didUpdateDownloadSpeed:bytesPerSec * 8.0];
        }
    }];
}

- (void)dispatchCacheTimeUpdate:(double)buf {
    [self runOnMain:^{
        if (self.destroyed || !isfinite(buf) || buf < 0) return;
        // S5：demuxer-cache-time 是缓存末尾包的绝对媒体
        // 时间戳（缓存结束点），不是"已缓冲时长"；上层
        // 用 bufferedPosition - currentPosition 算 ahead。
        self.bufferedPosition = buf;
    }];
}

- (void)flushPendingPositionImmediately {
    if (self.hasPendingPosition) {
        self.lastPositionDispatchAt = CACurrentMediaTime();
        double pos = self.pendingPosition;
        self.hasPendingPosition = NO;
        [self dispatchPositionUpdate:pos];
    }
}

// T20：事件循环每次 wake（wait_event 返回，含 0.25s 超时空转）都调
// 一次——把窗口内攒下的最新值刷到主线程。只由事件线程调用。
- (void)flushPendingCoalescedEventsIfDue {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.hasPendingPosition && now - self.lastPositionDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
        self.lastPositionDispatchAt = now;
        double pos = self.pendingPosition;
        self.hasPendingPosition = NO;
        [self dispatchPositionUpdate:pos];
    }
    if (self.hasPendingSpeed && now - self.lastSpeedDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
        self.lastSpeedDispatchAt = now;
        double bytesPerSec = self.pendingSpeedBytesPerSec;
        self.hasPendingSpeed = NO;
        [self dispatchDownloadSpeedUpdate:bytesPerSec];
    }
    if (self.hasPendingCacheTime && now - self.lastCacheTimeDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
        self.lastCacheTimeDispatchAt = now;
        double buf = self.pendingCacheTime;
        self.hasPendingCacheTime = NO;
        [self dispatchCacheTimeUpdate:buf];
    }
}

- (void)eventLoopMain:(NSValue *)handleValue {
    @autoreleasepool {
        mpv_handle *ctx = (mpv_handle *)handleValue.pointerValue;
        const CCTVMPVSymbolTable *syms = self.syms;
        if (!ctx || !syms) {
            host_mpv_lifecycle_note_event_thread_exited(_lifecycle);
            return;
        }
        // Never touch the handle if teardown already claimed it: the
        // destroy path waits for this exit note before terminate_destroy,
        // so leaving here without a wait_event call is always safe
        // (covers a thread that starts after destroy was requested).
        if (!host_mpv_lifecycle_command_allowed(_lifecycle)) {
            host_mpv_lifecycle_note_event_thread_exited(_lifecycle);
            return;
        }

        while (!self.destroyed) {
            // T20：每轮一个 autoreleasepool——旧外层 pool 覆盖整个长时
            // 循环，事件 payload 的临时对象攒到线程退出才释放。
            @autoreleasepool {
                cctv_mpv_event *ev = syms->wait_event(ctx, 0.25);
                // T20：每次 wake 都刷一次攒下的高频值（含超时空转），
                // 保证最新位置/速度/缓冲在 250ms 内到达主线程。
                [self flushPendingCoalescedEventsIfDue];
                if (!ev) continue;
                if (ev->event_id == MPV_EVENT_NONE) continue;
                if (ev->event_id == MPV_EVENT_SHUTDOWN) break;

            switch (ev->event_id) {
                case MPV_EVENT_FILE_LOADED: {
                    // T20：文件加载完成即重建轨道缓存（命令队列上枚举）。
                    [self rebuildCachedTracksOnCommandQueue];
                    [self runOnMain:^{ [self handleFileLoadedOnMain]; }];
                    break;
                }
                case MPV_EVENT_SEEK: {
                    [self runOnMain:^{
                        if (!self.destroyed) self.seekEventObserved = YES;
                    }];
                    break;
                }
                case MPV_EVENT_PLAYBACK_RESTART: {
                    [self flushPendingPositionImmediately];
                    [self runOnMain:^{
                        // S2：重启只证明解码器恢复输出，不证明视频画面——只有
                        // 观测到视频轨道时才算视频首帧（纯音频流的重启不报）。
                        if (self.hasVideoTrack) [self handleFirstFrameOnMain];
                        // S3：重启经 maybeCompletePendingSeek 完成本次 seek 请求。
                        [self maybeCompletePendingSeek];
                    }];
                    break;
                }
                case MPV_EVENT_END_FILE: {
                    [self flushPendingPositionImmediately];
                    cctv_mpv_event_end_file *endInfo = (cctv_mpv_event_end_file *)ev->data;
                    int reason = endInfo ? endInfo->reason : MPV_END_FILE_REASON_EOF;
                    int errCode = endInfo ? endInfo->error : 0;
                    NSString *errMsg = (errCode < 0 && syms->error_string(errCode))
                        ? [NSString stringWithUTF8String:syms->error_string(errCode)]
                        : @"播放流异常中断";
                    [self runOnMain:^{
                        if (reason == MPV_END_FILE_REASON_EOF) {
                            if (!self.preparedNotified && !self.firstFrameNotified) {
                                [self handleFailureWithCode:-1009 message:@"媒体流为空或提前结束"];
                            } else {
                                [self handleCompletionOnMain];
                            }
                        } else if (reason == MPV_END_FILE_REASON_ERROR) {
                            [self handleFailureWithCode:errCode message:errMsg];
                        }
                    }];
                    break;
                }
                case MPV_EVENT_PROPERTY_CHANGE: {
                    cctv_mpv_event_property *prop = (cctv_mpv_event_property *)ev->data;
                    if (!prop || !prop->data) break;
                    uint64_t tag = ev->reply_userdata;
                    if (tag == CCTVMPVReplyTimePos && prop->format == MPV_FORMAT_DOUBLE) {
                        double pos = *(double *)prop->data;
                        // T20：time-pos 可达每帧一次——主线程派发节流到
                        // 4Hz，窗口内只留最新值（flush 在每次 wake 时刷）。
                        CFTimeInterval now = CACurrentMediaTime();
                        if (now - self.lastPositionDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
                            self.lastPositionDispatchAt = now;
                            self.hasPendingPosition = NO;
                            [self dispatchPositionUpdate:pos];
                        } else {
                            self.pendingPosition = pos;
                            self.hasPendingPosition = YES;
                        }
                    } else if (tag == CCTVMPVReplyDuration && prop->format == MPV_FORMAT_DOUBLE) {
                        double dur = *(double *)prop->data;
                        // T20：时长只在变化时转发（加载/切流时变一次，
                        // 旧实现每次事件都派发主线程）。
                        if (isfinite(dur) && dur >= 0 && (!self.hasForwardedDuration || dur != self.lastForwardedDuration)) {
                            self.hasForwardedDuration = YES;
                            self.lastForwardedDuration = dur;
                            [self runOnMain:^{
                                if (self.destroyed) return;
                                self.duration = dur;
                            }];
                        }
                    } else if (tag == CCTVMPVReplyCacheTime && prop->format == MPV_FORMAT_DOUBLE) {
                        double buf = *(double *)prop->data;
                        // T20：与 time-pos 同款 4Hz 合并。
                        CFTimeInterval now = CACurrentMediaTime();
                        if (now - self.lastCacheTimeDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
                            self.lastCacheTimeDispatchAt = now;
                            self.hasPendingCacheTime = NO;
                            [self dispatchCacheTimeUpdate:buf];
                        } else {
                            self.pendingCacheTime = buf;
                            self.hasPendingCacheTime = YES;
                        }
                    } else if (tag == CCTVMPVReplyPausedForCache && prop->format == MPV_FORMAT_FLAG) {
                        BOOL isBuffering = (*(int *)prop->data) != 0;
                        [self runOnMain:^{
                            if (self.destroyed) return;
                            self.loading = isBuffering;
                            id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
                            if ([d respondsToSelector:@selector(cicadaAdapter:didUpdateLoading:progress:)]) {
                                [d cicadaAdapter:self didUpdateLoading:isBuffering progress:isBuffering ? 0.5f : 1.0f];
                            }
                        }];
                    } else if (tag == CCTVMPVReplyCacheSpeed && prop->format == MPV_FORMAT_INT64) {
                        int64_t bytesPerSec = *(int64_t *)prop->data;
                        // T20：网速回调与 time-pos 同款 4Hz 合并。
                        CFTimeInterval now = CACurrentMediaTime();
                        if (now - self.lastSpeedDispatchAt >= MediaPlaybackMPVEventCoalesceInterval) {
                            self.lastSpeedDispatchAt = now;
                            self.hasPendingSpeed = NO;
                            [self dispatchDownloadSpeedUpdate:(double)bytesPerSec];
                        } else {
                            self.pendingSpeedBytesPerSec = (double)bytesPerSec;
                            self.hasPendingSpeed = YES;
                        }
                    } else if (tag == CCTVMPVReplyVideoWidth && prop->format == MPV_FORMAT_INT64) {
                        int64_t w = *(int64_t *)prop->data;
                        [self runOnMain:^{
                            if (self.destroyed || w <= 0) return;
                            self.hasVideoTrack = YES;
                            self.lastVideoSize = CGSizeMake((CGFloat)w, self.lastVideoSize.height);
                            [self handleVideoGeometryUpdate];
                        }];
                    } else if (tag == CCTVMPVReplyVideoHeight && prop->format == MPV_FORMAT_INT64) {
                        int64_t h = *(int64_t *)prop->data;
                        [self runOnMain:^{
                            if (self.destroyed || h <= 0) return;
                            self.hasVideoTrack = YES;
                            self.lastVideoSize = CGSizeMake(self.lastVideoSize.width, (CGFloat)h);
                            [self handleVideoGeometryUpdate];
                        }];
                    } else if (tag == CCTVMPVReplyVideoRotate && prop->format == MPV_FORMAT_INT64) {
                        int64_t rot = *(int64_t *)prop->data;
                        [self runOnMain:^{
                            if (self.destroyed) return;
                            self.lastVideoRotation = (NSInteger)rot;
                            [self handleVideoGeometryUpdate];
                        }];
                    } else if (tag == CCTVMPVReplyEOFReached && prop->format == MPV_FORMAT_FLAG) {
                        BOOL reached = (*(int *)prop->data) != 0;
                        if (reached) [self runOnMain:^{ [self handleCompletionOnMain]; }];
                    } else if (tag == CCTVMPVReplyTrackListCount && prop->format == MPV_FORMAT_INT64) {
                        // T20：轨道数变了——重建缓存（命令队列上枚举）。
                        [self rebuildCachedTracksOnCommandQueue];
                    }
                    break;
                }
                default:
                    break;
            }
            } // per-iteration pool (T20)
        }
    }
    // Every exit path signals the destroy handshake, so the teardown
    // wait can never observe a live consumer that already left.
    host_mpv_lifecycle_note_event_thread_exited(_lifecycle);
}

- (void)handleFileLoadedOnMain {
    if (self.destroyed || self.preparedNotified) return;
    self.preparedNotified = YES;
    self.loading = NO;
    if (self.wantStartAfterPrepare) {
        [self start];
    } else {
        self.state = MediaPlaybackCicadaAdapterStatePaused;
    }
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapterDidPrepare:)]) {
        [d cicadaAdapterDidPrepare:self];
    }
}

- (void)handleFirstFrameOnMain {
    if (self.destroyed || self.firstFrameNotified) return;
    self.firstFrameNotified = YES;
    self.loading = NO;
    [self cancelFirstFrameWatchdog];
    if (self.wantStartAfterPrepare) self.state = MediaPlaybackCicadaAdapterStatePlaying;
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapterDidShowFirstFrame:)]) {
        [d cicadaAdapterDidShowFirstFrame:self];
    }
}

- (void)handleCompletionOnMain {
    if (self.destroyed || self.completionNotified) return;
    self.completionNotified = YES;
    self.loading = NO;
    [self cancelFirstFrameWatchdog];
    [self finishPendingSeek:NO];
    self.state = MediaPlaybackCicadaAdapterStateCompleted;
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapterDidComplete:)]) {
        [d cicadaAdapterDidComplete:self];
    }
}

- (NSInteger)lastErrorCode { return _lastErrorCode; }

- (NSDictionary<NSString *, id> *)playbackStatistics {
    // S5：只填引擎真实上报的值；引擎不暴露的键是字符串 @"unknown"，
    // 绝不伪造数字。键契约见 CCTVPlaybackEngineProtocol.h 的
    // playbackStatistics 注释。
    // bufferedPosition 是 demuxer-cache-time 的原值：缓存末尾包的绝对
    // 媒体时间戳（不是"已缓冲时长"）；bufferedAheadSeconds 是它与当前
    // 位置之差，下限钳到 0。
    id hwdec = @"unknown", videoBitrate = @"unknown", audioBitrate = @"unknown";
    id fps = @"unknown", droppedFrames = @"unknown", cacheSeconds = @"unknown";
    // T20：7 次属性读取进命令队列同步执行（与控制命令串行；prepare
    // 的 loadfile 已是 async，队列无长任务）。句柄未发布时直接返回
    // unknown，不等队列——与旧行为一致。
    BOOL handleLive = NO;
    if (host_mpv_lifecycle_command_allowed(_lifecycle)) {
        [self.mpvLock lock];
        handleLive = (self.mpvHandle != NULL);
        [self.mpvLock unlock];
    }
    if (handleLive) {
        __block id blockHwdec = @"unknown", blockVideoBitrate = @"unknown", blockAudioBitrate = @"unknown";
        __block id blockFps = @"unknown", blockDroppedFrames = @"unknown", blockCacheSeconds = @"unknown";
        [self runOnCommandQueueSync:^{
            if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
            [self.mpvLock lock];
            mpv_handle *ctx = self.mpvHandle;
            const CCTVMPVSymbolTable *syms = self.syms;
            if (ctx && syms) {
                char *hw = syms->get_property_string(ctx, "hwdec-current");
                if (hw) {
                    blockHwdec = [NSString stringWithUTF8String:hw] ?: @"unknown";
                    syms->free_mem(hw);
                }
                int64_t vbr = -1;
                if (syms->get_property(ctx, "video-bitrate", MPV_FORMAT_INT64, &vbr) >= 0 && vbr >= 0) blockVideoBitrate = @(vbr);
                int64_t abr = -1;
                if (syms->get_property(ctx, "audio-bitrate", MPV_FORMAT_INT64, &abr) >= 0 && abr >= 0) blockAudioBitrate = @(abr);
                double f = 0;
                if (syms->get_property(ctx, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &f) >= 0 && f > 0) blockFps = @(f);
                int64_t drop = -1;
                if (syms->get_property(ctx, "decoder-frame-drop-count", MPV_FORMAT_INT64, &drop) >= 0 && drop >= 0) blockDroppedFrames = @(drop);
                double cache = 0;
                if (syms->get_property(ctx, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cache) >= 0 && cache >= 0) blockCacheSeconds = @(cache);
            }
            [self.mpvLock unlock];
        }];
        hwdec = blockHwdec; videoBitrate = blockVideoBitrate; audioBitrate = blockAudioBitrate;
        fps = blockFps; droppedFrames = blockDroppedFrames; cacheSeconds = blockCacheSeconds;
    }
    NSTimeInterval ahead = MAX(0, self.bufferedPosition - self.currentPosition);
    return @{@"engine": @"mpv",
             @"hwdec": hwdec,
             @"videoBitrate": videoBitrate,
             @"audioBitrate": audioBitrate,
             @"fps": fps,
             @"droppedFrames": droppedFrames,
             @"cacheSeconds": cacheSeconds,
             @"bufferedPosition": @(self.bufferedPosition),
             @"bufferedAheadSeconds": @(ahead),
             @"currentPosition": @(self.currentPosition),
             @"duration": @(self.duration),
             @"state": @(self.state),
             @"stallCount": @"unknown"};
}

- (void)handleFailureWithCode:(NSInteger)code message:(NSString *)message {
    [self runOnMain:^{
        if (self.destroyed) return;
        self.loading = NO;
        self.lastErrorCode = code;
        [self cancelFirstFrameWatchdog];
        [self finishPendingSeek:NO];
        self.state = MediaPlaybackCicadaAdapterStateFailed;
        NSError *err = [NSError errorWithDomain:MediaPlaybackMPVAdapterErrorDomain
                                           code:code
                                       userInfo:@{NSLocalizedDescriptionKey: message ?: @"MPV 播放失败"}];
        id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(cicadaAdapter:didFailWithError:)]) {
            [d cicadaAdapter:self didFailWithError:err];
        }
    }];
}

- (void)handleVideoGeometryUpdate {
    if (self.destroyed || self.lastVideoSize.width <= 0 || self.lastVideoSize.height <= 0) return;
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapter:didUpdateVideoSize:rotation:)]) {
        [d cicadaAdapter:self didUpdateVideoSize:self.lastVideoSize rotation:self.lastVideoRotation];
    }
}

- (void)finishPendingSeek:(BOOL)finished {
    // S3：完成一次且只通知一次；成功才发 didSeek（与 Cicada adapter 的
    // finishPendingSeekWithFinished: 同款）。
    [self.seekTimeoutTimer invalidate];
    self.seekTimeoutTimer = nil;
    void (^cb)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    if (cb) cb(finished);
    if (finished) {
        id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(cicadaAdapterDidSeek:)]) {
            [d cicadaAdapterDidSeek:self];
        }
    }
}

#pragma mark - AVSampleBufferDisplayLayer Picture-in-Picture Bridge

// T10/F1：MPV 的 PiP 目前只有控制骨架，没有视频供帧——全文件无任何
// sample enqueue（真实输出是 Metal）。isPictureInPictureSupported 只
// 返回设备支持会谎称支持 PiP（打开是黑窗），故先标记为未实现：
// supported 返回 NO，start 是 no-op，不建空 PiP 窗。供帧由 T24 实现后
// 再开放（pipDisplayLayer/pipController 属性与 delegate 方法保留给 T24）。
- (BOOL)isPictureInPictureSupported {
    return NO;
}

- (BOOL)isPictureInPictureActive {
    return self.pipController.isPictureInPictureActive;
}

- (void)startPictureInPicture {
    // T10：未实现——没有视频 sample 可供帧，建 AVSampleBufferDisplayLayer
    // 也只会得到黑窗；不启动、不创建 controller。
    return;
}

- (void)stopPictureInPicture {
    if (self.pipController.isPictureInPictureActive) {
        [self.pipController stopPictureInPicture];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController setPlaying:(BOOL)playing {
    (void)pictureInPictureController;
    if (playing) [self start];
    else [self pause];
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    if (self.liveStreamHint || self.duration <= 0) {
        return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
    }
    return CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(self.duration, 600));
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    return self.state != MediaPlaybackCicadaAdapterStatePlaying;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
    (void)pictureInPictureController;
    (void)newRenderSize;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler {
    (void)pictureInPictureController;
    NSTimeInterval delta = CMTimeGetSeconds(skipInterval);
    NSTimeInterval target = MAX(0.0, self.currentPosition + (isfinite(delta) ? delta : 0.0));
    [self seekToTime:target completion:^(__unused BOOL finished) {
        if (completionHandler) completionHandler();
    }];
}

@end
