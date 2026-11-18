"""Regression tests for Round 10 Second-Pass Deep Audit & Enhancement of Python/JS Service Detail & Editor (ISS-80 through ISS-84)."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round10ServiceDetailAndEditorV2Tests(unittest.TestCase):
    def test_iss80_js_plugin_runtime_does_not_overwrite_user_edited_webox_scripts(self):
        js_m = (SOURCES / "JSPluginRuntime.m").read_text(encoding="utf-8")
        self.assertIn(
            'BOOL legacyUnadaptedWasm = [text containsString:@"KVM_WASM_BASE64"] && ![text containsString:@"generatePlayUrlPureJS"];',
            js_m,
        )
        self.assertIn("if (legacyUnadaptedWasm) {", js_m)

    def test_iss81_centralized_bundled_factory_path_plain_string_options_and_one_tap_restart_prompt(self):
        ss_h = (SOURCES / "ServiceStore.h").read_text(encoding="utf-8")
        ss_m = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        self.assertIn("+ (nullable NSString *)bundledFactoryCodePathForService:(NSDictionary *)service;", ss_h)
        self.assertIn("+ (nullable NSString *)bundledFactoryCodePathForService:(NSDictionary *)service {", ss_m)

        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertIn("NSString *factoryPath=[ServiceStore bundledFactoryCodePathForService:self.service];", plug_m)
        self.assertIn('if(factoryData.length&&[currentData isEqualToData:factoryData]){[updated removeObjectForKey:@"userEditedCode"];}', plug_m)
        self.assertIn("if(jsonErr&&[options isKindOfClass:NSString.class]&&![trimmed hasPrefix:@\"{\"]&&![trimmed hasPrefix:@\"[\"])", plug_m)
        self.assertIn("- (void)promptRestartIfRunningWithTitle:(NSString *)title message:(NSString *)message", plug_m)
        self.assertIn('actionWithTitle:@"立即重启"', plug_m)

        svc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("NSString *factoryPath = [ServiceStore bundledFactoryCodePathForService:self.service];", svc_m)
        self.assertIn('[updated removeObjectForKey:@"userEditedCode"];', svc_m)

    def test_iss82_service_code_editor_syntax_highlighting_search_replace_and_jscontext_ast_check(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn("#import <JavaScriptCore/JavaScriptCore.h>", se_m)
        self.assertIn("- (void)applySyntaxHighlightingIfNeeded", se_m)
        self.assertIn("- (void)promptReplaceInCode", se_m)
        self.assertIn('actionWithTitle:@"查找并替换代码"', se_m)
        self.assertIn('actionWithTitle:@"替换下一处"', se_m)
        self.assertIn('actionWithTitle:@"全部替换"', se_m)
        self.assertIn('[syntaxCtx evaluateScript:@"new Function(__candidateSource);"];', se_m)
        self.assertIn("JavaScriptCore 语法编译：", se_m)

    def test_iss83_companion_config_editor_and_per_plugin_runtime_storage_clear(self):
        ss_h = (SOURCES / "ServiceStore.h").read_text(encoding="utf-8")
        ss_m = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        self.assertIn("+ (BOOL)clearRuntimeStorageForService:(NSDictionary *)service error:(NSError **)error;", ss_h)
        self.assertIn('+ (BOOL)clearRuntimeStorageForService:(NSDictionary *)service error:(NSError **)error {', ss_m)
        self.assertIn('[NSUserDefaults.standardUserDefaults removeObjectForKey:[@"CCTVJSStorage:" stringByAppendingString:identifier]];', ss_m)

        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)openCompanionConfigEditor", plug_m)
        self.assertIn("- (void)confirmClearPluginStorage", plug_m)
        self.assertIn('@{@"title":@"清理此资源缓存与会话状态"', plug_m)
        self.assertIn('if([action isEqual:@"editConfigEntry"]){[self openCompanionConfigEditor];return;}', plug_m)
        self.assertIn('if([action isEqual:@"clearStorage"]){[self confirmClearPluginStorage];return;}', plug_m)

    def test_iss84_live_port_conflict_footer_and_file_mode_document_picker_routing(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        footer_body = se_m.split("- (void)refreshSection0FooterCache {", 1)[1].split(
            "\n- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:", 1
        )[0]
        self.assertIn("⚠ 端口 %ld 已被「%@」占用", footer_body)
        self.assertIn("- (void)presentCodeDocumentPicker", se_m)
        self.assertIn("else if (self.sourceControl.selectedSegmentIndex == 0 && !self.code.length)\n            [self presentCodeDocumentPicker];", se_m)


if __name__ == "__main__":
    unittest.main()
