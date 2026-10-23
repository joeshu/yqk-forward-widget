#!/usr/bin/env python3
"""Install the pinned Node.js Mobile device/simulator slice into an app bundle."""
import argparse
import hashlib
import pathlib
import shutil
import tempfile
import urllib.request
import zipfile

VERSION = '18.20.4'
SHA256 = '8c5ca3a0d1e38de7f182a5642593e82593b820efd375a14b3ecafc4bcfee620e'
URL = f'https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v{VERSION}/nodejs-mobile-v{VERSION}-ios.zip'


def prepare(app, simulator=False):
    archive = pathlib.Path(tempfile.gettempdir()) / 'cctvhost-node-mobile-ios.zip'
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        staged = archive.with_suffix('.download')
        with urllib.request.urlopen(URL, timeout=60) as response, staged.open('wb') as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if hashlib.sha256(staged.read_bytes()).hexdigest() != SHA256:
            staged.unlink(missing_ok=True)
            raise ValueError('Node.js Mobile archive checksum mismatch')
        staged.replace(archive)
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.namelist():
                if member.startswith('/') or '..' in pathlib.PurePosixPath(member).parts:
                    raise ValueError('Invalid Node runtime archive path')
            bundle.extractall(tmp)
        variant = 'ios-arm64_x86_64-simulator' if simulator else 'ios-arm64'
        source = pathlib.Path(tmp) / 'NodeMobile.xcframework' / variant / 'NodeMobile.framework'
        destination = pathlib.Path(app) / 'Frameworks' / 'NodeMobile.framework'
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, destination, dirs_exist_ok=True)
        shutil.rmtree(destination / '_CodeSignature', ignore_errors=True)
    print(f'Node.js Mobile {VERSION}: {variant}, verified SHA256')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app')
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    prepare(args.app, args.simulator)
