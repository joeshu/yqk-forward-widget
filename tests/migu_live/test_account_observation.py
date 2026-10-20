import json
import unittest
from unittest.mock import Mock
from migu import android as a


class AccountObservationTests(unittest.TestCase):
    def payload(self,logged=False,rate=2,trial=60):
        return {'code':'200','rid':'SUCCESS','body':{'auth':{'authResult':'FAIL' if not logged else 'SUCCESS','logined':logged},'content':{'contId':'631780532'},'urlInfo':{'url':'http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=already','rateType':rate,'trySeeDuration':trial}}}

    def test_account_rejection_and_recovery_are_observed_from_playback_without_extra_calls(self):
        clock=[0];settings=a.AndroidSettings(user_id='123456789',token='synthetic-account-token')
        client=Mock();client.get.side_effect=[(json.dumps(self.payload()).encode(),{}),(json.dumps(self.payload(True,3,0)).encode(),{})]
        def resolver(pid):return a.android_play_url(pid,settings,Mock(return_value=client),observer=store._observe)
        store=a.AndroidStore(settings,resolver,clock=lambda:clock[0]);self.addCleanup(store.close)
        self.assertEqual(store.status()['credential_state'],'unchecked')
        store.resolve('p631780532')
        status=store.status();self.assertEqual(status['credential_state'],'not_recognized')
        self.assertEqual(status['upstream_observation']['actual_quality'],2)
        self.assertEqual(status['upstream_observation']['trial_seconds'],60)
        store.resolve('p631780532');self.assertEqual(client.get.call_count,1)
        for secret in ('123456789','synthetic-account-token','ddCalcu','already'):
            self.assertNotIn(secret,json.dumps(status))
        clock[0]=a.CACHE_SUCCESS+1;store.resolve('p631780532')
        self.assertEqual(store.status()['credential_state'],'accepted')
        self.assertEqual(client.get.call_count,2)

    def test_sd_does_not_mislabel_unsubmitted_account_as_expired(self):
        observations=[];settings=a.AndroidSettings(user_id='123456789',token='synthetic-account-token',rate_type=2)
        client=Mock();client.get.return_value=(json.dumps(self.payload()).encode(),{})
        a.android_play_url('631780532',settings,Mock(return_value=client),observer=observations.append)
        self.assertFalse(observations[0]['account_sent'])
        self.assertNotIn('UserToken',client.get.call_args.kwargs['headers'])
        self.assertEqual(client.get.call_args.kwargs['headers']['User-Agent'],'node-fetch')
        self.assertEqual(client.get.call_args.kwargs['headers']['Accept'],'*/*')

    def test_untrusted_response_text_never_becomes_diagnostic_data(self):
        observations=[];payload=self.payload();payload['rid']='https://private.invalid/?token=secret';payload['body']['urlInfo']['trySeeDuration']='https://private.invalid/secret'
        client=Mock();client.get.return_value=(json.dumps(payload).encode(),{})
        with self.assertRaises(a.MiguApiError):a.android_play_url('631780532',a.AndroidSettings(),Mock(return_value=client),observer=observations.append)
        self.assertNotIn('private',json.dumps(observations))
        self.assertEqual(observations[0]['rid'],'UNKNOWN')
        self.assertIsNone(observations[0]['trial_seconds'])
