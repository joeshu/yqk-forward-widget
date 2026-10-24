from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GlobalThemeContracts(unittest.TestCase):
    def test_theme_palette_has_persisted_dark_and_light_styles(self):
        theme = (ROOT / "Sources/HostTheme.h").read_text(encoding="utf-8")
        settings = (ROOT / "Sources/SettingsViewController.m").read_text(encoding="utf-8")
        app = (ROOT / "Sources/AppDelegate.m").read_text(encoding="utf-8")
        root = (ROOT / "Sources/RootViewController.m").read_text(encoding="utf-8")

        self.assertIn('HostDarkThemePreferenceKey = @"hostDarkTheme"', theme)
        self.assertIn("UIUserInterfaceStyleDark", theme)
        self.assertIn("UIUserInterfaceStyleLight", theme)
        self.assertIn('initWithItems:@[@"黑色",@"白色"]', settings)
        self.assertIn("setBool:dark forKey:HostDarkThemePreferenceKey", settings)
        self.assertIn("window.overrideUserInterfaceStyle=dark?UIUserInterfaceStyleDark:UIUserInterfaceStyleLight", settings)
        self.assertIn("HostSelectedInterfaceStyle()", app)
        self.assertIn("window.overrideUserInterfaceStyle=value?UIUserInterfaceStyleDark:UIUserInterfaceStyleLight", root)

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
