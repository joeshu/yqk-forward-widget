#import "HostRuntimeLifecycleCoordinator.h"
#import "HostMemoryBudgetCoordinator.h"
#import "PyHost.h"
#import "JSPluginRuntime.h"
#import "NodePluginRuntime.h"
#import "MediaJARRuntime.h"
#import "RuntimeDiagnostics.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

NSString * const HostRuntimeIdleReclaimEnabledKey = @"cctv.runtime.idleReclaimEnabled.v1";
NSString * const HostRuntimeIdleReclaimSecondsKey = @"cctv.runtime.idleReclaimSeconds.v1";
NSNotificationName const HostRuntimeDidReclaimNotification = @"HostRuntimeDidReclaimNotification";

static NSTimeInterval const HostRuntimeIdleWatchdogInterval = 60.0;
// 内存告警临界阈值：高于最长的单次启动超时（Node/JS 启动最长 95s），
// 确保临界回收不会打断仍在进行中的启动调用。
static NSTimeInterval const HostRuntimeCriticalMemoryThreshold = 120.0;
static NSInteger const HostRuntimeDefaultIdleSeconds = 600;

@interface HostRuntimeLifecycleCoordinator ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t watchdog;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDate *> *lastActivity;
@property (nonatomic, copy, nullable) BOOL (^playbackProvider)(void);
@property (nonatomic, assign) BOOL monitoring;
- (void)registerDefaults;
- (NSTimeInterval)thresholdForCritical:(BOOL)critical;
- (NSDate *)lastActivityForKind:(HostRuntimeKind)kind;
- (void)touchActivityForKind:(HostRuntimeKind)kind;
- (void)touchActiveRuntimes;
- (BOOL)hasActiveSessionsForKind:(HostRuntimeKind)kind;
- (BOOL)anyRuntimeActive;
- (void)performReclaimWithReason:(NSString *)reason critical:(BOOL)critical;
- (void)stopIdleSessionsForKind:(HostRuntimeKind)kind;
- (NSString *)nameForKind:(HostRuntimeKind)kind;
- (void)handleMemoryWarning:(NSNotification *)note;
- (void)handleBudgetTrim:(NSNotification *)note;
@end

@implementation HostRuntimeLifecycleCoordinator

+ (instancetype)shared {
    static HostRuntimeLifecycleCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.cctvhost.runtime-lifecycle", DISPATCH_QUEUE_SERIAL);
        _lastActivity = [NSMutableDictionary dictionary];
        // 初始活动时间设为启动时刻：开机即开始计时，首个空闲窗口可被看门狗观测。
        NSDate *now = [NSDate date];
        for (NSInteger k = HostRuntimeKindPython; k <= HostRuntimeKindJVM; k++) {
            _lastActivity[@(k)] = now;
        }
    }
    return self;
}

- (void)registerDefaults {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        HostRuntimeIdleReclaimEnabledKey: @YES,
        HostRuntimeIdleReclaimSecondsKey: @(HostRuntimeDefaultIdleSeconds),
    }];
}

- (BOOL)idleReclaimEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:HostRuntimeIdleReclaimEnabledKey];
}

- (NSTimeInterval)idleReclaimThreshold {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:HostRuntimeIdleReclaimSecondsKey];
    return seconds > 0 ? (NSTimeInterval)seconds : (NSTimeInterval)HostRuntimeDefaultIdleSeconds;
}

- (NSTimeInterval)thresholdForCritical:(BOOL)critical {
    if (critical) return HostRuntimeCriticalMemoryThreshold;
    return self.idleReclaimThreshold;
}

- (void)startMonitoring {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startMonitoring]; });
        return;
    }
    if (self.monitoring) return;
    self.monitoring = YES;
    [self registerDefaults];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handlePyHostStateChange:)
                                               name:PyHostRuntimeStateDidChangeNotification
                                             object:nil];
#if TARGET_OS_IOS
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMemoryWarning:)
                                               name:UIApplicationDidReceiveMemoryWarningNotification
                                             object:nil];
#endif
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleBudgetTrim:)
                                               name:HostMemoryBudgetDidTrimNotification
                                             object:nil];
    dispatch_queue_t queue = self.queue;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HostRuntimeIdleWatchdogInterval * NSEC_PER_SEC)),
                              (uint64_t)(HostRuntimeIdleWatchdogInterval * NSEC_PER_SEC),
                              (uint64_t)(5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        HostRuntimeLifecycleCoordinator *strong = weakSelf;
        if (!strong) return;
        [strong performReclaimWithReason:@"idle_watchdog" critical:NO];
    });
    self.watchdog = timer;
    dispatch_resume(timer);
}

- (void)noteRuntimeActivity:(HostRuntimeKind)kind {
    dispatch_async(self.queue, ^{ [self touchActivityForKind:kind]; });
}

- (void)registerPlaybackActiveProvider:(BOOL (^)(void))provider {
    @synchronized(self) {
        self.playbackProvider = provider ? [provider copy] : nil;
    }
}

- (BOOL)isPlaybackActive {
    @synchronized(self) {
        return self.playbackProvider ? self.playbackProvider() : NO;
    }
}

#pragma mark - Activity tracking

- (NSDate *)lastActivityForKind:(HostRuntimeKind)kind {
    @synchronized(self) {
        return self.lastActivity[@(kind)] ?: [NSDate distantPast];
    }
}

- (void)touchActivityForKind:(HostRuntimeKind)kind {
    @synchronized(self) {
        self.lastActivity[@(kind)] = [NSDate date];
    }
}

/// 任何运行时存在活跃会话时刷新其计时，使空闲窗口仅在会话全部退出后才开始累计。
- (void)touchActiveRuntimes {
    for (NSInteger k = HostRuntimeKindPython; k <= HostRuntimeKindJVM; k++) {
        HostRuntimeKind kind = (HostRuntimeKind)k;
        if ([self hasActiveSessionsForKind:kind]) [self touchActivityForKind:kind];
    }
}

- (BOOL)hasActiveSessionsForKind:(HostRuntimeKind)kind {
    switch (kind) {
        case HostRuntimeKindPython:
            // runningServiceIdentifiers 已聚合 Python/Node/JS 的活跃会话；
            // Python 自身无活跃任务时该列表对 Python 部分为空。
            return PyHost.runningServiceIdentifiers.count > 0;
        case HostRuntimeKindJavaScript:
            // 仅“已确认活跃”的会话视为占用；managed-but-not-active（uncertain/启动中）
            // 在空闲阈值（远大于启动超时）后视为可回收的残留会话。
            return JSPluginRuntime.shared.activeSessionIdentifiers.count > 0;
        case HostRuntimeKindNode:
            // hasActivePlugin 仅统计已确认会话；starting/uncertain 在空闲阈值后可回收。
            return NodePluginRuntime.shared.hasActivePlugin;
        case HostRuntimeKindJVM:
            // MediaJARRuntime 为按请求调用，无常驻会话句柄；活跃性由各请求票据自管。
            // 此处无法查询在途票据，JVM 不参与会话级空闲回收。
            return NO;
    }
    return NO;
}

- (BOOL)anyRuntimeActive {
    for (NSInteger k = HostRuntimeKindPython; k <= HostRuntimeKindJVM; k++) {
        if ([self hasActiveSessionsForKind:(HostRuntimeKind)k]) return YES;
    }
    return NO;
}

#pragma mark - Reclamation

- (void)performReclaimWithReason:(NSString *)reason critical:(BOOL)critical {
    // 播放中绝不回收——避免在点播/直播占用播放器期间释放任何运行时会话。
    if ([self isPlaybackActive]) return;
    if (!critical && !self.idleReclaimEnabled) return;
    [self touchActiveRuntimes];
    NSTimeInterval threshold = [self thresholdForCritical:critical];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray<NSString *> *reclaimed = [NSMutableArray array];

    // 内存告警按优先级释放：Node（最重常驻）→ JavaScript → Python 残留会话。
    // JVM 不可会话级回收，跳过。
    NSArray<NSNumber *> *order = critical
        ? @[@(HostRuntimeKindNode), @(HostRuntimeKindJavaScript), @(HostRuntimeKindPython)]
        : @[@(HostRuntimeKindPython), @(HostRuntimeKindNode), @(HostRuntimeKindJavaScript)];

    for (NSNumber *boxed in order) {
        HostRuntimeKind kind = (HostRuntimeKind)boxed.integerValue;
        if ([self hasActiveSessionsForKind:kind]) continue;
        NSDate *last = [self lastActivityForKind:kind];
        BOOL idle = (now - last.timeIntervalSince1970) >= threshold;
        if (!idle) continue;
        [self stopIdleSessionsForKind:kind];
        [reclaimed addObject:[self nameForKind:kind]];
        [self touchActivityForKind:kind];
    }

    if (reclaimed.count) {
        [NSNotificationCenter.defaultCenter postNotificationName:HostRuntimeDidReclaimNotification
                                                          object:self
                                                        userInfo:@{
                                                            @"reason": reason ?: @"unspecified",
                                                            @"critical": @(critical),
                                                            @"kinds": reclaimed.copy,
                                                        }];
        [RuntimeDiagnostics.shared recordEvent:@"runtime_idle_reclaim"
                                      category:@"runtime"
                                        fields:@{
                                            @"reason": reason ?: @"unspecified",
                                            @"critical": @(critical),
                                            @"kinds": reclaimed.copy,
                                            @"threshold_seconds": @(threshold),
                                        }];
    }
}

- (void)stopIdleSessionsForKind:(HostRuntimeKind)kind {
    // 仅当该运行时无活跃会话时调用其停止入口，清理 uncertain/managed 残留会话。
    // 全部在私有后台串行队列执行，不阻塞主线程。
    switch (kind) {
        case HostRuntimeKindNode:
            if (NodePluginRuntime.shared.managedServiceIdentifiers.count > 0) {
                [NodePluginRuntime.shared stopWithError:NULL];
            }
            break;
        case HostRuntimeKindJavaScript: {
            NSArray<NSString *> *managed = JSPluginRuntime.shared.managedServiceIdentifiers;
            for (NSString *identifier in managed) {
                [JSPluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:NULL];
            }
            break;
        }
        case HostRuntimeKindPython:
            // 无活跃 Python 会话时 stopWithError 清理跨运行时的残留 managed 会话；
            // 已通过 hasActiveSessionsForKind 保证此时无活跃会话，不会打断在用服务。
            if (PyHost.runningServiceIdentifiers.count == 0) {
                [PyHost stopWithError:NULL];
            }
            break;
        case HostRuntimeKindJVM:
            // 按请求调用，无可停止的常驻会话；进程级 teardown 为高风险（见报告）。
            break;
    }
}

- (NSString *)nameForKind:(HostRuntimeKind)kind {
    switch (kind) {
        case HostRuntimeKindPython: return @"python";
        case HostRuntimeKindJavaScript: return @"javascript";
        case HostRuntimeKindNode: return @"node";
        case HostRuntimeKindJVM: return @"jvm";
    }
    return @"unknown";
}

#pragma mark - JVM / Node mutual exclusion

- (void)prepareForMutualExclusionBeforeActivating:(HostRuntimeKind)kind {
    // 非阻塞：检查与实际停止派发到后台队列，不在调用方（可能为主线程）等待。
    HostRuntimeKind other = HostRuntimeKindPython;
    if (kind == HostRuntimeKindNode) other = HostRuntimeKindJVM;
    else if (kind == HostRuntimeKindJVM) other = HostRuntimeKindNode;
    else return; // 仅 JVM ↔ Node 互斥；Python/JS 不参与。
    dispatch_async(self.queue, ^{
        // 对方有活跃会话时绝不停止。
        if ([self hasActiveSessionsForKind:other]) {
            [self touchActivityForKind:other];
            return;
        }
        if (other == HostRuntimeKindNode) {
            // 拉起 JVM 前，若 Node 无活跃会话则停止其残留会话，释放 Node 工作内存。
            if (NodePluginRuntime.shared.managedServiceIdentifiers.count > 0) {
                [NodePluginRuntime.shared stopWithError:NULL];
                [RuntimeDiagnostics.shared recordEvent:@"runtime_mutual_exclusion_reclaim"
                                              category:@"runtime"
                                                fields:@{@"stopped": @"node", @"activating": @"jvm"}];
            }
        }
        // 拉起 Node 前，JVM 无常驻会话可停止（按请求调用）；仅刷新计时。
        [self touchActivityForKind:other];
    });
}

- (void)reclaimIdleRuntimesForMemoryPressure:(BOOL)critical {
    dispatch_async(self.queue, ^{
        [self performReclaimWithReason:@"memory_pressure" critical:critical];
    });
}

#pragma mark - Notifications

- (void)handlePyHostStateChange:(NSNotification *)note {
    (void)note;
    dispatch_async(self.queue, ^{ [self touchActiveRuntimes]; });
}

- (void)handleMemoryWarning:(NSNotification *)note {
    (void)note;
    [self reclaimIdleRuntimesForMemoryPressure:YES];
}

- (void)handleBudgetTrim:(NSNotification *)note {
    NSString *level = note.userInfo[@"level"];
    BOOL critical = [level isEqualToString:@"critical"];
    [self reclaimIdleRuntimesForMemoryPressure:critical];
}

- (void)dealloc {
    if (self.watchdog) {
        dispatch_source_cancel(self.watchdog);
        self.watchdog = nil;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
