import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round24ResourceSubpagesDeepAuditTests(unittest.TestCase):
    def test_01_config_center_batch_probe_get_fallback_and_context_destructive_actions(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(cc.count("status==405||status==501"), 2)
        self.assertGreaterEqual(cc.count("UIMenuElementAttributesDestructive"), 4)
        self.assertIn('[self showResourceToast:@"资源概览摘要已复制"];', cc)

    def test_02_tvbox_catalog_filter_cache_theme_sync_accent_bar_and_prompt(self):
        tv = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        for token in (
            "- (void)rebuildFilteredCatalogCache",
            "self.cachedFilteredSites",
            "self.cachedFilteredLives",
            "self.headerCardView",
            "- (void)showTransientPrompt:(NSString *)prompt",
            "- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection",
            "accentBar.tag=9201;",
        ):
            self.assertIn(token, tv)

    def test_03_plugin_resource_detail_hero_card_refresh_control_and_trait_sync(self):
        plug = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        for token in (
            '@"plugin.detail.hero-card"',
            "- (void)buildHeroHeaderView",
            "- (void)updateHeroHeaderView",
            "- (void)handlePullRefresh",
            "UIRefreshControl",
            "- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection",
        ):
            self.assertIn(token, plug)

    def test_04_plugin_run_history_destructive_clear_refresh_spring_and_accent_bar(self):
        hist = (SOURCES / "PluginRunHistoryViewController.m").read_text(encoding="utf-8")
        for token in (
            "clear.attributes=UIMenuElementAttributesDestructive;",
            "UIRefreshControl",
            "didHighlightRowAtIndexPath:",
            "bar.tag=9301;",
            "- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection",
        ):
            self.assertIn(token, hist)

    def test_05_services_version_nscache_and_trait_sync(self):
        svc = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("static NSCache<NSString *,NSString *> *versionCache=nil;", svc)
        self.assertIn("[versionCache setObject:", svc)
        self.assertIn("- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection", svc)


if __name__ == "__main__":
    unittest.main()
