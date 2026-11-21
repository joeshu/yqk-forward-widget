from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1] / "Sources"


class Round41FullOptimizationContractsTests(unittest.TestCase):
    def read(self, name: str) -> str:
        return (ROOT / name).read_text(encoding="utf-8")

    def test_p0_live_and_vod_avplayer_fast_startup_buffer_policy(self):
        playback = self.read("RootViewController+Playback.m")
        self.assertIn("item.preferredForwardBufferDuration=1.0;", playback)
        self.assertIn("self.avPlayer.automaticallyWaitsToMinimizeStalling=NO;", playback)
        self.assertIn("playImmediatelyAtRate:1.0", playback)
        self.assertIn("item.preferredForwardBufferDuration=4.0;", playback)

        vod = self.read("MediaPlaybackViewController.m")
        self.assertIn("self.player.automaticallyWaitsToMinimizeStalling=!fastStartup;", vod)

    def test_p0_native_preloader_ttl_and_shown_channels_priority(self):
        preloader = self.read("NativeChannelPreloader.m")
        self.assertIn("NativeChannelPreloaderTTLSeconds = 90.0;", preloader)

        playback = self.read("RootViewController+Playback.m")
        self.assertIn("0.8*NSEC_PER_SEC", playback)
        self.assertIn("self.shownChannels.count>=2?self.shownChannels:self.allChannels", playback)
        self.assertIn("refreshVisibleChannelSelectionFromID:", playback)

    def test_p0_event_driven_and_hedged_web_stream_sniffing(self):
        vod = self.read("MediaPlaybackViewController.m")
        self.assertIn("CCTVSnifferMessageProxy", vod)
        self.assertIn("cctvStreamCaptured", vod)
        self.assertIn("removeScriptMessageHandlerForName:@\"cctvStreamCaptured\"", vod)
        self.assertIn("0.8*NSEC_PER_SEC", vod)

    def test_p1_protocol_headers_hls_segment_probe_and_udpxy(self):
        probe_h = self.read("MediaChannelProbe.h")
        self.assertIn("startWithURL:(NSURL *)url headers:", probe_h)

        probe_m = self.read("MediaChannelProbe.m")
        self.assertIn("MediaChannelProbeExtractFirstHLSSegment", probe_m)
        self.assertIn("MediaChannelProbeSegmentByteLimit = 65536", probe_m)

        m3u = self.read("M3UParser.m")
        self.assertIn("cctv.udpxyBaseURL.v1", m3u)

        key_req = self.read("MediaKeyRequest.m")
        self.assertIn("MediaKeyRequestDelegateQueue()", key_req)
        self.assertNotIn("delegateQueue:NSOperationQueue.mainQueue", key_req)

    def test_p1_cicada_live_vs_vod_buffer_separation(self):
        cicada = self.read("MediaPlaybackCicadaAdapter.m")
        self.assertIn("setMaxDelayTime:", cicada)
        self.assertIn("isLikelyLive", cicada)
        self.assertIn("45000", cicada)

    def test_p1_catalog_size_cache_zero_network_snapshot_and_lru_eviction(self):
        catalog = self.read("RootViewController+Catalog.m")
        self.assertIn("sizeCache.countLimit=4096;", catalog)

        metrics = self.read("RootViewController+StreamMetrics.m")
        self.assertIn("startWithURL:probeURL headers:rawHeaders", metrics)
        self.assertIn("keys.count/4", metrics)

        xmltv = self.read("XMLTVStore.m")
        self.assertIn("windowStart=now-6*3600", xmltv)

    def test_p1_media_global_search_home_shelves_and_jar_mirror_persistence(self):
        search = self.read("MediaGlobalSearchViewController.m")
        self.assertIn("MediaGlobalSearchMaximumConcurrentSources = 6;", search)
        self.assertIn("MediaGlobalSearchMaximumResultsPerProvider = 20;", search)
        self.assertIn("MediaGlobalSearchProviderCache", search)

        browser = self.read("MediaBrowserViewController.m")
        self.assertIn("self.homeCategoryLoadsInFlight.count>=3", browser)

        api = self.read("MediaAPIClient.m")
        self.assertIn("cctv.jarBridgeMirrorCache.v1", api)

    def test_p1_playlist_save_acknowledgement_and_js_runtime_idle_eviction(self):
        subs = self.read("RootViewController+Subscriptions.m")
        installer = subs.split("- (BOOL)installPlaylist:", 1)[1].split("- (void)applyPlaylistText:", 1)[0]
        self.assertLess(installer.index('@"cachedChannels":[owned copy]'), installer.index("return YES;"))

        js = self.read("JSPluginRuntime.m")
        self.assertIn("JSIdleEvictionSeconds = 120.0;", js)
        self.assertIn("UIApplicationDidReceiveMemoryWarningNotification", js)
        self.assertIn("JSGarbageCollect", js)

    def test_p2_detail_pre_resolve_view_pooling_copyright_lru_and_udpxy_ui(self):
        browser = self.read("MediaBrowserViewController.m")
        self.assertIn("preResolveSelectedEpisodeIfNeeded", browser)
        self.assertIn("self.preResolvedResult", browser)
        self.assertIn("existingRouteViews", browser)

        ep_sel = self.read("MediaEpisodeSelectionViewController.m")
        self.assertIn("existingChips", ep_sel)
        self.assertIn("existingRows", ep_sel)

        timeshift = self.read("CCTVTimeshiftController.m")
        self.assertIn("sortedKeys.count / 4", timeshift)

        config_vc = self.read("ConfigCenterViewController.m")
        self.assertIn("promptUdpxyConfiguration", config_vc)
        self.assertIn("cctv.udpxyBaseURL.v1", config_vc)


if __name__ == "__main__":
    unittest.main()
