from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr
import io
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

from migu import core as m
from migu import native as n, service as s


class NativeTests(unittest.TestCase):
    def api(self, response):
        client = Mock()
        client.get.return_value = json.dumps(response).encode(), {}
        factory = Mock(return_value=client)
        return factory, client

    def response(self, url=None):
        return {'code': '200', 'body': {'content': {'contId': '608807420'}, 'urlInfo': {'url': url or 'http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064230&puData=0123456789abcdef0123456789abcdef'}}}

    def test_anonymous_sd_request_no_credentials_and_complete_url_preserved(self):
        url = 'http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=x&sig=a%2Bb'
        factory, client = self.api(self.response(url))
        self.assertEqual(n.native_play_url('608807420', factory), url)
        factory.assert_called_once_with('api', attempts=1, timeout=8, budget=10)
        endpoint = client.get.call_args.args[0]
        query = parse_qs(urlsplit(endpoint).query)
        self.assertEqual(query['rateType'], ['3'])
        self.assertEqual(query['contId'], ['608807420'])
        self.assertEqual(len(query['sign'][0]), 32)
        self.assertNotIn('UserToken', client.get.call_args.kwargs['headers'])
        self.assertNotIn('UserId', client.get.call_args.kwargs['headers'])

    def test_url_challenge_is_appended_without_reordering_original_query(self):
        factory, _ = self.api(self.response())
        url = n.native_play_url('608807420', factory)
        self.assertTrue(url.startswith(self.response()['body']['urlInfo']['url'] + '&ddCalcu='))
        proof = parse_qs(urlsplit(url).query)['ddCalcu'][0]
        expected = ''.join('0123456789abcdef0123456789abcdef'[-i-1] + '0123456789abcdef0123456789abcdef'[i] + {1:'e',2:'2',3:'8',4:'0'}.get(i,'') for i in range(16))
        self.assertEqual(proof, expected)
        self.assertNotIn('&sv=',url)

    def test_denials_bad_json_missing_url_and_untrusted_media_fail_closed(self):
        cases = [({'code':'403','rid':'COPYRIGHT_AREA_INVALID'}, 'MIGU_REGION_RESTRICTED'),
                 ({'code':'200','rid':'TIPS_NEED_MEMBER'}, 'MIGU_MEMBERSHIP_REQUIRED'),
                 ({'code':'200','body':{'urlInfo':{}}}, 'MIGU_PLAY_URL_MISSING'),
                 (self.response('http://127.0.0.1/index.m3u8?puData=abcd'), 'URL_HOST_OR_PORT_NOT_ALLOWED'),
                 (self.response('http://gslbmgsplive.miguvideo.com/live/index.m3u8?puData=weird'), 'MIGU_PLAY_URL_FORMAT_CHANGED')]
        for response, code in cases:
            with self.subTest(code=code):
                factory, _ = self.api(response)
                with self.assertRaisesRegex(m.UpdateError, code):
                    n.native_play_url('608807420', factory)
        factory, client = self.api({})
        client.get.return_value = b'<html>no</html>', {}
        with self.assertRaisesRegex(m.FetchError, 'MIGU_API_FORMAT_CHANGED'):
            n.native_play_url('608807420', factory)

    def test_generic_authorization_failure_is_not_claimed_to_require_membership(self):
        response=self.response('http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=private')
        response['body']['auth']={'authResult':'FAIL','logined':False,'resultDesc':'private description'}
        factory,_=self.api(response)
        with self.assertRaises(n.MiguApiError) as caught:
            n.native_play_url('608807420',factory)
        self.assertEqual(str(caught.exception),'MIGU_AUTHORIZATION_REJECTED')
        details=caught.exception.details
        self.assertEqual(details['api_code'],'200')
        self.assertTrue(details['has_play_url'])
        self.assertFalse(details['logged_in'])
        self.assertNotIn('private',json.dumps(details))

    def test_negative_cache_keeps_safe_upstream_details(self):
        resolver=Mock(side_effect=n.MiguApiError('MIGU_LOGIN_REQUIRED',{'channel_id':'608807420','api_code':'403','rid':'NEED_LOGIN','token':'secret','has_play_url':False}))
        store=n.NativeStore(resolver);self.addCleanup(store.close)
        for _ in range(2):
            with self.assertRaises(n.MiguApiError) as caught:
                store.resolve('p608807420')
            self.assertEqual(caught.exception.details['rid'],'NEED_LOGIN')
            self.assertNotIn('secret',json.dumps(caught.exception.details))
        self.assertEqual(resolver.call_count,1)
        self.assertEqual(store.status()['last_upstream']['rid'],'NEED_LOGIN')

    def test_api_role_restricts_https_host_path_and_redirect(self):
        m.validate_url('https://play.miguvideo.com/playurl/v1/play/playurl?x=1', 'api')
        for url in ['http://play.miguvideo.com/playurl/v1/play/playurl', 'https://play.miguvideo.com/other', 'https://localhost/playurl/v1/play/playurl', 'https://play.miguvideo.com:8080/playurl/v1/play/playurl']:
            with self.assertRaises(m.UpdateError):
                m.validate_url(url, 'api')

    def test_native_http_route_resolves_only_known_channels_and_reports_region_error(self):
        resolver=Mock(side_effect=m.FetchError('MIGU_REGION_RESTRICTED'))
        store=n.NativeStore(resolver)
        service=s.Service(store, '', 'http://127.0.0.1:0', require_token=False)
        server=s.BoundedServer(('127.0.0.1',0), service)
        service.public_base=f'http://127.0.0.1:{server.server_address[1]}'
        thread=threading.Thread(target=server.serve_forever, kwargs={'poll_interval':.01}, daemon=True); thread.start()
        def get(path):
            client=http.client.HTTPConnection(*server.server_address, timeout=2)
            client.request('GET',path); response=client.getresponse(); body=response.read(); client.close()
            return response.status,body
        try:
            self.assertEqual(get('/all.m3u')[0],200)
            self.assertEqual(get('/live/p1.m3u8')[0],404)
            self.assertEqual(get('/live/p608807420.m3u8?playbackbegin=20261019000000&playbackend=20261019001000')[0],400)
            resolver.assert_not_called()
            code,body=get('/live/p608807420.m3u8')
            self.assertEqual(code,403)
            self.assertEqual(json.loads(body),{'error':'MIGU_REGION_RESTRICTED'})
        finally:
            server.shutdown(); server.server_close(); service.close(); thread.join(2)

    def test_builtin_catalogue_requires_neither_network_nor_files_and_has_unique_ids(self):
        store = n.NativeStore(resolver=Mock(side_effect=AssertionError('network')))
        self.addCleanup(store.close)
        snap = store.get()
        self.assertEqual(len(snap.channels), len(n.BUILTIN_CHANNELS))
        self.assertGreater(len(snap.channels), 100)
        service = s.Service(store, '', 'http://127.0.0.1:18768', require_token=False)
        self.addCleanup(service.manifests.close)
        data = service.catalogue(snap)
        self.assertTrue(data.startswith(b'#EXTM3U '))
        self.assertIn(b'/live/p608807420.m3u8', data)
        self.assertNotIn(b'52top', data)
        self.assertNotIn(b'puData', data)
        self.assertNotIn(b'catchup=', data)
        store.resolver.assert_not_called()

    def test_concurrent_requests_share_refresh_and_cache_expires_without_stale_url(self):
        entered, release = threading.Event(), threading.Event()
        now = [0]
        def resolve(pid):
            entered.set()
            release.wait(2)
            return 'signed'
        resolver = Mock(side_effect=resolve)
        store = n.NativeStore(resolver, clock=lambda: now[0]); self.addCleanup(store.close)
        with ThreadPoolExecutor(max_workers=10) as pool:
            requests = [pool.submit(store.resolve, 'p608807420') for _ in range(10)]
            self.assertTrue(entered.wait(1)); release.set()
            self.assertEqual([f.result(3) for f in requests], ['signed'] * 10)
        self.assertEqual(resolver.call_count, 1)
        self.assertEqual(store.resolve('p608807420'), 'signed')
        now[0] = 31
        resolver.side_effect = m.FetchError('MIGU_REGION_RESTRICTED')
        for _ in range(2):
            with self.assertRaisesRegex(m.FetchError, 'MIGU_REGION_RESTRICTED'):
                store.resolve('p608807420')
        self.assertEqual(resolver.call_count, 2)
        now[0] = 37
        with self.assertRaises(m.FetchError): store.resolve('p608807420')
        self.assertEqual(resolver.call_count, 3)


class StartupTests(unittest.TestCase):
    def test_default_native_does_not_touch_disk_or_lock_and_tolerates_signal_failure(self):
        server = Mock()
        server.serve_forever.side_effect = KeyboardInterrupt
        with patch.object(s.Path, 'mkdir', side_effect=PermissionError('readonly')) as mkdir, patch.object(s, 'BoundedServer', return_value=server), patch.object(s.signal, 'signal', side_effect=ValueError('embedded runtime')):
            self.assertEqual(s.main([]), 0)
        mkdir.assert_not_called()
        server.server_close.assert_called_once()

    def test_port_and_directory_errors_identify_stage_without_exposing_sensitive_context(self):
        with redirect_stderr(io.StringIO()) as output, patch.object(s, 'BoundedServer', side_effect=OSError(98, 'secret URL https://private/?token=secret')):
            self.assertEqual(s.main([]), 1)
        self.assertIn('[bind]', output.getvalue())
        self.assertIn('errno=98', output.getvalue())
        self.assertNotIn('secret', output.getvalue())
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'not-directory'; file.write_text('x')
            with redirect_stderr(io.StringIO()) as output:
                self.assertEqual(s.main(['--require-token', '--data-dir', str(file)]), 1)
            self.assertIn('[data-directory]', output.getvalue())

    def test_explicit_symlink_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            link=Path(directory)/'link'; link.symlink_to(directory)
            with self.assertRaisesRegex(s.ServiceError, 'SYMLINK'):
                s.service_data_directory(link)


if __name__ == '__main__': unittest.main()
