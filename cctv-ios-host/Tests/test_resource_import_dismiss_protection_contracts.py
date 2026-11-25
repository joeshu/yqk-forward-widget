"""Phase-C 契约测试：ResourceImportWorkflowViewController 导入过程防误关闭。

只读取源码文本断言契约，不触发构建/网络。覆盖：
1. 导入进行中（busy）禁止手势/外部 dismiss —— isModalInPresentation 与 busy 绑定；
2. 显式取消语义（cancelWork）不变：generation++ → fetcher/downloader cancel → busy=NO；
3. minimize 仍是「收起面板」而非取消（不触发 cancel，仅 dismiss）；
4. 进度恢复（snapshot busy）restore 语义保留；
5. 保护在 updateView 中刷新，使 busy 状态翻转后立即生效。

依据：Docs/PHASE-C-UI-AUDIT.md §6/§9「返回逻辑薄弱点」与待办条目。
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceImportDismissProtectionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / 'Sources' / 'ResourceImportWorkflowViewController.m').read_text(encoding="utf-8")

    def _body(self, selector):
        before, _, rest = self.workflow.partition(selector)
        self.assertIn(selector, self.workflow)
        # 取该方法到下一个「- (」或文件末尾
        nxt = rest.find("\n- (")
        nxt2 = rest.find("\n-  (")
        cuts = [c for c in (nxt, nxt2) if c != -1]
        return rest[:min(cuts)] if cuts else rest

    # 1. 防误关闭保护存在且与 busy 绑定 -----------------------------------------
    def test_modal_in_presentation_guard_is_bound_to_busy(self):
        self.assertIn('- (void)applyModalDismissProtection', self.workflow)
        guard = self._body('- (void)applyModalDismissProtection')
        self.assertIn('self.isModalInPresentation', guard)
        self.assertIn('self.navigationController.isModalInPresentation', guard)
        self.assertIn('self.busy&&!self.finished', guard)
        # 保护必须在 updateView 内刷新，busy 翻转后即时生效
        update = self._body('- (void)updateView')
        self.assertIn('[self applyModalDismissProtection]', update)
        # 空闲态必须放开保护（modal=NO），否则完成态无法自动收起
        self.assertNotIn('self.isModalInPresentation=YES', guard)

    # 2. 显式取消语义不变 -------------------------------------------------------
    def test_explicit_cancel_semantics_unchanged(self):
        cancel = self._body('- (void)cancelWork')
        # 顺序：先失效 in-flight（generation++），再取消 fetcher/downloader，再清 busy
        self.assertLess(cancel.index('self.generation++'), cancel.index('[self.fetcher cancel]'))
        self.assertLess(cancel.index('[self.fetcher cancel]'), cancel.index('[self.downloader cancel]'))
        self.assertLess(cancel.index('[self.downloader cancel]'), cancel.index('self.busy=NO'))
        self.assertIn('任务已取消', cancel)
        self.assertIn('[self updateView]', cancel)

    # 3. minimize 是收起而非取消 -------------------------------------------------
    def test_minimize_is_hide_not_cancel(self):
        minimize = self._body('- (void)minimize')
        self.assertIn('dismissViewControllerAnimated:YES', minimize)
        # 收起动作本身不得直接触发取消/生成失效（取消只能经 cancelWork）
        for forbidden in ('[self.fetcher cancel]', '[self.downloader cancel]', 'self.generation++', 'cancelWork'):
            self.assertNotIn(forbidden, minimize, f"minimize 不应直接执行取消语义：发现 {forbidden}")

    # 4. 进度取消/恢复状态：snapshot busy 恢复语义保留 --------------------------
    def test_snapshot_busy_restore_semantics_preserved(self):
        self.assertIn('if([snapshot[@"busy"] boolValue])', self.workflow)
        # busy 中断后任务可重试：stage 提示重试未保存项（按 taskKind 分流）
        self.assertIn('上次保存中断 · 可重试未保存项目', self.workflow)
        self.assertIn('上次链接识别中断 · 点按识别链接重试', self.workflow)
        self.assertIn('上次本地识别中断 · 重新选择文件，或重试单项', self.workflow)
        # 实现体存在（区别于接口前向声明）
        self.assertIn('- (void)restoreSnapshot:(NSDictionary *)snapshot {', self.workflow)
        # 显式取消入口仍由 busy 行触发（section 2 row 0）
        self.assertIn('if(self.busy)[self cancelWork];else[self reset];', self.workflow)

    # 5. dealloc 仍取消在途网络任务（防泄漏），与 cancelWork 解耦 ---------------
    def test_dealloc_aborts_inflight_without_changing_cancel_semantics(self):
        dealloc = self._body('- (void)dealloc')
        self.assertIn('[self.fetcher cancel]', dealloc)
        self.assertIn('[self.downloader cancel]', dealloc)
        # dealloc 不写 stage/busy=NO（那是 cancelWork 的职责）
        self.assertNotIn('self.busy=NO', dealloc)
        self.assertNotIn('任务已取消', dealloc)


if __name__ == '__main__':
    unittest.main()
