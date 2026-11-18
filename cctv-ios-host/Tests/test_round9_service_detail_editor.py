"""Regression tests for Round 9 Deep Audit & Enhancement of Python/JS Service Detail & Editor (ISS-73 through ISS-79)."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round9ServiceDetailAndEditorAuditTests(unittest.TestCase):
    def test_iss73_manifest_plugin_code_editing_unlocked_and_user_edits_preserved_across_bundle_sync(self):
        se_h = (SOURCES / "ServiceEditorViewController.h").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic, copy, nullable) NSString *bundledResourcePath;", se_h)
        self.assertIn("@property(nonatomic, copy, nullable) dispatch_block_t onSaveCode;", se_h)

        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (BOOL)isReadOnlyCode {return [self.service[@\"builtin\"] boolValue];}", se_m)
        self.assertIn('@"查看 / 编辑资源入口代码"', se_m)
        self.assertIn("view.readOnly=[self isReadOnlyCode];", se_m)
        self.assertIn('service[@"userEditedCode"] = @YES;', se_m)

        ss_m = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        self.assertIn('BOOL userEdited = [service[@"userEditedCode"] boolValue] && [NSFileManager.defaultManager fileExistsAtPath:target];', ss_m)

    def test_iss74_running_service_config_or_code_changes_offer_stop_and_restart(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        save_body = se_m.split("- (void)applySaveForService:(NSDictionary *)service {", 1)[1].split(
            "\n- (BOOL)customCodeMatchesSavedVersion", 1
        )[0]
        self.assertIn('alertControllerWithTitle:@"应用配置并重启服务？"', save_body)
        self.assertIn('actionWithTitle:@"停止并重启"', save_body)
        self.assertIn("[weakSelf applyPortChange:service];", save_body)

    def test_iss75_service_code_editor_status_bar_cyclic_find_goto_line_syntax_validator_and_unsaved_guard(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn('self.codeStatusLabel.accessibilityIdentifier = @"service.code.status";', se_m)
        self.assertIn("- (void)updateCodeStatusBar", se_m)
        self.assertIn("- (void)promptGoToLine", se_m)
        self.assertIn("- (void)validateCodeSyntax", se_m)
        self.assertIn("- (void)requestCloseCodeEditor", se_m)
        self.assertIn('actionWithTitle:@"跳转到指定行号"', se_m)
        self.assertIn('actionWithTitle:@"语法与结构预检"', se_m)
        self.assertIn("NSUInteger currentEnd = NSMaxRange(owner->_editor.selectedRange);", se_m)
        self.assertIn("NSUInteger limit=self.readOnly?512*1024:2*1024*1024;", se_m)

    def test_iss76_plugin_resource_detail_entry_code_viewer_options_editor_and_media_health_probe(self):
        plug_m = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertIn('@{@"title":@"入口文件",@"value":entry,@"action":@"viewCode"}', plug_m)
        self.assertIn('@{@"title":@"插件参数",@"value":@"查看或编辑 JSON 运行参数",@"action":@"editOptions"}', plug_m)
        self.assertIn('@{@"title":@"检测资源接口健康"', plug_m)
        self.assertIn("- (void)openEntryCodeViewer", plug_m)
        self.assertIn("- (void)openOptionsJSONEditor", plug_m)
        self.assertIn("- (void)probeMediaHealth", plug_m)

    def test_iss77_multi_engine_file_picker_code_templates_and_reset_bundled_code(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn(
            "initForOpeningContentTypes:@[ UTTypePythonScript, UTTypeJavaScript, UTTypeJSON, UTTypePlainText, UTTypeSourceCode ]",
            se_m,
        )
        self.assertIn("- (void)insertCodeTemplate:(NSString *)templateKind", se_m)
        self.assertIn("- (void)resetBundledCodeIfApplicable", se_m)
        self.assertIn('menuWithTitle:@"插入标准脚本模板"', se_m)
        self.assertIn('actionWithTitle:@"恢复内置初始代码"', se_m)

    def test_iss78_services_list_perform_service_change_has_30s_watchdog_and_editable_code_viewer(self):
        svc_m = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *changingServiceGenerations;", svc_m)
        self.assertIn("![owner.changingServiceIDs containsObject:identifier])return;", svc_m)
        self.assertIn('v.readOnly = [self.service[@"builtin"] boolValue];', svc_m)

    def test_iss79_service_editor_cleans_orphan_draft_files_on_load(self):
        se_m = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        load_body = se_m.split("@implementation ServiceEditorViewController", 1)[1].split("- (void)viewDidLoad {", 1)[1].split("\n- (void)reloadThemeAppearance", 1)[0]
        self.assertIn("[NSFileManager.defaultManager removeItemAtPath:[self draftPath] error:NULL];", load_body)
        self.assertIn("[NSFileManager.defaultManager removeItemAtPath:[self optionsDraftPath] error:NULL];", load_body)


if __name__ == "__main__":
    unittest.main()
