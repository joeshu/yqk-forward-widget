"""B4/T18 · 图片全链路（PERF-01–05）行为测试

只读取 Sources 文本断言不变量 + 对磁盘 LRU 算法跑 Python 模型验证，不触发构建/网络/CI。
对应审计：PERF-01 磁盘缓存无容量/TTL/淘汰；PERF-02 解码与磁盘 I/O 共用协调队列；
PERF-03 内存缓存与在途压缩体混账；PERF-04 域退避移除的请求无终结通知；
PERF-05 清盘与写盘分属两条路径（清盘后旧请求可能回写）。

T18 改动（Sources/HostImageLoader.m/.h）：
1. PERF-01 磁盘 LRU：128 MiB / 30 天 TTL / 超限清至 80% / 每遍最多删 50 个，
   后台分批执行；写盘走磁盘队列（JPEG 编码也在磁盘队列）。
2. PERF-02 解码分离：NSOperationQueue（并发 2）做 ImageIO 缩略图解码，
   磁盘队列串行写盘；协调/网络仍走原串行 _queue。
3. PERF-03 分别计费：内存缓存 / 在途压缩体 / 磁盘缓存各一栏 + statisticsSnapshot。
4. PERF-04 统一终结：finishRequest 至多完成一次；取消与退避移除都终结观察者，
   取消时 retryAfter 强制为 0（不复活已取消的请求）。
5. PERF-05 清盘与写盘同一 epoch 门禁：clearDiskCache 自增 diskEpoch 并在磁盘队列
   删目录，旧 epoch 的写盘请求直接丢弃。

语义不变：请求合并/下采样/退避/NSCache 32 MiB/360 项/8 并发/160 待办/单体 body
2/4 MiB/预取每批 6 项、generation 守卫、view 二次比对均保留（见
test_d_image_prefetch_audit_contracts.py 与 test_jar_progressive_support.py）。
"""
import os
import shutil
import tempfile
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


# --- 磁盘 LRU 的 Python 模型（与 HostImageLoader.m 的 trimDiskCacheOnDiskQueue 同算法） ---
DISK_LIMIT = 128 * 1024 * 1024
DISK_TTL = 30 * 24 * 3600
DISK_TRIM_TARGET = int(128 * 1024 * 1024 * 0.8)
DISK_BATCH = 50


def trim_model(entries, now):
    """entries: [{'path','size','mtime'}]。返回 (剩余条目, 删除数, 释放字节)。

    每遍：先删过期（>30 天），再按 mtime 从旧到新删至 80%；每遍最多删 50 个，
    删满 50 说明扫描没做完，再排一遍（循环直到一遍删除 <50）。
    """
    remaining = list(entries)
    deleted_total = 0
    freed_total = 0
    while True:
        total = sum(e["size"] for e in remaining)
        deleted = 0
        freed = 0
        kept = []
        for e in remaining:
            if deleted < DISK_BATCH and now - e["mtime"] > DISK_TTL:
                deleted += 1
                freed += e["size"]
                continue
            kept.append(e)
        remaining = kept
        total = sum(e["size"] for e in remaining)
        if total > DISK_LIMIT:
            for e in sorted(remaining, key=lambda x: x["mtime"]):
                if deleted >= DISK_BATCH or total <= DISK_TRIM_TARGET:
                    break
                remaining.remove(e)
                deleted += 1
                freed += e["size"]
                total -= e["size"]
        deleted_total += deleted
        freed_total += freed
        if deleted < DISK_BATCH:
            break
    return remaining, deleted_total, freed_total


class T18ImagePipelineContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.impl = read_source("HostImageLoader.m")
        cls.header = read_source("HostImageLoader.h")

    # PERF-01：磁盘 LRU 常量与后台分批清理
    def test_disk_lru_limits_defined(self):
        self.assertIn("static NSUInteger const ImageDiskCacheLimitBytes = 128 * 1024 * 1024;", self.impl)
        self.assertIn("static NSTimeInterval const ImageDiskCacheTTLSeconds = 30 * 24 * 3600;", self.impl)
        self.assertIn("static NSUInteger const ImageDiskCacheTrimTargetBytes = (NSUInteger)(128 * 1024 * 1024 * 0.8);", self.impl)
        self.assertIn("static NSUInteger const ImageDiskTrimBatchLimit = 50;", self.impl)

    def test_trim_runs_on_disk_queue_and_requeues_when_batch_full(self):
        body = self.impl.split("- (void)trimDiskCacheOnDiskQueue {", 1)[1]
        self.assertIn('if(![name hasSuffix:@".jpg"])continue;', body)
        self.assertIn("now-[entry[@\"mtime\"] doubleValue]>ImageDiskCacheTTLSeconds", body)
        self.assertIn("totalBytes>ImageDiskCacheLimitBytes", body)
        self.assertIn("totalBytes<=ImageDiskCacheTrimTargetBytes", body)
        self.assertIn("if(deleted>=ImageDiskTrimBatchLimit){", body)
        self.assertIn("dispatch_async(self.diskQueue, ^{HostImageLoader *owner=weakSelf;", body)

    def test_disk_write_goes_through_disk_queue_with_jpeg_encode_there(self):
        body = self.impl.split("- (void)scheduleDiskWriteForImage:(UIImage *)image cacheKey:(NSString *)cacheKey url:(NSString *)url maximumPixelSize:(NSUInteger)maximumPixelSize diskEpoch:(NSUInteger)diskEpoch {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("dispatch_async(self.diskQueue, ^{", body)
        self.assertIn("UIImageJPEGRepresentation(image,0.82)", body)
        self.assertIn("jpegData.length<=512*1024", body)
        self.assertIn("[self trimDiskCacheOnDiskQueue];", body)

    # PERF-02：解码与磁盘队列分离
    def test_decode_queue_is_separate_bounded_operation_queue(self):
        self.assertIn("static NSInteger const ImageDecodeConcurrentLimit = 2;", self.impl)
        self.assertIn("_decodeQueue=[NSOperationQueue new];_decodeQueue.name=@\"cctvhost.images.decode\";_decodeQueue.maxConcurrentOperationCount=ImageDecodeConcurrentLimit;", self.impl)
        self.assertIn('_diskQueue=dispatch_queue_create("cctvhost.images.disk", DISPATCH_QUEUE_SERIAL);', self.impl)

    def test_finish_routes_body_to_decode_queue_not_main_or_coordination_queue(self):
        body = self.impl.split("- (void)finish:", 1)[1]
        self.assertIn("[self decodeImageData:body maximumPixelSize:record.maximumPixelSize completion:", body)
        # 解码完成回调回 _queue 再终结，不直接在解码队列交付。
        self.assertIn("dispatch_async(owner.queue, ^{", body)
        self.assertIn("[owner completeDecodedRequest:record error:error image:decoded failureStage:failureStage];", body)

    def test_decode_uses_imageio_thumbnail_on_decode_queue(self):
        body = self.impl.split("- (void)decodeImageData:(NSData *)data maximumPixelSize:(NSUInteger)maximumPixelSize completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable failureStage, double pixelWidth, double pixelHeight))completion {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("[self.decodeQueue addOperationWithBlock:^{", body)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", body)
        self.assertIn("kCGImageSourceCreateThumbnailWithTransform", body)
        # 解码回调也在解码队列（调用方负责回 _queue），不越俎代庖。
        self.assertIn("if(completion)completion(image,failureStage,pixelWidth,pixelHeight);", body)

    # PERF-03：分别计费
    def test_separate_billing_fields_and_snapshot(self):
        for field in ("memoryCacheBytes", "inFlightCompressedBytes"):
            self.assertIn(f"@property(nonatomic) NSUInteger {field};", self.impl)
        # 磁盘三栏由 trim 在磁盘队列上写、快照在 _queue 上读，必须 atomic
        #（父代理核查补修：原 nonatomic 声明下跨队列读写是数据竞争）。
        for field in ("diskCacheBytes", "diskEvictionCount", "diskTrimmedBytes"):
            self.assertIn(f"@property(atomic) NSUInteger {field};", self.impl)
        snap = self.impl.split("- (NSDictionary<NSString *, id> *)statisticsSnapshot {", 1)[1]
        for key in ("memoryCacheBytes", "inFlightCompressedBytes", "diskCacheBytes",
                    "cacheHits", "cacheMisses", "diskHits", "diskEvictions", "diskTrimmedBytes"):
            self.assertIn(f"@\"{key}\":", snap)
        self.assertIn("- (NSDictionary<NSString *, id> *)statisticsSnapshot;", self.header)

    def test_inflight_bytes_tracked_on_receive_and_released_on_complete(self):
        self.assertIn("self.inFlightCompressedBytes+=data.length;", self.impl)
        self.assertIn("self.inFlightCompressedBytes-=MIN(self.inFlightCompressedBytes,record.data.length);", self.impl)

    def test_memory_cache_cost_tracked_on_store_and_eviction(self):
        self.assertIn("self.memoryCacheBytes+=cost;", self.impl)
        evict = self.impl.split("- (void)cache:(NSCache *)cache willEvictObject:(id)obj {", 1)[1]
        self.assertIn("self.memoryCacheBytes-=MIN(self.memoryCacheBytes,cost);", evict)
        self.assertIn("_cache.delegate=self;", self.impl)

    def test_cache_hits_and_misses_counted_separately(self):
        self.assertIn("self.cacheHitCount++;", self.impl)
        self.assertIn("self.cacheMissCount++;", self.impl)
        # 磁盘命中分支在 _queue 的 block 里，经 owner 计数。
        self.assertIn("owner.diskHitCount++;", self.impl)

    def test_clear_cache_resets_memory_billing(self):
        clear = self.impl.split("- (void)clearCache {", 1)[1].split("\n- (void)clearDiskCache", 1)[0]
        self.assertIn("self.memoryCacheBytes=0;", clear)

    # PERF-04：统一终结
    def test_finish_request_delivers_at_most_once(self):
        body = self.impl.split("- (void)finishRequest:", 1)[1]
        self.assertIn("if(record.completionDelivered)return;record.completionDelivered=YES;", body)
        self.assertIn("@property(nonatomic) BOOL completionDelivered;", self.impl)

    def test_cancelled_observers_terminate_with_retry_after_zero(self):
        body = self.impl.split("- (void)finishRequest:", 1)[1]
        self.assertIn("if(record.generation!=self.generation){image=nil;retryAfter=0;}", body)
        cancel = self.impl.split("- (void)cancelPending {", 1)[1]
        # 在途任务与排队任务都被终结（不再只取消 task、不通知观察者）。
        self.assertIn("[self finishRequest:record image:nil retryAfter:0];", cancel)
        self.assertIn("for(HostImageRequest *record in self.pending)[self finishRequest:record image:nil retryAfter:0];", cancel)

    def test_backoff_dropped_queued_requests_terminate_with_remaining_backoff(self):
        body = self.impl.split("- (void)finish:", 1)[1]
        self.assertIn("for(HostImageRequest *queued in dropped)[self finishRequest:queued image:nil retryAfter:backoffRemaining];", body)
        self.assertIn('inflight.failureStage=@"domain_backoff_fast_fail";', body)

    # PERF-05：清盘与写盘同一 epoch 门禁
    def test_clear_disk_cache_bumps_epoch_and_removes_dir_on_disk_queue(self):
        body = self.impl.split("- (void)clearDiskCache {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("self.diskEpoch++;", body)
        self.assertIn("dispatch_async(self.diskQueue, ^{", body)
        self.assertIn("[fm removeItemAtPath:dir error:NULL];", body)
        self.assertIn("@property(atomic) NSUInteger diskEpoch;", self.impl)

    def test_stale_epoch_disk_writes_are_dropped(self):
        body = self.impl.split("- (void)scheduleDiskWriteForImage:(UIImage *)image cacheKey:(NSString *)cacheKey url:(NSString *)url maximumPixelSize:(NSUInteger)maximumPixelSize diskEpoch:(NSUInteger)diskEpoch {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("if(diskEpoch!=self.diskEpoch)return;", body)
        finish = self.impl.split("- (void)finish:", 1)[1]
        # 磁盘 epoch 在解码开始时抓取（与 generation 同一时刻），不是写盘时现取。
        self.assertIn("record.diskEpoch=self.diskEpoch;", finish)
        self.assertIn("@property(nonatomic) NSUInteger diskEpoch;", self.impl)

    # LRU 算法行为（Python 模型，与 trimDiskCacheOnDiskQueue 同规则）
    def test_lru_model_expired_files_removed(self):
        now = time.time()
        entries = [
            {"path": "a.jpg", "size": 1000, "mtime": now - 31 * 24 * 3600},
            {"path": "b.jpg", "size": 1000, "mtime": now - 100},
        ]
        remaining, deleted, freed = trim_model(entries, now)
        self.assertEqual([e["path"] for e in remaining], ["b.jpg"])
        self.assertEqual((deleted, freed), (1, 1000))

    def test_lru_model_over_limit_trims_oldest_to_eighty_percent(self):
        now = time.time()
        entries = [
            {"path": f"{i}.jpg", "size": 20 * 1024 * 1024, "mtime": now - i * 1000}
            for i in range(7)  # 140 MiB > 128 MiB
        ]
        remaining, deleted, freed = trim_model(entries, now)
        total = sum(e["size"] for e in remaining)
        self.assertLessEqual(total, DISK_TRIM_TARGET)
        self.assertGreaterEqual(deleted, 1)
        # 最旧的先被删（mtime 最小者不在剩余里）。
        self.assertNotIn("6.jpg", [e["path"] for e in remaining])

    def test_lru_model_under_limit_keeps_everything_fresh(self):
        now = time.time()
        entries = [
            {"path": f"{i}.jpg", "size": 1024, "mtime": now - i * 60}
            for i in range(10)
        ]
        remaining, deleted, freed = trim_model(entries, now)
        self.assertEqual(len(remaining), 10)
        self.assertEqual((deleted, freed), (0, 0))

    def test_lru_model_batch_cap_rescans_until_done(self):
        now = time.time()
        # 120 个过期文件：每遍最多删 50 个，需多遍才删完。
        entries = [
            {"path": f"{i}.jpg", "size": 100, "mtime": now - 40 * 24 * 3600}
            for i in range(120)
        ]
        remaining, deleted, freed = trim_model(entries, now)
        self.assertEqual(remaining, [])
        self.assertEqual(deleted, 120)

    def test_lru_model_real_files_on_disk(self):
        # 在真实临时目录上跑模型：过期与超限文件都被删，鲜活文件保留。
        tmp = tempfile.mkdtemp(prefix="t18-lru-")
        try:
            now = time.time()
            old = os.path.join(tmp, "old.jpg")
            fresh = os.path.join(tmp, "fresh.jpg")
            with open(old, "wb") as f:
                f.write(b"x" * 4096)
            with open(fresh, "wb") as f:
                f.write(b"y" * 4096)
            os.utime(old, (now - 40 * 24 * 3600, now - 40 * 24 * 3600))
            entries = [
                {"path": old, "size": os.path.getsize(old), "mtime": os.path.getmtime(old)},
                {"path": fresh, "size": os.path.getsize(fresh), "mtime": os.path.getmtime(fresh)},
            ]
            remaining, deleted, freed = trim_model(entries, now)
            for e in entries:
                if e not in remaining:
                    os.remove(e["path"])
            self.assertFalse(os.path.exists(old))
            self.assertTrue(os.path.exists(fresh))
            self.assertEqual(deleted, 1)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
