"""CTR counter descriptions compatible with Crypto.Util.Counter.new."""


def new(nbits, prefix=b"", suffix=b"", initial_value=1,
        little_endian=False, allow_wraparound=False):
    if not isinstance(nbits, int) or nbits <= 0 or nbits % 8:
        raise ValueError("nbits must be a positive multiple of 8")
    prefix, suffix = bytes(prefix), bytes(suffix)
    if len(prefix) + nbits // 8 + len(suffix) != 16:
        raise ValueError("counter block must be exactly 16 bytes")
    if not isinstance(initial_value, int) or not 0 <= initial_value < (1 << nbits):
        raise ValueError("initial_value does not fit in counter field")
    return {"counter_len": nbits // 8, "prefix": prefix, "suffix": suffix,
            "initial_value": initial_value, "little_endian": bool(little_endian),
            "allow_wraparound": bool(allow_wraparound)}
