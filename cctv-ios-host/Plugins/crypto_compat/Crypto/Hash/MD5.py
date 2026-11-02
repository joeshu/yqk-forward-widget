from ._hash import Hash

digest_size, block_size, oid = 16, 64, "1.2.840.113549.2.5"


def new(data=b""):
    return Hash("md5", data)
