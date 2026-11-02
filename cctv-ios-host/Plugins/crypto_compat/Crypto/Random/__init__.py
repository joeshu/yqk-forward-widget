"""Cryptographically secure random bytes backed by the OS CSPRNG."""

import secrets


def get_random_bytes(count):
    if not isinstance(count, int) or count < 0:
        raise ValueError("number of bytes must be a non-negative integer")
    return secrets.token_bytes(count)


class _RandomSource:
    def read(self, count):
        return get_random_bytes(count)


def new(*args, **kwargs):
    if args or kwargs:
        raise TypeError("Random.new accepts no arguments")
    return _RandomSource()
