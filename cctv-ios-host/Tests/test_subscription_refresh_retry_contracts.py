"""定向契约测试：订阅刷新失败时的内联错误与重试入口、loading 防重复、已有错误状态不被静默清除。

仅做静态源码断言，不编译、不联网、不跑 CI。覆盖 SubscriptionResourceViewController.m 的最小低 risk 改动。
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUB = (ROOT / "Sources" / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
ROOTVC = "\n".join(
    (ROOT / "Sources" / f).read_text(encoding="utf-8")
    for f in (
        "RootViewController+Subscriptions.m",
    )
)


class SubscriptionRefreshRetryContracts(unittest.TestCase):
    # --- loading 时防重复 -------------------------------------------------
    def test_refreshing_guard_property_exists(self):
        self.assertIn("@property(nonatomic) BOOL refreshing;", SUB)

    def test_begin_refresh_action_helper_guards_reentry(self):
        body = SUB.split("- (BOOL)beginRefreshActionWithPrompt:(NSString *)prompt {", 1)[1]
        body = body.split("\n- (void)loadFields", 1)[0]
        # 必须在 refreshing/saving 时拒绝第二次触发
        self.assertIn("if(self.refreshing||self.saving)return NO;", body)
        self.assertIn("self.refreshing=YES;", body)
        # on* 为 fire-and-forget，需有界兜底复位，避免刷新态永久锁住
        self.assertIn("dispatch_after", body)
        self.assertIn("owner.refreshing=NO;", body)

    def test_metadata_changed_releases_refreshing_lock(self):
        body = SUB.split("- (void)metadataChanged {", 1)[1].split("\n- (void)updateAction", 1)[0]
        self.assertIn("if(self.editingResource||self.saving||self.suppressMetadataReload)return;", body)
        self.assertIn("if(self.refreshing)self.refreshing=NO;", body)
        # 主线程收敛不应被破坏
        self.assertIn("if(!NSThread.isMainThread)", body)

    def test_handle_pull_refresh_uses_guard(self):
        body = SUB.split("- (void)handlePullRefresh {", 1)[1].split("\n- (void)viewDidLoad", 1)[0]
        self.assertIn("beginRefreshActionWithPrompt:", body)
        # 不应在未过 guard 的情况下直接无条件触发 onRefresh
        self.assertNotIn("if(self.onRefresh){\n        self.onRefresh();", body)

    # --- 已有错误状态不被静默清除 -----------------------------------------
    def test_refresh_actions_do_not_overwrite_notice(self):
        body = SUB.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        body = body.split("\n- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:", 1)[0]
        # 四个刷新类动作应统一过 guard，不再赋值 self.notice 旧文案
        self.assertIn('[action isEqual:@"refresh"]', body)
        self.assertIn('[action isEqual:@"recheck"]', body)
        self.assertIn('[action isEqual:@"rematch"]', body)
        self.assertIn('[action isEqual:@"matchLogos"]', body)
        for action in ("refresh", "recheck", "rematch", "matchLogos"):
            seg = body.split('[action isEqual:@"%s"]' % action, 1)[1].split("else if([action", 1)[0]
            self.assertIn("beginRefreshActionWithPrompt:", seg, f"{action} 未走 beginRefreshActionWithPrompt")
        # 旧的内联覆盖文案应被移除（不再静默清除已有 notice/错误）
        self.assertNotIn("self.notice=self.source.length?@\"刷新请求已发起\"", SUB)
        self.assertNotIn("self.notice=@\"已完成官方高清台标与节目单归一匹配\"", SUB)

    # --- 失败行/页提供内联错误 + 重试入口 --------------------------------
    def test_footer_surfaces_failure_status_as_inline_error(self):
        body = SUB.split("- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {", 1)[1]
        body = body.split("\n- (void)tableView:(UITableView *)tableView cellForRowAtIndexPath:", 1)[0]
        self.assertIn("self.cachedProfile", body)
        self.assertIn('containsString:@"失败"', body)
        self.assertIn('containsString:@"异常"', body)
        self.assertIn('containsString:@"错误"', body)
        # 默认文案仍保留
        self.assertIn("修改订阅地址会先读取新清单", body)

    def test_management_rows_keep_refresh_retry_entry(self):
        body = SUB.split("- (NSArray<NSDictionary *> *)managementRows", 1)[1].split("\n- (void)applyInPlaceSwitchFeedbackForRow:", 1)[0]
        self.assertIn('@"action":@"refresh"', body)
        self.assertIn("刷新此订阅", body)

    # --- 模型层去重未被破坏（不得改网络政策/远端服务） -------------------
    def test_model_layer_dedup_unchanged(self):
        self.assertIn("if(self.subscriptionTasks[sourceKey])", ROOTVC)
        self.assertIn("subscription_refresh_joined_existing", ROOTVC)
        # 失败仍写显式状态并保留上次频道
        self.assertIn("刷新失败", ROOTVC)
        self.assertIn("保留上次", ROOTVC)


if __name__ == "__main__":
    unittest.main()
