"""A 阶段审计契约：点播回退总预算 / 重复尝试 / 线路切换。

审计对象：MediaPlaybackDecodeRouter + MediaPlaybackViewController 的有序回退链
    AVPlayer → MPV → Cicada → WebView
不变量（本测试钉死）：
  1. 每条路由在同一条源 URL 内最多尝试一次——attemptedRoutes 位掩码在引擎
     启动点置位，且 AdvanceCicada/WatchAVPlayer 等“链内”方法不得把
     attemptedRoutes 清零（清零只发生在 URL/线路/分集切换等边界）。
  2. 总超时有界——每条路由都有有限首帧看门狗，线路切换 ≤16、清晰度切换 ≤5，
     因此整条回退链存在有限上界。
  3. Cicada 专属格式（FLV/DASH/MKV/WebM/RTMP）不得先试 AVPlayer：
     MediaPlaybackResultSupportsAVPlayer 对这些格式返回 NO，路由表必须据此跳过
     AVPlayer 候选，避免在一个注定失败的路由上浪费整整一档启动看门狗预算，
     并契合头文件声明的“Cicada 专属格式 → [Cicada,WebView]”优先级。

静态源码契约（与 test_media_playback_route_fallback.py 同款）：不做网络 / 真机 / CI。
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VC = (ROOT / "Sources" / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
ROUTER = (ROOT / "Sources" / "MediaPlaybackDecodeRouter.m").read_text(encoding="utf-8")
CICADA = (ROOT / "Sources" / "MediaPlaybackCicadaAdapter.m").read_text(encoding="utf-8")
MPV = (ROOT / "Sources" / "MediaPlaybackMPVAdapter.m").read_text(encoding="utf-8")


def method_body(source, signature):
    start = source.rindex(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


def router_body():
    return method_body(
        ROUTER,
        "MediaPlaybackDecodeRoute MediaPlaybackDecodeRouteNextForResult",
    )


class RouteOnceBitmaskContracts(unittest.TestCase):
    """每条路由只尝试一次：启动即置位，链内不清零。"""

    def test_router_skips_attempted_bits(self):
        body = router_body()
        self.assertIn("(attemptedRoutes & bit) == 0) return route", body)
        self.assertIn("return MediaPlaybackDecodeRouteNone", body)

    def test_avplayer_start_marks_its_bit(self):
        body = method_body(VC, "- (void)playResult:(NSDictionary *)result")
        self.assertIn(
            "self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedAVPlayer", body
        )

    def test_cicada_family_start_marks_mpv_or_cicada_bit(self):
        body = method_body(VC, "- (void)startCicadaPlaybackWithResult:")
        self.assertIn(
            "self.attemptedRoutes|=(useMPV?MediaPlaybackDecodeRouteAttemptedMPV"
            ":MediaPlaybackDecodeRouteAttemptedCicadaPlayer)",
            body,
        )

    def test_webview_start_marks_its_bit(self):
        body = method_body(VC, "- (void)openWebPlaybackFallback")
        self.assertIn(
            "self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedWebView", body
        )

    def test_advance_from_cicada_is_idempotent(self):
        # 重复错误回调不得二次推进路由（防回退循环）。
        body = method_body(VC, "- (void)advanceFromCicadaFailureWithError:")
        self.assertIn("if(!adapter)return", body)

    def test_software_decode_retry_is_one_shot(self):
        # Cicada 软解码重建是同一路由的唯一一次就地重试：由
        # cicadaAdapterSoftwareDecodeFallbackAttempted 单次闸门控制。
        body = method_body(VC, "- (void)advanceFromCicadaFailureWithError:")
        self.assertIn(
            "!self.cicadaAdapterSoftwareDecodeFallbackAttempted&&decoderFailure",
            body,
        )
        self.assertIn(
            "self.cicadaAdapterSoftwareDecodeFallbackAttempted=YES", body
        )

    def test_in_chain_methods_never_reset_attempted_routes(self):
        # 链内方法清零 attemptedRoutes 会导致同一路由被重复尝试。
        for signature in (
            "- (void)advanceFromCicadaFailureWithError:",
            "- (void)startCicadaPlaybackWithResult:",
            "- (void)watchAVPlayerFirstFrameForItem:",
            "- (void)recordPlaybackFailureForItem:",
            "- (void)openWebPlaybackFallback",
        ):
            body = method_body(VC, signature)
            self.assertNotIn(
                "self.attemptedRoutes=0",
                body,
                f"{signature} 在链内清零 attemptedRoutes，会破坏“每条只尝试一次”不变量",
            )


class BoundedTotalBudgetContracts(unittest.TestCase):
    """总超时有界：每条路由有限看门狗 + 线路/清晰度切换计数有上限。"""

    def test_avplayer_first_frame_watchdog_is_bounded(self):
        body = method_body(VC, "- (void)watchAVPlayerFirstFrameForItem:")
        self.assertIn('@"cenc"]?45:20', body)
        # 三档快失败均在主超时之下，主超时即该路由的有限上界。
        self.assertIn("tier1DeadLink", body)
        self.assertIn("tier2AudioOnlyVideoStuck", body)
        self.assertIn("avFirstFrameActiveWait<timeout", body)

    def test_mpv_first_frame_timeout_is_fixed_finite(self):
        self.assertIn("MediaPlaybackMPVFirstFrameTimeout = 20.0", MPV)
        self.assertIn(
            "return MediaPlaybackMPVFirstFrameTimeout",
            method_body(MPV, "- (NSTimeInterval)firstFrameTimeout"),
        )
        # 非重复定时器：到期即报错推进路由。
        self.assertIn("scheduledTimerWithTimeInterval:MediaPlaybackMPVFirstFrameTimeout", MPV)

    def test_cicada_first_frame_timeout_is_bounded_formula(self):
        self.assertIn("MediaPlaybackCicadaFirstFrameTimeout = 20.0", CICADA)
        body = method_body(CICADA, "- (NSTimeInterval)firstFrameTimeout")
        self.assertIn("return MAX(MediaPlaybackCicadaFirstFrameTimeout, self.networkTimeout + 10.0)", body)
        # networkTimeout 被夹在 [5,40] 秒，故 firstFrameTimeout ≤ 50s。
        init = method_body(CICADA, "- (instancetype)initWithURL:")
        self.assertIn("MIN(40, MAX(5,", init)
        # 首帧看门狗为非重复定时器，到期触发 reportErrorWithCode:-1001 推进路由。
        self.assertIn("repeats:NO block:^(NSTimer *timer)", CICADA)
        self.assertIn("reportErrorWithCode:-1001", CICADA)

    def test_webview_sniff_has_finite_deadline(self):
        sniff = method_body(VC, "- (void)sniffNativeStreamFromPageResult:")
        # 轻量 HTTP 抓取超时。
        self.assertIn("timeoutInterval:3.5", sniff)
        # 隐藏 WKWebView 嗅探的硬截止（到期 teardown + 失败收尾）。
        self.assertIn("3.2*NSEC_PER_SEC", sniff)
        # 嗅探失败必走线路回退或终态上报，不得悬挂。
        fail = method_body(VC, "- (void)finishNativeStreamSniffFailureForGeneration:")
        self.assertIn("tryNextLineForAutomaticFallback:", fail)
        self.assertIn("setRetryAvailable:YES", fail)

    def test_line_switch_is_capped(self):
        self.assertIn("CCTVAutomaticRouteFallbackLimit = 16", VC)
        body = method_body(VC, "- (BOOL)tryNextLineForAutomaticFallback:")
        self.assertIn("MIN(lineCount,CCTVAutomaticRouteFallbackLimit)", body)
        self.assertIn("containsIndex:candidateLine", body)

    def test_alternate_switch_is_capped(self):
        body = method_body(VC, "- (BOOL)tryNextAlternateForAutomaticFallback:")
        self.assertIn("MIN(alternates.count,(NSUInteger)5)", body)

    def test_parser_pages_skip_native_probe(self):
        # 解析页/播放页是文档，直接走 WebView，不计入原生探测预算。
        body = router_body()
        self.assertIn("if (requiresWebPlayback) {", body)
        self.assertIn("MediaPlaybackDecodeRouteWebView", body)


class CicadaOnlyFormatSkipsAVPlayerContracts(unittest.TestCase):
    """修复契约：Cicada 专属格式不得先试 AVPlayer。"""

    def test_avsupported_flag_is_computed(self):
        body = router_body()
        self.assertIn(
            "BOOL avSupported = MediaPlaybackResultSupportsAVPlayer(result)", body
        )

    def test_candidate_loop_skips_avplayer_when_unsupported(self):
        body = router_body()
        self.assertIn(
            "if (route == MediaPlaybackDecodeRouteAVPlayer && !avSupported) continue",
            body,
        )

    def test_ordered_candidate_chain_unchanged(self):
        # 顺序仍为 AVPlayer → MPV → Cicada → WebView（仅按能力跳过，不改顺序）。
        body = router_body()
        self.assertIn(
            "{ MediaPlaybackDecodeRouteAVPlayer, MediaPlaybackDecodeRouteMPV, "
            "MediaPlaybackDecodeRouteCicadaPlayer, MediaPlaybackDecodeRouteWebView }",
            body,
        )

    def test_mpv_skip_and_attempted_skip_remain(self):
        body = router_body()
        self.assertIn(
            "route == MediaPlaybackDecodeRouteMPV && !MediaPlaybackMPVRouteEnabled()",
            body,
        )


if __name__ == "__main__":
    unittest.main()
