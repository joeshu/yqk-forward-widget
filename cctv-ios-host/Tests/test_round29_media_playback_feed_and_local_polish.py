import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestRound29MediaPlaybackFeedAndLocalPolish(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_local_media_size_cache_native_menu_state_refresh_and_trait_sync(self):
        src = self._read("Sources/LocalMediaViewController.m")
        self.assertIn("@property(nonatomic,strong) NSMutableDictionary<NSURL *, NSNumber *> *fileSizesByURL;", src)
        self.assertIn("- (void)refreshLocalMedia;", src)
        self.assertIn("UIMenuElementStateOn:UIMenuElementStateOff", src)
        self.assertNotIn('@"✓ 全部文件"', src)
        self.assertNotIn('@"✓ 按文件大小排序"', src)
        self.assertIn("NSDictionary<NSURL *, NSNumber *> *sizes=self.fileSizesByURL?:@{};", src)
        self.assertIn("self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;", src)
        self.assertIn('localRefresh.accessibilityIdentifier=@"local.media.refreshControl";', src)
        self.assertIn("self.view.overrideUserInterfaceStyle=self.overrideUserInterfaceStyle;", src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", src)

    def test_media_feed_skeleton_pulse_hero_context_menu_and_color_trait_sync(self):
        src = self._read("Sources/MediaFeedView.m")
        self.assertIn("- (void)updateSkeletonPulse {", src)
        self.assertIn("UIAccessibilityIsReduceMotionEnabled()", src)
        self.assertIn('media.skeleton.pulse', src)
        self.assertIn('if([kind isEqual:@"hero"]){', src)
        self.assertIn("MediaFeedHeroCell *heroCell=(MediaFeedHeroCell *)[collectionView cellForItemAtIndexPath:indexPath];", src)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:previous", src)

    def test_media_playback_and_detail_trait_and_keyboard_polish(self):
        pb = self._read("Sources/MediaPlaybackViewController.m")
        self.assertIn("self.view.overrideUserInterfaceStyle=self.overrideUserInterfaceStyle;", pb)
        self.assertIn("traitCollectionDidChange:", pb)
        self.assertIn("hasDifferentColorAppearanceComparedToTraitCollection:", pb)

        mb = self._read("Sources/MediaBrowserViewController.m")
        self.assertIn(
            'self.scrollView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.scrollView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.scrollView.accessibilityIdentifier=@"media-detail-scroll";',
            mb,
        )


if __name__ == "__main__":
    unittest.main()
