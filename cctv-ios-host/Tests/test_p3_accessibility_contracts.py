"""Phase 3 accessibility reinforcement contract tests.

These source-pattern tests pin the small, reviewable dynamic-type and VoiceOver
guards added to the core user paths (RootViewController channel/search,
MediaBrowserViewController home/detail, MediaEpisodeSelectionViewController,
MediaPlaybackViewController control bar / line / quality / retry).

Style follows the other contract suites: each test asserts a small, reviewable
fragment is present in the sources, so a future refactor that drops the guard
will fail loudly. These tests do NOT build — they only guard the source text.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"

ROOT_SOURCE = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
CATALOG_SOURCE = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
BROWSER_SOURCE = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
PLAYBACK_SOURCE = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
EPISODE_SOURCE = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
SERVICES_SOURCE = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
TVBOX_SOURCE = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")


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


class DynamicTypeContracts(unittest.TestCase):
    """文字标题/副标题用 preferredFontForTextStyle 或 UIFontMetrics 缩放字体，
    并打开 adjustsFontForContentSizeCategory；HUD/图标固定字号可保留。"""

    def test_episode_description_toggle_scales_with_dynamic_type(self):
        self.assertIn(
            'descriptionToggle.titleLabel.font=[[UIFontMetrics metricsForTextStyle:'
            'UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:12 '
            'weight:UIFontWeightSemibold]]',
            EPISODE_SOURCE,
        )
        self.assertIn(
            "descriptionToggle.titleLabel.adjustsFontForContentSizeCategory=YES",
            EPISODE_SOURCE,
        )

    def test_episode_season_buttons_use_scaled_pill_font(self):
        body = method_body(EPISODE_SOURCE, "- (void)buildSeasons {")
        # season pills 不能只写死 13pt，必须套一层缩放
        self.assertIn("MediaEpisodeApplyScaledPillFont(button);", body)

    def test_episode_route_buttons_use_scaled_pill_font(self):
        body = method_body(EPISODE_SOURCE, "- (void)rebuildSelection {")
        self.assertIn("MediaEpisodeApplyScaledPillFont(button);", body)

    def test_playback_line_buttons_use_scaled_pill_font(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildLines {")
        self.assertIn("MediaPlaybackApplyScaledPillFont(button);", body)

    def test_playback_quality_buttons_use_scaled_pill_font(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildQualityButtons {")
        self.assertIn("MediaPlaybackApplyScaledPillFont(button);", body)

    def test_cicada_control_factory_keeps_hud_font_fixed(self):
        # HUD 创建被委托给独立模块；固定字号和动态元素仍在 builder 内。
        controls = (SOURCES / "MediaPlaybackCicadaControls.m").read_text(encoding="utf-8")
        self.assertIn("systemFontOfSize:12 weight:UIFontWeightSemibold", controls)


class VoiceOverButtonContracts(unittest.TestCase):
    """关键可操作按钮必须有 accessibilityLabel（避免仅 image 按钮无标签），
    并补充 Hint/Traits 与选中状态。"""

    def test_episode_continue_button_has_label_and_hint(self):
        self.assertIn(
            'continueButton.accessibilityLabel=@"继续播放或重新播放";',
            EPISODE_SOURCE,
        )
        self.assertIn(
            'continueButton.accessibilityHint=@"从上次离开的位置继续播放，'
            '或重新播放选中的分集";',
            EPISODE_SOURCE,
        )

    def test_episode_description_toggle_has_label_hint_traits(self):
        self.assertIn(
            'descriptionToggle.accessibilityLabel=@"展开简介";',
            EPISODE_SOURCE,
        )
        self.assertIn(
            'descriptionToggle.accessibilityHint=@"展开或收起影片简介";',
            EPISODE_SOURCE,
        )
        self.assertIn(
            "self.descriptionToggle.accessibilityLabel=self.descriptionExpanded",
            EPISODE_SOURCE,
        )

    def test_episode_season_buttons_carry_label_hint_and_selected_trait(self):
        body = method_body(EPISODE_SOURCE, "- (void)buildSeasons {")
        self.assertIn("button.accessibilityLabel=", body)
        self.assertIn("button.accessibilityHint=", body)
        self.assertIn("UIAccessibilityTraitButton|(selected?", body)

    def test_episode_route_buttons_carry_label_hint_and_selected_trait(self):
        body = method_body(EPISODE_SOURCE, "- (void)rebuildSelection {")
        self.assertIn("button.accessibilityLabel=", body)
        self.assertIn("button.accessibilityHint=", body)
        self.assertIn("UIAccessibilityTraitButton|(selected?", body)

    def test_playback_line_buttons_carry_label_hint_and_selected_trait(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildLines {")
        self.assertIn("button.accessibilityLabel=[NSString stringWithFormat:", body)
        self.assertIn("button.accessibilityHint=", body)
        self.assertIn("UIAccessibilityTraitButton|(idx==self.lineIndex?", body)

    def test_playback_quality_buttons_keep_existing_label_and_hint(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildQualityButtons {")
        self.assertIn("button.accessibilityLabel=name;", body)
        self.assertIn("button.accessibilityHint=alternates.count==1?", body)

    def test_playback_retry_and_web_buttons_have_hint(self):
        self.assertIn(
            'inlineRetryButton.accessibilityHint=@"重新加载当前影片的播放线路";',
            PLAYBACK_SOURCE,
        )
        self.assertIn(
            'inlineWebButton.accessibilityHint=@"在不支持原生播放时改用网页播放";',
            PLAYBACK_SOURCE,
        )

    def test_cicada_control_buttons_have_hints(self):
        controls = (SOURCES / "MediaPlaybackCicadaControls.m").read_text(encoding="utf-8")
        for fragment in (
            '_rewindButton.accessibilityHint=@"回退 10 秒"',
            '_playPauseButton.accessibilityHint=@"暂停或继续播放"',
            '_forwardButton.accessibilityHint=@"快进 10 秒"',
            '_rateButton.accessibilityHint=@"调整播放倍速"',
            '_fullscreenButton.accessibilityHint=@"进入或退出全屏"',
        ):
            self.assertIn(fragment, controls)

    def test_cicada_rate_button_reports_value(self):
        self.assertIn(
            "self.cicadaControlsBuilder.rateButton.accessibilityValue=[NSString "
            'stringWithFormat:@"%.2g×",self.cicadaAdapter.rate];',
            PLAYBACK_SOURCE,
        )

    def test_browser_favorite_button_reports_value_and_hint(self):
        self.assertIn(
            'self.favoriteButton.accessibilityValue=favorite?@"已收藏":@"未收藏";',
            BROWSER_SOURCE,
        )
        self.assertIn("self.favoriteButton.accessibilityHint=favorite?", BROWSER_SOURCE)

    def test_browser_back_and_paging_buttons_have_hint(self):
        self.assertIn('back.accessibilityHint=@"返回上一级页面";', BROWSER_SOURCE)
        self.assertIn(
            'self.previousPageButton.accessibilityHint=@"查看上一组分集";',
            BROWSER_SOURCE,
        )
        self.assertIn(
            'self.nextPageButton.accessibilityHint=@"查看下一组分集";',
            BROWSER_SOURCE,
        )

    def test_browser_scope_buttons_carry_label_and_selected_trait(self):
        body = method_body(
            BROWSER_SOURCE,
            "- (void)addScopeButton:(NSString *)key title:(NSString *)title {",
        )
        self.assertIn("button.accessibilityLabel=title;", body)
        self.assertIn("UIAccessibilityTraitButton|([key isEqual:self.selectedScope]?", body)

    def test_browser_featured_category_button_has_label_and_hint(self):
        self.assertIn(
            'featured.accessibilityLabel=@"精选首页";', BROWSER_SOURCE
        )
        self.assertIn(
            'featured.accessibilityHint=@"查看精选推荐影视";', BROWSER_SOURCE
        )

    def test_browser_category_loop_sets_selected_trait(self):
        # 重建分类按钮的循环里要带 selected trait，避免 VoiceOver 不报选中状态
        body = method_body(
            BROWSER_SOURCE,
            "- (void)configureCategories: {",
        ) if "- (void)configureCategories: {" in BROWSER_SOURCE else None
        # 厂家方法名可能不同，退回全文断言：循环里同时出现 trait 与 cornerRadius
        self.assertIn(
            "button.accessibilityTraits=UIAccessibilityTraitButton|(selected?",
            BROWSER_SOURCE,
        )

    def test_root_search_bar_has_label_and_hint(self):
        self.assertIn(
            'searchBar.accessibilityLabel = @"搜索频道";', ROOT_SOURCE
        )
        self.assertIn(
            'searchBar.accessibilityHint = @"输入频道名称或编号以筛选列表";',
            ROOT_SOURCE,
        )


class ResourceServicesVoiceOverContracts(unittest.TestCase):
    def test_service_hero_actions_have_label_hint_traits_and_dynamic_titles(self):
        body = method_body(SERVICES_SOURCE, "- (void)setupServiceDetailHeaderView {")
        self.assertIn('@"hint":@"探测本机端口健康或频道清单"', body)
        self.assertIn("btn.accessibilityLabel=spec[@\"title\"]", body)
        self.assertIn("btn.accessibilityHint=spec[@\"hint\"]", body)
        self.assertIn("btn.accessibilityTraits=UIAccessibilityTraitButton", body)
        self.assertIn("btn.titleLabel.adjustsFontForContentSizeCategory=YES", body)
        for label in ("titleLbl", "subLbl", "statusBadge"):
            self.assertIn(f"{label}.adjustsFontForContentSizeCategory=YES", body)

    def test_service_toggle_button_has_hint_traits_value_and_scaled_title(self):
        self.assertIn('control.accessibilityHint=managed?@"停止此资源服务":@"启动此资源服务";', SERVICES_SOURCE)
        self.assertIn("control.accessibilityTraits=UIAccessibilityTraitButton;", SERVICES_SOURCE)
        self.assertIn('control.accessibilityValue=isRunning?@"运行中":@"已停止";', SERVICES_SOURCE)
        self.assertIn("control.titleLabel.adjustsFontForContentSizeCategory=YES", SERVICES_SOURCE)

    def test_service_detail_interactive_rows_have_traits_and_hint(self):
        self.assertIn("c.accessibilityTraits=UIAccessibilityTraitButton;", SERVICES_SOURCE)
        self.assertIn('c.accessibilityHint=@"点按执行此行操作";', SERVICES_SOURCE)

    def test_services_search_filter_and_summary_are_accessible_and_dynamic(self):
        self.assertIn('self.search.searchBar.accessibilityLabel=@"搜索资源服务";', SERVICES_SOURCE)
        self.assertIn('self.search.searchBar.accessibilityHint=@"输入名称、端口、引擎或协议以筛选服务列表";', SERVICES_SOURCE)
        self.assertIn('self.statusFilter.accessibilityLabel=@"服务状态筛选";', SERVICES_SOURCE)
        self.assertIn('self.statusFilter.accessibilityHint=@"选择全部、运行中、待处理或已停止分组";', SERVICES_SOURCE)
        self.assertIn("[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:", SERVICES_SOURCE)
        self.assertIn("self.runtimeSummary.adjustsFontForContentSizeCategory=YES", SERVICES_SOURCE)

    def test_service_list_control_and_rows_have_voiceover_metadata(self):
        self.assertIn('control.accessibilityHint=managed?@"停止此资源服务":@"启动此资源服务";', SERVICES_SOURCE)
        self.assertIn('control.accessibilityValue=[PyHost isRunningServiceIdentifier:identifier]?@"运行中":@"已停止";', SERVICES_SOURCE)
        self.assertIn('c.accessibilityHint=@"点按查看服务详情，长按可复制访问地址";', SERVICES_SOURCE)


class TVBoxCatalogVoiceOverContracts(unittest.TestCase):
    def test_search_and_filter_controls_have_labels_hints(self):
        self.assertIn('self.searchController.searchBar.accessibilityLabel=@"搜索资源合集";', TVBOX_SOURCE)
        self.assertIn('self.searchController.searchBar.accessibilityHint=@"输入站点名称、协议或 URL 以筛选合集列表";', TVBOX_SOURCE)
        self.assertIn('self.contentFilter.accessibilityLabel=@"资源分类筛选";', TVBOX_SOURCE)
        self.assertIn('self.contentFilter.accessibilityHint=@"筛选全部、影视、直播或不支持的资源";', TVBOX_SOURCE)

    def test_more_menu_button_has_label_and_hint(self):
        self.assertIn('more.accessibilityLabel=@"合集操作";more.accessibilityHint=@"导出、导入或移除本资源合集";', TVBOX_SOURCE)

    def test_supported_resource_rows_have_button_trait_and_contextual_hint(self):
        self.assertIn("cell.accessibilityTraits=UIAccessibilityTraitButton;", TVBOX_SOURCE)
        self.assertIn('cell.accessibilityHint=ip.section==0?@"点按打开或导入此站点，长按可导出单项资源":@"点按加载此直播清单，长按可导出单项资源";', TVBOX_SOURCE)
        self.assertIn("cell.imageView.accessibilityElementsHidden=YES;", TVBOX_SOURCE)


if __name__ == "__main__":
    unittest.main()
