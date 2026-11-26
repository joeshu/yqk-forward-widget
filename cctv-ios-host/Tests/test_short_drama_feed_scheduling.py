"""短剧竖屏流调度（T03：M01/M02/S6）行为测试 + 源码合同。

行为部分用 Python 模型忠实复刻 ShortDramaVerticalFeedController.m 改后的
槽位状态机与解析调度（状态、取消令牌、退场守卫、centre-first 发起顺序、
独立 client、请求头合并、网页解析结果让路标准播放器），真实执行场景断言。
模型与源码的对应关系由同文件的合同测试锁定：模型里每条转移在 ObjC 源码里
都有同名/同义的实现，改源码不改模型时合同测试先失败。

旧 bug 对照（M01）：三槽共用详情页的 owner.client，而 MediaAPIClient.call
会在每次新调用时取消本 client 上一次调用——邻集解析会取消当前集解析。
test_shared_client_control 用同一模型跑旧接法，证明只有最后一次解析能完成。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'

IDLE, RESOLVING, READY, FAILED, CANCELLED = 'idle', 'resolving', 'ready', 'failed', 'cancelled'

# MediaPlaybackHeadersFromResult 的屏蔽名（MediaPlaybackHeaders.m）。
BLOCKED_HEADER_NAMES = {'host', 'content-length', 'connection',
                        'transfer-encoding', 'keep-alive', 'upgrade'}


def merge_headers(result):
    """复刻 MediaPlaybackHeadersFromResult：ext.headers → ext.header →
    headers → header → customHeaders，后出现的同名覆盖先出现的（大小写不敏感），
    屏蔽名丢弃。只覆盖字典形态的源（字符串形态由 AddHeaderValue 另行处理）。"""
    merged = {}

    def add(value):
        if not isinstance(value, dict):
            return
        for name, text in value.items():
            if not isinstance(name, str) or not isinstance(text, str):
                continue
            if name.lower() in BLOCKED_HEADER_NAMES:
                continue
            for old in list(merged):
                if old.lower() == name.lower():
                    del merged[old]
            merged[name] = text

    if isinstance(result, dict):
        ext = result.get('ext')
        if isinstance(ext, dict):
            add(ext.get('headers'))
            add(ext.get('header'))
        add(result.get('headers'))
        add(result.get('header'))
        add(result.get('customHeaders'))
    return merged


def feed_playable(result):
    """复刻详情页 resolver 的让路规则：明确 requiresWebPlayback 且不可原生播的，
    feed 不喂给 AVPlayer，回调 nil 让槽位失败、用户退回详情页走标准播放器；
    没有该标记的插件结果默认按直链放行。"""
    if not isinstance(result, dict):
        return False
    if (isinstance(result.get('requiresWebPlayback'), bool)
            and result['requiresWebPlayback']
            and not result.get('nativePlayable')):
        return False
    return True


class FakeAPIClient:
    """复刻 MediaAPIClient.call 的取消语义：同一 client 上新调用取消上一次调用
   （cancelWithReason:@"superseded_by_new_request"），被取消的 completion 不再落地。"""

    def __init__(self):
        self.calls = []
        self.active = None

    def call(self, args, completion):
        if self.active is not None:
            self.active['cancelled'] = True
            self.active = None
        entry = {'args': args, 'cancelled': False, 'completed': False}
        self.calls.append(entry)
        self.active = entry

        def deliver(result):
            if entry['cancelled'] or entry['completed']:
                return False
            entry['completed'] = True
            completion(*result)
            return True

        entry['deliver'] = deliver
        return entry

    def cancel(self):
        if self.active is not None:
            self.active['cancelled'] = True
            self.active = None


class Slot:
    def __init__(self, index):
        self.index = index
        self.state = IDLE
        self.cancel = None
        self.item_url = None
        self.played = False
        self.spinner = False
        self.buffer_seconds = None


class FeedModel:
    """复刻改后的 ShortDramaVerticalFeedController 调度（不含 UIKit/AVPlayer 本体）。
    解析是异步的：resolver 只登记 pending completion，由测试显式 deliver，
    以复现滑动、逐出、退场与回调到达之间的时序。"""

    def __init__(self, episode_count, resolver):
        self.episode_count = episode_count
        self.resolver = resolver  # (index, completion) -> cancel callable | None
        self.pool = {}
        self.active_index = 0
        self.feed_active = True
        self.issue_order = []
        self.session_acquired = False
        self.session_released = False

    def appear(self):
        self.session_acquired = True

    def update_pool(self, center):
        self.active_index = center
        keep = {center - 1, center, center + 1}
        for key in list(self.pool):
            if key not in keep:
                evicted = self.pool.pop(key)
                if evicted.cancel is not None:
                    evicted.cancel()
                    evicted.cancel = None
                evicted.state = CANCELLED
                evicted.played = False
            elif key != center:
                self.pool[key].played = False
        self.prepare(center, True)
        if center + 1 < self.episode_count:
            self.prepare(center + 1, False)
        if center - 1 >= 0:
            self.prepare(center - 1, False)

    def prepare(self, index, auto_play):
        if index < 0 or index >= self.episode_count:
            return
        slot = self.pool.get(index)
        if slot is not None:
            if slot.state == READY:
                if auto_play:
                    slot.played = True
                slot.spinner = False
            elif slot.state == RESOLVING:
                # 解析中重遇：不播、不停 spinner，等回调。
                slot.spinner = True
            elif slot.state in (FAILED, CANCELLED):
                if auto_play:
                    self.start_resolve(slot, index)
                    slot.spinner = True
                else:
                    slot.spinner = False
            elif slot.state == IDLE:
                if auto_play:
                    self.start_resolve(slot, index)
                    slot.spinner = True
            return
        slot = Slot(index)
        slot.state = RESOLVING
        slot.spinner = True
        self.pool[index] = slot
        self.start_resolve(slot, index)

    def start_resolve(self, slot, index):
        slot.state = RESOLVING
        slot.cancel = None
        self.issue_order.append(index)

        def apply_url(url, headers):
            # 复刻 dispatch 到主队列后的 applyURL 回调。
            if not self.feed_active:
                return
            if self.pool.get(index) is not slot:
                return
            if slot.state != RESOLVING:
                return
            slot.cancel = None
            if not url:
                slot.state = FAILED
                slot.spinner = False
                return
            slot.item_url = url
            slot.buffer_seconds = 10.0 if index == self.active_index else 4.0
            slot.state = READY
            slot.spinner = False
            if index == self.active_index:
                slot.played = True

        slot.cancel = self.resolver(index, apply_url)

    def close(self):
        self.feed_active = False
        for slot in self.pool.values():
            if slot.cancel is not None:
                slot.cancel()
                slot.cancel = None
            slot.state = CANCELLED
            slot.played = False
        self.session_released = True

    def session_step(self, direction):
        if not self.feed_active or direction == 0:
            return False
        target = self.active_index + (1 if direction > 0 else -1)
        if target < 0 or target >= self.episode_count:
            return False
        self.update_pool(target)
        return True


def make_independent_resolver(pending):
    """新接法：每次解析一个独立 FakeAPIClient——三槽解析互不取消。"""

    def resolver(index, completion):
        client = FakeAPIClient()
        entry = client.call({'index': index}, completion)
        pending[index] = (client, entry)
        return client.cancel

    return resolver


def make_shared_resolver(pending):
    """旧接法对照：三槽共用一个 client——新调用取消上一次。"""
    shared = FakeAPIClient()

    def resolver(index, completion):
        entry = shared.call({'index': index}, completion)
        pending[index] = (shared, entry)
        return shared.cancel

    return resolver


def read_source(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def extract_method(source, signature):
    """按花括号配对抽取一个 ObjC 方法体（含签名行）。"""
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for pos in range(brace, len(source)):
        ch = source[pos]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return source[start:pos + 1]
    raise AssertionError('unbalanced braces in ' + signature)


class ShortDramaSchedulingBehavior(unittest.TestCase):
    def setUp(self):
        self.pending = {}

    def deliver(self, index, url):
        client, entry = self.pending[index]
        return entry['deliver']((url, {}))

    def test_three_concurrent_resolves_all_complete(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.appear()
        feed.update_pool(2)
        self.assertEqual(feed.issue_order, [2, 3, 1])
        self.assertEqual({i: s.state for i, s in feed.pool.items()},
                         {2: RESOLVING, 3: RESOLVING, 1: RESOLVING})
        self.assertTrue(self.deliver(2, 'https://cdn.example/ep2.m3u8'))
        self.assertTrue(self.deliver(3, 'https://cdn.example/ep3.m3u8'))
        self.assertTrue(self.deliver(1, 'https://cdn.example/ep1.m3u8'))
        self.assertEqual({i: s.state for i, s in feed.pool.items()},
                         {2: READY, 3: READY, 1: READY})
        self.assertTrue(feed.pool[2].played)
        self.assertFalse(feed.pool[3].played)
        self.assertFalse(feed.pool[1].played)

    def test_shared_client_control_only_last_resolve_survives(self):
        # 旧接法的对照：共用 client 时邻集解析取消当前集，只有最后一次能完成。
        feed = FeedModel(5, make_shared_resolver(self.pending))
        feed.update_pool(2)
        self.assertFalse(self.deliver(2, 'https://cdn.example/ep2.m3u8'))
        self.assertFalse(self.deliver(3, 'https://cdn.example/ep3.m3u8'))
        self.assertTrue(self.deliver(1, 'https://cdn.example/ep1.m3u8'))
        self.assertEqual(feed.pool[2].state, RESOLVING)
        self.assertEqual(feed.pool[1].state, READY)

    def test_reenter_resolving_slot_keeps_spinner_and_does_not_play(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.update_pool(2)
        slot = feed.pool[2]
        self.assertEqual(slot.state, RESOLVING)
        feed.prepare(2, True)  # 滑回同一集：解析中重遇
        self.assertEqual(slot.state, RESOLVING)
        self.assertTrue(slot.spinner)
        self.assertFalse(slot.played)
        self.assertEqual(len(self.pending[2][0].calls), 1)  # 没有重发解析
        self.assertTrue(self.deliver(2, 'https://cdn.example/ep2.m3u8'))
        self.assertEqual(slot.state, READY)
        self.assertTrue(slot.played)

    def test_failed_slot_retries_only_when_current(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.update_pool(2)
        self.assertTrue(self.deliver(3, None))  # 邻集解析失败
        self.assertEqual(feed.pool[3].state, FAILED)
        self.assertFalse(feed.pool[3].spinner)
        feed.prepare(3, False)  # 邻集重遇不重试
        self.assertEqual(len(self.pending[3][0].calls), 1)
        feed.update_pool(3)  # 滑到该集成为当前集：重试
        self.assertEqual(feed.pool[3].state, RESOLVING)
        self.assertTrue(feed.pool[3].spinner)
        self.assertTrue(self.deliver(3, 'https://cdn.example/ep3.m3u8'))
        self.assertEqual(feed.pool[3].state, READY)
        self.assertTrue(feed.pool[3].played)

    def test_evict_cancels_pending_resolve_and_late_callback_dropped(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.update_pool(1)
        slot = feed.pool[2]
        self.assertEqual(slot.state, RESOLVING)
        feed.update_pool(4)  # 集 2 被逐出滑窗
        self.assertNotIn(2, feed.pool)
        self.assertEqual(slot.state, CANCELLED)
        self.assertFalse(self.deliver(2, 'https://cdn.example/ep2.m3u8'))
        self.assertIsNone(slot.item_url)
        self.assertFalse(slot.played)

    def test_close_cancels_all_and_late_callback_never_plays(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.appear()
        feed.update_pool(2)
        feed.close()
        self.assertTrue(feed.session_released)
        self.assertFalse(feed.feed_active)
        for slot in feed.pool.values():
            self.assertEqual(slot.state, CANCELLED)
            self.assertFalse(slot.played)
        # 退场后到达的三个回调一律丢弃。
        for index in (2, 3, 1):
            self.assertFalse(self.deliver(index, f'https://cdn.example/ep{index}.m3u8'))
        for slot in feed.pool.values():
            self.assertIsNone(slot.item_url)
            self.assertFalse(slot.played)

    def test_center_first_issue_order_and_neighbor_buffer_cap(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.update_pool(0)
        self.assertEqual(feed.issue_order, [0, 1])
        self.assertTrue(self.deliver(0, 'https://cdn.example/ep0.m3u8'))
        self.assertTrue(self.deliver(1, 'https://cdn.example/ep1.m3u8'))
        self.assertEqual(feed.pool[0].buffer_seconds, 10.0)
        self.assertEqual(feed.pool[1].buffer_seconds, 4.0)

    def test_session_step_moves_one_episode(self):
        feed = FeedModel(5, make_independent_resolver(self.pending))
        feed.update_pool(2)
        self.assertTrue(feed.session_step(1))
        self.assertEqual(feed.active_index, 3)
        self.assertTrue(feed.session_step(-1))
        self.assertEqual(feed.active_index, 2)
        feed.update_pool(4)
        self.assertFalse(feed.session_step(1))
        feed.update_pool(0)
        self.assertFalse(feed.session_step(-1))
        feed.close()
        self.assertFalse(feed.session_step(1))

    def test_web_only_result_defers_to_standard_player(self):
        web_only = {'url': 'https://jx.example/parse?id=1', 'parse': 1,
                    'requiresWebPlayback': True, 'nativePlayable': False}
        self.assertFalse(feed_playable(web_only))
        native = {'url': 'https://cdn.example/ep.m3u8', 'parse': 1,
                  'requiresWebPlayback': False, 'nativePlayable': True}
        self.assertTrue(feed_playable(native))
        plugin = {'url': 'https://cdn.example/ep.m3u8'}  # 无标记的插件结果默认放行
        self.assertTrue(feed_playable(plugin))
        self.assertFalse(feed_playable(None))

    def test_headers_merge_keeps_plural_headers(self):
        result = {
            'headers': {'Referer': 'https://site.example/', 'User-Agent': 'okhttp/4.12.0'},
            'header': {'X-Custom': '1'},
            'customHeaders': {'Authorization': 'Bearer x'},
        }
        merged = merge_headers(result)
        self.assertEqual(merged['Referer'], 'https://site.example/')
        self.assertEqual(merged['User-Agent'], 'okhttp/4.12.0')
        self.assertEqual(merged['X-Custom'], '1')
        self.assertEqual(merged['Authorization'], 'Bearer x')
        # 单数 header 覆盖复数 headers 的同名项；屏蔽名丢弃。
        merged = merge_headers({'headers': {'Referer': 'https://old.example/'},
                                'header': {'referer': 'https://new.example/',
                                           'Host': 'evil.example'}})
        self.assertEqual(merged['referer'], 'https://new.example/')
        self.assertNotIn('Host', merged)
        self.assertNotIn('host', merged)


class ShortDramaSchedulingContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feed_h = read_source('ShortDramaVerticalFeedController.h')
        cls.feed_m = read_source('ShortDramaVerticalFeedController.m')
        cls.browser_m = read_source('MediaBrowserViewController.m')

    def test_resolver_returns_cancel_token(self):
        self.assertIn('ShortDramaResolveCancel', self.feed_h)
        self.assertIn('ShortDramaEpisodeResolver', self.feed_h)
        self.assertIn('episodeResolver:(nullable ShortDramaEpisodeResolver)resolver', self.feed_h)
        self.assertIn('每次调用必须使用独立的解析任务', self.feed_h)

    def test_slot_state_machine_replaces_resolving_bool(self):
        for state in ('ShortDramaSlotStateIdle', 'ShortDramaSlotStateResolving',
                      'ShortDramaSlotStateReady', 'ShortDramaSlotStateFailed',
                      'ShortDramaSlotStateCancelled'):
            self.assertIn(state, self.feed_m)
        self.assertIn('ShortDramaSlotState state;', self.feed_m)
        self.assertIn('resolveCancel', self.feed_m)
        self.assertNotIn('slot.resolving', self.feed_m)
        self.assertNotIn('resolving = YES', self.feed_m)
        self.assertNotIn('resolving = NO', self.feed_m)

    def test_failed_slot_retries_on_reenter_as_current(self):
        self.assertIn('case ShortDramaSlotStateFailed:', self.feed_m)
        self.assertIn('case ShortDramaSlotStateCancelled:', self.feed_m)
        self.assertIn('startResolveForSlot', self.feed_m)

    def test_apply_url_drops_late_callbacks(self):
        self.assertIn('if (!owner || !owner.feedActive) return;', self.feed_m)
        self.assertIn('slot.state != ShortDramaSlotStateResolving', self.feed_m)
        self.assertIn('slot.state = ShortDramaSlotStateFailed;', self.feed_m)

    def test_eviction_and_close_cancel_pending_resolves(self):
        self.assertIn('evicted.resolveCancel(); evicted.resolveCancel = nil;', self.feed_m)
        self.assertIn('slot.resolveCancel(); slot.resolveCancel = nil;', self.feed_m)
        self.assertIn('self.feedActive = NO;', self.feed_m)

    def test_feed_owns_playback_session(self):
        for method in ('sessionHasContent', 'sessionIsPlaying', 'sessionPlay',
                       'sessionPause', 'sessionStep:(NSInteger)direction',
                       'sessionWantsPlayback', 'sessionMediaServicesReset'):
            self.assertIn(method, self.feed_m)
        self.assertIn('PlaybackSession>', self.feed_m)
        self.assertIn('[[PlaybackCoordinator shared] acquireSession:(id<PlaybackSession>)self];',
                      self.feed_m)
        self.assertIn('[[PlaybackCoordinator shared] releaseSession:(id<PlaybackSession>)self];',
                      self.feed_m)
        self.assertIn('if (!self.feedActive) return;', self.feed_m)  # handlePlaybackEnded 守卫

    def test_neighbor_buffer_cap_kept(self):
        self.assertIn('preferredForwardBufferDuration = (index == owner.activeIndex) ? 10.0 : 4.0;',
                      self.feed_m)

    def test_detail_uses_independent_client_per_resolve(self):
        self.assertIn('newShortDramaResolveClient', self.browser_m)
        self.assertIn('MediaAPIClient *resolveClient=[owner newShortDramaResolveClient];',
                      self.browser_m)
        self.assertIn('return ^{ [resolveClient cancel]; };', self.browser_m)
        body = extract_method(self.browser_m, '- (void)openShortDramaVerticalFeed {')
        self.assertNotIn('[owner.client call:', body)
        self.assertNotIn('result[@"header"]', body)

    def test_detail_uses_standard_header_merge(self):
        self.assertIn('#import "MediaPlaybackHeaders.h"', self.browser_m)
        self.assertIn('MediaPlaybackHeadersFromResult(dict)', self.browser_m)
        body = extract_method(self.browser_m, '- (void)openShortDramaVerticalFeed {')
        self.assertIn('requiresWebPlayback', body)
        self.assertIn('nativePlayable', body)


if __name__ == '__main__':
    unittest.main()
