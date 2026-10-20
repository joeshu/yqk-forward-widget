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
