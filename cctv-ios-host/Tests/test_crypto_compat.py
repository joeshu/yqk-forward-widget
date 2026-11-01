import base64
import importlib
import importlib.util
from pathlib import Path
import sys
import unittest


COMPAT_ROOT = Path(__file__).resolve().parents[1] / 'Plugins' / 'crypto_compat' / 'Crypto'
PACKAGE_NAME = '_cctvhost_crypto_compat_test'
spec = importlib.util.spec_from_file_location(
    PACKAGE_NAME, COMPAT_ROOT / '__init__.py',
    submodule_search_locations=[str(COMPAT_ROOT)])
crypto = importlib.util.module_from_spec(spec)
sys.modules[PACKAGE_NAME] = crypto
spec.loader.exec_module(crypto)
AES = importlib.import_module(PACKAGE_NAME + '.Cipher.AES')
PKCS1_v1_5 = importlib.import_module(PACKAGE_NAME + '.Cipher.PKCS1_v1_5')
RSA = importlib.import_module(PACKAGE_NAME + '.PublicKey.RSA')
Padding = importlib.import_module(PACKAGE_NAME + '.Util.Padding')


class CryptoCompatibilityTests(unittest.TestCase):
    def test_aes_ecb_cbc_ctr_vectors_and_padding(self):
        key = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
        plain = bytes.fromhex('00112233445566778899aabbccddeeff')
        encrypted = AES.new(key, AES.MODE_ECB).encrypt(plain)
        self.assertEqual(encrypted.hex(), '69c4e0d86a7b0430d8cdb78070b4c55a')
        self.assertEqual(AES.new(key, AES.MODE_ECB).decrypt(encrypted), plain)

        key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        iv = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
        plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
        encrypted = AES.new(key, AES.MODE_CBC, iv).encrypt(plain)
        self.assertEqual(encrypted.hex(), '7649abac8119b246cee98e9b12e9197d')
        self.assertEqual(AES.new(key, AES.MODE_CBC, iv).decrypt(encrypted), plain)

        counter = bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff')
        encrypted = AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=counter).encrypt(plain)
        self.assertEqual(encrypted.hex(), '874d6191b620e3261bef6864990db6ce')
        self.assertEqual(AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=counter).decrypt(encrypted), plain)

        padded = Padding.pad(b'fixture payload', 16)
        self.assertEqual(len(padded) % 16, 0)
        self.assertEqual(Padding.unpad(padded, 16), b'fixture payload')
        with self.assertRaises(ValueError):
            Padding.unpad(padded[:-1] + b'\x00', 16)

    def test_ctr_keeps_partial_keystream_across_calls(self):
        key = bytes(range(16))
        initial_value = bytes(range(16, 32))
        payload = bytes(range(73))
        expected = AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=initial_value).encrypt(payload)
        cipher = AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=initial_value)
        split = cipher.encrypt(payload[:5]) + cipher.encrypt(payload[5:21]) + cipher.encrypt(payload[21:])
        self.assertEqual(split, expected)

    def test_rsa_spki_import_and_pkcs1_v15_encryption(self):
        encoded = base64.b64decode(
            'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr8SzZhjYy+rsya1K09t8d2K50pWFoBkgUqMpKOiW+'
            '3IEVKd4eTdvg9RSOjQ82kypL6R9BnsmrS1V8s4PVDwjQbUtYhTPPC9Hz16qY7rpD6m0d2vr09/UpWQ5u'
            'Oy9PR0QTrsioveZ+DIe9jc3C+zBCu/kZSY/R8stwJoiitki3gwIDAQAB')
        public_key = RSA.import_key(encoded)
        self.assertEqual(public_key.size_in_bytes(), 128)
        encryptor = PKCS1_v1_5.new(public_key)
        first = encryptor.encrypt(b'local fixture message')
        second = encryptor.encrypt(b'local fixture message')
        self.assertEqual(len(first), 128)
        self.assertLess(int.from_bytes(first, 'big'), public_key.n)
        self.assertNotEqual(first, second, 'PKCS#1 v1.5 encryption needs fresh non-zero padding')
        with self.assertRaises(ValueError):
            encryptor.encrypt(b'x' * 118)

    def test_malformed_rsa_der_is_rejected(self):
        with self.assertRaises(ValueError):
            RSA.import_key(b'\x30\x03\x02\x01\x01')


if __name__ == '__main__':
    unittest.main()
