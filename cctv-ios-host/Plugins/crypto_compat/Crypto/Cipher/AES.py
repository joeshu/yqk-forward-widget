"""PyCryptodome-shaped AES modes backed by the bundled pure-Python AES core."""

import struct

from ._aes_core import AES as _AESCore, ctr_xor as _ctr_xor

MODE_ECB = 1
MODE_CBC = 2
MODE_CFB = 3
MODE_OFB = 5
MODE_CTR = 6
MODE_EAX = 9
MODE_GCM = 11
block_size = 16


def _bytes(value, label):
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise TypeError("%s must be bytes-like" % label)
    return bytes(value)


class _Cipher:
    def __init__(self, key, mode, iv=None, nonce=None, initial_value=None,
                 segment_size=8, mac_len=16, counter=None):
        self.key = _bytes(key, "key")
        if len(self.key) not in (16, 24, 32):
            raise ValueError("AES key must be 16, 24, or 32 bytes long")
        self.mode = mode
        self._aes = _AESCore(self.key)
        self._iv = None
        self._counter = None
        self._counter_modulus = None
        self._keystream = b""
        self._segment_size = segment_size
        self._stream_register = None
        self._cfb_segment = bytearray()
        self._operation = None
        self._finalized = False
        self._aad = bytearray()
        self._authenticated_data = bytearray()
        self._tag = None
        self._mac_len = mac_len
        self._gcm_h = None
        self._gcm_j0 = None
        self._eax_nonce_mac = None
        if mode == MODE_ECB:
            if iv is not None or nonce is not None or initial_value is not None or counter is not None:
                raise TypeError("ECB mode does not use an IV or counter")
        elif mode == MODE_CBC:
            if nonce is not None or initial_value is not None or counter is not None:
                raise TypeError("CBC mode accepts an IV only")
            self._iv = _bytes(iv, "iv")
            if len(self._iv) != block_size:
                raise ValueError("CBC IV must be 16 bytes long")
        elif mode == MODE_CTR:
            if iv is not None:
                raise TypeError("CTR mode accepts nonce and initial_value, not iv")
            if counter is not None:
                if nonce is not None or initial_value is not None:
                    raise TypeError("counter cannot be combined with nonce or initial_value")
                if not isinstance(counter, dict):
                    raise TypeError("counter must be created by Crypto.Util.Counter.new")
                counter_size = counter.get("counter_len")
                prefix = _bytes(counter.get("prefix", b""), "counter prefix")
                suffix = _bytes(counter.get("suffix", b""), "counter suffix")
                if not isinstance(counter_size, int) or counter_size <= 0 or len(prefix) + counter_size + len(suffix) != block_size:
                    raise ValueError("counter fields must total 16 bytes")
                initial_value = counter.get("initial_value", 1)
                little_endian = bool(counter.get("little_endian", False))
                if not isinstance(initial_value, int) or not 0 <= initial_value < (1 << (counter_size * 8)):
                    raise ValueError("initial counter value does not fit")
                self._counter_prefix, self._counter_suffix = prefix, suffix
                self._counter_bytes = counter_size
                self._counter_little_endian = little_endian
            else:
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
                self._counter_prefix, self._counter_suffix = nonce, b""
                self._counter_bytes = counter_size
                self._counter_little_endian = False
            self._counter_modulus = 1 << (self._counter_bytes * 8)
            if initial_value >= self._counter_modulus:
                raise ValueError("initial_value does not fit in the counter field")
            self._counter = initial_value
        elif mode in (MODE_CFB, MODE_OFB):
            if nonce is not None or initial_value is not None or counter is not None:
                raise TypeError("CFB/OFB mode accepts an IV only")
            self._iv = _bytes(iv, "iv")
            if len(self._iv) != block_size:
                raise ValueError("IV must be 16 bytes long")
            self._stream_register = self._iv
            if mode == MODE_CFB and (not isinstance(segment_size, int) or segment_size < 8 or segment_size > 128 or segment_size % 8):
                raise ValueError("segment_size must be a positive multiple of 8 no larger than 128")
        elif mode in (MODE_GCM, MODE_EAX):
            if iv is not None or initial_value is not None or counter is not None:
                raise TypeError("AEAD modes accept nonce, not iv or counter")
            if nonce is None:
                from ..Random import get_random_bytes
                nonce = get_random_bytes(16)
            self.nonce = _bytes(nonce, "nonce")
            if not isinstance(mac_len, int) or not 4 <= mac_len <= block_size:
                raise ValueError("mac_len must be between 4 and 16 bytes")
            if mode == MODE_GCM:
                self._gcm_h = int.from_bytes(self._encrypt_block(bytes(block_size)), "big")
                nonce_int = int.from_bytes(self.nonce, "big")
                if len(self.nonce) == 12:
                    self._gcm_j0 = nonce_int << 32 | 1
                else:
                    self._gcm_j0 = _ghash(self._gcm_h, b"", self.nonce)
                self._counter = self._gcm_j0
            else:
                self._eax_nonce_mac = _omac(self._aes, self._encrypt_block, 0, self.nonce)
                self._counter = 0
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
            # Keep the word-oriented fast path for the common full-width counter.
            if self._counter_bytes == block_size and not self._counter_prefix and not self._counter_suffix and not self._counter_little_endian:
                counter_block = self._counter_block()
                full_data = data if pos == 0 and full == len(data) else data[pos:pos + full]
                out.extend(_ctr_xor(self.key, counter_block, full_data))
                self._counter = (self._counter + full // block_size) % self._counter_modulus
                pos += full
            else:
                end = pos + full
                while pos < end:
                    stream = self._encrypt_block(self._counter_block())
                    out.extend(a ^ b for a, b in zip(data[pos:pos + block_size], stream))
                    self._counter = (self._counter + 1) % self._counter_modulus
                    pos += block_size
        if pos < len(data):
            counter_block = self._counter_block()
            stream = self._encrypt_block(counter_block)
            tail = data[pos:]
            out.extend(a ^ b for a, b in zip(tail, stream))
            self._keystream = stream[len(tail):]
            self._counter = (self._counter + 1) % self._counter_modulus
        return bytes(out)

    def _counter_block(self):
        order = "little" if self._counter_little_endian else "big"
        value = self._counter.to_bytes(self._counter_bytes, order)
        return self._counter_prefix + value + self._counter_suffix

    def _stream(self, data, decrypt=False):
        out = bytearray()
        if self.mode == MODE_OFB:
            while data:
                if not self._keystream:
                    self._stream_register = self._encrypt_block(self._stream_register)
                    self._keystream = self._stream_register
                take = min(len(data), len(self._keystream))
                out.extend(a ^ b for a, b in zip(data[:take], self._keystream[:take]))
                self._keystream = self._keystream[take:]
                data = data[take:]
            return bytes(out)
        segment = self._segment_size // 8
        while data:
            if not self._keystream:
                self._keystream = self._encrypt_block(self._stream_register)
            take = min(segment - len(self._cfb_segment), len(data), len(self._keystream))
            source = data[:take]
            transformed = bytes(a ^ b for a, b in zip(source, self._keystream[:take]))
            out.extend(transformed)
            self._cfb_segment.extend(source if decrypt else transformed)
            self._keystream = self._keystream[take:]
            if len(self._cfb_segment) == segment:
                self._stream_register = self._stream_register[segment:] + self._cfb_segment
                self._cfb_segment.clear()
                self._keystream = b""
            data = data[take:]
        return bytes(out)

    def _gcm_crypt(self, data):
        out = bytearray()
        if self._keystream:
            take = min(len(data), len(self._keystream))
            out.extend(a ^ b for a, b in zip(data[:take], self._keystream[:take]))
            self._authenticated_data.extend(data[:take] if self._operation == "decrypt" else out[-take:])
            self._keystream = self._keystream[take:]
            data = data[take:]
        while data:
            self._counter = (self._counter & ~0xffffffff) | (((self._counter & 0xffffffff) + 1) & 0xffffffff)
            self._keystream = self._encrypt_block(self._counter.to_bytes(block_size, "big"))
            take = min(len(data), block_size)
            chunk = bytes(a ^ b for a, b in zip(data[:take], self._keystream[:take]))
            out.extend(chunk)
            self._authenticated_data.extend(data[:take] if self._operation == "decrypt" else chunk)
            self._keystream = self._keystream[take:]
            data = data[take:]
        return bytes(out)

    def _eax_crypt(self, data):
        out = bytearray()
        while data:
            if not self._keystream:
                counter = (int.from_bytes(self._eax_nonce_mac, "big") + self._counter) % (1 << 128)
                self._keystream = self._encrypt_block(counter.to_bytes(block_size, "big"))
                self._counter = (self._counter + 1) % (1 << 128)
            take = min(len(data), len(self._keystream))
            transformed = bytes(a ^ b for a, b in zip(data[:take], self._keystream[:take]))
            out.extend(transformed)
            self._authenticated_data.extend(data[:take] if self._operation == "decrypt" else transformed)
            self._keystream = self._keystream[take:]
            data = data[take:]
        return bytes(out)

    def update(self, assoc_data):
        data = _bytes(assoc_data, "associated data")
        if self.mode not in (MODE_GCM, MODE_EAX):
            raise TypeError("update is available only for AEAD modes")
        if self._operation is not None or self._finalized:
            raise TypeError("associated data must be supplied before the message")
        self._aad.extend(data)
        return self

    def encrypt(self, plaintext):
        data = _bytes(plaintext, "plaintext")
        if self.mode == MODE_CTR:
            return self._ctr(data)
        if self.mode == MODE_CFB or self.mode == MODE_OFB:
            return self._stream(data)
        if self.mode in (MODE_GCM, MODE_EAX):
            if self._finalized:
                raise TypeError("message authentication has already been finalized")
            if self._operation == "decrypt":
                raise TypeError("encrypt and decrypt cannot be mixed")
            self._operation = "encrypt"
            return self._gcm_crypt(data) if self.mode == MODE_GCM else self._eax_crypt(data)
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
        if self.mode in (MODE_CFB, MODE_OFB):
            return self._stream(data, decrypt=True)
        if self.mode in (MODE_GCM, MODE_EAX):
            if self._finalized:
                raise TypeError("message authentication has already been finalized")
            if self._operation == "encrypt":
                raise TypeError("encrypt and decrypt cannot be mixed")
            self._operation = "decrypt"
            return self._gcm_crypt(data) if self.mode == MODE_GCM else self._eax_crypt(data)
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

    def digest(self):
        if self.mode not in (MODE_GCM, MODE_EAX):
            raise TypeError("digest is available only for AEAD modes")
        if self._operation == "decrypt":
            raise TypeError("digest() cannot be called when decrypting a message")
        if self._tag is None:
            self._tag = self._calculate_tag()
        self._finalized = True
        return self._tag

    def _calculate_tag(self):
        if self.mode == MODE_GCM:
            auth = _ghash(self._gcm_h, bytes(self._aad), bytes(self._authenticated_data))
            mask = int.from_bytes(self._encrypt_block(self._gcm_j0.to_bytes(block_size, "big")), "big")
            return (mask ^ auth).to_bytes(block_size, "big")[:self._mac_len]
        header_mac = _omac(self._aes, self._encrypt_block, 1, bytes(self._aad))
        data_mac = _omac(self._aes, self._encrypt_block, 2, bytes(self._authenticated_data))
        return bytes(a ^ b ^ c for a, b, c in zip(self._eax_nonce_mac, header_mac, data_mac))[:self._mac_len]

    def hexdigest(self):
        return self.digest().hex()

    def verify(self, received_mac_tag):
        import hmac
        if self.mode not in (MODE_GCM, MODE_EAX):
            raise TypeError("verify is available only for AEAD modes")
        if self._operation != "decrypt":
            raise TypeError("verify() can only be called after decrypting a message")
        received = _bytes(received_mac_tag, "MAC tag")
        expected = self._calculate_tag()
        self._finalized = True
        if not hmac.compare_digest(expected, received):
            raise ValueError("MAC check failed")

    def hexverify(self, hex_mac_tag):
        try:
            tag = bytes.fromhex(hex_mac_tag)
        except (TypeError, ValueError):
            raise ValueError("invalid hexadecimal MAC tag") from None
        self.verify(tag)

    def encrypt_and_digest(self, plaintext):
        ciphertext = self.encrypt(plaintext)
        return ciphertext, self.digest()

    def decrypt_and_verify(self, ciphertext, received_mac_tag):
        plaintext = self.decrypt(ciphertext)
        self.verify(received_mac_tag)
        return plaintext


def _gf_multiply(x, y):
    z, v = 0, y
    for bit in range(127, -1, -1):
        if (x >> bit) & 1:
            z ^= v
        v = (v >> 1) ^ (0xe1000000000000000000000000000000 if v & 1 else 0)
    return z


def _ghash(h, aad, data):
    value = 0
    for source in (aad, data):
        for pos in range(0, len(source), block_size):
            block = source[pos:pos + block_size].ljust(block_size, b"\x00")
            value = _gf_multiply(value ^ int.from_bytes(block, "big"), h)
    lengths = (len(aad) * 8).to_bytes(8, "big") + (len(data) * 8).to_bytes(8, "big")
    return _gf_multiply(value ^ int.from_bytes(lengths, "big"), h)


def _double(block):
    value = int.from_bytes(block, "big")
    value = ((value << 1) & ((1 << 128) - 1)) ^ (0x87 if value >> 127 else 0)
    return value.to_bytes(block_size, "big")


def _cmac(aes, encrypt_block, message):
    zero = bytes(block_size)
    k1 = _double(encrypt_block(zero))
    k2 = _double(k1)
    complete = bool(message) and len(message) % block_size == 0
    blocks = [message[pos:pos + block_size] for pos in range(0, len(message), block_size)]
    if not blocks:
        blocks = [b""]
    last = blocks.pop()
    if complete:
        last = bytes(a ^ b for a, b in zip(last, k1))
    else:
        last = bytes(a ^ b for a, b in zip(last + b"\x80" + bytes(block_size - len(last) - 1), k2))
    state = zero
    for block in blocks:
        state = encrypt_block(bytes(a ^ b for a, b in zip(state, block)))
    return encrypt_block(bytes(a ^ b for a, b in zip(state, last)))


def _omac(aes, encrypt_block, domain, message):
    return _cmac(aes, encrypt_block, bytes(block_size - 1) + bytes((domain,)) + message)


def new(key, mode, iv=None, nonce=None, initial_value=None, **kwargs):
    segment_size = kwargs.pop("segment_size", 8)
    mac_len = kwargs.pop("mac_len", 16)
    counter = kwargs.pop("counter", None)
    for ignored in ("assoc_len", "msg_len", "use_aesni"):
        kwargs.pop(ignored, None)
    if kwargs:
        raise TypeError("unsupported AES option: %s" % next(iter(kwargs)))
    return _Cipher(key, mode, iv=iv, nonce=nonce, initial_value=initial_value,
                   segment_size=segment_size, mac_len=mac_len, counter=counter)
