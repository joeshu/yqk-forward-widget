import importlib.util
import io
import pathlib
import struct
import unittest
import warnings
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ipa_live_audit', ROOT / 'Scripts/audit_ipa_live_routes.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class AddressDecoderTests(unittest.TestCase):
    def test_direct_forward_backward_and_tail_branches(self):
        self.assertEqual(AUDIT.branch_target(0x94000004, 0x1000), 0x1010)
        self.assertEqual(AUDIT.branch_target(0x97ffffff, 0x1000), 0xffc)
        self.assertEqual(AUDIT.branch_target(0x14000002, 0x1000), 0x1008)
        self.assertIsNone(AUDIT.branch_target(0x54000040, 0x1000))
        self.assertIsNone(AUDIT.branch_target(0xf9400021, 0x1000))

    def test_adrp_negative_page_uses_instruction_page(self):
        self.assertEqual(AUDIT.adrp_target(0x90000001, 0x1234), 0x1000)
        self.assertEqual(AUDIT.adrp_target(0xf0ffffe1, 0x1234), 0)

    def test_invalid_or_truncated_macho_rejected(self):
        for data in (b'', b'not a binary' * 10,
                     struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 8, 0, 0)):
            with self.assertRaises(ValueError):
                AUDIT.MachO(data)

    def test_duplicate_or_oversized_zip_member_rejected(self):
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, 'w') as archive:
            archive.writestr('entry', b'1234')
        memory.seek(0)
        with zipfile.ZipFile(memory) as archive:
            with self.assertRaises(ValueError):
                AUDIT.member(archive, 'entry', 3)
            with self.assertRaises(ValueError):
                AUDIT.member(archive, 'missing', 4)
            self.assertEqual(AUDIT.member(archive, 'entry', 4), b'1234')
        with zipfile.ZipFile(memory, 'a') as archive, warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            archive.writestr('entry', b'5678')
        memory.seek(0)
        with zipfile.ZipFile(memory) as archive:
            with self.assertRaises(ValueError):
                AUDIT.member(archive, 'entry', 4)

    def test_only_known_selector_stub_layout_is_accepted(self):
        data = bytearray(0x4000)
        struct.pack_into('<II', data, 0, 0xb0000001, 0xf9400021)
        struct.pack_into('<Q', data, 0x1000, 0x3000)
        data[0x2000:0x2005] = b'play\0'
        reader = AUDIT.MachO.__new__(AUDIT.MachO)
        reader.data, reader.base = data, 0x1000
        reader.segments, reader.sections = [(0x1000, 0, len(data))], {'__objc_stubs': (0x1000, 16)}
        self.assertEqual(reader.selector_stub(0x1000), 'play')
        self.assertIsNone(reader.selector_stub(0x2000))
        struct.pack_into('<I', data, 4, 0xf9400020)  # Loads x0, not selector register x1.
        self.assertIsNone(reader.selector_stub(0x1000))


@unittest.skipUnless(AUDIT.DEFAULT_IPA.is_file(), 'requires user-supplied repository IPA')
class ProvidedIPAContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = AUDIT.audit(AUDIT.DEFAULT_IPA)

    def test_identity_and_exact_sdk_match(self):
        self.assertEqual(self.report['sample']['bundle_id'], 'cn.vuclip.mobiletv')
        self.assertEqual(self.report['sample']['version'], '7.9.31')
        self.assertEqual(self.report['sample']['sha256'], 'e7b153ab80a17a646d7011ebedc17b786835ab27feba4959af07bcc7ec8c9315')
        self.assertTrue(self.report['sdk']['matches_host_sdk'])

    def test_all_three_url_frontends_really_call_cnplayer(self):
        for wrapper in self.report['app_url_frontends']:
            with self.subTest(frontend=wrapper['class']):
                self.assertEqual(len(wrapper['url_play_calls']), 1)
                self.assertEqual(wrapper['url_play_calls'][0]['selector'], AUDIT.URL_SELECTOR)
        method = self.report['sdk']['url_play_instance_method']
        self.assertEqual(method['types'], 'B40@0:8@16@24@32')

    def test_channel_metadata_and_verification_boundary(self):
        self.assertEqual(self.report['sample_channel_drm_metadata'], {'cctv1': '1', 'cctv7': '1', 'cctv13': '1'})
        self.assertTrue(self.report['static_audit_only'])
        self.assertFalse(self.report['native_playback_verified'])


if __name__ == '__main__':
    unittest.main()
