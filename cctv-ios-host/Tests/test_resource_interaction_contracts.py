from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceInteractionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = (ROOT / 'Sources/ConfigCenterViewController.m').read_text()
        cls.root = (ROOT / 'Sources/RootViewController.m').read_text()
        cls.editor = (ROOT / 'Sources/ServiceEditorViewController.m').read_text()
        cls.detail = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        cls.playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        cls.episodes = (ROOT / 'Sources/MediaEpisodeSelectionViewController.m').read_text()
        cls.resource_detail = (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text()

    def test_resource_filters_and_service_detail_use_distinct_controls(self):
        for kind in ('all', 'vod', 'live', 'catalog', 'script', 'attention'):
            self.assertIn(f'@"id":@"{kind}"', self.catalog)
        self.assertIn('resource-filter-', self.catalog)
        self.assertIn('profile:profile matchesKind:identifier', self.catalog)
        self.assertIn('initWithArrangedSubviews:@[running,more]', self.catalog)
        self.assertIn('onOpenResource', self.catalog)
        self.assertIn('onToggleProfile(p[@"source"], sender.on)', self.catalog)
        self.assertIn('onToggle=^', self.root)
        self.assertIn('isRunningServiceIdentifier', self.root)

    def test_home_separates_source_and_platform_and_uses_bounded_recommendation_cache(self):
        self.assertIn('MediaHomeModulesSchemaKey', self.detail)
        self.assertIn('@"id":@"recommendations"', self.detail)
        self.assertIn('homeFeatureCardForItem:', self.detail)
        self.assertIn('operation:@"home" arguments:arguments maximumAge:24*60*60', self.detail)
        self.assertIn('selectionRow.hidden=NO', self.detail)
        self.assertIn('media-home-feature', self.detail)
        self.assertIn('owner.generation!=generation', self.detail)

    def test_resource_collection_script_and_native_sources_open_the_film_library(self):
        collection = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        collection_store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        browser_header = (ROOT / 'Sources/MediaBrowserViewController.h').read_text()
        browser = self.detail
        self.assertIn('searchBar.placeholder=@"搜索合集中的站点、协议或 URL"', collection)
        self.assertIn('filteredRowsForSection:', collection)
        self.assertIn('serviceForSite(row)', collection)
        self.assertIn('启动并打开资源', collection)
        self.assertIn('导入并打开资源', collection)
        self.assertIn('仅导入到资源页', collection)
        self.assertIn('onImportSite(row,YES)', collection)
        self.assertIn('onImportSite(row,NO)', collection)
        self.assertIn('资源合集', collection_store)
        self.assertIn('- (void)openSourceIdentifier:(NSString *)identifier', browser_header)
        open_source = browser[browser.index('- (void)openSourceIdentifier:'):
                              browser.index('- (void)showMessage:', browser.index('- (void)openSourceIdentifier:'))]
        self.assertIn('self.sourcesProvider?self.sourcesProvider():@[]', open_source)
        self.assertIn('[self activate:target]', open_source)
        self.assertNotIn('[self refreshSources]', open_source)
        self.assertIn('[browser openSourceIdentifier:item[@"id"]', self.root)
        self.assertIn('[browser openSourceIdentifier:sourceID]', self.root)
        self.assertIn('[service[@"url"] isEqual:api]', self.root)
        self.assertIn('siteCount', self.root)
        self.assertIn('个站点 · %lu 个可用', self.catalog)

    def test_live_resource_uses_declared_route_and_can_configure_missing_route(self):
        self.assertIn('item[@"playlistPath"]', self.root)
        self.assertIn('editor.service=item', self.root)
        self.assertIn('self.playlistPathField', self.editor)
        self.assertIn('playlistPath hasPrefix:@"/"', self.editor)
        self.assertIn('@"http://127.0.0.1:%@%@",item[@"port"],playlist', self.root)

    def test_service_editor_uses_dynamic_type_and_vertical_input_rows(self):
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('self.tableView.rowHeight = UITableViewAutomaticDimension', self.editor)
        self.assertIn('adjustsFontForContentSizeCategory=YES', self.editor)
        self.assertIn('stack.axis=UILayoutConstraintAxisVertical', self.editor)
        self.assertIn('stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor', self.editor)
        self.assertIn('UIContentSizeCategoryAccessibilityExtraExtraExtraLarge', smoke)
        self.assertIn('label does not overlap its input at large text size', smoke)
        self.assertIn('stays inside its large-type editor row', smoke)

    def test_running_http_service_port_edit_stops_saves_and_restarts(self):
        services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        self.assertIn('v.onApplyService = self.onApplyService', services)
        self.assertIn('停止并重启', self.editor)
        self.assertIn('CCTVHostServiceConfigurationSaved', self.editor)
        apply_handler = self.root[self.root.index('page.onApplyService='):self.root.index('page.onBrowseService=', self.root.index('page.onApplyService='))]
        self.assertLess(apply_handler.index('enabled:NO'), apply_handler.index('[ServiceStore save:updatedService]'))
        self.assertLess(apply_handler.index('[ServiceStore save:updatedService]'), apply_handler.index('enabled:YES'))
        self.assertIn('def test_configured_service_port_overrides_hardcoded_primary_http_port',
                      (ROOT / 'Tests/test_service_runtime.py').read_text())

    def test_episode_selection_carries_source_provider_line_and_episode_to_player(self):
        for key in ('@"source"', '@"provider"', '@"detail"', '@"lineIndex"', '@"episodeIndex"'):
            self.assertIn(key, self.episodes)
        self.assertIn('MediaPlaybackViewController *player', self.root)
        self.assertIn('resolveAndPlay', self.playback)
        self.assertIn('self.playerController.player=self.player', self.playback)
        self.assertIn('selectionUpdatesPlayer=YES', self.playback)
        self.assertIn('MediaEpisodeSelectionViewController', self.playback)

    def test_episode_switch_remains_available_during_resolution_and_discards_stale_results(self):
        selector_start = self.episodes.index('- (void)selectEpisode:(UIButton *)sender {')
        selector = self.episodes[selector_start:self.episodes.index('\n@end', selector_start)]
        resolver = self.playback[self.playback.index('- (void)resolveAndPlay'):]
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('NSUInteger generation=++self.generation', selector)
        self.assertIn('owner.generation!=generation', selector)
        self.assertIn('NSUInteger generation=++self.generation', resolver)
        self.assertIn('generation!=owner.generation', resolver)
        self.assertIn('[self cancelWithReason:@"superseded_by_new_request"]', api_client)
        self.assertIn('- (void)cancel { [self cancelWithReason:@"caller_cancelled"]; }', api_client)
        self.assertIn('self.generation++;', api_client)

    def test_detail_embeds_route_and_paged_episode_grid_and_resolves_playback(self):
        detail = self.detail[self.detail.index('@interface MediaDetailViewController'):
                             self.detail.index('@interface MediaBrowserViewController')]
        self.assertIn('media-detail-episode-grid', detail)
        self.assertIn('media-detail-route-', detail)
        self.assertIn('constraintGreaterThanOrEqualToConstant:44', detail)
        self.assertIn('call:@"play"', detail)
        self.assertIn('toggleFavorite', detail)
        self.assertIn('cctv.mediaFavorites.v1', detail)
        self.assertIn('MediaFavoritesViewController', self.detail)
        self.assertIn('openFavorites', self.detail)
        self.assertIn('@"lineIndex"', self.episodes)
        self.assertIn('@"episodeIndex"', self.episodes)
        self.assertIn('viewWillTransitionToSize', self.playback)
        self.assertIn('landscapeConstraints', self.playback)
        self.assertIn('viewDidAppear:(BOOL)animated', self.playback)
        self.assertIn('pendingEpisodeResult', self.playback)

    def test_player_exposes_quality_choices_and_keeps_parse_and_resolution_states_clear(self):
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('self.result[@"alternates"]', self.playback)
        self.assertIn('playback_quality_selected', self.playback)
        self.assertIn('awaitingWebPlaybackReturn', self.playback)
        self.assertIn('if(self.resolving)return', self.playback)
        self.assertIn('resolvedExtension', self.playback)
        self.assertIn('url.user.length||url.password.length', self.playback)
        self.assertIn('[self setRetryAvailable:NO]', self.playback)
        self.assertIn('playback page exposes the source\'s actual alternate quality choices', smoke)
        self.assertIn('quality=low', smoke)
        fixture = (ROOT / 'Tests/UISmoke/fixture_server.py').read_text()
        self.assertIn("if \"?\" in self.path and (self.headers.get(\"Referer\")", fixture)

    def test_media_resource_and_site_pickers_are_separate(self):
        self.assertIn('选择影视资源', self.detail)
        self.assertIn('影视站点：%@，点按切换', self.detail)
        self.assertIn('media-source-selector', self.detail)
        self.assertIn('media-provider-selector', self.detail)
        self.assertIn('selectionRow.bottomAnchor', self.detail)
        self.assertIn('[self updateSelectionControls]', self.detail)
        self.assertIn('- (void)chooseResource', self.detail)
        self.assertIn('- (void)chooseProvider', self.detail)
        self.assertIn('UIModalPresentationPageSheet', self.detail)
        self.assertIn('mediumDetent', self.detail)
        self.assertIn('UITableViewCellAccessoryCheckmark', self.detail)
        self.assertIn('scopeStack', self.detail)
        self.assertIn('NSString *url=[source[@"url"] isKindOfClass:NSString.class]', self.detail)
        self.assertIn('@"url":url', self.detail)

    def test_local_interface_probe_is_bounded_and_does_not_follow_redirects(self):
        self.assertIn('completionHandler(nil)', self.resource_detail)
        self.assertIn('1024*1024', self.resource_detail)
        self.assertIn('timeoutIntervalForResource=7', self.resource_detail)
        self.assertIn('M3UParser parse:text baseURL:url', self.resource_detail)

    def test_starting_imported_service_does_not_implicitly_subscribe_its_playlist(self):
        start = self.root[self.root.index('NSString *playlistPath=[service[@"builtin"]'):
                                          self.root.index('for(NSString *source in self.subscriptionURLs.allObjects)',
                                                          self.root.index('NSString *playlistPath=[service[@"builtin"]'))]
        self.assertIn('if([service[@"builtin"] boolValue]', start)
        use = self.root[self.root.index('page.onUse=^'):
                        self.root.index('page.onLog=^', self.root.index('page.onUse=^'))]
        service_start = self.root.index('- (void)usePluginService:', self.root.index('@implementation RootViewController'))
        service_use = self.root[service_start:
                                self.root.index('- (void)openTVBoxCatalog:', service_start)]
        self.assertIn('[self.subscriptionURLs addObject:url]', service_use)
        self.assertIn('[weakSelf usePluginService:item kind:kind]', use)

    def test_duplicate_remote_import_is_explicit_and_does_not_replace_existing_data(self):
        importer = self.root[self.root.index('- (void)acceptImportedMedia:'):
                             self.root.index('- (void)documentPickerWasCancelled:')]
        self.assertIn('发现相同来源', importer)
        self.assertIn('保留为独立副本', importer)
        self.assertIn('打开已有资源', importer)
        self.assertIn('[ServiceStore remove:identifier]', importer)

    def test_imported_source_url_remains_visible_and_searchable(self):
        self.assertIn('@"title":@"资源来源"', self.resource_detail)
        self.assertIn('copySource', self.resource_detail)
        self.assertIn('p[@"url"]', self.catalog)

    def test_list_restore_stops_when_source_has_no_more_pages(self):
        self.assertIn('owner.pendingRestorePage>requestedPage && [result[@"hasMore"] boolValue] && incoming.count', self.detail)

    def test_tvbox_catalog_import_is_additive_and_adapter_bounded(self):
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        catalog_view = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('ResourceImportOptionTVBox', (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text())
        self.assertIn('TVBoxCatalogStore parseData:data sourceURL:nil', self.root)
        self.assertIn('保留独立副本', self.root)
        self.assertIn('TVBox type 1/4 JSON API', catalog_view)
        self.assertIn('apiKindTVBox', store)
        self.assertIn('TVBox API 请求地址无效或过长', api_client)
        self.assertIn('vod_play_from', api_client)
        self.assertIn('values[@"wd"]', api_client)
        self.assertIn('values[@"ac"]=@"detail"', api_client)
        self.assertIn('values[@"filter"]=@"true"', api_client)
        self.assertIn('values[@"quick"]=@"false"', api_client)
        self.assertIn('MediaTVBoxReservedFilterKeys()', api_client)
        self.assertIn('values[@"play"]', api_client)
        self.assertIn('MediaTVBoxPlaybackHeaders', api_client)
        self.assertIn('result[@"alternates"]=alternates', api_client)
        self.assertIn('apiCode==0', api_client)
        self.assertIn('hasUsablePayload', api_client)
        self.assertIn('initWithTVBoxSource', self.detail)
        self.assertIn('onUseNativeSite', self.root)
        self.assertIn('removeCatalog:', self.root)
        self.assertIn('@"tvboxCatalogs"', store)
        catalog_test = (ROOT / 'Tests/native_profile_tests.m').read_text()
        self.assertIn('type 3 JAR stays unsupported', catalog_test)
        self.assertIn('type 1 direct playback', (ROOT / 'Tests/native_media_api_tests.m').read_text())

    def test_media_home_reuses_existing_history_favorites_and_services(self):
        self.assertIn('MediaPlaybackStateStore.watchHistory', self.detail)
        self.assertIn('trailingSwipeActionsConfigurationForRowAtIndexPath', self.detail)
        self.assertIn('removeHistoryEntryWithKey', self.detail)
        self.assertIn('performsFirstActionWithFullSwipe=NO', self.detail)
        self.assertIn('cctv.mediaFavorites.v1', self.detail)
        self.assertIn('MediaHomePinnedSourcesDefaultsKey', self.detail)
        self.assertIn('sourcesProvider', self.detail)
        self.assertIn('onActivateService', self.detail)
        self.assertIn('media-home-browse-mode', self.detail)
        self.assertIn('openHomeConfiguration', self.detail)
        self.assertIn('@"首页"', self.root)
        self.assertIn('CCTV",@"频道",@"首页",@"资源",@"设置', self.root)
        self.assertIn('@"频道"', self.root)

    def test_global_search_reports_each_source_and_retries_failures(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        self.assertIn('已完成 %lu / %lu 个资源', search)
        self.assertIn('重试失败', search)
        self.assertIn('retryFailedSources', search)
        self.assertIn('部分完成', search)
        self.assertIn('failedProviders', search)
        self.assertIn('retryProviders', search)
        self.assertIn('sourceAvailableForSearch', search)
        self.assertIn('不会自动启动其他插件', search)
        self.assertIn('MediaGlobalSearchMaximumConcurrentSources = 3', search)
        self.assertIn('MediaGlobalSearchJob', search)
        self.assertIn('searchNextProviderForJob', search)
        self.assertIn('cancelJobsAndAdvanceGeneration', search)
        self.assertIn('enqueueStartedSection', search)
        self.assertIn('initWithTVBoxSource:source', search)

    def test_signed_media_urls_keep_parameters_and_relay_failures_are_stage_specific(self):
        relay = (ROOT / 'Plugins/host_media_relay.py').read_text()
        service = (ROOT / 'Plugins/media-service.py').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        native_tests = (ROOT / 'Tests/native_media_api_tests.m').read_text()
        for stage in ('upstream_http_error', 'upstream_timeout', 'upstream_network_error',
                      'upstream_dns_error', 'upstream_tls_error', 'upstream_connect_error',
                      'manifest_invalid', 'manifest_encoding_invalid', 'manifest_too_large'):
            self.assertIn(stage, relay)
        self.assertIn('parent.query', relay)
        self.assertIn('fallback_url', relay)
        self.assertIn('X-CCTVHost-Relay-Stage', relay)
        self.assertIn('diagnostic_id=correlation_id or request_id', service)
        self.assertIn('alternate[\'originalURL\'] = address', service)
        self.assertIn('alternate[@"originalURL"]', self.playback)
        self.assertIn('X-CCTVHost-Correlation-ID', api_client)
        self.assertIn('extensionless signed media URL stays intact', native_tests)
        self.assertIn('detail preserves signed episode URLs byte-for-byte', native_tests)

    def test_player_distinguishes_item_ready_from_first_frame_ready(self):
        self.assertIn('AVPlayerItemStatusFailed', self.playback)
        self.assertIn('AVPlayerLayer', self.playback)
        self.assertIn('readyForDisplay', self.playback)
        self.assertIn('playback_first_frame_ready', self.playback)
        headers = (ROOT / 'Sources/MediaPlaybackHeaders.m').read_text()
        self.assertIn('MediaPlaybackHeadersFromResult(result)', self.playback)
        self.assertIn('AVURLAssetHTTPHeaderFieldsKey', self.playback)
        self.assertIn('result[@"headers"]', headers)
        self.assertIn('result[@"header"]', headers)
        self.assertIn('@"host"', headers)
        fixture = (ROOT / 'Tests/UISmoke/fixture_server.py').read_text()
        self.assertIn('X-Fixture-Playback', fixture)
        self.assertIn('self.headers.get("Referer")', fixture)
        self.assertIn('等待视频帧超时', self.playback)
        self.assertNotIn('首帧渲染状态未知', self.playback)

    def test_tvbox_playback_keeps_native_api_client_across_episode_switches_and_auto_next(self):
        self.assertIn('MediaPlaybackClientForSource', self.playback)
        self.assertIn('MediaSourceUsesNativeCatalogAPI(source)', self.playback)
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('[protocol isEqual:@"tvbox-api"]', api_client)
        self.assertIn('[protocol isEqual:@"maccms-api"]', api_client)
        self.assertIn('self.client=MediaPlaybackClientForSource(source)', self.playback)
        self.assertIn('page.client=MediaPlaybackClientForSource(page.source)', self.playback)
        self.assertIn('cctv.mediaAutoPlayNext', self.playback)
        self.assertIn('playback_auto_advance', self.playback)
        self.assertIn('self.episodeIndex+1<self.episodes.count', self.playback)
        self.assertIn('关闭自动连播下一集', self.playback)
        self.assertIn('开启自动连播下一集', self.playback)

    def test_tvbox_filters_and_playback_flags_survive_native_adaptation(self):
        client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('MediaTVBoxFilters(root)', client)
        self.assertIn('arguments[@"filters"]', client)
        self.assertIn('clearFilters', self.detail)
        self.assertIn('result[@"jx"]', self.playback)
        self.assertIn('result[@"requiresWebPlayback"]', self.playback)
        self.assertNotIn('@"filters":@{}', client)
        self.assertIn('MediaTVBoxResolvedPoster', client)
        self.assertIn('TVBoxWebURL(resolved.absoluteString)', (ROOT / 'Sources/TVBoxCatalogStore.m').read_text())

    def test_global_search_uses_bounded_source_health_cooldowns(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        health = (ROOT / 'Sources/MediaSourceHealthStore.m').read_text()
        self.assertIn('sortPendingSectionsByHealth', search)
        self.assertIn('recordSourceID:job.source', search)
        self.assertIn('MediaSourceHealthLimit = 128', health)
        self.assertIn('MediaSourceHealthExpiry = 7 * 24 * 60 * 60', health)
        self.assertIn('MIN(600,30*pow', health)

    def test_media_http_health_precedes_slow_spider_init_and_capabilities_retry_busy(self):
        service = (ROOT / 'Plugins/media-service.py').read_text()
        runtime = (ROOT / 'Plugins/host_media_runtime.py').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        load_capabilities = self.detail[self.detail.index('- (void)loadCapabilities {'):
                                        self.detail.index('- (void)loadHome {', self.detail.index('- (void)loadCapabilities {'))]
        self.assertLess(service.index('server = Server((args.bind, args.port), runtime)'),
                        service.index('runtime.start_initialization(create_engine, initialization_failed)'))
        self.assertIn("'runtime_state': self._state", runtime)
        self.assertIn("MediaError('BUSY', '影视资源脚本正在准备", runtime)
        self.assertIn('@"plugin_retryable":@(pluginRetryable)', api_client)
        self.assertIn('error.userInfo[@"plugin_retryable"]', load_capabilities)
        self.assertIn('capabilityReadinessRetryCount<45', load_capabilities)
        self.assertIn('资源脚本正在准备', load_capabilities)

    def test_playback_recovery_is_generation_scoped_and_quality_restores_pause_state(self):
        self.assertIn('owner.stallRecoveryAttempts>=1', self.playback)
        self.assertIn('playback_stall_recovery_started', self.playback)
        self.assertIn('generation!=owner.playerGeneration', self.playback)
        self.assertIn('pendingQualityWasPlaying', self.playback)
        self.assertIn('未能按名称确认分集', self.playback)

    def test_settings_expose_bounded_movie_metadata_cache_cleanup(self):
        settings = (ROOT / 'Sources/SettingsViewController.m').read_text()
        cache = (ROOT / 'Sources/MediaMetadataCache.m').read_text()
        self.assertIn('clearMediaMetadata', settings)
        self.assertIn('收藏、观看历史、订阅和插件数据会保留', settings)
        self.assertIn('MediaMetadataCacheEntryLimit = 64', cache)
        self.assertIn('MediaMetadataCacheByteLimit = 8 * 1024 * 1024', cache)
        self.assertNotIn('@"detail"', cache)
        self.assertIn('影片详情与播放线路不缓存', settings)

    def test_rotation_is_limited_to_the_player_and_supported_by_the_app(self):
        with (ROOT / 'Resources/Info.plist').open('rb') as f:
            plist = plistlib.load(f)
        self.assertIn('UIInterfaceOrientationLandscapeLeft', plist['UISupportedInterfaceOrientations'])
        self.assertIn('UIInterfaceOrientationLandscapeRight', plist['UISupportedInterfaceOrientations'])
        app_delegate = (ROOT / 'Sources/AppDelegate.m').read_text()
        self.assertIn('self.topViewController.supportedInterfaceOrientations', app_delegate)
        self.assertIn('supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait;', self.root)
        self.assertIn('supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}', self.detail)
        self.assertIn('UIInterfaceOrientationMaskAllButUpsideDown', self.playback)


if __name__ == '__main__':
    unittest.main()
