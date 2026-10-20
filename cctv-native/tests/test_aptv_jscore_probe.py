import builtins
import importlib.util
from pathlib import Path
import unittest
from unittest import mock


def load_probe():
    spec = importlib.util.spec_from_file_location(
        'aptv_jscore_probe', Path(__file__).resolve().parents[1] / 'aptv-jscore-probe.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestJScoreProbe(unittest.TestCase):
    def test_non_apple_runtime_does_not_attempt_native_loading(self):
        probe = load_probe()
        original = builtins.__import__
        def guarded(name, *args, **kwargs):
            if name in ('ctypes', 'subprocess'):
                raise AssertionError('unexpected native import')
            return original(name, *args, **kwargs)
        with mock.patch.object(probe.sys, 'platform', 'linux'), mock.patch(
                'builtins.__import__', side_effect=guarded):
            value = probe.report()
        self.assertEqual(value['status'], 'apple-platform-required')
        self.assertFalse(value['playback_verified'])

    def test_missing_library_is_reported_without_leaking_exception_content(self):
        probe = load_probe()
        with mock.patch.object(probe.sys, 'platform', 'ios'), mock.patch.object(
                probe, 'evaluate', side_effect=OSError('private exception details')):
            value = probe.report()
        self.assertEqual(value['status'], 'native-engine-unavailable')
        self.assertEqual(value['error_type'], 'OSError')
        self.assertNotIn('private exception details', str(value))

    def test_javascript_without_working_wasm_is_not_a_pass(self):
        probe = load_probe()
        with mock.patch.object(probe.sys, 'platform', 'darwin'), mock.patch.object(
                probe, 'evaluate', return_value={'javascript': 42, 'wasm_available': False}):
            self.assertEqual(probe.report()['status'], 'wasm-test-failed')

    def test_basic_engine_success_does_not_claim_media_playback(self):
        probe = load_probe()
        with mock.patch.object(probe.sys, 'platform', 'ios'), mock.patch.object(
                probe, 'evaluate', return_value={'javascript': 42, 'wasm': 42}):
            value = probe.report()
        self.assertEqual(value['status'], 'wasm-test-passed')
        self.assertFalse(value['playback_verified'])
        self.assertFalse(value['external_requests'])
        self.assertFalse(value['subprocess_required'])
