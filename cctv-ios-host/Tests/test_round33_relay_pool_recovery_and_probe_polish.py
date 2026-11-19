import http.client
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PLUGINS_DIR = str(ROOT / "Plugins")
if PLUGINS_DIR not in sys.path:
    sys.path.insert(0, PLUGINS_DIR)

import host_media_relay


class _FakeSock:
    def __init__(self, fd=10):
        self._fd = fd
        self.closed = False

    def fileno(self):
        return -1 if self.closed else self._fd

    def settimeout(self, t):
        pass


class _FakeConn:
    def __init__(self, host=""):
        self.host = host
        self.sock = _FakeSock()
        self.closed = False
        self._HTTPConnection__response = None

    def close(self):
        self.closed = True
        self.sock.closed = True


class TestRound33RelayPoolRecoveryAndProbePolish(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_upstream_connection_pool_evicts_excess_hosts_and_closes_sockets(self):
        pool = host_media_relay.UpstreamConnectionPool(max_per_host=2, idle_timeout=45.0, max_hosts=4)
        conns = []
        for i in range(6):
            c = _FakeConn(f"cdn{i}.example.com")
            conns.append(c)
            pool.release(("https", f"cdn{i}.example.com", 0), c)
        self.assertLessEqual(len(pool._pools), 4)
        self.assertTrue(conns[0].closed)
        self.assertTrue(conns[1].closed)
        self.assertFalse(conns[-1].closed)

    def test_open_with_timeout_retry_recovers_from_keepalive_remote_disconnected(self):
        calls = []

        class _FakeResp:
            pass

        class _FakeOpener:
            def open(self, req, timeout=8):
                calls.append(timeout)
                if len(calls) == 1:
                    raise http.client.RemoteDisconnected("Remote end closed connection without response")
                return _FakeResp()

        req = urllib.request.Request("https://cdn.example.com/live/stream.m3u8", method="GET")
        with patch.object(host_media_relay, "_DEFAULT_OPENER", _FakeOpener()):
            resp = host_media_relay._open_with_timeout_retry(req, diagnostic_id="r33-keepalive-test")
        self.assertIsInstance(resp, _FakeResp)
        self.assertEqual(calls, [8, 6])

    def test_media_playback_common_modes_weak_self_and_channel_probe_main_thread(self):
        pb = self._read("Sources/MediaPlaybackViewController.m")
        self.assertIn("[NSRunLoop.mainRunLoop addTimer:self.mediaSleepTimer forMode:NSRunLoopCommonModes];", pb)
        self.assertIn("[NSRunLoop.mainRunLoop addTimer:self.avFirstFrameTimer forMode:NSRunLoopCommonModes];", pb)
        self.assertIn("if(!NSThread.isMainThread){NSNotification *note=notification;__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf playerItemEnded:note];});return;}", pb)
        self.assertIn("if(!NSThread.isMainThread){NSNotification *note=notification;__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf playerItemFailed:note];});return;}", pb)

        probe = self._read("Sources/MediaChannelProbe.m")
        self.assertIn("- (void)dealloc {[self cancel];}", probe)
        self.assertIn("if(completion){if(NSThread.isMainThread)completion(result);else dispatch_async(dispatch_get_main_queue(),^{completion(result);});}", probe)


if __name__ == "__main__":
    unittest.main()
