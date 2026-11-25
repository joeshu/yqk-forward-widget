"""Regression tests for Round 6 Principal Architect Audit & Fixes (ISS-45 through ISS-54)."""
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"
for _p in (ROOT / "Plugins", ROOT / "Scripts"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


class Round6PrincipalArchitectAuditFixesTests(unittest.TestCase):
    def test_iss45_notification_handlers_enforce_main_thread_confinement(self):
        plugin_vc = (SOURCES / "PluginViewController.m").read_text(encoding="utf-8")
        refresh_body = plugin_vc.split("- (void)refreshStatus {", 1)[1].split("\n- (void)verifyPortReleasedAfterStop", 1)[0]
        self.assertIn("if(!NSThread.isMainThread)", refresh_body)

        cfg_vc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        cfg_rt = cfg_vc.split("- (void)runtimeStateDidChange {", 1)[1].split("\n- (void)viewDidLayoutSubviews", 1)[0]
        self.assertIn("if(!NSThread.isMainThread)", cfg_rt)

        svc_vc = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        detail_rt = svc_vc.split("- (void)runtimeStateDidChange {", 1)[1].split("\n- (void)probeIfStale", 1)[0]
        self.assertIn("if(!NSThread.isMainThread)", detail_rt)
        list_rt = svc_vc.split("- (void)runtimeStateDidChange {", 2)[2].split("\n- (void)refresh {", 1)[0]
        self.assertIn("if(!NSThread.isMainThread)", list_rt)

        sub_vc = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        meta_body = sub_vc.split("- (void)metadataChanged {", 1)[1].split("\n- (void)updateAction", 1)[0]
        self.assertIn("if(!NSThread.isMainThread)", meta_body)

    def test_iss46_timeshift_controller_weak_self_and_synchronized_bounded_copyright_cache(self):
        ts_m = (SOURCES / "CCTVTimeshiftController.m").read_text(encoding="utf-8")
        exec_body = ts_m.split("- (void)executePendingSeek {", 1)[1].split("\n- (void)checkCopyrightForStart:", 1)[0]
        self.assertIn("__weak typeof(self) weakSelf = self;", exec_body)
        self.assertIn("CCTVTimeshiftController *owner = weakSelf;", exec_body)

        chk_body = ts_m.split("- (void)checkCopyrightForStart:", 1)[1].split("\n- (void)issueSeekToStart:", 1)[0]
        self.assertGreaterEqual(chk_body.count("@synchronized(self)"), 1)
        self.assertIn("@synchronized(owner)", chk_body)
        self.assertIn("owner.copyrightCache.count >= 64", chk_body)

    def test_iss47_repeating_block_timers_self_invalidate_and_epg_uses_weak_self(self):
        cicada_m = (SOURCES / "MediaPlaybackCicadaAdapter.m").read_text(encoding="utf-8")
        poll_body = cicada_m.split("- (void)startPollTimer {", 1)[1].split("\n// ---------- 内部状态机", 1)[0]
        self.assertIn("[timer invalidate];", poll_body)

        info_m = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)dealloc {", info_m)
        timer_body = info_m.split("- (void)startAutoRefreshTimer {", 1)[1].split("\n- (void)stopAutoRefreshTimer", 1)[0]
        self.assertIn("[timer invalidate];", timer_body)

        epg_m = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        sched_body = epg_m.split("- (void)scheduleRefreshTimer {", 1)[1].split("\n- (void)cancelPageRequest", 1)[0]
        self.assertIn("[t invalidate];", sched_body)
        fetch_off = epg_m.split("- (void)fetchOfficial {", 1)[1].split("\n- (void)viewDidLayoutSubviews", 1)[0]
        self.assertNotIn("[self normalize:epg]", fetch_off)
        self.assertIn("[weakSelf normalize:epg]", fetch_off)

        metrics_m = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        badge_body = metrics_m.split("- (void)startLiveQualityBadgeTimer {", 1)[1].split(
            "\n- (PlaybackInfoViewController *)playbackInformationPage", 1
        )[0]
        self.assertIn("[timer invalidate];", badge_body)

    def test_iss48_kvo_removals_guarded_and_root_dealloc_cancels_subscription_edit_tasks(self):
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        stop_body = play_m.split("- (void)stopPlayback {", 1)[1].split("\n    self.epgListGeneration++;", 1)[0]
        # P1 cleanup: KVO removal goes through the shared guarded helper (still @try/@catch inside).
        self.assertIn('[self guardedRemoveObserverFrom:self.avPlayer.currentItem keyPath:@"playbackLikelyToKeepUp"', stop_body)
        self.assertIn('[self guardedRemoveObserverFrom:self.avLayer keyPath:@"readyForDisplay"', stop_body)
        root_src = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        helper = root_src.split("- (void)guardedRemoveObserverFrom:", 1)[1].split("\n", 1)[0]
        self.assertIn("@try{[object removeObserver:self forKeyPath:keyPath context:context];}", helper)
        self.assertIn("@catch(NSException *e){[self log:", helper)

        mp_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        stop_obs = mp_m.split("- (void)stopObservingCurrentPlayback {", 1)[1].split("\n- (void)observePlayerItem:", 1)[0]
        self.assertIn('MediaPlaybackGuardedTeardown(@"controllerReadyForDisplay",self.playerController,self,@"readyForDisplay",CCTVPlayerControllerReadyContext,nil);', stop_obs)
        self.assertIn('else if (observer && keyPath.length) [(NSObject *)target removeObserver:observer forKeyPath:keyPath context:context];', mp_m)

        root_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        dealloc_body = root_m.split("- (void)dealloc {", 1)[1].split("\n- (void)didReceiveMemoryWarning", 1)[0]
        self.assertIn("self.subscriptionEditTasks", dealloc_body)

    def test_iss49_subscription_replacement_uses_mapped_file_read_without_url_loader_risk(self):
        sub_m = (SOURCES / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        self.assertNotIn("dataWithContentsOfURL:", sub_m)
        self.assertIn("dataWithContentsOfFile:location.path options:NSDataReadingMappedIfSafe error:NULL", sub_m)

    def test_iss50_media_playback_state_store_synchronizes_all_readers(self):
        store_m = (SOURCES / "MediaPlaybackStateStore.m").read_text(encoding="utf-8")
        hist_entry = store_m.split("+ (NSDictionary *)historyEntryForContext:", 1)[1].split(
            "\n+ (NSDictionary *)latestHistoryForSourceID:", 1
        )[0]
        self.assertIn("@synchronized(self)", hist_entry)
        latest_entry = store_m.split("+ (NSDictionary *)latestHistoryForSourceID:", 1)[1].split(
            "\n+ (void)recordContext:", 1
        )[0]
        self.assertIn("@synchronized(self)", latest_entry)
        skip_pts = store_m.split("+ (NSDictionary *)skipPointsForContext:", 1)[1].split(
            "\n+ (NSTimeInterval)introEndForContext:", 1
        )[0]
        self.assertIn("@synchronized(self)", skip_pts)

    def test_iss51_iso8601_formatters_cached_and_synchronized_in_pyhost_and_diagnostics(self):
        pyhost_m = (SOURCES / "PyHost.m").read_text(encoding="utf-8")
        self.assertIn("static NSString *pythonISO8601Timestamp(void)", pyhost_m)
        diag_m = (SOURCES / "RuntimeDiagnostics.m").read_text(encoding="utf-8")
        self.assertIn("static NSString *RuntimeDiagnosticsISO8601String(NSDate *date)", diag_m)

    def test_iss52_and_iss53_and_iss54_regex_and_formatter_synchronization(self):
        settings_m = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&updateRegexOnce", settings_m)

        exp_m = (SOURCES / "TVBoxCatalogPackageExporter.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&md5RegexOnce", exp_m)

        imp_m = (SOURCES / "MediaPackageImporter.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&nanoRegexOnce", imp_m)
        self.assertIn("dispatch_once(&weboxMetaRegexOnce", imp_m)

        tv_m = (SOURCES / "TVBoxCatalogStore.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&originJsonRegexOnce", tv_m)

        epg_m = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (NSString *)dayKeyForTimestamp:(NSTimeInterval)ts", epg_m)


if __name__ == "__main__":
    unittest.main()
