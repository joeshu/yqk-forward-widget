import builtins
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "Plugins" / "cctvhost_ffmpeg.py"
PYHOST = (ROOT / "Sources" / "PyHost.m").read_text(encoding="utf-8")


def load_api(bridge):
    spec = importlib.util.spec_from_file_location("cctvhost_ffmpeg_test", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    with patch.object(builtins, "_cctvhost_ffmpeg_call", bridge, create=True):
        spec.loader.exec_module(module)
    return module


class PythonFFmpegBridgeTests(unittest.TestCase):
    def test_python_api_reports_native_library_and_never_claims_a_cli_binary(self):
        expected = {"native_library": True, "command_line": False,
                    "engine": "alivcffmpeg.framework", "operations": ["probe"]}
        calls = []

        def bridge(raw):
            calls.append(json.loads(raw))
            return json.dumps(expected)

        api = load_api(bridge)
        self.assertTrue(api.available())
        self.assertEqual(api.capabilities(), expected)
        self.assertEqual([call["operation"] for call in calls], ["capabilities", "capabilities"])

    def test_api_reports_unavailable_outside_the_host_instead_of_crashing_on_import(self):
        api = load_api(None)
        self.assertFalse(api.available())
        with self.assertRaisesRegex(api.FFmpegError, "unavailable"):
            api.probe("https://media.example/video.mp4")

    def test_probe_forwards_stream_headers_and_timeout_to_native_library(self):
        observed = []

        def bridge(raw):
            observed.append(json.loads(raw))
            return json.dumps({"ok": True, "has_video": True, "video_stream_index": 0,
                               "has_audio": True, "audio_stream_index": 1,
                               "has_subtitles": False, "subtitle_stream_index": -1,
                               "verification": "native-demux-stream-discovery-only"})

        api = load_api(bridge)
        info = api.probe("https://media.example/video.mp4", {"Referer": "https://site.example/"}, 8)
        self.assertTrue(info["has_video"])
        self.assertEqual(observed, [{"operation": "probe", "url": "https://media.example/video.mp4",
                                     "headers": {"Referer": "https://site.example/"}, "timeout": 8.0}])

    def test_probe_rejects_unbounded_or_malformed_python_arguments_before_native_call(self):
        api = load_api(lambda _raw: self.fail("invalid arguments must not reach native code"))
        for args in (("",), ("x" * 4097,), ("https://media.example/a", {"Bad Header": "x"}),
                     ("https://media.example/a", {"Referer": "a\nb"}),
                     ("https://media.example/a", {}, 0),
                     ("https://media.example/a", {}, True)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                api.probe(*args)

    def test_native_bridge_is_registered_and_uses_bundled_framework_without_subprocess(self):
        self.assertIn('PyDict_SetItemString(builtins, "_cctvhost_ffmpeg_call", ffmpegFunction)', PYHOST)
        self.assertIn('avformat_open_input(&context', PYHOST)
        self.assertIn('avformat_find_stream_info(context', PYHOST)
        self.assertIn('Py_BEGIN_ALLOW_THREADS', PYHOST)
        self.assertIn('av_find_best_stream(context, 0', PYHOST)
        self.assertIn('"rw_timeout"', PYHOST)
        self.assertIn('"probesize", "2097152"', PYHOST)
        self.assertNotIn("subprocess", MODULE_PATH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
