from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation execution requires macOS')
class NativeSearchResults(unittest.TestCase):
    def test_provider_identity_filters_limits_and_untrusted_metadata(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            executable = str(Path(directory) / 'search-results')
            built = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                                    '-I', str(root / 'Sources'),
                                    str(root / 'Tests/native_search_results_tests.m'), '-o', executable],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([executable], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
