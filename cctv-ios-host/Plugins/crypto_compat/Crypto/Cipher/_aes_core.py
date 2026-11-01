"""Pure Python AES core adapted from the supplied HGTV Spider sample.

Provides AES block transforms and CTR/CBC helpers for the bundled Crypto shim.
"""
########## 1. AES（纯 Python 实现，无第三方依赖） ##########

"""纯 Python AES（CTR 加密 / CBC 解密），无第三方依赖"""

_SBOX = [
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
_INV = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV[_v] = _i
_RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d]

def _xt(a):
    return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1)

# T 表：Te0..Te3
Te0 = [0]*256; Te1 = [0]*256; Te2 = [0]*256; Te3 = [0]*256
for _i in range(256):
    s = _SBOX[_i]; s2 = _xt(s); s3 = s2 ^ s
    Te0[_i] = (s2 << 24) | (s << 16) | (s << 8) | s3
    Te1[_i] = (s3 << 24) | (s2 << 16) | (s << 8) | s
    Te2[_i] = (s << 24) | (s3 << 16) | (s2 << 8) | s
    Te3[_i] = (s << 24) | (s << 16) | (s3 << 8) | s2
# 解密用 Td 表
Td0 = [0]*256; Td1 = [0]*256; Td2 = [0]*256; Td3 = [0]*256
def _gm(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a = _xt(a); b >>= 1
    return r
for _i in range(256):
    s = _INV[_i]
    s9, s11, s13, s14 = _gm(s,9), _gm(s,11), _gm(s,13), _gm(s,14)
    Td0[_i] = (s14 << 24) | (s9 << 16) | (s13 << 8) | s11
    Td1[_i] = (s11 << 24) | (s14 << 16) | (s9 << 8) | s13
    Td2[_i] = (s13 << 24) | (s11 << 16) | (s14 << 8) | s9
    Td3[_i] = (s9 << 24) | (s13 << 16) | (s11 << 8) | s14

class AES(object):
    __slots__ = ("rk", "nr", "dk")

    def __init__(self, key):
        nk = len(key) // 4
        self.nr = nk + 6
        w = [list(key[4*i:4*i+4]) for i in range(nk)]
        for i in range(nk, 4 * (self.nr + 1)):
            t = list(w[i-1])
            if i % nk == 0:
                t = t[1:] + t[:1]
                t = [_SBOX[b] for b in t]
                t[0] ^= _RCON[i//nk - 1]
            elif nk > 6 and i % nk == 4:
                t = [_SBOX[b] for b in t]
            w.append([w[i-nk][j] ^ t[j] for j in range(4)])
        self.rk = [0] * (4 * (self.nr + 1))
        for i, wi in enumerate(w):
            self.rk[i] = (wi[0] << 24) | (wi[1] << 16) | (wi[2] << 8) | wi[3]
        # 解密轮密钥（逆序 + InvMixColumns）
        dk = list(self.rk)
        for r in range(1, self.nr):
            for c in range(4):
                v = self.rk[r*4 + c]
                dk[r*4 + c] = (Td0[_SBOX[(v >> 24) & 0xff]] ^ Td1[_SBOX[(v >> 16) & 0xff]] ^
                               Td2[_SBOX[(v >> 8) & 0xff]] ^ Td3[_SBOX[v & 0xff]])
        dk2 = [0] * len(dk)
        for r in range(self.nr + 1):
            for c in range(4):
                dk2[r*4 + c] = dk[(self.nr - r) * 4 + c]
        self.dk = dk2

    def encrypt_block(self, s0, s1, s2, s3):
        rk = self.rk; nr = self.nr
        s0 ^= rk[0]; s1 ^= rk[1]; s2 ^= rk[2]; s3 ^= rk[3]
        k = 4
        for _ in range(1, nr):
            t0 = Te0[s0 >> 24] ^ Te1[(s1 >> 16) & 0xff] ^ Te2[(s2 >> 8) & 0xff] ^ Te3[s3 & 0xff] ^ rk[k]
            t1 = Te0[s1 >> 24] ^ Te1[(s2 >> 16) & 0xff] ^ Te2[(s3 >> 8) & 0xff] ^ Te3[s0 & 0xff] ^ rk[k+1]
            t2 = Te0[s2 >> 24] ^ Te1[(s3 >> 16) & 0xff] ^ Te2[(s0 >> 8) & 0xff] ^ Te3[s1 & 0xff] ^ rk[k+2]
            t3 = Te0[s3 >> 24] ^ Te1[(s0 >> 16) & 0xff] ^ Te2[(s1 >> 8) & 0xff] ^ Te3[s2 & 0xff] ^ rk[k+3]
            s0, s1, s2, s3 = t0, t1, t2, t3
            k += 4
        o0 = ((_SBOX[s0 >> 24] << 24) | (_SBOX[(s1 >> 16) & 0xff] << 16) | (_SBOX[(s2 >> 8) & 0xff] << 8) | _SBOX[s3 & 0xff]) ^ rk[k]
        o1 = ((_SBOX[s1 >> 24] << 24) | (_SBOX[(s2 >> 16) & 0xff] << 16) | (_SBOX[(s3 >> 8) & 0xff] << 8) | _SBOX[s0 & 0xff]) ^ rk[k+1]
        o2 = ((_SBOX[s2 >> 24] << 24) | (_SBOX[(s3 >> 16) & 0xff] << 16) | (_SBOX[(s0 >> 8) & 0xff] << 8) | _SBOX[s1 & 0xff]) ^ rk[k+2]
        o3 = ((_SBOX[s3 >> 24] << 24) | (_SBOX[(s0 >> 16) & 0xff] << 16) | (_SBOX[(s1 >> 8) & 0xff] << 8) | _SBOX[s2 & 0xff]) ^ rk[k+3]
        return o0, o1, o2, o3

    def decrypt_block(self, s0, s1, s2, s3):
        dk = self.dk; nr = self.nr
        s0 ^= dk[0]; s1 ^= dk[1]; s2 ^= dk[2]; s3 ^= dk[3]
        k = 4
        for _ in range(1, nr):
            t0 = Td0[s0 >> 24] ^ Td1[(s3 >> 16) & 0xff] ^ Td2[(s2 >> 8) & 0xff] ^ Td3[s1 & 0xff] ^ dk[k]
            t1 = Td0[s1 >> 24] ^ Td1[(s0 >> 16) & 0xff] ^ Td2[(s3 >> 8) & 0xff] ^ Td3[s2 & 0xff] ^ dk[k+1]
            t2 = Td0[s2 >> 24] ^ Td1[(s1 >> 16) & 0xff] ^ Td2[(s0 >> 8) & 0xff] ^ Td3[s3 & 0xff] ^ dk[k+2]
            t3 = Td0[s3 >> 24] ^ Td1[(s2 >> 16) & 0xff] ^ Td2[(s1 >> 8) & 0xff] ^ Td3[s0 & 0xff] ^ dk[k+3]
            s0, s1, s2, s3 = t0, t1, t2, t3
            k += 4
        o0 = ((_INV[s0 >> 24] << 24) | (_INV[(s3 >> 16) & 0xff] << 16) | (_INV[(s2 >> 8) & 0xff] << 8) | _INV[s1 & 0xff]) ^ dk[k]
        o1 = ((_INV[s1 >> 24] << 24) | (_INV[(s0 >> 16) & 0xff] << 16) | (_INV[(s3 >> 8) & 0xff] << 8) | _INV[s2 & 0xff]) ^ dk[k+1]
        o2 = ((_INV[s2 >> 24] << 24) | (_INV[(s1 >> 16) & 0xff] << 16) | (_INV[(s0 >> 8) & 0xff] << 8) | _INV[s3 & 0xff]) ^ dk[k+2]
        o3 = ((_INV[s3 >> 24] << 24) | (_INV[(s2 >> 16) & 0xff] << 16) | (_INV[(s1 >> 8) & 0xff] << 8) | _INV[s0 & 0xff]) ^ dk[k+3]
        return o0, o1, o2, o3

def ctr_xor(key, nonce, data):
    a = AES(key)
    n = len(data)
    out = bytearray(n)
    c0 = int.from_bytes(nonce[0:4], "big")
    c1 = int.from_bytes(nonce[4:8], "big")
    c2 = int.from_bytes(nonce[8:12], "big")
    c3 = int.from_bytes(nonce[12:16], "big")
    enc = a.encrypt_block
    blocks = n // 16
    for i in range(blocks):
        o0, o1, o2, o3 = enc(c0, c1, c2, c3)
        ks = o0.to_bytes(4, "big") + o1.to_bytes(4, "big") + o2.to_bytes(4, "big") + o3.to_bytes(4, "big")
        off = i * 16
        d = data[off:off+16]
        out[off] = d[0] ^ ks[0]; out[off+1] = d[1] ^ ks[1]
        out[off+2] = d[2] ^ ks[2]; out[off+3] = d[3] ^ ks[3]
        out[off+4] = d[4] ^ ks[4]; out[off+5] = d[5] ^ ks[5]
        out[off+6] = d[6] ^ ks[6]; out[off+7] = d[7] ^ ks[7]
        out[off+8] = d[8] ^ ks[8]; out[off+9] = d[9] ^ ks[9]
        out[off+10] = d[10] ^ ks[10]; out[off+11] = d[11] ^ ks[11]
        out[off+12] = d[12] ^ ks[12]; out[off+13] = d[13] ^ ks[13]
        out[off+14] = d[14] ^ ks[14]; out[off+15] = d[15] ^ ks[15]
        # counter++
        c3 = (c3 + 1) & 0xffffffff
        if c3 == 0:
            c2 = (c2 + 1) & 0xffffffff
            if c2 == 0:
                c1 = (c1 + 1) & 0xffffffff
                if c1 == 0:
                    c0 = (c0 + 1) & 0xffffffff
    rem = n - blocks * 16
    if rem:
        o0, o1, o2, o3 = enc(c0, c1, c2, c3)
        ks = o0.to_bytes(4, "big") + o1.to_bytes(4, "big") + o2.to_bytes(4, "big") + o3.to_bytes(4, "big")
        off = blocks * 16
        for i in range(rem):
            out[off+i] = data[off+i] ^ ks[i]
    return bytes(out)

def cbc_decrypt(key, iv, data):
    a = AES(key)
    out = bytearray()
    prev = int.from_bytes(iv, "big")
    for off in range(0, len(data) - 15, 16):
        blk = int.from_bytes(data[off:off+16], "big")
        o0, o1, o2, o3 = a.decrypt_block((blk >> 96) & 0xffffffff, (blk >> 64) & 0xffffffff,
                                         (blk >> 32) & 0xffffffff, blk & 0xffffffff)
        dec = (o0 << 96) | (o1 << 64) | (o2 << 32) | o3
        dec ^= prev
        out += dec.to_bytes(16, "big")
        prev = blk
    return bytes(out)
