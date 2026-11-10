#!/usr/bin/env python3
"""Trim packaging overhead without shrinking the dynamic plugin class path."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile
import zlib

ORIGINAL_LINK = '"$HOST/bin/jlink" --module-path "$MODULE_PATH" --add-modules "$MODULES" --output "$LINK/image"'
OPTIMIZED_LINK = ORIGINAL_LINK.replace('$LINK/image', '$LINK/image-baseline') + '\n' + ORIGINAL_LINK.replace(
    '--output', '--strip-debug --compress=zip-0 --no-header-files --no-man-pages --output')
SDK_JAR = 'android-4.1.1.4.jar'


def configure(script):
    text = script.read_text()
    if OPTIMIZED_LINK in text:
        return
    if text.count(ORIGINAL_LINK) != 1:
        raise ValueError('Pinned upstream jlink invocation changed; review packaging before building')
    script.write_text(text.replace(ORIGINAL_LINK, OPTIMIZED_LINK))


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


def optimize(runtime, baseline, jimage):
    resources = runtime / 'Resources'
    libraries = resources / 'JavaHost/lib'
    all_jars = list((resources / 'JavaHost').rglob('*.jar'))
    jar = libraries / SDK_JAR
    untouched = {str(p.relative_to(resources)): digest(p.read_bytes()) for p in all_jars if p != jar}
    image = resources / 'lib/lib/modules'
    before_entries = image_entries(jimage, baseline)
    after_entries = image_entries(jimage, image)
    if before_entries != after_entries:
        raise ValueError('JDK module/class/resource set changed during debug stripping')
    report = {'profile': 'preserve-classes-v1', 'jdk': {
        'before': sizes(baseline), 'after': sizes(image),
        'modules': [n.removeprefix('Module: ') for n in after_entries if n.startswith('Module: ')],
        'entries': len(after_entries), 'entry_set_identical': True,
        'options': ['--strip-debug', '--compress=zip-0', '--no-header-files', '--no-man-pages']},
        'android_sdk': optimize_sdk(jar), 'unchanged_jars_sha256': untouched}
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
