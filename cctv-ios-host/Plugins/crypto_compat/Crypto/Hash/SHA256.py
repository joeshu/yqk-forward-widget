from ._hash import Hash

digest_size, block_size, oid = 32, 64, "2.16.840.1.101.3.4.2.1"


def new(data=b""):
    return Hash("sha256", data)
