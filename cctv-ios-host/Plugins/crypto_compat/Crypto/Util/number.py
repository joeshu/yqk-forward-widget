"""Common integer conversion and number theory helpers."""

import secrets
import math


def bytes_to_long(data):
    return int.from_bytes(data, "big")


def long_to_bytes(value, blocksize=0):
    if not isinstance(value, int) or value < 0:
        raise ValueError("value must be a non-negative integer")
    length = max(1, (value.bit_length() + 7) // 8)
    raw = value.to_bytes(length, "big")
    if blocksize:
        if not isinstance(blocksize, int) or blocksize < 0:
            raise ValueError("blocksize must be a non-negative integer")
        if len(raw) % blocksize:
            raw = bytes(blocksize - len(raw) % blocksize) + raw
    return raw


def GCD(a, b):
    while b:
        a, b = b, a % b
    return abs(a)


def inverse(u, v):
    try:
        return pow(u, -1, v)
    except ValueError:
        raise ValueError("inverse does not exist") from None


def getRandomNBitInteger(N):
    if N <= 0:
        raise ValueError("N must be positive")
    return (1 << (N - 1)) | secrets.randbits(N - 1)


def getRandomRange(a, b):
    if b <= a:
        raise ValueError("empty range")
    return secrets.randbelow(b - a) + a


_SMALL_PRIMES = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)


def isPrime(n, false_positive_prob=1e-6):
    if n < 2:
        return False
    for prime in _SMALL_PRIMES:
        if n % prime == 0:
            return n == prime
    d, shifts = n - 1, 0
    while d % 2 == 0:
        d //= 2
        shifts += 1
    if not 0 < false_positive_prob < 1:
        raise ValueError("false_positive_prob must be between 0 and 1")
    rounds = max(8, min(32, math.ceil(-math.log(false_positive_prob, 4))))
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(shifts - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True
