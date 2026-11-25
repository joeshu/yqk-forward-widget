// HostRuntimeLifecycleCoordinator.h
//
// 第四阶段：插件运行时按需加载与空闲回收。
//
// Python(PyHost)、JavaScriptCore(JSPluginRuntime)、Node(NodePluginRuntime)、
// JVM(MediaJARRuntime) 可能同时常驻。本协调器负责：
//   1) 空闲回收：某运行时无活跃会话且空闲超过可配置阈值（默认 10 分钟）时
//      回收其残留会话；播放中或有活跃服务会话时绝不回收。
//   2) JVM 与 Node 互斥常驻：拉起其中一个前，若另一个无活跃会话则先停止其
//      空闲会话；有活跃会话则不动。
//   3) 内存告警时按优先级释放空闲运行时会话，复用 HostMemoryBudgetCoordinator。
//
// 进程级拆解（CPython Py_Finalize / Node.js Mobile 进程退出 / Apple TV JVM
// teardown）经审计判定为高风险，本阶段不实现，仅回收会话级资源；详见报告。
//
// 调度安全：所有回收动作派发到私有后台串行队列执行，不在主线程等待。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HostRuntimeKind) {
    HostRuntimeKindPython = 0,
    HostRuntimeKindJavaScript,
    HostRuntimeKindNode,
    HostRuntimeKindJVM,
};

/// 空闲回收总开关（NSUserDefaults BOOL，默认 YES）。置 NO 关闭空闲看门狗。
FOUNDATION_EXPORT NSString * const HostRuntimeIdleReclaimEnabledKey;
/// 空闲回收阈值秒数（NSUserDefaults integer，默认 600）。
FOUNDATION_EXPORT NSString * const HostRuntimeIdleReclaimSecondsKey;
/// 回收发生时发送；userInfo[@"kinds"] 为本次回收的运行时名称数组。
FOUNDATION_EXPORT NSNotificationName const HostRuntimeDidReclaimNotification;

@interface HostRuntimeLifecycleCoordinator : NSObject

+ (instancetype)shared;

/// 主线程调用：注册默认偏好、启动空闲看门狗并监听内存告警与 PyHost 状态变化。
- (void)startMonitoring;

/// 任意运行时会话活动时调用（线程安全），刷新该运行时的空闲计时。
- (void)noteRuntimeActivity:(HostRuntimeKind)kind;

/// 注册播放占用判定（主线程注册）。回放期间绝不回收任何运行时。
- (void)registerPlaybackActiveProvider:(BOOL (^)(void))provider;

/// 当前是否存在播放占用（未注册时返回 NO）。
- (BOOL)isPlaybackActive;

/// 在拉起 JVM 或 Node 之前调用：若对方运行时无活跃会话则先停止其空闲会话，
/// 有活跃会话则不动。非阻塞——实际停止派发到后台队列，不在主线程等待。
- (void)prepareForMutualExclusionBeforeActivating:(HostRuntimeKind)kind;

/// 内存告警路径：按优先级释放空闲运行时会话。critical 为 YES 时阈值放宽。
/// 复用 HostMemoryBudgetCoordinator 的裁剪通知触发。
- (void)reclaimIdleRuntimesForMemoryPressure:(BOOL)critical;

/// 空闲回收是否启用（读取 NSUserDefaults，默认 YES）。
@property (nonatomic, readonly) BOOL idleReclaimEnabled;

/// 空闲回收阈值秒数（读取 NSUserDefaults，默认 600；内存告警 critical 时降为 60）。
@property (nonatomic, readonly) NSTimeInterval idleReclaimThreshold;

@end

NS_ASSUME_NONNULL_END
