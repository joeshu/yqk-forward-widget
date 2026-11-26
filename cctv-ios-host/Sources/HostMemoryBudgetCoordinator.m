#import "HostMemoryBudgetCoordinator.h"
#import "HostImageLoader.h"
#import "MediaMetadataCache.h"
#import "RuntimeDiagnostics.h"
#import <UIKit/UIKit.h>
#import <os/proc.h>

NSNotificationName const HostMemoryBudgetDidTrimNotification = @"HostMemoryBudgetDidTrimNotification";

static uint64_t const HostMemoryWarningThresholdBytes  = 350ULL * 1024ULL * 1024ULL;
static uint64_t const HostMemoryCriticalThresholdBytes = 200ULL * 1024ULL * 1024ULL;
static NSTimeInterval const HostMemoryMonitorInterval  = 30.0;
// Warning 与 Critical 共用最小裁剪间隔（迟滞）：10 秒内重复的压力信号合并为
// 一次裁剪，避免播放中反复清缓存造成重新下载。
static NSTimeInterval const HostMemoryTrimMinimumInterval = 10.0;

@interface HostMemoryBudgetCoordinator ()
@property (nonatomic, assign) BOOL monitoring;
@property (nonatomic, strong, nullable) dispatch_source_t monitorTimer;
@property (nonatomic, strong) dispatch_queue_t trimQueue;
@property (nonatomic, assign) NSTimeInterval lastTrimTimestamp;
- (void)handleSystemMemoryWarning:(NSNotification *)note;
- (HostMemoryBudgetPressure)pressureForAvailableBytes:(uint64_t)available;
- (BOOL)requestTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available;
- (void)performTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available;
@end

@implementation HostMemoryBudgetCoordinator

- (instancetype)init {
    if ((self = [super init])) {
        _trimQueue = dispatch_queue_create("com.cctvhost.memory-budget.trim", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)shared {
    static HostMemoryBudgetCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [self new];
    });
    return instance;
}

- (uint64_t)availableMemoryBytes {
#if TARGET_OS_IPHONE
    return (uint64_t)os_proc_available_memory();
#else
    return 1024ULL * 1024ULL * 1024ULL;
#endif
}

- (HostMemoryBudgetPressure)pressureForAvailableBytes:(uint64_t)available {
    HostMemoryBudgetPressure pressure;
    if (available == 0) pressure = HostMemoryBudgetPressureUnknown;
    else if (available < HostMemoryCriticalThresholdBytes) pressure = HostMemoryBudgetPressureCritical;
    else if (available < HostMemoryWarningThresholdBytes) pressure = HostMemoryBudgetPressureWarning;
    else pressure = HostMemoryBudgetPressureNormal;
#if TARGET_OS_IPHONE
    // 热状态是第二维信号：严重/危急温升时预算至少收紧到 Warning（只裁图片位图，
    // 不动元数据内存索引），不只看可用内存单一阈值。
    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    if ((thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical)
        && (pressure == HostMemoryBudgetPressureNormal || pressure == HostMemoryBudgetPressureUnknown)) {
        pressure = HostMemoryBudgetPressureWarning;
    }
#endif
    return pressure;
}

- (HostMemoryBudgetPressure)currentPressure {
    return [self pressureForAvailableBytes:[self availableMemoryBytes]];
}

- (void)startMonitoring {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startMonitoring]; });
        return;
    }
    if (self.monitoring) return;
    self.monitoring = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleSystemMemoryWarning:)
                                               name:UIApplicationDidReceiveMemoryWarningNotification
                                             object:nil];
    // 周期性水位检查走后台串行裁剪队列，不再占主线程 NSTimer；检查本身只做
    // 门禁判断，重活派发到同一队列（见 requestTrimWithPressure:）。
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.trimQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HostMemoryMonitorInterval * NSEC_PER_SEC)),
                              (uint64_t)(HostMemoryMonitorInterval * NSEC_PER_SEC),
                              (uint64_t)(5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf trimIfNeededForOperation:@"periodic_watchdog"];
    });
    self.monitorTimer = timer;
    dispatch_resume(timer);
}

- (void)handleSystemMemoryWarning:(NSNotification *)note {
    (void)note;
    [self requestTrimWithPressure:HostMemoryBudgetPressureCritical
                        operation:@"system_memory_warning"
                   availableBytes:[self availableMemoryBytes]];
}

- (BOOL)trimIfNeededForOperation:(NSString *)operation {
    uint64_t avail = [self availableMemoryBytes];
    return [self requestTrimWithPressure:[self pressureForAvailableBytes:avail]
                               operation:(operation.length ? operation : @"unspecified")
                          availableBytes:avail];
}

- (BOOL)requestTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available {
    // 串行化压力状态：门禁判断与 lastTrimTimestamp 的写在同一把锁内完成，
    // 多入口（周期看门狗 / 系统告警 / JAR 拉起）并发到达时只有一个能放行，
    // 其余合并丢弃；Warning 与 Critical 共用 10 秒最小间隔（迟滞），避免
    // 播放中反复清缓存造成重新下载。首次系统告警立即放行（上次裁剪很久
    // 以前），10 秒内的重复告警合并。Unknown 不触发裁剪。
    if (pressure == HostMemoryBudgetPressureNormal || pressure == HostMemoryBudgetPressureUnknown) return NO;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    BOOL admitted = NO;
    @synchronized(self) {
        if ((now - self.lastTrimTimestamp) >= HostMemoryTrimMinimumInterval) {
            self.lastTrimTimestamp = now;
            admitted = YES;
        }
    }
    if (!admitted) return NO;
    // 重活只在后台串行裁剪队列执行，不占调用线程（主线程 / JS 线程 / JAR 线程）。
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.trimQueue, ^{
        [weakSelf performTrimWithPressure:pressure operation:(operation ?: @"unspecified") availableBytes:available];
    });
    return YES;
}

- (void)performTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available {
    // 只在后台串行裁剪队列执行（调用方经 requestTrimWithPressure: 门禁放行，
    // lastTrimTimestamp 已在门禁内写下，此处不再碰它）。
    // 释放顺序：先裁剪体量最大、重建成本最低的图片位图缓存（NSCache，~32 MiB），
    // 再在 Critical 时回收元数据内存索引。元数据持久记录（home/category 磁盘缓存）
    // 须跨重启保留，故仅用 evictMemoryCache 回收内存，不可调用 clear 抹除磁盘状态——
    // 否则一次瞬时系统内存告警就会摧毁本应持久化的目录缓存，触发昂贵的全量重拉。
    [HostImageLoader.shared clearCache];
    if (pressure == HostMemoryBudgetPressureCritical) {
        [MediaMetadataCache.shared evictMemoryCache];
    }
    NSString *level = pressure == HostMemoryBudgetPressureCritical ? @"critical" : @"warning";
    [NSNotificationCenter.defaultCenter postNotificationName:HostMemoryBudgetDidTrimNotification
                                                      object:self
                                                    userInfo:@{@"level": level, @"operation": operation ?: @"", @"available_bytes": @(available)}];
    [RuntimeDiagnostics.shared recordEvent:(pressure == HostMemoryBudgetPressureCritical ? @"memory_budget_critical_trim" : @"memory_budget_trim")
                                  category:@"runtime"
                                    fields:@{
                                        @"level": level,
                                        @"operation": operation ?: @"",
                                        @"available_mb": @(available / (1024ULL * 1024ULL))
                                    }];
}

- (void)dealloc {
    if (self.monitorTimer) dispatch_source_cancel(self.monitorTimer);
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
