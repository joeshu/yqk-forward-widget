import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class Round34CellSelfSizingAuditTests(unittest.TestCase):
    """Ensure standard UITableViewCellStyleSubtitle cells never add Auto Layout
    constraints to cell.contentView (which collapses UITableViewAutomaticDimension
    row heights and clips textLabel/detailTextLabel)."""

    def test_01_tvbox_catalog_accent_bar_uses_autoresizing_not_autolayout(self):
        src = (SOURCES / "TVBoxCatalogViewController.m").read_text(encoding="utf-8")
        self.assertIn("accentBar.tag=9201;", src)
        self.assertIn(
            "accentBar.autoresizingMask=UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleRightMargin;",
            src,
        )
        self.assertNotIn("accentBar.translatesAutoresizingMaskIntoConstraints=NO;", src)
        self.assertNotIn("accentBar.topAnchor", src)
        self.assertNotIn("accentBar.bottomAnchor", src)
        self.assertIn("cell.textLabel.adjustsFontForContentSizeCategory=YES;", src)
        self.assertIn("cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;", src)

    def test_02_local_media_accent_bar_uses_autoresizing_not_autolayout(self):
        src = (SOURCES / "LocalMediaViewController.m").read_text(encoding="utf-8")
        self.assertIn("accentBar.tag=8801;", src)
        self.assertIn(
            "accentBar.autoresizingMask=UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleRightMargin;",
            src,
        )
        self.assertNotIn("accentBar.translatesAutoresizingMaskIntoConstraints=NO;", src)
        self.assertNotIn("accentBar.topAnchor", src)
        self.assertNotIn("accentBar.bottomAnchor", src)

    def test_03_plugin_run_history_bar_uses_autoresizing_not_autolayout(self):
        src = (SOURCES / "PluginRunHistoryViewController.m").read_text(encoding="utf-8")
        self.assertIn("bar.tag=9301;", src)
        self.assertIn(
            "bar.autoresizingMask=UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleRightMargin;",
            src,
        )
        self.assertNotIn("bar.translatesAutoresizingMaskIntoConstraints=NO;", src)
        self.assertNotIn("bar.topAnchor", src)
        self.assertNotIn("bar.bottomAnchor", src)

    def test_04_root_playback_panel_decorations_use_autoresizing_not_autolayout(self):
        src = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        panel = src.split("@implementation CCTVPlaybackListPanelController", 1)[1].split("@end", 1)[0]
        self.assertIn("specular.tag=8901;", panel)
        self.assertIn("accentBar.tag=8902;", panel)
        self.assertIn(
            "specular.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin;",
            panel,
        )
        self.assertIn(
            "accentBar.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleRightMargin;",
            panel,
        )
        self.assertNotIn("specular.translatesAutoresizingMaskIntoConstraints=NO;", panel)
        self.assertNotIn("accentBar.translatesAutoresizingMaskIntoConstraints=NO;", panel)

    def test_05_epg_row_decorations_use_autoresizing_not_autolayout(self):
        src = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")
        self.assertIn("epgSpecular.tag = 9103;", src)
        self.assertIn("epgAccentBar.tag = 9104;", src)
        self.assertIn(
            "epgSpecular.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;",
            src,
        )
        self.assertIn(
            "epgAccentBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;",
            src,
        )
        self.assertNotIn("epgSpecular.translatesAutoresizingMaskIntoConstraints = NO;", src)
        self.assertNotIn("epgAccentBar.translatesAutoresizingMaskIntoConstraints = NO;", src)


if __name__ == "__main__":
    unittest.main()
