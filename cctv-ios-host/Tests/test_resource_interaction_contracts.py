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
        cls.service_store = (ROOT / 'Sources/ServiceStore.m').read_text()

    def test_player_exit_cancels_work_after_confirmed_transition(self):
        will = self.playback.split('- (void)viewWillDisappear:', 1)[1].split('- (void)viewDidDisappear:', 1)[0]
        did = self.playback.split('- (void)viewDidDisappear:', 1)[1].split('- (void)viewWillAppear:', 1)[0]
        self.assertIn('self.navigationController.isBeingDismissed', will)
        self.assertNotIn('[self.client cancel]', will)
        self.assertIn('if(!self.pendingScreenExit)return;', did)
        self.assertLess(did.index('self.generation++'), did.index('[self.client cancel]'))
        self.assertIn('[self clearCurrentPlayerItem]', did)
        self.assertIn('replaceCurrentItemWithPlayerItem:nil', did)
        appeared = self.playback.split('- (void)viewDidAppear:', 1)[1].split('- (void)viewWillDisappear:', 1)[0]
        self.assertIn('self.pendingScreenExit=NO', appeared)

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

    def test_resource_single_taps_show_details_or_choices_instead_of_implicitly_switching_pages(self):
        selection = self.catalog[self.catalog.index('- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:'):]
        self.assertIn('self.onOpenResource(source)', selection)
        self.assertNotIn('self.onUseResource(source', selection)
        self.assertIn('打开频道', selection)
        self.assertIn('编辑订阅与节目单', selection)
        self.assertIn('添加直播频道', self.catalog)
        self.assertIn('进入影视', self.catalog)

    def test_python_http_playlist_addresses_are_displayed_and_auto_subscribed_on_start(self):
        start = self.root[self.root.index('- (BOOL)startService:'):
                          self.root.index('- (void)toggleService:', self.root.index('- (BOOL)startService:'))]
        self.assertIn('[ServiceStore subscriptionURLForService:service]', start)
        self.assertIn('服务订阅地址：%@', start)
        self.assertIn('节目单地址：', start)
        self.assertIn('[self.subscriptionURLs addObject:playlistURL]', start)
        self.assertIn('@"managedServiceID":serviceID', start)
        self.assertIn('if(health)c.path=@"/health"', self.root)
        self.assertIn('playlistPathForService:service', self.root)
        self.assertIn('节目单地址', (ROOT / 'Sources/ServicesViewController.m').read_text())
        self.assertIn('服务订阅地址', self.resource_detail)
        self.assertIn('节目单地址', self.resource_detail)
        self.assertIn('节目单地址：%@', self.root)

    def test_playing_a_stopped_managed_channel_starts_its_own_service_then_checks_readiness(self):
        start = self.root[self.root.index('- (void)startRemoteChannel:'):
                          self.root.index('- (void)failRemoteReadiness:', self.root.index('- (void)startRemoteChannel:'))]
        self.assertIn('[self changeService:service enabled:YES completion:', start)
        self.assertIn('continueRemotePlaybackForURL:u service:service generation:generation', start)
        self.assertIn('generation!=owner.playbackGeneration', start)
        self.assertIn('local_service_start_for_playback_requested', start)
        self.assertIn('正在启动本机服务', start)
        self.assertNotIn('请先在服务页启动此自定义 Python 服务', start)

    def test_local_channel_service_resolution_uses_subscription_owner_and_rejects_ambiguous_ports(self):
        lookup_start = self.root.index('- (NSDictionary *)localServiceForURL:')
        lookup_end = self.root.index('- (NSArray<NSString *> *)managedSubscriptionSourcesForService:', lookup_start)
        lookup = self.root[lookup_start:lookup_end]
        self.assertIn('managedServiceID', lookup)
        self.assertIn('matches.count==1', lookup)
        self.assertIn('if(running)return nil', lookup)
        self.assertIn('localServiceForChannel:ch URL:', self.root)
        self.assertIn('channel[@"subscriptionSources"]', lookup)

    def test_service_status_and_successful_port_migration_reach_all_resource_views(self):
        install = self.root[self.root.index('- (void)installPlaylist:'):
                            self.root.index('- (void)applyPlaylistText:', self.root.index('- (void)installPlaylist:'))]
        self.assertIn('managedSubscriptionSourcesForService', install)
        self.assertIn('retiredSourceSet', install)
        self.assertLess(install.index('snapshot.length>4*1024*1024'), install.index('[ProfileStore remove:retiredSource]'))
        self.assertIn('migratedDisabled', install)
        self.assertIn('replacementOrderIndex', install)
        self.assertLess(install.index('snapshot.length>4*1024*1024'), install.index('replacementOrderIndex'))
        self.assertIn('ProfileStoreMetadataDidChangeNotification', install)
        services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        self.assertIn('订阅清单状态', services)
        self.assertIn('最近成功刷新', services)
        self.assertIn('section == 2 ? 12', services)
        self.assertIn('probePlaylistChecked', services)
        self.assertIn('probeChannelCount=channels.count', services)
        self.assertIn('probeChannelCount', services)
        self.assertIn('channelCount', self.root)
        self.assertIn('subscriptionStatus', self.catalog)
        self.assertIn('openServiceEditorForService', self.root)
        self.assertIn('editor.onApplyService=', self.root)

    def test_playlist_errors_are_searchable_and_visible_in_attention_filter(self):
        self.assertIn('profile[@"subscriptionStatus"]', self.catalog)
        self.assertIn('[playlistStatus containsString:@"失败"]', self.catalog)
        self.assertIn('subscriptionStatus', self.catalog)
        self.assertIn('刷新中…', self.root)
        self.assertIn('ProfileStoreMetadataDidChangeNotification object:sourceKey', self.root)

    def test_resource_ui_keeps_full_source_query_while_logs_redact_query_values(self):
        address = self.root[self.root.index('static NSString *CCTVServiceLogAddress'):
                            self.root.index('static NSString *CCTVRouteGroupKey')]
        self.assertIn('value:item.value.length?@"[已脱敏]":item.value', address)
        self.assertIn('CCTVServiceLogAddress(sourceKey)', self.root)
        self.assertIn('CCTVServiceLogAddress(u)', self.root)
        self.assertIn('"value":subscription', self.resource_detail)
        self.assertIn('p[@"subscriptionURL"]', self.catalog)

    def test_home_separates_source_and_platform_and_uses_bounded_recommendation_cache(self):
        self.assertIn('MediaHomeModulesSchemaKey', self.detail)
        self.assertIn('@"id":@"recommendations"', self.detail)
        self.assertIn('homeFeatureCardForItem:', self.detail)
        self.assertIn('operation:@"home" arguments:arguments maximumAge:24*60*60', self.detail)
        self.assertIn('selectionRow.hidden=NO', self.detail)
        self.assertIn('media-home-feature', self.detail)
        self.assertIn('- (void)addHomeFeatureCarousel:', self.detail)
        self.assertIn('pagingEnabled=YES', self.detail)
        self.assertIn('UIPageControl', self.detail)
        self.assertIn('MIN((NSUInteger)5,items.count)', self.detail)
        self.assertIn('owner.generation!=generation', self.detail)

    def test_home_uses_reference_style_category_rails_from_real_source_results(self):
        self.assertIn('@"id":@"catalog"', self.detail)
        self.assertIn('- (void)loadHomeShelves:', self.detail)
        self.assertIn('operation:@"category" arguments:arguments maximumAge:6*3600', self.detail)
        self.assertIn('MIN((NSUInteger)8,categories.count)', self.detail)
        self.assertIn('@"media_home_shelf_readable"', self.detail)
        self.assertIn('@"media_home_shelf_failed"', self.detail)
        self.assertIn('- (BOOL)isHomePageVisible', self.detail)
        self.assertIn('top==self||top==self.parentViewController', self.detail)
        self.assertIn('homeCardWithTitle:item[@"name"]', self.detail)
        self.assertIn('homeSectionHeader:name', self.detail)
        self.assertIn('[heading addArrangedSubview:all]', self.detail)
        self.assertIn('setInteger:3 forKey:MediaHomeModulesSchemaKey', self.detail)

    def test_movie_detail_uses_soft_backdrop_real_cast_and_actionable_controls(self):
        detail = self.detail[self.detail.index('@interface MediaDetailViewController'):
                             self.detail.index('@interface MediaFavoritesViewController')]
        self.assertIn('media-detail-backdrop', detail)
        self.assertIn('UIBlurEffectStyleSystemMaterial', detail)
        self.assertIn('media-detail-share', detail)
        self.assertIn('media-detail-copy-title', detail)
        self.assertIn('media-detail-jump-episodes', detail)
        self.assertIn('- (void)refreshCastRow', detail)
        self.assertIn('person.crop.circle.fill', detail)
        self.assertIn('self.castTitle.hidden=names.count==0', detail)
        self.assertIn('multiplier:0.94', detail)

    def test_media_browser_cancels_parent_requests_and_resumes_after_child_navigation(self):
        self.assertIn('media_request_cancelled_on_page_exit', self.detail)
        self.assertIn('self.generation++;self.homeShelfGeneration=0', self.detail)
        self.assertIn('[self.client cancel]', self.detail)
        self.assertIn('resumeCancelledMediaRequestOnAppear', self.detail)
        self.assertIn('homeShelfRequestInFlight', self.detail)
        self.assertIn('if([operation isEqualToString:@"home_shelf"])', self.detail)
        self.assertIn('self.activeMediaOperation=@"home_shelf"', self.detail)

    def test_home_status_is_inline_actionable_and_does_not_rebuild_content_on_each_progress_update(self):
        show_message = self.detail[self.detail.index('- (void)showMessage:'):
                                   self.detail.index('- (void)chooseResource', self.detail.index('- (void)showMessage:'))]
        status = self.detail[self.detail.index('- (void)updateHomeStatusCard {'):
                             self.detail.index('- (void)performHomeStatusAction', self.detail.index('- (void)updateHomeStatusCard {'))]
        self.assertIn('media-home-status-card', status)
        self.assertIn('media-home-status-action', status)
        self.assertIn('启动并加载', status)
        self.assertIn('self.homeMode', show_message)
        self.assertIn('[self updateHomeStatusCard]', show_message)
        self.assertNotIn('[self refreshHomeModules]', show_message)
        self.assertIn('self.homeScroll.contentOffset=CGPointMake', self.detail)

    def test_home_plugin_deep_links_wait_for_health_and_capabilities_before_detail(self):
        implementation = self.detail.index('@implementation MediaBrowserViewController')
        recommendation_start = self.detail.index('- (void)openHomeRecommendation:', implementation)
        recommendation = self.detail[recommendation_start:
                                     self.detail.index('- (void)browsePinnedSource:', recommendation_start)]
        favorite_start = self.detail.index('- (void)openHomeFavorite:', implementation)
        favorite = self.detail[favorite_start:
                               self.detail.index('- (void)openPendingHomeDetailForSource:', favorite_start)]
        self.assertIn('self.pendingHomeDetail=', recommendation)
        self.assertIn('[self activate:source keepingHome:YES]', recommendation)
        self.assertNotIn('self.onActivateService(source,', recommendation)
        self.assertIn('self.pendingHomeDetail=', favorite)
        self.assertIn('[self activate:source keepingHome:YES]', favorite)
        capabilities_start = self.detail.index('- (void)loadCapabilities {', implementation)
        capabilities = self.detail[capabilities_start:
                                   self.detail.index('- (void)loadHome {', capabilities_start)]
        self.assertIn('owner.generation!=generation', capabilities)
        self.assertIn('[page openPendingHomeDetailForSource:page.source', capabilities)
        self.assertIn('openPendingHomeDetailForSource:owner.source', capabilities)

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
        self.assertIn('[ServiceStore subscriptionURLForService:item]', self.root)
        self.assertIn('[self openServiceEditorForService:item]', self.root)
        self.assertIn('editor.onApplyService=', self.root)
        self.assertIn('self.playlistPathField', self.editor)
        self.assertIn('[ServiceStore playlistPathForService:self.service]', self.editor)
        self.assertIn('playlistPath hasPrefix:@"/"', self.editor)
        self.assertIn('未配置直播列表', self.root + (ROOT / 'Sources/ServicesViewController.m').read_text())

    def test_playlist_route_inference_requires_route_evidence(self):
        self.assertIn('Only infer a URL when it appears in an actual route declaration', self.service_store)
        self.assertIn('legacyPythonHTTP', self.service_store)
        self.assertIn('if(!nanoTVLive&&!pythonHTTP&&!legacyPythonHTTP)return nil', self.service_store)
        self.assertIn('add_url_rule|add_get|add_route', self.service_store)
        self.assertIn('route|playlist(?:_path)?|m3u_path', self.service_store)
        self.assertIn('inferredPlaylistPathInCode:entryText', (ROOT / 'Sources/MediaPackageImporter.m').read_text())
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('@"resolvedPlaylistPath":[ServiceStore playlistPathForService:service]',native)
        self.assertIn('--playlist-check',native)
        fixture=(ROOT / 'Tests/test_native_package.py').read_text()
        self.assertIn('test_python_spider_routes_are_not_misidentified_as_local_live_subscriptions',fixture)
        self.assertIn('test_only_live_service_protocols_expose_declared_playlist_paths',fixture)

    def test_resource_updates_refresh_detected_runtime_defaults_but_preserve_manual_overrides(self):
        importer=(ROOT / 'Sources/MediaPackageImporter.m').read_text()
        editor=(ROOT / 'Sources/ServiceEditorViewController.m').read_text()
        self.assertIn('@"argumentsSource":@"inferred"', importer)
        self.assertIn('importedService[@"playlistPathSource"]=@"inferred"', importer)
        self.assertIn('runtimeChanged||inferredArguments', self.service_store)
        self.assertIn('hasManualPlaylist', self.service_store)
        self.assertIn('argumentsSource"] isEqual:@"inferred"', self.service_store)
        self.assertIn('playlistPathSource"] isEqual:@"inferred"', self.service_store)
        self.assertIn('service[@"argumentsSource"]=@"manual"', editor)
        self.assertIn('service[@"playlistPathSource"]=@"manual"', editor)
        self.assertIn('留空自动识别，或填 /all.m3u', editor)
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('--update-manual', native)
        self.assertIn('rollbackRestoredPlaylist', native)

    def test_resource_detail_exposes_import_metadata_and_explains_md5_boundary(self):
        importer=(ROOT / 'Sources/MediaPackageImporter.m').read_text()
        self.assertIn('clean[@"pluginVersion"]=pluginVersion', importer)
        self.assertIn('package[@"version"]', importer)
        self.assertIn('@"title":@"资源版本"', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())
        self.assertIn('@"title":@"入口文件"', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())
        self.assertIn('完整性校验，不是数字签名', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())

    def test_import_progress_distinguishes_checksum_runtime_inspection_and_persistence(self):
        downloader=(ROOT / 'Sources/MediaPackageDownloader.m').read_text()
        for stage in ('MD5 校验值已读取','MD5 校验通过','未验证来源完整性',
                      '检查资源入口、运行时与协议','识别完成 · 保存到本机资源库'):
            self.assertIn(stage,downloader)
        progress=downloader[downloader.index('- (void)progress:'):downloader.index('- (void)importURL:')]
        self.assertIn('lastProgressStage',progress)
        self.assertIn('stageChanged',progress)
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('@"progressStages":progressStages',native)
        remote=(ROOT / 'Tests/test_native_package.py').read_text()
        self.assertIn("stages=result['progressStages']",remote)

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
        implementation = self.root.index('@implementation RootViewController')
        apply_start = self.root.index('- (void)applyServiceConfigurationFrom:', implementation)
        apply_handler = self.root[apply_start:self.root.index('- (void)usePluginService:', apply_start)]
        self.assertLess(apply_handler.index('enabled:NO'), apply_handler.index('[ServiceStore save:updated]'))
        self.assertLess(apply_handler.index('[ServiceStore save:updated]'), apply_handler.index('enabled:YES'))
        self.assertIn('associateLegacyLoopbackSubscriptionsForService:previous', apply_handler)
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
        self.assertIn('MediaPlaybackResultSupportsAVPlayer(result)', self.playback)
        self.assertIn('url.user.length||url.password.length', self.playback)
        self.assertIn('[self setRetryAvailable:NO]', self.playback)
        self.assertIn('playback page exposes the source\'s actual alternate quality choices', smoke)
        self.assertIn('quality=low', smoke)

    def test_quality_specific_headers_survive_source_normalization_relay_and_selection(self):
        runtime = (ROOT / 'Plugins/host_media_runtime.py').read_text()
        service = (ROOT / 'Plugins/media-service.py').read_text()
        api = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn("choice_headers.update(media_headers(item.get('headers', {})))", runtime)
        self.assertIn("'baseHeaders': media_headers(base_headers)", runtime)
        self.assertIn("alternate_headers.update(alternate.get('headers') or {})", service)
        self.assertIn('alternate_headers or is_declared_hls(alternate_media, address)', service)
        self.assertIn('def is_extensionless_url(url):', service)
        self.assertIn('or is_extensionless_url(result.get(\'url\'))', service)
        self.assertIn('MediaTVBoxPlaybackHeaders(source,root)', api)
        self.assertIn('MediaTVBoxPlaybackHeaders(@{},choice)', api)
        self.assertIn('choiceHeaders=[headers mutableCopy]', api)
        self.assertIn('MediaPlaybackHeadersFromResult(alternate)', self.playback)
        self.assertIn('basePlaybackHeaders', self.playback)
        self.assertIn('test_quality_specific_headers_reach_hls_alternate',
                      (ROOT / 'Tests/test_media_runtime.py').read_text())
        self.assertIn('per-quality request headers survive TVBox normalization',
                      (ROOT / 'Tests/native_media_api_tests.m').read_text())
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

    def test_starting_python_http_adds_the_configured_subscription_without_inventing_missing_routes(self):
        start = self.root[self.root.index('- (BOOL)startService:'):
                          self.root.index('- (void)toggleService:', self.root.index('- (BOOL)startService:'))]
        self.assertIn('NSString *playlistURL=[ServiceStore subscriptionURLForService:service]', start)
        self.assertIn('if(playlistURL.length)', start)
        self.assertIn('else if([service[@"protocol"] isEqual:@"python-http"])', start)
        self.assertIn('不会添加猜测地址', start)
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
        self.assertIn('media-home-browse-button', self.detail)
        self.assertIn('media-home-search-button', self.detail)
        self.assertIn('homeSearchButton.hidden=!hidden', self.detail)
        self.assertIn('onDisplayModeChanged', self.root)
        self.assertIn('[owner activate:source keepingHome:YES]', self.detail)
        self.assertIn('openHomeConfiguration', self.detail)
        self.assertIn('@"首页"', self.root)
        self.assertIn('CCTV",@"频道",@"首页",@"资源",@"设置', self.root)
        self.assertIn('@"频道"', self.root)

    def test_global_search_filters_restore_state_and_cancel_changed_queries(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        self.assertIn('media-search-station-filters', search)
        self.assertIn('[self.renderedFilterKey isEqual:self.filterPositionKey]', search)
        self.assertIn('MediaSearchEntries(entries,provider).count', search)
        self.assertIn('MediaSearchAppend(stored,items,providerID,providerName,remaining)', search)
        self.assertIn('HostImageLoader.shared loadURL:', search)
        self.assertIn('暂无影片信息', search)
        self.assertIn('@"无结果"', search)
        self.assertIn('@"来源失败"', search)
        changed = search.split('textDidChange:(NSString *)searchText', 1)[1].split('- (BOOL)sourceAvailableForSearch:', 1)[0]
        self.assertIn('[self cancelSearch]', changed)
        self.assertIn('[self cancelJobsAndAdvanceGeneration]', changed)
        self.assertIn('self.keyword=@""', changed)
        self.assertIn('self.savedSearchOffset=self.tableView.contentOffset', search)
        self.assertIn('[self restoreReadingPosition:self.savedReadingPosition]', search)
        self.assertIn('if(!self.resultsVisible){return;}', search)
        self.assertIn('hasSubmittedSearchInput', search)
        self.assertIn('self.selectedProvider&&!sourceFailed', search)
        self.assertIn('job.generation == self.generation', search)
        self.assertIn('self.jobs[@(job.section)] == job', search)

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

    def test_web_playback_close_keeps_native_fallback_action_available(self):
        appeared = self.playback[self.playback.index('- (void)viewDidAppear:'):
                                 self.playback.index('- (void)viewWillDisappear:')]
        fallback = self.playback[self.playback.index('- (void)tryNativePlayback {'):
                                 self.playback.index('- (void)selectLine:')]
        webview = (ROOT / 'Sources/MediaWebViewController.m').read_text()
        self.assertIn('网页播放已关闭 · 可尝试原生播放', appeared)
        self.assertIn('[self setRetryAvailable:YES]', appeared)
        self.assertNotIn('self.awaitingWebPlaybackReturn=NO', appeared)
        self.assertIn('candidate[@"playbackMethodOverride"]=@"avplayer"', fallback)
        self.assertIn('web.onTryNativePlayback=^{[weakSelf tryNativePlayback];}', self.playback)
        self.assertIn('@"原生播放"', webview)
        self.assertIn('installCookieHeader:cookie forURL:configurationURL', webview)
        self.assertIn('httpCookieStore setCookie:item', webview)
        self.assertIn('WKWebsiteDataStore.nonPersistentDataStore', webview)

    def test_no_media_error_offers_the_original_episode_page_without_exposing_its_url(self):
        self.assertIn('MediaPlaybackEpisodePageFallbackURL', self.playback)
        self.assertIn('pluginCode isEqualToString:@"NO_MEDIA"', self.playback)
        self.assertIn('owner.episodeWebFallbackAvailable=pageURL!=nil', self.playback)
        self.assertIn('@selector(openEpisodePageWebFallback)', self.playback)
        self.assertIn('episode_web_fallback_available', self.playback)
        self.assertIn('打开分集网页尝试播放', self.playback)
        self.assertNotIn('fields[@"episode_url"]', self.playback)

    def test_extensionless_signed_media_endpoints_use_native_playback_classification(self):
        client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        native_tests = (ROOT / 'Tests/native_media_api_tests.m').read_text()
        self.assertIn('MediaTVBoxQueryNameLooksSigned', client)
        self.assertIn('@"token",@"sign",@"auth"', client)
        self.assertIn('[compact hasSuffix:@"key"]', client)
        self.assertIn('camel-case auth and session tokens uses native playback', native_tests)
        self.assertIn('playback_has_signed_parameter', playback)

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

    def test_media_health_waits_for_spider_ready_without_repeating_busy_api_calls(self):
        readiness = (ROOT / 'Sources/LocalServiceReadiness.m').read_text()
        browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        self.assertIn('healthJSON[@"runtime_ready"]', readiness)
        self.assertIn('@"runtime_preparing"', readiness)
        self.assertIn('@"runtime_failed"', readiness)
        self.assertIn('pollInterval = [self.lastFailureKind isEqualToString:@"runtime_preparing"] ? 0.75 : 0.3', readiness)
        self.assertIn('initWithURL:health timeout:45 requiresHealthJSON:YES', browser)

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
