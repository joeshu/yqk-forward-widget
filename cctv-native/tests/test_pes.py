"""Offline PES repacketization invariants using generated transport packets."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cctv_native_ts import TSFormatError, inspect_ts, transform_nals, transform_pes_nals
from test_ts import Builder, fixture, pes


def stream(*, sizes=(176,), pcr=False, bounded=True, second_pes=False, pts_dts=False):
    builder = Builder()
    packets = builder.tables()
    es = (b"\x00\x00\x00\x01\x67SPS" + b"\x00\x00\x01\x65" + b"ABCD" * 150
          + b"\x00\x00\x00\x01\x41" + b"EFGH" * 100
          + b"\x00\x00\x01\x09\xf0")
    if pts_dts:
        timestamp = b"\x31\x00\x01\x00\x01\x11\x00\x01\x00\x01"
        optional = b"\x80\xc0\x0a" + timestamp
        value = b"\x00\x00\x01\xe0" + (len(optional) + len(es)).to_bytes(2, "big") + optional + es
    else:
        value = pes(es, bounded=bounded)
    video = builder.packets(256, value, sizes=sizes, pcr=pcr)
    audio = builder.packets(257, b"AUDIO" * 130)
    packets += video[:2] + audio[:1] + video[2:] + audio[1:]
    if second_pes:
        packets += builder.packets(256, pes(es, bounded=bounded), sizes=sizes, pcr=pcr)
        es += es
    return b"".join(packets), es


def transport_packets(data):
    for offset in range(0, len(data), 188):
        raw = data[offset : offset + 188]
        pid = ((raw[1] & 31) << 8) | raw[2]
        yield offset, pid, raw


def payload(raw):
    if not raw[3] & 0x10:
        return b""
    start = 4 + (1 + raw[4] if raw[3] & 0x20 else 0)
    return raw[start:]


def pes_values(data):
    groups = []
    pending = bytearray()
    for _, pid, raw in transport_packets(data):
        if pid != 256 or not raw[3] & 0x10:
            continue
        if raw[1] & 0x40 and pending:
            groups.append(bytes(pending))
            pending.clear()
        pending.extend(payload(raw))
    if pending:
        groups.append(bytes(pending))
    return groups


class TestPESRepacketization(unittest.TestCase):
    def test_identity_remains_exact_with_cross_packet_headers_and_pcr(self):
        for sizes in ((176,), (2, 3, 4, 61)):
            with self.subTest(sizes=sizes):
                data, _ = stream(sizes=sizes, pcr=True)
                output, _ = transform_pes_nals(data, lambda n, b: b, nal_types=(1, 5, 7))
                self.assertEqual(output, data)

    def test_one_byte_shrink_is_exact_es_and_adaptation_stuffing(self):
        data, _ = stream()
        seen = []

        def callback(nal, value):
            seen.append(nal.nal_type)
            return value[:-1] if nal.nal_type == 1 else value

        output, original = transform_pes_nals(data, callback, nal_types=(1, 5, 7))
        self.assertEqual(seen, [7, 5, 1])
        self.assertEqual(len(output), len(data))
        new = inspect_ts(output)
        original_pes = pes_values(data)[0]
        new_pes = pes_values(output)[0]
        self.assertEqual(len(new_pes), len(original_pes) - 1)
        self.assertEqual(int.from_bytes(new_pes[4:6], "big"), int.from_bytes(original_pes[4:6], "big") - 1)
        self.assertEqual(new_pes[:4] + new_pes[6:14], original_pes[:4] + original_pes[6:14])
        for before, after in zip(original.nals, new.nals):
            expected = original.nal_bytes(before)
            if before.nal_type == 1:
                expected = expected[:-1]
            self.assertEqual(new.nal_bytes(after), expected)
        before_packets = list(transport_packets(data))
        after_packets = list(transport_packets(output))
        last_video = max(i for i, (_, pid, _) in enumerate(before_packets) if pid == 256)
        for index, ((offset, pid, old), (new_offset, new_pid, updated)) in enumerate(zip(before_packets, after_packets)):
            self.assertEqual((offset, pid), (new_offset, new_pid))
            if pid != 256:
                self.assertEqual(old, updated)
                continue
            self.assertEqual(old[:3], updated[:3])
            self.assertEqual(old[3] & 0xCF, updated[3] & 0xCF)
            if index == last_video:
                self.assertEqual(len(payload(updated)), len(payload(old)) - 1)
                self.assertEqual(updated[4], old[4] + 1)
                self.assertEqual(updated[5 : 5 + old[4]], old[5 : 5 + old[4]])
                self.assertEqual(updated[5 + old[4]], 0xFF)
            else:
                self.assertEqual(updated[: 188 - len(payload(updated))], old[: 188 - len(payload(old))])

    def test_pts_dts_pcr_positions_and_audio_preserved(self):
        data, _ = stream(pcr=True, pts_dts=True)
        output, _ = transform_pes_nals(data, lambda n, b: b[:-9] if n.nal_type == 1 else b)
        before_pes = pes_values(data)[0]
        after_pes = pes_values(output)[0]
        self.assertEqual(before_pes[6:19], after_pes[6:19])
        for (offset, pid, before), (new_offset, _, after) in zip(transport_packets(data), transport_packets(output)):
            self.assertEqual(offset, new_offset)
            if pid == 256:
                self.assertEqual(before[5:12], after[5:12])  # flags + the six PCR bytes, same offsets
                self.assertEqual(before[3] & 15, after[3] & 15)
            else:
                self.assertEqual(before, after)

    def test_shrink_across_multiple_packet_slots_keeps_every_payload_nonempty(self):
        data, _ = stream(sizes=(61,), pcr=True)
        output, _ = transform_pes_nals(data, lambda n, b: b[:1] + b[301:] if n.nal_type == 5 else b)
        before_pes = pes_values(data)[0]
        after_pes = pes_values(output)[0]
        self.assertEqual(len(after_pes), len(before_pes) - 300)
        sizes = [len(payload(raw)) for _, pid, raw in transport_packets(output) if pid == 256]
        self.assertTrue(all(size >= 1 for size in sizes))
        self.assertGreater(sum(size == 1 for size in sizes), 1)
        self.assertEqual(len(output), len(data))

    def test_create_zero_length_adaptation_after_no_adaptation_packet(self):
        builder = Builder()
        es = b"\x00\x00\x01\x65" + b"A" * 163 + b"\x00\x00\x01\x09\xf0"
        value = pes(es)
        self.assertEqual(len(value), 186)
        # Use 2+184 so the last packet initially has no adaptation field.
        packets = builder.tables() + builder.packets(256, value, sizes=(2, 184))
        data = b"".join(packets)
        self.assertEqual(packets[-1][3] & 0x30, 0x10)
        output, _ = transform_pes_nals(data, lambda n, b: b[:-1])
        last = output[-188:]
        self.assertEqual(last[3] & 0x30, 0x30)
        self.assertEqual(last[4], 0)
        self.assertEqual(len(payload(last)), 183)

    def test_create_flags_when_zero_length_adaptation_grows(self):
        builder = Builder()
        es = b"\x00\x00\x01\x65" + b"A" * 162 + b"\x00\x00\x01\x09\xf0"
        value = pes(es)
        packets = builder.tables() + builder.packets(256, value, sizes=(2, 183))
        data = b"".join(packets)
        self.assertEqual(packets[-1][4], 0)
        output, _ = transform_pes_nals(data, lambda n, b: b[:-1])
        self.assertEqual(output[-188 + 4 : -188 + 6], b"\x01\x00")

    def test_unbounded_pes_length_stays_zero(self):
        data, _ = stream(bounded=False)
        output, _ = transform_pes_nals(data, lambda n, b: b[:-1])
        self.assertEqual(pes_values(output)[0][4:6], b"\x00\x00")
        self.assertTrue(inspect_ts(output).unbounded_final_pes)

    def test_multiple_pes_shrink_independently(self):
        data, _ = stream(second_pes=True)
        output, _ = transform_pes_nals(data, lambda n, b: b[:-2])
        for before, after in zip(pes_values(data), pes_values(output)):
            self.assertEqual(len(after), len(before) - 4)
        self.assertEqual(inspect_ts(output).pes_count, 2)

    def test_cross_pes_nal_rejected_before_any_callback(self):
        data, _ = fixture()
        calls = []
        with self.assertRaisesRegex(TSFormatError, "crosses PES boundaries"):
            transform_pes_nals(data, lambda n, b: calls.append(n) or b, nal_types=(1, 5, 7))
        self.assertEqual(calls, [])

    def test_last_boundary_still_required_before_any_callback(self):
        data, _ = fixture(final_slice=True)
        calls = []
        with self.assertRaisesRegex(TSFormatError, "proven boundary"):
            transform_pes_nals(data, lambda n, b: calls.append(n) or b)
        self.assertEqual(calls, [])

    def test_growth_empty_mutable_header_change_and_unescaped_startcode_rejected(self):
        data, _ = stream()
        callbacks = (
            (lambda n, b: b + b"x", "growth"),
            (lambda n, b: b"", "nonempty"),
            (lambda n, b: bytearray(b), "immutable"),
            (lambda n, b: bytes([b[0] ^ 1]) + b[1:], "NAL header"),
            (lambda n, b: b[:1] + b"\x00\x00\x01" + b[4:], "Annex B"),
        )
        for callback, reason in callbacks:
            with self.subTest(reason=reason), self.assertRaisesRegex(TSFormatError, reason):
                transform_pes_nals(data, callback)

    def test_insufficient_capacity_rejected(self):
        data, _ = stream(sizes=(1,))
        with self.assertRaisesRegex(TSFormatError, "Insufficient PES packet capacity"):
            transform_pes_nals(data, lambda n, b: b[:-1])

    def test_pes_crc_dependency_rejected(self):
        builder = Builder()
        es = b"\x00\x00\x01\x65abc\x00\x00\x01\x09\xf0"
        value = bytearray(pes(es))
        value[7] |= 2
        packets = builder.tables() + builder.packets(256, bytes(value))
        with self.assertRaisesRegex(TSFormatError, "PES CRC"):
            transform_pes_nals(b"".join(packets), lambda n, b: b)

    def test_equal_length_api_default_still_rejects_shrinking(self):
        data, _ = stream()
        with self.assertRaisesRegex(TSFormatError, "exact original length"):
            transform_nals(data, lambda n, b: b[:-1])


if __name__ == "__main__":
    unittest.main()
