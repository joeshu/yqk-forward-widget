from contextlib import redirect_stdout
import io
import json
import threading
import unittest
from unittest.mock import Mock, patch

from migu import service as s
import live_fixture as fixtures
from live_fixture import TOKEN


class DiagnosticsTests(unittest.TestCase):
    def test_ring_and_dedup_are_bounded_and_reject_sensitive_text(self):
        now=[0]; logs=s.Diagnostics(clock=lambda: now[0])
        with redirect_stdout(io.StringIO()) as console:
            logs.record('UPSTREAM_ERROR'); logs.record('UPSTREAM_ERROR')
            logs.record('https://example/?token=secret')
            self.assertEqual(len(logs.snapshot()),2)
            now[0]=16; logs.record('UPSTREAM_ERROR')
            self.assertEqual(len(logs.snapshot()),3)
            for i in range(300): logs.record('ERROR_'+str(i))
        self.assertNotIn('secret',console.getvalue())
        self.assertNotIn('https://',console.getvalue())
        self.assertIn('UNCLASSIFIED_ERROR',console.getvalue())
        self.assertEqual(len(logs.snapshot()),120)
        self.assertEqual(len(logs.last),64)
        snapshot=logs.snapshot(); snapshot.clear()
        self.assertEqual(len(logs.snapshot()),120)

    def test_closed_console_does_not_raise(self):
        logs=s.Diagnostics()
        with patch('builtins.print',side_effect=OSError('closed console')):
            logs.record('UPSTREAM_ERROR')
        self.assertEqual(logs.snapshot()[0]['code'],'UPSTREAM_ERROR')

    def test_app_worker_thread_runs_without_registering_process_signal(self):
        server=Mock(); server.serve_forever.side_effect=KeyboardInterrupt
        results=[]
        with patch.object(s,'BoundedServer',return_value=server), patch.object(s.signal,'signal',side_effect=AssertionError('host signal handler changed')):
            thread=threading.Thread(target=lambda: results.append(s.main([])))
            thread.start(); thread.join(3)
        self.assertEqual(results,[0])
        server.server_close.assert_called_once()


class DiagnosticHttpTests(unittest.TestCase):
    # Reuse the real HTTP fixture without inheriting and duplicating its tests.
    server=fixtures.server
    request=fixtures.request

    def test_diag_has_same_auth_and_host_controls_and_does_not_refresh_source(self):
        with self.server() as (server, service):
            before=service.store.status()['api_requests']
            service.diagnostics.record('UPSTREAM_ERROR')
            code,headers,body=self.request(server,'/diag')
            self.assertEqual(code,200)
            data=json.loads(body)
            self.assertEqual(data['events'][-1]['code'],'UPSTREAM_ERROR')
            self.assertFalse(data['status']['playback_verified'])
            self.assertEqual(service.store.status()['api_requests'],before)
            self.assertEqual(headers['Cache-Control'],'no-store')
            self.assertNotIn(b'source-private',body)
            self.assertEqual(self.request(server,'/diag',headers={'Host':'evil.example'})[0],403)
            self.assertEqual(self.request(server,'/diag',headers={'Origin':'https://evil.example'})[0],403)
        with self.server(require_token=True) as (server, service):
            self.assertEqual(self.request(server,'/diag')[0],401)
            code,_,body=self.request(server,'/diag?token='+TOKEN)
            self.assertEqual(code,200)
            self.assertNotIn(TOKEN.encode(),body)


if __name__=='__main__': unittest.main()
