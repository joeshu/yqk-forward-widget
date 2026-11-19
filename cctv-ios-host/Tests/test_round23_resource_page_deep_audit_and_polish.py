import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round23ResourcePageDeepAuditAndPolishTests(unittest.TestCase):
    def test_01_detail_summary_cache_populated_for_plugin_tvbox_and_subscription(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(cc.count("self.detailSummaryCache[cacheKey]="), 3)

    def test_02_row_more_menu_uses_inline_sections_and_destructive_remove_attribute(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        for token in (
            '@"resource.row.menu.primary"',
            '@"resource.row.menu.display"',
            '@"resource.row.menu.maintenance"',
            '@"resource.row.menu.order"',
            '@"resource.row.menu.danger"',
            "remove.attributes=UIMenuElementAttributesDestructive;",
        ):
            self.assertIn(token, cc)

    def test_03_interactive_empty_state_typo_fix_and_compact_header_tap_to_top(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertNotIn("移入资源", cc)
        self.assertIn("没有找到匹配的导入资源", cc)
        self.assertIn('@"resource.empty.view"', cc)
        self.assertIn('@"resource.empty.action"', cc)
        self.assertIn("- (void)handleEmptyActionTap", cc)
        self.assertIn("- (void)scrollToTopFromCompactHeader", cc)
        self.assertIn("- (void)showResourceToast:(NSString *)message", cc)

    def test_04_probe_single_profile_dedup_single_row_reload_and_get_range_fallback(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn('if([self.latencyResults[source][@"probing"] boolValue])return;', cc)
        self.assertIn("- (void)reloadVisibleRowForSource:(NSString *)source", cc)
        self.assertIn("status==405||status==501", cc)
        self.assertIn('@"bytes=0-0"', cc)

    def test_05_search_ime_debounce_latency_sort_and_trait_collection_sync(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("if(self.resourceSearchField.markedTextRange)return;", cc)
        self.assertIn('else if([self.sortMode isEqual:@"latency"])', cc)
        self.assertIn('@"测速最快优先"', cc)
        self.assertIn("- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection", cc)


if __name__ == "__main__":
    unittest.main()
