import struct
import tempfile
from pathlib import Path
import sys
import unittest

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media


class HgtvSampleEntryCompatibilityTests(unittest.TestCase):
    def test_stsd_fullbox_header_is_skipped_before_sample_entries(self):
        source = '''
def _boxes(data, start, end):
    while start + 8 <= end:
        size = int.from_bytes(data[start:start + 4], 'big')
        kind = data[start + 4:start + 8]
        if size < 8 or start + size > end:
            return
        yield kind, start, start + 8, start + size
        start += size

def _walk_stsd(data, start, end, out):
    for kind, box_start, _payload, _box_end in _boxes(data, start, end):
        if kind == b'encv':
            out.append((box_start, b'hvc1'))

def collect_patches(d, start, end, out):
    cs, be = start, end
    _walk_stsd(d, cs, be, out)

def decrypt_moov_bytes(data, start, patches):
    return data

class Spider:
    def homeContent(self, _filter):
        return {'class': []}
'''
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'fixture.py').write_text(source)
            engine = media.PythonSpider(root, 'fixture.py')
            try:
                module = sys.modules[engine.module_name]
                entry = struct.pack('>I4s', 12, b'encv') + bytes(4)
                stsd_payload = bytes(4) + struct.pack('>I', 1) + entry
                patches = []
                module.collect_patches(stsd_payload, 0, len(stsd_payload), patches)
                self.assertTrue(module._cctvhost_stsd_compat_applied)
                self.assertEqual(patches, [(8, b'hvc1')])
            finally:
                engine.close()


if __name__ == '__main__':
    unittest.main()
