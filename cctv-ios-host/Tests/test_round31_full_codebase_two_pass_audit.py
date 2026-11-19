import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestRound31FullCodebaseTwoPassAudit(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_every_themed_view_controller_syncs_trait_collection_changes(self):
        missing = []
        for path in sorted((ROOT / "Sources").glob("*ViewController.m")):
            text = path.read_text(encoding="utf-8")
            if "reloadThemeAppearance" in text and "traitCollectionDidChange:" not in text:
                missing.append(path.name)
        self.assertEqual(missing, [], f"ViewControllers missing traitCollectionDidChange: {missing}")

    def test_epg_seven_day_lookback_guards_weak_self_and_generation_early(self):
        src = self._read("Sources/EPGViewController.m")
        self.assertIn(
            "EPGViewController *owner = weakSelf;\n            if (!owner || generation != owner.requestGeneration) {",
            src,
        )
        self.assertIn("NSArray *norm = [owner normalize:programList];", src)

    def test_services_code_actions_and_playback_more_sheet_use_weak_self_and_safe_popover(self):
        svc = self._read("Sources/ServicesViewController.m")
        self.assertIn("ServiceDetailViewController *owner = weakSelf;", svc)
        self.assertIn("NSString *exportPath=[owner.service[@\"archivePath\"] length]?owner.service[@\"archivePath\"]:[ServiceStore codePath:owner.service];", svc)
        self.assertIn("[owner presentViewController:v animated:YES completion:nil];", svc)

        pb = self._read("Sources/RootViewController+Playback.m")
        idx = pb.index("- (void)showMorePlaybackActions {")
        end = pb.index("- (void)beginPlaybackPriority {", idx)
        body = pb[idx:end]
        self.assertIn("__weak typeof(self) weakSelf = self;", body)
        self.assertIn("UIView *anchor = self.moreBtn ?: self.view;", body)


if __name__ == "__main__":
    unittest.main()
