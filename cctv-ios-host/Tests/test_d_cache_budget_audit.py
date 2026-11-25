"""D 阶段契约测试：缓存与运行时内存预算上限审计。

静态契约校验（本机不编译 iOS）四个缓存子系统的三项不变量：
  1. 统一有界 —— 每个缓存都有显式的条目数 / 字节上限常量并接入裁剪。
  2. 压力时清理顺序正确 —— HostMemoryBudgetCoordinator 先释放体量最大的图片位图缓存，
     再在 Critical 回收元数据内存；且 Critical 下对 MediaMetadataCache 只回收内存
     (evictMemoryCache)，不得调用 clear 抹除跨重启持久化的磁盘目录记录。
  3. LRU 键稳定 —— 各缓存键由确定性函数（SHA-256 / 固定格式串）派生，同一输入跨调用恒等。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def _read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


class CacheBudgetAuditContracts(unittest.TestCase):
    def setUp(self):
        self.budget_h = _read("HostMemoryBudgetCoordinator.h")
        self.budget_m = _read("HostMemoryBudgetCoordinator.m")
        self.image_m = _read("HostImageLoader.m")
        self.meta_m = _read("MediaMetadataCache.m")
        self.xmltv_m = _read("XMLTVStore.m")

    # ---- 1. 统一有界 ----
    def test_host_image_loader_cache_is_bounded(self):
        self.assertIn("_cache.countLimit=360", self.image_m)
        self.assertIn("_cache.totalCostLimit=32*1024*1024", self.image_m)
        # 失败标记缓存与域名状态缓存均有条目上限。
        self.assertIn("_failures.countLimit=200", self.image_m)
        self.assertIn("_domainFailures.countLimit=64", self.image_m)
        # 在途请求队列有界，避免无限制堆积。
        self.assertIn("ImageQueueLimit = 160", self.image_m)
        self.assertIn("ImageConcurrentLimit = 8", self.image_m)

    def test_media_metadata_cache_is_bounded(self):
        self.assertIn("MediaMetadataCacheEntryLimit = 64", self.meta_m)
        self.assertIn("MediaMetadataCacheByteLimit = 8 * 1024 * 1024", self.meta_m)
        self.assertIn("MediaMetadataCacheSingleEntryLimit = 1024 * 1024", self.meta_m)
        self.assertIn("MediaMetadataPersistentEntryLimit = 32", self.meta_m)
        self.assertIn("MediaMetadataPersistentByteLimit = 4 * 1024 * 1024", self.meta_m)
        # NSCache 接入上限并参与手动 LRU 裁剪循环。
        self.assertIn("_entries.countLimit=MediaMetadataCacheEntryLimit", self.meta_m)
        self.assertIn("_entries.totalCostLimit=MediaMetadataCacheByteLimit", self.meta_m)
        self.assertIn("while(self.order.count>MediaMetadataCacheEntryLimit)", self.meta_m)

    def test_xmltv_disk_cache_is_bounded(self):
        self.assertIn("XMLTVDiskEntryLimit = 16 * 1024 * 1024", self.xmltv_m)
        self.assertIn("XMLTVDiskTotalLimit = 64 * 1024 * 1024", self.xmltv_m)
        self.assertIn("XMLTVDiskFileCountLimit = 32", self.xmltv_m)
        # 盘上 LRU 裁剪循环按条目数与总字节双约束驱动。
        self.assertIn(
            "while(items.count>XMLTVDiskFileCountLimit||total>XMLTVDiskTotalLimit)",
            self.xmltv_m,
        )
        # 内存缓存在系统内存告警时自回收（与协调器/AppDelegate 多通路互补）。
        self.assertIn(
            'addObserver:s selector:@selector(evictMemoryCache) name:UIApplicationDidReceiveMemoryWarningNotification',
            self.xmltv_m,
        )

    # ---- 2. 压力时清理顺序正确 ----
    def test_coordinator_pressure_thresholds_defined(self):
        self.assertIn("HostMemoryWarningThresholdBytes  = 350ULL", self.budget_m)
        self.assertIn("HostMemoryCriticalThresholdBytes = 200ULL", self.budget_m)

    def test_coordinator_trims_images_before_metadata_in_order(self):
        body = self.budget_m.split("- (void)performTrimWithPressure:", 1)[1]
        img_pos = body.index("[HostImageLoader.shared clearCache]")
        meta_pos = body.index("[MediaMetadataCache.shared evictMemoryCache]")
        self.assertLess(img_pos, meta_pos, "图片缓存必须先于元数据缓存被回收")

    def test_coordinator_critical_uses_memory_only_eviction_not_clear(self):
        """Critical 压力下只能回收内存，不得抹除持久化磁盘目录记录。"""
        body = self.budget_m.split("- (void)performTrimWithPressure:", 1)[1]
        # 关键不变量：performTrimWithPressure 体内不得出现 [MediaMetadataCache.shared clear]
        self.assertNotIn("[MediaMetadataCache.shared clear]", body)
        self.assertIn("[MediaMetadataCache.shared evictMemoryCache]", body)
        # 仅 Critical 触发元数据回收（Warning 仅裁图片）。
        self.assertIn(
            "if (pressure == HostMemoryBudgetPressureCritical) {\n        [MediaMetadataCache.shared evictMemoryCache];\n    }",
            body,
        )

    def test_coordinator_warning_level_skips_metadata(self):
        # Warning 阈值路径仅裁剪图片，不触及元数据（含 evictMemoryCache 的分支被 Critical 守卫）。
        body = self.budget_m.split("- (void)performTrimWithPressure:", 1)[1]
        head = body.split("if (pressure == HostMemoryBudgetPressureCritical)", 1)[0]
        self.assertIn("[HostImageLoader.shared clearCache]", head)
        self.assertNotIn("MediaMetadataCache", head)

    def test_coordinator_and_appdelegate_use_memory_only_for_pressure(self):
        """压力/告警通路统一用 evictMemoryCache；clear 仅留给用户主动清理（Settings）。"""
        app = _read("AppDelegate.m")
        warn = app.split("applicationDidReceiveMemoryWarning", 1)[1]
        self.assertIn("[MediaMetadataCache.shared evictMemoryCache]", warn)
        self.assertIn("[XMLTVStore.shared evictMemoryCache]", warn)
        # 持久化 clear 是用户主动操作入口（SettingsViewController），不应出现在压力通路中。
        settings = _read("SettingsViewController.m")
        self.assertIn("[MediaMetadataCache.shared clear]", settings)

    # ---- 3. LRU 键稳定 ----
    def test_image_loader_cache_key_is_deterministic(self):
        # 键格式 "<maxPixelSize>|<url>"，同一 URL+尺寸跨调用恒等。
        self.assertIn('NSString *cacheKey=[NSString stringWithFormat:@"%lu|%@",(unsigned long)maximumPixelSize,url]',
                      self.image_m)

    def test_media_metadata_cache_key_is_sha256_hex(self):
        # 摘要键：JSON 排序键序列化后 SHA-256，64 位十六进制；持久化载入时按长度校验。
        self.assertIn("NSJSONWritingSortedKeys", self.meta_m)
        self.assertIn("CC_SHA256(data.bytes,(CC_LONG)data.length,digest)", self.meta_m)
        self.assertIn('[key length]!=64', self.meta_m)
        # 刷新/强制刷新标志不参与键恒等（避免强制刷新被误判为另一个缓存槽）。
        key_body = self.meta_m.split("- (NSString *)keyForSource:", 1)[1]
        self.assertIn('[k isEqual:@"refresh"]||[k isEqual:@"forceRefresh"]', key_body)

    def test_xmltv_disk_path_key_is_sha256_hex(self):
        self.assertIn("CC_SHA256(d.bytes,(CC_LONG)d.length,hash)", self.xmltv_m)
        # 盘上 LRU 以文件修改时间排序（读取时刷新 mtime），键与源 URL 一一对应。
        evict = self.xmltv_m.split("- (void)evictDiskCacheLocked", 1)[1]
        self.assertIn("[a[@\"date\"] compare:b[@\"date\"]]", evict)
        self.assertIn("NSFileModificationDate", self.xmltv_m)


if __name__ == "__main__":
    unittest.main()
