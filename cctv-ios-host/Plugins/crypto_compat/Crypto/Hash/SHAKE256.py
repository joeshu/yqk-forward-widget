from ._hash import Hash

digest_size, block_size = 0, 136


def new(data=b""):
    return Hash("shake_256", data)
