import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
PLUGINS = ROOT / "Plugins"
SCRIPTS = ROOT / "Scripts"

if str(PLUGINS) not in sys.path:
    sys.path.insert(0, str(PLUGINS))


class Round18CatchupDiagnosticsAndResourceRefactorTests(unittest.TestCase):
    def test_01_cctv_catchup_auto_play_without_tapping_continue(self):
        rvc_h = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        epg_m = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")

        self.assertIn("@property(nonatomic) BOOL nativeUserPaused;", rvc_h)
        self.assertIn("- (void)ensureNativeTimeshiftPlayingForTrigger:(NSString *)trigger;", rvc_h)
        self.assertIn("- (void)ensureNativeTimeshiftPlayingForTrigger:(NSString *)trigger {", play_m)
        self.assertIn('[self ensureNativeTimeshiftPlayingForTrigger:@"timeshift_prepared"];', play_m)
        self.assertIn('[self ensureNativeTimeshiftPlayingForTrigger:@"seek_succeed"];', play_m)
        self.assertIn('[weakSelf ensureNativeTimeshiftPlayingForTrigger:@"timeshift_seek_completed"];', play_m)
        self.assertIn('[weakSelf ensureNativeTimeshiftPlayingForTrigger:@"timeshift_post_settle"];', play_m)
        self.assertIn('[self ensureNativeTimeshiftPlayingForTrigger:@"playback_paused_during_timeshift"];', play_m)
        self.assertIn('BOOL timeshiftSwitchReady = (event == 19) || ((event == 6 || event == 7 || event == 8) && self.startupTrace.stages[@"prepared"] != nil);', play_m)
        self.assertIn("owner.livePlaybackSuspendedForNavigation=NO;owner.nativeUserPaused=NO;owner.liveMiniPlayerBar.hidden=YES;", epg_m)

    def test_02_diagnostic_log_fixes_playback_storm_loopback_backoff_and_spider_timeouts(self):
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        rvc_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        hil_m = (SOURCES / "HostImageLoader.m").read_text(encoding="utf-8")
        mp_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        mb_m = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        hmr_py = (PLUGINS / "host_media_runtime.py").read_text(encoding="utf-8")

        # 1. CNPlayer -12909 error callback storm suppression & UDRM route CDN fallback
        failed_body = play_m.split("- (void)player:(id)player playbackFailed:(NSError *)error {", 1)[1].split(
            "\n- (void)retryPlaybackWithAlternateSource", 1
        )[0]
        self.assertIn("if(self.nativePlaybackFailed)return;", failed_body)
        self.assertIn("self.nativeSessionDelegate=nil;self.nativeSessionID++;", failed_body)
        self.assertIn('if(player!=self.avPlayer)[self call:player sel:@"stop"];', failed_body)
        self.assertIn("error.code == -12909", failed_body)
        self.assertIn("[self.nativeCDNPreference applyRoute:self.requestedNativeRoute error:NULL];", failed_body)

        # 2. Loopback 127.0.0.1 / localhost / ::1 exempt from 60s image domain backoff
        self.assertIn('BOOL isLoopbackHost=([recordHost isEqualToString:@"127.0.0.1"]||[recordHost isEqualToString:@"localhost"]||[recordHost isEqualToString:@"::1"]);', hil_m)
        self.assertIn("BOOL isDomainTimeout=!isLoopbackHost&&", hil_m)
        self.assertIn("if([self domainStateForURL:queued.url]==domain)", hil_m)

        # 3. Python spider default timeout wrapper, urllib3 warning suppression, and bounded close()
        self.assertIn("warnings.filterwarnings('ignore', message='Unverified HTTPS request')", hmr_py)
        self.assertIn("urllib3.disable_warnings()", hmr_py)
        self.assertIn("_bounded_session_request", hmr_py)
        self.assertIn("acquired = self.lock.acquire(timeout=0.5)", hmr_py)

        # 4. MediaPlayback 502/504 loopback relay fast failover & MediaBrowser rebuild deduplication
        self.assertIn("BOOL relayGatewayDead=", mp_m)
        self.assertIn("if(relayGatewayDead)self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedCicadaPlayer;", mp_m)
        self.assertIn("if(currentSections.count>0&&!self.pendingHomeOffsetRestore&&[[self mediaFeedSections] isEqualToArray:currentSections])", mb_m)
        self.assertIn('if([relayRecord[@"event"] isEqualToString:@"media_relay_client_disconnected"])return;', rvc_m)

    def test_03_resource_page_architect_dashboard_and_card_hierarchy(self):
        cc_m = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,strong) UIView *topSpecularLine;", cc_m)
        self.assertIn("@property(nonatomic,strong) UILabel *capabilityBadge;", cc_m)
        self.assertIn("@property(nonatomic,strong) UIView *dashboardCard;", cc_m)
        self.assertIn("- (void)buildDashboardCard", cc_m)
        self.assertIn("- (void)updateDashboardCard", cc_m)
        self.assertIn("- (void)handleDashboardMetricTap:(UIButton *)sender", cc_m)
        self.assertIn("- (NSAttributedString *)attributedDetailForText:(NSString *)detailText font:(UIFont *)font", cc_m)
        self.assertIn("- (NSString *)capabilityTagForProfile:(NSDictionary *)profile", cc_m)
        self.assertIn('@"resource.dashboard.card"', cc_m)
        self.assertIn('@"resource.capability.badge"', cc_m)


if __name__ == "__main__":
    unittest.main()
