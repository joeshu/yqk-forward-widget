"""Pure-Python ARC4 compatibility for legacy TVBox Spider sources.

ARC4 is retained only for decoding existing provider protocols. New systems
should use a modern authenticated cipher.
"""

block_size = 1
key_size = tuple(range(1, 257))
_MAX_DROP = 1_000_000


def _bytes(value, label):
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise TypeError("%s must be bytes-like" % label)
    return bytes(value)


class _Cipher:
    def __init__(self, key, drop=0):
        key = _bytes(key, "key")
        if not 1 <= len(key) <= 256:
            raise ValueError("ARC4 key must be between 1 and 256 bytes long")
        if not isinstance(drop, int) or isinstance(drop, bool) or not 0 <= drop <= _MAX_DROP:
            raise ValueError("drop must be an integer from 0 to 1000000")

        state = list(range(256))
        j = 0
        for i in range(256):
            j = (j + state[i] + key[i % len(key)]) & 0xff
            state[i], state[j] = state[j], state[i]

        self._state = state
        self._i = 0
        self._j = 0
        self._discard(drop)

    def _next_byte(self):
        self._i = (self._i + 1) & 0xff
        self._j = (self._j + self._state[self._i]) & 0xff
        self._state[self._i], self._state[self._j] = (
            self._state[self._j], self._state[self._i])
        return self._state[(self._state[self._i] + self._state[self._j]) & 0xff]

    def _discard(self, count):
        for _ in range(count):
            self._next_byte()

    def encrypt(self, data):
        data = _bytes(data, "data")
        output = bytearray(len(data))
        for index, value in enumerate(data):
            output[index] = value ^ self._next_byte()
        return bytes(output)

    def decrypt(self, data):
        return self.encrypt(data)


def new(key, **kwargs):
    drop = kwargs.pop("drop", 0)
    if kwargs:
        raise TypeError("Unsupported ARC4 parameter: %s" % next(iter(kwargs)))
    return _Cipher(key, drop)
