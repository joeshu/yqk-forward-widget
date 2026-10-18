"""Original v9.5 compatibility and channel isolation; no real upstream requests."""
import contextlib
from email.message import Message
import http.client
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from test_release_959 import args, entry, server

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_release_9513', ROOT / 'ysp-live-v9.5.14.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def media(seq=1):
    return f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{seq}\n#EXTINF:6,\nhttps://media.cctv.cn/{seq}.ts\n'


class Response(io.BytesIO):
    def __init__(self, body, url):
        super().__init__(body.encode())
        self.url, self.status, self.headers = url, 200, Message()
    def geturl(self):
        return self.url


class TransportCompatibilityTests(unittest.TestCase):
    def test_jce_retains_original_20_second_timeout_for_each_nested_playlist(self):
        seen = []
        def fetch(req, timeout):
            seen.append(timeout)
            if timeout < 12:
                raise TimeoutError('simulated twelve-second upstream')
            body = ('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080\nchild.m3u8\n'
                    if req.full_url.endswith('master.m3u8') else media())
            return Response(body, req.full_url)
        ch = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        with mock.patch.object(live, 'jce_timeshift_url', return_value='https://media.cctv.cn/master.m3u8'), \
             mock.patch.object(live.global_flow_limiter, 'wait_slot'), \
             mock.patch.object(live.urllib.request, 'urlopen', side_effect=fetch):
            self.assertEqual(len(live.jce_fetch(ch)), 1)
        self.assertEqual(seen, [20, 20])

    def test_backup_retains_ten_second_timeout(self):
        with mock.patch.object(live.urllib.request, 'urlopen', return_value=Response(media(), 'https://media.cctv.cn/a.m3u8')) as fetch:
            live.fetch_abs_playlist('https://media.cctv.cn/a.m3u8')
            self.assertEqual(fetch.call_args.kwargs['timeout'], 10)

    def test_compatible_mode_delegates_dns_and_uses_urllib_without_system_proxy(self):
        policy = live.URLPolicy(network_mode='compatible')
        with mock.patch.object(live, 'bounded_dns_addresses', side_effect=AssertionError('must not pre-resolve DNS')), \
             mock.patch.object(live.urllib.request, 'getproxies', return_value={}), \
             mock.patch.object(live.urllib.request, 'build_opener') as build:
            build.return_value.open.return_value = Response(media(), 'https://media.cctv.cn/a.m3u8')
            remote = live.open_remote('https://media.cctv.cn/a.m3u8', policy=policy)
            self.assertEqual(remote.status, 200)
            self.assertIsNone(remote.connection)
            remote.close()
            build.return_value.open.assert_called_once()
            with self.assertRaises(live.ProxyError):
                policy.resolve('http://127.0.0.1/private')
            with self.assertRaises(live.ProxyError):
                policy.resolve('https://media.cctv.cn:12345/private')

    def test_compatible_mode_still_validates_each_real_http_redirect(self):
        from http.server import BaseHTTPRequestHandler
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(302)
                self.send_header('Location', 'http://not-allowed.invalid/media')
                self.send_header('Content-Length', '0')
                self.end_headers()
        policy = live.URLPolicy(allowed_suffixes=('127.0.0.1',), allow_private=True, network_mode='compatible')
        with server(Origin) as upstream, mock.patch.object(live.urllib.request, 'getproxies', return_value={}):
            with self.assertRaisesRegex(live.ProxyError, 'not allowed'):
                live.open_remote(f'http://127.0.0.1:{upstream.server_port}/redirect', policy=policy)

    def test_validated_mode_still_rejects_fake_ip_without_opt_in(self):
        with mock.patch.object(live, 'bounded_dns_addresses', return_value=['198.18.0.1']):
            with self.assertRaisesRegex(live.ProxyError, 'Fake-IP'):
                live.URLPolicy(network_mode='validated', allow_fake_ip=False).resolve('https://media.cctv.cn/a.ts')


class DeviceIsolationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.r = live.Resolver(args(directory.name))
        self.addCleanup(self.r.close)
        self.r.write_meta = mock.Mock()

    def test_channel_400_preserves_other_channel_cache_session_and_identity(self):
        self.r.args.identity_reset_error_threshold = 1
        other, session = object(), object()
        self.r.state.cache['cctv2'] = other
        self.r.state.sessions[0] = session
        self.r._session_results[0] = ('keep',)
        with mock.patch.object(self.r, 'rotate_device_on_400') as rotate, \
             mock.patch.object(self.r, 'refresh_channel_controlled', side_effect=live.YsptpError('live/v1/01 HTTP 400: channel rejected')) as fetch:
            with self.assertRaisesRegex(live.YsptpError, 'HTTP 400'):
                self.r.ensure_channel('cctv1')
            rotate.assert_not_called()
            fetch.assert_called_once()
        self.assertIs(self.r.state.cache['cctv2'], other)
        self.assertIs(self.r.state.sessions[0], session)
        self.assertEqual(self.r._session_results[0], ('keep',))
        self.assertEqual(self.r.state.channel_failures['cctv1'][2], 1)
        for endpoint in ('live/v1/01', 'live/v1/02', 'VDN', 'upstream m3u8'):
            message = endpoint + ' HTTP 400'
            self.assertFalse(live.is_session_invalidating_error(message))
            self.assertFalse(live.is_identity_recoverable_error(message))

    def test_device_registration_400_keeps_bounded_global_recovery(self):
        with mock.patch.object(self.r, 'rotate_device_on_400', return_value=True) as rotate, \
             mock.patch.object(self.r, 'refresh_channel_controlled', side_effect=[live.YsptpError('cloud_register HTTP 400'), entry()]) as fetch:
            self.assertIsNotNone(self.r.ensure_channel('cctv1'))
            rotate.assert_called_once()
            self.assertEqual(fetch.call_count, 2)

    def test_pending_identity_is_reused_across_failed_bootstrap_attempts(self):
        original = live.default_device_state()
        original.registered_at = 0
        live.save_device_state(self.r.args.device_json, original)
        with mock.patch.object(self.r, 'app_start_flow', side_effect=live.YsptpError('stop before network')) as start:
            for _ in range(2):
                with self.assertRaisesRegex(live.YsptpError, 'stop before network'):
                    self.r.bootstrap_session(1)
            for call in start.call_args_list:
                self.assertEqual(call.args[1].android_id, original.profile.android_id)
        self.assertEqual(live.load_device_state(self.r.args.device_json)[0].profile.android_id, original.profile.android_id)

    def test_cloud_registration_errors_include_codes_without_response_secrets(self):
        response = live.HttpResponse(400, 'Bad Request', {}, b'{"result":99,"data":{"guid":"secret-guid"},"token":"secret-token"}')
        self.r.generic_client.post_json = mock.Mock(return_value=response)
        identity = SimpleNamespace(headers={})
        with mock.patch.object(live, 'rsa_encrypt_device_id', return_value='encrypted'):
            with self.assertRaises(live.YsptpError) as raised:
                self.r.cloud_registration_flow(identity, 'secret-device')
        self.assertIn('cloud_get HTTP 400', str(raised.exception))
        self.assertEqual(self.r._registration_last['result_code'], 99)
        for secret in ('secret-guid', 'secret-token', 'secret-device'):
            self.assertNotIn(secret, str(raised.exception))
            self.assertNotIn(secret, str(self.r._registration_last))

    def test_empty_guid_registration_failure_is_shared_for_sixty_seconds(self):
        with mock.patch.object(self.r, 'bootstrap_session', side_effect=live.YsptpError('cloud device registration failed: empty guid')) as bootstrap:
            for _ in range(2):
                with self.assertRaises(live.YsptpError):
                    self.r.ensure_slot_session(0)
            bootstrap.assert_called_once()
        self.assertGreater(self.r._session_results[0][2] - time.monotonic(), 50)


class PromotionTests(unittest.TestCase):
    def test_initial_upgrade_is_faster_but_requires_progress_and_content_evidence(self):
        clock = [100.0]
        s = live.SourceSelector(clock=lambda: clock[0], fast_start=True, validate_recovery=True)
        s.commit('backup')
        clock[0] = 105
        self.assertIsNone(s.reserve_probe(['backup', 'device']))
        clock[0] = 106
        self.assertEqual(s.reserve_probe(['backup', 'device']), 'device')
        s.success('device', media(1), .1, probe=True)
        s.states['device']['probing'] = False
        self.assertEqual(s.order(['device', 'backup'])[0], 'backup')
        clock[0] = 112
        self.assertEqual(s.reserve_probe(['backup', 'device']), 'device')
        s.success('device', media(2), .1, probe=True)
        self.assertEqual(s.order(['device', 'backup'])[0], 'backup')
        s.states['device']['content_result'] = {'ok': True}
        s.states['device']['content_verified_at'] = clock[0]
        self.assertEqual(s.order(['device', 'backup'])[0], 'device')

    def test_failed_source_and_later_recovery_keep_normal_hold(self):
        clock = [100.0]
        s = live.SourceSelector(clock=lambda: clock[0], fast_start=True)
        s.commit('backup')
        s.failure('device', 'upstream failed')
        clock[0] = 112
        self.assertIsNone(s.reserve_probe(['device', 'backup']))
        for seq in (1, 2):
            s.success('device', media(seq), .1, probe=True)
        self.assertEqual(s.order(['device', 'backup'])[0], 'backup')
        clock[0] = 131
        self.assertEqual(s.order(['device', 'backup'])[0], 'device')
        s.commit('device')
        s.commit('backup')
        clock[0] += 6
        self.assertIsNone(s.reserve_probe(['device', 'backup']))


class TheatreAuthorizationTests(unittest.TestCase):
    def test_theatre_tries_highest_then_original_quality_and_remembers_result(self):
        for slug in live.THEATRE_CHANNELS:
            ch = live.Channel(slug, 'Theatre', 'sid', 'pid', 'best')
            with mock.patch.object(live.time, 'monotonic', return_value=1000), \
                 mock.patch.object(live, 'bk_playurls', side_effect=[
                     live.UpstreamAuthorizationError('iretcode=25'), ['low'], ['low-again']]) as api:
                self.assertEqual(live.bk_channel_playurls(ch), ['low'])
                self.assertEqual(live.bk_channel_playurls(ch), ['low-again'])
                self.assertEqual([call.args[2] for call in api.call_args_list], ['fhd', 'shd', 'shd'])
                self.assertEqual(ch.bk_effective_quality, 'shd')
                self.assertEqual(ch.bk_quality_retry_at, 1300)
            with mock.patch.object(live.time, 'monotonic', return_value=1301), \
                 mock.patch.object(live, 'bk_playurls', return_value=['high']) as api:
                self.assertEqual(live.bk_channel_playurls(ch), ['high'])
                api.assert_called_once_with('sid', 'pid', 'fhd')
                self.assertEqual(ch.bk_effective_quality, 'fhd')
                self.assertEqual(ch.bk_quality_retry_at, 0)

    def test_only_confirmed_quality_rejection_uses_original_theatre_fallback(self):
        ch = live.Channel('cctvfyjc', 'Theatre', 'sid', 'pid', 'best')
        with mock.patch.object(live, 'bk_playurls', side_effect=TimeoutError('network slow')) as api:
            with self.assertRaises(TimeoutError):
                live.bk_channel_playurls(ch)
            api.assert_called_once()
        other = live.Channel('cctv1', 'Normal', 'sid', 'pid', 'best')
        with mock.patch.object(live, 'bk_playurls', side_effect=live.UpstreamAuthorizationError('iretcode=25')) as api:
            with self.assertRaises(live.UpstreamAuthorizationError):
                live.bk_channel_playurls(other)
            api.assert_called_once_with('sid', 'pid', 'fhd')

    def test_both_theatre_tiers_rejected_remain_authorization_failure(self):
        ch = live.Channel('cctvfyjc', 'Theatre', 'sid', 'pid', 'best')
        ch.mode = 'bk'
        with mock.patch.object(live, 'bk_playurls', side_effect=live.UpstreamAuthorizationError('iretcode=25')) as api, \
             mock.patch.object(live.global_flow_limiter, 'wait_slot'):
            self.assertFalse(live.refresh_once(ch))
            self.assertEqual([call.args[2] for call in api.call_args_list], ['fhd', 'shd'])
            self.assertEqual(ch.last_error_stage, 'authorization')
            self.assertGreater(ch.authorization_retry_at, time.monotonic())

    def test_theatre_routes_are_retained_and_do_not_invent_device_ids(self):
        for slug in ('cctvfyjc', 'cctvdyjc', 'cctvhjjc'):
            self.assertIn(slug, live.CHANNEL_MAP)
            self.assertIn(slug, live.FORCE_BK)
            self.assertIsNone(live.channel_by_name(slug))

    def test_business_login_failure_has_a_distinct_type(self):
        response = Response('{"iretcode":25,"errinfo":"无登录信息"}', 'https://bkliveinfo.ysp.cctv.cn/')
        with mock.patch.object(live.urllib.request, 'urlopen', return_value=response):
            with self.assertRaises(live.UpstreamAuthorizationError):
                live.bk_playurls('sid', 'pid')

    def test_authorization_backoff_is_channel_local_and_retries_after_expiry(self):
        ch = live.Channel('cctvfyjc', 'CCTV 风云剧场', 'sid', 'pid', 'best')
        ch.mode = 'bk'
        with mock.patch.object(live, 'bk_refresh', side_effect=live.UpstreamAuthorizationError('iretcode=25 无登录信息')) as source, \
             mock.patch.object(live, 'jce_refresh') as jce, \
             mock.patch.object(live.time, 'monotonic', return_value=1000):
            for _ in range(3):
                self.assertFalse(live.refresh_once(ch))
            source.assert_called_once()
            jce.assert_not_called()
        self.assertEqual(ch.authorization_retry_at, 1300)
        self.assertEqual(ch.last_error_stage, 'authorization')
        with mock.patch.object(live.time, 'monotonic', return_value=1301), \
             mock.patch.object(live, 'bk_refresh', return_value=True) as source:
            self.assertTrue(live.refresh_once(ch))
            source.assert_called_once()
        self.assertEqual(ch.authorization_retry_at, 0)

    def test_http_reports_upstream_auth_without_faking_playability(self):
        ch = live.Channel('cctvfyjc', 'CCTV 风云剧场', 'sid', 'pid', 'best')
        ch.last_error, ch.last_error_stage = 'iretcode=25 无登录信息', 'authorization'
        ch.authorization_retry_at = time.monotonic() + 300
        with mock.patch.object(live, 'CHANNEL_MAP', {'cctvfyjc': ch}), \
             mock.patch.object(live, 'source_loaders', return_value={'backup': lambda: (None, 'backup:bk', {})}), \
             server(live.Handler) as gateway:
            gateway.access_token = ''
            connection = http.client.HTTPConnection('127.0.0.1', gateway.server_port, timeout=3)
            connection.request('GET', '/cctvfyjc.m3u8')
            response = connection.getresponse()
            self.assertEqual(response.status, 503)
            self.assertEqual(response.getheader('X-Upstream-Auth'), 'required')
            self.assertGreater(int(response.getheader('Retry-After')), 290)
            self.assertIn('上游需要登录', response.read().decode())
            connection.close()
            row = next(row for row in live.channel_status() if row['slug'] == ch.slug)
            self.assertTrue(row['upstream_authorization_required'])
            self.assertEqual(row['state'], 'authorization_required')


if __name__ == '__main__':
    unittest.main()
