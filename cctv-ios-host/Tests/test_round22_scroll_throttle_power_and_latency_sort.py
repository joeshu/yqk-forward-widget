import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round22ScrollThrottlePowerAndLatencySortTests(unittest.TestCase):
    def test_01_list_and_grid_defer_epg_and_telemetry_probes_during_scroll(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        self.assertIn("if (!t.isDragging && !t.isDecelerating) [self probeTelemetryForChannel:ch];", cat)
        self.assertIn("if (!self.epgCache[cid] && !t.isDragging && !t.isDecelerating) [self loadEPGForChannel:cid channel:ch section:ip];", cat)
        self.assertIn("if(!collectionView.isDragging && !collectionView.isDecelerating)[self probeTelemetryForChannel:ch];", cat)

    def test_02_live_quality_badge_skips_inactive_background_and_non_live_tabs(self):
        sm = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        self.assertIn(
            "if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.activeTab >= 2) return;",
            sm,
        )
        self.assertIn("if(realFrame && CCTVPreviewImageHasValidVideoContent(realFrame))", sm)

    def test_03_single_active_catalog_reload_and_weak_idle_dispatch(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        pb = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        sm = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        self.assertIn("- (void)reloadActiveCatalogView", cat)
        self.assertIn("[self reloadActiveCatalogView];", pb)
        self.assertIn("__weak typeof(self) weakIdleSelf=self;", pb)
        self.assertNotIn("[self.table reloadData];[self.channelGrid reloadData];", sm)

    def test_04_latency_sort_mode_adjacent_scroll_sync_and_catchup_empty_copy(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("if(self.channelSortMode==2)", cat)
        self.assertIn('@"channel.catalog.sort"', cat)
        self.assertIn("w.channelSortMode=(w.channelSortMode+1)%3;", cat)
        self.assertIn("if(self.channelSortMode<0||self.channelSortMode>2)self.channelSortMode=0;", root)
        self.assertIn("当前分组下暂无支持回看的频道", cat)


if __name__ == "__main__":
    unittest.main()
