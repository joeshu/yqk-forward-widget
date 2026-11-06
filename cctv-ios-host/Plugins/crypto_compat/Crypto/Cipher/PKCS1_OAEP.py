"""RSAES-OAEP encryption for public RSA keys."""

import hashlib
import secrets


def _hash_factory(hash_module):
    if hash_module is None:
        return hashlib.sha1
    if isinstance(hash_module, str):
        return lambda data=b"": hashlib.new(hash_module, data)
    if hasattr(hash_module, "new"):
        return hash_module.new
    return hash_module


def _mgf1(seed, length, hash_factory):
    digest_size = hash_factory().digest_size
    output = bytearray()
    for counter in range((length + digest_size - 1) // digest_size):
        output.extend(hash_factory(seed + counter.to_bytes(4, "big")).digest())
    return bytes(output[:length])


class PKCS1OAEP:
    def __init__(self, key, hashAlgo=None, mgfunc=None, label=b"", randfunc=None):
        self.key = key
        self.hash = _hash_factory(hashAlgo)
        self.mgf = mgfunc or (lambda seed, length: _mgf1(seed, length, self.hash))
        self.label = bytes(label)
        self.randfunc = randfunc or secrets.token_bytes

    def encrypt(self, message):
        message = bytes(message)
        k = self.key.size_in_bytes()
        hlen = self.hash().digest_size
        if len(message) > k - 2 * hlen - 2:
            raise ValueError("message is too long")
        data_block = self.hash(self.label).digest() + bytes(k - len(message) - 2 * hlen - 2) + b"\x01" + message
        seed = self.randfunc(hlen)
        if len(seed) != hlen:
            raise ValueError("randfunc returned an incorrect number of bytes")
        masked_db = bytes(a ^ b for a, b in zip(data_block, self.mgf(seed, k - hlen - 1)))
        masked_seed = bytes(a ^ b for a, b in zip(seed, self.mgf(masked_db, hlen)))
        encoded = b"\x00" + masked_seed + masked_db
        return pow(int.from_bytes(encoded, "big"), self.key.e, self.key.n).to_bytes(k, "big")


def new(key, hashAlgo=None, mgfunc=None, label=b"", randfunc=None):
    return PKCS1OAEP(key, hashAlgo, mgfunc, label, randfunc)
