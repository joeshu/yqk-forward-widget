import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation")
class NativeBufferTests(unittest.TestCase):
    def test_preserves_drm_restores_buffers_and_rejects_unsupported_cores(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe = str(pathlib.Path(tmp) / "buffer-tests")
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I", str(root / "Sources"),
                str(root / "Tests/native_buffer_tests.m"),
                str(root / "Sources/NativeStartupTuner.m"), "-o", exe,
            ], check=True, capture_output=True, text=True)
            subprocess.run([exe], check=True, capture_output=True, text=True, timeout=10)
