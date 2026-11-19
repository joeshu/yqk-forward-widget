import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round19CCTVSubpagesAndMenusRefactorTests(unittest.TestCase):
    def test_01_cctv_inline_panels_and_grouped_submenus(self):
        root_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        cat_m = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")

        # CCTVPlaybackListPanelController card specular border, leading accent bar, and semantic pill badge
        panel = root_m.split("@implementation CCTVPlaybackListPanelController", 1)[1].split("@end", 1)[0]
        self.assertIn("specular.tag=8901;", panel)
        self.assertIn("accentBar.tag=8902;", panel)
        self.assertIn('@"cctv.panel.badge"', panel)
        self.assertIn("HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2)", panel)

        # Inline grouped catalogMenu & channel context menu
        self.assertIn('@"channel.catalog.section.current"', cat_m)
        self.assertIn('@"channel.catalog.section.browse"', cat_m)
        self.assertIn('@"channel.catalog.section.library"', cat_m)
        self.assertIn('@"channel.catalog.section.maintenance"', cat_m)
        self.assertIn("UIMenuOptionsDisplayInline", cat_m)
        self.assertIn("✓ SDK 自动选线（推荐 · 智能调度）", cat_m)
        self.assertIn("NSString *modeTag = CCTVRouteRequiresSDK(r)", cat_m)
        self.assertIn("NSString *sheetMessage = [NSString stringWithFormat:@\"线路：%@ · %@%@\"", play_m)
        self.assertIn("时移 / 回看 · 实时直播", play_m)

    def test_02_epg_view_controller_dual_mode_inline_toolbar_and_row_badges(self):
        epg_m = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn('@"epg.inline.toolbar"', epg_m)
        self.assertIn('@"epg.inline.live"', epg_m)
        self.assertIn('@"epg.inline.7days"', epg_m)
        self.assertIn('@"epg.inline.return-live"', epg_m)
        self.assertIn('@"epg.inline.filter"', epg_m)
        self.assertIn("- (void)refreshInlineActionBar", epg_m)
        self.assertIn("epgSpecular.tag = 9103;", epg_m)
        self.assertIn("epgAccentBar.tag = 9104;", epg_m)
        self.assertIn('@"epg.row.status.badge"', epg_m)

    def test_03_playback_info_telemetry_dashboard_and_live_refresh_toggle(self):
        info_m = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn('@"playback.info.summary-card"', info_m)
        self.assertIn('@"playback.info.live-toggle"', info_m)
        self.assertIn('@"playback.info.refresh"', info_m)
        self.assertIn("- (void)toggleAutoRefreshPause", info_m)
        self.assertIn("- (void)updateLiveRefreshToggleAppearance", info_m)
        self.assertIn("BOOL isAlertValue =", info_m)
        self.assertNotIn("画质评分", info_m)

    def test_04_log_center_stat_chips_accent_bar_and_floating_jump_bottom(self):
        log_m = (SOURCES / "LogCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn('@"diagnostic.logs.stats"', log_m)
        self.assertIn('@"diagnostic.logs.jump-bottom"', log_m)
        self.assertIn("- (void)handleStatChipTap:(UIButton *)sender", log_m)
        self.assertIn("- (void)updateStatChipsWithTotal:", log_m)
        self.assertIn("@property(nonatomic,strong) UIView *accentBar;", log_m)


if __name__ == "__main__":
    unittest.main()
