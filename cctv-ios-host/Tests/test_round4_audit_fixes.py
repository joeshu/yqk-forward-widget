"""Regression tests for Round 4 Principal Architect Audit & Fixes (ISS-25 through ISS-34)."""
import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Round4PrincipalArchitectAuditFixesTests(unittest.TestCase):
    def test_iss25_udrm_embedded_sources_compile_and_source_audit_checks_embedded_ast(self):
        source_audit = _load_module("source_audit", ROOT / "Scripts" / "source_audit.py")

        for rel in ("cctv-app-udrm/cctv-app-udrm.py", "cctv-app-udrm/cctv-app-udrm-v0.3.7.py"):
            rec = source_audit.inspect(rel)
            self.assertNotIn("error", rec, f"source_audit reported error for {rel}: {rec.get('error')}")
            self.assertIn("python_ast", rec["checks"])
            self.assertIn("embedded_python_ast", rec["checks"])

            path = REPO / rel
            module = _load_module(path.stem.replace("-", "_"), path)
            loaded = module.load_modules()
            self.assertTrue(hasattr(loaded, "CHANNEL_ROUTES") and hasattr(loaded, "main"))

    def test_iss26_and_iss28_adaptation_monitor_bounded_stream_probe_and_thread_safety(self):
        mon = (SOURCES / "MediaAdaptationMonitor.m").read_text(encoding="utf-8")
        self.assertIn("static const NSUInteger MediaAdaptationProbeByteLimit = 4096;", mon)
        self.assertIn("@interface CCTVAdaptationStreamProbe : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>", mon)
        self.assertIn("[CCTVAdaptationStreamProbe probeWithRequest:req completion:", mon)
        self.assertIn("- (NSString *)formattedTimestampForDate:(NSDate *)date", mon)
        self.assertIn("@synchronized(self.timeFormatter)", mon)
        self.assertIn("self.persistScheduled", mon)

    def test_iss27_root_timers_use_weak_self_blocks_to_break_retain_cycles(self):
        epg_m = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")
        play_m = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")

        restart_body = epg_m.split("- (void)restartEPGTimer {", 1)[1].split("\n- (void)refreshNowNext", 1)[0]
        self.assertNotIn("target:self", restart_body)
        self.assertIn("scheduledTimerWithTimeInterval:60 repeats:YES block:", restart_body)
        self.assertIn("if (!strongSelf) { [timer invalidate]; return; }", restart_body)

        watchdog_body = play_m.split("- (void)startWatchdog {", 1)[1].split("\n- (BOOL)recoverNativeStartupForReason:", 1)[0]
        self.assertNotIn("target:self", watchdog_body)
        self.assertIn("scheduledTimerWithTimeInterval:0.5 repeats:YES block:", watchdog_body)
        self.assertIn("if (!strongSelf) { [timer invalidate]; return; }", watchdog_body)

    def test_iss29_config_center_and_services_probe_always_invalidate_url_sessions(self):
        cfg_m = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        svc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")

        notify_chunk = cfg_m.split("dispatch_group_notify(group,dispatch_get_main_queue(),^{", 1)[1].split("});", 1)[0]
        self.assertLess(
            notify_chunk.index("[session finishTasksAndInvalidate];"),
            notify_chunk.index("if(!owner)return;"),
        )

        probe_chunk = svc_m.split("- (void)probe {", 1)[1].split("\n- (void)restart {", 1)[0]
        self.assertIn("[self.probeSession invalidateAndCancel];self.probeSession=nil;", probe_chunk)
        self.assertIn("[createdSession finishTasksAndInvalidate];", probe_chunk)
        self.assertLess(
            probe_chunk.index("[createdSession finishTasksAndInvalidate];"),
            probe_chunk.index("if(!w||generation!=w.probeGeneration)return;"),
        )

    def test_iss30_media_channel_probe_synchronizes_cancel_and_delegate_callbacks(self):
        probe_m = (SOURCES / "MediaChannelProbe.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(probe_m.count("@synchronized(self)"), 6)
        cancel_body = probe_m.split("- (void)cancel {", 1)[1].split("\n- (void)finishWithError:", 1)[0]
        self.assertIn("@synchronized(self)", cancel_body)

    def test_iss31_csp_adapter_bounded_reads_and_worker_cap(self):
        csp_src = (ROOT / "Plugins" / "csp_adapter.py").read_text(encoding="utf-8")
        self.assertNotIn("r.read(4 * 1024 * 1024)", csp_src)
        self.assertIn("_HTTP_READ_CHUNK_BYTES = 512 * 1024", csp_src)
        self.assertIn("ThreadPoolExecutor(max_workers=4)", csp_src)

    def test_iss32_plugin_log_store_truncates_newline_free_tails_and_aligns_utf8(self):
        log_m = (SOURCES / "PluginLogStore.m").read_text(encoding="utf-8")
        self.assertIn("(bytes[startOffset]&0xC0)==0x80", log_m)
        self.assertIn("NSStringEncodingDetectionAllowLossyKey", log_m)

    def test_iss33_stream_metrics_scopes_preview_headers_and_caches_directory(self):
        metrics_m = (SOURCES / "RootViewController+StreamMetrics.m").read_text(encoding="utf-8")
        dir_body = metrics_m.split("- (NSString *)channelPreviewCacheDirectory {", 1)[1].split(
            "\n- (NSString *)channelPreviewDiskPathForChannelID:", 1
        )[0]
        self.assertIn("dispatch_once(&onceToken", dir_body)
        detect_body = metrics_m.split("- (void)detectRealPreviewFrameForChannel:(NSDictionary *)channel force:(BOOL)force {", 1)[1]
        self.assertIn("MediaPlaybackHeadersScopedToURL(rawHeaders,probeURL,probeURL)", detect_body)

    def test_iss34_hot_regex_caching_and_dealloc_sniff_task_cleanup(self):
        diag_m = (SOURCES / "RuntimeDiagnostics.m").read_text(encoding="utf-8")
        safe_body = diag_m.split("- (NSString *)safeText:(NSString *)text {", 1)[1].split(
            "\n- (void)prepareExportWithCompletion:", 1
        )[0]
        self.assertIn("dispatch_once(&regexOnce", safe_body)

        mp_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        dealloc_body = mp_m.split("- (void)dealloc {", 1)[1].split("\n- (void)updateEstimatedThroughput", 1)[0]
        self.assertIn("[self.streamSniffTask cancel];self.streamSniffTask=nil;", dealloc_body)
        self.assertIn("dispatch_once(&paOnce", mp_m)


if __name__ == "__main__":
    unittest.main()
