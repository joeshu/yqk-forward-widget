"""B4/T20 · 引擎开销（S4/S5）行为测试

只读取 Sources 文本断言不变量 + 对合并/缓存/队列跑 Python 模型验证，不触发构建/网络/CI。
对应审计：S4 MPV 初始化与控制在调用线程同步执行、track 枚举同步读取、
选项设置返回值多未检查、eventLoopMain 一个外层 autoreleasepool 覆盖长时循环、
逐属性派发 main queue；S5 demuxer-cache-time 当 bufferedPosition、
playbackStatistics 返回空字典。

T20 改动：
1. MPV 串行命令队列（com.cctvhost.mpv.command）：全部 handle 触碰只在
   队列上执行；prepare 的创建/初始化/loadfile 进队列异步执行（loadfile
   改 command_async，队列永不因网络 open 而堵住）；首帧 watchdog 回
   主线程 arm（命令队列无 runloop）；destroy 排队期间的 prepare 块
   由 Gate 1/2 拦截，不创建句柄、不调 abandon（teardown 归 destroy）。
2. 轨道缓存：availableTracks 只读缓存；枚举抽成 helper 只在命令队列
   上跑（FILE_LOADED 与 track-list/count 变化时重建）；select 成功后
   乐观更新缓存选中态（T09 验证重查可见）；destroy 清缓存。
3. 受检调用：set_option/set_option_string/observe_property 经
   mpvSetOption*/mpvObserveProperty，失败记名、prepare 末尾一次性报
   mpv_option_failed（不改失败策略）；set_property 经 mpvSetProperty*，
   失败记 mpv_control_failed。
4. 事件循环：每轮一个 autoreleasepool；time-pos/cache-speed/cache-time
   向主线程合并到 4Hz（窗口内只留最新值，每次 wake 刷一次）；
   duration 只在变化时转发；终态/首帧/seek/缓冲状态变化始终即时。
5. Cicada：onCurrentDownLoadSpeed 转发节流 0.5s；onLoadingProgress 转发
   节流 0.35s（到 1.0 即加载结束，始终即时）。prepare 仍在调用线程
   （内核启动时已初始化、prepare 内部异步，见报告）；轨道枚举仍是
   进程内 KVC 读（无 IPC 往返），不动。
6. S5：两 adapter 的 13 键统计契约是 T08 已交付——本轮只做回归验证，
   不重做（键集合由 test_playback_engine_interface_contract 锁住）。

语义不变：T02 生命周期门禁与 abandon 计数、T08 首帧/seek/统计口径、
T09 菜单验证（重查 selected）、T10 PiP 标记均保留；MediaPlaybackViewController
零改动；控制方法的返回值语义不变（select 仍同步返回下发结果）。
"""
import collections
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


def method_body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


MPV_M = read_source("MediaPlaybackMPVAdapter.m")
CICADA_M = read_source("MediaPlaybackCicadaAdapter.m")


# --- 高频事件合并的 Python 模型（与事件循环的节流+flush 同构） ---
class CoalescingModel:
    """时间以 1/60 秒 tick 计（避免浮点噪声）；窗口 15 tick = 0.25s。

    on_event：窗口到即派发，否则只留最新值；on_wake：每次循环 wake
    时把窗口内攒下的最新值刷出（对应 wait_event 0.25s 超时空转）。
    """

    INTERVAL_TICKS = 15

    def __init__(self):
        # last 初始远负：对应 ObjC 里 last*DispatchAt 初始 0 而
        # CACurrentMediaTime() 是很大的启动后秒数，首个事件必定即时派发。
        self.last = -10 ** 9
        self.pending = None
        self.has_pending = False
        self.dispatched = []  # (tick, value)

    def on_event(self, tick, value):
        if tick - self.last >= self.INTERVAL_TICKS:
            self.last = tick
            self.has_pending = False
            self.dispatched.append((tick, value))
        else:
            self.pending = value
            self.has_pending = True

    def on_wake(self, tick):
        if self.has_pending and tick - self.last >= self.INTERVAL_TICKS:
            self.last = tick
            value = self.pending
            self.has_pending = False
            self.dispatched.append((tick, value))


# --- 轨道缓存的 Python 模型（与 rebuild/乐观更新/T09 验证同构） ---
class TrackCacheModel:
    def __init__(self):
        self.tracks = []

    def rebuild(self, engine_tracks):
        self.tracks = [dict(t) for t in engine_tracks]

    def select(self, index, kind, selected=True):
        # 对应 updateCachedTrackSelectionForIndex:kind:selected:
        for t in self.tracks:
            if t["type"] == kind:
                t["selected"] = bool(selected and t["index"] == index)

    def verify_selection(self, index, kind):
        # 对应 MediaPlaybackSettingsCoordinator verifyTrackSelectionForAdapter
        for t in self.tracks:
            if t["type"] == kind and t["index"] == index:
                return t["selected"] is True
        return False

    def verify_off(self, kind):
        # 对应 verifyTrackOffForAdapter
        return not any(t["type"] == kind and t["selected"] for t in self.tracks)


# --- 受检 option 的 Python 模型（与 mpvSetOption*/上报同构） ---
class CheckedOptionsModel:
    def __init__(self, failing):
        self.failing = set(failing)
        self.failed = []
        self.events = []

    def set_option(self, name):
        if name in self.failing:
            self.failed.append(name)
            return -1
        return 0

    def finish_prepare(self, diagnostics_enabled):
        if self.failed and diagnostics_enabled:
            self.events.append(("mpv_option_failed", ",".join(self.failed)))
        self.failed.clear()


class EngineOverheadT20Tests(unittest.TestCase):
    # ---------- M1：串行命令队列 + prepare 离开调用线程 ----------
    def test_mpv_command_queue_is_serial_with_reentrancy_guard(self):
        self.assertIn('dispatch_queue_create("com.cctvhost.mpv.command", DISPATCH_QUEUE_SERIAL)', MPV_M)
        self.assertIn("dispatch_queue_set_specific(_commandQueue, kMediaPlaybackMPVCommandQueueKey", MPV_M)
        self.assertIn("dispatch_get_specific(kMediaPlaybackMPVCommandQueueKey)", MPV_M)
        self.assertIn("- (void)runOnCommandQueue:(dispatch_block_t)block;", MPV_M)
        self.assertIn("- (void)runOnCommandQueueSync:(dispatch_block_t)block;", MPV_M)

    def test_prepare_heavy_work_runs_on_command_queue(self):
        prepare = method_body(MPV_M, "- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder {",
                              "- (void)prepareHandleWithSymbols:")
        self.assertIn("dispatch_async(self.commandQueue, ^{", prepare)
        self.assertIn("- (void)prepareHandleWithSymbols:(const CCTVMPVSymbolTable *)syms enableHardwareDecoder:(BOOL)enableHardwareDecoder;", MPV_M)
        # loadfile 不再同步堵队列；首帧 watchdog 回主线程 arm（队列无 runloop）。
        self.assertIn("syms->command_async(ctx, 0, loadCmd)", MPV_M)
        self.assertNotIn("syms->command(ctx, loadCmd)", MPV_M)
        self.assertIn("[self runOnMain:^{ [self armFirstFrameWatchdog]; }];", MPV_M)

    def test_prepare_block_aborts_when_destroy_claimed_first(self):
        # Gate 1（排队期间）与 Gate 2（init 之后、发布句柄之前）：destroy
        # 认领后 lifecycle 不再是 PREPARED，块静默返回、不创建句柄；
        # Gate 2 的孤儿 ctx 由本块自行 terminate_destroy。
        self.assertIn("host_mpv_lifecycle_state(strongSelf->_lifecycle) != HOST_MPV_LC_PREPARED", MPV_M)
        self.assertIn("host_mpv_lifecycle_state(_lifecycle) != HOST_MPV_LC_PREPARED", MPV_M)
        # abandon 计数仍是 4（调用方 2 处 + 块内 2 处），T02 契约不破。
        self.assertEqual(MPV_M.count("host_mpv_lifecycle_abandon_prepare(_lifecycle)"), 4)

    def test_control_methods_route_through_command_queue(self):
        async_methods = (
            ("- (void)start {", "- (void)pause {"),
            ("- (void)pause {", "- (void)stop {"),
            ("- (void)stop {", "- (void)destroy {"),
            ("- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL finished))completion {",
             "- (void)setRate:(float)rate {"),
            ("- (void)setRate:(float)rate {", "- (void)setMuted:(BOOL)muted {"),
            ("- (void)setMuted:(BOOL)muted {", "- (BOOL)canSelectTracks {"),
            ("- (void)applyVideoGravity:(NSString *)gravity {", "- (void)applyGravity:"),
            ("- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL {", "- (void)applyVideoGravity:"),
        )
        for start, end in async_methods:
            body = method_body(MPV_M, start, end)
            self.assertIn("runOnCommandQueue:", body, start)
            # stop 从来没有调用方门禁（旧代码只查 destroyed；T02 契约
            # 也不列它）——门禁在队列块内（strongSelf 形态）重查。
            if start != "- (void)stop {":
                self.assertIn("host_mpv_lifecycle_command_allowed(_lifecycle)", body, start)
        # 需返回值的走同步队列（T09 验证时序不变；句柄未发布走 fast path）。
        for start, end in (
                ("- (BOOL)selectTrackWithIndex:(NSInteger)index {", "- (BOOL)addExternalSubtitleURL:"),
                ("- (NSDictionary<NSString *, id> *)playbackStatistics {", "- (void)handleFailureWithCode:"),
        ):
            body = method_body(MPV_M, start, end)
            self.assertIn("runOnCommandQueueSync:", body, start)
            self.assertIn("handleLive", body, start)

    def test_no_direct_handle_calls_outside_checked_helpers(self):
        # 全部 set_option/set_property/observe_property 只剩 helper 内
        # 各 1 处直接调用；同步 command（loadfile）已清零；async 命令
        # 仍是 5 处（stop/quit/seek/sub-add/loadfile）。
        for call in ("syms->set_option(", "syms->set_option_string(",
                    "syms->set_property(", "syms->set_property_string(",
                    "syms->observe_property("):
            self.assertEqual(MPV_M.count(call), 1, call)
        self.assertEqual(MPV_M.count("syms->command(ctx"), 0)
        self.assertEqual(MPV_M.count("command_async(ctx, 0,"), 5)

    # ---------- M2：轨道缓存 ----------
    def test_track_list_is_cached_not_enumerated_per_read(self):
        tracks = method_body(MPV_M, "- (NSArray<NSDictionary *> *)availableTracks {",
                             "- (NSArray<NSDictionary *> *)enumerateTracksFromHandle:")
        self.assertIn("self.cachedTracks", tracks)
        self.assertNotIn("get_property_string", tracks)
        self.assertNotIn("track-list/count", tracks)
        enumerated = method_body(MPV_M, "- (NSArray<NSDictionary *> *)enumerateTracksFromHandle:",
                                 "- (void)rebuildCachedTracksOnCommandQueue")
        self.assertIn("i < 64", enumerated)
        self.assertIn('@"selected"', enumerated)
        # 观测 track-list/count；FILE_LOADED 与数量变化时重建。
        self.assertIn('mpvObserveProperty:ctx tag:CCTVMPVReplyTrackListCount name:"track-list/count"', MPV_M)
        self.assertGreaterEqual(MPV_M.count("rebuildCachedTracksOnCommandQueue"), 3)
        # destroy 清缓存。
        destroy = method_body(MPV_M, "- (void)destroy {", "- (void)seekToTime:")
        self.assertIn("self.cachedTracks = nil;", destroy)

    def test_select_updates_cache_optimistically_for_t09_verification(self):
        select = method_body(MPV_M, "- (BOOL)selectTrackWithIndex:(NSInteger)index {",
                             "- (BOOL)addExternalSubtitleURL:")
        self.assertIn("updateCachedTrackSelectionForIndex:index kind:kind selected:", select)
        update = method_body(MPV_M, "- (void)updateCachedTrackSelectionForIndex:",
                             "- (BOOL)selectTrackWithIndex:")
        self.assertIn('copy[@"selected"] = @(selected && isTarget);', update)

    # ---------- M3：受检调用 ----------
    def test_option_and_property_calls_are_checked_and_recorded(self):
        self.assertIn('#import "RuntimeDiagnostics.h"', MPV_M)
        for helper in ("- (int)mpvSetOptionString:", "- (int)mpvSetOptionInt:",
                       "- (int)mpvObserveProperty:", "- (int)mpvSetProperty:",
                       "- (int)mpvSetPropertyString:"):
            self.assertIn(helper, MPV_M)
        self.assertIn('"mpv_option_failed"', MPV_M)
        self.assertIn('"mpv_control_failed"', MPV_M)
        self.assertIn("[self.failedOptionNames componentsJoinedByString:@\",\"]", MPV_M)

    # ---------- M4：事件循环合并 ----------
    def test_event_loop_coalesces_high_frequency_events(self):
        self.assertIn("MediaPlaybackMPVEventCoalesceInterval = 0.25", MPV_M)
        for helper in ("- (void)dispatchPositionUpdate:(double)pos;",
                       "- (void)dispatchDownloadSpeedUpdate:(double)bytesPerSec;",
                       "- (void)dispatchCacheTimeUpdate:(double)buf;",
                       "- (void)flushPendingCoalescedEventsIfDue;"):
            self.assertIn(helper, MPV_M)
        loop = MPV_M[MPV_M.index("- (void)eventLoopMain:"):]
        self.assertIn("[self flushPendingCoalescedEventsIfDue];", loop)
        # 每轮一个 pool：外层 1 个 + 循环内 1 个，且内层包住 wait_event。
        self.assertEqual(loop.count("@autoreleasepool"), 2)
        inner_pool = loop.index("@autoreleasepool", loop.index("while (!self.destroyed)"))
        self.assertLess(inner_pool, loop.index("wait_event", inner_pool))
        # duration 只在变化时转发；终态分支仍即时（FILE_LOADED/END_FILE
        # 不经过节流 helper）。
        self.assertIn("hasForwardedDuration", MPV_M)
        self.assertIn("CCTVMPVReplyTrackListCount", loop)

    # ---------- M5：Cicada 节流 ----------
    def test_cicada_callbacks_are_throttled_not_restructured(self):
        speed = method_body(CICADA_M, "- (void)onCurrentDownLoadSpeed:",
                            "- (void)onVideoSizeChanged:")
        self.assertIn("lastSpeedEmission", speed)
        self.assertIn("< 0.5", speed)
        progress = method_body(CICADA_M, "- (void)onLoadingProgress:",
                               "- (void)onPlayerStatusChanged:")
        self.assertIn("lastLoadingProgressEmission", progress)
        self.assertIn("< 0.35", progress)
        self.assertIn("clamped < 1.0f &&", progress)
        # prepare 仍在调用线程（内核启动时已初始化、prepare 内部异步），
        # 不建命令队列；轨道枚举仍是进程内 KVC 读。
        prepare = method_body(CICADA_M, "- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder {",
                              "- (void)armFirstFrameWatchdog {")
        self.assertNotIn("dispatch_async", prepare)
        self.assertNotIn("commandQueue", CICADA_M)
        self.assertIn('valueForKey:@"mediaInfo"', CICADA_M)

    # ---------- 行为模型 ----------
    def test_coalescing_caps_main_thread_dispatches_at_4hz(self):
        model = CoalescingModel()
        for tick in range(0, 121):  # 60Hz 事件，持续 2 秒
            model.on_event(tick, value=tick)
            model.on_wake(tick)
        # 首次即时 + 之后每 15 tick 一次：0,15,...,120 共 9 次。
        self.assertEqual(len(model.dispatched), 9)
        self.assertEqual([t for t, _ in model.dispatched],
                         [0, 15, 30, 45, 60, 75, 90, 105, 120])
        gaps = [b - a for (a, _), (b, _) in zip(model.dispatched, model.dispatched[1:])]
        self.assertTrue(all(g == 15 for g in gaps))

    def test_coalescing_delivers_latest_value_within_window(self):
        model = CoalescingModel()
        for tick in range(0, 115):  # 流在窗口中途（tick 114）停止
            model.on_event(tick, value=tick)
            model.on_wake(tick)
        self.assertTrue(model.has_pending)
        self.assertEqual(model.pending, 114)
        model.on_wake(120)  # 下一次循环 wake（0.25s 后）
        self.assertFalse(model.has_pending)
        self.assertEqual(model.dispatched[-1], (120, 114))

    def test_duration_forwards_only_on_change(self):
        forwarded = []
        has_forwarded = False
        last_forwarded = None
        for duration in (120.0, 120.0, 120.0, 121.5, 121.5, 0.0):
            if not has_forwarded or duration != last_forwarded:
                has_forwarded = True
                last_forwarded = duration
                forwarded.append(duration)
        self.assertEqual(forwarded, [120.0, 121.5, 0.0])

    def test_cached_tracks_verify_selection_after_switch(self):
        cache = TrackCacheModel()
        cache.rebuild([
            {"type": "audio", "index": 1, "name": "中文", "selected": True},
            {"type": "audio", "index": 2, "name": "English", "selected": False},
            {"type": "subtitle", "index": 10001, "name": "中字", "selected": False},
        ])
        self.assertTrue(cache.verify_selection(1, "audio"))
        cache.select(2, "audio", selected=True)
        self.assertTrue(cache.verify_selection(2, "audio"))
        self.assertFalse(cache.verify_selection(1, "audio"))
        self.assertFalse(cache.verify_selection(10001, "subtitle"))

    def test_cached_tracks_verify_off_after_sentinel(self):
        cache = TrackCacheModel()
        cache.rebuild([
            {"type": "audio", "index": 1, "name": "中文", "selected": True},
            {"type": "subtitle", "index": 10001, "name": "中字", "selected": True},
        ])
        cache.select(0, "audio", selected=False)  # 关闭哨兵
        self.assertTrue(cache.verify_off("audio"))
        self.assertFalse(cache.verify_off("subtitle"))

    def test_rebuild_resyncs_selection_from_engine(self):
        cache = TrackCacheModel()
        cache.rebuild([{"type": "audio", "index": 1, "name": "中文", "selected": True}])
        cache.select(1, "audio", selected=False)  # 乐观更新后引擎又否了
        cache.rebuild([{"type": "audio", "index": 1, "name": "中文", "selected": True}])
        self.assertTrue(cache.verify_selection(1, "audio"))

    def test_failed_options_recorded_once_per_prepare(self):
        model = CheckedOptionsModel(failing={"vo", "gpu-api"})
        for name in ("wid", "vo", "gpu-api", "ao", "hwdec"):
            model.set_option(name)
        model.finish_prepare(diagnostics_enabled=True)
        self.assertEqual(model.events, [("mpv_option_failed", "vo,gpu-api")])
        # 成功路径与诊断关闭时都不产生事件。
        clean = CheckedOptionsModel(failing=set())
        for name in ("vo", "ao"):
            clean.set_option(name)
        clean.finish_prepare(diagnostics_enabled=True)
        self.assertEqual(clean.events, [])
        quiet = CheckedOptionsModel(failing={"vo"})
        quiet.set_option("vo")
        quiet.finish_prepare(diagnostics_enabled=False)
        self.assertEqual(quiet.events, [])

    def test_prepare_block_aborts_when_destroy_claimed_first(self):
        def prepare_block(state):
            # 对应 Gate 1：只有 PREPARED 才创建句柄。
            if state != "PREPARED":
                return "aborted"
            return "handle-created"

        self.assertEqual(prepare_block("PREPARED"), "handle-created")
        self.assertEqual(prepare_block("DESTROYING"), "aborted")
        self.assertEqual(prepare_block("DESTROYED"), "aborted")

    def test_control_commands_execute_fifo_after_prepare(self):
        queue = collections.deque()
        executed = []
        queue.append(("prepare-tail", lambda: executed.append("prepare-tail")))
        queue.append(("setRate", lambda: executed.append("setRate")))
        queue.append(("pause", lambda: executed.append("pause")))
        while queue:
            _, fn = queue.popleft()
            fn()
        self.assertEqual(executed, ["prepare-tail", "setRate", "pause"])


if __name__ == "__main__":
    unittest.main()
