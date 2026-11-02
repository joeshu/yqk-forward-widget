import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMPAT_PARENT = ROOT / 'Plugins' / 'crypto_compat'
spec = importlib.util.spec_from_file_location('hostcrypto_fallback', ROOT / 'Plugins' / 'hostcrypto.py')
hostcrypto = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(COMPAT_PARENT))
spec.loader.exec_module(hostcrypto)


class HostCryptoTests(unittest.TestCase):
    def test_ctr_matches_nist_vector_and_keeps_counter_across_updates(self):
        key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        iv = bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff')
        plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
        expected = bytes.fromhex('874d6191b620e3261bef6864990db6ce')
        cipher = hostcrypto.AES_CTR(key, iv)
        self.assertEqual(cipher.update(memoryview(plain[:5])) + cipher.update(plain[5:]), expected)

    def test_context_rejects_wrong_key_or_counter_size_and_closes(self):
        with self.assertRaises(ValueError):
            hostcrypto.AES_CTR(b'k' * 15, b'i' * 16)
        with self.assertRaises(ValueError):
            hostcrypto.AES_CTR(b'k' * 16, b'i' * 8)
        cipher = hostcrypto.AES_CTR(b'k' * 16, b'i' * 16)
        cipher.close()
        with self.assertRaises(RuntimeError):
            cipher.update(b'data')

    def test_native_module_is_registered_before_cpython_initialization(self):
        source = (ROOT / 'Sources' / 'PyHost.m').read_text()
        self.assertIn('PyImport_AppendInittab("hostcrypto",PyInit_hostcrypto)', source)
        self.assertIn('CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES', source)
        self.assertIn('kCCModeOptionCTR_BE', source)
        self.assertIn('PyBytes_AS_STRING(output)', source)


if __name__ == '__main__':
    unittest.main()
