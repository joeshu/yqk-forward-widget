"""Minimal PKCS#1 v1.5 RSA encryption API."""


class PKCS115Cipher:
    def __init__(self, key):
        if not callable(getattr(key, "encrypt", None)):
            raise TypeError("key must support RSA public-key encryption")
        self._key = key

    def encrypt(self, message):
        return self._key.encrypt(message)


def new(key):
    return PKCS115Cipher(key)
