from ._hash import Hash

digest_size, block_size, oid = 48, 128, "2.16.840.1.101.3.4.2.2"


def new(data=b""):
    return Hash("sha384", data)
