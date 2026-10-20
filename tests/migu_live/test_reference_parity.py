"""Contract tests against public reference e475b2f; all inputs are synthetic."""
import hashlib
import json
import unittest
from unittest.mock import Mock,patch
from urllib.parse import parse_qs,urlsplit
from migu import android as a, native as n, core as m


class ReferenceParityTests(unittest.TestCase):
    def run_payload(self,payload,settings=None):
        client=Mock();client.get.return_value=(json.dumps(payload).encode(),{})
        return a.android_play_url('631780532',settings or a.AndroidSettings(),Mock(return_value=client)),client

    def payload(self,url=None):
        return {'code':'200','rid':'SUCCESS','body':{'content':{'contId':'631780532'},'urlInfo':{'url':url or 'http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064125&ProgramID=631780532&puData=0123456789abcdef0123456789abcdef','rateType':3}}}

    def test_guest_hd_uses_legacy_720p_but_sd_uses_modern_without_account(self):
        _,client=self.run_payload(self.payload())
        self.assertEqual(client.get.call_args.kwargs['headers']['AppVersion'],'2600034600')
        self.assertTrue(parse_qs(urlsplit(client.get.call_args.args[0]).query)['salt'][0].endswith('25'))
        _,client=self.run_payload(self.payload(),a.AndroidSettings(rate_type=2,user_id='123456789',token='test-token'))
        self.assertEqual(client.get.call_args.kwargs['headers']['AppVersion'],'2600037000')
        self.assertNotIn('UserToken',client.get.call_args.kwargs['headers'])
        self.assertEqual(parse_qs(urlsplit(client.get.call_args.args[0]).query)['rateType'],['2'])

    def test_modern_header_and_eight_digit_signature_version_are_distinct(self):
        with patch.object(a.time,'time',return_value=1234567890):
            url,headers=a.playurl_request('631780532',3)
        inner=hashlib.md5(b'123456789000063178053226000370').hexdigest()
        expected=hashlib.md5((inner+a.MODERN_SUFFIX).encode()).hexdigest()
        self.assertEqual(parse_qs(urlsplit(url).query)['sign'],[expected])
        self.assertEqual(headers['AppVersion'],'2600037000')

    def test_complete_signed_address_is_preserved_byte_for_byte(self):
        url='http://gslbmgsplive.miguvideo.com/live/index.m3u8?ProgramID=631780532&sig=a%2Bb&ddCalcu=already&sv=10004&ct=android'
        actual,_=self.run_payload(self.payload(url))
        self.assertEqual(actual,url)
        self.assertEqual(actual.count('ddCalcu='),1)

    def test_wrong_channel_malformed_payload_and_conflicting_directives_are_rejected(self):
        wrong=self.payload();wrong['body']['content']['contId']='608807420'
        for payload in (wrong, {'rid':'SUCCESS','body':[]},self.payload('http://gslbmgsplive.miguvideo.com/live/index.m3u8?ProgramID=608807420&ddCalcu=x'),self.payload('http://gslbmgsplive.miguvideo.com/live/index.m3u8?puData=abcdef&timestamp=20261020064125&ct=unknown')):
            with self.subTest(payload_type=type(payload.get('body')).__name__):
                with self.assertRaises(m.UpdateError):self.run_payload(payload)

    def test_odd_seed_center_is_not_duplicated_and_timestamp_is_from_url(self):
        proof=a.dd_calcu('0123456789abcdef0123456789abcde','631780532',3,legacy=True,timestamp='20460101000000')
        self.assertEqual(len(proof),35)
        self.assertEqual(proof[-1],'f')
        self.assertEqual(proof[7],a.ANDROID_KEYS[4])

    def test_higher_tier_refusal_has_one_total_budget_and_never_repeats_a_tier(self):
        client=Mock();client.get.side_effect=[(json.dumps({'rid':'TIPS_NEED_MEMBER','body':{'urlInfo':{'rateType':3}}}).encode(),{}),(json.dumps(self.payload()).encode(),{})]
        a.android_play_url('631780532',a.AndroidSettings(user_id='123456789',token='test-token',rate_type=4),Mock(return_value=client))
        self.assertEqual([parse_qs(urlsplit(c.args[0]).query)['rateType'][0] for c in client.get.call_args_list],['4','3'])
        client=Mock();client.get.return_value=(json.dumps({'rid':'TIPS_NEED_MEMBER'}).encode(),{})
        with self.assertRaises(a.MiguApiError):a.android_play_url('631780532',a.AndroidSettings(),Mock(return_value=client))
        self.assertEqual(client.get.call_count,1)

    def test_identity_profile_mismatch_and_credentials_are_not_exposed(self):
        with self.assertRaisesRegex(m.UpdateError,'PROFILE_MISMATCH'):a.AndroidSettings.load({'MIGU_APP_VERSION':'2600000900'})
        settings=a.AndroidSettings.load({'MIGU_USER_ID':'123456789','MIGU_USER_TOKEN':'synthetic-token'})
        self.assertNotIn('synthetic-token',repr(settings))
        with self.assertRaises(m.UpdateError):a.AndroidSettings.load({'MIGU_USER_ID':'123456789','MIGU_USER_TOKEN':'非ASCII'})

    def test_native_unknown_refusal_with_url_is_not_treated_as_guest_success(self):
        payload=self.payload();payload['rid']='SOME_NEW_DENIAL'
        client=Mock();client.get.return_value=(json.dumps(payload).encode(),{})
        with self.assertRaises(n.MiguApiError):n.native_play_url('631780532',Mock(return_value=client))
