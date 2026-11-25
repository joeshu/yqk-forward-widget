"""阶段 B-quality-panel 源码契约：播放页画质面板纯呈现职责拆分。

从 MediaPlaybackViewController 中抽出一个低耦合、边界明确的纯呈现职责——
画质面板（纵向 qualityGroup UIStackView + qualityLabel 标题 + 横向
qualityScroll 滚动容器 + qualityButtons 按钮栈，连同 44pt 高度与五条内部
锚约束，以及 buildQualityButtons 的「按 alternates 计数折叠标题/滚动条」与
「逐档按钮样式 / accessibilityIdentifier / accessibilityLabel /
accessibilityHint / 选中态 / 按压反馈 / 动态字体缩放」构造）——迁入独立 UIView
模块 MediaPlaybackQualityPanelView。

约束（由测试守护）：
  - 不触碰路由回退、HostPlaybackSession、播放器状态机、请求层
    （selectAlternate: / resolveAndPlay / playResult: / basePlaybackHeaders /
     selectedAlternateIndex 解析均保留在控制器）；
  - 保持 Accessibility IDs 不变（accessibilityIdentifier=media-quality-%lu
    逐字一致，UISmoke KVC `valueForKey:@"qualityButtons"` 兼容别名保留）；
  - 行为等价：buildQualityButtons 成为门面，转发到面板，调用点签名不变。

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


class QualityPanelSplitContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vc_m = read('MediaPlaybackViewController.m')
        cls.panel_h = read('MediaPlaybackQualityPanelView.h')
        cls.panel_m = read('MediaPlaybackQualityPanelView.m')

    # ---- 新增模块存在 ----
    def test_panel_header_and_impl_exist(self):
        self.assertIn('@interface MediaPlaybackQualityPanelView : UIView', self.panel_h)
        self.assertIn('@implementation MediaPlaybackQualityPanelView', self.panel_m)

    def test_header_exports_rebuild_api(self):
        self.assertIn(
            '- (void)rebuildWithAlternates:(NSArray *)alternates\n'
            '                 selectedIndex:(NSInteger)selectedIndex\n',
            self.panel_h,
        )

    def test_header_exposes_subviews_readonly(self):
        # UISmoke 经 KVC 取 qualityButtons，面板须以 readonly 暴露四件套。
        self.assertIn('@property(nonatomic,strong,readonly) UIStackView *qualityGroup;', self.panel_h)
        self.assertIn('@property(nonatomic,strong,readonly) UILabel *qualityLabel;', self.panel_h)
        self.assertIn('@property(nonatomic,strong,readonly) UIScrollView *qualityScroll;', self.panel_h)
        self.assertIn('@property(nonatomic,strong,readonly) UIStackView *qualityButtons;', self.panel_h)

    def test_header_uses_nullability_macros(self):
        self.assertIn('NS_ASSUME_NONNULL_BEGIN', self.panel_h)
        self.assertIn('NS_ASSUME_NONNULL_END', self.panel_h)

    def test_header_imports_host_theme(self):
        # HostStylePillButton / HostInstallPressFeedback / HostText /
        # HostSecondaryText 均来自 HostTheme.h。
        self.assertIn('#import "HostTheme.h"', self.panel_h)

    # ---- 行为等价：按钮构造逐字迁移 ----
    def test_impl_rebuild_preserves_button_construction(self):
        body = method_body(self.panel_m, '- (void)rebuildWithAlternates:')
        # 逐字迁移自 VC.buildQualityButtons：标题缺省、13pt Medium、
        # HostStylePillButton 选中态、scaledPillFont、按压反馈、tag、单档禁用。
        self.assertIn('[NSString stringWithFormat:@"清晰度 %lu"', body)
        self.assertIn('systemFontOfSize:13 weight:UIFontWeightMedium', body)
        self.assertIn('HostStylePillButton(button,(NSInteger)index==selectedIndex)', body)
        self.assertIn('HostInstallPressFeedback(button);', body)
        self.assertIn('MediaPlaybackApplyScaledPillFont(button);', body)
        self.assertIn('button.tag=index;', body)
        self.assertIn('button.enabled=alternates.count>1;', body)
        self.assertIn('[button setTitleColor:HostText() forState:UIControlStateDisabled]', body)

    def test_impl_rebuild_preserves_accessibility_identifiers(self):
        body = method_body(self.panel_m, '- (void)rebuildWithAlternates:')
        self.assertIn(
            'button.accessibilityIdentifier=[NSString stringWithFormat:@"media-quality-%lu"',
            body,
        )
        self.assertIn('button.accessibilityLabel=name;', body)
        self.assertIn('button.accessibilityHint=alternates.count==1?', body)

    def test_impl_rebuild_preserves_available_folding(self):
        body = method_body(self.panel_m, '- (void)rebuildWithAlternates:')
        # 无档时折叠：spacing=0、标题/滚动条隐藏；单档标题文案分支保留。
        self.assertIn('self.qualityGroup.spacing=available?3:0', body)
        self.assertIn('self.qualityLabel.hidden=!available', body)
        self.assertIn('self.qualityScroll.hidden=!available', body)
        self.assertIn('@"清晰度（仅此档可用）"', body)

    def test_impl_rebuild_target_action_forwarded(self):
        body = method_body(self.panel_m, '- (void)rebuildWithAlternates:')
        # 点按事件以 target/action 转发给控制器，不在面板内持有请求逻辑。
        self.assertIn('[button addTarget:target action:action', body)

    def test_impl_rebuild_clears_existing_buttons_first(self):
        body = method_body(self.panel_m, '- (void)rebuildWithAlternates:')
        self.assertIn('self.qualityButtons.arrangedSubviews.copy', body)
        self.assertIn('removeArrangedSubview:view', body)

    def test_impl_owns_internal_constraints(self):
        # 面板自持 qualityGroup 四边 + qualityScroll 44pt 高 + qualityButtons
        # 五条内部约束，控制器不再手写。
        body = method_body(self.panel_m, '- (instancetype)initWithFrame:')
        self.assertIn('qualityScrollHeight.priority=UILayoutPriorityDefaultHigh;', body)
        self.assertIn('[self.qualityScroll.heightAnchor constraintEqualToConstant:44]', body)
        self.assertIn('self.qualityScroll.contentLayoutGuide.leadingAnchor', body)
        self.assertIn('self.qualityButtons.heightAnchor constraintEqualToAnchor:self.qualityScroll.frameLayoutGuide.heightAnchor', body)
        self.assertIn('[self.qualityGroup.topAnchor constraintEqualToAnchor:self.topAnchor]', body)

    # ---- VC 迁出：buildQualityButtons 成门面 ----
    def test_vc_imports_panel_header(self):
        self.assertIn('#import "MediaPlaybackQualityPanelView.h"', self.vc_m)

    def test_vc_buildqualitybuttons_is_facade(self):
        body = method_body(self.vc_m, '- (void)buildQualityButtons {')
        self.assertIn('rebuildWithAlternates:alternates selectedIndex:self.selectedAlternateIndex', body)
        self.assertIn('@selector(selectAlternate:)', body)
        # 不再在 VC 内直接构造画质按钮。
        self.assertNotIn('[UIButton buttonWithType:UIButtonTypeSystem]', body)
        # selectedAlternateIndex 解析（按 originalURL 匹配）仍留在控制器。
        self.assertIn('if([original isEqual:currentURL])', body)

    def test_vc_retains_alias_properties_and_points_to_panel(self):
        # UISmoke KVC `valueForKey:@"qualityButtons"` 仍可取到按钮栈；
        # 外部约束仍经 qualityGroup 别名参与几何。
        self.assertIn('@property(nonatomic,strong) MediaPlaybackQualityPanelView *qualityPanel;', self.vc_m)
        self.assertIn('@property(nonatomic,strong) UIStackView *qualityGroup;', self.vc_m)
        self.assertIn('@property(nonatomic,strong) UIStackView *qualityButtons;', self.vc_m)
        self.assertIn('self.qualityGroup=self.qualityPanel.qualityGroup;', self.vc_m)
        self.assertIn('self.qualityButtons=self.qualityPanel.qualityButtons;', self.vc_m)
        self.assertIn('self.qualityScroll=self.qualityPanel.qualityScroll;', self.vc_m)
        self.assertIn('self.qualityLabel=self.qualityPanel.qualityLabel;', self.vc_m)

    def test_vc_external_constraints_still_reference_qualitygroup(self):
        # 外部几何约束（含嵌入态 constant:11）仍引用 qualityGroup 别名，
        # 不因迁出而改动。
        self.assertIn('self.routePanel.bottomAnchor', self.vc_m)
        self.assertIn('[self.qualityGroup.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:11]', self.vc_m)

    def test_vc_selectalternate_unchanged_in_vc(self):
        # selectAlternate 请求/状态机/headers/播放逻辑保留在控制器，不在面板。
        body = method_body(self.vc_m, '- (void)selectAlternate:(UIButton *)sender {')
        self.assertIn('sender.tag<0||sender.tag>=(NSInteger)alternates.count', body)
        self.assertIn('self.pendingQualityRestorePlaybackState=YES', body)
        self.assertIn('[self playResult:selected]', body)

    def test_vc_no_longer_hand_builds_quality_subviews(self):
        # 控制器不再直接 new qualityGroup/Label/Scroll/Buttons，也不再手写
        # qualityScrollHeight 内部约束。
        setup = method_body(self.vc_m, '- (void)buildPlaybackControls {') \
            if '- (void)buildPlaybackControls {' in self.vc_m else self.vc_m
        self.assertNotIn('self.qualityGroup=[UIStackView new]', setup)
        self.assertNotIn('self.qualityScroll=[UIScrollView new]', setup)
        self.assertNotIn('NSLayoutConstraint *qualityScrollHeight=', setup)

    # ---- 边界：不触碰路由 / 会话 / 状态机 / 请求 ----
    def test_panel_does_not_touch_route_or_session_or_request_layers(self):
        self.assertNotIn('MediaPlaybackDecodeRouter', self.panel_m)
        self.assertNotIn('HostPlaybackSession', self.panel_m)
        self.assertNotIn('attemptedRoutes', self.panel_m)
        self.assertNotIn('selectAlternate', self.panel_m)
        self.assertNotIn('resolveAndPlay', self.panel_m)
        self.assertNotIn('playResult', self.panel_m)
        self.assertNotIn('basePlaybackHeaders', self.panel_m)
        self.assertNotIn('pendingQuality', self.panel_m)
        self.assertNotIn('selectedAlternateIndex', self.panel_m)
        self.assertNotIn('self.result', self.panel_m)

    def test_panel_has_no_player_or_web_dependencies(self):
        self.assertNotIn('AVPlayer', self.panel_h)
        self.assertNotIn('AVPlayer', self.panel_m)
        self.assertNotIn('AVKit', self.panel_h)
        self.assertNotIn('WKWebView', self.panel_m)
        self.assertNotIn('MediaAPIClient', self.panel_m)
        self.assertNotIn('RuntimeDiagnostics', self.panel_m)

    def test_panel_does_not_own_alternates_model(self):
        # 面板不持有 alternates 数据模型（不定义 alternates/result 属性），
        # 列表与选中下标均由调用方以值传入。
        self.assertNotIn('@property', self.panel_h.replace('@property(nonatomic,strong,readonly) UIStackView *qualityGroup;', '').replace('@property(nonatomic,strong,readonly) UILabel *qualityLabel;', '').replace('@property(nonatomic,strong,readonly) UIScrollView *qualityScroll;', '').replace('@property(nonatomic,strong,readonly) UIStackView *qualityButtons;', ''))

    # ---- 括号平衡 ----
    def test_panel_impl_balanced_delimiters(self):
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', self.panel_m, flags=re.S)
        code = re.sub(r'@"(?:\\.|[^"\\])*"', '""', code)
        self.assertEqual(code.count('{'), code.count('}'), 'panel impl braces 不平衡')
        self.assertEqual(code.count('('), code.count(')'), 'panel impl parens 不平衡')

    def test_vc_line_count_decreased(self):
        # 迁出 buildQualityButtons 按钮构造 + 四件套创建 + 内部约束后 VC 应缩减。
        n = len(self.vc_m.splitlines())
        self.assertLess(n, 2899, 'VC 未因迁出而缩减（%d 行）' % n)
        self.assertGreater(n, 2820, 'VC 不应被过度削减（%d 行）' % n)


if __name__ == '__main__':
    unittest.main()
