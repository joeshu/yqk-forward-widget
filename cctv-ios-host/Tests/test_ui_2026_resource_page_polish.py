import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class ResourcePage2026PolishTests(unittest.TestCase):
    def test_01_resource_card_triple_badges_and_tap_to_probe_latency(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn("@property(nonatomic,strong) UILabel *statusBadge;", cc)
        self.assertIn('@"resource.status.badge"', cc)
        self.assertIn('@"resource.latency.badge"', cc)
        self.assertIn("- (void)handleLatencyBadgeTap", cc)
        self.assertIn("HostAnimateSelection(self.latencyBadge);", cc)
        self.assertIn("- (NSString *)statusBadgeTextForProfile:(NSDictionary *)profile", cc)
        self.assertIn('@"  ● 当前使用  "', cc)
        self.assertIn('@"  ● 运行中  "', cc)
        self.assertIn('@"  ⚠ 待处理  "', cc)

    def test_02_resource_card_tactile_spring_highlight_and_active_border(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn("- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated", cc)
        self.assertIn("CGAffineTransformMakeScale(0.985,0.985)", cc)
        self.assertIn("if(isCurrent){c.layer.borderWidth=1.15;HostSetLayerBorderColor(c,HostAccent());", cc)

    def test_03_inline_search_quick_sort_pill_and_specular_border(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn("@property(nonatomic,strong) UIButton *sortFilterButton;", cc)
        self.assertIn('self.sortFilterButton.accessibilityIdentifier=@"resource-sort-pill";', cc)
        self.assertIn("- (void)updateSortPillButton", cc)
        self.assertIn('@"manual":@"⇅ 手动",@"name":@"⇅ A–Z",@"recent":@"⇅ 最近",@"attention":@"⇅ 待处理"', cc)
        self.assertIn("self.resourceSearchField.rightViewMode=UITextFieldViewModeUnlessEditing;", cc)

    def test_04_sticky_compact_header_frosted_glass_and_separator(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn("@property(nonatomic,strong) UIVisualEffectView *compactBlur;", cc)
        self.assertIn("@property(nonatomic,strong) UIView *compactSeparator;", cc)
        self.assertIn("self.compactBlur=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];", cc)
        self.assertIn("self.compactSeparator.backgroundColor=HostSeparator();", cc)
        self.assertIn("button.layer.cornerRadius=18;", cc)

    def test_05_universal_swipe_actions_for_plugins_catalogs_and_subscriptions(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn('title:tvbox?@"打开":@"编辑"', cc)
        self.assertIn('title:@"健康检测"', cc)
        self.assertIn('title:@"刷新合集"', cc)
        self.assertIn('title:@"测速"', cc)

    def test_06_tvbox_catalog_semantic_icons_and_active_service_border(self):
        tvbox = read_source("TVBoxCatalogViewController.m")
        self.assertIn('NSString *iconName=ip.section==0?([row[@"apiKind"] isEqual:@"script"]?@"terminal":@"bolt.horizontal.circle"):@"dot.radiowaves.left.and.right";', tvbox)
        self.assertIn("if(serviceRunning){cell.layer.borderWidth=1.05;HostSetLayerBorderColor(cell,HostAccent());}", tvbox)
        self.assertIn("HostStyleSectionHeaderView(view);", tvbox)
        self.assertIn("HostStyleSectionFooterView(view);", tvbox)

    def test_07_plugin_resource_detail_semantic_icons_and_tabular_numerals(self):
        detail = read_source("PluginResourceDetailViewController.m")
        self.assertIn('@"运行能力":@"cpu"', detail)
        self.assertIn('@"进入媒体":@"play.circle.fill"', detail)
        self.assertIn('@"服务进程":@"bolt.horizontal.circle"', detail)
        self.assertIn("HostMonospacedDigitFont(14,UIFontWeightRegular,UIFontTextStyleSubheadline)", detail)
        self.assertIn("if(isProcessRow&&self.running){cell.layer.borderWidth=1.05;HostSetLayerBorderColor(cell,HostAccent());}", detail)

    def test_08_subscription_and_import_workflow_and_services_visual_refinements(self):
        sub = read_source("SubscriptionResourceViewController.m")
        self.assertIn('@[@"tag",@"link",@"calendar.badge.clock"]', sub)
        self.assertIn("HostStyleSectionHeaderView(view);", sub)

        sheet = read_source("ResourceImportSheetViewController.m")
        self.assertIn("_iconBackground.layer.cornerRadius=16;", sheet)
        self.assertIn("CGAffineTransformMakeScale(0.985,0.985)", sheet)

        wf = read_source("ResourceImportWorkflowViewController.m")
        self.assertIn('@"link.badge.plus"', wf)
        self.assertIn('@"doc.badge.plus"', wf)
        self.assertIn('@"folder.badge.plus"', wf)
        self.assertIn('@"square.grid.2x2"', wf)

        svc = read_source("ServicesViewController.m")
        self.assertIn("if([PyHost isRunningServiceIdentifier:identifier]){c.layer.borderWidth=1.05;HostSetLayerBorderColor(c,HostAccent());}", svc)
        self.assertIn("control.layer.cornerRadius=14;", svc)

    def test_09_player_upper_half_shadow_removed_and_background_auto_advance_enabled(self):
        mp = read_source("MediaPlaybackViewController.m")
        self.assertIn("self.videoTopScrim.colors=@[(id)UIColor.clearColor.CGColor,(id)UIColor.clearColor.CGColor];", mp)
        self.assertIn("self.videoTopScrim.hidden=YES;self.videoTopScrim.opacity=0.0f;", mp)
        self.assertIn("self.videoTopScrim.frame=CGRectZero;self.videoTopScrim.hidden=YES;", mp)
        self.assertNotIn("CGRectGetHeight(self.videoView.bounds)*0.58", mp)

        self.assertIn("AVAudioSessionCategoryPlayback", mp)
        self.assertIn("AVAudioSessionModeMoviePlayback", mp)
        self.assertIn("AVPlayerAudiovisualBackgroundPlaybackPolicyContinuesIfPossible", mp)
        self.assertIn('beginBackgroundTaskWithName:@"cctv.media.autoAdvanceEpisode"', mp)
        self.assertIn("- (void)activateBackgroundAudioSessionIfNeeded", mp)
        self.assertIn("- (void)beginBackgroundAutoAdvanceTaskIfNeeded", mp)
        self.assertIn("- (void)endBackgroundAutoAdvanceTaskIfNeeded", mp)
        self.assertIn("- (void)applicationWillEnterForeground:(NSNotification *)notification", mp)
        self.assertIn("if(self.player&&!self.pictureInPictureActive)self.playerController.player=nil;", mp)
        self.assertIn("BOOL attachViewPlayer=(UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground||self.pictureInPictureActive);self.playerController.player=attachViewPlayer?self.player:nil;", mp)
        self.assertIn("- (void)updateNowPlayingInfoCenter", mp)

    def test_10_cctv_and_channel_pages_segments_recents_casting_center_and_empty_state_actions(self):
        root = read_source("RootViewController.m")
        # 1. Dynamic segments replace 熊猫/订阅 with 收藏/最近, and table list no longer inserts Section 0 recents
        self.assertIn('@[@"全部", @"央视", @"卫视", @"地方", @"其他", @"收藏", @"最近"]', root)
        self.assertIn('@[@"全部", @"央视", @"卫视", @"地方", @"教育", @"收藏", @"最近"]', root)
        self.assertIn("- (void)syncGroupControlSegments", root)
        self.assertNotIn('s == 0 ? @"最近观看" : @"全部频道"', root)

        # 2. Casting Center, AirPlay smart route switching, and LAN IP stream URL rewrite
        self.assertIn('self.castBtn = [self barButton:@"投屏" action:@selector(showCastingCenter)];', root)
        self.assertIn('self.castBtn.accessibilityIdentifier = @"player.control.cast";', root)
        self.assertIn("- (void)showCastingCenter", root)
        self.assertIn("- (BOOL)switchToAirPlayCompatibleRouteIfPossible", root)
        self.assertIn("- (NSString *)castableStreamURLForCurrentChannel", root)
        self.assertIn("static NSString *CCTVDeviceLANIPv4Address(void)", root)
        self.assertIn("self.avPlayer.allowsExternalPlayback=YES;self.avPlayer.usesExternalPlaybackWhileExternalScreenIsActive=YES;", root)

        # 3. Actionable empty state & overlay toggle fix
        self.assertIn("- (UIView *)buildCatalogEmptyBackgroundViewWithMessage:(NSString *)message", root)
        self.assertIn("- (void)enableNativeChannelsFromEmptyState", root)
        self.assertIn('@"catalog.empty.enable-native"', root)
        self.assertIn('@"catalog.empty.add-subscription"', root)


    def test_11_per_resource_channel_logo_switches_and_station_enhancements(self):
        profile_h = read_source("ProfileStore.h")
        profile_m = read_source("ProfileStore.m")
        cc_h = read_source("ConfigCenterViewController.h")
        cc_m = read_source("ConfigCenterViewController.m")
        sub_h = read_source("SubscriptionResourceViewController.h")
        sub_m = read_source("SubscriptionResourceViewController.m")
        plug_m = read_source("PluginResourceDetailViewController.m")
        root_m = read_source("RootViewController.m")

        # ProfileStore per-resource logo toggles and station canonicalization
        for sig in (
            "+ (BOOL)isChannelLogoEnabledForSource:",
            "+ (void)setChannelLogoEnabled:(BOOL)enabled forSource:",
            "+ (BOOL)isPlayerCornerLogoEnabledForSource:",
            "+ (void)setPlayerCornerLogoEnabled:(BOOL)enabled forSource:",
            "+ (BOOL)isChannelLogoEnabledForChannel:",
            "+ (BOOL)isPlayerCornerLogoEnabledForChannel:",
            "+ (nullable NSString *)canonicalStationIDForChannel:",
        ):
            self.assertIn(sig, profile_h)
        self.assertIn("disabledChannelLogoSources", profile_m)
        self.assertIn("disabledPlayerCornerLogoSources", profile_m)
        self.assertIn("canonicalStationIDForChannel:", profile_m)

        # ConfigCenterViewController logo toggle callbacks & menu items
        self.assertIn("onToggleChannelLogo", cc_h)
        self.assertIn("onTogglePlayerCornerLogo", cc_h)
        self.assertIn("onMatchStationLogos", cc_h)
        self.assertIn("- (void)toggleChannelLogoForSource:(NSString *)source enabled:(BOOL)enabled", cc_m)
        self.assertIn("- (void)togglePlayerCornerLogoForSource:(NSString *)source enabled:(BOOL)enabled", cc_m)
        self.assertIn('@"列表与播放器台标：已开启"', cc_m)
        self.assertIn('@"播放器右上角台标：已开启"', cc_m)
        self.assertIn('@"智能匹配官方台标与节目单"', cc_m)

        # SubscriptionResourceViewController switches & station matching row
        self.assertIn("onMatchStationLogos", sub_h)
        self.assertIn('@"subscription.logo.switch"', sub_m)
        self.assertIn('@"subscription.corner-logo.switch"', sub_m)
        self.assertIn("- (void)toggleChannelLogoSwitch:(UISwitch *)sender", sub_m)
        self.assertIn("- (void)togglePlayerCornerLogoSwitch:(UISwitch *)sender", sub_m)
        self.assertIn('@"智能匹配官方高清台标与节目单"', sub_m)

        # PluginResourceDetailViewController live logo toggles
        self.assertIn('@"频道列表与网格台标"', plug_m)
        self.assertIn('@"播放器右上角台标"', plug_m)
        self.assertIn('toggleChannelLogo', plug_m)
        self.assertIn('toggleCornerLogo', plug_m)

        # RootViewController player top-right & list/grid logo integration + station enhancement hub
        self.assertIn("[ProfileStore isChannelLogoEnabledForChannel:ch]", root_m)
        self.assertIn("[ProfileStore isPlayerCornerLogoEnabledForChannel:channel]", root_m)
        self.assertIn("- (void)handlePlayerChannelLogoTap", root_m)
        self.assertIn("- (void)presentStationEnhancementSheetForChannel:", root_m)
        self.assertIn("- (NSArray<NSDictionary *> *)sameStationAlternateChannelsForChannel:", root_m)
        self.assertIn("- (void)matchOfficialStationLogosAndEPGForSource:", root_m)


    def test_12_holistic_migration_backup_and_channel_preview_telemetry_switches(self):
        profile_h = read_source("ProfileStore.h")
        profile_m = read_source("ProfileStore.m")
        backup_m = read_source("HostBackup.m")
        cc_h = read_source("ConfigCenterViewController.h")
        cc_m = read_source("ConfigCenterViewController.m")
        sub_m = read_source("SubscriptionResourceViewController.m")
        plug_m = read_source("PluginResourceDetailViewController.m")
        root_m = read_source("RootViewController.m")
        settings_m = read_source("SettingsViewController.m")

        for sig in (
            "+ (BOOL)isChannelPreviewEnabledForSource:",
            "+ (void)setChannelPreviewEnabled:(BOOL)enabled forSource:",
            "+ (BOOL)isChannelPreviewEnabledForChannel:",
            "+ (BOOL)isChannelTelemetryEnabledForSource:",
            "+ (void)setChannelTelemetryEnabled:(BOOL)enabled forSource:",
            "+ (BOOL)isChannelTelemetryEnabledForChannel:",
            "+ (void)migrateResourceDisplaySettingsFromSource:(nullable NSString *)oldSource toSource:(nullable NSString *)newSource;",
        ):
            self.assertIn(sig, profile_h)

        self.assertIn("disabledChannelPreviewSources", profile_m)
        self.assertIn("disabledChannelTelemetrySources", profile_m)
        self.assertIn("migrateResourceDisplaySettingsFromSource:", profile_m)

        for key in (
            '@"nativeChannelLogoEnabled"',
            '@"nativeChannelPreviewEnabled"',
            '@"nativeChannelTelemetryEnabled"',
            '@"cctv.mediaEpisodeShowBadge.v1"',
            '@"cctv.mediaEpisodeAutoExpand.v1"',
            '@"cctv.mediaEpisodeLayoutStyle.v1"',
        ):
            self.assertIn(key, backup_m)
            self.assertIn(key, settings_m)

        self.assertIn("onToggleChannelPreview", cc_h)
        self.assertIn("onToggleChannelTelemetry", cc_h)
        self.assertIn("- (void)toggleChannelPreviewForSource:(NSString *)source enabled:(BOOL)enabled", cc_m)
        self.assertIn("- (void)toggleChannelTelemetryForSource:(NSString *)source enabled:(BOOL)enabled", cc_m)
        self.assertIn('@"频道实时预览图：已开启"', cc_m)
        self.assertIn('@"频道速率与延迟：已开启"', cc_m)

        self.assertIn('@"subscription.preview.switch"', sub_m)
        self.assertIn('@"subscription.telemetry.switch"', sub_m)
        self.assertIn("- (void)toggleChannelPreviewSwitch:(UISwitch *)sender", sub_m)
        self.assertIn("- (void)toggleChannelTelemetrySwitch:(UISwitch *)sender", sub_m)

        self.assertIn('@"频道实时预览图"', plug_m)
        self.assertIn('@"频道速率与延迟"', plug_m)
        self.assertIn("toggleChannelPreview", plug_m)
        self.assertIn("toggleChannelTelemetry", plug_m)

        self.assertIn("- (UIImage *)previewImageForChannel:(NSDictionary *)channel", root_m)
        self.assertIn("- (void)captureLivePreviewSnapshotForChannelID:(NSString *)cid", root_m)
        self.assertIn("- (NSString *)telemetryBadgeTextForChannel:(NSDictionary *)channel color:(UIColor * __autoreleasing *)colorOut", root_m)
        self.assertIn("- (void)probeTelemetryForChannel:(NSDictionary *)channel", root_m)
        self.assertIn("[ProfileStore migrateResourceDisplaySettingsFromSource:", root_m)

    def test_13_vod_detail_and_selection_multi_style_episode_list_and_switches(self):
        layout_h = read_source("MediaEpisodeLayout.h")
        browser_m = read_source("MediaBrowserViewController.m")
        selection_m = read_source("MediaEpisodeSelectionViewController.m")

        for token in (
            "CCTVEpisodeLayoutStyleGrid4 = 0",
            "CCTVEpisodeLayoutStyleList = 1",
            "CCTVEpisodeLayoutStyleCard2 = 2",
            "CCTVEpisodeLayoutStyleGrid3 = 3",
            "CCTVEpisodeCurrentLayoutStyle(void)",
            "CCTVEpisodeSetLayoutStyle(CCTVEpisodeLayoutStyle style)",
            "CCTVEpisodeColumnsForStyle(CCTVEpisodeLayoutStyle style, BOOL isAccessibilityCategory)",
            "CCTVEpisodeFormattedDisplayTitle(NSDictionary *episode, NSUInteger sourceIndex, CCTVEpisodeLayoutStyle style, BOOL selected, BOOL resumeMatch, BOOL showBadge)",
        ):
            self.assertIn(token, layout_h)

        self.assertIn('@"media-detail-episode-style"', browser_m)
        self.assertIn("- (void)cycleEpisodeLayoutStyle", browser_m)
        self.assertIn("- (UIMenu *)buildEpisodeStyleMenu", browser_m)
        self.assertIn("- (void)presentEpisodeGroupJumpSheet", browser_m)
        self.assertIn("- (UIMenu *)episodeStyleConfigurationMenu", browser_m)

        self.assertIn('@"media-episode-style"', selection_m)
        self.assertIn("- (void)cycleEpisodeLayoutStyle", selection_m)
        self.assertIn("- (UIMenu *)buildEpisodeStyleMenu", selection_m)
        self.assertIn("CCTVEpisodeColumnsForStyle(epStyle,isAccessibilitySize)", selection_m)
        self.assertIn("CCTVEpisodeFormattedDisplayTitle(episode,index,epStyle,selected,NO,showEpBadge)", selection_m)


if __name__ == "__main__":
    unittest.main()
