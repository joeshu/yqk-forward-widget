import unittest
from dataclasses import replace
from test_pes import stream
from cctv_native_ts import inspect_ts,transform_pes_nals,TSFormatError


class TestPreparedRepack(unittest.TestCase):
    def test_prepared_mapping_retains_exact_output_and_all_validation(self):
        raw,_=stream()
        analysis=inspect_ts(raw,final_nal_complete=True)
        expected,_=transform_pes_nals(raw,lambda n,data:data,final_nal_complete=True)
        actual,_=transform_pes_nals(raw,lambda n,data:data,final_nal_complete=True,_prepared=analysis)
        self.assertEqual(actual,expected)
        self.assertEqual(actual,raw)

    def test_analysis_from_other_byte_object_is_rejected_even_if_bytes_equal(self):
        raw,_=stream()
        analysis=inspect_ts(raw,final_nal_complete=True)
        copied=bytes(bytearray(raw))
        self.assertEqual(copied,raw)
        self.assertIsNot(copied,raw)
        with self.assertRaisesRegex(TSFormatError,'Prepared TS analysis'):
            transform_pes_nals(copied,lambda n,data:data,final_nal_complete=True,_prepared=analysis)

    def test_prepared_analysis_without_final_proof_is_rejected(self):
        raw,_=stream()
        analysis=inspect_ts(raw)
        with self.assertRaisesRegex(TSFormatError,'boundary assertion'):
            transform_pes_nals(raw,lambda n,data:data,final_nal_complete=True,_prepared=analysis)

    def test_prepared_boundary_requires_same_bytes_and_stream_selection(self):
        from cctv_native_ts import boundary_proven_by
        from unittest import mock
        raw,_=stream();analysis=inspect_ts(raw)
        with mock.patch('cctv_native_ts.inspect_ts',side_effect=AssertionError('duplicate parse')):
            self.assertTrue(boundary_proven_by(raw,program_number=analysis.program_number,
                                             video_pid=analysis.video_pid,_prepared=analysis))
            self.assertFalse(boundary_proven_by(bytes(bytearray(raw)),_prepared=analysis))
            self.assertFalse(boundary_proven_by(raw,program_number=analysis.program_number+1,_prepared=analysis))
            self.assertFalse(boundary_proven_by(raw,video_pid=analysis.video_pid+1,_prepared=analysis))

    def test_validation_only_parse_matches_media_and_nals_without_remap(self):
        for options in ({},{'second_pes':True,'pcr':True},{'sizes':(2,3,4,61),'pts_dts':True}):
            raw,_=stream(**options)
            full=inspect_ts(raw,final_nal_complete=True)
            checked=inspect_ts(raw,final_nal_complete=True,_map_bytes=False)
            self.assertEqual(checked.elementary,full.elementary)
            self.assertEqual([full.nal_bytes(n) for n in full.nals],[checked.nal_bytes(n) for n in checked.nals])
            self.assertEqual(checked.spans,());self.assertEqual(checked._packet_view,())
            with self.assertRaises(TSFormatError):
                transform_pes_nals(raw,lambda n,b:b,final_nal_complete=True,_prepared=checked)

    def test_validation_only_parse_rejects_bad_ts_psi_and_nal(self):
        raw,_=stream();full=inspect_ts(raw)
        bad_sync=bytearray(raw);bad_sync[0]=0
        bad_crc=bytearray(raw);bad_crc[187]^=1
        bad_nal=bytearray(raw);bad_nal[full.nals[0].spans[0].ts_offset]=0x80
        for bad in (bytes(bad_sync),bytes(bad_crc),bytes(bad_nal),raw[:-1]):
            with self.subTest(bad=bad[:5]),self.assertRaises(TSFormatError):
                inspect_ts(bad,_map_bytes=False)
