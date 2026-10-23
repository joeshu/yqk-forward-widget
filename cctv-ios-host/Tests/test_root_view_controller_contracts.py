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
        self.assertIn("playViaSDK:cid title:name", body)
        self.assertIn("self.playbackGeneration += 1", method_body("- (void)startRemoteChannel:"))

    def test_bottom_tabs_open_service_directory_and_settings_pages(self):
        self.assertIn('- (void)buildBottomBar', TEXT)
        self.assertIn('[w openServicesPage]', TEXT)
        self.assertIn('[self makeSettingsPage]', TEXT)
        self.assertIn('ServicesViewController *page', TEXT)
        self.assertIn('[weakSelf openPluginPage]', TEXT)
        self.assertIn('SettingsViewController *page', TEXT)

    def test_settings_preferences_are_wired_to_real_playback_behavior(self):
        for key in ['resumeLastChannel','rememberLastChannel','autoLoadEPG','allowBackgroundAudio','autoPiP']:
            self.assertIn('@"' + key + '"', TEXT)
            self.assertIn('@"' + key + '"', SETTINGS)

    def test_services_directory_shows_live_status_and_opens_detail(self):
        self.assertIn('PyHost.running', SERVICES)
        self.assertIn('onToggleService', SERVICES)
        self.assertIn('ServiceDetailViewController', SERVICES)
        self.assertIn('ServiceStore', SERVICES)

    def test_plugin_and_settings_pages_use_safe_area_cards_and_live_status(self):
        self.assertIn('UIScrollView', PLUGIN)
        self.assertIn('statusTimer', PLUGIN)
        self.assertIn('updateRunning:PyHost.running', PLUGIN)
        self.assertIn('UITableViewStyleInsetGrouped', SETTINGS)
        self.assertIn('epg-cache.json', SETTINGS)

    def test_epg_page_supports_pull_to_refresh_and_grouped_cards(self):
        self.assertIn('UITableViewStyleInsetGrouped', EPG)
        self.assertIn('UIRefreshControl', EPG)
        self.assertIn('endRefreshing', EPG)

    def test_stable_url_key_rejects_bad_m3u_without_uncaught_exception(self):
        body = method_body("- (NSString *)stableURLKey:")
        self.assertIn('isKindOfClass:NSString.class', body)
        self.assertIn('@catch (NSException *exception)', body)
        self.assertIn('urlString.length > 8192', body)
        self.assertIn('isEqualToString:@"http"', body)
        self.assertIn('isEqualToString:@"https"', body)
        self.assertIn('skippedInvalidURLs++', method_body('- (void)installPlaylist:'))

    def test_m3u_parser_catches_invalid_url_lines(self):
        parser = (SOURCE.parent / "M3UParser.m").read_text(encoding="utf-8")
        self.assertIn('@catch (NSException *exception)', parser)
        self.assertIn('pendingLogo = nil; pendingEPGID = nil; continue;', parser)

    def test_catalog_supports_grid_and_list_and_routes_remain_long_press(self):
        self.assertIn('self.table.rowHeight = 48', TEXT)
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
        self.assertIn('"--cache-mb", "32"', PYHOST)
        self.assertIn('"--links-per-device", "2"', PYHOST)
        self.assertIn('iOS 插件安全模式', PYHOST)

    def test_favorites_filter_remains_available(self):
        self.assertIn('self.favoritesOnly', TEXT)
        self.assertIn('if (self.favoritesOnly) {', TEXT)


if __name__ == "__main__":
    unittest.main()
