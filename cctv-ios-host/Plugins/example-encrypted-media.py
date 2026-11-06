"""Template Python Spider for non-fragmented CENC MP4 sources.

Configure ``options.items`` in cctvhost.json as a mapping from episode ID to
``{"title": ..., "url": "https://.../video.mp4", "key": "32 hex chars",
"headers": {...}}``. The source must provide HTTP byte ranges and a standard
MP4 sample table with per-sample IVs in ``senc``. No plugin HTTP server or ffmpeg
process is needed; CCTVHost serves localProxy() responses and owns Range handling.
"""

import bisect
import collections
import json
import re
import struct
import urllib.parse
import urllib.request

import hostcrypto


MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_MOOV_BYTES = 16 * 1024 * 1024
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_SAMPLES = 1_000_000
_REMOVED_BOXES = {b'senc', b'saiz', b'saio', b'sinf', b'sgpd', b'sbgp', b'saif', b'sdtp'}
_CONTAINER_BOXES = {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts', b'dinf', b'udta', b'mvex'}
_CONTENT_RANGE = re.compile(r'^bytes (\d+)-(\d+)/(\d+)$', re.I)
_RANGE = re.compile(r'^bytes=(\d*)-(\d*)$', re.I)


def _u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise ValueError('truncated MP4 integer')
    return struct.unpack_from('>I', data, offset)[0]


def _u64(data, offset):
    if offset < 0 or offset + 8 > len(data):
        raise ValueError('truncated MP4 integer')
    return struct.unpack_from('>Q', data, offset)[0]


def _boxes(data, start, end):
    offset = start
    while offset + 8 <= end:
        size = _u32(data, offset)
        kind = data[offset + 4:offset + 8]
        header = 8
        if size == 1:
            if offset + 16 > end:
                raise ValueError('truncated extended MP4 box')
            size = _u64(data, offset + 8)
            header = 16
        elif size == 0:
            size = end - offset
        if size < header or offset + size > end:
            raise ValueError('invalid MP4 box size')
        yield kind, offset, offset + header, offset + size
        offset += size
    if offset != end:
        raise ValueError('trailing bytes in MP4 box table')


def _child(data, start, end, kind):
    for box_kind, _box_start, content, box_end in _boxes(data, start, end):
        if box_kind == kind:
            return content, box_end
    return None


def _path(data, start, end, kinds):
    bounds = (start, end)
    for kind in kinds:
        bounds = _child(data, bounds[0], bounds[1], kind)
        if not bounds:
            return None
    return bounds


def _request_headers(headers, start, end):
    result = {str(key): str(value) for key, value in (headers or {}).items()
              if isinstance(key, str) and isinstance(value, str) and
              len(key) <= 128 and len(value) <= 8192 and
              re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", key) and
              '\r' not in value and '\n' not in value and
              key.lower() not in ('host', 'range', 'content-length', 'connection')}
    result['Range'] = 'bytes=%d-%d' % (start, end)
    result['Accept-Encoding'] = 'identity'
    result.setdefault('User-Agent', 'CCTVHost encrypted-media example')
    return result


def _valid_http_url(value):
    if not isinstance(value, str) or len(value) > 8192:
        return False
    try:
        parts = urllib.parse.urlsplit(value)
        parts.port
        return parts.scheme.lower() in ('http', 'https') and bool(parts.hostname) and not parts.username and not parts.password
    except ValueError:
        return False


def _fetch_range(url, start, end, headers, timeout=30):
    if not _valid_http_url(url):
        raise ValueError('upstream media must use a valid HTTP or HTTPS URL')
    if start < 0 or end < start or end - start + 1 > MAX_FILE_BYTES:
        raise ValueError('invalid or oversized upstream range')
    request = urllib.request.Request(url, headers=_request_headers(headers, start, end))
    with urllib.request.urlopen(request, timeout=timeout) as response:
        status = response.getcode()
        content_range = response.headers.get('Content-Range', '')
        match = _CONTENT_RANGE.fullmatch(content_range.strip())
        if status != 206 or not match:
            raise ValueError('upstream must honor byte ranges with HTTP 206')
        actual_start, actual_end, total = map(int, match.groups())
        if actual_start != start or actual_end != end:
            raise ValueError('upstream returned a mismatched Content-Range')
        if total <= 0 or total > MAX_FILE_BYTES or actual_end >= total:
            raise ValueError('upstream MP4 size is invalid or exceeds the limit')
        body = response.read(actual_end - actual_start + 2)
        expected = actual_end - actual_start + 1
        if len(body) != expected:
            raise ValueError('upstream range body length does not match Content-Range')
        return body, total


def _read_moov(url, headers):
    first, total = _fetch_range(url, 0, 0, headers)
    if total < 16:
        raise ValueError('MP4 is too small')
    offset = 0
    for _ in range(256):
        if offset + 8 > total:
            break
        header, _ = _fetch_range(url, offset, min(total - 1, offset + 15), headers)
        size = _u32(header, 0)
        kind = header[4:8]
        header_size = 8
        if size == 1:
            if len(header) < 16:
                raise ValueError('truncated extended MP4 box header')
            size = _u64(header, 8)
            header_size = 16
        elif size == 0:
            size = total - offset
        if size < header_size or size > total - offset:
            raise ValueError('invalid top-level MP4 box size')
        if kind == b'moov':
            if size > MAX_MOOV_BYTES:
                raise ValueError('MP4 moov box exceeds 16 MB')
            data, _ = _fetch_range(url, offset, offset + size - 1, headers)
            return offset, data, total
        offset += size
    raise ValueError('MP4 moov box was not found in top-level boxes')


def _tenc_iv_size(moov):
    position = 0
    while True:
        position = moov.find(b'tenc', position)
        if position < 0:
            return None
        box_start = position - 4
        try:
            size = _u32(moov, box_start)
            content = box_start + 8
            if size >= 31 and box_start + size <= len(moov):
                protected = moov[content + 5]
                iv_size = moov[content + 6]
                if protected and iv_size in (8, 16):
                    return iv_size
        except (IndexError, ValueError):
            pass
        position += 4


def _parse_senc(data, content, end, sample_count, iv_size):
    flags = int.from_bytes(data[content + 1:content + 4], 'big')
    if flags & 1:
        raise ValueError('senc override parameters are not supported by this template')
    count = _u32(data, content + 4)
    if count != sample_count or count > MAX_SAMPLES:
        raise ValueError('senc sample count does not match stsz')
    offset = content + 8
    ivs, subsamples = [], []
    for _ in range(count):
        if offset + iv_size > end:
            raise ValueError('truncated senc sample IV')
        ivs.append(bytes(data[offset:offset + iv_size]))
        offset += iv_size
        entries = None
        if flags & 2:
            if offset + 2 > end:
                raise ValueError('truncated senc subsample count')
            sub_count = struct.unpack_from('>H', data, offset)[0]
            offset += 2
            if sub_count > 4096 or offset + sub_count * 6 > end:
                raise ValueError('invalid senc subsample table')
            entries = []
            for _ in range(sub_count):
                clear_bytes = struct.unpack_from('>H', data, offset)[0]
                encrypted_bytes = _u32(data, offset + 2)
                entries.append((clear_bytes, encrypted_bytes))
                offset += 6
        subsamples.append(entries)
    return ivs, subsamples


def _sample_offsets(chunks, stsc, sizes):
    offsets = []
    row_index = 0
    sample_index = 0
    for chunk_index, chunk_offset in enumerate(chunks, 1):
        while row_index + 1 < len(stsc) and chunk_index >= stsc[row_index + 1][0]:
            row_index += 1
        if not stsc:
            break
        position = chunk_offset
        for _ in range(stsc[row_index][1]):
            if sample_index >= len(sizes):
                break
            offsets.append(position)
            position += sizes[sample_index]
            sample_index += 1
    if sample_index != len(sizes):
        raise ValueError('stsc/stco do not describe every stsz sample')
    return offsets


def _parse_track(moov, track_start, track_end, iv_size):
    bounds = _path(moov, track_start, track_end, (b'mdia', b'minf', b'stbl'))
    if not bounds:
        return None
    start, end = bounds
    sizes, chunks, stsc = [], [], []
    sample_count = 0
    senc = None
    encrypted = False
    for kind, _box_start, content, box_end in _boxes(moov, start, end):
        if kind == b'stsd':
            if content + 16 <= box_end:
                sample_type = moov[content + 12:content + 16]
                encrypted = sample_type in (b'encv', b'enca')
        elif kind == b'stsz':
            default_size = _u32(moov, content + 4)
            sample_count = _u32(moov, content + 8)
            if sample_count > MAX_SAMPLES:
                raise ValueError('stsz sample count exceeds the limit')
            if default_size:
                sizes = [default_size] * sample_count
            else:
                table_end = content + 12 + sample_count * 4
                if table_end > box_end:
                    raise ValueError('truncated stsz table')
                sizes = list(struct.unpack_from('>%dI' % sample_count, moov, content + 12)) if sample_count else []
        elif kind == b'stco':
            count = _u32(moov, content + 4)
            if count > MAX_SAMPLES or content + 8 + count * 4 > box_end:
                raise ValueError('invalid stco table')
            chunks = list(struct.unpack_from('>%dI' % count, moov, content + 8)) if count else []
        elif kind == b'co64':
            count = _u32(moov, content + 4)
            if count > MAX_SAMPLES or content + 8 + count * 8 > box_end:
                raise ValueError('invalid co64 table')
            chunks = list(struct.unpack_from('>%dQ' % count, moov, content + 8)) if count else []
        elif kind == b'stsc':
            count = _u32(moov, content + 4)
            if count > MAX_SAMPLES or content + 8 + count * 12 > box_end:
                raise ValueError('invalid stsc table')
            stsc = [struct.unpack_from('>III', moov, content + 8 + i * 12) for i in range(count)]
        elif kind == b'senc':
            senc = (content, box_end)
    if not encrypted:
        return None
    if iv_size not in (8, 16) or not senc or not sizes or not chunks or not stsc:
        raise ValueError('encrypted track is missing tenc/senc sample tables')
    ivs, subsamples = _parse_senc(moov, senc[0], senc[1], sample_count, iv_size)
    offsets = _sample_offsets(chunks, stsc, sizes)
    return [{'offset': offset, 'size': size, 'iv': iv, 'subsamples': sub}
            for offset, size, iv, sub in zip(offsets, sizes, ivs, subsamples)]


def _find_frma(data, start, end):
    sinf = _child(data, start, end, b'sinf')
    if not sinf:
        return None
    frma = _child(data, sinf[0], sinf[1], b'frma')
    if frma and frma[0] + 4 <= frma[1]:
        return data[frma[0]:frma[0] + 4]
    return None


def _collect_patches(data, start, end, absolute_base, output):
    for kind, box_start, content, box_end in _boxes(data, start, end):
        if kind in _REMOVED_BOXES:
            output.append((absolute_base + box_start + 4, b'free'))
        elif kind == b'stsd':
            if content + 8 > box_end:
                raise ValueError('truncated stsd table')
            count = _u32(data, content + 4)
            entry_start = content + 8
            for _ in range(min(count, 256)):
                if entry_start + 8 > box_end:
                    raise ValueError('truncated stsd sample entry')
                size = _u32(data, entry_start)
                entry_type = data[entry_start + 4:entry_start + 8]
                entry_end = entry_start + size
                if size < 8 or entry_end > box_end:
                    raise ValueError('invalid stsd sample entry size')
                if entry_type in (b'encv', b'enca'):
                    skip = 78 if entry_type == b'encv' else 28
                    actual_type = _find_frma(data, entry_start + 8 + skip, entry_end)
                    if not actual_type:
                        actual_type = b'hvc1' if entry_type == b'encv' else b'mp4a'
                    output.append((absolute_base + entry_start + 4, actual_type))
                    _collect_patches(data, entry_start + 8 + skip, entry_end, absolute_base, output)
                entry_start = entry_end
        elif kind in _CONTAINER_BOXES:
            _collect_patches(data, content, box_end, absolute_base, output)


def _parse_moov(moov, absolute_offset):
    iv_size = _tenc_iv_size(moov)
    if iv_size is None:
        raise ValueError('moov has no supported 8- or 16-byte tenc IV size')
    root = _child(moov, 0, len(moov), b'moov')
    if not root:
        raise ValueError('moov box is missing')
    samples = []
    for kind, _box_start, content, box_end in _boxes(moov, root[0], root[1]):
        if kind == b'trak':
            parsed = _parse_track(moov, content, box_end, iv_size)
            if parsed:
                samples.extend(parsed)
    if not samples:
        raise ValueError('moov has no encrypted sample table')
    samples.sort(key=lambda sample: sample['offset'])
    patches = []
    _collect_patches(moov, root[0], root[1], absolute_offset, patches)
    return samples, patches


def _parse_range(value, total):
    if not value:
        return 0, total - 1, False
    match = _RANGE.fullmatch(str(value).strip())
    if not match:
        return None
    start_text, end_text = match.groups()
    if not start_text and not end_text:
        return None
    if start_text:
        start = int(start_text)
        end = int(end_text) if end_text else total - 1
    else:
        suffix = int(end_text)
        if suffix <= 0:
            return None
        start, end = max(0, total - suffix), total - 1
    if start >= total or end < start:
        return None
    return start, min(end, total - 1), True


class CENCSession:
    def __init__(self, url, key, headers):
        self.url = url
        self.key = bytes.fromhex(key)
        if len(self.key) != 16:
            raise ValueError('CENC AES-128 key must be 32 hex characters')
        self.headers = dict(headers or {})
        self.moov_offset, moov, self.size = _read_moov(url, self.headers)
        self.samples, self.patches = _parse_moov(moov, self.moov_offset)
        self.starts = [sample['offset'] for sample in self.samples]
        for sample in self.samples:
            if sample['size'] <= 0 or sample['offset'] < 0 or sample['offset'] + sample['size'] > self.size:
                raise ValueError('sample table points outside the MP4')

    def _decrypt_sample(self, sample, ciphertext):
        iv = sample['iv']
        counter = iv if len(iv) == 16 else iv + b'\x00' * 8
        cipher = hostcrypto.AES_CTR(self.key, counter)
        plain = bytearray(ciphertext)
        try:
            subsamples = sample['subsamples']
            if subsamples is None:
                plain[:] = cipher.update(ciphertext)
            else:
                offset = 0
                for clear_bytes, encrypted_bytes in subsamples:
                    offset += clear_bytes
                    end = offset + encrypted_bytes
                    if end > len(plain):
                        raise ValueError('senc subsample lengths exceed sample size')
                    if encrypted_bytes:
                        plain[offset:end] = cipher.update(ciphertext[offset:end])
                    offset = end
                if offset > len(plain):
                    raise ValueError('senc subsample table exceeds sample size')
        finally:
            cipher.close()
        return bytes(plain)

    def read(self, start, end):
        length = end - start + 1
        if length <= 0 or length > MAX_RESPONSE_BYTES:
            raise ValueError('requested range exceeds the 16 MB response limit')
        body, _ = _fetch_range(self.url, start, end, self.headers)
        output = bytearray(body)
        first = max(0, bisect.bisect_right(self.starts, start) - 1)
        for index in range(first, len(self.samples)):
            sample = self.samples[index]
            sample_start = sample['offset']
            sample_end = sample_start + sample['size'] - 1
            if sample_start > end:
                break
            if sample_end < start:
                continue
            if start <= sample_start and sample_end <= end:
                ciphertext = bytes(output[sample_start - start:sample_end - start + 1])
            else:
                ciphertext, _ = _fetch_range(self.url, sample_start, sample_end, self.headers)
            plaintext = self._decrypt_sample(sample, ciphertext)
            overlap_start, overlap_end = max(start, sample_start), min(end, sample_end)
            output[overlap_start - start:overlap_end - start + 1] = plaintext[
                overlap_start - sample_start:overlap_end - sample_start + 1]
        for offset, replacement in self.patches:
            if start <= offset and offset + 4 <= end + 1:
                output[offset - start:offset - start + 4] = replacement
        return bytes(output)


class Spider:
    """Replace the empty example catalogue with source-specific metadata."""

    def __init__(self):
        self.items = {}
        self.sessions = collections.OrderedDict()

    def init(self, extend=''):
        try:
            options = json.loads(extend) if isinstance(extend, str) and extend else {}
        except (TypeError, ValueError):
            options = {}
        items = options.get('items', {}) if isinstance(options, dict) else {}
        if isinstance(items, list):
            items = {str(item.get('id')): item for item in items if isinstance(item, dict) and item.get('id')}
        if isinstance(items, dict):
            for identifier, item in items.items():
                if not isinstance(item, dict):
                    continue
                url, key = item.get('url'), item.get('key')
                if (not _valid_http_url(url) or not isinstance(key, str) or
                        not re.fullmatch(r'[0-9a-fA-F]{32}', key)):
                    continue
                raw_headers = item.get('headers') if isinstance(item.get('headers'), dict) else {}
                headers = {}
                for header_name, header_value in list(raw_headers.items())[:64]:
                    if isinstance(header_name, str) and isinstance(header_value, (str, int, float)):
                        headers[header_name] = str(header_value)
                self.items[str(identifier)] = {'id': str(identifier), 'title': str(item.get('title') or identifier)[:256],
                                               'url': url, 'key': key.lower(), 'headers': headers}

    def homeContent(self, filter):
        return {'class': [{'type_id': 'encrypted', 'type_name': '加密示例'}],
                'list': [{'vod_id': item['id'], 'vod_name': item['title']} for item in self.items.values()]}

    def categoryContent(self, tid, pg, filter, extend):
        return {'page': 1, 'pagecount': 1,
                'list': [{'vod_id': item['id'], 'vod_name': item['title']} for item in self.items.values()]}

    def searchContent(self, key, quick, pg='1'):
        key = str(key or '').lower()
        return {'list': [{'vod_id': item['id'], 'vod_name': item['title']}
                         for item in self.items.values() if key in item['title'].lower()]}

    def detailContent(self, ids):
        item = self.items.get(str(ids[0])) if ids else None
        if not item:
            return {'list': []}
        return {'list': [{'vod_id': item['id'], 'vod_name': item['title'],
                          'vod_play_from': 'CENC 本机解密',
                          'vod_play_url': '正片$' + item['id']} ]}

    def playerContent(self, flag, id, vipFlags):
        item = self.items.get(str(id))
        if not item:
            return {'error': '示例没有配置该分集；请在 cctvhost.json options.items 中填入地址和密钥'}
        token = urllib.parse.quote(item['id'], safe='')
        return {'url': 'cenc://' + token, 'proxy': 1, 'format': 'mp4',
                'contentType': 'video/mp4', 'header': item['headers']}

    def _session(self, item, headers):
        key = (item['url'], item['key'], tuple(sorted((str(name), str(value))
                                                       for name, value in (headers or {}).items())))
        cached = self.sessions.get(key)
        if cached:
            self.sessions.move_to_end(key)
            return cached
        session = CENCSession(item['url'], item['key'], headers)
        self.sessions[key] = session
        while len(self.sessions) > 4:
            self.sessions.popitem(last=False)
        return session

    def localProxy(self, params):
        if not isinstance(params, dict):
            return [400, {'Content-Type': 'text/plain; charset=utf-8'}, b'invalid proxy parameters']
        request_url = urllib.parse.urlsplit(str(params.get('url') or ''))
        identifier = urllib.parse.unquote((request_url.netloc + request_url.path).lstrip('/'))
        item = self.items.get(identifier)
        if not item:
            return [404, {'Content-Type': 'text/plain; charset=utf-8'}, b'unknown encrypted episode']
        method = str(params.get('method') or 'GET').upper()
        if method not in ('GET', 'HEAD'):
            return [405, {'Allow': 'GET, HEAD'}, b'']
        upstream_headers = params.get('upstreamHeaders')
        if not isinstance(upstream_headers, dict):
            upstream_headers = item['headers']
        try:
            session = self._session(item, upstream_headers)
            request_range = params.get('range') or (params.get('headers') or {}).get('Range', '')
            selected = _parse_range(request_range, session.size)
            if selected is None:
                return [416, {'Content-Range': 'bytes */%d' % session.size,
                              'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'}, b'']
            start, end, partial = selected
            length = end - start + 1
            status = 206 if partial else 200
            headers = {'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes',
                       'Content-Length': str(length)}
            if partial:
                headers['Content-Range'] = 'bytes %d-%d/%d' % (start, end, session.size)
            body = b'' if method == 'HEAD' else session.read(start, end)
            return [status, headers, body]
        except Exception as error:
            message = ('CENC proxy failed: ' + str(error))[:512]
            return [502, {'Content-Type': 'text/plain; charset=utf-8'}, message.encode('utf-8')]
