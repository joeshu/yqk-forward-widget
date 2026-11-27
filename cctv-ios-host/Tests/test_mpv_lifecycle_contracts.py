"""Source-contract tests for the T02 (S1) MPV lifecycle wiring.

These assert that MediaPlaybackMPVAdapter routes its terminal lifecycle
through the pure-C core (Sources/HostMPVLifecycle.h/.c). The actual
state-machine behaviour is executed by test_mpv_lifecycle.py; these
contracts only pin the wiring so a later edit cannot silently drop it.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
ADAPTER_M = (SOURCES / "MediaPlaybackMPVAdapter.m").read_text(encoding="utf-8")
LIFECYCLE_H = (SOURCES / "HostMPVLifecycle.h").read_text(encoding="utf-8")
LIFECYCLE_C = (SOURCES / "HostMPVLifecycle.c").read_text(encoding="utf-8")


class MPVLifecycleContractTests(unittest.TestCase):
    def test_adapter_uses_lifecycle_core(self):
        self.assertIn('#import "HostMPVLifecycle.h"', ADAPTER_M)
        self.assertIn("host_mpv_lifecycle_t *_lifecycle;", ADAPTER_M)
        self.assertIn("host_mpv_lifecycle_create()", ADAPTER_M)

    def test_prepare_is_single_owner_with_abandon_on_early_failure(self):
        self.assertIn("host_mpv_lifecycle_begin_prepare(_lifecycle)", ADAPTER_M)
        # Every failure path before the event thread starts must return
        # the lifecycle to IDLE so no half-prepared state lingers.
        self.assertGreaterEqual(
            ADAPTER_M.count("host_mpv_lifecycle_abandon_prepare(_lifecycle)"), 4)
        self.assertIn("host_mpv_lifecycle_note_event_thread_started(_lifecycle)",
                      ADAPTER_M)

    def test_destroy_is_single_owner_and_waits_for_event_exit(self):
        self.assertIn("host_mpv_lifecycle_begin_destroy(lc)", ADAPTER_M)
        self.assertIn(
            "host_mpv_lifecycle_wait_event_thread_exit(lc, MediaPlaybackMPVDestroyEventExitTimeoutMs)",
            ADAPTER_M)
        self.assertIn("host_mpv_lifecycle_finish_destroy(lc)", ADAPTER_M)
        # The teardown block must never touch the adapter itself: it only
        # uses the retained lifecycle reference and the captured handle.
        destroy = ADAPTER_M[ADAPTER_M.index("- (void)destroy {"):]
        destroy = destroy[:destroy.index("\n}\n") + 3]
        self.assertNotIn("self.mpvHandle", destroy.split("dispatch_async")[1])
        self.assertNotIn("self.destroyed", destroy.split("dispatch_async")[1])
        # destroy releases its teardown reference; dealloc releases the
        # adapter's own reference.
        self.assertIn("host_mpv_lifecycle_release(lc);", destroy)
        self.assertIn("host_mpv_lifecycle_release(_lifecycle);", ADAPTER_M)

    def test_commands_after_destroy_are_gated(self):
        for method in ("- (void)start {", "- (void)pause {",
                       "- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(BOOL finished))completion {",
                       "- (void)setRate:(float)rate {",
                       "- (void)setMuted:(BOOL)muted {",
                       "- (BOOL)selectTrackWithIndex:(NSInteger)index {",
                       "- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL {",
                       "- (void)applyVideoGravity:(NSString *)gravity {",
                       "- (NSArray<NSDictionary *> *)availableTracks {"):
            start = ADAPTER_M.index(method)
            body = ADAPTER_M[start:start + 900]
            self.assertIn("host_mpv_lifecycle_command_allowed(_lifecycle)", body,
                          f"{method} must gate on the lifecycle core")

    def test_event_thread_signals_exit_on_every_path(self):
        # Entry guards + the normal loop exit all signal the handshake.
        self.assertGreaterEqual(
            ADAPTER_M.count("host_mpv_lifecycle_note_event_thread_exited(_lifecycle)"), 3)

    def test_cond_clock_is_portable_to_darwin(self):
        # pthread_condattr_setclock does not exist on macOS (CI ui-preview
        # failed on it): the monotonic cond setup must be guarded out on
        # Apple platforms, and the wait deadline must then be computed in
        # the cond's own (realtime) clock, or the bounded wait misfires.
        self.assertIn("#if !defined(__APPLE__)", LIFECYCLE_C)
        self.assertIn("pthread_condattr_setclock", LIFECYCLE_C)
        self.assertIn("#ifdef __APPLE__", LIFECYCLE_C)
        self.assertIn("pthread_cond_timedwait_relative_np", LIFECYCLE_C)
        self.assertIn("clock_gettime(CLOCK_MONOTONIC, &deadline)", LIFECYCLE_C)

    def test_lifecycle_core_is_pure_c(self):
        # No Foundation, no I/O, no allocation besides the object itself.
        for forbidden in ("#import <Foundation", "NSLog", "fopen", "NSLock",
                          "dispatch_", "NSURL", "NSDictionary"):
            self.assertNotIn(forbidden, LIFECYCLE_C, forbidden)
            self.assertNotIn(forbidden, LIFECYCLE_H, forbidden)
        self.assertIn("pthread_mutex_t", LIFECYCLE_H)
        self.assertIn("pthread_cond_t", LIFECYCLE_H)
        for api in ("host_mpv_lifecycle_begin_prepare",
                    "host_mpv_lifecycle_abandon_prepare",
                    "host_mpv_lifecycle_note_event_thread_started",
                    "host_mpv_lifecycle_note_event_thread_exited",
                    "host_mpv_lifecycle_command_allowed",
                    "host_mpv_lifecycle_begin_destroy",
                    "host_mpv_lifecycle_wait_event_thread_exit",
                    "host_mpv_lifecycle_finish_destroy"):
            self.assertIn(api, LIFECYCLE_H)
            self.assertIn(api, LIFECYCLE_C)


if __name__ == "__main__":
    unittest.main()
