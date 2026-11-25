#!/usr/bin/env python3
"""Contract tests for playback session state-machine isolation (Stage A P0-2).

These tests verify the three minimal race fixes applied to the playback session
state machine:

1. PlaybackCoordinator.play clears resumeAfterInterruption (prevent double-resume
   when the user manually plays during an audio interruption).
2. MediaPlaybackViewController.sessionWantsPlayback honors resumePromptPending
   (prevent interruption auto-resume from bypassing the resume-position prompt).
3. MediaPlaybackViewController.playResult: cancels stale hedged resolution when
   the URL changes (prevent a stale hedged callback from overwriting a new
   line/quality selection).

The tests are source-level contracts: they read the Objective-C source files
and assert that the guard conditions exist. They do not require a macOS/iOS
toolchain and run as part of the Python test suite.
"""
import pathlib
import re
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


class PlaybackSessionIsolationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.coordinator = (SOURCES / "PlaybackCoordinator.m").read_text(encoding="utf-8")
        cls.mpvc = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")

    # ── Race 1: PlaybackCoordinator.play must clear resumeAfterInterruption ──

    def test_play_clears_resume_after_interruption(self):
        """play() and pause() must both clear resumeAfterInterruption so that a
        manual play during interruption does not cause a second sessionPlay when
        the interruption ends."""
        body = _method_body(self.coordinator, "- (MPRemoteCommandHandlerStatus)play ")
        self.assertIn("self.resumeAfterInterruption=NO", body,
                      "play must clear resumeAfterInterruption before forwarding sessionPlay")

    def test_pause_already_clears_resume_after_interruption(self):
        """pause() already clears resumeAfterInterruption — this is the existing
        symmetry we are matching."""
        body = _method_body(self.coordinator, "- (MPRemoteCommandHandlerStatus)pause ")
        self.assertIn("self.resumeAfterInterruption=NO", body)

    def test_interruption_end_checks_interrupted_session_identity(self):
        """The interruption end handler must verify interruptedSession ==
        currentSession before resuming, so a session switch during interruption
        does not resume the wrong session."""
        body = _method_body(self.coordinator, "- (void)interruption:(NSNotification *)note ")
        self.assertRegex(body, r"self\.interruptedSession==self\.currentSession")

    # ── Race 2: sessionWantsPlayback must honor resumePromptPending ──

    def test_session_wants_playback_checks_resume_prompt(self):
        """sessionWantsPlayback must return NO while resumePromptPending is YES,
        so the PlaybackCoordinator does not auto-resume after an interruption
        and bypass the user's resume-position choice."""
        body = _method_body(self.mpvc, "- (BOOL)sessionWantsPlayback ")
        self.assertIn("!self.resumePromptPending", body,
                      "sessionWantsPlayback must check !resumePromptPending")

    def test_session_play_does_not_clear_resume_prompt(self):
        """sessionPlay must NOT clear resumePromptPending itself — the prompt
        is dismissed by the user's choice in the alert actions. sessionPlay
        only sets playbackWantsPlayback and playbackSuspendedForVisibility."""
        body = _method_body(self.mpvc, "- (void)sessionPlay ")
        self.assertNotIn("resumePromptPending=NO", body,
                         "sessionPlay must not clear resumePromptPending (the alert handler does)")

    # ── Race 3: playResult cancels stale hedged resolution on URL change ──

    def test_play_result_cancels_hedged_on_url_change(self):
        """When the incoming URL differs from the previous URL, playResult must
        cancel any in-flight hedged resolution and clear the stale result, so a
        late hedged callback cannot overwrite the new selection."""
        body = _method_body(self.mpvc, "- (void)playResult:(NSDictionary *)result ")
        # Find the URL-change block
        self.assertIn("if(![incomingURL isEqualToString:previousURL])", body)
        url_change_start = body.index("if(![incomingURL isEqualToString:previousURL])")
        # Find the closing brace of that if-block (it's a single-line statement block)
        block_end = body.index("}", url_change_start)
        url_change_block = body[url_change_start:block_end+1]
        self.assertIn("[self.hedgedClient cancel]", url_change_block,
                      "hedgedClient must be cancelled when URL changes in playResult")
        self.assertIn("self.hedgedEpisodeResult=nil", url_change_block,
                      "hedgedEpisodeResult must be cleared when URL changes in playResult")

    def test_resolve_completion_still_checks_generation(self):
        """The async resolution completion block must check generation before
        calling playResult, so a superseded resolution does not overwrite the
        current selection."""
        # Find the completion block in resolveAndPlayForReason
        completion_match = re.search(
            r"void \(\^completion\)\(id,NSError \*\)=\^\(id result,NSError \*error\)\{",
            self.mpvc,
        )
        self.assertIsNotNone(completion_match, "resolution completion block must exist")
        # Extract a window around the completion block
        start = completion_match.start()
        window = self.mpvc[start:start+2000]
        self.assertIn("generation!=owner.generation", window,
                      "completion block must check generation != owner.generation")

    def test_hedged_callback_checks_generation(self):
        """The hedged resolution callback must also check generation."""
        body = _method_body(self.mpvc, "- (void)scheduleHedgedBackupLineResolutionForGeneration:(NSUInteger)generation ")
        self.assertIn("generation!=strongOwner.generation", body,
                      "hedged callback must check generation != strongOwner.generation")

    def test_sniff_callback_checks_player_generation(self):
        """The native stream sniff callback must check playerGeneration."""
        body = _method_body(self.mpvc, "- (void)sniffNativeStreamFromPageResult:(NSDictionary *)result playerGeneration:(NSUInteger)playerGeneration ")
        self.assertIn("owner.playerGeneration!=playerGeneration", body,
                      "sniff callback must check playerGeneration")

    # ── Cancellation thoroughness: cleanup paths cancel hedged client ──

    def test_dealloc_cancels_hedged_client(self):
        """dealloc must cancel the hedged client to prevent stale callbacks
        after the screen is destroyed."""
        body = _method_body(self.mpvc, "- (void)dealloc ")
        self.assertIn("[self.hedgedClient cancel]", body)

    def test_open_episode_selection_cancels_hedged_client(self):
        """openEpisodeSelection must cancel the hedged client before pushing
        the selection page."""
        body = _method_body(self.mpvc, "- (void)openEpisodeSelection ")
        self.assertIn("[self.hedgedClient cancel]", body)

    # ── Live generation guards (RootViewController) ──

    def test_live_play_channel_bumps_generation(self):
        """playChannel must bump playbackGeneration before starting."""
        root = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        body = _method_body(root, "- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route ")
        self.assertIn("self.playbackGeneration", body)

    def test_live_stop_playback_bumps_native_session_id(self):
        """stopPlayback must bump nativeSessionID so stale SDK callbacks are
        dropped by CNPlayerSessionDelegate.isCurrentSession."""
        root = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        body = _method_body(root, "- (void)stopPlayback ")
        self.assertIn("self.nativeSessionID++", body)
        self.assertIn("self.nativeSessionDelegate=nil", body)

    def test_native_delegate_checks_session_id(self):
        """CNPlayerSessionDelegate must check isCurrentSession before forwarding
        every callback."""
        delegate = (SOURCES / "CNPlayerSessionDelegate.m").read_text(encoding="utf-8")
        self.assertIn("- (BOOL)isCurrentSession {", delegate)
        self.assertIn("_sessionID == owner.nativeSessionID", delegate)
        # Every forwarded method must call isCurrentSession
        forward_count = delegate.count("if (![self isCurrentSession]) return;")
        self.assertGreaterEqual(forward_count, 10,
                                "all delegate forward methods must check isCurrentSession")

    def test_live_remote_callbacks_check_generation(self):
        """RootViewController async callbacks (readiness probe, remote URL
        start) must check playbackGeneration."""
        root = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        self.assertIn("generation!=self.playbackGeneration", root)
        self.assertIn("generation!=owner.playbackGeneration", root)
        self.assertIn("generation!=w.playbackGeneration", root)


if __name__ == "__main__":
    unittest.main()
