import glob
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class Round39ZeroLegacySheetsAndUXPolishTests(unittest.TestCase):
    def test_zero_legacy_ui_action_sheets_remain_across_all_sources(self):
        offenders = []
        for path in sorted(glob.glob(str(SOURCES / "*.m"))):
            text = pathlib.Path(path).read_text(encoding="utf-8")
            if "UIAlertControllerStyleActionSheet" in text:
                offenders.append(pathlib.Path(path).name)
        self.assertEqual(offenders, [], f"Legacy UIAlertControllerStyleActionSheet still present in: {offenders}")

    def test_glass_action_sheet_row_density_and_adoption(self):
        glass = read_source("HostGlassActionSheetViewController.m")
        self.assertIn("constraintGreaterThanOrEqualToConstant:48", glass)
        self.assertIn("constant:54", glass)
        self.assertIn("HostRoundedFont(14.5, UIFontWeightSemibold, UIFontTextStyleSubheadline)", glass)

        total_present = sum(
            pathlib.Path(p).read_text(encoding="utf-8").count("HostGlassActionSheetViewController presentOn:")
            for p in glob.glob(str(SOURCES / "*.m"))
        )
        self.assertGreaterEqual(total_present, 27)

    def test_root_channel_table_and_grid_dismiss_keyboard_on_drag(self):
        root = read_source("RootViewController.m")
        self.assertIn("self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;", root)
        self.assertIn("self.channelGrid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;", root)


if __name__ == "__main__":
    unittest.main()
