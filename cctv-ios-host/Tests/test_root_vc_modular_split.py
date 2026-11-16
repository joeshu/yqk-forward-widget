import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class RootViewControllerModularSplitTests(unittest.TestCase):
    EXPECTED_MODULES = [
        "RootViewController.m",
        "RootViewController+Catalog.m",
        "RootViewController+Playback.m",
        "RootViewController+StreamMetrics.m",
        "RootViewController+EPG.m",
        "RootViewController+Subscriptions.m",
        "RootViewController+Services.m",
    ]

    def test_all_seven_modules_and_internal_header_exist_with_bounded_sizes(self):
        internal_h = SOURCES / "RootViewController_Internal.h"
        self.assertTrue(internal_h.is_file(), "RootViewController_Internal.h must exist")
        for name in self.EXPECTED_MODULES:
            path = SOURCES / name
            self.assertTrue(path.is_file(), f"Missing module {name}")
            line_count = len(path.read_text(encoding="utf-8").splitlines())
            self.assertGreater(line_count, 100, f"{name} is unexpectedly empty")
            self.assertLess(line_count, 1600, f"{name} exceeds modular line budget ({line_count} lines)")

    def test_zero_duplicate_methods_across_root_vc_modules(self):
        seen = {}
        for name in self.EXPECTED_MODULES:
            lines = (SOURCES / name).read_text(encoding="utf-8").splitlines()
            in_root_impl = False
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("@implementation RootViewController"):
                    in_root_impl = True
                    continue
                if in_root_impl and stripped == "@end":
                    in_root_impl = False
                    continue
                if in_root_impl and line.startswith(("- (", "+ (")):
                    sig = line.split("{")[0].strip()
                    self.assertNotIn(sig, seen, f"Duplicate method {sig} in {name} and {seen.get(sig)}")
                    seen[sig] = name
        self.assertGreaterEqual(len(seen), 320)

    def test_memory_warning_and_background_lifecycle_hardening(self):
        core = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)didReceiveMemoryWarning", core)
        self.assertIn("[self.channelPreviewSnapshots removeAllObjects]", core)
        self.assertIn("cancelAllCGImageGeneration", core)
        self.assertIn("[self.liveQualityBadgeTimer invalidate]", core)

    def test_post_audit_o1_index_telemetry_and_nonblocking_probe_optimizations(self):
        catalog = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        metrics = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        epg = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")
        config_center = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")

        self.assertIn("self.channelIndexByID", catalog)
        self.assertIn("self.shownChannelIndexByID", catalog)
        self.assertIn("loadDeferredMetadataForVisibleTableRows", catalog)
        self.assertIn("canonicalStationIDForChannel:ch", epg)
        self.assertIn("M/s · %.0fms", metrics)
        self.assertIn("K/s · %.0fms", metrics)
        self.assertNotIn("dispatch_semaphore_wait", config_center)


if __name__ == "__main__":
    unittest.main()
