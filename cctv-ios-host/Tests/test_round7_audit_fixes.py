"""Regression tests for Round 7 Principal Architect Runtime Forensics & Code Audit Fixes (ISS-55 through ISS-62)."""
import importlib.util
from pathlib import Path
import ssl
import sys
from unittest import mock
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"
PLUGINS = ROOT / "Plugins"
for _p in (PLUGINS, ROOT / "Scripts"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import host_media_relay


class Round7RuntimeForensicsAndAuditFixesTests(unittest.TestCase):
    def test_iss55_udrm_embedded_service_fstring_compiles_in_both_scripts(self):
        for rel in ("cctv-app-udrm/cctv-app-udrm.py", "cctv-app-udrm/cctv-app-udrm-v0.3.7.py"):
            path = REPO / rel
            spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_").replace(".", "_"), path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            loaded = module.load_modules()
            self.assertTrue(hasattr(loaded, "CHANNEL_ROUTES") and hasattr(loaded, "main"))

    def test_iss56_relay_missing_intermediate_ca_resolver_preserves_cert_required(self):
        self.assertEqual(host_media_relay._DEFAULT_SSL_CONTEXT.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(host_media_relay._DEFAULT_SSL_CONTEXT.check_hostname)

        missing_issuer_err = urllib.error.URLError(
            ssl.SSLCertVerificationError(20, "certificate verify failed: unable to get local issuer certificate (_ssl.c:1032)")
        )
        self.assertTrue(host_media_relay._is_missing_intermediate_ca_error(missing_issuer_err))

        other_tls_err = urllib.error.URLError(
            ssl.SSLCertVerificationError(1, "certificate verify failed")
        )
        self.assertFalse(host_media_relay._is_missing_intermediate_ca_error(other_tls_err))

        fake_resp = mock.MagicMock()
        fake_aia_opener = mock.MagicMock()
        fake_aia_opener.open.return_value = fake_resp
        with mock.patch.object(host_media_relay._DEFAULT_OPENER, "open", side_effect=missing_issuer_err), \
             mock.patch.object(host_media_relay, "_resolve_aia_opener_for_host", return_value=fake_aia_opener) as resolve_mock:
            host_media_relay._AIA_OPENER_CACHE.clear()
            req = urllib.request.Request("https://p.hhwenjian.com/seg001.ts", method="GET")
            out = host_media_relay._open_with_timeout_retry(req, diagnostic_id="r7-aia")
            self.assertIs(out, fake_resp)
            resolve_mock.assert_called_once_with("p.hhwenjian.com", 443)
            fake_aia_opener.open.assert_called_once()

    def test_iss57_timeshift_binary_enum_alignment_and_prepared_seek_completion(self):
        ts_h = (SOURCES / "CCTVTimeshiftController.h").read_text(encoding="utf-8")
        self.assertIn("CCTVTimeshiftStatEventSwitchTimeshift = 6", ts_h)
        self.assertIn("CCTVTimeshiftStatEventSwitchLookback = 7", ts_h)
        self.assertIn("CCTVTimeshiftStatEventBackToLive = 8", ts_h)
        self.assertIn("CCTVTimeshiftStatEventBinaryVODSeekStart = 18", ts_h)
        self.assertIn("CCTVTimeshiftStatEventBinaryVODSeekCompletion = 19", ts_h)

        ts_m = (SOURCES / "CCTVTimeshiftController.m").read_text(encoding="utf-8")
        self.assertIn("self.prepareDoneDuringSeek = YES;", ts_m)
        self.assertIn("if (self.prepareDoneDuringSeek && self.state == CCTVTimeshiftStateSeeking)", ts_m)

        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        self.assertIn("- (void)completeNativeFirstRenderIfNeededForTrigger:(NSString *)trigger", play_m)
        self.assertIn("由时移/回看会话驱动，不重复调用 play", play_m)
        self.assertIn('[weakSelf ensureNativeTimeshiftPlayingForTrigger:@"timeshift_seek_completed"]', play_m)

    def test_iss58_user_selected_route_disables_live_public_check_and_guards_watchdog(self):
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        sdk_url_body = play_m.split("- (void)playViaSDKURL:(NSString *)url channelID:(NSString *)cid title:(NSString *)title {", 1)[1].split(
            "\n- (void)playViaSDK:(NSString *)cid title:(NSString *)title {", 1
        )[0]
        self.assertIn("CCTVTimeshiftConfigKeyLivePublicCheck:@NO", sdk_url_body)
        self.assertIn("CCTVTimeshiftConfigKeyTimeshiftingChannelID:cid", sdk_url_body)
        self.assertIn("if(!self.nativePlaybackFailed)[self startWatchdog];", sdk_url_body)

        tick_body = play_m.split("- (void)tick:(NSTimer *)timer {", 1)[1].split("\n#pragma mark - 通用调用", 1)[0]
        self.assertIn("if (!self.currentPlayer || self.nativePlaybackFailed) { [timer invalidate]; self.watchdog=nil; return; }", tick_body)

        pub_fail = play_m.split("- (void)player:(id)player publicRequestFailed:(NSError *)error {", 1)[1].split(
            "\n- (void)authFailed:", 1
        )[0]
        self.assertIn("if (self.directNativeRouteActive && self.channelID.length && !self.nativeStartupRecoveryUsed)", pub_fail)
        self.assertIn("[self playViaSDK:self.channelID title:self.channelName ?: self.channelID];", pub_fail)

    def test_iss59_episode_play_deduplication_czzy_aes_decrypt_and_empty_shelf_breaker(self):
        mb_m = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        resolve_body = mb_m.split("- (void)resolveAndPlaySelectedEpisode {", 1)[1].split("\n- (void)reloadThemeAppearance", 1)[0]
        self.assertIn("if(self.inFlightPlaySignature&&[self.inFlightPlaySignature isEqualToString:playSignature]&&(now-self.inFlightPlayStartedAt)<1.5)return;", resolve_body)
        self.assertIn("owner.inFlightPlaySignature=nil;", resolve_body)

        shelf_body = mb_m.split("- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories", 1)[1].split(
            "\n- (void)updateHomeStatusCard", 1
        )[0]
        self.assertIn("if(homeItemCount==0&&owner.consecutiveEmptyHomeShelves>=2)", shelf_body)

        mp_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("#import <CommonCrypto/CommonCryptor.h>", mp_m)
        self.assertIn("czzyCipherRe", mp_m)
        self.assertIn("CCCrypt(kCCDecrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding", mp_m)
        self.assertIn('BOOL shouldAttemptNativeStreamResolver=MediaPlaybackIsCommercialVIPURL(raw)||[result[@"parse"] integerValue]>0||[result[@"requiresWebPlayback"] boolValue];', mp_m)

    def test_iss60_and_iss61_plugin_detail_status_and_drpy_log_sanitization(self):
        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertNotIn("运行中 · 视频解码状态未知", plug_m)
        self.assertNotIn("暂无状态信息", plug_m)
        self.assertIn("运行中 · 接口就绪（点选节目后按需解码）", plug_m)

        drpy_js = (ROOT / "JSPlugins" / "drpy" / "upstream" / "drpy2.js").read_text(encoding="utf-8")
        self.assertNotIn("console.log(JSON.stringify(rule));", drpy_js)
        self.assertIn('console.log("rule_loaded:"', drpy_js)

        js_rt = (SOURCES / "JSPluginRuntime.m").read_text(encoding="utf-8")
        self.assertIn('[text isEqualToString:@"init_test_start"]', js_rt)
        self.assertIn('[text containsString:@"\\"_codec\\""]', js_rt)

    def test_iss62_live_ui_play_pause_icon_sync_preview_validation_and_pip_feedback(self):
        rvc_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)syncPlayPauseButtonIcon {", rvc_m)
        self.assertIn('@"重试":@"arrow.clockwise"', rvc_m)
        self.assertIn('@"重连中":@"arrow.triangle.2.circlepath"', rvc_m)
        self.assertIn("CGFloat floatingPillExtra=catalog?18:0;", rvc_m)
        self.assertIn("[self.channelPreviewSnapshots removeAllObjects];", rvc_m.split("- (void)onBackground {", 1)[1].split("\n- (void)onForeground", 1)[0])

        metrics_m = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        self.assertIn("static BOOL CCTVPreviewImageHasValidVideoContent(UIImage *image)", metrics_m)
        self.assertNotIn("[self.playerBox drawViewHierarchyInRect:", metrics_m)
        self.assertIn("[videoSurface drawViewHierarchyInRect:", metrics_m)


if __name__ == "__main__":
    unittest.main()
