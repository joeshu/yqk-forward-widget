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
            # 注意：不要用 check=True——CalledProcessError 的 traceback 不打印 clang 的
            # stderr，构建失败时真正原因会被吞掉（2026-11-26 CI 45718753390 上此测试就
            # 这样丢过一次错误信息）；改走 assertEqual，把 stdout+stderr 写进断言消息，
            # 与 test_native_js.py / test_native_import_audit.py 的写法一致。
            build = subprocess.run([
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
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([executable], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
