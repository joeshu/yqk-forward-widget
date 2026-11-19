import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round37DefaultLightThemePolishTests(unittest.TestCase):
    def test_01_default_theme_is_light_daylight_white(self):
        theme_h = (SOURCES / "HostTheme.h").read_text(encoding="utf-8")
        pal_h = (SOURCES / "HostThemePalette.h").read_text(encoding="utf-8")
        pal_m = (SOURCES / "HostThemePalette.m").read_text(encoding="utf-8")
        settings = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")

        self.assertIn('return @"light"; // Default to clean daylight white theme on first launch.', theme_h)
        self.assertIn('HostThemePaletteDefaultIdentifier = @"daylight";', pal_h)
        self.assertIn('+ (HostThemePalette *)defaultDarkPalette { return [self paletteForIdentifier:@"midnight"]; }', pal_m)
        self.assertIn('return [self paletteForIdentifier:self.currentPaletteIdentifier] ?: self.defaultLightPalette;', pal_m)
        self.assertIn('[HostThemePalette setCurrentPaletteIdentifier:HostThemePalette.defaultDarkPalette.identifier];', settings)
        self.assertIn('[HostThemePalette setCurrentPaletteIdentifier:HostThemePalette.defaultLightPalette.identifier];', settings)

    def test_02_light_mode_surfaces_and_adaptive_elements_refined(self):
        pal_m = (SOURCES / "HostThemePalette.m").read_text(encoding="utf-8")
        backdrop = (SOURCES / "HostGlassBackdropView.m").read_text(encoding="utf-8")
        ep_sel = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
        epg = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        settings = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")

        self.assertIn('@"card":@"#FFFFFF"', pal_m)
        self.assertIn('dark?0.16:0.06', backdrop)
        self.assertIn('dark?0.22:0.08', backdrop)
        self.assertNotIn("UIBlurEffectStyleDark", ep_sel)
        self.assertIn("HostRegisterGlassEffectView(self.backdropBlurView);", ep_sel)
        self.assertIn("epgSpecular.backgroundColor = HostIsDarkThemeSelected()", epg)
        self.assertIn("specular.backgroundColor=HostIsDarkThemeSelected()", root)
        self.assertIn('[HostGlassSheetSection sectionWithTitle:@"浅色主题（默认）" actions:lightActions]', settings)


if __name__ == "__main__":
    unittest.main()
