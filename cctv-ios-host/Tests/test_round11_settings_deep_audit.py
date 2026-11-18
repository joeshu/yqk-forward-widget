import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class Round11SettingsDeepAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings_m = read_source("SettingsViewController.m")
        cls.backup_m = read_source("HostBackup.m")
        cls.root_m = read_source("RootViewController.m")

    def test_iss85_settings_view_will_appear_sync_and_episode_layout_broadcast_and_factory_reset(self):
        # viewWillAppear: must refresh hero summary chips and reload table so cross-tab/subpage edits sync immediately
        self.assertIn("else [self refreshHeroSummaryChips];", self.settings_m)
        self.assertIn("[self.table reloadData];", self.settings_m)
        self.assertIn("handleExternalPreferenceNotification:", self.settings_m)
        # Episode layout segmented control and badge/auto-expand toggles must broadcast CCTVMediaEpisodeLayoutStyleDidChangeNotification
        self.assertIn("CCTVEpisodeSetLayoutStyle((CCTVEpisodeLayoutStyle)value);", self.settings_m)
        self.assertIn("CCTVEpisodeSetShowRemarksBadgeEnabled(sender.on);", self.settings_m)
        self.assertIn("CCTVEpisodeSetAutoExpandEnabled(sender.on);", self.settings_m)
        self.assertIn("CCTVMediaEpisodeLayoutStyleDidChangeNotification", self.settings_m)
        self.assertIn("CCTVMediaEpisodeLayoutStyleDidChangeNotification", self.root_m)
        # Factory reset must include adaptationMonitor, mediaHome.modules, and reset ProfileStore native source flags
        self.assertIn('@"cctv.adaptationMonitor.enabled"', self.settings_m)
        self.assertIn('@"cctv.mediaHome.modules.v1"', self.settings_m)
        self.assertIn('[ProfileStore setChannelLogoEnabled:NO forSource:@""];', self.settings_m)
        self.assertIn('[ProfileStore setPlayerCornerLogoEnabled:NO forSource:@""];', self.settings_m)
        self.assertIn('[ProfileStore setChannelPreviewEnabled:NO forSource:@""];', self.settings_m)
        self.assertIn('[ProfileStore setChannelTelemetryEnabled:NO forSource:@""];', self.settings_m)

    def test_iss86_clear_program_reminders_cancels_pending_notifications_and_xmltv_cache_counted(self):
        # Clearing EPG reminders must cancel pending UNUserNotificationCenter local notifications
        self.assertIn("#import <UserNotifications/UserNotifications.h>", self.settings_m)
        self.assertIn("removePendingNotificationRequestsWithIdentifiers:", self.settings_m)
        # EPG cache calculation and removal must cover both epg-cache.json and XMLTVStore Caches/XMLTV directory
        self.assertIn("SettingsXMLTVCacheDirectoryPath", self.settings_m)
        self.assertIn("[[XMLTVStore shared] clear];", self.settings_m)

    def test_iss87_settings_in_page_keyword_search_and_empty_state(self):
        # Settings hero header must provide an in-page keyword search field and empty state recovery
        self.assertIn('@"settings.search.field"', self.settings_m)
        self.assertIn("settingsSearchChanged:", self.settings_m)
        self.assertIn("clearSettingsSearchFilter", self.settings_m)
        self.assertIn('@"settings.search.empty"', self.settings_m)
        self.assertIn('@"settings.search.clear"', self.settings_m)

    def test_iss88_host_backup_covers_vod_favorites_watch_history_skip_points_and_home_modules(self):
        # HostBackup must include adaptationMonitor, mediaHome.modules, recents, vodFavorites, watchHistory, skipPoints, epgReminders
        self.assertIn("+ (NSArray<NSString *> *)arrayPreferenceKeys", self.backup_m)
        self.assertIn('@"cctv.adaptationMonitor.enabled"', self.backup_m)
        self.assertIn('@"cctv.mediaHome.modules.v1"', self.backup_m)
        for key in ["recents", "vodFavorites", "watchHistory", "skipPoints", "epgReminders"]:
            self.assertIn(f'@"{key}"', self.backup_m)
        # RootViewController finishConfigurationImport: must sync gridColumns, channelSortMode, and reloadThemeAppearance
        self.assertIn('restoredCols=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelGridColumns.v1"]', self.root_m)
        self.assertIn('self.channelSortMode=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelSortMode.v1"]', self.root_m)

    def test_iss89_update_check_presentation_and_https_guards_and_quality_picker_in_place_refresh(self):
        # checkForUpdateFromIndexPath: must verify window attachment, presentedViewController, and https scheme
        self.assertIn("if (!owner.view.window || owner.presentedViewController) return;", self.settings_m)
        self.assertIn('[u.scheme.lowercaseString isEqualToString:@"https"]', self.settings_m)
        # presentPreferredQualityPicker: must refresh hero summary chips in place without rebuilding the entire tableHeaderView
        start = self.settings_m.index("- (void)presentPreferredQualityPicker:")
        end = self.settings_m.index("- (void)presentSettingsAlert:", start)
        picker_body = self.settings_m[start:end]
        self.assertIn("[self refreshHeroSummaryChips];", picker_body)
        self.assertNotIn("[self setupHeroHeaderView];", picker_body)

    def test_iss90_live_storage_and_cleanup_row_summaries(self):
        for helper in [
            "SettingsAllCachesSummaryText()",
            "SettingsWatchHistorySummaryText()",
            "SettingsFavoritesSummaryText()",
            "SettingsEPGRemindersSummaryText()",
        ]:
            self.assertIn(helper, self.settings_m)

    def test_iss91_version_row_one_tap_diagnostics_snapshot_copy(self):
        self.assertIn('@"action":@"copyVersionDiagnostics"', self.settings_m)
        self.assertIn("- (void)copyVersionDiagnosticsFromIndexPath:(NSIndexPath *)ip", self.settings_m)
        self.assertIn('@"settings_version_diagnostics_copied"', self.settings_m)


if __name__ == "__main__":
    unittest.main()
