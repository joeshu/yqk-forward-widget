#!/usr/bin/env python3
"""Build symbol-isolated CCTVMPVCore.framework from pinned MPVKit LGPL slices.

Downloads MPVKit 1.0.0 (mpv v0.41.0 + FFmpeg n8.1.2) as the flat
libmpv-all.zip / FFmpeg-all.zip archives (lib/<platform>/thin/<arch>/lib/*.a),
plus the 18 dependency XCFrameworks upstream itself pins in
mpvkit/MPVKit@1.0.0 Package.swift (libass + freetype/fribidi/harfbuzz/unibreak,
libplacebo + MoltenVK + Libshaderc_combined + lcms2 + Libdovi, libbluray,
Libdav1d, Libuavs3d, Libuchardet, gnutls + gmp/nettle/hogweed), links them
into a single dynamic framework with -fvisibility=hidden and
-Wl,-exported_symbols_list=Scripts/mpv_exported_symbols.txt, and runs an
`nm -gU` gate proving zero FFmpeg/OpenSSL symbols are exported so
CNPlayerSDK (IJK FFmpeg) and Python.framework can never suffer symbol collisions.

NOTE: the *-all.zip archives carry NO dependency libraries at all — linking
only them fails on undefined _pl_/_ass_/_gnutls_/... symbols once libmpv is
force-loaded, which is why DEP_ARCHIVES exists. Libssl/Libcrypto are
deliberately NOT fetched: nothing in this closure references _SSL_/_EVP_
(FFmpeg 1.0.0 was built against gnutls). Libsmbclient is GPL-only and
Libluajit is macOS-only, so both are excluded like upstream's LGPL target.
"""
import argparse
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

VERSION = '1.0.0'
BASE_URL = f'https://github.com/mpvkit/MPVKit/releases/download/{VERSION}'
ARCHIVES = (
    ('libmpv-all.zip', f'{BASE_URL}/libmpv-all.zip'),
    ('FFmpeg-all.zip', f'{BASE_URL}/FFmpeg-all.zip'),
)

# Dependency XCFrameworks, exactly as pinned by mpvkit/MPVKit@1.0.0
# Package.swift (LGPL targets _MPVKit + _FFmpeg). (filename, url, sha256).
# Verified 2026-11-25: every checksum below matches the downloaded asset.
DEP_ARCHIVES = (
    ('Libass.xcframework.zip',
     'https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libass.xcframework.zip',
     '3f4c576d2818ceb4544aa2a20e1f55846511c5e706fd19adc3ea9fd842270498'),
    ('Libfreetype.xcframework.zip',
     'https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip',
     '496ca62488530e14b1e4624d20ee2b237c0bd675cd70c19da578a5768302d02d'),
    ('Libfribidi.xcframework.zip',
     'https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip',
     'bc15e097b892f2f90424e4a27ba287070cc2f98a74a4da10e6d2481d15cf5ff9'),
    ('Libharfbuzz.xcframework.zip',
     'https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip',
     'aa8e0b9ca0387dac74e3e93c86e34d11982bb013b28022d0e6966a8427a35b2e'),
    ('Libunibreak.xcframework.zip',
     'https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip',
     '940d9833cf4477d0a260d9f2b4066125bc0ff7bbc111ac3c90e774765b77a559'),
    ('Libplacebo.xcframework.zip',
     'https://github.com/mpvkit/libplacebo-build/releases/download/7.360.1/Libplacebo.xcframework.zip',
     '2fa3d54cb81f302d6f11c7b2f509af30944381c3b11ee9d35096eb4637a6e2dd'),
    ('MoltenVK.xcframework.zip',
     'https://github.com/mpvkit/moltenvk-build/releases/download/1.4.2/MoltenVK.xcframework.zip',
     'aee189c54ad7c62bf734a3dc51eb4cfad5685d1d63b0ec519ecd1b437c332418'),
    ('Libshaderc_combined.xcframework.zip',
     'https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip',
     '758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b'),
    ('lcms2.xcframework.zip',
     'https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip',
     'dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982'),
    ('Libdovi.xcframework.zip',
     'https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip',
     'e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d'),
    ('Libdav1d.xcframework.zip',
     'https://github.com/mpvkit/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip',
     'd1a32ae6a1f0193e9f05c44c9176844af7f6d2a58cb33843f6f1b8dfd9224083'),
    ('Libuavs3d.xcframework.zip',
     'https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip',
     'bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789'),
    ('Libbluray.xcframework.zip',
     'https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip',
     'bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d'),
    ('Libuchardet.xcframework.zip',
     'https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8/Libuchardet.xcframework.zip',
     'ea4f548a230a755e059144657cc9e2ff563c1cdeae03974c38f8b6e1a40303fb'),
    ('gnutls.xcframework.zip',
     'https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip',
     '3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d'),
    ('gmp.xcframework.zip',
     'https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip',
     'ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585'),
    ('nettle.xcframework.zip',
     'https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip',
     '0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02'),
    ('hogweed.xcframework.zip',
     'https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip',
     '25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27'),
)

# Any exported defined symbol matching these prefixes would collide with
# CNPlayerSDK's embedded IJK FFmpeg, alivcffmpeg, or Python's OpenSSL.
FORBIDDEN_EXPORT_PREFIXES = (
    '_avcodec_',
    '_avformat_',
    '_avutil_',
    '_avfilter_',
    '_avdevice_',
    '_av_',
    '_avpriv_',
    '_swr_',
    '_sws_',
    '_ff_',
    '_SSL_',
    '_EVP_',
    '_CRYPTO_',
    '_X509_',
    '_BIO_',
)

ALLOWED_EXPORT_PREFIX = '_mpv_'

# System frameworks the static closure needs. The first ten are upstream's
# own _FFmpeg/_MPVKit linker settings; the last five close gaps proven by a
# full undefined-symbol closure over the 8 flat libs + 18 dep slices:
# CoreGraphics (libplacebo _CGColorSpace*), CoreText (harfbuzz _CTFont*),
# IOSurface (MoltenVK _IOSurface*), OpenGLES (libmpv hwdec_ios_gl
# _CVOpenGLESTextureCache*; still shipped in the iOS 18 SDK on macos-15),
# Foundation (_NSLocalizedDescriptionKey, referenced from the dep libs),
# UIKit (MoltenVK references UIScreen/UIView; the framework is linked from
# a stub .c file, so nothing else pulls UIKit in).
LINK_FRAMEWORKS = (
    'AVFoundation',
    'AudioToolbox',
    'CoreAudio',
    'CoreFoundation',
    'CoreGraphics',
    'CoreMedia',
    'CoreText',
    'CoreVideo',
    'Foundation',
    'IOSurface',
    'Metal',
    'OpenGLES',
    'QuartzCore',
    'Security',
    'UIKit',
    'VideoToolbox',
)

LINK_LIBS = (
    # NOTE: no -lcommonCrypto here — iOS has no libcommonCrypto.tbd; its
    # symbols (e.g. _CCRandomGenerateBytes) live in libSystem, which is
    # linked by default. Adding -lcommonCrypto breaks the ld step.
    '-lbz2',
    '-liconv',
    '-lexpat',
    '-lresolv',
    '-lxml2',
    '-lz',
    '-lc++',
)


def parse_exported_symbols_from_nm(nm_output: str) -> list[str]:
    """Parse defined global symbol names from `nm -gU` output."""
    symbols: list[str] = []
    for raw_line in nm_output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 3:
            symbols.append(parts[-1])
        elif len(parts) == 2:
            symbols.append(parts[-1])
    return symbols


def verify_exported_symbols(nm_output: str, allowlist: set[str] | None = None) -> tuple[bool, list[str]]:
    """Verify `nm -gU` output exports only `_mpv_*` symbols with zero FFmpeg/OpenSSL leaks."""
    exported = parse_exported_symbols_from_nm(nm_output)
    violations: list[str] = []
    for sym in exported:
        if any(sym.startswith(prefix) for prefix in FORBIDDEN_EXPORT_PREFIXES):
            violations.append(f'forbidden_symbol:{sym}')
            continue
        if allowlist is not None:
            if sym not in allowlist:
                violations.append(f'unexpected_symbol:{sym}')
        elif not sym.startswith(ALLOWED_EXPORT_PREFIX):
            violations.append(f'non_mpv_symbol:{sym}')
    return (len(violations) == 0, violations)


def load_allowlist(path: pathlib.Path) -> set[str]:
    items: set[str] = set()
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        items.add(line)
    return items


def _sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _download_archive(cache_dir: pathlib.Path, filename: str, url: str,
                      sha256: str | None = None) -> pathlib.Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / filename
    if target.is_file() and target.stat().st_size > 1024 * 1024:
        if sha256 is None or _sha256_file(target) == sha256:
            return target
        print(f'[MPVKit] Cached {filename} failed checksum, re-downloading ...')
        target.unlink()
    staged = target.with_suffix('.download')
    print(f'[MPVKit] Downloading {filename} from {url} ...')
    with urllib.request.urlopen(url, timeout=180) as response, staged.open('wb') as out:
        shutil.copyfileobj(response, out, length=1024 * 1024)
    if sha256 is not None and _sha256_file(staged) != sha256:
        staged.unlink(missing_ok=True)
        raise RuntimeError(f'Checksum mismatch for {filename}: expected sha256 {sha256}')
    staged.replace(target)
    return target


def _safe_extract(zip_path: pathlib.Path, dest_dir: pathlib.Path) -> None:
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            if member.startswith('/') or '..' in pathlib.PurePosixPath(member).parts:
                raise ValueError(f'Unsafe archive member path: {member}')
        zf.extractall(dest_dir)


def _collect_static_libs(root: pathlib.Path, simulator: bool) -> list[pathlib.Path]:
    """Collect ios-arm64 (or simulator) static archives from extracted XCFrameworks
    and from the flat lib/<platform>/thin/<arch>/lib layout of *-all.zip.

    The *-all.zip archives contain NO *.xcframework at all — they are a flat
    tree lib/ios/thin/arm64/lib/libmpv.a (+ include/, pkgconfig-example/),
    so the xcframework-only walk above finds nothing and the old code raised
    'Libmpv static slice not found'. The flat *.a file is also lowercase
    (libmpv.a), so every 'Libmpv' match elsewhere in this module is
    case-insensitive.
    """
    preferred_slice = 'ios-arm64_x86_64-simulator' if simulator else 'ios-arm64'
    libs: list[pathlib.Path] = []
    seen_names: set[str] = set()
    for xcfw in sorted(root.rglob('*.xcframework')):
        # Skip macOS-only LuaJIT and GPL-only archives if present
        if xcfw.name.startswith('Libluajit') or '-GPL.' in xcfw.name:
            continue
        slice_dir = xcfw / preferred_slice
        if not slice_dir.is_dir():
            if simulator:
                alt = xcfw / 'ios-arm64-simulator'
                if alt.is_dir():
                    slice_dir = alt
                else:
                    continue
            else:
                continue
        # Look for either *.a directly or *.framework/<Name> static Mach-O archive
        candidates = sorted(slice_dir.glob('*.a'))
        if not candidates:
            for fw in sorted(slice_dir.glob('*.framework')):
                bin_path = fw / fw.stem
                if bin_path.is_file():
                    candidates.append(bin_path)
        for cand in candidates:
            key = cand.name
            if key in seen_names:
                continue
            seen_names.add(key)
            libs.append(cand)
    # Flat layout (libmpv-all.zip / FFmpeg-all.zip): only the slice matching
    # the target platform, never the macos/tvos/isimulator-x86_64 trees.
    flat_dir = root / 'lib' / ('isimulator' if simulator else 'ios') / 'thin' / 'arm64' / 'lib'
    if flat_dir.is_dir():
        for cand in sorted(flat_dir.glob('*.a')):
            key = cand.name
            if key in seen_names:
                continue
            seen_names.add(key)
            libs.append(cand)
    return libs


def _write_framework_plist(framework_dir: pathlib.Path) -> None:
    info = {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'CCTVMPVCore',
        'CFBundleIdentifier': 'com.cctvhost.CCTVMPVCore',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'CCTVMPVCore',
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': VERSION,
        'CFBundleVersion': '1',
        'MinimumOSVersion': '17.0',
    }
    with (framework_dir / 'Info.plist').open('wb') as f:
        plistlib.dump(info, f)


def prepare(app: str, simulator: bool = False) -> pathlib.Path:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    symbols_file = repo_root / 'Scripts' / 'mpv_exported_symbols.txt'
    allowlist = load_allowlist(symbols_file)
    cache_dir = pathlib.Path(os.environ.get('CCTV_MPV_CACHE', str(pathlib.Path(tempfile.gettempdir()) / f'cctvhost-mpvkit-{VERSION}')))

    sdk_name = 'iphonesimulator' if simulator else 'iphoneos'
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()

    with tempfile.TemporaryDirectory() as tmp_str:
        tmp = pathlib.Path(tmp_str)
        for filename, url in ARCHIVES:
            archive_path = _download_archive(cache_dir, filename, url)
            _safe_extract(archive_path, tmp)
        # Dependency XCFrameworks (sha256-pinned to MPVKit 1.0.0 Package.swift).
        for filename, url, sha256 in DEP_ARCHIVES:
            archive_path = _download_archive(cache_dir, filename, url, sha256=sha256)
            _safe_extract(archive_path, tmp)
        # Nested *.xcframework.zip files inside *-all.zip
        for nested in sorted(tmp.rglob('*.xcframework.zip')):
            _safe_extract(nested, nested.parent)

        static_libs = _collect_static_libs(tmp, simulator=simulator)
        if not any('libmpv' in str(p).lower() for p in static_libs):
            raise RuntimeError(f'Libmpv static slice not found in MPVKit {VERSION} archive')

        framework_dir = pathlib.Path(app) / 'Frameworks' / 'CCTVMPVCore.framework'
        framework_dir.mkdir(parents=True, exist_ok=True)
        out_binary = framework_dir / 'CCTVMPVCore'

        # Tiny stub translation unit so clang drives the dynamiclib link cleanly
        stub_c = tmp / 'mpv_core_stub.c'
        stub_c.write_text('/* CCTVMPVCore dynamic wrapper stub */\n', encoding='utf-8')

        cmd = [
            'xcrun', '--sdk', sdk_name, 'clang',
            '-arch', 'arm64',
            '-isysroot', sdk_path,
            '-miphonesimulator-version-min=17.0' if simulator else '-miphoneos-version-min=17.0',
            '-dynamiclib',
            '-fvisibility=hidden',
            '-fvisibility-inlines-hidden',
            '-install_name', '@rpath/CCTVMPVCore.framework/CCTVMPVCore',
            f'-Wl,-exported_symbols_list,{symbols_file}',
            '-Wl,-dead_strip',
            str(stub_c),
        ]
        # Force-load Libmpv so exported mpv_* symbols are retained, then pass all
        # FFmpeg/dependency static libs for symbol resolution. Match
        # case-insensitively: the flat archive ships lowercase libmpv.a.
        for lib in static_libs:
            if 'libmpv' in str(lib).lower():
                cmd.extend(['-Wl,-force_load', str(lib)])
            else:
                cmd.append(str(lib))
        for fw in LINK_FRAMEWORKS:
            cmd.extend(['-framework', fw])
        cmd.extend(LINK_LIBS)
        cmd.extend(['-o', str(out_binary)])

        print(f'[MPVKit] Linking symbol-isolated CCTVMPVCore.framework ({len(static_libs)} static slices) ...')
        subprocess.run(cmd, check=True)
        _write_framework_plist(framework_dir)

        nm_output = subprocess.check_output(['xcrun', 'nm', '-gU', str(out_binary)], text=True)
        ok, violations = verify_exported_symbols(nm_output, allowlist=allowlist)
        if not ok:
            out_binary.unlink(missing_ok=True)
            raise RuntimeError(f'CCTVMPVCore symbol isolation gate FAILED: {violations[:10]}')

        exported_count = len(parse_exported_symbols_from_nm(nm_output))
        print(f'[MPVKit] CCTVMPVCore.framework ready: {exported_count} exported _mpv_* symbols, 0 FFmpeg/OpenSSL leaks')
        return framework_dir


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app')
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    prepare(args.app, simulator=args.simulator)
