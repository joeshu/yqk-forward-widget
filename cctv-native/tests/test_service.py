"""Offline playlist and real loopback HTTP checks; never start the runtime."""

import http.client
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import service


BASE = "https://media.cntv.cn/live/root/index.m3u8?temporary=secret-source-token"


def arguments(**changes):
    values = {"warmup": False, "buffer_mb": 16, "idle_timeout": 120}
    values.update(changes)
    return SimpleNamespace(**values)


class TestPlaylists(unittest.TestCase):
    def test_master_selects_highest_bandwidth_and_resolves_uri(self):
        result = service.parse_playlist(
            "#EXTM3U\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=300000,CODECS=\"avc1.640028\"\nlow/index.m3u8\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=1600000,CODECS=\"avc1.640028\"\n../high/index.m3u8\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"avc1.640028\"\nmedium.m3u8\n",
            BASE,
        )
        self.assertEqual(result, {"variant": "https://media.cntv.cn/live/high/index.m3u8"})

    def test_media_sequence_duration_discontinuity_and_uris(self):
        result = service.parse_playlist(
            "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:100\n"
            "#EXTINF:4.125,first\nfirst.ts\n#EXT-X-DISCONTINUITY\n"
            "#EXTINF:3.75,second\n../second.ts?token=separate\n"
            "#EXTINF:4,third\n/third.ts\n",
            BASE,
        )
        self.assertEqual(
            result["entries"],
            [
                {"seq": 100, "duration": 4.125, "url": "https://media.cntv.cn/live/root/first.ts", "discontinuity": False},
                {"seq": 101, "duration": 3.75, "url": "https://media.cntv.cn/live/second.ts?token=separate", "discontinuity": True},
                {"seq": 102, "duration": 4.0, "url": "https://media.cntv.cn/third.ts", "discontinuity": False},
            ],
        )

    def test_nonfinite_nonpositive_or_excessive_duration_rejected(self):
        for duration in ("0", "-1", "nan", "inf", "-inf", "30.01"):
            with self.subTest(duration=duration), self.assertRaisesRegex(service.NativeError, "segment-duration"):
                service.parse_playlist(f"#EXTM3U\n#EXTINF:{duration},\npart.ts\n", BASE)

    def test_extra_key_and_map_rejected_while_method_none_is_accepted(self):
        for tag, reason in (
            ('#EXT-X-KEY:METHOD=AES-128,URI="key.bin"', "extra-encryption"),
            ('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"', "extra-encryption"),
            ('#EXT-X-MAP:URI="init.mp4"', "media-container"),
        ):
            with self.subTest(tag=tag), self.assertRaisesRegex(service.NativeError, reason):
                service.parse_playlist(f"#EXTM3U\n{tag}\n#EXTINF:4,\npart.ts\n", BASE)
        result = service.parse_playlist("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\npart.ts\n", BASE)
        self.assertEqual(result["entries"][0]["seq"], 0)

    def test_empty_or_oversized_media_playlist_rejected(self):
        for text in ("#EXTM3U\n", "#EXTM3U\n" + "#EXTINF:4,\npart.ts\n" * 65):
            with self.subTest(size=len(text)), self.assertRaisesRegex(service.NativeError, "empty-or-oversized"):
                service.parse_playlist(text, BASE)


class TestEnginePipe(unittest.TestCase):
    def test_engine_broken_pipe_is_not_retryable_upstream_transport(self):
        engine = service.Engine.__new__(service.Engine)
        engine.counter = 0
        engine.process = mock.Mock()
        engine.process.stdin.write.side_effect = BrokenPipeError('closed engine pipe')
        with self.assertRaisesRegex(service.NativeError, '^engine-io-failed$'):
            engine.transform([b'\x09\xf0'])
        engine.process.kill.assert_not_called()


class TestChannelRing(unittest.TestCase):
    def test_transient_playlist_failure_keeps_ready_media_and_reuses_child_url(self):
        from test_pes import stream
        raw, _ = stream()
        channel = service.Channel(arguments())
        channel.started_at = channel.last_request = time.monotonic()
        engine = mock.Mock(transform=mock.Mock(side_effect=lambda values: values))
        child = 'https://media.cntv.cn/live/child.m3u8'
        calls, published = [], []
        def playlist(url):
            calls.append(url)
            if len(calls) == 2:
                self.assertIsNotNone(channel.playlist())
                raise service.HTTPError(BASE, 503, 'temporary', {}, None)
            if len(calls) == 3:
                self.assertIsNotNone(channel.playlist())
                self.assertEqual(channel.last_transport_error, 'http-503')
            start = 0 if len(calls) == 1 else 1
            return ([dict(seq=i, duration=4, url=BASE+str(i), discontinuity=False)
                     for i in range(start, start+3)], child)
        publish = channel.publish
        def capture(body, entry, discontinuity):
            published.append(entry['seq'])
            publish(body, entry, discontinuity)
            if len(published) == 3:
                channel.stop.set()
        with mock.patch.object(service, 'Engine', return_value=engine), \
                mock.patch.object(service, 'source_url', return_value=BASE) as source, \
                mock.patch.object(service, 'media_playlist', side_effect=playlist), \
                mock.patch.object(service, 'get', return_value=(raw, BASE)), \
                mock.patch.object(channel, 'publish', side_effect=capture), \
                mock.patch.object(channel.stop, 'wait', return_value=False):
            channel.run()
        self.assertEqual(published, [0, 1, 2])
        self.assertEqual(calls, [BASE, child, child])
        source.assert_called_once()
        self.assertEqual(channel.transport_retries, 1)
        self.assertEqual(channel.last_transport_error, '')
        self.assertEqual(channel.error, '')

    def test_failed_segment_future_is_downloaded_again(self):
        from test_pes import stream
        raw, _ = stream()
        channel = service.Channel(arguments())
        channel.started_at = channel.last_request = time.monotonic()
        engine = mock.Mock(transform=mock.Mock(side_effect=lambda values: values))
        entries = [dict(seq=i, duration=4, url=BASE+str(i), discontinuity=False) for i in range(3)]
        downloaded = []
        def download(url):
            with channel.condition:
                downloaded.append(url)
                fail = url == entries[0]['url'] and downloaded.count(url) == 1
            if fail:
                raise service.URLError('temporary disconnect')
            return raw, BASE
        publish = channel.publish
        def capture(*args):
            publish(*args)
            if channel.processed == 2:
                channel.stop.set()
        with mock.patch.object(service, 'Engine', return_value=engine), \
                mock.patch.object(service, 'source_url', return_value=BASE), \
                mock.patch.object(service, 'media_playlist', return_value=(entries, BASE)), \
                mock.patch.object(service, 'get', side_effect=download), \
                mock.patch.object(channel, 'publish', side_effect=capture), \
                mock.patch.object(channel.stop, 'wait', return_value=False):
            channel.run()
        self.assertEqual(downloaded.count(entries[0]['url']), 2)
        self.assertEqual(channel.processed, 2)
        self.assertEqual(channel.transport_retries, 1)
        self.assertEqual(channel.error, '')

    def test_persistent_transport_failure_has_a_progress_deadline(self):
        channel = service.Channel(arguments())
        now = [1000.0]
        channel.started_at = channel.last_request = now[0]
        engine = mock.Mock()
        def wait(_seconds):
            now[0] += 31
        with mock.patch.object(service, 'Engine', return_value=engine), \
                mock.patch.object(service, 'source_url', return_value=BASE), \
                mock.patch.object(service, 'media_playlist', side_effect=TimeoutError(BASE)) as playlist, \
                mock.patch.object(service.time, 'monotonic', side_effect=lambda: now[0]), \
                mock.patch.object(channel.stop, 'wait', side_effect=wait), \
                mock.patch('builtins.print') as logged:
            channel.run()
        playlist.assert_called_once()
        self.assertEqual(channel.error, 'source-media-stalled')
        self.assertEqual(channel.transport_retries, 1)
        engine.close.assert_called_once()
        value = channel.snapshot()
        self.assertEqual(value['operation'], 'media-playlist')
        self.assertEqual(value['last_transport_error'], 'TimeoutError')
        self.assertEqual(value['playlist_entries'], 0)
        self.assertEqual(value['last_segment_bytes'], 0)
        lines = ' '.join(str(call.args) for call in logged.call_args_list)
        self.assertIn('diagnostics=', lines)
        self.assertIn('operation=media-playlist cause=TimeoutError', lines)
        self.assertNotIn('secret-source-token', lines)

    def test_two_initial_legacy_handshake_failures_have_short_bounded_delays(self):
        error=service.ssl.SSLError(1,'handshake-failed')
        error.reason='UNSAFE_LEGACY_RENEGOTIATION_DISABLED'
        channel=service.Channel(arguments())
        channel.started_at=channel.last_request=time.monotonic()
        engine=mock.Mock()
        with mock.patch.object(service,'Engine',return_value=engine), \
             mock.patch.object(service,'source_url',side_effect=[service.URLError(error),service.URLError(error),service.NativeError('official-playback-not-permitted')]), \
             mock.patch.object(channel.stop,'wait',return_value=False) as wait, \
             mock.patch('builtins.print'):
            channel.run()
        self.assertEqual([c.args[0] for c in wait.call_args_list],[.15,.30])
        self.assertEqual(channel.error,'official-playback-not-permitted')

    def test_expired_url_refresh_stops_when_official_api_denies_playback(self):
        channel = service.Channel(arguments())
        channel.started_at = channel.last_request = time.monotonic()
        engine = mock.Mock()
        with mock.patch.object(service, 'Engine', return_value=engine), \
                mock.patch.object(service, 'source_url', side_effect=[
                    BASE, service.NativeError('official-playback-not-permitted')]) as source, \
                mock.patch.object(service, 'media_playlist', side_effect=
                    service.HTTPError(BASE, 403, 'expired', {}, None)) as playlist, \
                mock.patch.object(channel.stop, 'wait', return_value=False), \
                mock.patch('builtins.print'):
            channel.run()
        self.assertEqual(source.call_count, 2)
        playlist.assert_called_once()
        self.assertEqual(channel.error, 'official-playback-not-permitted')
        self.assertEqual(channel.transport_retries, 1)
        engine.close.assert_called_once()

    def test_window_gap_resyncs_with_discontinuity_and_updates_every_nal(self):
        from test_pes import stream
        raw, _ = stream()
        channel = service.Channel(arguments())
        channel.started_at = channel.last_request = time.monotonic()
        engine = mock.Mock()
        engine.transform.side_effect = lambda values: values
        def window(start):
            return ([dict(seq=i, duration=4, url=BASE+str(i), discontinuity=False)
                     for i in range(start, start+3)], BASE)
        published = []
        publish = channel.publish
        def capture(body, entry, discontinuity):
            published.append((entry['seq'], discontinuity))
            publish(body, entry, discontinuity)
            if len(published) == 4:
                channel.stop.set()
        with mock.patch.object(service, 'Engine', return_value=engine), \
                mock.patch.object(service, 'source_url', return_value=BASE), \
                mock.patch.object(service, 'media_playlist', side_effect=[window(0), window(5)]), \
                mock.patch.object(service, 'get', return_value=(raw, BASE)), \
                mock.patch.object(channel, 'publish', side_effect=capture), \
                mock.patch.object(channel.stop, 'wait', return_value=False):
            channel.run()
        self.assertEqual(published, [(0, False), (1, False), (5, True), (6, False)])
        self.assertEqual(channel.source_gaps, 1)
        self.assertEqual(channel.error, '')
        for call in engine.transform.call_args_list:
            self.assertEqual([value[0] & 31 for value in call.args[0]], [7, 5, 1, 9])
        engine.close.assert_called_once()

    def test_discontinuity_sequence_survives_window_sliding_and_ring_eviction(self):
        channel = service.Channel(arguments())
        channel.generation = "a" * 32
        channel.started_at = time.monotonic()
        # Cover markers first leaving the six-segment playlist, then the ring.
        expected = {
            6: (1, 0, 1),
            8: (3, 1, 1),
            12: (7, 1, 2),
            16: (11, 2, 1),
            22: (17, 3, 0),
        }
        seen_segment_sequences = {}
        for index in range(23):
            channel.publish(f"segment-{index}".encode(), {"duration": 4}, index in (2, 7, 12))
            if index not in expected:
                continue
            with self.subTest(published=index):
                first, discontinuity_sequence, visible_markers = expected[index]
                lines = channel.playlist().splitlines()
                self.assertIn(f"#EXT-X-MEDIA-SEQUENCE:{first}", lines)
                self.assertIn(f"#EXT-X-DISCONTINUITY-SEQUENCE:{discontinuity_sequence}", lines)
                self.assertEqual(lines.count("#EXT-X-DISCONTINUITY"), visible_markers)
                current_sequence = discontinuity_sequence
                for line in lines:
                    if line == "#EXT-X-DISCONTINUITY":
                        current_sequence += 1
                    elif line.startswith("media/"):
                        # An overlapping segment must retain its absolute
                        # discontinuity number in every playlist snapshot.
                        previous = seen_segment_sequences.setdefault(line, current_sequence)
                        self.assertEqual(current_sequence, previous)

    def test_ready_after_two_segments_and_bounded_live_window(self):
        channel = service.Channel(arguments())
        channel.generation = "a" * 32
        channel.started_at = time.monotonic()
        channel.publish(b"first", {"duration": 4.125}, False)
        self.assertIsNone(channel.playlist())
        self.assertFalse(channel.snapshot()["media_ready"])
        channel.publish(b"second", {"duration": 3.5}, True)
        self.assertEqual(channel.state, "ready")
        self.assertTrue(channel.snapshot()["media_ready"])
        self.assertIn("#EXT-X-TARGETDURATION:5\n", channel.playlist())
        self.assertIn("#EXT-X-DISCONTINUITY\n", channel.playlist())
        for index in range(2, 12):
            channel.publish(f"part-{index}".encode(), {"duration": 4}, False)
        self.assertEqual(channel.processed, 12)
        self.assertEqual(channel.counter, 12)
        self.assertEqual(list(channel.ring), list(range(2, 12)))
        self.assertEqual(channel.size, sum(len(value[0]) for value in channel.ring.values()))
        listing = channel.playlist()
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:6\n", listing)
        self.assertEqual(listing.count("#EXTINF:"), 6)
        self.assertNotIn("secret-source-token", listing)


class TestLocalHTTP(unittest.TestCase):
    def setUp(self):
        self.args = arguments()
        self.channel = service.Channel(self.args)
        self.channel.started_at = time.monotonic()
        self.channel.generation = "a" * 32
        self.channel.demand = mock.Mock(name="demand")
        self.network_guard = mock.patch.object(service, "get", side_effect=AssertionError("offline test attempted upstream I/O"))
        self.network_guard.start()
        self.addCleanup(self.network_guard.stop)
        self.server = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
        self.server.daemon_threads = True
        self.server.args = self.args
        self.server.channel = self.channel
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def request(self, method, path, *, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            body = response.read()
            return response.status, dict(response.getheaders()), body
        finally:
            connection.close()

    def ready(self):
        self.channel.publish(b"synthetic-ts-first", {"duration": 4}, False)
        self.channel.publish(b"synthetic-ts-second", {"duration": 4.2}, False)

    def test_subscription_is_local_and_default_does_not_start_channel(self):
        status, headers, body = self.request("GET", "/all.m3u")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(int(headers["Content-Length"]), len(body))
        self.assertIn(b'tvg-id="CCTV2"', body)
        self.assertIn(f"http://127.0.0.1:{self.server.server_port}/cctv2.m3u8\n".encode(), body)
        self.assertNotIn(b"cntv.cn", body)
        self.channel.demand.assert_not_called()

    def test_head_never_starts_channel_even_when_warmup_enabled(self):
        self.args.warmup = True
        for path in ("/all.m3u", "/cctv2.m3u8", "/status"):
            with self.subTest(path=path):
                status, _, body = self.request("HEAD", path)
                self.assertEqual(status, 200)
                self.assertEqual(body, b"")
        self.channel.demand.assert_not_called()
        self.request("GET", "/all.m3u")
        self.channel.demand.assert_called_once_with()

    def test_post_and_invalid_host_do_not_start_channel(self):
        status, headers, _ = self.request("POST", "/all.m3u")
        self.assertEqual(status, 405)
        self.assertEqual(headers["Cache-Control"], "no-store")
        status, _, _ = self.request("GET", "/all.m3u", headers={"Host": "bad.example/path"})
        self.assertEqual(status, 400)
        self.channel.demand.assert_not_called()

    def test_status_is_uncached_and_does_not_expose_runtime_or_signed_source(self):
        self.channel.upstream_url = BASE
        self.channel.engine = SimpleNamespace(process="private-process", credentials="private-key")
        status, headers, body = self.request("GET", "/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        snapshot = json.loads(body)
        self.assertEqual(snapshot["state"], "idle")
        self.assertFalse(snapshot["media_ready"])
        for private in ("secret-source-token", "private-process", "private-key", "temporary="):
            self.assertNotIn(private, body.decode())
        self.channel.demand.assert_not_called()

    def test_ready_playlist_uses_local_generation_paths(self):
        self.ready()
        status, headers, body = self.request("GET", "/cctv2.m3u8")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn(f"media/{self.channel.generation}/0.ts".encode(), body)
        self.assertIn(b"#EXT-X-MEDIA-SEQUENCE:0", body)
        self.assertNotIn(b"https://", body)
        with self.channel.condition:
            self.assertTrue(self.channel.condition.wait_for(lambda: self.channel.waiters == 0, timeout=1))
        self.channel.demand.assert_called_once_with()

    def test_media_get_is_cached_head_has_no_demand_and_stale_entries_expire(self):
        self.ready()
        current = f"/media/{self.channel.generation}/0.ts"
        status, headers, body = self.request("HEAD", current)
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(int(headers["Content-Length"]), len(b"synthetic-ts-first"))
        self.channel.demand.assert_not_called()
        status, headers, body = self.request("GET", current)
        self.assertEqual(status, 200)
        self.assertEqual(body, b"synthetic-ts-first")
        self.assertEqual(headers["Cache-Control"], "max-age=5")
        self.channel.demand.assert_called_once_with(start=False)
        self.channel.demand.reset_mock()
        for path in (f'/media/{"b" * 32}/0.ts', f"/media/{self.channel.generation}/999.ts"):
            with self.subTest(path=path):
                status, headers, body = self.request("GET", path)
                self.assertEqual(status, 410)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(body, b"expired-media")
        self.channel.demand.assert_not_called()

    def test_failed_channel_returns_immediate_retryable_503(self):
        self.channel.state = "error"
        self.channel.error = "simulated-source-unavailable"
        self.channel.failed_at = time.monotonic()
        status, headers, body = self.request("GET", "/cctv2.m3u8")
        self.assertEqual(status, 503)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Retry-After"], "3")
        self.assertEqual(json.loads(body)["error"], "simulated-source-unavailable")
        with self.channel.condition:
            self.assertTrue(self.channel.condition.wait_for(lambda: self.channel.waiters == 0, timeout=1))

    def test_unknown_route_is_404_without_starting_channel(self):
        status, headers, _ = self.request("GET", "/not-a-route")
        self.assertEqual(status, 404)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.channel.demand.assert_not_called()


if __name__ == "__main__":
    unittest.main()


class TestTransportDiagnostics(unittest.TestCase):
    def test_nested_network_error_reports_type_and_errno_without_address(self):
        error = service.URLError(ConnectionRefusedError(61, BASE))
        self.assertEqual(service.transport_error_code(error), 'URLError:ConnectionRefusedError:errno-61')
        self.assertNotIn('secret-source-token',service.transport_error_code(error))

    def test_text_reason_is_never_forwarded(self):
        self.assertEqual(service.transport_error_code(service.URLError(BASE)), 'URLError')


class TestSourceTLSCompatibility(unittest.TestCase):
    def setUp(self):
        self.policy = mock.patch.object(service, '_API_TLS12_PREFERRED', False)
        self.policy.start()
        self.addCleanup(self.policy.stop)

    URL = 'https://vdnx.live.cntv.cn/api/v3/vdn/live?temporary=secret-source-token'

    def test_ssl_handshake_retry_preserves_verification_request_and_body_limit(self):
        failure = service.URLError(service.ssl.SSLError(1, self.URL))
        first, second = mock.Mock(), mock.Mock()
        first.open.side_effect = failure
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.url = self.URL
        response.read.return_value = b'{}'
        second.open.return_value = response
        with mock.patch.object(service, 'build_opener', side_effect=[first, second]) as build, \
             mock.patch('builtins.print') as logged:
            raw, final = service.get(self.URL, headers={'auth-key':'private-header'},limit=50,timeout=3)
        self.assertEqual((raw,final),(b'{}',self.URL))
        response.read.assert_called_once_with(51)
        self.assertIs(first.open.call_args.args[0],second.open.call_args.args[0])
        self.assertEqual(second.open.call_args.kwargs['timeout'],3)
        handler = build.call_args_list[1].args[1]
        context = handler._context
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode,service.ssl.CERT_REQUIRED)
        self.assertEqual(context.minimum_version,service.ssl.TLSVersion.TLSv1_2)
        self.assertEqual(context.maximum_version,service.ssl.TLSVersion.TLSv1_2)
        logs = str(logged.call_args_list)
        self.assertNotIn('secret-source-token',logs)
        self.assertNotIn('private-header',logs)

    def test_successful_tls12_is_remembered_and_reused_for_next_channel(self):
        first, second, third = mock.Mock(), mock.Mock(), mock.Mock()
        first.open.side_effect = service.URLError(service.ssl.SSLError(1,'handshake-failure'))
        response=mock.MagicMock();response.__enter__.return_value=response
        response.url=self.URL;response.read.return_value=b'{}'
        second.open.return_value=response;third.open.return_value=response
        with mock.patch.object(service,'build_opener',side_effect=[first,second,third]) as build, \
             mock.patch('builtins.print'):
            service.get(self.URL)
            self.assertTrue(service._API_TLS12_PREFERRED)
            service.get(self.URL)
        self.assertEqual(build.call_count,3)
        self.assertEqual(len(build.call_args_list[2].args),2)
        self.assertEqual(build.call_args_list[2].args[1]._context.maximum_version,service.ssl.TLSVersion.TLSv1_2)

    def test_learned_preference_recovers_after_network_changes(self):
        service._API_TLS12_PREFERRED=True
        first,second=mock.Mock(),mock.Mock()
        first.open.side_effect=service.URLError(service.ssl.SSLError(1,'network-changed'))
        response=mock.MagicMock();response.__enter__.return_value=response
        response.url=self.URL;response.read.return_value=b'{}';second.open.return_value=response
        with mock.patch.object(service,'build_opener',side_effect=[first,second]) as build, \
             mock.patch('builtins.print'):
            service.get(self.URL)
        self.assertEqual(len(build.call_args_list[0].args),2)
        self.assertEqual(len(build.call_args_list[1].args),1)
        self.assertFalse(service._API_TLS12_PREFERRED)

    def test_certificate_failure_is_not_given_protocol_retry(self):
        opener=mock.Mock()
        opener.open.side_effect=service.URLError(service.ssl.SSLCertVerificationError(1,'private'))
        with mock.patch.object(service,'build_opener',return_value=opener) as build:
            with self.assertRaises(service.URLError):
                service.get(self.URL)
        self.assertEqual(build.call_count,1)

    def test_other_hosts_and_media_paths_do_not_receive_api_compatibility_policy(self):
        for url in (BASE,'https://vdnx.live.cntv.cn/media/index.m3u8'):
            with self.subTest(url=url):
                opener=mock.Mock()
                opener.open.side_effect=service.URLError(service.ssl.SSLError(1,'private'))
                with mock.patch.object(service,'build_opener',return_value=opener) as build:
                    with self.assertRaises(service.URLError):service.get(url)
                self.assertEqual(build.call_count,1)

    def test_ssl_reason_is_enum_only_and_does_not_forward_exception_text(self):
        error=service.ssl.SSLError(1,self.URL)
        error.library='SSL'
        error.reason='TLSV1_ALERT_INTERNAL_ERROR'
        code=service.transport_error_code(service.URLError(error))
        self.assertIn('library-SSL',code)
        self.assertIn('reason-TLSV1_ALERT_INTERNAL_ERROR',code)
        self.assertNotIn('secret-source-token',code)
        error.reason=self.URL
        self.assertNotIn('secret-source-token',service.transport_error_code(service.URLError(error)))


class TestWebsiteSourceSelection(unittest.TestCase):
    def test_channel_api_receives_correct_official_identifier(self):
        data={'play':'1','manifest':{'hls_cdrm':BASE}}
        with mock.patch.object(service,'get',return_value=(json.dumps(data).encode(),BASE)) as fetch:
            self.assertEqual(service.source_url('cctvjilu'),BASE)
        self.assertIn('channel=cctvjilu&',fetch.call_args.args[0])

    def test_other_channel_denial_is_not_bypassed(self):
        with mock.patch.object(service,'get',return_value=(b'{"play":0}',BASE)):
            with self.assertRaisesRegex(service.NativeError,'official-playback-not-permitted'):
                service.source_url('cctv3')
        with mock.patch.object(service,'get') as fetch:
            with self.assertRaisesRegex(service.NativeError,'unknown-channel'):
                service.source_url('injected-host')
            fetch.assert_not_called()
