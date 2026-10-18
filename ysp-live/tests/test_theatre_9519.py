"""Reproduce theatre refresh failures and verify bounded, transactional upgrades."""
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
from pathlib import Path
import sys
import threading
import time
import unittest
import urllib.error
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[1]


def load(version):
    name = 'theatre_' + uuid.uuid4().hex
    spec = importlib.util.spec_from_file_location(name, ROOT / ('ysp-live-v' + version + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def media(sequence=1, variant='low'):
    return ('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:%s\n'
            '#EXTINF:6,\nhttps://media.cctv.cn/%s/%s.ts\n' % (sequence, variant, sequence))


@contextlib.contextmanager
def server(handler, server_class=ThreadingHTTPServer):
    service = server_class(('127.0.0.1', 0), handler)
    service.access_token, service.trust_proxy, service.public_base_url = '', False, ''
    worker = threading.Thread(target=service.serve_forever, daemon=True)
    worker.start()
    try:
        yield service
    finally:
        service.shutdown()
        service.server_close()
        worker.join(2)


class TheatreRefreshTests(unittest.TestCase):
    def setUp(self):
        self.live = load('9.5.19')
        self.live.global_flow_limiter = self.live.ApiFlowLimiter(0, 0)
        self.events, self.workers, self.modules = [], [], [self.live]
        self.ch = self.channel(self.live)

    def channel(self, module, slug='cctvfyjc'):
        ch = module.Channel(slug, 'Theatre', 'sid', 'pid', 'best')
        ch.mode, ch.bk_effective_quality = 'bk', 'shd'
        ch.bk_urls, ch.bk_urls_time = ['https://good.cctv.cn/low.m3u8'], time.monotonic()
        ch.bk_quality_retry_at = time.monotonic() + 300
        ch.last_access, ch.last_ok = time.time(), time.time()
        ch.bk_playlist = media()
        return ch

    def event(self):
        event = threading.Event()
        self.events.append(event)
        return event

    def tearDown(self):
        for event in self.events:
            event.set()
        for module in self.modules:
            module.shutdown_event.set()
        for worker in self.workers:
            worker.join(2)
            self.assertFalse(worker.is_alive())
        for module in self.modules:
            with module._inflight_lock:
                pending = list(module._inflight_refresh.values())
            for task in pending:
                self.assertTrue(task.event.wait(2), 'refresh survived test shutdown')
            module.feature_pool.shutdown(wait=True, cancel_futures=True)
            module.diagnostic_pool.shutdown(wait=True, cancel_futures=True)
            sys.modules.pop(module.__name__, None)

    def wait_for(self, predicate, message='condition not reached'):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if predicate():
                return
            threading.Event().wait(.002)
        self.assertTrue(predicate(), message)

    def test_v9518_control_quality_timeout_skips_a_healthy_existing_url(self):
        old = load('9.5.18')
        self.modules.append(old)
        ch = self.channel(old)
        ch.bk_quality_retry_at = time.monotonic() - 1
        with mock.patch.object(old.global_flow_limiter, 'wait_slot'), \
             mock.patch.object(old, 'bk_playurls', side_effect=TimeoutError('quality API slow')), \
             mock.patch.object(old, 'fetch_abs_playlist', return_value=media()) as playlist:
            self.assertFalse(old.refresh_once(ch))
            playlist.assert_not_called()

    def test_quality_timeout_does_not_fail_working_theatre_or_enter_auth_cooldown(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        with mock.patch.object(live, 'bk_playurls', side_effect=TimeoutError('quality API slow')), \
             mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)) as fetch:
            self.assertTrue(live.refresh_once(ch))
            self.wait_for(lambda: ch.bk_quality_probe_error == 'TimeoutError')
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual((ch.bk_effective_quality, ch.last_error, ch.authorization_retry_at), ('shd', '', 0))
        self.assertEqual(ch.bk_playlist, media(2))

    def test_next_refresh_uses_successful_cdn_first(self):
        ch, live = self.ch, self.live
        bad, good = 'https://bad.cctv.cn/live.m3u8', ch.bk_urls[0]
        ch.bk_urls = [bad, good]
        calls = []
        def fetch(url, **_):
            calls.append(url)
            if url == bad:
                raise TimeoutError('bad node')
            return media(len(calls))
        with mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.bk_refresh(ch))
            self.assertTrue(live.bk_refresh(ch))
        self.assertEqual(calls, [bad, good, good])

    def test_nominal_url_ttl_does_not_discard_a_working_theatre_url(self):
        ch, live = self.ch, self.live
        ch.bk_urls_time = time.monotonic() - 600
        with mock.patch.object(live, 'bk_playurls', side_effect=AssertionError('unnecessary URL replacement')) as api, \
             mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)):
            self.assertTrue(live.bk_refresh(ch))
        api.assert_not_called()

    def test_idle_return_renews_confirmed_tier_before_background_upgrade(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        old, renewed = ch.bk_urls[0], 'https://good.cctv.cn/renewed.m3u8'
        calls = []
        def api(_sid, _pid, quality):
            calls.append(quality)
            if quality == 'shd':
                return [renewed]
            raise TimeoutError('upgrade API slow')
        def fetch(url, **_):
            if url == old:
                raise urllib.error.HTTPError(old, 403, 'expired', {}, io.BytesIO())
            return media(2)
        with mock.patch.object(live, 'bk_playurls', side_effect=api), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.refresh_once(ch))
            self.wait_for(lambda: ch.bk_quality_probe_error == 'TimeoutError')
        self.assertEqual(calls, ['shd', 'fhd'])
        self.assertEqual(ch.bk_urls, [renewed])
        self.assertEqual(ch.authorization_retry_at, 0)

    def test_rejected_known_tier_can_recover_to_newly_available_higher_tier(self):
        ch, live = self.ch, self.live
        old, high = ch.bk_urls[0], 'https://high.cctv.cn/live.m3u8'
        def api(_sid, _pid, quality):
            if quality == 'shd':
                raise live.UpstreamAuthorizationError('iretcode=25')
            return [high]
        def fetch(url, **_):
            if url == old:
                raise TimeoutError('old source failed')
            return media(3, 'high')
        with mock.patch.object(live, 'bk_playurls', side_effect=api) as resolve, \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.refresh_once(ch))
        self.assertEqual([call.args[2] for call in resolve.call_args_list], ['shd', 'fhd'])
        self.assertEqual(ch.bk_effective_quality, 'fhd')

    def test_explicit_shd_setting_does_not_request_another_tier_on_rejection(self):
        ch, live = self.ch, self.live
        ch.defn = 'shd'
        with mock.patch.object(live, 'bk_playurls', side_effect=live.UpstreamAuthorizationError('iretcode=25')) as api, \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=TimeoutError('old URL failed')):
            self.assertFalse(live.refresh_once(ch))
        self.assertEqual([call.args[2] for call in api.call_args_list], ['shd'])

    def test_candidate_url_is_not_committed_until_playlist_is_verified(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        entered, release = self.event(), self.event()
        high = 'https://high.cctv.cn/live.m3u8'
        def fetch(url, **_):
            if url == high:
                entered.set()
                release.wait(2)
                return media(3, 'high')
            return media(2)
        with mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.bk_refresh(ch))
            self.assertTrue(entered.wait(1))
            self.assertEqual((ch.bk_effective_quality, ch.bk_urls), ('shd', ['https://good.cctv.cn/low.m3u8']))
            self.assertEqual(ch.bk_playlist, media(2))
            release.set()
            self.wait_for(lambda: ch.bk_effective_quality == 'fhd')
        self.assertEqual(ch.bk_urls, [high])
        self.assertEqual(ch.bk_playlist, media(3, 'high'))

    def test_unplayable_high_quality_candidate_keeps_verified_current_tier(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        high = 'https://high.cctv.cn/live.m3u8'
        def fetch(url, **_):
            if url == high:
                raise TimeoutError('candidate CDN slow')
            return media(2)
        with mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.refresh_once(ch))
            self.wait_for(lambda: ch.bk_quality_probe_error == 'TimeoutError')
        self.assertEqual((ch.bk_effective_quality, ch.bk_playlist), ('shd', media(2)))
        self.assertEqual(ch.authorization_retry_at, 0)

    def test_high_quality_segment_403_does_not_replace_the_working_tier(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = 0
        high = 'https://high.cctv.cn/live.m3u8'
        with mock.patch.object(live, 'media_probe_manager', object()), \
             mock.patch.object(live, 'probe_playlist_content', side_effect=live.ProxyError(403, 'segment HTTP 403')) as probe, \
             mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=lambda url, **_: media(3, 'high') if url == high else media(2)):
            self.assertTrue(live.refresh_once(ch))
            self.wait_for(lambda: ch.bk_quality_probe_error == 'ProxyError')
            probe.assert_called_once()
        self.assertEqual((ch.bk_effective_quality, ch.bk_playlist), ('shd', media(2)))
        self.assertEqual((ch.authorization_retry_at, ch.last_error), (0, ''))

    def test_inconclusive_upgrade_content_keeps_verified_current_picture(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = 0
        high = 'https://high.cctv.cn/live.m3u8'
        with mock.patch.object(live, 'media_probe_manager', object()), \
             mock.patch.object(live, 'probe_playlist_content', return_value={'ok': None}), \
             mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=lambda url, **_: media(3, 'high') if url == high else media(2)):
            self.assertTrue(live.refresh_once(ch))
            self.wait_for(lambda: ch.bk_quality_probe_error == 'RuntimeError')
        self.assertEqual(ch.bk_effective_quality, 'shd')

    def test_late_current_tier_refresh_cannot_undo_verified_upgrade(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        high_entered, high_release = self.event(), self.event()
        low_entered, low_release = self.event(), self.event()
        high = 'https://high.cctv.cn/live.m3u8'
        low_calls = []
        def fetch(url, **_):
            if url == high:
                high_entered.set()
                high_release.wait(2)
                return media(4, 'high')
            low_calls.append(url)
            if len(low_calls) > 1:
                low_entered.set()
                low_release.wait(2)
            return media(2)
        with mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            live.bk_refresh(ch)
            self.assertTrue(high_entered.wait(1))
            worker = threading.Thread(target=lambda: live.bk_refresh(ch), daemon=True)
            self.workers.append(worker)
            worker.start()
            self.assertTrue(low_entered.wait(1))
            high_release.set()
            self.wait_for(lambda: ch.bk_effective_quality == 'fhd')
            low_release.set()
            worker.join(1)
        self.assertEqual((ch.bk_effective_quality, ch.bk_playlist), ('fhd', media(4, 'high')))

    def test_lower_declared_resolution_cannot_replace_current_picture(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = time.monotonic() - 1
        low, high = media(2), media(3, 'candidate')
        live.remember_playlist_profile(low, live.StreamProfile(width=1920, height=1080))
        live.remember_playlist_profile(high, live.StreamProfile(width=1280, height=720))
        candidate_url = 'https://high.cctv.cn/live.m3u8'
        with mock.patch.object(live, 'bk_playurls', return_value=[candidate_url]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=lambda url, **_: high if url == candidate_url else low):
            live.bk_refresh(ch)
            self.wait_for(lambda: ch.bk_quality_probe_error == 'RuntimeError')
        self.assertEqual(ch.bk_playlist, low)

    def test_probe_does_not_warm_unwatched_or_unrelated_channels(self):
        ch, live = self.ch, self.live
        for slug, last_access in (('cctvfyjc', time.time() - 60), ('cctv1', time.time())):
            ch.slug, ch.last_access, ch.bk_quality_retry_at = slug, last_access, 0
            with mock.patch.object(live, 'bk_playurls') as api, \
                 mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)):
                self.assertTrue(live.bk_refresh(ch))
                api.assert_not_called()

    def test_full_background_capacity_does_not_block_verified_playback(self):
        live, ch = self.live, self.ch
        release = self.event()
        ch.bk_quality_retry_at = 0
        for index in range(6):
            live.coalesce_refresh('occupied-' + str(index), lambda: release.wait(2), timeout=0,
                                  background=True, active=lambda: True)
        with mock.patch.object(live, 'bk_playurls') as api, \
             mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)):
            self.assertTrue(live.bk_refresh(ch))
            api.assert_not_called()
            self.assertFalse(ch.bk_quality_probe_running)
            self.assertEqual(live.coalesce_refresh('foreground', lambda: True, timeout=1), True)
        release.set()

    def test_expired_demand_stops_upgrade_before_next_http_without_source_failure(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = 0
        entered, release = self.event(), self.event()
        high = 'https://high.cctv.cn/live.m3u8'
        def api(*_):
            entered.set()
            release.wait(2)
            return [high]
        with mock.patch.object(live, 'bk_playurls', side_effect=api), \
             mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)) as fetch:
            self.assertTrue(live.bk_refresh(ch))
            self.assertTrue(entered.wait(1))
            ch.last_access = time.time() - 60
            release.set()
            self.wait_for(lambda: not ch.bk_quality_probe_running)
            self.assertEqual(fetch.call_count, 1)
        self.assertEqual((ch.bk_effective_quality, ch.last_error, ch.authorization_retry_at), ('shd', '', 0))

    def test_leaving_during_candidate_playlist_read_skips_next_content_request(self):
        ch, live = self.ch, self.live
        ch.bk_quality_retry_at = 0
        high, fetched = 'https://high.cctv.cn/live.m3u8', self.event()
        def fetch(url, **_):
            if url == high:
                ch.last_access = time.time() - 60
                fetched.set()
                return media(3, 'high')
            return media(2)
        with mock.patch.object(live, 'media_probe_manager', object()), \
             mock.patch.object(live, 'probe_playlist_content') as content, \
             mock.patch.object(live, 'bk_playurls', return_value=[high]), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.refresh_once(ch))
            self.assertTrue(fetched.wait(1))
            self.wait_for(lambda: not ch.bk_quality_probe_running)
            content.assert_not_called()
        self.assertEqual((ch.bk_effective_quality, ch.last_error), ('shd', ''))

    def test_same_failed_url_is_not_downloaded_twice_in_one_refresh(self):
        ch, live = self.ch, self.live
        with mock.patch.object(live, 'bk_playurls', return_value=list(ch.bk_urls)), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=TimeoutError('node slow')) as fetch:
            with self.assertRaises(TimeoutError):
                live.bk_refresh(ch)
            self.assertEqual(fetch.call_count, 1)

    def test_failed_cdn_http_response_is_closed_before_successful_fallback(self):
        ch, live = self.ch, self.live
        bad, good = 'https://bad.cctv.cn/live.m3u8', ch.bk_urls[0]
        ch.bk_urls = [bad, good]
        body = io.BytesIO(b'local error page')
        error = urllib.error.HTTPError(bad, 503, 'local failure', {}, body)
        def fetch(url, **_):
            if url == bad:
                raise error
            self.assertTrue(body.closed)
            return media(2)
        with mock.patch.object(live, 'fetch_abs_playlist', side_effect=fetch):
            self.assertTrue(live.bk_refresh(ch))

    def test_cached_publication_cannot_masquerade_as_recent_upstream_refresh(self):
        ch, live = self.ch, self.live
        ch.last_ok, ch.last_fetch_success_at = time.time() - 30, time.time()
        def refresh(*_, **__):
            ch.last_access = time.time() - 60
            return True
        with mock.patch.object(live, 'coalesce_refresh', side_effect=refresh) as refresh_call:
            live.refresh_loop(ch)
        refresh_call.assert_called_once()

    def test_real_http_cdn_failure_is_not_repeated_after_another_url_succeeds(self):
        ch, live, calls = self.ch, self.live, []
        class Origin(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                if self.path == '/bad':
                    self.send_error(503)
                    return
                body = media(len(calls)).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_):
                pass
        with server(Origin) as origin:
            base = 'http://127.0.0.1:' + str(origin.server_port)
            ch.bk_urls = [base + '/bad', base + '/good']
            self.assertTrue(live.bk_refresh(ch))
            self.assertTrue(live.bk_refresh(ch))
        self.assertEqual(calls, ['/bad', '/good', '/good'])

    def test_all_three_http_channels_stay_available_while_upgrade_api_is_waiting(self):
        live = self.live
        channels = {slug: self.channel(live, slug) for slug in live.THEATRE_CHANNELS}
        release = self.event()
        def api(*_):
            release.wait(3)
            raise live.UpstreamAuthorizationError('iretcode=25')
        with mock.patch.object(live, 'CHANNEL_MAP', channels), \
             mock.patch.object(live, 'resolver', None), mock.patch.object(live, 'engine_enabled', False), \
             mock.patch.object(live, 'media_probe_manager', None), mock.patch.object(live, 'schedule_source_probe'), \
             mock.patch.object(live, 'bk_playurls', side_effect=api), \
             mock.patch.object(live, 'fetch_abs_playlist', return_value=media(2)):
            for channel in channels.values():
                channel.bk_quality_retry_at = 0
                self.assertTrue(live.refresh_once(channel))
                live.build_playlist(channel)
            self.wait_for(lambda: all(ch.bk_quality_probe_running for ch in channels.values()))
            with server(live.Handler, live.BoundedHTTPServer) as gateway:
                for slug in channels:
                    with contextlib.closing(http.client.HTTPConnection('127.0.0.1', gateway.server_port, timeout=1)) as client:
                        client.request('GET', '/' + slug + '.m3u8')
                        response = client.getresponse()
                        self.assertEqual((response.status, response.getheader('X-Source')), (200, 'backup:bk'))
                        self.assertIn(b'#EXTM3U', response.read())
            release.set()
            self.wait_for(lambda: all(not ch.bk_quality_probe_running for ch in channels.values()))
        self.assertTrue(all(ch.authorization_retry_at == 0 for ch in channels.values()))


if __name__ == '__main__':
    unittest.main()
