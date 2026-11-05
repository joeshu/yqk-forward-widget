import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PALETTE = ROOT / "Sources/HostThemePalette.m"
PALETTE_HEADER = ROOT / "Sources/HostThemePalette.h"
THEME = ROOT / "Sources/HostTheme.h"
SETTINGS = ROOT / "Sources/SettingsViewController.m"
BACKUP = ROOT / "Sources/HostBackup.m"

REQUIRED_ROLES = (
    "background", "card", "raised", "text", "secondary", "accent",
    "onAccent", "muted", "glass", "neutral", "success",
)


def parse_themes():
    text = PALETTE.read_text(encoding="utf-8")
    blocks = re.split(r'@"id":@"', text)[1:]
    themes = []
    for block in blocks:
        identifier = block.split('"', 1)[0]
        pairs = dict(re.findall(r'@"(\w+)":@"([^"]+)"', block))
        dark_match = re.search(r'@"dark":@(YES|NO)', block)
        themes.append({
            "id": identifier,
            "name": pairs.get("name", ""),
            "tagline": pairs.get("tagline", ""),
            "dark": dark_match.group(1) == "YES" if dark_match else None,
            "colors": pairs,
        })
    return themes


def luminance(hex_color):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

    def linear(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = linear(r), linear(g), linear(b)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    lo, hi = min(la, lb), max(la, lb)
    return (hi + 0.05) / (lo + 0.05)


class HostThemePaletteContracts(unittest.TestCase):
    def test_six_themes_with_two_light_and_four_dark(self):
        themes = parse_themes()
        self.assertEqual(len(themes), 6)
        identifiers = [t["id"] for t in themes]
        self.assertEqual(len(set(identifiers)), 6)
        self.assertEqual(sum(1 for t in themes if t["dark"]), 4)
        self.assertEqual(sum(1 for t in themes if t["dark"] is False), 2)
        for theme in themes:
            with self.subTest(theme=theme["id"]):
                self.assertTrue(theme["name"])
                self.assertTrue(theme["tagline"])
                self.assertIsNotNone(theme["dark"])
                for role in REQUIRED_ROLES:
                    self.assertIn(role, theme["colors"])
        self.assertIn("midnight", identifiers)
        self.assertIn("daylight", identifiers)
        self.assertIn("snow", identifiers)
        midnight = next(t for t in themes if t["id"] == "midnight")
        self.assertTrue(midnight["dark"])

    def test_palette_contrast_meets_accessibility(self):
        # 主文字 AAA（>=7），次文字 AA（>=4.5），强调色 AA（>=4.5），
        # 强调色上文字至少大字 AA（>=3）；除沿用现有品牌红的午夜影院外，
        # 其余五套强调色上文字也达到 AA（>=4.5）。
        for theme in parse_themes():
            colors = theme["colors"]
            with self.subTest(theme=theme["id"]):
                self.assertGreaterEqual(contrast(colors["text"], colors["background"]), 7.0)
                self.assertGreaterEqual(contrast(colors["secondary"], colors["background"]), 4.5)
                self.assertGreaterEqual(contrast(colors["accent"], colors["background"]), 4.5)
                self.assertGreaterEqual(contrast(colors["onAccent"], colors["accent"]), 3.0)
                if theme["id"] != "midnight":
                    self.assertGreaterEqual(contrast(colors["onAccent"], colors["accent"]), 4.5)

    def test_theme_engine_hooks(self):
        header = PALETTE_HEADER.read_text(encoding="utf-8")
        theme = THEME.read_text(encoding="utf-8")
        self.assertIn("HostThemePaletteIdentifierPreferenceKey", header)
        self.assertIn('@"cctv.themeIdentifier.v1"', header)
        self.assertIn("+ (NSArray<HostThemePalette *> *)allThemes;", header)
        self.assertIn("paletteForIdentifier:", header)
        self.assertIn("effectivePaletteForDark:", header)
        self.assertIn("currentPaletteIdentifier", header)
        self.assertIn("defaultDarkPalette", header)
        self.assertIn("defaultLightPalette", header)
        self.assertIn('#import "HostThemePalette.h"', theme)
        self.assertIn("HostApplyThemeToWindow", theme)
        for role in ("background", "card", "raisedSurface", "text", "secondaryText",
                     "accent", "onAccent", "mutedText", "glassTint", "border",
                     "separator", "neutralSurface", "selectedSurface",
                     "highlightedSurface", "successSurface"):
            self.assertIn(f"effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].{role}", theme)

    def test_system_light_dark_modes_preserved(self):
        theme = THEME.read_text(encoding="utf-8")
        settings = SETTINGS.read_text(encoding="utf-8")
        self.assertIn('HostDarkThemePreferenceKey = @"hostDarkTheme"', theme)
        self.assertIn('HostThemeModePreferenceKey = @"hostThemeMode"', theme)
        self.assertIn('@[@"system",@"light",@"dark"]', theme)
        self.assertIn('initWithItems:@[@"系统",@"浅色",@"深色"]', settings)

    def test_settings_offers_theme_palette_picker(self):
        settings = SETTINGS.read_text(encoding="utf-8")
        self.assertIn('@\"action\":@\"themePalette\"', settings)
        self.assertIn("presentThemePicker:", settings)
        self.assertIn("HostThemePalette setCurrentPaletteIdentifier:", settings)
        self.assertIn("HostThemePalette currentPalette", settings)
        self.assertIn("HostApplyThemeToWindow(window)", settings)
        self.assertIn("6 套主题", settings)

    def test_backup_covers_theme_identifier_and_mode(self):
        backup = BACKUP.read_text(encoding="utf-8")
        self.assertIn('@\"hostThemeMode\"', backup)
        self.assertIn('@\"cctv.themeIdentifier.v1\"', backup)
        identifiers = [t["id"] for t in parse_themes()]
        for identifier in identifiers:
            self.assertIn(f'@"{identifier}"', backup)


if __name__ == "__main__":
    unittest.main()
