"""logfix 2026-11-26：1.76 实测日志五项修复的契约测试。

F1 /health 探针带 token；F2 过期 shelf 缓存先渲染；F3 JS play 桥超时对齐；
F4 直播 -12909 自动换线；F5 点播解析失败自动换线（已自动，只锁定）；
F6 详情 id 原样透传（蜘蛛侧契约问题，只锁定 App 侧行为）。

行为模型（Python 小模型）+ 源码契约断言：模型定行为，断言把模型钉在
ObjC/Python 实现上。本机跑不了的原生部分不伪造结果，只做契约锁定。
"""

import importlib.util
import json
import os
import pathlib
import re
import sys
import threading
import unittest
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
PLUGINS = ROOT / "Plugins"
sys.path.insert(0, str(PLUGINS))


def _read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


def _load_media_service():
    spec = importlib.util.spec_from_file_location(
        "media_service_logfix", PLUGINS / "media-service.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _StubRuntime:
    """media-service /health 只需要 health_status 与 stopping。"""

    def __init__(self):
        self.stopping = threading.Event()

    def health_status(self):
        return {"runtime_ready": True, "runtime_state": "ready"}


def _get(port, path, token=None):
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path))
    if token is not None:
        request.add_header("X-CCTVHost-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class LogfixF1HealthProbeTokenTests(unittest.TestCase):
    # F1：/health 门禁是真的，探针必须带与 MediaAPIClient 相同的 token。

    def test_health_gate_live(self):
        module = _load_media_service()
        previous = os.environ.get("CCTVHOST_CONTROL_TOKEN")
        os.environ["CCTVHOST_CONTROL_TOKEN"] = "logfix-test-token"
        server = module.Server(("127.0.0.1", 0), _StubRuntime())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            # 无 token：403，且正文恰好是日志里的 35 字节。
            status, body = _get(port, "/health")
            self.assertEqual(status, 403)
            self.assertEqual(body, b'{"ok": false, "error": "forbidden"}')
            self.assertEqual(len(body), 35)
            # 错 token：同样 403。
            status, _ = _get(port, "/health", "wrong-token")
            self.assertEqual(status, 403)
            # 对 token：200，ok/media/runtime_ready 全真。
            status, body = _get(port, "/health", "logfix-test-token")
            self.assertEqual(status, 200)
            payload = json.loads(body)
            self.assertTrue(payload["ok"])
            self.assertTrue(payload["media"])
            self.assertTrue(payload["runtime_ready"])
            # 根路径同样受门禁。
            status, _ = _get(port, "/")
            self.assertEqual(status, 403)
        finally:
            server.shutdown()
            server.server_close()
            if previous is None:
                os.environ.pop("CCTVHOST_CONTROL_TOKEN", None)
            else:
                os.environ["CCTVHOST_CONTROL_TOKEN"] = previous

    def test_health_gate_disabled_without_configured_token(self):
        module = _load_media_service()
        previous = os.environ.get("CCTVHOST_CONTROL_TOKEN")
        os.environ.pop("CCTVHOST_CONTROL_TOKEN", None)
        server = module.Server(("127.0.0.1", 0), _StubRuntime())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            status, body = _get(server.server_address[1], "/health")
            self.assertEqual(status, 200)
            self.assertTrue(json.loads(body)["ok"])
        finally:
            server.shutdown()
            server.server_close()
            if previous is not None:
                os.environ["CCTVHOST_CONTROL_TOKEN"] = previous

    def test_readiness_probe_sends_control_token(self):
        readiness = _read("LocalServiceReadiness.m")
        self.assertIn('#import "PyHost.h"', readiness)
        self.assertIn(
            '[request setValue:PyHostControlToken() forHTTPHeaderField:@"X-CCTVHost-Token"];',
            readiness)
        # 与 MediaAPIClient 用同一个 token、同一个 header 名。
        self.assertIn("PyHostControlToken()", _read("MediaAPIClient.m"))
        self.assertIn('"X-CCTVHost-Token"', _read("MediaAPIClient.m"))
        self.assertIn(
            "FOUNDATION_EXPORT NSString *PyHostControlToken(void);",
            _read("PyHost.h"))
        # 403 仍判失败（http_status），不是静默通过；就绪判定没有放宽。
        self.assertIn('self.lastFailureKind=@"http_status"', readiness)
        self.assertIn("requiresHealthJSON", readiness)
        # 探针请求在创建后、发出前就带上 token（顺序断言）。
        self.assertLess(
            readiness.index("PyHostControlToken()"),
            readiness.index("dataTaskWithRequest:request"))


class ShelfLoad:
    """loadHomeShelves 缓存决策的镜像（MBVC.m）。

    fresh（<=5 分钟）跳过网络；stale 有缓存条目时先渲染缓存再后台刷新；
    stale 无条目或未命中直接发请求；失败 60 秒内退避。
    """

    FRESH_SECONDS = 5 * 60
    BACKOFF_SECONDS = 60.0

    def __init__(self, now=1000.0):
        self.now = now
        self.failed_at = {}

    @staticmethod
    def age_state(age_seconds):
        if age_seconds < 0:
            return -1
        if age_seconds < 5 * 60:
            return 0
        if age_seconds <= 6 * 3600:
            return 1
        return 2

    def decide(self, category_id, cached, stale, cached_count):
        failed_at = self.failed_at.get(category_id)
        if failed_at is not None and self.now - failed_at < self.BACKOFF_SECONDS:
            return ["backoff"]
        if cached and not stale:
            return ["skip_network"]
        actions = []
        if cached and stale and cached_count > 0:
            actions.append("render_cached_first")
        actions.append("request_network")
        return actions

    def complete(self, category_id, ok):
        if not ok:
            self.failed_at[category_id] = self.now
            return "backoff_recorded"
        return "render_fresh"


class LogfixF2StaleShelfTests(unittest.TestCase):
    # F2：过期缓存先渲染、后台刷新后替换；fresh 仍跳过网络；失败仍 60 秒退避。

    def test_fresh_cache_skips_network(self):
        self.assertEqual(
            ShelfLoad().decide("c1", cached=True, stale=False, cached_count=24),
            ["skip_network"])

    def test_stale_cache_renders_first_then_refreshes(self):
        self.assertEqual(
            ShelfLoad().decide("c1", cached=True, stale=True, cached_count=24),
            ["render_cached_first", "request_network"])

    def test_stale_cache_without_items_requests_only(self):
        self.assertEqual(
            ShelfLoad().decide("c1", cached=True, stale=True, cached_count=0),
            ["request_network"])

    def test_cache_miss_requests(self):
        self.assertEqual(
            ShelfLoad().decide("c1", cached=False, stale=False, cached_count=0),
            ["request_network"])

    def test_failure_backs_off_for_60_seconds_then_retries(self):
        shelves = ShelfLoad(now=1000.0)
        self.assertEqual(shelves.complete("c1", ok=False), "backoff_recorded")
        self.assertEqual(
            shelves.decide("c1", cached=False, stale=False, cached_count=0),
            ["backoff"])
        shelves.now += 59.0
        self.assertEqual(
            shelves.decide("c1", cached=False, stale=False, cached_count=0),
            ["backoff"])
        shelves.now += 2.0
        self.assertEqual(
            shelves.decide("c1", cached=False, stale=False, cached_count=0),
            ["request_network"])

    def test_age_state_matches_cache_age_helper(self):
        self.assertEqual(ShelfLoad.age_state(60), 0)
        self.assertEqual(ShelfLoad.age_state(5 * 60 + 1), 1)
        self.assertEqual(ShelfLoad.age_state(6 * 3600), 1)
        self.assertEqual(ShelfLoad.age_state(6 * 3600 + 1), 2)

    def test_stale_first_render_is_wired_before_the_network_request(self):
        browser = _read("MediaBrowserViewController.m")
        start = browser.index(
            "- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories")
        end = browser.index("- (void)updateHomeStatusCard", start)
        body = browser[start:end]
        # fresh 仍跳过网络。
        self.assertIn(
            "if(cached&&!stale&&!self.forceVisibleShelfRefresh)", body)
        # stale 有缓存：先刷新（sections 从 DBL_MAX 缓存读数），再发请求。
        self.assertIn("if(cached&&stale&&cachedCount>0)[self refreshHomeModules];", body)
        self.assertLess(
            body.index("if(cached&&stale&&cachedCount>0)[self refreshHomeModules];"),
            body.index('[shelfClient call:@"category"'))
        # 刷新回来仍刷新一次替换为新数据。
        self.assertIn("if(owner.isHomePageVisible)[owner refreshHomeModules];", body)
        # 不动的参数：6 小时 maximumAge、并发上限 3、60 秒失败退避。
        self.assertIn("maximumAge:6*3600", body)
        self.assertIn("self.homeCategoryLoadsInFlight.count>=3", body)
        self.assertIn("CACurrentMediaTime()-shelfFailedAt.doubleValue<60.0", body)

    def test_shelf_age_title_uses_t15_age_helpers(self):
        browser = _read("MediaBrowserViewController.m")
        start = browser.index("- (NSArray<NSDictionary *> *)mediaFeedSections")
        end = browser.index("- (CGFloat)stableTopSafeAreaInset", start)
        body = browser[start:end]
        self.assertIn(
            'ageOfResultForSource:self.source operation:@"category"', body)
        self.assertIn("MediaBrowserCacheAgeState(shelfAge)>=1", body)
        self.assertIn("MediaBrowserCacheAgeText(shelfAge)", body)
        self.assertIn('@" · 正在刷新"', body)
        # 架标题只在有缓存条目且过期时才带年龄；新鲜缓存标题不变。
        self.assertIn("if(items.count&&MediaBrowserCacheAgeState(shelfAge)>=1)", body)


class LogfixF3BridgeTimeoutTests(unittest.TestCase):
    # F3：JS play 桥超时 12 秒 < HTTP play 超时 15 秒，失败从桥侧先返回。

    def test_play_bridge_timeout_below_http_play_timeout(self):
        pyhost = _read("PyHost.m")
        match = re.search(
            r'isEqualToString:@"play"\]\?(\d+):(\d+)', pyhost)
        self.assertIsNotNone(match, "play 桥超时未按操作区分")
        play_bridge_seconds = int(match.group(1))
        other_bridge_seconds = int(match.group(2))
        api = _read("MediaAPIClient.m")
        http_match = re.search(r"_playTimeoutMilliseconds=(\d+);", api)
        self.assertIsNotNone(http_match, "HTTP play 超时默认值未找到")
        http_play_seconds = int(http_match.group(1)) / 1000.0
        self.assertEqual(other_bridge_seconds, 40)
        self.assertLess(play_bridge_seconds, http_play_seconds)
        self.assertEqual(play_bridge_seconds, 12)
        self.assertEqual(http_play_seconds, 15)
        # 桥调用确实用这个区分后的超时；HTTP 层 play 请求仍用 15 秒。
        self.assertIn(
            "callOperation:operationName json:requestJSON timeout:bridgeTimeout",
            pyhost)
        self.assertNotIn("timeout:40 error:&error", pyhost)
        self.assertIn("playTimeoutMilliseconds/1000", api)

    def test_bridge_timeout_path_resets_unresponsive_session(self):
        runtime = _read("JSPluginRuntime.m")
        # 信号量超时：先标 unresponsive，再把复位排在串行队列尾。
        self.assertIn("self.unresponsive=YES;", runtime)
        self.assertIn("dispatch_async(self.queue,^{", runtime)
        # 复位：清掉待复位标记、取消在途 fetch、恢复 unresponsive。
        self.assertIn('[self fetchFinished:reqKey error:@"AbortError"]', runtime)
        self.assertIn("self.unresponsive=NO;", runtime)
        # 超时返回 code 2（JS 插件调用超时），调用方能区分。
        self.assertIn('code:2', runtime)


class LiveRouteRecovery:
    """playbackFailed -12909 分支的镜像（RootViewController+Playback.m）。

    每条自选线路各有一次恢复机会：失败即切下一条；线路耗尽回 SDK 自动；
    SDK 自动失败走 retryCount 分支（最多 2 次），耗尽才显示失败。
    同一次失败的重复回调在 nativePlaybackFailed 置位后被抑制。
    """

    def __init__(self, routes):
        self.routes = list(routes)
        self.current = 0
        self.recovery_used = [False] * len(routes)
        self.failed = False

    def on_12909(self):
        if self.failed:
            return "suppressed_duplicate_callback"
        self.failed = True
        if self.current >= len(self.routes):
            return "retry_sdk_auto"
        if self.recovery_used[self.current]:
            return "retry_sdk_auto"
        self.recovery_used[self.current] = True
        if self.current + 1 < len(self.routes):
            self.current += 1
            return ("switch_route", self.routes[self.current])
        self.current = len(self.routes)
        return ("sdk_auto", None)

    def on_new_attempt(self):
        # playChannel:route: 为新线路复位恢复标记与重试计数。
        self.failed = False


class LogfixF4Live12909Tests(unittest.TestCase):
    # F4：-12909 首次失败自动切下一条线；切完仍失败才显示失败；风暴仍被抑制。

    def test_three_self_selected_routes_fall_through_to_sdk_auto(self):
        live = LiveRouteRecovery(["WS", "BD", "KS"])
        self.assertEqual(live.on_12909(), ("switch_route", "BD"))
        live.on_new_attempt()
        self.assertEqual(live.on_12909(), ("switch_route", "KS"))
        live.on_new_attempt()
        self.assertEqual(live.on_12909(), ("sdk_auto", None))

    def test_duplicate_callback_for_the_same_failure_is_suppressed(self):
        live = LiveRouteRecovery(["WS", "BD"])
        self.assertEqual(live.on_12909(), ("switch_route", "BD"))
        self.assertEqual(live.on_12909(), "suppressed_duplicate_callback")

    def test_12909_branch_auto_advances_and_shows_failure_only_when_exhausted(self):
        playback = _read("RootViewController+Playback.m")
        failed_start = playback.index(
            "- (void)player:(id)player playbackFailed:(NSError *)error {")
        failed_end = playback.index(
            "- (void)retryPlaybackWithAlternateSource", failed_start)
        failed_body = playback[failed_start:failed_end]
        branch_start = failed_body.index("error.code == -12909")
        branch_end = failed_body.index(
            'if (error.code >= 4000 && error.code < 5000)', branch_start)
        branch = failed_body[branch_start:branch_end]
        # 一次恢复机会占位，之后自动切下一条线，不再原地显示失败。
        self.assertIn("self.nativeStartupRecoveryUsed=YES;", branch)
        self.assertIn("[self retryPlaybackWithAlternateSource];", branch)
        self.assertNotIn("displayNativePlaybackFailure", branch)
        # 条件本身不动：仅自选 SDK 线路、仅 -12909、仅未用过恢复机会。
        self.assertIn("CCTVRouteRequiresSDK(self.requestedNativeRoute)", failed_body)
        self.assertIn("error.code == -12909", failed_body)
        self.assertIn("!self.nativeStartupRecoveryUsed", failed_body)

    def test_12909_storm_suppression_expectations_preserved(self):
        # 与 test_round18 §1 同样的期望：本文件独立锁定，防止回归。
        playback = _read("RootViewController+Playback.m")
        failed_start = playback.index(
            "- (void)player:(id)player playbackFailed:(NSError *)error {")
        failed_end = playback.index(
            "- (void)retryPlaybackWithAlternateSource", failed_start)
        failed_body = playback[failed_start:failed_end]
        self.assertIn("if(self.nativePlaybackFailed)return;", failed_body)
        self.assertIn("self.nativeSessionDelegate=nil;self.nativeSessionID++;", failed_body)
        self.assertIn(
            'if(player!=self.avPlayer)[self call:player sel:@"stop"];', failed_body)
        self.assertIn("error.code == -12909", failed_body)
        self.assertNotIn(
            "[self.nativeCDNPreference applyRoute:self.requestedNativeRoute error:NULL];",
            failed_body)

    def test_alternate_source_cycles_routes_then_falls_back_to_sdk_auto(self):
        playback = _read("RootViewController+Playback.m")
        start = playback.index("- (void)retryPlaybackWithAlternateSource {")
        end = playback.index(
            "- (void)displayNativePlaybackFailure:(NSString *)stage", start)
        body = playback[start:end]
        self.assertIn("routes[current+1]:nil", body)
        self.assertIn("[self playChannel:channel route:next];", body)

    def test_new_route_resets_recovery_flag_and_retry_count(self):
        playback = _read("RootViewController+Playback.m")
        start = playback.index("- (void)playChannel:(NSDictionary *)ch route:")
        end = playback.index("- (void)playViaSDKURL:", start)
        body = playback[start:end]
        self.assertIn("self.nativeStartupRecoveryUsed = NO;", body)
        self.assertIn("self.retryCount = 0;", body)


class VodLineFallback:
    """tryNextLineForAutomaticFallback 的镜像（MediaPlaybackViewController.m）。

    解析失败先试同线 alternates（略），再按顺序切下一条未试过的线，
    按 id/名/集号匹配同集；上限 CCTVAutomaticRouteFallbackLimit=16。
    """

    LIMIT = 16

    def __init__(self, lines):
        # lines: 每条线的分集 id 列表；同集在不同线用相同 id。
        self.lines = [list(line) for line in lines]
        self.line_index = 0
        self.episode_index = 0
        self.tried = set()

    def on_resolve_failed(self):
        if len(self.lines) < 2:
            return False
        if len(self.tried) >= min(len(self.lines), self.LIMIT):
            return False
        episode_id = self.lines[self.line_index][self.episode_index]
        for offset in range(1, len(self.lines)):
            candidate = (self.line_index + offset) % len(self.lines)
            if candidate in self.tried:
                continue
            self.tried.add(self.line_index)
            self.tried.add(candidate)
            if episode_id in self.lines[candidate]:
                self.line_index = candidate
                self.episode_index = self.lines[candidate].index(episode_id)
                return True
            self.tried.add(candidate)
        return False


class LogfixF5VodResolveFallbackTests(unittest.TestCase):
    # F5：点播解析失败本来就自动换线——本节只锁定，不改代码。

    def test_resolve_failure_advances_to_next_line(self):
        vod = VodLineFallback([["e1", "e2"], ["e1", "e2"], ["e1"]])
        self.assertTrue(vod.on_resolve_failed())
        self.assertEqual(vod.line_index, 1)
        self.assertTrue(vod.on_resolve_failed())
        self.assertEqual(vod.line_index, 2)

    def test_single_line_has_nowhere_to_fall_back(self):
        vod = VodLineFallback([["e1", "e2"]])
        self.assertFalse(vod.on_resolve_failed())

    def test_empty_play_result_is_rejected_with_no_media(self):
        from host_media_runtime import MediaError, playback
        # 证据原文：parse=1 且无任何可用地址 -> NO_MEDIA。
        with self.assertRaises(MediaError) as caught:
            playback({"parse": 1, "jx": 0, "url": ""})
        self.assertEqual(caught.exception.code, "NO_MEDIA")
        self.assertIn("来源未返回有效 HTTP/HTTPS 媒体地址", str(caught.exception))
        # parse=0 的 m3u8 正常通过；parse=1 带页面地址则透传，由 App 侧拒收。
        result = playback({"parse": 0, "jx": 0, "url": "https://example.com/x.m3u8"})
        self.assertEqual(result["url"], "https://example.com/x.m3u8")
        result = playback(
            {"parse": 1, "jx": 0, "url": "https://example.com/play?id=1"})
        self.assertEqual(result["parse"], 1)

    def test_resolve_failure_calls_automatic_line_fallback(self):
        player = _read("MediaPlaybackViewController.m")
        # 失败先记 episode_resolve_failed（含错误域/码/文案与失败阶段），
        # 紧接着自动换线；两者相邻，不经过手动选线。
        self.assertIn(
            '[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed"'
            ' category:@"media_api" fields:fields];\n'
            '            if([owner tryNextLineForAutomaticFallback:@"episode_resolve_failed"])return;',
            player)
        self.assertIn('@"error_domain":error.domain', player)
        self.assertIn('@"error_code":@(error.code)', player)
        self.assertIn('@"error_message":error.localizedDescription', player)
        self.assertIn('@"service_failure_stage"', player)

    def test_automatic_fallback_advances_line_and_re_resolves(self):
        player = _read("MediaPlaybackViewController.m")
        self.assertIn(
            "static NSUInteger const CCTVAutomaticRouteFallbackLimit = 16;", player)
        start = player.index(
            "- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason {")
        end = player.index("- (void)resolveAndPlay {", start)
        body = player[start:end]
        self.assertIn("NSUInteger limit=MIN(lineCount,CCTVAutomaticRouteFallbackLimit);", body)
        self.assertIn("self.lineIndex=(NSInteger)candidateLine;", body)
        self.assertIn('[self resolveAndPlay];return YES;', body)
        self.assertIn('@"playback_auto_line_fallback"', body)
        # parse=1 网页播放仍被拒：无直链的播放结果记 direct_url_missing。
        self.assertIn('@"direct_url_missing"', _read("MediaAPIClient.m"))


class LogfixF6DetailIdPassthroughTests(unittest.TestCase):
    # F6：App 侧把条目 id 原样传给 detail（蜘蛛侧只认链接形 id 是蜘蛛契约问题）。

    def test_detail_request_passes_item_id_verbatim(self):
        browser = _read("MediaBrowserViewController.m")
        self.assertIn(
            'NSString *requestedItemID=([self.item[@"id"] isKindOfClass:NSString.class]',
            browser)
        self.assertIn('NSMutableDictionary *args=[@{@"id":requestedItemID} mutableCopy];',
                      browser)


if __name__ == "__main__":
    unittest.main()
