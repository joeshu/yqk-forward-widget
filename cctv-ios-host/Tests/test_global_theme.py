from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GlobalThemeContracts(unittest.TestCase):
    def test_theme_palette_has_persisted_system_light_and_dark_styles(self):
        theme = (ROOT / "Sources/HostTheme.h").read_text(encoding="utf-8")
        settings = (ROOT / "Sources/SettingsViewController.m").read_text(encoding="utf-8")
        app = (ROOT / "Sources/AppDelegate.m").read_text(encoding="utf-8")
        root = (ROOT / "Sources/RootViewController.m").read_text(encoding="utf-8")

        self.assertIn('HostDarkThemePreferenceKey = @"hostDarkTheme"', theme)
        self.assertIn('HostThemeModePreferenceKey = @"hostThemeMode"', theme)
        self.assertIn('@[@"system",@"light",@"dark"]', theme)
        self.assertIn("HostSystemInterfaceStyle()==UIUserInterfaceStyleDark", theme)
        self.assertIn("UIUserInterfaceStyleDark", theme)
        self.assertIn("UIUserInterfaceStyleLight", theme)
        self.assertIn('initWithItems:@[@"系统",@"浅色",@"深色"]', settings)
        self.assertIn("setBool:dark forKey:HostDarkThemePreferenceKey", settings)
        self.assertIn("window.overrideUserInterfaceStyle=HostSelectedInterfaceStyle()", settings)
        self.assertIn("HostSelectedInterfaceStyle()", app)
        self.assertIn("HostThemeModePreferenceKey", root)

    def test_global_glass_surfaces_and_reduced_motion_are_shared(self):
        theme = (ROOT / "Sources/HostTheme.h").read_text(encoding="utf-8")
        theme_impl = (ROOT / "Sources/HostTheme.m").read_text(encoding="utf-8")
        backdrop = (ROOT / "Sources/HostGlassBackdropView.m").read_text(encoding="utf-8")
        app = (ROOT / "Sources/AppDelegate.m").read_text(encoding="utf-8")
        root = (ROOT / "Sources/RootViewController.m").read_text(encoding="utf-8")
        media = (ROOT / "Sources/MediaBrowserViewController.m").read_text(encoding="utf-8")

        self.assertIn("HostInstallGlassBackdrop(self.window)", app)
        self.assertIn("HostStyleGlassCard(cell.contentView,9)", root)
        self.assertIn("HostStyleGlassCard(self.contentView,10)", media)
        self.assertIn("HostAnimateSelection", theme)
        self.assertIn("UIAccessibilityIsReduceMotionEnabled()", theme)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection", root)
        self.assertIn("HostRefreshAppearanceLayers(self.view.window)", root)
        self.assertIn("- (void)layoutSubviews", backdrop)
        self.assertIn("self.baseGradient.frame=bounds", backdrop)
        self.assertNotIn("CAConstraint", theme)
        self.assertIn("extern char HostAppearanceRefreshAssociationKey", theme)
        self.assertIn("char HostAppearanceRefreshAssociationKey", theme_impl)

    def test_primary_pages_use_shared_dynamic_palette(self):
        pages = (
            "RootViewController.m",
            "MediaBrowserViewController.m",
            "MediaPlaybackViewController.m",
            "MediaEpisodeSelectionViewController.m",
            "ServicesViewController.m",
            "PluginViewController.m",
            "ConfigCenterViewController.m",
            "SettingsViewController.m",
            "EPGViewController.m",
            "LogCenterViewController.m",
            "ServiceEditorViewController.m",
        )
        for name in pages:
            source = (ROOT / "Sources" / name).read_text(encoding="utf-8")
            with self.subTest(page=name):
                self.assertIn('#import "HostTheme.h"', source)
                self.assertIn("HostBackground()", source)

        services = (ROOT / "Sources/ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostSuccessSurface()", services)

    def test_video_canvas_remains_black_in_both_themes(self):
        playback = (ROOT / "Sources/MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.videoView.backgroundColor=UIColor.blackColor", playback)


if __name__ == "__main__":
    unittest.main()
