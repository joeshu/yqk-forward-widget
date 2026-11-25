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

    def test_picker_search_empty_migrated_to_shared_helper(self):
        # 阶段 C 续一：MediaSourcePicker 的搜索空态由手写 UILabel 迁移到
        # HostEmptyStateView。原文案来源（emptyMessageForQuery:）与触发逻辑
        # （!self.shown.count）保持不变，标识符 media-picker-empty 保留。
        src=(S/"MediaBrowserViewController.m").read_text(encoding="utf-8")
        start=src.index("@implementation MediaSourcePicker")
        end=src.index("@interface MediaDetailViewController",start)
        body=src[start:end]
        m=body[body.index("- (void)updateSearchResultsForSearchController:") :]
        head=m[:m.index("[self.tableView reloadData];")]
        self.assertIn("[MediaBrowserQueryBuilder emptyMessageForQuery:query]",head)
        self.assertIn("if(!self.shown.count)",head)
        self.assertIn(
            'HostEmptyStateView emptyStateViewWithTitle:[MediaBrowserQueryBuilder emptyMessageForQuery:query] subtitle:nil symbol:nil',
            head,
        )
        self.assertIn('accessibilityIdentifier=@"media-picker-empty"',head)
        self.assertNotIn("UILabel *empty=",head)

    def test_no_handwritten_empty_label_remains_in_scoped_pages(self):
        # 收藏/历史/全局搜索/TVBox 四类页面内不应再残留手写 UILabel 空态。
        for f in ("MediaBrowserViewController.m","MediaGlobalSearchViewController.m","TVBoxCatalogViewController.m"):
            self.assertNotIn("UILabel *empty=",(S/f).read_text(encoding="utf-8"))

    def test_scoped_empty_state_identifiers_are_distinct(self):
        src=(S/"MediaBrowserViewController.m").read_text(encoding="utf-8")
        for identifier in ("media-favorites-empty","media-history-empty","media-picker-empty"):
            self.assertEqual(src.count(f'accessibilityIdentifier=@"{identifier}"'),1,identifier)
        tv=(S/"TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertEqual(tv.count('accessibilityIdentifier=@"tvbox-catalog-empty"'),1)
        gs=(S/"MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        self.assertEqual(gs.count('accessibilityIdentifier=@"media-global-search-empty"'),1)

if __name__ == "__main__": unittest.main()
