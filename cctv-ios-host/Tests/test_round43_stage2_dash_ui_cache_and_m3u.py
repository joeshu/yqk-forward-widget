import collections
import pathlib
import struct
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGINS_DIR = ROOT / "Plugins"
SOURCES_DIR = ROOT / "Sources"
if str(PLUGINS_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGINS_DIR))

import host_dash
import host_media_runtime


def _mp4_box(box_type: bytes, payload: bytes) -> bytes:
    return struct.pack(">I4s", 8 + len(payload), box_type) + payload


def _build_sidx_v0(timescale: int, first_offset: int, entries: list[tuple[int, int]]) -> bytes:
    # version=0, flags=0, ref_id=1, timescale, earliest_pts=0, first_offset, reserved=0, count
    header = struct.pack(">I", 0) + struct.pack(">IIIIHH", 1, timescale, 0, first_offset, 0, len(entries))
    body = b"".join(
        struct.pack(">III", size & 0x7FFFFFFF, dur, 0x80000000)
        for size, dur in entries
    )
    return _mp4_box(b"sidx", header + body)


def _build_hev1_init_mp4() -> bytes:
    ftyp = _mp4_box(b"ftyp", b"iso5\x00\x00\x00\x01iso5dash")
    hvcc = _mp4_box(b"hvcC", b"\x01\x01\x60\x00\x00\x00\x90\x00")
    # VisualSampleEntry has 78 bytes of fixed header fields before child boxes (e.g. hvcC)
    hev1_entry = _mp4_box(b"hev1", b"\x00" * 78 + hvcc)
    # FullBox header (4 bytes version/flags) + entry_count (4 bytes) + entry
    stsd = _mp4_box(b"stsd", struct.pack(">II", 0, 1) + hev1_entry)
    stbl = _mp4_box(b"stbl", stsd)
    minf = _mp4_box(b"minf", stbl)
    mdia = _mp4_box(b"mdia", minf)
    trak = _mp4_box(b"trak", mdia)
    moov = _mp4_box(b"moov", trak)
    return ftyp + moov


class Round43Stage2AndP3Tests(unittest.TestCase):
    def test_dash_sidx_parser_and_segment_base_manifest(self):
        sidx_bytes = _build_sidx_v0(
            timescale=1000,
            first_offset=0,
            entries=[(50000, 4000), (60000, 4000)],
        )
        segs = host_dash.parse_sidx_segments(sidx_bytes, index_end=999)
        self.assertEqual(len(segs), 2)
        self.assertAlmostEqual(segs[0][0], 4.0)
        self.assertEqual(segs[0][1], "1000-50999")
        self.assertAlmostEqual(segs[1][0], 4.0)
        self.assertEqual(segs[1][1], "51000-110999")

        mpd = """<?xml version="1.0" encoding="utf-8"?>
        <MPD type="static" mediaPresentationDuration="PT8S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v1" bandwidth="2500000" width="1920" height="1080" codecs="hev1.1.6.L120.90">
                <BaseURL>https://cdn.example.com/movie.m4s</BaseURL>
                <SegmentBase indexRange="800-999">
                  <Initialization range="0-799"/>
                </SegmentBase>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        parsed = host_dash.parse_mpd(
            mpd.encode("utf-8"),
            "https://cdn.example.com/manifest.mpd",
            sidx_fetcher=lambda url, idx_range: sidx_bytes,
        )
        self.assertEqual(len(parsed["tracks"]), 1)
        rep = parsed["tracks"][0]
        self.assertEqual(rep["kind"], "video")
        self.assertEqual(rep["init_range"], "0-799")
        self.assertEqual(len(rep["segments"]), 2)

        class _StubRelay:
            def _same_origin(self, a, b):
                return True
            def register(self, url, headers, **kwargs):
                return "tok"
            def dash_track_url(self, session, track_id, base):
                return f"{base}/dash/{track_id}.m3u8"

        session = host_dash.DashSession(
            _StubRelay(),
            "https://cdn.example.com/manifest.mpd",
            {},
            "diag-1",
            "scope-1",
        )
        session.snapshot = parsed
        session.expires = 10**12

        master = session.playlist(None, "http://127.0.0.1:9999")
        self.assertIn('CODECS="hvc1.1.6.L120.90"', master)
        self.assertNotIn('CODECS="hev1.', master)

        media_m3u8 = session.playlist(rep["id"], "http://127.0.0.1:9999")
        self.assertIn('BYTERANGE="800@0"', media_m3u8)
        self.assertIn("#EXT-X-BYTERANGE:50000@1000", media_m3u8)
        self.assertIn("#EXT-X-BYTERANGE:60000@51000", media_m3u8)

    def test_dash_hev1_to_hvc1_binary_init_rewrite(self):
        raw_init = _build_hev1_init_mp4()
        self.assertIn(b"hev1", raw_init)
        self.assertNotIn(b"hvc1", raw_init)

        rewritten = host_dash.rewrite_hev1_to_hvc1_init(raw_init)
        self.assertEqual(len(rewritten), len(raw_init))
        self.assertIn(b"hvc1", rewritten)
        self.assertNotIn(b"hev1", rewritten)
        # Non-hev1 boxes remain untouched
        self.assertTrue(rewritten.startswith(raw_init[:16]))
        self.assertIn(b"hvcC", rewritten)

    def test_python_spider_lru_cache_bounds(self):
        spider = host_media_runtime.PythonSpider.__new__(host_media_runtime.PythonSpider)
        spider._vod_title_by_id = collections.OrderedDict()
        spider._episode_map = collections.OrderedDict()
        spider._last_detail_title = ""
        spider._meta_map_limit = 2048
        spider._record_vod_titles(
            {"list": [{"vod_id": f"vod-{i}", "vod_name": f"影视标题{i}"} for i in range(2300)]}
        )
        episodes = "#".join(f"第{i+1}集$ep-{i}" for i in range(2300))
        spider._record_detail_episodes({"vod_name": "测试剧集", "vod_play_url": episodes}, vid="vod-1")
        self.assertLessEqual(len(spider._vod_title_by_id), 2048)
        self.assertLessEqual(len(spider._episode_map), 2048)
        self.assertNotIn("vod-0", spider._vod_title_by_id)
        self.assertIn("vod-2299", spider._vod_title_by_id)
        self.assertNotIn("ep-0", spider._episode_map)
        self.assertIn("ep-2299", spider._episode_map)

    def test_stage2_ui_popover_detent_accessibility_and_headers(self):
        sheet_src = (SOURCES_DIR / "HostGlassActionSheetViewController.m").read_text(encoding="utf-8")
        self.assertIn("UIModalPresentationPopover", sheet_src)
        self.assertIn("customDetentWithIdentifier:@\"host.sheet.fit\"", sheet_src)

        live_sheet_src = (SOURCES_DIR / "CCTVLiveControlSheetViewController.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(live_sheet_src.count("isAccessibilityElement = YES"), 2)

        theme_h = (SOURCES_DIR / "HostTheme.h").read_text(encoding="utf-8")
        self.assertIn("HostSizeTableHeaderToFit(UITableView *tableView, CGFloat minHeight)", theme_h)

        for filename in (
            "ServicesViewController.m",
            "SubscriptionResourceViewController.m",
            "PluginResourceDetailViewController.m",
            "PlaybackInfoViewController.m",
            "LocalMediaViewController.m",
        ):
            src = (SOURCES_DIR / filename).read_text(encoding="utf-8")
            self.assertIn("HostSizeTableHeaderToFit(", src, msg=f"{filename} should use HostSizeTableHeaderToFit")

        services_src = (SOURCES_DIR / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertNotIn("checkmark.Power", services_src)
        self.assertIn("bolt.horizontal.circle.fill", services_src)

        browser_src = (SOURCES_DIR / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("UIInterfaceOrientationMaskAll", browser_src)

        episode_src = (SOURCES_DIR / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
        self.assertIn("UIInterfaceOrientationMaskAll", episode_src)

    def test_stage2_settings_jar_log_playback_and_m3u_contracts(self):
        settings_src = (SOURCES_DIR / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("SettingsRefreshDiskCacheStatsAsync", settings_src)
        self.assertIn("defaultDecodeMode", settings_src)
        self.assertIn("cctv.mediaDecodeMode.v1", settings_src)
        self.assertIn("清理内存与磁盘缩略图缓存", settings_src)

        jar_src = (SOURCES_DIR / "MediaJARRuntime.m").read_text(encoding="utf-8")
        self.assertIn("86400", jar_src)
        self.assertIn("JARRuntime", jar_src)

        log_src = (SOURCES_DIR / "LogCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("com.cctvhost.logcenter.parse", log_src)

        playback_src = (SOURCES_DIR / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.throughputLabel.hidden)return;", playback_src)
        self.assertIn("media-cicada-fullscreen-playpause", playback_src)

        m3u_src = (SOURCES_DIR / "M3UParser.m").read_text(encoding="utf-8")
        self.assertIn("M3UMaximumChannels = 25000", m3u_src)
        self.assertIn("M3UMaximumLines = 250000", m3u_src)


if __name__ == "__main__":
    unittest.main()
