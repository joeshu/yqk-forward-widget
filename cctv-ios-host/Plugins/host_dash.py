"""Bounded clear ISO-BMFF DASH -> HLS manifests, without transcoding.

Supports a single Period, inherited SegmentTemplate/SegmentTimeline and
SegmentList (including byte ranges). Live streams need an explicit timeline.
Encrypted/DRM, SegmentBase, WebM and multi-period presentations stay on the
original DASH engine; this bridge never invents playable segments or keys.
"""
import math
import re
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET

from host_media_url import http_url

MAX_SEGMENTS = 12000


class DashError(ValueError):
    pass


def children(node, name):
    return [e for e in node if e.tag.rsplit('}', 1)[-1] == name]


def child(node, name):
    return next(iter(children(node, name)), None)


def duration(value):
    m = re.fullmatch(r'P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?', value or '')
    return sum(float(n or 0) * scale for n, scale in zip(m.groups(), (86400, 3600, 60, 1))) if m else 0


def expand(template, representation, number=0, stamp=0):
    values = {'RepresentationID': representation.get('id', ''),
              'Bandwidth': representation.get('bandwidth', ''), 'Number': number, 'Time': stamp}
    def replace(match):
        if match[0] == '$$':
            return '$'
        name, width = match.group(1), match.group(2)
        if name not in values or values[name] == '':
            raise DashError('dash_template_invalid')
        return str(values[name]).zfill(int(width)) if width else str(values[name])
    result = re.sub(r'\$\$|\$(RepresentationID|Bandwidth|Number|Time)(?:%0(\d{1,2})d)?\$', replace, template)
    if re.search(r'\$[A-Za-z]', result):
        raise DashError('dash_template_unsupported')
    return result


def timeline(node, timescale, total, offset=0):
    stamps, current = [], 0
    rows = children(node, 'S')
    for index, row in enumerate(rows):
        if stamps and 't' in row.attrib and int(row.get('t')) != current:
            raise DashError('dash_timeline_discontinuity_unsupported')
        current = int(row.get('t', current))
        length, repeat = int(row.get('d', 0)), int(row.get('r', 0))
        if length <= 0 or repeat < -1 or current < 0:
            raise DashError('dash_timeline_invalid')
        if repeat == -1:
            end = int(rows[index + 1].get('t', 0)) if index + 1 < len(rows) else offset + math.ceil(total * timescale)
            if end <= current:
                raise DashError('dash_live_timeline_unbounded')
            repeat = math.ceil((end - current) / length) - 1
        if len(stamps) + repeat + 1 > MAX_SEGMENTS:
            raise DashError('dash_segments_exceeded')
        for _ in range(repeat + 1):
            stamps.append((current, length / timescale))
            current += length
    return stamps


def parse_sidx_segments(data, index_end):
    """Parse an ISO BMFF sidx box into [(duration_seconds, 'start-end'), ...]."""
    if not isinstance(data, (bytes, bytearray)) or len(data) < 28:
        raise DashError('dash_sidx_invalid')
    buf = bytes(data)
    pos = 0
    sidx_start = -1
    sidx_size = 0
    while pos + 8 <= len(buf):
        box_size = int.from_bytes(buf[pos:pos + 4], 'big')
        box_type = buf[pos + 4:pos + 8]
        if box_size == 1 and pos + 16 <= len(buf):
            box_size = int.from_bytes(buf[pos + 8:pos + 16], 'big')
        if box_size < 8 or pos + box_size > len(buf):
            break
        if box_type == b'sidx':
            sidx_start = pos
            sidx_size = box_size
            break
        pos += box_size
    if sidx_start < 0:
        raise DashError('dash_sidx_invalid')
    p = sidx_start + 8
    end = sidx_start + sidx_size
    if p + 4 > end:
        raise DashError('dash_sidx_invalid')
    version = buf[p]
    p += 4  # version + flags
    if version == 0:
        if p + 16 > end:
            raise DashError('dash_sidx_invalid')
        timescale = int.from_bytes(buf[p + 4:p + 8], 'big')
        first_offset = int.from_bytes(buf[p + 12:p + 16], 'big')
        p += 16
    elif version == 1:
        if p + 24 > end:
            raise DashError('dash_sidx_invalid')
        timescale = int.from_bytes(buf[p + 4:p + 8], 'big')
        first_offset = int.from_bytes(buf[p + 16:p + 24], 'big')
        p += 24
    else:
        raise DashError('dash_sidx_invalid')
    if timescale <= 0 or p + 4 > end:
        raise DashError('dash_sidx_invalid')
    ref_count = int.from_bytes(buf[p + 2:p + 4], 'big')
    p += 4
    if ref_count <= 0 or ref_count > MAX_SEGMENTS or p + ref_count * 12 > end:
        raise DashError('dash_sidx_invalid')
    offset = int(index_end) + 1 + first_offset
    segments = []
    for _ in range(ref_count):
        word0 = int.from_bytes(buf[p:p + 4], 'big')
        subseg_dur = int.from_bytes(buf[p + 4:p + 8], 'big')
        p += 12
        ref_type = (word0 >> 31) & 1
        ref_size = word0 & 0x7FFFFFFF
        if ref_type != 0 or ref_size <= 0 or subseg_dur <= 0:
            raise DashError('dash_sidx_invalid')
        seg_end = offset + ref_size - 1
        segments.append((subseg_dur / float(timescale), f'{offset}-{seg_end}'))
        offset = seg_end + 1
    return segments


def rewrite_hev1_to_hvc1_init(data):
    """Rewrite fMP4 moov/stsd 'hev1' FourCC to Apple-compatible 'hvc1' when hvcC is present."""
    if not isinstance(data, (bytes, bytearray)) or b'hev1' not in data or b'hvcC' not in data:
        return data
    buf = bytearray(data)
    container_types = {b'moov', b'trak', b'mdia', b'minf', b'stbl'}

    def walk(start, end):
        cursor = start
        while cursor + 8 <= end:
            size = int.from_bytes(buf[cursor:cursor + 4], 'big')
            btype = bytes(buf[cursor + 4:cursor + 8])
            header = 8
            if size == 1 and cursor + 16 <= end:
                size = int.from_bytes(buf[cursor + 8:cursor + 16], 'big')
                header = 16
            elif size == 0:
                size = end - cursor
            if size < header or cursor + size > end:
                break
            body_start = cursor + header
            body_end = cursor + size
            if btype in container_types:
                walk(body_start, body_end)
            elif btype == b'stsd' and body_start + 8 <= body_end:
                entry_pos = body_start + 8
                while entry_pos + 8 <= body_end:
                    esize = int.from_bytes(buf[entry_pos:entry_pos + 4], 'big')
                    etype = bytes(buf[entry_pos + 4:entry_pos + 8])
                    if esize < 8 or entry_pos + esize > body_end:
                        break
                    if etype == b'hev1' and b'hvcC' in buf[entry_pos:entry_pos + esize]:
                        buf[entry_pos + 4:entry_pos + 8] = b'hvc1'
                    entry_pos += esize
            cursor = body_end

    walk(0, len(buf))
    return bytes(buf)


_CLEARKEY_SCHEMES = {
    'urn:mpeg:dash:mp4protection:2011',
    'urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e',
    'urn:uuid:1077efec-c0b2-4d02-ace3-3c1e52e2fb4b',
}


def parse_mpd(data, url, sidx_fetcher=None, clearkey_keys=None):
    if len(data) > 2 * 1024 * 1024 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise DashError('dash_manifest_invalid')
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise DashError('dash_manifest_invalid') from error
    if root.tag.rsplit('}', 1)[-1] != 'MPD':
        raise DashError('dash_manifest_invalid')
    cp_nodes = [e for e in root.iter() if e.tag.rsplit('}', 1)[-1] == 'ContentProtection']
    clearkey_info = None
    if cp_nodes:
        schemes = {(e.get('schemeIdUri') or '').strip().lower() for e in cp_nodes}
        default_kid = ''
        for e in cp_nodes:
            for k, v in e.attrib.items():
                if k.rsplit('}', 1)[-1].lower() == 'default_kid' and v:
                    default_kid = v.replace('-', '').strip().lower()
                    break
            if default_kid:
                break
        if not clearkey_keys or not (schemes & _CLEARKEY_SCHEMES):
            raise DashError('dash_requires_license')
        clearkey_info = {
            'enabled': True,
            'default_kid': default_kid,
            'keys': dict(clearkey_keys) if isinstance(clearkey_keys, dict) else {'default': str(clearkey_keys)},
        }
    periods = children(root, 'Period')
    if len(periods) != 1:
        raise DashError('dash_multiple_periods_unsupported')
    period = periods[0]
    live = root.get('type') == 'dynamic'
    total = duration(period.get('duration')) or max(0, duration(root.get('mediaPresentationDuration')) - duration(period.get('start')))
    tracks, required_kinds = [], set()
    for a_index, adaptation in enumerate(children(period, 'AdaptationSet')):
        for r_index, rep in enumerate(children(adaptation, 'Representation')):
            nodes = (root, period, adaptation, rep)
            base = url
            attrs, template, segment_list, segment_base = {}, None, None, None
            template_attrs, template_timeline = {}, None
            for node in nodes:
                attrs.update(node.attrib)
                b = child(node, 'BaseURL')
                if b is not None and b.text:
                    base = urllib.parse.urljoin(base, b.text.strip())
                t = child(node, 'SegmentTemplate')
                if t is not None:
                    template = t
                    template_attrs.update(t.attrib)
                    if child(t, 'SegmentTimeline') is not None:
                        template_timeline = child(t, 'SegmentTimeline')
                if child(node, 'SegmentList') is not None:
                    segment_list = child(node, 'SegmentList')
                if child(node, 'SegmentBase') is not None:
                    segment_base = child(node, 'SegmentBase')
            mime, codecs = attrs.get('mimeType', ''), attrs.get('codecs', '')
            kind = attrs.get('contentType') or mime.split('/')[0]
            if kind not in ('video', 'audio'):
                kind = 'video' if codecs.startswith(('avc', 'hvc', 'hev')) else 'audio' if codecs.startswith('mp4a') else ''
            if kind not in ('video', 'audio'):
                continue
            required_kinds.add(kind)
            if 'webm' in mime or (codecs and not codecs.startswith(('avc1', 'avc3', 'hvc1', 'hev1', 'mp4a', 'ac-3', 'ec-3'))):
                continue
            segments, init, init_range = [], '', ''
            number = 1
            if segment_list is not None:
                scale = int(segment_list.get('timescale', 1))
                if scale <= 0:
                    raise DashError('dash_timescale_invalid')
                t = child(segment_list, 'SegmentTimeline')
                urls = children(segment_list, 'SegmentURL')
                stamps = timeline(t, scale, total) if t is not None else [(0, int(segment_list.get('duration', 0)) / scale)] * len(urls)
                if len(urls) != len(stamps) or len(urls) > MAX_SEGMENTS:
                    raise DashError('dash_segment_list_invalid')
                initialization = child(segment_list, 'Initialization')
                if initialization is not None:
                    init, init_range = urllib.parse.urljoin(base, initialization.get('sourceURL', '')), initialization.get('range', '')
                segments = [(urllib.parse.urljoin(base, e.get('media', '')), stamps[i][1], e.get('mediaRange', '')) for i, e in enumerate(urls)]
            elif template is not None:
                scale = int(template_attrs.get('timescale', 1))
                number = int(template_attrs.get('startNumber', 1))
                if scale <= 0 or number < 0:
                    raise DashError('dash_template_invalid')
                offset = int(template_attrs.get('presentationTimeOffset', 0))
                if template_timeline is not None:
                    stamps = timeline(template_timeline, scale, total, offset)
                else:
                    length = int(template_attrs.get('duration', 0))
                    media_tpl = template_attrs.get('media', '')
                    if live and length > 0 and '$Number' in media_tpl:
                        seg_sec = length / scale
                        window_sec = duration(root.get('timeShiftBufferDepth')) or max(seg_sec * 6.0, 24.0)
                        win_count = max(3, min(MAX_SEGMENTS, int(math.ceil(window_sec / seg_sec))))
                        avail_raw = (root.get('availabilityStartTime') or '').strip()
                        live_end_num = number + win_count - 1
                        if avail_raw:
                            try:
                                import datetime
                                avail_dt = datetime.datetime.fromisoformat(avail_raw.replace('Z', '+00:00'))
                                elapsed = max(0.0, time.time() - avail_dt.timestamp())
                                live_end_num = max(number, number + int(elapsed // seg_sec) - 1)
                            except Exception:
                                pass
                        number = max(number, live_end_num - win_count + 1)
                        stamps = [(offset + (number + i) * length, seg_sec) for i in range(win_count)]
                    elif live or length <= 0 or total <= 0:
                        raise DashError('dash_timeline_required')
                    else:
                        count = math.ceil(total * scale / length)
                        if count > MAX_SEGMENTS:
                            raise DashError('dash_segments_exceeded')
                        stamps = [(offset + i * length, min(length / scale, total - i * length / scale)) for i in range(count)]
                media = template_attrs.get('media', '')
                init_template = template_attrs.get('initialization', '')
                if not media or not init_template:
                    raise DashError('dash_initialization_required')
                init = urllib.parse.urljoin(base, expand(init_template, rep))
                segments = [(urllib.parse.urljoin(base, expand(media, rep, number + i, stamp)), length, '') for i, (stamp, length) in enumerate(stamps)]
            elif segment_base is not None and segment_base.get('indexRange') and callable(sidx_fetcher):
                idx_range = segment_base.get('indexRange', '').strip()
                m_idx = re.fullmatch(r'(\d+)-(\d+)', idx_range)
                if not m_idx or int(m_idx[2]) < int(m_idx[1]):
                    raise DashError('dash_byte_range_invalid')
                initialization = child(segment_base, 'Initialization')
                if initialization is not None:
                    init = urllib.parse.urljoin(base, initialization.get('sourceURL', ''))
                    init_range = initialization.get('range', '')
                else:
                    init = base
                    init_range = f'0-{max(0, int(m_idx[1]) - 1)}'
                sidx_bytes = sidx_fetcher(base, idx_range)
                parsed_sidx = parse_sidx_segments(sidx_bytes, int(m_idx[2]))
                segments = [(base, seg_dur, seg_span) for seg_dur, seg_span in parsed_sidx]
            else:
                raise DashError('dash_segment_base_unsupported')
            if not init or not segments or any(not math.isfinite(s[1]) or s[1] <= 0 for s in segments):
                raise DashError('dash_segments_invalid')
            if sum(len(t['segments']) for t in tracks) + len(segments) > MAX_SEGMENTS:
                raise DashError('dash_segments_exceeded')
            if live:
                # A sliding timeline's first Number must advance as segments
                # disappear. Support both $Time$ timelines and fixed-duration $Number$ windows.
                media_tpl = template_attrs.get('media', '')
                if template is None or not stamps or ('$Time' not in media_tpl and '$Number' not in media_tpl):
                    raise DashError('dash_live_numbering_unsupported')
                if '$Time' in media_tpl:
                    step = max(1, round(stamps[0][1] * scale))
                    if any(round(length * scale) != step for _, length in stamps):
                        raise DashError('dash_live_variable_timeline_unsupported')
                    number = stamps[0][0] // step
            tracks.append({'id': str(a_index) + ':' + str(rep.get('id', r_index)), 'kind': kind,
                           'bandwidth': max(1, int(attrs.get('bandwidth', 1000000))),
                           'codecs': codecs, 'width': attrs.get('width', ''), 'height': attrs.get('height', ''),
                           'language': attrs.get('lang', 'und'), 'number': number,
                           'init': init, 'init_range': init_range, 'segments': segments})
            if len(tracks) > 32:
                raise DashError('dash_tracks_exceeded')
    if not tracks or not required_kinds.issubset({t['kind'] for t in tracks}):
        raise DashError('dash_codec_unsupported')
    result = {'tracks': tracks, 'live': live, 'ttl': max(1, min(duration(root.get('minimumUpdatePeriod')) or 3, 30)) if live else 3600}
    if clearkey_info:
        result['clearkey'] = clearkey_info
    return result


def byte_range(value):
    if not value:
        return ''
    m = re.fullmatch(r'(\d+)-(\d+)', value)
    if not m or int(m[2]) < int(m[1]):
        raise DashError('dash_byte_range_invalid')
    return str(int(m[2]) - int(m[1]) + 1) + '@' + m[1]


class DashSession:
    def __init__(self, relay, url, headers, diagnostic_id, scope):
        self.relay, self.url, self.headers = relay, http_url(url), dict(headers)
        p = urllib.parse.urlsplit(self.url)
        self.origin = (p.scheme.lower(), p.netloc.lower())
        self.manifest_url = self.url
        self.diagnostic_id, self.scope = diagnostic_id, scope
        self.lock, self.tokens, self.snapshot, self.expires = threading.Lock(), {}, None, 0

    def load(self):
        with self.lock:
            if self.snapshot and time.monotonic() < self.expires:
                return self.snapshot
            data, final_url = self.relay.read_dash_manifest(self.url, self.headers, self.diagnostic_id)
            sidx_fetcher = None
            if hasattr(self.relay, 'read_dash_range'):
                sidx_fetcher = lambda seg_url, span: self.relay.read_dash_range(seg_url, self.headers, span, self.diagnostic_id)
            snapshot = parse_mpd(data, final_url, sidx_fetcher=sidx_fetcher)
            self.manifest_url = final_url
            self.snapshot, self.expires = snapshot, time.monotonic() + snapshot['ttl']
            return snapshot

    def local(self, url, base, kind='media'):
        p, parent = urllib.parse.urlsplit(url), urllib.parse.urlsplit(self.manifest_url)
        if not p.query and parent.query and self.relay._same_origin(p, parent):
            url = self.relay._with_query(url, parent.query)
        token = self.relay.register(url, self.headers, origin=self.origin, diagnostic_id=self.diagnostic_id,
                                    resource_scope=self.scope, segment=True, resource_kind=kind)
        return base + '/media/' + token

    def playlist(self, track_id, base):
        snapshot = self.load()
        tracks = snapshot['tracks']
        if track_id is None:
            lines = ['#EXTM3U', '#EXT-X-VERSION:7']
            audio = [t for t in tracks if t['kind'] == 'audio']
            video = [t for t in tracks if t['kind'] == 'video']
            for i, t in enumerate(audio if video else []):
                uri = self.relay.dash_track_url(self, t['id'], base)
                language = str(t.get('language') or 'und').replace('"', '').replace('\r', '').replace('\n', '')[:32]
                lines.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="{language} {i+1}",LANGUAGE="{language}",DEFAULT={"YES" if i == 0 else "NO"},AUTOSELECT=YES,URI="{uri}"')
            for t in video or audio:
                attrs = ['BANDWIDTH=' + str(t['bandwidth'] + (max(x['bandwidth'] for x in audio) if video and audio else 0))]
                codecs = ','.join(dict.fromkeys([t['codecs']] + ([x['codecs'] for x in audio] if video else []))).strip(',')
                if codecs:
                    codecs = re.sub(r'\bhev1(?=\.|$)', 'hvc1', codecs)
                if codecs and re.fullmatch(r'[A-Za-z0-9.,_-]+', codecs):
                    attrs.append('CODECS="' + codecs + '"')
                if str(t['width']).isdigit() and str(t['height']).isdigit():
                    attrs.append('RESOLUTION=' + t['width'] + 'x' + t['height'])
                if video and audio:
                    attrs.append('AUDIO="audio"')
                lines += ['#EXT-X-STREAM-INF:' + ','.join(attrs), self.relay.dash_track_url(self, t['id'], base)]
            return '\n'.join(lines) + '\n'
        t = next((t for t in tracks if t['id'] == track_id), None)
        if not t:
            raise DashError('dash_track_expired')
        lines = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-TARGETDURATION:' + str(math.ceil(max(s[1] for s in t['segments']))),
                 '#EXT-X-MEDIA-SEQUENCE:' + str(t['number'])]
        if not snapshot['live']:
            lines.append('#EXT-X-PLAYLIST-TYPE:VOD')
        init = '#EXT-X-MAP:URI="' + self.local(t['init'], base, 'map') + '"'
        if t['init_range']:
            init += ',BYTERANGE="' + byte_range(t['init_range']) + '"'
        lines.append(init)
        for url, length, span in t['segments']:
            lines.append('#EXTINF:' + format(length, '.6f') + ',')
            if span:
                lines.append('#EXT-X-BYTERANGE:' + byte_range(span))
            lines.append(self.local(url, base))
        if not snapshot['live']:
            lines.append('#EXT-X-ENDLIST')
        return '\n'.join(lines) + '\n'
