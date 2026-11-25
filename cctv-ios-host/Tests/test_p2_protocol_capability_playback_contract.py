"""源码契约：点播播放器接入协议能力表时保持路由与直播隔离。"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


class ProtocolCapabilityPlaybackContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
        cls.root = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")

    def test_capability_is_queried_before_route_selection(self):
        self.assertIn('#import "MediaProtocolCapabilities.h"', self.playback)
        query = self.playback.index("MediaProtocolCapabilityStatusForURL(sourceURL?:url)")
        route = self.playback.index("MediaPlaybackDecodeRoute initialRoute=[self.playbackSession nextRouteForResult:result];")
        self.assertLess(query, route)
        self.assertIn('recordEvent:@"protocol_capability" category:@"playback"', self.playback)
        self.assertIn('@"protocol_capability":self.playbackProtocolCapability', self.playback)

    def test_experimental_notice_is_one_time_non_blocking_and_unknown_is_silent(self):
        self.assertIn("experimentalProtocolNoticeShown", self.playback)
        self.assertIn('protocolStatus==MediaProtocolCapabilityStatusExperimental&&!self.experimentalProtocolNoticeShown', self.playback)
        self.assertIn('该协议为实验支持，可能无法播放', self.playback)
        self.assertIn('dispatch_after', self.playback)
        self.assertNotIn('protocolStatus==MediaProtocolCapabilityStatusUnknown', self.playback)
        # Unknown 没有专门分支，因此不会提示；仅 experimental 分支排队更新 UI。
        notice_start = self.playback.index('if(protocolStatus==MediaProtocolCapabilityStatusExperimental')
        notice_end = self.playback.index('NSMutableDictionary *attemptFields=', notice_start)
        self.assertIn('dispatch_async', self.playback[notice_start:notice_end])
        self.assertNotIn('MediaProtocolCapabilityStatusUnknown', self.playback[notice_start:notice_end])

    def test_terminal_fallback_messages_keep_existing_actions(self):
        self.assertIn('协议为实验支持，可能无法播放 · 可重试或切换线路', self.playback)
        self.assertIn('协议为实验支持，可能无法播放 · 可重试或手动切换线路', self.playback)
        self.assertIn('[self setRetryAvailable:YES]', self.playback)
        self.assertIn('inlineWebButton', self.playback)

    def test_live_sdk_path_does_not_query_protocol_table(self):
        self.assertNotIn('MediaProtocolCapability', self.root)

    def test_objc_delimiters_remain_balanced(self):
        # Counts avoid comments/strings, but catch common accidental edit damage.
        for opening, closing in (("{", "}"), ("(", ")"), ("[", "]")):
            self.assertEqual(self.playback.count(opening), self.playback.count(closing), (opening, closing))


if __name__ == "__main__":
    unittest.main()
