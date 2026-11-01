"""PyCryptodome-shaped AES modes backed by the bundled pure-Python AES core."""

import struct

from ._aes_core import AES as _AESCore, ctr_xor as _ctr_xor

MODE_ECB = 1
MODE_CBC = 2
MODE_CTR = 6
block_size = 16


def _bytes(value, label):
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise TypeError("%s must be bytes-like" % label)
    return bytes(value)


class _Cipher:
    def __init__(self, key, mode, iv=None, nonce=None, initial_value=None):
        self.key = _bytes(key, "key")
        if len(self.key) not in (16, 24, 32):
            raise ValueError("AES key must be 16, 24, or 32 bytes long")
        self.mode = mode
        self._aes = _AESCore(self.key)
        self._iv = None
        self._counter = None
        self._counter_modulus = None
        self._keystream = b""
        if mode == MODE_ECB:
            if iv is not None or nonce is not None or initial_value is not None:
                raise TypeError("ECB mode does not use an IV or counter")
        elif mode == MODE_CBC:
            if nonce is not None or initial_value is not None:
                raise TypeError("CBC mode accepts an IV only")
            self._iv = _bytes(iv, "iv")
            if len(self._iv) != block_size:
                raise ValueError("CBC IV must be 16 bytes long")
        elif mode == MODE_CTR:
            if iv is not None:
                raise TypeError("CTR mode accepts nonce and initial_value, not iv")
            nonce = b"" if nonce is None else _bytes(nonce, "nonce")
            if len(nonce) >= block_size:
                raise ValueError("CTR nonce must be shorter than 16 bytes")
            counter_size = block_size - len(nonce)
            if initial_value is None:
                initial_value = 0
            if isinstance(initial_value, (bytes, bytearray, memoryview)):
                initial_value = bytes(initial_value)
                if len(initial_value) != counter_size:
                    raise ValueError("initial_value must fill the counter field")
                initial_value = int.from_bytes(initial_value, "big")
            if not isinstance(initial_value, int) or initial_value < 0:
                raise ValueError("initial_value must be a non-negative integer or bytes")
            self._counter_modulus = 1 << (counter_size * 8)
            if initial_value >= self._counter_modulus:
                raise ValueError("initial_value does not fit in the counter field")
            self._nonce = nonce
            self._counter = initial_value
        else:
            raise ValueError("unsupported AES mode")

    def _encrypt_block(self, block):
        words = struct.unpack(">4I", block)
        return struct.pack(">4I", *self._aes.encrypt_block(*words))

    def _decrypt_block(self, block):
        words = struct.unpack(">4I", block)
        return struct.pack(">4I", *self._aes.decrypt_block(*words))

    def _ctr(self, data):
        out = bytearray()
        pos = 0
        if self._keystream:
            take = min(len(data), len(self._keystream))
            out.extend(a ^ b for a, b in zip(data[:take], self._keystream[:take]))
            self._keystream = self._keystream[take:]
            pos = take
        full = (len(data) - pos) // block_size * block_size
        if full:
            counter_block = self._nonce + self._counter.to_bytes(block_size - len(self._nonce), "big")
            full_data = data if pos == 0 and full == len(data) else data[pos:pos + full]
            out.extend(_ctr_xor(self.key, counter_block, full_data))
            self._counter = (self._counter + full // block_size) % self._counter_modulus
            pos += full
        if pos < len(data):
            counter_block = self._nonce + self._counter.to_bytes(block_size - len(self._nonce), "big")
            stream = self._encrypt_block(counter_block)
            tail = data[pos:]
            out.extend(a ^ b for a, b in zip(tail, stream))
            self._keystream = stream[len(tail):]
            self._counter = (self._counter + 1) % self._counter_modulus
        return bytes(out)

    def encrypt(self, plaintext):
        data = _bytes(plaintext, "plaintext")
        if self.mode == MODE_CTR:
            return self._ctr(data)
        if len(data) % block_size:
            raise ValueError("data length must be a multiple of 16 bytes")
        out = bytearray()
        for pos in range(0, len(data), block_size):
            block = data[pos:pos + block_size]
            if self.mode == MODE_CBC:
                block = bytes(a ^ b for a, b in zip(block, self._iv))
            block = self._encrypt_block(block)
            out.extend(block)
            if self.mode == MODE_CBC:
                self._iv = block
        return bytes(out)

    def decrypt(self, ciphertext):
        data = _bytes(ciphertext, "ciphertext")
        if self.mode == MODE_CTR:
            return self._ctr(data)
        if len(data) % block_size:
            raise ValueError("data length must be a multiple of 16 bytes")
        out = bytearray()
        for pos in range(0, len(data), block_size):
            block = data[pos:pos + block_size]
            plain = self._decrypt_block(block)
            if self.mode == MODE_CBC:
                plain = bytes(a ^ b for a, b in zip(plain, self._iv))
                self._iv = block
            out.extend(plain)
        return bytes(out)


def new(key, mode, iv=None, nonce=None, initial_value=None, **kwargs):
    if kwargs:
        raise TypeError("unsupported AES option: %s" % next(iter(kwargs)))
    return _Cipher(key, mode, iv=iv, nonce=nonce, initial_value=initial_value)
