#!/usr/bin/env python3
"""Build symbol-isolated CCTVMPVCore.framework from pinned MPVKit LGPL slices.

Downloads MPVKit (mpv v0.41.0 + FFmpeg n8.1.2 + libass + libplacebo + MoltenVK +
libdav1d) static XCFrameworks, links them into a single dynamic framework with
-fvisibility=hidden and -Wl,-exported_symbols_list=Scripts/mpv_exported_symbols.txt,
and runs an `nm -gU` gate proving zero FFmpeg/OpenSSL symbols are exported so
CNPlayerSDK (IJK FFmpeg) and Python.framework can never suffer symbol collisions.
"""
import argparse
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

LINK_FRAMEWORKS = (
    'AVFoundation',
    'AudioToolbox',
    'CoreAudio',
    'CoreFoundation',
    'CoreMedia',
    'CoreVideo',
    'Metal',
    'QuartzCore',
    'Security',
    'VideoToolbox',
)

LINK_LIBS = (
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


def _download_archive(cache_dir: pathlib.Path, filename: str, url: str) -> pathlib.Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / filename
    if target.is_file() and target.stat().st_size > 1024 * 1024:
        return target
    staged = target.with_suffix('.download')
    print(f'[MPVKit] Downloading {filename} from {url} ...')
    with urllib.request.urlopen(url, timeout=180) as response, staged.open('wb') as out:
        shutil.copyfileobj(response, out, length=1024 * 1024)
    staged.replace(target)
    return target


def _safe_extract(zip_path: pathlib.Path, dest_dir: pathlib.Path) -> None:
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            if member.startswith('/') or '..' in pathlib.PurePosixPath(member).parts:
                raise ValueError(f'Unsafe archive member path: {member}')
        zf.extractall(dest_dir)


def _collect_static_libs(root: pathlib.Path, simulator: bool) -> list[pathlib.Path]:
    """Collect ios-arm64 (or simulator) static archives from extracted XCFrameworks."""
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
        # Nested *.xcframework.zip files inside *-all.zip
        for nested in sorted(tmp.rglob('*.xcframework.zip')):
            _safe_extract(nested, nested.parent)

        static_libs = _collect_static_libs(tmp, simulator=simulator)
        if not any('Libmpv' in str(p) for p in static_libs):
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
        # FFmpeg/libass/libplacebo/MoltenVK static libs for dependency resolution.
        for lib in static_libs:
            if 'Libmpv' in str(lib):
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
