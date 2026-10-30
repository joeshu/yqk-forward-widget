import pathlib
import re
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "RootViewController.m"
TEXT = SOURCE.read_text(encoding="utf-8")
PYHOST = (SOURCE.parent / "PyHost.m").read_text(encoding="utf-8")
PLUGIN = (SOURCE.parent / "PluginViewController.m").read_text(encoding="utf-8")
SETTINGS = (SOURCE.parent / "SettingsViewController.m").read_text(encoding="utf-8")
SERVICES = (SOURCE.parent / "ServicesViewController.m").read_text(encoding="utf-8")
EPG = (SOURCE.parent / "EPGViewController.m").read_text(encoding="utf-8")
CONFIG = (SOURCE.parent / "ConfigCenterViewController.m").read_text(encoding="utf-8")
SERVICE_UI = (SOURCE.parent / "ServicesViewController.m").read_text(encoding="utf-8")
REDACTOR = (SOURCE.parent / "HostLogRedactor.m").read_text(encoding="utf-8")


def method_body(signature):
    start = TEXT.index(signature)
    opening = TEXT.index("{", start)
    depth = 0
    for index in range(opening, len(TEXT)):
        if TEXT[index] == "{":
            depth += 1
        elif TEXT[index] == "}":
            depth -= 1
            if depth == 0:
                return TEXT[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class RootViewControllerSourceContracts(unittest.TestCase):
    def test_native_metadata_preload_survives_selection_until_channel_match(self):
        selection = method_body("- (void)playChannel:")
        startup = method_body("- (void)playViaSDK:")
        self.assertNotIn("[self.nativePreloader cancel]", selection)
        self.assertLess(startup.index("takeChannel:cid"), startup.index("[self.nativePreloader cancel]"))

    def test_subscription_refresh_is_source_owned_and_replaces_stale_entries(self):
        body = method_body("- (void)installPlaylist:")
        self.assertIn("stableURLKey:", body)
        self.assertIn('existing[@"subscriptionSources"]', body)
        self.assertIn("[owners removeObject:sourceKey]", body)
        self.assertIn("subscriptionSources", body)
        self.assertIn('urlIndexes[stable]', body)

    def test_delete_removes_only_source_owned_channels_and_invalidates_fetch(self):
        body = method_body("- (void)removeSubscriptionSource:")
        self.assertIn("[sources removeObject:sourceKey]", body)
        self.assertIn("if (!sources.count) continue", body)
        self.assertIn("self.allChannels = kept", body)
        delete_block = TEXT[TEXT.index('actionWithTitle:@"删除"'):TEXT.index('actionWithTitle:@"取消"', TEXT.index('actionWithTitle:@"删除"'))]
        self.assertIn("subscriptionRequestVersions", delete_block)
        self.assertIn("removeSubscriptionSource:", delete_block)

    def test_subscription_response_is_version_guarded(self):
        body = method_body("- (void)fetchSubscription:")
        self.assertIn("requestVersion", body)
        self.assertIn("!= requestVersion", body)
        self.assertIn("if(self.subscriptionTasks[sourceKey])", body)
        self.assertNotIn("[self.subscriptionTasks[sourceKey] cancel]", body)
        self.assertNotIn("components.query=nil", method_body("- (NSString *)stableURLKey:"))

    def test_playback_waits_for_starting_service_http_readiness(self):
        start = method_body("- (void)startRemoteChannel:")
        self.assertIn("continueRemotePlaybackForURL:u service:service generation:generation", start)
        self.assertNotIn("stateError=[NSError errorWithDomain:@\"CCTVHostService\" code:3", start)
        readiness = method_body("- (void)continueRemotePlaybackForURL:(NSString *)u service:(NSDictionary *)service generation:(NSUInteger)generation {")
        self.assertIn("isStartingServiceIdentifier:service[@\"id\"]", readiness)
        self.assertIn("readinessForURL:[NSURL URLWithString:u] service:service", readiness)
        self.assertIn('isEqualToString:@"python"]?[PyHost startupErrorForServiceIdentifier:', readiness)
        self.assertIn("startupErrorForServiceIdentifier:service[@\"id\"]", readiness)

    def test_subscription_page_supports_per_source_refresh_and_real_last_success(self):
        self.assertIn("onRefreshProfile", CONFIG)
        self.assertIn("刷新此订阅", CONFIG)
        self.assertIn("updatedAt", method_body("- (NSArray *)configurationProfiles"))
        self.assertIn("最近成功", CONFIG)
        self.assertIn("confirmRemoveProfile", CONFIG)
        self.assertIn("其他订阅源共同提供的频道会保留", CONFIG)

    def test_epg_cache_rejects_future_timestamps(self):
        body = method_body("- (void)loadEPGCache")
        self.assertRegex(body, r"ts\s*<=\s*now")
        self.assertRegex(body, r"now\s*-\s*ts\s*<\s*6\s*\*\s*3600")

    def test_now_next_uses_cache_and_rejects_stale_playback_callback(self):
        body = method_body("- (void)refreshNowNext") + method_body("- (void)refreshOfficialNowNext")
        self.assertIn("NSDictionary *cached = self.epgCache[cid]", body)
        self.assertIn("epgGeneration != weakSelf.playbackGeneration", body)
        self.assertIn("![weakSelf.channelID isEqualToString:cid]", body)

    def test_panda_official_feed_is_grouped_but_not_claimed_verified(self):
        import json
        channels = json.loads((SOURCE.parents[1] / "Resources" / "channels.json").read_text(encoding="utf-8"))
        matches = [c for c in channels if c["id"] == "ipanda-live"]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["group"], "熊猫")
        self.assertFalse(matches[0]["verified"])
        self.assertIn("not a specific camera", matches[0]["validationStatus"])
        self.assertIn("@\"熊猫\"", TEXT)

    def test_epg_cache_path_uses_valid_objc_message_expression(self):
        body = method_body("- (NSString *)epgCachePath")
        self.assertIn("NSSearchPathForDirectoriesInDomains(NSCachesDirectory", body)
        self.assertNotIn(".firstObject];", body)

    def test_retry_is_bound_to_current_generation_and_playback_type(self):
        body = method_body("- (void)player:(id)player playbackFailed:")
        self.assertIn("generation != self.playbackGeneration", body)
        self.assertIn("BOOL remotePlayback = self.avPlayer != nil", body)
        self.assertIn("if (remotePlayback)", body)
        self.assertIn("playSelectedNativeRouteOrChannel", body)
        self.assertIn("self.playbackGeneration += 1", method_body("- (void)startRemoteChannel:"))

    def test_remote_failure_recovery_is_bounded_and_deduplicates_player_callbacks(self):
        body = method_body("- (void)recoverRemoteFailureForItem:")
        self.assertIn("self.remoteRetryCount<1", body)
        self.assertIn("self.remoteFailureRecoveryPending", body)
        self.assertIn("generation!=self.playbackGeneration", body)
        self.assertIn("item!=self.avPlayer.currentItem", body)

    def test_first_frame_watchdog_ignores_terminal_playback_failures(self):
        body = method_body("- (void)startRemoteURL:")
        guard = body.index("item.status==AVPlayerItemStatusFailed")
        self.assertLess(guard, body.index('recordEvent:@"playback_first_frame_timeout"'))
        self.assertIn("!w.remotePlaybackWanted", body)
        self.assertIn("[self recoverRemoteFailureForItem:n.object error:e]", method_body("- (void)avItemFailed:"))
        self.assertIn("[self recoverRemoteFailureForItem:item error:item.error]", method_body("- (void)observeValueForKeyPath:"))

    def test_remote_channel_reselection_restarts_after_failed_source(self):
        body = method_body("- (void)selectChannel:")
        self.assertIn("self.remotePlaybackWanted || self.playbackReadiness", body)
        self.assertNotIn("(self.avPlayer || self.playbackReadiness)", body)

    def test_media_and_resource_tabs_reuse_page_state(self):
        self.assertIn("self.tabPages[@2]", TEXT)
        self.assertIn("self.tabPages[@3]", TEXT)
        self.assertIn("self.tabPages[@4]", TEXT)
        self.assertIn("[page refreshSources]", TEXT)
        self.assertIn("for(NSDictionary *candidate in updated)if([candidate[@\"id\"] isEqual:self.source[@\"id\"]])", (SOURCE.parent / "MediaBrowserViewController.m").read_text(encoding="utf-8"))

    def test_last_bottom_tab_is_restored_without_automatic_channel_refresh(self):
        startup = method_body("- (void)viewDidAppear:")
        select = method_body("- (void)selectBottomTab:")
        tap = method_body("- (void)bottomTabTapped:")
        self.assertIn('cctv.lastBottomTab.v1', TEXT)
        self.assertIn('cctv.manualStartupLoadingMigration.v1', TEXT)
        self.assertIn('[preferences setBool:NO forKey:@"resumeLastChannel"]', TEXT)
        self.assertIn('self.initialTabRestorePending', startup)
        self.assertIn('self.restoringLastTab=YES', startup)
        self.assertIn('setInteger:self.activeTab forKey:@"cctv.lastBottomTab.v1"', select)
        self.assertIn('self.userInitiatedTabSelection&&!self.restoringLastTab', select)
        self.assertIn('self.userInitiatedTabSelection=YES', tap)

    def test_bottom_tabs_open_service_directory_and_settings_pages(self):
        self.assertIn('- (void)buildBottomBar', TEXT)
        self.assertIn('[w openServicesPage]', TEXT)
        self.assertIn('[self makeSettingsPage]', TEXT)
        self.assertIn('ServicesViewController *page', TEXT)
        self.assertIn('[weakSelf openPluginPage]', TEXT)
        self.assertIn('SettingsViewController *page', TEXT)

    def test_service_directory_applies_safe_area_only_once(self):
        self.assertIn('self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever', SERVICE_UI)
        self.assertIn('[self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor]', SERVICE_UI)
        self.assertIn('[self.table.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]', SERVICE_UI)

    def test_live_header_actions_follow_selected_channel_and_group(self):
        navigation = method_body("- (void)configureCatalogNavigation")
        group_menu = method_body("- (void)showGroupMenu")
        self.assertIn("BOOL expandedLive", navigation)
        self.assertIn("self.channelName", navigation)
        self.assertIn('@"heart.fill":@"heart"', navigation)
        self.assertIn('AVRoutePickerView *airPlayPicker', navigation)
        self.assertIn('@"customView":airPlayPicker', navigation)
        self.assertIn('@"info.circle"', navigation)
        self.assertIn("self.groupControl.selectedSegmentIndex", navigation)
        self.assertIn("self.groupControl.numberOfSegments", group_menu)
        self.assertIn("✓", group_menu)

    def test_player_failures_stop_loading_and_offer_manual_retry(self):
        failure = TEXT[TEXT.rindex("- (void)displayNativePlaybackFailure:"):]
        retry = method_body("- (void)togglePlayPause")
        self.assertIn("[self.spinner stopAnimating]", failure)
        self.assertIn("[self endPlaybackPriority]", failure)
        self.assertIn('setTitle:@"重试"', failure)
        self.assertIn("self.nativePlaybackFailed", retry)
        self.assertIn("self.remotePlaybackFailed", retry)
        self.assertIn("displayNativePlaybackFailure:@\"频道调度失败\"", method_body("- (void)player:(id)player vdnRequestFailed:"))

    def test_settings_preferences_are_wired_to_real_playback_behavior(self):
        for key in ['resumeLastChannel','rememberLastChannel','autoLoadEPG','allowBackgroundAudio','autoPiP']:
            self.assertIn('@"' + key + '"', TEXT)
            self.assertIn('@"' + key + '"', SETTINGS)
        self.assertIn('CCTVBoolPreference(@"resumeLastChannel",NO)', TEXT)
        self.assertIn('@"key":@"resumeLastChannel", @"icon":@"arrow.counterclockwise", @"default":@NO', SETTINGS)

    def test_services_directory_shows_live_status_and_opens_detail(self):
        self.assertIn('isRunningServiceIdentifier', SERVICES)
        self.assertIn('每个服务可独立启停', SERVICES)
        self.assertIn('onToggleService', SERVICES)
        self.assertIn('ServiceDetailViewController', SERVICES)
        self.assertIn('ServiceStore', SERVICES)

    def test_service_lifecycle_is_scoped_to_service_identifier(self):
        starter = method_body('- (BOOL)startService:')
        toggler = method_body('- (void)changeService:')
        self.assertIn('startScriptAtPath:[ServiceStore scriptPath:service] identifier:serviceID', starter)
        self.assertIn('stopServiceIdentifier:serviceID', toggler)
        self.assertNotIn('stopWithError', toggler)
        self.assertIn('端口 %ld 正由', starter)

    def test_service_log_handlers_are_released_after_failed_start_or_confirmed_stop(self):
        cleanup = method_body('- (void)clearServiceLogHandlers:')
        for runtime in ('PyHost', 'NodePluginRuntime.shared', 'JSPluginRuntime.shared'):
            self.assertIn(f'[{runtime} setLogHandler:nil forServiceIdentifier:identifier]', cleanup)
        starter = method_body('- (BOOL)startService:')
        stopped = method_body('- (void)completeServiceStopForIdentifier:')
        self.assertIn('[self clearServiceLogHandlers:serviceID]', starter)
        self.assertIn('[self clearServiceLogHandlers:serviceID]', stopped)

    def test_plugin_and_settings_pages_use_safe_area_cards_and_live_status(self):
        self.assertIn('UIScrollView', PLUGIN)
        self.assertIn('PyHostRuntimeStateDidChangeNotification', PLUGIN)
        self.assertNotIn('NSTimer', PLUGIN)
        self.assertIn('isRunningServiceIdentifier:@"builtin-ysp"', PLUGIN)
        self.assertIn('UITableViewStyleInsetGrouped', SETTINGS)
        self.assertIn('epg-cache.json', SETTINGS)

    def test_service_views_use_change_notifications_and_separate_runtime_from_health(self):
        config=(SOURCE.parent / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("PyHostRuntimeStateDidChangeNotification", SERVICES)
        self.assertIn("PyHostRuntimeStateDidChangeNotification", config)
        self.assertNotIn("NSTimer", SERVICES)
        self.assertNotIn("NSTimer", config)
        self.assertIn("runtimeStatusDescription", PYHOST)
        self.assertIn("HTTP 健康状态未知", SERVICES)
        self.assertIn("健康检查通过", SERVICES)
        self.assertIn("ServiceProbeRedirectGuard", SERVICES)
        self.assertIn("completionHandler(nil)", SERVICES)
        self.assertIn("invalidateAndCancel", SERVICES)

    def test_epg_refresh_pauses_for_background_and_rejects_old_completion(self):
        self.assertIn("UIApplicationDidEnterBackgroundNotification", EPG)
        self.assertIn("UIApplicationWillEnterForegroundNotification", EPG)
        self.assertIn("[self cancelPageRequest]", EPG)
        self.assertIn("self.requestGeneration++", EPG)
        self.assertIn("applicationState!=UIApplicationStateActive", EPG)
        background=method_body("- (void)onBackground")
        foreground=method_body("- (void)onForeground")
        self.assertIn("setPaused:YES", background)
        self.assertIn("officialEPGRequestGeneration++", background)
        self.assertIn("[self.epgTask cancel]", background)
        self.assertIn("setPaused:playbackPriority", foreground)
        self.assertIn("playbackPriority", foreground)
        self.assertIn("requestGeneration!=weakSelf.officialEPGRequestGeneration", method_body("- (void)refreshOfficialNowNext"))

    def test_epg_page_supports_pull_to_refresh_and_grouped_cards(self):
        self.assertIn('UITableViewStyleInsetGrouped', EPG)
        self.assertIn('UIRefreshControl', EPG)
        self.assertIn('endRefreshing', EPG)

    def test_logs_redact_secrets_before_persistence(self):
        self.assertIn("HostLogRedactor redactText:msg", TEXT)
        plugin=(SOURCE.parent / "PluginLogStore.m").read_text(encoding="utf-8")
        self.assertIn('HostLogRedactor redactText:text?:@""', plugin)
        self.assertIn('appendText:line toPath:path', plugin)
        self.assertIn('safeText:text', plugin)
        self.assertIn("HostLogRedactor redactText:text", plugin)
        self.assertIn("HostLogRedactor redactText:content", plugin)
        self.assertIn("HostLogRedactor redactText:stored", TEXT)
        self.assertIn("HostLogRedactor redactText:text?:@\"\"", TEXT)
        for secret in ("authorization", "cookie", "access[_-]?token", "password", "Bearer"):
            self.assertIn(secret, REDACTOR)
        smoke=(SOURCE.parents[1] / "Tests" / "UISmoke" / "SmokeDriver.m").read_text(encoding="utf-8")
        self.assertIn("diagnostic logs redact URL credentials", smoke)

    def test_stable_url_key_rejects_bad_m3u_without_uncaught_exception(self):
        body = method_body("- (NSString *)stableURLKey:")
        self.assertIn('isKindOfClass:NSString.class', body)
        self.assertIn('@catch (NSException *exception)', body)
        self.assertIn('urlString.length > 8192', body)
        self.assertIn('isEqualToString:@"http"', body)
        self.assertIn('isEqualToString:@"https"', body)
        self.assertIn('skippedInvalidURLs++', method_body('- (void)installPlaylist:'))

    def test_channel_search_and_route_fallback_use_safe_identity(self):
        self.assertIn('containsString:query', TEXT)
        self.assertNotIn('![[[channel[@"name"]', TEXT)
        self.assertIn('CCTVRouteGroupKey(channel)', TEXT)
        self.assertIn('tvg-id:', TEXT)
        self.assertNotIn('self.altSources[c.name]', TEXT)

    def test_service_profiles_report_per_service_runtime_state(self):
        self.assertIn('runtimeStatusDescriptionForServiceIdentifier:service[@"id"]', TEXT)
        self.assertIn('runtimeStatusDescriptionForServiceIdentifier:', PYHOST)

    def test_playback_diagnostics_snapshot_and_epg_date_selection_are_stable(self):
        playback=(SOURCE.parent / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn('snapshotRows', playback)
        self.assertNotIn('self.rowsProvider()[ip.row]', playback)
        self.assertIn('NSString *previous=', EPG)

    def test_javascript_start_timeout_keeps_owner_until_ordered_stop(self):
        runtime=(SOURCE.parent / "JSPluginRuntime.m").read_text(encoding="utf-8")
        self.assertIn('if(failedStart)', runtime)
        self.assertIn('ordered stop', runtime)
        self.assertIn('self.sessionRuntimes[session]==runtime', runtime)

    def test_node_session_status_distinguishes_confirmed_from_unresolved(self):
        node=(SOURCE.parent / "NodePluginRuntime.m").read_text(encoding="utf-8")
        self.assertIn('confirmedSessions', node)
        self.assertIn('uncertainSessions', node)
        self.assertIn('Reserve before I/O', node)
        self.assertIn('isManagedServiceIdentifier', PYHOST)
        self.assertIn('Node 操作超时；会话结果未知', node)
        self.assertIn('managedServiceIdentifiers', PYHOST)
        self.assertIn('启停结果待确认', SERVICES)
        self.assertIn('isManagedServiceIdentifier:self.service', SERVICES)

    def test_global_stop_includes_sessions_with_unconfirmed_start_replies(self):
        self.assertIn('NodePluginRuntime.shared.managedServiceIdentifiers', PYHOST)
        self.assertIn('JSPluginRuntime.shared.managedServiceIdentifiers', PYHOST)

    def test_m3u_parser_catches_invalid_url_lines(self):
        parser = (SOURCE.parent / "M3UParser.m").read_text(encoding="utf-8")
        self.assertIn('@catch (NSException *exception)', parser)
        self.assertIn('pendingName = nil; pendingLogo = nil; pendingEPGID = nil; pendingTVGName = nil; [pendingHeaders removeAllObjects]; return;', parser)
        self.assertIn('ch.tvgName = pendingTVGName', parser)
        self.assertIn('ch.headers = pendingHeaders.copy', parser)

    def test_live_player_has_category_channel_program_and_route_panels(self):
        self.assertIn('initWithItems:@[@"分类",@"频道",@"节目",@"线路"]', TEXT)
        self.assertIn('if(index==0)v=[self categoryPanel]', TEXT)
        self.assertIn('else if(index==2)v=[self epgPageForChannel:', TEXT)
        self.assertIn('else if(index==3)v=[self routesPanel]', TEXT)
        routes = method_body('- (CCTVPlaybackListPanelController *)routesPanel')
        self.assertIn('自动选择', routes)
        self.assertIn('displaySafeSourceURL:', routes)
        self.assertIn('点按切换', routes)

    def test_cctv_selected_route_uses_sdk_url_entry_and_stays_selected_on_retry(self):
        body=method_body('- (void)playChannel:')
        self.assertLess(body.index('URLForRoute:route error:'), body.index('[self stopPlayback]'))
        self.assertLess(body.index('showNativeRouteError:'), body.index('self.playbackGeneration += 1'))
        self.assertIn('restoreDefault:', body)
        self.assertNotIn('getVDNConfig_CDNLive_DefaultCDNInfo', body)
        self.assertIn('playViaSDKURL:selectedURL channelID:cid', body)
        self.assertIn('playViaSDK:cid title:self.channelName', body)
        retry=method_body('- (void)togglePlayPause')
        self.assertIn('route:self.requestedNativeRoute', retry)
        direct=method_body('- (void)playViaSDKURL:')
        self.assertIn('playLIVEWithUrl:delegate:configOptions:', direct)
        self.assertIn('kOptURLChannelIDForStats:cid', direct)
        self.assertIn('kOptUserID', direct)
        self.assertIn('保留线路选择，不回退自动', direct)
        self.assertIn('自选地址 %@', TEXT)
        self.assertIn('SDK 报告节点', TEXT)
        self.assertIn('playSelectedNativeRouteOrChannel', method_body('- (void)player:(id)player playbackFailed:'))
        self.assertNotIn('armCicadaFallback', TEXT)
        self.assertIn('generation!=owner.playbackGeneration',body)
        self.assertIn('HLSRouteProbe',body)
        self.assertIn('nativePlainRoute',body)
        self.assertIn('[self.nativeRouteProbe cancel]',method_body('- (void)stopPlayback'))
        self.assertIn('self.nativePlainRouteActive?0:1',method_body('- (void)startRemoteChannel:'))

    def test_player_toolbar_uses_real_airplay_picker_and_delays_logo_io_until_first_frame(self):
        self.assertIn('AVRoutePickerView *airPlayPicker', TEXT)
        self.assertIn('@"customView":airPlayPicker', TEXT)
        self.assertIn('loadPlayerChannelLogoAfterFirstFrame', TEXT)
        body = method_body('- (void)loadLogo:')
        self.assertIn('playbackPriorityUntil', body)

    def test_epg_debug_info_reports_subscription_match_fields_and_preserves_source_query(self):
        epg=(SOURCE.parent / "EPGViewController.m").read_text(encoding="utf-8")
        profile=(SOURCE.parent / "ProfileStore.m").read_text(encoding="utf-8")
        self.assertIn('M3U tvg-id', epg)
        self.assertIn('M3U tvg-name', epg)
        self.assertIn('channel[@"tvgName"]', profile)
        self.assertIn('匹配依据', epg)
        self.assertIn('所选日期', epg)
        safe = epg[epg.index('- (NSString *)safeSourceDescription'):epg.index('- (void)showSourceInfo')]
        self.assertNotIn('components.query=nil', safe)
        self.assertIn('components.password=nil', safe)
        route_url = method_body('- (NSString *)displaySafeSourceURL:')
        self.assertNotIn('components.query=nil', route_url)
        self.assertIn('components.password=nil', route_url)

    def test_catalog_supports_grid_and_list_and_routes_remain_long_press(self):
        self.assertIn('self.table.rowHeight = UITableViewAutomaticDimension', TEXT)
        self.assertIn('self.table.estimatedRowHeight = 58', TEXT)
        self.assertIn('channel.list', TEXT)
        self.assertIn('return (NSInteger)self.shownChannels.count;', TEXT)
        self.assertIn('channel.grid', TEXT)
        self.assertIn('channelGridMode', TEXT)
        self.assertIn('contextMenuConfigurationForItemAtIndexPath', TEXT)
        self.assertIn('onLongPress:', TEXT)

    def test_video_text_overlays_hide_after_first_render(self):
        body = method_body('- (void)player:(id)player statEvent:')
        self.assertIn('self.titleLabel.hidden = YES', body)
        self.assertIn('self.infoLabel.hidden = YES', body)

    def test_ios_plugin_uses_bounded_startup_resources(self):
        self.assertIn('@"--cache-mb",@"32"', TEXT)
        self.assertIn('@"--links-per-device",@"2"', TEXT)
        self.assertIn('stable-playback', TEXT)

    def test_favorites_filter_remains_available(self):
        self.assertIn('self.favoritesOnly', TEXT)
        self.assertIn('if (self.favoritesOnly) {', TEXT)


if __name__ == "__main__":
    unittest.main()
