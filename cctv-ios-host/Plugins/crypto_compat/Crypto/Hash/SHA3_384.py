from ._hash import Hash

digest_size, block_size, oid = 48, 104, "2.16.840.1.101.3.4.2.9"


def new(data=b""):
    return Hash("sha3_384", data)
