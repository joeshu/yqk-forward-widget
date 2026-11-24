import http.client
import json
import os
import pathlib
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins'))
sys.path.insert(0, str(ROOT / 'Scripts'))

from host_media_relay import MediaRelay, _drop_spliced_ad_segments, scoped_headers
import host_service_runtime


class Round42P0FixesTests(unittest.TestCase):
    # --- P0-1: Cicada VOD vs live buffer classification ---
    def test_p0_1_cicada_adapter_vod_not_misclassified_as_live(self):
        header = (ROOT / 'Sources/MediaPlaybackCicadaAdapter.h').read_text(encoding='utf-8')
        impl = (ROOT / 'Sources/MediaPlaybackCicadaAdapter.m').read_text(encoding='utf-8')
        live_caller = (ROOT / 'Sources/RootViewController+Playback.m').read_text(encoding='utf-8')
        vod_caller = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text(encoding='utf-8')

        self.assertIn('@property (nonatomic) BOOL liveStreamHint;', header)
        self.assertIn('BOOL isLikelyLive=self.liveStreamHint||urlLooksLive||(self.preparedReported&&self.duration<=0);', impl)
        self.assertIn('CicadaCallVoidInt(self.config,NSSelectorFromString(@"setMaxDelayTime:"),0);', impl)
        self.assertIn('self.preparedReported = YES;\n    [self updateBufferConfiguration];', impl)
        self.assertIn('adapter.liveStreamHint=!self.remoteCatchupActive;', live_caller)
        self.assertIn('adapter.liveStreamHint=[result[@"isLive"] boolValue];', vod_caller)

    # --- P0-2: Cross-origin anti-hotlink Referer/Origin preserved, credentials stripped ---
    def test_p0_2_cross_origin_preserves_referer_origin_and_strips_credentials(self):
        headers = {
            'Authorization': 'Bearer secret',
            'Cookie': 'sid=secret',
            'X-Auth': 'secret',
            'User-Agent': 'CCTVHost/1',
            'Referer': 'https://player.example.com/',
            'Origin': 'https://player.example.com',
            'Range': 'bytes=0-1023',
        }
        origin = ('https', 'api.example.com:443')
        cross = scoped_headers(headers, origin, 'https://cdn-edge.othercdn.net/seg01.ts')
        self.assertEqual(cross.get('Referer'), 'https://player.example.com/')
        self.assertEqual(cross.get('Origin'), 'https://player.example.com')
        self.assertEqual(cross.get('User-Agent'), 'CCTVHost/1')
        self.assertEqual(cross.get('Range'), 'bytes=0-1023')
        self.assertNotIn('Authorization', cross)
        self.assertNotIn('Cookie', cross)
        self.assertNotIn('X-Auth', cross)

        objc_headers = (ROOT / 'Sources/MediaPlaybackHeaders.m').read_text(encoding='utf-8')
        self.assertIn('@"origin",@"range",@"referer",@"user-agent"', objc_headers)
        webview = (ROOT / 'Sources/MediaWebViewController.m').read_text(encoding='utf-8')
        self.assertIn('headers[@"Referer"]=referer.URL.absoluteString;', webview)

    # --- P0-3: HLS ad filter scopes pre-roll #EXT-X-KEY to first block & removes spliced ads ---
    def test_p0_3_hls_ad_filter_drops_preroll_ad_key_without_polluting_content(self):
        preroll = [
            '#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:6',
            '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.test/ads/ad.key"',
            '#EXTINF:5.0,', 'https://cdn.test/ads/pre0.ts',
            '#EXTINF:5.0,', 'https://cdn.test/ads/pre1.ts',
            '#EXT-X-DISCONTINUITY',
        ]
        for i in range(24):
            preroll += ['#EXTINF:5.0,', f'https://cdn.test/main/seg{i:02d}.ts']
        preroll.append('#EXT-X-ENDLIST')
        cleaned_pre, dropped_pre = _drop_spliced_ad_segments('\n'.join(preroll), 'https://cdn.test/index.m3u8')
        self.assertEqual(dropped_pre, 2)
        self.assertNotIn('ad.key', cleaned_pre)
        self.assertNotIn('#EXT-X-DISCONTINUITY', cleaned_pre)

    # --- P0-4: Raw progressive .ts / mpegts routed directly to Cicada ---
    def test_p0_4_raw_progressive_ts_prefers_cicada(self):
        router = (ROOT / 'Sources/MediaPlaybackDecodeRouter.m').read_text(encoding='utf-8')
        self.assertIn('@"rtmp", @"mpegts"', router)
        self.assertIn('BOOL rawProgressiveTS = ([urlExt isEqualToString:@"ts"]', router)
        self.assertIn('probedCicadaOnly || rawProgressiveTS', router)

    # --- P0-5: Atomic Python socket rebind & Node foreground self-healing ---
    def test_p0_5_python_atomic_rebind_and_node_foreground_rebind(self):
        class DummyServer(socketserver.TCPServer):
            allow_reuse_address = True

        srv = DummyServer(('127.0.0.1', 0), socketserver.BaseRequestHandler)
        try:
            port = srv.server_address[1]
            host_service_runtime._rebind_server_socket(srv)
            self.assertEqual(srv.server_address[1], port)
            self.assertGreaterEqual(srv.socket.fileno(), 0)
            self.assertNotEqual(srv.socket.fileno(), -1)
        finally:
            srv.server_close()

        # Verify Node control server rebinds on .rebind trigger file
        with tempfile.TemporaryDirectory() as tmp:
            info_path = os.path.join(tmp, 'node.json')
            token = 'test-token-r42'
            proc = subprocess.Popen(
                ['node', str(ROOT / 'Plugins/node-plugin-host.cjs'), info_path, token, tmp],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.time() + 5.0
                while time.time() < deadline and not os.path.exists(info_path):
                    time.sleep(0.05)
                self.assertTrue(os.path.exists(info_path))
                initial = json.loads(pathlib.Path(info_path).read_text(encoding='utf-8'))
                self.assertGreater(initial['port'], 0)
                first_stamp = initial.get('reboundAt', 0)

                time.sleep(0.02)
                pathlib.Path(info_path + '.rebind').write_text(str(time.time()), encoding='utf-8')
                deadline = time.time() + 3.0
                rebound = initial
                while time.time() < deadline:
                    try:
                        cur = json.loads(pathlib.Path(info_path).read_text(encoding='utf-8'))
                        if cur.get('reboundAt', 0) != first_stamp:
                            rebound = cur
                            break
                    except Exception:
                        pass
                    time.sleep(0.05)
                self.assertNotEqual(rebound.get('reboundAt', 0), first_stamp)
                conn = http.client.HTTPConnection('127.0.0.1', rebound['port'], timeout=2)
                conn.request('GET', '/health', headers={'X-CCTVHost-Token': token})
                resp = conn.getresponse()
                self.assertEqual(resp.status, 200)
                conn.close()
            finally:
                proc.terminate()
                proc.wait(timeout=3)

        pyhost = (ROOT / 'Sources/PyHost.m').read_text(encoding='utf-8')
        node_rt = (ROOT / 'Sources/NodePluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn('[NodePluginRuntime.shared refreshListenersAfterForeground];', pyhost)
        self.assertIn('triggerControlRebindSynchronously', node_rt)
        self.assertIn('statusCode==503', node_rt)

    # --- P0-6: MediaRelay keep-alive & bounded warmup executor + Python bounded semaphores ---
    def test_p0_6_relay_keepalive_and_bounded_semaphores(self):
        class MockHandler:
            protocol_version = 'HTTP/1.1'
            request_version = 'HTTP/1.1'
            headers = {'Connection': 'keep-alive'}

        self.assertEqual(MediaRelay._connection_header(MockHandler(), True), 'keep-alive')
        self.assertEqual(MediaRelay._connection_header(MockHandler(), False), 'close')

        relay = MediaRelay()
        ex = relay._get_warmup_executor()
        self.assertIsNotNone(ex)
        relay.close()
        self.assertIsNone(relay._warmup_executor)

        rt = (ROOT / 'Scripts/host_service_runtime.py').read_text(encoding='utf-8')
        self.assertIn('slots.acquire(timeout=1.5)', rt)
        self.assertIn('owner.response_read_slots.acquire(timeout=4.0)', rt)
        self.assertIn('HTTP/1.1 503 Service Unavailable', rt)

    # --- P0-7: Deterministic .pyc precompilation in ci-build.sh ---
    def test_p0_7_ci_build_precompiles_pyc(self):
        ci = (ROOT / 'Scripts/ci-build.sh').read_text(encoding='utf-8')
        self.assertIn('python3 -m compileall -q -f --invalidation-mode unchecked-hash', ci)

    # --- P0-8: RootVC fullscreen/dock/miniBar, swipe-back on Detail/Episode, PlaybackInfo redaction ---
    def test_p0_8_ui_dock_fullscreen_swipeback_and_redaction(self):
        root_vc = (ROOT / 'Sources/RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('self.table.hidden=YES;', root_vc)
        self.assertIn('self.liveMiniPlayerBar.hidden=YES;', root_vc)
        self.assertIn('self.bottomBar.frame=CGRectMake(dockX+4,tabY+2,MAX(0,dockWidth-8),tabHeight-4);', root_vc)
        self.assertIn('if(showMiniBar)[self.view bringSubviewToFront:self.liveMiniPlayerBar];', root_vc)

        browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('@interface MediaDetailViewController () <UIGestureRecognizerDelegate>', browser)
        self.assertIn('self.navigationController.interactivePopGestureRecognizer', browser)

        episode = (ROOT / 'Sources/MediaEpisodeSelectionViewController.m').read_text(encoding='utf-8')
        self.assertIn('UIGestureRecognizerDelegate', episode)
        self.assertIn('self.navigationController.interactivePopGestureRecognizer', episode)

        info_vc = (ROOT / 'Sources/PlaybackInfoViewController.m').read_text(encoding='utf-8')
        self.assertIn('UIPasteboard.generalPasteboard.string = [HostLogRedactor redactText:line];', info_vc)
        self.assertIn('[HostLogRedactor redactText:(value.length ? value : title)]', info_vc)


if __name__ == '__main__':
    unittest.main()
