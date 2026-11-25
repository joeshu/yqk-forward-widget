"""Phase B P1 — 影视浏览信息架构空状态一致性契约测试。

审计发现 MediaFavoritesViewController 与 MediaWatchHistoryViewController 的
空状态标签此前缺少 Dynamic Type 缩放（preferredFontForTextStyle +
adjustsFontForContentSizeCategory）与稳定 accessibilityIdentifier，与
MediaSourcePicker 的 media-picker-empty 空状态不一致。本次一致性修复把它们
对齐到与 picker/全局搜索空状态相同的约定。本测试钉住该约定，避免回归。
仅做源码文本断言，不编译、不依赖运行环境。
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
        # 与 picker/全局搜索一致的 Dynamic Type 约定。
        self.assertIn("empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];", body)
        self.assertIn("empty.adjustsFontForContentSizeCategory=YES;", body)
        self.assertIn("empty.numberOfLines=0;", body)
        self.assertIn("empty.textColor=HostSecondaryText();", body)
        # 稳定可访问性标识，便于 UISmoke/VoiceOver 定位。
        self.assertIn('empty.accessibilityIdentifier=@"media-favorites-empty";', body)

    def test_history_empty_state_uses_dynamic_type_and_identifier(self):
        body = _method_body(
            HISTORY_IMPL,
            "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {",
        )
        self.assertIn("还没有观看记录", body)
        self.assertIn("播放过的影片会保存在这里", body)
        self.assertIn("empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];", body)
        self.assertIn("empty.adjustsFontForContentSizeCategory=YES;", body)
        self.assertIn("empty.numberOfLines=0;", body)
        self.assertIn("empty.textColor=HostSecondaryText();", body)
        self.assertIn('empty.accessibilityIdentifier=@"media-history-empty";', body)

    def test_picker_empty_state_remains_the_reference_convention(self):
        # picker 是本次对齐的参照基准：必须仍具备 Body 字号 + 缩放 + 标识符。
        body = _method_body(
            PICKER_IMPL,
            "- (void)updateSearchResultsForSearchController:(UISearchController *)controller {",
        )
        self.assertIn("[UIFont preferredFontForTextStyle:UIFontTextStyleBody]", body)
        self.assertIn("empty.adjustsFontForContentSizeCategory=YES;", body)
        self.assertIn('empty.accessibilityIdentifier=@"media-picker-empty";', body)

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
