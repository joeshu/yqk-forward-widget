"""Phase-C resource-page accessibility reinforcement contract tests.

These source-pattern tests pin the small, reviewable VoiceOver (accessibility
Label/Hint/Traits/Value) and Dynamic Type guards added to the resource pages
that were NOT already covered by the Phase-3 suite:
  * LogCenterViewController (diagnostic log center)
  * LocalMediaViewController (local media library)
  * ServiceEditorViewController + ServiceCodeViewController (resource editor)

Services/TVBox were migrated in Phase 3 (see test_p3_accessibility_contracts.py)
and are intentionally NOT touched here, so this suite focuses only on the
remaining resource surfaces.

Style follows the other contract suites: each test asserts a small, reviewable
fragment is present in the sources, so a future refactor that drops the guard
will fail loudly. These tests do NOT build — they only guard the source text.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"

LOG_SOURCE = (SOURCES / "LogCenterViewController.m").read_text(encoding="utf-8")
LOCAL_SOURCE = (SOURCES / "LocalMediaViewController.m").read_text(encoding="utf-8")
EDITOR_SOURCE = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")


def method_body(source, signature):
    start = source.rindex(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class LogCenterVoiceOverContracts(unittest.TestCase):
    """日志中心统计筛选条与日志行单元必须可被 VoiceOver 读屏。"""

    def test_stat_chips_carry_label_hint_traits_and_selected_value(self):
        # 统计筛选条同时是按钮，且选中状态需向 VoiceOver 汇报
        body = method_body(LOG_SOURCE, "- (void)updateStatChipsWithTotal:")
        self.assertIn("chip.accessibilityLabel=titles[i];", body)
        self.assertIn(
            "chip.accessibilityTraits=UIAccessibilityTraitButton|(active?"
            "UIAccessibilityTraitSelected:0);",
            body,
        )
        self.assertIn('chip.accessibilityValue=active?@"已选中":@"未选中";', body)

    def test_stat_chips_declare_button_trait_and_hint_at_creation(self):
        self.assertIn(
            "chip.accessibilityTraits=UIAccessibilityTraitButton;"
            'chip.accessibilityHint=@"点按按此类别筛选日志";',
            LOG_SOURCE,
        )

    def test_log_line_cell_is_grouped_with_label_and_button_trait(self):
        # 自定义日志行有多处装饰子视图：收拢为单一可读元素，避免逐子视图读屏
        self.assertIn(
            "cell.isAccessibilityElement=YES;cell.accessibilityLabel=line;"
            'cell.accessibilityTraits=UIAccessibilityTraitButton;'
            'cell.accessibilityHint=@"点按复制这行日志";',
            LOG_SOURCE,
        )

    def test_jump_bottom_button_has_hint(self):
        self.assertIn(
            'self.jumpBottomButton.accessibilityHint=@"滚动到日志列表底部查看最新输出";',
            LOG_SOURCE,
        )


class LogCenterDynamicTypeContracts(unittest.TestCase):
    """日志正文/摘要/空态文案必须随 Dynamic Type 缩放。"""

    def test_log_line_message_scales_with_content_size(self):
        self.assertIn("self.messageLabel.adjustsFontForContentSizeCategory=YES;", LOG_SOURCE)
        self.assertIn("[[UIFontMetrics defaultMetrics] scaledFontForFont:", LOG_SOURCE)

    def test_summary_and_empty_labels_scale_with_content_size(self):
        self.assertIn("self.summaryLabel.adjustsFontForContentSizeCategory=YES;", LOG_SOURCE)
        self.assertIn("self.emptyLabel.adjustsFontForContentSizeCategory=YES;", LOG_SOURCE)


class LocalMediaVoiceOverContracts(unittest.TestCase):
    """本地媒体页导入入口与媒体行必须可被 VoiceOver 读屏。"""

    def test_summary_import_button_has_label_hint_traits(self):
        self.assertIn('btn.accessibilityLabel=@"导入本地媒体";', LOCAL_SOURCE)
        self.assertIn('btn.accessibilityHint=@"选择零拷贝外部挂载或复制到本机沙盒";', LOCAL_SOURCE)
        self.assertIn("btn.accessibilityTraits=UIAccessibilityTraitButton;", LOCAL_SOURCE)

    def test_add_bar_button_has_label_and_hint(self):
        self.assertIn(
            'addItem.accessibilityLabel=@"导入本地媒体";'
            'addItem.accessibilityHint=@"选择并导入视频或音频文件";',
            LOCAL_SOURCE,
        )

    def test_media_row_has_button_trait_and_hint(self):
        self.assertIn(
            "cell.accessibilityTraits=UIAccessibilityTraitButton;"
            'cell.accessibilityHint=@"点按播放 · 长按分享、复制或删除";',
            LOCAL_SOURCE,
        )

    def test_decorative_accent_bar_and_ext_badge_are_hidden_from_voiceover(self):
        # 装饰条与扩展名徽标重复了正文信息，不应再被逐个读出
        self.assertIn("accentBar.accessibilityElementsHidden=YES;", LOCAL_SOURCE)
        self.assertIn("extBadge.accessibilityElementsHidden=YES;", LOCAL_SOURCE)

    def test_stop_button_has_hint(self):
        self.assertIn(
            'self.stopButton.accessibilityHint=@"当前文件完成后结束导入任务";',
            LOCAL_SOURCE,
        )


class LocalMediaDynamicTypeContracts(unittest.TestCase):
    """本地媒体标题/明细/汇总标签必须随 Dynamic Type 缩放。"""

    def test_media_row_text_labels_scale(self):
        body = method_body(LOCAL_SOURCE, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {")
        self.assertIn("cell.textLabel.adjustsFontForContentSizeCategory=YES;", body)
        self.assertIn("cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;", body)

    def test_summary_card_labels_scale(self):
        self.assertIn("title.adjustsFontForContentSizeCategory=YES;", LOCAL_SOURCE)
        self.assertIn("detail.adjustsFontForContentSizeCategory=YES;", LOCAL_SOURCE)


class ServiceEditorVoiceOverContracts(unittest.TestCase):
    """资源编辑器内联操作按钮、开关、分段与保存控件必须可被 VoiceOver 读屏。"""

    def test_auto_port_button_has_label_hint_traits(self):
        self.assertIn('autoPortBtn.accessibilityLabel=@"自动分配可用端口";', EDITOR_SOURCE)
        self.assertIn('autoPortBtn.accessibilityHint=@"在 1024–65535 范围内分配一个未被占用的端口";', EDITOR_SOURCE)
        self.assertIn("autoPortBtn.accessibilityTraits=UIAccessibilityTraitButton;", EDITOR_SOURCE)

    def test_paste_url_button_has_label_hint_traits(self):
        self.assertIn('pasteURLBtn.accessibilityLabel=@"粘贴剪贴板中的代码链接";', EDITOR_SOURCE)
        self.assertIn('pasteURLBtn.accessibilityHint=@"将剪贴板内容填入远程代码 URL 输入框";', EDITOR_SOURCE)
        self.assertIn("pasteURLBtn.accessibilityTraits=UIAccessibilityTraitButton;", EDITOR_SOURCE)

    def test_lan_switch_has_label_and_hint(self):
        self.assertIn('self.lanSwitch.accessibilityLabel=@"允许局域网访问";', EDITOR_SOURCE)
        self.assertIn('self.lanSwitch.accessibilityHint=@"开启后同一局域网内的设备可访问此服务";', EDITOR_SOURCE)

    def test_source_control_has_hint(self):
        self.assertIn(
            'self.sourceControl.accessibilityHint=@"选择服务代码来自文件、链接或直接输入代码";',
            EDITOR_SOURCE,
        )

    def test_save_bar_button_has_label_and_hint(self):
        self.assertIn(
            'self.navigationItem.rightBarButtonItem.accessibilityLabel=@"保存资源配置";',
            EDITOR_SOURCE,
        )
        self.assertIn(
            'self.navigationItem.rightBarButtonItem.accessibilityHint=@"校验并保存当前资源名称、端口、代码与网络配置";',
            EDITOR_SOURCE,
        )

    def test_save_row_and_selectable_rows_carry_button_trait(self):
        # 保存协议行需有具体 hint；其余可选行兜底 button trait + 默认 hint
        self.assertIn('c.accessibilityHint=@"保存当前资源配置";', EDITOR_SOURCE)
        self.assertIn(
            "c.accessibilityTraits=UIAccessibilityTraitButton;\n"
            "        if(!c.accessibilityHint.length)c.accessibilityHint=@\"点按查看或编辑此行配置\";",
            EDITOR_SOURCE,
        )

    def test_code_tools_menu_button_has_label_and_hint(self):
        self.assertIn('toolsItem.accessibilityLabel=@"代码工具";', EDITOR_SOURCE)
        self.assertIn(
            'toolsItem.accessibilityHint=@"搜索、跳行、预检、格式化、复制或插入代码模板";',
            EDITOR_SOURCE,
        )


class ServiceEditorDynamicTypeContracts(unittest.TestCase):
    """资源编辑器输入框、分段标题与代码状态栏必须随 Dynamic Type 缩放。"""

    def test_input_fields_use_preferred_font_and_scale(self):
        body = method_body(EDITOR_SOURCE, "- (UITextField *)field:(NSString *)placeholder value:(NSString *)value {")
        self.assertIn("f.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];", body)
        self.assertIn("f.adjustsFontForContentSizeCategory=YES;", body)
        self.assertIn("[f.heightAnchor constraintGreaterThanOrEqualToConstant:44].active", body)

    def test_source_control_title_scales_with_content_size(self):
        body = method_body(EDITOR_SOURCE, "- (void)updateSourceControlFont {")
        self.assertIn("preferredFontForTextStyle:UIFontTextStyleSubheadline", body)
        # 在内容尺寸变化时刷新分段标题字体
        self.assertIn("preferredContentSizeCategory", method_body(EDITOR_SOURCE, "- (void)traitCollectionDidChange:"))

    def test_code_editor_font_is_scaled_and_capped(self):
        self.assertIn(
            "[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:baseCodeFont];",
            EDITOR_SOURCE,
        )
        self.assertIn("_editor.adjustsFontForContentSizeCategory=YES;", EDITOR_SOURCE)

    def test_code_status_bar_scales_with_content_size(self):
        self.assertIn("self.codeStatusLabel.adjustsFontForContentSizeCategory = YES;", EDITOR_SOURCE)


if __name__ == "__main__":
    unittest.main()
