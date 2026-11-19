import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round20ChannelTabSubpagesAndMenusRefactorTests(unittest.TestCase):
    def test_01_live_resource_capsule_inline_sections_and_protocol_icons(self):
        subs = (SOURCES / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        for token in (
            '@"live.resource.section.scope"',
            '@"live.resource.section.sources"',
            '@"live.resource.section.actions"',
            '@"live.resource.add"',
            '@"live.resource.manage"',
            '@"live.resource.refresh"',
            "UIMenuOptionsDisplayInline",
            '@"line.3.horizontal.decrease.circle.fill"',
        ):
            self.assertIn(token, subs)

    def test_02_subscription_submenus_and_preview_box_refinements(self):
        subs = (SOURCES / "RootViewController+Subscriptions.m").read_text(encoding="utf-8")
        for token in (
            '@"订阅源管理"',
            '@"查看与编辑资源详情"',
            '@"添加新订阅源"',
            '@"恢复自动匹配"',
            '@"备用源 %lu · %@ (%@)"',
            '@"channel.preview.box"',
            '@"channel.preview.badge"',
            '@"channel.preview.close"',
            "CGFloat previewWidth=MIN(280,self.view.bounds.size.width-32);",
            "close.frame=CGRectMake(MAX(0,previewWidth-100),0,MIN(100,previewWidth),44);",
        ):
            self.assertIn(token, subs)

    def test_03_channel_list_context_menu_and_catalog_manage_entry(self):
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        for token in (
            '@"channel.list.ctx.primary"',
            '@"channel.list.ctx.tools"',
            '@"备用源与频道工具"',
            '@"channel.catalog.manage-subscriptions"',
            '@"管理订阅源"',
        ):
            self.assertIn(token, cat)

    def test_04_subscription_resource_hero_card_and_management_subtitles(self):
        sub_vc = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        for token in (
            '@"subscription.hero.card"',
            "- (void)buildHeroHeaderView",
            "- (void)updateHeroSummary",
            "- (void)showTransientPrompt:(NSString *)prompt",
            "UIRefreshControl",
            '@"内容状态与显示增强"',
            '@"返回频道页并仅展示此订阅来源的直播台"',
            '@"subscription.logo.switch"',
            '@"subscription.telemetry.switch"',
        ):
            self.assertIn(token, sub_vc)

    def test_05_local_media_summary_sort_badges_and_grouped_context_menu(self):
        lm = (SOURCES / "LocalMediaViewController.m").read_text(encoding="utf-8")
        for token in (
            '@"local.media.summary-card"',
            '@"local.media.summary-import"',
            '@"local.media.sort"',
            '@"local.media.ext-badge"',
            '@"local.media.ctx.primary"',
            '@"local.media.ctx.destructive"',
            "- (void)applyFilterAndSort",
            "didHighlightRowAtIndexPath:",
            "waveform.circle.fill",
        ):
            self.assertIn(token, lm)


if __name__ == "__main__":
    unittest.main()
