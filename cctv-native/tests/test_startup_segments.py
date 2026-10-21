import unittest
from types import SimpleNamespace
from test_jscore_service import load_service

class TestStartupSegments(unittest.TestCase):
    def test_only_complete_published_media_can_open_first_playlist(self):
        m=load_service()
        for count in (1,2):
            channel=m.Channel(SimpleNamespace(buffer_mb=32,startup_segments=count,idle_timeout=120))
            channel.started_at=m.time.monotonic()
            self.assertIsNone(channel.playlist())
            channel.publish(b'complete-first',{'duration':4,'seq':0},False)
            if count==1:
                self.assertIsNotNone(channel.playlist())
                self.assertEqual(channel.playlist().count('#EXTINF:'),1)
                self.assertNotIn('#EXT-X-ENDLIST',channel.playlist())
            else:
                self.assertIsNone(channel.playlist())
            channel.publish(b'complete-second',{'duration':4,'seq':1},False)
            self.assertEqual(channel.playlist().count('#EXTINF:'),2)
            self.assertEqual(channel.snapshot()['startup_segments'],count)
