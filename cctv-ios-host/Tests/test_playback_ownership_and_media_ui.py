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
    def test_channel_logos_keep_their_image_during_reuse_and_playback_priority(self):
        load_logo = method_body(ROOT_SOURCE, "- (void)loadLogo:(NSString *)url into:(UIImageView *)iv")
        self.assertIn("HostImageLoader shared] loadURL:url intoImageView:iv", load_logo)
        self.assertNotIn("playbackPriorityUntil", load_logo)
        self.assertIn("BOOL sameImage=[imageView.accessibilityIdentifier isEqualToString:url ?: @\"\"]", IMAGE_SOURCE)
        self.assertIn("if(!sameImage)imageView.image=nil", IMAGE_SOURCE)
        grid_cell = method_body(ROOT_SOURCE, "- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:")
        self.assertNotIn("logo.image=nil;logo.accessibilityIdentifier=logoURL", grid_cell)
        list_cell = method_body(ROOT_SOURCE, "- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:")
        self.assertNotIn("cell.imageView.image = nil", list_cell)

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

    def test_resource_navigation_snapshots_scroll_before_push(self):
        for signature in (
            "- (void)openServicesPage",
            "- (void)openPluginResource:(NSString *)source",
            "- (void)openTVBoxCatalog:(NSString *)identifier",
            "- (void)openServiceEditorForService:(NSDictionary *)service",
        ):
            body = method_body(ROOT_SOURCE, signature)
            prepare = body.index("prepareForNavigationTransition]")
            push = body.index("pushViewController:")
            self.assertLess(prepare, push, signature)

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
        root_media = method_body(ROOT_SOURCE, "- (MediaBrowserViewController *)mediaPageCreatingIfNeeded")
        self.assertIn("@property(nonatomic,copy) dispatch_block_t onPlaybackWillStart", BROWSER_SOURCE)
        self.assertIn("detail.onPlaybackWillStart=self.onPlaybackWillStart", BROWSER_SOURCE)
        self.assertIn("player.onPlaybackWillStart=self.onPlaybackWillStart", show_inline)
        self.assertIn("if(self.onPlaybackWillStart)self.onPlaybackWillStart()", play_result)
        self.assertIn("page.onPlaybackWillStart=", root_media)
        self.assertIn("player.onPlaybackWillStart=", root_media)
        self.assertIn('recordEvent:@"playback_owner_acquired"', play_result)

    def test_legacy_vod_entry_is_removed_and_live_owner_still_notified(self):
        # 旧的 playMediaResult 入口已删除（无调用者）：VOD 统一走
        # MediaPlaybackViewController.playResult:，起播前仍通过
        # onPlaybackWillStart 通知直播方释放所有权；直播挂起辅助
        # 方法仍记录挂起/释放事件。
        self.assertNotIn("playMediaResult:", ROOT_SOURCE)
        self.assertIn('recordEvent:hasLivePlayback?@"live_playback_suspended":@"playback_owner_released"', method_body(ROOT_SOURCE, "- (void)suspendLivePlaybackForReason:"))

    def test_back_and_detail_actions_keep_visible_text_fallbacks(self):
        self.assertIn('setTitle:@"‹"', BROWSER_SOURCE)
        self.assertIn('setTitle:@"‹"', EPISODE_SOURCE)
        action = method_body(BROWSER_SOURCE, "- (UIButton *)detailActionButton:")
        for title in ("复制", "分享", "收藏", "选集"):
            self.assertIn(f'detailActionButton:@"{title}"', BROWSER_SOURCE)
        self.assertIn("[button setTitle:title forState:UIControlStateNormal]", action)

    def test_inline_player_floats_video_while_its_controls_join_detail_content(self):
        inline = method_body(BROWSER_SOURCE, "- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context")
        self.assertIn("installFloatingInlineSurfaceInHost:dock controlsStack:self.contentStack", inline)
        self.assertIn("inlinePlaybackScrollTopConstraint=[self.scrollView.topAnchor constraintEqualToAnchor:dock.bottomAnchor constant:8]", inline)
        self.assertNotIn("multiplier:0.5625 constant:88", inline)
        self.assertIn("preferredInlineVideoHeightForWidth:width maximumHeight:maximum", BROWSER_SOURCE)
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
        self.assertIn('正在播放 · ', body)
        self.assertIn('self.episodeTitle.accessibilityLabel=visibleTitle', body)
        self.assertIn('self.title=title', body)
        embedded = PLAYBACK_SOURCE[PLAYBACK_SOURCE.index('if(self.embeddedMode){'):PLAYBACK_SOURCE.index('[NSNotificationCenter.defaultCenter addObserver:self')]
        self.assertIn('self.episodeTitle.hidden=NO', embedded)
        self.assertIn('constraintEqualToAnchor:self.episodeTitle.bottomAnchor', embedded)

    def test_long_series_uses_thirty_episode_groups_without_changing_playback_indexes(self):
        layout = (SOURCES / "MediaEpisodeLayout.h").read_text(encoding="utf-8")
        self.assertIn("static const NSUInteger CCTVEpisodesPerGroup = 30", layout)
        self.assertIn("count - sourceIndex - 1", layout)
        self.assertIn("count - displayIndex - 1", layout)
        for source in (BROWSER_SOURCE, EPISODE_SOURCE):
            with self.subTest(source="detail" if source is BROWSER_SOURCE else "player selection"):
                self.assertIn("CCTVEpisodeSourceIndex(displayIndex,episodes.count,self.episodeOrderReversed)", source)
                self.assertIn("button.tag=index", source)
                self.assertIn('第 %ld/%lu 组 · 第 %lu–%lu 集', source)
                self.assertNotIn("(episodes.count+11)/12", source)
        self.assertIn("playback_gesture_seek", PLAYBACK_SOURCE)
        self.assertIn("playback_gesture_rate_started", PLAYBACK_SOURCE)
        self.assertIn("self.player.rate=3.0f", PLAYBACK_SOURCE)

    def test_player_adapts_portrait_video_and_adds_reference_style_swipe_controls(self):
        self.assertIn("videoAspectRatio>0.0&&self.videoAspectRatio<0.95", PLAYBACK_SOURCE)
        self.assertIn("portraitTallViewportHeightConstraint", PLAYBACK_SOURCE)
        self.assertIn("landscapeTallViewportHeightConstraint", PLAYBACK_SOURCE)
        self.assertIn("embeddedTallVideoAspectConstraint", PLAYBACK_SOURCE)
        self.assertIn("owner.videoAspectRatio=displayAspect", PLAYBACK_SOURCE)
        self.assertIn("self.playbackPanGesture=[[UIPanGestureRecognizer alloc]", PLAYBACK_SOURCE)
        self.assertIn("if(self.embeddedMode)return fabs(velocity.x)>fabs(velocity.y)*1.25", PLAYBACK_SOURCE)
        self.assertIn("MediaPlaybackPanModeBrightness", PLAYBACK_SOURCE)
        self.assertIn("UIScreen.mainScreen.brightness=value", PLAYBACK_SOURCE)
        self.assertIn("MPVolumeView", PLAYBACK_SOURCE)
        self.assertIn("playback_gesture_swipe_seek", PLAYBACK_SOURCE)
        self.assertIn("touch.view", PLAYBACK_SOURCE)

    def test_playback_intent_survives_resolution_and_never_overrides_a_user_pause(self):
        session_play = method_body(PLAYBACK_SOURCE, "- (void)sessionPlay")
        session_pause = method_body(PLAYBACK_SOURCE, "- (void)sessionPause")
        play_result = method_body(PLAYBACK_SOURCE, "- (void)playResult:")
        ready_buffer = method_body(PLAYBACK_SOURCE, "- (void)startAVPlayerFromReadyBufferIfNeeded:")
        now_playing = method_body(PLAYBACK_SOURCE, "- (void)updateNowPlayingInfoCenter")
        player_observer = method_body(PLAYBACK_SOURCE, "- (void)observeValueForKeyPath:")
        self.assertIn("self.playbackWantsPlayback=YES", session_play)
        self.assertIn("self.playbackWantsPlayback=NO", session_pause)
        self.assertLess(play_result.index("NSString *previousURL="), play_result.index("self.result=[result copy]"))
        reset_routes = play_result.index("if(![incomingURL isEqualToString:previousURL])self.attemptedRoutes=0")
        paused_result = play_result.index("if(!self.playbackWantsPlayback||self.playbackSuspendedForVisibility)")
        self.assertLess(reset_routes, paused_result)
        self.assertIn("[self clearCurrentPlayerItem]", play_result[paused_result:])
        self.assertIn("!self.playbackWantsPlayback", ready_buffer)
        self.assertIn("self.hasReportedPlaying=YES;self.playbackWantsPlayback=YES", player_observer)
        self.assertIn("self.player.timeControlStatus!=state", player_observer)
        self.assertIn("NSUInteger reportedIntentGeneration=self.playbackIntentGeneration", player_observer)
        self.assertIn("reportedIntentGeneration!=self.playbackIntentGeneration", player_observer)
        self.assertIn("if(_playbackWantsPlayback!=value)self.playbackIntentGeneration++", PLAYBACK_SOURCE)
        self.assertIn("if(_playbackSuspendedForVisibility!=value)self.playbackIntentGeneration++", PLAYBACK_SOURCE)
        self.assertIn("if(value)self.ignorePausedTimeControlUntilPlaying=YES", PLAYBACK_SOURCE)
        self.assertIn("self.ignorePausedTimeControlUntilPlaying=NO;self.hasReportedPlaying=YES", player_observer)
        self.assertIn("!self.ignorePausedTimeControlUntilPlaying", player_observer)
        resume_visibility = method_body(PLAYBACK_SOURCE, "- (void)resumeAfterVisibilityChange")
        self.assertIn("if(!self.isViewLoaded)return", resume_visibility)
        self.assertNotIn("self.view.window", resume_visibility)
        self.assertIn("pendingGeneration==self.generation", resume_visibility)
        self.assertIn("if(self.playbackWantsPlayback&&!self.resolving&&self.player.currentItem)[self playActiveEngine]", resume_visibility)
        self.assertIn('inline_playback_visibility_resume_checked', resume_visibility)
        self.assertIn("[self.inlinePlaybackController resumeAfterVisibilityChange]", BROWSER_SOURCE)
        self.assertIn("owner.playbackWantsPlayback=YES;owner.context=context;owner.lineIndex=[context[@\"lineIndex\"] integerValue]", PLAYBACK_SOURCE)
        selection_play = method_body(EPISODE_SOURCE, "- (void)selectEpisode:")
        self.assertIn("page.onPlaybackReturn", PLAYBACK_SOURCE)
        self.assertIn("[navigation popViewControllerAnimated:YES]", selection_play)
        self.assertIn("transitionContext.isCancelled", selection_play)
        self.assertIn("onPlaybackReturn)onPlaybackReturn()", selection_play)
        self.assertIn("!self.awaitingWebPlaybackReturn", player_observer)
        self.assertIn("[self updateNowPlayingInfoCenter]", player_observer)
        self.assertIn("currentSession]!=(id<PlaybackSession>)self", now_playing)
        self.assertIn("self.playbackWantsPlayback?", now_playing)
        self.assertIn('@"videoCodec",@"capabilityStatus",@"capabilityReason",@"capabilityReasonMessage"', PLAYBACK_SOURCE)
        self.assertIn('videoCodec:[self.result[@"videoCodec"] isKindOfClass:NSString.class]?self.result[@"videoCodec"]:@""', PLAYBACK_SOURCE)

    def test_automatic_next_episode_restores_play_intent_after_item_completion(self):
        for signature in ("- (void)playerItemEnded:", "- (void)cicadaAdapterDidComplete:"):
            body = method_body(PLAYBACK_SOURCE, signature)
            self.assertIn("self.playbackWantsPlayback=YES", body)
            self.assertLess(body.index("self.playbackWantsPlayback=YES"), body.index("[self resolveAndPlay]"))

    def test_live_overlay_respects_voiceover_and_rearms_after_scrubbing(self):
        overlay = (SOURCES / "PlaybackOverlayController.m").read_text(encoding="utf-8")
        self.assertIn("UIAccessibilityVoiceOverStatusDidChangeNotification", overlay)
        self.assertIn("if(self.visible)[self scheduleAutoHideAfter:3.0]", overlay)
        self.assertIn("else[owner scheduleAutoHideAfter:0.5]", overlay)
        self.assertIn("[self.controlsOverlay rearmAutoHide]", PLAYBACK_SOURCE)

    def test_live_player_fullscreen_control_has_dynamic_accessibility_state(self):
        self.assertIn('accessibilityIdentifier=@"player.control.fullscreen"', ROOT_SOURCE)
        self.assertIn('self.fullscreen?@"退出全屏":@"全屏"', ROOT_SOURCE)
        self.assertIn('self.fullscreen?@"返回频道播放页面":@"全屏显示当前频道"', ROOT_SOURCE)
        self.assertIn("button.titleLabel.hidden=large", method_body(ROOT_SOURCE, "- (void)updatePlaybackControlAccessibility"))
        cell = method_body(ROOT_SOURCE, "- (void)layoutSubviews")
        self.assertIn("textWidth=MIN(textWidth,MAX(0,badgeX-textX-4))", cell)

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
        self.assertIn('table.tableHeaderView=header', RESOURCE_SOURCE)
        self.assertIn('- (void)prepareForNavigationTransition;', RESOURCE_HEADER)
        self.assertIn('- (void)refreshHeaderAfterNavigationTransition;', RESOURCE_HEADER)
        self.assertIn('self.resourceHeaderTopConstraint.constant=MAX(0,self.statusBarSafeInset)+4', RESOURCE_SOURCE)
        self.assertIn('constraintEqualToAnchor:self.resourceHeader.topAnchor constant:4', RESOURCE_SOURCE)
        self.assertIn('- (void)setTopSafeAreaInset:(CGFloat)inset', RESOURCE_SOURCE)
        layout = method_body(ROOT_SOURCE, '- (void)viewDidLayoutSubviews')
        self.assertIn('BOOL resourcePage=[self.tabPage isKindOfClass:ConfigCenterViewController.class]', layout)
        # Step 3：资源页顶边距直接用 view 的 safe.top，不再读 window（window 可能为 nil）。
        self.assertNotIn('self.view.window.safeAreaInsets.top', layout)
        self.assertIn('setTopSafeAreaInset:top]', layout)
        self.assertIn('CGFloat pageTop=0', layout)
        view_will_appear = method_body(RESOURCE_SOURCE, '- (void)viewWillAppear:(BOOL)animated')
        self.assertIn('[self updateResourceHeaderLayoutReattaching:YES]', view_will_appear)
        self.assertNotIn('[self refreshHeaderAfterNavigationTransition]', view_will_appear)
        self.assertIn('NSString *query=self.searchQuery?:@""', RESOURCE_SOURCE)
        self.assertIn('self.resourceActionsButton.hidden=YES', ROOT_SOURCE)

    def test_movie_posters_keep_a_fallback_and_retry_once_after_transient_failure(self):
        self.assertIn('loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView completion:', (SOURCES / "HostImageLoader.h").read_text(encoding="utf-8"))
        self.assertIn('imageView.image=[UIImage systemImageNamed:@"film"]', IMAGE_SOURCE)
        self.assertIn('observer.completion(image!=nil,image?0:retryAfter)', IMAGE_SOURCE)
        feed = (SOURCES / 'MediaFeedView.m').read_text(encoding='utf-8')
        self.assertIn('MediaFeedLoadPosterWithRetry', feed)
        self.assertIn('retriesRemaining', feed)
        self.assertIn('self.poster.image=[UIImage systemImageNamed:@"film"]', feed)
        self.assertIn('MediaFeedLoadPosterWithRetry(poster,self.poster,1)', feed)
        self.assertIn('current.window', feed)
        self.assertIn('accessibilityIdentifier isEqualToString:url', feed)
        self.assertIn('MediaSearchLoadPosterWithRetry(poster,resultCell.poster,1)', (SOURCES / "MediaGlobalSearchViewController.m").read_text(encoding="utf-8"))

    def test_home_and_listing_payloads_filter_bad_rows_and_never_insert_nil_ids(self):
        listing = method_body(BROWSER_SOURCE, "- (void)loadListing:(BOOL)append")
        home = method_body(BROWSER_SOURCE, "- (void)applyHomeResult:(NSDictionary *)result")
        self.assertIn('![result isKindOfClass:NSDictionary.class]', listing)
        self.assertIn('![result[@"items"] isKindOfClass:NSArray.class]', listing)
        self.assertIn('MediaBrowserDictionaryRows(result[@"items"]', listing)
        self.assertIn('MediaBrowserItemIdentity(item)', listing)
        self.assertNotIn('addObject:item[@"id"]', listing)
        self.assertIn('MediaBrowserDictionaryRows(result[@"items"]', home)
        self.assertIn('discarded_item_count', home)

    def test_detail_refresh_keeps_stable_episode_identity_and_player_syncs_parent(self):
        restore = method_body(BROWSER_SOURCE, "- (void)restoreSelectionFromDetail:")
        inline = method_body(BROWSER_SOURCE, "- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context")
        player_update = method_body(PLAYBACK_SOURCE, "- (void)updateEpisodeTitle")
        self.assertIn('lineID.length', restore)
        self.assertIn('episodeID.length', restore)
        self.assertIn('onEpisodeSelectionChanged', inline)
        self.assertIn('owner.selectedEpisodeIndex=episodeIndex', inline)
        self.assertIn('updatedContext[@"episodeIndex"]', player_update)
        self.assertIn('if(self.onEpisodeSelectionChanged)self.onEpisodeSelectionChanged(self.context)', player_update)

    def test_episode_selection_refresh_prefers_ids_before_names(self):
        refresh = method_body(EPISODE_SOURCE, "- (void)refreshDetail")
        self.assertIn('MediaEpisodeSelectionSanitizedDetail(result)', refresh)
        self.assertIn('if(lineID.length)', refresh)
        self.assertIn('if(!lineMatched&&lineName.length)', refresh)
        self.assertIn('if(!episodeMatched&&episodeName.length)', refresh)


if __name__ == "__main__":
    unittest.main()
