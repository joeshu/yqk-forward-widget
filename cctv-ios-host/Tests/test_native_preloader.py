import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation")
class NativePreloaderTests(unittest.TestCase):
    def test_metadata_only_handoff_expiry_cancellation_and_stale_callbacks(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe = str(pathlib.Path(tmp) / "preloader-tests")
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I", str(root / "Sources"), str(root / "Tests/native_preloader_tests.m"),
                str(root / "Sources/NativeChannelPreloader.m"), "-o", exe,
            ], check=True, capture_output=True, text=True)
            subprocess.run([exe], check=True, capture_output=True, text=True, timeout=10)
