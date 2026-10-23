import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation")
class NativeTimeshiftTests(unittest.TestCase):
    def test_double_abi_ranges_copyright_and_cancellation(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe = str(pathlib.Path(tmp) / "timeshift-tests")
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-I", str(root / "Sources"),
                str(root / "Tests/native_timeshift_tests.m"), str(root / "Sources/NativeTimeshiftSession.m"), "-o", exe,
            ], check=True, capture_output=True, text=True)
            subprocess.run([exe], check=True, capture_output=True, text=True, timeout=10)
