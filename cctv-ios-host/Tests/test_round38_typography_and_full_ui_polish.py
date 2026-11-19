import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class Round38TypographyAndFullUIPolishTests(unittest.TestCase):
    def test_global_typography_stepped_down_one_size_cleanly(self):
        theme_h = read_source("HostTheme.h")
        self.assertIn("CGFloat refinedSize = MAX(9.5, size - 1.0);", theme_h)
        self.assertIn("CGFloat refinedSize = MAX(9.5, size - 0.75);", theme_h)
        self.assertIn("HostRoundedFont(16.5, UIFontWeightSemibold, nil)", theme_h)
        self.assertIn("HostRoundedFont(29, UIFontWeightBold, nil)", theme_h)
        self.assertIn("HostRoundedFont(12.5, UIFontWeightSemibold, UIFontTextStyleSubheadline)", theme_h)
        self.assertIn("[UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular]", theme_h)

        root_m = read_source("RootViewController.m")
        self.assertIn("NSInteger stepped=(offset<=0)?MAX(0,index-1):MIN((NSInteger)ordered.count-1,index+offset);", root_m)

    def test_glass_specular_rim_adapts_for_light_and_dark_themes(self):
        theme_h = read_source("HostTheme.h")
        self.assertGreaterEqual(theme_h.count("specularRim.colors=!HostIsDarkThemeSelected()"), 2)
        self.assertIn("[UIColor colorWithWhite:1 alpha:0.62].CGColor", theme_h)

    def test_settings_pickers_upgraded_to_glass_action_sheets(self):
        settings_m = read_source("SettingsViewController.m")
        for method in (
            "- (void)presentPlaybackRatePicker:(NSIndexPath *)ip",
            "- (void)presentVideoGravityPicker:(NSIndexPath *)ip",
            "- (void)presentPreferredQualityPicker:(NSIndexPath *)ip",
        ):
            start = settings_m.index(method)
            next_method = settings_m.index("\n- (", start + 10)
            body = settings_m[start:next_method]
            self.assertIn("HostGlassActionSheetViewController presentOn:self", body, msg=method)
            self.assertNotIn("UIAlertControllerStyleActionSheet", body, msg=method)

    def test_remaining_high_traffic_sheets_upgraded_to_glass_sheets(self):
        tvbox_m = read_source("TVBoxCatalogViewController.m")
        self.assertIn('#import "HostGlassActionSheetViewController.h"', tvbox_m)
        self.assertIn("HostGlassActionSheetViewController presentOn:self", tvbox_m)

        services_m = read_source("ServicesViewController.m")
        self.assertIn('#import "HostGlassActionSheetViewController.h"', services_m)
        self.assertIn("HostGlassActionSheetViewController presentOn:self", services_m)

        config_m = read_source("ConfigCenterViewController.m")
        self.assertIn('#import "HostGlassActionSheetViewController.h"', config_m)
        self.assertIn("HostGlassActionSheetViewController presentOn:self", config_m)

        stream_m = read_source("RootViewController+StreamMetrics.m")
        self.assertIn('#import "HostGlassActionSheetViewController.h"', stream_m)
        self.assertIn("HostGlassActionSheetViewController presentOn:self", stream_m)
        self.assertIn('@"同台跨源切换"', stream_m)
        self.assertIn('@"台标与遥测显示"', stream_m)

        subs_m = read_source("RootViewController+Subscriptions.m")
        self.assertIn('#import "HostGlassActionSheetViewController.h"', subs_m)
        self.assertGreaterEqual(subs_m.count("HostGlassActionSheetViewController presentOn:"), 5)

    def test_log_center_menu_uses_inline_sections_and_destructive_clear(self):
        log_m = read_source("LogCenterViewController.m")
        self.assertIn("clear.attributes=UIMenuElementAttributesDestructive;", log_m)
        self.assertIn("UIMenuOptionsDisplayInline children:@[copy,copyErrors]", log_m)
        self.assertIn("UIMenuOptionsDisplayInline children:@[clear]", log_m)


if __name__ == "__main__":
    unittest.main()
