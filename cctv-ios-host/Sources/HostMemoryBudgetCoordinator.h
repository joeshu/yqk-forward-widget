#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const HostMemoryBudgetDidTrimNotification;

typedef NS_ENUM(NSInteger, HostMemoryBudgetPressure) {
    HostMemoryBudgetPressureNormal = 0,
    HostMemoryBudgetPressureWarning,
    HostMemoryBudgetPressureCritical,
    /// 内存值不可用（os_proc_available_memory 返回 0）：不断言“正常”，也不触发裁剪。
    HostMemoryBudgetPressureUnknown,
};

@interface HostMemoryBudgetCoordinator : NSObject

+ (instancetype)shared;

/// 开始监听系统内存告警与周期性水位检查（主线程调用）。
- (void)startMonitoring;

/// 当前进程剩余可用内存字节数（os_proc_available_memory）。
- (uint64_t)availableMemoryBytes;

/// 当前内存压力级别（<350MB Warning，<200MB Critical；读不到按 Unknown；
/// 严重/危急温升至少 Warning）。只读快照，调用方不得据此假设已裁剪。
- (HostMemoryBudgetPressure)currentPressure;

/// 非必要后台预热（原生频道预解析、下一集预取）是否允许新开任务。
/// Normal/Unknown 允许；Warning/Critical 拒绝（只管新准入，不取消在途任务）；
/// 低电量模式也拒绝（省电优先于预热）。热状态已折进 currentPressure。
+ (BOOL)shouldAllowBackgroundWarmup;

/// 在拉起大型运行时（Python / Node / JAR / MPV）前按需触发缓存裁剪，返回是否执行了裁剪。
- (BOOL)trimIfNeededForOperation:(NSString *)operation;

@end

NS_ASSUME_NONNULL_END
