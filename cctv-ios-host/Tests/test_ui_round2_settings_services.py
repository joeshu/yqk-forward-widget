"""Second-round UI/layout/interaction + stability contracts for the
settings and resource-service pages (Settings, ConfigCenter, Plugin,
PluginResourceDetail, PluginRunHistory, ResourceImportSheet).

Each test pins one round-2 fix by inspecting the Objective-C source:
no Xcode and no device are available, so these are source contracts
in the same style as the other Tests/test_*.py files.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def method_body(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class SettingsRound2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = (ROOT / 'Sources/SettingsViewController.m').read_text()

    def test_action_sheet_guards_double_present(self):
        # 快速连点同一行会重复 present：UIKit 只会警告并丢掉后一个。
        body = method_body(self.settings, '- (void)presentActionSheet:')
        self.assertIn('if(self.presentedViewController)return;', body)

    def test_update_check_has_inflight_guard_and_session_cleanup(self):
        # 连点“检查更新”会发重复请求并弹重复提示；一次性 session 也要释放。
        self.assertIn('@property(nonatomic,assign) BOOL checkingUpdate;', self.settings)
        body = method_body(self.settings, '- (void)checkForUpdateFromIndexPath:')
        self.assertIn('if(self.checkingUpdate)return;self.checkingUpdate=YES;', body)
        self.assertIn('owner.checkingUpdate=NO;', body)
        self.assertIn('finishTasksAndInvalidate', body)

    def test_controls_have_accessibility_labels(self):
        # 开关/分段控件之前只有 accessibilityIdentifier，VoiceOver
        # 读不出“这是什么设置”；每类控件都要有行标题作 label。
        body = method_body(self.settings, 'cellForRowAtIndexPath:')
        self.assertEqual(body.count('accessibilityLabel=row[@"title"]'), 3)

    def test_toggle_never_writes_with_nil_key(self):
        body = method_body(self.settings, '- (void)toggle:')
        self.assertIn('if(!sender.accessibilityIdentifier.length)return;', body)

    def test_dynamic_type_change_reloads_settings_rows(self):
        # 分段标题字号取自 preferredFont，档位变化时不会自动跟随。
        body = method_body(self.settings, '- (void)traitCollectionDidChange:')
        self.assertIn('preferredContentSizeCategory', body)
        self.assertIn('[self.table reloadData]', body)

    def test_theme_change_refreshes_rows_even_without_window(self):
        # view.window 为 nil 时主题仍已写入偏好：色板副标题不能一直显示旧主题。
        picker = method_body(self.settings, '- (void)presentThemePicker:')
        self.assertIn('[self.table reloadData];', picker)
        appearance = method_body(self.settings, '- (void)appearanceChanged:')
        self.assertIn('[self.table reloadData]', appearance)


class ConfigCenterRound2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = (ROOT / 'Sources/ConfigCenterViewController.m').read_text()

    def test_filter_pills_and_more_button_meet_44pt(self):
        # 筛选 pill 最小 42pt、“更多”按钮 36x36，都低于 44pt 最小触摸目标。
        self.assertIn('CGFloat pillHeight=MAX(44,', self.config)
        self.assertNotIn('MAX(42,', self.config)
        self.assertIn('more.frame=CGRectMake(0,0,44,44);', self.config)
        self.assertIn('more.frame=CGRectMake(58,0,44,44);', self.config)
        self.assertIn('initWithFrame:CGRectMake(0,0,104,44)', self.config)
        self.assertIn('accessoryWidth=plugin?104:(tvbox?44:(hasExportMenu?104:56))', self.config)

    def test_toggle_reverts_when_profile_is_gone(self):
        # 配置已被筛选掉/移除时，开关还停在拨动后的样子，与实际状态不一致。
        body = method_body(self.config, '- (void)toggle:')
        self.assertIn('if(!p){sender.on=!sender.on;return;}', body)

    def test_date_formatter_is_shared_not_recreated_per_row(self):
        # heightForRow/cellForRow 每行都调 resourceDetailForProfile，
        # 每次 new 一个 NSDateFormatter 会拖慢滚动。
        self.assertIn('CCTVResourceListDateFormatter', self.config)
        self.assertEqual(self.config.count('[NSDateFormatter new]'), 1)

    def test_runtime_observer_not_double_registered(self):
        body = method_body(self.config, '- (void)viewWillAppear:')
        self.assertIn('removeObserver:self name:PyHostRuntimeStateDidChangeNotification', body)
        self.assertIn('addObserver:self selector:@selector(runtimeStateDidChange)', body)


class PluginRound2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = (ROOT / 'Sources/PluginViewController.m').read_text()

    def test_service_port_is_validated_and_centralised(self):
        # 端口曾在三处复制粘贴查找，订阅地址还取“第一个 builtin 服务”：
        # 配置缺失/非法时会拼出 http://127.0.0.1:0/all.m3u。
        self.assertIn('- (NSInteger)pluginServicePort', self.plugin)
        self.assertIn('(port>=1&&port<=65535)?port:8767', self.plugin)
        self.assertNotIn('{port=[service[@"port"] integerValue];break;}', self.plugin)
        self.assertNotIn('if([s[@"builtin"] boolValue])', self.plugin)
        body = method_body(self.plugin, '- (NSString *)subscriptionURL')
        self.assertIn('[self pluginServicePort]', body)

    def test_restart_has_watchdog_like_detail_page(self):
        # onRestart 回调若永不触发，重启按钮会永久锁死（详情页已有 30 秒兜底）。
        body = method_body(self.plugin, '- (void)restart')
        self.assertIn('restartGeneration', body)
        self.assertIn('30*NSEC_PER_SEC', body)
        self.assertIn('owner.restarting=NO;', body)

    def test_start_stop_locked_until_state_update(self):
        # 启停是异步的：状态通知回来前连点会重复下发启停。
        self.assertIn('startStopPending', self.plugin)
        start = method_body(self.plugin, '- (void)start')
        self.assertIn('if(self.startStopPending)return;', start)
        stop = method_body(self.plugin, '- (void)stop')
        self.assertIn('if(self.startStopPending)return;', stop)
        watchdog = method_body(self.plugin, '- (void)armStartStopWatchdog')
        self.assertIn('10*NSEC_PER_SEC', watchdog)
        refresh = method_body(self.plugin, '- (void)refreshStatus')
        self.assertIn('self.startStopPending=NO;', refresh)

    def test_buttons_shrink_long_titles_at_xxx_large_type(self):
        # 三个启停按钮各占 1/3 宽，特大字体下标题会被截断。
        body = method_body(self.plugin, '- (UIButton *)button:')
        self.assertIn('adjustsFontSizeToFitWidth=YES', body)
        self.assertIn('minimumScaleFactor=0.6', body)


class PluginDetailRound2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.detail = (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text()

    def test_state_change_reload_is_main_thread_only(self):
        # 运行状态通知可能来自后台线程：直接 reloadData 会触发 UIKit 断言。
        body = method_body(self.detail, '- (void)stateChanged')
        self.assertIn('NSThread.isMainThread', body)
        self.assertIn('isViewLoaded', body)

    def test_service_dictionary_access_is_type_checked(self):
        # manifest/url 曾被无检查地嵌套下标/length：类型不对会崩溃。
        self.assertIn('- (NSDictionary *)serviceManifest', self.detail)
        self.assertIn('- (NSString *)serviceURLString', self.detail)
        self.assertNotIn('self.service[@"manifest"][', self.detail)
        self.assertNotIn('[self.service[@"url"] length]', self.detail)
        self.assertIn('serviceStatus=[self.service[@"status"] isKindOfClass:NSString.class]', self.detail)

    def test_long_values_use_subtitle_cells(self):
        # Value1 样式的 detail 在长值下会被截断：超长值改用 Subtitle 布局。
        body = method_body(self.detail, 'cellForRowAtIndexPath:')
        self.assertIn('service.resource.long-value', body)
        self.assertIn('length]>80', body)

    def test_show_error_not_presented_over_existing_alert(self):
        # 已有弹窗时再 present 错误弹窗会被 UIKit 静默丢掉。
        body = method_body(self.detail, '- (void)showError:(NSString *)message {')
        self.assertIn('self.presentedViewController', body)


class RunHistoryAndImportRound2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.history = (ROOT / 'Sources/PluginRunHistoryViewController.m').read_text()
        cls.sheet = (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text()

    def test_run_history_reuses_date_formatter(self):
        body = method_body(self.history, '- (NSString *)formattedDate:')
        self.assertIn('dispatch_once', body)

    def test_run_history_refresh_is_main_thread_only(self):
        body = method_body(self.history, '- (void)refreshRuns')
        self.assertIn('NSThread.isMainThread', body)

    def test_import_sheet_ignores_double_tap(self):
        # 快速连点会 dismiss 两次并回调两次 onSelect（上层可能重复 push）。
        body = method_body(self.sheet, 'didSelectRowAtIndexPath:')
        self.assertIn('if(self.didSelectOption)return;self.didSelectOption=YES;', body)

    def test_import_sheet_rows_have_accessibility_identifiers(self):
        body = method_body(self.sheet, 'cellForRowAtIndexPath:')
        self.assertIn('resource-import-option-%ld-%ld', body)


if __name__ == '__main__':
    unittest.main()
