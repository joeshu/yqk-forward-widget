"""阶段 C UI 审计：HostEmptyStateView 统一空态 helper 契约测试。

这是一组源码契约测试（与 test_p3_accessibility_contracts / test_root_view_controller_contracts
风格一致），不编译 ObjC，仅断言 helper 源码中关键约定存在，防止后续重构静默丢掉
动态字体、VoiceOver 合并朗读或主题跟随等行为。

被测文件：
  Sources/HostEmptyStateView.h
  Sources/HostEmptyStateView.m
"""
import pathlib
import unittest

SOURCES = pathlib.Path(__file__).resolve().parents[1] / "Sources"
H_TEXT = (SOURCES / "HostEmptyStateView.h").read_text(encoding="utf-8")
M_TEXT = (SOURCES / "HostEmptyStateView.m").read_text(encoding="utf-8")


class HostEmptyStateViewApiContracts(unittest.TestCase):
    """公开 API 表面与可发现性约定。"""

    def test_header_declares_class_and_factories(self):
        self.assertIn("@interface HostEmptyStateView : UIView", H_TEXT)
        # 两个便捷工厂 + 占位标签工厂都必须导出，便于各空态站点迁移。
        self.assertIn(
            "+ (instancetype)emptyStateViewWithTitle:(nullable NSString *)title",
            H_TEXT,
        )
        self.assertIn(
            "+ (UILabel *)placeholderLabelWithText:(NSString *)text;",
            H_TEXT,
        )
        # 动作回调与无障碍标识属性必须公开，供调用方注入行动入口。
        self.assertIn("@property (nonatomic, copy, nullable) void (^onAction)(void);", H_TEXT)
        self.assertIn(
            "@property (nonatomic, copy, nullable) NSString *accessibilityIdentifier;",
            H_TEXT,
        )
        # 必须暴露主题刷新入口，与 RootVC 各页 reloadThemeAppearance 对齐。
        self.assertIn("- (void)reloadThemeAppearance;", H_TEXT)

    def test_implementation_conforms_to_host_theme_palette(self):
        # 颜色必须走动态颜色提供者，而非固定色值，保证深浅主题一致。
        self.assertIn("HostSecondaryText()", M_TEXT)
        self.assertIn("HostText()", M_TEXT)
        self.assertIn("HostRaisedSurface()", M_TEXT)
        self.assertIn("HostBorder()", M_TEXT)
        self.assertIn("HostSelectedInterfaceStyle()", M_TEXT)
        self.assertIn("HostSetLayerBorderColor(_actionButton, HostBorder())", M_TEXT)


class HostEmptyStateViewDynamicTypeContracts(unittest.TestCase):
    """动态字体 / 大字号风险防护。"""

    def test_all_text_uses_preferred_font_with_content_size_category(self):
        # 标题、副标题、动作按钮、占位标签 四处文字都必须缩放。
        self.assertIn("preferredFontForTextStyle:UIFontTextStyleHeadline", M_TEXT)
        self.assertIn("preferredFontForTextStyle:UIFontTextStyleSubheadline", M_TEXT)
        self.assertIn("preferredFontForTextStyle:UIFontTextStyleBody", M_TEXT)
        # 每个 adaptive label/button.titleLabel 上必须开启 adjustsFontForContentSizeCategory。
        self.assertGreaterEqual(
            M_TEXT.count("adjustsFontForContentSizeCategory = YES"), 3
        )
        # placeholderLabel 工厂同样必须开启动态字体。
        placeholder_body = self._method_body(
            "+ (UILabel *)placeholderLabelWithText:"
        )
        self.assertIn("adjustsFontForContentSizeCategory = YES", placeholder_body)
        self.assertIn("numberOfLines = 0", placeholder_body)

    def test_trait_collection_change_handles_font_and_appearance(self):
        body = self._method_body("- (void)traitCollectionDidChange:")
        # 深浅主题变化与字号档位变化都应被响应。
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection", body)
        self.assertIn("preferredContentSizeCategory", body)

    def _method_body(self, signature):
        # 跳过类扩展里的前向声明（"- (void)foo;"），找到以 "{" 开头的实现。
        start = 0
        while True:
            start = M_TEXT.index(signature, start)
            tail = M_TEXT[start + len(signature):]
            semi = tail.index(";") if ";" in tail else len(tail)
            brace = tail.index("{") if "{" in tail else len(tail)
            if brace < semi:
                break  # 实现在前，命中。
            start += len(signature)  # 当前进度是声明，继续找下一个。
        opening = M_TEXT.index("{", start)
        depth = 0
        for i in range(opening, len(M_TEXT)):
            if M_TEXT[i] == "{":
                depth += 1
            elif M_TEXT[i] == "}":
                depth -= 1
                if depth == 0:
                    return M_TEXT[opening + 1 : i]
        raise AssertionError("unterminated method: " + signature)


class HostEmptyStateViewAccessibilityContracts(unittest.TestCase):
    """VoiceOver 合并朗读与可操作性约定，对应审计中各空态标签 a11y 不一致问题。"""

    def test_view_is_single_accessibility_element_with_merged_label(self):
        self.assertIn("self.isAccessibilityElement = YES", M_TEXT)
        # 标题与副标题应合并为一句 accessibilityLabel。
        self.assertIn("componentsJoinedByString:", M_TEXT)

    def test_traits_switch_between_static_text_and_button(self):
        # 无动作按钮时为静态文本；有动作按钮时为按钮，避免 VoiceOver 误读为纯文字。
        self.assertIn("UIAccessibilityTraitStaticText", M_TEXT)
        self.assertIn("UIAccessibilityTraitButton", M_TEXT)
        self.assertIn("_actionButton.hidden", M_TEXT)

    def test_placeholder_label_is_accessible_static_text(self):
        body = self._method_body("+ (UILabel *)placeholderLabelWithText:")
        self.assertIn("isAccessibilityElement = YES", body)
        self.assertIn("accessibilityLabel = text", body)
        self.assertIn("UIAccessibilityTraitStaticText", body)

    def test_child_elements_excluded_from_individual_announcement(self):
        body = self._method_body("- (void)_updateAccessibility")
        # 图标、标题、副标题、按钮都不单独朗读，由容器合并。
        self.assertIn("_symbolView.isAccessibilityElement = NO", body)
        self.assertIn("_titleLabel.isAccessibilityElement = NO", body)
        self.assertIn("_subtitleLabel.isAccessibilityElement = NO", body)
        self.assertIn("_actionButton.isAccessibilityElement = NO", body)

    def _method_body(self, signature):
        # 跳过类扩展里的前向声明（"- (void)foo;"），找到以 "{" 开头的实现。
        start = 0
        while True:
            start = M_TEXT.index(signature, start)
            tail = M_TEXT[start + len(signature):]
            semi = tail.index(";") if ";" in tail else len(tail)
            brace = tail.index("{") if "{" in tail else len(tail)
            if brace < semi:
                break  # 实现在前，命中。
            start += len(signature)  # 当前进度是声明，继续找下一个。
        opening = M_TEXT.index("{", start)
        depth = 0
        for i in range(opening, len(M_TEXT)):
            if M_TEXT[i] == "{":
                depth += 1
            elif M_TEXT[i] == "}":
                depth -= 1
                if depth == 0:
                    return M_TEXT[opening + 1 : i]
        raise AssertionError("unterminated method: " + signature)


class HostEmptyStateViewLayoutContracts(unittest.TestCase):
    """布局安全：居中、宽度受控、Autoresizing 友好，适配 iPhone 与 iPad 宽屏。"""

    def test_stack_centered_with_horizontal_insets(self):
        # 必须 居中并保留水平内边距，避免 iPad 宽屏下空态文字拉满整行。
        self.assertIn("centerXAnchor constraintEqualToAnchor:self.centerXAnchor", M_TEXT)
        self.assertIn("centerYAnchor constraintEqualToAnchor:self.centerYAnchor", M_TEXT)
        self.assertIn("leadingAnchor constraintGreaterThanOrEqualToAnchor", M_TEXT)
        self.assertIn("trailingAnchor constraintLessThanOrEqualToAnchor", M_TEXT)
        self.assertIn("kHostEmptyHorizontalInset", M_TEXT)

    def test_factories_do_not_force_frame_sizing(self):
        # 四参工厂是真正构造入口：使用 [self new]（zero frame），交由 Auto Layout
        # 在 superview 中布局，与 tableView.backgroundView 的自动 resize 行为兼容。
        # 定位含 actionTitle 的四参实现方法体。
        sig = "+ (instancetype)emptyStateViewWithTitle:"
        # 跳过返回 actionTitle:nil 的两参转发实现，找到带四参签名的实现。
        idx = M_TEXT.index("actionTitle:(NSString *)actionTitle {")
        start = M_TEXT.rindex(sig, 0, idx)
        opening = M_TEXT.index("{", idx)
        depth = 0
        body = ""
        for i in range(opening, len(M_TEXT)):
            if M_TEXT[i] == "{":
                depth += 1
            elif M_TEXT[i] == "}":
                depth -= 1
                if depth == 0:
                    body = M_TEXT[opening + 1 : i]
                    break
        self.assertIn("[self new]", body)

    def _method_body(self, signature):
        # 跳过类扩展里的前向声明（"- (void)foo;"），找到以 "{" 开头的实现。
        start = 0
        while True:
            start = M_TEXT.index(signature, start)
            tail = M_TEXT[start + len(signature):]
            semi = tail.index(";") if ";" in tail else len(tail)
            brace = tail.index("{") if "{" in tail else len(tail)
            if brace < semi:
                break  # 实现在前，命中。
            start += len(signature)  # 当前进度是声明，继续找下一个。
        opening = M_TEXT.index("{", start)
        depth = 0
        for i in range(opening, len(M_TEXT)):
            if M_TEXT[i] == "{":
                depth += 1
            elif M_TEXT[i] == "}":
                depth -= 1
                if depth == 0:
                    return M_TEXT[opening + 1 : i]
        raise AssertionError("unterminated method: " + signature)


if __name__ == "__main__":
    unittest.main()
