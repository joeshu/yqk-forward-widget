"""DER/PEM RSA public-key import and PKCS#1 v1.5 encryption."""

import base64
import re
import secrets


_RSA_ENCRYPTION_OID = b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"


def _tlv(data, offset):
    if offset >= len(data):
        raise ValueError("truncated DER value")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise ValueError("truncated DER length")
    length = data[offset]
    offset += 1
    if length & 0x80:
        count = length & 0x7f
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("invalid DER length")
        if data[offset] == 0:
            raise ValueError("non-canonical DER length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
        if length < 0x80:
            raise ValueError("non-canonical DER length")
    end = offset + length
    if end > len(data):
        raise ValueError("truncated DER payload")
    return tag, offset, end


def _sequence(data):
    tag, start, end = _tlv(data, 0)
    if tag != 0x30 or end != len(data):
        raise ValueError("invalid RSA DER sequence")
    return data[start:end]


def _integers(sequence):
    values = []
    offset = 0
    while offset < len(sequence):
        tag, start, end = _tlv(sequence, offset)
        if tag != 0x02 or start == end or sequence[start] & 0x80:
            raise ValueError("invalid RSA integer")
        values.append(int.from_bytes(sequence[start:end], "big"))
        offset = end
    return values


def _parse_pkcs1(data):
    values = _integers(_sequence(data))
    if len(values) >= 3 and values[0] in (0, 1):
        # PKCS#1 private-key form begins with a version, then n and e.
        n, e = values[1], values[2]
    elif len(values) >= 2:
        n, e = values[0], values[1]
    else:
        raise ValueError("RSA key does not contain modulus and exponent")
    return n, e


def _parse_der(data):
    body = _sequence(data)
    try:
        n, e = _parse_pkcs1(data)
        if n > 1 and e > 1:
            return n, e
    except ValueError:
        pass

    tag, alg_start, alg_end = _tlv(body, 0)
    if tag != 0x30:
        raise ValueError("unsupported RSA public-key encoding")
    oid_tag, oid_start, oid_end = _tlv(body[alg_start:alg_end], 0)
    if oid_tag != 0x06 or body[alg_start + oid_start:alg_start + oid_end] != _RSA_ENCRYPTION_OID:
        raise ValueError("DER key is not an RSA public key")
    bit_tag, bit_start, bit_end = _tlv(body, alg_end)
    if bit_tag != 0x03 or bit_start == bit_end or body[bit_start] != 0:
        raise ValueError("invalid RSA SubjectPublicKeyInfo")
    return _parse_pkcs1(body[bit_start + 1:bit_end])


class RsaKey:
    def __init__(self, n, e):
        if not isinstance(n, int) or not isinstance(e, int) or n <= 1 or e <= 1 or not e & 1:
            raise ValueError("invalid RSA public modulus or exponent")
        self.n, self.e = n, e
        self._size = (n.bit_length() + 7) // 8

    def size_in_bytes(self):
        return self._size

    def encrypt(self, message):
        if not isinstance(message, (bytes, bytearray, memoryview)):
            raise TypeError("RSA plaintext must be bytes-like")
        message = bytes(message)
        padding_size = self._size - len(message) - 3
        if padding_size < 8:
            raise ValueError("RSA message is too long for PKCS#1 v1.5")
        padding = bytearray()
        while len(padding) < padding_size:
            padding.extend(value for value in secrets.token_bytes(padding_size - len(padding) + 8) if value)
        encoded = b"\x00\x02" + bytes(padding[:padding_size]) + b"\x00" + message
        encrypted = pow(int.from_bytes(encoded, "big"), self.e, self.n)
        return encrypted.to_bytes(self._size, "big")


def import_key(extern_key, passphrase=None, **kwargs):
    if passphrase is not None or kwargs:
        raise ValueError("private-key options are not supported by this public-key shim")
    if isinstance(extern_key, str):
        extern_key = extern_key.encode("ascii")
    if not isinstance(extern_key, (bytes, bytearray, memoryview)):
        raise TypeError("RSA key must be bytes or text")
    data = bytes(extern_key).strip()
    if data.startswith(b"-----BEGIN"):
        match = re.search(rb"-----BEGIN [^-]+-----(.*?)-----END [^-]+-----", data, re.S)
        if not match:
            raise ValueError("invalid RSA PEM data")
        data = base64.b64decode(re.sub(rb"\s+", b"", match.group(1)), validate=True)
    n, e = _parse_der(data)
    return RsaKey(n, e)
