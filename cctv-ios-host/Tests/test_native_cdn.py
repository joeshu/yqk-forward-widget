import json
import pathlib
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class BundledCDNContractTests(unittest.TestCase):
    def test_getter_belongs_to_vdn_manager_and_setter_returns_object(self):
        indexer = ROOT.parent / 'tools/ipa/objc-method-index.py'
        result = subprocess.run([sys.executable, str(indexer), str(ROOT / 'Frameworks/CNPlayerSDK.framework/CNPlayerSDK')], capture_output=True, text=True, check=True)
        classes = {c['name']: c for c in json.loads(result.stdout)['classes']}
        player = {m['name']: m for m in classes['CNPlayer']['class']}
        manager = {m['name']: m for m in classes['CNVDNManager']['class']}
        getter = 'getVDNConfig_CDNLive_DefaultCDNInfo'
        self.assertNotIn(getter, player)
        self.assertEqual(manager[getter]['types'], '@16@0:8')
        self.assertEqual(player['configSDK_CDN_LIVEDefaultCDNInfo:']['types'], '@24@0:8@16')


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativeCDNTests(unittest.TestCase):
    def test_configuration_roundtrip_rollback_invalid_inputs_and_real_observation(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = str(pathlib.Path(tmp) / 'cdn-tests')
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-I', str(ROOT / 'Sources'),
                            str(ROOT / 'Tests/native_cdn_tests.m'), str(ROOT / 'Sources/NativeCDNPreference.m'), '-o', exe], check=True, capture_output=True, text=True)
            subprocess.run([exe], check=True, capture_output=True, text=True, timeout=10)
