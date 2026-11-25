import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


class HostPlaybackSessionP2Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.session_h = (SOURCES / "HostPlaybackSession.h").read_text(encoding="utf-8")
        cls.session_m = (SOURCES / "HostPlaybackSession.m").read_text(encoding="utf-8")
        cls.playback = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")

    def test_session_owns_request_headers_retry_and_resume_state(self):
        for declaration in (
            r"@property\s*\(nonatomic,\s*copy,\s*nullable\).*\*\s*requestHeaders",
            r"@property\s*\(nonatomic\)\s*NSUInteger\s+retryCount",
            r"@property\s*\(nonatomic\)\s*NSTimeInterval\s+resumePosition",
        ):
            self.assertRegex(self.session_h, declaration)
        self.assertIn("isfinite(resumePosition) && resumePosition > 0", self.session_m)

    def test_controller_properties_forward_into_session(self):
        for accessor in (
            "self.playbackSession.requestHeaders=headers",
            "self.playbackSession.retryCount=attempts",
            "self.playbackSession.resumePosition=position",
        ):
            self.assertIn(accessor, self.playback)
        self.assertIn("return self.playbackSession.requestHeaders;", self.playback)
        self.assertIn("return self.playbackSession.retryCount;", self.playback)
        self.assertIn("return self.playbackSession.resumePosition;", self.playback)

    def test_forwarded_kvc_property_names_remain_declared_and_no_backing_ivar(self):
        for name in ("basePlaybackHeaders", "stallRecoveryAttempts", "lastPersistedPosition"):
            self.assertRegex(self.playback, rf"@property[^;]*\b{name}\b[^;]*;")
            self.assertNotRegex(self.playback, rf"\b_{name}\b")
        self.assertRegex(self.playback, r"- \(void\)setBasePlaybackHeaders:")
        self.assertRegex(self.playback, r"- \(void\)setStallRecoveryAttempts:")
        self.assertRegex(self.playback, r"- \(void\)setLastPersistedPosition:")

    def test_progress_save_timing_and_logic_stay_in_controller(self):
        self.assertIn("if(position-owner.lastPersistedPosition>=10.0){[owner persistPlaybackProgress];owner.lastPersistedPosition=position;}", self.playback)
        persist = self.playback.split("- (void)persistPlaybackProgress {", 1)[1].split("\n- (", 1)[0]
        self.assertIn("[MediaPlaybackStateStore recordContext:self.context", persist)
        self.assertIn("self.lastPersistedPosition=position;", persist)


if __name__ == "__main__":
    unittest.main()
