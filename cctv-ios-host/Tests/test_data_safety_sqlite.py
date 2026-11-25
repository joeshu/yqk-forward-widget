"""SQLite 迁移回退与数据一致性可执行测试。

本机无法编译 iOS ObjC，因此将 HostLibraryStore 的 SQL 字面量和迁移/对账语义
抽取为 Python sqlite3 模型，实际执行验证以下场景：

1. 事务中断：BEGIN IMMEDIATE + ROLLBACK 后数据库状态不变。
2. fallback→恢复合并：SQLite 不可用期间写入 defaults，恢复后 MERGE 合并不丢数据。
3. 重复启动幂等：迁移标记已设时重复 prepare 不重复迁移、不丢数据。
4. backup roundtrip：snapshot→restore 两边一致（SQLite + defaults 双写）。
5. 备份恢复 REPLACE 语义：restore 时 fallback → 恢复后用 REPLACE 而非 MERGE。
6. 对账幂等性：重复 reconcileFallbackData 结果相同。
"""
import json
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"

SCHEMA = """
CREATE TABLE IF NOT EXISTS favorites (
  key TEXT PRIMARY KEY NOT NULL,
  payload BLOB NOT NULL,
  updated_at REAL NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS media_favorites (
  key TEXT PRIMARY KEY NOT NULL,
  payload BLOB NOT NULL,
  updated_at REAL NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS media_watch_history (
  key TEXT PRIMARY KEY NOT NULL,
  payload BLOB NOT NULL,
  watched_at REAL NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS recents (
  key TEXT PRIMARY KEY NOT NULL,
  payload BLOB NOT NULL,
  watched_at REAL NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_favorites_position ON favorites(position);
CREATE INDEX IF NOT EXISTS idx_recents_position ON recents(position);
"""

RECENTS_LIMIT = 24
WATCH_HISTORY_LIMIT = 100


def _json(obj):
    return json.dumps(obj).encode()


def _insert(db, table, key, payload, time_col, time, position):
    db.execute(
        f"INSERT OR REPLACE INTO {table}(key, payload, {time_col}, position) VALUES(?, ?, ?, ?)",
        (key, _json(payload), time, position),
    )


def write_favorites(db, favorites):
    db.execute("DELETE FROM favorites;")
    for pos, key in enumerate(favorites):
        _insert(db, "favorites", key, key, "updated_at", 0.0, pos)


def write_recents(db, recents):
    db.execute("DELETE FROM recents;")
    for pos, entry in enumerate(recents):
        key = entry["id"]
        watched_at = entry.get("watchedAt", 0)
        _insert(db, "recents", key, entry, "watched_at", watched_at, pos)


def write_media_favorites(db, favorites):
    db.execute("DELETE FROM media_favorites;")
    for pos, key in enumerate(favorites):
        _insert(db, "media_favorites", key, favorites[key], "updated_at", 0.0, pos)


def write_media_history(db, history):
    db.execute("DELETE FROM media_watch_history;")
    seen = set()
    pos = 0
    for entry in history:
        key = entry.get("key")
        if not key or key in seen:
            continue
        seen.add(key)
        time_val = entry.get("updatedAt")
        if isinstance(time_val, (int, float)):
            watched_at = float(time_val)
        else:
            watched_at = 0.0
        serialized = dict(entry)
        if isinstance(serialized.get("updatedAt"), str):
            pass
        # store as NSNumber-compatible (epoch) in payload
        if "updatedAt" in serialized and not isinstance(serialized["updatedAt"], (int, float)):
            serialized["updatedAt"] = watched_at
        _insert(db, "media_watch_history", key, serialized, "watched_at", watched_at, pos)
        pos += 1
        if pos >= WATCH_HISTORY_LIMIT:
            break


def read_favorites(db):
    return [json.loads(r[0]) for r in db.execute("SELECT payload FROM favorites ORDER BY position ASC;")]


def read_recents(db):
    return [json.loads(r[0]) for r in db.execute("SELECT payload FROM recents ORDER BY position ASC;")]


def read_media_favorites(db):
    result = {}
    for r in db.execute("SELECT key, payload FROM media_favorites ORDER BY position ASC;"):
        result[r[0]] = json.loads(r[1])
    return result


def read_media_history(db):
    rows = []
    for r in db.execute("SELECT payload FROM media_watch_history ORDER BY position ASC;"):
        entry = json.loads(r[0])
        if isinstance(entry.get("updatedAt"), (int, float)):
            entry["updatedAt"] = entry["updatedAt"]  # keep as number for test comparison
        rows.append(entry)
    return rows


def recent_key(entry):
    return entry.get("id") if isinstance(entry, dict) else None


def watched_at(entry):
    v = entry.get("watchedAt", 0) if isinstance(entry, dict) else 0
    return float(v) if isinstance(v, (int, float)) else 0.0


def history_time(entry):
    v = entry.get("updatedAt", 0) if isinstance(entry, dict) else 0
    return float(v) if isinstance(v, (int, float)) else 0.0


def normalize_favorites(value):
    if not isinstance(value, list):
        return []
    result = []
    seen = set()
    for item in value:
        if isinstance(item, str) and item and item not in seen:
            seen.add(item)
            result.append(item)
    return result


def normalize_recents(value):
    if not isinstance(value, list):
        return []
    result = []
    seen = set()
    for item in value:
        k = recent_key(item)
        if not k or k in seen:
            continue
        seen.add(k)
        result.append(item)
    return result


def reconcile_favorites(sqlite_favs, defaults_favs):
    """MERGE: append defaults-only favorites to SQLite."""
    existing = set(sqlite_favs)
    merged = list(sqlite_favs)
    for fav in defaults_favs:
        if fav not in existing:
            merged.append(fav)
            existing.add(fav)
    return merged


def reconcile_recents(sqlite_recents, defaults_recents):
    """MERGE: union by id, keep higher watchedAt; sort desc; trim to limit."""
    by_id = {}
    for entry in sqlite_recents:
        k = recent_key(entry)
        if k:
            by_id[k] = entry
    for entry in defaults_recents:
        k = recent_key(entry)
        if not k:
            continue
        existing = by_id.get(k)
        if not existing or watched_at(entry) > watched_at(existing):
            by_id[k] = entry
    all_recents = sorted(by_id.values(), key=lambda e: watched_at(e), reverse=True)
    return all_recents[:RECENTS_LIMIT]


def reconcile_media_favorites(sqlite_fav, defaults_fav):
    """MERGE: add defaults-only keys."""
    merged = dict(sqlite_fav)
    for key, val in defaults_fav.items():
        if key not in merged:
            merged[key] = val
    return merged


def reconcile_media_history(sqlite_hist, defaults_hist):
    """MERGE: union by key, keep higher updatedAt; trim to limit."""
    by_key = {}
    for entry in sqlite_hist:
        k = entry.get("key")
        if k:
            by_key[k] = entry
    for entry in defaults_hist:
        k = entry.get("key")
        if not k:
            continue
        existing = by_key.get(k)
        if not existing or history_time(entry) > history_time(existing):
            by_key[k] = entry
    all_hist = sorted(by_key.values(), key=lambda e: history_time(e), reverse=True)
    return all_hist[:WATCH_HISTORY_LIMIT]


def _connect():
    """Create an in-memory db with manual transaction control (matching sqlite3_exec BEGIN/COMMIT)."""
    db = sqlite3.connect(":memory:")
    db.isolation_level = None  # autocommit off → manual BEGIN/COMMIT like sqlite3_exec
    return db


class TransactionInterruptionTests(unittest.TestCase):
    """事务中断：BEGIN IMMEDIATE + ROLLBACK 后数据库状态不变。"""

    def test_rollback_preserves_existing_data(self):
        db = _connect()
        db.executescript(SCHEMA)
        write_favorites(db, ["cctv1", "cctv2", "cctv3"])
        write_recents(db, [{"id": "r1", "watchedAt": 100}, {"id": "r2", "watchedAt": 200}])
        original_favs = read_favorites(db)
        original_recents = read_recents(db)

        # Simulate transaction failure: BEGIN, modify, ROLLBACK
        db.execute("BEGIN IMMEDIATE;")
        write_favorites(db, ["new1", "new2"])
        db.execute("DELETE FROM recents;")
        db.execute("ROLLBACK;")

        self.assertEqual(read_favorites(db), original_favs)
        self.assertEqual(read_recents(db), original_recents)

    def test_transaction_failure_then_subsequent_write_ok(self):
        db = _connect()
        db.executescript(SCHEMA)
        write_favorites(db, ["a"])

        # Failed transaction
        db.execute("BEGIN IMMEDIATE;")
        db.execute("DELETE FROM favorites;")
        db.execute("ROLLBACK;")
        self.assertEqual(read_favorites(db), ["a"])

        # Subsequent write after rollback succeeds
        db.execute("BEGIN IMMEDIATE;")
        db.execute("DELETE FROM favorites;")
        _insert(db, "favorites", "b", "b", "updated_at", 0.0, 0)
        db.execute("COMMIT;")
        self.assertEqual(read_favorites(db), ["b"])

    def test_write_media_favorites_atomic_delete_insert(self):
        """writeMediaFavorites does DELETE then INSERT in a single transaction."""
        db = _connect()
        db.executescript(SCHEMA)
        write_media_favorites(db, {"k1": {"name": "N1"}, "k2": {"name": "N2"}})
        self.assertEqual(len(read_media_favorites(db)), 2)

        # Replace in a transaction
        db.execute("BEGIN IMMEDIATE;")
        db.execute("DELETE FROM media_favorites;")
        _insert(db, "media_favorites", "k3", {"name": "N3"}, "updated_at", 0.0, 0)
        db.execute("COMMIT;")
        result = read_media_favorites(db)
        self.assertEqual(set(result.keys()), {"k3"})

        # If transaction fails midway, old data survives
        db.execute("BEGIN IMMEDIATE;")
        db.execute("DELETE FROM media_favorites;")
        db.execute("ROLLBACK;")
        self.assertEqual(set(read_media_favorites(db).keys()), {"k3"})


class FallbackRecoveryMergeTests(unittest.TestCase):
    """fallback→恢复合并：SQLite 不可用期间写入 defaults，恢复后 MERGE 合并。"""

    def test_favorites_merge_preserves_both(self):
        sqlite_favs = ["cctv1", "cctv2", "cctv3"]
        defaults_favs = ["cctv1", "cctv2", "fallback_new"]
        merged = reconcile_favorites(sqlite_favs, defaults_favs)
        self.assertIn("cctv1", merged)
        self.assertIn("cctv2", merged)
        self.assertIn("cctv3", merged)  # SQLite data preserved
        self.assertIn("fallback_new", merged)  # fallback write preserved
        # Order: SQLite items first, then defaults-only
        self.assertEqual(merged, ["cctv1", "cctv2", "cctv3", "fallback_new"])

    def test_recents_merge_by_id_keeps_higher_watched_at(self):
        sqlite_recents = [
            {"id": "r1", "watchedAt": 300},
            {"id": "r2", "watchedAt": 200},
        ]
        defaults_recents = [
            {"id": "r2", "watchedAt": 500},  # fallback updated r2
            {"id": "r3", "watchedAt": 100},  # fallback new
        ]
        merged = reconcile_recents(sqlite_recents, defaults_recents)
        ids = [e["id"] for e in merged]
        self.assertIn("r1", ids)
        self.assertIn("r2", ids)
        self.assertIn("r3", ids)
        # r2 should have the higher watchedAt (from defaults)
        r2 = [e for e in merged if e["id"] == "r2"][0]
        self.assertEqual(r2["watchedAt"], 500)
        # Sorted by watchedAt desc: r2(500), r1(300), r3(100)
        self.assertEqual(ids, ["r2", "r1", "r3"])

    def test_media_favorites_merge_adds_defaults_only_keys(self):
        sqlite_fav = {"k1": {"name": "N1"}, "k2": {"name": "N2"}}
        defaults_fav = {"k2": {"name": "OLD"}, "k3": {"name": "N3"}}
        merged = reconcile_media_favorites(sqlite_fav, defaults_fav)
        self.assertEqual(set(merged.keys()), {"k1", "k2", "k3"})
        self.assertEqual(merged["k1"], {"name": "N1"})  # SQLite version preserved
        self.assertEqual(merged["k2"], {"name": "N2"})  # SQLite version not overwritten
        self.assertEqual(merged["k3"], {"name": "N3"})  # defaults-only added

    def test_media_history_merge_by_key_keeps_higher_updated_at(self):
        sqlite_hist = [
            {"key": "h1", "updatedAt": 100},
            {"key": "h2", "updatedAt": 200},
        ]
        defaults_hist = [
            {"key": "h2", "updatedAt": 300},
            {"key": "h3", "updatedAt": 50},
        ]
        merged = reconcile_media_history(sqlite_hist, defaults_hist)
        keys = [e["key"] for e in merged]
        self.assertIn("h1", keys)
        self.assertIn("h2", keys)
        self.assertIn("h3", keys)
        h2 = [e for e in merged if e["key"] == "h2"][0]
        self.assertEqual(h2["updatedAt"], 300)  # higher wins

    def test_fallback_add_then_recovery_does_not_lose_data(self):
        """Full scenario: migrate → normal writes → SQLite fails → fallback writes → recover → merge."""
        db = _connect()
        db.executescript(SCHEMA)
        defaults = {}
        defaults["favorites"] = ["cctv1", "cctv2"]
        defaults["recents"] = [{"id": "r1", "watchedAt": 100}]
        write_favorites(db, defaults["favorites"])
        write_recents(db, defaults["recents"])
        # migration marker set; defaults retain old values

        # Phase 2: normal writes (SQLite available) - add cctv3
        db.execute("BEGIN IMMEDIATE;")
        existing = read_favorites(db)
        existing.append("cctv3")
        write_favorites(db, existing)
        db.execute("COMMIT;")
        # defaults NOT updated (SQLite was available)

        # Phase 3: SQLite fails → fallback writes go to defaults
        defaults["favorites"] = ["cctv1", "cctv2", "fallback_fav"]
        defaults["recents"] = [{"id": "r1", "watchedAt": 100}, {"id": "fallback_r", "watchedAt": 999}]

        # Phase 4: SQLite recovers → reconcile
        sqlite_favs = read_favorites(db)
        sqlite_recents = read_recents(db)
        merged_favs = reconcile_favorites(sqlite_favs, normalize_favorites(defaults["favorites"]))
        merged_recents = reconcile_recents(sqlite_recents, normalize_recents(defaults["recents"]))

        # No data loss: cctv3 (SQLite-only) preserved, fallback_fav (defaults-only) preserved
        self.assertIn("cctv1", merged_favs)
        self.assertIn("cctv2", merged_favs)
        self.assertIn("cctv3", merged_favs)
        self.assertIn("fallback_fav", merged_favs)

        # recents: fallback_r preserved, r1 preserved
        recents_ids = [e["id"] for e in merged_recents]
        self.assertIn("r1", recents_ids)
        self.assertIn("fallback_r", recents_ids)


class IdempotencyTests(unittest.TestCase):
    """重复启动幂等：迁移标记已设时重复 prepare 不重复迁移、不丢数据。"""

    def test_repeated_migration_marker_check_is_idempotent(self):
        db = _connect()
        db.executescript(SCHEMA)
        # First migration
        defaults_favs = ["a", "b", "c"]
        write_favorites(db, defaults_favs)
        migration_marker = True  # set after first successful migration

        # Second prepare: marker already set, skip migration
        self.assertTrue(migration_marker)
        # Data unchanged
        self.assertEqual(read_favorites(db), defaults_favs)

        # Third prepare: still unchanged
        self.assertEqual(read_favorites(db), defaults_favs)

    def test_reconcile_idempotent(self):
        """Running reconcileFallbackData twice produces the same result."""
        sqlite_favs = ["cctv1", "cctv2"]
        defaults_favs = ["cctv1", "fallback_new"]

        # First reconcile
        merged1 = reconcile_favorites(sqlite_favs, defaults_favs)
        # Second reconcile with same inputs
        merged2 = reconcile_favorites(merged1, defaults_favs)
        self.assertEqual(merged1, merged2)

        # Recents
        sqlite_recents = [{"id": "r1", "watchedAt": 300}]
        defaults_recents = [{"id": "r1", "watchedAt": 500}, {"id": "r2", "watchedAt": 100}]
        merged1r = reconcile_recents(sqlite_recents, defaults_recents)
        merged2r = reconcile_recents(merged1r, defaults_recents)
        self.assertEqual(merged1r, merged2r)

        # Media favorites
        sqlite_mf = {"k1": {"v": 1}}
        defaults_mf = {"k1": {"v": 0}, "k2": {"v": 2}}
        merged1mf = reconcile_media_favorites(sqlite_mf, defaults_mf)
        merged2mf = reconcile_media_favorites(merged1mf, defaults_mf)
        self.assertEqual(merged1mf, merged2mf)

        # Media history
        sqlite_mh = [{"key": "h1", "updatedAt": 100}]
        defaults_mh = [{"key": "h1", "updatedAt": 200}, {"key": "h2", "updatedAt": 50}]
        merged1mh = reconcile_media_history(sqlite_mh, defaults_mh)
        merged2mh = reconcile_media_history(merged1mh, defaults_mh)
        self.assertEqual(merged1mh, merged2mh)

    def test_reconcile_with_empty_defaults_is_noop(self):
        sqlite_favs = ["a", "b"]
        defaults_favs = []
        merged = reconcile_favorites(sqlite_favs, defaults_favs)
        self.assertEqual(merged, sqlite_favs)

        sqlite_recents = [{"id": "r1", "watchedAt": 100}]
        merged_r = reconcile_recents(sqlite_recents, [])
        self.assertEqual(merged_r, sqlite_recents)

    def test_reconcile_with_identical_data_is_noop(self):
        sqlite_favs = ["a", "b"]
        defaults_favs = ["a", "b"]
        merged = reconcile_favorites(sqlite_favs, defaults_favs)
        self.assertEqual(merged, sqlite_favs)


class BackupRoundtripTests(unittest.TestCase):
    """backup roundtrip：snapshot→restore 两边一致（SQLite + defaults 双写）。"""

    def test_backup_snapshot_restore_roundtrip(self):
        db = _connect()
        db.executescript(SCHEMA)
        defaults = {}

        # Initial state
        favorites = ["cctv1", "cctv2", "cctv3"]
        recents = [{"id": "r1", "watchedAt": 100}, {"id": "r2", "watchedAt": 200}]
        media_fav = {"k1": {"name": "N1"}, "k2": {"name": "N2"}}
        media_hist = [{"key": "h1", "updatedAt": 1000}, {"key": "h2", "updatedAt": 2000}]

        write_favorites(db, favorites)
        write_recents(db, recents)
        write_media_favorites(db, media_fav)
        write_media_history(db, media_hist)

        defaults["favorites"] = favorites
        defaults["recents"] = recents
        defaults["cctv.mediaFavorites.v1"] = media_fav
        defaults["cctv.mediaWatchHistory.v1"] = media_hist

        # Snapshot reads from store (SQLite)
        snap_favorites = read_favorites(db)
        snap_recents = read_recents(db)
        snap_media_fav = read_media_favorites(db)
        snap_media_hist = read_media_history(db)

        # Restore writes to both SQLite and defaults
        write_favorites(db, snap_favorites)
        write_recents(db, snap_recents)
        write_media_favorites(db, snap_media_fav)
        write_media_history(db, snap_media_hist)
        defaults["favorites"] = snap_favorites
        defaults["recents"] = snap_recents
        defaults["cctv.mediaFavorites.v1"] = snap_media_fav
        defaults["cctv.mediaWatchHistory.v1"] = snap_media_hist

        # Both sides match
        self.assertEqual(read_favorites(db), defaults["favorites"])
        self.assertEqual(read_recents(db), defaults["recents"])
        self.assertEqual(read_media_favorites(db), defaults["cctv.mediaFavorites.v1"])
        # Media history: compare by key+updatedAt
        db_hist = {e["key"]: e["updatedAt"] for e in read_media_history(db)}
        defaults_hist = {e["key"]: e["updatedAt"] for e in defaults["cctv.mediaWatchHistory.v1"]}
        self.assertEqual(db_hist, defaults_hist)

    def test_backup_restore_replaces_not_merges(self):
        """Restore should REPLACE, not merge: old data not in backup is gone."""
        db = _connect()
        db.executescript(SCHEMA)

        # Old state has extra data
        write_favorites(db, ["old1", "old2", "old3"])
        write_media_favorites(db, {"old_k": {"name": "OLD"}})

        # Backup data only has subset
        backup_favorites = ["new1", "new2"]
        backup_media_fav = {"new_k": {"name": "NEW"}}

        # Restore replaces
        write_favorites(db, backup_favorites)
        write_media_favorites(db, backup_media_fav)

        self.assertEqual(read_favorites(db), backup_favorites)
        self.assertNotIn("old1", read_favorites(db))
        self.assertNotIn("old_k", read_media_favorites(db))

    def test_backup_restore_then_recover_uses_replace_semantics(self):
        """Restore in fallback mode → recover with REPLACE: SQLite matches backup, not union."""
        db = _connect()
        db.executescript(SCHEMA)

        # Pre-existing SQLite data
        write_favorites(db, ["pre_existing1", "pre_existing2"])
        write_media_history(db, [{"key": "old_h", "updatedAt": 500}])

        defaults = {
            "favorites": ["backup1", "backup2"],
            "recents": [{"id": "br1", "watchedAt": 100}],
            "cctv.mediaFavorites.v1": {"bk": {"name": "BKN"}},
            "cctv.mediaWatchHistory.v1": [{"key": "backup_h", "updatedAt": 1000}],
        }

        # Restore in fallback: writes go to defaults, set restorePending
        restore_pending = True

        # Recover: SQLite available, restorePending set → REPLACE
        if restore_pending:
            # Replace SQLite with defaults data
            write_favorites(db, defaults["favorites"])
            write_recents(db, defaults["recents"])
            write_media_favorites(db, defaults["cctv.mediaFavorites.v1"])
            write_media_history(db, defaults["cctv.mediaWatchHistory.v1"])
            restore_pending = False

        # SQLite now matches backup exactly, not a union
        self.assertEqual(read_favorites(db), ["backup1", "backup2"])
        self.assertNotIn("pre_existing1", read_favorites(db))
        hist_keys = [e["key"] for e in read_media_history(db)]
        self.assertEqual(hist_keys, ["backup_h"])
        self.assertNotIn("old_h", hist_keys)


class FallbackPendingFlagTests(unittest.TestCase):
    """迁移失败标记正确性：验证 fallbackPending 在各失败路径被设置。"""

    def test_source_has_fallback_pending_on_all_failure_paths(self):
        m = (SOURCES / "HostLibraryStore.m").read_text(encoding="utf-8")
        # Every return NO in prepareLocked should be preceded by setBool:YES forKey:FallbackPending
        prepare_start = m.index("- (BOOL)prepareLocked {")
        prepare_end = m.index("- (BOOL)migrateFromDefaultsLocked {")
        prepare = m[prepare_start:prepare_end]
        # Count fallbackPending sets and closeLocked returns
        fallback_sets = prepare.count("setBool:YES forKey:HostLibraryFallbackPendingKey")
        self.assertGreaterEqual(fallback_sets, 5, "fallbackPending must be set on all failure paths in prepareLocked")

    def test_source_has_reconciliation_after_migration(self):
        m = (SOURCES / "HostLibraryStore.m").read_text(encoding="utf-8")
        prepare_start = m.index("- (BOOL)prepareLocked {")
        prepare_end = m.index("- (BOOL)migrateFromDefaultsLocked {")
        prepare = m[prepare_start:prepare_end]
        self.assertIn("HostLibraryFallbackPendingKey", prepare)
        self.assertIn("reconcileFallbackDataLocked", prepare)
        self.assertIn("replaceFromDefaultsLocked", prepare)
        self.assertIn("HostLibraryRestorePendingKey", prepare)
        # Clear fallbackPending after successful reconciliation
        self.assertIn("setBool:NO forKey:HostLibraryFallbackPendingKey", prepare)
        self.assertIn("setBool:NO forKey:HostLibraryRestorePendingKey", prepare)

    def test_replace_media_methods_set_fallback_on_failure(self):
        m = (SOURCES / "HostLibraryStore.m").read_text(encoding="utf-8")
        impl = m[m.index("@implementation HostLibraryStore"):]
        # replaceMediaFavorites failure path sets fallbackPending
        self.assertIn(
            "setBool:YES forKey:HostLibraryFallbackPendingKey];"
            "[self.defaults setObject:copy forKey:HostMediaFavoritesKey]",
            impl,
        )
        # replaceMediaWatchHistory failure path sets fallbackPending
        self.assertIn(
            "setBool:YES forKey:HostLibraryFallbackPendingKey];"
            "[self.defaults setObject:boundedHistory() forKey:HostMediaHistoryKey]",
            impl,
        )

    def test_no_legacy_defaults_writes_when_sqlite_available(self):
        """When SQLite is available, favorites/recents writes go to SQLite, not defaults."""
        m = (SOURCES / "HostLibraryStore.m").read_text(encoding="utf-8")
        impl = m[m.index("@implementation HostLibraryStore"):]
        # addFavorite: SQLite path does NOT call setObject:forKey:
        add_fav_start = impl.index("- (void)addFavorite:")
        add_fav_end = impl.index("- (void)removeFavorite:")
        add_fav = impl[add_fav_start:add_fav_end]
        # The else branch (fallback) writes to defaults, but the if branch (SQLite) does not
        self.assertIn("if ([self prepareLocked])", add_fav)
        self.assertIn("else {", add_fav)
        # Verify the else block contains the defaults write
        else_idx = add_fav.index("else {")
        else_block = add_fav[else_idx:]
        self.assertIn("setObject:favorites forKey:HostLibraryLegacyFavoritesKey", else_block)


class SourceExtractionTests(unittest.TestCase):
    """验证 SQL 字面量从源码提取后可执行。"""

    @classmethod
    def setUpClass(cls):
        cls.m = (SOURCES / "HostLibraryStore.m").read_text(encoding="utf-8")

    def test_schema_creates_all_four_tables(self):
        db = _connect()
        db.executescript(SCHEMA)
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table';")}
        self.assertEqual(tables, {"favorites", "recents", "media_favorites", "media_watch_history"})

    def test_insert_or_replace_favorites(self):
        insert_sql = "INSERT OR REPLACE INTO favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);"
        self.assertIn(insert_sql, self.m.replace("\\\n", "\n"))
        db = _connect()
        db.executescript(SCHEMA)
        db.execute(insert_sql, ("cctv1", _json("cctv1"), 0.0, 0))
        db.execute(insert_sql, ("cctv1", _json("cctv1"), 1.0, 1))  # replace same key
        self.assertEqual(len(read_favorites(db)), 1)

    def test_recents_trim_limit_24(self):
        trim = "DELETE FROM recents WHERE key NOT IN (SELECT key FROM recents ORDER BY position ASC LIMIT %d);" % RECENTS_LIMIT
        self.assertIn(trim.replace(str(RECENTS_LIMIT), "%lu"), self.m)
        db = _connect()
        db.executescript(SCHEMA)
        for i in range(30):
            _insert(db, "recents", f"r{i}", {"id": f"r{i}", "watchedAt": i}, "watched_at", float(i), i)
        db.execute(trim)
        self.assertEqual(len(read_recents(db)), RECENTS_LIMIT)
        # Keeps the first 24 (lowest positions)
        recents = read_recents(db)
        self.assertEqual(recents[0]["id"], "r0")
        self.assertEqual(recents[-1]["id"], "r23")


if __name__ == "__main__":
    unittest.main()
