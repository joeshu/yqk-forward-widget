"""B4/T19 · 存储与主线程（PERF-09/10、M12）行为测试

只读取 Sources 文本断言不变量 + 对快照可见性跑 Python 模型验证，不触发构建/网络/CI。
对应审计：PERF-09 MediaMetadataCache 同步访问协调队列、写入时全量排序/序列化成本
随缓存增长；PERF-10 HostLibraryStore/ChannelSQLiteIndex/ProfileStore/
TVBoxCatalogStore 同步队列/锁和磁盘写存在，未证明全部主线程调用链已经隔离。

T19 改动：
1. MediaMetadataCache（PERF-09）：冷启动持久化加载改异步（persistenceQueue，
   发布时只补不存在的 key）；读/写记诊断耗时（media_metadata_cache_read/store，
   诊断开启时才记）；同步块里不再为未知 cost 序列化（读：不提升进内存缓存；
   写裁剪：未知 cost 直接淘汰）。
2. HostLibraryStore（PERF-10）：读用不可变快照（epoch 脏标记 + 写块结束刷新；
   写块经 performWrite 包一层）；父代理 CI 修正：入队时同步记 pendingWriteCount，
   有未完成写时读一律走 performSync 等写完成（否则排队期间读命中旧快照，
   ui-smoke "film favorite is visibly updated and persisted" 失败）。备份恢复
   直接写 defaults 后调 invalidateSnapshots。
3. ProfileStore（PERF-10）：metadata: 加有界只读快照（大条目不缓存），
   storeProfile/remove/replaceBackupMetadata 失效。
4. TVBoxCatalogStore（PERF-10）：saveCatalog 的 sidecar 写盘与 removeCatalog 的
   文件删除移出 @synchronized；catalogs 本来就有快照，不动。
5. ChannelSQLiteIndex（PERF-10）：核实——replaceChannels 两处调用方本来就先
   dispatch 到 UTILITY 队列；FTS 查询有索引且限流；无代码改动，只锁契约。

语义不变：T16 的 schema/事务/回退约定、M11 历史证据门禁、M12 行级写入、
缓存年龄标记均保留；读返回类型仍为可变副本（旧行为）。
"""
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


def method_body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


# --- HostLibraryStore 快照可见性的 Python 模型（与 performWrite/refresh 语义同构） ---
class LibraryStoreSnapshotModel:
    """db: 底层数据；epoch: 脏标记；snapshot: 已发布快照；pending: 未完成写块数。

    写块：入队时 pending+1（调用线程同步）→ 块执行时自增 epoch → 改 db →
    刷新快照（loaded=epoch）→ pending−1。
    读：epoch 一致且 pending==0 直接取快照；否则“等队列排空”（模型里即
    立即执行待处理写块再重建）——排队期间的读绝不能命中旧快照（CI
    2026-11-26：ui-smoke "film favorite is visibly updated and persisted"
    失败的根因，点收藏后立刻重读看到了旧快照）。
    """

    def __init__(self):
        self.db = []
        self.snapshot = None
        self.epoch = 0
        self.loaded_epoch = None
        self.pending = 0
        self.queue = []

    def write(self, value):
        self.enqueue_write(value)
        self.run_pending()

    def enqueue_write(self, value):
        self.pending += 1  # 入队时同步 +1（调用线程）
        self.queue.append(value)

    def run_pending(self):
        for value in self.queue:
            self.epoch += 1  # 脏标记先于改动
            self.db.append(value)
            self.snapshot = list(self.db)  # 刷新快照
            self.loaded_epoch = self.epoch
            self.pending -= 1
        self.queue = []

    def read(self):
        if self.snapshot is not None and self.loaded_epoch == self.epoch and self.pending == 0:
            return list(self.snapshot)
        # 快照失效或有写在排队：等队列排空后重建（模型里同步执行待处理写块）。
        self.run_pending()
        self.snapshot = list(self.db)
        self.loaded_epoch = self.epoch
        return list(self.snapshot)

    def external_defaults_write(self, values):
        # 备份恢复的两面写：直接改底层，不经过写块。
        self.db = list(values)

    def invalidate(self):
        self.epoch += 1


class T19StorageMainThreadContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.meta = read_source("MediaMetadataCache.m")
        cls.lib = read_source("HostLibraryStore.m")
        cls.lib_h = read_source("HostLibraryStore.h")
        cls.profile = read_source("ProfileStore.m")
        cls.catalog = read_source("TVBoxCatalogStore.m")
        cls.channel = read_source("ChannelSQLiteIndex.m")
        cls.backup = read_source("HostBackup.m")

    # --- 1. MediaMetadataCache（PERF-09） ---
    def test_cold_start_persistent_load_is_async(self):
        init = method_body(self.meta, "- (instancetype)init {", "- (void)loadPersistentRecordsAsync {")
        self.assertIn("[self loadPersistentRecordsAsync];", init)
        self.assertNotIn("[self loadPersistentRecords];", init)
        loader = method_body(self.meta, "- (void)loadPersistentRecordsAsync {", "- (void)loadPersistentRecords {")
        self.assertIn("dispatch_async(self.persistenceQueue, ^{ [self loadPersistentRecords]; });", loader)

    def test_library_store_imports_quartzcore_for_media_time(self):
        # Contract lock (CI 2026-11-26): allFavorites 用 CACurrentMediaTime
        # 计快照重建耗时——本文件必须 import QuartzCore，否则 macOS clang
        # 报 implicit function declaration；本地 Python 套件编不到 ObjC，
        # 只有这条契约能拦住。
        self.assertIn("#import <QuartzCore/QuartzCore.h>", self.lib)
        self.assertIn("CACurrentMediaTime()", self.lib)

    def test_persistent_load_never_overwrites_newer_records(self):
        body = method_body(self.meta, "- (void)loadPersistentRecords {", "- (void)schedulePersistentWrite {")
        self.assertIn("dispatch_sync(self.queue, ^{for(NSString *key in loaded)if(!self.persistentRecords[key])self.persistentRecords[key]=loaded[key];});", body)

    def test_read_path_never_serializes_for_unknown_cost(self):
        body = method_body(self.meta, "- (id)resultForSource:", "- (void)storeResult:")
        self.assertNotIn("dataWithJSONObject:entry.result", body)
        self.assertIn("if(cachedCost){entry.cost=cachedCost;[self.entries setObject:entry forKey:key cost:entry.cost];}", body)

    def test_store_trim_evicts_unknown_cost_without_serializing(self):
        body = method_body(self.meta, "- (void)storeResult:", "- (NSTimeInterval)ageOfResultForSource:")
        self.assertNotIn('dataWithJSONObject:record[@"result"]', body)
        self.assertIn("if(!cost){[self.persistentRecords removeObjectForKey:candidate];", body)

    def test_read_and_store_timings_recorded_when_diagnostics_enabled(self):
        self.assertIn('"media_metadata_cache_read"', self.meta)
        self.assertIn('"media_metadata_cache_store"', self.meta)
        self.assertIn("if(RuntimeDiagnostics.shared.enabled)", self.meta)
        # Round 18 的去重序列化不变量保留。
        self.assertIn("[persistentResult isEqual:result]?data:", self.meta)

    # --- 2. HostLibraryStore（PERF-10） ---
    def test_snapshot_properties_and_epoch_declared(self):
        for prop in ("snapshotFavorites", "snapshotRecents", "snapshotMediaFavorites", "snapshotMediaHistory"):
            self.assertIn(f"@property (atomic, strong)", self.lib)
            self.assertIn(prop, self.lib)
        self.assertIn("@property (atomic) NSUInteger snapshotEpoch;", self.lib)
        self.assertIn("@property (atomic) NSUInteger loadedSnapshotEpoch;", self.lib)
        self.assertIn("- (void)refreshSnapshotsLocked;", self.lib)

    def test_reads_serve_snapshot_without_queue_wait(self):
        for method, decl in (
            ("- (NSArray<NSString *> *)allFavorites {", "NSArray<NSString *> *snapshot = self.snapshotFavorites;"),
            ("- (NSArray<NSDictionary *> *)recents {", "NSArray<NSDictionary *> *snapshot = self.snapshotRecents;"),
            ("- (NSDictionary<NSString *,NSDictionary *> *)mediaFavorites {", "NSDictionary *snapshot = self.snapshotMediaFavorites;"),
            ("- (NSArray<NSDictionary *> *)mediaWatchHistory {", "NSArray *snapshot = self.snapshotMediaHistory;"),
        ):
            body = self.lib[self.lib.index(method):]
            body = body[:body.index("\n- (", 10)]
            self.assertIn(decl, body)
            self.assertIn("self.loadedSnapshotEpoch == self.snapshotEpoch", body)
            self.assertIn("[self refreshSnapshotsLocked];", body)
            # 返回类型仍为可变副本（旧行为）。
            self.assertIn("mutableCopy", body)

    def test_is_favorite_served_from_snapshot(self):
        body = method_body(self.lib, "- (BOOL)isFavorite:(NSString *)key {", "- (void)addFavorite:")
        # 有未完成写时不命中快照（父代理 CI 修正：排队期间读旧快照会让 UI
        # 冒烟的收藏断言失败，见 test_pending_write_gate_in_source）。
        self.assertIn("if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch && ![self hasPendingWrites]) return [snapshot containsObject:key];", body)

    def test_all_write_methods_go_through_perform_write(self):
        self.assertEqual(self.lib.count("[self performWrite:^{"), 11)
        # performWrite 内部仍用 performAsync 入队，不递归。
        wrapper = method_body(self.lib, "- (void)performWrite:(dispatch_block_t)block {", "- (void)refreshSnapshotsLocked {")
        self.assertIn("[self performAsync:^{", wrapper)
        self.assertIn("self.snapshotEpoch++;", wrapper)
        self.assertIn("[self refreshSnapshotsLocked];", wrapper)

    def test_refresh_publishes_snapshots_before_epoch(self):
        body = method_body(self.lib, "- (void)refreshSnapshotsLocked {", "- (NSArray<NSString *> *)favoritesLockedWithPrepared:")
        for snapshot in ("snapshotFavorites", "snapshotRecents", "snapshotMediaFavorites", "snapshotMediaHistory"):
            self.assertIn(f"self.{snapshot} = ", body)
        self.assertLess(body.index("self.snapshotMediaHistory = "),
                        body.index("self.loadedSnapshotEpoch = self.snapshotEpoch;"))

    def test_no_new_remove_object_for_key(self):
        # T16 契约：全文件唯一的 removeObjectForKey 仍是那一处。
        self.assertEqual(self.lib.count("removeObjectForKey"), 1)

    def test_sql_literals_unchanged(self):
        for sql in (
            "SELECT payload FROM favorites ORDER BY position ASC;",
            "SELECT payload FROM recents ORDER BY position ASC;",
            "SELECT key,payload FROM media_favorites ORDER BY position ASC;",
            "SELECT payload FROM media_watch_history ORDER BY position ASC;",
            "SELECT COALESCE(MIN(position), 1) - 1 FROM recents;",
        ):
            self.assertIn(sql, self.lib)

    def test_backup_restore_invalidates_snapshots(self):
        self.assertIn("- (void)invalidateSnapshots;", self.lib_h)
        self.assertIn("[HostLibraryStore.shared invalidateSnapshots];", self.backup)
        # 失效调用在直接写 defaults 之后、恢复返回之前。
        self.assertLess(self.backup.index('[d setObject:backup[@"vodFavorites"] forKey:@"cctv.mediaFavorites.v1"]'),
                        self.backup.index("[HostLibraryStore.shared invalidateSnapshots];"))

    # --- 3. ProfileStore（PERF-10） ---
    def test_metadata_cache_hit_before_disk_read(self):
        body = method_body(self.profile, "+ (NSDictionary *)metadata:", "+ (BOOL)replaceBackupMetadata:")
        self.assertIn("NSDictionary *cached=gProfileMetadataCache[source];", body)
        self.assertIn("if(cached)return cached;", body)
        self.assertIn("dictionaryWithContentsOfFile:payloadPath", body)

    def test_metadata_cache_skips_heavy_entries(self):
        body = method_body(self.profile, "+ (NSDictionary *)metadata:", "+ (BOOL)replaceBackupMetadata:")
        # 大条目不缓存：与落盘阈值同界（text>64KB 或 cachedChannels>200）。
        self.assertIn('([result[@"text"] length]>65536)||([result[@"cachedChannels"] count]>200)', body)

    def test_metadata_cache_invalidated_on_all_writers(self):
        self.assertIn("[gProfileMetadataCache removeObjectForKey:source];", self.profile)
        self.assertIn("[gProfileMetadataCache removeAllObjects];", self.profile)
        store = method_body(self.profile, "+ (void)storeProfile:", "+ (void)update:")
        self.assertIn("[gProfileMetadataCache removeObjectForKey:source];", store)

    # --- 4. TVBoxCatalogStore（PERF-10） ---
    def test_save_catalog_writes_sidecar_outside_lock(self):
        body = method_body(self.catalog, "+ (void)saveCatalog:", "+ (NSDictionary *)catalogForID:")
        self.assertLess(body.index("writeToFile:path options:NSDataWritingAtomic"),
                        body.index("@synchronized(self){"))
        self.assertIn("sidecarSaved", body)

    def test_remove_catalog_deletes_files_outside_lock(self):
        body = method_body(self.catalog, "+ (void)removeCatalog:", "+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:")
        sync_end = body.index("\n    }\n")
        sync_block = body[:sync_end]
        self.assertIn("setObject:rows forKey:@\"tvboxCatalogs\"", sync_block)
        self.assertNotIn("removeItemAtPath", sync_block)
        self.assertIn("removeItemAtPath:path error:NULL", body[sync_end:])

    def test_catalogs_snapshot_cache_untouched(self):
        self.assertIn("gCachedCatalogs", self.catalog)
        self.assertIn("gCachedRawCatalogs", self.catalog)

    # --- 5. ChannelSQLiteIndex（PERF-10，核实无改动） ---
    def test_replace_channels_call_sites_already_async(self):
        coordinators = read_source("HostPlaybackAndResourceCoordinators.m")
        index_async = method_body(coordinators, "- (void)indexChannelsAsync:", "@end")
        self.assertIn("dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{", index_async)
        self.assertIn("[ChannelSQLiteIndex.shared replaceChannels:snapshot forSourceID:src];", index_async)
        catalog_m = read_source("RootViewController+Catalog.m")
        idx = catalog_m.index("[ChannelSQLiteIndex.shared replaceChannels:rows forSourceID:@\"catalog\"];")
        self.assertIn("dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{", catalog_m[max(0, idx - 1500):idx])

    def test_channel_search_is_indexed_and_capped(self):
        self.assertIn("MIN(limit, 500)", self.channel)
        self.assertIn("channels_fts MATCH ?", self.channel)
        self.assertIn('"BEGIN IMMEDIATE;"', self.channel)
        self.assertIn('"COMMIT;"', self.channel)

    # --- 快照可见性模型（行为验证） ---
    def test_snapshot_model_read_before_write_sees_old(self):
        store = LibraryStoreSnapshotModel()
        store.write("a")
        self.assertEqual(store.read(), ["a"])
        # 写块执行前读到旧快照（写是异步的，读不等它）。
        store.db.append("b")  # 模拟底层已改但写块未完成：epoch 已脏时读会重建
        store.epoch += 1
        self.assertEqual(store.read(), ["a", "b"])

    def test_snapshot_model_read_after_completed_write_sees_new(self):
        store = LibraryStoreSnapshotModel()
        store.write("a")
        store.write("b")
        self.assertEqual(store.read(), ["a", "b"])
        # 连续读不再进队列。
        self.assertEqual(store.read(), ["a", "b"])

    def test_snapshot_model_queued_write_is_visible_to_immediate_read(self):
        # 冒烟回归（CI 2026-11-26）：点收藏后立刻重读，必须看到新值，
        # 不能命中排队期间的旧快照。
        store = LibraryStoreSnapshotModel()
        store.write("a")
        self.assertEqual(store.read(), ["a"])
        store.enqueue_write("b")  # 写已入队、块未执行
        self.assertEqual(store.read(), ["a", "b"])
        self.assertEqual(store.pending, 0)

    def test_snapshot_model_two_queued_writes_both_visible(self):
        store = LibraryStoreSnapshotModel()
        store.write("a")
        store.enqueue_write("b")
        store.enqueue_write("c")
        self.assertEqual(store.read(), ["a", "b", "c"])
        self.assertEqual(store.pending, 0)

    def test_pending_write_gate_in_source(self):
        # 契约：performWrite 入队时同步 +1、块结束刷新后 −1；5 处读都以
        # hasPendingWrites 为门；计数器读写在 @synchronized 下（atomic
        # 属性的 ++ 不是原子 RMW，不能直接用）。
        perform = method_body(self.lib, "- (void)performWrite:(dispatch_block_t)block {",
                              "- (BOOL)hasPendingWrites {")
        self.assertIn("@synchronized(self) { self.pendingWriteCount++; }", perform)
        self.assertIn("[self refreshSnapshotsLocked];", perform)
        self.assertIn("@synchronized(self) { self.pendingWriteCount--; }", perform)
        self.assertLess(perform.index("self.pendingWriteCount++;"),
                        perform.index("[self performAsync:^{"))
        self.assertLess(perform.index("[self refreshSnapshotsLocked];"),
                        perform.index("self.pendingWriteCount--;"))
        gate = method_body(self.lib, "- (BOOL)hasPendingWrites {", "- (void)refreshSnapshotsLocked {")
        self.assertIn("@synchronized(self) { return self.pendingWriteCount > 0; }", gate)
        self.assertEqual(self.lib.count("&& ![self hasPendingWrites]"), 5)

    def test_snapshot_model_external_defaults_write_needs_invalidate(self):
        store = LibraryStoreSnapshotModel()
        store.write("a")
        self.assertEqual(store.read(), ["a"])
        store.external_defaults_write(["x", "y"])
        # 未失效：读仍命中旧快照（这就是 HostBackup 必须调 invalidateSnapshots 的原因）。
        self.assertEqual(store.read(), ["a"])
        store.invalidate()
        self.assertEqual(store.read(), ["x", "y"])

    def test_profile_cache_model_update_invalidates(self):
        cache = {}
        defaults = {"s": {"name": "old", "count": 1}}
        # metadata: 读并缓存。
        cache["s"] = defaults["s"]
        self.assertEqual(cache["s"]["name"], "old")
        # update: 写 defaults + 失效。
        defaults["s"] = {"name": "new", "count": 2}
        cache.pop("s", None)
        cache["s"] = defaults["s"]
        self.assertEqual(cache["s"]["name"], "new")


if __name__ == "__main__":
    unittest.main()
