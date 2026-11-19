import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class Round27ResourcePerfLayoutVisualPolishTests(unittest.TestCase):
    def test_config_center_row_height_cache_and_attributed_reset(self):
        src = read_source("ConfigCenterViewController.m")
        self.assertIn("rowHeightCache", src)
        self.assertIn("[self.rowHeightCache removeAllObjects];", src)
        self.assertIn("NSNumber *cached=[self.rowHeightCache objectForKey:cacheKey];", src)
        self.assertIn("else{c.detailTextLabel.attributedText=nil;}", src)

    def test_tvbox_catalog_auto_layout_header_and_pull_to_refresh(self):
        src = read_source("TVBoxCatalogViewController.m")
        self.assertIn("- (void)updateHeaderLayoutIfNeeded", src)
        self.assertIn("systemLayoutSizeFittingSize:target", src)
        self.assertIn("self.summaryLabel.adjustsFontForContentSizeCategory=YES;", src)
        self.assertIn("- (void)pullRefreshCatalog:(UIRefreshControl *)sender", src)
        self.assertIn("self.refreshControl=rc;", src)

    def test_plugin_view_controller_card_theme_refresh_and_context_menu(self):
        src = read_source("PluginViewController.m")
        self.assertIn("UIContextMenuInteractionDelegate", src)
        self.assertIn("cardViews", src)
        self.assertIn("for(UIView *c in self.cardViews){if(c.superview)HostStyleGlassCard(c,18);}", src)
        self.assertIn("contextMenuInteraction:", src)
        self.assertIn("复制播放列表地址", src)

    def test_service_editor_live_port_validation_and_footer_sync(self):
        src = read_source("ServiceEditorViewController.m")
        self.assertIn("- (void)portFieldChanged;", src)
        self.assertIn("addTarget:self action:@selector(portFieldChanged)", src)
        m = re.search(r"- \(void\)portFieldChanged \{.*?\n\}", src, re.DOTALL)
        self.assertIsNotNone(m)
        body = m.group(0)
        self.assertIn("UIColor.systemRedColor", body)
        self.assertIn("UIColor.systemOrangeColor", body)
        self.assertIn("[self refreshSection0FooterCache];", body)


if __name__ == "__main__":
    unittest.main()
