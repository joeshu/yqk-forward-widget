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
            compile_result = subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                "-I", str(root / "Sources"),
                str(root / "Tests" / "native_state_tests.m"),
                str(root / "Sources" / "HostBackup.m"),
                str(root / "Sources" / "ProfileStore.m"),
                str(root / "Sources" / "ServiceStore.m"), "-o", executable,
                str(root / "Sources" / "HostLogBuffer.m"),
                str(root / "Sources" / "MediaMetadataCache.m"),
                str(root / "Sources" / "MediaPlaybackStateStore.m"),
                str(root / "Sources" / "MediaSourceHealthStore.m"),
            ], capture_output=True, text=True)
            self.assertEqual(
                compile_result.returncode,
                0,
                "native state test compilation failed:\n"
                + compile_result.stdout
                + compile_result.stderr,
            )
            subprocess.run([executable], check=True, capture_output=True, text=True, timeout=30)
