"""T13 根导航/全屏/设备（U03/U04/U05/U06）。

行为模型复刻 ObjC 逻辑并实际执行；源码合同锁住接线。
被测文件：
  Sources/RootViewController.m（U03 导航所有权、U04 直播全屏横屏）
  Sources/RootViewController_Internal.h（U03 in-flight 标志）
  Sources/MediaPlaybackViewController.m（U06 锁按钮语义）
  Sources/PlaybackOverlayController.m（U06 覆盖层 VoiceOver 保护，已有）
  project.yml / Scripts/ci-build.sh / Tests/ui-smoke.sh（U05 最低 iOS 17.0）
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


ROOT_SOURCE = read("RootViewController.m")
INTERNAL_HEADER = read("RootViewController_Internal.h")
PLAYBACK_SOURCE = read("MediaPlaybackViewController.m")
OVERLAY_SOURCE = read("PlaybackOverlayController.m")


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


WILL_SHOW = "- (void)navigationController:(UINavigationController *)navigationController willShowViewController:"
DID_SHOW = "- (void)navigationController:(UINavigationController *)navigationController didShowViewController:"


# ---------------------------------------------------------------------------
# 行为模型：U03 导航所有权状态机
# ---------------------------------------------------------------------------
# 复刻 willShow/didShow 的标志协议：
#   willShow(self)            -> 标志清零（侧滑返回手势开始）
#   willShow(其他页)          -> 标志置位（push 开始）
#   didShow(self)             -> 标志清零，不挂起
#   didShow(其他页)           -> 仅当标志置位时才是“push 完成”，
#                                且仅当 activeTab<2 且不是只读 EPG 页时挂起
# 取消的交互式 pop 序列是 willShow(self) -> didShow(详情页)，
# 标志已被清零，所以不会误挂起——这正是旧实现（willShow 里直接挂起）
# 的不可逆停播缺陷。
#
# shown: 'self' 根页 / 'epg' 只读节目单页 / 'config' 其他二级页。


class LiveNavigationSession:
    def __init__(self):
        self.live_playing = True
        self.suspended = False
        self.push_in_flight = False
        self.active_tab = 0
        self.shown = "self"

    def will_show(self, vc):
        self.push_in_flight = vc != "self"

    def did_show(self, vc):
        self.shown = vc
        if vc == "self":
            self.push_in_flight = False
            return
        if self.push_in_flight:
            self.push_in_flight = False
            if self.active_tab < 2 and vc != "epg":
                self._suspend("left_live_navigation_page")

    def _suspend(self, reason):
        if not self.live_playing:
            return
        self.live_playing = False
        self.suspended = True
        self.suspend_reason = reason

    def select_tab(self, tag):
        # 显式切 tab 是所有权转移：换 tab 前就挂起（旧行为保留）。
        if self.active_tab < 2 and tag >= 2:
            self._suspend("left_live_interface")
        self.active_tab = tag

    def vod_will_start(self):
        # 明确启动另一播放会话：释放原 owner（旧行为保留）。
        self._suspend("vod_playback_starting")

    def resume_from_mini_bar(self):
        if self.suspended:
            self.suspended = False
            self.live_playing = True


class NavigationOwnershipModelTests(unittest.TestCase):
    def test_completed_push_to_config_page_suspends_live(self):
        session = LiveNavigationSession()
        session.will_show("config")
        session.did_show("config")
        self.assertFalse(session.live_playing)
        self.assertTrue(session.suspended)
        self.assertEqual(session.suspend_reason, "left_live_navigation_page")

    def test_cancelled_interactive_pop_does_not_stop_playback(self):
        session = LiveNavigationSession()
        session.will_show("config")
        session.did_show("config")
        session.resume_from_mini_bar()
        # 侧滑返回手势开始：willShow(self) 清标志；取消后 didShow
        # 再次报告详情页，但标志已清，不挂起。
        session.will_show("self")
        session.did_show("config")
        self.assertTrue(session.live_playing)
        self.assertFalse(session.suspended)

    def test_completed_push_to_epg_keeps_live_session(self):
        session = LiveNavigationSession()
        session.will_show("epg")
        session.did_show("epg")
        self.assertTrue(session.live_playing)
        self.assertFalse(session.suspended)

    def test_pop_back_to_live_page_keeps_suspended_state_until_manual_resume(self):
        session = LiveNavigationSession()
        session.will_show("config")
        session.did_show("config")
        session.will_show("self")
        session.did_show("self")
        self.assertFalse(session.live_playing)
        self.assertTrue(session.suspended)
        session.resume_from_mini_bar()
        self.assertTrue(session.live_playing)

    def test_tab_switch_still_suspends_before_the_tab_changes(self):
        session = LiveNavigationSession()
        session.select_tab(2)
        self.assertFalse(session.live_playing)
        self.assertEqual(session.suspend_reason, "left_live_interface")

    def test_vod_start_still_releases_the_live_owner(self):
        session = LiveNavigationSession()
        session.vod_will_start()
        self.assertFalse(session.live_playing)
        self.assertEqual(session.suspend_reason, "vod_playback_starting")

    def test_push_from_a_non_live_tab_does_not_touch_live(self):
        session = LiveNavigationSession()
        session.active_tab = 2
        session.will_show("config")
        session.did_show("config")
        self.assertTrue(session.live_playing)

    def test_second_push_while_suspended_is_a_no_op(self):
        session = LiveNavigationSession()
        session.will_show("config")
        session.did_show("config")
        session.will_show("config")
        session.did_show("config")
        self.assertTrue(session.suspended)


# ---------------------------------------------------------------------------
# 行为模型：U04 直播全屏方向
# ---------------------------------------------------------------------------


def live_orientation_mask(fullscreen):
    # 复刻 RootViewController.supportedInterfaceOrientations。
    return "AllButUpsideDown" if fullscreen else "Portrait"


class LiveFullscreenOrientation:
    def __init__(self):
        self.fullscreen = False
        self.rotation_requests = 0

    def toggle(self):
        # 复刻 toggleFullscreen：翻转全屏态后请求系统重算方向。
        self.fullscreen = not self.fullscreen
        self.rotation_requests += 1


class LiveFullscreenOrientationModelTests(unittest.TestCase):
    def test_live_is_portrait_until_fullscreen(self):
        self.assertEqual(live_orientation_mask(False), "Portrait")

    def test_fullscreen_allows_landscape(self):
        self.assertEqual(live_orientation_mask(True), "AllButUpsideDown")

    def test_exiting_fullscreen_restores_portrait(self):
        player = LiveFullscreenOrientation()
        player.toggle()
        self.assertTrue(player.fullscreen)
        self.assertEqual(live_orientation_mask(player.fullscreen), "AllButUpsideDown")
        player.toggle()
        self.assertFalse(player.fullscreen)
        self.assertEqual(live_orientation_mask(player.fullscreen), "Portrait")
        self.assertEqual(player.rotation_requests, 2)


# ---------------------------------------------------------------------------
# 行为模型：U06 锁按钮语义
# ---------------------------------------------------------------------------


def lock_button_announcement(locked):
    """复刻 toggleGestureLock 写入的无障碍状态与副作用。"""
    return {
        "value": "已锁定" if locked else "未锁定",
        "hint": "点按解锁画面手势" if locked else "点按锁定画面手势",
        "selected_trait": locked,
        "control_panel_interactive": not locked,
        "control_panel_hidden_from_voiceover": locked,
        "focus_target": "lock_button",
    }


def lock_button_spring_runs(locked, reduce_motion):
    """锁按钮弹跳与手势反馈出现动画都只在未减弱动态时跑。"""
    del locked  # 动画与锁态无关，只与减弱动态有关
    return not reduce_motion


class GestureLockSemanticsModelTests(unittest.TestCase):
    def test_unlocked_button_announces_itself_as_unlockable(self):
        state = lock_button_announcement(False)
        self.assertEqual(state["value"], "未锁定")
        self.assertEqual(state["hint"], "点按锁定画面手势")
        self.assertFalse(state["selected_trait"])
        self.assertTrue(state["control_panel_interactive"])
        self.assertFalse(state["control_panel_hidden_from_voiceover"])

    def test_locked_button_announces_locked_and_hides_controls_from_voiceover(self):
        state = lock_button_announcement(True)
        self.assertEqual(state["value"], "已锁定")
        self.assertEqual(state["hint"], "点按解锁画面手势")
        self.assertTrue(state["selected_trait"])
        self.assertFalse(state["control_panel_interactive"])
        self.assertTrue(state["control_panel_hidden_from_voiceover"])
        self.assertEqual(state["focus_target"], "lock_button")

    def test_reduce_motion_suppresses_both_spring_animations(self):
        self.assertFalse(lock_button_spring_runs(True, True))
        self.assertFalse(lock_button_spring_runs(False, True))
        self.assertTrue(lock_button_spring_runs(True, False))
        self.assertTrue(lock_button_spring_runs(False, False))


# ---------------------------------------------------------------------------
# 源码合同：U03/U04/U05/U06 接线
# ---------------------------------------------------------------------------


class RootNavigationContracts(unittest.TestCase):
    def test_will_show_never_releases_the_live_session(self):
        body = method_body(ROOT_SOURCE, WILL_SHOW)
        self.assertNotIn("suspendLivePlaybackForReason", body)
        self.assertIn("self.liveNavigationPushInFlight=YES", body)
        self.assertIn("self.liveNavigationPushInFlight=NO", body)

    def test_did_show_releases_only_a_completed_push_to_a_non_readonly_page(self):
        body = method_body(ROOT_SOURCE, DID_SHOW)
        self.assertIn("self.liveNavigationPushInFlight", body)
        self.assertIn(
            'if(self.activeTab<2&&![viewController isKindOfClass:EPGViewController.class])'
            '[self suspendLivePlaybackForReason:@"left_live_navigation_page"]',
            body,
        )

    def test_push_in_flight_flag_is_declared(self):
        self.assertIn(
            "@property (nonatomic, assign) BOOL liveNavigationPushInFlight;",
            INTERNAL_HEADER,
        )

    def test_tab_switch_and_vod_start_still_release_live_explicitly(self):
        self.assertIn(
            'suspendLivePlaybackForReason:@"left_live_interface"', ROOT_SOURCE
        )
        self.assertIn(
            'suspendLivePlaybackForReason:@"vod_playback_starting"', ROOT_SOURCE
        )

    def test_last_tab_is_restored(self):
        self.assertIn('cctv.lastBottomTab.v1', ROOT_SOURCE)

    def test_live_fullscreen_orientation_is_conditional(self):
        self.assertIn(
            "supportedInterfaceOrientations { return "
            "self.fullscreen?UIInterfaceOrientationMaskAllButUpsideDown:"
            "UIInterfaceOrientationMaskPortrait;",
            ROOT_SOURCE,
        )

    def test_toggle_fullscreen_requests_rotation(self):
        body = method_body(ROOT_SOURCE, "- (void)toggleFullscreen")
        self.assertIn("[UIViewController attemptRotationToDeviceOrientation]", body)
        self.assertIn('@"退出全屏"', body)
        self.assertIn('@"全屏"', body)

    def test_minimum_ios_is_17_everywhere_in_the_packaging_path(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        ci_build = (ROOT / "Scripts/ci-build.sh").read_text(encoding="utf-8")
        smoke = (ROOT / "Scripts/ui-smoke.sh").read_text(encoding="utf-8")
        self.assertIn('iOS: "17.0"', project)
        self.assertIn("--minimum-deployment-target 17.0", ci_build)
        self.assertIn("MinimumOSVersion 17.0", ci_build)
        self.assertIn("-miphoneos-version-min=17.0", ci_build)
        for text in (project, ci_build, smoke):
            self.assertNotIn("15.0", text)

    def test_lock_button_announces_state_and_hides_locked_controls(self):
        self.assertIn('self.screenLockButton.accessibilityValue=@"未锁定"', PLAYBACK_SOURCE)
        self.assertIn(
            'self.screenLockButton.accessibilityHint=@"点按锁定画面手势"',
            PLAYBACK_SOURCE,
        )
        body = method_body(PLAYBACK_SOURCE, "- (void)toggleGestureLock")
        self.assertIn('self.screenLockButton.accessibilityValue=self.gestureLockActive?@"已锁定":@"未锁定"', body)
        self.assertIn('self.screenLockButton.accessibilityHint=self.gestureLockActive?@"点按解锁画面手势":@"点按锁定画面手势"', body)
        self.assertIn("UIAccessibilityTraitSelected", body)
        self.assertIn(
            "self.controlPanel.accessibilityElementsHidden=self.gestureLockActive",
            body,
        )
        self.assertIn(
            "UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,self.screenLockButton)",
            body,
        )
        self.assertIn("UIAccessibilityIsReduceMotionEnabled()", body)

    def test_gesture_feedback_appear_animation_respects_reduce_motion(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)showGestureFeedback:(NSString *)text")
        self.assertIn("UIAccessibilityIsReduceMotionEnabled()", body)
        self.assertIn("usingSpringWithDamping:0.75", body)

    def test_overlay_stays_visible_while_voiceover_runs(self):
        self.assertIn("UIAccessibilityVoiceOverStatusDidChangeNotification", OVERLAY_SOURCE)
        self.assertIn("[self isVoiceOverRunning]?0.0:3.0", OVERLAY_SOURCE)


if __name__ == "__main__":
    unittest.main()
