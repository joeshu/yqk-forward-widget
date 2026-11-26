#import "MediaPlaybackMPVAdapter.h"
#import "HostMPVLifecycle.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <stdint.h>

NSString * const MediaPlaybackMPVAdapterErrorDomain = @"CCTVHost.MediaPlaybackMPVAdapter";

static NSTimeInterval const MediaPlaybackMPVFirstFrameTimeout = 20.0;
// Bounded wait for the event thread to leave mpv_wait_event before the
// handle is released in destroy (T02/S1). The wait never blocks the
// caller: on timeout teardown proceeds anyway and the state still closes.
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
        if (!dl) return;

#define LOAD_MPV_SYM(field, sym) table.field = dlsym(dl, sym); if (!table.field) { dlclose(dl); return; }
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
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.contentScaleFactor = UIScreen.mainScreen.scale;
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.contentsScale = UIScreen.mainScreen.scale;
        metalLayer.framebufferOnly = YES;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.screen.scale > 0 ? self.window.screen.scale : UIScreen.mainScreen.scale;
    metalLayer.contentsScale = scale;
    CGSize boundsSize = self.bounds.size;
    if (boundsSize.width > 0 && boundsSize.height > 0) {
        metalLayer.drawableSize = CGSizeMake(ceil(boundsSize.width * scale), ceil(boundsSize.height * scale));
    }
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
};

@interface MediaPlaybackMPVAdapter () <AVPictureInPictureSampleBufferPlaybackDelegate> {
    // Terminal lifecycle core (T02/S1): heap-allocated and atomically
    // refcounted so the background teardown in destroy can outlive the
    // adapter object; the adapter holds one reference, released in dealloc.
    host_mpv_lifecycle_t *_lifecycle;
}
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic) NSTimeInterval networkTimeout;
@property (nonatomic, strong) CCTVMPVMetalLayerView *metalView;
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
@property (nonatomic) BOOL completionNotified;
@property (nonatomic) BOOL wantStartAfterPrepare;
@property (nonatomic) CGSize lastVideoSize;
@property (nonatomic) NSInteger lastVideoRotation;
@property (nonatomic, strong, nullable) NSTimer *firstFrameWatchdog;
@property (nonatomic, copy, nullable) void (^pendingSeekCompletion)(BOOL finished);
@property (nonatomic, strong, nullable) NSThread *eventThread;
@property (nonatomic, strong) NSLock *mpvLock;
@property (nonatomic, assign) mpv_handle *mpvHandle;
@property (nonatomic, assign) const CCTVMPVSymbolTable *syms;

- (void)runOnMain:(dispatch_block_t)block;
- (void)armFirstFrameWatchdog;
- (void)cancelFirstFrameWatchdog;
- (void)handleFirstFrameTimeout;
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
@end

@implementation MediaPlaybackMPVAdapter

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
        _metalView = [[CCTVMPVMetalLayerView alloc] initWithFrame:CGRectZero];
        _metalView.translatesAutoresizingMaskIntoConstraints = NO;
        _state = MediaPlaybackCicadaAdapterStateIdle;
        _rate = 1.0f;
        _pendingGravity = AVLayerVideoGravityResizeAspect;
        _mpvLock = [NSLock new];
        _lifecycle = host_mpv_lifecycle_create();
    }
    return self;
}

- (void)dealloc {
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
    self.completionNotified = NO;
    self.hasVideoTrack = NO;

    mpv_handle *ctx = syms->create();
    if (!ctx) {
        host_mpv_lifecycle_abandon_prepare(_lifecycle);
        [self handleFailureWithCode:-1002 message:@"无法创建 libmpv 播放上下文"];
        return;
    }

    // Video output: Metal via libplacebo + MoltenVK (CAMetalLayer wid)
    int64_t wid = (int64_t)(uintptr_t)(__bridge void *)self.metalView.layer;
    syms->set_option(ctx, "wid", MPV_FORMAT_INT64, &wid);
    syms->set_option_string(ctx, "vo", "gpu-next");
    syms->set_option_string(ctx, "gpu-api", "vulkan");
    syms->set_option_string(ctx, "gpu-context", "moltenvk");
    syms->set_option_string(ctx, "ao", "avfoundation");
    syms->set_option_string(ctx, "hwdec", enableHardwareDecoder ? "videotoolbox" : "no");
    syms->set_option_string(ctx, "hwdec-codecs", "all");
    syms->set_option_string(ctx, "deinterlace", "auto");
    syms->set_option_string(ctx, "ytdl", "no");
    syms->set_option_string(ctx, "keep-open", "no");
    syms->set_option_string(ctx, "sub-auto", "no");
    syms->set_option_string(ctx, "subs-with-matching-audio", "yes");
    syms->set_option_string(ctx, "sub-ass", "yes");
    syms->set_option_string(ctx, "pause", "yes");

    [self applyBufferOptionsOnHandle:ctx];
    [self configureHTTPHeadersOnHandle:ctx];
    [self applyGravity:self.pendingGravity onHandle:ctx];

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

    syms->observe_property(ctx, CCTVMPVReplyTimePos, "time-pos", MPV_FORMAT_DOUBLE);
    syms->observe_property(ctx, CCTVMPVReplyDuration, "duration", MPV_FORMAT_DOUBLE);
    syms->observe_property(ctx, CCTVMPVReplyCacheTime, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
    syms->observe_property(ctx, CCTVMPVReplyPausedForCache, "paused-for-cache", MPV_FORMAT_FLAG);
    syms->observe_property(ctx, CCTVMPVReplyCacheSpeed, "cache-speed", MPV_FORMAT_INT64);
    syms->observe_property(ctx, CCTVMPVReplyVideoWidth, "video-params/w", MPV_FORMAT_INT64);
    syms->observe_property(ctx, CCTVMPVReplyVideoHeight, "video-params/h", MPV_FORMAT_INT64);
    syms->observe_property(ctx, CCTVMPVReplyVideoRotate, "video-params/rotate", MPV_FORMAT_INT64);
    syms->observe_property(ctx, CCTVMPVReplyEOFReached, "eof-reached", MPV_FORMAT_FLAG);

    [self.mpvLock lock];
    self.mpvHandle = ctx;
    [self.mpvLock unlock];

    // Spawn dedicated background event-loop thread so mpv_wait_event never stalls GCD.
    NSThread *thread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(eventLoopMain:)
                                                 object:[NSValue valueWithPointer:ctx]];
    thread.name = @"com.cctvhost.mpv.events";
    self.eventThread = thread;
    host_mpv_lifecycle_note_event_thread_started(_lifecycle);
    [thread start];

    const char *loadCmd[] = {"loadfile", self.url.absoluteString.UTF8String, "replace", NULL};
    int loadErr = syms->command(ctx, loadCmd);
    if (loadErr < 0) {
        const char *errStr = syms->error_string(loadErr);
        [self handleFailureWithCode:loadErr message:(errStr ? [NSString stringWithUTF8String:errStr] : @"加载媒体失败")];
        return;
    }

    if (self.rate != 1.0f) [self setRate:self.rate];
    if (self.muted) [self setMuted:YES];
    [self armFirstFrameWatchdog];
}

- (void)applyBufferOptionsOnHandle:(mpv_handle *)ctx {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return;
    NSString *timeoutStr = [NSString stringWithFormat:@"%.0f", MAX(5.0, self.networkTimeout)];
    syms->set_option_string(ctx, "network-timeout", timeoutStr.UTF8String);
    syms->set_option_string(ctx, "cache", "yes");
    if (self.liveStreamHint) {
        syms->set_option_string(ctx, "profile", "low-latency");
        syms->set_option_string(ctx, "demuxer-max-bytes", "16MiB");
        syms->set_option_string(ctx, "demuxer-readahead-secs", "12");
    } else {
        syms->set_option_string(ctx, "demuxer-max-bytes", "64MiB");
        syms->set_option_string(ctx, "demuxer-readahead-secs", "45");
    }
}

- (void)configureHTTPHeadersOnHandle:(mpv_handle *)ctx {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx || !self.headers.count) return;
    NSMutableArray<NSString *> *extraFields = [NSMutableArray array];
    for (NSString *rawKey in self.headers) {
        if (![rawKey isKindOfClass:NSString.class]) continue;
        NSString *rawVal = [self.headers[rawKey] isKindOfClass:NSString.class] ? self.headers[rawKey] : @"";
        NSString *key = CCTVMPVSanitizeHeaderValue(rawKey);
        NSString *val = CCTVMPVSanitizeHeaderValue(rawVal);
        if (!key.length || !val.length) continue;
        NSString *lower = key.lowercaseString;
        if ([lower isEqualToString:@"user-agent"]) {
            syms->set_option_string(ctx, "user-agent", val.UTF8String);
        } else if ([lower isEqualToString:@"referer"]) {
            syms->set_option_string(ctx, "referrer", val.UTF8String);
        } else {
            [extraFields addObject:[NSString stringWithFormat:@"%@: %@", key, val]];
        }
    }
    if (extraFields.count) {
        NSString *joined = [extraFields componentsJoinedByString:@","];
        syms->set_option_string(ctx, "http-header-fields", joined.UTF8String);
    }
}

- (void)start {
    if (self.destroyed) return;
    self.wantStartAfterPrepare = YES;
    // Media commands may only touch the handle while the lifecycle is
    // PREPARED (T02/S1): after destroy the handle is gone.
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (ctx && syms) {
        int flag = 0;
        syms->set_property(ctx, "pause", MPV_FORMAT_FLAG, &flag);
        if (self.state == MediaPlaybackCicadaAdapterStatePaused || self.preparedNotified) {
            self.state = MediaPlaybackCicadaAdapterStatePlaying;
        }
    }
    [self.mpvLock unlock];
}

- (void)pause {
    if (self.destroyed) return;
    self.wantStartAfterPrepare = NO;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (ctx && syms) {
        int flag = 1;
        syms->set_property(ctx, "pause", MPV_FORMAT_FLAG, &flag);
        if (self.state == MediaPlaybackCicadaAdapterStatePlaying) {
            self.state = MediaPlaybackCicadaAdapterStatePaused;
        }
    }
    [self.mpvLock unlock];
}

- (void)stop {
    if (self.destroyed) return;
    [self cancelFirstFrameWatchdog];
    [self finishPendingSeek:NO];
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (ctx && syms) {
        const char *stopCmd[] = {"stop", NULL};
        syms->command_async(ctx, 0, stopCmd);
    }
    [self.mpvLock unlock];
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
    [self cancelFirstFrameWatchdog];
    [self finishPendingSeek:NO];

    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    self.mpvHandle = NULL;
    [self.mpvLock unlock];

    if (ctx && syms) {
        const char *quitCmd[] = {"quit", NULL};
        syms->command_async(ctx, 0, quitCmd);
        syms->wakeup(ctx);
        // Release the handle only after the event consumer has left
        // wait_event, on a background queue so teardown never blocks
        // the caller or the UI. The wait is bounded: if the consumer
        // is stuck, teardown still proceeds and the state still closes.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            host_mpv_lifecycle_wait_event_thread_exit(lc, MediaPlaybackMPVDestroyEventExitTimeoutMs);
            syms->terminate_destroy(ctx);
            host_mpv_lifecycle_finish_destroy(lc);
            host_mpv_lifecycle_release(lc);
        });
    } else {
        host_mpv_lifecycle_finish_destroy(lc);
        host_mpv_lifecycle_release(lc);
    }
}

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL finished))completion {
    if (self.destroyed) {
        if (completion) completion(NO);
        return;
    }
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) {
        if (completion) completion(NO);
        return;
    }
    [self finishPendingSeek:NO];
    self.pendingSeekCompletion = completion;
    NSTimeInterval clamped = MAX(0.0, time);
    NSString *target = [NSString stringWithFormat:@"%.3f", clamped];
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    int err = -1;
    if (ctx && syms) {
        const char *seekCmd[] = {"seek", target.UTF8String, "absolute+exact", NULL};
        err = syms->command_async(ctx, 0, seekCmd);
    }
    [self.mpvLock unlock];
    if (err < 0) {
        [self finishPendingSeek:NO];
    }
}

- (void)setRate:(float)rate {
    float clamped = MIN(3.0f, MAX(0.5f, isfinite(rate) ? rate : 1.0f));
    self.rate = clamped;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (ctx && syms) {
        double speed = (double)clamped;
        syms->set_property(ctx, "speed", MPV_FORMAT_DOUBLE, &speed);
    }
    [self.mpvLock unlock];
}

- (void)setMuted:(BOOL)muted {
    self.muted = muted;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (ctx && syms) {
        int flag = muted ? 1 : 0;
        syms->set_property(ctx, "mute", MPV_FORMAT_FLAG, &flag);
    }
    [self.mpvLock unlock];
}

- (BOOL)canSelectTracks {
    return host_mpv_lifecycle_command_allowed(_lifecycle);
}

- (NSArray<NSDictionary *> *)availableTracks {
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return @[];
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!ctx || !syms) {
        [self.mpvLock unlock];
        return @[];
    }
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
        // Encode type in upper bits so selectTrackWithIndex: knows aid vs sid vs vid.
        NSInteger encodedIndex = (NSInteger)trackId;
        if ([kind isEqualToString:@"subtitle"]) encodedIndex += 10000;
        else if ([kind isEqualToString:@"video"]) encodedIndex += 20000;
        [tracks addObject:@{@"type": kind, @"index": @(encodedIndex), @"name": display}];
    }
    [self.mpvLock unlock];
    return tracks.copy;
}

- (BOOL)selectTrackWithIndex:(NSInteger)index {
    if (index <= 0) return NO;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return NO;
    const char *prop = "aid";
    int64_t trackId = index;
    if (index >= 20000) {
        prop = "vid";
        trackId = index - 20000;
    } else if (index >= 10000) {
        prop = "sid";
        trackId = index - 10000;
    }
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    int err = -1;
    if (ctx && syms) {
        err = syms->set_property(ctx, prop, MPV_FORMAT_INT64, &trackId);
    }
    [self.mpvLock unlock];
    return err >= 0;
}

- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL {
    if (!subtitleURL.absoluteString.length || self.destroyed) return NO;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return NO;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    const CCTVMPVSymbolTable *syms = self.syms;
    int err = -1;
    if (ctx && syms) {
        const char *cmd[] = {"sub-add", subtitleURL.absoluteString.UTF8String, "select", NULL};
        err = syms->command_async(ctx, 0, cmd);
    }
    [self.mpvLock unlock];
    return err >= 0;
}

- (void)applyVideoGravity:(NSString *)gravity {
    self.pendingGravity = gravity ?: AVLayerVideoGravityResizeAspect;
    if (!host_mpv_lifecycle_command_allowed(_lifecycle)) return;
    [self.mpvLock lock];
    mpv_handle *ctx = self.mpvHandle;
    if (ctx) [self applyGravity:self.pendingGravity onHandle:ctx];
    [self.mpvLock unlock];
}

- (void)applyGravity:(NSString *)gravity onHandle:(mpv_handle *)ctx {
    const CCTVMPVSymbolTable *syms = self.syms;
    if (!syms || !ctx) return;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        syms->set_property_string(ctx, "keepaspect", "yes");
        double panscan = 1.0;
        syms->set_property(ctx, "panscan", MPV_FORMAT_DOUBLE, &panscan);
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        syms->set_property_string(ctx, "keepaspect", "no");
        double panscan = 0.0;
        syms->set_property(ctx, "panscan", MPV_FORMAT_DOUBLE, &panscan);
    } else {
        syms->set_property_string(ctx, "keepaspect", "yes");
        double panscan = 0.0;
        syms->set_property(ctx, "panscan", MPV_FORMAT_DOUBLE, &panscan);
    }
}

- (void)armFirstFrameWatchdog {
    [self cancelFirstFrameWatchdog];
    __weak typeof(self) weakSelf = self;
    self.firstFrameWatchdog = [NSTimer scheduledTimerWithTimeInterval:MediaPlaybackMPVFirstFrameTimeout
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
    if (self.destroyed || self.firstFrameNotified) return;
    [self handleFailureWithCode:-1008 message:@"MPV 全能内核首帧渲染超时"];
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
            cctv_mpv_event *ev = syms->wait_event(ctx, 0.25);
            if (!ev) continue;
            if (ev->event_id == MPV_EVENT_NONE) continue;
            if (ev->event_id == MPV_EVENT_SHUTDOWN) break;

            switch (ev->event_id) {
                case MPV_EVENT_FILE_LOADED: {
                    [self runOnMain:^{ [self handleFileLoadedOnMain]; }];
                    break;
                }
                case MPV_EVENT_PLAYBACK_RESTART: {
                    [self runOnMain:^{
                        [self handleFirstFrameOnMain];
                        [self finishPendingSeek:YES];
                        id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
                        if ([d respondsToSelector:@selector(cicadaAdapterDidSeek:)]) {
                            [d cicadaAdapterDidSeek:self];
                        }
                    }];
                    break;
                }
                case MPV_EVENT_END_FILE: {
                    cctv_mpv_event_end_file *endInfo = (cctv_mpv_event_end_file *)ev->data;
                    int reason = endInfo ? endInfo->reason : MPV_END_FILE_REASON_EOF;
                    int errCode = endInfo ? endInfo->error : 0;
                    NSString *errMsg = (errCode < 0 && syms->error_string(errCode))
                        ? [NSString stringWithUTF8String:syms->error_string(errCode)]
                        : @"播放流异常中断";
                    [self runOnMain:^{
                        if (reason == MPV_END_FILE_REASON_EOF) {
                            [self handleCompletionOnMain];
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
                        [self runOnMain:^{
                            if (self.destroyed || !isfinite(pos) || pos < 0) return;
                            self.currentPosition = pos;
                            if (!self.firstFrameNotified && pos > 0.05) [self handleFirstFrameOnMain];
                            id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
                            if ([d respondsToSelector:@selector(cicadaAdapter:didUpdatePosition:duration:)]) {
                                [d cicadaAdapter:self didUpdatePosition:self.currentPosition duration:self.duration];
                            }
                        }];
                    } else if (tag == CCTVMPVReplyDuration && prop->format == MPV_FORMAT_DOUBLE) {
                        double dur = *(double *)prop->data;
                        [self runOnMain:^{
                            if (self.destroyed || !isfinite(dur) || dur < 0) return;
                            self.duration = dur;
                        }];
                    } else if (tag == CCTVMPVReplyCacheTime && prop->format == MPV_FORMAT_DOUBLE) {
                        double buf = *(double *)prop->data;
                        [self runOnMain:^{
                            if (self.destroyed || !isfinite(buf) || buf < 0) return;
                            self.bufferedPosition = buf;
                        }];
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
                        [self runOnMain:^{
                            if (self.destroyed || bytesPerSec < 0) return;
                            id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
                            if ([d respondsToSelector:@selector(cicadaAdapter:didUpdateDownloadSpeed:)]) {
                                [d cicadaAdapter:self didUpdateDownloadSpeed:(double)bytesPerSec * 8.0];
                            }
                        }];
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
                    }
                    break;
                }
                default:
                    break;
            }
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
    self.state = MediaPlaybackCicadaAdapterStateCompleted;
    id<MediaPlaybackCicadaAdapterDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(cicadaAdapterDidComplete:)]) {
        [d cicadaAdapterDidComplete:self];
    }
}

- (NSInteger)lastErrorCode { return _lastErrorCode; }

- (NSDictionary<NSString *, id> *)playbackStatistics {
    return @{};
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
    void (^cb)(BOOL) = self.pendingSeekCompletion;
    self.pendingSeekCompletion = nil;
    if (cb) cb(finished);
}

#pragma mark - AVSampleBufferDisplayLayer Picture-in-Picture Bridge

- (BOOL)isPictureInPictureSupported {
    return [AVPictureInPictureController isPictureInPictureSupported];
}

- (BOOL)isPictureInPictureActive {
    return self.pipController.isPictureInPictureActive;
}

- (void)startPictureInPicture {
    if (self.destroyed || ![AVPictureInPictureController isPictureInPictureSupported]) return;
    if (!self.pipDisplayLayer) {
        AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer new];
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        layer.frame = self.metalView.bounds;
        [self.metalView.layer addSublayer:layer];
        self.pipDisplayLayer = layer;
    }
    if (!self.pipController && self.pipDisplayLayer) {
        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.pipDisplayLayer
                                                                               playbackDelegate:self];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:source];
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
    }
    [self.pipController invalidatePlaybackState];
    if (!self.pipController.isPictureInPictureActive) {
        [self.pipController startPictureInPicture];
    }
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
