import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round21CCTVAndChannelPerfStabilityTests(unittest.TestCase):
    def test_01_epg_cache_key_bug_fixed_across_catalog_and_subscriptions(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        subs = (SOURCES / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        self.assertNotIn('epgCache[ch[@"id"]?:@""][@"t"]', cat)
        self.assertNotIn('epgCache[ch[@"id"] ?: @""][@"t"]', subs)
        self.assertNotIn('epgCache[cid][@"t"]', subs)
        self.assertIn('epgCache[ch[@"id"]?:@""][@"now"]', cat)
        self.assertIn('epgCache[ch[@"id"] ?: @""][@"now"]', subs)
        self.assertIn('epgCache[cid][@"now"]', subs)

    def test_02_o1_channel_lookup_indexes_eliminate_quadratic_catchup_and_epg_scans(self):
        hdr = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        epg = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")
        for prop in (
            "catchupIndexByGroupKey",
            "catchupIndexByCanonical",
            "nativeIDIndexByName",
            "ensureChannelLookupIndexes",
        ):
            self.assertIn(prop, hdr)
            self.assertIn(prop, cat)
        self.assertIn("[self ensureChannelLookupIndexes];", epg)
        self.assertIn("self.nativeIDIndexByName", epg)
        self.assertNotIn("for (NSDictionary *cand in self.allChannels)", cat)

    def test_03_cached_catalog_fonts_single_view_reload_and_epg_pill_reuse(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        epg_vc = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (UIFont *)catalogCardTitleFont", cat)
        self.assertIn("- (UIFont *)catalogCardSubtitleFont", cat)
        self.assertIn("if (self.gridMode) [self.channelGrid reloadData];\n    else [self.table reloadData];", cat)
        self.assertIn("cell.accessoryView.tag == 9105", epg_vc)

    def test_04_functional_enhancements_adjacent_zap_catchup_filter_and_search_clear(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        for token in (
            "- (void)switchToAdjacentChannel:(NSInteger)delta",
            '@"channel.catalog.prev"',
            '@"channel.catalog.next"',
            '@"channel.catalog.catchup-only"',
            "self.catchupOnlyFilter",
            '@"清除搜索"',
            'indexOfObject:@"收藏"',
            '[w showRemoteTools:ch]',
        ):
            self.assertIn(token, cat)


if __name__ == "__main__":
    unittest.main()
