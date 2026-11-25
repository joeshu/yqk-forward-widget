"""第四阶段契约测试：插件运行时按需加载与空闲回收（HostRuntimeLifecycleCoordinator）。

本机无法编译 iOS，故以源码静态契约方式校验：
  - 公开 API 与 NSUserDefaults 键 / 默认值
  - 播放中绝不回收
  - 回收与互斥派发到后台队列，不在主线程阻塞等待
  - 互斥仅在对方无活跃会话时停止
  - 类扩展不得重复声明公开 readwrite 属性（CI #615 回归守卫）
  - 构建脚本自动收集新增 Sources/*.m
  - 运行时启动/调用入口已注入活动埋点与互斥钩子
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
SCRIPTS = ROOT / "Scripts"
HEADER = SOURCES / "HostRuntimeLifecycleCoordinator.h"
IMPL = SOURCES / "HostRuntimeLifecycleCoordinator.m"


class RuntimeIdleReclaimContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HEADER.is_file(), "HostRuntimeLifecycleCoordinator.h 缺失")
        self.assertTrue(IMPL.is_file(), "HostRuntimeLifecycleCoordinator.m 缺失")
        self.h = HEADER.read_text(encoding="utf-8")
        self.m = IMPL.read_text(encoding="utf-8")

    def test_public_api_surface(self):
        for needle in [
            "+ (instancetype)shared",
            "- (void)startMonitoring",
            "- (void)noteRuntimeActivity:(HostRuntimeKind)kind",
            "- (void)registerPlaybackActiveProvider:(BOOL (^)(void))provider",
            "- (BOOL)isPlaybackActive",
            "- (void)prepareForMutualExclusionBeforeActivating:(HostRuntimeKind)kind",
            "- (void)reclaimIdleRuntimesForMemoryPressure:(BOOL)critical",
            "@property (nonatomic, readonly) BOOL idleReclaimEnabled",
            "@property (nonatomic, readonly) NSTimeInterval idleReclaimThreshold",
        ]:
            self.assertIn(needle, self.h, f"公开 API 缺失：{needle}")

    def test_defaults_keys_and_values(self):
        self.assertIn(
            'NSString * const HostRuntimeIdleReclaimEnabledKey = @"cctv.runtime.idleReclaimEnabled.v1";',
            self.m,
        )
        self.assertIn(
            'NSString * const HostRuntimeIdleReclaimSecondsKey = @"cctv.runtime.idleReclaimSeconds.v1";',
            self.m,
        )
        # 默认阈值 600 秒，默认开启。
        self.assertIn("HostRuntimeDefaultIdleSeconds = 600", self.m)
        self.assertIn(HostRuntimeIdleReclaimEnabledKey_marker(self.m), self.m)
        self.assertIn("registerDefaults", self.m)
        self.assertIn("HostRuntimeIdleReclaimEnabledKey: @YES", self.m)
        self.assertIn("HostRuntimeIdleReclaimSecondsKey: @(HostRuntimeDefaultIdleSeconds)", self.m)

    def test_playback_guard_blocks_reclaim(self):
        # performReclaimWithReason 实现开头必须先判定播放占用并提前返回。
        # 定位实现（带 '{' 的签名行），略过类扩展里的声明（带 ';'）。
        pat = re.compile(r"- \(void\)performReclaimWithReason:\(NSString \*\)reason critical:\(BOOL\)critical\s*\{")
        m = pat.search(self.m)
        self.assertIsNotNone(m, "performReclaimWithReason 实现未找到")
        head = self.m[m.start():m.start() + 260]
        self.assertIn("isPlaybackActive", head)
        self.assertIn("return;", head)

    def test_reclaim_runs_off_main_background_queue(self):
        # 回收与内存告警路径均通过 dispatch_async 派发到私有队列，不在主线程等待。
        self.assertIn("dispatch_queue_create(\"com.cctvhost.runtime-lifecycle\", DISPATCH_QUEUE_SERIAL)", self.m)
        self.assertIn("dispatch_async(self.queue", self.m)
        # 看门狗为 dispatch_source_t 定时器，回调在后台队列。
        self.assertIn("dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER", self.m)
        # 不存在主线程同步等待回收的迹象。
        self.assertNotIn("dispatch_sync(dispatch_get_main_queue()", self.m)

    def test_mutual_exclusion_only_stops_idle_peer(self):
        idx = self.m.index("- (void)prepareForMutualExclusionBeforeActivating:")
        body = self.m[idx:idx + 900]
        # 对方有活跃会话时提前 return，不停止。
        self.assertIn("hasActiveSessionsForKind:other", body)
        self.assertIn("return;", body)
        # 仅 JVM ↔ Node 互斥；Python/JS 直接 return。
        self.assertIn("if (kind == HostRuntimeKindNode) other = HostRuntimeKindJVM", body)
        self.assertIn("else if (kind == HostRuntimeKindJVM) other = HostRuntimeKindNode", body)
        # 实际停止派发到后台队列。
        self.assertIn("dispatch_async(self.queue", body)

    def test_class_extension_does_not_redeclare_public_readwrite(self):
        # CI #615：类扩展不得重复声明公开头文件中已为 readwrite 的属性。
        # 本头文件中两个属性均为 readonly，故 .m 类扩展内不应再出现它们的 @property 声明。
        ext = re.search(r"@interface HostRuntimeLifecycleCoordinator \(\)(.*?)@end",
                        self.m, flags=re.S).group(1)
        self.assertNotRegex(ext, r"@property[^;]*\bidleReclaimEnabled\b",
                            "类扩展非法重复声明 idleReclaimEnabled")
        self.assertNotRegex(ext, r"@property[^;]*\bidleReclaimThreshold\b",
                            "类扩展非法重复声明 idleReclaimThreshold")
        # 头文件中二者必须为 readonly（确保 .m 内 getter 为方法实现，而非读写合成）。
        self.assertRegex(self.h, r"@property\s*\([^)]*\breadonly\b[^)]*\)\s*BOOL\s+idleReclaimEnabled")
        self.assertRegex(self.h, r"@property\s*\([^)]*\breadonly\b[^)]*\)\s*NSTimeInterval\s+idleReclaimThreshold")

    def test_critical_memory_threshold_above_max_start_timeout(self):
        # 临界回收阈值须高于最长启动超时（Node/JS 启动最长 95s），避免打断在途启动。
        self.assertIn("HostRuntimeCriticalMemoryThreshold = 120.0", self.m)

    def test_build_scripts_collect_new_sources(self):
        ci = (SCRIPTS / "ci-build.sh").read_text(encoding="utf-8")
        ui = (SCRIPTS / "ui-smoke.sh").read_text(encoding="utf-8")
        self.assertIn("find Sources -maxdepth 1 -name '*.m'", ci)
        self.assertIn("Sources/*.m", ui)

    def test_runtimes_wire_activity_and_mutual_exclusion(self):
        pyhost = (SOURCES / "PyHost.m").read_text(encoding="utf-8")
        node = (SOURCES / "NodePluginRuntime.m").read_text(encoding="utf-8")
        js = (SOURCES / "JSPluginRuntime.m").read_text(encoding="utf-8")
        jar = (SOURCES / "MediaJARRuntime.m").read_text(encoding="utf-8")
        app_delegate = (SOURCES / "AppDelegate.m").read_text(encoding="utf-8")
        self.assertIn("noteRuntimeActivity:HostRuntimeKindPython", pyhost)
        self.assertIn("noteRuntimeActivity:HostRuntimeKindNode", node)
        self.assertIn("prepareForMutualExclusionBeforeActivating:HostRuntimeKindNode", node)
        self.assertIn("noteRuntimeActivity:HostRuntimeKindJavaScript", js)
        self.assertIn("prepareForMutualExclusionBeforeActivating:HostRuntimeKindJVM", jar)
        self.assertIn("noteRuntimeActivity:HostRuntimeKindJVM", jar)
        # AppDelegate 启动监控并注册播放占用判定。
        self.assertIn("[HostRuntimeLifecycleCoordinator.shared startMonitoring]", app_delegate)
        self.assertIn("registerPlaybackActiveProvider", app_delegate)

    def test_memory_warning_reuses_budget_coordinator(self):
        # 监听 HostMemoryBudgetDidTrimNotification 与系统内存告警，复用现有裁剪协调器。
        self.assertIn("HostMemoryBudgetDidTrimNotification", self.m)
        self.assertIn("UIApplicationDidReceiveMemoryWarningNotification", self.m)
        self.assertIn("reclaimIdleRuntimesForMemoryPressure", self.m)


def HostRuntimeIdleReclaimEnabledKey_marker(text):
    # 占位：键常量已在 test_defaults_keys_and_values 中直接断言。
    return "HostRuntimeIdleReclaimEnabledKey"


if __name__ == "__main__":
    unittest.main()
