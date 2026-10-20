"""Synthetic, offline fixtures. No website data or external tools required."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cctv_native_ts import TSFormatError, boundary_proven_by, inspect_ts, mpeg_crc32, transform_nals


def section(table_id, body):
    size = len(body) + 4
    value = bytes([table_id, 0xB0 | (size >> 8), size & 255]) + body
    return value + mpeg_crc32(value).to_bytes(4, "big")


def pat(programs=((1, 4095),)):
    body = b"\x00\x01\xc1\x00\x00"
    for number, pid in programs:
        body += number.to_bytes(2, "big") + (0xE000 | pid).to_bytes(2, "big")
    return section(0, body)


def pmt(streams=((0x1B, 256), (0x0F, 257))):
    body = b"\x00\x01\xc1\x00\x00\xe1\x00\xf0\x00"
    for kind, pid in streams:
        body += bytes([kind]) + (0xE000 | pid).to_bytes(2, "big") + b"\xf0\x00"
    return section(2, body)


def packet(pid, payload, cc, *, pusi=False, pcr=False):
    head = bytes([0x47, (0x40 if pusi else 0) | (pid >> 8), pid & 255])
    if len(payload) == 184 and not pcr:
        return head + bytes([0x10 | cc]) + payload
    size = 183 - len(payload)
    if size < 0 or (pcr and size < 7):
        raise ValueError("fixture packet too large")
    adaptation = bytes([size])
    if size:
        flags = 0x10 if pcr else 0
        values = bytes([flags]) + (b"\x00\x00\x01\x02\x7e\x00" if pcr else b"")
        adaptation += values + b"\xff" * (size - len(values))
    return head + bytes([0x30 | cc]) + adaptation + payload


class Builder:
    def __init__(self):
        self.cc = {}

    def packets(self, pid, payload, sizes=(176,), *, pusi=True, pcr=False):
        result = []
        cursor = 0
        index = 0
        while cursor < len(payload):
            value = payload[cursor : cursor + sizes[index % len(sizes)]]
            cc = self.cc.get(pid, 0)
            result.append(packet(pid, value, cc, pusi=pusi and index == 0, pcr=pcr))
            self.cc[pid] = (cc + 1) % 16
            cursor += len(value)
            index += 1
        return result

    def tables(self, *, programs=((1, 4095),), streams=((0x1B, 256), (0x0F, 257))):
        return self.packets(0, b"\x00" + pat(programs), sizes=(2, 3, 7)) + self.packets(
            4095, b"\x00" + pmt(streams), sizes=(2, 4, 6)
        )


def pes(es, *, bounded=True):
    optional = b"\x80\x80\x05\x21\x00\x01\x00\x01"
    count = len(optional) + len(es) if bounded else 0
    return b"\x00\x00\x01\xe0" + count.to_bytes(2, "big") + optional + es


def fixture(*, final_slice=False, unbounded=False, multi_program=False, two_video=False):
    builder = Builder()
    programs = ((1, 4095), (2, 4094)) if multi_program else ((1, 4095),)
    streams = ((0x1B, 256), (0x1B, 258)) if two_video else ((0x1B, 256), (0x0F, 257))
    packets = builder.tables(programs=programs, streams=streams)
    es = (
        b"\x00\x00\x00\x01\x67SPS"
        b"\x00\x00\x01\x68PP"
        b"\x00\x00\x00\x01\x65" + bytes([3, 4, 5, 6, 7, 8, 9]) * 70
        + b"\x00\x00\x01\x41" + b"\xaa\xbb\xcc" * 150
    )
    if not final_slice:
        es += b"\x00\x00\x01\x09\xf0"
    # The IDR NAL crosses a PES boundary; the first PES header also crosses TS packets.
    first = builder.packets(256, pes(es[:80]), sizes=(2, 3, 4, 61), pcr=True)
    second = builder.packets(256, pes(es[80:], bounded=not unbounded), sizes=(83, 176), pcr=True)
    audio = builder.packets(257, b"\x00\x00\x01\xc0" + b"AUDIO" * 100)
    packets.extend(first[:2] + audio[:1] + first[2:] + second[:2] + audio[1:] + second[2:])
    return b"".join(packets), es


class TestTSNAL(unittest.TestCase):
    def test_extra_zero_bytes_before_prefix_stay_in_protected_nal(self):
        builder = Builder()
        value = b'\x65DATA\x00\x00\x00'
        es = b'\x00\x00\x00\x01' + value + b'\x00\x00\x00\x01\x09\xf0'
        data = b''.join(builder.tables() + builder.packets(256, pes(es)))
        analysis = inspect_ts(data)
        self.assertEqual(analysis.nal_bytes(analysis.nals[0]), value)
        self.assertEqual([n.prefix_length for n in analysis.nals], [4, 4])

    def test_pat_pmt_pes_and_annexb_are_reconstructed(self):
        data, es = fixture()
        result = inspect_ts(data)
        self.assertEqual((result.program_number, result.pmt_pid, result.video_pid, result.pcr_pid),
                         (1, 4095, 256, 256))
        self.assertEqual(result.elementary, es)
        self.assertEqual([n.nal_type for n in result.nals], [7, 8, 5, 1, 9])
        self.assertEqual([n.prefix_length for n in result.nals], [4, 3, 4, 3, 3])
        self.assertEqual(result.pes_count, 2)
        self.assertEqual([n.complete for n in result.nals], [True, True, True, True, False])
        self.assertGreater(len(result.slice_nals[0].spans), 3)
        for nal in result.nals:
            actual = b"".join(data[s.ts_offset : s.ts_offset + s.length] for s in nal.spans)
            self.assertEqual(actual, result.nal_bytes(nal))

    def test_identity_roundtrip_is_exact(self):
        data, _ = fixture()
        output, _ = transform_nals(data, lambda nal, value: value)
        self.assertEqual(output, data)

    def test_processor_can_select_sps_and_slices_in_stream_order(self):
        data, _ = fixture()
        visited = []
        output, _ = transform_nals(data, lambda n, b: visited.append(n.nal_type) or b, nal_types=(1, 5, 7))
        self.assertEqual(visited, [7, 5, 1])
        self.assertEqual(output, data)
        for selection in ((), (0,), (24,), (True,)):
            with self.subTest(selection=selection), self.assertRaises(ValueError):
                transform_nals(data, lambda n, b: b, nal_types=selection)

    def test_sps_byte_two_may_change_while_header_stays_intact(self):
        data, _ = fixture()

        def process(nal, value):
            if nal.nal_type == 7:
                return value[:2] + b"\x00" + value[3:]
            return value

        output, _ = transform_nals(data, process, nal_types=(1, 5, 7))
        result = inspect_ts(output)
        sps = next(nal for nal in result.nals if nal.nal_type == 7)
        self.assertEqual(result.nal_bytes(sps), b"\x67S\x00S")

    def test_replacement_preserves_all_other_bytes(self):
        data, _ = fixture()
        visited = []

        def callback(nal, original):
            visited.append(nal.nal_type)
            return original[:1] + b"\x55" * (len(original) - 1)

        output, result = transform_nals(data, callback)
        self.assertEqual(visited, [5, 1])
        self.assertEqual(len(output), len(data))
        mask = bytearray(len(data))
        for nal in result.slice_nals:
            for span in nal.spans:
                mask[span.ts_offset : span.ts_offset + span.length] = b"\x01" * span.length
        for offset, (before, after) in enumerate(zip(data, output)):
            if not mask[offset]:
                self.assertEqual(before, after, f"unselected TS byte changed at {offset}")
        reparsed = inspect_ts(output)
        for nal in reparsed.slice_nals:
            self.assertEqual(reparsed.nal_bytes(nal)[1:], b"\x55" * (nal.length - 1))

    def test_unproven_last_slice_rejected_before_callback(self):
        data, _ = fixture(final_slice=True)
        visited = []
        with self.assertRaisesRegex(TSFormatError, "proven boundary"):
            transform_nals(data, lambda nal, value: visited.append(nal) or value)
        self.assertEqual(visited, [])
        output, _ = transform_nals(data, lambda nal, value: value, final_nal_complete=True)
        self.assertEqual(output, data)

    def test_unbounded_final_pes_is_marked(self):
        data, es = fixture(unbounded=True)
        result = inspect_ts(data)
        self.assertEqual(result.elementary, es)
        self.assertTrue(result.unbounded_final_pes)

    def test_next_independent_segment_can_prove_annexb_boundary(self):
        previous, _ = fixture(final_slice=True)
        next_segment, _ = fixture()
        self.assertTrue(boundary_proven_by(next_segment, program_number=1, video_pid=256))
        output, _ = transform_nals(previous, lambda n, b: b,
                                  final_nal_complete=boundary_proven_by(next_segment))
        self.assertEqual(output, previous)
        self.assertFalse(boundary_proven_by(next_segment[:-1]))
        self.assertFalse(boundary_proven_by(next_segment, program_number=2))
        self.assertFalse(boundary_proven_by(next_segment, video_pid=257))

    def test_boundary_proof_refuses_non_annexb_next_segment(self):
        builder = Builder()
        next_segment = b"".join(builder.tables() + builder.packets(256, pes(b"no Annex B prefix")))
        self.assertFalse(boundary_proven_by(next_segment))

    def test_psi_pointer_finishes_previous_section_then_starts_next(self):
        builder = Builder()
        value = pat()
        packets = builder.packets(0, b"\x00" + value[:7])
        packets += builder.packets(0, bytes([len(value) - 7]) + value[7:] + value)
        packets += builder.packets(4095, b"\x00" + pmt())
        es = b"\x00\x00\x01\x65abc\x00\x00\x01\x09\xf0"
        packets += builder.packets(256, pes(es))
        self.assertEqual(inspect_ts(b"".join(packets)).elementary, es)

    def test_bad_psi_pointer_rejected(self):
        builder = Builder()
        with self.assertRaisesRegex(TSFormatError, "PSI pointer"):
            inspect_ts(b"".join(builder.packets(0, b"\xff" + pat())))

    def test_equal_length_and_immutable_bytes_required(self):
        data, _ = fixture()
        for callback in (lambda n, b: b + b"x", lambda n, b: b[:-1], lambda n, b: bytearray(b)):
            with self.subTest(callback=callback), self.assertRaisesRegex(TSFormatError, "exact original length"):
                transform_nals(data, callback)

    def test_header_change_and_internal_startcode_rejected(self):
        data, _ = fixture()
        for callback in (lambda n, b: bytes([b[0] ^ 1]) + b[1:],
                         lambda n, b: b[:1] + b"\x00\x00\x01" + b[4:]):
            with self.subTest(callback=callback), self.assertRaises(TSFormatError):
                transform_nals(data, callback)

    def test_multi_program_requires_explicit_selection(self):
        data, _ = fixture(multi_program=True)
        with self.assertRaisesRegex(TSFormatError, "program_number explicitly"):
            inspect_ts(data)
        self.assertEqual(inspect_ts(data, program_number=1).video_pid, 256)

    def test_multiple_video_streams_require_selection(self):
        data, _ = fixture(two_video=True)
        with self.assertRaisesRegex(TSFormatError, "one H.264 stream"):
            inspect_ts(data)
        self.assertEqual(inspect_ts(data, video_pid=256).video_pid, 256)

    def test_missing_h264_stream_is_rejected(self):
        builder = Builder()
        data = b"".join(builder.tables(streams=((0x24, 256),)))
        with self.assertRaisesRegex(TSFormatError, "H.264 stream"):
            inspect_ts(data)

    def test_bad_alignment_sync_tei_and_reserved_header_rejected(self):
        data, _ = fixture()
        variants = [data[:-1]]
        for index, value in ((0, 0x46), (1, data[1] | 0x80), (3, data[3] & 0xCF)):
            value_data = bytearray(data)
            value_data[index] = value
            variants.append(bytes(value_data))
        for value in variants:
            with self.subTest(value=value[:8]), self.assertRaises(TSFormatError):
                inspect_ts(value)

    def test_adaptation_overflow_and_short_pcr_rejected(self):
        data, _ = fixture()
        bad = bytearray(data)
        bad[4] = 184
        with self.assertRaisesRegex(TSFormatError, "adaptation length"):
            inspect_ts(bytes(bad))
        malformed = packet(0, b"\x00" + pat(), 0)
        malformed = bytearray(malformed)
        malformed[5] = 0x10
        malformed[4] = 1
        with self.assertRaisesRegex(TSFormatError, "adaptation data"):
            inspect_ts(bytes(malformed))

    def test_continuity_gap_rejected_legal_psi_duplicate_ignored(self):
        data, _ = fixture()
        bad = bytearray(data)
        bad[188 + 3] ^= 2
        with self.assertRaisesRegex(TSFormatError, "continuity gap"):
            inspect_ts(bytes(bad))
        result = inspect_ts(data[:188] + data)
        self.assertEqual(result.elementary, inspect_ts(data).elementary)

    def test_video_duplicate_rejected_until_one_to_many_mapping_exists(self):
        data, _ = fixture()
        for offset in range(0, len(data), 188):
            if ((data[offset + 1] & 31) << 8 | data[offset + 2]) == 256:
                duplicate = data[:offset] + data[offset : offset + 188] + data[offset:]
                break
        with self.assertRaisesRegex(TSFormatError, "Duplicate video TS packet"):
            inspect_ts(duplicate)

    def test_video_discontinuity_is_not_silently_concatenated(self):
        data, _ = fixture()
        bad = bytearray(data)
        seen = False
        for offset in range(0, len(data), 188):
            if ((data[offset + 1] & 31) << 8 | data[offset + 2]) == 256:
                if seen:
                    bad[offset + 5] |= 0x80
                    break
                seen = True
        with self.assertRaisesRegex(TSFormatError, "Video discontinuity"):
            inspect_ts(bytes(bad))

    def test_crc_mismatch_and_incomplete_psi_rejected(self):
        builder = Builder()
        bad_pat = bytearray(pat())
        bad_pat[-1] ^= 1
        with self.assertRaisesRegex(TSFormatError, "CRC mismatch"):
            inspect_ts(b"".join(builder.packets(0, b"\x00" + bad_pat)))
        builder = Builder()
        with self.assertRaisesRegex(TSFormatError, "PSI section is incomplete"):
            inspect_ts(b"".join(builder.packets(0, b"\x00" + pat()[:6])))

    def test_bounded_truncated_pes_rejected(self):
        builder = Builder()
        packets = builder.tables()
        packets += builder.packets(256, pes(b"\x00\x00\x01\x65abc")[:-1])
        with self.assertRaisesRegex(TSFormatError, "Bounded PES packet"):
            inspect_ts(b"".join(packets))

    def test_cross_chunk_pes_header_requires_previous_chunk(self):
        builder = Builder()
        packets = builder.tables()
        table_count = len(packets)
        packets += builder.packets(256, pes(b"\x00\x00\x01\x65abc"), sizes=(2, 3, 4))
        with self.assertRaisesRegex(TSFormatError, "Incomplete MPEG-2 PES header"):
            inspect_ts(b"".join(packets[: table_count + 1]))

    def test_video_continuation_at_input_start_rejected(self):
        builder = Builder()
        packets = builder.tables()
        packets += builder.packets(256, b"continuation", pusi=False)
        with self.assertRaisesRegex(TSFormatError, "retain the previous HLS chunk"):
            inspect_ts(b"".join(packets))

    def test_scrambled_video_rejected(self):
        data, _ = fixture()
        bad = bytearray(data)
        for offset in range(0, len(data), 188):
            if ((data[offset + 1] & 31) << 8 | data[offset + 2]) == 256:
                bad[offset + 3] |= 0x80
                break
        with self.assertRaisesRegex(TSFormatError, "scrambled video"):
            inspect_ts(bytes(bad))


if __name__ == "__main__":
    unittest.main()
