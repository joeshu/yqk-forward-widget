import unittest
from unittest.mock import patch
from migu import native as n, core as m


class LegacyProofTests(unittest.TestCase):
    def test_calendar_and_channel_characters_come_from_issued_url(self):
        auth=n.NativeAuth.load(environ={})
        seed='0123456789abcdef0123456789abcdef'
        # Local wall clock must not change the proof of a URL issued before midnight.
        with patch.object(m,'utcnow',side_effect=AssertionError('wall clock used')):
            proof=n.native_proof(seed,'608807420','20261019235959',auth,3)
        self.assertEqual(''.join(proof[i] for i in (4,7,10,13)),'e180')
        following=n.native_proof(seed,'608807420','20261020000001',auth,3)
        self.assertEqual(''.join(following[i] for i in (4,7,10,13)),'e280')
        self.assertEqual(''.join(n.native_proof(seed,'631780532','20261020000001',auth,3)[i] for i in (4,7,10,13)),'e210')

    def test_odd_seed_preserves_middle_character_once(self):
        auth=n.NativeAuth.load(environ={})
        seed='0123456789abcdef0123456789abcde'
        proof=n.native_proof(seed,'608807420','20261020000001',auth,3)
        base=''.join(char for i,char in enumerate(proof) if i not in {4,7,10,13})
        expected=''.join(seed[-i-1]+seed[i] for i in range(len(seed)//2))+seed[len(seed)//2]
        self.assertEqual(base,expected)
        self.assertEqual(len(base),len(seed))

    def test_anonymous_hd_request_is_allowed_and_server_still_decides_authorization(self):
        auth=n.NativeAuth.load(environ={})
        self.assertEqual(auth.rate_type,3)
        url,headers=n.native_request('608807420',auth,'1234567890000')
        self.assertNotIn('UserToken',headers)
        self.assertNotIn('appCode',headers)
        self.assertIn('rateType=3',url)
        # Public reference has a lower quality exception for Guangdong TV.
        self.assertIn('rateType=2',n.native_request('608831231',auth,'1234567890000')[0])
