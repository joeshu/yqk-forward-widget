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
        self.assertIn('- (NSDictionary *)sanitizedDetail:(id)raw discardedLines:(NSUInteger *)discardedLines discardedEpisodes:(NSUInteger *)discardedEpisodes', self.impl)
        self.assertIn('if([value isKindOfClass:NSNumber.class])return [value stringValue];', self.impl)
        # 统一清洗器：丢弃的行/集计入 out-param，loadDetail 的诊断事件才能触发。
        self.assertIn('if(discardedLines)*discardedLines=0;if(discardedEpisodes)*discardedEpisodes=0;', self.impl)
        self.assertIn('if(![rawLine isKindOfClass:NSDictionary.class]){droppedLines++;continue;}', self.impl)
        self.assertIn('if(![rawEpisode isKindOfClass:NSDictionary.class]){droppedEpisodes++;continue;}', self.impl)
        self.assertIn('if(!episodeID.length){droppedEpisodes++;continue;}', self.impl)
        self.assertIn('if(!episodes.count){droppedLines++;continue;}', self.impl)
        self.assertIn('if(discardedLines)*discardedLines=droppedLines;if(discardedEpisodes)*discardedEpisodes=droppedEpisodes;', self.impl)
        self.assertIn('@\"vod_pic\"', self.impl)
        self.assertNotIn('MediaBrowserSanitizedDetail', self.source)
        self.assertIn('clean[@\"lines\"]=lines;', self.impl)
        # Unknown keys are preserved for the playback context (only known
        # display fields are coerced); the raw dict is the starting point.
        self.assertIn('NSMutableDictionary *clean=[(NSDictionary *)raw mutableCopy];', self.impl)

    def test_detail_load_applies_sanitizer(self):
        load = self.impl.split('- (void)loadDetail', 1)[1].split('- (void)restoreResumeEntrySelection', 1)[0]
        # 统一清洗器：一次调用同时清洗并回传丢弃计数，诊断事件才能触发。
        self.assertIn('[owner sanitizedDetail:result discardedLines:&discardedLines discardedEpisodes:&discardedEpisodes]', load)
        self.assertNotIn('MediaBrowserSanitizedDetail', load)
        self.assertIn('owner.detail=sanitizedDetail;', load)
        self.assertNotIn('owner.detail=result;', load)

    def test_detail_fresh_cache_skips_network_and_manual_reload_revalidates(self):
        load = self.impl.split('- (void)loadDetail {', 1)[1].split('- (void)restoreResumeEntrySelection', 1)[0]
        self.assertIn('[self loadDetailRefreshing:NO]', load)
        self.assertIn('[self loadDetailRefreshing:YES]', load)
        self.assertIn('if(!cacheStale&&!forceRefresh)return;', load)
        self.assertLess(load.index('if(!cacheStale&&!forceRefresh)return;'), load.index('[self.client call:@"detail"'))
        self.assertNotIn('safeDetailMemCache', load)
        self.assertIn('maximumAge:300', load)
        self.assertIn('dispatch_async(detailProcessingQueue', load)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', load)
        self.assertIn('owner.generation!=generation', load)

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
        self.assertIn('[hero.heightAnchor constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.36]', self.impl)
        self.assertIn('multiplier:0.36', self.impl)


    def test_detail_recovers_human_title_when_spider_returns_opaque_id(self):
        self.assertIn('MediaDetailPreferredTitle(', self.source)
        import sys
        sys.path.insert(0, str(ROOT / 'Plugins'))
        import host_media_runtime as media
        # Case 1: detailContent omits vod_name and falls back to opaque ID, but vod_content has 《小猪佩奇》
        d1 = media.detail({
            'vod_id': 'feca5fe770ef4cdeba3d',
            'vod_content': '《小猪佩奇》是一部针对学龄前儿童的动画片，讲述的是一只名叫佩奇的可爱小猪的故事。',
            'vod_play_from': '优酷',
            'vod_play_url': '第1集$https://v.youku.com/v_show/id_XNjU.html',
        }, 'feca5fe770ef4cdeba3d')
        self.assertEqual(d1['name'], '小猪佩奇')

    def test_media_home_disables_inline_continue_watching_while_retaining_menu_history(self):
        defs = self.source.split('static NSArray<NSDictionary *> *MediaHomeModuleDefinitions(void)', 1)[1].split('}', 1)[0]
        self.assertNotIn('@"id":@"continue"', defs)
        self.assertIn('if(NO&&[enabled containsObject:@"continue"])', self.source)
        self.assertIn('[UIAction actionWithTitle:@"观看历史"', self.source)


if __name__ == '__main__':
    unittest.main()
