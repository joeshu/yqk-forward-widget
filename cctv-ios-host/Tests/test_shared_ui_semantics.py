"""T12 公共语义组件（U01/U02）。

行为模型复刻 ObjC 逻辑并实际执行；源码合同锁住接线。
被测文件：
  Sources/HostEmptyStateView.m/.h（U01：空态 CTA 语义拆分）
  Sources/HostGlassActionSheetViewController.m（U02：chip/关闭/单次触发）
  Sources/CCTVLiveControlSheetViewController.m（U02：睡眠 chip/关闭）
  Sources/RootViewController.m（U02：mini bar 命中与大字号两行）
"""
import math
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 行为模型：U01 空态无障碍语义拆分
# ---------------------------------------------------------------------------

def empty_state_elements(title, subtitle, action_visible):
    """复刻 HostEmptyStateView._updateAccessibility 的新语义。

    返回 VoiceOver 会遍历到的元素表：(角色, 朗读内容)。
    容器本身不是元素；标题行承载合并文案（静态文本）；按钮独立暴露。
    """
    parts = [p for p in (title, subtitle) if p]
    combined = "，".join(parts) if parts else "空状态"
    elements = [("static_text", combined)]
    if action_visible:
        elements.append(("button", None))  # 按钮按自身标题朗读
    return elements


class EmptyStateSemanticsModelTests(unittest.TestCase):
    def test_static_empty_reads_merged_text_once(self):
        self.assertEqual(
            empty_state_elements("还没有收藏影视", "在影片详情页点按「收藏」即可保存", False),
            [("static_text", "还没有收藏影视，在影片详情页点按「收藏」即可保存")],
        )

    def test_action_empty_exposes_real_button_besides_static_text(self):
        elements = empty_state_elements("加载失败", "请检查网络后重试", True)
        self.assertEqual(elements[0], ("static_text", "加载失败，请检查网络后重试"))
        self.assertEqual(elements[1][0], "button")

    def test_subtitle_only_and_empty_fallback(self):
        self.assertEqual(
            empty_state_elements("", "请修改搜索词", False),
            [("static_text", "请修改搜索词")],
        )
        self.assertEqual(
            empty_state_elements("", "", False), [("static_text", "空状态")]
        )

    def test_container_is_never_an_element(self):
        # 模型里容器从不出现：旧实现把容器标成按钮却无激活路径，
        # VoiceOver 双击无法触发真实按钮（U01 缺口）。
        for title, subtitle, action in [
            ("A", "B", True),
            ("A", None, False),
            ("", "", True),
        ]:
            roles = [r for r, _ in empty_state_elements(title, subtitle, action)]
            self.assertNotIn("container_button", roles)


def action_tap_fires_once(hidden, enabled, has_handler, taps=3):
    """复刻 _actionTapped 的单次触发守卫：隐藏/禁用/无回调不触发。"""
    fires = 0
    for _ in range(taps):
        if hidden or not enabled or not has_handler:
            continue
        fires += 1
    return fires


class EmptyStateSingleFireModelTests(unittest.TestCase):
    def test_visible_enabled_handler_fires_each_tap(self):
        self.assertEqual(action_tap_fires_once(False, True, True), 3)

    def test_hidden_disabled_or_no_handler_never_fires(self):
        self.assertEqual(action_tap_fires_once(True, True, True), 0)
        self.assertEqual(action_tap_fires_once(False, False, True), 0)
        self.assertEqual(action_tap_fires_once(False, True, False), 0)


# ---------------------------------------------------------------------------
# 行为模型：U02 chip 选择、换行、单次触发
# ---------------------------------------------------------------------------

CHIP_MIN_HIT = 44
CHIP_ROW_MAX = 4


def chip_rows(n):
    """复刻 makeChipRowCard 的分行：每行最多 4 个 chip。"""
    return [min(CHIP_ROW_MAX, n - start) for start in range(0, n, CHIP_ROW_MAX)]


def chip_width(available_width, n_in_row, spacing=8):
    return (available_width - spacing * (n_in_row - 1)) / n_in_row


class ChipLayoutModelTests(unittest.TestCase):
    def test_rows_chunked_at_four(self):
        self.assertEqual(chip_rows(3), [3])
        self.assertEqual(chip_rows(4), [4])
        self.assertEqual(chip_rows(5), [4, 1])  # 快退 5 芯片：4+1 两行
        self.assertEqual(chip_rows(8), [4, 4])

    def test_chunked_row_keeps_44pt_hit_at_320pt(self):
        # 320pt 屏、左右 inset 16 → 可用 288pt；4 个一行仍有 66pt 宽。
        for row in chip_rows(5):
            self.assertGreaterEqual(chip_width(288, row), CHIP_MIN_HIT)

    def test_unchunked_five_would_squeeze_but_stay_above_44(self):
        # 旧单行 5 个在 320pt 下是 51.2pt——宽度尚可，但大字号标题仍挤；
        # 分行是为动态字体留余量，不是为修宽度下限。
        self.assertGreaterEqual(chip_width(288, 5), CHIP_MIN_HIT)


class SleepChipModelTests(unittest.TestCase):
    """睡眠 0/15/30/60：同一时刻只有一个 selected；已选再点不回调。"""

    def setUp(self):
        self.selected = 0
        self.callbacks = []

    def tap(self, minutes):
        if minutes == self.selected:
            return  # 已选再点：不重复回调
        self.selected = minutes
        self.callbacks.append(minutes)

    def test_single_selection_invariant(self):
        for m in (15, 30, 60, 0, 30):
            self.tap(m)
            selected_count = sum(1 for v in (0, 15, 30, 60) if v == self.selected)
            self.assertEqual(selected_count, 1)
        self.assertEqual(self.callbacks, [15, 30, 60, 0, 30])

    def test_retap_selected_fires_no_callback(self):
        self.tap(30)
        self.tap(30)
        self.tap(30)
        self.assertEqual(self.callbacks, [30])


def sheet_action_dispatch(taps):
    """复刻 runActionControl 的 actionDispatched 守卫。"""
    dispatched = False
    runs = 0
    for _ in taps:
        if dispatched:
            continue
        dispatched = True
        runs += 1
    return runs


class SheetSingleFireModelTests(unittest.TestCase):
    def test_rapid_double_tap_runs_handler_once(self):
        self.assertEqual(sheet_action_dispatch(["tap", "tap"]), 1)
        self.assertEqual(sheet_action_dispatch(["tap"]), 1)


# ---------------------------------------------------------------------------
# 行为模型：U02 mini bar 布局
# ---------------------------------------------------------------------------

def mini_bar_layout(accessibility_category):
    """复刻 RootViewController.m:1312 的 mini bar 布局。

    48pt 高、两按钮 44×44、标签大字号两行；底部 inset 48+8=56。
    """
    return {
        "height": 48,
        "close": (44, 44),
        "resume": (88, 44),
        "label_lines": 2 if accessibility_category else 1,
        "bottom_inset": 56,
    }


class MiniBarLayoutModelTests(unittest.TestCase):
    def test_normal_size_single_line_44pt_buttons(self):
        layout = mini_bar_layout(False)
        self.assertEqual(layout["height"], 48)
        self.assertEqual(layout["close"], (44, 44))
        self.assertEqual(layout["resume"], (88, 44))
        self.assertEqual(layout["label_lines"], 1)
        self.assertEqual(layout["bottom_inset"], 56)

    def test_accessibility_size_label_wraps_to_two_lines(self):
        layout = mini_bar_layout(True)
        self.assertEqual(layout["label_lines"], 2)
        self.assertEqual(layout["height"], 48)


# ---------------------------------------------------------------------------
# 源码合同
# ---------------------------------------------------------------------------

class EmptyStateContracts(unittest.TestCase):
    def setUp(self):
        self.m = read("HostEmptyStateView.m")

    def test_container_not_accessibility_element(self):
        body = self.m[self.m.index("- (void)_updateAccessibility"):]
        self.assertIn("self.isAccessibilityElement = NO", body)
        self.assertIn("_titleLabel.isAccessibilityElement = YES", body)
        self.assertIn("_actionButton.isAccessibilityElement = YES", body)

    def test_action_tap_guarded_single_fire(self):
        body = self.m[self.m.index("- (void)_actionTapped"):]
        self.assertIn("_actionButton.hidden", body)
        self.assertIn("!_actionButton.enabled", body)
        self.assertIn("!self.onAction", body)


class GlassSheetContracts(unittest.TestCase):
    def setUp(self):
        self.m = read("HostGlassActionSheetViewController.m")

    def test_chips_have_selected_semantics_and_44pt(self):
        body = self.m[self.m.index("- (UIView *)makeChipRowCard:"):]
        self.assertIn("UIAccessibilityTraitSelected", body)
        self.assertIn("accessibilityValue = action.value", body)
        self.assertIn("accessibilityHint = action.subtitle", body)
        self.assertIn("constraintGreaterThanOrEqualToConstant:44", body)

    def test_chips_wrap_at_four_per_row(self):
        body = self.m[self.m.index("- (UIView *)makeChipRowCard:"):]
        self.assertIn("NSUInteger chunk = 4", body)
        self.assertIn("MIN(actions.count, start + chunk)", body)

    def test_close_hit_area_44_visual_30(self):
        self.assertIn("closeHit", self.m)
        self.assertIn("[closeHit.widthAnchor constraintEqualToConstant:44]", self.m)
        self.assertIn("[closeHit.heightAnchor constraintEqualToConstant:44]", self.m)
        self.assertIn("[closeBtn.widthAnchor constraintEqualToConstant:30]", self.m)
        self.assertIn("closeBtn.userInteractionEnabled = NO", self.m)

    def test_action_dispatch_guarded_once(self):
        self.assertIn("actionDispatched", self.m)
        body = self.m[self.m.index("- (void)runActionControl:"):]
        self.assertIn("if (self.actionDispatched) return;", body)
        self.assertIn("self.actionDispatched = YES;", body)


class LiveControlSheetContracts(unittest.TestCase):
    def setUp(self):
        self.m = read("CCTVLiveControlSheetViewController.m")

    def test_sleep_chips_44pt_with_selected_traits(self):
        self.assertIn("constraintGreaterThanOrEqualToConstant:44", self.m)
        body = self.m[self.m.index("- (void)updateSleepChipSelection"):]
        self.assertIn("UIAccessibilityTraitSelected", body)
        self.assertIn('accessibilityValue = active ? @"已选择" : nil', body)

    def test_sleep_retap_selected_is_noop(self):
        body = self.m[self.m.index("- (void)sleepChipTapped:"):]
        self.assertIn("if (sender.tag == self.sleepMinutes) return;", body)

    def test_close_hit_area_44_visual_30(self):
        self.assertIn("[closeHit.widthAnchor constraintEqualToConstant:44]", self.m)
        self.assertIn("[closeBtn.widthAnchor constraintEqualToConstant:30]", self.m)


class MiniBarContracts(unittest.TestCase):
    def test_mini_bar_48pt_44pt_buttons_two_line_label(self):
        rvc = read("RootViewController.m")
        self.assertIn("miniH=48", rvc)
        self.assertIn("CGRectMake(miniW-46,2,44,44)", rvc)
        self.assertIn("CGRectMake(miniW-142,2,88,44)", rvc)
        self.assertIn("numberOfLines=axLarge?2:1", rvc)
        self.assertIn("UIContentSizeCategoryIsAccessibilityCategory", rvc)
        self.assertIn("showMiniBar?56:0", rvc)


if __name__ == "__main__":
    unittest.main()
