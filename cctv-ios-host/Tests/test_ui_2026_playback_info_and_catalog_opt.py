import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_VC = "\n".join((p.read_text(encoding="utf-8").split("\n- (BOOL)sessionHasContent;", 1)[0] if p.name.endswith(".h") else p.read_text(encoding="utf-8")) for p in ([ROOT / "Sources" / "RootViewController_Internal.h", *sorted((ROOT / "Sources").glob("RootViewController*.m"))]))
INFO_H = (ROOT / "Sources" / "PlaybackInfoViewController.h").read_text(encoding="utf-8")
INFO_M = (ROOT / "Sources" / "PlaybackInfoViewController.m").read_text(encoding="utf-8")


class PlaybackInfoAndCatalogOptimizationTests(unittest.TestCase):
    def test_playback_info_supports_sections_summary_and_autorefresh(self):
        self.assertIn("sectionsProvider", INFO_H)
        self.assertIn("summaryProvider", INFO_H)
        self.assertIn("autoRefreshInterval", INFO_H)
        self.assertIn("buildSummaryHeaderView", INFO_M)
        self.assertIn("startAutoRefreshTimer", INFO_M)
        self.assertIn("stopAutoRefreshTimer", INFO_M)
        # Ensure no quality scoring system is present per user instruction
        self.assertNotIn("画质评分", INFO_M)
        self.assertNotIn("画质评分", ROOT_VC)

    def test_stream_metrics_collect_across_all_three_engines(self):
        self.assertIn("collectLiveStreamMetrics", ROOT_VC)
        self.assertIn("indicatedBitrate", ROOT_VC)
        self.assertIn("nominalFrameRate", ROOT_VC)
        self.assertIn("numberOfDroppedVideoFrames", ROOT_VC)
        self.assertIn("cicadaAdapter:(id)adapter didUpdateVideoSize:", ROOT_VC)
        self.assertIn("cicadaAdapter:(id)adapter didUpdateDownloadSpeed:", ROOT_VC)
        self.assertIn("playbackQualityBadgeBtn", ROOT_VC)
        self.assertIn('player.control.info', ROOT_VC)
        self.assertIn("流媒体画质参数", ROOT_VC)
        self.assertIn("播放与缓冲状态", ROOT_VC)
        self.assertIn("线路与节点诊断", ROOT_VC)

    def test_catalog_partial_reload_grid_epg_and_multidim_search(self):
        self.assertIn("reloadVisibleCatalogItemForChannelID:", ROOT_VC)
        self.assertIn("loadEPGForVisibleGridItems", ROOT_VC)
        self.assertIn("scrollViewDidEndDecelerating:", ROOT_VC)
        self.assertIn("sourceCountForChannel:", ROOT_VC)
        self.assertIn("channelSupportsCatchup:", ROOT_VC)
        self.assertIn("回看", ROOT_VC)
        self.assertIn("canonicalStationIDForChannel:", ROOT_VC)
        self.assertIn("self.epgCache[cid]", ROOT_VC)


if __name__ == "__main__":
    unittest.main()
