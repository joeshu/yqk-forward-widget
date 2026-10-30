from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
ROOT_SOURCE = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
BROWSER_SOURCE = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
PLAYBACK_SOURCE = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
EPISODE_SOURCE = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
IMAGE_SOURCE = (SOURCES / "HostImageLoader.m").read_text(encoding="utf-8")
RESOURCE_SOURCE = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
RESOURCE_HEADER = (SOURCES / "ConfigCenterViewController.h").read_text(encoding="utf-8")


def method_body(source, signature):
    # Many controllers forward-declare private methods before their implementation.
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


class PlaybackOwnershipAndMediaUIContracts(unittest.TestCase):
    def test_leaving_live_tabs_suspends_before_the_active_tab_changes(self):
        body = method_body(ROOT_SOURCE, "- (void)selectBottomTab:(UIButton *)sender")
        suspend = body.index('suspendLivePlaybackForReason:@"left_live_interface"')
        change = body.index("self.activeTab=sender.tag")
        self.assertLess(suspend, change)
        self.assertIn("self.activeTab<2&&sender.tag>=2", body)

    def test_pushing_a_secondary_navigation_page_also_suspends_live(self):
        body = method_body(ROOT_SOURCE, "- (void)navigationController:(UINavigationController *)navigationController willShowViewController:")
        self.assertIn("viewController==self", body)
        self.assertIn("if(self.activeTab<2)[self suspendLivePlaybackForReason:@\"left_live_navigation_page\"]", body)

    def test_live_suspend_invalidates_and_releases_the_old_player(self):
        body = method_body(ROOT_SOURCE, "- (void)suspendLivePlaybackForReason:(NSString *)reason")
        self.assertLess(body.index("self.playbackGeneration++"), body.index("[self stopPlayback]"))
        self.assertIn('recordEvent:hasLivePlayback?@"live_playback_suspended"', body)
        self.assertIn('self.livePlaybackSuspendedForNavigation=hasLivePlayback', body)
        self.assertIn("直播已暂停", body)

    def test_suspended_live_channel_can_be_restarted_from_its_live_page(self):
        body = method_body(ROOT_SOURCE, "- (void)togglePlayPause")
        self.assertIn("if(self.livePlaybackSuspendedForNavigation)", body)
        self.assertIn("[self playChannel:channel route:self.requestedNativeRoute]", body)
        self.assertIn("self.activeTab==1&&self.currentRemoteURL.length", body)

    def test_background_exception_applies_only_while_live_page_is_visible(self):
        body = method_body(ROOT_SOURCE, "- (void)onBackground")
        self.assertIn("self.activeTab<2&&self.navigationController.topViewController==self", body)
        self.assertIn("self.presentedViewController==nil", body)
        self.assertIn("if(!livePageRemainsVisible)[self suspendLivePlaybackForReason:", body)
        self.assertIn("if(!livePageRemainsVisible)[self call:self.currentPlayer sel:@\"resignActive\"]", body)
        self.assertIn('keep_live_playback', body)

    def test_inline_and_pushed_vod_players_notify_the_live_owner(self):
        show_inline = method_body(BROWSER_SOURCE, "- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context")
        play_result = method_body(PLAYBACK_SOURCE, "- (void)playResult:(NSDictionary *)result")
        root_media = method_body(ROOT_SOURCE, "- (void)openMediaTab")
        self.assertIn("@property(nonatomic,copy) dispatch_block_t onPlaybackWillStart", BROWSER_SOURCE)
        self.assertIn("detail.onPlaybackWillStart=self.onPlaybackWillStart", BROWSER_SOURCE)
        self.assertIn("player.onPlaybackWillStart=self.onPlaybackWillStart", show_inline)
        self.assertIn("if(self.onPlaybackWillStart)self.onPlaybackWillStart()", play_result)
        self.assertIn("page.onPlaybackWillStart=", root_media)
        self.assertIn("player.onPlaybackWillStart=", root_media)
        self.assertIn('recordEvent:@"playback_owner_acquired"', play_result)

    def test_legacy_vod_entry_stops_live_before_creating_its_player(self):
        body = method_body(ROOT_SOURCE, "- (void)playMediaResult:(NSDictionary *)result name:")
        self.assertLess(body.index('suspendLivePlaybackForReason:@"vod_playback_starting"'), body.index("AVPlayer playerWithPlayerItem:item"))
        self.assertIn('recordEvent:hasLivePlayback?@"live_playback_suspended":@"playback_owner_released"', method_body(ROOT_SOURCE, "- (void)suspendLivePlaybackForReason:"))

    def test_back_and_detail_actions_keep_visible_text_fallbacks(self):
        self.assertIn('setTitle:@"‹"', BROWSER_SOURCE)
        self.assertIn('setTitle:@"‹"', EPISODE_SOURCE)
        action = method_body(BROWSER_SOURCE, "- (UIButton *)detailActionButton:")
        for title in ("复制", "分享", "收藏", "选集"):
            self.assertIn(f'detailActionButton:@"{title}"', BROWSER_SOURCE)
        self.assertIn("[button setTitle:title forState:UIControlStateNormal]", action)

    def test_inline_player_prefers_compact_height_without_clipping_extra_routes(self):
        inline = method_body(BROWSER_SOURCE, "- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context")
        self.assertIn("multiplier:0.5625 constant:88", inline)
        self.assertIn("inlineHeight.priority=UILayoutPriorityDefaultHigh", inline)
        self.assertIn("setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical", PLAYBACK_SOURCE)

    def test_poster_download_budget_handles_large_covers_without_unbounded_reads(self):
        self.assertIn("static NSUInteger const ImageBodyLimit = 2 * 1024 * 1024", IMAGE_SOURCE)
        self.assertIn("static NSUInteger const PosterBodyLimit = 4 * 1024 * 1024", IMAGE_SOURCE)
        self.assertIn("record.maximumPixelSize>512?PosterBodyLimit:ImageBodyLimit", IMAGE_SOURCE)
        self.assertIn("[self maximumBodyLengthForRequest:record]", IMAGE_SOURCE)

    def test_avfoundation_cannot_open_error_is_actionable(self):
        self.assertIn('error.code==-11828)return @"media_open_failed"', PLAYBACK_SOURCE)
        self.assertIn("iOS 无法打开这条媒体流", PLAYBACK_SOURCE)

    def test_current_episode_number_stays_visible_during_playback(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)updateEpisodeTitle")
        self.assertIn('第 %ld 集', body)
        self.assertIn('self.episodeTitle.accessibilityLabel=title', body)
        embedded = PLAYBACK_SOURCE[PLAYBACK_SOURCE.index('if(self.embeddedMode){'):PLAYBACK_SOURCE.index('[NSNotificationCenter.defaultCenter addObserver:self')]
        self.assertIn('self.episodeTitle.hidden=NO', embedded)
        self.assertIn('constraintEqualToAnchor:self.episodeTitle.bottomAnchor', embedded)

    def test_scripts_and_services_is_a_primary_resource_page_button(self):
        self.assertIn('accessibilityIdentifier=@"resource-floating-actions"', ROOT_SOURCE)
        self.assertIn('self.resourceActionsButton.showsMenuAsPrimaryAction=NO', ROOT_SOURCE)
        self.assertIn('action:@selector(openServicesPage) forControlEvents:UIControlEventTouchUpInside', ROOT_SOURCE)
        self.assertIn('actionWithTitle:@"脚本与服务"', ROOT_SOURCE)
        self.assertIn('- (void)refreshProfiles;', RESOURCE_HEADER)
        self.assertIn('self.resourceActionsButton.frame=CGRectMake', ROOT_SOURCE)
        self.assertIn('||self.activeTab==3', ROOT_SOURCE)
        self.assertIn('self.resourceSearchField.placeholder=@"搜索资源"', RESOURCE_SOURCE)
        self.assertIn('accessibilityIdentifier=@"resource-search-field"', RESOURCE_SOURCE)

    def test_resource_page_matches_compact_toolbar_title_search_and_filters(self):
        self.assertIn('accessibilityIdentifier=@"resource-action.more"', RESOURCE_SOURCE)
        self.assertIn('accessibilityIdentifier=[@"resource-action." stringByAppendingString:item[@"label"]]', RESOURCE_SOURCE)
        self.assertIn('UIAction *servicesAction=[UIAction actionWithTitle:@"脚本与服务"', RESOURCE_SOURCE)
        self.assertIn('accessibilityIdentifier=@"resource-search-field"', RESOURCE_SOURCE)
        self.assertIn('- (void)updateResourceHeaderLayout', RESOURCE_SOURCE)
        self.assertIn('systemLayoutSizeFittingSize:CGSizeMake(width,UIViewNoIntrinsicMetric)', RESOURCE_SOURCE)
        self.assertIn('self.tableView.tableHeaderView=header', RESOURCE_SOURCE)
        self.assertIn('self.resourceHeaderTopConstraint.constant=MAX(0,self.view.safeAreaInsets.top)+8', RESOURCE_SOURCE)
        layout = method_body(ROOT_SOURCE, '- (void)viewDidLayoutSubviews')
        self.assertIn('BOOL resourcePage=[self.tabPage isKindOfClass:ConfigCenterViewController.class]', layout)
        self.assertIn('CGFloat pageTop=resourcePage?0:top', layout)
        self.assertIn('[self updateResourceHeaderLayout]', method_body(RESOURCE_SOURCE, '- (void)viewWillAppear:(BOOL)animated'))
        self.assertIn('NSString *query=self.searchQuery?:@""', RESOURCE_SOURCE)
        self.assertIn('self.resourceActionsButton.hidden=YES', ROOT_SOURCE)


if __name__ == "__main__":
    unittest.main()
