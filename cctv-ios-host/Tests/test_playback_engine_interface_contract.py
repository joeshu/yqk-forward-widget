"""Source contracts for the unified playback engine API (iOS SDK unavailable here)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


class PlaybackEngineInterfaceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.protocol = read('CCTVPlaybackEngineProtocol.h')
        cls.types = read('CCTVPlaybackEngineTypes.h')
        cls.cicada_h = read('MediaPlaybackCicadaAdapter.h')
        cls.mpv_h = read('MediaPlaybackMPVAdapter.h')
        cls.cicada_m = read('MediaPlaybackCicadaAdapter.m')
        cls.mpv_m = read('MediaPlaybackMPVAdapter.m')

    def test_protocol_import_graph_has_no_adapter_cycle(self):
        self.assertNotIn('MediaPlaybackCicadaAdapter.h', self.protocol)
        self.assertNotIn('MediaPlaybackMPVAdapter.h', self.protocol)
        self.assertIn('#import "CCTVPlaybackEngineTypes.h"', self.protocol)
        self.assertIn('#import "CCTVPlaybackEngineProtocol.h"', self.cicada_h)
        self.assertNotIn('#import "CCTVPlaybackEngineProtocol.h"', self.types)

    def test_both_adapters_declare_protocol_conformance(self):
        self.assertRegex(self.cicada_h, r'@interface\s+MediaPlaybackCicadaAdapter\s*:\s*NSObject\s*<[^>]*CCTVPlaybackEngine')
        self.assertRegex(self.mpv_h, r'@interface\s+MediaPlaybackMPVAdapter\s*:\s*NSObject\s*<[^>]*CCTVPlaybackEngine')

    def test_required_members_are_declared_and_implemented(self):
        header_patterns = {
            'prepare': r'-\s*\(void\)prepare\s*;',
            'prepareWithHardwareDecoder:': r'prepareWithHardwareDecoder:\s*\(BOOL\)',
            'start': r'-\s*\(void\)start\s*;',
            'pause': r'-\s*\(void\)pause\s*;',
            'stop': r'-\s*\(void\)stop\s*;',
            'destroy': r'-\s*\(void\)destroy\s*;',
            'seekToTime:completion:': r'seekToTime:\s*\(NSTimeInterval\)[^{;]*completion:',
            'setMuted:': r'setMuted:\s*\(BOOL\)',
        }
        for selector, pattern in header_patterns.items():
            with self.subTest(selector=selector):
                for header in (self.cicada_h, self.mpv_h):
                    self.assertRegex(header, pattern)
        impl_selector = {
            'prepare': r'-\s*\(void\)prepare\s*\{',
            'prepareWithHardwareDecoder:': r'-\s*\(void\)prepareWithHardwareDecoder:\s*\(BOOL\)',
            'start': r'-\s*\(void\)start\s*\{',
            'pause': r'-\s*\(void\)pause\s*\{',
            'stop': r'-\s*\(void\)stop\s*\{',
            'destroy': r'-\s*\(void\)destroy\s*\{',
            'seekToTime:completion:': r'-\s*\(void\)seekToTime:\s*\(NSTimeInterval\)[^{;]*completion:',
            'setMuted:': r'-\s*\(void\)setMuted:\s*\(BOOL\)',
        }
        for selector, pattern in impl_selector.items():
            for implementation in (self.cicada_m, self.mpv_m):
                with self.subTest(selector=selector, implementation=implementation[:30]):
                    self.assertRegex(implementation, pattern)

    def test_error_and_statistics_surfaces_are_implemented(self):
        for header, implementation in ((self.cicada_h, self.cicada_m), (self.mpv_h, self.mpv_m)):
            self.assertRegex(header, r'@property\s*\([^)]*readonly[^)]*\)\s*NSInteger\s+lastErrorCode\s*;')
            self.assertRegex(implementation, r'-\s*\(NSInteger\)lastErrorCode\s*\{')
            self.assertRegex(implementation, r'-\s*\(NSDictionary<NSString\s*\*,\s*id>\s*\*\)playbackStatistics\s*\{\s*return\s*@\{\};\s*\}')
        self.assertIn('self.lastErrorCode = code;', self.cicada_m)
        self.assertIn('self.lastErrorCode = code;', self.mpv_m)

    def test_extended_capabilities_are_optional_and_advertised_only_if_supported(self):
        optional = self.protocol[self.protocol.index('@optional'):]
        for selector in ('rate', 'availableTracks', 'canSelectTracks',
                         'selectTrackWithIndex:', 'applyVideoGravity:', 'addExternalSubtitleURL:'):
            self.assertIn(selector, optional)
        for header in (self.cicada_h, self.mpv_h):
            for symbol in ('rate', 'setRate:', 'availableTracks', 'canSelectTracks',
                           'selectTrackWithIndex:', 'applyVideoGravity:'):
                self.assertIn(symbol, header)

    def test_objc_changed_headers_have_balanced_delimiters(self):
        for text in (self.protocol, self.types, self.cicada_h, self.mpv_h):
            # Ignore comments: prose may contain unmatched punctuation.
            code = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
            self.assertEqual(code.count('{'), code.count('}'))
            self.assertEqual(code.count('('), code.count(')'))
            self.assertEqual(code.count('['), code.count(']'))


if __name__ == '__main__':
    unittest.main()
