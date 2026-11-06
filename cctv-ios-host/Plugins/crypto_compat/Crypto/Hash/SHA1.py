from ._hash import Hash

digest_size, block_size, oid = 20, 64, "1.3.14.3.2.26"


def new(data=b""):
    return Hash("sha1", data)
