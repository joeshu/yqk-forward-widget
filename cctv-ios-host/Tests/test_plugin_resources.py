"""Exercise resource limits with real TCP sockets and controlled registration failures."""
import socket
import threading
import time
import unittest
from unittest.mock import Mock, patch
from test_plugin_http import plugin


class PluginResourceTests(unittest.TestCase):
    def test_zero_budget_disables_cache_and_small_entries_are_bounded(self):
        cache = plugin.TsSegmentCache(max_mb=0)
        cache.set('empty', b'', {})
        cache.set('data', b'x', {})
        self.assertEqual(cache.stats()['count'], 0)
        cache = plugin.TsSegmentCache(max_mb=1)
        for i in range(1000):
            cache.set(str(i), b'x', {})
        self.assertEqual(cache.stats()['count'], 512)
        self.assertIsNone(cache.get('0'))
        cache.clear()
        self.assertEqual(cache.curr_bytes, 0)
        self.assertEqual(len(cache.order), 0)

    def test_slow_clients_are_bounded_and_workers_recover(self):
        class Server(plugin.BoundedHTTPServer):
            max_workers = 2
            client_timeout = .15
        server = Server(('127.0.0.1', 0), plugin.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        sockets = []
        try:
            for _ in range(2):
                client = socket.create_connection(server.server_address, timeout=2)
                sockets.append(client)
                client.sendall(b'GET /health HTTP/1.0\r\n')  # Deliberately incomplete headers.
            deadline = time.monotonic() + 1
            while server.worker_slots._value and time.monotonic() < deadline:
                time.sleep(.005)
            extra = socket.create_connection(server.server_address, timeout=2)
            sockets.append(extra)
            self.assertIn(b'503', extra.recv(1024))
            deadline = time.monotonic() + 2
            while server.worker_slots._value != 2 and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertEqual(server.worker_slots._value, 2)
            client = socket.create_connection(server.server_address, timeout=2)
            sockets.append(client)
            client.sendall(b'GET /all.m3u HTTP/1.0\r\n\r\n')
            self.assertIn(b'200', client.recv(1024))
        finally:
            for client in sockets:
                client.close()
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_registration_enters_cooldown_and_stop_interrupts_retry(self):
        stop = threading.Event()
        waits = []
        def wait(seconds):
            waits.append(seconds)
            if len(waits) == 3:
                stop.set()
            return stop.is_set()
        resolver = Mock()
        resolver.ensure_slot_session.side_effect = RuntimeError('empty guid')
        with patch.object(plugin, 'resolver', resolver), patch.object(plugin, 'service_stop', stop), \
             patch.object(stop, 'wait', side_effect=wait), patch.object(plugin, 'log'), \
             patch.object(plugin, 'set_resolver_ready'):
            plugin.init_resolver()
        self.assertEqual(resolver.ensure_slot_session.call_count, 3)
        self.assertEqual(waits, [15, 22.5, 300])

    def test_stopped_service_does_not_spawn_channel_refresh(self):
        stop = threading.Event()
        stop.set()
        action = Mock()
        with patch.object(plugin, 'service_stop', stop):
            plugin.coalesce_refresh('stopped-test', action, timeout=0)
        action.assert_not_called()
