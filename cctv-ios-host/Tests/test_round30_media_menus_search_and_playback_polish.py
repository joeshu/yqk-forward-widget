import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestRound30MediaMenusSearchAndPlaybackPolish(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_playback_options_menu_uses_native_state_and_inline_sections(self):
        src = self._read("Sources/MediaPlaybackViewController.m")
        self.assertIn("optAct.state=[selected isEqual:option]?UIMenuElementStateOn:UIMenuElementStateOff;", src)
        self.assertIn("rateAct.state=fabs(currentRate-rate)<0.01?UIMenuElementStateOn:UIMenuElementStateOff;", src)
        self.assertIn("gravAct.state=active?UIMenuElementStateOn:UIMenuElementStateOff;", src)
        self.assertIn("decAct.state=[currentDecodeMode isEqualToString:val]?UIMenuElementStateOn:UIMenuElementStateOff;", src)
        self.assertIn('identifier:@"media.playback.menu.av" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.playback.menu.prefs" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.playback.menu.diag" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.playback.menu.episodes" options:UIMenuOptionsDisplayInline', src)

    def test_global_search_weak_self_and_highlight_feedback(self):
        src = self._read("Sources/MediaGlobalSearchViewController.m")
        self.assertIn(
            "MediaGlobalSearchViewController *owner=weakSelf;if(owner&&owner.isViewLoaded&&owner.initialKeyword.length&&[owner.searchBar.text isEqual:owner.initialKeyword])[owner submitSearch];",
            src,
        )
        self.assertIn("- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath", src)
        self.assertIn("- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath", src)

    def test_media_browser_detail_weak_self_and_grouped_menus(self):
        src = self._read("Sources/MediaBrowserViewController.m")
        self.assertIn(
            "if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf handleEpisodeLayoutStyleDidChange];});return;}",
            src,
        )
        self.assertIn('identifier:@"media.detail.menu.nav" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.detail.menu.share" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.home.menu.library" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.home.menu.tools" options:UIMenuOptionsDisplayInline', src)
        self.assertIn('identifier:@"media.display.settings"', src)
        self.assertIn('identifier:@"media.home.refresh"', src)


if __name__ == "__main__":
    unittest.main()
