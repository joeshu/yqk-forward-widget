"""Behavior tests for the T02 (S1) MPV lifecycle core.

Unlike source-contract tests, these tests EXECUTE the production
lifecycle code: the pure-C core (Sources/HostMPVLifecycle.c) is compiled
with the system C compiler and driven by the scripted harness
(Tests/native_mpv_lifecycle_tests.c), which plays the test doubles — a
fake mpv_wait_event consumer thread (250ms timed wait, exits on request,
with a stuck-consumer variant) and two racing destroy callers.

The harness prints one ``RESULT <scenario> <key>=<value> ...`` line per
scenario; this file asserts the numbers. The core performs no I/O by
design, which the no-files test verifies behaviorally.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
LIFECYCLE_C = SOURCES / "HostMPVLifecycle.c"
LIFECYCLE_H = SOURCES / "HostMPVLifecycle.h"
HARNESS_C = ROOT / "Tests" / "native_mpv_lifecycle_tests.c"


def parse_results(output):
    results = {}
    for line in output.splitlines():
        match = re.match(r"^RESULT (\S+)((?: \S+=\S+)*)$", line)
        if not match:
            continue
        values = {}
        for token in match.group(2).split():
            key, value = token.split("=", 1)
            values[key] = int(value) if re.fullmatch(r"-?\d+", value) else value
        results[match.group(1)] = values
    return results


@unittest.skipUnless(shutil.which("cc"), "system C compiler (cc) is required")
class MPVLifecycleBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.exe = str(Path(cls.tmp.name) / "mpv-lifecycle-tests")
        compiled = subprocess.run(
            ["cc", "-std=c99", "-Wall", "-Wextra", "-O1", "-pthread",
             "-I", str(SOURCES), str(LIFECYCLE_C), str(HARNESS_C),
             "-o", cls.exe],
            capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        assert not compiled.stderr.strip(), compiled.stderr
        run = subprocess.run([cls.exe], capture_output=True, text=True,
                             cwd=cls.tmp.name, timeout=120)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "MPV_LIFECYCLE_DOUBLES_OK" in run.stdout, run.stdout + run.stderr
        cls.results = parse_results(run.stdout)
        cls.run_stdout = run.stdout

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_prepare_once(self):
        r = self.results["prepare_once"]
        self.assertEqual(r["prepared"], 1)
        self.assertEqual(r["allowed"], 1)
        self.assertEqual(r["state"], 1)  # HOST_MPV_LC_PREPARED

    def test_double_prepare_rejected(self):
        r = self.results["double_prepare_rejected"]
        self.assertEqual(r["first"], 1)
        self.assertEqual(r["second"], 0)
        self.assertEqual(r["allowed"], 1)
        self.assertEqual(r["state"], 1)

    def test_commands_after_destroy(self):
        r = self.results["commands_after_destroy"]
        self.assertEqual(r["owned"], 1)
        self.assertEqual(r["allowed"], 0)
        self.assertEqual(r["reprepare"], 0)
        self.assertEqual(r["second_destroy"], 0)
        self.assertEqual(r["waited"], 1)
        self.assertEqual(r["state"], 3)  # HOST_MPV_LC_DESTROYED

    def test_destroy_before_prepare(self):
        r = self.results["destroy_before_prepare"]
        self.assertEqual(r["owned"], 1)
        self.assertEqual(r["allowed"], 0)
        self.assertEqual(r["reprepare"], 0)
        self.assertEqual(r["waited"], 1)
        self.assertLess(r["elapsed_ms"], 100)
        self.assertEqual(r["state"], 3)

    def test_event_exit_handshake_orders_release_after_exit(self):
        r = self.results["event_exit_handshake"]
        self.assertEqual(r["owned"], 1)
        self.assertEqual(r["waited"], 1)
        self.assertLess(r["elapsed_ms"], 1000)
        self.assertGreater(r["exit_seq"], 0)
        # The release (teardown) sequence number must come after the
        # consumer-exit sequence number: terminate_destroy can only run
        # once the event thread has left wait_event.
        self.assertLess(r["exit_seq"], r["release_seq"])
        self.assertEqual(r["state"], 3)

    def test_exit_sequence_is_recorded_before_signalling_exit(self):
        # Contract lock (CI 2026-11-26): fake_consumer_main must take its
        # exit_seq BEFORE note_event_thread_exited — the waiter takes
        # release_seq the moment the wait returns, so recording after the
        # signal lets the waiter win the race and flakes the ordering
        # check above on a loaded runner.
        harness = HARNESS_C.read_text()
        main = harness[harness.index("fake_consumer_main"):
                       harness.index("fake_consumer_start")]
        self.assertLess(main.index("c->exit_seq = next_seq();"),
                        main.index("host_mpv_lifecycle_note_event_thread_exited(c->lc);"))

    def test_event_exit_timeout_is_bounded(self):
        r = self.results["event_exit_timeout_bounded"]
        self.assertEqual(r["owned"], 1)
        self.assertEqual(r["waited"], 0)
        self.assertGreaterEqual(r["elapsed_ms"], 150)
        self.assertLess(r["elapsed_ms"], 1000)
        self.assertEqual(r["state"], 3)

    def test_concurrent_destroy_single_owner(self):
        r = self.results["concurrent_destroy_single_owner"]
        self.assertEqual(r["rounds"], 50)
        self.assertEqual(r["owners_total"], 50)

    def test_abandon_prepare(self):
        r = self.results["abandon_prepare"]
        self.assertEqual(r["first"], 1)
        self.assertEqual(r["abandoned"], 1)
        self.assertEqual(r["idle_state"], 0)  # HOST_MPV_LC_IDLE
        self.assertEqual(r["reprepare"], 1)
        self.assertEqual(r["allowed"], 1)

    def test_abandon_after_thread_started_refused(self):
        r = self.results["abandon_after_thread_started_refused"]
        self.assertEqual(r["abandoned"], 0)
        self.assertEqual(r["state"], 1)
        self.assertEqual(r["allowed"], 1)

    def test_rapid_prepare_destroy_cycles(self):
        r = self.results["rapid_prepare_destroy_cycles"]
        self.assertEqual(r["cycles"], 200)
        self.assertEqual(r["bad"], 0)

    def test_refcount_teardown_outlives_owner(self):
        r = self.results["refcount_teardown_outlives_owner"]
        self.assertEqual(r["rc_create"], 1)
        self.assertEqual(r["rc_after_retain"], 2)
        self.assertEqual(r["rc_after_owner_release"], 1)
        self.assertEqual(r["rc_before_teardown_release"], 1)

    def test_lifecycle_core_performs_no_file_io(self):
        # The harness ran inside the (initially empty) temp dir; the core
        # must not have written anything there.
        leftovers = [p for p in Path(self.tmp.name).iterdir()
                     if p.name != "mpv-lifecycle-tests"]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
