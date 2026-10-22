#!/usr/bin/env python3
"""Validate IPA structure and Mach-O device platform. Does not claim playback works."""
import argparse, hashlib, json, plistlib, struct, zipfile

def macho_info(data):
    if len(data) < 4:
        raise ValueError('truncated Mach-O')
    magic_be = struct.unpack_from('>I', data, 0)[0]
    if magic_be == 0xCAFEBABE:  # FAT_MAGIC
        nfat = struct.unpack_from('>I', data, 4)[0]
        assert 0 < nfat <= 32, 'invalid FAT architecture count'
        slices = []
        pos = 8
        for _ in range(nfat):
            cpu, sub, off, size, align = struct.unpack_from('>IIIII', data, pos)
            pos += 20
            assert off + size <= len(data), 'FAT slice outside binary'
            assert cpu == 0x0100000C, f'non-ARM64 FAT slice: {cpu:#x}'
            slices.append(macho_info(data[off:off+size]))
        return {'cpu': 'arm64', 'platform': 'iOS device', 'slices': slices}
    magic, cpu, sub, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    assert magic == 0xfeedfacf, f'unsupported Mach-O magic: {magic:#x}'
    assert cpu == 0x100000c, f'expected ARM64, got {cpu:#x}'
    off = 32
    platform = None
    for _ in range(count):
        cmd, n = struct.unpack_from('<II', data, off)
        assert n >= 8 and off + n <= len(data), 'invalid load command'
        if cmd == 0x32:
            platform = struct.unpack_from('<I', data, off + 8)[0]
        if cmd == 0x25 and platform is None:
            platform = 2
        off += n
    assert platform == 2, f'expected iOS device platform=2, got {platform}'
    return {'cpu': 'arm64', 'platform': 'iOS device', 'kind': kind}

def validate(path):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None, 'ZIP checksum failure'
        root = 'Payload/CCTVHost.app/'
        info = plistlib.loads(z.read(root + 'Info.plist'))
        binary = info['CFBundleExecutable']
        result = {'bundle_id': info['CFBundleIdentifier'], 'binaries': {}}
        result['binaries'][binary] = macho_info(z.read(root + binary))
        for name in ('CNPlayerSDK', 'CicadaPlayerSDK', 'alivcffmpeg'):
            member = f'{root}Frameworks/{name}.framework/{name}'
            result['binaries'][name] = macho_info(z.read(member))
        py = root + 'Frameworks/Python.framework/Python'
        result['python_embedded'] = py in z.namelist()
        if result['python_embedded']:
            result['binaries']['Python'] = macho_info(z.read(py))
            assert root + 'python/lib/python3.13/encodings/__init__.py' in z.namelist(), 'missing Python encodings'
        channels = json.loads(z.read(root + 'channels.json'))
        assert isinstance(channels, list) and channels, 'empty channel catalog'
        result['channel_count'] = len(channels)
    with open(path, 'rb') as f:
        result['sha256'] = hashlib.file_digest(f, 'sha256').hexdigest()
    return result

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('ipa')
    args = ap.parse_args()
    print(json.dumps(validate(args.ipa), indent=2, ensure_ascii=False))
