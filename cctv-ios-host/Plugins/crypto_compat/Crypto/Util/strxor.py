"""Byte-string XOR helpers."""


def strxor(term1, term2, output=None):
    left, right = bytes(term1), bytes(term2)
    if len(left) != len(right):
        raise ValueError("input strings must have equal length")
    result = bytes(a ^ b for a, b in zip(left, right))
    if output is not None:
        if len(output) < len(result):
            raise ValueError("output buffer is too small")
        output[:len(result)] = result
        return output
    return result


def strxor_c(term, c):
    if not isinstance(c, int) or not 0 <= c <= 255:
        raise ValueError("c must be a byte value")
    return bytes(value ^ c for value in bytes(term))
