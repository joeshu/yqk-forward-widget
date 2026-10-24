#!/usr/bin/env python3
"""Read-only audit of live URL frontends in the user-supplied CCTV IPA.

Does not load executable code, request a license, inspect DRM implementations,
or establish playback success. Uses only stdlib and the repository's ObjC indexer.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_IPA = ROOT.parent / 'cctv-app-udrm/cn.vuclip.mobiletv-7.9.31-eeveedecrypter.ipa'
URL_SELECTOR = 'playLIVEWithUrl:delegate:configOptions:'
APP_SELECTOR = 'playLiveVideoWithUrl:configOptions:'
FRONTENDS = ('CNPlayerSimpleLiveView', 'CNPlayerLiveView', 'CNPlayerPortraitLiveView')


class MachO:
    """Minimal arm64 address/selector reader; deliberately not a general decompiler."""
    def __init__(self, data):
        self.data = data
        if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
            raise ValueError('expected a thin little-endian arm64 Mach-O')
        self.segments, self.sections = [], {}
        count, command_bytes = struct.unpack_from('<II', data, 16)
        end, cursor = 32 + command_bytes, 32
        if end > len(data) or count > 10000:
            raise ValueError('invalid Mach-O load command bounds')
        for _ in range(count):
            if cursor + 8 > end:
                raise ValueError('truncated Mach-O load command')
            cmd, size = struct.unpack_from('<II', data, cursor)
            if size < 8 or cursor + size > end:
                raise ValueError('invalid Mach-O load command size')
            if cmd == 0x19:
                if size < 72:
                    raise ValueError('truncated segment')
                values = struct.unpack_from('<II16sQQQQIIII', data, cursor)
                _, _, _, address, _, offset, length, _, _, nsections, _ = values
                if offset + length > len(data) or 72 + nsections * 80 > size:
                    raise ValueError('invalid Mach-O segment bounds')
                self.segments.append((address, offset, length))
                for i in range(nsections):
                    item = struct.unpack_from('<16s16sQQIIIIIIII', data, cursor + 72 + i * 80)
                    self.sections[item[0].rstrip(b'\0').decode('ascii')] = (item[2], item[3])
            cursor += size
        self.base = min(a for a, _, n in self.segments if n)

    def at(self, address, length):
        for base, offset, size in self.segments:
            if base <= address and address + length <= base + size:
                return self.data[offset + address - base:offset + address - base + length]
        raise ValueError('address outside file-backed Mach-O segments')

    def pointer(self, address):
        value, = struct.unpack('<Q', self.at(address, 8))
        try:
            self.at(value, 1)
            return value
        except ValueError:
            # This sample's non-authenticated chained rebase encodes low 36 bits.
            if value >> 63:
                raise ValueError('bound/authenticated pointer is not a selector')
            target = self.base + (value & ((1 << 36) - 1))
            self.at(target, 1)
            return target

    def selector_stub(self, target):
        base, size = self.sections.get('__objc_stubs', (0, 0))
        if not base <= target < base + size - 8:
            return None
        adrp, load = struct.unpack('<II', self.at(target, 8))
        # objc_msgSend stub: ADRP x1, page ; LDR x1, [x1, #offset].
        if adrp & 0x9f00001f != 0x90000001 or load & 0xffc003ff != 0xf9400021:
            return None
        page = adrp_target(adrp, target)
        slot = page + ((load >> 10) & 4095) * 8
        selector = self.pointer(slot)
        chars = bytearray()
        for i in range(1024):
            char = self.at(selector + i, 1)
            if char == b'\0':
                return chars.decode('utf-8')
            chars.extend(char)
        raise ValueError('unterminated selector')

    def calls(self, start, end):
        if not start < end <= start + 32768:
            raise ValueError('unexpected frontend method extent')
        result = []
        for i in range(start, end - 3, 4):
            opcode, = struct.unpack('<I', self.at(i, 4))
            target = branch_target(opcode, i)
            if target is not None:
                name = self.selector_stub(target)
                if name:
                    result.append({'address': hex(i), 'selector': name})
        return result


def sign_extend(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def adrp_target(opcode, address):
    immediate = ((opcode >> 5) & 0x7ffff) << 2 | ((opcode >> 29) & 3)
    return (address & ~4095) + (sign_extend(immediate, 21) << 12)


def branch_target(opcode, address):
    # Only direct BL and tail-call B, never conditional branches or data loads.
    if opcode & 0xfc000000 not in (0x94000000, 0x14000000):
        return None
    return address + sign_extend(opcode & 0x3ffffff, 26) * 4


def index(data):
    script = ROOT.parent / 'tools/ipa/objc-method-index.py'
    with tempfile.TemporaryDirectory(prefix='cctv-ipa-audit-') as folder:
        binary = pathlib.Path(folder) / 'binary'
        binary.write_bytes(data)
        output = subprocess.run([sys.executable, str(script), str(binary)], check=True,
                                capture_output=True, text=True, timeout=30)
    result = json.loads(output.stdout)
    if any(item[2] for item in result.get('crypt', [])):
        raise ValueError('encrypted image cannot provide reliable frontend evidence')
    return {c['name']: c for c in result['classes']}


def member(archive, name, limit):
    matches = [i for i in archive.infolist() if i.filename == name]
    if len(matches) != 1 or matches[0].file_size > limit:
        raise ValueError('missing, duplicate or oversized IPA member')
    return archive.read(matches[0])


def audit(path):
    with zipfile.ZipFile(path) as archive:
        plists = [i.filename for i in archive.infolist() if i.filename.startswith('Payload/')
                  and i.filename.count('/') == 2 and i.filename.endswith('.app/Info.plist')]
        if len(plists) != 1:
            raise ValueError('expected exactly one root app Info.plist')
        prefix = plists[0].rsplit('/', 1)[0] + '/'
        info = plistlib.loads(member(archive, plists[0], 1024 * 1024))
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or not executable or '/' in executable or executable in ('.', '..'):
            raise ValueError('invalid executable member name')
        app = member(archive, prefix + executable, 128 * 1024 * 1024)
        sdk = member(archive, prefix + 'Frameworks/CNPlayerSDK.framework/CNPlayerSDK', 64 * 1024 * 1024)
        config = json.loads(member(archive, prefix + 'Frameworks/CNPlayerSDK.framework/CNLiveConfig_V2th.json', 1024 * 1024))
    app_index, sdk_index = index(app), index(sdk)
    app_reader = MachO(app)
    starts = sorted({int(m['imp'], 16) for c in app_index.values()
                     for kind in ('class', 'instance') for m in c[kind]})
    wrappers = []
    for name in FRONTENDS:
        method = next(m for m in app_index[name]['instance'] if m['name'] == APP_SELECTOR)
        start = int(method['imp'], 16)
        end = next(i for i in starts if i > start)
        calls = app_reader.calls(start, end)
        wrappers.append({'class': name, 'method': method, 'url_play_calls': [c for c in calls if c['selector'] == URL_SELECTOR]})
    sdk_url = next(m for m in sdk_index['CNPlayer']['instance'] if m['name'] == URL_SELECTOR)
    local_sdk = ROOT / 'Frameworks/CNPlayerSDK.framework/CNPlayerSDK'
    drm = config['client_config']['channel_info']
    return {
        'static_audit_only': True, 'native_playback_verified': False,
        'sample': {'filename': pathlib.Path(path).name, 'sha256': hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest(),
                   'bundle_id': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                   'executable_sha256': hashlib.sha256(app).hexdigest()},
        'sdk': {'sha256': hashlib.sha256(sdk).hexdigest(),
                'matches_host_sdk': hashlib.sha256(sdk).digest() == hashlib.sha256(local_sdk.read_bytes()).digest(),
                'url_play_instance_method': sdk_url},
        'app_url_frontends': wrappers,
        'sample_channel_drm_metadata': {c['channel']: c.get('drm') for c in drm if c.get('channel') in ('cctv1', 'cctv7', 'cctv13')},
        'interpretation': 'Observed URL frontends call CNPlayer; this does not establish a standalone AVPlayer/Cicada route, a complete DRM configuration contract, or successful decoding.'
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', nargs='?', type=pathlib.Path, default=DEFAULT_IPA)
    args = parser.parse_args()
    print(json.dumps(audit(args.ipa), ensure_ascii=False, indent=2))
