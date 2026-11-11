import base64
import importlib
import importlib.util
from pathlib import Path
import sys
import unittest


COMPAT_ROOT = Path(__file__).resolve().parents[1] / 'Plugins' / 'crypto_compat' / 'Crypto'
COMPAT_PARENT = COMPAT_ROOT.parent
PACKAGE_NAME = '_cctvhost_crypto_compat_test'
spec = importlib.util.spec_from_file_location(
    PACKAGE_NAME, COMPAT_ROOT / '__init__.py',
    submodule_search_locations=[str(COMPAT_ROOT)])
crypto = importlib.util.module_from_spec(spec)
sys.modules[PACKAGE_NAME] = crypto
spec.loader.exec_module(crypto)
AES = importlib.import_module(PACKAGE_NAME + '.Cipher.AES')
ARC4 = importlib.import_module(PACKAGE_NAME + '.Cipher.ARC4')
PKCS1_v1_5 = importlib.import_module(PACKAGE_NAME + '.Cipher.PKCS1_v1_5')
RSA = importlib.import_module(PACKAGE_NAME + '.PublicKey.RSA')
Padding = importlib.import_module(PACKAGE_NAME + '.Util.Padding')
Counter = importlib.import_module(PACKAGE_NAME + '.Util.Counter')
strxor = importlib.import_module(PACKAGE_NAME + '.Util.strxor')
SHA256 = importlib.import_module(PACKAGE_NAME + '.Hash.SHA256')
HMAC = importlib.import_module(PACKAGE_NAME + '.Hash.HMAC')
CMAC = importlib.import_module(PACKAGE_NAME + '.Hash.CMAC')
KDF = importlib.import_module(PACKAGE_NAME + '.Protocol.KDF')
PKCS1_OAEP = importlib.import_module(PACKAGE_NAME + '.Cipher.PKCS1_OAEP')


def der(tag, payload):
    size = len(payload)
    if size < 0x80:
        length = bytes([size])
    else:
        raw = size.to_bytes((size.bit_length() + 7) // 8, 'big')
        length = bytes([0x80 | len(raw)]) + raw
    return bytes([tag]) + length + payload


def der_integer(value):
    raw = value.to_bytes((value.bit_length() + 7) // 8 or 1, 'big')
    if raw[0] & 0x80:
        raw = b'\x00' + raw
    return der(0x02, raw)


def rsa_private_fixture():
    # Mersenne primes make a deterministic, dependency-free test key. This is
    # test-only material and is unrelated to any attached provider key.
    p, q = (1 << 521) - 1, (1 << 607) - 1
    n, e = p * q, 65537
    lam = __import__('math').lcm(p - 1, q - 1)
    d = pow(e, -1, lam)
    dmp1, dmq1, iqmp = d % (p - 1), d % (q - 1), pow(q, -1, p)
    fields = (0, n, e, d, p, q, dmp1, dmq1, iqmp)
    pkcs1 = der(0x30, b''.join(der_integer(value) for value in fields))
    algorithm = der(0x30, bytes.fromhex('06092a864886f70d0101010500'))
    pkcs8 = der(0x30, der_integer(0) + algorithm + der(0x04, pkcs1))
    return pkcs1, pkcs8

cryptodomex_spec = importlib.util.spec_from_file_location(
    'Cryptodome', COMPAT_PARENT / 'Cryptodome' / '__init__.py',
    submodule_search_locations=[str(COMPAT_PARENT / 'Cryptodome')])
cryptodomex = importlib.util.module_from_spec(cryptodomex_spec)
sys.modules['Cryptodome'] = cryptodomex
cryptodomex_spec.loader.exec_module(cryptodomex)


class CryptoCompatibilityTests(unittest.TestCase):
    def test_arc4_rfc_6229_vector_and_drop_parameter(self):
        cipher = ARC4.new(b'Key')
        self.assertEqual(cipher.encrypt(b'Plaintext').hex(), 'bbf316e8d940af0ad3')

        self.assertEqual(ARC4.new(b'Wiki').encrypt(b'pedia').hex(), '1021bf0420')
        ciphertext = ARC4.new(b'Wiki').encrypt(bytes(24))
        self.assertEqual(ciphertext[:8].hex(), '6044db6d41b7e8e7')
        dropped = ARC4.new(b'Wiki', drop=16).encrypt(bytes(8))
        self.assertEqual(dropped, ciphertext[16:24])
        self.assertEqual(ARC4.new(b'Wiki').decrypt(ciphertext), bytes(24))

    def test_arc4_rejects_invalid_parameters(self):
        for key in (b'', bytes(257), 'text'):
            with self.assertRaises((TypeError, ValueError)):
                ARC4.new(key)
        for drop in (-1, 1.5, True, 1_000_001):
            with self.assertRaises(ValueError):
                ARC4.new(b'key', drop=drop)

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

    def test_aes_cfb_and_ofb_standard_vectors(self):
        key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        iv = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
        plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
        expected = bytes.fromhex('3b3fd92eb72dad20333449f8e83cfb4a')
        for mode in (AES.MODE_CFB, AES.MODE_OFB):
            encrypted = AES.new(key, mode, iv=iv, segment_size=128).encrypt(plain)
            self.assertEqual(encrypted, expected)
            self.assertEqual(AES.new(key, mode, iv=iv, segment_size=128).decrypt(encrypted), plain)
        payload = bytes(range(51))
        for mode in (AES.MODE_CFB, AES.MODE_OFB):
            expected_stream = AES.new(key, mode, iv=iv, segment_size=128).encrypt(payload)
            streaming = AES.new(key, mode, iv=iv, segment_size=128)
            self.assertEqual(streaming.encrypt(payload[:5]) + streaming.encrypt(payload[5:19]) + streaming.encrypt(payload[19:]), expected_stream)

    def test_aes_gcm_nist_vector_and_split_updates(self):
        key, nonce = bytes(16), bytes(12)
        plain = bytes(16)
        expected_cipher = bytes.fromhex('0388dace60b6a392f328c2b971b2fe78')
        expected_tag = bytes.fromhex('ab6e47d42cec13bdf53a67b21257bddf')
        cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
        encrypted = cipher.encrypt(plain[:5]) + cipher.encrypt(plain[5:])
        self.assertEqual(encrypted, expected_cipher)
        self.assertEqual(cipher.digest(), expected_tag)
        decryptor = AES.new(key, AES.MODE_GCM, nonce=nonce)
        self.assertEqual(decryptor.decrypt_and_verify(encrypted, expected_tag), plain)
        with self.assertRaises(TypeError):
            decryptor.decrypt(b'additional data')
        with self.assertRaises(TypeError):
            AES.new(key, AES.MODE_GCM, nonce=nonce).verify(expected_tag)
        with self.assertRaises(ValueError):
            AES.new(key, AES.MODE_GCM, nonce=nonce).decrypt_and_verify(encrypted, bytes(16))

    def test_aes_eax_and_cmac_vectors(self):
        key = bytes.fromhex('233952dee4d5ed5f9b9c6d6ff80ff478')
        nonce = bytes.fromhex('62ec67f9c3a4a407fcb2a8c49031a8b3')
        header = bytes.fromhex('6bfb914fd07eae6b')
        plain = bytes.fromhex('f7fb')
        cipher = AES.new(key, AES.MODE_EAX, nonce=nonce)
        cipher.update(header)
        encrypted, tag = cipher.encrypt_and_digest(plain)
        self.assertEqual(encrypted.hex(), 'b001')
        self.assertEqual(tag.hex(), 'db59644a96009d3c8659fdf8922f97cb')
        decryptor = AES.new(key, AES.MODE_EAX, nonce=nonce)
        decryptor.update(header)
        self.assertEqual(decryptor.decrypt_and_verify(encrypted, tag), plain)

        mac = CMAC.new(bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c'))
        self.assertEqual(mac.hexdigest(), 'bb1d6929e95937287fa37d129b756746')

    def test_common_hash_hmac_kdf_and_util_apis(self):
        self.assertEqual(SHA256.new(b'abc').hexdigest(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        mac = HMAC.new(b'key', b'The quick brown fox jumps over the lazy dog', SHA256)
        self.assertEqual(mac.hexdigest(), 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8')
        mac.verify(bytes.fromhex(mac.hexdigest()))
        self.assertEqual(KDF.PBKDF2(b'password', b'salt', 20, 1).hex(), '0c60c80f961f0e71f3a9b524af6012062fe037a6')
        self.assertEqual(
            KDF.HKDF(bytes.fromhex('0b' * 22), 42,
                     salt=bytes.fromhex('000102030405060708090a0b0c'),
                     hashmod=SHA256,
                     context=bytes.fromhex('f0f1f2f3f4f5f6f7f8f9')).hex(),
            '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865')
        self.assertEqual(strxor.strxor(b'\x01\x02', b'\x03\x04'), b'\x02\x06')
        shake = importlib.import_module(PACKAGE_NAME + '.Hash.SHAKE128')
        self.assertEqual(shake.new(b'').hexdigest(16), '7f9c2ba4e88f827d616045507605853e')
        alias_aes = importlib.import_module('Cryptodome.Cipher.AES')
        self.assertEqual(alias_aes.new(bytes(16), alias_aes.MODE_ECB).encrypt(bytes(16)).hex(), '66e94bd4ef8a2c3b884cfa59ca342b2e')

    def test_ctr_counter_dictionary_and_oaep_encryption(self):
        key = bytes(range(16))
        counter = Counter.new(64, prefix=b'prefix00', initial_value=7)
        payload = bytes(range(39))
        encrypted = AES.new(key, AES.MODE_CTR, counter=counter).encrypt(payload)
        self.assertEqual(AES.new(key, AES.MODE_CTR, counter=counter).decrypt(encrypted), payload)

        nist_key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        nist_counter = Counter.new(64, prefix=bytes.fromhex('f0f1f2f3f4f5f6f7'), initial_value=0xf8f9fafbfcfdfeff)
        nist_plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
        self.assertEqual(AES.new(nist_key, AES.MODE_CTR, counter=nist_counter).encrypt(nist_plain).hex(), '874d6191b620e3261bef6864990db6ce')

        encoded = base64.b64decode(
            'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr8SzZhjYy+rsya1K09t8d2K50pWFoBkgUqMpKOiW+'
            '3IEVKd4eTdvg9RSOjQ82kypL6R9BnsmrS1V8s4PVDwjQbUtYhTPPC9Hz16qY7rpD6m0d2vr09/UpWQ5u'
            'Oy9PR0QTrsioveZ+DIe9jc3C+zBCu/kZSY/R8stwJoiitki3gwIDAQAB')
        public_key = RSA.import_key(encoded)
        oaep = PKCS1_OAEP.new(public_key, randfunc=lambda count: bytes(count))
        self.assertEqual(len(oaep.encrypt(b'local oaep fixture')), public_key.size_in_bytes())

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

    def test_rsa_pkcs1_v15_private_import_and_decryption(self):
        pkcs1, pkcs8 = rsa_private_fixture()
        for encoded in (pkcs1, pkcs8):
            with self.subTest(encoding='PKCS#1' if encoded is pkcs1 else 'PKCS#8'):
                private_key = RSA.import_key(encoded)
                cipher = PKCS1_v1_5.new(private_key)
                encrypted = cipher.encrypt(b'local provider fixture')
                self.assertEqual(cipher.decrypt(encrypted), b'local provider fixture')
                sentinel = object()
                self.assertIs(cipher.decrypt(bytes(private_key.size_in_bytes()), sentinel), sentinel)

        public = RSA.import_key(base64.b64decode(
            'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr8SzZhjYy+rsya1K09t8d2K50pWFoBkgUqMpKOiW+'
            '3IEVKd4eTdvg9RSOjQ82kypL6R9BnsmrS1V8s4PVDwjQbUtYhTPPC9Hz16qY7rpD6m0d2vr09/UpWQ5u'
            'Oy9PR0QTrsioveZ+DIe9jc3C+zBCu/kZSY/R8stwJoiitki3gwIDAQAB'))
        with self.assertRaises(TypeError):
            PKCS1_v1_5.new(public).decrypt(bytes(public.size_in_bytes()))

    def test_malformed_rsa_der_is_rejected(self):
        with self.assertRaises(ValueError):
            RSA.import_key(b'\x30\x03\x02\x01\x01')


if __name__ == '__main__':
    unittest.main()
