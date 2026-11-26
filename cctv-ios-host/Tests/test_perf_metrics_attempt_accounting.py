"""Behavior tests for the T01 (PERF-07) attempt ledger.

Unlike the source-contract tests in test_perf_metrics.py, these tests
EXECUTE the production accounting code: the pure-C ledger
(Sources/HostPerfAttemptLedger.c) is compiled with the system C compiler
and driven by the scripted harness (Tests/native_perf_ledger_tests.c),
which plays the test doubles — a controllable monotonic clock (explicit
``now_ms`` values), a fake engine / event emitter (scripted begin /
first-audio / first-video / failed / cancelled calls, including duplicate
and stale callbacks and a cancel-then-retry sequence) and a fake API
client dimension (source_revision carried per attempt).

The harness prints one ``RESULT <scenario> <key>=<value> ...`` line per
scenario; this file asserts the numbers. The ledger performs no I/O by
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
LEDGER_C = SOURCES / "HostPerfAttemptLedger.c"
LEDGER_H = SOURCES / "HostPerfAttemptLedger.h"
HARNESS_C = ROOT / "Tests" / "native_perf_ledger_tests.c"
DIAGNOSTICS = (SOURCES / "RuntimeDiagnostics.m").read_text(encoding="utf-8")


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
class PerfAttemptAccountingBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.exe = str(Path(cls.tmp.name) / "ledger-tests")
        compiled = subprocess.run(
            ["cc", "-std=c99", "-Wall", "-Wextra", "-O1",
             "-I", str(SOURCES), str(LEDGER_C), str(HARNESS_C),
             "-o", cls.exe],
            capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        assert not compiled.stderr.strip(), compiled.stderr

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_harness(self):
        run = subprocess.run([self.exe], capture_output=True, text=True,
                             cwd=self.tmp.name, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("HARNESS OK", run.stdout)
        return parse_results(run.stdout)

    def test_quantiles_from_known_samples_are_accurate(self):
        # 100 video attempts, latencies 100..10000ms in 100ms steps.
        result = self.run_harness()["quantiles"]
        self.assertEqual(result["p50"], 5000)
        self.assertEqual(result["p95"], 9500)
        self.assertEqual(result["count"], 100)
        self.assertEqual(result["min"], 100)
        self.assertEqual(result["max"], 10000)
        self.assertEqual(result["avg"], 5050)

    def test_cancel_is_listed_separately_from_success_rate_denominator(self):
        # 7 video successes, 2 failures, 1 cancel: rate is 7/(7+2), not 7/10.
        result = self.run_harness()["success_rate"]
        self.assertEqual(result["started"], 10)
        self.assertEqual(result["success"], 7)
        self.assertEqual(result["failed"], 2)
        self.assertEqual(result["cancelled"], 1)
        self.assertEqual(result["rate_milli"], 777)

    def test_duplicate_first_video_is_not_double_counted(self):
        result = self.run_harness()["duplicate_first_video"]
        self.assertEqual(result["success"], 1)
        self.assertEqual(result["duplicate_ignored"], 1)

    def test_stale_callback_does_not_count_for_new_attempt(self):
        # Old attempt's late first video + old generation for the new
        # attempt are both ignored; only the current attempt counts.
        result = self.run_harness()["stale_callback"]
        self.assertEqual(result["stale_ignored"], 2)
        self.assertEqual(result["success"], 1)

    def test_cancel_is_terminal_and_late_frames_are_ignored(self):
        result = self.run_harness()["cancel_terminal"]
        self.assertEqual(result["cancelled"], 1)
        self.assertEqual(result["success"], 0)

    def test_audio_only_success_is_separate_from_video_success(self):
        result = self.run_harness()["audio_only"]
        self.assertEqual(result["success_audio"], 1)
        self.assertEqual(result["success_video"], 0)
        self.assertEqual(result["started"], 2)

    def test_prewarm_samples_do_not_pollute_latency_histogram(self):
        result = self.run_harness()["prewarm_excluded"]
        self.assertEqual(result["histogram_count"], 1)
        self.assertEqual(result["p50"], 5000)
        self.assertEqual(result["started"], 2)

    def test_attempt_ring_is_bounded(self):
        result = self.run_harness()["ring_bounded"]
        self.assertEqual(result["ring_count"], result["capacity"])
        self.assertEqual(result["capacity"], 128)
        self.assertEqual(result["started"], 200)

    def test_engine_split_and_cancel_then_retry(self):
        result = self.run_harness()["engine_split"]
        self.assertEqual(result["avplayer"], 4)
        self.assertEqual(result["cicada"], 2)
        self.assertEqual(result["success"], 6)
        self.assertEqual(result["failed"], 1)

    def test_accounting_writes_no_files(self):
        # The ledger is pure computation: running every scenario must not
        # create any file (no high-frequency persistence by construction).
        before = set(Path(self.tmp.name).iterdir())
        self.run_harness()
        after = set(Path(self.tmp.name).iterdir())
        self.assertEqual(before, after)

    def test_ledger_sources_are_balanced(self):
        for path in (LEDGER_C, LEDGER_H, HARNESS_C):
            text = path.read_text(encoding="utf-8")
            code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
            code = re.sub(r"//[^\n]*", "", code)
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
            for opening, closing in ("{}", "()", "[]"):
                self.assertEqual(code.count(opening), code.count(closing),
                                 f"{path.name} {opening}{closing}")


class DiagnosticsDisabledGateTests(unittest.TestCase):
    """Contract check (not a behavior test): the diagnostics-off gate in
    RuntimeDiagnostics must return before any serialization or file write,
    so disabling diagnostics can never cause high-frequency persistence.
    The behavior side is covered by test_accounting_writes_no_files above
    (the ledger, which feeds diagnostics, writes nothing itself)."""

    def test_record_event_returns_before_serialization_when_disabled(self):
        start = DIAGNOSTICS.index(
            "- (void)recordEvent:(NSString *)event category:(NSString *)category "
            "fields:(NSDictionary<NSString *,id> *)fields synchronously:(BOOL)synchronously")
        body = DIAGNOSTICS[start:start + 2500]
        gate = body.index("if (!self.enabled) return;")
        self.assertLess(gate, body.index("dataWithJSONObject"))
        self.assertLess(gate, body.index("dispatch_async(self.queue, write)"))
        self.assertLess(gate, body.index("dispatch_sync(self.queue, write)"))


if __name__ == "__main__":
    unittest.main()
