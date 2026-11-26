"""B4/T21 · 全局资源预算（PERF-06/08/11、S6、V05）行为测试

只读取 Sources 文本断言不变量 + 对门禁/租约/泵送跑 Python 模型验证，不触发构建/网络/CI。
对应审计：PERF-06 内存预算固定阈值 + 30 秒主线程 timer + critical 无节流 +
多入口线程归属未核实；PERF-08 同步 JS 请求占执行线程最多 13 秒，阻塞行为依赖
调用方队列；PERF-11 运行时空闲回收已有 watchdog，但无统一 lease、无回收耗时/
失败原因记录，JVM 在途票据不可见。

T21 改动：
1. HostMemoryBudgetCoordinator（PERF-06）：压力判定抽成 pressureForAvailableBytes
   （0 字节按 Unknown，不再断言 Normal；严重/危急温升至少 Warning）；裁剪门禁
   收敛到 requestTrimWithPressure（@synchronized 内判读+写 lastTrimTimestamp，
   Warning 与 Critical 共用 10 秒最小间隔；Unknown/Normal 不触发；首次系统告警
   立即放行，10 秒内重复告警合并）；重活只在后台串行裁剪队列执行；30 秒主线程
   NSTimer 改 dispatch_source 定时器（同一裁剪队列）；350/200MiB 阈值不动。
2. HostRuntimeLifecycleCoordinator（PERF-11）：新增租约 acquireLease/releaseLease
   （NSUUID token，@synchronized 字典）；回收与互斥前确认活跃会话或在途租约；
   回收记耗时 elapsed_ms，停止失败的 kind 进 failed_kinds、不记入 reclaimed、
   不刷新计时（旧代码无条件记入，诊断谎称已回收）。
3. MediaJARRuntime（PERF-11）：每张 JAR 票据持有 JVM 租约（requestSource 时取，
   claimCompletion 首次认领 / cancel / 队列拒收时归还，幂等）；此前协调器看不见
   在途票据（hasActiveSessionsForKind:JVM 恒为 NO）。原生测试桩同步补租约方法。
4. HostSyncRequest / JSPluginRuntime（PERF-08）：核实，无代码改动——JS 求值与
   __hostFetchSync 全在每会话私有串行队列 cctvhost.javascript 上（不在主线程、
   不与其它源共队列）；performRequest 拒主线程、10/12/13 秒三层超时、2MB 上限、
   停止时取消在途同步请求；除 JSPluginRuntime 外无调用方。
5. MediaGlobalSearchViewController（S6/V05）：全局搜索并发上限随内存压力自适应
   （正常/未知 6 路、Warning 2 路、Critical 1 路），只管新任务准入，不取消在途搜索。
6. ShortDramaVerticalFeedController（S6）：邻集预解析按剩余资源决定（正常/未知
   前后各一集、Warning 只下一集、Critical 只当前集），不取消已在途的解析。

语义不变：裁剪顺序（图片先于元数据、Critical 才动元数据内存索引、绝不 clear
磁盘）由 test_d_cache_budget_audit 锁住；播放中绝不回收、互斥仅 JVM↔Node、
120 秒临界阈值由 test_runtime_idle_reclaim 锁住；JS 同步接口保留；搜索 6 路
上限常量保留；短剧 centre-first 发起顺序与邻集 4s/中心 10s 缓冲保留。
"""
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")
TESTS = os.path.join(REPO_ROOT, "Tests")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


def method_body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


BUDGET_H = read_source("HostMemoryBudgetCoordinator.h")
BUDGET_M = read_source("HostMemoryBudgetCoordinator.m")
LIFE_H = read_source("HostRuntimeLifecycleCoordinator.h")
LIFE_M = read_source("HostRuntimeLifecycleCoordinator.m")
JAR_M = read_source("MediaJARRuntime.m")
SYNC_M = read_source("HostSyncRequest.m")
JS_M = read_source("JSPluginRuntime.m")
SEARCH_M = read_source("MediaGlobalSearchViewController.m")
FEED_M = read_source("ShortDramaVerticalFeedController.m")
NATIVE_API_TESTS = open(os.path.join(TESTS, "native_media_api_tests.m"), encoding="utf-8").read()


# --- PERF-06：压力判定与裁剪门禁的 Python 模型（与 ObjC 语义同构） ---
class PressureModel:
    """阈值 350/200MiB；0 字节按 Unknown；严重/危急温升把 Normal/Unknown 抬到 Warning。"""

    WARNING = 350 * 1024 * 1024
    CRITICAL = 200 * 1024 * 1024

    def pressure(self, available, thermal="nominal"):
        if available == 0:
            level = "unknown"
        elif available < self.CRITICAL:
            level = "critical"
        elif available < self.WARNING:
            level = "warning"
        else:
            level = "normal"
        if thermal in ("serious", "critical") and level in ("normal", "unknown"):
            level = "warning"
        return level


class TrimGateModel:
    """门禁：Normal/Unknown 不触发；Warning 与 Critical 共用 10 秒最小间隔；
    判读+写时间戳在同一把锁内；重活排进串行裁剪队列，不占调用线程。"""

    INTERVAL = 10.0

    def __init__(self):
        self.last_trim = None
        self.queued = []
        self.executed = []

    def request(self, pressure, operation, now):
        if pressure in ("normal", "unknown"):
            return False
        if self.last_trim is not None and now - self.last_trim < self.INTERVAL:
            return False
        self.last_trim = now
        self.queued.append((pressure, operation))
        return True

    def run_queued(self):
        self.executed.extend(self.queued)
        self.queued = []


# --- PERF-11：租约与回收的 Python 模型 ---
class LeaseModel:
    """token→kind；归还幂等；回收前确认活跃会话或在途租约。"""

    def __init__(self):
        self.leases = {}
        self._next = 0

    def acquire(self, kind, owner=""):
        self._next += 1
        self.leases[self._next] = kind
        return self._next

    def release(self, token):
        self.leases.pop(token, None)

    def has_live_lease(self, kind):
        return kind in self.leases.values()


class ReclaimModel:
    """按优先级回收；播放中不回收；停止失败进 failed、不记入 reclaimed。"""

    ORDER = ("node", "javascript", "python")

    def reclaim(self, leases, active, idle, stop_errors, playback_active=False):
        if playback_active:
            return [], []
        reclaimed, failed = [], []
        for kind in self.ORDER:
            if kind in active or leases.has_live_lease(kind):
                continue
            if kind not in idle:
                continue
            if stop_errors.get(kind):
                failed.append(kind)
                continue
            reclaimed.append(kind)
        return reclaimed, failed


class JarTicketModel:
    """票据持有 JVM 租约：创建时取；首次认领/取消/队列拒收时归还，幂等。"""

    def __init__(self, leases):
        self.leases = leases
        self.lease = leases.acquire("jvm", "jar-request")
        self.completed = False
        self.cancelled = False

    def _release_lease(self):
        if self.lease is not None:
            self.leases.release(self.lease)
            self.lease = None

    def claim_completion(self):
        if self.completed or self.cancelled:
            return False
        self.completed = True
        self._release_lease()
        return True

    def cancel(self):
        self.cancelled = True
        self._release_lease()

    def queue_full_reject(self):
        self._release_lease()


# --- S6：搜索泵送与邻集预算的 Python 模型 ---
class SearchPumpModel:
    """并发上限随压力自适应；只管新任务准入，不取消在途搜索。"""

    LIMITS = {"normal": 6, "unknown": 6, "warning": 2, "critical": 1}

    def __init__(self, pending):
        self.jobs = []
        self.pending = list(pending)

    def effective_limit(self, pressure):
        return self.LIMITS[pressure]

    def schedule(self, pressure):
        admitted = 0
        while len(self.jobs) < self.effective_limit(pressure) and self.pending:
            self.jobs.append(self.pending.pop(0))
            admitted += 1
        return admitted

    def finish(self, section, pressure):
        self.jobs.remove(section)
        return self.schedule(pressure)


class NeighborBudgetModel:
    """邻集预解析预算：正常/未知 2（下一集+上一集）、Warning 1（仅下一集）、Critical 0。"""

    BUDGETS = {"normal": 2, "unknown": 2, "warning": 1, "critical": 0}

    def resolved(self, center, count, pressure):
        out = [center]
        budget = self.BUDGETS[pressure]
        if budget >= 1 and center + 1 < count:
            out.append(center + 1)
        if budget >= 2 and center - 1 >= 0:
            out.append(center - 1)
        return out


class GlobalResourceBudgetTests(unittest.TestCase):
    # --- PERF-06 模型 ---
    def test_pressure_thresholds_and_unknown(self):
        p = PressureModel()
        self.assertEqual(p.pressure(0), "unknown")
        self.assertEqual(p.pressure(199 * 1024 * 1024), "critical")
        self.assertEqual(p.pressure(200 * 1024 * 1024), "warning")
        self.assertEqual(p.pressure(349 * 1024 * 1024), "warning")
        self.assertEqual(p.pressure(350 * 1024 * 1024), "normal")
        self.assertEqual(p.pressure(8 * 1024 * 1024 * 1024), "normal")

    def test_pressure_thermal_floor(self):
        p = PressureModel()
        self.assertEqual(p.pressure(8 * 1024 * 1024 * 1024, "serious"), "warning")
        self.assertEqual(p.pressure(0, "critical"), "warning")
        self.assertEqual(p.pressure(199 * 1024 * 1024, "serious"), "critical")
        self.assertEqual(p.pressure(8 * 1024 * 1024 * 1024, "nominal"), "normal")

    def test_trim_gate_normal_and_unknown_never_trim(self):
        gate = TrimGateModel()
        self.assertFalse(gate.request("normal", "periodic_watchdog", 100.0))
        self.assertFalse(gate.request("unknown", "periodic_watchdog", 100.0))
        self.assertEqual(gate.queued, [])

    def test_trim_gate_warning_and_critical_share_throttle(self):
        gate = TrimGateModel()
        self.assertTrue(gate.request("warning", "periodic_watchdog", 100.0))
        # 审计原话：critical 没有与 warning 一样的 10 秒节流——本轮补上。
        self.assertFalse(gate.request("critical", "system_memory_warning", 105.0))
        self.assertFalse(gate.request("warning", "periodic_watchdog", 109.9))
        self.assertTrue(gate.request("critical", "system_memory_warning", 110.0))
        gate.run_queued()
        self.assertEqual(gate.executed, [("warning", "periodic_watchdog"),
                                         ("critical", "system_memory_warning")])

    def test_trim_gate_concurrent_burst_coalesces_to_one(self):
        gate = TrimGateModel()
        results = [gate.request("critical", "jar_runtime", 50.0),
                   gate.request("warning", "periodic_watchdog", 50.0),
                   gate.request("critical", "system_memory_warning", 50.0),
                   gate.request("warning", "jar_runtime", 50.0)]
        self.assertEqual(results, [True, False, False, False])
        self.assertEqual(len(gate.queued), 1)

    def test_trim_gate_first_system_warning_admitted(self):
        gate = TrimGateModel()
        self.assertTrue(gate.request("critical", "system_memory_warning", 0.0))
        self.assertFalse(gate.request("critical", "system_memory_warning", 5.0))
        self.assertTrue(gate.request("critical", "system_memory_warning", 10.0))

    # --- PERF-11 模型 ---
    def test_lease_acquire_release_is_idempotent(self):
        leases = LeaseModel()
        token = leases.acquire("jvm", "jar-request")
        self.assertTrue(leases.has_live_lease("jvm"))
        leases.release(token)
        self.assertFalse(leases.has_live_lease("jvm"))
        leases.release(token)
        self.assertFalse(leases.has_live_lease("jvm"))
        leases.release(None)

    def test_reclaim_skips_leased_kind(self):
        leases = LeaseModel()
        leases.acquire("node", "background-job")
        reclaimed, failed = ReclaimModel().reclaim(leases, active=set(),
                                                   idle={"node", "javascript", "python"},
                                                   stop_errors={})
        self.assertNotIn("node", reclaimed)
        self.assertIn("javascript", reclaimed)
        self.assertIn("python", reclaimed)

    def test_reclaim_failed_stop_not_listed_as_reclaimed(self):
        leases = LeaseModel()
        reclaimed, failed = ReclaimModel().reclaim(leases, active=set(),
                                                   idle={"node", "javascript", "python"},
                                                   stop_errors={"node": "stop failed"})
        self.assertNotIn("node", reclaimed)
        self.assertEqual(failed, ["node"])
        self.assertIn("javascript", reclaimed)

    def test_reclaim_blocked_while_playback_active(self):
        leases = LeaseModel()
        reclaimed, failed = ReclaimModel().reclaim(leases, active=set(),
                                                   idle={"node", "javascript", "python"},
                                                   stop_errors={}, playback_active=True)
        self.assertEqual((reclaimed, failed), ([], []))

    def test_jar_ticket_lease_lifecycle(self):
        leases = LeaseModel()
        ticket = JarTicketModel(leases)
        self.assertTrue(leases.has_live_lease("jvm"))
        self.assertTrue(ticket.claim_completion())
        self.assertFalse(leases.has_live_lease("jvm"))
        self.assertFalse(ticket.claim_completion())
        ticket.cancel()
        self.assertFalse(leases.has_live_lease("jvm"))

    def test_jar_ticket_cancel_without_claim_releases(self):
        leases = LeaseModel()
        ticket = JarTicketModel(leases)
        ticket.cancel()
        ticket.cancel()
        self.assertFalse(leases.has_live_lease("jvm"))
        self.assertFalse(ticket.claim_completion())

    def test_jar_ticket_queue_full_reject_releases_without_claim(self):
        leases = LeaseModel()
        ticket = JarTicketModel(leases)
        ticket.queue_full_reject()
        self.assertFalse(leases.has_live_lease("jvm"))
        self.assertIsNone(ticket.lease)

    def test_jvm_lease_visible_while_request_in_flight(self):
        leases = LeaseModel()
        first = JarTicketModel(leases)
        second = JarTicketModel(leases)
        self.assertTrue(leases.has_live_lease("jvm"))
        first.claim_completion()
        self.assertTrue(leases.has_live_lease("jvm"))
        second.cancel()
        self.assertFalse(leases.has_live_lease("jvm"))

    # --- S6 模型 ---
    def test_search_pump_limits_by_pressure(self):
        pump = SearchPumpModel(range(10))
        self.assertEqual(pump.schedule("normal"), 6)
        self.assertEqual(len(pump.jobs), 6)
        pump2 = SearchPumpModel(range(10))
        self.assertEqual(pump2.schedule("warning"), 2)
        pump3 = SearchPumpModel(range(10))
        self.assertEqual(pump3.schedule("critical"), 1)
        pump4 = SearchPumpModel(range(10))
        self.assertEqual(pump4.schedule("unknown"), 6)

    def test_search_pump_limit_drop_never_cancels_in_flight(self):
        pump = SearchPumpModel(range(10))
        pump.schedule("normal")
        self.assertEqual(len(pump.jobs), 6)
        # 压力升到 Critical：泵送不再准入新任务，但在途 6 个一个不少。
        self.assertEqual(pump.schedule("critical"), 0)
        self.assertEqual(len(pump.jobs), 6)
        # 完成一个后仍高于新上限，不补位。
        self.assertEqual(pump.finish(0, "critical"), 0)
        self.assertEqual(len(pump.jobs), 5)
        # 压力回落，泵送自动补到 6 路。
        self.assertEqual(pump.schedule("normal"), 1)
        self.assertEqual(len(pump.jobs), 6)

    def test_neighbor_budget_by_pressure(self):
        m = NeighborBudgetModel()
        self.assertEqual(m.resolved(5, 10, "normal"), [5, 6, 4])
        self.assertEqual(m.resolved(5, 10, "unknown"), [5, 6, 4])
        self.assertEqual(m.resolved(5, 10, "warning"), [5, 6])
        self.assertEqual(m.resolved(5, 10, "critical"), [5])

    def test_neighbor_budget_edges(self):
        m = NeighborBudgetModel()
        self.assertEqual(m.resolved(0, 10, "normal"), [0, 1])
        self.assertEqual(m.resolved(9, 10, "normal"), [9, 8])
        self.assertEqual(m.resolved(0, 1, "critical"), [0])

    # --- PERF-06 源码契约 ---
    def test_budget_unknown_pressure_in_header(self):
        self.assertIn("HostMemoryBudgetPressureUnknown", BUDGET_H)
        self.assertIn("HostMemoryBudgetPressureNormal = 0", BUDGET_H)

    def test_budget_thresholds_unchanged(self):
        self.assertIn("HostMemoryWarningThresholdBytes  = 350ULL", BUDGET_M)
        self.assertIn("HostMemoryCriticalThresholdBytes = 200ULL", BUDGET_M)

    def test_budget_pressure_function_unknown_and_thermal(self):
        body = method_body(BUDGET_M, "- (HostMemoryBudgetPressure)pressureForAvailableBytes:(uint64_t)available {",
                           "- (HostMemoryBudgetPressure)currentPressure {")
        self.assertIn("if (available == 0) pressure = HostMemoryBudgetPressureUnknown;", body)
        self.assertIn("NSProcessInfoThermalStateSerious", body)
        self.assertIn("NSProcessInfoThermalStateCritical", body)
        self.assertNotIn("return HostMemoryBudgetPressureNormal;", body)

    def test_budget_trim_queue_serial_and_timer_off_main(self):
        self.assertIn('dispatch_queue_create("com.cctvhost.memory-budget.trim", DISPATCH_QUEUE_SERIAL)', BUDGET_M)
        self.assertIn("dispatch_source_t monitorTimer", BUDGET_M)
        self.assertNotIn("NSTimer *monitorTimer", BUDGET_M)
        self.assertNotIn("scheduledTimerWithTimeInterval", BUDGET_M)
        start = method_body(BUDGET_M, "- (void)startMonitoring {", "- (void)handleSystemMemoryWarning:")
        self.assertIn("dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER", start)
        self.assertIn("self.trimQueue", start)
        dealloc = method_body(BUDGET_M, "- (void)dealloc {", "@end")
        self.assertIn("dispatch_source_cancel(self.monitorTimer)", dealloc)
        self.assertNotIn("[self.monitorTimer invalidate]", dealloc)

    def test_budget_gate_serializes_and_throttles_both_levels(self):
        gate = method_body(BUDGET_M, "- (BOOL)requestTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available {",
                           "- (void)performTrimWithPressure:")
        self.assertIn("@synchronized(self)", gate)
        self.assertIn("HostMemoryTrimMinimumInterval", gate)
        self.assertIn("pressure == HostMemoryBudgetPressureNormal || pressure == HostMemoryBudgetPressureUnknown", gate)
        self.assertIn("dispatch_async(self.trimQueue", gate)
        # 审计原话：critical 没有与 warning 一样的 10 秒节流——旧的 warning-only 条件必须消失。
        self.assertNotIn("if (pressure == HostMemoryBudgetPressureWarning && (now - self.lastTrimTimestamp) < 10.0)", BUDGET_M)

    def test_budget_system_warning_goes_through_gate(self):
        handler = method_body(BUDGET_M, "- (void)handleSystemMemoryWarning:(NSNotification *)note {",
                              "- (BOOL)trimIfNeededForOperation:")
        self.assertIn("requestTrimWithPressure:HostMemoryBudgetPressureCritical", handler)
        self.assertNotIn("performTrimWithPressure:", handler)

    def test_budget_perform_trim_keeps_order_and_no_disk_wipe(self):
        body = method_body(BUDGET_M, "- (void)performTrimWithPressure:(HostMemoryBudgetPressure)pressure operation:(NSString *)operation availableBytes:(uint64_t)available {",
                           "- (void)dealloc {")
        img_pos = body.index("[HostImageLoader.shared clearCache]")
        meta_pos = body.index("[MediaMetadataCache.shared evictMemoryCache]")
        self.assertLess(img_pos, meta_pos, "图片缓存必须先于元数据缓存被回收")
        self.assertIn("if (pressure == HostMemoryBudgetPressureCritical) {\n        [MediaMetadataCache.shared evictMemoryCache];\n    }", body)
        self.assertNotIn("[MediaMetadataCache.shared clear]", body)
        # 时间戳只在门禁内写，performTrim 不再碰它。
        self.assertNotIn("self.lastTrimTimestamp =", body)

    # --- PERF-11 源码契约 ---
    def test_lifecycle_lease_api_in_header(self):
        self.assertIn("acquireLeaseForKind:(HostRuntimeKind)kind owner:", LIFE_H)
        self.assertIn("releaseLease:(nullable NSUUID *)lease", LIFE_H)

    def test_lifecycle_lease_storage_and_lookup(self):
        self.assertIn("NSMutableDictionary<NSUUID *, NSDictionary *> *leases", LIFE_M)
        acquire = method_body(LIFE_M, "- (NSUUID *)acquireLeaseForKind:", "- (void)releaseLease:")
        self.assertIn("[NSUUID UUID]", acquire)
        self.assertIn("@synchronized(self)", acquire)
        self.assertIn("hasLiveLeaseForKind:", LIFE_M)

    def test_lifecycle_reclaim_checks_lease_and_records_outcome(self):
        body = method_body(LIFE_M, "- (void)performReclaimWithReason:(NSString *)reason critical:(BOOL)critical {",
                           "- (NSError *)stopIdleSessionsForKind:")
        self.assertIn("hasLiveLeaseForKind:kind", body)
        self.assertIn("failedKinds", body)
        self.assertIn("elapsed_ms", body)
        self.assertIn("CFAbsoluteTimeGetCurrent()", body)
        # 播放守卫仍在方法开头（test_runtime_idle_reclaim 的 260 字符契约）。
        head = body[:260]
        self.assertIn("isPlaybackActive", head)
        self.assertIn("return;", head)

    def test_lifecycle_stop_returns_error(self):
        body = method_body(LIFE_M, "- (NSError *)stopIdleSessionsForKind:(HostRuntimeKind)kind {",
                           "- (NSString *)nameForKind:")
        self.assertIn("stopWithError:&error", body)
        self.assertNotIn("stopWithError:NULL", body)
        self.assertIn("return error;", body)

    def test_lifecycle_mutual_exclusion_checks_lease_too(self):
        body = method_body(LIFE_M, "- (void)prepareForMutualExclusionBeforeActivating:",
                           "- (void)reclaimIdleRuntimesForMemoryPressure:")
        self.assertIn("hasActiveSessionsForKind:other", body)
        self.assertIn("hasLiveLeaseForKind:other", body)

    def test_jar_ticket_holds_and_releases_jvm_lease(self):
        request = JAR_M[JAR_M.index("+ (MediaJARRequest *)requestSource:"):JAR_M.index("+ (id)perform:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments ticket:(MediaJARRequest *)ticket error:(NSError **)error {")]
        self.assertIn("acquireLeaseForKind:HostRuntimeKindJVM", request)
        # 租约是新增，互斥钩子必须保留（T21 自查曾误删，旧测试抓回）。
        self.assertIn("prepareForMutualExclusionBeforeActivating:HostRuntimeKindJVM", request)
        self.assertIn("[ticket releaseRuntimeLease]", request)
        claim = method_body(JAR_M, "- (BOOL)claimCompletion {", "- (void)releaseRuntimeLease {")
        self.assertIn("[self releaseRuntimeLease]", claim)
        release = method_body(JAR_M, "- (void)releaseRuntimeLease {", "- (void)cancel {")
        self.assertIn("self.runtimeLease=nil", release)
        cancel = method_body(JAR_M, "- (void)cancel {", "- (void)URLSession:")
        self.assertIn("[self releaseRuntimeLease]", cancel)

    def test_native_media_api_stub_implements_lease_methods(self):
        self.assertIn("acquireLeaseForKind:", NATIVE_API_TESTS)
        self.assertIn("releaseLease:", NATIVE_API_TESTS)

    # --- PERF-08 核查契约（无代码改动，锁住已验证的事实） ---
    def test_sync_js_runs_on_private_serial_queue_not_main(self):
        op = JS_M[JS_M.index("- (NSString *)callOperation:"):]
        dispatch_at = op.index("dispatch_async(self.queue")
        init_at = op.index("[self initializeContext]", dispatch_at)
        self.assertGreater(init_at, dispatch_at, "JS 上下文初始化在会话私有串行队列内")
        self.assertIn("dispatch_queue_create(\"cctvhost.javascript\", DISPATCH_QUEUE_SERIAL)", JS_M)
        self.assertIn('if(NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"JSPlugin" code:1', JS_M)

    def test_sync_request_timeouts_caps_and_cancel(self):
        self.assertIn('if(NSThread.isMainThread)return @{@"error":@"同步 JS 请求须从后台调用"}', SYNC_M)
        self.assertIn("timeoutIntervalForRequest=10", SYNC_M)
        self.assertIn("timeoutIntervalForResource=12", SYNC_M)
        self.assertIn("13*NSEC_PER_SEC", SYNC_M)
        self.assertIn("2*1024*1024", SYNC_M)
        self.assertIn("for(HostSyncRequest *request in self.syncRequests)[request cancel]", JS_M)

    def test_sync_request_only_called_by_js_runtime(self):
        callers = set()
        for name in os.listdir(SOURCES):
            if not name.endswith(".m"):
                continue
            with open(os.path.join(SOURCES, name), encoding="utf-8") as f:
                text = f.read()
            if "performRequest:" in text:
                callers.add(name)
        self.assertEqual(callers, {"HostSyncRequest.m", "JSPluginRuntime.m"})

    # --- S6 源码契约 ---
    def test_search_effective_limit_by_pressure(self):
        body = method_body(SEARCH_M, "- (NSUInteger)effectiveMaximumConcurrentSources {",
                           "- (void)scheduleSources {")
        self.assertIn("if (pressure == HostMemoryBudgetPressureCritical) return 1;", body)
        self.assertIn("if (pressure == HostMemoryBudgetPressureWarning) return 2;", body)
        self.assertIn("return MediaGlobalSearchMaximumConcurrentSources;", body)
        pump = method_body(SEARCH_M, "- (void)scheduleSources {", "- (void)startSourceAtSection:")
        self.assertIn("[self effectiveMaximumConcurrentSources]", pump)
        self.assertIn("MediaGlobalSearchMaximumConcurrentSources = 6", SEARCH_M)

    def test_neighbor_budget_by_pressure(self):
        body = method_body(FEED_M, "- (void)updateSlidingPoolAroundIndex:(NSInteger)centerIndex {",
                           "- (void)prepareSlotForIndex:")
        self.assertIn("neighborBudget", body)
        self.assertIn("pressure == HostMemoryBudgetPressureCritical ? 0 : (pressure == HostMemoryBudgetPressureWarning ? 1 : 2)", body)
        center_at = body.index("[self prepareSlotForIndex:centerIndex autoPlay:YES]")
        next_at = body.index("neighborBudget >= 1")
        prev_at = body.index("neighborBudget >= 2")
        self.assertLess(center_at, next_at, "中心集先于邻集发起")
        self.assertLess(next_at, prev_at, "下一集先于上一集")


if __name__ == "__main__":
    unittest.main()
