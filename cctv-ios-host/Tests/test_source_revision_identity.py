"""来源 revision 统一（T04：M03/M04/M07/V01）行为测试 + 源码合同。

行为部分用 Python 模型复刻改后的身份规则并真实执行：
- 连接指纹 = 13 个连接字段的排序 JSON 的 SHA-256（与 MediaMetadataCache.m
  的 MediaSourceConnectionIdentity 逐字段对应；NSJSONSerialization 输出紧凑
  JSON、UTF-8 不转义，模型用 ensure_ascii=False 复刻）；
- 预解析/播放签名绑定指纹 + provider + 影片 ID + 详情版本 + 索引 + 稳定
  线路/分集 ID + 解析器；
- 分类预览旧回调先验证后改集合；homeResult 复用增加指纹校验。
模型与源码的对应关系由同文件合同测试锁定。
"""
import hashlib
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'

IDENTITY_FIELDS = ('id', 'port', 'protocol', 'packageRoot', 'api', 'header',
                   'headers', 'manifest', 'playUrl', 'options', 'tvboxType',
                   'jar', 'subscriptionURL')


def connection_identity(source):
    """复刻 MediaSourceConnectionIdentity：只取连接字段，显示名不参与。"""
    source = source if isinstance(source, dict) else {}
    port = source.get('port')
    port = str(port) if port is not None else ''
    return {
        'id': source.get('id') if isinstance(source.get('id'), str) else '',
        'port': port,
        'protocol': source.get('protocol') if isinstance(source.get('protocol'), str) else '',
        'packageRoot': source.get('packageRoot') if isinstance(source.get('packageRoot'), str) else '',
        'api': source.get('api') if isinstance(source.get('api'), str) else '',
        'header': source.get('header') if isinstance(source.get('header'), dict) else {},
        'headers': source.get('headers') if isinstance(source.get('headers'), dict) else {},
        'manifest': source.get('manifest') if isinstance(source.get('manifest'), dict) else {},
        'playUrl': source.get('playUrl') if isinstance(source.get('playUrl'), str) else '',
        'options': source.get('options') if source.get('options') is not None else '',
        'tvboxType': source.get('tvboxType') if source.get('tvboxType') is not None else 0,
        'jar': source.get('jar') if isinstance(source.get('jar'), dict) else {},
        'subscriptionURL': source.get('subscriptionURL') if isinstance(source.get('subscriptionURL'), str) else '',
    }


def fingerprint(source):
    if not isinstance(source, dict):
        return ''
    data = json.dumps(connection_identity(source), sort_keys=True,
                      separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def revision(source):
    fp = fingerprint(source)
    return int(fp[:8], 16) if len(fp) >= 8 else 0


def cache_key(source, operation, arguments):
    """复刻 keyForSource：身份 + operation + arguments（去掉 refresh 类键）。"""
    identity = connection_identity(source)
    clean_args = {k: v for k, v in (arguments or {}).items()
                  if k not in ('refresh', 'forceRefresh')}
    identity = dict(identity)
    identity['operation'] = operation or ''
    identity['arguments'] = clean_args
    data = json.dumps(identity, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def needs_client_rebuild(old_source, new_source):
    """M04：连接指纹变了才重建 client；显示名变化不重建。"""
    return fingerprint(old_source) != fingerprint(new_source)


def resolve_signature(fp, provider, item_id, detail_rev, line_index,
                      episode_index, line_id, episode_id, parser_id):
    return '|'.join([fp, provider or '', item_id or '', str(detail_rev),
                     f'{line_index}:{episode_index}', line_id or '',
                     episode_id or '', parser_id or ''])


class PreResolveStore:
    """复刻详情页预解析缓存：命中要求签名一致且 180 秒内。"""

    def __init__(self):
        self.result = None
        self.signature = None
        self.stored_at = None

    def store(self, result, signature, now):
        self.result, self.signature, self.stored_at = result, signature, now

    def hit(self, signature, now):
        return (self.result is not None and self.signature == signature
                and (now - self.stored_at) < 180.0)

    def invalidate(self):
        self.result = self.signature = self.stored_at = None


class ShelfBookkeeping:
    """复刻分类预览任务集合：新行为先验证代际/源/provider 再改集合。"""

    def __init__(self):
        self.in_flight = set()

    def start(self, category_id):
        self.in_flight.add(category_id)

    def complete_old_style(self, category_id, current):
        # 旧行为（M07）：先删集合，再验证——同分类 ID 时删掉新任务的记录。
        self.in_flight.discard(category_id)
        return current

    def complete_new_style(self, category_id, current):
        # 新行为：验证失败直接丢弃，不碰集合。
        if not current:
            return False
        self.in_flight.discard(category_id)
        return True


def read_source(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def extract_block(source, start_marker):
    """从 start_marker 处的 '{' 起按花括号配对抽取代码块。"""
    start = source.index(start_marker)
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
    raise AssertionError('unbalanced braces after ' + start_marker)


BASE_SOURCE = {
    'id': 'svc-1', 'port': 8080, 'protocol': 'pyhost',
    'packageRoot': '/srv/a', 'api': 'https://api.example/x',
    'header': {'X-A': '1'}, 'headers': {}, 'manifest': {'options': {}},
    'playUrl': '', 'options': {'playTimeoutMs': 15000}, 'tvboxType': 0,
    'jar': {}, 'subscriptionURL': '',
}


class SourceRevisionBehavior(unittest.TestCase):
    def test_fingerprint_stable_and_hex(self):
        fp = fingerprint(BASE_SOURCE)
        self.assertEqual(len(fp), 64)
        self.assertEqual(fp, fingerprint(dict(BASE_SOURCE)))
        self.assertEqual(fp, fingerprint(BASE_SOURCE))
        self.assertRegex(fp, r'^[0-9a-f]{64}$')

    def test_display_only_change_keeps_fingerprint(self):
        changed = dict(BASE_SOURCE, name='新显示名', status='已导入')
        self.assertEqual(fingerprint(changed), fingerprint(BASE_SOURCE))
        self.assertFalse(needs_client_rebuild(BASE_SOURCE, changed))

    def test_each_connection_field_change_rebuilds(self):
        changes = {
            'port': 9090, 'protocol': 'tvbox', 'packageRoot': '/srv/b',
            'api': 'https://api.example/y',
            'header': {'X-A': '2'}, 'headers': {'Referer': 'https://r.example/'},
            'manifest': {'options': {'x': 1}}, 'playUrl': 'https://play.example/',
            'options': {'playTimeoutMs': 7000}, 'tvboxType': 1,
            'jar': {'md5': 'abc'}, 'subscriptionURL': 'https://sub.example/s.json',
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                changed = dict(BASE_SOURCE, **{field: value})
                self.assertNotEqual(fingerprint(changed), fingerprint(BASE_SOURCE),
                                    f'{field} 变化应改变指纹')
                self.assertTrue(needs_client_rebuild(BASE_SOURCE, changed))

    def test_same_id_different_port_is_different_config(self):
        # M04 的核心场景：同 ID 来源改端口，旧 client 与旧 homeResult 都不能再用。
        changed = dict(BASE_SOURCE, port=18080)
        self.assertNotEqual(fingerprint(changed), fingerprint(BASE_SOURCE))
        self.assertNotEqual(revision(changed), revision(BASE_SOURCE))

    def test_revision_is_numeric_prefix_of_fingerprint(self):
        self.assertEqual(revision(BASE_SOURCE), int(fingerprint(BASE_SOURCE)[:8], 16))
        self.assertEqual(revision(None), 0)
        self.assertEqual(revision({}), int(fingerprint({})[:8], 16))

    def test_cache_key_uses_same_identity(self):
        # keyForSource = 身份 + operation + arguments；改连接字段换键，
        # 改显示名不换键，refresh 类参数不参与。
        key = cache_key(BASE_SOURCE, 'detail', {'id': 'v1'})
        self.assertEqual(key, cache_key(dict(BASE_SOURCE, name='x'), 'detail', {'id': 'v1'}))
        self.assertEqual(key, cache_key(BASE_SOURCE, 'detail', {'id': 'v1', 'refresh': True}))
        self.assertNotEqual(key, cache_key(dict(BASE_SOURCE, port=9090), 'detail', {'id': 'v1'}))
        self.assertNotEqual(key, cache_key(BASE_SOURCE, 'detail', {'id': 'v2'}))
        self.assertNotEqual(key, cache_key(BASE_SOURCE, 'home', {'id': 'v1'}))

    def test_pre_resolve_hit_requires_full_identity(self):
        fp = fingerprint(BASE_SOURCE)
        sig = resolve_signature(fp, 'p1', 'item-9', 3, 1, 5, 'line-b', 'ep-42', '')
        store = PreResolveStore()
        store.store({'url': 'https://cdn.example/ep42.m3u8'}, sig, now=1000.0)
        self.assertTrue(store.hit(sig, now=1100.0))
        # 详情重载（detailRevision +1）后旧结果命中不了。
        self.assertFalse(store.hit(
            resolve_signature(fp, 'p1', 'item-9', 4, 1, 5, 'line-b', 'ep-42', ''), now=1100.0))
        # 同索引但分集 ID 换了（详情重排）命中不了。
        self.assertFalse(store.hit(
            resolve_signature(fp, 'p1', 'item-9', 3, 1, 5, 'line-b', 'ep-99', ''), now=1100.0))
        # 换线路 / 换解析器 / 换 provider / 换源命中不了。
        self.assertFalse(store.hit(
            resolve_signature(fp, 'p1', 'item-9', 3, 1, 5, 'line-a', 'ep-42', ''), now=1100.0))
        self.assertFalse(store.hit(
            resolve_signature(fp, 'p1', 'item-9', 3, 1, 5, 'line-b', 'ep-42', 'jx1'), now=1100.0))
        self.assertFalse(store.hit(
            resolve_signature(fp, 'p2', 'item-9', 3, 1, 5, 'line-b', 'ep-42', ''), now=1100.0))
        self.assertFalse(store.hit(
            resolve_signature(fingerprint(dict(BASE_SOURCE, port=9090)), 'p1', 'item-9', 3, 1, 5, 'line-b', 'ep-42', ''), now=1100.0))
        # 180 秒窗口过期命中不了。
        self.assertFalse(store.hit(sig, now=1180.0))
        # 作废后命中不了。
        store.invalidate()
        self.assertFalse(store.hit(sig, now=1100.0))

    def test_pre_resolve_falls_back_to_index_when_ids_missing(self):
        # V01：身份缺失时退回索引身份（仍可解析，不静默串到别的集——
        # 详情重载 bump 的 detailRevision 会让旧结果失效）。
        fp = fingerprint(BASE_SOURCE)
        sig = resolve_signature(fp, '', '', 2, 0, 3, '', '', '')
        store = PreResolveStore()
        store.store({'url': 'https://cdn.example/x.m3u8'}, sig, now=1000.0)
        self.assertTrue(store.hit(sig, now=1010.0))
        self.assertFalse(store.hit(
            resolve_signature(fp, '', '', 3, 0, 3, '', '', ''), now=1010.0))

    def test_stale_shelf_callback_must_not_remove_new_task(self):
        # M07：旧源同分类 ID 的迟到回调。新行为下新任务的记录保留。
        bookkeeping = ShelfBookkeeping()
        bookkeeping.start('cat-7')
        # 旧回调（新源/新代际下到达）：验证失败，不碰集合。
        self.assertFalse(bookkeeping.complete_new_style('cat-7', current=False))
        self.assertIn('cat-7', bookkeeping.in_flight)
        # 当前回调：验证通过，才删记录。
        self.assertTrue(bookkeeping.complete_new_style('cat-7', current=True))
        self.assertNotIn('cat-7', bookkeeping.in_flight)
        # 旧行为对照：同样是过期回调，会先删掉新任务的记录。
        bookkeeping.start('cat-7')
        bookkeeping.complete_old_style('cat-7', current=False)
        self.assertNotIn('cat-7', bookkeeping.in_flight)

    def test_home_result_reuse_requires_fingerprint(self):
        # M04：sourceID + provider 相同但指纹不同，旧 homeResult 不复用。
        stored = {'source_id': 'svc-1', 'provider': 'p1',
                  'fingerprint': fingerprint(BASE_SOURCE)}
        current_fp = fingerprint(dict(BASE_SOURCE, port=9090))
        reuse_old = (stored['source_id'] == 'svc-1' and stored['provider'] == 'p1')
        reuse_new = reuse_old and stored['fingerprint'] == current_fp
        self.assertTrue(reuse_old)   # 旧规则会误复用
        self.assertFalse(reuse_new)  # 新规则强制重新请求
        self.assertTrue(stored['fingerprint'] == fingerprint(BASE_SOURCE))


class SourceRevisionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cache_h = read_source('MediaMetadataCache.h')
        cls.cache_m = read_source('MediaMetadataCache.m')
        cls.browser_m = read_source('MediaBrowserViewController.m')

    def test_fingerprint_functions_declared_and_defined(self):
        self.assertIn('MediaSourceConnectionFingerprint', self.cache_h)
        self.assertIn('MediaSourceConnectionRevision', self.cache_h)
        self.assertIn('MediaSourceConnectionIdentity', self.cache_m)
        self.assertIn('MediaSourceConnectionFingerprint(NSDictionary *source)', self.cache_m)
        self.assertIn('MediaSourceConnectionRevision(NSDictionary *source)', self.cache_m)
        for field in IDENTITY_FIELDS:
            self.assertIn(f'@"{field}"', self.cache_m)
        # 显示名字段不得参与指纹。
        helper = extract_block(self.cache_m, 'static NSDictionary *MediaSourceConnectionIdentity')
        self.assertNotIn('@"name"', helper)

    def test_cache_key_reuses_identity_helper(self):
        body = extract_block(self.cache_m, '- (NSString *)keyForSource:')
        self.assertIn('MediaSourceConnectionIdentity(source)', body)
        self.assertIn('identity[@"operation"]=operation', body)
        self.assertIn('identity[@"arguments"]=cleanArgs', body)
        # 旧的内联身份字典不得再出现在 keyForSource 里（单点定义）。
        self.assertNotIn('@"packageRoot"', body)

    def test_refresh_sources_compares_fingerprint(self):
        body = extract_block(self.browser_m, '- (void)refreshSources {')
        self.assertIn('MediaSourceConnectionFingerprint(current)', body)
        self.assertIn('MediaSourceConnectionFingerprint(self.source)', body)
        self.assertNotIn('packageRoot', body)
        self.assertNotIn('current[@"api"]', body)

    def test_detail_reload_rebuilds_client_on_any_connection_change(self):
        body = extract_block(self.browser_m, '- (void)loadDetailRefreshing:(BOOL)forceRefresh {')
        self.assertIn('invalidatePreResolvedResult', body)
        self.assertIn('oldFingerprint=MediaSourceConnectionFingerprint(self.source)', body)
        self.assertIn('![MediaSourceConnectionFingerprint(self.source) isEqualToString:oldFingerprint]', body)
        self.assertNotIn('oldPort', body)

    def test_detail_revision_bumped_on_detail_assignment(self):
        self.assertIn('self.detailRevision++;[self invalidatePreResolvedResult];', self.browser_m)
        self.assertIn('owner.detailRevision++;[owner invalidatePreResolvedResult];', self.browser_m)
        self.assertIn('@property(nonatomic) NSUInteger detailRevision;', self.browser_m)

    def test_resolve_signature_binds_full_identity(self):
        helper = extract_block(
            self.browser_m,
            '- (NSString *)episodeResolveSignatureForLineIndex:(NSInteger)lineIndex episodeIndex:(NSInteger)episodeIndex {')
        self.assertIn('MediaSourceConnectionFingerprint(self.source)', helper)
        self.assertIn('self.detailRevision', helper)
        self.assertIn('[line[@"id"] description]', helper)
        self.assertIn('[episode[@"id"] description]', helper)
        self.assertIn('[self selectedPlaybackParserID]', helper)
        self.assertIn('[self.item[@"id"] description]', helper)
        # 两处调用点都走 helper，不再用旧的纯索引格式。
        self.assertIn('[self episodeResolveSignatureForLineIndex:self.selectedLineIndex episodeIndex:self.selectedEpisodeIndex]',
                      self.browser_m)
        self.assertNotIn('stringWithFormat:@"%ld:%ld:%@"', self.browser_m)

    def test_pre_resolve_invalidated_on_context_change(self):
        for site in ('- (void)selectRoute:(UIButton *)sender {',
                     '- (void)viewDidDisappear:(BOOL)animated {'):
            body = extract_block(self.browser_m, site)
            self.assertIn('invalidatePreResolvedResult', body)
        self.assertIn('[owner invalidatePreResolvedResult];[owner updateParserSelectionButton];',
                      self.browser_m)
        self.assertIn('[self.preResolveClient cancel];', self.browser_m)  # dealloc

    def test_shelf_completion_validates_before_mutating(self):
        completion = extract_block(
            self.browser_m,
            '[shelfClient call:@"category" arguments:arguments correlationID:self.diagnosticTraceID completion:^')
        discard_at = completion.index('media_home_shelf_response_discarded')
        remove_at = completion.index('[owner.homeCategoryLoadsInFlight removeObject:identifier];')
        self.assertLess(discard_at, remove_at)
        self.assertNotIn('if(!owner)return;[owner.homeCategoryLoadsInFlight removeObject:identifier];',
                         completion)

    def test_home_result_reuse_checks_fingerprint(self):
        self.assertIn('@property(nonatomic,copy) NSString *homeResultSourceFingerprint;', self.browser_m)
        getter = extract_block(self.browser_m, '- (NSDictionary *)cachedHomeResultForSelectedProvider:')
        self.assertIn('[self.homeResultSourceFingerprint isEqualToString:MediaSourceConnectionFingerprint(self.source)]',
                      getter)
        apply = extract_block(self.browser_m, '- (void)applyHomeResult:(NSDictionary *)result {')
        self.assertIn('self.homeResultSourceFingerprint=MediaSourceConnectionFingerprint(self.source);',
                      apply)
        clear = extract_block(self.browser_m, '- (void)clearHomeResult {')
        self.assertIn('self.homeResultSourceFingerprint=nil;', clear)

    def test_real_revision_wired_into_diagnostics_and_context(self):
        self.assertIn('@"source_revision":@(MediaSourceConnectionRevision(self.source))',
                      self.browser_m)
        self.assertIn('@"source_revision":@(MediaSourceConnectionRevision(owner.source))',
                      self.browser_m)
        self.assertIn('@"sourceRevision":@(MediaSourceConnectionRevision(self.source))',
                      self.browser_m)
        self.assertIn('@"sourceRevision":@(MediaSourceConnectionRevision(owner.source))',
                      self.browser_m)


if __name__ == '__main__':
    unittest.main()
