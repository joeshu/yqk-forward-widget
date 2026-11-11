"""Minimal PKCS#1 v1.5 RSA encryption and decryption API."""


class PKCS115Cipher:
    def __init__(self, key):
        if not callable(getattr(key, "encrypt", None)):
            raise TypeError("key must support RSA public-key encryption")
        self._key = key

    def encrypt(self, message):
        return self._key.encrypt(message)

    def decrypt(self, ciphertext, sentinel=None):
        decrypt = getattr(self._key, "decrypt", None)
        if not callable(decrypt) or getattr(self._key, "d", None) is None:
            raise TypeError("key must support RSA private-key decryption")
        try:
            encoded = decrypt(ciphertext)
            if not isinstance(encoded, (bytes, bytearray, memoryview)):
                raise ValueError("RSA decryption returned an invalid block")
            encoded = bytes(encoded)
            if len(encoded) < 11 or encoded[:2] != b"\x00\x02":
                raise ValueError("invalid PKCS#1 v1.5 encryption block")
            separator = encoded.find(b"\x00", 2)
            if separator < 10:
                raise ValueError("invalid PKCS#1 v1.5 padding")
            return encoded[separator + 1:]
        except (TypeError, ValueError, OverflowError):
            return sentinel


def new(key):
    return PKCS115Cipher(key)
