from pathlib import Path
import os
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativeParserBindingTests(unittest.TestCase):
    def test_binding_is_persistent_and_does_not_change_content_ownership(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            executable = str(Path(tmp) / 'native-parser-binding')
            built = subprocess.run([
                'xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                '-I', str(root / 'Sources'),
                str(root / 'Tests/native_parser_binding_tests.m'),
                str(root / 'Sources/ServiceStore.m'),
                str(root / 'Sources/ProfileStore.m'), '-o', executable,
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            run = subprocess.run([executable], env=dict(os.environ, CFFIXED_USER_HOME=tmp),
                                 capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('PASS: per-source parser binding', run.stdout)
