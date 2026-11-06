"""HMAC API shaped like Crypto.Hash.HMAC."""

import hashlib
import hmac


class HMAC:
    def __init__(self, key, msg=None, digestmod=None):
        if digestmod is None:
            digestmod = hashlib.sha1
        if isinstance(digestmod, str):
            digestmod = digestmod.lower().replace("-", "")
        elif hasattr(digestmod, "new"):
            hash_module = digestmod
            digestmod = lambda data=b"": hash_module.new(data)
        if msg is None:
            msg = b""
        self._mac = hmac.new(key, msg, digestmod)
        self.digest_size = self._mac.digest_size
        self.block_size = self._mac.block_size

    def update(self, msg):
        self._mac.update(msg)
        return self

    def digest(self):
        return self._mac.digest()

    def hexdigest(self):
        return self._mac.hexdigest()

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
        duplicate = object.__new__(HMAC)
        duplicate._mac = self._mac.copy()
        duplicate.digest_size = self.digest_size
        duplicate.block_size = self.block_size
        return duplicate


def new(key, msg=None, digestmod=None, **kwargs):
    if kwargs:
        raise TypeError("unsupported HMAC option: %s" % next(iter(kwargs)))
    return HMAC(key, msg, digestmod)
