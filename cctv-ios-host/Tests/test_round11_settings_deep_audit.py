import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class Round11SettingsDeepAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings_h = read_source("SettingsViewController.h")
        cls.settings_m = read_source("SettingsViewController.m")
        cls.backup_m = read_source("HostBackup.m")
        cls.root_m = read_source("RootViewController.m")
        cls.services_m = read_source("ServicesViewController.m")
        cls.timeshift_m = read_source("CCTVTimeshiftController.m")
        cls.playback_m = read_source("RootViewController+Playback.m")
        cls.epg_m = read_source("RootViewController+EPG.m")
        cls.catalog_m = read_source("RootViewController+Catalog.m")

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
        restore = (SOURCES / "RootViewController+Services.m").read_text(encoding="utf-8")
        # RootViewController finishConfigurationImport: must sync gridColumns, channelSortMode, and reloadThemeAppearance
        self.assertIn('restoredCols=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelGridColumns.v1"]', restore)
        self.assertIn('self.channelSortMode=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelSortMode.v1"]', restore)

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

    def test_iss92_collapsible_domain_headers_subgroup_tags_and_search_highlighting(self):
        # Collapsible section headers with item count badge and subgroup tags
        self.assertIn("- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section", self.settings_m)
        self.assertIn("- (BOOL)isSectionCollapsedAtIndex:(NSInteger)section", self.settings_m)
        self.assertIn("- (void)toggleSectionHeaderButton:(UIButton *)sender", self.settings_m)
        self.assertIn('@"subgroup":', self.settings_m)
        self.assertIn("- (NSAttributedString *)highlightedAttributedString:", self.settings_m)
        self.assertIn("- (void)updateSearchMatchCountBadge", self.settings_m)

    def test_iss93_interactive_hero_control_center_quick_tiles_and_category_counts(self):
        # 4-tile quick control center + interactive summary chips + global hero action sheet + category item counts
        self.assertIn('@"settings.hero.quickTiles"', self.settings_m)
        self.assertIn('@"settings.quick.theme"', self.settings_m)
        self.assertIn('@"settings.quick.quality"', self.settings_m)
        self.assertIn('@"settings.quick.monitor"', self.settings_m)
        self.assertIn('@"settings.quick.cache"', self.settings_m)
        self.assertIn("- (void)handleHeroQuickTileTap:(UIButton *)sender", self.settings_m)
        self.assertIn("- (void)handleHeroSummaryChipTap:(UIButton *)chip", self.settings_m)
        self.assertIn("[chip addTarget:self action:@selector(handleHeroSummaryChipTap:) forControlEvents:UIControlEventTouchUpInside]", self.settings_m)
        self.assertIn("- (void)presentHeroQuickActionsSheet:(UIButton *)sender", self.settings_m)
        self.assertIn("- (NSUInteger)totalRowCountForCategory:(NSString *)categoryID", self.settings_m)

    def test_iss94_haptics_context_menu_single_row_reset_and_trailing_value_accessory(self):
        # Tactile feedback, press scale highlight, context menu single-row reset, and custom trailing value pill accessory
        self.assertIn("SettingsTriggerHapticSelection()", self.settings_m)
        self.assertIn("SettingsTriggerHapticImpact(", self.settings_m)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", self.settings_m)
        self.assertIn("- (void)resetSingleRowToDefault:(NSDictionary *)row atIndexPath:(NSIndexPath *)ip", self.settings_m)
        self.assertIn("- (UIView *)buildActionAccessoryViewForRow:(NSDictionary *)row inCategory:(NSString *)category", self.settings_m)
        self.assertIn("didHighlightRowAtIndexPath:", self.settings_m)
        self.assertIn("didUnhighlightRowAtIndexPath:", self.settings_m)

    def test_iss95_spatial_squircle_icon_badge_engine_and_semantic_domain_tints(self):
        # Cached squircle icon badge renderer, semantic domain/role colors, and theme swatch preview
        self.assertIn("- (void)reloadThemeAppearance;", self.settings_h)
        self.assertIn("SettingsSquircleBadgeImage(", self.settings_m)
        self.assertIn("SettingsSemanticTintForCategoryAndRole(", self.settings_m)
        self.assertIn("SettingsThemeSwatchPreviewImage(", self.settings_m)
        self.assertIn("SettingsIconBadgeCache()", self.settings_m)

    def test_iss96_to_iss100_cctv_timeshift_consecutive_seeks_sdk_options_and_catchup_fallback(self):
        # ISS-96: consecutive seeks allowed during timeshift/transition & post-seek settle confirmation
        self.assertIn(
            "if (!self.currentPlayer || self.avPlayer || (!self.firstRender && !self.nativeTimeShiftActive && !self.nativeTransitionKind.length))",
            self.playback_m,
        )
        self.assertIn("if (event == 3 && !self.firstRender)", self.playback_m)
        self.assertIn("else if (self.onFailure) self.onFailure(error);", self.timeshift_m)
        # ISS-97: playViaSDK passes TimeshiftingChannelID & LivePublicCheck
        sdk_body = self.playback_m.split("- (void)playViaSDK:(NSString *)cid title:(NSString *)title {", 1)[1].split(
            "\n- (void)recordStartupStage:", 1
        )[0]
        self.assertIn("CCTVTimeshiftConfigKeyTimeshiftingChannelID:cid", sdk_body)
        self.assertIn("CCTVTimeshiftConfigKeyLivePublicCheck:@NO", sdk_body)
        # ISS-98: automatic M3U catchup fallback on native timeshift failure + non-destructive failNativeTransition
        self.assertIn("- (NSDictionary *)anyCatchupChannelForStation:(NSDictionary *)channel", self.catalog_m)
        self.assertIn("NSDictionary *catchupFallback = [weakSelf anyCatchupChannelForStation:channel];", self.playback_m)
        self.assertIn("self.nativePlaybackFailed=(self.currentPlayer==nil);if(self.currentPlayer)self.firstRender=YES;", self.playback_m)
        # ISS-99 & ISS-100: cumulative seek offset, fast-forward in replay, and EPG active timeshift seek
        self.assertIn('[weakSelf seekCurrentChannelByOffsetMinutes:-fmins];', self.playback_m)
        self.assertIn(
            "(!owner.firstRender && !owner.nativeTimeShiftActive && !owner.nativeTransitionKind.length)",
            self.epg_m,
        )

    def test_iss101_to_iss103_settings_50_item_audit_sync_live_handlers_and_cell_reuse(self):
        # ISS-101: rememberLastChannel in HostBackup and bidirectional sync with resumeLastChannel
        self.assertIn('@"rememberLastChannel"', self.backup_m)
        self.assertIn('if ([defaults boolForKey:@"resumeLastChannel"])', self.settings_m)
        self.assertIn('if ([defaults objectForKey:@"rememberLastChannel"] && ![defaults boolForKey:@"rememberLastChannel"])', self.settings_m)
        # ISS-102: RootViewController makeSettingsPage live handlers for preferredQuality, preloadNativeChannel, legacyNativePlayback
        self.assertIn("weakSelf.avPlayer.currentItem.preferredPeakBitRate = peak;", self.root_m)
        self.assertIn("[weakSelf prepareNextNativeChannelForGeneration:weakSelf.playbackGeneration];", self.root_m)
        # ISS-103: heightForHeaderInSection, attributedText reset on reuse, and picker single-row reset
        self.assertIn("- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section", self.settings_m)
        self.assertIn("cell.textLabel.attributedText=nil;", self.settings_m)
        self.assertIn("cell.detailTextLabel.attributedText=nil;", self.settings_m)
        self.assertIn("BOOL isResettablePickerAction=", self.settings_m)

    def test_iss104_to_iss106_service_detail_subtitle_layout_timestamp_dedup_and_version_resolution(self):
        # ISS-104: subtitle layout prevents crushed 1-char vertical text on Section 0 Row 0
        self.assertIn('BOOL subtitleLayout=(ip.section==0&&ip.row==0)||(ip.section==1&&(ip.row==0||ip.row==2))||(ip.section==2&&(ip.row==6||ip.row==7||ip.row==8||ip.row==9));', self.services_m)
        self.assertIn("- (NSString *)effectiveRuntimeStatusTitle", self.services_m)
        self.assertIn("- (void)setupServiceDetailHeaderView", self.services_m)
        # ISS-105: ServiceHealthDisplay avoids duplicate timestamp appending
        self.assertIn('[result containsString:@"最近 HTTP 响应"]', self.services_m)
        # ISS-106: ServiceResolvedVersionText extracts version from script or falls back cleanly, plus tap-to-copy sourceURL & openCodeViewer
        self.assertIn("static NSString *ServiceResolvedVersionText(NSDictionary *service)", self.services_m)
        self.assertIn("- (void)openCodeViewer", self.services_m)
        self.assertIn('@"源地址已复制"', self.services_m)



    def test_full_app_ui_and_feature_audit_iss107_to_iss114(self) -> None:
        # ISS-107: EPGViewController 7-day official CNTV lookback + glass hint card + context menu + press animation
        epg = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("fetchOfficialSevenDayLookback", epg)
        self.assertIn("https://api.cntv.cn/epg/epginfo3?serviceId=cbox&c=%@&d=%@", epg)
        self.assertIn("epg.load.7days", epg)
        self.assertIn("HostStyleGlassCard(self.hintCard, 10)", epg)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", epg)
        self.assertIn("didHighlightRowAtIndexPath:", epg)

        # ISS-108: PlaybackInfoViewController dynamic Subtitle layout for long values + context menu + press feedback
        pinfo = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn("playback.info.subtitle", pinfo)
        self.assertIn("UITableViewCellStyleSubtitle", pinfo)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", pinfo)
        self.assertIn("HostStyleSectionHeaderView(view);", pinfo)

        # ISS-109: LogCenterViewController pull-to-refresh + context menu & PluginRunHistoryViewController SF symbols
        log_center = (SOURCES / "LogCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("UIRefreshControl", log_center)
        self.assertIn("pullRefreshLogs:", log_center)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", log_center)
        run_hist = (SOURCES / "PluginRunHistoryViewController.m").read_text(encoding="utf-8")
        self.assertIn("archivebox.fill", run_hist)
        self.assertIn("HostStyleSectionHeaderView(view);", run_hist)

        # ISS-110: RuntimeDiagnosticsViewController dynamic tableHeaderView resizing + pull-to-refresh + semantic icons
        rdiag = (SOURCES / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("viewDidLayoutSubviews", rdiag)
        self.assertIn("UIRefreshControl", rdiag)
        self.assertIn("waveform.path.ecg", rdiag)

        # ISS-111: LocalMediaViewController Spatial Glass card border + audio/video SF symbols + context menu
        local_media = (SOURCES / "LocalMediaViewController.m").read_text(encoding="utf-8")
        self.assertIn("waveform.circle.fill", local_media)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", local_media)
        self.assertIn("HostSetLayerBorderColor(", local_media)

        # ISS-112: SubscriptionResourceViewController & PluginResourceDetailViewController context menu + subtitle layout
        sub_res = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", sub_res)
        self.assertIn("didHighlightRowAtIndexPath:", sub_res)
        plug_res = (SOURCES / "PluginResourceDetailViewController.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", plug_res)
        self.assertIn("didHighlightRowAtIndexPath:", plug_res)
        self.assertIn("length]>28", plug_res)

        # ISS-113: ServiceEditorViewController elevated primary action button styling
        svc_editor = (SOURCES / "ServiceEditorViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostSelectedSurface()", svc_editor)
        self.assertIn("[HostAccent() colorWithAlphaComponent:0.45]", svc_editor)

        # ISS-114: MediaGlobalSearchViewController reloadThemeAppearance & TVBoxCatalogViewController segment styling
        gsearch = (SOURCES / "MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)reloadThemeAppearance", gsearch)
        tvbox_cat = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn("setTitleTextAttributes:", tvbox_cat)
        self.assertIn("didHighlightRowAtIndexPath:", tvbox_cat)



    def test_round15_full_app_deep_audit_iss115_to_iss122(self) -> None:
        # ISS-115: MediaWebViewController KVO estimatedProgress/title + Safari open + pull-to-refresh
        web = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        self.assertIn("observingWebKVO", web)
        self.assertIn('forKeyPath:@"estimatedProgress"', web)
        self.assertIn('forKeyPath:@"title"', web)
        self.assertIn("media.web.safari", web)
        self.assertIn("self.web.scrollView.refreshControl=webRefresh;", web)

        # ISS-116: PluginViewController pull-to-refresh + manualProbeHTTP + full theme refresh
        plug = (SOURCES / "PluginViewController.m").read_text(encoding="utf-8")
        self.assertIn("pullRefreshPluginStatus:", plug)
        self.assertIn("manualProbeHTTP", plug)
        self.assertIn("HostSetLayerBorderColor(b, HostBorder());", plug)

        # ISS-117 & ISS-118: MediaBrowser sub-controllers, MediaFeedView context menu, Detail & Episode pull-to-refresh
        mb = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("media.picker.context", mb)
        self.assertIn("media.detail.refresh", mb)
        self.assertIn("media.favorite.context", mb)
        self.assertIn("media.history.context", mb)
        self.assertIn("HostStyleSectionHeaderView(view);", mb)
        mf = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForItemAtIndexPath:", mf)
        mes = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
        self.assertIn("media.episode.refreshControl", mes)

        # ISS-119: MediaAdaptationMonitorViewController Spatial Glass cards + pull-to-refresh + context menu
        mam = (SOURCES / "MediaAdaptationMonitor.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", mam)
        self.assertIn("didHighlightRowAtIndexPath:", mam)
        self.assertIn("UIRefreshControl *monRefresh", mam)

        # ISS-120: ResourceImportSheetViewController & ResourceImportWorkflowViewController context menus
        ris = (SOURCES / "ResourceImportSheetViewController.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", ris)
        riw = (SOURCES / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", riw)
        self.assertIn("didHighlightRowAtIndexPath:", riw)

        # ISS-121: ServicesViewController & ConfigCenterViewController pull-to-refresh + press feedback
        svc = (SOURCES / "ServicesViewController.m").read_text(encoding="utf-8")
        self.assertIn("pullRefreshServiceDetail:", svc)
        self.assertIn("pullRefreshServicesList:", svc)
        self.assertIn("didHighlightRowAtIndexPath:", svc)
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("didHighlightRowAtIndexPath:", cc)
        self.assertIn("UIScrollViewKeyboardDismissModeOnDrag", cc)

        # ISS-122: RootViewController CCTVPlaybackListPanelController & Catalog context menu + grid highlight
        rvc = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("cctv.playback.panel.context", rvc)
        cat = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        self.assertIn("didHighlightItemAtIndexPath:", cat)
        self.assertIn("contextMenuConfigurationForRowAtIndexPath:", cat)



    def test_no_objc_forward_calls_without_interface_declarations_iss_123_to_125(self):
        """ISS-123..ISS-125: Verify all newly added selectors, properties, C helpers, and forward declarations compile cleanly under clang -fobjc-arc."""
        def parse_sel(sig_body):
            s = re.sub(r'^\s*\([^)]+\)\s*', '', sig_body.strip())
            if ':' not in s:
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', s)
                return m.group(1) if m else None
            parts = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*:', s)
            return ':'.join(parts) + ':' if parts else None

        all_defined_sels = set()
        smoke_dir = SOURCES.parent / "Tests" / "UISmoke"
        for hp in list(SOURCES.glob("*.h")) + list((SOURCES / "Include").glob("*.h")) + list(SOURCES.glob("*.m")) + list(smoke_dir.glob("*.h")) + list(smoke_dir.glob("*.m")):
            htxt = hp.read_text(encoding="utf-8")
            for m in re.finditer(r'^\s*[-+]\s*(\([^)]+\)[^;{]+)[;{]', htxt, re.M):
                sel = parse_sel(m.group(1))
                if sel:
                    all_defined_sels.add(sel)
            for m in re.finditer(r'@property\s*(?:\([^)]*\))?\s*[^;]+?\b([A-Za-z_][A-Za-z0-9_]*)\s*;', htxt):
                prop = m.group(1)
                all_defined_sels.add(prop)
                all_defined_sels.add("set" + prop[0].upper() + prop[1:] + ":")

        rvc_h = (SOURCES / "RootViewController_Internal.h").read_text(encoding="utf-8")
        self.assertIn("- (void)completeNativeFirstRenderIfNeededForTrigger:(NSString *)trigger;", rvc_h)
        self.assertIn("- (NSDictionary *)anyCatchupChannelForStation:(NSDictionary *)channel;", rvc_h)

        # Ensure every UISmoke @selector(...) exists in Sources
        smoke_dir = SOURCES.parent / "Tests" / "UISmoke"
        for sp in sorted(smoke_dir.glob("*.m")):
            stxt = sp.read_text(encoding="utf-8")
            for m in re.finditer(r'@selector\(([^)]+)\)', stxt):
                sel = m.group(1).strip()
                self.assertIn(sel, all_defined_sels, f"Missing UISmoke selector {sel} in {sp.name}")


if __name__ == "__main__":
    unittest.main()
