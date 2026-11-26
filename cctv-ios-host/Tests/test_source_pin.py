"""来源固定（T06：M06）行为测试 + 源码合同。

行为部分用 Python 模型复刻改前/改后的开关写路径并真实执行：
- 旧写法：开关把 kind + 源 ID 编进 accessibilityIdentifier 再按冒号拆分、
  要求恰好两段；原生源 ID 自带两个冒号（protocol:catalogID:siteKey），
  拆出 4 段直接 return，固定状态写不进去；模块与单段 ID 的本地插件不受影响。
- 新写法：开关是结构化绑定的 MediaHomeSettingSwitch（settingKind +
  settingIdentifier 两个类型化属性），toggleSetting 直接读属性写集合；
  偏好 key（cctv.mediaHome.pinnedSources.v1）与存储值格式（源 ID 原串）
  保持不变，不迁移；重进配置页与资源选择器按整 ID 比对，排序优先。
模型与源码的对应关系由同文件合同测试锁定。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'

PINNED_KEY = 'cctv.mediaHome.pinnedSources.v1'

# 五类来源 ID（真实格式）：TVBox / MacCMS / 豆瓣 / JAR 均为原生
# protocol:catalogID:siteKey；本地插件为单段服务 key。
SOURCE_IDS = {
    'tvbox': 'tvbox-api:catalog-1:joeshu.hawk.keke',
    'maccms': 'maccms-api:catalog-1:yingtan',
    'douban': 'douban-index:catalog-1:douban',
    'jar': 'jar-bridge:catalog-1:ningmeng',
    'plugin': 'builtin-ysp',
}
MODULE_IDS = ('recommendations', 'catalog', 'continue', 'favorites', 'sources')


class FakeDefaults:
    """NSUserDefaults 的最小替身：只存数组。"""

    def __init__(self):
        self.store = {}

    def array(self, key):
        return self.store.get(key)

    def set_array(self, key, values):
        self.store[key] = sorted(values)


def pinned_sources(defaults):
    saved = defaults.array(PINNED_KEY) or []
    return {value for value in saved if isinstance(value, str) and value}


def old_decode(accessibility_identifier):
    """复刻旧 toggleSetting: 的冒号拆分。返回 (kind, id) 或 None。"""
    parts = (accessibility_identifier or '').split(':')
    if len(parts) != 2:
        return None
    return parts[0], parts[1]


class OldSwitch:
    """旧开关：只靠 accessibilityIdentifier 传身份。"""

    def __init__(self, kind, identifier):
        self.accessibility_identifier = '%s:%s' % (kind, identifier)


class NewSwitch:
    """新开关：结构化绑定（复刻 MediaHomeSettingSwitch）。"""

    def __init__(self, kind, identifier):
        self.accessibility_identifier = '%s:%s' % (kind, identifier)
        self.setting_kind = kind
        self.setting_identifier = identifier


class ConfigPage:
    """复刻 MediaHomeConfigurationViewController 的固定写读路径。"""

    def __init__(self, defaults, sources):
        self.defaults = defaults
        self.sources = sources
        self.pinned = pinned_sources(defaults)
        self.modules = set()

    def toggle(self, switch, is_on, new_style=True):
        if new_style:
            kind = getattr(switch, 'setting_kind', None)
            identifier = getattr(switch, 'setting_identifier', None)
            if kind not in ('module', 'source') or not identifier:
                return False
        else:
            decoded = old_decode(getattr(switch, 'accessibility_identifier', ''))
            if decoded is None:
                return False
            kind, identifier = decoded
        target = self.modules if kind == 'module' else self.pinned
        if is_on:
            target.add(identifier)
        else:
            target.discard(identifier)
        key = PINNED_KEY
        self.defaults.set_array(key, sorted(self.pinned))
        return True

    def cell_enabled(self, identifier):
        """复刻 cellForRow 的整 ID 比对。"""
        return identifier in self.pinned

    def picker_order(self, choices):
        """复刻资源选择器的固定优先排序。"""
        return sorted(choices,
                      key=lambda choice: 0 if choice in self.pinned else 1)


class SourcePinBehaviorTests(unittest.TestCase):
    def test_old_decoder_drops_all_native_source_ids(self):
        for kind, source_id in SOURCE_IDS.items():
            if kind == 'plugin':
                continue
            self.assertIsNone(old_decode('source:' + source_id),
                              '旧写法应丢弃 %s' % kind)

    def test_old_decoder_keeps_modules_and_local_plugin(self):
        self.assertEqual(old_decode('module:recommendations'),
                         ('module', 'recommendations'))
        self.assertEqual(old_decode('source:builtin-ysp'),
                         ('source', 'builtin-ysp'))

    def test_new_binding_pins_each_native_kind(self):
        for kind, source_id in SOURCE_IDS.items():
            if kind == 'plugin':
                continue
            defaults = FakeDefaults()
            page = ConfigPage(defaults, list(SOURCE_IDS.values()))
            switch = NewSwitch('source', source_id)
            self.assertTrue(page.toggle(switch, True))
            self.assertIn(source_id, pinned_sources(defaults))
            # 重进配置页：开关恢复为开。
            reloaded = ConfigPage(defaults, list(SOURCE_IDS.values()))
            self.assertTrue(reloaded.cell_enabled(source_id))
            # 资源选择器：固定来源排第一。
            self.assertEqual(reloaded.picker_order(
                ['other-source', source_id])[0], source_id)

    def test_new_binding_pins_local_plugin_too(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        self.assertTrue(page.toggle(NewSwitch('source', 'builtin-ysp'), True))
        self.assertIn('builtin-ysp', pinned_sources(defaults))

    def test_unpin_removes_and_survives_reload(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        page.toggle(NewSwitch('source', SOURCE_IDS['tvbox']), True)
        page.toggle(NewSwitch('source', SOURCE_IDS['tvbox']), False)
        self.assertNotIn(SOURCE_IDS['tvbox'], pinned_sources(defaults))
        reloaded = ConfigPage(defaults, list(SOURCE_IDS.values()))
        self.assertFalse(reloaded.cell_enabled(SOURCE_IDS['tvbox']))
        # 取消后不再优先：两项都未固定，顺序保持原样。
        self.assertEqual(reloaded.picker_order(
            ['other-source', SOURCE_IDS['tvbox']]),
            ['other-source', SOURCE_IDS['tvbox']])

    def test_pinning_one_source_does_not_touch_others(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        page.toggle(NewSwitch('source', SOURCE_IDS['maccms']), True)
        page.toggle(NewSwitch('source', SOURCE_IDS['jar']), True)
        self.assertEqual(pinned_sources(defaults),
                         {SOURCE_IDS['maccms'], SOURCE_IDS['jar']})
        page.toggle(NewSwitch('source', SOURCE_IDS['maccms']), False)
        self.assertEqual(pinned_sources(defaults), {SOURCE_IDS['jar']})

    def test_module_toggle_still_works(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        self.assertTrue(page.toggle(NewSwitch('module', 'catalog'), True))
        self.assertIn('catalog', page.modules)
        self.assertEqual(pinned_sources(defaults), set())

    def test_preexisting_pinned_entry_needs_no_migration(self):
        # 旧版本已写进去的本地插件固定项（同 key、同值格式）照常用。
        defaults = FakeDefaults()
        defaults.set_array(PINNED_KEY, ['builtin-ysp'])
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        self.assertTrue(page.cell_enabled('builtin-ysp'))
        page.toggle(NewSwitch('source', SOURCE_IDS['douban']), True)
        self.assertEqual(pinned_sources(defaults),
                         {'builtin-ysp', SOURCE_IDS['douban']})

    def test_unknown_sender_writes_nothing(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        plain = OldSwitch('source', SOURCE_IDS['tvbox'])
        self.assertFalse(page.toggle(plain, True))
        self.assertEqual(pinned_sources(defaults), set())

    def test_empty_identifier_writes_nothing(self):
        defaults = FakeDefaults()
        page = ConfigPage(defaults, list(SOURCE_IDS.values()))
        self.assertFalse(page.toggle(NewSwitch('source', ''), True))
        self.assertEqual(pinned_sources(defaults), set())


class SourcePinContractTests(unittest.TestCase):
    def _read(self, name):
        return (SOURCES / name).read_text(encoding='utf-8')

    def test_setting_switch_structured_binding_declared(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('@interface MediaHomeSettingSwitch : UISwitch', text)
        self.assertIn('@property(nonatomic,copy) NSString *settingKind;', text)
        self.assertIn('@property(nonatomic,copy) NSString *settingIdentifier;', text)
        self.assertIn('@implementation MediaHomeSettingSwitch', text)

    def test_cell_binds_kind_and_identifier(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('MediaHomeSettingSwitch *toggle=[MediaHomeSettingSwitch new];', text)
        self.assertIn('toggle.settingKind=indexPath.section==0?@"module":@"source";', text)
        self.assertIn('toggle.settingIdentifier=identifier;', text)

    def test_toggle_reads_binding_not_colon_split(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('setting.settingKind', text)
        self.assertIn('setting.settingIdentifier', text)
        self.assertIn('isKindOfClass:MediaHomeSettingSwitch.class', text)
        # 固定开关不再按冒号拆分 accessibilityIdentifier。
        config = text[text.index('@implementation MediaHomeConfigurationViewController'):
                      text.index('@end', text.index('@implementation MediaHomeConfigurationViewController'))]
        self.assertNotIn('componentsSeparatedByString:@":"', config)
        self.assertNotIn('parts.count!=2', config)

    def test_preference_key_and_value_format_unchanged(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('static NSString * const MediaHomePinnedSourcesDefaultsKey = @"cctv.mediaHome.pinnedSources.v1";', text)
        self.assertIn('setObject:[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:key];', text)

    def test_accessibility_identifier_kept_as_ui_hook(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('toggle.accessibilityIdentifier=[NSString stringWithFormat:@"%@:%@",indexPath.section==0?@"module":@"source",identifier];', text)

    def test_read_paths_compare_full_source_id(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('enabled=[self.pinnedSources containsObject:identifier];', text)
        self.assertIn('[MediaHomePinnedSources() containsObject:a[@"source"][@"id"]?:@""]', text)


if __name__ == '__main__':
    unittest.main()
