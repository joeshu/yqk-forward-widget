"""Padding helpers compatible with the subset used by bundled sources."""


def pad(data_to_pad, block_size, style="pkcs7"):
    if not isinstance(data_to_pad, (bytes, bytearray, memoryview)):
        raise TypeError("data_to_pad must be bytes-like")
    data = bytes(data_to_pad)
    if not isinstance(block_size, int) or not 1 <= block_size <= 255:
        raise ValueError("block_size must be between 1 and 255")
    count = block_size - len(data) % block_size
    if style == "pkcs7":
        suffix = bytes((count,)) * count
    elif style == "x923":
        suffix = bytes(count - 1) + bytes((count,))
    elif style == "iso7816":
        suffix = b"\x80" + bytes(count - 1)
    else:
        raise ValueError("unsupported padding style")
    return data + suffix


def unpad(padded_data, block_size, style="pkcs7"):
    if not isinstance(padded_data, (bytes, bytearray, memoryview)):
        raise TypeError("padded_data must be bytes-like")
    data = bytes(padded_data)
    if not data or not isinstance(block_size, int) or not 1 <= block_size <= 255:
        raise ValueError("invalid padded data")
    if len(data) % block_size:
        raise ValueError("padded data length must be a multiple of block_size")
    if style == "pkcs7":
        count = data[-1]
        expected = bytes((count,)) * count
    elif style == "x923":
        count = data[-1]
        expected = bytes(count - 1) + bytes((count,))
    elif style == "iso7816":
        marker = data.rfind(b"\x80")
        if marker < 0:
            raise ValueError("invalid padding")
        count = len(data) - marker
        expected = b"\x80" + bytes(count - 1)
    else:
        raise ValueError("unsupported padding style")
    if not 1 <= count <= block_size or data[-count:] != expected:
        raise ValueError("invalid padding")
    return data[:-count]
