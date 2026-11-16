import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class PrincipalArchitectAuditFixesTests(unittest.TestCase):
    def test_media_jar_runtime_eliminates_forever_semaphore_and_leaks(self):
        jar = (SOURCES / "MediaJARRuntime.m").read_text(encoding="utf-8")
        # Semaphore waits must be bounded. DISPATCH_TIME_FOREVER still
        # legitimately appears once in the watchdog's one-shot timer
        # (dispatch_source_set_timer interval), which is not a wait.
        semaphore_waits = [line for line in jar.splitlines() if "dispatch_semaphore_wait" in line]
        self.assertTrue(semaphore_waits, "expected semaphore waits in MediaJARRuntime.m")
        for line in semaphore_waits:
            self.assertNotIn(
                "DISPATCH_TIME_FOREVER", line,
                "semaphore wait must be bounded, not DISPATCH_TIME_FOREVER",
            )
        self.assertIn("dispatch_semaphore_t dlSema=self.downloaded;if(dlSema)dispatch_semaphore_signal(dlSema);", jar)
        self.assertIn("@finally {\n            [session invalidateAndCancel];ticket.download=nil;", jar)

    def test_pyhost_uses_monotonic_relative_wait_and_async_foreground_rebind(self):
        pyhost = (SOURCES / "PyHost.m").read_text(encoding="utf-8")
        self.assertIn("pthread_cond_timedwait_relative_np(&gCondition, &gLock, &relWait);", pyhost)
        self.assertIn('fgQueue = dispatch_queue_create("com.cctvhost.pyhost.foreground", DISPATCH_QUEUE_SERIAL);', pyhost)
        self.assertIn("if (NSThread.isMainThread) dispatch_async(fgQueue, work);", pyhost)

    def test_profile_store_synchronizes_reads_offloads_large_payloads_and_optimizes_sort(self):
        prof = (SOURCES / "ProfileStore.m").read_text(encoding="utf-8")
        self.assertIn("+ (NSString *)payloadFilePathForSource:(NSString *)source", prof)
        self.assertIn('if(![dict[@"_hasDiskPayload"] boolValue])return dict;', prof)
        self.assertIn("NSMutableDictionary<NSString *,NSNumber *> *rankMap=[NSMutableDictionary dictionaryWithCapacity:order.count];", prof)

    def test_media_playback_sniffer_mutes_offscreen_media_and_blocks_ad_domains(self):
        mp = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("function muteAll(){try{document.querySelectorAll('video,audio')", mp)
        self.assertIn("function isAdURL(u){return /(?:doubleclick|googlesyndication", mp)
        self.assertIn("[web.configuration.userContentController removeAllUserScripts];", mp)
        self.assertIn('[web loadHTMLString:@"" baseURL:nil];', mp)

    def test_tvbox_catalog_store_and_log_redactor_cache_hot_paths(self):
        tv = (SOURCES / "TVBoxCatalogStore.m").read_text(encoding="utf-8")
        red = (SOURCES / "HostLogRedactor.m").read_text(encoding="utf-8")
        self.assertIn("static NSArray<NSDictionary *> *gCachedCatalogs = nil;", tv)
        self.assertIn("+ (void)invalidateCatalogsCache", tv)
        self.assertIn("static dispatch_once_t xtreamOnce;", red)

    def test_node_backoff_web_ssrf_guard_and_xmltv_thread_safety(self):
        node = (SOURCES / "NodePluginRuntime.m").read_text(encoding="utf-8")
        web = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        xml = (SOURCES / "XMLTVStore.m").read_text(encoding="utf-8")
        self.assertIn("[NSThread sleepForTimeInterval:(0.06 * (1 << retry))];", node)
        self.assertIn("(targetLoopback&&!pageLoopback)", web)
        self.assertIn('@synchronized(self){return self.cache[source][@"rows"][identifier.lowercaseString]?:@[];}', xml)


if __name__ == "__main__":
    unittest.main()
