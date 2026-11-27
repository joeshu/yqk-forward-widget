import pathlib
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGINS_DIR = ROOT / "Plugins"
SOURCES_DIR = ROOT / "Sources"
if str(PLUGINS_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGINS_DIR))

import host_dash
import host_media_servers


class Round45FullPlanCompletionTests(unittest.TestCase):
    def test_dash_dynamic_number_live_sliding_window(self):
        mpd = """<?xml version="1.0" encoding="utf-8"?>
        <MPD type="dynamic" availabilityStartTime="2026-01-01T00:00:00Z" timeShiftBufferDepth="PT24S" minimumUpdatePeriod="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v1" bandwidth="3000000" width="1920" height="1080" codecs="avc1.640028">
                <SegmentTemplate timescale="1000" duration="4000" startNumber="100"
                                 initialization="https://live.example.com/init.mp4"
                                 media="https://live.example.com/chunk-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        parsed = host_dash.parse_mpd(mpd.encode("utf-8"), "https://live.example.com/live.mpd")
        self.assertTrue(parsed["live"])
        self.assertEqual(len(parsed["tracks"]), 1)
        track = parsed["tracks"][0]
        self.assertGreaterEqual(len(track["segments"]), 6)
        self.assertIn("chunk-", track["segments"][0][0])

    def test_media_servers_alist_plex_emby_and_search(self):
        # 1) Alist / OpenList: list + subtitle auto-pairing + search + raw_url
        alist = host_media_servers.ServerSpider()
        alist.init({"type": "alist", "url": "https://alist.example.com", "apiKey": "tok-alist"})
        self.assertIn("search", alist.supported_operations)

        def fake_alist_req(path="", query=None, method="GET", body=None, xml=False):
            if path == "api/fs/list":
                return {"data": {"total": 2, "content": [
                    {"name": "Movie.4K.mkv", "is_dir": False, "thumb": ""},
                    {"name": "Movie.4K.ass", "is_dir": False},
                ]}}
            if path == "api/fs/search":
                return {"data": {"total": 1, "content": [
                    {"name": "Movie.4K.mkv", "parent": "/Movies", "is_dir": False},
                ]}}
            if path == "api/fs/get":
                p = body["path"]
                return {"data": {"raw_url": f"https://cdn.example.com{p}"}}
            raise AssertionError(f"Unexpected alist path: {path}")

        with mock.patch.object(alist, "_request", side_effect=fake_alist_req):
            cat = alist.categoryContent("/", 1)
            self.assertEqual(len(cat["list"]), 1)
            vod_id = cat["list"][0]["vod_id"]
            play = alist.playerContent("alist", vod_id)
            self.assertEqual(play["url"], "https://cdn.example.com/Movie.4K.mkv")
            self.assertEqual(len(play.get("subtitles", [])), 1)
            self.assertTrue(play["subtitles"][0]["url"].endswith("Movie.4K.ass"))
            search = alist.searchContent("Movie")
            self.assertEqual(len(search["list"]), 1)

        # 2) Plex: sections + category + search + play
        plex = host_media_servers.ServerSpider()
        plex.init({"type": "plex", "url": "https://plex.example.com", "apiKey": "plex-tok"})

        def fake_plex_req(path="", query=None, method="GET", body=None, xml=False):
            if path == "library/sections":
                return {"MediaContainer": {"Directory": [{"key": "1", "title": "Movies"}]}}
            if path == "library/sections/1/all":
                return {"MediaContainer": {"totalSize": 1, "Metadata": [{"ratingKey": "42", "title": "Inception", "type": "movie", "year": 2010}]}}
            if path == "search":
                return {"MediaContainer": {"Metadata": [{"ratingKey": "42", "title": "Inception", "type": "movie"}]}}
            if path == "library/metadata/42":
                return {"MediaContainer": {"Metadata": [{"ratingKey": "42", "title": "Inception", "Media": [{"Part": [{"key": "/library/parts/99/file.mkv"}]}]}]}}
            raise AssertionError(f"Unexpected plex path: {path}")

        with mock.patch.object(plex, "_request", side_effect=fake_plex_req):
            home = plex.homeContent()
            self.assertEqual(home["class"][0]["type_name"], "Movies")
            cat = plex.categoryContent("1", 1)
            self.assertEqual(cat["list"][0]["vod_name"], "Inception")
            play = plex.playerContent("plex", cat["list"][0]["vod_id"])
            self.assertIn("/library/parts/99/file.mkv", play["url"])
            self.assertIn("X-Plex-Token=plex-tok", play["url"])

        # 3) Emby: multi-version MediaSources + external subtitles + progress report
        emby = host_media_servers.ServerSpider()
        emby.init({"type": "emby", "url": "https://emby.example.com", "apiKey": "k", "userId": "u1"})

        def fake_emby_req(path="", query=None, method="GET", body=None, xml=False):
            if path == "Users/u1/Items/100":
                return {"Id": "100", "Name": "Dune", "MediaSources": [{"Id": "s1", "Name": "4K HDR"}, {"Id": "s2", "Name": "1080p"}]}
            if path == "Items/100/PlaybackInfo":
                return {"MediaSources": [{"MediaStreams": [{"Type": "Subtitle", "DisplayTitle": "Chinese", "DeliveryUrl": "/Videos/100/sub.srt"}]}]}
            if path == "Sessions/Playing/Progress":
                return {}
            raise AssertionError(f"Unexpected emby path: {path}")

        with mock.patch.object(emby, "_request", side_effect=fake_emby_req):
            vid = emby._id({"id": "100", "type": "Movie"})
            detail = emby.detailContent([vid])
            play_url_str = detail["list"][0]["vod_play_url"]
            self.assertIn("4K HDR", play_url_str)
            self.assertIn("1080p", play_url_str)
            first_ep_id = play_url_str.split("#")[0].split("$", 1)[1]
            play = emby.playerContent("emby", first_ep_id)
            self.assertIn("MediaSourceId=s1", play["url"])
            self.assertEqual(len(play.get("subtitles", [])), 1)
            self.assertTrue(emby.report_playback_progress("100", 123.5, is_paused=False))

    def test_stage3_and_stage4_native_modules_contracts(self):
        mem_m = (SOURCES_DIR / "HostMemoryBudgetCoordinator.m").read_text(encoding="utf-8")
        self.assertIn("os_proc_available_memory()", mem_m)
        self.assertIn("HostMemoryWarningThresholdBytes", mem_m)
        self.assertIn("UIApplicationDidReceiveMemoryWarningNotification", mem_m)

        app_m = (SOURCES_DIR / "AppDelegate.m").read_text(encoding="utf-8")
        self.assertIn("[HostMemoryBudgetCoordinator.shared startMonitoring];", app_m)

        jar_m = (SOURCES_DIR / "MediaJARRuntime.m").read_text(encoding="utf-8")
        self.assertIn("thread.stackSize=2*1024*1024;", jar_m)
        self.assertIn("trimIfNeededForOperation:@\"jar_runtime\"", jar_m)

        sub_m = (SOURCES_DIR / "HostSubtitleOverlayView.m").read_text(encoding="utf-8")
        self.assertIn("parseSubtitleText:", sub_m)
        self.assertIn("Dialogue:", sub_m)
        self.assertIn("updateForPlaybackTime:", sub_m)

        drama_m = (SOURCES_DIR / "ShortDramaVerticalFeedController.m").read_text(encoding="utf-8")
        self.assertIn("pagingEnabled = YES", drama_m)
        self.assertIn("updateSlidingPoolAroundIndex:", drama_m)
        self.assertIn("AVPlayerItemDidPlayToEndTimeNotification", drama_m)

        sqlite_m = (SOURCES_DIR / "ChannelSQLiteIndex.m").read_text(encoding="utf-8")
        self.assertIn("PRAGMA journal_mode=WAL", sqlite_m)
        self.assertIn("USING fts5", sqlite_m)
        self.assertIn("epg_programs", sqlite_m)

        m3u_m = (SOURCES_DIR / "M3UParser.m").read_text(encoding="utf-8")
        self.assertIn("udpxyOverride:(NSString *)udpxyOverride", m3u_m)

        local_m = (SOURCES_DIR / "LocalMediaStore.m").read_text(encoding="utf-8")
        self.assertIn("NSURLBookmarkCreationMinimalBookmark", local_m)
        self.assertIn("mountExternalURLs:", local_m)

        sheet_m = (SOURCES_DIR / "HostGlassActionSheetViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostInstallPressFeedback(row)", sheet_m)
        self.assertIn("trailingIcon.hidden = action.destructive && !action.selected;", sheet_m)

        diag_m = (SOURCES_DIR / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostSizeTableHeaderToFit(self.table, 156.0);", diag_m)

        settings_m = (SOURCES_DIR / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("clearJARRuntimeCache", settings_m)

        playback_m = (SOURCES_DIR / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        fullscreen_m = (SOURCES_DIR / "MediaPlaybackFullscreenHost.m").read_text(encoding="utf-8")
        self.assertIn("UIWindowSceneGeometryPreferencesIOS", fullscreen_m)
        self.assertIn("subtitleOverlay updateForPlaybackTime:", playback_m)
        self.assertIn("loadExternalSubtitlesForResult:result headers:requestHeaders", playback_m)
        self.assertIn("media.playback.menu.extsub", playback_m)

        browser_m = (SOURCES_DIR / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("ShortDramaVerticalFeedController.h", browser_m)
        self.assertIn("openShortDramaVerticalFeed", browser_m)

        catalog_m = (SOURCES_DIR / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        self.assertIn("ChannelSQLiteIndex.h", catalog_m)
        self.assertIn("searchChannelsWithQuery:", catalog_m)

        local_vc_m = (SOURCES_DIR / "LocalMediaViewController.m").read_text(encoding="utf-8")
        self.assertIn("mountedBookmarkURLsSnapshot", local_vc_m)
        self.assertIn("mountExternalURLs:urls", local_vc_m)

        sub_vc_m = (SOURCES_DIR / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        self.assertIn("cctv.subscription.udpxy.v1", sub_vc_m)

        sub_root_m = (SOURCES_DIR / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        self.assertIn("udpxyOverride:udpxyOverride", sub_root_m)


if __name__ == "__main__":
    unittest.main()
