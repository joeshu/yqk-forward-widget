"""Regression tests for the 2026-11 comprehensive full-project audit and fixes (Round 1 & Round 2)."""
import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"
for _p in (ROOT / "Plugins", ROOT / "Scripts"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


def read_root_source() -> str:
    parts = [
        SOURCES / "RootViewController_Internal.h",
        SOURCES / "RootViewController.m",
        SOURCES / "RootViewController+Catalog.m",
        SOURCES / "RootViewController+Playback.m",
        SOURCES / "RootViewController+StreamMetrics.m",
        SOURCES / "RootViewController+EPG.m",
        SOURCES / "RootViewController+Subscriptions.m",
        SOURCES / "RootViewController+Services.m",
    ]
    return "\n".join(
        p.read_text(encoding="utf-8").split("\n- (BOOL)sessionHasContent;", 1)[0]
        if p.name.endswith(".h")
        else p.read_text(encoding="utf-8")
        for p in parts
    )


class ComprehensiveAuditRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = read_root_source()
        cls.catalog = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        cls.playback_live = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        cls.metrics = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        cls.subscriptions = (SOURCES / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        cls.services = (SOURCES / "RootViewController+Services.m").read_text(encoding="utf-8")
        cls.media_playback_h = (SOURCES / "MediaPlaybackViewController.h").read_text(encoding="utf-8")
        cls.media_playback_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        cls.media_browser_m = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        cls.episode_selection_m = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
        cls.media_web_m = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        cls.services_vc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        cls.service_editor_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        cls.plugin_detail_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        cls.epg_vc_m = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        cls.config_center_m = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        cls.sub_resource_m = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        cls.import_workflow_m = (SOURCES / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        cls.settings_m = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        cls.backup_m = (SOURCES / "HostBackup.m").read_text(encoding="utf-8")

    def test_01_udrm_embedded_service_compiles_under_python_311(self):
        for rel in ("cctv-app-udrm/cctv-app-udrm.py", "cctv-app-udrm/cctv-app-udrm-v0.3.7.py"):
            path = REPO / rel
            self.assertTrue(path.is_file(), f"Missing {rel}")
            spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            loaded = module.load_modules()
            self.assertTrue(hasattr(loaded, "CHANNEL_ROUTES") and hasattr(loaded, "main"))

    def test_02_cold_start_populates_alt_sources_applies_filter_and_never_passively_probes_previews(self):
        load_body = self.catalog.split("- (void)loadChannels {", 1)[1].split("\n- (UISwipeActionsConfiguration *)", 1)[0]
        self.assertIn("[self.altSources removeAllObjects];", load_body)
        self.assertIn("CCTVRouteGroupKey(c)", load_body)
        self.assertIn("[self applyFilter];", load_body)

        preview_body = self.metrics.split("- (UIImage *)previewImageForChannel:(NSDictionary *)channel {", 1)[1].split(
            "\n- (void)captureLivePreviewSnapshotForChannelID:", 1
        )[0]
        self.assertIn("if(needsRefresh){", preview_body)
        self.assertNotIn("!self.channelPreviewCapturedAt[cid]", preview_body)

    def test_03_inline_playback_and_overlay_timers_teardown_cleanly_on_exit(self):
        self.assertEqual(self.media_playback_h.count("- (void)reloadThemeAppearance;"), 1)
        self.assertIn("- (void)teardownAfterScreenExit;", self.media_playback_h)
        self.assertIn("- (void)teardownCicadaAdapter;", self.media_playback_h)

        will_disappear = self.media_playback_m.split("- (void)viewWillDisappear:(BOOL)animated {", 1)[1].split(
            "- (void)viewDidDisappear:(BOOL)animated {", 1
        )[0]
        self.assertIn("self.parentViewController.isMovingFromParentViewController", will_disappear)
        self.assertIn("self.parentViewController.isBeingDismissed", will_disappear)
        self.assertGreaterEqual(self.media_playback_m.count("[self.controlsOverlay invalidate];"), 2)

        teardown_inline = self.media_browser_m.split("- (void)teardownInlinePlayback {", 1)[1].split("\n- (void)goBack", 1)[0]
        self.assertIn("[player teardownAfterScreenExit];", teardown_inline)
        self.assertIn("[player teardownCicadaAdapter];", teardown_inline)
        self.assertIn("[self.inlinePlaybackDock removeFromSuperview];", teardown_inline)

        self.assertGreaterEqual(self.root.count("[self.liveControlsOverlay invalidate];"), 2)

    def test_04_service_enable_port_probe_does_not_sleep_on_main_thread(self):
        change_body = self.services.split(
            "- (void)changeService:(NSDictionary *)service enabled:(BOOL)enabled completion:(void (^)(NSError *))completion {", 1
        )[1].split("\n- (void)hibernateExcessBackgroundVODServicesKeepingID:", 1)[0]
        self.assertIn("dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{", change_body)
        before_async = change_body.split("dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{", 1)[0]
        self.assertNotIn("sleepForTimeInterval", before_async)
        self.assertNotIn("HostLocalPortState", before_async)

    def test_05_settings_and_backup_cover_all_four_native_switches_and_source_arrays(self):
        self.assertIn('@"key":@"nativePlayerCornerLogoEnabled"', self.settings_m)
        self.assertIn('if ([key isEqualToString:@"nativePlayerCornerLogoEnabled"])', self.root)
        self.assertIn('@"nativePlayerCornerLogoEnabled"', self.backup_m)
        self.assertIn("+ (NSArray<NSString *> *)arrayPreferenceKeys", self.backup_m)
        for key in (
            "enabledChannelLogoSources",
            "disabledChannelLogoSources",
            "enabledPlayerCornerLogoSources",
            "disabledPlayerCornerLogoSources",
            "enabledChannelPreviewSources",
            "disabledChannelPreviewSources",
            "enabledChannelTelemetrySources",
            "disabledChannelTelemetrySources",
            "resourceUnifiedOrder",
        ):
            self.assertIn(f'@"{key}"', self.backup_m)

    def test_06_live_mute_uses_instance_state_and_preview_passes_scoped_headers(self):
        self.assertIn("@property(nonatomic,assign) BOOL liveMuted;", self.root)
        self.assertNotIn("static BOOL muted", self.playback_live)
        self.assertIn("self.liveMuted = NO;", self.playback_live)

        preview_ch = self.subscriptions.split("- (void)previewChannel:(NSDictionary *)ch {", 1)[1].split(
            "\n- (void)stopPreview", 1
        )[0]
        self.assertIn("MediaPlaybackHeadersScopedToURL(rawHeaders,previewURL,previewURL)", preview_ch)
        self.assertIn('@"AVURLAssetHTTPHeaderFieldsKey"', preview_ch)

    def test_07_web_playback_disabled_and_routed_to_native_stream_sniffer(self):
        retry_body = self.media_playback_m.split("- (void)setRetryAvailable:(BOOL)available {", 1)[1].split(
            "\n- (void)teardownHiddenStreamSniffer", 1
        )[0]
        self.assertIn("self.inlineWebButton.hidden=YES;", retry_body)
        self.assertNotIn("webFallbackItem", retry_body)

        dealloc_body = self.media_playback_m.split("- (void)dealloc {", 1)[1].split(
            "\n- (void)updateEstimatedThroughput", 1
        )[0]
        self.assertIn("[self teardownHiddenStreamSniffer];", dealloc_body)

        web_fallback = self.media_playback_m.split("- (void)openWebPlaybackFallback {", 1)[1].split(
            "\n- (void)recordPlaybackFailureForItem:", 1
        )[0]
        self.assertNotIn("MediaWebViewController", web_fallback)
        self.assertEqual(web_fallback.count("sniffNativeStreamFromPageResult:"), 2)

    def test_13_youku_tencent_iqiyi_mgtv_vip_watch_resolution_in_python_runtime(self):
        from unittest import mock
        import csp_adapter
        import host_media_runtime

        for url, expected_ref in (
            ("https://v.youku.com/v_show/id_XNjU4.html", "https://v.youku.com/"),
            ("https://v.qq.com/x/cover/mzc00200/v001.html", "https://v.qq.com/"),
            ("https://www.iqiyi.com/v_19rr7p.html", "https://www.iqiyi.com/"),
            ("https://www.mgtv.com/b/600123/20123456.html", "https://www.mgtv.com/"),
        ):
            self.assertTrue(csp_adapter.is_vip_watch_url(url))
            self.assertEqual(csp_adapter.vip_platform_referer(url), expected_ref)

        with mock.patch.object(csp_adapter, "resolve_maccms_stream_by_title", return_value="https://cdn.example/vip/ep1.m3u8"):
            for url, flag in (
                ("https://v.youku.com/v_show/id_XNjU4.html", "youku"),
                ("https://v.qq.com/x/cover/mzc00200/v001.html", "qq"),
                ("https://www.iqiyi.com/v_19rr7p.html", "qiyi"),
                ("https://www.mgtv.com/b/600123/20123456.html", "mgtv"),
            ):
                stream, hdrs = csp_adapter.resolve_vip_watch_url(url, title="庆余年第二季", episode_index=0, episode_name="第1集", flag=flag)
                self.assertEqual(stream, "https://cdn.example/vip/ep1.m3u8")
                self.assertIn("Referer", hdrs)

    def test_14_extract_title_from_vip_url_preserves_book_titles_and_episodes(self):
        from unittest import mock
        import csp_adapter

        fake_resp = mock.MagicMock()
        fake_resp.status_code = 200
        fake_resp.text = '<html><head><meta property="og:title" content="《藏海传》第03集-高清完整版在线观看-优酷"/></head></html>'
        with mock.patch("csp_adapter.requests.get", return_value=fake_resp):
            title, ep_name = csp_adapter.extract_title_from_vip_url("https://v.youku.com/v_show/id_XNjU4.html")
            self.assertEqual(title, "藏海传")
            self.assertEqual(ep_name, "第3集")

    def test_15_media_api_client_vip_platform_matching_and_auto_fallback(self):
        api_m = (ROOT / "Sources/MediaAPIClient.m").read_text(encoding="utf-8")
        self.assertIn("MediaParserMatchesVIPPlatform(parser,mediaURL)", api_m)
        self.assertIn('@[@"qiyi",@"iqiyi",@"爱奇艺",@"奇艺"]', api_m)
        self.assertIn('@[@"mgtv",@"imgo",@"芒果"]', api_m)
        self.assertIn("NSDictionary *fallback=self.selectedParserID.length?self.parserWebFallbackResult:(self.parserWebFallbackResult?:self.parserFallbackResult);", api_m)

    def test_16_playback_controller_vip_native_stream_sniffer_and_sp360_headers(self):
        self.assertIn("MediaPlaybackIsCommercialVIPURL", self.media_playback_m)
        self.assertIn("MediaPlaybackPlatformRefererForURL", self.media_playback_m)
        self.assertIn("MediaPlaybackResolveVIPNativeStream", self.media_playback_m)
        self.assertIn("if(!vipResolutionPending)[inner finishNativeStreamSniffFailureForGeneration:playerGeneration];", self.media_playback_m)
        sp360_h = (ROOT / "Sources/MediaSP360Adapter.h").read_text(encoding="utf-8")
        self.assertIn("MediaSP360PlatformName", sp360_h)
        self.assertIn("MediaSP360PlatformReferer", sp360_h)

    def test_08_episode_selection_utf16_safe_truncation_notifications_and_touch_targets(self):
        desc_body = self.episode_selection_m.split("- (void)updateDescription {", 1)[1].split(
            "\n- (void)rebuildHeroBadges", 1
        )[0]
        self.assertIn("rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,1800)", desc_body)
        self.assertNotIn("[synopsis substringToIndex:1800]", desc_body)

        self.assertIn("CCTVMediaEpisodeLayoutStyleDidChangeNotification", self.episode_selection_m)
        self.assertIn('name:@"MediaDisplayConfigurationDidChangeNotification"', self.episode_selection_m)
        self.assertIn("[NSNotificationCenter.defaultCenter removeObserver:self];", self.episode_selection_m)
        self.assertIn("[back.widthAnchor constraintEqualToConstant:44].active=YES;", self.episode_selection_m)
        self.assertIn("[self.jumpEpisodeButton.widthAnchor constraintEqualToConstant:44].active=YES;", self.episode_selection_m)
        self.assertIn("[self.refreshButton.widthAnchor constraintEqualToConstant:44].active=YES;", self.episode_selection_m)
        self.assertIn("[paging.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;", self.episode_selection_m)

    def test_09_service_detail_and_plugin_detail_restart_thread_safety_and_watchdogs(self):
        restart_body = self.services_vc_m.split("- (void)restart {", 1)[1].split(
            "\n- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1
        )[0]
        self.assertIn("if(self.changingService)return;", restart_body)
        self.assertIn("self.changingService=YES;", restart_body)
        self.assertIn("dispatch_async(dispatch_get_main_queue(),^{", restart_body)
        self.assertIn("30*NSEC_PER_SEC", restart_body)

        self.assertGreaterEqual(
            self.services_vc_m.count("[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];"),
            4,
        )

        plugin_restart = self.plugin_detail_m.split('if([action isEqual:@"restart"]){', 1)[1].split(
            'if([action isEqual:@"toggle"]){', 1
        )[0]
        self.assertIn("self.restartGeneration", plugin_restart)
        self.assertIn("30*NSEC_PER_SEC", plugin_restart)
        self.assertIn("[owner refreshPlaylistPathState];", plugin_restart)

    def test_10_service_editor_invalidates_download_session_to_prevent_delegate_leak(self):
        complete_body = self.service_editor_m.split(
            "- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {", 1
        )[1].split("\n- (void)documentPicker:", 1)[0]
        self.assertIn("[owner.downloadSession finishTasksAndInvalidate];owner.downloadSession=nil;", complete_body)
        self.assertIn("[session finishTasksAndInvalidate];", complete_body)

        url_changed = self.service_editor_m.split("- (void)urlChanged {", 1)[1].split("\n- (void)sourceChanged", 1)[0]
        self.assertIn("[self.downloadSession invalidateAndCancel];self.downloadSession=nil;", url_changed)

    def test_11_epg_effective_channel_id_prevents_custom_channel_reminder_collision(self):
        self.assertIn("- (NSString *)effectiveChannelIdentifier", self.epg_vc_m)
        reminder_key = self.epg_vc_m.split("- (NSString *)reminderKeyForProgram:(NSDictionary *)program {", 1)[1].split(
            "\n- (BOOL)isProgramReminded:", 1
        )[0]
        self.assertIn("[self effectiveChannelIdentifier]", reminder_key)
        clear_body = self.epg_vc_m.split("- (void)clearChannelReminders {", 1)[1].split("\n- (void)filterDate", 1)[0]
        self.assertIn("[self effectiveChannelIdentifier]", clear_body)
        self.assertIn("self.dates.frame=CGRectMake(16,top+8,width-32,44);", self.epg_vc_m)

    def test_12_media_web_view_pauses_html5_media_on_close_and_touch_targets_enlarged(self):
        self.assertIn("- (void)stopWebMediaPlayback", self.media_web_m)
        self.assertGreaterEqual(self.media_web_m.count("[self stopWebMediaPlayback];") + self.media_web_m.count("[page stopWebMediaPlayback];"), 4)
        self.assertIn("CGRectMake(0,0,82,44)", self.config_center_m)
        self.assertIn("CGRectMake(0,0,48,36)", self.sub_resource_m)
        self.assertIn("CGRectMake(0,0,MAX(62,CGRectGetWidth(editBtn.bounds)+10),44)", self.import_workflow_m)


if __name__ == "__main__":
    unittest.main()
