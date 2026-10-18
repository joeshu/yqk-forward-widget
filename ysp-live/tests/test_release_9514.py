"""HTTP 400 can carry a normal registration transition, not device invalidation."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from test_release_959 import args

ROOT = Path(__file__).resolve().parents[1]

def load(version):
    name = 'registration_compare_' + version.replace('.', '_')
    spec = importlib.util.spec_from_file_location(name, ROOT / ('ysp-live-v' + version + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

live = load('9.5.16')
broken = load('9.5.13')


class RegistrationBusinessReplyTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = directory.name
        self.r = self.resolver(live)
        self.identity = SimpleNamespace(headers={})

    def resolver(self, module):
        r = module.Resolver(args(self.directory))
        self.addCleanup(r.close)
        return r

    def response(self, status, code=None, guid='', module=live):
        value = {'result': code, 'data': {'guid': guid}}
        return module.HttpResponse(status, 'simulated', {}, json.dumps(value).encode())

    def flow(self, responses):
        self.r.generic_client.post_json = mock.Mock(side_effect=responses)
        with mock.patch.object(live, 'rsa_encrypt_device_id', return_value='encrypted'):
            return self.r.cloud_registration_flow(self.identity, 'not-logged')

    def test_actual_log_400_result_2_continues_register_instead_of_failing_early(self):
        self.assertEqual(self.flow([self.response(400, 2), self.response(200, 0, 'valid-guid')]), 'valid-guid')
        urls = [call.args[0] for call in self.r.generic_client.post_json.call_args_list]
        self.assertEqual(urls, [live.CLOUD_GET_URL, live.CLOUD_REGISTER_URL])
        self.assertEqual(self.r.state.device_wipe_count, 0)

    def test_v9513_regression_is_reproduced_with_identical_reply(self):
        old = self.resolver(broken)
        old.generic_client.post_json = mock.Mock(side_effect=[
            self.response(400, 2, module=broken), self.response(200, 0, 'valid-guid', module=broken)])
        with mock.patch.object(broken, 'rsa_encrypt_device_id', return_value='encrypted'):
            with self.assertRaisesRegex(broken.YsptpError, 'cloud_get HTTP 400'):
                old.cloud_registration_flow(self.identity, 'not-logged')
        self.assertEqual(old.generic_client.post_json.call_count, 1)

    def test_http_400_needs_register_and_registered_elsewhere_can_requery_guid(self):
        self.assertEqual(self.flow([
            self.response(400, 601), self.response(400, 694), self.response(400, 0, 'returned-guid')]), 'returned-guid')
        self.assertEqual([call.args[0] for call in self.r.generic_client.post_json.call_args_list],
                         [live.CLOUD_GET_URL, live.CLOUD_REGISTER_URL, live.CLOUD_GET_URL])
        self.assertTrue(self.r._registration_last['business_reply_on_http_error'])

    def test_registration_retry_later_is_bounded_to_two_attempts(self):
        self.assertEqual(self.flow([self.response(400, 2), self.response(400, 695), self.response(400, 695)]), '')
        self.assertEqual(self.r.generic_client.post_json.call_count, 3)
        self.assertEqual(self.r._registration_last['result_code'], 695)

    def test_no_guid_never_fabricates_a_registered_device(self):
        self.assertEqual(self.flow([self.response(400, 2), self.response(400, 2), self.response(400, 2)]), '')
        self.assertFalse(self.r.state.sessions)
        self.assertFalse(self.r._registration_last['guid_present'])

    def test_non_protocol_http_failures_do_not_continue_registration(self):
        for status, code in ((400, 99), (400, None), (400, 695), (401, 2), (403, 2), (429, 2), (500, 2)):
            with self.subTest(status=status, code=code):
                self.r.generic_client.post_json = mock.Mock(return_value=self.response(status, code))
                with mock.patch.object(live, 'rsa_encrypt_device_id', return_value='encrypted'):
                    with self.assertRaises(live.YsptpError):
                        self.r.cloud_registration_flow(self.identity, 'not-logged')
                self.r.generic_client.post_json.assert_called_once()

    def test_normal_http_success_path_still_works(self):
        self.assertEqual(self.flow([self.response(200, 0, 'existing-guid')]), 'existing-guid')
        self.assertFalse(self.r._registration_last['business_reply_on_http_error'])


class BackupFailureDiagnosticsTests(unittest.TestCase):
    def test_timeout_is_not_wrapped_and_retains_playlist_stage(self):
        ch = live.Channel('cctvfyjc', 'Theatre', 'sid', 'pid', 'best')
        ch.mode = 'bk'
        error = TimeoutError('The read operation timed out')
        error.playback_stage = 'playlist'
        with mock.patch.object(live.global_flow_limiter, 'wait_slot'), \
             mock.patch.object(live, 'bk_channel_playurls', return_value=['https://media.cctv.cn/a.m3u8']), \
             mock.patch.object(live, 'fetch_abs_playlist', side_effect=error):
            self.assertFalse(live.refresh_once(ch))
        self.assertTrue(ch.last_error.startswith('TimeoutError:'))
        self.assertEqual(ch.last_error_stage, 'playlist')
        self.assertEqual(ch.authorization_retry_at, 0)

    def test_non_hls_response_reports_type_and_size_without_body_or_url(self):
        body = b'<html>secret-session-token</html>'
        with mock.patch.object(live, 'fetch_urllib_bytes', return_value=(200, {'Content-Type': 'text/html; charset=UTF-8'}, body,
                               'https://media.cctv.cn/path?token=secret-url')):
            with self.assertRaises(live.UnsafePlaylist) as raised:
                live.fetch_abs_playlist('https://media.cctv.cn/a.m3u8')
        text = str(raised.exception)
        self.assertIn('HTTP=200 type=text/html', text)
        self.assertIn('bytes=' + str(len(body)), text)
        self.assertNotIn('secret-session-token', text)
        self.assertNotIn('secret-url', text)
        self.assertEqual(raised.exception.playback_stage, 'playlist')


if __name__ == '__main__':
    unittest.main()
