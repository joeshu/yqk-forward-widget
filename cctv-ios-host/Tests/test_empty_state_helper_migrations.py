from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
S = ROOT / "Sources"

class EmptyStateHelperMigrationContracts(unittest.TestCase):
    def assertUsesHelper(self, file, method_start, marker, expected_call, identifier):
        text=(S/file).read_text(encoding="utf-8")
        start=text.index(method_start)
        body=text[start:text.index(marker,start)]
        self.assertIn(expected_call,body)
        self.assertIn(f'accessibilityIdentifier=@"{identifier}"',body)
        self.assertNotIn("UILabel *empty=",body)

    def test_favorites_and_watch_history_use_shared_helper(self):
        src=(S/"MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:@"还没有收藏影视" subtitle:@"在影片详情页点按「收藏」即可保存" symbol:@"heart"',src)
        self.assertIn('accessibilityIdentifier=@"media-favorites-empty"',src)
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:@"还没有观看记录" subtitle:@"播放过的影片会保存在这里" symbol:@"clock"',src)
        self.assertIn('accessibilityIdentifier=@"media-history-empty"',src)

    def test_tvbox_and_global_search_use_shared_helper(self):
        tv=(S/"TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:emptyTitle subtitle:emptySubtitle symbol:@"rectangle.stack"',tv)
        self.assertIn('accessibilityIdentifier=@"tvbox-catalog-empty"',tv)
        gs=(S/"MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:@"尚未导入影视资源" subtitle:@"请先到资源页导入影视包，再回来搜索" symbol:@"tray"',gs)
        self.assertIn('accessibilityIdentifier=@"media-global-search-empty"',gs)

    def test_shared_helper_owns_dynamic_type_and_voiceover(self):
        h=(S/"HostEmptyStateView.h").read_text(encoding="utf-8")
        m=(S/"HostEmptyStateView.m").read_text(encoding="utf-8")
        self.assertIn("adjustsFontForContentSizeCategory",m)
        self.assertIn("isAccessibilityElement",m)
        self.assertIn("UIAccessibilityTrait",m)
        self.assertIn("reloadThemeAppearance",h)

    def test_global_search_preserves_no_sources_gate(self):
        gs=(S/"MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        body=gs[gs.index("- (void)updateEmptyState") :]
        self.assertIn("if(self.sources.count){self.tableView.backgroundView=nil;return;}",body)

if __name__ == "__main__": unittest.main()
