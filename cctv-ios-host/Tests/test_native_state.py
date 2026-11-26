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
            # 注意：不要用 check=True——CalledProcessError 的 traceback 不打印
            # 二进制的输出，运行时哪条 check 失败会被吞掉（test_native_history_cap.py
            # 已改同款；本文件 2026-11-26 CI 45813507443 就这样丢过一次失败原因）；
            # 改走 assertEqual，把 stdout+stderr 写进断言消息。
            build = subprocess.run([
                "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "Security",
                "-I", str(root / "Sources"),
                str(root / "Tests" / "native_state_tests.m"),
                str(root / "Sources" / "HostBackup.m"),
                str(root / "Sources" / "HostLibraryStore.m"), "-lsqlite3",
                str(root / "Sources" / "ProfileStore.m"),
                str(root / "Sources" / "ServiceStore.m"), "-o", executable,
                str(root / "Sources" / "HostLogBuffer.m"),
                str(root / "Sources" / "MediaMetadataCache.m"),
                str(root / "Sources" / "MediaPlaybackStateStore.m"),
                str(root / "Sources" / "MediaSourceHealthStore.m"),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([executable], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
