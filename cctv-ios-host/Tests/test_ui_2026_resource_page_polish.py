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


if __name__ == "__main__":
    unittest.main()
