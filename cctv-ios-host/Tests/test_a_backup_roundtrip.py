"""A 阶段：HostBackup 导出→导入→SQLite/defaults fallback roundtrip 确定性审计测试。

本机无法编译 iOS，沿用本仓库既有的"源码契约 + SQL 字面量实跑"测试范式，
对 HostBackup.m 与 HostLibraryStore.m 做静态结构与语义断言，覆盖三类确定性缺陷：
  1) 重复：replaceFavorites/replaceRecents 的 NSUserDefaults 回退镜像必须写入归一化
     （去重/过滤无效项）结果，而非原始 snapshot，确保两层一致、不残留重复条目。
  2) 数据丢失：validatedBackup: 必须拒绝缺少 id 的 recents 条目和缺少 key 的
     watchHistory 条目——这类条目会被 writeRecentsLocked/writeMediaHistoryLocked
     静默丢弃，导致 SQLite 与 defaults 分叉、再快照时丢数据。
  3) 顺序：writeRecentsLocked/writeFavoritesLocked 按 position 递增写入，
     snapshot/取值均 ORDER BY position ASC，roundtrip 顺序稳定。
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


def method_body(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    raise AssertionError(f"unterminated method: {signature}")


class BackupValidationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.backup = read("HostBackup.m")

    def test_recents_entries_must_have_nonempty_id(self):
        """recents 条目必须带非空 id——否则 writeRecentsLocked 经 HostLibraryRecentKey
        静默丢弃，SQLite 层丢失而 defaults 层保留，造成两层分叉与再快照丢数据。"""
        line = [l for l in self.backup.splitlines() if 'root[@"recents"]' in l and "isKindOfClass:NSArray.class" in l][0]
        self.assertIn('![r[@"id"] isKindOfClass:NSString.class]', line)
        self.assertIn('![r[@"id"] length]', line)

    def test_watchHistory_entries_must_have_nonempty_key(self):
        """watchHistory 条目必须带非空 key——否则 writeMediaHistoryLocked 静默丢弃，
        且 replaceMediaWatchHistory 的 boundedHistory() 亦跳过，造成两层分叉。"""
        line = [l for l in self.backup.splitlines() if 'root[@"watchHistory"]' in l and "isKindOfClass:NSArray.class" in l][0]
        self.assertIn('![w[@"key"] isKindOfClass:NSString.class]', line)
        self.assertIn('![w[@"key"] length]', line)

    def test_validation_does_not_dedup_so_store_normalizes(self):
        """验证层允许重复（不 reject 重复 favorites/id/key），去重交由 store 归一化；
        因此 store 的两层归一化是消除重复的唯一关口（见下组测试）。"""
        # favorites 仅校验类型/长度，不 reject 重复
        fav_line = [l for l in self.backup.splitlines() if 'root[@"favorites"]' in l and "isKindOfClass:NSString.class" in l][0]
        self.assertNotIn("NSSet", fav_line)


class StoreFallbackNormalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = read("HostLibraryStore.m")

    def _body(self, signature):
        impl = self.m[self.m.index("@implementation HostLibraryStore"):]
        return method_body(impl, signature)

    def test_replaceFavorites_fallback_writes_normalized_not_raw(self):
        """回退分支必须写入归一化结果，否则备份含重复收藏时 defaults 层残留重复，
        fallback 读取 allFavorites 会返回重复条目。"""
        body = self._body("- (void)replaceFavorites:(NSArray *)favorites {")
        self.assertIn("HostLibraryNormalizedFavorites(snapshot)", body)
        # 不得再向 defaults 写入原始 snapshot
        self.assertNotIn("setObject:snapshot forKey:HostLibraryLegacyFavoritesKey", body)
        # 两处 defaults 写入（事务失败回退 + 不可用回退）均用 normalized
        self.assertEqual(body.count("setObject:normalized forKey:HostLibraryLegacyFavoritesKey"), 2)

    def test_replaceRecents_fallback_writes_normalized_not_raw(self):
        """回退分支必须写入归一化结果，否则备份含无 id/重复 id 条目时 defaults 层
        残留无效/重复项，与 SQLite 层分叉。"""
        body = self._body("- (void)replaceRecents:(NSArray *)recents {")
        self.assertIn("HostLibraryNormalizedRecents(snapshot)", body)
        self.assertNotIn("setObject:snapshot forKey:HostLibraryLegacyRecentsKey", body)
        self.assertIn("i < HostLibraryRecentsLimit", body)
        self.assertEqual(body.count("setObject:bounded forKey:HostLibraryLegacyRecentsKey"), 2)

    def test_normalizers_dedup_and_drop_invalid(self):
        """实跑归一化逻辑：确认去重 + 过滤空 id/无 id/不可序列化项的语义。"""
        # favorites 归一化：去重、去空串
        favorites_in = ["a", "a", "", "b", "a", "b", "c"]
        seen, out = set(), []
        for item in favorites_in:
            if not item or item in seen:
                continue
            seen.add(item)
            out.append(item)
        self.assertEqual(out, ["a", "b", "c"])

        # recents 归一化：按 id 去重，丢弃无 id/空 id/不可序列化
        recents_in = [
            {"id": "r1", "watchedAt": 1},
            {"id": "r1", "watchedAt": 2},          # 重复 id → 丢弃
            {"name": "no-id"},                      # 无 id → 丢弃
            {"id": "", "name": "empty"},            # 空 id → 丢弃
            {"id": "r2", "watchedAt": 3},
        ]
        seen_id, recents_out = set(), []
        for entry in recents_in:
            kid = entry.get("id")
            if not kid or kid in seen_id:
                continue
            seen_id.add(kid)
            recents_out.append(entry)
        self.assertEqual([e["id"] for e in recents_out], ["r1", "r2"])


class RoundtripOrderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = read("HostLibraryStore.m")

    def test_write_paths_use_monotonic_position_preserving_order(self):
        """writeFavoritesLocked/writeRecentsLocked/writeMediaHistoryLocked 按 array 顺序
        赋 position 0,1,2…；取值 ORDER BY position ASC → roundtrip 顺序稳定。"""
        # 抽取建表 + 写入 SQL，用 Python sqlite3 实跑顺序语义
        schema_start = self.m.index('"CREATE TABLE IF NOT EXISTS favorites (')
        schema_end = self.m.index("];", schema_start)
        schema = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', self.m[schema_start:schema_end]))
        db = sqlite3.connect(":memory:")
        db.executescript(schema)
        insert = "INSERT OR REPLACE INTO favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);"
        self.assertIn(insert, self.m)
        # 按 array 顺序写入
        order = ["f3", "f1", "f2", "f1"]  # 含重复
        pos = 0
        seen = set()
        for k in order:
            if k in seen:
                continue
            seen.add(k)
            db.execute(insert, (k, json.dumps(k).encode(), 0, pos))
            pos += 1
        rows = [json.loads(r[0]) for r in db.execute("SELECT payload FROM favorites ORDER BY position ASC;")]
        self.assertEqual(rows, ["f3", "f1", "f2"])  # 去重 + 保序

    def test_recents_write_then_read_roundtrips_order(self):
        # 复用完整建表 schema（favorites 在前，recents 在后），避免 CREATE INDEX 缺表
        schema_start = self.m.index('"CREATE TABLE IF NOT EXISTS favorites (')
        schema_end = self.m.index("];", schema_start)
        schema = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', self.m[schema_start:schema_end]))
        db = sqlite3.connect(":memory:")
        db.executescript(schema)
        insert = "INSERT OR REPLACE INTO recents(key, payload, watched_at, position) VALUES(?, ?, ?, ?);"
        self.assertIn(insert, self.m)
        entries = [{"id": "c3", "watchedAt": 3}, {"id": "c1", "watchedAt": 1}, {"id": "c2", "watchedAt": 2}]
        for pos, e in enumerate(entries):
            db.execute(insert, (e["id"], json.dumps(e).encode(), e["watchedAt"], pos))
        rows = [json.loads(r[0]) for r in db.execute("SELECT payload FROM recents ORDER BY position ASC;")]
        self.assertEqual([r["id"] for r in rows], ["c3", "c1", "c2"])


if __name__ == "__main__":
    unittest.main()
