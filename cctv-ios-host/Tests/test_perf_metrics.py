import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
HEADER = (SOURCES / "HostPerfMetrics.h").read_text(encoding="utf-8")
IMPL = (SOURCES / "HostPerfMetrics.m").read_text(encoding="utf-8")
APP_DELEGATE = (SOURCES / "AppDelegate.m").read_text(encoding="utf-8")
ROOT_VC = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
CATALOG = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
EPG = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")
PLAYBACK = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
DIAGNOSTICS = (SOURCES / "RuntimeDiagnostics.m").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")
TRACE_H = (SOURCES / "PlaybackStartupTrace.h").read_text(encoding="utf-8")
TRACE_M = (SOURCES / "PlaybackStartupTrace.m").read_text(encoding="utf-8")
LEDGER_H = (SOURCES / "HostPerfAttemptLedger.h").read_text(encoding="utf-8")
LEDGER_C = (SOURCES / "HostPerfAttemptLedger.c").read_text(encoding="utf-8")


def method_body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
    raise AssertionError("unbalanced method body: " + signature)


def strip_comments_and_strings(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'@?"(?:\\.|[^"\\])*"', '""', text)
    text = re.sub(r"'(?:\\.|[^'\\])'", "''", text)
    return text


class HostPerfMetricsSourceContractTests(unittest.TestCase):
    def test_sources_are_balanced(self):
        # New files must balance as a whole; for edited legacy files only the touched
        # method bodies are checked (the legacy files contain literals this lightweight
        # stripper cannot model exactly).
        regions = {
            "HostPerfMetrics.h": HEADER,
            "HostPerfMetrics.m": IMPL,
            "AppDelegate.didFinishLaunching": method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:"),
            "EPG.schedulePostFirstScreenStartupTasks": method_body(EPG, "- (void)schedulePostFirstScreenStartupTasks"),
            "Root.viewDidAppear": method_body(ROOT_VC[ROOT_VC.index("@implementation RootViewController"):], "- (void)viewDidAppear:(BOOL)animated"),
            "Catalog.loadChannels": method_body(CATALOG, "- (void)loadChannels"),
            "EPG.loadEPGCache": method_body(EPG, "- (void)loadEPGCache"),
            "Playback.recordStartupStage": method_body(PLAYBACK, "- (void)recordStartupStage:(NSString *)stage"),
            "Diagnostics.didReceiveMetricPayloads": method_body(DIAGNOSTICS, "- (void)didReceiveMetricPayloads:"),
            "Diagnostics.didReceiveDiagnosticPayloads": method_body(DIAGNOSTICS, "- (void)didReceiveDiagnosticPayloads:"),
        }
        for name, text in regions.items():
            code = strip_comments_and_strings(text)
            for opening, closing in ("{}", "()", "[]"):
                self.assertEqual(code.count(opening), code.count(closing), f"{name} {opening}{closing}")
        impl = strip_comments_and_strings(IMPL)
        self.assertEqual(impl.count("@implementation"), 1)
        self.assertEqual(impl.count("@interface"), 1)
        self.assertEqual(impl.count("@end"), 2)

    def test_header_declares_public_api(self):
        for marker in (
            "@interface HostPerfMetrics : NSObject", "+ (instancetype)shared;",
            "processStartEpoch", "prewarmedLaunch", "hasReachedFirstScreen",
            "- (void)markLaunchStarted;", "- (void)markDidFinishLaunching;",
            "- (BOOL)markFirstScreenInteractive:(NSString *)screen;",
            "recordFirstFrameWithEngine:(NSString *)engine", "channelID:(nullable NSString *)channelID",
            "elapsedSeconds:(NSTimeInterval)elapsedSeconds", "- (NSArray<NSDictionary<NSString *, id> *> *)recentEntries;",
            "- (NSDictionary<NSString *, id> *)summary;", "- (nullable NSData *)exportJSONData;",
            "exportJSONToTemporaryFileWithError:", "NS_ASSUME_NONNULL_BEGIN", "NS_ASSUME_NONNULL_END",
        ):
            self.assertIn(marker, HEADER)

    def test_process_start_comes_from_sysctl_kern_proc(self):
        for marker in ("#include <sys/sysctl.h>", "struct kinfo_proc", "CTL_KERN, KERN_PROC, KERN_PROC_PID",
                       "getpid()", "kp_proc.p_starttime", "tv_usec", "ActivePrewarm"):
            self.assertIn(marker, IMPL)

    def test_ring_buffer_keeps_latest_fifty_entries(self):
        self.assertIn("NSUInteger const HostPerfMetricsRingCapacity = 50;", IMPL)
        emit = method_body(IMPL, "- (void)emit:(NSString *)event")
        self.assertIn("@synchronized (self)", emit)
        self.assertIn("while (self.ring.count > HostPerfMetricsRingCapacity) [self.ring removeObjectAtIndex:0];", emit)
        self.assertIn("[RuntimeDiagnostics.shared recordEvent:event category:HostPerfMetricsCategory", emit)
        self.assertIn('HostPerfMetricsCategory = @"performance"', IMPL)

    def test_perf_events_are_emitted(self):
        for event in ("perf_process_start", "perf_did_finish_launching", "perf_first_screen_interactive",
                      "perf_first_frame", "perf_launch_first_frame", "perf_channel_switch"):
            self.assertIn(f'@"{event}"', IMPL)
        self.assertIn('[name hasPrefix:@"perf_"]', IMPL)

    def test_json_export_summary(self):
        for marker in ('@"cctvhost.perf.v1"', '@"first_frame_by_engine"', '@"channel_switch"', '@"recent"',
                       '@"launch"', "NSJSONSerialization isValidJSONObject", "NSJSONWritingSortedKeys",
                       "NSTemporaryDirectory()", "NSDataWritingAtomic"):
            self.assertIn(marker, IMPL)

    def test_first_screen_is_one_shot(self):
        body = method_body(IMPL, "- (BOOL)markFirstScreenInteractive:")
        self.assertIn("if (self.firstScreenMarked) return NO;", body)
        self.assertIn("return YES;", body)

    def test_app_delegate_marks_launch_milestones(self):
        launch = method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:")
        self.assertIn('#import "HostPerfMetrics.h"', APP_DELEGATE)
        self.assertLess(launch.index("beginAppSessionWithFields:"), launch.index("[HostPerfMetrics.shared markLaunchStarted];"))
        self.assertLess(launch.index("makeKeyAndVisible"), launch.index("[HostPerfMetrics.shared markDidFinishLaunching];"))
        self.assertLess(launch.index("markDidFinishLaunching"), launch.index("return YES;"))

    def test_first_frame_reuses_startup_trace_frame_stage_by_engine(self):
        body = method_body(PLAYBACK, "- (void)recordStartupStage:(NSString *)stage")
        self.assertIn("if(![self.startupTrace record:stage atTime:CACurrentMediaTime()])return;", body)
        self.assertIn('[stage isEqualToString:@"frame"]', body)
        self.assertIn('recordFirstFrameWithEngine:(self.remoteAdapter?@"cicada":(self.currentRemoteURL.length?@"avplayer":@"cnplayer"))', body)
        self.assertIn('channelID:self.channelID elapsedSeconds:[self.startupTrace.stages[@"frame"] doubleValue] stages:self.startupTrace.stages', body)
        internal = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        self.assertIn('#import "HostPerfMetrics.h"', internal)


class StartupDeferralContractTests(unittest.TestCase):
    def setUp(self):
        start = ROOT_VC.index("@implementation RootViewController")
        self.root_impl = ROOT_VC[start:]
        self.view_did_load = method_body(self.root_impl, "- (void)viewDidLoad {")
        self.view_did_appear = method_body(self.root_impl, "- (void)viewDidAppear:(BOOL)animated")
        self.deferred = method_body(EPG, "- (void)schedulePostFirstScreenStartupTasks")

    def test_non_first_screen_work_left_view_did_load(self):
        self.assertNotIn("[PyHost recoverInterruptedPythonSessions]", self.view_did_load)
        self.assertNotIn("[self installBundledMediaResourcesIfNeeded]", self.view_did_load)
        self.assertNotIn("[self loadEPGCache]", method_body(CATALOG, "- (void)loadChannels").replace(
            "if (HostPerfMetrics.shared.hasReachedFirstScreen) [self loadEPGCache];", ""))
        self.assertIn("if (HostPerfMetrics.shared.hasReachedFirstScreen) [self loadEPGCache];", CATALOG)

    def test_first_screen_work_stays_in_view_did_load(self):
        for marker in ("[self loadChannels];", "[self buildPlayer];", "[self buildList];", "[self setupSDK];",
                       "[MediaPackageImporter migrateLegacyRuntimeMetadata];", "[self restoreDiagnosticLog];"):
            self.assertIn(marker, self.view_did_load)

    def test_deferred_tasks_run_once_after_first_appearance_on_main_queue(self):
        self.assertIn("if([HostPerfMetrics.shared markFirstScreenInteractive:NSStringFromClass(self.class)])[self schedulePostFirstScreenStartupTasks];", self.view_did_appear)
        self.assertLess(self.view_did_appear.index("schedulePostFirstScreenStartupTasks"), self.view_did_appear.index("if(!self.initialTabRestorePending)return;"))
        self.assertIn("dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue()", self.deferred)
        self.assertIn("__weak typeof(self) weakSelf=self;", self.deferred)
        for marker in ("[PyHost recoverInterruptedPythonSessions];", "[owner loadEPGCache];",
                       "[owner installBundledMediaResourcesIfNeeded];", "[owner reloadActiveCatalogView]",
                       '@"perf_deferred_startup_tasks"'):
            self.assertIn(marker, self.deferred)

    def test_deferred_entry_is_declared_for_cross_module_call(self):
        internal = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        epg_interface = internal[internal.index("@interface RootViewController (EPG)"):]
        epg_interface = epg_interface[:epg_interface.index("@end")]
        self.assertIn("- (void)schedulePostFirstScreenStartupTasks;", epg_interface)
        self.assertIn('#import "HostPerfMetrics.h"', EPG)
        self.assertIn('#import "HostPerfMetrics.h"', ROOT_VC)

    def test_deferred_epg_cache_does_not_overwrite_fresh_entries(self):
        body = method_body(EPG, "- (void)loadEPGCache")
        self.assertIn("!self.epgCache[key]) self.epgCache[key] = obj;", body)


class MetricKitContractTests(unittest.TestCase):
    def test_metrickit_is_linked_and_subscribed(self):
        self.assertIn("sdk: MetricKit.framework", PROJECT)
        self.assertIn("#import <MetricKit/MetricKit.h>", DIAGNOSTICS)
        self.assertIn("[[MXMetricManager sharedManager] addSubscriber:self]", DIAGNOSTICS)

    def test_diagnostic_payload_records_crash_and_hang_summaries(self):
        body = method_body(DIAGNOSTICS, "- (void)didReceiveDiagnosticPayloads:")
        for marker in ("payload.crashDiagnostics", "metrickit_crash_diagnostic_received",
                       "MXHangDiagnostic *hang in payload.hangDiagnostics", "hang.hangDuration",
                       "NSUnitDuration.seconds", "hang_duration_ms", "metrickit_hang_diagnostic_received",
                       "metrickit_diagnostic_payload_summary", "cpu_exception_count", "disk_write_exception_count"):
            self.assertIn(marker, body)
        self.assertIn("if (!self.enabled) return;", body)

    def test_metric_payload_records_launch_histogram(self):
        body = method_body(DIAGNOSTICS, "- (void)didReceiveMetricPayloads:")
        for marker in ("payload.applicationLaunchMetrics", "histogrammedTimeToFirstDraw", "bucketEnumerator",
                       "MXHistogramBucket<NSUnitDuration *>", "perf_metrickit_launch_metrics", "report_is_aggregate"):
            self.assertIn(marker, body)


class AttemptLedgerContractTests(unittest.TestCase):
    """T01 (PERF-07) wiring contracts. The accounting behavior itself is
    executed by Tests/test_perf_metrics_attempt_accounting.py against the
    production C ledger; these tests pin the ObjC integration points."""

    def test_header_declares_attempt_lifecycle(self):
        for marker in (
            "beginPlaybackAttemptWithSessionID:(nullable NSString *)sessionID",
            "attemptID:(nullable NSString *)attemptID",
            "generation:(NSUInteger)generation",
            "sourceRevision:(NSUInteger)sourceRevision",
            "recordPlaybackAttemptFirstAudio:",
            "recordPlaybackAttemptFirstVideo:",
            "recordPlaybackAttemptFailed:",
            "recordPlaybackAttemptCancelled:",
            "cancelPendingPlaybackAttempt;",
        ):
            self.assertIn(marker, HEADER)

    def test_ledger_is_pure_c_bounded_and_io_free(self):
        self.assertNotIn("Foundation", LEDGER_H)
        self.assertNotIn("Foundation", LEDGER_C)
        self.assertIn("#define HOST_PERF_LEDGER_MAX_ATTEMPTS 128", LEDGER_H)
        self.assertIn("#define HOST_PERF_LEDGER_HISTOGRAM_BUCKETS 11", LEDGER_H)
        for banned in ("fopen", "malloc", "NSLog", "NSURL", "NSDictionary"):
            self.assertNotIn(banned, LEDGER_C)
        for marker in ("HostPerfLedgerQuantileMs", "HostPerfLedgerSuccessRate",
                       "HostPerfLedgerHashString", "stale_ignored",
                       "duplicate_ignored", "superseded"):
            self.assertIn(marker, LEDGER_H)

    def test_metrics_feeds_ledger_and_emits_attempt_events(self):
        for marker in ('#import "HostPerfAttemptLedger.h"', "HostPerfLedgerInit",
                       "HostPerfLedgerBegin", "HostPerfLedgerMarkFirstVideo",
                       "HostPerfLedgerMarkFailed", "HostPerfLedgerMarkCancelled",
                       '@"perf_attempt_started"', '@"perf_attempt_first_video"',
                       '@"perf_attempt_first_audio"', '@"perf_attempt_failed"',
                       '@"perf_attempt_cancelled"', '@"attempts"',
                       "CACurrentMediaTime() * 1000.0"):
            self.assertIn(marker, IMPL)
        summary = method_body(IMPL, "- (NSDictionary<NSString *, id> *)summary")
        self.assertIn('summary[@"attempts"] = [self attemptSummary];', summary)

    def test_attempt_events_carry_no_url_or_header(self):
        # Attempt events must never contain URLs, headers or media content.
        for signature in (
            "- (void)beginPlaybackAttemptWithSessionID:",
            "- (void)recordPlaybackAttemptFailed:",
            "- (void)recordPlaybackAttemptFirstVideo:",
        ):
            body = method_body(IMPL, signature).lower()
            self.assertNotIn("url", body)
            self.assertNotIn("header", body)
            self.assertNotIn("media", body)

    def test_legacy_first_frame_still_works_unattributed(self):
        wrapper = method_body(IMPL, "- (void)recordFirstFrameWithEngine:(NSString *)engine\n                         channelID:(NSString *)channelID\n                    elapsedSeconds:(NSTimeInterval)elapsedSeconds\n                            stages:(NSDictionary<NSString *, NSNumber *> *)stages {")
        self.assertIn("attemptID:nil generation:0 sourceRevision:0", wrapper)

    def test_trace_rejects_stale_identity(self):
        for marker in ("@property(nonatomic, readonly, copy, nullable) NSString *attemptID;",
                       "@property(nonatomic, readonly) NSUInteger generation;",
                       "initWithStartTime:(NSTimeInterval)time\n                        attemptID:(nullable NSString *)attemptID",
                       "record:(NSString *)stage\n        atTime:(NSTimeInterval)time\n     attemptID:"):
            self.assertIn(marker, TRACE_H)
        body = method_body(TRACE_M, "- (BOOL)record:(NSString *)stage\n        atTime:(NSTimeInterval)time\n     attemptID:(NSString *)attemptID")
        self.assertIn("if (self.attemptID.length &&", body)
        self.assertIn("generation != self.generation", body)

    def test_controller_wires_attempt_lifecycle(self):
        self.assertGreaterEqual(PLAYBACK.count("beginPlaybackAttemptWithSessionID:"), 3)
        self.assertIn("attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration sourceRevision:self.selectionVersion", PLAYBACK)
        self.assertGreaterEqual(PLAYBACK.count("recordPlaybackAttemptFailed:"), 2)
        self.assertIn("userAction:@\"auto_recovery\"", PLAYBACK)
        self.assertIn("[HostPerfMetrics.shared cancelPendingPlaybackAttempt]", ROOT_VC)


if __name__ == "__main__":
    unittest.main()
