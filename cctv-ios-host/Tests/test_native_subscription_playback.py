from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativeSubscriptionPlaybackTests(unittest.TestCase):
    def test_source_adapter_and_retry_policy(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            output = str(Path(tmp) / 'subscription-playback')
            built = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-I', str(root / 'Sources'),
                str(root / 'Tests/native_subscription_playback_tests.m'), str(root / 'Sources/MediaPlaybackHeaders.m'),
                str(root / 'Sources/MediaPlaybackDecodeRouter.m'), '-o', output], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            run = subprocess.run([output], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
