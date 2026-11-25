"""Contracts for Phase 3 incremental refresh on history and recent channels."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class HistoryIncrementalContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        cls.start = cls.source.index("@interface MediaWatchHistoryViewController")
        cls.end = cls.source.index("@end", cls.source.index("@implementation MediaWatchHistoryViewController", cls.start))
        cls.block = cls.source[cls.start:cls.end]

    def test_single_history_removal_uses_stable_key_diff_and_batches(self):
        self.assertIn('#import "HostListDiffHelper.h"', self.source)
        self.assertIn("- (void)applyHistoryEntriesIncremental", self.block)
        helper = self.block[self.block.index("- (void)applyHistoryEntriesIncremental"):]
        for token in ("MediaPlaybackStateStore.watchHistory", 'entry[@"key"]', "HostListDiffHelper diffFromOld:", "performBatchUpdates:", "deleteRowsAtIndexPaths:", "insertRowsAtIndexPaths:", "moveRowAtIndexPath:", "reloadRowsAtIndexPaths:"):
            self.assertIn(token, helper)
        self.assertIn("if(!tableView.window)", helper)
        self.assertIn("[tableView reloadData]", helper)
        self.assertGreaterEqual(self.block.count("applyHistoryEntriesIncremental]"), 2)
        self.assertIn("media.history.progress", self.block)


class RecentChannelIncrementalContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")

    def test_recent_remove_is_narrowly_guarded_and_batched(self):
        self.assertIn('#import "HostListDiffHelper.h"', self.source)
        self.assertIn("BOOL recentScope=owner.recentsOnly", self.source)
        self.assertIn("BOOL canDiff=recentScope&&!owner.gridMode&&!owner.query.length&&!owner.catchupOnlyFilter;", self.source)
        self.assertIn("objc_setAssociatedObject(owner,&CCTVCatalogIncrementalRefreshKey,@(canDiff)", self.source)
        self.assertIn("[owner applyFilter];", self.source)
        start = self.source.index("- (void)applyFilter {")
        end = self.source.index("- (void)rememberChannel:", start)
        block = self.source[start:end]
        for token in ("oldShown", "HostListDiffHelper diffFromOld:", "performBatchUpdates:", "deleteRowsAtIndexPaths:", "insertRowsAtIndexPaths:", "moveRowAtIndexPath:", "reloadRowsAtIndexPaths:"):
            self.assertIn(token, block)
        self.assertIn("if(incremental&&!self.gridMode&&self.table.window)", block)
        self.assertIn("else [self.table reloadData]", block)
        self.assertIn('return cid.length?cid:', block)

    def test_other_filter_mutations_keep_full_reload_path(self):
        self.assertIn("- (void)applyFilter {", self.source)
        self.assertIn("objc_getAssociatedObject(self,&CCTVCatalogIncrementalRefreshKey)", self.source)
        self.assertIn("[owner applyFilter];", self.source)


if __name__ == "__main__":
    unittest.main()
