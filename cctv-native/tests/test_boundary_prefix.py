"""A boundary prefix must contain a fully delimited first video PES."""
import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from cctv_native_ts import inspect_boundary_prefix,inspect_ts,boundary_proven_by,TSFormatError
from test_ts import Builder,pes


class TestBoundaryPrefix(unittest.TestCase):
    def sample(self,*,bounded=True,sizes=(176,),second=True):
        b=Builder();packets=b.tables()
        es=b'\x00\x00\x00\x01\x67SPS\x00\x00\x01\x65'+b'ABCD'*150
        first=b.packets(256,pes(es,bounded=bounded),sizes=sizes)
        packets+=first;end=len(packets)*188
        if second:packets+=b.packets(256,pes(b'\x00\x00\x01\x41'+b'EFGH'*100),sizes=sizes)
        return b''.join(packets),end

    def test_bounded_first_pes_is_trimmed_and_source_identity_preserved(self):
        raw,end=self.sample()
        prefix,a=inspect_boundary_prefix(raw)
        self.assertEqual(prefix,raw[:end]);self.assertIs(a._source,prefix)
        self.assertFalse(a.nals[-1].complete)
        self.assertEqual(a._packet_view,())
        self.assertTrue(boundary_proven_by(prefix,program_number=a.program_number,video_pid=a.video_pid,_prepared=a))

    def test_header_can_span_ts_packets(self):
        for bounded in (True,False):
            raw,end=self.sample(bounded=bounded,sizes=(2,3,4,61))
            pair=inspect_boundary_prefix(raw)
            self.assertIsNotNone(pair);self.assertEqual(pair[0],raw[:end])

    def test_unbounded_first_pes_requires_next_complete_valid_header(self):
        raw,end=self.sample(bounded=False)
        self.assertIsNone(inspect_boundary_prefix(raw[:end]))
        prefix,a=inspect_boundary_prefix(raw)
        self.assertEqual(prefix,raw[:end]);self.assertTrue(a.unbounded_final_pes)
        # Corrupt the second video's PES prefix using its known TS payload.
        after=raw[end:];start=4+(1+after[4] if after[3]&0x20 else 0)
        damaged=bytearray(raw);damaged[end+start]=0x55
        self.assertIsNone(inspect_boundary_prefix(bytes(damaged)))

    def test_incomplete_first_pes_and_no_program_are_not_proof(self):
        raw,end=self.sample()
        self.assertIsNone(inspect_boundary_prefix(raw[:end-188]))
        self.assertIsNone(inspect_boundary_prefix(raw[376:]))
        self.assertIsNone(inspect_boundary_prefix(b''))

    def test_selected_program_and_pid_must_match(self):
        raw,_=self.sample()
        self.assertIsNotNone(inspect_boundary_prefix(raw,program_number=1,video_pid=256))
        self.assertIsNone(inspect_boundary_prefix(raw,program_number=2))
        self.assertIsNone(inspect_boundary_prefix(raw,video_pid=257))

    def test_bad_crc_continuity_scrambling_and_nal_fail_closed(self):
        raw,_=self.sample(sizes=(61,))
        variants=[]
        bad=bytearray(raw);bad[187]^=1;variants.append(bytes(bad))
        a=inspect_ts(raw);offsets=[p.payload_offset+len(p.payload)-188 for p in a._packet_view if p.pid==256 and p.payload]
        bad=bytearray(raw);bad[offsets[1]+3]^=2;variants.append(bytes(bad))
        bad=bytearray(raw);bad[offsets[0]+3]|=0x80;variants.append(bytes(bad))
        bad=bytearray(raw);bad[a.nals[0].spans[0].ts_offset]=0x80;variants.append(bytes(bad))
        for bad in variants:
            with self.subTest(prefix=bad[:8]):self.assertIsNone(inspect_boundary_prefix(bad))

    def test_trailing_partial_packet_is_only_ignored_for_explicit_prefix_api(self):
        raw,end=self.sample();partial=raw[:end+13]
        self.assertEqual(inspect_boundary_prefix(partial)[0],raw[:end])
        with self.assertRaises(TSFormatError):inspect_ts(partial)

    def test_unbounded_needs_entire_next_header_when_split(self):
        raw,end=self.sample(bounded=False,sizes=(2,3,4,61))
        self.assertIsNone(inspect_boundary_prefix(raw[:end+188]))
        self.assertIsNotNone(inspect_boundary_prefix(raw))

    def test_unbounded_invalid_next_header_flags_are_not_a_delimiter(self):
        raw,end=self.sample(bounded=False)
        after=raw[end:];start=4+(1+after[4] if after[3]&0x20 else 0)
        for field,value in ((3,0xBD),(6,0),(7,0x40),(8,0)):
            bad=bytearray(raw);bad[end+start+field]=value
            with self.subTest(field=field):
                self.assertTrue(inspect_boundary_prefix(bytes(bad)) is None, 'invalid PES header accepted')

    def test_first_annexb_marker_must_be_at_zero(self):
        b=Builder()
        raw=b''.join(b.tables()+b.packets(256,pes(b'\x00\x00\x00\x00\x00\x01\x65abc')))
        self.assertIsNone(inspect_boundary_prefix(raw))
