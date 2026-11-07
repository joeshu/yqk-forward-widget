import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class UI2026PerformanceStabilityTests(unittest.TestCase):
    def test_01_media_metadata_cache_memory_warning_eviction(self):
        header = (SOURCES / "MediaMetadataCache.h").read_text(encoding="utf-8")
        impl = (SOURCES / "MediaMetadataCache.m").read_text(encoding="utf-8")
        self.assertIn("- (void)evictMemoryCache;", header)
        self.assertIn("UIApplicationDidReceiveMemoryWarningNotification", impl)
        self.assertIn("- (void)evictMemoryCache", impl)

    def test_02_xmltv_store_memory_warning_and_autoreleasepool_and_nil_guard(self):
        header = (SOURCES / "XMLTVStore.h").read_text(encoding="utf-8")
        impl = (SOURCES / "XMLTVStore.m").read_text(encoding="utf-8")
        self.assertIn("- (void)evictMemoryCache;", header)
        self.assertIn("UIApplicationDidReceiveMemoryWarningNotification", impl)
        self.assertIn("@autoreleasepool{XMLTVReader *reader=[XMLTVReader new];", impl)
        self.assertIn("if(!source.length||!identifier.length)return @[];", impl)

    def test_03_app_delegate_coordinated_memory_warning_purge(self):
        app_delegate = (SOURCES / "AppDelegate.m").read_text(encoding="utf-8")
        self.assertIn("[HostImageLoader.shared clearCache];", app_delegate)
        self.assertIn("[MediaMetadataCache.shared evictMemoryCache];", app_delegate)
        self.assertIn("[XMLTVStore.shared evictMemoryCache];", app_delegate)

    def test_04_media_source_health_store_in_memory_cache(self):
        health = (SOURCES / "MediaSourceHealthStore.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,strong) NSMutableDictionary *memoryRecords;", health)
        self.assertIn("if(!_memoryRecords)", health)

    def test_05_host_theme_specular_rim_frame_refresh_on_layout(self):
        theme = (SOURCES / "HostTheme.h").read_text(encoding="utf-8")
        self.assertIn("CAGradientLayer *specularRim=objc_getAssociatedObject(view,&HostSpecularRimAssociationKey);", theme)
        self.assertIn("if(specularRim)specularRim.frame=CGRectMake(0,0,CGRectGetWidth(view.bounds),MIN(1.2,CGRectGetHeight(view.bounds)));", theme)

    def test_06_sleep_timer_invalidation_in_dealloc_and_teardown(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("[self.liveSleepTimer invalidate];", root)
        self.assertGreaterEqual(playback.count("[self.mediaSleepTimer invalidate];"), 2)

    def test_07_config_center_detail_summary_memoization_cache(self):
        config = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("detailSummaryCache", config)
        self.assertIn("[self.detailSummaryCache removeAllObjects];", config)

    def test_08_media_feed_poster_cell_async_layer_drawing(self):
        feed = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("self.poster.layer.drawsAsynchronously=YES;", feed)

    def test_09_service_editor_json_format_size_guard(self):
        editor = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn("if (!raw.length || raw.length > 2 * 1024 * 1024) return;", editor)

    def test_10_host_image_loader_fast_fail_connectivity_and_domain_cache_purge(self):
        loader = (SOURCES / "HostImageLoader.m").read_text(encoding="utf-8")
        self.assertIn("config.waitsForConnectivity=NO;", loader)
        self.assertIn("[self.domainFailures removeAllObjects];", loader)

    def test_11_cross_platform_uikit_guards_for_macos_native_ci_tests(self):
        for filename in ("XMLTVStore.m", "MediaMetadataCache.m"):
            impl = (SOURCES / filename).read_text(encoding="utf-8")
            self.assertIn("#import <TargetConditionals.h>", impl)
            self.assertIn("#if TARGET_OS_IOS\n#import <UIKit/UIKit.h>\n#endif", impl)
            self.assertGreaterEqual(impl.count("#if TARGET_OS_IOS"), 2)

    def test_12_media_service_port_collision_deduplication_and_reassignment(self):
        service_store = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        import_workflow = (SOURCES / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("if([self isMediaService:resolved]&&(port<1024||port>65535||[usedPorts containsObject:@(port)]))", service_store)
        self.assertIn('if(![mutableService[@"builtin"] boolValue]&&[self isMediaService:mutableService])', service_store)
        self.assertIn("NSMutableSet *batchPorts=[NSMutableSet set];", import_workflow)
        self.assertIn("if(portBusy||HostLocalPortState((int)port)==1)", root)
        self.assertIn('if(![activeSource[@"port"] isEqual:owner.source[@"port"]])', browser)


if __name__ == "__main__":
    unittest.main()
