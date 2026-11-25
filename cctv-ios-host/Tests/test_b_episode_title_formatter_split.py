"""阶段 B-P2 源码契约：点播分集标题格式化职责拆分。

继 MediaPlaybackSettingsCoordinator（设置菜单协调器）拆出后，继续从
MediaPlaybackViewController 中抽出一个低风险、边界明确的剩余职责——
分集编号/名称解析与匹配（原先为文件内 static 函数，仅服务于分集标题 UI）——
迁入独立模块 MediaPlaybackEpisodeFormatter。

约束：
  - 不触碰已抽出的 MediaPlaybackSettingsCoordinator；
  - 不触碰播放路由层（MediaPlaybackDecodeRouter）与状态机（HostPlaybackSession）；
  - 保持分集菜单 identifier 与 accessibilityIdentifier 不变；
  - 行为等价：两个 helper 逐字迁移，VC 仍在原调用点以相同签名调用，
    故既有契约 test_ui_2026_deep_refinements.test_ref15 中
    `!MediaPlaybackEpisodeNamesMatch(name,number)` 断言继续成立。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


class EpisodeTitleFormatterSplitContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vc_m = read('MediaPlaybackViewController.m')
        cls.fmt_h = read('MediaPlaybackEpisodeFormatter.h')
        cls.fmt_m = read('MediaPlaybackEpisodeFormatter.m')

    # ---- 新增模块存在 ----
    def test_formatter_header_and_impl_exist(self):
        # 纯函数模块：头文件无 @interface 类声明，仅导出两个符号。
        self.assertIn('FOUNDATION_EXPORT NSString *MediaPlaybackEpisodeNumber(NSString *value);', self.fmt_h)
        self.assertIn('FOUNDATION_EXPORT BOOL MediaPlaybackEpisodeNamesMatch(NSString *left, NSString *right);', self.fmt_h)

    def test_header_exports_both_helpers(self):
        self.assertIn('FOUNDATION_EXPORT NSString *MediaPlaybackEpisodeNumber(NSString *value);', self.fmt_h)
        self.assertIn('FOUNDATION_EXPORT BOOL MediaPlaybackEpisodeNamesMatch(NSString *left, NSString *right);', self.fmt_h)

    def test_header_uses_nullability_macros(self):
        self.assertIn('NS_ASSUME_NONNULL_BEGIN', self.fmt_h)
        self.assertIn('NS_ASSUME_NONNULL_END', self.fmt_h)

    # ---- 行为等价：实现逐字迁移 ----
    def test_impl_defines_helpers_with_original_signatures(self):
        self.assertIn('NSString *MediaPlaybackEpisodeNumber(NSString *value) {', self.fmt_m)
        self.assertIn('BOOL MediaPlaybackEpisodeNamesMatch(NSString *left,NSString *right) {', self.fmt_m)

    def test_impl_preserves_episode_number_regex_patterns(self):
        # 四条解析规则必须保留，保证 SxxEyy / 第N集·话·期 / episode·ep / 纯数字 行为不变。
        for pat in (r'(?i)s\d+\s*e\s*0*(\d{1,4})',
                    r'(?i)(?:第\s*)?0*(\d{1,4})\s*(?:集|话|期)',
                    r'(?i)(?:episode|ep)\s*0*(\d{1,4})',
                    r'^\s*0*(\d{1,4})\s*$'):
            self.assertIn(pat.replace('\\', '\\\\'), self.fmt_m.replace('\\\\', '\\\\'),
                          '分集编号正则丢失: %s' % pat)

    def test_names_match_falls_back_to_parsed_numbers(self):
        self.assertIn('localizedCaseInsensitiveCompare:right]==NSOrderedSame', self.fmt_m)
        self.assertIn('leftNumber.length&&[leftNumber isEqualToString:rightNumber]', self.fmt_m)

    # ---- VC 迁出：不再定义 static，但仍调用 ----
    def test_vc_no_longer_defines_static_helpers(self):
        self.assertNotIn('static NSString *MediaPlaybackEpisodeNumber(NSString *value)', self.vc_m)
        self.assertNotIn('static BOOL MediaPlaybackEpisodeNamesMatch(NSString *left,NSString *right)', self.vc_m)

    def test_vc_imports_formatter_header(self):
        self.assertIn('#import "MediaPlaybackEpisodeFormatter.h"', self.vc_m)

    def test_vc_keeps_call_sites_unchanged(self):
        # 调用点保持不变 → 既有 deep_refinements.test_ref15 断言继续成立，行为等价。
        self.assertIn('MediaPlaybackEpisodeNumber(name)', self.vc_m)
        self.assertIn('!MediaPlaybackEpisodeNamesMatch(name,number)', self.vc_m)

    def test_vc_line_count_decreased(self):
        # 迁出两个 static 函数后 VC 应较基线（2916 行）缩减。
        n = len(self.vc_m.splitlines())
        self.assertLess(n, 2916, 'VC 未因迁出而缩减（%d 行）' % n)
        self.assertGreater(n, 2800, 'VC 不应被过度削减（%d 行）' % n)

    # ---- 边界：不触碰已抽出的协调器 / 路由 / 状态机 ----
    def test_formatter_does_not_touch_settings_coordinator(self):
        self.assertNotIn('MediaPlaybackSettingsCoordinator', self.fmt_m)
        self.assertNotIn('SettingsCoordinator', self.fmt_h)

    def test_formatter_does_not_touch_route_or_session_layers(self):
        self.assertNotIn('MediaPlaybackDecodeRouter', self.fmt_m)
        self.assertNotIn('HostPlaybackSession', self.fmt_m)
        self.assertNotIn('attemptedRoutes', self.fmt_m)
        self.assertNotIn('AttemptedMPV', self.fmt_m)
        self.assertNotIn('AttemptedCicada', self.fmt_m)

    def test_formatter_has_no_ui_or_menu_identifiers(self):
        # 纯解析模块不应携带菜单 identifier 或 accessibilityIdentifier。
        self.assertNotIn('media.playback.menu', self.fmt_m)
        self.assertNotIn('accessibilityIdentifier', self.fmt_m)

    # ---- 括号平衡（新实现） ----
    def test_formatter_impl_balanced_delimiters(self):
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', self.fmt_m, flags=re.S)
        code = re.sub(r'@"(?:\\.|[^"\\])*"', '""', code)
        # 纯正则字面量中的括号在 NSString 内，已被上一行替换；残余括号来自 C 语法。
        self.assertEqual(code.count('{'), code.count('}'), 'formatter 实现 braces 不平衡')
        self.assertEqual(code.count('('), code.count(')'), 'formatter 实现 parens 不平衡')

    def test_formatter_impl_uses_only_foundation(self):
        # 不应引入 UIKit / AVKit / 解码相关依赖，保持纯 Foundation 可单测。
        self.assertNotIn('UIKit', self.fmt_h)
        self.assertNotIn('UIKit', self.fmt_m)
        self.assertNotIn('AVKit', self.fmt_h)


if __name__ == '__main__':
    unittest.main()
