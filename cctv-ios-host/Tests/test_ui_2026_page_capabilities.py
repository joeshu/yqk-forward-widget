import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class PageCapabilities2026Tests(unittest.TestCase):
    def test_cap1_live_mini_player_dismiss_and_live_sleep_timer(self):
        root = read_source("RootViewController.m")
        self.assertIn('self.liveMiniPlayerCloseButton.accessibilityIdentifier=@"live.mini-player.close"', root)
        self.assertIn("- (void)dismissSuspendedLiveMiniBar", root)
        self.assertIn("- (void)configureLiveSleepTimerMinutes:(NSInteger)minutes", root)
        self.assertIn("直播睡眠定时", root)

    def test_cap2_epg_program_scope_filter_and_clear_channel_reminders(self):
        epg = read_source("EPGViewController.m")
        self.assertIn('self.filterMenuItem.accessibilityIdentifier=@"epg.filter.menu"', epg)
        self.assertIn("- (UIMenu *)buildProgramFilterMenu", epg)
        self.assertIn("- (void)clearChannelReminders", epg)
        self.assertIn("仅看已播 / 可回看", epg)
        self.assertIn("仅看已预约提醒", epg)

    def test_cap3_playback_info_copy_snapshot_and_single_row_copy(self):
        info = read_source("PlaybackInfoViewController.m")
        self.assertIn('copyItem.accessibilityIdentifier = @"playback.info.copy"', info)
        self.assertIn("- (void)copyAllDiagnostics", info)
        self.assertIn("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip", info)
        self.assertIn('c.accessibilityHint = @"点按复制此项指标"', info)

    def test_cap4_global_search_result_context_menu_actions(self):
        search = read_source("MediaGlobalSearchViewController.m")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath", search)
        self.assertIn("仅看此来源结果", search)
        self.assertIn("复制片名", search)

    def test_cap5_favorites_swipe_unfavorite_and_watch_history_progress_bar(self):
        mb = read_source("MediaBrowserViewController.m")
        self.assertIn("- (void)reloadFavoriteEntries", mb)
        self.assertIn("- (void)confirmClearFavorites", mb)
        self.assertIn('title:@"取消收藏"', mb)
        self.assertIn('watchProgress.accessibilityIdentifier=@"media.history.progress"', mb)

    def test_cap6_episode_selection_jump_to_episode_number_or_name(self):
        ep = read_source("MediaEpisodeSelectionViewController.m")
        self.assertIn('self.jumpEpisodeButton.accessibilityIdentifier=@"media-episode-jump"', ep)
        self.assertIn("- (void)promptJumpToEpisode", ep)
        self.assertIn("快速跳集", ep)

    def test_cap7_media_playback_gesture_screen_lock_and_sleep_timer(self):
        mp = read_source("MediaPlaybackViewController.m")
        self.assertIn('self.screenLockButton.accessibilityIdentifier=@"media-playback-lock-button"', mp)
        self.assertIn("- (void)toggleGestureLock", mp)
        self.assertIn("- (void)configureMediaSleepTimerMinutes:(NSInteger)minutes", mp)
        self.assertIn("- (UIMenu *)playbackSleepTimerMenu", mp)

    def test_cap8_web_player_loading_progress_bar(self):
        web = read_source("MediaWebViewController.m")
        self.assertIn('self.webProgressView.accessibilityIdentifier=@"media.web.progress"', web)
        self.assertIn("[self.webProgressView setProgress:0.35 animated:YES]", web)
        self.assertIn("[self.webProgressView setProgress:1.0 animated:YES]", web)

    def test_cap9_tvbox_catalog_copy_endpoint_and_service_code_tools(self):
        tvbox = read_source("TVBoxCatalogViewController.m")
        self.assertNotIn("UIColor.labelColor", tvbox)
        self.assertNotIn("UIColor.secondaryLabelColor", tvbox)
        self.assertIn("复制接口地址", tvbox)

        editor = read_source("ServiceEditorViewController.m")
        self.assertIn('toolsItem.accessibilityIdentifier = @"service.code.tools"', editor)
        self.assertIn("- (void)promptFindInCode", editor)
        self.assertIn("- (void)formatJSONIfApplicable", editor)

    def test_cap10_runtime_diagnostics_event_category_filter(self):
        diag = read_source("RuntimeDiagnosticsViewController.m")
        self.assertIn('self.eventCategoryFilter.accessibilityIdentifier = @"diagnostic.event.filter"', diag)
        self.assertIn("- (void)applyEventCategoryFilter", diag)
        self.assertIn('@[@"全部", @"播放", @"接口", @"服务", @"异常"]', diag)


if __name__ == "__main__":
    unittest.main()
