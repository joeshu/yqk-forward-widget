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
    dependencies = []
    for _ in range(count):
        cmd, n = struct.unpack_from('<II', data, off)
        assert n >= 8 and off + n <= len(data), 'invalid load command'
        if cmd == 0x32:
            platform = struct.unpack_from('<I', data, off + 8)[0]
        if cmd in (0xc, 0x80000018, 0x8000001f):
            name_offset = struct.unpack_from('<I', data, off + 8)[0]
            assert 24 <= name_offset < n, 'invalid dylib name offset'
            dependencies.append(data[off + name_offset:off + n].split(b'\0', 1)[0].decode('utf-8'))
        if cmd == 0x25 and platform is None:
            platform = 2
        off += n
    assert platform == 2, f'expected iOS device platform=2, got {platform}'
    return {'cpu': 'arm64', 'platform': 'iOS device', 'kind': kind, 'dependencies': dependencies}

def validate(path):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None, 'ZIP checksum failure'
        root = 'Payload/CCTVHost.app/'
        info = plistlib.loads(z.read(root + 'Info.plist'))
        assert root + 'Assets.car' in z.namelist(), 'missing compiled AppIcon Assets.car'
        primary_icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
        assert primary_icon, 'missing CFBundlePrimaryIcon in Info.plist'
        result = {'bundle_id': info['CFBundleIdentifier'], 'app_icon': True, 'binaries': {}}
        binary = info.get('CFBundleExecutable')
        assert binary == 'CCTVHost', 'unexpected or missing app executable'
        result['version'] = info.get('CFBundleShortVersionString')
        result['build'] = info.get('CFBundleVersion')
        result['binaries'][binary] = macho_info(z.read(root + binary))
        for name in ('CNPlayerSDK', 'CicadaPlayerSDK', 'alivcffmpeg'):
            member = f'{root}Frameworks/{name}.framework/{name}'
            result['binaries'][name] = macho_info(z.read(member))
        py = root + 'Frameworks/Python.framework/Python'
        result['python_embedded'] = py in z.namelist()
        if result['python_embedded']:
            result['binaries']['Python'] = macho_info(z.read(py))
            assert root + 'python/lib/python3.13/encodings/__init__.py' in z.namelist(), 'missing Python encodings'
        variant = info.get('CCTVHostBuildVariant')
        result['build_variant'] = variant or 'legacy'
        linked = any('/Python.framework/' in name for name in result['binaries'][binary].get('dependencies', []))
        result['python_linked'] = linked
        if variant in ('no-python', 'baseline09'):
            assert not result['python_embedded'] and not linked, 'no-python build contains or links Python'
            assert not any(name.startswith(root + 'python/') for name in z.namelist()), 'no-python build includes stdlib'
            assert root + 'ysp-live.py' not in z.namelist(), 'no-python build includes bundled Python service'
            assert info['CFBundleIdentifier'].endswith('.nopy'), 'diagnostic bundle must install separately'
        elif variant == 'full':
            assert result['python_embedded'] and linked, 'full build missing embedded or linked Python'
            assert root + 'host_service_runtime.py' in z.namelist(), 'full build missing service lifecycle manager'
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
