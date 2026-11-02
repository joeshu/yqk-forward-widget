from ._hash import Hash

digest_size, block_size, oid = 64, 72, "2.16.840.1.101.3.4.2.10"


def new(data=b""):
    return Hash("sha3_512", data)
