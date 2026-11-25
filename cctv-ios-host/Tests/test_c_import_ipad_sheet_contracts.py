"""Phase-C · c-import-ipad-sheet 定向契约测试

验证 ResourceImportWorkflowViewController 与其演示方（RootViewController+Subscriptions.m）
的 iPad sheet 适配，只读取源码文本断言契约，不触发构建/网络。

覆盖：
1. 演示方按 size-class 分流 modalPresentationStyle：
   regular → formSheet，compact → fullScreen；
2. viewDidLoad 配置 sheet detents / grabber / prefersEdgeAttachedInCompactHeight；
3. 键盘安全区：tableView.keyboardDismissMode + contentInsetAdjustmentBehavior；
4. isModalInPresentation 保护仍与 busy 绑定，在 updateView 刷新（回归）；
5. 显式取消语义（cancelWork / minimize / didSelectRow cancel 行）不变（回归）。

依据：Docs/PHASE-C-IMPORT-DISMISS-REPORT.md「为何未做 iPad sheet 适配」遗留项落实。
"""
import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class CImportIpadSheetContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = read_source("ResourceImportWorkflowViewController.m")
        cls.subs = read_source("RootViewController+Subscriptions.m")


class PresentationAdaptiveStyleTests(CImportIpadSheetContracts):
    # 1. 演示方 size-class 分流 --------------------------------------------------
    def test_subs_select_form_sheet_for_regular_width(self):
        # addSubscription 内演示方按 presenter.traitCollection.horizontalSizeClass 分流
        self.assertIn("horizontalSizeClass", self.subs)
        self.assertIn("UIModalPresentationFormSheet", self.subs)
        # regular 判定
        self.assertTrue(
            re.search(r"horizontalSizeClass\s*==\s*UIUserInterfaceSizeClassRegular", self.subs),
            "应检测 regular width 切换到 formSheet",
        )

    def test_subs_keeps_fullscreen_for_compact_width(self):
        # compact 仍走 fullScreen
        self.assertIn("UIModalPresentationFullScreen", self.subs)
        # 应存在三元或 if 分流，而非无条件 fullScreen
        self.assertIn("regularWidth", self.subs)

    def test_subs_uses_presenter_not_rootvc_directly(self):
        # 演示对象通过 presenter 变量引用 topViewController，确保 traitCollection 读取自正确的 VC
        self.assertIn("presenter.traitCollection", self.subs)
        self.assertIn("presenter presentViewController", self.subs)


class ViewDidLoadSheetConfigTests(CImportIpadSheetContracts):
    # 2. viewDidLoad sheet detents / grabber / edge-attached --------------------
    def test_sheet_detents_configured(self):
        self.assertIn("UISheetPresentationControllerDetent.mediumDetent", self.workflow)
        self.assertIn("UISheetPresentationControllerDetent.largeDetent", self.workflow)

    def test_grabber_visible(self):
        self.assertIn("prefersGrabberVisible=YES", self.workflow)

    def test_prefers_edge_attached_in_compact_height(self):
        # iPad 进入紧凑高度（分屏/横屏）时 sheet 锚底边而非全屏
        self.assertIn("prefersEdgeAttachedInCompactHeight=YES", self.workflow)

    def test_sheet_fetched_from_navigation_or_self(self):
        # 兼容 wrapped-in-nav 与直接呈现两种场景
        self.assertIn("self.navigationController.sheetPresentationController", self.workflow)


class KeyboardSafeAreaTests(CImportIpadSheetContracts):
    # 3. 键盘安全区 -------------------------------------------------------------
    def test_keyboard_dismiss_mode_preserved(self):
        self.assertIn("keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag", self.workflow)

    def test_content_inset_adjustment_behavior_explicit(self):
        # 显式声明自动 inset 调整，确保 sheet 下键盘不遮挡内容
        self.assertIn("contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentAutomatic", self.workflow)


class ModalDismissProtectionRegressionTests(CImportIpadSheetContracts):
    # 4. isModalInPresentation 回归 ---------------------------------------------
    def test_apply_modal_protection_bound_to_busy(self):
        self.assertIn("- (void)applyModalDismissProtection", self.workflow)
        guard = self._body("- (void)applyModalDismissProtection")
        self.assertIn("self.modalInPresentation", guard)
        self.assertIn("self.navigationController.modalInPresentation", guard)
        self.assertIn("self.busy&&!self.finished", guard)
        self.assertNotIn("self.modalInPresentation=YES", guard)

    def test_protection_refreshed_in_update_view(self):
        update = self._body("- (void)updateView")
        self.assertIn("[self applyModalDismissProtection]", update)

    # 5. 显式取消语义回归 -------------------------------------------------------
    def test_cancel_work_semantics_unchanged(self):
        cancel = self._body("- (void)cancelWork")
        self.assertLess(cancel.index("self.generation++"), cancel.index("[self.fetcher cancel]"))
        self.assertLess(cancel.index("[self.fetcher cancel]"), cancel.index("[self.downloader cancel]"))
        self.assertLess(cancel.index("[self.downloader cancel]"), cancel.index("self.busy=NO"))
        self.assertIn("任务已取消", cancel)

    def test_minimize_is_dismiss_not_cancel(self):
        minimize = self._body("- (void)minimize")
        self.assertIn("dismissViewControllerAnimated:YES", minimize)
        for forbidden in ("[self.fetcher cancel]", "[self.downloader cancel]", "self.generation++", "cancelWork"):
            self.assertNotIn(forbidden, minimize)

    def test_did_select_row_cancel_entry_preserved(self):
        self.assertIn("if(self.busy)[self cancelWork];else[self reset];", self.workflow)

    def _body(self, selector):
        before, _, rest = self.workflow.partition(selector)
        self.assertIn(selector, self.workflow, f"missing selector: {selector}")
        nxt = rest.find("\n- (")
        nxt2 = rest.find("\n-  (")
        cuts = [c for c in (nxt, nxt2) if c != -1]
        return rest[: min(cuts)] if cuts else rest


if __name__ == "__main__":
    unittest.main()
