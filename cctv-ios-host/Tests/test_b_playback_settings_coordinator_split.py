"""阶段 B-P1 源码契约：播放设置菜单协调器拆分。

验证 MediaPlaybackViewController（约 3070 行 -> 缩减）将播放设置菜单构建职责
迁入独立协调器 MediaPlaybackSettingsCoordinator 后：
  - 协调器新增源文件存在且实现顶层菜单/倍速/画面比例/音轨/字幕/外挂字幕/睡眠定时等构建；
  - 协调器以弱引用持有 owner，不造成循环；init 不可用空构造；
  - 宿主 VC 在 init 创建协调器，teardown 与 dealloc 经协调器清理睡眠定时器；
  - 迁出后宿主 VC 不再直接实现被迁出的六个菜单/定时方法（避免重复实现导致行为分叉）；
  - accessibilityIdentifier（media-playback-speed 等）与菜单 identifier
    （media.playback.menu.av / .controls / .prefs / .diag / .skip / .episodes / .extsub）保持不变；
  - 不触碰 MPV 路由层（a-playback-route）与状态机（a-playback-session）：
    协调器不引用 MediaPlaybackDecodeRouter / HostPlaybackSession / attemptedRoutes 的直接写。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


class PlaybackSettingsCoordinatorSplitContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vc_m = read('MediaPlaybackViewController.m')
        cls.coord_h = read('MediaPlaybackSettingsCoordinator.h')
        cls.coord_m = read('MediaPlaybackSettingsCoordinator.m')

    # ---- 新增源文件存在 ----
    def test_coordinator_header_and_impl_exist(self):
        self.assertIn('@interface MediaPlaybackSettingsCoordinator : NSObject', self.coord_h)
        self.assertIn('@implementation MediaPlaybackSettingsCoordinator', self.coord_m)

    def test_owner_protocol_declares_engine_action_callbacks(self):
        proto = self.coord_h[self.coord_h.index('@protocol MediaPlaybackSettingsCoordinatorOwner'):]
        proto = proto[:proto.index('@end')]
        for sel in ('setPlaybackRate:', 'setVideoGravity:', 'setKeepScreenAwake:',
                    'rememberIntroEnd', 'rememberOutroSkip', 'copyCurrentStreamDiagnostics',
                    'openAdaptationMonitor', 'playResult:', 'playNextEpisodeManually',
                    'playPreviousEpisodeManually', 'applyDecodeModeChange:'):
            self.assertIn(sel, proto, 'owner 协议缺少回调 %s' % sel)

    def test_coordinator_weak_owner_avoids_retain_cycle(self):
        self.assertIn('@property (nonatomic, weak, nullable) id<MediaPlaybackSettingsCoordinatorOwner> owner;', self.coord_h)

    def test_init_requires_owner_and_disables_empty_new(self):
        self.assertIn('- (instancetype)initWithOwner:(id<MediaPlaybackSettingsCoordinatorOwner>)owner NS_DESIGNATED_INITIALIZER;', self.coord_h)
        self.assertIn('- (instancetype)init NS_UNAVAILABLE;', self.coord_h)
        self.assertIn('+ (instancetype)new NS_UNAVAILABLE;', self.coord_h)

    # ---- 宿主 VC 接线 ----
    def test_vc_creates_coordinator_in_init(self):
        m = re.search(r'- \(instancetype\)init \{if\(\(self=\[super init\]\)\)\{([^}]*_settingsCoordinator=[^}]*)\}return self;\}', self.vc_m)
        self.assertIsNotNone(m, 'VC init 未创建 settingsCoordinator')
        self.assertIn('_settingsCoordinator=[[MediaPlaybackSettingsCoordinator alloc] initWithOwner:self]', m.group(1))

    def test_vc_declares_owner_protocol_conformance(self):
        ext = self.vc_m.split('@interface MediaPlaybackViewController ()', 1)[1].split('@end', 1)[0]
        self.assertIn('MediaPlaybackSettingsCoordinatorOwner', ext)

    def test_vc_has_settings_coordinator_property(self):
        self.assertIn('@property(nonatomic,strong) MediaPlaybackSettingsCoordinator *settingsCoordinator;', self.vc_m)

    def test_vc_sleep_timer_teardown_via_coordinator(self):
        # teardownAfterScreenExit 与 dealloc 各调用一次 invalidateSleepTimer
        self.assertGreaterEqual(self.vc_m.count('[self.settingsCoordinator invalidateSleepTimer];'), 2)

    def test_vc_menu_calls_go_through_coordinator(self):
        # 不应残留对已迁出菜单方法的直接 self/owner 调用
        self.assertNotIn('[self playbackOptionsMenu]', self.vc_m)
        self.assertNotIn('[owner playbackOptionsMenu]', self.vc_m)
        self.assertNotIn('[self playbackRateMenu]', self.vc_m)
        self.assertNotIn('[owner playbackRateMenu]', self.vc_m)

    # ---- 协调器实现被迁出的六个方法 ----
    def test_coordinator_implements_migrated_menu_methods(self):
        for sig in ('- (UIMenu *)playbackOptionsMenu {',
                    '- (nullable UIMenu *)playbackRateMenu {',
                    '- (UIMenu *)externalSubtitleMenu {',
                    '- (UIMenu *)playbackSleepTimerMenu {',
                    '- (nullable UIMenu *)mediaSelectionMenuForCharacteristic:'):
            self.assertIn(sig, self.coord_m, '协调器缺少实现 %s' % sig)

    def test_vc_no_longer_implements_migrated_menu_methods(self):
        for sig in ('- (UIMenu *)playbackOptionsMenu {',
                    '- (nullable UIMenu *)playbackRateMenu {',
                    '- (UIMenu *)externalSubtitleMenu {',
                    '- (UIMenu *)playbackSleepTimerMenu {',
                    '- (nullable UIMenu *)mediaSelectionMenuForCharacteristic:'):
            self.assertNotIn(sig, self.vc_m, 'VC 不应再实现被迁出方法 %s' % sig)

    def test_coordinator_owns_sleep_timer_state(self):
        self.assertIn('@property (nonatomic) NSInteger mediaSleepMinutes;', self.coord_h)
        self.assertIn('@property (nonatomic, strong, nullable) NSTimer *mediaSleepTimer;', self.coord_h)
        self.assertIn('[self.mediaSleepTimer invalidate]', self.coord_m)

    def test_vc_no_longer_owns_sleep_timer_properties(self):
        ext = self.vc_m.split('@interface MediaPlaybackViewController ()', 1)[1].split('@end', 1)[0]
        self.assertNotIn('NSTimer *mediaSleepTimer;', ext)
        self.assertNotIn('NSInteger mediaSleepMinutes;', ext)

    # ---- accessibility IDs 与菜单标识符保持不变 ----
    def test_accessibility_identifier_speed_button_preserved_in_vc(self):
        self.assertIn('@"media-playback-speed"', self.vc_m)

    def test_menu_identifiers_preserved_in_coordinator(self):
        for ident in ('@"media.playback.menu.av"',
                      '@"media.playback.menu.controls"',
                      '@"media.playback.menu.prefs"',
                      '@"media.playback.menu.diag"',
                      '@"media.playback.menu.skip"',
                      '@"media.playback.menu.episodes"',
                      '@"media.playback.menu.extsub"'):
            self.assertIn(ident, self.coord_m, '协调器缺少菜单标识符 %s' % ident)

    # ---- 不触碰 MPV 路由 / 状态机 ----
    def test_coordinator_does_not_touch_route_or_session_layers(self):
        self.assertNotIn('MediaPlaybackDecodeRouter', self.coord_m)
        self.assertNotIn('HostPlaybackSession', self.coord_m)
        self.assertNotIn('attemptedRoutes', self.coord_m)
        # 协调器不应直接调用 playResult:（解码模式/上下集切换经 owner 回调）
        # —— 但 owner 协议声明了 playResult:，这里检查实现体不硬编码路由位掩码
        self.assertNotIn('AttemptedMPV', self.coord_m)
        self.assertNotIn('AttemptedCicada', self.coord_m)

    # ---- 解码模式切换经 owner 回调 ----
    def test_decode_mode_action_delegates_to_owner(self):
        self.assertIn('[host applyDecodeModeChange:val]', self.coord_m)
        self.assertIn('- (void)applyDecodeModeChange:(NSString *)mode;', self.coord_h)

    def test_vc_implements_applyDecodeMode_change(self):
        self.assertIn('- (void)applyDecodeModeChange:(NSString *)mode {', self.vc_m)

    # ---- 括号平衡（协调器实现） ----
    def test_coordinator_impl_balanced_delimiters(self):
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', self.coord_m, flags=re.S)
        # 去掉字符串字面量以避免 NSString 内的括号干扰
        code = re.sub(r'@"(?:\\.|[^"\\])*"', '""', code)
        self.assertEqual(code.count('{'), code.count('}'), '协调器实现 braces 不平衡')
        self.assertEqual(code.count('('), code.count(')'), '协调器实现 parens 不平衡')


if __name__ == '__main__':
    unittest.main()
