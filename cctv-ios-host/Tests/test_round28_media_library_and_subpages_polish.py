import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestRound28MediaLibraryAndSubpagesPolish(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_media_browser_subpages_weak_self_keyboard_and_trait_sync(self):
        src = self._read("Sources/MediaBrowserViewController.m")

        # confirmClearFavorites and confirmClearHistory use weakSelf
        fav_idx = src.index("- (void)confirmClearFavorites {")
        fav_end = src.index("- (NSInteger)tableView:", fav_idx)
        fav_body = src[fav_idx:fav_end]
        self.assertIn("__weak typeof(self) weakSelf=self;", fav_body)
        self.assertIn("MediaFavoritesViewController *owner=weakSelf;", fav_body)

        hist_idx = src.index("- (void)confirmClearHistory {")
        hist_end = src.index("@end", hist_idx)
        hist_body = src[hist_idx:hist_end]
        self.assertIn("__weak typeof(self) weakSelf=self;", hist_body)
        self.assertIn("MediaWatchHistoryViewController *owner=weakSelf;", hist_body)

        # keyboardDismissMode on Favorites, WatchHistory, HomeConfiguration
        self.assertGreaterEqual(
            src.count("self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;"),
            4,
        )

        # MediaHomeConfigurationViewController theme + bar item sync
        cfg_idx = src.index("@implementation MediaHomeConfigurationViewController")
        cfg_end = src.index("@end", cfg_idx)
        cfg_body = src[cfg_idx:cfg_end]
        self.assertIn("self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();", cfg_body)
        self.assertIn("self.view.overrideUserInterfaceStyle=self.overrideUserInterfaceStyle;", cfg_body)
        self.assertIn("[self updateEpisodeStyleBarItem];[self.tableView reloadData];", cfg_body)
        self.assertIn("traitCollectionDidChange:", cfg_body)

        # All 5 subpage classes + main class have traitCollectionDidChange:
        self.assertGreaterEqual(src.count("hasDifferentColorAppearanceComparedToTraitCollection:"), 6)

    def test_episode_selection_context_menu_keyboard_and_trait_sync(self):
        src = self._read("Sources/MediaEpisodeSelectionViewController.m")
        self.assertIn("<UIContextMenuInteractionDelegate>", src)
        self.assertIn("self.scrollView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;", src)
        self.assertIn("[[UIContextMenuInteraction alloc] initWithDelegate:self]", src)
        self.assertIn("contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:", src)
        self.assertIn("立即播放此集", src)
        self.assertIn("复制分集名称", src)
        self.assertIn("traitCollectionDidChange:", src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)

    def test_media_web_view_dynamic_menu_transient_prompt_and_trait_sync(self):
        src = self._read("Sources/MediaWebViewController.m")
        self.assertIn("@property(nonatomic) NSUInteger promptGeneration;", src)
        self.assertIn("- (void)showTransientPrompt:(NSString *)message;", src)
        self.assertIn("UIDeferredMenuElement elementWithUncachedProvider:", src)
        self.assertIn("UIMenuElementAttributesDisabled", src)
        self.assertIn("[weakSelf showTransientPrompt:@\"已复制当前网页地址\"]", src)
        self.assertIn("[weakSelf showTransientPrompt:@\"本机配置页仅限应用内打开\"]", src)
        self.assertIn("self.web.scrollView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;", src)
        self.assertIn("traitCollectionDidChange:", src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)

    def test_global_search_and_adaptation_monitor_trait_sync(self):
        search_src = self._read("Sources/MediaGlobalSearchViewController.m")
        self.assertIn("traitCollectionDidChange:", search_src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", search_src)

        mon_src = self._read("Sources/MediaAdaptationMonitor.m")
        self.assertIn("traitCollectionDidChange:", mon_src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", mon_src)


if __name__ == "__main__":
    unittest.main()
