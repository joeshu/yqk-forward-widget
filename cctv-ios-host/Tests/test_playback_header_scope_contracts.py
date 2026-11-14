from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlaybackHeaderScopeContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        cls.headers = (ROOT / 'Sources/MediaPlaybackHeaders.m').read_text()

    def test_key_requests_scope_headers_to_the_key_origin(self):
        loader = self.playback.split('- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:', 1)[1]
        self.assertIn('MediaPlaybackHeadersScopedToURL(', loader)
        self.assertIn('keyOriginURL', loader)
        self.assertIn('request loadURL:httpURL headers:keyHeaders', loader)

    def test_direct_av_and_cicada_requests_use_scoped_headers(self):
        av = self.playback.split('static NSDictionary *MediaPlaybackAVAssetHeaders', 1)[1].split('static NSURL *MediaPlaybackEpisodePageFallbackURL', 1)[0]
        self.assertIn('MediaPlaybackHeadersScopedToURL(headers,originURL,url)', av)
        cicada = self.playback.split('- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration {', 1)[1].split('\n- (void)', 1)[0]
        self.assertIn('MediaPlaybackHeadersScopedToURL(requestHeaders,sourceURL?:url,effectiveURL)', cicada)

    def test_scope_preserves_same_origin_and_standard_https_upgrade(self):
        self.assertIn('([a isEqual:b]&&ap==bp)', self.headers)
        self.assertIn('([a isEqual:@"http"]&&[b isEqual:@"https"]&&ap==80&&bp==443)', self.headers)
        self.assertIn('NSSet *allowed=[NSSet setWithArray:@[@"accept"', self.headers)
        self.assertIn('if(![allowed containsObject:key.lowercaseString])', self.headers)


if __name__ == '__main__':
    unittest.main()
