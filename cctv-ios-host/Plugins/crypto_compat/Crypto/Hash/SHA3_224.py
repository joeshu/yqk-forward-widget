from ._hash import Hash

digest_size, block_size, oid = 28, 144, "2.16.840.1.101.3.4.2.7"


def new(data=b""):
    return Hash("sha3_224", data)
