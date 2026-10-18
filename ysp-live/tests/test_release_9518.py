"""Identity evidence, heartbeat isolation and real atomic metadata writes.

Upstreams are local functions; the playback check uses loopback HTTP only.
"""
import concurrent.futures
import contextlib
import dataclasses
import http.client
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from test_release_959 import args


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_release_9518', ROOT / 'ysp-live-v9.5.19.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def playlist():
    return ('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:1\n'
            '#EXTINF:6,\nhttps://media.cctv.cn/one.ts\n')


class ResolverFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.r = live.Resolver(args(self.directory.name))
        self.r.args.zap_debounce = 0
        self.r.args.foreground_wait = 1
        self.addCleanup(self.r.close)
        self.addCleanup(live.set_resolver_ready, False)
        self.release_events = []
        self.addCleanup(self.release_all)

    def release_all(self):
        for event in self.release_events:
            event.set()

    def wait_for(self, predicate, message='condition was not reached', timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            threading.Event().wait(.002)
        self.assertTrue(predicate(), message)

    def entry(self, channel='cctv1', generation=1, session_generation=7):
        return live.ChannelEntry(channel=channel, final_url='https://media.cctv.cn/' + channel + '.m3u8',
            android_id='local-test', generation=generation, session_generation=session_generation,
            refreshed_at=time.time(), expires_at=time.time() + 600)

    def session(self):
        device = live.default_device_state()
        session = live.AppSession(profile=device.profile,
            identity=live.build_identity(device.profile, 'dangbei', '1.4.1'), client=mock.Mock(),
            session_key='0' * 32, cloud_guid='local-guid', version='1.4.1',
            screen_param=device.screen_param, cast_model=device.cast_model, created_at=time.time(),
            generation=7, last_heartbeat_at=time.time(), heartbeat_count=1,
            last_heartbeat_result='0', last_heartbeat_error='')
        self.r.state.sessions[0] = session
        self.r.state.session_generation = 7
        return session


class IdentityEvidenceTests(ResolverFixture):
    def test_transport_status_and_channel_permissions_do_not_prove_invalid_identity(self):
        for error in (TimeoutError('timed out'), live.YsptpError('app/start HTTP 400'),
                      live.YsptpError('cloud_register HTTP 400'), live.YsptpError('heartbeat HTTP 400'),
                      live.YsptpError('live/v1/01 HTTP 403'), live.YsptpError('missing videos')):
            with self.subTest(error=str(error)):
                self.assertFalse(live.is_identity_recoverable_error(error))
                self.assertFalse(live.is_session_invalidating_error(error))

    def test_explicit_evidence_is_restricted_to_identity_endpoints(self):
        for phase, status, value, expected in (
            ('cloud_register', 400, {'result': 99, 'message': 'Invalid device identity'}, True),
            ('app_start', 403, {'message': 'Device id is revoked'}, True),
            ('cloud_get', 400, {'result': 99}, False),
            ('cloud_get', 503, {'message': 'Invalid device identity'}, False),
            ('live/v1/01', 403, {'message': 'Invalid device identity'}, False),
            ('cloud_get', 200, {'result': 0, 'message': 'Invalid device identity'}, False),
            ('cloud_get', 400, {'result': 99, 'data': 'Invalid device identity'}, False),
            ('cloud_get', 400, {'result': 99, 'message': 'Invalid device signature'}, False),
            ('cloud_get', 400, {'result': 99, 'message': 'Invalid device id signature'}, False),
            ('cloud_get', 400, {'result': 99, 'message': 'This does not mean the device is invalid'}, False),
        ):
            with self.subTest(phase=phase, status=status, value=value):
                error = live.protocol_response_error(phase, status, value)
                self.assertEqual(live.is_identity_recoverable_error(error), expected)

    def test_unknown_400_preserves_other_sources_and_session(self):
        session = self.session()
        other = self.entry('cctv2')
        self.r.state.cache['cctv2'] = other
        error = live.protocol_response_error('cloud_register', 400, {'result': 99})
        with mock.patch.object(self.r, 'rotate_device_on_400') as rotate, \
             mock.patch.object(self.r, 'request_meta_write'), \
             mock.patch.object(self.r, 'refresh_channel_controlled', side_effect=error):
            with self.assertRaises(live.UpstreamProtocolError):
                self.r.ensure_channel('cctv1')
            rotate.assert_not_called()
        self.assertIs(self.r.state.sessions[0], session)
        self.assertIs(self.r.state.cache['cctv2'], other)

    def test_explicit_identity_rejection_keeps_one_bounded_recovery(self):
        error = live.protocol_response_error('cloud_register', 400, {'result': 99, 'message': 'Invalid device'})
        entry = self.entry()
        with mock.patch.object(self.r, 'rotate_device_on_400', return_value=True) as rotate, \
             mock.patch.object(self.r, 'request_meta_write'), \
             mock.patch.object(self.r, 'refresh_channel_controlled', side_effect=[error, entry]) as resolve:
            self.assertIs(self.r.ensure_channel('cctv1'), entry)
        rotate.assert_called_once()
        self.assertEqual(resolve.call_count, 2)

    def test_bootstrap_preserves_error_evidence_without_response_secrets(self):
        error = live.protocol_response_error('cloud_register', 400,
            {'result': 99, 'message': 'Invalid device', 'token': 'do-not-log-this'})
        with mock.patch.object(self.r, 'app_start_flow', return_value=SimpleNamespace(session_key='local')), \
             mock.patch.object(self.r, 'cloud_registration_flow', side_effect=error):
            with self.assertRaises(live.UpstreamProtocolError) as raised:
                self.r.bootstrap_session(1)
        self.assertTrue(raised.exception.identity_invalid)
        self.assertEqual(raised.exception.phase, 'cloud_register')
        self.assertEqual(raised.exception.http_status, 400)
        self.assertEqual(raised.exception.business_code, 99)
        self.assertNotIn('do-not-log-this', str(raised.exception))

    def test_initialization_unknown_400_does_not_rotate(self):
        stop = threading.Event()
        error = live.protocol_response_error('cloud_get', 400, {'result': 99})
        fake = SimpleNamespace(ensure_slot_session=mock.Mock(side_effect=error), rotate_device_on_400=mock.Mock())
        def wait(_):
            stop.set()
            return True
        with mock.patch.object(live, 'resolver', fake), mock.patch.object(live, 'shutdown_event', stop), \
             mock.patch.object(stop, 'wait', side_effect=wait):
            live.init_resolver()
        fake.rotate_device_on_400.assert_not_called()

    def test_known_registration_transition_does_not_rotate_despite_invalid_device_wording(self):
        responses = [
            live.HttpResponse(400, 'local', {}, b'{"result":2,"message":"Invalid device"}'),
            live.HttpResponse(200, 'local', {}, b'{"result":0,"data":{"guid":"existing-guid"}}'),
        ]
        with mock.patch.object(live, 'rsa_encrypt_device_id', return_value='local'), \
             mock.patch.object(self.r.generic_client, 'post_json', side_effect=responses), \
             mock.patch.object(self.r, 'rotate_device_on_400') as rotate:
            guid = self.r.cloud_registration_flow(SimpleNamespace(headers={}), 'local')
        self.assertEqual(guid, 'existing-guid')
        rotate.assert_not_called()

    def test_initialization_explicit_rejection_keeps_bounded_recovery(self):
        stop = threading.Event()
        error = live.protocol_response_error('cloud_get', 400, {'result': 99, 'message': 'Invalid device id'})
        fake = SimpleNamespace(ensure_slot_session=mock.Mock(side_effect=error), rotate_device_on_400=mock.Mock())
        def wait(_):
            stop.set()
            return True
        with mock.patch.object(live, 'resolver', fake), mock.patch.object(live, 'shutdown_event', stop), \
             mock.patch.object(stop, 'wait', side_effect=wait):
            live.init_resolver()
        fake.rotate_device_on_400.assert_called_once()


class ExistingSourceTests(ResolverFixture):
    def setUp(self):
        super().setUp()
        self.session_value = self.session()
        self.entry_value = self.entry()
        self.r.state.cache['cctv1'] = self.entry_value
        self.r.request_meta_write = mock.Mock()
        self.r.fetch_playlist = mock.Mock(return_value=(playlist(), 'hls', None))
        self.r.ensure_channel = mock.Mock(side_effect=AssertionError('must not resolve or register'))

    @contextlib.contextmanager
    def playback_context(self):
        channel = live.Channel('cctv1', 'Test', 'sid', 'pid', 'best')
        with mock.patch.object(live, 'resolver', self.r), \
             mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': channel}), \
             mock.patch.object(live, 'active_backend_channels', {'cctv1'}), \
             mock.patch.object(live, 'engine_enabled', False), \
             mock.patch.object(live, 'media_probe_manager', None), \
             mock.patch.object(live, 'schedule_source_probe'):
            yield channel

    def test_heartbeat_timeout_is_unconfirmed_and_existing_source_remains_available(self):
        live.set_resolver_ready(True)
        self.r.heartbeat_flow = mock.Mock(side_effect=TimeoutError('network read timed out'))
        self.r.send_heartbeat()
        self.assertFalse(live.resolver_ready())
        self.assertIs(self.r.state.sessions[0], self.session_value)
        self.assertTrue(self.r.has_existing_channel_source('cctv1'))
        self.assertEqual(self.r.session_health_snapshot()['state'], 'heartbeat_pending')
        with self.playback_context() as channel:
            body, source, _ = live.source_loaders(channel, 'http://127.0.0.1:18767')['device']()
        self.assertIn('#EXTM3U', body)
        self.assertEqual(source, 'device')
        self.r.ensure_channel.assert_not_called()

    def test_real_http_get_keeps_device_source_when_heartbeat_is_unconfirmed(self):
        live.set_resolver_ready(False)
        with self.playback_context():
            server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
            server.access_token, server.trust_proxy, server.public_base_url = '', False, ''
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with contextlib.closing(http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)) as client:
                    client.request('GET', '/cctv1.m3u8')
                    response = client.getresponse()
                    body = response.read()
                    self.assertEqual((response.status, response.getheader('X-Source')), (200, 'device'))
                    self.assertIn(b'#EXTM3U', body)
                    client.request('GET', '/api/diagnostics')
                    diagnostics_response = client.getresponse()
                    diagnostics = json.loads(diagnostics_response.read())
                    self.assertEqual(diagnostics_response.status, 200)
                    self.assertFalse(diagnostics['device_ready'])
                    self.assertEqual(diagnostics['device_session_health']['existing_source_count'], 1)
                    self.assertIn('pending', diagnostics['metadata_writer'])
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)
        self.r.ensure_channel.assert_not_called()

    def test_expired_source_does_not_enable_device_loader(self):
        live.set_resolver_ready(False)
        self.entry_value.expires_at = time.time() - 1
        with self.playback_context() as channel:
            self.assertNotIn('device', live.source_loaders(channel, 'http://127.0.0.1:18767'))
        self.r.fetch_playlist.assert_not_called()

    def test_only_existing_source_never_forces_auth_retry(self):
        self.r.fetch_playlist.side_effect = live.YsptpError('upstream m3u8 HTTP 403')
        with self.assertRaisesRegex(live.YsptpError, '403'):
            self.r.fetch_channel_playlist_bounded('cctv1', 'local', _existing_only=True)
        self.r.ensure_channel.assert_not_called()
        self.r.fetch_playlist.assert_called_once()

    def test_explicit_heartbeat_auth_rejection_blocks_existing_generation(self):
        error = live.protocol_response_error('heartbeat', 401, {})
        self.r.heartbeat_flow = mock.Mock(side_effect=error)
        self.r.send_heartbeat()
        self.assertNotIn(0, self.r.state.sessions)
        self.assertFalse(self.r.has_existing_channel_source('cctv1'))
        self.assertEqual(self.r.session_health_snapshot()['state'], 'rejected')
        with self.playback_context() as channel:
            self.assertNotIn('device', live.source_loaders(channel, 'http://127.0.0.1:18767'))

    def test_missing_signed_headers_are_not_reused(self):
        self.entry_value.final_url = 'https://liveali.cctv.cn/test.m3u8'
        self.assertFalse(self.r.has_existing_channel_source('cctv1'))

    def test_source_expiring_during_playlist_read_is_not_delivered(self):
        def fetch(*_):
            self.entry_value.expires_at = time.time() - 1
            return playlist(), 'hls', None
        self.r.fetch_playlist.side_effect = fetch
        with self.assertRaises(live.SourcePending):
            self.r.fetch_channel_playlist('cctv1', 'local', _existing_only=True)
        self.r.ensure_channel.assert_not_called()

    def test_busy_heartbeat_preserves_existing_source_without_waiting(self):
        entered, release = threading.Event(), threading.Event()
        self.release_events.append(release)
        def hold_control():
            with self.r.control_lock:
                entered.set()
                release.wait(2)
        worker = threading.Thread(target=hold_control, daemon=True)
        worker.start()
        self.assertTrue(entered.wait(1))
        self.session_value.last_heartbeat_at = time.time() - 120
        try:
            self.r.send_heartbeat()
            self.assertFalse(live.resolver_ready())
            self.assertTrue(self.r.has_existing_channel_source('cctv1'))
            self.assertEqual(self.r.session_health_snapshot()['state'], 'heartbeat_pending')
        finally:
            release.set()
            worker.join(2)

    def test_rejected_session_cannot_publish_a_late_playlist_result(self):
        # Exercise the actual playlist fetch, not the mock used by other cases.
        entry = self.entry_value
        self.r.fetch_playlist = live.Resolver.fetch_playlist.__get__(self.r)
        def fetch(*_):
            with self.r.state_lock:
                self.r._invalidate_session_locked(0)
            return 200, 'hls', playlist(), entry.final_url
        with mock.patch.object(live, 'fetch_playlist_http1', side_effect=fetch):
            with self.assertRaisesRegex(live.YsptpError, 'source changed'):
                self.r.fetch_channel_playlist('cctv1', 'local', _existing_only=True)
        self.assertNotIn('cctv1', self.r._playlist_raw)

    def test_next_successful_heartbeat_restores_confirmed_session_state(self):
        self.r.heartbeat_flow = mock.Mock(side_effect=[TimeoutError('offline'), '0'])
        self.r.send_heartbeat()
        self.assertFalse(live.resolver_ready())
        self.r.send_heartbeat()
        self.assertTrue(live.resolver_ready())
        self.assertEqual(self.r.session_health_snapshot()['state'], 'healthy')
        self.assertIs(self.r.state.sessions[0], self.session_value)

    def test_failed_renewal_keeps_existing_source_without_claiming_renewal_success(self):
        self.session_value.created_at = time.time() - self.r.args.session_ttl + 100
        with mock.patch.object(self.r, 'bootstrap_session', side_effect=TimeoutError('renewal offline')):
            self.r.send_heartbeat()
        self.assertFalse(live.resolver_ready())
        self.assertIs(self.r.state.sessions[0], self.session_value)
        self.assertTrue(self.r.has_existing_channel_source('cctv1'))
        self.assertEqual(self.r.session_health_snapshot()['state'], 'heartbeat_pending')

    def test_expired_entry_in_only_existing_mode_does_not_resolve(self):
        self.entry_value.expires_at = time.time() - 1
        with self.assertRaises(live.SourcePending):
            self.r.fetch_channel_playlist_bounded('cctv1', 'local', _existing_only=True)
        self.r.ensure_channel.assert_not_called()
        self.r.fetch_playlist.assert_not_called()

    def test_playlist_auth_rejection_in_swr_cache_disables_existing_source(self):
        entry = self.entry_value
        self.r.fetch_playlist = live.Resolver.fetch_playlist.__get__(self.r)
        with mock.patch.object(live, 'fetch_playlist_http1', return_value=(200, 'hls', playlist(), entry.final_url)):
            self.r.fetch_playlist(entry, 'http://local')
        raw = self.r._playlist_raw['cctv1']
        raw.expires_at = 0
        key = self.r._playlist_source_key(entry)
        error = live.UpstreamProtocolError('upstream m3u8 HTTP 403', phase='playlist', http_status=403)
        self.r._playlist_failures[key] = time.monotonic() + 2, error
        # The normal SWR path can retain old media during an error backoff.
        # Only-existing mode must not use that media after a definite rejection.
        with self.assertRaises(live.UpstreamProtocolError):
            self.r.fetch_channel_playlist('cctv1', 'local', _existing_only=True)
        self.assertFalse(self.r.has_existing_channel_source('cctv1'))
        self.assertEqual(self.r._stats['playlist_source_invalidated'], 1)
        self.r.ensure_channel.assert_not_called()


class MetadataWriterTests(ResolverFixture):
    def test_burst_is_coalesced_and_close_flushes_to_real_file(self):
        self.r.state.cache['cctv1'] = self.entry()
        self.r._meta_debounce = 10
        with mock.patch.object(live, 'atomic_json_write', wraps=live.atomic_json_write) as write:
            for _ in range(50):
                self.assertTrue(self.r.request_meta_write())
            self.r.close()
            self.assertEqual(write.call_count, 1)
        payload = json.loads(Path(self.r.args.meta_json).read_text())
        self.assertIn('cctv1', payload['cache_detail'])
        self.assertFalse(self.r.metadata_writer_snapshot()['pending'])
        self.assertFalse(self.r.metadata_writer_snapshot()['worker_alive'])

    def test_slow_disk_does_not_block_next_channel_resolution_or_protocol_lock(self):
        entered, release = threading.Event(), threading.Event()
        self.release_events.append(release)
        write = live.atomic_json_write
        def slow_write(path, payload):
            entered.set()
            if not release.wait(3):
                raise AssertionError('test did not release disk')
            return write(path, payload)
        def resolve(channel):
            entry = self.entry(channel)
            with self.r.state_lock:
                self.r.state.cache[channel] = entry
            return entry
        self.r._meta_debounce = 0
        with mock.patch.object(live, 'atomic_json_write', side_effect=slow_write), \
             mock.patch.object(self.r, 'refresh_channel_controlled', side_effect=resolve):
            try:
                first = self.r.ensure_channel('cctv1')
                self.assertTrue(entered.wait(1))
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    second = pool.submit(self.r.ensure_channel, 'cctv2').result(1)
                self.assertEqual((first.channel, second.channel), ('cctv1', 'cctv2'))
                self.assertTrue(self.r.control_lock.acquire(blocking=False))
                self.r.control_lock.release()
                self.assertTrue(self.r.metadata_writer_snapshot()['pending'])
            finally:
                release.set()
            self.wait_for(lambda: not self.r.metadata_writer_snapshot()['pending'])
        saved = json.loads(Path(self.r.args.meta_json).read_text())['cache_detail']
        self.assertEqual(set(saved), {'cctv1', 'cctv2'})

    def test_request_during_write_is_not_lost(self):
        self.r.state.cache['cctv1'] = self.entry()
        self.r._meta_debounce = 0
        entered, release = threading.Event(), threading.Event()
        self.release_events.append(release)
        write = live.atomic_json_write
        calls = []
        def first_slow_write(path, payload):
            calls.append(set(payload['cache_detail']))
            if len(calls) == 1:
                entered.set()
                release.wait(3)
            return write(path, payload)
        with mock.patch.object(live, 'atomic_json_write', side_effect=first_slow_write):
            self.r.request_meta_write()
            self.assertTrue(entered.wait(1))
            with self.r.state_lock:
                self.r.state.cache['cctv2'] = self.entry('cctv2')
            self.r.request_meta_write()
            release.set()
            self.wait_for(lambda: not self.r.metadata_writer_snapshot()['pending'])
        self.assertEqual(calls, [{'cctv1'}, {'cctv1', 'cctv2'}])

    def test_old_pending_snapshot_cannot_restore_cache_after_identity_rotation(self):
        self.r.state.cache['cctv1'] = self.entry()
        self.r._meta_debounce = 10
        original = live.default_device_state()
        live.save_device_state(self.r.args.device_json, original)
        self.r.request_meta_write()
        self.assertTrue(self.r.rotate_device_on_400('explicit recovery test'))
        # Critical writes are immediate, independent of the batching window.
        self.assertEqual(json.loads(Path(self.r.args.meta_json).read_text())['cache_detail'], {})
        self.assertNotEqual(live.load_device_state(self.r.args.device_json)[0].profile.android_id,
                            original.profile.android_id)
        self.r.close()
        self.assertEqual(json.loads(Path(self.r.args.meta_json).read_text())['cache_detail'], {})

    def test_metadata_error_remains_pending_and_shutdown_retries(self):
        self.r._meta_debounce = 0
        self.r.state.cache['cctv1'] = self.entry()
        with mock.patch.object(live, 'atomic_json_write', side_effect=OSError('disk full')) as write:
            self.r.request_meta_write()
            self.wait_for(lambda: 'disk full' in self.r._worker_error)
            self.assertTrue(self.r.metadata_writer_snapshot()['pending'])
            self.assertIn('disk full', self.r._worker_error)
        self.r.close()
        self.assertFalse(self.r.metadata_writer_snapshot()['pending'])
        self.assertIn('cctv1', json.loads(Path(self.r.args.meta_json).read_text())['cache_detail'])

    def test_rejected_generation_is_saved_and_not_reused_after_restart(self):
        self.session()
        self.r.state.cache['cctv1'] = self.entry()
        with self.r.state_lock:
            self.r._invalidate_session_locked(0)
        self.r.request_meta_write()
        self.r.close()
        restarted = live.Resolver(self.r.args)
        self.addCleanup(restarted.close)
        self.assertFalse(restarted.has_existing_channel_source('cctv1'))
        self.assertIn(7, restarted._rejected_session_generations)

    def test_close_without_requests_does_not_start_writer_and_rejects_late_requests(self):
        with mock.patch.object(self.r, 'write_meta') as write:
            self.r.close()
            self.assertIsNone(self.r._meta_worker)
            self.assertFalse(self.r.request_meta_write())
            write.assert_not_called()


if __name__ == '__main__':
    unittest.main()
