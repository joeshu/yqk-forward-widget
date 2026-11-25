"""Source contract tests for the protocol capability table and HostPlaybackSession.

本机无法编译 iOS，这里只做源码级契约：
- Plugins/media-capabilities.json 的 protocolCapabilities 是数据源；
- Sources/MediaProtocolCapabilities.m 的 ObjC 表与之逐项一致；
- Plugins/host_media_capabilities.py 的查询函数与之一致；
- MediaPlaybackViewController 的“选择下一个解码路由”经由 HostPlaybackSession。
"""
import importlib.util
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'
PLUGINS = ROOT / 'Plugins'

EXPECTED = {
    'hls': 'verified',
    'mp4': 'verified',
    'flv': 'engine_dependent',
    'dash': 'engine_dependent',
    'rtmp': 'engine_dependent',
    'rtsp': 'experimental',
    'srt': 'experimental',
    'smb': 'experimental',
    'udp': 'experimental',
}


def read(path):
    return path.read_text(encoding='utf-8')


def objc_table(source):
    start = source.index('table = @{')
    end = source.index('};', start)
    return dict(re.findall(r'@"([a-z0-9_]+)"\s*:\s*@"([a-z_]+)"', source[start:end]))


def load_capabilities_module():
    spec = importlib.util.spec_from_file_location('host_media_capabilities_contract', PLUGINS / 'host_media_capabilities.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProtocolCapabilityTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = json.loads(read(PLUGINS / 'media-capabilities.json'))
        cls.header = read(SOURCES / 'MediaProtocolCapabilities.h')
        cls.impl = read(SOURCES / 'MediaProtocolCapabilities.m')

    def test_json_registry_declares_expected_statuses(self):
        self.assertEqual(self.registry.get('protocolCapabilities'), EXPECTED)

    def test_existing_registry_keys_are_untouched(self):
        for key in ('networkTransports', 'cicadaFormats', 'avFormats', 'unsupportedContainers',
                    'unsupportedVideoCodecs', 'verifiedNetworkTransports'):
            self.assertIn(key, self.registry)
        self.assertEqual(self.registry['verifiedNetworkTransports'], [])

    def test_objc_table_matches_json(self):
        self.assertEqual(objc_table(self.impl), self.registry['protocolCapabilities'])

    def test_only_known_status_values(self):
        allowed = {'verified', 'engine_dependent', 'experimental'}
        self.assertTrue(set(self.registry['protocolCapabilities'].values()) <= allowed)
        for name in allowed | {'unknown'}:
            self.assertIn('@"%s"' % name, self.impl)

    def test_header_exposes_query_functions(self):
        for symbol in ('MediaProtocolCapabilityTable', 'MediaProtocolCapabilityStatusForProtocol',
                       'MediaProtocolIdentifierForURL', 'MediaProtocolCapabilityStatusForURL',
                       'MediaProtocolCapabilityStatusName', 'MediaProtocolCapabilityIsVerified'):
            self.assertRegex(self.header, r'FOUNDATION_EXPORT[^;]*\b%s\(' % symbol)
            self.assertRegex(self.impl, r'\n[A-Za-z][^\n;]*\b%s\([^;{]*\)\s*\{' % symbol)
        for case in ('MediaProtocolCapabilityStatusUnknown = 0', 'MediaProtocolCapabilityStatusVerified',
                     'MediaProtocolCapabilityStatusEngineDependent', 'MediaProtocolCapabilityStatusExperimental'):
            self.assertIn(case, self.header)

    def test_objc_sources_are_foundation_only_and_balanced(self):
        for text in (self.header, self.impl):
            self.assertNotIn('#import <UIKit', text)
            self.assertNotIn('CicadaPlayer', text)
            self.assertEqual(text.count('{'), text.count('}'))
            self.assertEqual(text.count('('), text.count(')'))
            self.assertEqual(text.count('['), text.count(']'))
        self.assertIn('NS_ASSUME_NONNULL_BEGIN', self.header)
        self.assertIn('NS_ASSUME_NONNULL_END', self.header)
        self.assertIn('#import "MediaProtocolCapabilities.h"', self.impl)

    def test_url_inference_covers_schemes_and_extensions(self):
        start = self.impl.index('NSString *MediaProtocolIdentifierForURL(')
        body = self.impl[start:self.impl.index('\n}\n', start)]
        for scheme in ('rtmp', 'rtmps', 'rtsp', 'srt', 'smb', 'udp'):
            self.assertIn('@"%s"' % scheme, body)
        for ext, proto in (('m3u8', 'hls'), ('mp4', 'mp4'), ('flv', 'flv'), ('mpd', 'dash')):
            self.assertIn('@"%s"' % ext, body)
            self.assertIn('return @"%s"' % proto, body)

    def test_python_query_function_matches_registry(self):
        module = load_capabilities_module()
        self.assertEqual(module.PROTOCOL_CAPABILITIES, EXPECTED)
        for name, status in EXPECTED.items():
            self.assertEqual(module.protocol_capability(name), status)
            self.assertEqual(module.protocol_capability(' %s ' % name.upper()), status)
        self.assertEqual(module.protocol_capability('gopher'), 'unknown')
        self.assertEqual(module.protocol_capability(None), 'unknown')

    def test_generated_foundation_registry_not_drifted(self):
        spec = importlib.util.spec_from_file_location('generator_contract', ROOT / 'Scripts/generate_media_capabilities.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(read(SOURCES / 'MediaCapabilityRegistry.h'), module.render())


class HostPlaybackSessionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = read(SOURCES / 'HostPlaybackSession.h')
        cls.impl = read(SOURCES / 'HostPlaybackSession.m')
        cls.playback = read(SOURCES / 'MediaPlaybackViewController.m')

    def test_session_holds_playback_state(self):
        for prop in ('resolvedResult', 'requestHeaders', 'currentRoute', 'attemptedRoutes',
                     'retryCount', 'resumePosition'):
            self.assertRegex(self.header, r'@property \([^)]*\)[^;]*\b%s;' % prop)
        self.assertIn('- (MediaPlaybackDecodeRoute)nextRouteForResult:(nullable NSDictionary *)result;', self.header)
        self.assertIn('- (MediaPlaybackDecodeRoute)peekNextRouteForResult:(nullable NSDictionary *)result;', self.header)

    def test_session_wraps_router_function(self):
        self.assertIn('MediaPlaybackDecodeRouteNextForResult(result, self.attemptedRoutes)', self.impl)
        self.assertIn('self.currentRoute = route;', self.impl)
        self.assertIn('if (markAttempted) [self markRouteAttempted:route];', self.impl)
        for mask in ('AVPlayer', 'CicadaPlayer', 'WebView', 'MPV'):
            self.assertIn('MediaPlaybackDecodeRouteAttempted%s' % mask, self.impl)
        for text in (self.header, self.impl):
            self.assertNotIn('#import <UIKit', text)
            self.assertEqual(text.count('{'), text.count('}'))
            self.assertEqual(text.count('('), text.count(')'))
            self.assertEqual(text.count('['), text.count(']'))
        self.assertEqual(self.impl.count('@implementation'), self.impl.count('@end'))

    def test_view_controller_selects_routes_through_session(self):
        self.assertIn('#import "HostPlaybackSession.h"', self.playback)
        self.assertIn('MediaPlaybackDecodeRoute initialRoute=[self.playbackSession nextRouteForResult:result];', self.playback)
        self.assertEqual(self.playback.count('nextRoute=[self.playbackSession nextRouteForResult:self.result];'), 3)
        self.assertIn('[owner.playbackSession peekNextRouteForResult:owner.result]', self.playback)
        # 回退链中不再直接调用路由函数（仅保留预取判定 attempted=0 的一处）。
        self.assertEqual(re.findall(r'MediaPlaybackDecodeRouteNextForResult\(([^)]*)\)', self.playback), ['result,0'])

    def test_attempted_routes_storage_is_forwarded_to_session(self):
        self.assertIn('- (NSUInteger)attemptedRoutes {return self.playbackSession.attemptedRoutes;}', self.playback)
        self.assertIn('- (void)setAttemptedRoutes:(NSUInteger)attemptedRoutes {self.playbackSession.attemptedRoutes=attemptedRoutes;}', self.playback)
        self.assertNotIn('_attemptedRoutes', self.playback)

    def test_project_includes_sources_directory(self):
        project = read(ROOT / 'project.yml')
        self.assertRegex(project, r'sources:\s*\n\s*- path: Sources\n')


if __name__ == '__main__':
    unittest.main()
