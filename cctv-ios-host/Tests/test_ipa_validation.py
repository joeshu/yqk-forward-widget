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

if __name__ == '__main__': unittest.main()
