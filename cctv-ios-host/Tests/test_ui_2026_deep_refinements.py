import pathlib
import re
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
        self.assertIn("HostStylePillButton(self.dateMenuButton,NO);HostInstallPressFeedback(self.dateMenuButton);", epg)

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
        self.assertIn("HostStylePillButton(self.historyButton,NO);", search)
        self.assertIn("HostInstallPressFeedback(self.historyButton);", search)

    def test_ref7_runtime_diagnostics_status_badges_and_cards(self):
        diag = (SOURCES / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius = 14; cell.layer.cornerCurve = kCACornerCurveContinuous;", diag)
        self.assertIn('@"未正常收尾 ⚠"', diag)
        self.assertIn('[self showTransientPrompt:@"诊断事件已复制"];', diag)

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

    def test_ref11_full_app_live_theme_reload_and_interface_style_coverage(self):
        for p in sorted(SOURCES.glob("*.m")):
            text = p.read_text(encoding="utf-8")
            for cls in re.findall(r"@implementation\s+(\w+)", text):
                if "ViewController" in cls or cls in ("MediaSourcePicker", "CCTVPlaybackListPanelController"):
                    block = re.search(rf"@implementation\s+{cls}\b(.*?)@end", text, re.S).group(1)
                    with self.subTest(file=p.name, controller=cls):
                        self.assertIn("- (void)reloadThemeAppearance", block)
                        self.assertIn("overrideUserInterfaceStyle", block)

    def test_ref12_live_panel_and_source_picker_spatial_selected_cards(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.backgroundColor=selected?HostSelectedSurface():HostCard();", root)
        self.assertIn("cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());", root)

        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.backgroundColor=selected?HostSelectedSurface():HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());", browser)

    def test_ref13_playback_info_and_log_center_and_web_player_spatial_polish(self):
        info = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostSetLayerBorderColor(c, HostBorder());", info)
        self.assertIn('@"实时播放链路指标 · 点按任意行可复制"', info)
        self.assertIn('[self showTransientPrompt:@"指标已复制"];', info)

        log_center = (SOURCES / "LogCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("card.layer.borderWidth=0.6;HostSetLayerBorderColor(card,HostBorder());", log_center)
        self.assertIn('@"跳到最新末尾"', log_center)
        self.assertIn('[self showTransientPrompt:@"日志内容已复制"];', log_center)

        web = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostStyleGlassCard(self.statusCard,16);", web)
        self.assertIn('@"网页操作"', web)
        self.assertIn('@"复制当前网页地址"', web)

        feed = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("self.poster.layer.borderWidth=0.6;HostSetLayerBorderColor(self.poster,HostBorder());", feed)
        self.assertIn("self.contentView.layer.borderWidth=0.6;HostSetLayerBorderColor(self.contentView,HostBorder());", feed)


if __name__ == "__main__":
    unittest.main()
