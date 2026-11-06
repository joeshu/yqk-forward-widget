import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class UI2026DeepRefinementsTests(unittest.TestCase):
    def test_ref1_settings_theme_palette_preview_dots_and_cards(self):
        settings = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn('NSString *dot=theme.dark?@"● ":@"○ ";', settings)
        self.assertIn("cell.layer.cornerRadius=14; cell.layer.cornerCurve=kCACornerCurveContinuous;", settings)

    def test_ref2_root_channel_list_cell_card_rounding_and_border(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous;", root)
        self.assertIn("HostSetLayerBorderColor(cell,playing?HostAccent():HostBorder());", root)

    def test_ref3_epg_guide_cell_card_rounding_and_active_border(self):
        epg = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous;", epg)
        self.assertIn("HostSetLayerBorderColor(cell,live?HostAccent():HostBorder());", epg)

    def test_ref4_media_detail_resume_episode_accent_border(self):
        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn('button.accessibilityHint=@"上次播放至此集";', browser)
        self.assertIn("HostSetLayerBorderColor(button,HostAccent());", browser)

    def test_ref5_favorites_and_history_poster_thumbnail_rounding(self):
        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(browser.count("cell.imageView.layer.cornerRadius=10;cell.imageView.layer.cornerCurve=kCACornerCurveContinuous;"), 2)

    def test_ref6_global_search_result_floating_cards_and_poster_corners(self):
        search = (SOURCES / "MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.layer.cornerRadius=14;self.layer.cornerCurve=kCACornerCurveContinuous;", search)
        self.assertIn("self.poster.layer.cornerRadius=10;self.poster.layer.cornerCurve=kCACornerCurveContinuous;", search)
        self.assertIn("self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;", search)

    def test_ref7_runtime_diagnostics_status_badges_and_cards(self):
        diag = (SOURCES / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius = 14; cell.layer.cornerCurve = kCACornerCurveContinuous;", diag)
        self.assertIn('@"未正常收尾 ⚠"', diag)

    def test_ref8_tvbox_catalog_card_borders_and_corners(self):
        catalog = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13;cell.layer.cornerCurve=kCACornerCurveContinuous;", catalog)
        self.assertIn("HostSetLayerBorderColor(cell,HostBorder());", catalog)

    def test_ref9_playback_gesture_feedback_spring_animation(self):
        playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("usingSpringWithDamping:0.75 initialSpringVelocity:0.4", playback)
        self.assertIn("usingSpringWithDamping:0.65 initialSpringVelocity:0.5", playback)

    def test_ref10_playback_quality_buttons_press_feedback(self):
        playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostInstallPressFeedback(button);MediaPlaybackApplyScaledPillFont(button);", playback)


if __name__ == "__main__":
    unittest.main()
