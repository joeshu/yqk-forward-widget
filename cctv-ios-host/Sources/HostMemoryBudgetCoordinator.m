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

@interface HostMemoryBudgetCoordinator ()
@property (nonatomic, assign) BOOL monitoring;
@property (nonatomic, strong, nullable) NSTimer *monitorTimer;
@property (nonatomic, assign) NSTimeInterval lastTrimTimestamp;
- (void)handleSystemMemoryWarning:(NSNotification *)note;
- (void)performTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available;
@end

@implementation HostMemoryBudgetCoordinator

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

- (HostMemoryBudgetPressure)currentPressure {
    uint64_t avail = [self availableMemoryBytes];
    if (avail == 0) return HostMemoryBudgetPressureNormal;
    if (avail < HostMemoryCriticalThresholdBytes) return HostMemoryBudgetPressureCritical;
    if (avail < HostMemoryWarningThresholdBytes) return HostMemoryBudgetPressureWarning;
    return HostMemoryBudgetPressureNormal;
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
    __weak typeof(self) weakSelf = self;
    self.monitorTimer = [NSTimer scheduledTimerWithTimeInterval:HostMemoryMonitorInterval
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) {
        [weakSelf trimIfNeededForOperation:@"periodic_watchdog"];
    }];
}

- (void)handleSystemMemoryWarning:(NSNotification *)note {
    (void)note;
    [self performTrimWithPressure:HostMemoryBudgetPressureCritical
                        operation:@"system_memory_warning"
                   availableBytes:[self availableMemoryBytes]];
}

- (BOOL)trimIfNeededForOperation:(NSString *)operation {
    uint64_t avail = [self availableMemoryBytes];
    HostMemoryBudgetPressure pressure = [self currentPressure];
    if (pressure == HostMemoryBudgetPressureNormal) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    if (pressure == HostMemoryBudgetPressureWarning && (now - self.lastTrimTimestamp) < 10.0) {
        return NO;
    }
    [self performTrimWithPressure:pressure operation:(operation.length ? operation : @"unspecified") availableBytes:avail];
    return YES;
}

- (void)performTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available {
    self.lastTrimTimestamp = CACurrentMediaTime();
    [HostImageLoader.shared clearCache];
    if (pressure == HostMemoryBudgetPressureCritical) {
        [MediaMetadataCache.shared clear];
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
    [self.monitorTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
