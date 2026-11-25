import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation")
class NativeHistoryCapTests(unittest.TestCase):
    def test_backup_restore_trims_recents_and_watch_history_to_store_caps(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            executable = str(pathlib.Path(tmp) / "cctvhost-native-history-cap-tests")
            subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "Security",
                "-I", str(root / "Sources"),
                str(root / "Tests" / "native_history_cap_tests.m"),
                str(root / "Sources" / "HostBackup.m"),
                str(root / "Sources" / "HostLibraryStore.m"), "-lsqlite3",
                str(root / "Sources" / "ProfileStore.m"),
                str(root / "Sources" / "ServiceStore.m"), "-o", executable,
                str(root / "Sources" / "HostLogBuffer.m"),
                str(root / "Sources" / "MediaMetadataCache.m"),
                str(root / "Sources" / "MediaPlaybackStateStore.m"),
                str(root / "Sources" / "MediaSourceHealthStore.m"),
            ], check=True, capture_output=True, text=True)
            subprocess.run([executable], check=True, capture_output=True, text=True, timeout=30)
