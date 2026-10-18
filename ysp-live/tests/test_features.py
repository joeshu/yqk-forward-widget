"""Operations, routing, and XMLTV regressions; no public network access."""
from __future__ import annotations
import concurrent.futures
import gzip
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_feature_application', ROOT / 'ysp-live-v9.5.12.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def playlist(sequence=1):
    return f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n#EXTINF:6,\nhttps://media.cctv.cn/{sequence}.ts\n'


def xmltv(title='测试节目', channel='external-id', offset='+0800'):
    now = int(time.time())
    start, stop = now - 3600, now - 1800
    tz = live.datetime.timezone(live.datetime.timedelta(hours=8))
    def stamp(value):
        return live.datetime.datetime.fromtimestamp(value, tz).strftime('%Y%m%d%H%M%S') + ' ' + offset
    return (f'<tv><channel id="{channel}"><display-name>CCTV1</display-name></channel>'
            f'<programme channel="{channel}" start="{stamp(start)}" stop="{stamp(stop)}">'
            f'<title>{title}</title><desc>描述</desc></programme></tv>').encode(), start, stop


class SourceSelectionTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.selector = live.SourceSelector(clock=lambda: self.now)

    def test_failure_backoff_does_not_retry_every_request(self):
        self.selector.failure('device', 'HTTP 503')
        self.assertEqual(self.selector.order(['device', 'backup']), ['backup'])
        self.now += 5
        self.assertEqual(self.selector.order(['device', 'backup']), ['device', 'backup'])
        self.selector.failure('device', 'HTTP 503')
        self.assertEqual(self.selector.snapshot()['sources']['device']['retry_in'], 10)
        self.assertEqual(self.selector.order(['device']), [])

    def test_recovery_requires_two_advancing_samples_and_minimum_hold(self):
        self.selector.commit('backup')
        self.selector.success('device', playlist(1), .1, probe=True)
        self.selector.success('device', playlist(1), .1, probe=True)
        self.now += 31
        self.assertEqual(self.selector.order(['device', 'backup'])[0], 'backup')
        self.selector.success('device', playlist(2), .1, probe=True)
        self.assertEqual(self.selector.order(['device', 'backup'])[0], 'device')

    def test_master_success_does_not_prove_media_recovery(self):
        self.selector.commit('backup')
        for _ in range(3):
            self.selector.success('device', '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=123\na.m3u8\n', .1, probe=True)
        self.now += 60
        self.assertEqual(self.selector.order(['device', 'backup'])[0], 'backup')

    def test_frozen_candidate_is_rejected_and_cannot_be_promoted(self):
        self.selector.success('device', playlist(), .1)
        self.now += 31
        with self.assertRaises(live.FrozenPlaylistError):
            self.selector.success('device', playlist(), .1, probe=True)
        self.selector.failure('device', 'frozen')
        self.assertEqual(self.selector.snapshot()['sources']['device']['recovery_samples'], 0)

    def test_probe_reservation_coalesces_and_obeys_interval(self):
        self.selector.commit('backup')
        self.now += 31
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            results = list(pool.map(lambda _: self.selector.reserve_probe(['device', 'backup']), range(8)))
        self.assertEqual(results.count('device'), 1)
        self.selector.states['device']['probing'] = False
        self.assertIsNone(self.selector.reserve_probe(['device', 'backup']))
        self.now += 30
        self.assertEqual(self.selector.reserve_probe(['device', 'backup']), 'device')

    def test_rotating_proxy_tokens_do_not_count_as_media_advancement(self):
        one = live.register_resource('https://media.cctv.cn/segment.ts?sig=first')
        two = live.register_resource('https://media.cctv.cn/segment.ts?sig=second')
        first = playlist().replace('https://media.cctv.cn/1.ts', '/proxy?resource=' + one)
        second = playlist().replace('https://media.cctv.cn/1.ts', '/proxy?resource=' + two)
        self.assertEqual(live.media_signature(first), live.media_signature(second))
        self.selector.success('device', first, .1)
        self.now += 31
        with self.assertRaises(live.FrozenPlaylistError):
            self.selector.success('device', second, .1)


class EPGTests(unittest.TestCase):
    def cache(self, **kwargs):
        cache = live.EPGCache(**kwargs)
        self.addCleanup(cache.close)
        return cache

    def wait(self, cache):
        deadline = time.monotonic() + 3
        while cache.stats()['loading']:
            if time.monotonic() >= deadline:
                self.fail('EPG refresh did not finish')
            time.sleep(.01)

    def test_gzip_alias_matching_timezone_and_xml_escaping(self):
        cache = self.cache()
        xml, start, stop = xmltv('新闻 &amp; &lt;节目&gt;')
        rows = cache.parse(gzip.compress(xml))
        self.assertEqual((rows[0]['channel'], rows[0]['start'], rows[0]['stop']), ('cctv1', start, stop))
        self.assertEqual(rows[0]['title'], '新闻 & <节目>')
        cache.programmes = rows
        encoded = cache.xml()
        tree = ET.fromstring(encoded)
        self.assertEqual(tree.find('programme/title').text, '新闻 & <节目>')
        self.assertIs(cache.xml(), encoded)
        self.assertEqual(tree.find('programme').get('channel'), live.TVG_IDS['cctv1'])

    def test_real_gzip_epg_redirect_uses_urllib_without_custom_dns_policy(self):
        payload = gzip.compress(xmltv()[0])
        agents = []
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                agents.append(self.headers.get('User-Agent'))
                if self.path == '/epg':
                    self.send_response(302)
                    self.send_header('Location', '/feed.xml.gz')
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        cache = self.cache(urls=[f'http://127.0.0.1:{server.server_port}/epg'])
        try:
            with mock.patch.dict(live.os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}), \
                 mock.patch.object(live.URLPolicy, 'resolve', side_effect=AssertionError('unexpected DNS policy')):
                cache.request_refresh()
                self.wait(cache)
            self.assertEqual(len(cache.read('cctv1')), 1)
            self.assertEqual(agents, ['ysp-live/EPG', 'ysp-live/EPG'])
            self.assertEqual(ET.fromstring(cache.xml()).find('programme').get('channel'), 'CCTV1')
        finally:
            server.shutdown()
            server.server_close()
            worker.join(2)

    def test_rejects_entities_utf16_and_unmatched_feeds(self):
        cache = self.cache()
        for payload in (b'<!DOCTYPE tv [<!ENTITY a "x">]><tv/>',
                        '<tv/>'.encode('utf-16'), b'<tv><channel id="none"/></tv>'):
            with self.assertRaises(ValueError):
                cache.parse(payload)

    def test_decompression_and_item_budgets_are_enforced(self):
        cache = self.cache()
        cache.max_xml = 128
        with self.assertRaises(ValueError):
            cache.parse(gzip.compress(b' ' * 129))
        cache.max_xml, cache.max_items = 2**20, 0
        with self.assertRaises(OverflowError):
            cache.parse(xmltv()[0])

    def test_concurrent_requests_share_one_refresh_and_persist_cache(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def fetch(url):
            calls.append(url)
            entered.set()
            release.wait(2)
            return xmltv()[0]
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / 'epg.json')
            cache = self.cache(urls=['https://example.test/epg'], path=path, fetcher=fetch)
            self.addCleanup(release.set)
            with concurrent.futures.ThreadPoolExecutor(10) as pool:
                list(pool.map(lambda _: cache.request_refresh(), range(10)))
            self.assertTrue(entered.wait(1))
            release.set()
            self.wait(cache)
            self.assertEqual(len(calls), 1)
            restored = self.cache(urls=cache.urls, path=path)
            self.assertEqual(len(restored.read('cctv1')), 1)

    def test_failed_refresh_preserves_old_cache_and_redacts_error(self):
        cache = self.cache(urls=['https://example.test/epg?token=supersecret'],
            fetcher=lambda url: (_ for _ in ()).throw(OSError(url)))
        cache.programmes = cache.parse(xmltv()[0])
        cache.updated = time.time() - 7200
        cache.request_refresh()
        self.wait(cache)
        self.assertEqual(len(cache.read('cctv1')), 1)
        self.assertTrue(cache.stats()['stale'])
        self.assertNotIn('supersecret', cache.stats()['error'])
        retry = cache.retry_at
        cache.request_refresh()
        self.assertEqual(cache.retry_at, retry)

    def test_disk_failure_keeps_valid_memory_cache_after_multi_source_refresh(self):
        fetch = mock.Mock(return_value=xmltv()[0])
        cache = self.cache(urls=['first', 'second'], path='/unused/epg.json', fetcher=fetch)
        with mock.patch.object(live, 'atomic_json_write', side_effect=OSError('disk full')):
            cache.request_refresh()
            self.wait(cache)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(len(cache.read('cctv1')), 1)
        self.assertIn('persistence', cache.stats()['warning'])

    def test_source_fallback_and_close_block_new_downloads(self):
        calls = []
        def fetch(url):
            calls.append(url)
            if url == 'bad':
                raise OSError('offline')
            return xmltv()[0]
        cache = self.cache(urls=['bad', 'good'], fetcher=fetch)
        cache.request_refresh()
        self.wait(cache)
        self.assertEqual(calls, ['bad', 'good'])
        self.assertEqual(len(cache.read('cctv1')), 1)
        cache.close()
        cache.updated = 0
        cache.request_refresh()
        self.assertFalse(cache.loading)


class FeatureHTTPTests(unittest.TestCase):
    def setUp(self):
        self.ch = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'fhd')
        self.stack = live.contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': self.ch}))
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', None))
        self.server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
        self.server.access_token = ''
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def request(self, path, method='GET', headers=None):
        with live.contextlib.closing(http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)) as connection:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()

    def test_status_shell_is_public_but_channel_data_requires_token(self):
        self.server.access_token = 'test-token'
        status, headers, body = self.request('/status')
        self.assertEqual(status, 200)
        self.assertIn(b'nonce=', body)
        self.assertNotIn(b'__NONCE__', body)
        self.assertIn('nonce-', headers['Content-Security-Policy'])
        self.assertNotIn(b'test-token', body)
        self.assertEqual(self.request('/api/channels')[0], 401)
        with mock.patch.object(live, 'fetch_upstream_engine_playlist', side_effect=AssertionError('passive status must not fetch')):
            status, _, body = self.request('/api/channels', headers={'Authorization': 'Bearer test-token'})
        self.assertEqual(status, 200)
        row = next(c for c in json.loads(body)['channels'] if c['slug'] == 'cctv1')
        self.assertEqual(row['state'], 'unobserved')

    def test_diagnostics_hide_url_tokens_and_device_identifiers(self):
        secret = 'sensitive-access-value'
        self.server.access_token = secret
        self.ch.last_error = 'https://x.test/path-secret?token=url-secret uid=device-secret cookie=cookie-secret '
        with live._log_lock:
            live.global_log_ring.append('authorization=Bearer bearer-secret access_token=' + secret)
        status, _, body = self.request('/api/diagnostics', headers={'Authorization': 'Bearer ' + secret})
        self.assertEqual(status, 200)
        for value in ('path-secret', 'url-secret', 'device-secret', 'cookie-secret', 'bearer-secret', secret):
            self.assertNotIn(value.encode(), body)
        self.assertEqual(self.request('/api/diagnose?channel=cctv1', method='HEAD', headers={'Authorization': 'Bearer ' + secret})[0], 405)

    def test_fallback_remains_sticky_and_head_does_not_change_selection(self):
        bad = mock.Mock(side_effect=OSError('device offline'))
        good = mock.Mock(return_value=(playlist(), 'backup:jce', {}))
        with mock.patch.object(live, 'source_loaders', return_value={'device': bad, 'backup': good}):
            self.assertEqual(self.request('/cctv1.m3u8')[0], 200)
            self.assertEqual(self.request('/cctv1.m3u8')[0], 200)
            self.assertEqual(bad.call_count, 1)
            snapshot = live.channel_selector(self.ch).snapshot()
            self.assertEqual(snapshot['selected'], 'backup')
            self.assertEqual(self.request('/cctv1.m3u8', method='HEAD')[0], 200)
            self.assertEqual(live.channel_selector(self.ch).snapshot(), snapshot)

    def test_cold_head_does_not_load_or_register_playback_interest(self):
        resolver = mock.Mock()
        with mock.patch.object(live, 'resolver', resolver), \
             mock.patch.object(live, 'source_loaders') as loaders:
            for _ in range(3):
                status, headers, body = self.request('/cctv1.m3u8', method='HEAD')
                self.assertEqual((status, body), (200, b''))
                self.assertEqual(headers['X-Playback-State'], 'unobserved')
                self.assertNotIn('Content-Length', headers)
            loaders.assert_not_called()
            resolver.note_channel_interest.assert_not_called()
        self.assertIsNone(self.ch._publication)
        self.assertEqual(self.ch.last_access, 0)
        self.assertEqual(self.request('/unknown-channel.m3u8', method='HEAD')[0], 404)
        self.server.access_token = 'secret'
        self.assertEqual(self.request('/cctv1.m3u8', method='HEAD')[0], 401)

    def test_catchup_head_validates_without_upstream_io(self):
        start, stop = int(time.time()) - 1800, int(time.time()) - 900
        with mock.patch.object(live, 'jce_timeshift_url') as source, \
             mock.patch.object(live, 'fetch_abs_playlist') as fetch:
            status, headers, body = self.request(
                f'/cctv1.m3u8?start={start}&end={stop}', method='HEAD')
            self.assertEqual((status, body), (200, b''))
            self.assertEqual(headers['X-Playback-State'], 'unobserved')
            self.assertEqual(self.request('/cctv1.m3u8?start=invalid', method='HEAD')[0], 400)
            source.assert_not_called()
            fetch.assert_not_called()

    def test_head_source_header_matches_existing_publication(self):
        live.publish_channel_playlist(self.ch, playlist(), 'device')
        before = self.ch._publication['snapshot']
        with mock.patch.object(live, 'source_loaders', return_value={
                'backup': lambda: (playlist(), 'backup:jce', {})}):
            status, headers, body = self.request('/cctv1.m3u8', method='HEAD')
        self.assertEqual((status, headers['X-Source'], body), (200, 'device', b''))
        self.assertEqual(self.ch._publication['source'], 'device')
        self.assertEqual(self.ch._publication['snapshot'], before)

    def test_epg_subscription_conditional_xml_and_catchup_capabilities(self):
        cache = live.EPGCache(urls=['https://example.test/epg'])
        self.addCleanup(cache.close)
        xml, start, stop = xmltv()
        cache.programmes, cache.updated = cache.parse(xml), time.time()
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        self.server.access_token = 'test-token'
        auth = {'Authorization': 'Bearer test-token'}
        status, _, body = self.request('/all.m3u', headers=auth)
        self.assertEqual(status, 200)
        self.assertIn(b'/epg.xml?access_token=test-token', body)
        status, _, body = self.request('/api/epg?channel=cctv1', headers=auth)
        self.assertEqual(status, 200)
        item = json.loads(body)['programmes'][0]
        self.assertIn('access_token=test-token', item['catchup_url'])
        status, headers, body = self.request('/epg.xml', headers=auth)
        self.assertEqual(status, 200)
        self.assertIsNotNone(ET.fromstring(body).find('programme'))
        self.assertEqual(self.request('/epg.xml', headers={**auth, 'If-None-Match': headers['ETag']})[0], 304)
        status, _, body = self.request(f'/api/catchup?channel=cctv1&start={start}&end={stop}', headers=auth)
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)['verified'])
        self.assertEqual(self.request(f'/api/catchup?channel=cctv1&start={stop}&end={start}', headers=auth)[0], 400)
        self.assertEqual(self.request(f'/api/catchup?channel=cctv17&start={start}&end={stop}', headers=auth)[0], 422)

    def test_active_diagnostic_is_coalesced_and_checks_playlist_dns_and_content(self):
        entered, release = threading.Event(), threading.Event()
        def load():
            entered.set()
            release.wait(2)
            return playlist(), 'backup:jce', {}
        remote = mock.Mock(status=200, headers={})
        remote.read.side_effect = [b'G' + b'\0' * 187 + b'G' + b'\0' * 187 + b'G' + b'\0' * 187, b'']
        self.stack.enter_context(mock.patch.object(live, 'diagnostic_jobs', {}))
        self.addCleanup(release.set)
        with mock.patch.object(live, 'source_loaders', return_value={'backup': load}), \
                mock.patch.object(live.media_proxy.policy, 'resolve', return_value=(None, ['8.8.8.8'])), \
                mock.patch.object(live, 'open_remote', return_value=remote) as head:
            first = json.loads(self.request('/api/diagnose?channel=cctv1')[2])
            self.assertTrue(entered.wait(1))
            second = json.loads(self.request('/api/diagnose?channel=cctv1')[2])
            self.assertEqual(first['started'], second['started'])
            release.set()
            deadline = time.monotonic() + 3
            while True:
                result = json.loads(self.request('/api/diagnose?channel=cctv1')[2])
                if not result['running']:
                    break
                if time.monotonic() > deadline:
                    self.fail('diagnostic did not finish')
                time.sleep(.01)
            self.assertEqual([step['layer'] for step in result['steps']], ['playlist', 'dns_policy', 'segment_content'])
            head.assert_called_once()
            self.assertEqual(head.call_args.kwargs['method'], 'GET')
            remote.close.assert_called_once()
            self.assertIsNone(self.ch._publication)

    def test_playlist_errors_are_exposed_with_their_layer_and_redacted_details(self):
        def load():
            raise live.ProxyError(502, 'bad upstream https://media.cctv.cn/a?token=secret')
        with mock.patch.object(live, 'source_loaders', return_value={'device': live.playback_stage('playlist')(load)}):
            self.assertEqual(self.request('/cctv1.m3u8')[0], 503)
        status, _, body = self.request('/api/channels')
        issue = json.loads(body)['channels'][0]['last_issue']
        self.assertEqual((status, issue['stage'], issue['label']), (200, 'playlist', '播放列表失败'))
        self.assertNotIn('secret', issue['message'])

    def test_resource_failures_are_exposed_as_segment_errors(self):
        token = live.register_resource('https://media.cctv.cn/a.ts', channel='cctv1')
        with mock.patch.object(live.media_proxy, 'serve', side_effect=live.ProxyError(403, 'target rejected')):
            self.assertEqual(self.request('/proxy?resource=' + token)[0], 403)
        self.assertEqual(self.ch.issues[-1]['stage'], 'segment')
        self.assertEqual(self.ch.issues[-1]['status'], 403)

    def test_epg_missing_channel_is_distinguished_from_download_failure(self):
        cache = live.EPGCache(urls=['https://example.test/epg'])
        self.addCleanup(cache.close)
        cache.programmes, cache.updated = cache.parse(xmltv()[0]), time.time()
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        status, _, body = self.request('/api/epg?channel=cctv2')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['coverage']['state'], 'missing')
        cache.programmes, cache.error, cache.retry_at = (), 'download failed', time.time() + 60
        _, _, body = self.request('/api/epg?channel=cctv2')
        self.assertEqual(json.loads(body)['coverage']['state'], 'unavailable')

    def test_cold_epg_clients_receive_xml_on_first_get_and_share_download(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def fetch(url):
            calls.append(url)
            entered.set()
            release.wait(2)
            return xmltv()[0]
        cache = live.EPGCache(urls=['https://example.test/epg'], fetcher=fetch, initial_wait=2)
        self.addCleanup(cache.close)
        self.addCleanup(release.set)
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            futures = [pool.submit(self.request, '/epg.xml') for _ in range(3)]
            self.assertTrue(entered.wait(1))
            self.assertEqual(self.request('/livez')[0], 200)
            release.set()
            for future in futures:
                status, _, body = future.result(3)
                self.assertEqual(status, 200)
                tree = ET.fromstring(body)
                self.assertEqual(tree.find('programme').get('channel'), 'CCTV1')
                self.assertEqual(tree.find('channel').get('id'), 'CCTV1')
        self.assertEqual(len(calls), 1)

    def test_epg_head_does_not_download_or_wait(self):
        fetch = mock.Mock(return_value=xmltv()[0])
        cache = live.EPGCache(urls=['https://example.test/epg'], fetcher=fetch)
        self.addCleanup(cache.close)
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        status, _, body = self.request('/epg.xml', method='HEAD')
        self.assertEqual((status, body), (503, b''))
        fetch.assert_not_called()

    def test_stale_epg_is_served_while_refresh_is_blocked(self):
        entered, release = threading.Event(), threading.Event()
        def fetch(url):
            entered.set()
            release.wait(2)
            return xmltv()[0]
        cache = live.EPGCache(urls=['https://example.test/epg'], fetcher=fetch)
        cache.programmes, cache.updated = cache.parse(xmltv()[0]), time.time() - 7200
        self.addCleanup(cache.close)
        self.addCleanup(release.set)
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        started = time.monotonic()
        status, headers, body = self.request('/epg.xml')
        self.assertEqual(status, 200)
        self.assertEqual(headers['X-EPG-Stale'], 'true')
        self.assertIsNotNone(ET.fromstring(body).find('programme'))
        self.assertLess(time.monotonic() - started, 1)
        self.assertTrue(entered.wait(1))
        release.set()

    def test_subscription_starts_epg_loading_in_background(self):
        entered, release = threading.Event(), threading.Event()
        def fetch(url):
            entered.set()
            release.wait(2)
            return xmltv()[0]
        cache = live.EPGCache(urls=['https://example.test/epg'], fetcher=fetch)
        self.addCleanup(cache.close)
        self.addCleanup(release.set)
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        self.assertEqual(self.request('/all.m3u')[0], 200)
        self.assertTrue(entered.wait(1))
        release.set()

    def test_cold_epg_wait_is_bounded_and_liveness_remains_available(self):
        entered, release = threading.Event(), threading.Event()
        def fetch(url):
            entered.set()
            release.wait(2)
            return xmltv()[0]
        cache = live.EPGCache(urls=['https://example.test/epg'], fetcher=fetch, initial_wait=.05)
        self.addCleanup(cache.close)
        self.addCleanup(release.set)
        self.stack.enter_context(mock.patch.object(live, 'epg_manager', cache))
        started = time.monotonic()
        self.assertEqual(self.request('/epg.xml')[0], 503)
        self.assertLess(time.monotonic() - started, 1)
        self.assertTrue(entered.wait(1))
        self.assertEqual(self.request('/livez')[0], 200)
        release.set()


if __name__ == '__main__':
    unittest.main()
