import json
import plistlib
import tempfile
import zipfile
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('validate_ipa', Path(__file__).parents[1] / 'Scripts/validate_ipa.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

def sample(platform=2, cpu=0x100000c, kind=6):
    header = struct.pack('<8I', 0xfeedfacf, cpu, 0, kind, 1, 24, 0, 0)
    return header + struct.pack('<6I', 0x32, 24, platform, 0xf0000, 0x120000, 0)

class TestDevicePlatform(unittest.TestCase):
    def test_fat_arm64_device_framework(self):
        thin=sample()
        offset=32
        fat=bytes.fromhex('cafebabe')+struct.pack('>I',1)+struct.pack('>IIIII',0x0100000c,0,offset,len(thin),2)+bytes(4)+thin
        info=v.macho_info(fat)
        self.assertEqual(info['slices'][0]['platform'],'iOS device')
    def test_fat_simulator_slice_rejected(self):
        thin=sample(platform=7)
        offset=32
        fat=bytes.fromhex('cafebabe')+struct.pack('>I',1)+struct.pack('>IIIII',0x0100000c,0,offset,len(thin),2)+bytes(4)+thin
        with self.assertRaisesRegex(AssertionError,'platform=2'): v.macho_info(fat)
    def test_device(self):
        self.assertEqual(v.macho_info(sample())['platform'], 'iOS device')
    def test_simulator_arm64_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'platform=2'):
            v.macho_info(sample(platform=7))
    def test_macos_rejected(self):
        with self.assertRaises(AssertionError): v.macho_info(sample(platform=1))
    def test_x86_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'ARM64'): v.macho_info(sample(cpu=0x1000007))
    def test_invalid_command_rejected(self):
        bad=sample()[:32]+struct.pack('<II',0x32,10000)
        with self.assertRaisesRegex(AssertionError, 'load command'):v.macho_info(bad)

class TestPackagedIPA(unittest.TestCase):
    def make_ipa(self, path, *, executable="CCTVHost", app_platform=2):
        root = "Payload/CCTVHost.app/"
        info = {"CFBundleIdentifier": "com.example.cctvhost", "CFBundleExecutable": executable,
                "CFBundleShortVersionString": "0.16.1", "CFBundleVersion": "16.1",
                "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}}}
        with zipfile.ZipFile(path, "w") as z:
            z.writestr(root + "Info.plist", plistlib.dumps(info))
            z.writestr(root + "Assets.car", b"test fixture")
            z.writestr(root + "CCTVHost", sample(platform=app_platform, kind=2))
            z.writestr(root + "channels.json", json.dumps([{"id": "cctv1"}]))
            for name in ("CNPlayerSDK", "CicadaPlayerSDK", "alivcffmpeg"):
                z.writestr(f"{root}Frameworks/{name}.framework/{name}", sample())

    def test_complete_package_validation_reaches_binary_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.ipa"
            self.make_ipa(path)
            result = v.validate(path)
            self.assertEqual(result["binaries"]["CCTVHost"]["kind"], 2)
            self.assertEqual(result["version"], "0.16.1")
            self.assertEqual(result["channel_count"], 1)
            self.assertEqual(len(result["sha256"]), 64)

    def test_packaged_simulator_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.ipa"
            self.make_ipa(path, app_platform=7)
            with self.assertRaisesRegex(AssertionError, "platform=2"):
                v.validate(path)

    def test_wrong_executable_metadata_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.ipa"
            self.make_ipa(path, executable="wrong")
            with self.assertRaisesRegex(AssertionError, "executable"):
                v.validate(path)

if __name__ == '__main__': unittest.main()
