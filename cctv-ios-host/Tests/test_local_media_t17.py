"""本地媒体缺口修复（T17：挂载移除、重复导入、磁盘不足、失效文件、历史打开）
行为测试 + 源码合同。

行为部分复刻 LocalMediaStore 的展示名、重复判定与磁盘不足报错；接线部分
用源码合同锁定（挂载移除入口、删除确认范围文案、失效文件提示、历史
local-media 分支）。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'


def read_source(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def display_name(last_component):
    """复刻 LocalMediaStore.displayNameForFileURL：去掉 UUID- 前缀。"""
    name = last_component or '媒体文件'
    if len(name) > 37 and name[36] == '-':
        return name[37:]
    return name


def is_duplicate(display_name, size, existing):
    """重复导入判定：同展示名且同大小的已在库文件。existing: [(name, size)]。"""
    if not display_name or size is None:
        return False
    return any(name == display_name and s == size for name, s in existing)


def import_error(free_bytes, source_size):
    """复刻导入失败报错：磁盘不足时明确报错，否则笼统失败。"""
    if source_size is not None and free_bytes is not None and free_bytes < source_size:
        return '可用空间不足，无法保存此文件'
    return '文件复制失败'


class DisplayNameBehavior(unittest.TestCase):
    def test_uuid_prefix_stripped(self):
        uuid = '12345678-1234-1234-1234-123456789012'
        self.assertEqual(display_name(uuid + '-仙逆.mp4'), '仙逆.mp4')
        self.assertEqual(display_name('仙逆.mp4'), '仙逆.mp4')
        # 短横线不在第 37 位时不动。
        self.assertEqual(display_name('a-b.mp4'), 'a-b.mp4')
        self.assertEqual(display_name(''), '媒体文件')


class DuplicateImportBehavior(unittest.TestCase):
    def test_same_name_same_size_is_duplicate(self):
        existing = [('仙逆.mp4', 1024)]
        self.assertTrue(is_duplicate('仙逆.mp4', 1024, existing))
        # 同名不同大小不是重复（不同版本）。
        self.assertFalse(is_duplicate('仙逆.mp4', 2048, existing))
        # 同大小不同名不是重复。
        self.assertFalse(is_duplicate('斗破.mp4', 1024, existing))
        # 大小未知时不判重复（不误删）。
        self.assertFalse(is_duplicate('仙逆.mp4', None, existing))

    def test_uuid_prefixed_import_matches_stored_display_name(self):
        # 导入文件带 UUID- 前缀，库里存的也是带前缀的文件名：展示名相同才判重。
        stored = display_name('12345678-1234-1234-1234-123456789012-仙逆.mp4')
        incoming = display_name('87654321-4321-4321-4321-210987654321-仙逆.mp4')
        self.assertEqual(stored, incoming)
        self.assertTrue(is_duplicate(incoming, 1024, [(stored, 1024)]))


class DiskFullBehavior(unittest.TestCase):
    def test_disk_full_message(self):
        self.assertEqual(import_error(100, 1024), '可用空间不足，无法保存此文件')
        self.assertEqual(import_error(2048, 1024), '文件复制失败')
        self.assertEqual(import_error(None, 1024), '文件复制失败')


class LocalMediaT17Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store_h = read_source('LocalMediaStore.h')
        cls.store_m = read_source('LocalMediaStore.m')
        cls.vc_m = read_source('LocalMediaViewController.m')
        cls.browser_m = read_source('MediaBrowserViewController.m')

    def test_store_new_apis(self):
        self.assertIn('displayNameForFileURL:', self.store_h)
        self.assertIn('removeBookmarkForURL:', self.store_h)
        self.assertIn('isCopiedFileURL:', self.store_h)
        # 挂载只删书签，不删原文件。
        self.assertIn('removeBookmarkForURL', self.store_m)
        self.assertIn('duplicateCount', self.store_m)

    def test_duplicate_skip_and_disk_full(self):
        # 重复不占失败数，只记 duplicateCount，提示说“重复文件已跳过”。
        self.assertIn('重复文件已跳过', self.vc_m)
        self.assertIn('已跳过', self.vc_m)
        self.assertIn('可用空间不足，无法保存此文件', self.store_m)
        self.assertIn('lastDuplicateCount', self.store_m)

    def test_delete_confirmation_explains_scope(self):
        # 副本：只删沙盒内文件；挂载：只删书签。删除前确认，不再一键直删。
        self.assertIn('仅删除 App 沙盒内的副本，Files 中的原文件不受影响', self.vc_m)
        self.assertIn('仅移除本页的挂载记录，原文件不受影响', self.vc_m)
        self.assertIn('删除本机副本？', self.vc_m)
        self.assertIn('移除挂载？', self.vc_m)
        self.assertIn('移除挂载', self.vc_m)
        self.assertIn('confirmDeleteFileAtIndexPath', self.vc_m)

    def test_missing_file_prompts_instead_of_playing(self):
        self.assertIn('该文件已移动或删除，可左滑移除挂载', self.vc_m)
        self.assertIn('该文件已不存在', self.vc_m)

    def test_local_history_entry_opens_locally(self):
        # 历史里 local-media 条目不再误报“该来源已移除”。
        self.assertIn('openLocalHistoryEntry', self.browser_m)
        self.assertIn('"local-media"', self.browser_m)
        self.assertIn('本地文件已移动或删除', self.browser_m)


if __name__ == '__main__':
    unittest.main()
