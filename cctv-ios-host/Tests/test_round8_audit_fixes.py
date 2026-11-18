"""Regression tests for Round 8 Principal Architect All-Pages Audit Fixes (ISS-63 through ISS-72)."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round8AllPagesArchitectAuditTests(unittest.TestCase):
    def test_iss63_cctv_native_udrm_stream_hides_pip_action_and_does_not_cross_tab_boundary(self):
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        more_body = play_m.split("- (void)showMorePlaybackActions {", 1)[1].split(
            "\n- (void)beginPlaybackPriority", 1
        )[0]
        self.assertIn("if(self.avLayer && AVPictureInPictureController.isPictureInPictureSupported){", more_body)
        self.assertIn('[sheet addAction:[UIAlertAction actionWithTitle:@"画中画"', more_body)

        rvc_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        pip_body = rvc_m.split("- (void)togglePiP {", 1)[1].split("\n#pragma mark - 播放区", 1)[0]
        self.assertNotIn("nextUntriedAlternateChannel", pip_body)
        self.assertNotIn("startRemoteChannel:", pip_body)
        self.assertIn("央视原生加密频道由专用内核（CNPlayerSDK）解密渲染，不支持系统画中画", pip_body)

    def test_iss64_service_editor_download_session_uses_main_queue_and_clears_buffer(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn(
            "self.downloadSession=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];",
            se_m,
        )
        self.assertIn("self.downloadData=nil;self.downloadFailureMessage=nil;self.downloading=NO;", se_m)
        self.assertIn("owner.downloading=NO;owner.downloadTask=nil;owner.downloadData=nil;owner.downloadFailureMessage=nil;", se_m)

    def test_iss65_media_web_view_weak_self_and_failed_progress_reset(self):
        mw_m = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        finish_body = mw_m.split("- (void)webView:(WKWebView *)webView didFinishNavigation:", 1)[1].split(
            "\n- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:", 1
        )[0]
        self.assertIn("__weak typeof(self) weakSelf=self;", finish_body)
        self.assertIn("if(!owner||owner.didClose)return;", finish_body)

        failed_body = mw_m.split("- (void)failed:(NSError *)error {", 1)[1]
        self.assertIn("self.webProgressView.hidden=YES;self.webProgressView.progress=0;", failed_body)

    def test_iss66_epg_view_controller_prunes_expired_reminders_and_guards_weak_self(self):
        epg_m = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("[self pruneExpiredReminders];", epg_m)
        self.assertIn("- (void)pruneExpiredReminders {", epg_m)
        self.assertIn("if(!w||request!=w.requestGeneration)return;", epg_m)
        self.assertIn("if(!weakSelf||generation!=weakSelf.requestGeneration)return;", epg_m)

    def test_iss67_subscription_and_plugin_run_history_date_formatter_sync_and_clear_refresh(self):
        sub_m = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        self.assertIn("@synchronized(fmt){timeStr=[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]];}", sub_m)

        prh_m = (SOURCES / "PluginRunHistoryViewController.m").read_text(encoding="utf-8")
        self.assertIn("@synchronized(formatter){return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];}", prh_m)
        self.assertIn("if(weakSelf.onClearAll)weakSelf.onClearAll();[weakSelf refreshRuns];", prh_m)
        self.assertIn("if(!self.isViewLoaded||!self.view.window||self.refreshScheduled)return;", prh_m)

    def test_iss68_local_media_view_controller_main_thread_bounds_and_empty_state(self):
        lm_m = (SOURCES / "LocalMediaViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,strong) UILabel *emptyLabel;", lm_m)
        self.assertIn("self.tableView.backgroundView=self.emptyLabel;", lm_m)
        self.assertIn("if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;", lm_m)
        self.assertIn("if(path.row<0||path.row>=self.files.count)return cell;", lm_m)
        self.assertIn("if(path.row<0||path.row>=self.files.count)return;NSURL *url=self.files[path.row];", lm_m)

    def test_iss69_runtime_diagnostics_main_thread_confinement_and_presentation_guard(self):
        rd_m = (SOURCES / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("if (NSThread.isMainThread) applyBlock(); else dispatch_async(dispatch_get_main_queue(), applyBlock);", rd_m)
        self.assertIn("if(!self.view.window)return;", rd_m)
        self.assertIn("if(self.presentedViewController)return;", rd_m)

    def test_iss70_media_episode_selection_deduplicates_inflight_select_episode(self):
        mes_m = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,copy) NSString *inFlightEpisodeSignature;", mes_m)
        self.assertIn(
            "if(self.inFlightEpisodeSignature&&[self.inFlightEpisodeSignature isEqualToString:episodeSignature]&&(now-self.inFlightEpisodeStartedAt)<1.5)return;",
            mes_m,
        )
        self.assertIn("owner.inFlightEpisodeSignature=nil;owner.inFlightEpisodeStartedAt=0;", mes_m)

    def test_iss71_resource_import_sheet_updates_surface_and_border_on_theme_reload(self):
        ris_m = (SOURCES / "ResourceImportSheetViewController.m").read_text(encoding="utf-8")
        reload_body = ris_m.split("- (void)reloadThemeAppearance {", 1)[1].split(
            "\n- (NSInteger)numberOfSectionsInTableView:", 1
        )[0]
        self.assertIn("self.view.backgroundColor=sheetSurface;", reload_body)
        self.assertIn("self.tableView.backgroundColor=sheetSurface;", reload_body)
        self.assertIn("HostSetLayerBorderColor(self.closeButton,HostBorder());", reload_body)

    def test_iss72_service_detail_change_service_watchdog_and_weak_self_prompt(self):
        svc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic, assign) NSUInteger changeServiceGeneration;", svc_m)
        self.assertIn("NSUInteger changeGen=++self.changeServiceGeneration;", svc_m)
        self.assertIn("ServiceDetailViewController *owner=weakSelf;if(!owner||changeGen!=owner.changeServiceGeneration||!owner.changingService)return;", svc_m)
        self.assertNotIn("^{if([self.navigationItem.prompt isEqual:@\"地址已复制\"])self.navigationItem.prompt=nil;}", svc_m)


if __name__ == "__main__":
    unittest.main()
