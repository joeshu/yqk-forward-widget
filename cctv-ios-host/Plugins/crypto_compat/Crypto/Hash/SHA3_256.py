from ._hash import Hash

digest_size, block_size, oid = 32, 136, "2.16.840.1.101.3.4.2.8"


def new(data=b""):
    return Hash("sha3_256", data)
