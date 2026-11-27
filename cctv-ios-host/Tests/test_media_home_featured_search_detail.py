"""影视精选、搜索、详情、选集与来源 UI（T15：M08–M10/M14/M15、V03/V07）。

行为部分用 Python 模型复刻改后语义并真实执行：
- M10 缓存年龄：fresh（<5 分钟）/ stale（5 分钟–6 小时）/ expired（>6 小时）
  三档与年龄文案；时钟回拨（存入时间在未来）视为未知；
- M14：首页模块白名单只剩精选与分类，继续观看不恢复首页模块，只走菜单历史；
- 选集：分页按钮边界禁用；大字体减列；详情刷新后按稳定 ID（先 ID 后名）
  复位线路/分集，找不到才按索引夹取；
- 全局搜索取消：保留已取得结果、行状态标“已取消”、右键变“重试失败”。

已由 T05 修好的不重做，只回归锁定：M08 架子失败≠空（test_search_state.py）、
M09 清空关键词回当前分类第一页（同文件）、M15 整页无新增即停续页（同文件）。
模型与源码的对应关系由同文件合同测试锁定。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'
TESTS = ROOT / 'Tests'

BROWSER = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
CACHE_H = (SOURCES / 'MediaMetadataCache.h').read_text(encoding='utf-8')
CACHE_M = (SOURCES / 'MediaMetadataCache.m').read_text(encoding='utf-8')
FEED = (SOURCES / 'MediaFeedView.m').read_text(encoding='utf-8')
GLOBAL_SEARCH = (SOURCES / 'MediaGlobalSearchViewController.m').read_text(encoding='utf-8')
EPISODE_LAYOUT = (SOURCES / 'MediaEpisodeLayout.h').read_text(encoding='utf-8')
EPISODE_PAGE = (SOURCES / 'MediaEpisodeSelectionViewController.m').read_text(encoding='utf-8')
DETAIL_CONTRACTS = (TESTS / 'test_media_detail_contracts.py').read_text(encoding='utf-8')


# ---------------------------------------------------------------- M10 模型

def cache_age_state(age):
    """复刻 MediaBrowserCacheAgeState：-1 未知；0 新鲜；1 陈旧；2 过期。"""
    if age < 0:
        return -1
    if age < 5 * 60:
        return 0
    if age <= 6 * 3600:
        return 1
    return 2


def cache_age_text(age):
    """复刻 MediaBrowserCacheAgeText。"""
    if age < 0:
        return ''
    if age < 60:
        return '刚刚'
    if age < 3600:
        return '%d分钟前' % int(age // 60)
    if age < 86400:
        return '%d小时前' % int(age // 3600)
    return '%d天前' % int(age // 86400)


def cache_age_of(stored_at, now):
    """复刻 ageOfResultForSource 的年龄计算：无记录或未来时间返回 -1。"""
    if stored_at is None or stored_at <= 0:
        return -1
    age = now - stored_at
    return -1 if age < 0 else age


# ---------------------------------------------------------------- 选集模型

def episode_columns(style, is_accessibility_category):
    """复刻 CCTVEpisodeColumnsForStyle。style：list/card2/grid3/grid4。"""
    if style == 'list':
        return 1
    if style == 'card2':
        return 1 if is_accessibility_category else 2
    if style == 'grid3':
        return 2 if is_accessibility_category else 3
    return 3 if is_accessibility_category else 4


def paging_buttons(page, total_episodes, per_group=30):
    """复刻选集分页按钮启用态：首组禁上一组、末组禁下一组。"""
    pages = max(1, -(-total_episodes // per_group))
    return {'previous_enabled': page > 0, 'next_enabled': page + 1 < pages}


def restore_selection(old_lines, old_line_index, old_episode_index, new_lines):
    """复刻 restoreSelectionFromDetail：先稳定 ID、后名字、最后索引夹取。"""
    if not old_lines:
        line = min(max(0, old_line_index), len(new_lines) - 1) if new_lines else 0
        episodes = new_lines[line].get('episodes', []) if new_lines else []
        episode = min(max(0, old_episode_index), len(episodes) - 1) if episodes else 0
        return line, episode
    old_line_index = min(max(0, old_line_index), len(old_lines) - 1)
    old_line = old_lines[old_line_index]
    old_episodes = old_line.get('episodes', [])
    old_episode_index = min(max(0, old_episode_index), len(old_episodes) - 1) if old_episodes else 0
    old_episode = old_episodes[old_episode_index] if old_episodes else {}
    line_id, line_name = str(old_line.get('id', '')), old_line.get('name', '')
    episode_id = str(old_episode.get('id', ''))
    episode_name = old_episode.get('name', '')

    def find_line():
        for i, line in enumerate(new_lines):
            if line_id and str(line.get('id', '')) == line_id:
                return i
        for i, line in enumerate(new_lines):
            if line_name and line.get('name', '') == line_name:
                return i
        return min(old_line_index, len(new_lines) - 1) if new_lines else 0

    line = find_line()
    new_episodes = new_lines[line].get('episodes', []) if new_lines else []
    episode = min(old_episode_index, len(new_episodes) - 1) if new_episodes else 0
    for i, ep in enumerate(new_episodes):
        if episode_id and str(ep.get('id', '')) == episode_id:
            episode = i
            break
    else:
        for i, ep in enumerate(new_episodes):
            if episode_name and ep.get('name', '') == episode_name:
                episode = i
                break
    return line, episode


# ---------------------------------------------------------------- 全局搜索取消模型

def cancel_search_model(rows):
    """复刻 cancelSearch：搜索中/等待中的行与 provider 态标已取消，结果保留。"""
    for row in rows:
        states = row.get('providerStates', {})
        for key, state in list(states.items()):
            if state == '正在加载更多':
                states[key] = '已取消加载 · 点按重试'
            elif state in ('搜索中', '等待搜索'):
                states[key] = '已取消'
        if row.get('state') in ('搜索中', '等待搜索', '等待重试', '等待健康检查'):
            row['state'] = '已取消'
    return rows


class TestCacheAgeModel(unittest.TestCase):
    def test_age_state_boundaries(self):
        self.assertEqual(cache_age_state(-1), -1)
        self.assertEqual(cache_age_state(0), 0)
        self.assertEqual(cache_age_state(299), 0)
        self.assertEqual(cache_age_state(300), 1)
        self.assertEqual(cache_age_state(6 * 3600), 1)
        self.assertEqual(cache_age_state(6 * 3600 + 1), 2)
        self.assertEqual(cache_age_state(86400 * 3), 2)

    def test_age_text(self):
        self.assertEqual(cache_age_text(-1), '')
        self.assertEqual(cache_age_text(0), '刚刚')
        self.assertEqual(cache_age_text(59), '刚刚')
        self.assertEqual(cache_age_text(60), '1分钟前')
        self.assertEqual(cache_age_text(3599), '59分钟前')
        self.assertEqual(cache_age_text(3600), '1小时前')
        self.assertEqual(cache_age_text(6 * 3600), '6小时前')
        self.assertEqual(cache_age_text(90000), '1天前')

    def test_clock_rollback_is_unknown(self):
        # 存入时间在未来（时钟回拨）：年龄视为未知，不展示假时间。
        self.assertEqual(cache_age_of(2000, 1000), -1)
        self.assertEqual(cache_age_of(None, 1000), -1)
        self.assertEqual(cache_age_of(0, 1000), -1)
        self.assertEqual(cache_age_of(900, 1000), 100)


class TestEpisodeSelectionModel(unittest.TestCase):
    def test_columns_shrink_at_accessibility_sizes(self):
        self.assertEqual(episode_columns('list', False), 1)
        self.assertEqual(episode_columns('list', True), 1)
        self.assertEqual(episode_columns('card2', False), 2)
        self.assertEqual(episode_columns('card2', True), 1)
        self.assertEqual(episode_columns('grid3', False), 3)
        self.assertEqual(episode_columns('grid3', True), 2)
        self.assertEqual(episode_columns('grid4', False), 4)
        self.assertEqual(episode_columns('grid4', True), 3)

    def test_paging_buttons_disabled_at_boundaries(self):
        self.assertEqual(paging_buttons(0, 90), {'previous_enabled': False, 'next_enabled': True})
        self.assertEqual(paging_buttons(1, 90), {'previous_enabled': True, 'next_enabled': True})
        self.assertEqual(paging_buttons(2, 90), {'previous_enabled': True, 'next_enabled': False})
        self.assertEqual(paging_buttons(0, 5), {'previous_enabled': False, 'next_enabled': False})

    def test_restore_selection_prefers_stable_id_over_index(self):
        old = [{'id': 'L1', 'name': '线路一', 'episodes': [
            {'id': 'E1', 'name': '第1集'}, {'id': 'E2', 'name': '第2集'}]}]
        # 新详情重排：线路/分集顺序变了，仍按 ID 找到同一集。
        new = [{'id': 'L2', 'name': '线路二', 'episodes': [{'id': 'E9', 'name': '第9集'}]},
               {'id': 'L1', 'name': '线路一', 'episodes': [
                   {'id': 'E2', 'name': '第2集'}, {'id': 'E1', 'name': '第1集'}]}]
        self.assertEqual(restore_selection(old, 0, 1, new), (1, 0))
        # ID 找不到时按名字，再找不到按索引夹取。
        renamed = [{'id': 'L1', 'name': '线路一改', 'episodes': [
            {'id': 'E2', 'name': '第2集'}, {'id': 'E1', 'name': '第1集'}]}]
        self.assertEqual(restore_selection(old, 0, 1, renamed), (0, 0))
        gone = [{'id': 'L9', 'name': '线路九', 'episodes': [{'id': 'E9', 'name': '第9集'}]}]
        self.assertEqual(restore_selection(old, 0, 1, gone), (0, 0))
        self.assertEqual(restore_selection([], 0, 0, new), (0, 0))

    def test_global_search_cancel_keeps_results(self):
        rows = [{'state': '搜索中', 'providerStates': {'p1': '搜索中', 'p2': '正在加载更多'}},
                {'state': '已完成', 'providerStates': {'p1': '已完成'}}]
        cancel_search_model(rows)
        self.assertEqual(rows[0]['state'], '已取消')
        self.assertEqual(rows[0]['providerStates']['p1'], '已取消')
        self.assertEqual(rows[0]['providerStates']['p2'], '已取消加载 · 点按重试')
        self.assertEqual(rows[1]['state'], '已完成')


class TestMediaHomeCacheAgeContracts(unittest.TestCase):
    def test_cache_exposes_age_without_mutating(self):
        self.assertIn('ageOfResultForSource', CACHE_H)
        self.assertIn('ageOfResultForSource', CACHE_M)
        age_body = CACHE_M.split('- (NSTimeInterval)ageOfResultForSource', 1)[1].split('\n- (', 1)[0]
        self.assertIn('storedAt', age_body)
        self.assertIn('return -1', age_body)
        # 只读：年龄查询不回填内存缓存、不写持久化记录。
        self.assertNotIn('setObject:entry forKey:key', age_body)
        self.assertNotIn('persistentRecords[key]=', age_body)

    def test_home_and_listing_messages_carry_cache_age(self):
        self.assertIn('MediaBrowserCacheAgeState', BROWSER)
        self.assertIn('MediaBrowserCacheAgeText', BROWSER)
        self.assertIn('5*60', BROWSER)
        self.assertIn('6*3600', BROWSER)
        self.assertIn('正在更新 · 暂用缓存推荐%@', BROWSER)
        self.assertIn('正在校验 · 显示上次推荐%@', BROWSER)
        self.assertIn('正在更新 · 暂用缓存结果%@', BROWSER)
        self.assertIn('正在校验 · 显示上次结果%@', BROWSER)
        self.assertIn('内容接口失败 · 当前仍显示缓存内容%@', BROWSER)
        self.assertIn('保留已加载影片 · 更新失败：%@%@', BROWSER)

    def test_expired_home_cache_gets_a_top_marker_with_retry(self):
        self.assertIn('@"id":@"cache-expired"', BROWSER)
        self.assertIn('推荐内容为过期缓存', BROWSER)
        self.assertIn('@"action":@"retry"', BROWSER)
        marker = BROWSER.split('// T15/M10：首页正展示', 1)[1].split('return [self scopeFeedSections:sections];', 1)[0]
        self.assertIn('MediaBrowserCacheAgeState(homeCacheAge)==2', marker)
        self.assertIn('!self.homeStatusLoading', marker)
        self.assertIn('recommendations.count', marker)
        self.assertIn('atIndex:0', marker)


class TestHomeModulesCleanupContracts(unittest.TestCase):
    def test_only_recommendations_and_catalog_remain(self):
        enabled = BROWSER.split('static NSSet<NSString *> *MediaHomeEnabledModules(void)', 1)[1].split('\n}', 1)[0]
        self.assertIn('@"recommendations"', enabled)
        self.assertIn('@"catalog"', enabled)
        self.assertNotIn('@"continue"', enabled)
        self.assertNotIn('@"favorites"', enabled)
        self.assertNotIn('@"sources"', enabled)

    def test_no_dead_continue_block_and_no_stale_copy(self):
        self.assertNotIn('if(NO&&[enabled containsObject:@"continue"])', BROWSER)
        self.assertNotIn('精选来自当前站点与本机观看记录', BROWSER)
        self.assertIn('精选来自当前站点。隐藏模块不会删除收藏或历史。', BROWSER)

    def test_menu_history_still_reachable(self):
        self.assertIn('[UIAction actionWithTitle:@"观看历史"', BROWSER)


class TestFeaturedSearchDetailRegressionContracts(unittest.TestCase):
    def test_carousel_pauses_for_voiceover_and_reduce_motion(self):
        self.assertIn('UIAccessibilityVoiceOverStatusDidChangeNotification', FEED)
        self.assertIn('UIAccessibilityIsVoiceOverRunning()', FEED)
        self.assertIn('UIAccessibilityIsReduceMotionEnabled()', FEED)
        can_animate = FEED.split('- (BOOL)canAnimate {', 1)[1].split('\n- (', 1)[0]
        self.assertIn('UIAccessibilityIsVoiceOverRunning()', can_animate)
        self.assertIn('return NO', can_animate)

    def test_global_search_cancel_marks_stopped_and_keeps_results(self):
        cancel = GLOBAL_SEARCH.split('- (void)cancelSearch', 1)[1].split('\n- (', 1)[0]
        self.assertIn('@"已取消"', cancel)
        self.assertIn('@"已取消加载 · 点按重试"', cancel)
        self.assertIn('搜索已停止 · 已保留', cancel)
        self.assertIn('@selector(retryFailedSources)', cancel)
        self.assertNotIn('[self.rows removeAllObjects]', cancel)

    def test_detail_refresh_restores_selection_by_stable_id(self):
        restore = BROWSER.split('- (void)restoreSelectionFromDetail:(NSDictionary *)previousDetail {', 1)[1].split('\n- (', 1)[0]
        self.assertIn('lineID', restore)
        self.assertIn('episodeID', restore)
        self.assertIn('lineName', restore)
        self.assertIn('episodeName', restore)
        # 找不到 ID/名字时才按旧索引夹取，不静默选错集。
        self.assertIn('MIN(MAX(0,self.selectedLineIndex)', restore)
        self.assertIn('MIN(MAX(0,self.selectedEpisodeIndex)', restore)

    def test_episode_paging_buttons_and_columns(self):
        self.assertIn('self.previousButton.enabled=self.page>0', EPISODE_PAGE)
        self.assertIn('self.nextButton.enabled=self.page+1<pages', EPISODE_PAGE)
        self.assertIn('CCTVEpisodeColumnsForStyle(epStyle,isAccessibilitySize)', EPISODE_PAGE)
        self.assertIn('scrollRectToVisible', EPISODE_PAGE)
        layout = EPISODE_LAYOUT.split('CCTVEpisodeColumnsForStyle', 1)[1].split('\n}', 1)[0]
        self.assertIn('isAccessibilityCategory ? 1 : 2', layout)
        self.assertIn('isAccessibilityCategory ? 2 : 3', layout)
        self.assertIn('isAccessibilityCategory ? 3 : 4', layout)

    def test_clear_keyword_returns_to_category_first_page(self):
        update = BROWSER.split('- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {', 1)[1].split('\n- (', 1)[0]
        self.assertIn('owner.page=1', update)
        self.assertIn('else if(owner.category.length)[owner loadListing:NO]', update)
        self.assertIn('else if(!owner.homeMode || previousKeyword.length)', update)

    def test_no_progress_pagination_stops(self):
        self.assertIn('本页没有新增影片 · 已停止续页', BROWSER)
        self.assertIn('noProgress=append&&appendedCount==0', BROWSER)


if __name__ == '__main__':
    unittest.main()
