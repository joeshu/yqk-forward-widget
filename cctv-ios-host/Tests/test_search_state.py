"""搜索状态统一（T05：M05/M08/M09/M15）行为测试 + 源码合同。

行为部分用 Python 模型复刻改后的语义并真实执行：
- 统一结果契约 MediaSearchClassifyResult（Valid/Malformed/Failed）与
  MediaSearchMalformedMessage（服务端 error/msg 优先，缺省给默认文案）；
- 全局搜索：格式不完整按来源失败计（不计成功、不记健康成功、不展示为
  "无结果"）；加载更多格式不完整按失败计（可重试）；重复页无进展停止；
- TVBox 归一化：分类/搜索缺 list、首页既无 list 也无 class 时返回可识别
  的错误字典，不再悄悄归一化为空列表；
- 当前源搜索清空关键词回到当前分类第一页（M09），加载中则由完成回调
  的 search_category_or_filter_changed 分支重新发起；
- 当前源分页：整页无新增即停止续页（M15，含恢复续页链路的打断）；
- 首页架子：失败不计连续空架、60 秒退避后滚动重试、连续真空架只停
  自动续链不永久隐藏后续分类（M08）。
模型与源码的对应关系由同文件合同测试锁定。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'

VALID = 'Valid'
MALFORMED = 'Malformed'
FAILED = 'Failed'
MALFORMED_DEFAULT = '来源返回的数据格式不完整'


def classify_result(result, error):
    """复刻 MediaSearchClassifyResult。"""
    if error is not None:
        return FAILED
    if not isinstance(result, dict):
        return MALFORMED
    if not isinstance(result.get('items'), list):
        return MALFORMED
    return VALID


def malformed_message(result):
    """复刻 MediaSearchMalformedMessage。"""
    if isinstance(result, dict):
        for key in ('error', 'errMsg', 'message', 'msg'):
            text = result.get(key)
            if isinstance(text, str) and text:
                return text
    return MALFORMED_DEFAULT


def text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    return ''


# ---------------------------------------------------------------- 全局搜索模型

class GlobalSearchJob:
    """复刻 MediaGlobalSearchViewController 一个来源任务的计分语义。"""

    def __init__(self):
        self.successful = 0
        self.failed_providers = []
        self.results = []
        self.provider_states = {}

    def complete_provider(self, provider_id, name, result, error):
        kind = classify_result(result, error)
        if kind != VALID:
            message = (error or '') if error else malformed_message(result)
            self.failed_providers.append({'id': provider_id, 'name': name,
                                         'error': message})
            self.provider_states[provider_id] = {'name': name,
                                                 'state': '来源失败',
                                                 'error': message}
            return kind
        self.successful += 1
        items = result.get('items') or []
        self.results.extend(items)
        self.provider_states[provider_id] = {
            'name': name,
            'state': '首批结果 · 可加载更多' if items else '无结果',
        }
        return kind

    def finish(self):
        """复刻 finishJob: 的状态与健康判定。job 级 error 由计分导出。"""
        partial = self.successful > 0 and len(self.failed_providers) > 0
        job_error = None if self.successful > 0 else (
            '全部来源失败' if self.failed_providers else None)
        health_success = job_error is None or self.successful > 0
        if job_error:
            state = '搜索失败'
        elif partial:
            state = '部分完成'
        else:
            state = '搜索完成' if self.results else '无结果'
        return {'state': state, 'partial': partial,
                'health_success': health_success, 'job_error': job_error}


class GlobalLoadMore:
    """复刻全局搜索加载更多的完成分支（含已有的无进展停止）。"""

    def __init__(self):
        self.state = '首批结果 · 可加载更多'
        self.results = []
        self.can_load_more = True

    def complete(self, result, error):
        if error is not None or classify_result(result, error) != VALID:
            self.state = '加载更多失败 · 点按重试'
            return 'failed'
        items = result.get('items') or []
        before = len(self.results)
        seen = {item.get('id') or item.get('name') for item in self.results}
        added = 0
        for item in items:
            key = item.get('id') or item.get('name')
            if key not in seen:
                seen.add(key)
                self.results.append(item)
                added += 1
        if added == 0:
            # 模型里 remaining 无上限，等价于源码 !added&&consumed==items.count。
            self.can_load_more = False
            self.state = '没有更多结果'
            return 'stopped'
        self.state = '搜索完成' if not self.can_load_more else self.state
        return 'appended'


# ------------------------------------------------------------- TVBox 归一化模型

def tvbox_normalize(operation, protocol, root):
    """复刻 MediaTVBoxNormalize 的 list 缺失守卫（MacCMS 分支保持原样）。"""
    if not isinstance(root, dict):
        root = {}
    if isinstance(root.get('data'), dict) and not isinstance(root.get('list'), list):
        root = root['data']
    if isinstance(root.get('list'), dict):
        root = dict(root, list=[root['list']])
    if not isinstance(root.get('list'), list) and isinstance(root.get('data'), list):
        root = dict(root, list=root['data'])
    if isinstance(root.get('class'), dict):
        root = dict(root, **{'class': [root['class']]})
    mac_cms = protocol == 'maccms-api'
    if mac_cms and operation in ('home', 'category', 'search', 'detail') \
            and not isinstance(root.get('list'), list) \
            and not isinstance(root.get('class'), list):
        message = next((root[k] for k in ('msg', 'message', 'errMsg')
                        if isinstance(root.get(k), str) and root[k]), '')
        return {'error': message or 'MacCMS JSON 已返回，但没有识别到 list 或 class 数据'}
    # T05 新增：原生 TVBox 同样守卫。
    if not mac_cms and operation in ('category', 'search') \
            and not isinstance(root.get('list'), list):
        return {'error': 'TVBox 接口已返回，但没有识别到 list 数据'}
    if not mac_cms and operation == 'home' \
            and not isinstance(root.get('list'), list) \
            and not isinstance(root.get('class'), list):
        return {'error': 'TVBox 接口已返回，但没有识别到 list 或 class 数据'}
    items = root.get('list') if isinstance(root.get('list'), list) else []
    return {'items': items, 'hasMore': False}


# ------------------------------------------------------------- 当前源搜索防抖模型

class BrowserSearchDebounce:
    """复刻 updateSearchResultsForSearchController 的 350ms 防抖回调。"""

    def __init__(self):
        self.keyword = ''
        self.category = ''
        self.home_mode = True
        self.loading = False
        self.actions = []

    def update(self, keyword, previous_keyword, search_active):
        if not keyword and not previous_keyword and (not search_active or self.home_mode):
            return
        self.keyword = keyword
        # 防抖回调（同步模拟；loading 时直接返回，由完成回调重发）。
        if self.loading:
            return
        self.actions.append(('page', 1))
        if keyword:
            self.actions.append(('loadListing', 'search'))
        elif self.category:
            self.actions.append(('loadListing', 'category'))
        elif not self.home_mode or previous_keyword:
            self.actions.append(('loadHome',))

    def listing_completion_changed(self):
        """复刻完成回调的 search_category_or_filter_changed 分支。"""
        self.actions.append(('page', 1))
        self.actions.append(('loadListing', 'reissue'))


# ------------------------------------------------------------- 当前源分页模型

class BrowserListing:
    """复刻 loadListing 的追加去重 + 无进展停止（含恢复续页打断）。"""

    def __init__(self):
        self.items = []
        self.has_more = False
        self.page = 1
        self.pending_restore_page = 0
        self.message = ''

    @staticmethod
    def identity(item):
        value = item.get('id') or item.get('name')
        return str(value) if value is not None else ''

    def complete(self, append, incoming, has_more):
        identities = {self.identity(item) for item in self.items
                      if self.identity(item)}
        appended = 0
        for item in incoming:
            identity = self.identity(item)
            if not identity or identity not in identities:
                self.items.append(item)
                appended += 1
                if identity:
                    identities.add(identity)
        no_progress = append and appended == 0
        if not no_progress and self.pending_restore_page > self.page \
                and has_more and incoming and self.page < self.pending_restore_page:
            self.page += 1
            return 'restore_advance'
        if self.pending_restore_page:
            self.pending_restore_page = 0
        self.has_more = False if no_progress else has_more
        self.message = '本页没有新增影片 · 已停止续页' if no_progress else (
            '' if self.items else '没有找到影片，请更换关键词或分类')
        return 'stopped' if no_progress else 'applied'


# ------------------------------------------------------------- 首页架子模型

class HomeShelves:
    """复刻 loadHomeShelves 的入口守卫 + 完成分支（M08 改后）。"""

    BACKOFF_SECONDS = 60.0

    def __init__(self, categories):
        self.categories = categories
        self.visible = set(categories)
        self.attempts = set()
        self.failed_at = {}
        self.in_flight = set()
        self.consecutive_empty = 0
        self.now = 1000.0
        self.home_item_count = 0
        self.loaded = []

    def request(self, index):
        identifier = self.categories[index]
        if identifier not in self.visible or identifier in self.attempts:
            return 'skipped'
        failed_at = self.failed_at.get(identifier)
        if failed_at is not None and self.now - failed_at < self.BACKOFF_SECONDS:
            return 'backoff'
        self.attempts.add(identifier)
        self.in_flight.add(identifier)
        return 'requested'

    def complete(self, index, result, error):
        identifier = self.categories[index]
        self.in_flight.discard(identifier)
        failed = False
        count = 0
        if error is None and isinstance(result, dict) \
                and isinstance(result.get('items'), list):
            count = len(result['items'])
        else:
            failed = True
            self.failed_at[identifier] = self.now
            self.attempts.discard(identifier)
        if failed:
            pass
        elif count == 0:
            self.consecutive_empty += 1
        else:
            self.consecutive_empty = 0
            self.loaded.append(identifier)
        if self.home_item_count == 0 and self.consecutive_empty >= 2:
            return 'chain_stopped'
        return 'continue'

    def scroll_load(self):
        """滚动触发的 loadVisibleHomeShelves：从头扫可见分类。"""
        for index in range(len(self.categories)):
            if self.request(index) == 'requested':
                self.loaded.append(self.categories[index])
                return self.categories[index]
        return None


class SearchStateBehaviorTests(unittest.TestCase):
    # M05：统一结果契约
    def test_classifier_distinguishes_valid_empty_error_malformed(self):
        self.assertEqual(classify_result({'items': []}, None), VALID)
        self.assertEqual(classify_result({'items': [{'id': '1'}]}, None), VALID)
        self.assertEqual(classify_result({'items': []}, 'boom'), FAILED)
        self.assertEqual(classify_result(None, None), MALFORMED)
        self.assertEqual(classify_result({'list': []}, None), MALFORMED)
        self.assertEqual(classify_result({'items': 'x'}, None), MALFORMED)
        self.assertEqual(classify_result({'items': None}, None), MALFORMED)

    def test_malformed_message_prefers_server_text(self):
        self.assertEqual(malformed_message({'error': '上游 500'}), '上游 500')
        self.assertEqual(malformed_message({'msg': 'token 失效'}), 'token 失效')
        self.assertEqual(malformed_message({}), MALFORMED_DEFAULT)
        self.assertEqual(malformed_message(None), MALFORMED_DEFAULT)

    # M05：全局搜索首批
    def test_malformed_provider_does_not_count_as_success(self):
        job = GlobalSearchJob()
        job.complete_provider('p1', '源一', {'list': []}, None)
        job.complete_provider('p2', '源二', {'items': 'not-an-array'}, None)
        self.assertEqual(job.successful, 0)
        self.assertEqual(len(job.failed_providers), 2)
        finished = job.finish()
        self.assertFalse(finished['health_success'])
        self.assertEqual(finished['state'], '搜索失败')
        self.assertIsNotNone(finished['job_error'])

    def test_valid_empty_is_a_real_empty_not_a_failure(self):
        job = GlobalSearchJob()
        job.complete_provider('p1', '源一', {'items': []}, None)
        self.assertEqual(job.successful, 1)
        self.assertEqual(job.failed_providers, [])
        finished = job.finish()
        self.assertTrue(finished['health_success'])
        self.assertEqual(finished['state'], '无结果')

    def test_mixed_valid_and_malformed_is_partial(self):
        job = GlobalSearchJob()
        job.complete_provider('p1', '源一', {'items': [{'id': 'a'}]}, None)
        job.complete_provider('p2', '源二', {'items': None}, None)
        finished = job.finish()
        self.assertTrue(finished['partial'])
        self.assertTrue(finished['health_success'])
        self.assertEqual(finished['state'], '部分完成')
        self.assertEqual(job.provider_states['p2']['state'], '来源失败')

    def test_error_and_malformed_both_fail_but_keep_server_message(self):
        job = GlobalSearchJob()
        job.complete_provider('p1', '源一', {'error': 'TVBox 接口已返回，但没有识别到 list 数据'}, None)
        self.assertEqual(job.failed_providers[0]['error'],
                         'TVBox 接口已返回，但没有识别到 list 数据')

    # M05：全局搜索加载更多
    def test_load_more_malformed_is_retryable_failure_not_no_more(self):
        more = GlobalLoadMore()
        more.complete({'items': [{'id': 'a'}]}, None)
        self.assertEqual(more.complete({'items': 'bad'}, None), 'failed')
        self.assertEqual(more.state, '加载更多失败 · 点按重试')
        self.assertTrue(more.can_load_more)

    def test_load_more_duplicate_page_stops(self):
        more = GlobalLoadMore()
        more.complete({'items': [{'id': 'a'}]}, None)
        self.assertEqual(more.complete({'items': [{'id': 'a'}]}, None), 'stopped')
        self.assertFalse(more.can_load_more)
        self.assertEqual(more.state, '没有更多结果')

    # M05：TVBox 归一化守卫
    def test_tvbox_missing_list_is_error_not_empty(self):
        self.assertEqual(tvbox_normalize('category', 'tvbox-api', {})['error'],
                         'TVBox 接口已返回，但没有识别到 list 数据')
        self.assertEqual(tvbox_normalize('search', 'tvbox-api', {'page': 1})['error'],
                         'TVBox 接口已返回，但没有识别到 list 数据')
        self.assertEqual(tvbox_normalize('home', 'tvbox-api', {})['error'],
                         'TVBox 接口已返回，但没有识别到 list 或 class 数据')

    def test_tvbox_home_with_class_only_is_legit(self):
        result = tvbox_normalize('home', 'tvbox-api', {'class': [{'type_id': '1'}]})
        self.assertNotIn('error', result)
        self.assertEqual(result['items'], [])

    def test_tvbox_list_present_still_normal(self):
        result = tvbox_normalize('category', 'tvbox-api', {'list': [{'vod_id': '1'}]})
        self.assertNotIn('error', result)
        self.assertEqual(len(result['items']), 1)

    def test_tvbox_data_envelope_still_unwrapped(self):
        result = tvbox_normalize('category', 'tvbox-api', {'data': {'list': [{'vod_id': '1'}]}})
        self.assertNotIn('error', result)
        self.assertEqual(len(result['items']), 1)

    def test_maccms_guard_unchanged(self):
        result = tvbox_normalize('category', 'maccms-api', {})
        self.assertIn('MacCMS JSON', result['error'])

    # M09：清空关键词回到当前分类
    def test_clear_keyword_with_category_reloads_category_page_one(self):
        browser = BrowserSearchDebounce()
        browser.category = 'movie'
        browser.home_mode = False
        browser.update('', '仙逆', True)
        self.assertEqual(browser.actions, [('page', 1), ('loadListing', 'category')])

    def test_clear_keyword_without_category_reloads_home(self):
        browser = BrowserSearchDebounce()
        browser.home_mode = False
        browser.update('', '仙逆', True)
        self.assertEqual(browser.actions, [('page', 1), ('loadHome',)])

    def test_clear_keyword_while_loading_defers_to_completion(self):
        browser = BrowserSearchDebounce()
        browser.category = 'movie'
        browser.home_mode = False
        browser.loading = True
        browser.update('', '仙逆', True)
        self.assertEqual(browser.actions, [])
        browser.loading = False
        browser.listing_completion_changed()
        self.assertEqual(browser.actions, [('page', 1), ('loadListing', 'reissue')])

    def test_typing_keyword_still_searches(self):
        browser = BrowserSearchDebounce()
        browser.category = 'movie'
        browser.home_mode = False
        browser.update('仙逆', '', True)
        self.assertEqual(browser.actions, [('page', 1), ('loadListing', 'search')])

    # M15：当前源分页无进展停止
    def test_duplicate_page_stops_pagination(self):
        listing = BrowserListing()
        listing.complete(False, [{'id': '1'}, {'id': '2'}], True)
        self.assertTrue(listing.has_more)
        self.assertEqual(listing.complete(True, [{'id': '1'}, {'id': '2'}], True), 'stopped')
        self.assertFalse(listing.has_more)
        self.assertEqual(listing.message, '本页没有新增影片 · 已停止续页')
        self.assertEqual(len(listing.items), 2)

    def test_empty_append_page_stops_too(self):
        listing = BrowserListing()
        listing.complete(False, [{'id': '1'}], True)
        self.assertEqual(listing.complete(True, [], True), 'stopped')
        self.assertFalse(listing.has_more)

    def test_short_page_with_new_items_keeps_going(self):
        listing = BrowserListing()
        listing.complete(False, [{'id': '1'}], True)
        self.assertEqual(listing.complete(True, [{'id': '2'}], True), 'applied')
        self.assertTrue(listing.has_more)
        self.assertEqual(len(listing.items), 2)

    def test_first_page_empty_is_normal_empty_not_no_progress_stop(self):
        listing = BrowserListing()
        self.assertEqual(listing.complete(False, [], False), 'applied')
        self.assertEqual(listing.message, '没有找到影片，请更换关键词或分类')

    def test_no_progress_breaks_restore_chain(self):
        listing = BrowserListing()
        listing.complete(False, [{'id': '1'}], True)
        listing.pending_restore_page = 3
        listing.page = 1
        self.assertEqual(listing.complete(True, [{'id': '1'}], True), 'stopped')
        self.assertEqual(listing.pending_restore_page, 0)

    # M08：架子失败与空的区分
    def test_shelf_failure_does_not_count_as_empty(self):
        shelves = HomeShelves(['c1', 'c2', 'c3'])
        self.assertEqual(shelves.request(0), 'requested')
        self.assertEqual(shelves.complete(0, None, 'boom'), 'continue')
        self.assertEqual(shelves.consecutive_empty, 0)
        self.assertNotIn('c1', shelves.attempts)

    def test_shelf_failure_backs_off_then_retries_on_scroll(self):
        shelves = HomeShelves(['c1', 'c2'])
        shelves.request(0)
        shelves.complete(0, None, 'boom')
        self.assertEqual(shelves.request(0), 'backoff')
        shelves.now += 59.0
        self.assertEqual(shelves.request(0), 'backoff')
        shelves.now += 2.0
        self.assertEqual(shelves.request(0), 'requested')

    def test_two_genuine_empties_stop_chain_but_third_loads_on_scroll(self):
        shelves = HomeShelves(['c1', 'c2', 'c3'])
        shelves.request(0)
        self.assertEqual(shelves.complete(0, {'items': []}, None), 'continue')
        shelves.request(1)
        self.assertEqual(shelves.complete(1, {'items': []}, None), 'chain_stopped')
        self.assertNotIn('c3', shelves.attempts)
        self.assertEqual(shelves.scroll_load(), 'c3')

    def test_failure_then_empty_does_not_trigger_gate(self):
        shelves = HomeShelves(['c1', 'c2', 'c3'])
        shelves.request(0)
        shelves.complete(0, None, 'boom')
        shelves.request(1)
        self.assertEqual(shelves.complete(1, {'items': []}, None), 'continue')
        self.assertEqual(shelves.consecutive_empty, 1)

    def test_nonempty_shelf_resets_consecutive_empty(self):
        shelves = HomeShelves(['c1', 'c2'])
        shelves.request(0)
        shelves.complete(0, {'items': []}, None)
        shelves.request(1)
        shelves.complete(1, {'items': [{'id': 'x'}]}, None)
        self.assertEqual(shelves.consecutive_empty, 0)


class SearchStateContractTests(unittest.TestCase):
    def _read(self, name):
        return (SOURCES / name).read_text(encoding='utf-8')

    # 共享契约落在 MediaSearchResults.h
    def test_shared_result_contract_declared(self):
        text = self._read('MediaSearchResults.h')
        self.assertIn('typedef NS_ENUM(NSInteger, MediaSearchResultKind)', text)
        self.assertIn('MediaSearchResultKindValid', text)
        self.assertIn('MediaSearchResultKindMalformed', text)
        self.assertIn('MediaSearchResultKindFailed', text)
        self.assertIn('MediaSearchClassifyResult', text)
        self.assertIn('MediaSearchMalformedMessage', text)

    # 全局搜索两处完成回调都用统一校验
    def test_global_search_uses_shared_classifier(self):
        text = self._read('MediaGlobalSearchViewController.m')
        self.assertEqual(text.count('MediaSearchClassifyResult(result,error)'), 2)
        self.assertEqual(text.count('MediaSearchMalformedMessage(result)'), 2)
        self.assertIn('MediaSearchClassifyResult(result,error)!=MediaSearchResultKindValid', text)

    # 当前源列表用统一校验，失败保留缓存、区分 failure_stage
    def test_browser_listing_uses_shared_classifier(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('#import "MediaSearchResults.h"', text)
        self.assertIn('MediaSearchResultKind resultKind=MediaSearchClassifyResult(result,error)', text)
        self.assertIn('resultKind!=MediaSearchResultKindValid', text)
        self.assertIn('resultKind==MediaSearchResultKindFailed?@"request_error":@"invalid_result_shape"', text)
        self.assertIn('MediaSearchMalformedMessage(result)', text)

    # M15：无进展停止
    def test_browser_no_progress_stop(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('NSUInteger appendedCount=0;', text)
        self.assertIn('appendedCount++;', text)
        self.assertIn('BOOL noProgress=append&&appendedCount==0;', text)
        self.assertIn('owner.hasMore=noProgress?NO:MediaBrowserBoolean(normalized[@"hasMore"]);', text)
        self.assertIn('@"本页没有新增影片 · 已停止续页"', text)
        self.assertIn('@"appended_count":@(appendedCount)', text)
        self.assertIn('if(!noProgress&&owner.pendingRestorePage>requestedPage', text)

    # M09：清空关键词回到当前分类
    def test_clear_keyword_reloads_current_category(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('else if(owner.category.length)[owner loadListing:NO];', text)

    # M08：架子失败退避与区分
    def test_shelf_failure_backoff_declared(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertIn('homeShelfFailedAt', text)
        self.assertIn('NSMutableDictionary<NSString *,NSNumber *> *homeShelfFailedAt', text)
        self.assertIn('self.homeShelfFailedAt=[NSMutableDictionary dictionary];', text)
        self.assertIn('CACurrentMediaTime()-shelfFailedAt.doubleValue<60.0', text)
        self.assertIn('owner.homeShelfFailedAt[identifier]=@(CACurrentMediaTime());', text)
        self.assertIn('[owner.homeShelfAttempts removeObject:identifier];', text)
        self.assertIn('if(shelfFailed){/* 失败不参与连续空架计数 */}', text)

    def test_shelf_gate_no_longer_marks_remaining_attempted(self):
        text = self._read('MediaBrowserViewController.m')
        self.assertNotIn('for(NSUInteger rem=index+1;rem<limit;rem++)', text)

    # M05：TVBox 归一化守卫
    def test_tvbox_normalizer_guards_missing_list(self):
        text = self._read('MediaAPIClient.m')
        self.assertIn('TVBox 接口已返回，但没有识别到 list 数据', text)
        self.assertIn('TVBox 接口已返回，但没有识别到 list 或 class 数据', text)


if __name__ == '__main__':
    unittest.main()
