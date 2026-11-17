"""Regression tests for Round 5 Principal Architect Audit & Fixes (ISS-35 through ISS-44)."""
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"
for _p in (ROOT / "Plugins", ROOT / "Scripts"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


class Round5PrincipalArchitectAuditFixesTests(unittest.TestCase):
    def test_iss35_plugin_resource_detail_session_invalidation_and_main_queue_delegate(self):
        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertIn("delegate:self delegateQueue:NSOperationQueue.mainQueue", plug_m)
        self.assertIn(
            "if(!self||generation!=self.probeGeneration){[session finishTasksAndInvalidate];return;}",
            plug_m,
        )
        self.assertIn(
            "if(!owner||generation!=owner.probeGeneration){[epgSession finishTasksAndInvalidate];return;}",
            plug_m,
        )
        next_body = plug_m.split("- (void)probeNextPlaylistPath {", 1)[1].split(
            "\n- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1
        )[0]
        self.assertIn("if(self.probePathIndex>=self.probePaths.count){", next_body)
        self.assertIn("[self.probeSession finishTasksAndInvalidate];self.probeSession=nil;", next_body)

    def test_iss36_xmltv_store_synchronizes_all_cache_mutations_and_caches_directory(self):
        xml_m = (SOURCES / "XMLTVStore.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(xml_m.count("@synchronized(self)"), 6)
        path_body = xml_m.split("- (NSString *)pathForSource:(NSString *)s {", 1)[1].split(
            "\n- (NSArray *)cachedRowsForSource:", 1
        )[0]
        self.assertIn("dispatch_once(&onceToken", path_body)
        evict_body = xml_m.split("- (void)evictMemoryCache {", 1)[1].split("\n- (void)clear {", 1)[0]
        self.assertIn("@synchronized(self){[self.cache removeAllObjects];}", evict_body)

    def test_iss37_sniff_fetch_and_hls_route_probe_synchronize_cross_thread_state(self):
        sniff_m = (SOURCES / "MediaPlaybackSniffFetch.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(sniff_m.count("@synchronized(self)"), 6)

        hls_m = (SOURCES / "HLSRouteProbe.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(hls_m.count("@synchronized(self)"), 7)
        self.assertIn(
            'BOOL downgrade = [response.URL.scheme.lowercaseString isEqualToString:@"https"] && [request.URL.scheme.lowercaseString isEqualToString:@"http"];',
            hls_m,
        )

    def test_iss38_tvbox_and_package_downloaders_synchronize_finish_and_buffer_mutations(self):
        tvdl_m = (SOURCES / "TVBoxCatalogDownloader.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(tvdl_m.count("@synchronized(self)"), 5)
        finish_body = tvdl_m.split("- (void)finish:(NSDictionary *)catalog error:(NSError *)error {", 1)[1].split(
            "\n- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:", 1
        )[0]
        self.assertIn("self.session=nil;self.task=nil;self.data=nil;", finish_body)
        self.assertLess(
            finish_body.index("self.session=nil;self.task=nil;self.data=nil;"),
            finish_body.index("[session invalidateAndCancel];"),
        )

        pkg_m = (SOURCES / "MediaPackageDownloader.m").read_text(encoding="utf-8")
        pkg_finish = pkg_m.split("- (void)finish:(NSDictionary *)service error:(NSError *)error {", 1)[1].split(
            "\n- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:", 1
        )[0]
        self.assertIn("self.session=nil;self.task=nil;self.body=nil;self.scriptData=nil;", pkg_finish)
        self.assertLess(
            pkg_finish.index("self.session=nil;self.task=nil;self.body=nil;self.scriptData=nil;"),
            pkg_finish.index("[session invalidateAndCancel];"),
        )

    def test_iss39_host_sync_request_preserves_timeout_error_and_synchronizes_response(self):
        sync_m = (SOURCES / "HostSyncRequest.m").read_text(encoding="utf-8")
        self.assertIn(
            'if(dispatch_semaphore_wait(self.done,dispatch_time(DISPATCH_TIME_NOW,13*NSEC_PER_SEC))!=0){@synchronized(self){if(!self.failure.length)self.failure=@"同步 JS 请求超时";}[self cancel];}',
            sync_m,
        )
        self.assertIn("if(failure.length&&!self.failure.length)self.failure=failure;", sync_m)
        self.assertIn("if(valid){@synchronized(self){self.response=(id)response;}}", sync_m)

    def test_iss40_vip_native_stream_resolver_cancels_timed_out_tasks_and_synchronizes_result(self):
        mp_m = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        vip_body = mp_m.split("static void MediaPlaybackResolveVIPNativeStream(", 1)[1].split(
            "\n- (void)sniffNativeStreamFromPageResult:", 1
        )[0]
        self.assertIn("if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)))!=0)[pTask cancel];", vip_body)
        self.assertIn("if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)))!=0)[cTask cancel];", vip_body)
        self.assertIn("@synchronized(sess)", vip_body)

    def test_iss41_python_runtime_strict_loopback_hostname_and_locked_maccms_cache(self):
        hmr_py = (ROOT / "Plugins" / "host_media_runtime.py").read_text(encoding="utf-8")
        self.assertNotIn("if ('127.0.0.1' in low or 'localhost' in low) and not is_direct:", hmr_py)
        self.assertIn("host_low = (parsed.hostname or '').lower() if parsed else ''", hmr_py)
        self.assertIn("if host_low in ('127.0.0.1', 'localhost', '::1') and not is_direct:", hmr_py)
        self.assertIn("with requests.get(url, timeout=2.5, stream=True) as probe:", hmr_py)

        csp_py = (ROOT / "Plugins" / "csp_adapter.py").read_text(encoding="utf-8")
        self.assertIn("_MACCMS_CACHE_LOCK = _threading.Lock()", csp_py)
        self.assertGreaterEqual(csp_py.count("with _MACCMS_CACHE_LOCK:"), 3)

    def test_iss42_date_formatters_and_utc_calendar_cached_in_hot_paths(self):
        m3u_m = (SOURCES / "M3UParser.m").read_text(encoding="utf-8")
        catchup_body = m3u_m.split("- (NSURL *)catchupURLForStart:(NSDate *)start end:(NSDate *)end {", 1)[1].split(
            "\n@end", 1
        )[0]
        self.assertNotIn("[NSDateFormatter new]", catchup_body)
        self.assertIn("static NSCalendar *utcCalendar=nil;", catchup_body)

        svc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("static NSString *ServiceFormatDateWithPattern(NSDate *date, NSString *pattern)", svc_m)
        cell_body = svc_m.split("- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {", 1)[1].split(
            "\n- (void)changeService:", 1
        )[0]
        self.assertNotIn("[NSDateFormatter new]", cell_body)

        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        row_body = plug_m.split("- (NSDictionary *)rowAt:(NSIndexPath *)ip {", 1)[1].split(
            "\n- (UITableViewCell *)tableView:", 1
        )[0]
        self.assertNotIn("[NSDateFormatter new]", row_body)
        self.assertIn("PluginResourceFormattedTimestamp(updated)", row_body)

    def test_iss43_and_iss44_regex_patterns_cached_via_dispatch_once(self):
        router_m = (SOURCES / "MediaPlaybackDecodeRouter.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&mpdOnce", router_m)

        rvc_h = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&pathReOnce", rvc_h)

        wf_m = (SOURCES / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&splitOnce", wf_m)
        self.assertIn("dispatch_once(&extractOnce", wf_m)

        api_m = (SOURCES / "MediaAPIClient.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&tplOnce", api_m)

        ss_m = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        self.assertIn("dispatch_once(&portRegexOnce", ss_m)
        self.assertIn("dispatch_once(&m3uRouteOnce", ss_m)
        self.assertIn("dispatch_once(&epgRouteOnce", ss_m)


if __name__ == "__main__":
    unittest.main()
