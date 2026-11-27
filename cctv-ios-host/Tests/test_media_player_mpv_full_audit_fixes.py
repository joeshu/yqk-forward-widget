import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class TestBatch1MPVAndRouterFixes(unittest.TestCase):
    def test_mpv_lifecycle_handles_eintr_and_darwin_monotonic_clock(self) -> None:
        src = read_source("HostMPVLifecycle.c")
        self.assertIn("#include <errno.h>", src)
        self.assertIn("EINTR", src)
        self.assertIn("pthread_cond_timedwait_relative_np", src)

    def test_mpv_adapter_no_recursive_rate_or_muted_setter(self) -> None:
        src = read_source("MediaPlaybackMPVAdapter.m")
        self.assertIn("_rate = clamped;", src)
        self.assertIn("_muted = muted;", src)
        self.assertNotIn("self.rate = clamped;", src)
        self.assertNotIn("self.muted = muted;", src)

    def test_mpv_adapter_background_metal_pause_and_foreground_restore(self) -> None:
        src = read_source("MediaPlaybackMPVAdapter.m")
        self.assertIn("UIApplicationWillResignActiveNotification", src)
        self.assertIn("UIApplicationDidEnterBackgroundNotification", src)
        self.assertIn("UIApplicationDidBecomeActiveNotification", src)
        self.assertIn("retainedMetalLayer", src)

    def test_mpv_adapter_thread_safety_and_header_append(self) -> None:
        src = read_source("MediaPlaybackMPVAdapter.m")
        self.assertIn("<stdatomic.h>", src)
        self.assertIn("http-header-fields-append", src)
        self.assertIn("initWithBlock:", src)
        self.assertIn("MPV_EVENT_SEEK", src)
        self.assertIn("self.url.isFileURL ? self.url.path : self.url.absoluteString", src)

    def test_decode_router_ts_sniff_and_mpv_only_exclusion(self) -> None:
        header = read_source("MediaPlaybackDecodeRouter.h")
        src = read_source("MediaPlaybackDecodeRouter.m")
        self.assertIn('@"mpv"', header)
        self.assertIn("len >= 189", src)
        self.assertIn("b[188] == 0x47", src)
        self.assertIn("mpvOnlyMedia", src)


class TestBatch2PlayerCoreFixes(unittest.TestCase):
    def test_playback_coordinator_releases_by_identity_and_clears_now_playing(self) -> None:
        src = read_source("PlaybackCoordinator.m")
        self.assertIn("currentSessionIdentity", src)
        self.assertIn("nowPlayingInfo", src)

    def test_settings_coordinator_refreshes_menus_on_track_selection(self) -> None:
        src = read_source("MediaPlaybackSettingsCoordinator.m")
        self.assertGreaterEqual(src.count("[coordinator refreshMenus];"), 4)

    def test_sniff_fetch_cancels_prior_session_on_reuse(self) -> None:
        src = read_source("MediaPlaybackSniffFetch.m")
        self.assertIn("invalidateAndCancel", src)

    def test_subtitle_overlay_handles_whitespace_blank_lines_and_gb18030(self) -> None:
        src = read_source("HostSubtitleOverlayView.m")
        self.assertIn("kCFStringEncodingGB_18030_2000", src)
        self.assertIn("[_fetchTask cancel];", src)

    def test_cicada_adapter_increments_stall_count_on_rebuffering(self) -> None:
        src = read_source("MediaPlaybackCicadaAdapter.m")
        self.assertIn("self.stallCount++", src)

    def test_playback_vc_visibility_resume_and_cleanup_fixes(self) -> None:
        src = read_source("MediaPlaybackViewController.m")
        self.assertIn("restorePortraitOrientationIfNeeded", src)
        self.assertIn("fabs(position-self.lastPersistedPosition)>=10.0", src)
        self.assertIn("[self.subtitleOverlay clearSubtitles];", src)
        self.assertIn("请选择分集", src)
        self.assertIn("engine_unavailable", src)


class TestBatch3MediaBrowserAndAPIFixes(unittest.TestCase):
    def test_api_client_breaks_url_session_retain_cycle_and_validates_json(self) -> None:
        src = read_source("MediaAPIClient.m")
        self.assertIn("MediaAPISessionDelegateProxy", src)
        self.assertIn("MediaTVBoxInteger", src)
        self.assertIn("MediaTVBoxBool", src)
        self.assertIn("listReq.timeoutInterval", src)

    def test_feed_view_and_query_builder_fixes(self) -> None:
        feed_h = read_source("MediaFeedView.h")
        feed_m = read_source("MediaFeedView.m")
        qb_m = read_source("MediaBrowserQueryBuilder.m")
        self.assertIn("onScrollEnd", feed_h)
        self.assertIn("self.poster.alpha=1.0;", feed_m)
        self.assertIn("stringByTrimmingCharactersInSet", qb_m)

    def test_browser_vc_shelf_client_ownership_and_state_resets(self) -> None:
        src = read_source("MediaBrowserViewController.m")
        self.assertIn("homeShelfClients", src)
        self.assertIn("- (void)cancelHomeShelfLoads", src)
        self.assertIn("feed.onScrollEnd", src)
        self.assertIn("owner.capabilityReadinessStartedAt", src)
        self.assertNotIn("self.capabilityReadinessStartedAt>0", src)
        self.assertIn("page.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaPage:page];", src)


class TestBatch4SubpagesFixes(unittest.TestCase):
    def test_short_drama_feed_unified_teardown_and_drag_sync(self) -> None:
        src = read_source("ShortDramaVerticalFeedController.m")
        self.assertIn("- (void)teardownFeed", src)
        self.assertIn("scrollViewDidEndDragging:", src)
        self.assertNotIn("MIN(self.episodes.count, (NSUInteger)30)", src)
        self.assertIn("existing.player.currentItem.preferredForwardBufferDuration = 10.0;", src)

    def test_local_media_store_and_vc_security_scoped_and_bookmark_cache(self) -> None:
        store = read_source("LocalMediaStore.m")
        vc = read_source("LocalMediaViewController.m")
        self.assertIn("cachedMountedURLs", store)
        self.assertIn("refreshCachedBookmarks", store)
        scoped_idx = store.index("BOOL scoped=[url startAccessingSecurityScopedResource];")
        size_idx = store.index("NSURLFileSizeKey")
        self.assertLess(scoped_idx, size_idx)
        self.assertIn("completionWithItemsHandler", vc)

    def test_web_vc_result_url_and_source_tag_and_close_callback(self) -> None:
        src = read_source("MediaWebViewController.m")
        self.assertIn("- (nullable NSURL *)resultURL", src)
        self.assertIn("querySelector('source[src]')", src)
        self.assertIn("navigationGeneration", src)
        self.assertIn('[self.web loadHTMLString:@"" baseURL:nil];', src)

    def test_global_search_vc_provider_helper_and_retry_guards(self) -> None:
        src = read_source("MediaGlobalSearchViewController.m")
        self.assertIn("- (void)applyProviders:", src)
        self.assertIn("加载更多失败 · 端口无效", src)
        self.assertIn("if (self.resultCount >= MediaGlobalSearchMaximumResults)", src)

    def test_episode_selection_vc_season_only_and_weak_alert(self) -> None:
        src = read_source("MediaEpisodeSelectionViewController.m")
        self.assertIn("if(!self.lines.count&&!episodes.count)", src)
        self.assertIn("if(self.lines.count&&(self.selectedLineIndex<0||self.selectedLineIndex>=self.lines.count))return;", src)
        self.assertIn("__weak UIAlertController *weakAlert=alert;", src)
        self.assertIn("media-episode-row-height", src)

    def test_tvbox_catalog_vc_cache_invalidation_and_native_helper(self) -> None:
        src = read_source("TVBoxCatalogViewController.m")
        self.assertIn("TVBoxCatalogSiteIsNativeAPI", src)
        self.assertIn("- (void)setCatalog:(NSDictionary *)catalog", src)


if __name__ == "__main__":
    unittest.main()
