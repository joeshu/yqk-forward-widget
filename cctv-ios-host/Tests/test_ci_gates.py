#!/usr/bin/env python3
"""Unit tests for the CI packaging gates (ci_gates.py).

The gates are exercised against *fabricated* ZIP/IPA fixtures built in
temporary directories so no real build artefact is required. The ``nm``
symbol gate is driven by an injected ``nm_runner`` so the tests run on any
host (no macOS toolchain needed).
"""
import importlib.util
import os
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "ci_gates", Path(__file__).parents[1] / "Scripts" / "ci_gates.py"
)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

APP_ROOT = "Payload/CCTVHost.app/"


def _write_app_skeleton(zf, frameworks=(), include_mpv=True, mpv_data=b""):
    """Write a minimal Payload/<app>.app/ tree into an open zipfile."""
    zf.writestr(APP_ROOT + "Info.plist", b"")
    for name in frameworks:
        zf.writestr(
            APP_ROOT + f"Frameworks/{name}.framework/{name}", b""
        )
    if include_mpv:
        member = APP_ROOT + "Frameworks/CCTVMPVCore.framework/CCTVMPVCore"
        zf.writestr(member, mpv_data or b"\x7fELF")


def _make_ipa(path, *, frameworks=(), include_mpv=True, mpv_data=b"",
              padding_name=None, padding_bytes=0):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as zf:
        _write_app_skeleton(
            zf, frameworks=frameworks, include_mpv=include_mpv,
            mpv_data=mpv_data,
        )
        if padding_name and padding_bytes:
            zf.writestr(padding_name, b"\0" * padding_bytes)


def _nm_runner_factory(lines):
    """Return a fake nm_runner emitting the given symbol lines."""
    output = "\n".join(lines)

    def runner(_path):
        return 0, output, ""

    return runner


class TestSizeGate(unittest.TestCase):
    def _ipa(self, tmp, size):
        path = Path(tmp) / "fat.ipa"
        _make_ipa(path, padding_name="Padding/big.bin", padding_bytes=size)
        return path

    def test_under_budget_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp, 5_000)
            name, passed, detail = g.check_ipa_size(ipa, 10_000)
            self.assertTrue(passed, detail)
            self.assertEqual(name, "ipa-size")

    def test_over_budget_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp, 20_000)
            name, passed, detail = g.check_ipa_size(ipa, 10_000)
            self.assertFalse(passed)
            self.assertIn("EXCEEDS", detail)

    def test_exact_budget_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp, 0)  # skeleton headers only
            actual = os.path.getsize(ipa)
            name, passed, detail = g.check_ipa_size(ipa, actual)
            self.assertTrue(passed, detail)


class TestFrameworkWhitelistGate(unittest.TestCase):
    WHITELIST = ("CNPlayerSDK", "CicadaPlayerSDK", "alivcffmpeg",
                 "CCTVMPVCore", "Python", "NodeMobile")

    def test_all_whitelisted_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "ok.ipa"
            _make_ipa(ipa, frameworks=self.WHITELIST)
            name, passed, detail = g.check_framework_whitelist(ipa, self.WHITELIST)
            self.assertTrue(passed, detail)

    def test_unknown_framework_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "rogue.ipa"
            _make_ipa(
                ipa,
                frameworks=self.WHITELIST + ("SurpriseKit",),
            )
            name, passed, detail = g.check_framework_whitelist(ipa, self.WHITELIST)
            self.assertFalse(passed)
            self.assertIn("SurpriseKit", detail)
            self.assertIn("unknown frameworks", detail)

    def test_missing_whitelisted_framework_still_passes(self):
        # Whitelist is an allowlist, not a must-include list: a subset is fine.
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "subset.ipa"
            _make_ipa(ipa, frameworks=("alivcffmpeg", "Python"))
            name, passed, detail = g.check_framework_whitelist(ipa, self.WHITELIST)
            self.assertTrue(passed, detail)


class TestMpvSymbolGate(unittest.TestCase):
    REQUIRED = g.REQUIRED_MPV_SYMBOLS

    def _ipa(self, tmp, *, include_mpv=True, mpv_data=b"\x7fELF"):
        path = Path(tmp) / "mpv.ipa"
        _make_ipa(
            path,
            frameworks=("alivcffmpeg", "CCTVMPVCore"),
            include_mpv=include_mpv,
            mpv_data=mpv_data,
        )
        return path

    def test_all_required_symbols_present_passes(self):
        lines = [
            "0000000100000000 T " + sym for sym in self.REQUIRED
        ]
        lines += ["0000000100001000 T _mpv_observe_property",
                  "0000000100002000 T _mpv_free_node_contents"]
        runner = _nm_runner_factory(lines)
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp)
            name, passed, detail = g.check_mpv_symbols(ipa, self.REQUIRED, runner)
            self.assertTrue(passed, detail)

    def test_missing_required_symbol_fails(self):
        present = list(self.REQUIRED)
        missing = present.pop()  # drop one required symbol
        lines = ["0000000100000000 T " + sym for sym in present]
        runner = _nm_runner_factory(lines)
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp)
            name, passed, detail = g.check_mpv_symbols(ipa, self.REQUIRED, runner)
            self.assertFalse(passed)
            self.assertIn("missing required", detail)
            self.assertIn(missing, detail)

    def test_nm_nonzero_return_fails(self):
        def runner(_path):
            return 1, "", "nm: file format not recognized"
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp)
            name, passed, detail = g.check_mpv_symbols(ipa, self.REQUIRED, runner)
            self.assertFalse(passed)
            self.assertIn("nm -gU failed", detail)

    def test_framework_absent_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "no-mpv.ipa"
            # CCTVMPVCore deliberately not embedded at all.
            _make_ipa(ipa, frameworks=("alivcffmpeg",), include_mpv=False)
            name, passed, detail = g.check_mpv_symbols(
                ipa, self.REQUIRED, _nm_runner_factory([])
            )
            self.assertFalse(passed)
            self.assertIn("not found in IPA", detail)

    def test_parses_addressless_nm_output(self):
        # Some nm variants print type-only lines without addresses.
        lines = ["T " + sym for sym in self.REQUIRED]
        runner = _nm_runner_factory(lines)
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._ipa(tmp)
            name, passed, detail = g.check_mpv_symbols(ipa, self.REQUIRED, runner)
            self.assertTrue(passed, detail)


class TestRunGates(unittest.TestCase):
    def test_all_pass(self):
        whitelist = g.FRAMEWORK_WHITELIST_DEFAULT
        required = g.REQUIRED_MPV_SYMBOLS
        nm_lines = ["T " + sym for sym in required]
        runner = _nm_runner_factory(nm_lines)
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "all.ipa"
            _make_ipa(ipa, frameworks=whitelist, mpv_data=b"\x7fELF")
            env = {"CCTV_IPA_SIZE_LIMIT_BYTES": str(10 * 1024 * 1024)}
            results = g.run_gates(
                ipa,
                whitelist=whitelist,
                required_mpv_symbols=required,
                nm_runner=runner,
                env=env,
            )
        self.assertTrue(all(p for _, p, _ in results), results)
        self.assertEqual([n for n, _, _ in results],
                         ["ipa-size", "framework-whitelist", "mpv-symbols"])

    def test_size_failure_blocks_overall(self):
        runner = _nm_runner_factory(["T " + s for s in g.REQUIRED_MPV_SYMBOLS])
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "fat.ipa"
            _make_ipa(
                ipa,
                frameworks=g.FRAMEWORK_WHITELIST_DEFAULT,
                padding_name="Padding/big.bin",
                padding_bytes=2 * 1024 * 1024,
                mpv_data=b"\x7fELF",
            )
            env = {"CCTV_IPA_SIZE_LIMIT_BYTES": "1024"}
            results = g.run_gates(
                ipa,
                whitelist=g.FRAMEWORK_WHITELIST_DEFAULT,
                nm_runner=runner,
                env=env,
            )
        statuses = {n: p for n, p, _ in results}
        self.assertFalse(statuses["ipa-size"])
        self.assertTrue(statuses["framework-whitelist"])
        self.assertTrue(statuses["mpv-symbols"])


class TestEnvResolution(unittest.TestCase):
    def test_size_env_bytes_overrides_default(self):
        env = {"CCTV_IPA_SIZE_LIMIT_BYTES": "4242"}
        self.assertEqual(g._resolve_size_limit(env), 4242)

    def test_size_env_mb_converts(self):
        env = {"CCTV_IPA_SIZE_LIMIT_MB": "5"}
        self.assertEqual(g._resolve_size_limit(env), 5_000_000)

    def test_size_default_when_unset(self):
        env = {}
        self.assertEqual(g._resolve_size_limit(env), g._default_size_limit_bytes())

    def test_whitelist_env_parsed(self):
        env = {"CCTV_FRAMEWORK_WHITELIST": "Foo,Bar , Baz"}
        self.assertEqual(g._resolve_whitelist(env), ("Foo", "Bar", "Baz"))

    def test_whitelist_default_when_unset(self):
        env = {}
        self.assertEqual(
            g._resolve_whitelist(env), g.FRAMEWORK_WHITELIST_DEFAULT
        )

    def test_default_size_limit_matches_documented_basis(self):
        # 108.8 MiB * (1 + 10%) reported in the module docstring & report.
        expected = int(round(108.8 * (1 << 20) * 1.10))
        self.assertEqual(g._default_size_limit_bytes(), expected)


class TestCli(unittest.TestCase):
    def test_cli_exits_nonzero_on_size_failure(self):
        runner = _nm_runner_factory(["T " + s for s in g.REQUIRED_MPV_SYMBOLS])
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "cli.ipa"
            _make_ipa(
                ipa,
                frameworks=g.FRAMEWORK_WHITELIST_DEFAULT,
                padding_name="Padding/big.bin",
                padding_bytes=1024 * 1024,
                mpv_data=b"\x7fELF",
            )
            # Patch the default nm runner so the CLI path uses the fake output.
            orig = g._default_nm_runner
            g._default_nm_runner = runner
            try:
                rc = g.main([
                    str(ipa),
                    "--size-limit-bytes", "1024",
                    "--framework-whitelist",
                    ",".join(g.FRAMEWORK_WHITELIST_DEFAULT),
                ])
            finally:
                g._default_nm_runner = orig
        self.assertEqual(rc, 1)

    def test_cli_exits_zero_when_all_pass(self):
        runner = _nm_runner_factory(["T " + s for s in g.REQUIRED_MPV_SYMBOLS])
        with tempfile.TemporaryDirectory() as tmp:
            ipa = Path(tmp) / "ok.ipa"
            _make_ipa(
                ipa,
                frameworks=g.FRAMEWORK_WHITELIST_DEFAULT,
                mpv_data=b"\x7fELF",
            )
            orig = g._default_nm_runner
            g._default_nm_runner = runner
            try:
                rc = g.main([
                    str(ipa),
                    "--size-limit-bytes", str(50 * 1024 * 1024),
                ])
            finally:
                g._default_nm_runner = orig
        self.assertEqual(rc, 0)

    def test_cli_missing_ipa_returns_two(self):
        rc = g.main(["/nonexistent/ipa.ipa"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
