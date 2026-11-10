#!/usr/bin/env python3
"""Trim packaging overhead without shrinking the dynamic plugin class path."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
import zlib

ORIGINAL_LINK = '"$HOST/bin/jlink" --module-path "$MODULE_PATH" --add-modules "$MODULES" --output "$LINK/image"'
V1_LINK = ORIGINAL_LINK.replace('$LINK/image', '$LINK/image-baseline') + '\n' + ORIGINAL_LINK.replace(
    '--output', '--strip-debug --compress=zip-0 --no-header-files --no-man-pages --output')
OPTIMIZED_LINK = V1_LINK.replace('--strip-debug', "--exclude-resources='glob:/*/_the.*' --strip-debug")
SDK_JAR = 'android-4.1.1.4.jar'
COMPILE_METADATA_JARS = (
    'kotlin-stdlib-common-1.9.10.jar', 'okio-3.6.0.jar',
    'listenablefuture-9999.0-empty-to-avoid-conflict-with-guava.jar',
)
BUILD_SUFFIXES = ('-javacserver.conf', '.config_vardeps', '.vardeps', '_batch',
                  '_batch.cmdline', '_batch.filelist', '_batch.log', '_batch.modfiles',
                  '_batch.modfiles.fixed', '_internalapi', '_pubapi')
NATIVE_START = 'if [ ! -f "$JDK/images/static-libs/lib/zero/libjvm.a" ] || [ ! -f "$JDK/images/static-libs/lib/libmanagement.a" ]; then Scripts/build-apple-jvm.sh "$TARGET"; fi'
NATIVE_END = 'xcrun libtool -static -o "$OUT/lib/libTVAppleRuntime.a" "${ARCHIVES[@]}"'
NATIVE_GUARD = 'if [ "${CCTV_JAR_REUSE_NATIVE:-0}" != 1 ]; then'


def configure(script):
    text = script.read_text()
    if OPTIMIZED_LINK not in text:
        if text.count(V1_LINK) == 1:
            text = text.replace(V1_LINK, OPTIMIZED_LINK)
        elif text.count(ORIGINAL_LINK) == 1:
            text = text.replace(ORIGINAL_LINK, OPTIMIZED_LINK)
        else:
            raise ValueError('Pinned upstream jlink invocation changed; review packaging before building')
    if NATIVE_GUARD not in text:
        if text.count(NATIVE_START) != 1 or text.count(NATIVE_END) != 1:
            raise ValueError('Pinned upstream native packaging changed; refusing cache reuse')
        start, end = text.index(NATIVE_START), text.index(NATIVE_END) + len(NATIVE_END)
        if end <= start:
            raise ValueError('Invalid native packaging boundaries')
        text = text[:start] + NATIVE_GUARD + '\n' + text[start:end] + '\nfi' + text[end:]
    script.write_text(text)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sizes(path):
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    compressed = 0
    with path.open('rb') as src:
        for block in iter(lambda: src.read(1024 * 1024), b''):
            compressed += len(compressor.compress(block))
    # Comparative estimate only; the final IPA is measured from its ZIP directory.
    return {'bytes': path.stat().st_size, 'deflate6_bytes': compressed + len(compressor.flush())}


def sdk_ui_resource(name):
    # Resources.java supplies virtual Android resources and never loads the SDK APK table.
    # Keep assets/: AssetManager can resolve class-loader assets, including a plugin's own files.
    return name.startswith('res/') or name in ('resources.arsc', 'AndroidManifest.xml')


def optimize_sdk(jar):
    before = sizes(jar)
    with zipfile.ZipFile(jar) as src:
        names = src.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate SDK archive entries')
        if not {'android/app/Activity.class', 'android/content/res/Resources.class'} <= set(names):
            raise ValueError('Unexpected Android SDK JAR; refusing resource trimming')
        if any(n.upper().startswith('META-INF/') and n.upper().endswith(('.SF', '.RSA', '.DSA', '.EC')) for n in names):
            raise ValueError('Unexpected signed Android SDK JAR; requires explicit review')
        retained = {n: digest(src.read(n)) for n in names if not sdk_ui_resource(n)}
        removed = [n for n in names if sdk_ui_resource(n)]
        removed_bytes = sum(src.getinfo(n).file_size for n in removed)
        with tempfile.NamedTemporaryFile(dir=jar.parent, suffix='.jar', delete=False) as tmp:
            replacement = Path(tmp.name)
        try:
            with zipfile.ZipFile(replacement, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
                dst.comment = src.comment
                for entry in src.infolist():
                    if entry.filename not in retained:
                        continue
                    info = copy.copy(entry)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    dst.writestr(info, src.read(entry), compresslevel=9)
            with zipfile.ZipFile(replacement) as dst:
                actual = {n: digest(dst.read(n)) for n in dst.namelist()}
            if retained != actual:
                raise ValueError('Android SDK class/resource preservation check failed')
            replacement.replace(jar)
        finally:
            replacement.unlink(missing_ok=True)
    return {'before': before, 'after': sizes(jar), 'removed_entries': len(removed),
            'removed_uncompressed_bytes': removed_bytes,
            'preserved_classes': sum(n.endswith('.class') for n in retained),
            'retained_entries_sha256': digest(json.dumps(retained, sort_keys=True).encode())}


def image_entries(jimage, image):
    result = subprocess.run([str(jimage), 'list', str(image)], check=True, text=True, capture_output=True)
    # The first line contains the image's filesystem path; subsequent lines identify its contents.
    entries = [line.strip() for line in result.stdout.splitlines() if line.strip() and not line.startswith('jimage:')]
    if 'Module: java.base' not in entries or 'java/lang/Object.class' not in entries:
        raise ValueError('Unrecognized jimage listing; refusing an unverified runtime')
    return entries


def compiler_metadata(module, name):
    return name in {'_the.' + module + suffix for suffix in BUILD_SUFFIXES}


def retained_image_entries(entries):
    module = ''
    retained, removed = [], []
    for name in entries:
        if name.startswith('Module: '):
            module = name.removeprefix('Module: ')
        if compiler_metadata(module, name):
            removed.append('/' + module + '/' + name)
        else:
            retained.append(name)
    return retained, removed


def module_sizes(jimage, image):
    result = subprocess.run([str(jimage), 'list', '--verbose', str(image)], check=True,
                            text=True, capture_output=True)
    modules, module = {}, ''
    for line in result.stdout.splitlines():
        if line.startswith('Module: '):
            module = line.removeprefix('Module: ')
            modules[module] = {'class_bytes': 0, 'runtime_resource_bytes': 0, 'compiler_metadata_bytes': 0}
        row = re.fullmatch(r'\s*\d+\s+(\d+)\s+\d+\s+(.+)', line)
        if not row or not module:
            continue
        size, name = row.groups()
        key = ('compiler_metadata_bytes' if compiler_metadata(module, name) else
               'class_bytes' if name.endswith('.class') else 'runtime_resource_bytes')
        modules[module][key] += int(size)
    return modules


def verify_runtime_resources(jimage, baseline, image, entries):
    """Hash all non-class runtime resources; only explicit compiler metadata may disappear."""
    paths, module = [], ''
    for name in entries:
        if name.startswith('Module: '):
            module = name.removeprefix('Module: ')
        elif not name.endswith('.class'):
            paths.append(module + '/' + name)
    with tempfile.TemporaryDirectory(prefix='cctv-jimage-check-') as tmp:
        roots = [Path(tmp) / 'before', Path(tmp) / 'after']
        for source, root in zip((baseline, image), roots):
            subprocess.run([str(jimage), 'extract', '--dir', str(root), str(source)], check=True, capture_output=True)
        hashes = {}
        for relative in paths:
            a, b = (root / relative for root in roots)
            value = digest(a.read_bytes())
            if value != digest(b.read_bytes()):
                raise ValueError('JDK runtime resource changed: ' + relative)
            hashes[relative] = value
        return hashes


def metadata_archive_plan(libraries):
    plan = {}
    for name in COMPILE_METADATA_JARS:
        path = libraries / name
        with zipfile.ZipFile(path) as jar:
            entries = [n for n in jar.namelist() if not n.endswith('/')]
            for entry in entries:
                allowed = (entry == 'META-INF/MANIFEST.MF' or entry.startswith('META-INF/maven/')
                           or entry.endswith(('.kotlin_metadata', '.kotlin_module')))
                runtime = entry.endswith(('.class', '.so', '.dll', '.dylib', '.jnilib')) or entry.startswith('META-INF/services/')
                if runtime or not allowed:
                    raise ValueError('Expected compile-only metadata, found runtime content: ' + name + ':' + entry)
        plan[name] = {'sha256': digest(path.read_bytes()), 'size': sizes(path), 'entries': len(entries)}
    return plan


def optimize(runtime, baseline, jimage):
    resources = runtime / 'Resources'
    libraries = resources / 'JavaHost/lib'
    all_jars = list((resources / 'JavaHost').rglob('*.jar'))
    jar = libraries / SDK_JAR
    metadata_jars = metadata_archive_plan(libraries)
    untouched = {str(p.relative_to(resources)): digest(p.read_bytes()) for p in all_jars
                 if p != jar and p.name not in metadata_jars}
    image = resources / 'lib/lib/modules'
    before_entries = image_entries(jimage, baseline)
    after_entries = image_entries(jimage, image)
    expected_entries, removed_metadata = retained_image_entries(before_entries)
    if expected_entries != after_entries:
        raise ValueError('JDK class/runtime resource set changed outside the compiler metadata allowlist')
    resource_hashes = verify_runtime_resources(jimage, baseline, image, expected_entries)
    report = {'profile': 'preserve-classes-v2', 'jdk': {
        'before': sizes(baseline), 'after': sizes(image),
        'modules': [n.removeprefix('Module: ') for n in after_entries if n.startswith('Module: ')],
        'entries': len(after_entries), 'runtime_entry_set_identical': True,
        'preserved_classes': sum(n.endswith('.class') for n in after_entries),
        'removed_compiler_metadata': removed_metadata,
        'module_sizes_before': module_sizes(jimage, baseline),
        'module_sizes_after': module_sizes(jimage, image),
        'runtime_resources_sha256': resource_hashes,
        'options': ['--exclude-resources=glob:/*/_the.*', '--strip-debug', '--compress=zip-0', '--no-header-files', '--no-man-pages']},
        'android_sdk': optimize_sdk(jar), 'removed_compile_metadata_jars': metadata_jars,
        'unchanged_jars_sha256': untouched}
    for name in metadata_jars:
        (libraries / name).unlink()
    for relative, expected in untouched.items():
        if digest((resources / relative).read_bytes()) != expected:
            raise ValueError('Runtime dependency changed: ' + relative)
    (runtime / 'packaging-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    cfg = sub.add_parser('configure')
    cfg.add_argument('script', type=Path)
    res = sub.add_parser('resources')
    res.add_argument('runtime', type=Path)
    res.add_argument('--baseline-modules', required=True, type=Path)
    res.add_argument('--jimage', required=True, type=Path)
    args = parser.parse_args()
    if args.command == 'configure':
        configure(args.script)
    else:
        optimize(args.runtime, args.baseline_modules, args.jimage)


if __name__ == '__main__':
    main()
