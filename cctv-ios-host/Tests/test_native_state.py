import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation")
class NativeStateTests(unittest.TestCase):
    def test_backup_validation_roundtrip_and_service_persistence(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            executable = str(pathlib.Path(tmp) / "cctvhost-native-state-tests")
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I", str(root / "Sources"),
                str(root / "Tests" / "native_state_tests.m"),
                str(root / "Sources" / "HostBackup.m"),
                str(root / "Sources" / "ServiceStore.m"), "-o", executable,
            ], check=True, capture_output=True, text=True)
            subprocess.run([executable], check=True, capture_output=True, text=True)
