"""T16 个人库/历史/收藏（M11–M13）测试。

M11：无首帧证据不建历史；续播确认前 / seek 未完成不覆盖旧进度；
     未完成且位置为 0 的记录在 Store 层直接丢弃。
M12：历史与收藏行级写入（单行 upsert/delete + SQL 内裁剪），不再整表
     DELETE + INSERT；事务失败回退 defaults 并发通知。
M13：历史与收藏统一来源解析——打开时查实时来源列表，显示时按 sourceID
     解析当前来源名（改名显示新名，来源已移除回落快照名）。

本机无法编译 iOS：源码合同用静态检查；SQL 语义把 .m 中的 SQL 字面量
抽出来交给 Python sqlite3 实际执行；M11/M13 的判定逻辑用 Python 模型
与源码逐行对照。
"""
import json
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"

HISTORY_LIMIT = 100


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


def strip_comments_and_strings(text):
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


def method_body(text, start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


# ---- M11 判定模型：与 persistPlaybackProgress + recordContext 逐行对照 ----
def vc_gate_passes(video_frame_ready, audio_only, resume_prompt_pending, pending_seek):
    """persistPlaybackProgress 的两道门。"""
    if not (video_frame_ready or audio_only):
        return False
    if resume_prompt_pending or pending_seek:
        return False
    return True


def store_guard_passes(position, duration, completed):
    """recordContext 的 Store 层守卫。"""
    if position is None or position != position or position < 0:
        return False
    if duration is None or duration != duration or duration < 0:
        duration = 0
    finished = completed or (duration > 0 and position >= duration - 2.0)
    if not finished and position <= 0:
        return False
    return True


def should_persist(video_frame_ready, audio_only, resume_prompt_pending,
                   pending_seek, position, duration, completed):
    return (vc_gate_passes(video_frame_ready, audio_only,
                           resume_prompt_pending, pending_seek)
            and store_guard_passes(position, duration, completed))


# ---- M13 显示名模型：与 MediaLibraryDisplaySourceName 逐行对照 ----
def display_source_name(entry, sources):
    source_id = entry.get("sourceID") if isinstance(entry.get("sourceID"), str) else ""
    if source_id:
        for source in sources or []:
            if str(source.get("id")) == source_id:
                name = source.get("name") if isinstance(source.get("name"), str) else ""
                if name:
                    return name
                break
    stored = entry.get("sourceName")
    return stored if isinstance(stored, str) else ""


class M11GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vc = read("MediaPlaybackViewController.m")
        cls.store = read("MediaPlaybackStateStore.m")

    def test_persist_gates_present_in_persist_method(self):
        body = method_body(self.vc, "- (void)persistPlaybackProgress {",
                           "- (void)activateBackgroundAudioSessionIfNeeded {")
        self.assertIn("if(!self.videoFrameReady&&!self.confirmedAudioOnly)return;", body)
        self.assertIn("if(self.resumePromptPending||self.pendingPlaybackSeekTime)return;", body)

    def test_evidence_flags_reset_when_item_cleared(self):
        body = method_body(self.vc, "- (void)clearCurrentPlayerItemPreservingPrefetch:(BOOL)preservePrefetch {",
                           "- (void)updateEpisodeTitle {")
        self.assertIn("self.confirmedAudioOnly=NO;self.videoFrameReady=NO;", body)
        # playResult 两条路径都经过 clearCurrentPlayerItem
        play = method_body(self.vc, "- (void)playResult:(NSDictionary *)result {",
                           "- (void)showTerminalPlaybackFailureWithStatus:")
        self.assertGreaterEqual(play.count("[self clearCurrentPlayerItem]"), 2)

    def test_store_zero_position_guard(self):
        body = method_body(self.store, "+ (void)recordContext:",
                           "+ (void)removeHistoryEntryWithKey:")
        self.assertIn("if(!finished&&position<=0)return;", body)

    def test_fresh_item_without_evidence_never_persists(self):
        self.assertFalse(should_persist(False, False, False, None, 0, 100, False))
        self.assertFalse(should_persist(False, False, False, None, 30, 100, False))

    def test_first_frame_or_audio_only_opens_the_gate(self):
        self.assertTrue(should_persist(True, False, False, None, 30, 100, False))
        self.assertTrue(should_persist(False, True, False, None, 30, 100, False))

    def test_resume_prompt_and_pending_seek_block_overwrite(self):
        self.assertFalse(should_persist(True, False, True, None, 30, 100, False))
        self.assertFalse(should_persist(True, False, False, 1800, 30, 100, False))
        self.assertFalse(should_persist(True, False, True, 1800, 0, 100, False))

    def test_zero_position_never_creates_or_overwrites(self):
        self.assertFalse(should_persist(True, False, False, None, 0, 100, False))
        self.assertFalse(should_persist(False, True, False, None, 0, 100, False))
        # 完成态（距片尾 2 秒内或显式 completed）不受 0 位置守卫拦
        self.assertTrue(should_persist(True, False, False, None, 99, 100, False))
        self.assertTrue(should_persist(True, False, False, None, 0, 0, True))

    def test_negative_or_nan_position_rejected(self):
        self.assertFalse(should_persist(True, False, False, None, -1, 100, False))
        self.assertFalse(should_persist(True, False, False, None, float("nan"), 100, False))


class M12StoreTests(unittest.TestCase):
    INSERT_HISTORY = ("INSERT OR REPLACE INTO media_watch_history"
                      "(key, payload, watched_at, position) VALUES(?, ?, ?, ?);")
    INSERT_FAVORITE = ("INSERT OR REPLACE INTO media_favorites"
                       "(key, payload, updated_at, position) VALUES(?, ?, ?, ?);")
    MIN_POS = "SELECT COALESCE(MIN(position), 1) - 1 FROM media_watch_history;"
    MAX_POS = "SELECT COALESCE(MAX(position), -1) + 1 FROM media_favorites;"

    @classmethod
    def setUpClass(cls):
        cls.h = read("HostLibraryStore.h")
        cls.m = read("HostLibraryStore.m")
        cls.state = read("MediaPlaybackStateStore.m")
        cls.browser = read("MediaBrowserViewController.m")
        cls.impl = cls.m[cls.m.index("@implementation HostLibraryStore"):]

    def trim_sql(self):
        return ("DELETE FROM media_watch_history WHERE key NOT IN "
                "(SELECT key FROM media_watch_history ORDER BY position ASC LIMIT %d);"
                % HISTORY_LIMIT)

    def test_public_api_declared(self):
        for sig in (
            "- (void)upsertMediaWatchHistoryEntry:(NSDictionary *)entry replacingKey:(nullable NSString *)previousKey;",
            "- (void)removeMediaWatchHistoryEntryWithKey:(NSString *)key;",
            "- (void)upsertMediaFavoriteWithKey:(NSString *)key payload:(NSDictionary *)payload;",
            "- (void)removeMediaFavoriteWithKey:(NSString *)key;",
            "FOUNDATION_EXPORT NSString *const HostLibraryStoreMediaHistoryWriteFailedNotification;",
        ):
            self.assertIn(sig, self.h)

    def test_record_context_uses_row_upsert_not_whole_table_replace(self):
        body = method_body(self.state, "+ (void)recordContext:",
                           "+ (void)removeHistoryEntryWithKey:")
        self.assertIn("upsertMediaWatchHistoryEntry:entry replacingKey:previousKey", body)
        self.assertNotIn("replaceMediaWatchHistory", body)
        self.assertNotIn("DELETE FROM media_watch_history", body)

    def test_remove_entry_uses_row_delete(self):
        body = method_body(self.state, "+ (void)removeHistoryEntryWithKey:",
                           "+ (void)clearWatchHistory {")
        self.assertIn("removeMediaWatchHistoryEntryWithKey:key", body)
        self.assertNotIn("replaceMediaWatchHistory", body)

    def test_upsert_sql_literals_present(self):
        self.assertIn(self.INSERT_HISTORY, self.m)
        self.assertIn(self.MIN_POS, self.m)
        self.assertIn(self.trim_sql().replace("100", "%lu"), self.m)
        self.assertIn("DELETE FROM media_watch_history WHERE key = ?;", self.m)
        self.assertIn(self.INSERT_FAVORITE, self.m)
        self.assertIn(self.MAX_POS, self.m)

    def test_failure_notification_posted_after_defaults_fallback(self):
        body = method_body(self.m, "- (void)upsertMediaWatchHistoryEntry:",
                           "- (void)removeMediaWatchHistoryEntryWithKey:")
        self.assertIn("HostLibraryStoreMediaHistoryWriteFailedNotification", self.m)
        self.assertIn("postNotificationName:HostLibraryStoreMediaHistoryWriteFailedNotification", body)
        self.assertLess(body.index("setBool:YES forKey:HostLibraryFallbackPendingKey"),
                        body.index("postNotificationName:HostLibraryStoreMediaHistoryWriteFailedNotification"))

    def test_toggle_favorite_and_unfavorite_use_row_api(self):
        self.assertIn("upsertMediaFavoriteWithKey:key payload:", self.browser)
        self.assertIn("removeMediaFavoriteWithKey:key", self.browser)
        self.assertIn("removeMediaFavoriteWithKey:favKey", self.browser)
        # 清空与备份恢复仍走整表替换（有意保留）
        self.assertIn("[HostLibraryStore.shared replaceMediaFavorites:@{}]", self.browser)

    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        schema = (
            "CREATE TABLE IF NOT EXISTS media_favorites (key TEXT PRIMARY KEY NOT NULL, "
            "payload BLOB NOT NULL, updated_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);"
            "CREATE TABLE IF NOT EXISTS media_watch_history (key TEXT PRIMARY KEY NOT NULL, "
            "payload BLOB NOT NULL, watched_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);"
        )
        self.assertIn("CREATE TABLE IF NOT EXISTS media_favorites (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);", self.m)
        self.assertIn("CREATE TABLE IF NOT EXISTS media_watch_history (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, watched_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);", self.m)
        self.db.executescript(schema)

    def upsert_history(self, key, previous=None, watched=0.0):
        if previous:
            self.db.execute("DELETE FROM media_watch_history WHERE key = ?;", (previous,))
        self.db.execute("DELETE FROM media_watch_history WHERE key = ?;", (key,))
        pos = self.db.execute(self.MIN_POS).fetchone()[0]
        self.db.execute(self.INSERT_HISTORY,
                        (key, json.dumps({"key": key, "position": watched}).encode(), watched, pos))
        self.db.execute(self.trim_sql())

    def history_keys(self):
        return [r[0] for r in self.db.execute(
            "SELECT key FROM media_watch_history ORDER BY position ASC;")]

    def history_payload(self, key):
        row = self.db.execute(
            "SELECT payload FROM media_watch_history WHERE key = ?;", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def test_upsert_new_entry_goes_first_others_untouched(self):
        for k in ("a", "b", "c"):
            self.upsert_history(k, watched=float(ord(k)))
        before = {k: self.history_payload(k) for k in ("a", "b", "c")}
        self.upsert_history("d", watched=9.0)
        self.assertEqual(self.history_keys(), ["d", "c", "b", "a"])
        for k in ("a", "b", "c"):
            self.assertEqual(self.history_payload(k), before[k])

    def test_upsert_existing_key_updates_in_place_and_moves_first(self):
        for k in ("a", "b", "c"):
            self.upsert_history(k, watched=float(ord(k)))
        self.upsert_history("a", watched=999.0)
        self.assertEqual(self.history_keys(), ["a", "c", "b"])
        self.assertEqual(self.history_payload("a")["position"], 999.0)
        self.assertEqual(len(self.history_keys()), 3)

    def test_upsert_with_changed_identity_deletes_old_row(self):
        for k in ("old-line", "b", "c"):
            self.upsert_history(k, watched=1.0)
        self.upsert_history("new-line", previous="old-line", watched=2.0)
        self.assertEqual(self.history_keys(), ["new-line", "c", "b"])
        self.assertIsNone(self.history_payload("old-line"))

    def test_cap_enforced_in_sql_not_in_memory(self):
        for i in range(105):
            self.upsert_history("k%03d" % i, watched=float(i))
        keys = self.history_keys()
        self.assertEqual(len(keys), 100)
        self.assertEqual(keys[0], "k104")
        self.assertEqual(keys[-1], "k005")
        self.assertNotIn("k000", keys)

    def test_row_delete_removes_only_that_key(self):
        for k in ("a", "b", "c"):
            self.upsert_history(k, watched=1.0)
        self.db.execute("DELETE FROM media_watch_history WHERE key = ?;", ("b",))
        self.assertEqual(self.history_keys(), ["c", "a"])

    def test_favorites_upsert_and_row_delete(self):
        def fav_upsert(key, name):
            pos = self.db.execute(self.MAX_POS).fetchone()[0]
            self.db.execute(self.INSERT_FAVORITE,
                            (key, json.dumps({"name": name}).encode(), 0.0, pos))

        fav_upsert("f1", "A")
        fav_upsert("f2", "B")
        fav_upsert("f1", "A2")  # 同 key 覆盖，不产生重复行
        rows = self.db.execute("SELECT key, payload FROM media_favorites;").fetchall()
        self.assertEqual(len(rows), 2)
        self.assertEqual(json.loads(dict(rows)["f1"])["name"], "A2")
        self.db.execute("DELETE FROM media_favorites WHERE key = ?;", ("f2",))
        rows = self.db.execute("SELECT key FROM media_favorites;").fetchall()
        self.assertEqual(rows, [("f1",)])


class M13SourceResolutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.browser = read("MediaBrowserViewController.m")

    def test_display_name_helper_and_both_lists_use_it(self):
        self.assertIn("static NSString *MediaLibraryDisplaySourceName(NSDictionary *entry, NSArray *sources) {",
                      self.browser)
        self.assertEqual(
            self.browser.count("MediaLibraryDisplaySourceName(entry,self.sources)"), 2)

    def test_single_shared_lookup_for_open_paths(self):
        self.assertIn("- (NSDictionary *)sourceForLibraryEntry:(NSDictionary *)entry {",
                      self.browser)
        self.assertIn("NSDictionary *source=[self sourceForLibraryEntry:entry];",
                      self.browser)
        fav = method_body(self.browser, "- (void)openHomeFavorite:",
                          "- (void)openPendingHomeDetailForSource:")
        self.assertNotIn("for(NSDictionary *candidate in self.sources)", fav)
        hist = method_body(self.browser, "- (void)openHistoryEntry:",
                           "- (void)openHistoryDetail:")
        self.assertNotIn("for(NSDictionary *candidate in sources)", hist)
        self.assertNotIn("isEqual:entry[@\"sourceID\"]", self.browser)

    def test_removed_source_message_unified(self):
        self.assertEqual(self.browser.count('@"该来源已移除，请先在资源页恢复"'), 2)
        self.assertNotIn("该收藏对应的来源已移除", self.browser)
        self.assertNotIn("观看记录对应的来源不可用", self.browser)

    def test_list_pages_receive_live_sources(self):
        for vc in ("MediaFavoritesViewController", "MediaWatchHistoryViewController"):
            section = self.browser[self.browser.index("@interface %s" % vc):
                                   self.browser.index("@end", self.browser.index("@interface %s" % vc))]
            self.assertIn("@property(nonatomic,copy) NSArray *sources;", section)
        self.assertIn("page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];",
                      self.browser)

    def test_renamed_source_shows_new_name_in_both_lists(self):
        entry = {"sourceID": "s1", "sourceName": "旧名"}
        sources = [{"id": "s1", "name": "新名"}, {"id": "s2", "name": "另一站"}]
        self.assertEqual(display_source_name(entry, sources), "新名")

    def test_removed_source_falls_back_to_stored_snapshot(self):
        entry = {"sourceID": "gone", "sourceName": "旧名"}
        self.assertEqual(display_source_name(entry, [{"id": "s1", "name": "新名"}]), "旧名")
        self.assertEqual(display_source_name({"sourceID": "gone"}, []), "")

    def test_numeric_source_id_matches_string_entry(self):
        entry = {"sourceID": "42", "sourceName": "旧名"}
        self.assertEqual(display_source_name(entry, [{"id": 42, "name": "数字站"}]), "数字站")


class TouchedFilesBalanceTests(unittest.TestCase):
    FILES = (
        "MediaPlaybackViewController.m",
        "MediaPlaybackStateStore.m",
        "HostLibraryStore.h",
        "HostLibraryStore.m",
        "MediaBrowserViewController.m",
    )

    def test_brackets_balanced(self):
        for name in self.FILES:
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


if __name__ == "__main__":
    unittest.main()
