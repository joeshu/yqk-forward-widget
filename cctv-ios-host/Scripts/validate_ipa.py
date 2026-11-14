#!/usr/bin/env python3
"""Validate IPA structure and Mach-O device platform. Does not claim playback works."""
import argparse, hashlib, json, os, plistlib, struct, zipfile

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
        result['size_bytes'] = {'ipa': os.path.getsize(path), 'app_uncompressed': sum(i.file_size for i in z.infolist() if i.filename.startswith(root))}
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
            assert root + 'python/lib/python3.13/site-packages/hostcrypto.py' in z.namelist(), 'full build missing portable hostcrypto fallback'
            assert root + 'python/lib/python3.13/site-packages/cctvhost_ffmpeg.py' in z.namelist(), 'full build missing native FFmpeg Python API'
            assert any('alivcffmpeg.framework/alivcffmpeg' in name for name in result['binaries'][binary].get('dependencies', [])), 'full build missing linked FFmpeg library'
            assert root + 'yangshipin-js.py' in z.namelist(), 'missing JS HTTP adapter'
            assert len(z.read(root + 'yangshipin.bundle.js')) > 10000, 'missing original JS extractor bundle'
            assert root + 'yangshipin-LICENSE.txt' in z.namelist(), 'missing JS plugin license'
            assert root + 'JSPlugins/yangshipin/upstream/resolver.js' in z.namelist(), 'missing original JS sources'
            assert any('JavaScriptCore.framework/' in name for name in result['binaries'][binary]['dependencies']), 'missing JavaScriptCore link'
            result['binaries']['NodeMobile'] = macho_info(z.read(root + 'Frameworks/NodeMobile.framework/NodeMobile'))
            assert not any('NodeMobile.framework/' in name for name in result['binaries'][binary]['dependencies']), 'Node must load on demand'
            for member in ('media-service.py', 'host_media_runtime.py', 'host_media_relay.py', 'host_media_url.py', 'host_dash.py', 'csp_adapter.py', 'example-encrypted-media.py', 'node-plugin-host.cjs', 'node-fetch.bundle.cjs', 'node-fetch-THIRD-PARTY-NOTICES.txt', 'base/spider.py', 'lxml/__init__.py', 'lxml/etree.py', 'lxml/html.py', 'pyquery.py', 'NodeMobile-LICENSE.txt', 'drpy-LICENSE.txt'):
                assert root + member in z.namelist(), 'missing media component: ' + member
            assert len(z.read(root + 'js-runtime.bundle.js')) > 100000, 'missing generic JS and drpy engine'
            for package in ('requests', 'bs4', 'html5lib', 'urllib3', 'elementpath', 'defusedxml'):
                assert root + 'python/lib/python3.13/site-packages/' + package + '/__init__.py' in z.namelist(), 'missing Python dependency: ' + package
            for member in (
                    'Crypto/__init__.py', 'Crypto/Cipher/__init__.py', 'Crypto/Cipher/ARC4.py', 'Crypto/Cipher/AES.py',
                    'Crypto/Cipher/PKCS1_v1_5.py', 'Crypto/Cipher/PKCS1_OAEP.py', 'Crypto/Cipher/_aes_core.py',
                    'Crypto/PublicKey/__init__.py', 'Crypto/PublicKey/RSA.py',
                    'Crypto/Util/__init__.py', 'Crypto/Util/Padding.py', 'Crypto/Util/Counter.py',
                    'Crypto/Util/number.py', 'Crypto/Util/strxor.py',
                    'Crypto/Hash/__init__.py', 'Crypto/Hash/MD5.py', 'Crypto/Hash/HMAC.py', 'Crypto/Hash/CMAC.py',
                    'Crypto/Protocol/__init__.py', 'Crypto/Protocol/KDF.py', 'Crypto/Random/__init__.py'):
                assert root + 'python/lib/python3.13/site-packages/' + member in z.namelist(), 'missing pure-Python crypto compatibility module: ' + member
            assert root + 'python/lib/python3.13/site-packages/Cryptodome/__init__.py' in z.namelist(), 'missing Cryptodome namespace alias'
            result['python_crypto_compat'] = ['ARC4', 'AES ECB/CBC/CFB/OFB/CTR/GCM/EAX', 'RSA PKCS#1 v1.5 public/private import and encrypt/decrypt, OAEP public-key encryption', 'MD5/Hash/HMAC/CMAC', 'PBKDF2/HKDF', 'Padding/Counter/number/strxor']
            result['local_media_runtimes'] = ['Python Spider', 'JavaScriptCore', 'drpy', 'Node.js Mobile']
        if variant == 'full':
            # A JavaHost resource alone is insufficient: require the statically linked JNI bridge too.
            executable = z.read(root + binary)
            assert b'TVAppleRuntimeRequest' in executable and b'JNI_CreateJavaVM' in executable, 'missing linked JVM/bridge'
            for member in ('JavaHost/host.jar', 'JavaHost/apple-bindings.jar', 'JavaHost/lib/android-4.1.1.4.jar', 'JavaHost/lib/okio-jvm-3.6.0.jar', 'JavaHost/lib/kotlin-stdlib-1.8.21.jar', 'JavaHost/lib/guava-27.1-android.jar', 'JavaHost/lib/bcprov-jdk18on-1.78.1.jar', 'lib/lib/modules', 'lib/lib/security/cacerts', 'jar-runtime.json', 'JARLicenses/COPYING'):
                assert root + member in z.namelist(), 'missing JAR runtime resource: ' + member
            for metadata in ('kotlin-stdlib-common-1.9.10.jar', 'okio-3.6.0.jar', 'listenablefuture-9999.0-empty-to-avoid-conflict-with-guava.jar'):
                assert root + 'JavaHost/lib/' + metadata not in z.namelist(), 'compile-only metadata JAR was bundled: ' + metadata
            assert int(info.get('MinimumOSVersion', '0').split('.')[0]) >= 17, 'JAR runtime requires iOS 17+'
            result['jar_runtime'] = json.loads(z.read(root + 'jar-runtime.json'))
            for name in z.namelist():
                if name.startswith(root + 'JavaHost/') and name.endswith('.jar'):
                    import io
                    with zipfile.ZipFile(io.BytesIO(z.read(name))) as jar:
                        assert not any(n.startswith('natives/') or n.endswith(('.dylib', '.jnilib', '.dll')) or (n.endswith('.so') and not n.startswith('android/')) for n in jar.namelist()), 'desktop native code in JAR: ' + name
                        if name.endswith('/android-4.1.1.4.jar'):
                            names = jar.namelist()
                            assert not any(n.startswith('res/') or n in ('resources.arsc', 'AndroidManifest.xml') for n in names), 'unused SDK UI resources were bundled'
                            assert 'android/app/Activity.class' in names and 'android/content/res/Resources.class' in names, 'Android compatibility classes missing'
                            assert any(n.startswith('assets/') and not n.endswith('/') for n in names), 'SDK class-loader assets were removed'
                            result['android_sdk_classes'] = sum(n.endswith('.class') for n in names)
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
