import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    return (SOURCES / name).read_text(encoding="utf-8")


class Round40PagePolishAndThemeNavFixesTests(unittest.TestCase):
    def test_01_shared_navigation_bar_not_polluted_by_playback_or_detail(self):
        playback = read_source("MediaPlaybackViewController.m")
        detail = read_source("MediaBrowserViewController.m")

        # MediaPlaybackViewController must skip nav bar changes in embeddedMode
        # and scope appearance to self.navigationItem when standalone.
        vwa = playback.split("- (void)viewWillAppear:(BOOL)animated {", 1)[1].split(
            "\n- (void)viewWillTransitionToSize:", 1
        )[0]
        self.assertIn("if(!self.embeddedMode){", vwa)
        self.assertIn("self.navigationItem.standardAppearance=scrolled;", vwa)
        self.assertIn("self.navigationItem.scrollEdgeAppearance=edge;", vwa)
        self.assertNotIn("bar.standardAppearance=", vwa)
        self.assertNotIn("UIColor.whiteColor", vwa)

        # MediaDetailViewController must scope appearance to self.navigationItem
        # so pushed pages (TVBoxCatalog / MediaGlobalSearch) keep HostStyleNavigation.
        detail_vwa = detail.split("@implementation MediaDetailViewController", 1)[1].split(
            "- (void)viewWillAppear:(BOOL)animated {", 1
        )[1].split("\n- (void)viewWillDisappear:", 1)[0]
        self.assertIn("self.navigationItem.standardAppearance=scrolled;", detail_vwa)
        self.assertIn("self.navigationItem.scrollEdgeAppearance=edge;", detail_vwa)
        self.assertNotIn("bar.standardAppearance=", detail_vwa)

    def test_02_global_theme_switch_propagates_to_nav_bar_and_bottom_dock(self):
        theme_h = read_source("HostTheme.h")
        root_m = read_source("RootViewController.m")

        self.assertIn("nav.overrideUserInterfaceStyle = targetStyle;", theme_h)
        self.assertIn("nav.navigationBar.overrideUserInterfaceStyle = targetStyle;", theme_h)
        self.assertIn("if(w.rootViewController)w.rootViewController.overrideUserInterfaceStyle=target;", theme_h)

        reload_body = root_m.split("- (void)reloadThemeAppearance {", 1)[1].split(
            "\n- (SettingsViewController *)makeSettingsPage", 1
        )[0]
        self.assertIn("self.navigationController.overrideUserInterfaceStyle=targetStyle;", reload_body)
        self.assertIn("self.navigationController.navigationBar.overrideUserInterfaceStyle=targetStyle;", reload_body)
        self.assertIn("resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:targetStyle]", reload_body)
        self.assertIn("[self setNeedsStatusBarAppearanceUpdate];", reload_body)
        self.assertIn("HostSetLayerBorderColor(catalogControls,HostBorder());", root_m)

    def test_03_episode_selection_no_double_nav_bar_and_visible_description(self):
        root_m = read_source("RootViewController.m")
        ep_m = read_source("MediaEpisodeSelectionViewController.m")

        self.assertIn('if([visibleController isKindOfClass:NSClassFromString(@"MediaEpisodeSelectionViewController")])return YES;', root_m)
        self.assertIn("if(navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:animated];", root_m)
        self.assertIn("self.descriptionLabel.translatesAutoresizingMaskIntoConstraints=NO;", ep_m)
        self.assertIn("toggleMinHeight.priority=UILayoutPriorityDefaultHigh;", ep_m)

    def test_04_resource_cells_settings_tiles_import_placeholder_epg_and_mini_bar(self):
        config_m = read_source("ConfigCenterViewController.m")
        settings_m = read_source("SettingsViewController.m")
        import_m = read_source("ResourceImportWorkflowViewController.m")
        epg_m = read_source("EPGViewController.m")
        root_m = read_source("RootViewController.m")

        self.assertIn("[self.profileTitleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];", config_m)
        self.assertIn("self.capabilityBadge.hidden=(CGRectGetWidth(self.capabilityBadge.frame)<needed-2.0);", config_m)
        self.assertIn("UIFont *titleFont=HostRoundedFont(16, UIFontWeightBold, UIFontTextStyleHeadline)", config_m)

        self.assertIn("titleLbl.adjustsFontSizeToFitWidth=YES;", settings_m)
        self.assertIn("subLbl.adjustsFontSizeToFitWidth=YES;", settings_m)
        self.assertIn("subtitleLabel.adjustsFontSizeToFitWidth=YES;", settings_m)

        self.assertIn("self.addressPlaceholder.numberOfLines=0;", import_m)
        self.assertIn("self.address.frameLayoutGuide.trailingAnchor constant:-10", import_m)

        self.assertIn("CGRectGetHeight(cell.contentView.bounds) - 6", epg_m)
        self.assertIn("CGFloat pageBottomInset=tabContentInset+(showMiniBar?50:0);", root_m)

    def test_05_ios15_default_rate_guards_and_compiler_warning_fixes(self):
        playback = read_source("MediaPlaybackViewController.m")
        theme_h = read_source("HostTheme.h")
        probe = read_source("HLSRouteProbe.m")
        services = read_source("ServicesViewController.m")
        root_services = read_source("RootViewController+Services.m")

        self.assertIn("static float MediaPlaybackDefaultRate(AVPlayer *player)", playback)
        self.assertIn("static void MediaPlaybackSetDefaultRate(AVPlayer *player, float rate)", playback)
        # Only the helper itself should access .defaultRate directly (inside @available(iOS 16.0, *)).
        self.assertEqual(playback.count(".defaultRate"), 3)

        self.assertIn("static inline void HostInstallPressFeedback(UIControl *button)", theme_h)
        self.assertIn("static dispatch_queue_t underlyingQueue;", probe)
        self.assertIn("\\\\s*[:=]?\\\\s*", services)
        self.assertIn("__weak TVBoxCatalogBulkImporter *weakImporter=importer;", root_services)


if __name__ == "__main__":
    unittest.main()
