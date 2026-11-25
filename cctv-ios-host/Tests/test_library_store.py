"""HostLibraryStore 源码契约测试：表结构、迁移标记、回退路径与调用点迁移。

本机无法编译 iOS，因此除静态检查外，还把 .m 中的 SQL 字面量抽出来交给
Python sqlite3 实际执行，验证语句合法且排序/裁剪语义与原 NSUserDefaults 行为一致。
"""
import json
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


def strip_comments_and_strings(text):
    """去掉 ObjC 注释、字符串与字符字面量，便于括号配对检查。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in "\"'":
            i += 1
            while i < n and text[i] != c:
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def c_string_literals(fragment):
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', fragment))


class HostLibraryStoreSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = read("HostLibraryStore.h")
        cls.m = read("HostLibraryStore.m")
        cls.impl = cls.m[cls.m.index("@implementation HostLibraryStore"):]

    def section(self, start, end):
        return self.impl[self.impl.index(start):self.impl.index(end)]

    def test_brackets_balanced(self):
        for name in ("HostLibraryStore.h", "HostLibraryStore.m"):
            body = strip_comments_and_strings(read(name))
            for open_c, close_c in ("()", "[]", "{}"):
                depth = 0
                for ch in body:
                    if ch == open_c:
                        depth += 1
                    elif ch == close_c:
                        depth -= 1
                    self.assertGreaterEqual(depth, 0, f"{name} {open_c}{close_c} closes early")
                self.assertEqual(depth, 0, f"{name} unbalanced {open_c}{close_c}")
            self.assertEqual(body.count("@interface"), body.count("@end") - body.count("@implementation"))

    def test_public_api(self):
        for sig in (
            "+ (instancetype)shared;",
            "- (NSArray<NSString *> *)allFavorites;",
            "- (BOOL)isFavorite:(NSString *)key;",
            "- (void)addFavorite:(NSString *)key;",
            "- (void)removeFavorite:(NSString *)key;",
            "- (void)replaceFavorites:(nullable NSArray *)favorites;",
            "- (NSArray<NSDictionary *> *)recents;",
            "- (void)appendRecent:(NSDictionary *)entry;",
            "- (void)replaceRecents:(nullable NSArray *)recents;",
            "- (void)clearRecents;",
            "@property (nonatomic, readonly) BOOL usingDefaultsFallback;",
        ):
            self.assertIn(sig, self.h)
        self.assertIn("const NSUInteger HostLibraryRecentsLimit = 24;", self.m)

    def test_independent_database_wal_and_serial_queue(self):
        self.assertIn("NSApplicationSupportDirectory", self.m)
        self.assertIn('stringByAppendingPathComponent:@"HostLibrary"', self.m)
        self.assertIn('@"library_v1.sqlite"', self.m)
        self.assertIn("PRAGMA journal_mode=WAL", self.m)
        self.assertIn("sqlite3_busy_timeout(self.db, 2000);", self.m)
        self.assertIn("DISPATCH_QUEUE_SERIAL", self.m)
        self.assertIn("dispatch_queue_set_specific", self.m)
        self.assertIn("dispatch_get_specific(&kHostLibraryQueueKey)", self.m)

    def test_private_methods_forward_declared(self):
        ext = self.m[self.m.index("@interface HostLibraryStore ()"):self.m.index("@implementation HostLibraryStore")]
        for name in re.findall(r"^- \([^)]*\)(\w+)", self.impl, re.M):
            if name in ("dealloc", "usingDefaultsFallback"):
                continue
            self.assertIn(name, ext + self.h, f"{name} missing forward declaration")

    def test_schema(self):
        self.assertIn("CREATE TABLE IF NOT EXISTS favorites (", self.m)
        self.assertIn("CREATE TABLE IF NOT EXISTS recents (", self.m)
        self.assertIn("key TEXT PRIMARY KEY NOT NULL", self.m)
        self.assertIn("payload BLOB NOT NULL", self.m)
        self.assertIn("updated_at REAL NOT NULL", self.m)
        self.assertIn("watched_at REAL NOT NULL", self.m)

    def test_migration_marker_and_legacy_keys_kept(self):
        self.assertIn('HostLibraryMigrationMarkerKey = @"cctv.libraryStore.migrated.v1"', self.m)
        self.assertIn('HostLibraryLegacyFavoritesKey = @"favorites"', self.m)
        self.assertIn('HostLibraryLegacyRecentsKey = @"recents"', self.m)
        self.assertIn("if (![self.defaults boolForKey:HostLibraryMigrationMarkerKey]) {", self.m)
        self.assertIn("[self.defaults setBool:YES forKey:HostLibraryMigrationMarkerKey];", self.m)
        migrate = self.section("- (BOOL)migrateFromDefaultsLocked {", "- (BOOL)transactionLocked:(BOOL (^)(void))work {")
        self.assertIn("transactionLocked", migrate)
        # 原键保留不删，便于回滚
        self.assertNotIn("removeObjectForKey", self.m)
        # 迁移成功后才写标记
        prepare = self.section("- (BOOL)prepareLocked {", "- (BOOL)migrateFromDefaultsLocked {")
        self.assertLess(prepare.index("migrateFromDefaultsLocked"), prepare.index("setBool:YES forKey:HostLibraryMigrationMarkerKey"))

    def test_fallback_to_defaults_when_sqlite_unavailable(self):
        prepare = self.section("- (BOOL)prepareLocked {", "- (BOOL)migrateFromDefaultsLocked {")
        self.assertIn("fallback to NSUserDefaults", prepare)
        self.assertEqual(prepare.count("[self closeLocked];"), 6)  # 4 migration failures + 2 reconciliation failures
        self.assertIn("[self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] ?: @[]", self.m)
        self.assertIn("[self.defaults arrayForKey:HostLibraryLegacyRecentsKey] ?: @[]", self.m)
        self.assertIn("[self.defaults setObject:merged forKey:HostLibraryLegacyRecentsKey];", self.m)

    def test_sql_literals_execute_with_expected_semantics(self):
        schema_start = self.m.index('"CREATE TABLE IF NOT EXISTS favorites (')
        schema_end = self.m.index("];", schema_start)
        schema = c_string_literals(self.m[schema_start:schema_end])
        db = sqlite3.connect(":memory:")
        db.executescript(schema)
        cols = {r[1]: r[2] for r in db.execute("PRAGMA table_info(favorites)")}
        self.assertEqual(cols["key"], "TEXT")
        self.assertEqual(cols["payload"], "BLOB")
        self.assertIn("updated_at", cols)
        cols = {r[1]: r[2] for r in db.execute("PRAGMA table_info(recents)")}
        self.assertIn("watched_at", cols)
        pk = [r[1] for r in db.execute("PRAGMA table_info(recents)") if r[5]]
        self.assertEqual(pk, ["key"])

        insert_recent = "INSERT OR REPLACE INTO recents(key, payload, watched_at, position) VALUES(?, ?, ?, ?);"
        self.assertIn(insert_recent, self.m)
        min_sql = "SELECT COALESCE(MIN(position), 1) - 1 FROM recents;"
        self.assertIn(min_sql, self.m)
        trim = "DELETE FROM recents WHERE key NOT IN (SELECT key FROM recents ORDER BY position ASC LIMIT %d);" % 24
        self.assertIn(trim.replace("24", "%lu"), self.m)

        def append(entry):
            db.execute("DELETE FROM recents WHERE key = ?;", (entry["id"],))
            pos = db.execute(min_sql).fetchone()[0]
            db.execute(insert_recent, (entry["id"], json.dumps(entry).encode(), entry["watchedAt"], pos))
            db.execute(trim)

        model = []
        for i in list(range(30)) + [3, 29, 7]:
            entry = {"id": f"c{i}", "name": f"C{i}", "watchedAt": i}
            append(entry)
            model = [entry] + [r for r in model if r["id"] != entry["id"]][:23]
        rows = [json.loads(r[0]) for r in db.execute("SELECT payload FROM recents ORDER BY position ASC;")]
        self.assertEqual(rows, model)
        self.assertEqual(len(rows), 24)

        db.execute("INSERT OR REPLACE INTO favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);",
                   ("cctv1", json.dumps("cctv1").encode(), 0, 0))
        nxt = db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM favorites;").fetchone()[0]
        self.assertEqual(nxt, 1)
        self.assertIn("SELECT COALESCE(MAX(position), -1) + 1 FROM favorites;", self.m)
        self.assertIn("SELECT payload FROM favorites ORDER BY position ASC;", self.m)


class LibraryCallSiteTests(unittest.TestCase):
    FILES = (
        "RootViewController.m",
        "RootViewController+Catalog.m",
        "RootViewController+Subscriptions.m",
        "RootViewController+Services.m",
        "SettingsViewController.m",
    )

    def test_no_direct_defaults_access_for_favorites_or_recents(self):
        pattern = re.compile(r'(?:ForKey|forKey):@"(?:favorites|recents)"')
        for name in self.FILES:
            text = read(name)
            self.assertIsNone(pattern.search(text), f"{name} still touches NSUserDefaults favorites/recents")
            self.assertIn('#import "HostLibraryStore.h"', text)

    def test_catalog_uses_store_api(self):
        catalog = read("RootViewController+Catalog.m")
        self.assertIn("[NSMutableArray arrayWithArray:[HostLibraryStore.shared allFavorites] ?: @[]]", catalog)
        self.assertIn("[NSMutableArray arrayWithArray:[HostLibraryStore.shared recents] ?: @[]]", catalog)
        self.assertIn("[HostLibraryStore.shared appendRecent:entry];", catalog)
        self.assertIn("[HostLibraryStore.shared clearRecents];", catalog)
        self.assertIn("[HostLibraryStore.shared replaceRecents:owner.recents];", catalog)
        self.assertGreaterEqual(catalog.count("[HostLibraryStore.shared addFavorite:"), 4)
        self.assertGreaterEqual(catalog.count("[HostLibraryStore.shared removeFavorite:"), 4)
        # 最近观看上限保持 24
        self.assertIn("m.count < 24", catalog)
        # lastChannel 等其他 defaults 用途不动
        self.assertIn('[defaults setObject:updated forKey:@"lastChannel"]', catalog)

    def test_other_call_sites(self):
        self.assertIn("[HostLibraryStore.shared replaceFavorites:owner.favorites];", read("RootViewController+Subscriptions.m"))
        self.assertIn("self.recents=[[HostLibraryStore.shared recents] mutableCopy]", read("RootViewController+Services.m"))
        settings = read("SettingsViewController.m")
        self.assertIn("[[HostLibraryStore.shared recents] count]", settings)
        self.assertIn("[[HostLibraryStore.shared allFavorites] count]", settings)

    def test_backup_reads_store_and_restore_syncs_store(self):
        backup = read("HostBackup.m")
        self.assertIn('@"favorites":[HostLibraryStore.shared allFavorites]?:@[]', backup)
        self.assertIn('@"favorites":[HostLibraryStore.shared allFavorites]?:@[]', backup)
        self.assertIn("NSArray *recents=[HostLibraryStore.shared recents];", backup)
        self.assertIn('[HostLibraryStore.shared replaceFavorites:backup[@"favorites"]];', backup)
        self.assertIn('[HostLibraryStore.shared replaceRecents:', backup)
        # mediaFavorites/mediaHistory restore also writes to NSUserDefaults for two-sided consistency
        self.assertIn('[d setObject:backup[@"vodFavorites"] forKey:@"cctv.mediaFavorites.v1"]', backup)
        self.assertIn('[d setObject:defaultsRows forKey:@"cctv.mediaWatchHistory.v1"]', backup)
        self.assertIn('[HostLibraryStore.shared markRestorePendingIfFallback];', backup)

    def test_unrelated_defaults_untouched(self):
        root = read("RootViewController.m")
        self.assertIn('@"cctv.lastBottomTab.v1"', root)
        self.assertIn('forKey:@"subscriptions"', root)
        catalog = read("RootViewController+Catalog.m")
        self.assertIn('arrayForKey:@"subscriptions"', catalog)
        self.assertIn('forKey:@"channelGridMode"', catalog)

    def test_fallback_pending_and_reconciliation_contracts(self):
        m = read("HostLibraryStore.m")
        # fallbackPending key defined and exported
        self.assertIn('HostLibraryFallbackPendingKey = @"cctv.libraryStore.fallbackPending.v1"', m)
        self.assertIn('HostLibraryFallbackPendingKey', read("HostLibraryStore.h"))
        # restorePending key defined and exported
        self.assertIn('HostLibraryRestorePendingKey = @"cctv.libraryStore.restorePending.v1"', m)
        self.assertIn('HostLibraryRestorePendingKey', read("HostLibraryStore.h"))
        # set fallbackPending on every failure path in prepareLocked
        impl = m[m.index("@implementation HostLibraryStore"):]
        prepare_start = impl.index("- (BOOL)prepareLocked {")
        prepare_end = impl.index("- (BOOL)migrateFromDefaultsLocked {")
        prepare = impl[prepare_start:prepare_end]
        self.assertGreaterEqual(prepare.count("setBool:YES forKey:HostLibraryFallbackPendingKey"), 5)
        # reconciliation called in prepareLocked after migration markers
        self.assertIn("reconcileFallbackDataLocked", prepare)
        self.assertIn("replaceFromDefaultsLocked", prepare)
        # fallbackPending cleared after successful reconciliation
        self.assertIn("setBool:NO forKey:HostLibraryFallbackPendingKey", prepare)
        # markRestorePendingIfFallback method exists
        self.assertIn("- (void)markRestorePendingIfFallback {", m)
        self.assertIn("- (void)markRestorePendingIfFallback;", read("HostLibraryStore.h"))
        # replaceMediaFavorites/replaceMediaWatchHistory set fallbackPending on transaction failure
        impl = m[m.index("@implementation HostLibraryStore"):]
        self.assertIn("setBool:YES forKey:HostLibraryFallbackPendingKey];[self.defaults setObject:copy forKey:HostMediaFavoritesKey]", impl)
        self.assertIn("setBool:YES forKey:HostLibraryFallbackPendingKey];[self.defaults setObject:boundedHistory() forKey:HostMediaHistoryKey]", impl)
        # SmokeDriver checks HostLibraryStore.shared.mediaFavorites not legacy NSUserDefaults
        smoke = (ROOT / "Tests" / "UISmoke" / "SmokeDriver.m").read_text(encoding="utf-8")
        self.assertIn('#import "HostLibraryStore.h"', smoke)
        self.assertIn("[HostLibraryStore.shared.mediaFavorites count]>0", smoke)
        self.assertNotIn('dictionaryForKey:@"cctv.mediaFavorites.v1"]', smoke)


if __name__ == "__main__":
    unittest.main()
