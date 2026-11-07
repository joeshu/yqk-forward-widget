import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class UI2026DeepRefinementsTests(unittest.TestCase):
    def test_ref1_settings_theme_palette_preview_dots_and_cards(self):
        settings = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn('NSString *dot=theme.dark?@"● ":@"○ ";', settings)
        self.assertIn("cell.layer.cornerRadius=14; cell.layer.cornerCurve=kCACornerCurveContinuous;", settings)

    def test_ref2_root_channel_list_cell_card_rounding_and_border(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous;", root)
        self.assertIn("HostSetLayerBorderColor(cell,playing?HostAccent():HostBorder());", root)

    def test_ref3_epg_guide_cell_card_rounding_and_active_border(self):
        epg = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous;", epg)
        self.assertIn("HostSetLayerBorderColor(cell,live?HostAccent():HostBorder());", epg)
        self.assertIn("HostStylePillButton(self.dateMenuButton,NO);HostInstallPressFeedback(self.dateMenuButton);", epg)

    def test_ref4_media_detail_resume_episode_accent_border(self):
        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn('button.accessibilityHint=@"上次播放至此集";', browser)
        self.assertIn("HostSetLayerBorderColor(button,HostAccent());", browser)

    def test_ref5_favorites_and_history_poster_thumbnail_rounding(self):
        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(browser.count("cell.imageView.layer.cornerRadius=10;cell.imageView.layer.cornerCurve=kCACornerCurveContinuous;"), 2)

    def test_ref6_global_search_result_floating_cards_and_poster_corners(self):
        search = (SOURCES / "MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.layer.cornerRadius=14;self.layer.cornerCurve=kCACornerCurveContinuous;", search)
        self.assertIn("self.poster.layer.cornerRadius=10;self.poster.layer.cornerCurve=kCACornerCurveContinuous;", search)
        self.assertIn("self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;", search)
        self.assertIn("HostStylePillButton(self.historyButton,NO);", search)
        self.assertIn("HostInstallPressFeedback(self.historyButton);", search)

    def test_ref7_runtime_diagnostics_status_badges_and_cards(self):
        diag = (SOURCES / "RuntimeDiagnosticsViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius = 14; cell.layer.cornerCurve = kCACornerCurveContinuous;", diag)
        self.assertIn('@"未正常收尾 ⚠"', diag)
        self.assertIn('[self showTransientPrompt:@"诊断事件已复制"];', diag)

    def test_ref8_tvbox_catalog_card_borders_and_corners(self):
        catalog = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.layer.cornerRadius=13;cell.layer.cornerCurve=kCACornerCurveContinuous;", catalog)
        self.assertIn("HostSetLayerBorderColor(cell,HostBorder());", catalog)

    def test_ref9_playback_gesture_feedback_spring_animation(self):
        playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("usingSpringWithDamping:0.75 initialSpringVelocity:0.4", playback)
        self.assertIn("usingSpringWithDamping:0.65 initialSpringVelocity:0.5", playback)

    def test_ref10_playback_quality_buttons_press_feedback(self):
        playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostInstallPressFeedback(button);MediaPlaybackApplyScaledPillFont(button);", playback)

    def test_ref11_full_app_live_theme_reload_and_interface_style_coverage(self):
        for p in sorted(SOURCES.glob("*.m")):
            text = p.read_text(encoding="utf-8")
            for cls in re.findall(r"@implementation\s+(\w+)", text):
                if "ViewController" in cls or cls in ("MediaSourcePicker", "CCTVPlaybackListPanelController"):
                    block = re.search(rf"@implementation\s+{cls}\b(.*?)@end", text, re.S).group(1)
                    with self.subTest(file=p.name, controller=cls):
                        self.assertIn("- (void)reloadThemeAppearance", block)
                        self.assertIn("overrideUserInterfaceStyle", block)

    def test_ref12_live_panel_and_source_picker_spatial_selected_cards(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.backgroundColor=selected?HostSelectedSurface():HostCard();", root)
        self.assertIn("cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());", root)

        browser = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("cell.backgroundColor=selected?HostSelectedSurface():HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());", browser)

    def test_ref13_playback_info_and_log_center_and_web_player_spatial_polish(self):
        info = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostSetLayerBorderColor(c, HostBorder());", info)
        self.assertIn('@"实时播放链路指标 · 点按任意行可复制"', info)
        self.assertIn('[self showTransientPrompt:@"指标已复制"];', info)

        log_center = (SOURCES / "LogCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("card.layer.borderWidth=0.6;HostSetLayerBorderColor(card,HostBorder());", log_center)
        self.assertIn('@"跳到最新末尾"', log_center)
        self.assertIn('[self showTransientPrompt:@"日志内容已复制"];', log_center)

        web = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostStyleGlassCard(self.statusCard,16);", web)
        self.assertIn('@"网页操作"', web)
        self.assertIn('@"复制当前网页地址"', web)

        feed = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("self.poster.layer.borderWidth=0.6;HostSetLayerBorderColor(self.poster,HostBorder());", feed)
        self.assertIn("self.contentView.layer.borderWidth=0.6;HostSetLayerBorderColor(self.contentView,HostBorder());", feed)


    def test_ref14_resource_page_squircle_icon_horizontal_badges_and_full_width_detail(self):
        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.iconBadgeContainer=[UIView new];", cc)
        self.assertIn("[self.profileTitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8]", cc)
        self.assertIn("[self.latencyBadge.leadingAnchor constraintEqualToAnchor:self.protocolBadge.trailingAnchor constant:6]", cc)
        self.assertIn("[self.profileDetailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8]", cc)
        self.assertIn('@"共 %lu 项 · 合集 %lu · 订阅启用 %lu · 服务启用 %lu · 运行中 %lu"', cc)

    def test_ref15_media_detail_and_inline_player_dedup_and_unclipped_controls(self):
        mp = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        self.assertIn("qualityScrollHeight.priority=UILayoutPriorityDefaultHigh;", mp)
        self.assertIn("!MediaPlaybackEpisodeNamesMatch(name,number)", mp)
        self.assertIn("[self.qualityGroup.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:11]", mp)

        mb = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.playButton.hidden=(self.inlinePlaybackController!=nil);", mb)
        self.assertIn('@"url",@"http",@"https",@"null",@"nil",@"none",@"unknown"', mb)
        self.assertIn("self.metadataLabel.hidden=(info.count==0);", mb)


    def test_ref16_live_player_bottom_scrim_embedded_epg_frame_and_dock_fade(self):
        root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.playerBottomScrim=[UIView new];", root)
        self.assertIn("self.bottomDockFadeGradient=[CAGradientLayer layer];", root)
        self.assertIn("self.playbackPanel.view.frame=[self.playbackPanel isKindOfClass:CCTVPlaybackListPanelController.class]?frame:CGRectMake(0,contentY,w,MAX(0,contentBottom-contentY));", root)
        self.assertIn("CGFloat catalogBottomInset=tabContentInset+62;", root)

    def test_ref17_playback_info_icons_settings_chips_and_media_feed_dedup(self):
        info = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")
        self.assertIn("@\"tv.fill\"", info)
        self.assertIn("@\"number.square\"", info)
        self.assertIn("@\"cpu\"", info)
        self.assertIn("@\"bolt.fill\"", info)
        self.assertIn("@\"app.badge.checkmark\"", info)

        feed = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("if([candidateDetail isEqualToString:badgeText])candidateDetail=@\"\";", feed)
        self.assertIn("@\"精选热播 · 点按查看详情\"", feed)

        mb = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("item[@\"feedSubtitle\"]=srcName.length?[NSString stringWithFormat:@\"继续观看 · %@\",srcName]:@\"继续观看\";", mb)
        self.assertIn("self.categoryScroll.contentInset=UIEdgeInsetsMake(0,0,0,14);", mb)

        st = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("@\"  🛡️ 纯本地无上传  \"", st)
        self.assertIn("bottom=MAX(24,self.bottomOverlayInset+22);", st)

    def test_ref18_spatial_typography_rounded_headers_monospaced_digits_and_editorial_accents(self):
        theme = (SOURCES / "HostTheme.h").read_text(encoding="utf-8")
        self.assertIn("HostRoundedFont(", theme)
        self.assertIn("HostMonospacedDigitFont(", theme)
        self.assertIn("HostStyleSectionHeaderView(", theme)
        self.assertIn("HostStyleSectionFooterView(", theme)
        self.assertIn("NSKernAttributeName : @(-0.35)", theme)

        feed = (SOURCES / "MediaFeedView.m").read_text(encoding="utf-8")
        self.assertIn("self.posterScrim=[CAGradientLayer layer];", feed)
        self.assertIn("self.accentBar=[UIView new];", feed)
        self.assertIn("self.nameLabel.layer.shadowOpacity=0.58;", feed)

        mb = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostRoundedFont(21,UIFontWeightBold,UIFontTextStyleTitle2)", mb)
        self.assertIn("HostMonospacedDigitFont(12,UIFontWeightMedium,UIFontTextStyleCaption1)", mb)

        cc = (SOURCES / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("HostMonospacedDigitFont(10.5,UIFontWeightBold,UIFontTextStyleCaption2)", cc)
        self.assertIn("HostStyleSectionHeaderView(view);", cc)


if __name__ == "__main__":

    unittest.main()
