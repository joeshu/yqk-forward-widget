"""Phase B P1 — 影视浏览信息架构空状态一致性契约测试。

审计发现 MediaFavoritesViewController 与 MediaWatchHistoryViewController 的
空状态标签此前缺少 Dynamic Type 缩放（preferredFontForTextStyle +
adjustsFontForContentSizeCategory）与稳定 accessibilityIdentifier。本轮阶段 C
将收藏/历史/全局搜索/TVBox/资源选择器(picker)空态统一迁移到 HostEmptyStateView，
对齐到同一套可访问性约定（动态字体由 helper 统一承担，各页只提供文案与标识符）。
本测试钉住该约定，避免回归。仅做源码文本断言，不编译、不依赖运行环境。
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
BROWSER = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")


def _slice(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]


def _method_body(source: str, signature: str) -> str:
    """Return the body (inside the outermost braces) of an ObjC method."""
    start = source.rindex(signature)
    opening = source.index("{", start)
    depth = 0
    for i in range(opening, len(source)):
        c = source[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise AssertionError(f"unterminated method: {signature}")


# Class implementation slices.
FAVORITES_IMPL = _slice(
    BROWSER,
    "@implementation MediaFavoritesViewController",
    "@interface MediaWatchHistoryViewController",
)
HISTORY_IMPL = _slice(
    BROWSER,
    "@implementation MediaWatchHistoryViewController",
    "@interface MediaHomeConfigurationViewController",
)
PICKER_IMPL = _slice(
    BROWSER,
    "@implementation MediaSourcePicker",
    "@interface MediaDetailViewController",
)


class MediaNavEmptyStateConsistency(unittest.TestCase):
    """收藏/历史空状态标签必须与资源选择器空状态采用同一套可访问性约定。"""

    def test_favorites_empty_state_uses_dynamic_type_and_identifier(self):
        body = _method_body(
            FAVORITES_IMPL,
            "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {",
        )
        # 空状态文本保持不变（语义不变）。
        self.assertIn("还没有收藏影视", body)
        self.assertIn("在影片详情页点按「收藏」即可保存", body)
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:@"还没有收藏影视" subtitle:@"在影片详情页点按「收藏」即可保存" symbol:@"heart"', body)
        self.assertIn('accessibilityIdentifier=@"media-favorites-empty"', body)
        helper = (SOURCES / "HostEmptyStateView.m").read_text(encoding="utf-8")
        self.assertIn("adjustsFontForContentSizeCategory = YES", helper)
        self.assertIn("isAccessibilityElement = YES", helper)

    def test_history_empty_state_uses_dynamic_type_and_identifier(self):
        body = _method_body(
            HISTORY_IMPL,
            "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {",
        )
        self.assertIn("还没有观看记录", body)
        self.assertIn("播放过的影片会保存在这里", body)
        self.assertIn('HostEmptyStateView emptyStateViewWithTitle:@"还没有观看记录" subtitle:@"播放过的影片会保存在这里" symbol:@"clock"', body)
        self.assertIn('accessibilityIdentifier=@"media-history-empty"', body)

    def test_picker_empty_state_uses_shared_helper(self):
        # picker 空态本轮已迁移到 HostEmptyStateView（与收藏/历史/全局搜索一致），
        # 但原文案来源（emptyMessageForQuery:）与触发条件（!self.shown.count）不变，
        # 标识符 media-picker-empty 保留以便 UI 自动化定位。
        body = _method_body(
            PICKER_IMPL,
            "- (void)updateSearchResultsForSearchController:(UISearchController *)controller {",
        )
        self.assertIn("[MediaBrowserQueryBuilder emptyMessageForQuery:query]", body)
        self.assertIn("if(!self.shown.count)", body)
        self.assertIn(
            'HostEmptyStateView emptyStateViewWithTitle:[MediaBrowserQueryBuilder emptyMessageForQuery:query] subtitle:nil symbol:nil',
            body,
        )
        self.assertIn('accessibilityIdentifier=@"media-picker-empty"', body)
        # 不再手写 UILabel 作为 backgroundView。
        self.assertNotIn("UILabel *empty=", body)

    def test_empty_state_identifiers_are_distinct(self):
        # 三个表格空状态标识符必须互不相同，避免 UISmoke/测试误匹配。
        ids = [
            'accessibilityIdentifier=@"media-favorites-empty"',
            'accessibilityIdentifier=@"media-history-empty"',
            'accessibilityIdentifier=@"media-picker-empty"',
        ]
        for identifier in ids:
            self.assertEqual(BROWSER.count(identifier), 1, f"{identifier} 应只在源中出现一次")
        # 不应再残留与 picker 重名的收藏/历史空状态标识符。
        self.assertNotIn('empty.accessibilityIdentifier=@"media-picker-empty";', FAVORITES_IMPL)
        self.assertNotIn('empty.accessibilityIdentifier=@"media-picker-empty";', HISTORY_IMPL)

    def test_list_pages_keep_clear_action_only_when_populated(self):
        # 空状态时不显示「清空」按钮（一致性：避免对空列表提供破坏性操作）。
        for impl, method in (
            (FAVORITES_IMPL, "- (void)reloadFavoriteEntries {"),
            (HISTORY_IMPL, "- (void)updateClearHistoryButton {"),
        ):
            body = _method_body(impl, method)
            self.assertIn("self.entries.count", body)
            self.assertIn('initWithTitle:@"清空"', body)


if __name__ == "__main__":
    unittest.main()
