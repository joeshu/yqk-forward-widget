from ._hash import Hash

digest_size, block_size = 0, 168


def new(data=b""):
    return Hash("shake_128", data)
