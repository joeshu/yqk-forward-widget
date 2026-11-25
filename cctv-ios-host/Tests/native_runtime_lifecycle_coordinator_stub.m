// Tests/native_runtime_lifecycle_coordinator_stub.m
//
// 最小桩：仅供 macOS 上的原生 JS 夹具测试（test_native_js.py）链接用。
//
// 真实的 HostRuntimeLifecycleCoordinator.m 不能编进 macOS 夹具：它引用 PyHost，
// 而 PyHost.m 用 Python C API（约 59 处），仓库的 Python 是 iOS-arm64 的 vendored
// framework，macOS 夹具既找不到 Python.h 也链不上 Py_* 符号（2026-11-26 CI
// 45718753390 上，JS 夹具就卡在这里）。
//
// JSPluginRuntime.m 对协调器只有一处调用（:664 noteRuntimeActivity:），桩只实现
// 该调用 + shared；若以后 JSPluginRuntime 调用了协调器的更多方法，链接会直接报
// 缺符号，届时再补。协调器的真实行为由源码级测试（test_runtime_idle_reclaim.py）
// 与 App 构建覆盖，不由本夹具覆盖。
#import "HostRuntimeLifecycleCoordinator.h"

@implementation HostRuntimeLifecycleCoordinator

+ (instancetype)shared {
    static HostRuntimeLifecycleCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (void)noteRuntimeActivity:(HostRuntimeKind)kind {
    (void)kind;
}

@end
