"""Portable fallback for the iOS built-in ``hostcrypto`` module.

The app registers a built-in module backed by CommonCrypto before Python starts,
so this file is used only by desktop harnesses and source-level tests.
"""

backend = 'python-fallback'
available = True


class AES_CTR:
    """Stateful AES-128-CTR transform with a 16-byte big-endian counter block."""

    def __init__(self, key, iv):
        key, iv = bytes(key), bytes(iv)
        if len(key) != 16 or len(iv) != 16:
            raise ValueError('AES_CTR requires a 16-byte key and a 16-byte counter block')
        from Crypto.Cipher import AES
        self._cipher = AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=iv)

    def update(self, data):
        if self._cipher is None:
            raise RuntimeError('AES_CTR context is closed')
        return self._cipher.decrypt(bytes(data))

    def close(self):
        self._cipher = None
