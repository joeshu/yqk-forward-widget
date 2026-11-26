import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "Scripts"
SOURCES_DIR = ROOT / "Sources"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import prepare_mpv_runtime


class Round44MPVUniversalDecoderTests(unittest.TestCase):
    def test_exported_symbol_allowlist_and_isolation_gate(self):
        allowlist_path = SCRIPTS_DIR / "mpv_exported_symbols.txt"
        allowlist = prepare_mpv_runtime.load_allowlist(allowlist_path)
        self.assertGreaterEqual(len(allowlist), 18)
        for sym in ("_mpv_create", "_mpv_initialize", "_mpv_wait_event", "_mpv_terminate_destroy"):
            self.assertIn(sym, allowlist)
        for sym in allowlist:
            self.assertTrue(sym.startswith("_mpv_"), f"Non-mpv symbol in allowlist: {sym}")

        clean_nm = "\n".join(f"0000000000001000 T {sym}" for sym in sorted(allowlist))
        ok, violations = prepare_mpv_runtime.verify_exported_symbols(clean_nm, allowlist=allowlist)
        self.assertTrue(ok, f"Clean nm output should pass gate: {violations}")
        self.assertEqual(violations, [])

        leaked_ffmpeg_nm = clean_nm + "\n0000000000020000 T _avcodec_open2\n0000000000020100 T _avformat_open_input\n"
        ok, violations = prepare_mpv_runtime.verify_exported_symbols(leaked_ffmpeg_nm, allowlist=allowlist)
        self.assertFalse(ok)
        self.assertIn("forbidden_symbol:_avcodec_open2", violations)
        self.assertIn("forbidden_symbol:_avformat_open_input", violations)

        leaked_ssl_nm = clean_nm + "\n0000000000030000 T _SSL_new\n"
        ok, violations = prepare_mpv_runtime.verify_exported_symbols(leaked_ssl_nm, allowlist=allowlist)
        self.assertFalse(ok)
        self.assertIn("forbidden_symbol:_SSL_new", violations)

    def test_mpv_adapter_zero_link_isolation_and_capabilities(self):
        adapter_h = (SOURCES_DIR / "MediaPlaybackMPVAdapter.h").read_text(encoding="utf-8")
        adapter_m = (SOURCES_DIR / "MediaPlaybackMPVAdapter.m").read_text(encoding="utf-8")

        self.assertNotIn("#include <mpv/client.h>", adapter_m)
        self.assertNotIn("#import <Libmpv/", adapter_m)
        self.assertIn("RTLD_NOW | RTLD_LOCAL", adapter_m)
        self.assertIn("CCTVMPVCore.framework/CCTVMPVCore", adapter_m)
        self.assertIn("CAMetalLayer", adapter_m)
        self.assertIn('"vo", "gpu-next"', adapter_m)
        self.assertIn('"gpu-api", "vulkan"', adapter_m)
        self.assertIn('"gpu-context", "moltenvk"', adapter_m)
        self.assertIn('"ao", "avfoundation"', adapter_m)
        self.assertIn('"videotoolbox"', adapter_m)
        self.assertIn('"deinterlace", "auto"', adapter_m)
        self.assertIn('"sub-ass", "yes"', adapter_m)
        self.assertIn('"sub-add"', adapter_m)
        self.assertIn("profile", adapter_m)
        self.assertIn("demuxer-max-bytes", adapter_m)
        self.assertIn("- (BOOL)addExternalSubtitleURL:(NSURL *)subtitleURL;", adapter_h)

    def test_router_player_and_ci_integration(self):
        router_m = (SOURCES_DIR / "MediaPlaybackDecodeRouter.m").read_text(encoding="utf-8")
        self.assertIn('NSClassFromString(@"MediaPlaybackMPVAdapter")', router_m)
        # T07/R4：webOnly 门禁按 MPV 启用状态（开关 + 可用性），不是裸可用性。
        # T11：旁路抽成 helper（直播关闭旁路），导出函数仍按同一启用状态返回 NO。
        self.assertIn('if (mpvBypassAllowed && MediaPlaybackMPVRouteEnabled()) return NO;', router_m)
        self.assertIn('return MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(result, YES);', router_m)
        self.assertIn('rtsp://', router_m)
        self.assertIn('srt://', router_m)

        player_m = (SOURCES_DIR / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn('#import "MediaPlaybackMPVAdapter.h"', player_m)
        # T07：VC 不再直接问 MPV isAvailable，改走协调器单一工厂建引擎。
        self.assertIn('engineForRoute:route', player_m)
        self.assertIn('addExternalSubtitleURL:', player_m)

        ci_sh = (SCRIPTS_DIR / "ci-build.sh").read_text(encoding="utf-8")
        self.assertIn("Scripts/prepare_mpv_runtime.py", ci_sh)
        self.assertNotIn("-framework CCTVMPVCore", ci_sh)

        val_py = (SCRIPTS_DIR / "validate_ipa.py").read_text(encoding="utf-8")
        self.assertIn("CCTVMPVCore.framework/CCTVMPVCore", val_py)
        self.assertIn("dlopen RTLD_LOCAL", val_py)


if __name__ == "__main__":
    unittest.main()
