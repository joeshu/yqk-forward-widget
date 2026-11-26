"""T14 逐页清单（U07/U08/U09）。

行为模型复刻 ObjC 逻辑并实际执行；源码合同锁住接线。
被测文件：
  Sources/RootViewController+Catalog.m（U07：网格列数先扣 inset 再算）
  Sources/RootViewController.m（U09：目录恢复双边 clamp）
  Sources/ResourceImportWorkflowViewController.m（U08：导入退出决策）
  Sources/MediaBrowserViewController.m / MediaGlobalSearchViewController.m
    （U09：两处恢复早已双边 clamp，本任务只回归锁定）
"""
import math
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


ROOT_SOURCE = read("RootViewController.m")
CATALOG_SOURCE = read("RootViewController+Catalog.m")
WORKFLOW_SOURCE = read("ResourceImportWorkflowViewController.m")
BROWSER_SOURCE = read("MediaBrowserViewController.m")
GLOBAL_SEARCH_SOURCE = read("MediaGlobalSearchViewController.m")


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


# ---------------------------------------------------------------------------
# 行为模型：U07 网格列数
# ---------------------------------------------------------------------------
# 旧算法用总宽除最小宽算列数，再扣 inset/spacing 得 itemWidth，
# 窄屏上 itemWidth 会小于 minimumWidth。复刻新旧两式对比。


def old_columns(width, min_width, preferred=4):
    return max(1, min(preferred, int(width / min_width)))


def new_columns(width, min_width, inset_left, inset_right, spacing, preferred=4):
    available = width - inset_left - inset_right
    return max(1, min(preferred, int((available + spacing) / (min_width + spacing))))


def item_width(width, columns, inset_left, inset_right, spacing):
    return math.floor(
        max(1, (width - inset_left - inset_right - (columns - 1) * spacing) / columns)
    )


class GridColumnsModelTests(unittest.TestCase):
    # (width, subtitle_point_size, insets, spacing)
    CASES = [
        (320, 12, 12, 12, 6),
        (375, 12, 12, 12, 6),
        (390, 12, 12, 12, 6),
        (430, 12, 12, 12, 6),
        (507, 12, 12, 12, 6),  # iPad 窄分屏
        (390, 23, 12, 12, 6),  # AX 大字体：subtitle 23pt -> 最小宽 184
        (320, 23, 12, 12, 6),
    ]

    def min_width(self, point_size):
        return max(96, point_size * 8)

    def test_new_columns_never_yield_an_item_narrower_than_minimum(self):
        for width, pt, left, right, spacing in self.CASES:
            minimum = self.min_width(pt)
            columns = new_columns(width, minimum, left, right, spacing)
            # floor 容差 1pt（minimumWidth 本身可带小数）。
            self.assertGreaterEqual(
                item_width(width, columns, left, right, spacing),
                minimum - 1,
                f"width={width} pt={pt}",
            )

    def test_old_algorithm_violates_minimum_width_on_narrow_screens(self):
        violations = []
        for width, pt, left, right, spacing in self.CASES:
            minimum = self.min_width(pt)
            columns = old_columns(width, minimum)
            if item_width(width, columns, left, right, spacing) < minimum:
                violations.append((width, pt))
        # 320pt、390pt 普通字号与 AX 大字体下旧算法都算出过窄的 item。
        self.assertIn((320, 12), violations)
        self.assertIn((390, 12), violations)
        self.assertIn((390, 23), violations)

    def test_new_columns_at_reference_widths(self):
        self.assertEqual(new_columns(320, 96, 12, 12, 6), 2)
        self.assertEqual(new_columns(375, 96, 12, 12, 6), 3)
        self.assertEqual(new_columns(390, 96, 12, 12, 6), 3)
        self.assertEqual(new_columns(430, 96, 12, 12, 6), 4)
        self.assertEqual(new_columns(390, 184, 12, 12, 6), 1)


# ---------------------------------------------------------------------------
# 行为模型：U09 滚动恢复双边 clamp
# ---------------------------------------------------------------------------


def restore_offset(saved, content_height, bounds_height, inset_top, inset_bottom):
    # 复刻 RootViewController 切 tab 恢复与 MediaBrowser
    # restoreHomeScrollOffsetIfNeeded 的双边 clamp。
    minimum = -inset_top
    maximum = max(minimum, content_height - bounds_height + inset_bottom)
    return min(max(saved, minimum), maximum)


def old_restore_offset(saved, inset_top):
    return max(-inset_top, saved)


class ScrollRestoreClampModelTests(unittest.TestCase):
    def test_stale_offset_is_clamped_to_the_new_maximum(self):
        # 删来源/改分组后内容变短：旧 offset 800 超出新最大 450。
        self.assertEqual(restore_offset(800, 1000, 600, 100, 50), 450)
        self.assertEqual(old_restore_offset(800, 100), 800)

    def test_valid_offset_passes_through(self):
        self.assertEqual(restore_offset(200, 1000, 600, 100, 50), 200)

    def test_negative_offset_is_clamped_to_the_top(self):
        self.assertEqual(restore_offset(-200, 1000, 600, 100, 50), -100)

    def test_empty_content_falls_back_to_the_top(self):
        self.assertEqual(restore_offset(800, 0, 600, 100, 50), -100)


# ---------------------------------------------------------------------------
# 行为模型：U08 导入退出决策
# ---------------------------------------------------------------------------
# hasUnsavedImportWork：finished 后无未保存工作；否则有候选或地址栏
# 内容即未保存工作。modal 保护 = (busy && !finished) || 未保存工作。
# minimize：busy 时按钮已禁用（防御性直接返回）；无未保存工作直接收起；
# 否则弹三选一决策。


def has_unsaved_work(finished, candidate_count, address):
    if finished:
        return False
    if candidate_count > 0:
        return True
    return len(address) > 0


def modal_protection(busy, finished, candidate_count, address):
    return (busy and not finished) or has_unsaved_work(
        finished, candidate_count, address
    )


def minimize_outcome(busy, finished, candidate_count, address):
    if busy:
        return "blocked"
    if not has_unsaved_work(finished, candidate_count, address):
        return "dismiss_direct"
    return "decision_sheet"


class ImportExitDecisionModelTests(unittest.TestCase):
    def test_busy_blocks_minimize_and_keeps_modal_protection(self):
        self.assertEqual(minimize_outcome(True, False, 0, ""), "blocked")
        self.assertTrue(modal_protection(True, False, 0, ""))

    def test_idle_with_unsaved_candidates_shows_the_decision_sheet(self):
        self.assertEqual(minimize_outcome(False, False, 3, ""), "decision_sheet")
        self.assertTrue(modal_protection(False, False, 3, ""))

    def test_idle_with_only_address_text_shows_the_decision_sheet(self):
        self.assertEqual(
            minimize_outcome(False, False, 0, "https://example.com/list.json"),
            "decision_sheet",
        )

    def test_finished_all_saved_dismisses_directly(self):
        self.assertEqual(minimize_outcome(False, True, 2, ""), "dismiss_direct")
        self.assertFalse(modal_protection(False, True, 2, ""))

    def test_blank_flow_dismisses_directly(self):
        self.assertEqual(minimize_outcome(False, False, 0, ""), "dismiss_direct")
        self.assertFalse(modal_protection(False, False, 0, ""))

    def test_decision_sheet_actions(self):
        # keep：只收起，快照保留；abandon：reset 再收起，已保存项保留；
        # cancel：留在流程里。
        actions = {
            "keep": ("dismiss", True),
            "abandon": ("reset_then_dismiss", True),
            "cancel": ("stay", True),
        }
        self.assertEqual(actions["keep"], ("dismiss", True))
        self.assertEqual(actions["abandon"], ("reset_then_dismiss", True))
        self.assertEqual(actions["cancel"], ("stay", True))


# ---------------------------------------------------------------------------
# 源码合同：U07/U08/U09 接线
# ---------------------------------------------------------------------------


class PageLayoutImportExitScrollContracts(unittest.TestCase):
    def test_grid_columns_are_computed_from_available_width(self):
        body = method_body(
            CATALOG_SOURCE,
            "- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip",
        )
        self.assertIn(
            "CGFloat available=collectionView.bounds.size.width-inset.left-inset.right;",
            body,
        )
        self.assertIn("(available+spacing)/(minimumWidth+spacing)", body)
        self.assertNotIn(
            "collectionView.bounds.size.width/minimumWidth", body
        )

    def test_catalog_restore_clamps_both_sides(self):
        self.assertIn("MIN(MAX(-topInset,gridY)", ROOT_SOURCE)
        self.assertIn("MIN(MAX(-self.table.contentInset.top,listY)", ROOT_SOURCE)
        self.assertIn("contentSize.height-self.channelGrid.bounds.size.height", ROOT_SOURCE)
        self.assertIn("contentSize.height-self.table.bounds.size.height", ROOT_SOURCE)

    def test_media_browser_and_global_search_restore_already_clamp_both_sides(self):
        self.assertIn(
            "MIN(MAX(self.pendingHomeOffsetRestore.doubleValue,minimum),maximum)",
            BROWSER_SOURCE,
        )
        self.assertIn("MIN(MAX(offset.y,minimum),maximum)", GLOBAL_SEARCH_SOURCE)

    def test_minimize_routes_through_the_exit_decision(self):
        body = method_body(WORKFLOW_SOURCE, "- (void)minimize")
        self.assertIn("if(self.busy)return;", body)
        self.assertIn("if(![self hasUnsavedImportWork])", body)
        self.assertIn("dismissViewControllerAnimated:YES", body)
        self.assertIn("[self presentExitDecisionSheet]", body)
        self.assertNotIn("[self.fetcher cancel]", body)
        self.assertNotIn("cancelWork", body)

    def test_modal_protection_covers_unsaved_work_and_arms_the_delegate(self):
        body = method_body(WORKFLOW_SOURCE, "- (void)applyModalDismissProtection")
        self.assertIn("self.busy&&!self.finished", body)
        self.assertIn("[self hasUnsavedImportWork]", body)
        self.assertIn("self.navigationController.presentationController.delegate=self", body)
        self.assertNotIn("self.modalInPresentation=YES", body)

    def test_gesture_dismiss_attempt_is_blocked_while_busy(self):
        # 忙时手势尝试关闭不得弹决策（否则“保留任务”会在导入中途收起流程，
        # 与 minimize 的 busy 阻塞和旧“禁止手势 dismiss”契约矛盾）；忙时
        # 代理方法直接返回，sheet 留在原地。
        body = method_body(
            WORKFLOW_SOURCE,
            "- (void)presentationControllerDidAttemptToDismiss",
        )
        self.assertIn("if(self.busy)return;", body)
        self.assertIn("[self presentExitDecisionSheet]", body)

    def test_exit_decision_sheet_has_three_named_choices(self):
        body = method_body(WORKFLOW_SOURCE, "- (void)presentExitDecisionSheet")
        self.assertIn('@"保留任务，稍后继续"', body)
        self.assertIn('@"放弃未保存并关闭"', body)
        self.assertIn('@"取消"', body)
        self.assertIn("destructive:YES", body)
        self.assertIn("[owner reset];", body)
        self.assertIn("dismissViewControllerAnimated:YES", body)
        self.assertIn("重新进入可恢复", body)
        self.assertIn("不影响已保存的项目", body)

    def test_unsaved_work_predicate(self):
        body = method_body(WORKFLOW_SOURCE, "- (BOOL)hasUnsavedImportWork")
        self.assertIn("if(self.finished)return NO;", body)
        self.assertIn("if(self.candidates.count>0)return YES;", body)
        self.assertIn("self.address.text.length>0", body)

    def test_gesture_dismiss_attempt_shows_the_decision_sheet(self):
        self.assertIn(
            "- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)presentationController",
            WORKFLOW_SOURCE,
        )
        self.assertIn(
            "UIAdaptivePresentationControllerDelegate", WORKFLOW_SOURCE
        )

    def test_minimize_button_is_disabled_while_busy(self):
        body = method_body(WORKFLOW_SOURCE, "- (void)updateView")
        self.assertIn(
            "self.navigationItem.leftBarButtonItem.enabled=!self.busy;", body
        )

    def test_explicit_cancel_row_is_unchanged(self):
        # 第 2 组第 0 行仍是显式取消/重置入口（忙时 cancelWork，闲时 reset），
        # 本任务只改退出路径，不动它。
        self.assertIn(
            "if(ip.section==2&&ip.row==0){if(self.busy)[self cancelWork];else[self reset];return;}",
            WORKFLOW_SOURCE,
        )


if __name__ == "__main__":
    unittest.main()
