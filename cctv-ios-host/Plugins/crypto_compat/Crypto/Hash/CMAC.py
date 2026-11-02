"""AES-CMAC API compatible with Crypto.Hash.CMAC."""

import hmac

from ..Cipher import AES
from ..Cipher.AES import _cmac


class CMAC:
    digest_size = 16
    block_size = 16

    def __init__(self, key, msg=None, ciphermod=AES, cipher_params=None, mac_len=None):
        if ciphermod is not AES:
            raise ValueError("only AES-CMAC is available")
        if cipher_params:
            raise TypeError("unsupported AES-CMAC cipher parameters")
        self._cipher = AES.new(key, AES.MODE_ECB)
        self._message = bytearray()
        self._mac_len = self.digest_size if mac_len is None else mac_len
        if not isinstance(self._mac_len, int) or not 4 <= self._mac_len <= self.digest_size:
            raise ValueError("mac_len must be between 4 and 16 bytes")
        if msg is not None:
            self.update(msg)

    def update(self, msg):
        self._message.extend(msg)
        return self

    def digest(self):
        return _cmac(self._cipher._aes, self._cipher._encrypt_block, bytes(self._message))[:self._mac_len]

    def hexdigest(self):
        return self.digest().hex()

    def verify(self, mac_tag):
        if not hmac.compare_digest(self.digest(), bytes(mac_tag)):
            raise ValueError("MAC check failed")

    def hexverify(self, hex_mac_tag):
        try:
            tag = bytes.fromhex(hex_mac_tag)
        except (TypeError, ValueError):
            raise ValueError("invalid hexadecimal MAC tag") from None
        self.verify(tag)

    def copy(self):
        other = object.__new__(CMAC)
        other._cipher = AES.new(self._cipher.key, AES.MODE_ECB)
        other._message = self._message.copy()
        other._mac_len = self._mac_len
        return other


def new(key, msg=None, ciphermod=AES, cipher_params=None, mac_len=None, **kwargs):
    if kwargs:
        raise TypeError("unsupported CMAC option: %s" % next(iter(kwargs)))
    return CMAC(key, msg, ciphermod, cipher_params, mac_len)
