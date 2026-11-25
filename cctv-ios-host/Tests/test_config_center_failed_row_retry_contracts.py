"""定向契约测试：ConfigCenter 失败行提供重试——失败行点开动作表时内联透出错误状态，并以“重试刷新”显式提供重试入口。

仅静态源码断言，不编译、不联网、不跑 CI。覆盖 ConfigCenterViewController.m 的最小低 risk 改动。
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CAT = (ROOT / "Sources" / "ConfigCenterViewController.m").read_text(encoding="utf-8")


class ConfigCenterFailedRowRetryContracts(unittest.TestCase):
    def _did_select_body(self):
        return CAT.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1].split(
            "- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView\n    trailingSwipeActionsConfigurationForRowAtIndexPath:", 1
        )[0]

    def test_failed_row_detection_in_tap_sheet(self):
        body = self._did_select_body()
        self.assertIn('rowStatus=[profile[@"status"]', body)
        self.assertIn('containsString:@"失败"', body)
        self.assertIn('containsString:@"异常"', body)
        self.assertIn('containsString:@"错误"', body)
        self.assertIn("BOOL failed=", body)

    def test_failed_row_offers_explicit_retry_action(self):
        body = self._did_select_body()
        # 失败时标题变为“重试刷新”，非失败仍为“刷新此订阅”
        self.assertIn('failed?@"重试刷新":@"刷新此订阅"', body)
        self.assertIn('failed?@"上次刷新失败，重新拉取最新频道列表"', body)

    def test_failed_row_subtitle_surfaces_error_status(self):
        body = self._did_select_body()
        self.assertIn("failed&&rowStatus.length", body)

    def test_non_failed_refresh_label_and_existing_contract_preserved(self):
        # 既有契约 test_root_view_controller_contracts 断言 “刷新此订阅” 仍存在
        self.assertIn("刷新此订阅", CAT)
        # 既有 swipe / context-menu 重试入口未被移除
        self.assertIn("onRefreshProfile", CAT)

    def test_swipe_and_context_menu_retry_entries_unchanged(self):
        # 失败行原有的左滑“刷新”、长按菜单“刷新此订阅”仍提供重试入口
        leading = CAT.split("leadingSwipeActionsConfigurationForRowAtIndexPath:", 1)[1].split(
            "- (UIContextMenuConfiguration *)tableView:", 1
        )[0]
        self.assertIn('title:@"刷新"', leading)
        ctx = CAT.split("- (UIContextMenuConfiguration *)tableView:", 1)[1]
        self.assertIn("刷新此订阅", ctx)


if __name__ == "__main__":
    unittest.main()
