"""B4/T22 · 自适应缓冲/预热（S6、性能专项）行为测试

只读取 Sources/Tests/Plugins 文本断言不变量 + 对预热准入门禁跑 Python 模型
验证，不触发构建/网络/CI。对应审计：S6 预解析、next episode、源探测与中继
暖机存在多个独立预算；NativeChannelPreloader 单 metadata player、autoPlay=NO、
90 秒 TTL、代际校验；MediaPlaybackBufferPolicy 速率/卡顿/constrained 缓冲，
首帧后渐进式 3.5/4/8/12s，距结尾 ≤min(90s,25% 时长)、缓冲≥2s 才预取；中继
有界预热；PlaybackCoordinator 旧会话只是 pause。

T22 改动：
1. HostMemoryBudgetCoordinator（S6）：新增 +shouldAllowBackgroundWarmup——
   非必要后台预热（原生频道预解析、下一集预取）的新开任务统一准入：
   Normal/Unknown 允许，Warning/Critical 拒绝，低电量模式拒绝；热状态已折进
   currentPressure。只管新准入，不取消在途任务（在途工作本身有界：预热单槽
   90s TTL、下一集预取单次 15s 客户端超时、中继预热 4 线程 + 10s 流过期）。
2. RootViewController+Playback（S6）：prepareNextNativeChannelForGeneration:
   的既有门禁追加预热门禁（原有 generation/首帧/时移/播放器/偏好/前台条件不动）。
3. MediaPlaybackViewController（S6）：prefetchNextEpisodeIfNeeded 首行门禁
   追加预热门禁（原有 resolving/在途/首帧/待 seek/续播提示条件不动；被拒的
   尝试不写 prefetchLastAttemptAt，不污染 30s 最小间隔，压力回落后下一轮
   调用自动恢复）。
4. NativeChannelPreloader（S6）：新增命中/浪费记账——preparedCount（成功发起
   的 SDK 元数据准备次数）、hitCount（交割成功次数）、wasteCount（已发起准备
   被丢弃且未交割的次数：取消/过期/失败/被取代）。只读快照，不参与准入门禁；
   原生 harness（Tests/native_preloader_tests.m）断言全流程终态 P=8/H=1/W=7。

语义不变（只核查 + 锁契约，不改代码）：
- 缓冲策略阈值不动（无真实基线不准调）：MediaPlaybackBufferPolicy.h 的
  3.5/4/8/12s 渐进坡、90s/25% 预取窗口、缓冲≥2s 门禁由原生
  native_playback_buffer_policy_tests.m 行为覆盖，本文件再锁常量文本。
- metadata 预热与真实解码分离：预热器 autoPlay=NO、单槽、statEvent==3 取消、
  交割不 reset；下一集预取只做 AV asset `playable` 元数据加载，永不盲 Range
  取流；本文件锁住这些不变量（其余由 test_d_channel_prewarm_audit_contracts
  锁住）。
- 不延长总失败等待时间：下一集预取与新解析走同一 MediaAPIClient `play`
  调用，同一 15s play 超时（request.timeoutInterval 按 operation 取
  playTimeoutMilliseconds）；推进（promote）路径在调度 hedged 备份解析前
  直接返回，不另起等待；预取完成回调清 prefetchInFlight。
- 中继预热有界：hostname 门禁（显式开关优先，否则只对非本地域名）、4 线程
  执行器、key 缓存 256、map 缓存 32、预取流 4 条 + 10s 过期。

明确不做（有意延期，原因写进报告）：
- 阈值不动：预热 90s TTL、预取 30s 最小间隔、120s 新鲜度、缓冲坡——无真实
  基线证据，不调数字。
- 在途预热不因压力取消：准入-only（与 T21 的搜索/邻集口径一致）；在途工作
  有界，取消节省有限且可能打断正在推进的解析。
- 下一集预取的浪费计数未进 MediaPlaybackViewController.m：该文件 2914 行，
  行数预算 2916 已被准入门禁（import + 门禁）占满；推进命中已有诊断事件
  episode_prefetch_promoted，浪费计数待行数预算松动后再补。
- RootViewController.m 内存告警时取消在途预热未做：该文件 1599/1600 无行数
  余量；预热单槽 90s TTL + 准入已按压力门禁，告警后不再新开。
"""
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")
TESTS = os.path.join(REPO_ROOT, "Tests")
PLUGINS = os.path.join(REPO_ROOT, "Plugins")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


def method_body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


BUDGET_H = read_source("HostMemoryBudgetCoordinator.h")
BUDGET_M = read_source("HostMemoryBudgetCoordinator.m")
PRELOADER_H = read_source("NativeChannelPreloader.h")
PRELOADER_M = read_source("NativeChannelPreloader.m")
PRELOADER_TESTS = open(os.path.join(TESTS, "native_preloader_tests.m"), encoding="utf-8").read()
RVC_PLAYBACK = read_source("RootViewController+Playback.m")
VC_M = read_source("MediaPlaybackViewController.m")
BUFFER_POLICY_H = read_source("MediaPlaybackBufferPolicy.h")
API_CLIENT_M = read_source("MediaAPIClient.m")
RELAY_PY = open(os.path.join(PLUGINS, "host_media_relay.py"), encoding="utf-8").read()


# --- S6：预热准入门禁的 Python 模型（与 ObjC 语义同构） ---
class WarmupAdmissionModel:
    """shouldAllowBackgroundWarmup 的模型：低电量拒绝；Warning/Critical 拒绝；
    Normal/Unknown 允许。热状态已折进压力值，不另设维度。"""

    NORMAL = "normal"
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

    def allows(self, pressure, low_power):
        if low_power:
            return False
        return pressure in (self.NORMAL, self.UNKNOWN)


class WarmupAdmissionModelTests(unittest.TestCase):
    def test_normal_and_unknown_allow(self):
        m = WarmupAdmissionModel()
        self.assertTrue(m.allows(m.NORMAL, False))
        self.assertTrue(m.allows(m.UNKNOWN, False))

    def test_warning_and_critical_deny(self):
        m = WarmupAdmissionModel()
        self.assertFalse(m.allows(m.WARNING, False))
        self.assertFalse(m.allows(m.CRITICAL, False))

    def test_low_power_denies_even_when_normal(self):
        m = WarmupAdmissionModel()
        self.assertFalse(m.allows(m.NORMAL, True))
        self.assertFalse(m.allows(m.UNKNOWN, True))

    def test_low_power_denies_at_every_pressure(self):
        m = WarmupAdmissionModel()
        for pressure in (m.NORMAL, m.WARNING, m.CRITICAL, m.UNKNOWN):
            self.assertFalse(m.allows(pressure, True), pressure)


class WarmupAdmissionContractTests(unittest.TestCase):
    def test_budget_coordinator_declares_warmup_admission(self):
        self.assertIn("+ (BOOL)shouldAllowBackgroundWarmup;", BUDGET_H)

    def test_warmup_admission_checks_low_power_then_pressure(self):
        body = method_body(BUDGET_M, "+ (BOOL)shouldAllowBackgroundWarmup {", "- (void)startMonitoring {")
        self.assertIn("NSProcessInfo.processInfo.lowPowerModeEnabled", body)
        self.assertIn("[[self shared] currentPressure]", body)
        self.assertIn("pressure == HostMemoryBudgetPressureNormal || pressure == HostMemoryBudgetPressureUnknown", body)

    def test_native_preloader_gate_appended_to_existing_conditions(self):
        # 门禁追加到 prepareNextNativeChannelForGeneration: 的既有条件行，
        # 不新增早返分支；原有 generation/首帧/时移/播放器/偏好/前台条件不动。
        body = method_body(RVC_PLAYBACK, "- (void)prepareNextNativeChannelForGeneration:", "- (void)player:(id)player playBackStateDidChanged:")
        self.assertIn("![HostMemoryBudgetCoordinator shouldAllowBackgroundWarmup]", body)
        for kept in ("generation!=self.playbackGeneration", "!self.firstRender",
                     "self.nativeTimeShiftActive", "!self.currentPlayer", "self.avPlayer",
                     "self.directNativeRouteActive", 'CCTVBoolPreference(@"preloadNativeChannel",YES)',
                     "UIApplicationStateActive"):
            self.assertIn(kept, body)
        self.assertIn('#import "HostMemoryBudgetCoordinator.h"', RVC_PLAYBACK)

    def test_next_episode_prefetch_gate_appended_to_first_line(self):
        # 门禁追加到 prefetchNextEpisodeIfNeeded 首行条件；被拒的尝试不写
        # prefetchLastAttemptAt（30s 最小间隔只在真正发起预取时写）。
        body = method_body(VC_M, "- (void)prefetchNextEpisodeIfNeeded {", "- (void)resourceLoader:")
        first_line = next(l for l in body.split("\n") if "self.resolving" in l)
        self.assertIn("![HostMemoryBudgetCoordinator shouldAllowBackgroundWarmup]", first_line)
        for kept in ("self.resolving", "self.prefetchInFlight", "!self.videoFrameReady",
                     "self.pendingPlaybackSeekTime", "self.resumePromptPending"):
            self.assertIn(kept, first_line)
        self.assertIn('#import "HostMemoryBudgetCoordinator.h"', VC_M)
        attempt_write = body.index("self.prefetchLastAttemptAt=CACurrentMediaTime();")
        should_prefetch = body.index("MediaPlaybackShouldPrefetch(")
        self.assertLess(should_prefetch, attempt_write,
                        "30s 最小间隔写在 ShouldPrefetch 通过之后，门禁拒绝不污染间隔")

    def test_denied_warmup_does_not_start_new_work(self):
        # 两处调用方都只在门禁行做判断：预热器 prepareChannel 与预取客户端
        # call 均在门禁之后，无绕过路径。
        preloader_gate = RVC_PLAYBACK.index("![HostMemoryBudgetCoordinator shouldAllowBackgroundWarmup]")
        prepare_call = RVC_PLAYBACK.index("[self.nativePreloader prepareChannel:", preloader_gate)
        self.assertGreater(prepare_call, preloader_gate)
        prefetch_gate = VC_M.index("![HostMemoryBudgetCoordinator shouldAllowBackgroundWarmup]")
        client_call = VC_M.index("[self.prefetchClient call:", prefetch_gate)
        self.assertGreater(client_call, prefetch_gate)


class PreloaderLedgerContractTests(unittest.TestCase):
    def test_header_declares_readonly_counters(self):
        for decl in ("@property(nonatomic,readonly) NSUInteger preparedCount;",
                     "@property(nonatomic,readonly) NSUInteger hitCount;",
                     "@property(nonatomic,readonly) NSUInteger wasteCount;"):
            self.assertIn(decl, PRELOADER_H)

    def test_prepared_counted_after_successful_play_live(self):
        # prepared 只在 playLIVE 成功返回后计一次；playLIVE 失败/selector
        # 缺失的路径在计数前 return，不计入。
        body = method_body(PRELOADER_M, "- (void)prepareChannel:", "- (id)takeChannel:")
        self.assertIn("if(![player playLIVEWithChannelID:", body)
        play_live = body.index("playLIVEWithChannelID:")
        counted = body.index("self.preparedCount++;")
        prepare_rate = body.index("[player prepareRateItemToPlay_completionBlock:")  # 实际调用，非 selector 数组里的字面量
        self.assertLess(play_live, counted)
        self.assertLess(counted, prepare_rate)

    def test_hit_counted_only_on_successful_take(self):
        body = method_body(PRELOADER_M, "- (id)takeChannel:", "- (void)cancel {")
        self.assertIn("self.hitCount++;self.generation++;", body)
        guard = body.index("if(!self.ready")
        counted = body.index("self.hitCount++;")
        self.assertLess(guard, counted, "守卫不通过（未 ready/频道不符/过期）时先 cancel 返回，不计 hit")

    def test_waste_counted_only_when_live_preparation_discarded(self):
        # cancel 里有 live player 才计 waste：空槽 cancel（重复取消、交割后）
        # 不计；被取代/过期/失败/取消的在途准备都计一次。
        body = method_body(PRELOADER_M, "- (void)cancel {", "- (void)dealloc {")
        self.assertIn("if(player)self.wasteCount++;", body)

    def test_native_harness_asserts_ledger_totals(self):
        # 原生 harness 全流程终态：发起 8 次、交割 1 次、丢弃 7 次（未 ready
        # 取用 1、过期 1、被取代 1、错频道取用 1、失败 1、显式取消 1、
        # 另一次取用后取消不计）。
        self.assertIn("p.preparedCount==2&&p.hitCount==1&&p.wasteCount==1", PRELOADER_TESTS)
        self.assertIn("p.preparedCount==3&&p.hitCount==1&&p.wasteCount==2", PRELOADER_TESTS)
        self.assertIn("p.preparedCount==8&&p.hitCount==1&&p.wasteCount==7", PRELOADER_TESTS)


class BufferPolicyUnchangedContractTests(unittest.TestCase):
    def test_smooth_ramp_thresholds_unchanged(self):
        # 首帧后渐进式 3.5/4/8/12s：无真实基线不调数字，只锁常量。
        self.assertIn("double base=3.5;", BUFFER_POLICY_H)
        self.assertIn("if(observed>=6.0)base=constrained?5.0:8.0;", BUFFER_POLICY_H)
        self.assertIn("else if(observed>=2.0)base=4.0;", BUFFER_POLICY_H)
        self.assertIn("MIN(constrained?12.0:30.0,base*MAX(1.0,rate))", BUFFER_POLICY_H)

    def test_prefetch_window_thresholds_unchanged(self):
        self.assertIn("bufferedAhead<2", BUFFER_POLICY_H)
        self.assertIn("duration-position<=MIN(90.0,duration*0.25)", BUFFER_POLICY_H)
        self.assertIn("position<2||duration<=0||position>=duration", BUFFER_POLICY_H)

    def test_preloader_ttl_and_prefetch_intervals_unchanged(self):
        self.assertIn("NativeChannelPreloaderTTLSeconds = 90.0;", PRELOADER_M)
        self.assertIn("CACurrentMediaTime()-self.prefetchLastAttemptAt<30", VC_M)
        self.assertIn("(CACurrentMediaTime()-self.prefetchedAt)<120.0", VC_M)
        self.assertIn("self.prefetchedAssetAt>0&&CACurrentMediaTime()-self.prefetchedAssetAt<120.0", VC_M)


class MetadataWarmupSeparationContractTests(unittest.TestCase):
    def test_preloader_never_auto_plays_and_never_starts_video(self):
        self.assertIn("player.autoPlay=NO;", PRELOADER_M)
        self.assertNotIn("autoPlay=YES", PRELOADER_M)
        take = method_body(PRELOADER_M, "- (id)takeChannel:", "- (void)cancel {")
        self.assertNotIn("playLIVEWithChannelID:", take)
        self.assertNotIn("prepareToPlay", take)

    def test_prefetch_asset_loads_metadata_only(self):
        # 下一集预取只加载 AV asset `playable` 元数据键，永不盲 Range 取流、
        # 永不下载整段媒体（注释即契约）。
        body = method_body(VC_M, "- (void)prepareAssetForPrefetchedResult:", "- (void)prefetchNextEpisodeIfNeeded {")
        self.assertIn('loadValuesAsynchronouslyForKeys:@[@"playable"]', body)
        self.assertIn("Metadata only: keep one reusable asset, never issue blind Range fetches", body)

    def test_stale_prefetched_asset_cancelled_on_consume(self):
        body = method_body(VC_M, "- (AVURLAsset *)consumePrefetchedAssetForURL:", "- (AVURLAsset *)assetForPlaybackURL:")
        self.assertIn("[self.prefetchedAsset cancelLoading];", body)


class FailureWaitContractTests(unittest.TestCase):
    def test_play_operation_timeout_bounds_prefetch_and_fresh_resolve(self):
        # 预取与新解析走同一 MediaAPIClient `play` 调用，同一 15s play 超时；
        # 推进不延长总失败等待时间。
        self.assertIn('request.timeoutInterval=[operation isEqual:@"play"]?self.playTimeoutMilliseconds/1000.0:self.requestTimeout;', API_CLIENT_M)
        self.assertIn("_playTimeoutMilliseconds=15000;", API_CLIENT_M)
        self.assertIn('[self.prefetchClient call:@"play"', VC_M)

    def test_promoted_prefetch_returns_before_hedged_backup(self):
        # 推进路径在调度 hedged 备份解析前直接返回：失败时走正常失败路径，
        # 不另起一份等待。
        body = method_body(VC_M, "if(promotePrefetch){", "[self scheduleHedgedBackupLineResolutionForGeneration:generation];")
        self.assertIn("self.promotedPrefetchCompletion=completion;", body)
        self.assertIn("return;", body)
        resolve = method_body(VC_M, "- (void)resolveAndPlay {", "- (void)reloadThemeAppearance {")
        self.assertLess(resolve.index("if(promotePrefetch){"), resolve.index("[self scheduleHedgedBackupLineResolutionForGeneration:generation];"))

    def test_prefetch_completion_clears_in_flight_flag(self):
        body = method_body(VC_M, "- (void)prefetchNextEpisodeIfNeeded {", "- (void)resourceLoader:")
        self.assertIn("owner.prefetchInFlight=NO;", body)


class RelayWarmupBoundedContractTests(unittest.TestCase):
    def test_warmup_executor_bounded(self):
        self.assertIn("max_workers=4", RELAY_PY)
        self.assertIn("thread_name_prefix='cctvhost-hls-warmup'", RELAY_PY)

    def test_warmup_caches_bounded(self):
        self.assertIn("while len(self.remote_key_cache) > 256:", RELAY_PY)
        self.assertIn("while len(self.remote_map_cache) > 32:", RELAY_PY)
        self.assertIn("while len(self.prefetched_segment_streams) >= 4:", RELAY_PY)
        self.assertIn("now - v[2] >= 10.0", RELAY_PY)

    def test_warmup_gated_by_hostname(self):
        body = RELAY_PY[RELAY_PY.index("def _should_speculative_warmup"):]
        self.assertIn("host not in ('127.0.0.1', 'localhost', '::1')", body)
        self.assertIn("if self.speculative_warmup is not None:", body)


class LineBudgetContractTests(unittest.TestCase):
    def test_budgeted_files_within_limits(self):
        # 行数预算（硬）：RootViewController.m <1600、RootViewController+Playback.m
        # <1600、MediaPlaybackViewController.m ≤2916。T22 在 VC 用掉最后余量
        # （import + 门禁并入首行条件），RVC+Playback 用掉 import 一行。
        for name, limit in (("RootViewController.m", 1600),
                            ("RootViewController+Playback.m", 1600),
                            ("MediaPlaybackViewController.m", 2916)):
            path = os.path.join(SOURCES, name)
            with open(path, encoding="utf-8") as f:
                lines = sum(1 for _ in f)
            check = lines < limit if limit == 1600 else lines <= limit
            self.assertTrue(check, f"{name} {lines} 行，超出预算 {limit}")


if __name__ == "__main__":
    unittest.main()
