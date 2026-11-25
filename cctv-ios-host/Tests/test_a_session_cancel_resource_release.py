#!/usr/bin/env python3
"""Stage A — session cancel & resource release contract tests.

These are source-level contracts (no macOS/iOS toolchain required) that verify
the three definite cancellation bugs fixed in this stage. Each fix ensures that
on 快速换片/换线路/取消解析 (fast episode switch / line switch / cancel parsing)
the four resource classes — resolution generation, hedged backup request,
player, and in-flight request tasks (client / prefetch / stream sniffer) — are
all invalidated before a new selection can drive playback.

The tests read MediaPlaybackViewController.m and assert the guards exist in the
relevant method bodies.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def _method_body(source, signature):
    """Extract the body of an Objective-C method from source text."""
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
    raise AssertionError(f"unterminated method: {signature}")


class SessionCancelResourceReleaseContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mpvc = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")

    # ── Fix 1: selectLine no-exact-match branch must invalidate resolution ──

    def test_select_line_no_match_invalidates_generation_and_client(self):
        """When switching to a line whose episodes cannot be matched, the
        in-flight `client` resolution (if any) must be cancelled and the
        resolution generation bumped, otherwise the stale completion — still
        carrying the old generation — would call playResult: and start playback
        of the previous line's episode under the "请点选集重新选择" state.

        The no-match branch already tears down the player (clearCurrentPlayerItem)
        and cancels hedged/prefetch (resetAutomaticFallbackLines); this test
        pins the previously-missing generation+client invalidation."""
        body = _method_body(self.mpvc, "- (void)selectLine:(UIButton *)sender ")
        # Locate the no-exact-match early-return block.
        self.assertIn("if(!exactMatch){", body)
        nomatch = body[body.index("if(!exactMatch){"):]
        nomatch = nomatch[:nomatch.index("return;")]
        # generation must be bumped inside the no-match branch.
        self.assertIn("self.generation++", nomatch,
                      "selectLine no-match branch must bump resolution generation")
        # the client request task must be cancelled inside the no-match branch.
        self.assertIn("[self.client cancel]", nomatch,
                      "selectLine no-match branch must cancel the in-flight client request")
        # resolving flag must be cleared so the spinner/status reflect cancellation.
        self.assertRegex(nomatch, r"if\(self\.resolving\)\{self\.resolving=NO;\}")

    # ── Fix 2: tryNextLineForAutomaticFallback must cancel the stale hedge ──

    def test_try_next_line_cancels_stale_hedged_before_resolve(self):
        """Automatic line fallback changes lineIndex, so the previous line's
        hedged backup resolution is stale. Before calling resolveAndPlay the
        hedge request must be cancelled and its state cleared; otherwise the
        old hedgedClient keeps consuming network bandwidth until the next
        resetAutomaticFallbackLines (which never runs on the fallback path
        because it would erase the accumulated tried-line set)."""
        body = _method_body(self.mpvc, "- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason ")
        # The fallback calls resolveAndPlay; the hedge cancel must precede it.
        resolve_idx = body.index("[self resolveAndPlay]")
        before_resolve = body[:resolve_idx]
        self.assertIn("[self.hedgedClient cancel]", before_resolve,
                      "tryNextLineForAutomaticFallback must cancel hedgedClient before resolveAndPlay")
        self.assertIn("self.hedgedClient=nil", before_resolve,
                      "hedgedClient handle must be cleared on line fallback")
        # The stale cached hedge result must also be cleared so it cannot be
        # promoted by a later resolveAndPlay for a different line.
        self.assertIn("self.hedgedEpisodeResult=nil", before_resolve)
        self.assertIn("self.hedgedLineIndex=-1", before_resolve)
        self.assertIn("self.hedgedEpisodeIndex=-1", before_resolve)

    # ── Fix 3: openEpisodeSelection (cancel-parsing) must cancel stream sniffer ──

    def test_open_episode_selection_cancels_stream_sniffer(self):
        """Opening the episode picker is the explicit "取消解析" action. Besides
        invalidating generation and cancelling client/hedged, it must also tear
        down the hidden stream sniffer (streamSniffTask + WKWebView), which runs
        as a post-resolution failure fallback. Without this, a sniff completion
        (guarded only by playerGeneration, which the picker does not bump) could
        deliver a sniffed URL and start playback underneath the picker."""
        body = _method_body(self.mpvc, "- (void)openEpisodeSelection ")
        self.assertIn("self.generation++", body,
                      "openEpisodeSelection must bump resolution generation")
        self.assertIn("[self.client cancel]", body,
                      "openEpisodeSelection must cancel the client request")
        self.assertIn("[self.hedgedClient cancel]", body,
                      "openEpisodeSelection must cancel the hedged request")
        self.assertIn("[self teardownHiddenStreamSniffer]", body,
                      "openEpisodeSelection must tear down the stream sniffer")
        # resolving must be cleared so the spinner stops and status reflects cancel.
        self.assertIn('self.status.text=@"解析已取消', body)

    # ── Regression guards: the well-covered paths remain intact ──

    def test_resolve_and_play_still_cancels_client_and_bumps_generation(self):
        """resolveAndPlay must continue to bump generation, cancel the client,
        and tear down the player via clearCurrentPlayerItemPreservingPrefetch
        before issuing a new request."""
        body = _method_body(self.mpvc, "- (void)resolveAndPlay ")
        self.assertIn("++self.generation", body)
        self.assertIn("[self.client cancel]", body)
        self.assertIn("[self clearCurrentPlayerItemPreservingPrefetch:", body)

    def test_teardown_after_screen_exit_cancels_all_request_classes(self):
        """The screen-exit path must cancel every request class: generation,
        client, hedged, and (via clearCurrentPlayerItem) prefetch + stream
        sniffer + player."""
        body = _method_body(self.mpvc, "- (void)teardownAfterScreenExit ")
        self.assertIn("self.generation++", body)
        self.assertIn("[self.client cancel]", body)
        self.assertIn("[self.hedgedClient cancel]", body)
        self.assertIn("self.hedgedClient=nil", body)
        self.assertIn("[self clearCurrentPlayerItem]", body)
        self.assertIn("[self.prefetchedAsset cancelLoading]", body)


if __name__ == "__main__":
    unittest.main()
