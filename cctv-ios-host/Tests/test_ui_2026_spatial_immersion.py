import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
CATPAW_PRESENTATION = ROOT.parent / "catpaw" / "presentation.js"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class SpatialImmersion2026Tests(unittest.TestCase):
    def test_item1_global_theme_unification_removes_hardcoded_dark_override(self):
        for filename in [
            "RootViewController.m",
            "MediaBrowserViewController.m",
            "MediaEpisodeSelectionViewController.m",
            "MediaPlaybackViewController.m",
            "ConfigCenterViewController.m",
            "ResourceImportSheetViewController.m",
            "ResourceImportWorkflowViewController.m",
            "SubscriptionResourceViewController.m",
        ]:
            text = read_source(filename)
            self.assertNotIn(
                "overrideUserInterfaceStyle=UIUserInterfaceStyleDark",
                text,
                f"{filename} must follow HostSelectedInterfaceStyle() instead of hardcoding dark mode",
            )
            self.assertIn("HostSelectedInterfaceStyle()", text)

    def test_item2_spatial_glass_2_translucent_alpha_and_specular_rim(self):
        palette = read_source("HostThemePalette.m")
        self.assertIn('@"glassAlpha":@0.62', palette)
        self.assertIn('@"glassAlpha":@0.64', palette)
        self.assertIn('@"glassAlpha":@0.68', palette)
        self.assertNotIn('@"glassAlpha":@0.91', palette)

        theme_h = read_source("HostTheme.h")
        self.assertIn("HostSpecularRimAssociationKey", theme_h)
        self.assertIn("specularRim=[CAGradientLayer layer]", theme_h)
        self.assertIn("HostStyleSurfaceCard(UIView *view, CGFloat radius)", theme_h)

        backdrop = read_source("HostGlassBackdropView.m")
        self.assertIn("UIColor *accent=[HostAccent() resolvedColorWithTraitCollection:traits];", backdrop)
        self.assertIn("UIColor *selected=[HostSelectedSurface() resolvedColorWithTraitCollection:traits];", backdrop)

    def test_item3_pill_button_contrast_shadow_and_border_refinement(self):
        theme_h = read_source("HostTheme.h")
        self.assertIn("button.titleLabel.layer.shadowColor", theme_h)
        self.assertIn("button.titleLabel.layer.shadowRadius = primary ? 1.5 : 0;", theme_h)

    def test_item4_bottom_dock_glass_and_live_mini_player_bar(self):
        root = read_source("RootViewController.m")
        self.assertIn("self.bottomDockGlass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()]", root)
        self.assertIn('self.liveMiniPlayerBar.accessibilityIdentifier=@"live.mini-player.bar"', root)
        self.assertIn('self.liveMiniPlayerResumeButton.accessibilityIdentifier=@"live.mini-player.resume"', root)
        self.assertIn("- (void)resumeSuspendedLiveFromMiniBar", root)

    def test_item5_live_control_bar_sf_symbols_and_epg_live_progress(self):
        root = read_source("RootViewController.m")
        self.assertIn('@"暂停":@"pause.fill"', root)
        self.assertIn('@"节目单":@"list.bullet.rectangle"', root)
        self.assertIn("b.layer.cornerRadius = 12;", root)

        epg = read_source("EPGViewController.m")
        self.assertIn('liveProgress.accessibilityIdentifier = @"epg.live.progress"', epg)
        self.assertIn("liveProgress.progress = progress;", epg)

        pb_info = read_source("PlaybackInfoViewController.m")
        self.assertIn('@"speedometer"', pb_info)
        self.assertIn("c.imageView.tintColor = HostAccent();", pb_info)

    def test_item6_media_home_hero_badge_play_pill_and_adaptive_scroll_chrome(self):
        feed = read_source("MediaFeedView.m")
        self.assertIn('self.heroBadgeLabel.accessibilityIdentifier=@"media-hero-badge"', feed)
        self.assertIn('self.playHintPill.accessibilityIdentifier=@"media-hero-play-pill"', feed)
        self.assertIn("CGAffineTransformMakeScale(1.03,1.03)", feed)

        mb = read_source("MediaBrowserViewController.m")
        self.assertIn("CGFloat collapseProgress=MIN(1.0,MAX(0.0,(offset-24.0)/96.0));", mb)
        self.assertIn("self.selectionRow.alpha=1.0-collapseProgress*0.18;", mb)

    def test_item7_media_detail_foreground_poster_thumbnail_and_first_screen_play_cta(self):
        mb = read_source("MediaBrowserViewController.m")
        self.assertIn("self.posterThumbnailView.hidden=NO;", mb)
        self.assertIn("self.heroBlurView.hidden=NO;", mb)
        self.assertIn(
            "[self.posterThumbnailView.widthAnchor constraintEqualToConstant:72],[self.posterThumbnailView.heightAnchor constraintEqualToConstant:102]",
            mb,
        )
        play_idx = mb.index("[self.contentStack addArrangedSubview:self.playButton];")
        info_idx = mb.index("[self.contentStack addArrangedSubview:infoCard];")
        source_idx = mb.index("[self.contentStack addArrangedSubview:sourceCard];")
        self.assertLess(play_idx, info_idx)
        self.assertLess(play_idx, source_idx)

    def test_item8_episode_selection_quick_horizontal_strip(self):
        ep = read_source("MediaEpisodeSelectionViewController.m")
        self.assertIn('self.quickEpisodeScroll.accessibilityIdentifier=@"media-episode-quick-scroll"', ep)
        self.assertIn("[self.quickEpisodeStack addArrangedSubview:chip]", ep)

    def test_item9_media_playback_landscape_proportion_and_gesture_hud_icons(self):
        mp = read_source("MediaPlaybackViewController.m")
        self.assertIn("multiplier:0.68", mp)
        self.assertIn("multiplier:0.94", mp)
        self.assertIn('if([text containsString:@"亮度"])prefix=@"☀︎ ";', mp)
        self.assertIn('else if([text containsString:@"音量"])prefix=@"🔊 ";', mp)

    def test_item10_resource_center_protocol_badges_and_js_card_presentation(self):
        cc = read_source("ConfigCenterViewController.m")
        self.assertIn('self.protocolBadge.accessibilityIdentifier=@"resource.protocol.badge"', cc)
        self.assertIn("c.protocolBadge.text=", cc)

        riw = read_source("ResourceImportWorkflowViewController.m")
        self.assertIn("sheet.prefersGrabberVisible=YES;", riw)
        self.assertIn("sheet.preferredCornerRadius=26;", riw)

        pres = CATPAW_PRESENTATION.read_text(encoding="utf-8")
        self.assertIn("badge:remarks||text(v.type_name).slice(0,12)", pres)


if __name__ == "__main__":
    unittest.main()
