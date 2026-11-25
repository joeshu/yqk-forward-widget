"""D阶段 · 图片预取（HostImageLoader prefetch）切换资源审计契约测试

只读取 Sources 文本断言不变量，不触发构建/网络/CI。
对应审计维度：并发、取消、过期/陈旧结果覆盖、内存预算。

审计结论：现有 HostImageLoader 预取/加载行为正确，无确定 bug 需修复；
本文件固化以下不变量以便回归：

1. 并发：图片队列串行 + delegate 队列单并发且绑定同一串行队列；generation 为原子。
2. 取消：cancelPending 先在主线程自增 generation，再在串行队列取消任务并清空全部容器；
   finish 以 generation 守卫丢弃被取消的陈旧结果。
3. 陈旧覆盖：finish 主线程派发再次校验 generation，并以 view.accessibilityIdentifier
   二次比对 record.url，杜绝视图已切换后旧图覆盖新视图。
4. 内存预算：NSCache count/totalCost 上限 + 内存告警清缓存；并发任务上限 8、待办上限 160；
   单体 body 上限 2/4 MiB；预取每批最多 6 且受并发闸门约束；finish 后释放网络 body。
"""
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class DImagePrefetchAuditContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.impl = read_source("HostImageLoader.m")

    # 1. 并发
    def test_image_queue_is_serial_and_delegate_bound_to_it(self):
        self.assertIn('dispatch_queue_create("cctvhost.images", DISPATCH_QUEUE_SERIAL);', self.impl)
        self.assertIn("delegate.maxConcurrentOperationCount=1;delegate.underlyingQueue=_queue;", self.impl)

    def test_generation_is_atomic(self):
        self.assertIn("@property(atomic) NSUInteger generation;", self.impl)

    # 2. 取消
    def test_cancel_pending_advances_generation_before_async_cleanup(self):
        body = self.impl.split("- (void)cancelPending", 1)[1]
        gen_part, async_part = body.split("dispatch_async(self.queue, ^", 1)
        self.assertIn("self.generation++;", gen_part)
        self.assertIn("for(HostImageRequest *record in self.tasks.allValues)", async_part)
        self.assertIn("[record.task cancel];", async_part)
        for	clear in (
            "[self.tasks removeAllObjects];",
            "[self.requests removeAllObjects];",
            "[self.pending removeAllObjects];",
            "[self.viewTargets removeAllObjects];",
        ):
            self.assertIn(clear, async_part)

    def test_finish_drops_results_when_generation_changed(self):
        body = self.impl.split("- (void)finish:", 1)[1]
        # 解码分支与失败记录分支都要求 generation 仍匹配当前 generation。
        self.assertIn(
            "if(!error && record.generation==self.generation && record.data.length && !record.responseEncrypted)",
            body,
        )
        self.assertIn(
            "if(!image && record.generation==self.generation && (error.code!=NSURLErrorCancelled||record.failureStage.length))",
            body,
        )

    # 3. 陈旧覆盖
    def test_finish_main_dispatch_rechecks_generation_and_view_identity(self):
        body = self.impl.split("- (void)finish:", 1)[1]
        self.assertIn("if(image||observers.count)dispatch_async(dispatch_get_main_queue(), ^{", body)
        self.assertIn("if(record.generation!=self.generation)return;", body)
        # 视图绑定与 completion 回调都二次比对 accessibilityIdentifier==record.url。
        self.assertIn(
            "for(UIImageView *view in views)if([view.accessibilityIdentifier isEqualToString:record.url])",
            body,
        )
        self.assertIn(
            "![view.accessibilityIdentifier isEqualToString:record.url])continue;",
            body,
        )

    def test_loadurl_drops_block_when_generation_changed_before_queue_run(self):
        body = self.impl.split("maximumPixelSize:(NSUInteger)maximumPixelSize completion:", 1)[1]
        self.assertIn("if(generation!=self.generation || !view)return;", body)

    # 4. 内存预算
    def test_cache_caps_and_memory_warning_clear(self):
        self.assertIn("_cache.countLimit=360;_cache.totalCostLimit=32*1024*1024;", self.impl)
        self.assertIn(
            "addObserver:self selector:@selector(clearCache) name:UIApplicationDidReceiveMemoryWarningNotification",
            self.impl,
        )
        clear = self.impl.split("- (void)clearCache {", 1)[1].split("\n@end", 1)[0]
        self.assertIn("[self.cache removeAllObjects];", clear)
        self.assertIn("[self.failures removeAllObjects];", clear)
        self.assertIn("[self.domainFailures removeAllObjects];", clear)

    def test_concurrent_and_queue_limits_defined(self):
        self.assertIn("static NSUInteger const ImageConcurrentLimit = 8;", self.impl)
        self.assertIn("static NSUInteger const ImageQueueLimit = 160;", self.impl)

    def test_body_limits_defined(self):
        self.assertIn("static NSUInteger const ImageBodyLimit = 2 * 1024 * 1024;", self.impl)
        self.assertIn("static NSUInteger const PosterBodyLimit = 4 * 1024 * 1024;", self.impl)

    def test_start_pending_never_exceeds_concurrent_limit(self):
        body = self.impl.split("- (void)startPending {", 1)[1]
        self.assertIn("while(self.tasks.count<ImageConcurrentLimit && self.pending.count)", body)

    def test_prefetch_capped_per_batch_and_gated_by_concurrent_budget(self):
        body = self.impl.split("- (void)prefetchPosterURLs:", 1)[1]
        self.assertIn("if(scheduled>=6 || (self.tasks.count+self.pending.count)>=ImageConcurrentLimit)break;", body)
        # 命中缓存/在途/失败负缓存的 URL 不重复入队。
        self.assertIn(
            "if([self.cache objectForKey:cacheKey] || self.requests[cacheKey] || [self.failures objectForKey:cacheKey])continue;",
            body,
        )
        self.assertIn("request.prefetch=YES;", body)

    def test_queue_pressure_evicts_viewless_pending_including_prefetch(self):
        # loadURL 在达到 QueueLimit 时驱逐无视图的 pending 记录（含预取），保证待办有界。
        body = self.impl.split("if(self.requests.count>=ImageQueueLimit){", 1)[1]
        self.assertIn("if(!queued.views.allObjects.count)", body)

    def test_finish_releases_network_body_after_decode(self):
        self.assertIn("record.data=nil;record.task=nil;", self.impl)

    def test_start_pending_skips_stale_generation_records(self):
        body = self.impl.split("- (void)startPending {", 1)[1]
        self.assertIn(
            "if(record.generation!=self.generation || (!record.views.allObjects.count && !record.prefetch))",
            body,
        )


if __name__ == "__main__":
    unittest.main()
