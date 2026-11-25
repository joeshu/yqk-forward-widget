import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round35PlaybackControlsRedesignTests(unittest.TestCase):
    def test_01_live_control_sheet_replaces_action_sheet_with_frosted_control_center(self):
        hdr = (SOURCES / "CCTVLiveControlSheetViewController.h").read_text(encoding="utf-8")
        impl = (SOURCES / "CCTVLiveControlSheetViewController.m").read_text(encoding="utf-8")
        pb = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")

        self.assertIn("@interface CCTVLiveControlSheetViewController : UIViewController", hdr)
        self.assertIn('- (void)reloadThemeAppearance;', hdr)
        self.assertIn('accessibilityIdentifier = @"cctv.live.control-sheet"', impl)
        self.assertIn("HostGlassBlur()", impl)
        self.assertIn("makeQuickTileWithTitle:", impl)
        self.assertIn("makeGroupedCardWithRows:", impl)
        self.assertIn("makeInlineSleepTimerRow", impl)
        self.assertIn("- (void)reloadThemeAppearance", impl)
        self.assertIn("- (void)traitCollectionDidChange:", impl)

        more = pb.split("- (void)showMorePlaybackActions {", 1)[1].split("\n- (void)beginPlaybackPriority", 1)[0]
        self.assertIn("CCTVLiveControlSheetViewController *sheet = [CCTVLiveControlSheetViewController new];", more)
        self.assertIn("sp.prefersGrabberVisible = YES;", more)
        self.assertIn("sp.preferredCornerRadius = 28.0;", more)
        self.assertNotIn("UIAlertControllerStyleActionSheet", more)

    def test_02_vod_playback_menu_has_aligned_sf_symbols_live_subtitles_and_clean_groups(self):
        mp = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8") + (SOURCES / "MediaPlaybackSettingsCoordinator.m").read_text(encoding="utf-8")
        for token in (
            'UIImage *icon=[UIImage systemImageNamed:isAudio?@"waveform":@"captions.bubble"];',
            'menuWithTitle:@"播放速度" image:[UIImage systemImageNamed:@"gauge.with.needle"]',
            'menuWithTitle:@"画面比例" image:[UIImage systemImageNamed:@"aspectratio"]',
            'menuWithTitle:@"片头片尾跳过" image:[UIImage systemImageNamed:@"forward.end.alt"]',
            'menuWithTitle:@"解码模式" image:[UIImage systemImageNamed:@"cpu"]',
            'danmaku.subtitle=@"当前视频未提供弹幕轨道";',
            'identifier:@"media.playback.menu.av" options:UIMenuOptionsDisplayInline',
            'identifier:@"media.playback.menu.controls" options:UIMenuOptionsDisplayInline',
            'identifier:@"media.playback.menu.prefs" options:UIMenuOptionsDisplayInline',
            'identifier:@"media.playback.menu.diag" options:UIMenuOptionsDisplayInline',
            'autoNextAction.state=autoNext?UIMenuElementStateOn:UIMenuElementStateOff;',
            'awake.state=keepAwake?UIMenuElementStateOn:UIMenuElementStateOff;',
            'act.state=(self.mediaSleepMinutes==mins)?UIMenuElementStateOn:UIMenuElementStateOff;',
        ):
            self.assertIn(token, mp)

    def test_03_all_secondary_menus_use_aligned_icons_native_state_and_inline_sections(self):
        tv = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn('json.image=[UIImage systemImageNamed:@"square.and.arrow.up"];', tv)
        self.assertIn('zip.image=[UIImage systemImageNamed:@"archivebox"];', tv)
        self.assertIn('bulk.image=[UIImage systemImageNamed:@"square.and.arrow.down"];', tv)
        self.assertIn('remove.image=[UIImage systemImageNamed:@"trash"];', tv)
        self.assertIn('identifier:@"tvbox.catalog.menu.export" options:UIMenuOptionsDisplayInline', tv)

        epg = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn('all.state=(self.programFilterMode==0)?UIMenuElementStateOn:UIMenuElementStateOff;', epg)
        self.assertIn('identifier:@"epg.menu.filter" options:UIMenuOptionsDisplayInline', epg)

        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn('@{@"id":@"latency",@"name":@"测速最快优先",@"icon":@"gauge.with.needle"}', cc)
        self.assertIn('action.state=[identifier isEqual:self.sortMode]?UIMenuElementStateOn:UIMenuElementStateOff;', cc)

        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        self.assertIn('castCenter.subtitle=@"AirPlay / 局域网电视";', cat)
        self.assertIn('catchupFilter.state=self.catchupOnlyFilter?UIMenuElementStateOn:UIMenuElementStateOff;', cat)

        mb = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn('toggleBadge.subtitle=badgeOn?@"已开启":@"已关闭";', mb)
        self.assertIn('toggleExpand.subtitle=autoExpandOn?@"已开启":@"已关闭";', mb)


if __name__ == "__main__":
    unittest.main()
