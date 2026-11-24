#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const HostMemoryBudgetDidTrimNotification;

typedef NS_ENUM(NSInteger, HostMemoryBudgetPressure) {
    HostMemoryBudgetPressureNormal = 0,
    HostMemoryBudgetPressureWarning,
    HostMemoryBudgetPressureCritical,
};

@interface HostMemoryBudgetCoordinator : NSObject

+ (instancetype)shared;

/// 开始监听系统内存告警与周期性水位检查（主线程调用）。
- (void)startMonitoring;

/// 当前进程剩余可用内存字节数（os_proc_available_memory）。
- (uint64_t)availableMemoryBytes;

/// 当前内存压力级别（<350MB Warning，<200MB Critical）。
- (HostMemoryBudgetPressure)currentPressure;

/// 在拉起大型运行时（Python / Node / JAR / MPV）前按需触发缓存裁剪，返回是否执行了裁剪。
- (BOOL)trimIfNeededForOperation:(NSString *)operation;

@end

NS_ASSUME_NONNULL_END
