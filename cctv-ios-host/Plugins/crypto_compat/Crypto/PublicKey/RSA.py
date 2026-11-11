"""DER/PEM RSA key import with PKCS#1 v1.5 encryption and decryption."""

import base64
import math
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
    def __init__(self, n, e, d=None, p=None, q=None, dmp1=None, dmq1=None, iqmp=None):
        if not isinstance(n, int) or not isinstance(e, int) or n <= 1 or e <= 1 or not e & 1:
            raise ValueError("invalid RSA public modulus or exponent")
        if d is not None and (not isinstance(d, int) or d <= 1):
            raise ValueError("invalid RSA private exponent")
        self.n, self.e = n, e
        self.d = d
        self.p, self.q = p, q
        self.dmp1, self.dmq1, self.iqmp = dmp1, dmq1, iqmp
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

    def decrypt(self, ciphertext):
        if self.d is None:
            raise TypeError("RSA private-key decryption requires a private key")
        if not isinstance(ciphertext, (bytes, bytearray, memoryview)):
            raise TypeError("RSA ciphertext must be bytes-like")
        ciphertext = bytes(ciphertext)
        if len(ciphertext) != self._size:
            raise ValueError("RSA ciphertext has an invalid length")
        value = int.from_bytes(ciphertext, "big")
        if value >= self.n:
            raise ValueError("RSA ciphertext representative is out of range")
        if (self.p and self.q and self.dmp1 and self.dmq1 and self.iqmp):
            # PKCS#1 private-key files include CRT parameters. Using them keeps
            # the pure-Python compatibility path quick for embedded spiders.
            first = pow(value, self.dmp1, self.p)
            second = pow(value, self.dmq1, self.q)
            correction = (self.iqmp * (first - second)) % self.p
            plain = (second + correction * self.q) % self.n
        else:
            plain = pow(value, self.d, self.n)
        return plain.to_bytes(self._size, "big")


def _sequence_fields(data):
    sequence = _sequence(data)
    fields = []
    offset = 0
    while offset < len(sequence):
        tag, start, end = _tlv(sequence, offset)
        fields.append((tag, sequence[start:end]))
        offset = end
    return fields


def _der_integer(value):
    if not value or value[0] & 0x80:
        raise ValueError("invalid RSA private-key integer")
    return int.from_bytes(value, "big")


def _parse_private_der(data):
    fields = _sequence_fields(data)
    # PKCS#8 PrivateKeyInfo wraps PKCS#1 RSAPrivateKey in an OCTET STRING.
    if (len(fields) == 3 and fields[0][0] == 0x02 and fields[1][0] == 0x30
            and fields[2][0] == 0x04):
        fields = _sequence_fields(fields[2][1])
    if len(fields) < 9 or any(tag != 0x02 for tag, _value in fields[:9]):
        raise ValueError("unsupported RSA private-key encoding")
    values = [_der_integer(value) for _tag, value in fields[:9]]
    if values[0] != 0:
        raise ValueError("multi-prime RSA private keys are not supported")
    _version, n, e, d, p, q, dmp1, dmq1, iqmp = values
    if min(n, e, d, p, q, dmp1, dmq1, iqmp) <= 1 or p * q != n:
        raise ValueError("invalid RSA private-key parameters")
    if d * e % math.lcm(p - 1, q - 1) != 1:
        raise ValueError("inconsistent RSA private exponent")
    if dmp1 != d % (p - 1) or dmq1 != d % (q - 1) or (iqmp * q) % p != 1:
        raise ValueError("inconsistent RSA CRT parameters")
    return RsaKey(n, e, d, p, q, dmp1, dmq1, iqmp)


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
    try:
        return _parse_private_der(data)
    except ValueError:
        pass
    n, e = _parse_der(data)
    return RsaKey(n, e)
