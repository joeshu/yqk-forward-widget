from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class PlaybackBufferPolicyTests(unittest.TestCase):
    def test_short_startup_steady_rebuffer_and_late_prefetch(self):
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe=str(Path(tmp)/'playback-buffers')
            build=subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-I',str(root/'Sources'),str(root/'Tests/native_playback_buffer_policy_tests.m'),'-o',exe],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([exe],capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
