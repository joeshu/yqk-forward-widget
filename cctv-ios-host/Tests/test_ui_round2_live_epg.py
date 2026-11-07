"""第二轮直播 / 频道页 UI、布局与稳定性合同测试。

只覆盖 RootViewController.m（央视直播页 + 频道页）与 EPGViewController.m
（节目单页）本轮改动；不改其他测试文件。
"""
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "RootViewController.m"
EPG = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "EPGViewController.m"
TEXT = ROOT.read_text(encoding="utf-8")
EPG_TEXT = EPG.read_text(encoding="utf-8")


def method_body(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class LivePageAccentContrastContracts(unittest.TestCase):
    def test_selected_text_on_accent_uses_theme_on_accent(self):
        # 深海蓝（teal #2DD4BF）与鎏金棕（gold #E8A33D）的 onAccent 是深色，
        # 白字放在上面对比度不足；三处“选中态写在 accent 底色上”的文字都要走
        # HostOnAccent()，而不是写死 whiteColor。
        build_list = method_body(TEXT, "- (void)buildList {")
        self.assertIn("NSForegroundColorAttributeName:HostOnAccent()", build_list)
        bottom_bar = method_body(TEXT, "- (void)buildBottomBar {")
        self.assertIn("cfg.baseForegroundColor=(i==0?HostOnAccent():HostMutedText())", bottom_bar)
        selection = method_body(TEXT, "- (void)updateBottomBarSelection {")
        self.assertIn("configuration.baseForegroundColor=selected?HostOnAccent():HostMutedText()", selection)

    def test_only_intentional_white_text_is_the_video_scrim_button(self):
        # 唯一剩下的 whiteColor 是播放区控制条按钮：它写在黑色半透明遮罩上，
        # 不在 accent 底色上，白字是正确的。
        self.assertEqual(TEXT.count("UIColor.whiteColor"), 1)
        bar_button = method_body(TEXT, "- (UIButton *)barButton:(NSString *)title action:(SEL)action {")
        self.assertIn("UIColor.whiteColor", bar_button)
        self.assertIn("[UIColor colorWithWhite:0 alpha:0.42]", bar_button)

    def test_secondary_text_uses_theme_color_not_system_color(self):
        # system secondaryLabelColor 不跟随 6 套主题；次要文字一律走
        # HostSecondaryText()（列表、网格、空态、播放面板、EPG 全部如此）。
        self.assertNotIn("UIColor.secondaryLabelColor", TEXT)
        self.assertNotIn("UIColor.secondaryLabelColor", EPG_TEXT)


class LivePageDynamicTypeContracts(unittest.TestCase):
    def test_control_bar_buttons_shrink_instead_of_truncating(self):
        # 大字体下 5 个等宽按钮放不下放大后的标题：允许缩到 60% 而不是截断。
        bar_button = method_body(TEXT, "- (UIButton *)barButton:(NSString *)title action:(SEL)action {")
        self.assertIn("adjustsFontSizeToFitWidth = YES", bar_button)
        self.assertIn("minimumScaleFactor = 0.6", bar_button)

    def test_segmented_controls_grow_with_dynamic_type(self):
        # 分段控件原来是 32pt 固定高度，大字体下标题会被裁；现在按缩放后
        # 行高给高度，列表起始位置跟着走。
        self.assertIn("segmentHeight=MAX(32,ceil(segmentFont.lineHeight)+14)", TEXT)
        self.assertIn("self.groupControl.frame=CGRectMake(12,y+6,w-24,segmentHeight)", TEXT)
        self.assertIn("self.playerTabs.frame=CGRectMake(12,y+6,w-24,segmentHeight)", TEXT)
        self.assertIn("CGFloat contentY=y+6+segmentHeight+4", TEXT)

    def test_columns_toggle_scales_with_dynamic_type(self):
        # 列数切换已从顶部导航栏移到“更多”菜单（configureCatalogNavigation
        # 不再往导航栏加按钮）；菜单项用系统字体，Dynamic Type 由系统自动
        # 缩放，不再需要手动 UIFontMetrics 代码。断言列数切换仍在菜单里。
        menu = method_body(TEXT, "- (UIMenu *)catalogMenu {")
        self.assertIn("channel.grid.columns.toggle", menu)
        self.assertIn("toggleCatalogColumns", menu)


class LivePageDeadCodeContracts(unittest.TestCase):
    def test_dead_fullscreen_and_pip_buttons_removed(self):
        # 全屏 / 画中画按钮建出来却从未加入任何父视图；入口仍在
        # （双击手势、“更多”菜单），只是不再留两个死按钮。
        self.assertNotIn("fullBtn", TEXT)
        self.assertNotIn("pipBtn", TEXT)
        self.assertIn("- (void)toggleFullscreen {", TEXT)
        self.assertIn("- (void)togglePiP {", TEXT)
        more = method_body(TEXT, "- (void)showMorePlaybackActions {")
        self.assertIn("toggleFullscreen", more)
        self.assertIn("togglePiP", more)


class LivePageCorruptCacheContracts(unittest.TestCase):
    def test_subscription_sources_are_type_guarded_everywhere(self):
        # 缓存/旧版本数据里 subscriptionSources 一旦混入非数组，
        # setWithArray:/containsObject: 会直接抛异常（启动、筛选都在内）。
        # 统一经 CCTVStringArrayValue 归一为空数组。
        self.assertIn("static NSArray *CCTVStringArrayValue(id value) {", TEXT)
        self.assertIn(
            "return [value isKindOfClass:NSArray.class] ? value : @[];", TEXT
        )
        self.assertNotIn('subscriptionSources"]?:@[]', TEXT)
        self.assertNotIn('subscriptionSources"] ?: @[]', TEXT)
        self.assertNotIn('[channel[@"subscriptionSources"] containsObject:', TEXT)
        self.assertNotIn('[c[@"subscriptionSources"] containsObject:', TEXT)
        # 413 合并后多一处导出函数的同类守卫（Root L1120），共 14 处。
        self.assertEqual(TEXT.count("CCTVStringArrayValue("), 14)

    def test_group_filter_does_not_message_non_string_group(self):
        body = method_body(TEXT, "- (void)applyFilter {")
        self.assertIn(
            '[o[@"group"] isKindOfClass:NSString.class] && [o[@"group"] isEqualToString:g]',
            body,
        )

    def test_channel_group_display_never_shows_null(self):
        body = method_body(
            TEXT,
            "- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {",
        )
        self.assertIn('NSString *groupName=[ch[@"group"] isKindOfClass:NSString.class]?ch[@"group"]:@"直播";', body)
        self.assertNotIn('ch[@"group"] ?: @"直播"', TEXT)


class LivePageEPGContracts(unittest.TestCase):
    def test_epg_titles_are_type_checked_before_display(self):
        # EPG 标题来自外部 JSON，非字符串时不能直接进缓存/拼进文案
        #（否则出现“正在播：<null>”）。
        cache = method_body(TEXT, "- (void)cacheXMLRows:(NSArray *)rows channel:(NSString *)cid {")
        self.assertIn('[r[@"title"] isKindOfClass:NSString.class]?r[@"title"]:nil', cache)
        self.assertIn("if(![r isKindOfClass:NSDictionary.class])continue;", cache)
        loader = method_body(
            TEXT,
            "- (void)loadEPGForChannel:(NSString *)cid channel:(NSDictionary *)channel section:(NSIndexPath *)ip {",
        )
        self.assertIn('[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil', loader)
        official = method_body(TEXT, "- (void)refreshOfficialNowNext {")
        self.assertIn('[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil', official)

    def test_load_epg_for_channel_reuses_the_cell_channel(self):
        # cellForRow 已持有频道字典：直接复用，避免每次出现新 cell 都对
        # 全量频道做两次线性查找（约 2 万条时滚动掉帧）。
        cell = method_body(
            TEXT,
            "- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {",
        )
        self.assertIn("[self loadEPGForChannel:cid channel:ch section:ip];", cell)
        loader = method_body(
            TEXT,
            "- (void)loadEPGForChannel:(NSString *)cid channel:(NSDictionary *)channel section:(NSIndexPath *)ip {",
        )
        self.assertIn("if(!channel)channel=[self channelWithID:cid];", loader)
        self.assertIn("[self epgIDForChannel:channel]", loader)
        self.assertEqual(loader.count("[self channelWithID:cid]"), 1)

    def test_preview_close_button_stays_inside_narrow_box(self):
        # 窄屏/分屏下预览盒宽度小于 280 时，写死 x=180 的关闭按钮会被裁掉。
        preview = method_body(TEXT, "- (void)previewChannel:(NSDictionary *)ch {")
        self.assertIn("CGFloat previewWidth=MIN(280,self.view.bounds.size.width-32);", preview)
        self.assertIn("close.frame=CGRectMake(MAX(0,previewWidth-100),0,MIN(100,previewWidth),44);", preview)

    def test_dealloc_still_tears_down_playback_timers_and_tasks(self):
        dealloc = method_body(TEXT, "- (void)dealloc {")
        self.assertIn("[self stopPlayback]", dealloc)
        self.assertIn("[self stopPreview]", dealloc)
        self.assertIn("[self.watchdog invalidate]", dealloc)
        self.assertIn("[self.epgTimer invalidate]", dealloc)
        self.assertIn("removeObserver:self", dealloc)


class EPGPageContracts(unittest.TestCase):
    def test_epg_dates_use_theme_on_accent_text(self):
        view_did_load = method_body(EPG_TEXT, "- (void)viewDidLoad {")
        self.assertIn("NSForegroundColorAttributeName:HostOnAccent()", view_did_load)
        self.assertIn("NSForegroundColorAttributeName:HostText()", view_did_load)
        self.assertIn("UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1", view_did_load)
        self.assertIn(
            "self.dateMenuButton.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]",
            view_did_load,
        )

    def test_epg_cell_reuses_one_time_formatter(self):
        # 原来每行都 new 一个 NSDateFormatter；滚动时每行都建，改成静态复用。
        cell = method_body(
            EPG_TEXT,
            "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {",
        )
        self.assertIn("static NSDateFormatter *fmt = nil;", cell)
        self.assertIn("dispatch_once(&onceToken,", cell)
        # 整个 cell 方法里只剩 dispatch_once 块内的一次创建，不再每行新建。
        self.assertEqual(cell.count("[[NSDateFormatter alloc] init]"), 1)

    def test_epg_failed_refresh_says_stale_data_is_shown(self):
        # 刷新失败时保留上次节目单：提示必须说清是旧数据，不能一边展示
        # 旧节目一边写“暂无有效节目单”。
        self.assertEqual(EPG_TEXT.count("刷新失败，显示上次节目单"), 2)

    def test_epg_table_respects_bottom_safe_area(self):
        # 原来表格高度没减底部安全区，末行会被 Home Indicator 遮住。
        layout = method_body(EPG_TEXT, "- (void)viewDidLayoutSubviews {")
        self.assertIn("CGFloat bottom=self.view.safeAreaInsets.bottom;", layout)
        self.assertIn("-8-bottom", layout)


if __name__ == "__main__":
    unittest.main()
