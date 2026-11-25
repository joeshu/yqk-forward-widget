"""阶段 B-route-episode-panel 源码契约：播放页线路面板纯呈现职责拆分。

从 MediaPlaybackViewController 中抽出一个低耦合、边界明确的纯呈现职责——
线路面板（横向滚动 UIScrollView + UIStackView 按钮栈 + 每条线路按钮的样式 /
accessibilityIdentifier / accessibilityLabel / accessibilityHint /
accessibilityTraits 构造）——迁入独立 UIView 模块 MediaPlaybackRoutePanelView。

约束（由测试守护）：
  - 不触碰路由回退、HostPlaybackSession、播放器状态机；
  - 保持 Accessibility IDs / menu IDs 不变（accessibilityIdentifier 逐字一致，
    UISmoke KVC `valueForKey:@"lineButtons"` 兼容别名保留）；
  - 行为等价：buildLines 成为门面，逐字转发到面板，所有既有调用点签名不变。

本套件为定向契约测试，不构建、不跑 CI、不联网。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def method_body(source, signature):
    start = source.rindex(signature)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f'unterminated method: {signature}')


class RouteEpisodePanelSplitContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vc_m = read('MediaPlaybackViewController.m')
        cls.vc_h = read('MediaPlaybackViewController.h')
        cls.panel_h = read('MediaPlaybackRoutePanelView.h')
        cls.panel_m = read('MediaPlaybackRoutePanelView.m')

    # ---- 新增模块存在 ----
    def test_panel_header_and_impl_exist(self):
        self.assertIn('@interface MediaPlaybackRoutePanelView : UIView', self.panel_h)
        self.assertIn('@implementation MediaPlaybackRoutePanelView', self.panel_m)

    def test_header_exports_rebuild_api(self):
        self.assertIn(
            '- (void)rebuildWithLines:(NSArray *)lines\n'
            '            selectedIndex:(NSInteger)selectedIndex\n',
            self.panel_h,
        )

    def test_header_exposes_linebuttons_readonly(self):
        # UISmoke 经 KVC 取 lineButtons，面板须以 readonly 暴露。
        self.assertIn('@property(nonatomic,strong,readonly) UIStackView *lineButtons;', self.panel_h)

    def test_header_uses_nullability_macros(self):
        self.assertIn('NS_ASSUME_NONNULL_BEGIN', self.panel_h)
        self.assertIn('NS_ASSUME_NONNULL_END', self.panel_h)

    def test_header_imports_host_theme(self):
        # HostStylePillButton 来自 HostTheme.h。
        self.assertIn('#import "HostTheme.h"', self.panel_h)

    # ---- 行为等价：按钮构造逐字迁移 ----
    def test_impl_rebuild_preserves_button_construction(self):
        body = method_body(self.panel_m, '- (void)rebuildWithLines:')
        # 逐字迁移自 VC.buildLines：标题缺省、13pt Medium、HostStylePillButton、
        # scaledPillFont、tag、a11y 四件套。
        self.assertIn('[NSString stringWithFormat:@"线路 %lu"', body)
        self.assertIn('systemFontOfSize:13 weight:UIFontWeightMedium', body)
        self.assertIn('HostStylePillButton(button,idx==selectedIndex)', body)
        self.assertIn('MediaPlaybackApplyScaledPillFont(button);', body)
        self.assertIn('button.tag=idx;', body)

    def test_impl_rebuild_preserves_accessibility_identifiers(self):
        body = method_body(self.panel_m, '- (void)rebuildWithLines:')
        self.assertIn(
            'button.accessibilityIdentifier=[NSString stringWithFormat:@"media-playback-line-%lu"',
            body,
        )
        self.assertIn('button.accessibilityHint=@"切换到此播放线路并重新加载分集"', body)
        self.assertIn('UIAccessibilityTraitButton|(idx==selectedIndex?', body)

    def test_impl_rebuild_preserves_label_format(self):
        body = method_body(self.panel_m, '- (void)rebuildWithLines:')
        self.assertIn(
            'button.accessibilityLabel=[NSString stringWithFormat:@"线路 %@"',
            body,
        )

    def test_impl_rebuild_target_action_forwarded(self):
        body = method_body(self.panel_m, '- (void)rebuildWithLines:')
        # 点按事件以 target/action 转发给控制器，不在面板内持有路由逻辑。
        self.assertIn('[button addTarget:target action:action', body)

    def test_impl_rebuild_clears_existing_buttons_first(self):
        body = method_body(self.panel_m, '- (void)rebuildWithLines:')
        self.assertIn('self.lineButtons.arrangedSubviews.copy', body)
        self.assertIn('removeArrangedSubview:view', body)

    def test_impl_owns_internal_constraints(self):
        # 面板自持 lineScroll ↔ lineButtons 内部五条约束，控制器不再手写。
        body = method_body(self.panel_m, '- (instancetype)initWithFrame:')
        self.assertIn('lineScroll.contentLayoutGuide.leadingAnchor', body)
        self.assertIn('lineButtons.heightAnchor constraintEqualToAnchor:_lineScroll.frameLayoutGuide.heightAnchor', body)

    # ---- VC 迁出：buildLines 成门面 ----
    def test_vc_imports_panel_header(self):
        self.assertIn('#import "MediaPlaybackRoutePanelView.h"', self.vc_m)

    def test_vc_buildlines_is_facade(self):
        body = method_body(self.vc_m, '- (void)buildLines {')
        self.assertIn('rebuildWithLines:self.lines selectedIndex:self.lineIndex', body)
        self.assertIn('@selector(selectLine:)', body)
        # 不再在 VC 内直接构造UIButton
        self.assertNotIn('[UIButton buttonWithType:UIButtonTypeSystem]', body)

    def test_vc_no_longer_directly_owns_linescroll(self):
        # lineScroll 属性已移除；lineButtons 保留为 KVC 兼容别名。
        self.assertNotIn('@property(nonatomic,strong) UIScrollView *lineScroll;', self.vc_m)
        self.assertIn('@property(nonatomic,strong) MediaPlaybackRoutePanelView *routePanel;', self.vc_m)

    def test_vc_linebuttons_alias_points_to_panel(self):
        # UISmoke KVC `valueForKey:@"lineButtons"` 仍可取到按钮栈。
        self.assertIn('self.lineButtons=self.routePanel.lineButtons;', self.vc_m)

    def test_vc_external_constraints_reference_routepanel(self):
        # 外部约束（portrait + embedded）引用 routePanel，不再引用 lineScroll。
        self.assertNotIn('self.lineScroll.topAnchor', self.vc_m)
        self.assertIn('self.routePanel.topAnchor', self.vc_m)
        self.assertIn('self.routePanel.heightAnchor constraintEqualToConstant:44', self.vc_m)

    def test_vc_embedded_hides_routepanel(self):
        self.assertNotIn('self.lineScroll.hidden=YES', self.vc_m)
        self.assertIn('self.routePanel.hidden=YES', self.vc_m)

    def test_vc_selectline_unchanged_in_vc(self):
        # selectLine 路由回退逻辑保留在控制器，不在面板内。
        body = method_body(self.vc_m, '- (void)selectLine:(UIButton *)sender {')
        self.assertIn('sender.tag<0||sender.tag>=self.lines.count', body)

    # ---- 边界：不触碰路由 / 会话 / 状态机 ----
    def test_panel_does_not_touch_route_or_session_layers(self):
        self.assertNotIn('MediaPlaybackDecodeRouter', self.panel_m)
        self.assertNotIn('HostPlaybackSession', self.panel_m)
        self.assertNotIn('attemptedRoutes', self.panel_m)
        self.assertNotIn('selectLine', self.panel_m)
        self.assertNotIn('resolveAndPlay', self.panel_m)
        self.assertNotIn('resetAutomaticFallbackLines', self.panel_m)

    def test_panel_has_no_player_or_web_dependencies(self):
        self.assertNotIn('AVPlayer', self.panel_h)
        self.assertNotIn('AVPlayer', self.panel_m)
        self.assertNotIn('AVKit', self.panel_h)
        self.assertNotIn('WKWebView', self.panel_m)
        self.assertNotIn('MediaAPIClient', self.panel_m)

    def test_panel_does_not_reference_lines_property(self):
        # 面板不持有线路数据模型（不定义 lines 属性），列表由调用方以值传入。
        self.assertNotIn('@property', self.panel_h.replace('@property(nonatomic,strong,readonly) UIScrollView *lineScroll;', '').replace('@property(nonatomic,strong,readonly) UIStackView *lineButtons;', ''))

    # ---- 括号平衡 ----
    def test_panel_impl_balanced_delimiters(self):
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', self.panel_m, flags=re.S)
        code = re.sub(r'@"(?:\\.|[^"\\])*"', '""', code)
        self.assertEqual(code.count('{'), code.count('}'), 'panel impl braces 不平衡')
        self.assertEqual(code.count('('), code.count(')'), 'panel impl parens 不平衡')

    def test_vc_line_count_decreased(self):
        # 迁出 buildLines 内部 + lineScroll 创建 + 10 条约束后 VC 应缩减。
        n = len(self.vc_m.splitlines())
        self.assertLess(n, 2909, 'VC 未因迁出而缩减（%d 行）' % n)
        self.assertGreater(n, 2800, 'VC 不应被过度削减（%d 行）' % n)


if __name__ == '__main__':
    unittest.main()
