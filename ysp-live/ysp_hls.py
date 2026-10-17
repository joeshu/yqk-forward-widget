"""Small, dependency-free HLS transformations with explicit encryption semantics."""
from __future__ import annotations
import dataclasses
import datetime
import hashlib
import math
import re
import urllib.parse

_URI = re.compile(r'(?P<name>\b(?:URI|SERVER-URI))=(?:"(?P<quoted>[^"]*)"|(?P<plain>[^\s,]+))')
_ATTR = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')
_VOLATILE = {'sig', 'signature', 'sign', 'token', 'auth', 'auth_key', 'expires', 'expire', 'wssecret', 'wstime', 'txsecret', 'txtime', 'upt', 'vkey'}
_GLOBAL = ('#EXTM3U', '#EXT-X-VERSION:', '#EXT-X-TARGETDURATION:', '#EXT-X-MEDIA-SEQUENCE:', '#EXT-X-DISCONTINUITY-SEQUENCE:', '#EXT-X-PLAYLIST-TYPE:', '#EXT-X-INDEPENDENT-SEGMENTS', '#EXT-X-START:', '#EXT-X-SERVER-CONTROL:', '#EXT-X-DEFINE:')

class UnsafePlaylist(ValueError):
    pass

def attributes(line):
    return {k: v.strip('"') for k, v in _ATTR.findall(line.partition(':')[2])}

def rewrite_uris(text, base_url, mapper=None):
    """Resolve every URI against its effective response URL, including tag attributes."""
    def absolute(value):
        resolved = urllib.parse.urljoin(base_url, value)
        return mapper(resolved) if mapper and urllib.parse.urlsplit(resolved).scheme in ('http', 'https') else resolved
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith('#'):
            line = _URI.sub(lambda m: m.group('name') + '="' + absolute(m.group('quoted') if m.group('quoted') is not None else m.group('plain')) + '"', line)
        elif s:
            line = absolute(s)
        out.append(line)
    return '\n'.join(out) + ('\n' if text.endswith(('\n', '\r')) else '')

def select_variant(text, quality='fhd'):
    """Choose a muxed rendition; keep masters with separate audio/video groups intact."""
    lines = text.splitlines()
    variants = []
    for i, line in enumerate(lines):
        if line.strip().startswith('#EXT-X-STREAM-INF:'):
            attrs = attributes(line.strip())
            if attrs.get('AUDIO') or attrs.get('VIDEO') or attrs.get('SUBTITLES'):
                return None
            for uri in lines[i + 1:]:
                if uri.strip() and not uri.lstrip().startswith('#'):
                    resolution = attrs.get('RESOLUTION', '0x0').lower().split('x')
                    try:
                        height = int(resolution[-1])
                        bandwidth = int(attrs.get('AVERAGE-BANDWIDTH', attrs.get('BANDWIDTH', 0)))
                    except ValueError:
                        height, bandwidth = 0, 0
                    variants.append((height, bandwidth, uri.strip()))
                    break
    if not variants:
        return None
    quality = (quality or 'fhd').lower()
    cap = {'sd': 576, 'hd': 720, 'shd': 720, 'fhd': 1080, 'uhd': 2160, '4k': 2160, '8k': 4320, 'stable': 720}.get(quality)
    if quality == 'auto':
        return None
    if cap:
        within = [v for v in variants if v[0] and v[0] <= cap]
        if within:
            return max(within) [2]
        measured = [v for v in variants if v[0]]
        if measured:
            return min(measured)[2]
    # Missing resolution: use bandwidth only as a bounded approximation.
    budget = {'shd': 3_000_000, 'hd': 3_000_000, 'stable': 3_000_000, 'sd': 1_500_000}.get(quality, 8_000_000)
    within = [v for v in variants if v[1] <= budget]
    return (max(within) if within else min(variants))[2]

def pdt_seconds(value):
    if not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value[:-1] + '+00:00' if value.upper().endswith('Z') else value)
        if dt.tzinfo is None:
            return None  # HLS PDT requires an explicit zone.
        return dt.timestamp()
    except (TypeError, ValueError, OverflowError):
        return None

def stable_uri(uri):
    p = urllib.parse.urlsplit(uri)
    # Preserve query parameters that may identify the media itself.
    query = urllib.parse.urlencode([(k, v) for k, v in urllib.parse.parse_qsl(p.query, keep_blank_values=True) if k.lower() not in _VOLATILE])
    return urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, query, ''))

@dataclasses.dataclass
class Segment:
    source_sequence: int
    duration: float
    pdt: str
    uri: str
    tags: list[str]
    key: str | None
    init_map: str | None
    byte_range: str | None
    discontinuity: int = 0

    @property
    def identity(self):
        stamp = pdt_seconds(self.pdt)
        if stamp is not None:
            return ('pdt', round(stamp, 6), self.byte_range)
        return ('uri', stable_uri(self.uri), self.byte_range)

@dataclasses.dataclass
class MediaPlaylist:
    headers: list[str]
    segments: list[Segment]
    trailing: list[str]
    sequence: int = 0
    discontinuity_sequence: int = 0
    target: float = 6.0
    unsafe: bool = False
    original_text: str = ''


def parse_media(text):
    if '#EXT-X-STREAM-INF:' in text or '#EXT-X-I-FRAME-STREAM-INF:' in text:
        return None
    headers, pending, segments, trailing = [], [], [], []
    sequence, discontinuity_sequence, duration, target = 0, 0, 6.0, 6.0
    key = init_map = byte_range = None
    pdt = ''
    inherited_pdt = None
    range_end, range_uri = None, None
    unsafe = False
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith(('#EXT-X-PART:', '#EXT-X-PRELOAD-HINT:', '#EXT-X-SKIP:', '#EXT-X-RENDITION-REPORT:')):
            unsafe = True
        if s.startswith('#EXT-X-MEDIA-SEQUENCE:'):
            sequence = int(s.partition(':')[2])
            if sequence < 0 or sequence >= 2 ** 128:
                raise UnsafePlaylist('invalid media sequence')
            headers.append(s)
        elif s.startswith('#EXT-X-DISCONTINUITY-SEQUENCE:'):
            discontinuity_sequence = int(s.partition(':')[2])
            headers.append(s)
        elif s.startswith('#EXT-X-TARGETDURATION:'):
            target = float(s.partition(':')[2])
            if not math.isfinite(target) or target <= 0:
                raise UnsafePlaylist('invalid target duration')
            headers.append(s)
        elif s.startswith('#EXTINF:'):
            duration = float(s.partition(':')[2].split(',')[0])
            if not math.isfinite(duration) or duration <= 0:
                raise UnsafePlaylist('invalid segment duration')
            pending.append(s)
        elif s.startswith('#EXT-X-PROGRAM-DATE-TIME:'):
            pdt = s.partition(':')[2]
            inherited_pdt = pdt_seconds(pdt)
            pending.append(s)
        elif s.startswith('#EXT-X-KEY:'):
            key = s
            pending.append(s)
        elif s.startswith('#EXT-X-MAP:'):
            init_map = s
            pending.append(s)
        elif s.startswith('#EXT-X-BYTERANGE:'):
            byte_range = s.partition(':')[2]
            pending.append(s)
        elif s.startswith('#EXT-X-ENDLIST'):
            trailing.append(s)
        elif any(s.startswith(prefix) for prefix in _GLOBAL):
            headers.append(s)
        elif s.startswith('#'):
            pending.append(s)
        else:
            if not any(t.startswith('#EXTINF:') for t in pending):
                unsafe = True
            actual_range = byte_range
            if byte_range:
                match = re.fullmatch(r'(\d+)(?:@(\d+))?', byte_range)
                if not match:
                    unsafe = True
                else:
                    length = int(match.group(1))
                    offset = int(match.group(2)) if match.group(2) is not None else range_end
                    if offset is None or (match.group(2) is None and range_uri != s):
                        unsafe = True
                    else:
                        actual_range = f'{length}@{offset}'
                        range_end, range_uri = offset + length, s
            else:
                range_end, range_uri = None, None
            if not pdt and inherited_pdt is not None:
                pdt = datetime.datetime.fromtimestamp(inherited_pdt, datetime.timezone.utc).isoformat()
            segments.append(Segment(sequence + len(segments), duration, pdt, s, pending, key, init_map, actual_range, pending.count('#EXT-X-DISCONTINUITY')))
            if inherited_pdt is not None:
                inherited_pdt += duration
            pending, pdt, byte_range = [], '', None
    trailing = pending + trailing
    return MediaPlaylist(headers, segments, trailing, sequence, discontinuity_sequence, target, unsafe, text)


def render_media(media, segments=None, sequences=None, *, live=False, boundary=None, discontinuity_base=None):
    """Render complete segment state; make AES-128 implicit IV explicit before renumbering."""
    if media.unsafe:
        raise UnsafePlaylist('playlist requires passthrough (LL-HLS or incomplete segment metadata)')
    segments = list(media.segments if segments is None else segments)
    if not segments:
        raise UnsafePlaylist('empty media playlist')
    sequences = list(range(segments[0].source_sequence, segments[0].source_sequence + len(segments))) if sequences is None else list(sequences)
    if len(sequences) != len(segments) or any(b != a + 1 for a, b in zip(sequences, sequences[1:])):
        raise UnsafePlaylist('non-contiguous output sequence')
    out = []
    for line in media.headers:
        if line.startswith(('#EXT-X-MEDIA-SEQUENCE:', '#EXT-X-DISCONTINUITY-SEQUENCE:')):
            continue
        if live and line.startswith(('#EXT-X-PLAYLIST-TYPE:', '#EXT-X-START:')):
            continue
        if line.startswith('#EXT-X-TARGETDURATION:'):
            line = '#EXT-X-TARGETDURATION:' + str(math.ceil(max(media.target, max(s.duration for s in segments))))
        out.append(line)
    if '#EXTM3U' not in out:
        out.insert(0, '#EXTM3U')
    if not any(s.startswith('#EXT-X-TARGETDURATION:') for s in out):
        out.append('#EXT-X-TARGETDURATION:' + str(math.ceil(max(s.duration for s in segments))))
    out.append('#EXT-X-MEDIA-SEQUENCE:' + str(sequences[0]))
    disc_base = media.discontinuity_sequence if discontinuity_base is None else discontinuity_base
    first_index = next((i for i, s in enumerate(media.segments) if s.identity == segments[0].identity), 0)
    omitted = sum(s.discontinuity for s in media.segments[:first_index])
    out.append('#EXT-X-DISCONTINUITY-SEQUENCE:' + str(disc_base + omitted))
    previous_key = previous_map = None
    for segment, output_seq in zip(segments, sequences):
        key = segment.key
        if key:
            attr = attributes(key)
            method = attr.get('METHOD')
            if method not in ('NONE', 'AES-128') and output_seq != segment.source_sequence:
                raise UnsafePlaylist('cannot renumber this encryption method')
            if method == 'AES-128' and 'IV' not in attr:
                if attr.get('KEYFORMAT', 'identity') != 'identity' or segment.init_map:
                    raise UnsafePlaylist('cannot infer initialization-map encryption IV')
                key += ',IV=0x' + format(segment.source_sequence, '032x')
        if boundary is not None and output_seq == boundary and '#EXT-X-DISCONTINUITY' not in segment.tags:
            out.append('#EXT-X-DISCONTINUITY')
        if key != previous_key:
            if key:
                out.append(key)
            elif previous_key:
                out.append('#EXT-X-KEY:METHOD=NONE')
            previous_key = key
        if segment.init_map != previous_map:
            if segment.init_map:
                out.append(segment.init_map)
            previous_map = segment.init_map
        if segment.pdt and not any(tag.startswith('#EXT-X-PROGRAM-DATE-TIME:') for tag in segment.tags):
            out.append('#EXT-X-PROGRAM-DATE-TIME:' + segment.pdt)
        for tag in segment.tags:
            if tag.startswith(('#EXT-X-KEY:', '#EXT-X-MAP:', '#EXT-X-BYTERANGE:')):
                continue
            out.append(tag)
        if segment.byte_range:
            # Explicit offsets make a trimmed first segment independently interpretable.
            out.append('#EXT-X-BYTERANGE:' + segment.byte_range)
        out.append(segment.uri)
    out.extend(t for t in media.trailing if not live or t != '#EXT-X-ENDLIST')
    return '\n'.join(out) + '\n'


def media_signature(text):
    media = parse_media(text)
    if media is None or not media.segments:
        return None, 6.0
    # A changed token alone is not a new frame. Include sequence and complete stable identity.
    last = media.segments[-1]
    payload = repr((last.source_sequence, last.identity)).encode()
    return hashlib.sha256(payload).hexdigest(), media.target
