import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestRound32ProtocolPlayerAndProbeEnhancements(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (ROOT / rel_path).read_text(encoding="utf-8")

    def test_cicada_adapter_case_insensitive_headers_common_modes_and_retry(self):
        src = self._read("Sources/MediaPlaybackCicadaAdapter.m")
        self.assertIn('CicadaCallVoidInt(config, NSSelectorFromString(@"setNetworkRetryCount:"), 3);', src)
        self.assertIn('CicadaCallVoidBool(config, NSSelectorFromString(@"setClearShowWhenStop:"), NO);', src)
        self.assertIn('[key caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame', src)
        self.assertIn('[key caseInsensitiveCompare:@"Referrer"] == NSOrderedSame', src)
        self.assertGreaterEqual(src.count("addTimer:self."), 3)
        self.assertIn("forMode:NSRunLoopCommonModes", src)

    def test_decode_router_and_headers_audio_magic_udp_and_extensionless_streams(self):
        router = self._read("Sources/MediaPlaybackDecodeRouter.m")
        self.assertIn('return @"flac";', router)
        self.assertIn('return @"wav";', router)
        self.assertIn('return @"mp3";', router)
        self.assertIn('return @"aac";', router)
        self.assertIn('[lowerRaw hasPrefix:@"udp://"]', router)
        self.assertIn('[lowerRaw containsString:@"format=flv"]', router)

        headers = self._read("Sources/MediaPlaybackHeaders.m")
        self.assertIn('[lowerRaw containsString:@"format=hls"]', headers)
        self.assertIn('[lowerRaw containsString:@"format=mp4"]', headers)
        self.assertIn('[scheme isEqual:@"udp"]', headers)
        self.assertIn('[lowerRaw containsString:@"format=flv"]', headers)

    def test_hls_probe_206_lru_eviction_latin1_fallback_and_sniff_dealloc(self):
        probe = self._read("Sources/HLSRouteProbe.m")
        self.assertIn("statusCode == 200 || statusCode == 206", probe)
        self.assertIn("NSISOLatin1StringEncoding", probe)
        self.assertIn("[store removeObjectForKey:oldestKey];", probe)

        sniff = self._read("Sources/MediaPlaybackSniffFetch.m")
        self.assertIn("- (void)dealloc {[self cancel];}", sniff)


if __name__ == "__main__":
    unittest.main()
