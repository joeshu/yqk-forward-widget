from ._hash import Hash

digest_size, block_size, oid = 64, 128, "2.16.840.1.101.3.4.2.3"


def new(data=b""):
    return Hash("sha512", data)
