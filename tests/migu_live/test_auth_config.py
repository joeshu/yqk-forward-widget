import hashlib
import json
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

from migu import native as n, service as s


class AuthConfigTests(unittest.TestCase):
    def auth(self, **changes):
        return n.NativeAuth.load({**n.NATIVE_SETTINGS, **changes}, environ={})

    def test_default_startup_uses_android_without_external_list(self):
        server = Mock()
        server.serve_forever.side_effect = KeyboardInterrupt
        store = Mock()
        store.provider = 'migu-android'
        store.get.return_value = Mock(channels={})
        with patch.object(s, 'AndroidStore', return_value=store) as selected, patch.object(s, 'ListStore', side_effect=AssertionError('external list selected')), patch.object(s, 'NativeStore', side_effect=AssertionError('experimental API selected')), patch.object(s, 'BoundedServer', return_value=server):
            self.assertEqual(s.main([]), 0)
        selected.assert_called_once_with()

    def test_changed_protocol_settings_are_used_and_credentials_are_headers_only(self):
        auth = self.auth(app_version='2600099900', client_channel='test-channel', sign_salt='1111111', sign_suffix='test-protocol-key', user_id='123456789', user_token='test-account-token', rate_type=3)
        url, headers = n.native_request('608807420', auth, '1234567890000')
        query = parse_qs(urlsplit(url).query)
        inner = hashlib.md5(b'123456789000060880742026000999').hexdigest()
        self.assertEqual(query['sign'], [hashlib.md5((inner+'test-protocol-key').encode()).hexdigest()])
        self.assertEqual(query['salt'], ['1111111'])
        self.assertEqual(query['rateType'], ['3'])
        self.assertEqual(headers['AppVersion'], '2600099900')
        self.assertEqual(headers['UserToken'], 'test-account-token')
        self.assertEqual(headers['UserId'], '123456789')
        self.assertNotIn('test-account-token', url)
        self.assertNotIn('test-account-token', repr(auth))

    def test_partial_credentials_bad_headers_and_unknown_configuration_fail_before_network(self):
        for changes in ({'user_id':'123456789'}, {'user_token':'test-token'}, {'user_id':'123456789','user_token':'bad\r\nInjected:yes'}, {'dd_timestamp_index':14}, {'unexpected':'value'}):
            with self.subTest(fields=list(changes)):
                with self.assertRaises(ValueError):
                    self.auth(**changes)
        auth=n.NativeAuth.load({**n.NATIVE_SETTINGS,'user_id':'123456789','user_token':'old-token'},environ={'MIGU_USER_TOKEN':'new-token'})
        self.assertEqual(auth.user_token,'new-token')

    def test_account_denial_serves_guest_address_without_leaking_credentials(self):
        auth=self.auth(user_id='123456789',user_token='test-account-token',rate_type=3)
        client=Mock()
        client.get.return_value=(json.dumps({'code':'200','rid':'SUCCESS','body':{'auth':{'authResult':'FAIL','logined':True},'urlInfo':{'url':'http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=secret'}}}).encode(),{})
        self.assertEqual(n.native_play_url('608807420',Mock(return_value=client),auth=auth),
                         'http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=secret')
        denied=n.MiguApiError('MIGU_AUTHORIZATION_REJECTED',{'channel_id':'608807420','has_play_url':False})
        store=n.NativeStore(resolver=Mock(side_effect=denied),auth=auth)
        self.addCleanup(store.close)
        with self.assertRaises(n.MiguApiError):store.resolve('p608807420')
        status=json.dumps(store.status())
        for secret in ('test-account-token','123456789','ddCalcu','sign_suffix'):
            self.assertNotIn(secret,status)
        self.assertEqual(store.status()['authorization'],'configured-account')

    def test_proof_uses_returned_quality_not_requested_quality(self):
        auth=self.auth(user_id='123456789',user_token='test-account-token',rate_type=3,dd_keys='cdabyzwxkl',dd_anonymous_word='v',dd_timestamp_index=0,dd_program_index=6,dd_tail='a',dd_suffix='&sv=10004&ct=android')
        seed='0123456789abcdef0123456789abcdef'
        def resolve(rate):
            client=Mock()
            client.get.return_value=(json.dumps({'code':'200','body':{'content':{'contId':'608807420'},'urlInfo':{'url':'http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064230&puData='+seed,'rateType':rate}}}).encode(),{})
            return parse_qs(urlsplit(n.native_play_url('608807420',Mock(return_value=client),auth=auth)).query)['ddCalcu'][0]
        self.assertEqual(resolve(2)[4],'v')
        self.assertEqual(resolve(3)[4],auth.dd_keys[8])
