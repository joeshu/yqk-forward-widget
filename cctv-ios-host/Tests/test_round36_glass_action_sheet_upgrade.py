import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round36GlassActionSheetUpgradeTests(unittest.TestCase):
    def test_01_reusable_host_glass_action_sheet_component_complete(self):
        hdr = (SOURCES / "HostGlassActionSheetViewController.h").read_text(encoding="utf-8")
        impl = (SOURCES / "HostGlassActionSheetViewController.m").read_text(encoding="utf-8")

        self.assertIn("@interface HostGlassSheetAction : NSObject", hdr)
        self.assertIn("@interface HostGlassSheetSection : NSObject", hdr)
        self.assertIn("@interface HostGlassActionSheetViewController : UIViewController", hdr)
        self.assertIn("+ (void)presentOn:(UIViewController *)presenter", hdr)
        self.assertIn('accessibilityIdentifier = @"host.glass.action-sheet"', impl)
        self.assertIn("HostGlassBlur()", impl)
        self.assertIn("makeChipRowCard:", impl)
        self.assertIn("makeGroupedRowsCard:", impl)
        self.assertIn("- (void)reloadThemeAppearance", impl)
        self.assertIn("- (void)traitCollectionDidChange:", impl)

    def test_02_four_major_legacy_action_sheets_upgraded_to_glass_sheets(self):
        pb = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        ts = pb.split("- (void)showNativeTimeshiftActions {", 1)[1].split("\n- (void)beginNativeTransition", 1)[0]
        cast = pb.split("- (void)showCastingCenter {", 1)[1].split("\n- (void)showMorePlaybackActions", 1)[0]
        self.assertIn("[HostGlassActionSheetViewController presentOn:self", ts)
        self.assertNotIn("UIAlertControllerStyleActionSheet", ts)
        self.assertIn("[HostGlassActionSheetViewController presentOn:self", cast)
        self.assertNotIn("UIAlertControllerStyleActionSheet", cast)

        settings = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        hero = settings.split("- (void)presentHeroQuickActionsSheet:(UIButton *)sender {", 1)[1].split("\n- (void)selectCategoryPill", 1)[0]
        self.assertIn("[HostGlassActionSheetViewController presentOn:self", hero)
        self.assertNotIn("UIAlertControllerStyleActionSheet", hero)

        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        flt = cc.split("- (void)showResourceFilters {", 1)[1].split("\n- (void)selectKind:", 1)[0]
        self.assertIn("[HostGlassActionSheetViewController presentOn:self", flt)
        self.assertNotIn("UIAlertControllerStyleActionSheet", flt)


if __name__ == "__main__":
    unittest.main()
