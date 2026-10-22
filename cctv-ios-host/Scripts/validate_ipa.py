#!/usr/bin/env python3
"""Validate IPA structure and Mach-O device platform. Does not claim playback works."""
import argparse, hashlib, json, plistlib, struct, zipfile

def macho_info(data):
    magic, cpu, sub, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    assert magic == 0xfeedfacf, 'expected thin 64-bit Mach-O'
    assert cpu == 0x100000c, 'expected ARM64'
    off = 32
    platform = None
    for _ in range(count):
        cmd, n = struct.unpack_from('<II', data, off)
        assert n >= 8 and off + n <= len(data), 'invalid load command'
        if cmd == 0x32:
            platform = struct.unpack_from('<I', data, off + 8)[0]
        if cmd == 0x25 and platform is None:
            platform = 2  # legacy LC_VERSION_MIN_IPHONEOS
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
