"""Conservative MPEG-TS / H.264 byte mapper; contains no media decryption.

Only 188-byte TS, single-section current PAT/PMT and MPEG-2 video PES are
supported. The callback receives a complete NAL including its one-byte header,
but excluding its Annex B start code. ``transform_nals`` permits only equal
lengths. ``transform_pes_nals`` also supports shrinking within one PES by moving
the freed bytes into TS adaptation stuffing; neither API implements a codec.

An EOF is not, by itself, proof of an Annex B NAL boundary. The final NAL is
therefore marked incomplete unless the caller explicitly supplies that proof
with ``final_nal_complete=True``. To handle arbitrary HLS chunks safely, retain
the unfinished PES / NAL and its original TS packets across chunk boundaries.
This module intentionally does not pretend that each HLS chunk is independent.
"""

from __future__ import annotations

import bisect
import re
from dataclasses import dataclass
from typing import Callable, Iterable


class TSFormatError(ValueError):
    """Malformed, incomplete or unsupported transport-stream structure."""


@dataclass(frozen=True)
class ByteSpan:
    """One contiguous mapping from elementary bytes to original TS bytes."""

    es_offset: int
    ts_offset: int
    length: int


@dataclass(frozen=True)
class NALUnit:
    nal_type: int
    start_code_offset: int
    prefix_length: int
    payload_offset: int
    end_offset: int
    complete: bool
    spans: tuple[ByteSpan, ...]

    @property
    def length(self) -> int:
        return self.end_offset - self.payload_offset


@dataclass(frozen=True)
class TSAnalysis:
    program_number: int
    pmt_pid: int
    pcr_pid: int
    video_pid: int
    elementary: bytes
    spans: tuple[ByteSpan, ...]
    nals: tuple[NALUnit, ...]
    pes_count: int
    unbounded_final_pes: bool

    @property
    def slice_nals(self) -> tuple[NALUnit, ...]:
        return tuple(nal for nal in self.nals if nal.nal_type in (1, 5))

    def nal_bytes(self, nal: NALUnit) -> bytes:
        return self.elementary[nal.payload_offset : nal.end_offset]


@dataclass(frozen=True)
class _Packet:
    pid: int
    pusi: bool
    payload_offset: int
    payload: bytes
    discontinuity: bool
    scrambling: int
    duplicate: bool


def mpeg_crc32(data: bytes) -> int:
    """MPEG-2 PSI CRC-32 (not the reflected zlib CRC variant)."""
    crc = 0xFFFFFFFF
    for value in data:
        crc ^= value << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
    return crc


def _packets(data: bytes) -> list[_Packet]:
    if not data or len(data) % 188:
        raise TSFormatError("Expected a nonempty whole number of 188-byte TS packets")
    packets = []
    continuity: dict[int, tuple[int, bytes]] = {}
    for offset in range(0, len(data), 188):
        raw = data[offset : offset + 188]
        if raw[0] != 0x47:
            raise TSFormatError(f"TS sync byte missing at offset {offset}")
        if raw[1] & 0x80:
            raise TSFormatError(f"Transport error indicator at offset {offset}")
        pid = ((raw[1] & 0x1F) << 8) | raw[2]
        pusi = bool(raw[1] & 0x40)
        scrambling = raw[3] >> 6
        afc = (raw[3] >> 4) & 3
        cc = raw[3] & 15
        if not afc or scrambling == 1:
            raise TSFormatError(f"Reserved TS header value at offset {offset}")
        cursor = 4
        discontinuity = False
        if afc & 2:
            adaptation_length = raw[cursor]
            cursor += 1
            end = cursor + adaptation_length
            if end > 188 or (afc == 2 and end != 188) or (afc == 3 and end >= 188):
                raise TSFormatError(f"Invalid adaptation length at offset {offset}")
            if adaptation_length:
                flags = raw[cursor]
                discontinuity = bool(flags & 0x80)
                scan = cursor + 1
                for flag, length in ((0x10, 6), (0x08, 6), (0x04, 1)):
                    if flags & flag:
                        scan += length
                for flag in (0x02, 0x01):
                    if flags & flag:
                        if scan >= end:
                            raise TSFormatError(f"Truncated adaptation data at offset {offset}")
                        scan += 1 + raw[scan]
                if scan > end:
                    raise TSFormatError(f"Truncated adaptation data at offset {offset}")
            cursor = end
        payload = raw[cursor:] if afc & 1 else b""
        duplicate = False
        if pid != 0x1FFF:
            previous = continuity.get(pid)
            if previous is not None and not discontinuity:
                expected = (previous[0] + bool(payload)) % 16
                if cc != expected:
                    if payload and cc == previous[0] and raw == previous[1]:
                        duplicate = True
                    else:
                        raise TSFormatError(f"TS continuity gap on PID {pid} at offset {offset}")
            continuity[pid] = (cc, raw)
        packets.append(_Packet(pid, pusi, offset + cursor, payload, discontinuity, scrambling, duplicate))
    return packets


class _SectionAssembler:
    def __init__(self) -> None:
        self.pending = bytearray()
        self.sections: list[bytes] = []

    def _consume(self, value: bytes) -> None:
        self.pending.extend(value)
        while self.pending:
            if self.pending[0] == 0xFF:
                if any(byte != 0xFF for byte in self.pending):
                    raise TSFormatError("Non-stuffing bytes after PSI stuffing")
                self.pending.clear()
                return
            if len(self.pending) < 3:
                return
            length = ((self.pending[1] & 15) << 8) | self.pending[2]
            if not 4 <= length <= 1021:
                raise TSFormatError("Unsupported PSI section length")
            total = length + 3
            if len(self.pending) < total:
                return
            section = bytes(self.pending[:total])
            del self.pending[:total]
            if mpeg_crc32(section):
                raise TSFormatError("PSI CRC mismatch")
            self.sections.append(section)

    def feed(self, packet: _Packet) -> None:
        if not packet.payload or packet.duplicate:
            return
        if packet.scrambling:
            raise TSFormatError("Scrambled PSI is unsupported")
        if packet.discontinuity and self.pending:
            raise TSFormatError("PSI discontinuity inside a section")
        if not packet.pusi:
            if not self.pending:
                raise TSFormatError("PSI begins with an unknown partial section")
            self._consume(packet.payload)
            return
        pointer = packet.payload[0]
        if pointer > len(packet.payload) - 1:
            raise TSFormatError("PSI pointer exceeds packet payload")
        if self.pending:
            self._consume(packet.payload[1 : 1 + pointer])
            if self.pending:
                raise TSFormatError("New PSI section before previous section completed")
        # A pointer may skip the end of a section that preceded the input buffer.
        self._consume(packet.payload[1 + pointer :])

    def finish(self) -> list[bytes]:
        if self.pending:
            raise TSFormatError("PSI section is incomplete at EOF")
        return self.sections


def _sections(packets: list[_Packet], pid: int, table_id: int) -> list[bytes]:
    assembler = _SectionAssembler()
    for packet in packets:
        if packet.pid == pid:
            assembler.feed(packet)
    result = []
    for section in assembler.finish():
        if section[0] != table_id:
            raise TSFormatError("Unexpected table on selected PSI PID")
        if len(section) < 12 or section[1] & 0xF0 != 0xB0:
            raise TSFormatError("Unsupported PSI syntax")
        if not section[5] & 1:
            continue
        if section[6] or section[7]:
            raise TSFormatError("Multi-section PAT/PMT is unsupported")
        result.append(section)
    if not result:
        raise TSFormatError(f"Current PSI table {table_id} missing on PID {pid}")
    if any(section != result[0] for section in result[1:]):
        raise TSFormatError("PAT/PMT changes within the input buffer are unsupported")
    return result


def _program(
    packets: list[_Packet], program_number: int | None, video_pid: int | None
) -> tuple[int, int, int, int]:
    pat = _sections(packets, 0, 0)[0]
    if (len(pat) - 12) % 4:
        raise TSFormatError("Malformed PAT program entries")
    programs = {}
    for offset in range(8, len(pat) - 4, 4):
        number = int.from_bytes(pat[offset : offset + 2], "big")
        if number:
            if number in programs:
                raise TSFormatError("Duplicate PAT program number")
            programs[number] = ((pat[offset + 2] & 31) << 8) | pat[offset + 3]
    if program_number is None:
        if len(programs) != 1:
            raise TSFormatError("Select program_number explicitly for a multi-program TS")
        program_number = next(iter(programs))
    if program_number not in programs:
        raise TSFormatError("Requested program_number is absent from PAT")
    pmt_pid = programs[program_number]
    if pmt_pid in (0, 0x1FFF):
        raise TSFormatError("Invalid PMT PID")
    pmt = _sections(packets, pmt_pid, 2)[0]
    if len(pmt) < 16 or int.from_bytes(pmt[3:5], "big") != program_number:
        raise TSFormatError("PMT program_number mismatch")
    pcr_pid = ((pmt[8] & 31) << 8) | pmt[9]
    cursor = 12 + (((pmt[10] & 15) << 8) | pmt[11])
    if cursor > len(pmt) - 4:
        raise TSFormatError("Truncated PMT program descriptors")
    candidates = []
    while cursor < len(pmt) - 4:
        if cursor + 5 > len(pmt) - 4:
            raise TSFormatError("Truncated PMT elementary entry")
        stream_type = pmt[cursor]
        pid = ((pmt[cursor + 1] & 31) << 8) | pmt[cursor + 2]
        cursor += 5 + (((pmt[cursor + 3] & 15) << 8) | pmt[cursor + 4])
        if cursor > len(pmt) - 4:
            raise TSFormatError("Truncated PMT elementary descriptors")
        if stream_type == 0x1B:
            candidates.append(pid)
    if video_pid is None:
        if len(candidates) != 1:
            raise TSFormatError("Expected one H.264 stream; select video_pid explicitly")
        video_pid = candidates[0]
    if video_pid not in candidates or video_pid in (0, pmt_pid, 0x1FFF):
        raise TSFormatError("Selected video_pid is not an H.264 stream in the PMT")
    return program_number, pmt_pid, pcr_pid, video_pid


def _mapped_slice(spans: list[ByteSpan] | tuple[ByteSpan, ...], begin: int, end: int) -> tuple[ByteSpan, ...]:
    if begin >= end:
        return ()
    # Search the existing sorted spans directly; avoid rebuilding all offsets
    # and slicing the remaining span table for every NAL. Python 3.10+ key API.
    index = max(0, bisect.bisect_right(spans, begin, key=lambda span: span.es_offset) - 1)
    result = []
    for position in range(index, len(spans)):
        span = spans[position]
        if span.es_offset >= end:
            break
        start = max(begin, span.es_offset)
        stop = min(end, span.es_offset + span.length)
        if start < stop:
            result.append(ByteSpan(start, span.ts_offset + start - span.es_offset, stop - start))
    if sum(span.length for span in result) != end - begin:
        raise TSFormatError("Internal elementary-to-TS mapping has a gap")
    return tuple(result)


def _elementary(packets: list[_Packet], video_pid: int) -> tuple[bytes, tuple[ByteSpan, ...], int, bool]:
    elementary = bytearray()
    spans: list[ByteSpan] = []
    pending = bytearray()
    pending_spans: list[ByteSpan] = []
    active = False
    pes_count = 0
    last_unbounded = False
    seen_video = False

    def flush(*, eof: bool = False) -> None:
        nonlocal active, pes_count, last_unbounded
        if len(pending) < 9:
            raise TSFormatError("Incomplete MPEG-2 PES header")
        if pending[:3] != b"\x00\x00\x01" or not 0xE0 <= pending[3] <= 0xEF:
            raise TSFormatError("Expected a video PES start code")
        if pending[6] & 0xC0 != 0x80 or pending[6] & 0x30:
            raise TSFormatError("Unsupported or scrambled PES header")
        if pending[7] & 0xC0 == 0x40:
            raise TSFormatError("Reserved PES PTS/DTS flag")
        header_length = 9 + pending[8]
        if header_length > len(pending):
            raise TSFormatError("Incomplete optional PES header")
        pts_dts = pending[7] >> 6
        required = 10 if pts_dts == 3 else (5 if pts_dts == 2 else 0)
        if pending[8] < required:
            raise TSFormatError("PES header is too short for PTS/DTS")
        packet_length = int.from_bytes(pending[4:6], "big")
        if packet_length and len(pending) != packet_length + 6:
            raise TSFormatError("Bounded PES packet is truncated or has unexplained trailing bytes")
        base = len(elementary)
        elementary.extend(pending[header_length:])
        for span in _mapped_slice(pending_spans, header_length, len(pending)):
            spans.append(ByteSpan(base + span.es_offset - header_length, span.ts_offset, span.length))
        pending.clear()
        pending_spans.clear()
        active = False
        pes_count += 1
        last_unbounded = eof and packet_length == 0

    for packet in packets:
        if packet.pid != video_pid:
            continue
        if packet.discontinuity and seen_video:
            raise TSFormatError("Video discontinuity inside the input stream; split at the discontinuity")
        if not packet.payload:
            continue
        if packet.duplicate:
            raise TSFormatError("Duplicate video TS packet needs a one-to-many byte mapper; unsupported")
        seen_video = True
        if packet.scrambling:
            raise TSFormatError("TS-level scrambled video is unsupported")
        if packet.pusi:
            if active:
                flush()
            active = True
        elif not active:
            raise TSFormatError("Video begins with PES continuation; retain the previous HLS chunk")
        pending_spans.append(ByteSpan(len(pending), packet.payload_offset, len(packet.payload)))
        pending.extend(packet.payload)
        if len(pending) >= 6:
            packet_length = int.from_bytes(pending[4:6], "big")
            if packet_length and len(pending) >= packet_length + 6:
                flush()
    if active:
        flush(eof=True)
    if not elementary:
        raise TSFormatError("No video elementary bytes found")
    return bytes(elementary), tuple(spans), pes_count, last_unbounded


def inspect_ts(
    data: bytes,
    *,
    program_number: int | None = None,
    video_pid: int | None = None,
    final_nal_complete: bool = False,
) -> TSAnalysis:
    """Locate H.264 NALs and their original bytes without changing the stream.

    ``final_nal_complete`` is an explicit caller assertion about the final NAL,
    not a conclusion inferred from a TS or HLS file ending.
    """
    packets = _packets(data)
    program, pmt, pcr, video = _program(packets, program_number, video_pid)
    elementary, spans, pes_count, last_unbounded = _elementary(packets, video)
    # Match the official player's capped three-zero state machine. Extra zero
    # bytes before a four-byte prefix belong to the preceding protected NAL;
    # trimming the entire run can remove bytes the runtime still needs.
    markers = list(re.finditer(b"\x00{2,3}\x01", elementary))
    if not markers or any(elementary[: markers[0].start()]):
        raise TSFormatError("Video does not begin with supported Annex B start codes")
    nals = []
    for index, marker in enumerate(markers):
        begin = marker.end()
        end = markers[index + 1].start() if index + 1 < len(markers) else len(elementary)
        if begin >= end:
            raise TSFormatError("Empty Annex B NAL")
        header = elementary[begin]
        nal_type = header & 31
        if header & 0x80 or not 1 <= nal_type <= 23:
            raise TSFormatError("Unsupported H.264 NAL header")
        nals.append(
            NALUnit(nal_type, marker.start(), marker.end() - marker.start(), begin, end,
                    index + 1 < len(markers) or final_nal_complete,
                    _mapped_slice(spans, begin, end))
        )
    return TSAnalysis(program, pmt, pcr, video, elementary, spans, tuple(nals), pes_count, last_unbounded)


def boundary_proven_by(
    next_data: bytes,
    *,
    program_number: int | None = None,
    video_pid: int | None = None,
) -> bool:
    """Whether an independently valid next segment starts a new Annex B NAL.

    The caller MUST first establish consecutive HLS media sequence numbers and
    absence of EXT-X-DISCONTINUITY. This function cannot establish chronological
    adjacency from bytes alone. Supplying the preceding segment's program and
    video PID also requires an unchanged stream selection.

    A failed or partial next-segment parse is a negative result, never implicit
    permission to process the preceding segment's unfinished final NAL.
    """
    try:
        analysis = inspect_ts(next_data, program_number=program_number, video_pid=video_pid)
    except TSFormatError:
        return False
    return bool(analysis.nals and analysis.nals[0].start_code_offset == 0)


def transform_nals(
    data: bytes,
    callback: Callable[[NALUnit, bytes], bytes],
    *,
    program_number: int | None = None,
    video_pid: int | None = None,
    final_nal_complete: bool = False,
    nal_types: Iterable[int] = (1, 5),
) -> tuple[bytes, TSAnalysis]:
    """Apply an equal-length callback to selected complete NALs, atomically.

    No callback runs unless all selected NALs have proven boundaries. All
    replacements are collected and length checked before any output is made.
    Audio, TS headers, adaptation/PCR, PES headers/PTS and Annex B prefixes are
    preserved byte-for-byte. The callback is forbidden to change the NAL header
    or introduce an Annex B start code inside the NAL payload.

    The default selection is slice types 1/5. Supply ``nal_types=(1, 5, 7)``
    when an external processor must also receive SPS; this mapper implements no
    codec-specific state or processing algorithm itself.
    """
    if not isinstance(data, bytes):
        raise TypeError("data must be immutable bytes")
    selected_types = frozenset(nal_types)
    if not selected_types or any(type(value) is not int or not 1 <= value <= 23 for value in selected_types):
        raise ValueError("nal_types must contain supported NAL type integers from 1 to 23")
    analysis = inspect_ts(data, program_number=program_number, video_pid=video_pid,
                          final_nal_complete=final_nal_complete)
    selected = tuple(nal for nal in analysis.nals if nal.nal_type in selected_types)
    if any(not nal.complete for nal in selected):
        raise TSFormatError("Final selected NAL has no proven boundary; retain it across HLS chunks")
    replacements = []
    for nal in selected:
        original = analysis.nal_bytes(nal)
        replacement = callback(nal, original)
        if not isinstance(replacement, bytes) or len(replacement) != len(original):
            raise TSFormatError("NAL callback must return immutable bytes of the exact original length")
        if replacement[0] != original[0]:
            raise TSFormatError("NAL callback may not change the NAL header")
        if re.search(b"\x00\x00\x01", replacement):
            raise TSFormatError("NAL callback introduced an unescaped Annex B start code")
        replacements.append((nal, replacement))
    result = bytearray(data)
    for nal, replacement in replacements:
        cursor = 0
        for span in nal.spans:
            result[span.ts_offset : span.ts_offset + span.length] = replacement[cursor : cursor + span.length]
            cursor += span.length
    return bytes(result), analysis


@dataclass(frozen=True)
class _PESGroup:
    es_offset: int
    es_end: int
    header_length: int
    data: bytes
    packets: tuple[_Packet, ...]


def _pes_groups(packets: list[_Packet], video_pid: int) -> list[_PESGroup]:
    """Group already-validated video payload packets by their original PES."""
    result = []
    pending: list[_Packet] = []
    value = bytearray()
    es_offset = 0

    def flush() -> None:
        nonlocal es_offset
        header_length = 9 + value[8]
        es_end = es_offset + len(value) - header_length
        result.append(_PESGroup(es_offset, es_end, header_length, bytes(value), tuple(pending)))
        es_offset = es_end
        pending.clear()
        value.clear()

    for packet in packets:
        if packet.pid != video_pid or not packet.payload:
            continue
        if packet.pusi and pending:
            flush()
        pending.append(packet)
        value.extend(packet.payload)
        if len(value) >= 6:
            length = int.from_bytes(value[4:6], "big")
            if length and len(value) == length + 6:
                flush()
    if pending:
        flush()
    return result


def _packet_with_smaller_payload(data: bytes, packet: _Packet, payload: bytes) -> tuple[int, bytes]:
    """Keep one original video packet slot, placing freed bytes in adaptation."""
    offset = packet.payload_offset + len(packet.payload) - 188
    raw = data[offset : offset + 188]
    if not 1 <= len(payload) <= len(packet.payload):
        raise TSFormatError("PES repacketization must keep every original video packet nonempty")
    if len(payload) == len(packet.payload):
        return offset, raw[: 188 - len(payload)] + payload
    header = bytearray(raw[:4])
    header[3] = (header[3] & 0xCF) | 0x30
    new_length = 183 - len(payload)
    if raw[3] & 0x20:
        original_length = raw[4]
        original = raw[5 : 5 + original_length]
        if original_length:
            adaptation = original + b"\xff" * (new_length - original_length)
        else:
            adaptation = b"\x00" + b"\xff" * (new_length - 1)
    else:
        adaptation = b"\x00" + b"\xff" * (new_length - 1) if new_length else b""
    output = bytes(header) + bytes([new_length]) + adaptation + payload
    if len(output) != 188:
        raise TSFormatError("Internal PES repacketization packet-size mismatch")
    return offset, output


def transform_pes_nals(
    data: bytes,
    callback: Callable[[NALUnit, bytes], bytes],
    *,
    program_number: int | None = None,
    video_pid: int | None = None,
    final_nal_complete: bool = False,
    nal_types: Iterable[int] = (1, 5),
) -> tuple[bytes, TSAnalysis]:
    """Apply non-growing NAL replacements while preserving original TS slots.

    Every selected NAL must be complete and wholly inside a single video PES.
    Replacements are collected in original NAL order before output is changed;
    callers may precompute them in one external batch and use this callback as
    an indexed lookup. An empty or growing replacement, cross-PES selected NAL,
    PES CRC dependency or insufficient packet capacity fails explicitly.

    Original PES headers (including PTS/DTS) are copied; a nonzero
    PES_packet_length is reduced by the exact byte count. A zero length stays
    zero. Freed bytes become 0xff adaptation stuffing, starting at the last
    payload packet. Each original packet retains at least one payload byte so
    all continuity counters, PUSI bits, PCR positions, packet order and byte
    count stay unchanged. No bytes are appended to any NAL or elementary data.
    Audio, PSI, null and adaptation-only packets remain byte-for-byte identical.

    The returned analysis describes the ORIGINAL stream and callback offsets.
    The final output is parsed again and checked against the exact rebuilt ES.
    """
    if not isinstance(data, bytes):
        raise TypeError("data must be immutable bytes")
    selected_types = frozenset(nal_types)
    if not selected_types or any(type(value) is not int or not 1 <= value <= 23 for value in selected_types):
        raise ValueError("nal_types must contain supported NAL type integers from 1 to 23")
    analysis = inspect_ts(data, program_number=program_number, video_pid=video_pid,
                          final_nal_complete=final_nal_complete)
    selected = tuple(nal for nal in analysis.nals if nal.nal_type in selected_types)
    if any(not nal.complete for nal in selected):
        raise TSFormatError("Final selected NAL has no proven boundary; retain it across HLS chunks")
    groups = _pes_groups(_packets(data), analysis.video_pid)
    group_starts = [group.es_offset for group in groups]
    memberships = []
    for nal in selected:
        index = bisect.bisect_right(group_starts, nal.payload_offset) - 1
        if index < 0 or nal.end_offset > groups[index].es_end:
            raise TSFormatError("Selected NAL crosses PES boundaries; variable PES repacketization is unsupported")
        memberships.append(index)
    if selected and any(group.data[7] & 0x02 for group in groups):
        raise TSFormatError("PES CRC dependencies are unsupported for transformed media")
    replacements: dict[int, list[tuple[NALUnit, bytes]]] = {}
    for nal, index in zip(selected, memberships):
        original = analysis.nal_bytes(nal)
        replacement = callback(nal, original)
        if not isinstance(replacement, bytes) or not replacement:
            raise TSFormatError("NAL callback must return nonempty immutable bytes")
        if len(replacement) > len(original):
            raise TSFormatError("NAL growth is unsupported by fixed-slot PES repacketization")
        if replacement[0] != original[0]:
            raise TSFormatError("NAL callback may not change the NAL header")
        if re.search(b"\x00\x00\x01", replacement):
            raise TSFormatError("NAL callback introduced an unescaped Annex B start code")
        replacements.setdefault(index, []).append((nal, replacement))
    # Validate and prepare all replacements before constructing any output.
    prepared = []
    expected_es = []
    for index, group in enumerate(groups):
        if index not in replacements:
            expected_es.append(group.data[group.header_length:])
            continue
        cursor = group.es_offset
        parts = []
        for nal, replacement in replacements[index]:
            parts.extend((analysis.elementary[cursor : nal.payload_offset], replacement))
            cursor = nal.end_offset
        parts.append(analysis.elementary[cursor : group.es_end])
        elementary = b"".join(parts)
        header = bytearray(group.data[:group.header_length])
        original_length = int.from_bytes(header[4:6], "big")
        if original_length:
            header[4:6] = (len(header) + len(elementary) - 6).to_bytes(2, "big")
        pes = bytes(header) + elementary
        sizes = [len(packet.payload) for packet in group.packets]
        freed = len(group.data) - len(pes)
        for packet_index in range(len(sizes) - 1, -1, -1):
            amount = min(freed, sizes[packet_index] - 1)
            sizes[packet_index] -= amount
            freed -= amount
        if freed:
            raise TSFormatError("Insufficient PES packet capacity to keep all original video packets nonempty")
        if sum(sizes) != len(pes):
            raise TSFormatError("Internal PES repacketization byte-count mismatch")
        prepared.append((group, pes, sizes))
        expected_es.append(elementary)
    result = bytearray(data)
    for group, pes, sizes in prepared:
        cursor = 0
        for packet, size in zip(group.packets, sizes):
            offset, rewritten = _packet_with_smaller_payload(data, packet, pes[cursor : cursor + size])
            result[offset : offset + 188] = rewritten
            cursor += size
    output = bytes(result)
    verified = inspect_ts(output, program_number=analysis.program_number, video_pid=analysis.video_pid,
                          final_nal_complete=final_nal_complete)
    if verified.elementary != b"".join(expected_es) or len(output) != len(data):
        raise TSFormatError("Repacketized output differs from the exact requested elementary stream")
    return output, analysis
