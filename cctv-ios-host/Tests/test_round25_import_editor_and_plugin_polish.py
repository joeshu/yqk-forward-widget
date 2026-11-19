import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class Round25ImportEditorAndPluginPolishTests(unittest.TestCase):
    def test_service_code_editor_ime_guard_and_debounced_syntax_highlight(self):
        src = read_source("ServiceEditorViewController.m")
        self.assertIn("syntaxHighlightGeneration", src)
        self.assertIn("- (void)scheduleSyntaxHighlighting", src)
        self.assertIn("120 * NSEC_PER_MSEC", src)
        m = re.search(
            r"- \(void\)textViewDidChange:\(UITextView \*\)textView \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m)
        body = m.group(0)
        self.assertIn("textView.markedTextRange != nil", body)
        self.assertIn("[self scheduleSyntaxHighlighting];", body)
        self.assertNotIn("[self applySyntaxHighlightingIfNeeded];", body)

    def test_service_code_and_editor_both_react_to_live_color_appearance_changes(self):
        src = read_source("ServiceEditorViewController.m")
        self.assertGreaterEqual(
            src.count("hasDifferentColorAppearanceComparedToTraitCollection:"), 2
        )

    def test_service_editor_tactile_press_context_menu_and_weak_close_alert(self):
        src = read_source("ServiceEditorViewController.m")
        self.assertIn("didHighlightRowAtIndexPath:", src)
        self.assertIn("didUnhighlightRowAtIndexPath:", src)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", src)
        self.assertIn("复制本机接口地址", src)
        m = re.search(
            r"- \(void\)requestClose \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m)
        self.assertIn("__weak typeof(self) weakSelf=self;", m.group(0))
        self.assertIn("[weakSelf save]", m.group(0))

    def test_resource_import_workflow_ime_pasteboard_throttle_and_theme_borders(self):
        src = read_source("ResourceImportWorkflowViewController.m")
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)
        self.assertIn("HostSetLayerBorderColor(self.address,HostBorder());", src)
        self.assertIn(
            "HostSetLayerBorderColor(self.smartClipboardButton,[HostAccent() colorWithAlphaComponent:0.35]);",
            src,
        )
        self.assertIn("self.clearAddressButton.backgroundColor=HostNeutralSurface();", src)
        m = re.search(
            r"- \(void\)textViewDidChange:\(UITextView \*\)textView \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m)
        body = m.group(0)
        self.assertIn("textView.markedTextRange!=nil", body)
        self.assertNotIn("[self refreshSmartClipboardAndPresets]", body)

    def test_resource_import_sheet_bounds_order_theme_and_keyboard_dismiss(self):
        src = read_source("ResourceImportSheetViewController.m")
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)
        self.assertIn("UIScrollViewKeyboardDismissModeOnDrag", src)
        self.assertIn("[item[@\"id\"] length]?[@\"resource-import.option.\"", src)
        m = re.search(
            r"- \(void\)tableView:\(UITableView \*\)tableView didSelectRowAtIndexPath:\(NSIndexPath \*\)indexPath \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m)
        body = m.group(0)
        self.assertLess(
            body.index("indexPath.row>=options.count"),
            body.index("self.didSelectOption=YES"),
        )
        self.assertIn("已复制导入说明", src)

    def test_plugin_view_controller_full_button_theme_pending_state_and_tap_copy(self):
        src = read_source("PluginViewController.m")
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)
        self.assertIn("styledButtons", src)
        self.assertIn("for(UIButton *b in self.styledButtons)", src)
        self.assertIn("UITapGestureRecognizer", src)
        self.assertIn("轻点复制播放列表地址", src)
        self.assertIn("正在启动服务…", src)
        self.assertIn("正在停止服务…", src)
        self.assertIn("self.restartButton.enabled=NO;", src)
        self.assertIn("__weak typeof(sender) weakSender=sender;", src)


if __name__ == "__main__":
    unittest.main()
