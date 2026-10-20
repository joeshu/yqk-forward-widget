"""Expected hashes captured from the reviewed upstream JavaScript, not our formulas."""
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import Mock,patch
from migu import android as a


class ReferenceGeneratedTests(unittest.TestCase):
    def test_requests_and_playback_urls_match_reference_generated_cases(self):
        record=json.loads(Path(__file__).with_name('reference_cases.json').read_text())
        digest=lambda text:hashlib.sha256(text.encode()).hexdigest()
        for case in record['cases']:
            with self.subTest(case=case['name']):
                settings=a.AndroidSettings(user_id='123456789' if case['account'] else '',token='synthetic-token' if case['account'] else '',rate_type=case['requested'])
                payload={'code':'200','rid':'SUCCESS','body':{'content':{'contId':case['pid']},'urlInfo':{'url':'http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064125&ProgramID='+case['pid']+'&puData=0123456789abcdef0123456789abcdef','rateType':case['returned']}}}
                client=Mock();client.get.return_value=(json.dumps(payload).encode(),{})
                with patch.object(a.time,'time',return_value=case['timestamp_ms']/1000),patch.object(a.random,'randint',return_value=case['salt_prefix']):
                    actual=a.android_play_url(case['pid'],settings,Mock(return_value=client))
                request=client.get.call_args
                headers=sorted([[k.lower(),str(v)] for k,v in request.kwargs['headers'].items() if k.lower() not in {'user-agent','accept'}])
                self.assertEqual(digest(request.args[0]),case['request_hash'])
                self.assertEqual(digest(json.dumps(headers,separators=(',',':'))),case['headers_hash'])
                self.assertEqual(digest(actual),case['stream_hash'])
