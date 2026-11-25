import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class MediaBrowserQueryBuilderModularSplitTests(unittest.TestCase):
    """P3 模块化拆分：把 MediaSourcePicker 的纯搜索/过滤逻辑抽到
    Foundation-only 的 MediaBrowserQueryBuilder，降低 MediaBrowserViewController.m
    的复杂度并集中查询语义。"""

    @classmethod
    def setUpClass(cls):
        cls.browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        cls.header = (SOURCES / "MediaBrowserQueryBuilder.h").read_text(encoding="utf-8")
        cls.impl = (SOURCES / "MediaBrowserQueryBuilder.m").read_text(encoding="utf-8")

    def test_helper_header_and_implementation_exist(self):
        self.assertTrue((SOURCES / "MediaBrowserQueryBuilder.h").is_file())
        self.assertTrue((SOURCES / "MediaBrowserQueryBuilder.m").is_file())

    def test_helper_is_foundation_only(self):
        # 纯逻辑 helper 不得依赖 UIKit；只导入 Foundation。
        self.assertIn("#import <Foundation/Foundation.h>", self.header)
        self.assertNotIn("#import <UIKit", self.header)
        self.assertNotIn("#import <UIKit", self.impl)
        self.assertIn("@interface MediaBrowserQueryBuilder : NSObject", self.header)

    def test_helper_exposes_single_responsibility_api(self):
        for sel in (
            "+ (NSUInteger)choiceCountForScope:(NSString *)key choices:(NSArray<NSDictionary *> *)choices;",
            "+ (NSArray<NSDictionary *> *)filteredChoices:(NSArray<NSDictionary *> *)choices\n                                        query:(NSString *)query\n                                        scope:(NSString *)scope;",
            "+ (NSString *)emptyMessageForQuery:(NSString *)query;",
        ):
            self.assertIn(sel, self.header, f"missing API: {sel}")
        for impl in (
            "+ (NSUInteger)choiceCountForScope:",
            "+ (NSArray<NSDictionary *> *)filteredChoices:",
            "+ (NSString *)emptyMessageForQuery:",
        ):
            self.assertIn(impl, self.impl, f"missing implementation: {impl}")

    def test_helper_preserves_query_semantics(self):
        # 大小写/重音不敏感匹配 + scope 过滤 + 空 query 命中全部。
        self.assertIn("NSCaseInsensitiveSearch", self.impl)
        self.assertIn("NSDiacriticInsensitiveSearch", self.impl)
        self.assertIn('@"name", @"subtitle", @"url"', self.impl)
        self.assertIn('BOOL scopeAll = [activeScope isEqual:@"*"];', self.impl)
        self.assertIn('BOOL matches = ![normalizedQuery length];', self.impl)
        # 非字典条目被丢弃（与历史内联谓词一致）。
        self.assertIn("if (![choice isKindOfClass:NSDictionary.class]) continue;", self.impl)
        # 空状态文案保持不变。
        self.assertIn("没有匹配的选项，请修改或清除搜索词", self.impl)
        self.assertIn("当前分组暂无选项，请切换到全部", self.impl)

    def test_picker_delegates_filter_count_and_empty_message_to_helper(self):
        # 主控制器必须复用 helper，删除重复的内联谓词实现。
        self.assertIn('#import "MediaBrowserQueryBuilder.h"', self.browser)
        self.assertIn("[MediaBrowserQueryBuilder filteredChoices:self.choices", self.browser)
        self.assertIn("[MediaBrowserQueryBuilder choiceCountForScope:", self.browser)
        self.assertIn("[MediaBrowserQueryBuilder emptyMessageForQuery:", self.browser)

    def test_picker_no_longer_inlines_duplicate_filter_predicate(self):
        # updateSearchResultsForSearchController 不再内联 filteredArrayUsingPredicate 谓词；
        # MediaSourcePicker 内已无该重复实现。
        picker = self.browser.split("@implementation MediaSourcePicker", 1)[1].split("@end", 1)[0]
        self.assertNotIn("filteredArrayUsingPredicate:[NSPredicate predicateWithBlock", picker)

    def test_pinned_picker_contracts_remain_intact(self):
        # 既有的源码契约（type-check / scope pill 44pt 高度）不受拆分影响。
        lines = self.browser.splitlines()
        head = "\n".join(lines[:next(i for i, l in enumerate(lines) if l.startswith("@interface MediaDetailViewController"))])
        self.assertIn("if(![choice isKindOfClass:NSDictionary.class])continue;", head)
        self.assertIn('label=[choice[@"scopeName"] isKindOfClass:NSString.class]?choice[@"scopeName"]:nil', head)
        self.assertIn("constraintEqualToAnchor:header.topAnchor constant:4", head)
        self.assertNotIn("constraintEqualToAnchor:header.topAnchor constant:6", head)
        self.assertIn("if(index.row<0||index.row>=self.shown.count)return;", head)
        # 详情页模型逻辑未被触碰（契约仍禁止该命名 helper）。
        self.assertNotIn("MediaBrowserSanitizedDetail", self.browser)
        self.assertIn("MediaDetailPreferredTitle(", self.browser)


if __name__ == "__main__":
    unittest.main()
