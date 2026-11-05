from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MediaDetailContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        cls.detail = cls.source[cls.source.index('@interface MediaDetailViewController'):
                                cls.source.index('@interface MediaFavoritesViewController')]
        cls.impl = cls.source[cls.source.index('@implementation MediaDetailViewController'):
                              cls.source.index('@interface MediaFavoritesViewController')]

    def test_detail_sanitizes_untyped_detail_payload(self):
        self.assertIn('- (NSString *)safeDetailString:(id)value', self.impl)
        self.assertIn('- (NSDictionary *)sanitizedDetail:(id)raw', self.impl)
        self.assertIn('if([value isKindOfClass:NSNumber.class])return [value stringValue];', self.impl)
        self.assertIn('if(![rawLine isKindOfClass:NSDictionary.class])continue;', self.impl)
        self.assertIn('if(![rawEpisode isKindOfClass:NSDictionary.class])continue;', self.impl)
        self.assertIn('if(!episodeID.length)continue;', self.impl)
        self.assertIn('if(!episodes.count)continue;', self.impl)
        self.assertIn('clean[@\"lines\"]=lines;', self.impl)
        # Unknown keys are preserved for the playback context (only known
        # display fields are coerced); the raw dict is the starting point.
        self.assertIn('NSMutableDictionary *clean=[(NSDictionary *)raw mutableCopy];', self.impl)

    def test_detail_load_applies_sanitizer(self):
        load = self.impl.split('- (void)loadDetail', 1)[1].split('- (void)restoreResumeEntrySelection', 1)[0]
        # 合并后是链式双清洗：先实例 sanitizedDetail，再过静态
        # MediaBrowserSanitizedDetail（丢弃行诊断 + 选中恢复）。
        self.assertIn('MediaBrowserSanitizedDetail([owner sanitizedDetail:result],&discardedLines,&discardedEpisodes)', load)
        self.assertIn('owner.detail=sanitizedDetail;', load)
        self.assertNotIn('owner.detail=result;', load)

    def test_detail_favorite_key_tolerates_numeric_ids(self):
        key = self.impl.split('- (NSString *)favoriteKey', 1)[1].split('- (void)updateFavoriteButton', 1)[0]
        self.assertIn('[self safeDetailString:self.source[@\"id\"]]', key)
        self.assertIn('[self safeDetailString:self.item[@\"id\"]]', key)
        self.assertNotIn('self.source[@\"id\"]?:@\"\"', key)
        self.assertNotIn('self.item[@\"id\"]?:@\"\"', key)

    def test_detail_header_uses_safe_string_for_title(self):
        header = self.impl.split('- (void)refreshDetailHeader', 1)[1].split('- (NSString *)favoriteKey', 1)[0]
        self.assertIn('[self safeDetailString:self.detail[@\"name\"]]', header)
        self.assertIn('[self safeDetailString:self.item[@\"name\"]]', header)
        self.assertNotIn('[self.detail[@\"name\"] length]', header)

    def test_detail_synopsis_truncation_preserves_composed_characters(self):
        header = self.impl.split('- (void)refreshDetailHeader', 1)[1].split('- (NSString *)favoriteKey', 1)[0]
        self.assertIn('rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,1200)', header)
        self.assertNotIn('substringToIndex:1200', header)

    def test_detail_episode_navigation_guards_non_array_episodes(self):
        for method in ('- (void)nextEpisodePage', '- (void)playCurrentEpisode'):
            body = self.impl.split(method, 1)[1].split('\n- (void)', 1)[0]
            self.assertIn('[self.lines[self.selectedLineIndex][@\"episodes\"] isKindOfClass:NSArray.class]', body)
        resolve = self.impl.split('- (void)resolveAndPlaySelectedEpisode', 1)[1].split('\n@end', 1)[0]
        self.assertIn('[self.lines[self.selectedLineIndex][@\"episodes\"] isKindOfClass:NSArray.class]', resolve)

    def test_detail_episode_selection_refreshes_grid_immediately(self):
        select = self.impl.split('- (void)selectEpisode:(UIButton *)sender', 1)[1].split('- (void)playCurrentEpisode', 1)[0]
        self.assertIn('self.selectedEpisodeIndex=sender.tag;', select)
        self.assertIn('[self updateRouteAndEpisodeViews];', select)
        self.assertLess(select.index('self.selectedEpisodeIndex=sender.tag;'),
                        select.index('[self updateRouteAndEpisodeViews];'))

    def test_detail_resolve_failure_scrolls_error_into_view(self):
        resolve = self.impl.split('- (void)resolveAndPlaySelectedEpisode', 1)[1].split('\n@end', 1)[0]
        self.assertIn('解析失败：%@', resolve)
        self.assertIn('[owner.scrollView setContentOffset:CGPointMake(0,-owner.scrollView.adjustedContentInset.top) animated:YES];', resolve)

    def test_detail_copy_title_explains_empty_name(self):
        self.assertIn('- (void)showTemporaryStatus:(NSString *)text', self.impl)
        copy = self.impl.split('- (void)copyTitle', 1)[1].split('- (void)shareTitle', 1)[0]
        self.assertIn('[self safeDetailString:self.detail[@\"name\"]]', copy)
        self.assertIn('没有可复制的片名', copy)
        self.assertIn('[self showTemporaryStatus:@\"片名已复制\"];', copy)

    def test_detail_hero_grows_with_large_text(self):
        # 413 是覆盖式 hero，高度按 view 高度算（main 的栈内 hero 按 hero 宽度算）。
        self.assertIn('[hero.heightAnchor constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.62]', self.impl)
        self.assertIn('multiplier:0.62', self.impl)


if __name__ == '__main__':
    unittest.main()
