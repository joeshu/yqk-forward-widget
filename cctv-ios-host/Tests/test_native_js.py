import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS JavaScriptCore')
class NativeJSTests(unittest.TestCase):
    def test_original_js_runs_in_real_javascriptcore_with_native_network_and_stop(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        bundle = root / 'GeneratedJS/yangshipin.bundle.js'
        if not bundle.exists():
            subprocess.run(['npm', 'ci', '--prefix', str(root / 'JSPlugins'), '--no-audit', '--no-fund'], check=True, capture_output=True, text=True)
            subprocess.run(['npm', 'run', 'build', '--prefix', str(root / 'JSPlugins')], check=True, capture_output=True, text=True)
        with tempfile.TemporaryDirectory() as tmp:
            executable = str(pathlib.Path(tmp) / 'native-js-test')
            build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'JavaScriptCore', '-framework', 'Security',
                '-I', str(root / 'Sources'), str(root / 'Tests/native_js_tests.m'), str(root / 'Sources/JSPluginRuntime.m'), str(root / 'Sources/HostSyncRequest.m'), '-o', executable], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([executable, str(bundle), str(root / 'GeneratedJS/js-runtime.bundle.js')], capture_output=True, text=True, timeout=70)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
