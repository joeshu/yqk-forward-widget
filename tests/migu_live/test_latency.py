import http.client
import io
from contextlib import redirect_stdout
import json
import threading
import unittest
from unittest.mock import Mock,patch
from migu import android as a,service as s


class LatencyTests(unittest.TestCase):
    def test_rolling_limit_returns_actual_retry_after_and_releases_at_window_boundary(self):
        clock=[0.0];resolver=Mock(return_value='http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=test')
        store=a.AndroidStore(settings=a.AndroidSettings(),resolver=resolver,clock=lambda:clock[0])
        for index,(pid,_,_) in enumerate(a.BUILTIN_CHANNELS[:30]):
            clock[0]=index;store.resolve('p'+pid)
        clock[0]=45
        service=s.Service(store,'','http://127.0.0.1:0',require_token=False)
        server=s.BoundedServer(('127.0.0.1',0),service)
        service.public_base=f'http://127.0.0.1:{server.server_address[1]}'
        thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
        key='p'+a.BUILTIN_CHANNELS[30][0]
        try:
            client=http.client.HTTPConnection(*server.server_address,timeout=2)
            client.request('GET','/live/'+key+'.m3u8');response=client.getresponse();body=response.read();client.close()
            self.assertEqual(response.status,429)
            self.assertEqual(response.getheader('Retry-After'),'15')
            self.assertEqual(json.loads(body)['error'],'MIGU_RESOLVE_BURST_LIMIT')
            self.assertEqual(resolver.call_count,30)
            self.assertEqual(store.status()['rate_limit_retry_after_seconds'],15)
            clock[0]=60
            store.resolve(key)
            self.assertEqual(resolver.call_count,31)
        finally:
            server.shutdown();server.server_close();service.close();thread.join(2)

    def test_timing_is_bounded_redacted_and_cache_hits_do_not_consume_new_api_requests(self):
        resolver=Mock(return_value='http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=private-signature')
        store=a.AndroidStore(settings=a.AndroidSettings(),resolver=resolver);self.addCleanup(store.close)
        with redirect_stdout(io.StringIO()) as output, patch.object(a.time,'perf_counter',side_effect=[1.0,3.0]):store.resolve('p608807420')
        self.assertEqual(store.status()['recent_resolves'][-1]['elapsed_ms'],2000)
        self.assertIn('MIGU_SLOW_RESOLVE',output.getvalue())
        self.assertNotIn('private-signature',output.getvalue())
        for _ in range(40):store.resolve('p608807420')
        status=store.status()
        self.assertEqual(len(status['recent_resolves']),32)
        self.assertEqual(resolver.call_count,1)
        self.assertEqual(status['cache_hits'],40)
        self.assertNotIn('private-signature',json.dumps(status))
