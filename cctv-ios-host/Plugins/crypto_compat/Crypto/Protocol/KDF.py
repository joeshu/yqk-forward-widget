"""Password and key derivation helpers used by common PyCryptodome sources."""

import hashlib
import hmac


def PBKDF2(password, salt, dkLen=16, count=1000, prf=None, hmac_hash_module=None):
    password, salt = bytes(password), bytes(salt)
    if not isinstance(count, int) or count <= 0 or not isinstance(dkLen, int) or dkLen <= 0:
        raise ValueError("count and dkLen must be positive integers")
    if prf is None and hmac_hash_module is None:
        return hashlib.pbkdf2_hmac("sha1", password, salt, count, dkLen)
    if prf is None:
        def prf(key, data):
            hash_factory = lambda d=b"": hmac_hash_module.new(d)
            return hmac.new(key, data, hash_factory).digest()
    digest_size = len(prf(password, b""))
    blocks = (dkLen + digest_size - 1) // digest_size
    if blocks > 0xffffffff:
        raise ValueError("derived key is too long")
    output = bytearray()
    for index in range(1, blocks + 1):
        u = prf(password, salt + index.to_bytes(4, "big"))
        result = bytearray(u)
        for _ in range(count - 1):
            u = prf(password, u)
            for offset, value in enumerate(u):
                result[offset] ^= value
        output.extend(result)
    return bytes(output[:dkLen])


def HKDF(master, key_len, salt=None, hashmod=None, num_keys=1, context=None):
    if hashmod is None:
        hashmod = hashlib.sha256
    elif hasattr(hashmod, "new"):
        module = hashmod
        hashmod = lambda data=b"": module.new(data)
    elif isinstance(hashmod, str):
        name = hashmod
        hashmod = lambda data=b"": hashlib.new(name, data)
    if not isinstance(num_keys, int) or num_keys < 1 or not isinstance(key_len, int) or key_len < 1:
        raise ValueError("num_keys and key_len must be positive integers")
    digest_size = hashmod().digest_size
    total = key_len * num_keys
    if total > 255 * digest_size:
        raise ValueError("requested key material is too long")
    salt = bytes(salt) if salt is not None else bytes(digest_size)
    context = b"" if context is None else bytes(context)
    prk = hmac.new(salt, bytes(master), lambda data=b"": hashmod(data)).digest()
    output, previous = bytearray(), b""
    for counter in range(1, (total + digest_size - 1) // digest_size + 1):
        previous = hmac.new(prk, previous + context + bytes((counter,)), lambda data=b"": hashmod(data)).digest()
        output.extend(previous)
    keys = [bytes(output[i * key_len:(i + 1) * key_len]) for i in range(num_keys)]
    return keys[0] if num_keys == 1 else keys


def scrypt(password, salt, key_len, N, r, p, num_keys=1):
    if not isinstance(num_keys, int) or num_keys < 1:
        raise ValueError("num_keys must be positive")
    result = hashlib.scrypt(bytes(password), salt=bytes(salt), n=N, r=r, p=p, dklen=key_len * num_keys)
    keys = [result[i * key_len:(i + 1) * key_len] for i in range(num_keys)]
    return keys[0] if num_keys == 1 else keys
