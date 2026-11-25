"""Contract: AVPlayer 失败/首帧超时必须能回退到 MPV 路由。

路由表（MediaPlaybackDecodeRouter.m）声明的点播有序回退链为：
    AVPlayer → MPV → Cicada → WebView
（见 candidates[] = { AVPlayer, MPV, Cicada, WebView } 与注释
 "Ordered VOD fallback: AVPlayer → MPV → Cicada → WebView."）

当 MPV 内核可用（CCTVMPVCore 已打包、cctv.mediaDecodeMPVEnabled.v1 未关闭、
未编译 CCTV_DISABLE_MPV）时，AVPlayer 取首帧未果 / AVPlayer 项出错后，
MediaPlaybackDecodeRouteNextForResult 返回的下一路应为 MPV（尚未尝试）。
此时 MediaPlaybackViewController 必须像 Cicada 回退那样调用
startCicadaPlaybackWithResult:（其内部据 attemptedRoutes 自动选用 MPV 适配器），
否则会把 MPV 这一路直接跳过，违背声明链。

本测试为静态源码契约（与 test_media_playback_route_fallback.py 同款）：
不做网络 / 真机 / CI 操作。
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources" / "MediaPlaybackViewController.m").read_text(encoding="utf-8")


def method_body(signature):
    start = SOURCE.rindex(signature)
    opening = SOURCE.index("{", start)
    depth = 0
    for index in range(opening, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class AVPlayerToMPVFallbackContracts(unittest.TestCase):
    def _block_before_next_route_branch(self, body, probe_call):
        """Return the source slice around the nextRoute guard that leads to
        startCicadaPlaybackWithResult. We look for the probe call and capture a
        generous window so the guard comparison can be inspected."""
        idx = body.index(probe_call)
        # Capture from the probe call up to the startCicadaPlaybackWithResult
        # invocation that follows it (the fallback hand-off).
        handoff = body.index("startCicadaPlaybackWithResult", idx)
        return body[idx:handoff]

    def test_item_failure_falls_back_to_mpv_or_cicada(self):
        body = method_body(
            "- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage"
        )
        window = self._block_before_next_route_branch(
            body, "nextRouteForResult:self.result"
        )
        # The guard feeding startCicadaPlaybackWithResult must accept the MPV
        # route, not only Cicada. Otherwise AVPlayer→MPV leg is skipped.
        self.assertIn("MediaPlaybackDecodeRouteMPV", window)
        self.assertIn("MediaPlaybackDecodeRouteCicadaPlayer", window)
        # The branch must hand off to the Cicada-family starter (which selects
        # MPV internally when the MPV bit is unset).
        self.assertIn("startCicadaPlaybackWithResult:self.result", body)

    def test_first_frame_timeout_falls_back_to_mpv_or_cicada(self):
        body = method_body(
            "- (void)watchAVPlayerFirstFrameForItem:(AVPlayerItem *)item "
            "generation:(NSUInteger)playerGeneration url:(NSURL *)url "
            "sourceURL:(NSURL *)sourceURL"
        )
        window = self._block_before_next_route_branch(
            body, "peekNextRouteForResult:owner.result"
        )
        self.assertIn("MediaPlaybackDecodeRouteMPV", window)
        self.assertIn("MediaPlaybackDecodeRouteCicadaPlayer", window)
        self.assertIn("startCicadaPlaybackWithResult:owner.result", body)

    def test_cicada_failure_already_covers_mpv_route(self):
        # Regression guard: advanceFromCicadaFailureWithError: is the reference
        # implementation and must remain covering both MPV and Cicada.
        body = method_body(
            "- (void)advanceFromCicadaFailureWithError:(NSError *)error"
        )
        self.assertIn(
            "nextRoute==MediaPlaybackDecodeRouteMPV||nextRoute==MediaPlaybackDecodeRouteCicadaPlayer",
            body,
        )

    def test_router_orders_mpv_before_cicada(self):
        # Cognitive anchor for the contract: the ordered chain must keep MPV
        # ahead of Cicada so the AVPlayer leg can reach MPV at all.
        router = (ROOT / "Sources" / "MediaPlaybackDecodeRouter.m").read_text(
            encoding="utf-8"
        )
        idx_av = router.index("MediaPlaybackDecodeRouteAVPlayer, MediaPlaybackDecodeRouteMPV")
        self.assertLess(
            router.index("MediaPlaybackDecodeRouteCicadaPlayer", idx_av),
            router.index("MediaPlaybackDecodeRouteWebView", idx_av),
        )


if __name__ == "__main__":
    unittest.main()
