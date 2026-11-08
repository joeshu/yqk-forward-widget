"""Local media protocol adapters. User JS stays JS; Python spiders stay Python.

Only explicitly enabled packages are loaded. This module never resolves a stream
by executing a plugin during import/inspection of an archive.
"""
import builtins
import collections
import importlib
import importlib.util
import inspect
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import uuid
import types


class MediaError(Exception):
    def __init__(self, code, message, retryable=False):
        super().__init__(message)
        self.code, self.retryable = code, retryable


def report_runtime_stage(stage):
    """Persist an allow-listed Python stage through the embedding host."""
    owner = getattr(threading.current_thread(), '_host_session', None)
    callback = vars(builtins).get('_cctvhost_python_stage')
    if owner is None or not callable(callback):
        return
    try:
        callback(str(getattr(owner, 'identifier', '')), str(stage))
    except BaseException:
        pass


def _python_spider_log_stage(event, entry, started_at, **fields):
    """Record safe phase timings in the owning service's isolated log."""
    owner = getattr(threading.current_thread(), '_host_session', None)
    if owner is None:
        return
    phase = {
        'python_spider_prepare_started': 'spider_module_import_started',
        'python_spider_module_loaded': 'spider_module_loaded',
        'python_spider_constructor_started': 'spider_constructor_started',
        'python_spider_init_started': 'spider_init_started',
        'python_spider_init_succeeded': 'spider_init_succeeded',
        'python_spider_ready': 'spider_ready',
        'python_spider_prepare_failed': 'spider_prepare_failed',
    }.get(event)
    if phase:
        report_runtime_stage(phase)
    record = {'event': event, 'entry': os.path.basename(str(entry or '')),
              'elapsed_ms': max(0, int((time.perf_counter() - started_at) * 1000))}
    record['service_id'] = str(getattr(owner, 'identifier', ''))
    record.update(fields)
    try:
        print('[CCTVHostMediaAPI] ' + json.dumps(record, ensure_ascii=False,
                                                   separators=(',', ':')))
    except Exception:
        pass


def decoded(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            pass
    return value


def unwrap_envelope(value, fields):
    """Unwrap common HTTP/API envelopes without changing source-native rows."""
    for _ in range(6):
        value = decoded(value)
        if not isinstance(value, dict) or any(key in value for key in fields):
            return value
        nested = next((value[key] for key in ('data', 'result', 'payload', 'response')
                       if key in value and value[key] is not None), None)
        if nested is None or nested is value:
            return value
        value = nested
    return decoded(value)


def rows(value):
    value = unwrap_envelope(value, {'list', 'items'})
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        result = decoded(value.get('list', value.get('items', [])))
        if isinstance(result, list):
            return result
        if isinstance(result, dict):
            return [result]
    return []


def _normalize_poster(raw_poster, raw_headers=None):
    poster = str(raw_poster or '').strip()
    headers = media_headers(raw_headers) if isinstance(raw_headers, dict) else {}
    if poster.startswith('//') and len(poster) > 4:
        poster = 'https:' + poster
    if '@' in poster and poster.lower().startswith(('http://', 'https://')):
        parts = poster.split('@')
        base_url = parts[0].strip()
        extra = {}
        valid_inline = True
        for seg in parts[1:]:
            if '=' in seg:
                k, _, v = seg.partition('=')
                k_clean = k.strip()
                if k_clean.lower() in ('referer', 'referrer', 'user-agent', 'ua', 'cookie', 'origin', 'authorization'):
                    if k_clean.lower() == 'ua':
                        k_clean = 'User-Agent'
                    elif k_clean.lower() == 'referrer':
                        k_clean = 'Referer'
                    extra[k_clean] = v.strip()
                else:
                    valid_inline = False
                    break
            else:
                valid_inline = False
                break
        if valid_inline and extra:
            poster = base_url
            headers.update(media_headers(extra))
    return poster, headers


def _clean_meta_text(value):
    if value is None or isinstance(value, bool):
        return ''
    if isinstance(value, (list, tuple)):
        parts = [_clean_meta_text(v) for v in value]
        return ' / '.join(p for p in parts if p)
    if isinstance(value, dict):
        for k in ('name', 'title', 'text', 'label', 'value', 'v', 'n', 'vod_name', 'type_name'):
            if value.get(k) not in (None, ''):
                return _clean_meta_text(value[k])
        return ''
    text = str(value).strip()
    if not text:
        return ''
    low = text.lower()
    if '[object ' in low:
        text = re.sub(r'\[object\s+[^\]]+\]', '', text, flags=re.I).strip(' ·/|-—,\t\r\n')
        low = text.lower()
    if low in ('null', 'nil', 'none', 'undefined', 'nan', '[object object]', '[object array]', '{}', '[]'):
        return ''
    return text


def cards(value):
    result = []
    for row in rows(value):
        if not isinstance(row, dict):
            continue
        identifier = row.get('id', row.get('vod_id'))
        name = _clean_meta_text(row.get('name', row.get('vod_name')))
        if identifier is None or not name:
            continue
        poster_url, poster_headers = _normalize_poster(
            row.get('poster', row.get('vod_pic', '')),
            row.get('posterHeaders') if isinstance(row.get('posterHeaders'), dict) else None,
        )
        result.append({'id': str(identifier), 'name': str(name),
                       'poster': poster_url,
                       'remarks': _clean_meta_text(row.get('remarks', row.get('vod_remarks', ''))),
                       **({'posterHeaders': poster_headers} if poster_headers else {})})
    return result


def listing(value, page=1):
    value = unwrap_envelope(value, {'list', 'items'})
    data = value if isinstance(value, dict) else {}
    result = {'items': cards(value), 'page': int(data.get('page') or page)}
    for name in ('pagecount', 'total', 'limit'):
        if data.get(name) is not None:
            try:
                result[name] = int(data[name])
            except (ValueError, TypeError):
                pass
    if 'hasMore' in data:
        result['hasMore'] = bool(data['hasMore'])
    elif 'pagecount' in result:
        result['hasMore'] = result['page'] < result['pagecount']
    else:
        # Unknown page size: never conclude that a short page is the last page.
        result['hasMore'] = bool(result['items'])
    return result


def home(value):
    value = unwrap_envelope(value, {'list', 'items', 'class', 'categories', 'filters'})
    value = value if isinstance(value, dict) else {}
    categories = value.get('categories', value.get('class', [])) or []
    return {'categories': [{'id': str(row.get('id', row.get('type_id', ''))),
                            'name': str(row.get('name', row.get('type_name', '')))}
                           for row in categories if isinstance(row, dict)],
            'filters': value.get('filters', {}), 'items': cards(value),
            'recommendationsUnavailable': value.get('recommendationsUnavailable') is True}


def detail(value, identifier):
    value = unwrap_envelope(value, {'list', 'items', 'lines', 'episodes',
                                    'vod_play_url', 'play_url', 'playUrl', 'vod_info',
                                    'vodInfo', 'video', 'detail'})
    raw = rows(value)
    if isinstance(value, dict) and ('list' in value or 'items' in value) and not raw:
        raise MediaError('NO_DETAIL', '此站点没有返回影片详情，请重试或更换站点')
    item = raw[0] if raw else value
    if isinstance(item, dict):
        nested = next((item[key] for key in ('vod_info', 'vodInfo', 'video', 'detail')
                       if isinstance(item.get(key), dict)), None)
        if nested is not None:
            item = nested
    if not isinstance(item, dict):
        raise MediaError('NO_DETAIL', '来源未返回影片详情')
    lines = []
    if isinstance(item.get('lines'), list):
        for index, line in enumerate(item['lines']):
            if not isinstance(line, dict) or not isinstance(line.get('episodes'), list):
                continue
            episodes = []
            for episode_index, row in enumerate(line['episodes']):
                if isinstance(row, dict):
                    episode_id = next((row[key] for key in ('id', 'url', 'playUrl', 'play_url', 'value', 'link')
                                       if row.get(key) not in (None, '')), None)
                    episode_name = next((row[key] for key in ('name', 'title', 'episode', 'label')
                                         if row.get(key)), None)
                elif isinstance(row, (str, int, float)):
                    episode_id, episode_name = row, None
                else:
                    continue
                if episode_id is None or not str(episode_id).strip():
                    continue
                episodes.append({'id': str(episode_id).strip(),
                                 'name': str(episode_name or f'第 {episode_index + 1} 集').strip()})
            if episodes:
                lines.append({'id': str(line.get('id', index)), 'name': str(line.get('name') or f'线路 {index + 1}'), 'episodes': episodes})
    # Some providers return an empty or partially populated normalized `lines`
    # array alongside the original MacCMS fields. Prefer usable normalized
    # lines, then fall back to the source's raw playback declaration.
    if not lines and 'vod_play_url' in item:
        raw_from = item.get('vod_play_from')
        flags = ([str(f).strip() for f in raw_from]
                 if isinstance(raw_from, (list, tuple))
                 else str(raw_from or '').split('$$$'))
        raw_url = item.get('vod_play_url')
        groups = ([str(g) for g in raw_url]
                  if isinstance(raw_url, (list, tuple))
                  else str(raw_url or '').split('$$$'))
        for line_index, group in enumerate(groups):
            flag = flags[line_index] if line_index < len(flags) else ''
            episodes = []
            for index, episode in enumerate(group.split('#')):
                if not episode:
                    continue
                label, separator, play_id = episode.partition('$')
                episode_id = play_id if separator else label
                episode_name = label if separator else ''
                if episode_id.strip():
                    episodes.append({'id': episode_id,
                                     'name': episode_name.strip() or f'第 {index + 1} 集'})
            if episodes:
                lines.append({'id': flag, 'name': flag or f'线路 {line_index + 1}', 'episodes': episodes})
    if not lines and isinstance(item.get('episodes'), list):
        episodes = []
        for index, row in enumerate(item['episodes']):
            if isinstance(row, dict):
                identifier = next((row[key] for key in ('id', 'url', 'playUrl', 'play_url', 'value', 'link')
                                    if row.get(key) is not None), None)
                name = next((row[key] for key in ('name', 'title', 'episode', 'label', 'vod_name')
                             if row.get(key)), None)
            elif isinstance(row, (str, int, float)):
                identifier, name = row, None
            else:
                continue
            if identifier is None or not str(identifier).strip():
                continue
            identifier = str(identifier).strip()
            episodes.append({'id': identifier,
                             'name': str(name or f'第 {index + 1} 集').strip()})
        if episodes:
            lines = [{'id': '', 'name': '播放', 'episodes': episodes}]
    poster_url, poster_headers = _normalize_poster(
        item.get('poster', item.get('vod_pic', '')),
        item.get('posterHeaders') if isinstance(item.get('posterHeaders'), dict) else None,
    )
    result = {'id': str(item.get('id', item.get('vod_id', identifier))),
              'name': _clean_meta_text(item.get('name', item.get('vod_name', identifier))) or str(identifier),
              'poster': poster_url,
              'description': _clean_meta_text(item.get('description', item.get('vod_content', ''))),
              'actor': _clean_meta_text(item.get('actor', item.get('vod_actor', ''))),
              'year': _clean_meta_text(item.get('year', item.get('vod_year', ''))), 'lines': lines}
    if poster_headers:
        result['posterHeaders'] = poster_headers
    # Preserve optional provider metadata when present so the native detail page
    # can show accurate credits and classification without inventing values.
    for key, aliases in {
        'area': ('area', 'vod_area'), 'lang': ('lang', 'vod_lang'),
        'type': ('type', 'vod_class'), 'director': ('director', 'vod_director'),
        'remarks': ('remarks', 'vod_remarks'), 'banner': ('banner', 'backdrop'),
    }.items():
        value = next((item[name] for name in aliases if item.get(name)), None)
        if value is not None:
            cleaned = str(value)[:4096] if key == 'banner' else _clean_meta_text(value)[:4096]
            if cleaned:
                result[key] = cleaned
    return result


def valid_media_url(value):
    if (not isinstance(value, str) or len(value) > 8192 or
            any(ord(char) <= 32 or ord(char) == 127 for char in value)):
        return False
    try:
        parsed = urllib.parse.urlsplit(value)
        parsed.port  # Reject malformed or out-of-range ports before handing the URL to AVPlayer.
        return (parsed.scheme.lower() in ('http', 'https') and bool(parsed.hostname)
                and not parsed.username and not parsed.password)
    except ValueError:
        return False


def valid_proxy_address(value):
    """Accept an HTTP URL or an opaque absolute URI owned by localProxy()."""
    if valid_media_url(value):
        return True
    if (not isinstance(value, str) or len(value) > 8192 or
            any(ord(char) <= 32 or ord(char) == 127 for char in value)):
        return False
    try:
        parsed = urllib.parse.urlsplit(value)
        return (bool(re.fullmatch(r'[A-Za-z][A-Za-z0-9+.-]{0,31}', parsed.scheme)) and
                parsed.scheme.lower() not in ('file', 'data', 'javascript', 'mailto') and
                bool(parsed.netloc or parsed.path) and not parsed.username and not parsed.password)
    except ValueError:
        return False


def _normalize_drm_key(value):
    if not value:
        return ''
    if isinstance(value, dict):
        keys = value.get('keys')
        if isinstance(keys, list) and keys and isinstance(keys[0], dict):
            k_val = str(keys[0].get('k') or '').strip()
            if k_val:
                return _normalize_drm_key(k_val)
        for k in ('drmKey', 'clearKey', 'cencKey', 'decryptionKey', 'key', 'k'):
            if value.get(k):
                return _normalize_drm_key(value[k])
        return ''
    text = str(value).strip()
    if not text:
        return ''
    if text.startswith('{'):
        try:
            return _normalize_drm_key(json.loads(text))
        except Exception:
            pass
    if ':' in text and not text.lower().startswith(('http:', 'https:', 'base64:', 'hex:')):
        _, _, rhs = text.rpartition(':')
        if rhs.strip():
            text = rhs.strip()
    if text.lower().startswith(('hex:', '0x')):
        text = re.sub(r'^(?:hex:|0x)', '', text, flags=re.I).strip()
    elif text.lower().startswith('base64:'):
        text = text[7:].strip()
    if re.fullmatch(r'[0-9a-fA-F]{32}', text):
        return text.lower()
    if 20 <= len(text) <= 28 and re.fullmatch(r'[A-Za-z0-9+/_=-]+', text):
        import base64
        try:
            padded = text + '=' * ((4 - len(text) % 4) % 4)
            raw = base64.urlsafe_b64decode(padded) if ('-' in text or '_' in text) else base64.b64decode(padded)
            if len(raw) == 16:
                return raw.hex()
        except Exception:
            pass
    return ''


def normalize_media_address(value):
    if not isinstance(value, str):
        return value
    address = re.sub(r'(?i)&(?:amp|#0*38|#x0*26);', '&', value.strip())
    if '\u002f' in address.lower() or '\/' in address:
        address = address.replace('\/', '/').replace('\u002f', '/').replace('\u002F', '/')
    if address.lower().startswith('base64://'):
        import base64
        try:
            b64_part = address[9:].strip()
            b64_part += '=' * ((4 - len(b64_part) % 4) % 4)
            dec = base64.b64decode(b64_part).decode('utf-8', errors='ignore').strip()
            if dec.lower().startswith(('http://', 'https://', '//')):
                address = dec
        except Exception:
            pass
    elif (address.startswith(('aHR0cHM6Ly', 'aHR0cDovL')) and
          re.fullmatch(r'[A-Za-z0-9+/=_-]{16,4096}', address)):
        import base64
        try:
            padded = address + '=' * ((4 - len(address) % 4) % 4)
            dec = (base64.urlsafe_b64decode(padded) if ('-' in address or '_' in address) else base64.b64decode(padded)).decode('utf-8', errors='ignore').strip()
            if dec.lower().startswith(('http://', 'https://')):
                address = dec
        except Exception:
            pass
    if address.startswith('//'):
        address = 'https:' + address
    if ' ' in address and address.lower().startswith(('http://', 'https://')):
        address = address.replace(' ', '%20')
    return address


def enabled(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value > 0
    return str(value or '').strip().lower() in ('1', 'true', 'yes', 'on')


def media_headers(value):
    if isinstance(value, str):
        parsed = {}
        if len(value) > 65536:
            return parsed
        for part in re.split(r'[\r\n#]+', value):
            name, separator, content = part.partition('$')
            if not separator:
                name, separator, content = part.partition(':')
            if separator and name.strip():
                parsed[name.strip()] = content.strip()
        value = parsed
    if not isinstance(value, dict):
        return {}
    result = {}
    for index, (key, content) in enumerate(value.items()):
        if index >= 256:
            break
        name, text = str(key), str(content)
        if (len(result) >= 64 or len(name) > 128 or len(text) > 16384 or
                not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or
                '\r' in text or '\n' in text or name.lower() in
                ('host', 'content-length', 'connection', 'transfer-encoding', 'keep-alive', 'upgrade')):
            continue
        result[name] = text
    return result


def media_choice_address(value):
    if not isinstance(value, dict):
        return ''
    return next((value.get(key) for key in
                 ('url', 'playUrl', 'playurl', 'play_url', 'videoUrl',
                  'video_url', 'mediaUrl', 'src', 'm3u8', 'mp4', 'flv',
                  'stream', 'streamUrl', 'stream_url', 'link', 'vurl',
                  'uri', 'file', 'value', 'v')
                 if value.get(key)), '')


def media_result_shape(value):
    """Describe protocol structure, never provider values or arbitrary keys."""
    def kind(item):
        return ('null' if item is None else 'object' if isinstance(item, dict) else
                'array' if isinstance(item, (list, tuple)) else 'string' if isinstance(item, str) else 'scalar')
    keys = ('url', 'playUrl', 'playurl', 'play_url', 'videoUrl', 'video_url',
            'mediaUrl', 'src', 'data', 'result', 'payload', 'response', 'alternates', 'parse', 'jx')
    fields = {'result_type': kind(value)}
    if not isinstance(value, dict):
        fields['validation_reason'] = 'unexpected_result_type'
        return fields
    fields['recognized_fields'] = ','.join(key for key in keys if key in value)
    address = next((value[key] for key in keys[:8] if value.get(key) not in (None, '')), None)
    fields['address_type'] = kind(address)
    fields['candidate_count'] = min(len(address), 32) if isinstance(address, (list, tuple)) else 0
    fields['validation_reason'] = ('missing_or_empty_address' if address is None else
                                   'unsupported_address_structure' if not isinstance(address, str) else
                                   'invalid_or_unsupported_address')
    return fields


def direct_episode_media_fallback(value, episode_id):
    """Use an episode ID directly only when the spider returned no result.

    Some Python Spider packages list an already playable media URL as the
    episode ID, then return None from playerContent. Do not override an
    explicit plugin error or a non-empty extraction result.
    """
    value = decoded(value)
    empty_result = value is None or value == ''
    if isinstance(value, dict):
        address_keys = ('url', 'playUrl', 'playurl', 'play_url', 'videoUrl',
                        'video_url', 'mediaUrl', 'src')
        nested_keys = ('data', 'result', 'payload', 'response')
        has_address = any(value.get(key) not in (None, '') for key in address_keys)
        has_nested = any(key in value for key in nested_keys)
        has_error = any(str(value.get(key) or '').strip()
                        for key in ('error', 'message', 'msg'))
        empty_result = not has_address and not has_nested and not has_error
    if not empty_result:
        return None
    address = normalize_media_address(episode_id if isinstance(episode_id, str) else '')
    if not valid_media_url(address):
        return None
    try:
        path = urllib.parse.urlsplit(address).path.lower()
    except ValueError:
        return None
    if not path.endswith(('.m3u8', '.m3u', '.mp4', '.m4v', '.mov',
                          '.m4a', '.mp3', '.aac', '.ts', '.mpd')):
        return None
    return playback({'url': address})


def playback(value, _depth=0):
    value = unwrap_envelope(value, {'url', 'playUrl', 'playurl', 'play_url', 'videoUrl',
                                    'video_url', 'mediaUrl', 'src', 'alternates',
                                    'parse', 'jx', 'headers', 'header', 'customHeaders', 'playerType',
                                    'proxy', 'error', 'message'})
    if isinstance(value, str):
        value = {'url': value}
    elif isinstance(value, list):
        value = {'url': value}
    if not isinstance(value, dict):
        raise MediaError('NO_MEDIA', '来源未返回播放结果')
    if not any(value.get(key) not in (None, '') for key in
               ('url', 'playUrl', 'playurl', 'play_url', 'videoUrl', 'video_url', 'mediaUrl', 'src',
                'm3u8', 'mp4', 'flv', 'stream', 'streamUrl', 'stream_url', 'link', 'vurl', 'uri', 'file')):
        nested = next((value[key] for key in ('data', 'result', 'payload', 'response')
                       if key in value and value[key] is not None), None)
        if nested is not None:
            nested = decoded(nested)
            if isinstance(nested, dict):
                merged = dict(value)
                merged.update(nested)
                return playback(merged)
            if isinstance(nested, str):
                merged = dict(value, url=nested)
                return playback(merged)
            if isinstance(nested, list):
                merged = dict(value, url=nested)
                return playback(merged)
    transport_keys = ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'content_type',
                      'mimeType', 'mime', 'parse', 'jx', 'proxy', 'requiresWebPlayback', 'webPlayback')
    source_transport = {key: value[key] for key in transport_keys if key in value}
    headers = media_headers(value.get('header', {}))
    headers.update(media_headers(value.get('headers', {})))
    headers.update(media_headers(value.get('customHeaders', {})))
    url = next((value.get(key) for key in
                ('url', 'playUrl', 'playurl', 'play_url', 'videoUrl', 'video_url', 'mediaUrl', 'src',
                 'm3u8', 'mp4', 'flv', 'stream', 'streamUrl', 'stream_url', 'link', 'vurl', 'uri', 'file')
                if value.get(key) not in (None, '')), None)
    proxy_requested = enabled(value.get('proxy'))
    alternates = value.get('alternates', [])
    primary_choice_headers = {}
    if isinstance(url, dict):
        nested_headers = media_headers(url.get('header', {}))
        nested_headers.update(media_headers(url.get('headers', {})))
        nested_headers.update(media_headers(url.get('customHeaders', {})))
        headers.update(nested_headers)
        # Some spiders put transport metadata beside the nested media URL.
        # Keep it before replacing the object with its URL string.
        for key in ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'content_type',
                    'mimeType', 'mime', 'parse', 'jx', 'proxy', 'requiresWebPlayback', 'webPlayback'):
            if key not in value and key in url:
                value[key] = url[key]
        if 'proxy' in value:
            proxy_requested = enabled(value.get('proxy'))
        choices = url.get('values') or url.get('list')
        if isinstance(choices, list):
            choices = [item for item in choices if isinstance(item, dict) and
                       (valid_media_url(normalize_media_address(media_choice_address(item))) or
                        (enabled(value.get('proxy')) or enabled(item.get('proxy'))) and
                        valid_proxy_address(normalize_media_address(media_choice_address(item))))]
            first = choices[0] if choices else None
            if first:
                for key in ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'content_type',
                            'mimeType', 'mime', 'parse', 'jx', 'requiresWebPlayback', 'webPlayback'):
                    if key not in value and key in first:
                        value[key] = first[key]
                if 'proxy' not in value and 'proxy' in first:
                    value['proxy'] = first['proxy']
                    proxy_requested = enabled(first['proxy'])
                first_headers = media_headers(first.get('header', {}))
                first_headers.update(media_headers(first.get('headers', {})))
                first_headers.update(media_headers(first.get('customHeaders', {})))
                primary_choice_headers.update(first_headers)
            url = choices
        else:
            url = media_choice_address(url)
    if isinstance(url, list):
        if url and all(isinstance(item, dict) for item in url):
            url = [item for item in url if valid_media_url(
                normalize_media_address(media_choice_address(item))) or
                (enabled(value.get('proxy')) or enabled(item.get('proxy'))) and
                valid_proxy_address(normalize_media_address(media_choice_address(item)))]
            if not url:
                raise MediaError('NO_MEDIA', '来源的播放线路均未返回有效 HTTP/HTTPS 地址')
            alternates = []
            first = url[0]
            if 'proxy' not in value and 'proxy' in first:
                value['proxy'] = first['proxy']
                proxy_requested = enabled(first['proxy'])
            for key in ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'content_type',
                        'mimeType', 'mime', 'parse', 'jx', 'requiresWebPlayback', 'webPlayback'):
                if key not in value and key in first:
                    value[key] = first[key]
            first_headers = media_headers(first.get('header', {}))
            first_headers.update(media_headers(first.get('headers', {})))
            first_headers.update(media_headers(first.get('customHeaders', {})))
            primary_choice_headers.update(first_headers)
            for index, item in enumerate(url):
                address = media_choice_address(item)
                if not address:
                    continue
                choice = {'name': str(item.get('name') or item.get('n') or item.get('quality') or f'线路 {index + 1}'),
                          'url': str(address)}
                if enabled(item.get('proxy')) or proxy_requested:
                    choice['proxy'] = True
                choice_headers = media_headers(item.get('header', {}))
                choice_headers.update(media_headers(item.get('headers', {})))
                choice_headers.update(media_headers(item.get('customHeaders', {})))
                if choice_headers:
                    choice['headers'] = choice_headers
                for key in ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'mimeType',
                            'mime', 'parse', 'jx', 'requiresWebPlayback'):
                    if item.get(key) is not None:
                        choice[key] = item[key]
                alternates.append(choice)
        else:
            strings = [normalize_media_address(str(item)) for item in url if item not in (None, '')]
            if len(strings) == 1 and (valid_media_url(strings[0]) or
                                      proxy_requested and valid_proxy_address(strings[0])):
                alternates = [{'name': '线路 1', 'url': strings[0]}]
            elif strings and all(valid_media_url(item) or
                                 proxy_requested and valid_proxy_address(item) for item in strings):
                alternates = [{'name': f'线路 {index + 1}', 'url': address}
                              for index, address in enumerate(strings)]
            elif strings and all('$' in item for item in strings):
                alternates = []
                for index, item in enumerate(strings):
                    name, _, address = item.partition('$')
                    if valid_media_url(address):
                        alternates.append({'name': name or f'线路 {index + 1}', 'url': address})
            else:
                alternates = [
                    {'name': str(url[i]), 'url': normalize_media_address(str(url[i + 1]))}
                    for i in range(0, len(url) - 1, 2)
                    if url[i + 1] not in (None, '')
                ]
        url = next(
            (
                cand
                for item in alternates
                if isinstance(item, dict)
                for cand in [normalize_media_address(media_choice_address(item))]
                if (valid_proxy_address(cand)
                    if (enabled(item.get('proxy')) or proxy_requested)
                    else valid_media_url(cand))
            ),
            alternates[0]['url'] if alternates else '',
        )
    base_headers = dict(headers)
    headers.update(primary_choice_headers)
    parse = 1 if enabled(value.get('parse')) else 0
    jx = 1 if enabled(value.get('jx')) else 0
    # Player pages commonly HTML-escape separators inside an m3u8 URL.
    # Decode only ampersand entities so signed query values and ordering stay intact.
    url = normalize_media_address(url)
    # A number of older Python spiders append ``format=.m3u8`` whenever the
    # full URL contains the text ``.m3u8`` but does not literally end with it.
    # For signed playlists this turns ``...?token=...`` into
    # ``...?token=...&format=.m3u8`` and can invalidate the source signature.
    # Repair only the unambiguous case: the URL path itself already ends in
    # .m3u8 and the spider explicitly identified the result as HLS.
    declared_format = str(value.get('format') or value.get('mediaType') or
                          value.get('playbackType') or '').strip().lower()
    declared_type = str(value.get('contentType') or value.get('content_type') or
                        value.get('mimeType') or value.get('mime') or '').strip().lower()
    declared_mime = declared_type.split(';', 1)[0].strip()
    hls_formats = {'hls', 'm3u8', 'm3u', 'mpegurl', 'application/vnd.apple.mpegurl',
                   'application/x-mpegurl', 'audio/mpegurl'}
    native_formats = hls_formats | {'mp4', 'm4v', 'mov', 'quicktime', 'mp3', 'm4a',
                                    'aac', 'ts', 'mpeg-ts', 'mpegts'}
    native_mimes = {'application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl',
                    'video/mp4', 'application/mp4', 'video/quicktime', 'audio/mp4',
                    'audio/mpeg', 'audio/aac', 'video/mp2t'}

    def repair_url(address):
        if not isinstance(address, str):
            return address
        address = normalize_media_address(address)
        if declared_format not in hls_formats and declared_mime not in hls_formats:
            return address
        try:
            parts = urllib.parse.urlsplit(address)
            if parts.path.lower().endswith('.m3u8'):
                query = re.sub(r'(?i)(?:^|&)format=\.m3u8$', '', parts.query)
                if query != parts.query:
                    address = urllib.parse.urlunsplit((parts.scheme, parts.netloc,
                                                       parts.path, query, parts.fragment))
        except ValueError:
            pass
        return address

    url = repair_url(url)
    if not (valid_proxy_address(url) if proxy_requested else valid_media_url(url)):
        message = value.get('error') or value.get('message') or value.get('msg')
        raise MediaError('NO_MEDIA', str(message or ('来源未返回有效本机代理地址' if proxy_requested else '来源未返回有效 HTTP/HTTPS 媒体地址'))[:512])
    safe_alternates = []
    if isinstance(alternates, list):
        for index, item in enumerate(alternates[:32]):
            if not isinstance(item, dict):
                continue
            candidate = normalize_media_address(media_choice_address(item))
            candidate = repair_url(candidate)
            item_proxy = enabled(item.get('proxy')) or proxy_requested
            if valid_media_url(candidate) or item_proxy and valid_proxy_address(candidate):
                choice = {'name': str(item.get('name') or item.get('n') or item.get('quality') or f'线路 {index + 1}')[:128], 'url': candidate}
                choice_headers = media_headers(item.get('header', {}))
                choice_headers.update(media_headers(item.get('headers', {})))
                choice_headers.update(media_headers(item.get('customHeaders', {})))
                if choice_headers:
                    choice['headers'] = choice_headers
                for key in ('format', 'mediaType', 'playbackType', 'playerType', 'contentType', 'mimeType',
                            'mime', 'parse', 'jx', 'proxy', 'requiresWebPlayback'):
                    if item.get(key) is not None:
                        choice[key] = item[key]
                transport = dict(source_transport)
                transport.update({key: item[key] for key in transport_keys if key in item})
                if item_proxy:
                    transport['proxy'] = True
                if _depth == 0:
                    transport['url'] = candidate
                    normalized = playback(transport, _depth=_depth + 1)
                    for key in ('format', 'contentType', 'parse', 'jx', 'requiresWebPlayback',
                                'directMedia', 'nativePlayable', 'proxy'):
                        if key in normalized:
                            choice[key] = normalized[key]
                safe_alternates.append(choice)
    try:
        extension = urllib.parse.urlsplit(url).path.rsplit('.', 1)[-1].lower() if '.' in urllib.parse.urlsplit(url).path else ''
    except ValueError:
        extension = ''
    if not extension and isinstance(url, str) and url:
        lower_url = url.lower()
        if '.m3u8' in lower_url or '/hls/' in lower_url or '/m3u8/' in lower_url or any(k in lower_url for k in ('type=m3u8', 'format=m3u8', 'ctype=m3u8', 'ext=m3u8', 'playtype=m3u8')):
            extension = 'm3u8'
        elif '.mp4' in lower_url or 'ext=mp4' in lower_url or 'type=mp4' in lower_url or 'mime=video' in lower_url:
            extension = 'mp4'
        elif '.flv' in lower_url or 'type=flv' in lower_url:
            extension = 'flv'
        elif '.mpd' in lower_url or 'format=mpd' in lower_url:
            extension = 'mpd'
        elif '.mkv' in lower_url:
            extension = 'mkv'
        elif '.ts' in lower_url:
            extension = 'ts'
    native_extensions = {'m3u8', 'm3u', 'mp4', 'm4v', 'mov', 'mp3', 'm4a', 'aac', 'ts', 'fmp4', 'cmaf', 'm4s', 'f4v', 'wav', 'flac', 'ac3', 'eac3'}
    stream_extensions = native_extensions | {'mpd', 'flv', 'mkv', 'avi', 'webm', 'wmv', 'rmvb'}
    cicada_extensions = {'mpd', 'flv', 'mkv', 'avi', 'webm', 'wmv', 'asf', 'rmvb', 'rm', 'mpg', 'mpeg', 'm2ts', '3gp'}
    cicada_formats = cicada_extensions | {'dash', 'mpeg-dash', 'matroska', 'application/dash+xml'}
    cicada_mimes = {'application/dash+xml', 'application/vnd.ms-sstr+xml', 'video/x-flv',
                    'video/x-matroska', 'video/webm', 'video/x-msvideo', 'video/x-ms-wmv'}
    declared_player = str(value.get('playerType') or '').strip().lower()
    app_player_hint = (declared_player in ('app', 'native', 'avplayer', 'cicada', 'system') and
                       not enabled(value.get('requiresWebPlayback')) and
                       not enabled(value.get('webPlayback')) and
                       not parse and not jx)
    cicada_media = (extension in cicada_extensions or declared_format in cicada_formats or
                    declared_mime in cicada_mimes)
    native_media = (extension in native_extensions or declared_format in native_formats or
                    declared_mime in native_mimes or (app_player_hint and not cicada_media))
    direct_media = (native_media or cicada_media or app_player_hint or extension in stream_extensions or
                    declared_format in native_formats | {'mpd', 'dash', 'flv', 'mkv', 'avi', 'webm', 'wmv', 'rmvb'} or
                    declared_mime.startswith(('video/', 'audio/')))
    requires_web = bool(enabled(value.get('requiresWebPlayback')) or
                        enabled(value.get('webPlayback')) or parse or jx)
    if native_media or cicada_media:
        # Legacy spiders often leave parser flags on direct media. An explicit
        # HLS/MP4 or Cicada-supported format must reach the native decoder.
        requires_web = False
    result = {'url': url, 'headers': media_headers(headers), 'baseHeaders': media_headers(base_headers),
              'alternates': safe_alternates,
              'parse': parse, 'jx': jx, 'playUrl': value.get('playUrl', '') if isinstance(value.get('playUrl', ''), str) else '',
              'directMedia': direct_media, 'nativePlayable': native_media,
              'requiresWebPlayback': requires_web}
    if proxy_requested:
        result['proxy'] = True
    if declared_format:
        result['format'] = declared_format[:64]
    if declared_type:
        result['contentType'] = declared_type[:128]
    if cicada_media:
        result['playbackEngine'] = 'cicada'
    for key in ('sessionID', 'expiresAt', 'refreshAfter', 'refreshInterval', 'isLive'):
        if key in value and isinstance(value[key], (str, int, float, bool)):
            result[key] = value[key]
    raw_drm_key = next((value.get(k) for k in ('drmKey', 'clearKey', 'cencKey', 'decryptionKey', 'key', 'ekey', 'drm')
                        if value.get(k) not in (None, '', False, True)), None)
    norm_drm_key = _normalize_drm_key(raw_drm_key)
    if not norm_drm_key and isinstance(url, str) and '#' in url:
        frag = urllib.parse.urlsplit(url).fragment
        for part in frag.split('&'):
            k_name, sep, k_val = part.partition('=')
            if sep and k_name.strip().lower() in ('key', 'drmkey', 'clearkey', 'cenckey'):
                norm_drm_key = _normalize_drm_key(urllib.parse.unquote(k_val))
                if norm_drm_key:
                    break
    if norm_drm_key:
        result['drmKey'] = norm_drm_key
        result['directMedia'] = True
        result['nativePlayable'] = True
        result['requiresWebPlayback'] = False
    raw_lic = next((value.get(k) for k in ('licenseUrl', 'drmLicenseUrl', 'keyUrl', 'license_url')
                    if isinstance(value.get(k), str) and value.get(k).strip()), '')
    if raw_lic and valid_media_url(normalize_media_address(raw_lic)):
        result['licenseUrl'] = normalize_media_address(raw_lic)
    raw_subs = value.get('subs') or value.get('subtitles')
    if isinstance(raw_subs, list):
        subs = []
        for sub in raw_subs[:16]:
            if isinstance(sub, dict):
                sub_url = normalize_media_address(str(sub.get('url') or sub.get('src') or ''))
                if valid_media_url(sub_url):
                    subs.append({
                        'name': str(sub.get('name') or sub.get('title') or sub.get('lang') or '字幕')[:64],
                        'url': sub_url,
                        'lang': str(sub.get('lang') or '')[:32],
                        'format': str(sub.get('format') or sub.get('mime') or '')[:32],
                    })
        if subs:
            result['subtitles'] = subs
    danmaku_url = value.get('danmaku') or value.get('danmu')
    if isinstance(danmaku_url, str):
        norm_dm = normalize_media_address(danmaku_url)
        if valid_media_url(norm_dm):
            result['danmaku'] = norm_dm
    return result


def _repair_mp4_stsd_walker(module):
    """Adapt the bundled HGTV-style stsd walker when it is passed the fullbox header.

    Some single-file spiders call `_walk_stsd` at the start of the `stsd`
    payload, which still contains the 4-byte version/flags and 4-byte entry
    count. Their walker expects the first sample-entry box. Detect this exact
    call pattern and skip that header before delegating to the source helper.
    """
    if getattr(module, '_cctvhost_stsd_compat_applied', False):
        return True
    walker = getattr(module, '_walk_stsd', None)
    collector = getattr(module, 'collect_patches', None)
    if not (callable(walker) and callable(collector) and
            callable(getattr(module, '_boxes', None)) and
            callable(getattr(module, 'decrypt_moov_bytes', None))):
        return False
    try:
        collector_source = inspect.getsource(collector)
    except (OSError, TypeError):
        return False
    if not re.search(r'_walk_stsd\s*\(\s*d\s*,\s*cs\s*,\s*be\s*,\s*out\s*\)',
                     collector_source):
        return False

    def walk_stsd(data, start, end, out):
        count = int.from_bytes(data[start + 4:start + 8], 'big') if start + 8 <= end else 0
        if (start + 8 <= end and data[start:start + 4] == b'\x00\x00\x00\x00' and
                0 < count <= (end - start - 8) // 8):
            start += 8
        return walker(data, start, end, out)

    walk_stsd.__name__ = getattr(walker, '__name__', '_walk_stsd')
    walk_stsd.__doc__ = getattr(walker, '__doc__', None)
    module._walk_stsd = walk_stsd
    module._cctvhost_stsd_compat_applied = True
    return True


class PythonSpider:
    def __init__(self, root, entry, options=None, proxy_url='', data_dir=''):
        prepare_started_at = time.perf_counter()
        prepare_stage = 'module_import'
        owner = getattr(threading.current_thread(), '_host_session', None)
        self.service_identifier = str(getattr(owner, 'identifier', ''))
        self.root = os.path.realpath(root)
        path = os.path.realpath(os.path.join(self.root, entry))
        if os.path.commonpath([self.root, path]) != self.root or not path.endswith('.py'):
            raise MediaError('INVALID_ENTRY', 'Python 入口超出资源目录或不是 .py 文件')
        self.added_path = self.root not in sys.path
        if self.added_path:
            sys.path.insert(0, self.root)
        self.namespace = '_cctvhost_spider_' + uuid.uuid4().hex
        self.local_proxy_servers = set()
        namespace = types.ModuleType(self.namespace)
        namespace.__path__ = [self.root]
        sys.modules[self.namespace] = namespace
        self._plugin_builtins = dict(vars(builtins))
        original_import = builtins.__import__

        def import_local(name, globals=None, locals=None, fromlist=(), level=0):
            if level == 0 and isinstance(name, str) and name:
                local_name = self._load_local_module(name)
                if local_name:
                    module = sys.modules[local_name]
                    if fromlist:
                        for child in fromlist:
                            if child == '*' or hasattr(module, child):
                                continue
                            self._load_local_module(name + '.' + child)
                        return module
                    return sys.modules[self.namespace]
            return original_import(name, globals, locals, fromlist, level)

        self._plugin_builtins['__import__'] = import_local
        relative = os.path.relpath(path, self.root)[:-3].replace(os.sep, '.')
        parent_relative = relative.rpartition('.')[0]
        if parent_relative:
            parent_parts = parent_relative.split('.')
            for index in range(1, len(parent_parts) + 1):
                package_name = '.'.join(parent_parts[:index])
                qualified_package = self.namespace + '.' + package_name
                if qualified_package in sys.modules:
                    continue
                self._load_local_module(package_name)
                if qualified_package not in sys.modules:
                    package_path = os.path.realpath(os.path.join(self.root, package_name.replace('.', os.sep)))
                    if os.path.commonpath([self.root, package_path]) == self.root and os.path.isdir(package_path):
                        package = types.ModuleType(qualified_package)
                        package.__path__ = [package_path]
                        package.__package__ = qualified_package
                        package.__builtins__ = self._plugin_builtins
                        sys.modules[qualified_package] = package
                        parent = sys.modules.get(qualified_package.rpartition('.')[0])
                        if parent:
                            setattr(parent, package_name.rpartition('.')[2], package)
        name = self.namespace + '.' + relative
        spec = importlib.util.spec_from_file_location(name, path)
        if not spec or not spec.loader:
            raise MediaError('INVALID_ENTRY', '无法加载 Python Spider')
        self.module_name = name
        module = importlib.util.module_from_spec(spec)
        module.__dict__['__builtins__'] = self._plugin_builtins
        sys.modules[name] = module
        _python_spider_log_stage('python_spider_prepare_started', entry, prepare_started_at)
        try:
            _install_python_spider_compatibility()
            spec.loader.exec_module(module)
            _repair_mp4_stsd_walker(module)
            _python_spider_log_stage('python_spider_module_loaded', entry, prepare_started_at)
            cls = getattr(module, 'Spider', None)
            if not callable(cls):
                raise MediaError('INVALID_PROTOCOL', '文件未提供 Spider 类；HTTP 服务脚本请按服务方式运行')
            prepare_stage = 'spider_constructor'
            _python_spider_log_stage('python_spider_constructor_started', entry, prepare_started_at)
            self.spider = cls()
            self.spider._cctvhost_proxy_url = proxy_url
            self.spider._cctvhost_data_dir = os.path.realpath(data_dir) if data_dir else ''
            try:
                self._source_text = Path(path).read_text(encoding='utf-8', errors='ignore')
            except Exception:
                self._source_text = ''
            self._is_tvbox_spider = (
                ('base.spider' in self._source_text or 'BaseSpider' in self._source_text) and
                not any(tok in self._source_text for tok in ('.test', '.example', '127.0.0.1'))
            )
            self._cms_fallback = None
            self._last_detail_title = ''
            self._episode_map = {}
            self.lock = threading.Lock()
            self.proxy_lock_timeout = 120.0
            # Python Spider implementations are not generally thread-safe, so
            # calls stay serialized. Give a request already in progress time to
            # finish instead of turning ordinary home -> detail navigation into
            # an almost immediate HTTP 503 BUSY response.
            self.lock_timeout = 25.0
            if callable(getattr(self.spider, 'init', None)):
                prepare_stage = 'spider_init'
                init_started_at = time.perf_counter()
                _python_spider_log_stage('python_spider_init_started', entry, init_started_at)
                init_options = (options if isinstance(options, str) else
                                (json.dumps(options, ensure_ascii=False) if options is not None else ''))
                self.spider.init(init_options)
                _python_spider_log_stage('python_spider_init_succeeded', entry, init_started_at)
            self._capture_plugin_loopback_servers()
            _python_spider_log_stage('python_spider_ready', entry, prepare_started_at)
        except BaseException as error:
            self._capture_plugin_loopback_servers()
            self._stop_plugin_loopback_servers()
            _python_spider_log_stage('python_spider_prepare_failed', entry, prepare_started_at,
                                     stage=prepare_stage, error_type=type(error).__name__)
            self._remove_package_modules()
            if self.added_path and self.root in sys.path:
                sys.path.remove(self.root)
            raise

    def _load_local_module(self, name):
        qualified = self.namespace + '.' + name
        if qualified in sys.modules:
            return qualified
        parent_name, _, child_name = name.rpartition('.')
        if parent_name and not self._load_local_module(parent_name):
            parent_dir = os.path.realpath(os.path.join(self.root, parent_name.replace('.', os.sep)))
            if os.path.commonpath([self.root, parent_dir]) != self.root or not os.path.isdir(parent_dir):
                return None
            parent_qualified = self.namespace + '.' + parent_name
            parent_module = types.ModuleType(parent_qualified)
            parent_module.__path__ = [parent_dir]
            parent_module.__package__ = parent_qualified
            parent_module.__builtins__ = self._plugin_builtins
            sys.modules[parent_qualified] = parent_module
        relative = name.replace('.', os.sep)
        module_path = os.path.realpath(os.path.join(self.root, relative + '.py'))
        package_path = os.path.realpath(os.path.join(self.root, relative, '__init__.py'))
        is_package = False
        if os.path.commonpath([self.root, module_path]) == self.root and os.path.isfile(module_path):
            selected_path = module_path
        elif os.path.commonpath([self.root, package_path]) == self.root and os.path.isfile(package_path):
            selected_path = package_path
            is_package = True
        else:
            return None
        spec = importlib.util.spec_from_file_location(qualified, selected_path,
                    submodule_search_locations=[os.path.dirname(selected_path)] if is_package else None)
        if not spec or not spec.loader:
            return None
        module = importlib.util.module_from_spec(spec)
        module.__dict__['__builtins__'] = self._plugin_builtins
        sys.modules[qualified] = module
        qualified_parent, _, qualified_child = qualified.rpartition('.')
        parent = sys.modules.get(qualified_parent)
        if parent is not None and qualified_child:
            setattr(parent, qualified_child, module)
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(qualified, None)
            raise
        return qualified

    def _remove_package_modules(self):
        for module_name, loaded in list(sys.modules.items()):
            if module_name == self.namespace or module_name.startswith(self.namespace + '.'):
                sys.modules.pop(module_name, None)

    def _capture_plugin_loopback_servers(self):
        """Track loopback HTTP servers created by this Spider for playback."""
        for thread in threading.enumerate():
            target = getattr(thread, '_target', None)
            server = getattr(target, '__self__', None)
            if server is None or not callable(getattr(server, 'shutdown', None)) or not callable(getattr(server, 'server_close', None)):
                continue
            address = getattr(server, 'server_address', None)
            host = str(address[0]).strip('[]').lower() if isinstance(address, tuple) and address else ''
            if host not in ('127.0.0.1', '::1', 'localhost'):
                continue
            handler = getattr(server, 'RequestHandlerClass', None)
            module = str(getattr(handler, '__module__', ''))
            if module == self.namespace or module.startswith(self.namespace + '.'):
                self.local_proxy_servers.add(server)

    def _stop_plugin_loopback_servers(self):
        servers = tuple(self.local_proxy_servers)
        self.local_proxy_servers.clear()
        for server in servers:
            def shutdown(target=server):
                try:
                    target.shutdown()
                except Exception:
                    pass
                try:
                    target.server_close()
                except Exception:
                    pass
            stopper = threading.Thread(target=shutdown, name='cctvhost-spider-proxy-stop', daemon=True)
            stopper.start()
            stopper.join(timeout=1.0)

    def capabilities(self):
        methods = {'home': 'homeContent', 'category': 'categoryContent', 'search': 'searchContent',
                   'detail': 'detailContent', 'play': 'playerContent', 'proxy': 'localProxy'}
        return {'engine': 'CPython', 'protocol': 'python-spider',
                'capabilities': [key for key, method in methods.items() if callable(getattr(self.spider, method, None))]}

    def call(self, operation, args):
        wait_started = time.perf_counter()
        lock_timeout = max(.1, float(getattr(self, 'lock_timeout', 12.0)))
        if operation == 'proxy':
            try:
                proxy_lock_timeout = float(getattr(self, 'proxy_lock_timeout', 120.0))
            except (TypeError, ValueError):
                proxy_lock_timeout = 120.0
            lock_timeout = min(120.0, max(lock_timeout, proxy_lock_timeout))
        acquired = self.lock.acquire(timeout=lock_timeout)
        wait_ms = max(0, int((time.perf_counter() - wait_started) * 1000))
        request = getattr(threading.current_thread(), '_host_media_request_context', {})
        if wait_ms >= 100 or not acquired:
            record = {'event': 'python_spider_request_busy' if not acquired else 'python_spider_request_queued',
                      'operation': str(operation or 'unknown')[:48], 'wait_ms': wait_ms,
                      'service_id': self.service_identifier}
            if not acquired:
                record['wait_timeout_ms'] = int(lock_timeout * 1000)
            for key in ('request_id', 'correlation_id'):
                value = request.get(key) if isinstance(request, dict) else None
                if isinstance(value, str) and value:
                    record[key] = value[:96]
            try:
                print('[CCTVHostMediaAPI] ' + json.dumps(record, ensure_ascii=False, separators=(',', ':')))
            except Exception:
                pass
        if not acquired:
            raise MediaError('BUSY', '影视来源请求排队超时（%g 秒），请重试' % lock_timeout, True)
        try:
            spider = self.spider
            if operation == 'home':
                try:
                    result = decoded(spider.homeContent(True))
                except Exception:
                    if not self._is_tvbox_spider:
                        raise
                    result = {}
                if not isinstance(result, dict):
                    result = {}
                if not rows(result) and callable(getattr(spider, 'homeVideoContent', None)):
                    try:
                        result = dict(result, list=rows(spider.homeVideoContent()))
                    except Exception:
                        if not self._is_tvbox_spider:
                            raise
                if self._is_tvbox_spider and not rows(result):
                    cats = result.get('class') or result.get('categories') or []
                    if isinstance(cats, list) and cats and isinstance(cats[0], dict):
                        first_tid = str(cats[0].get('type_id') or cats[0].get('id') or '1')
                        try:
                            cat_res = decoded(spider.categoryContent(first_tid, '1', True, {}))
                            if rows(cat_res):
                                result = dict(result, list=rows(cat_res))
                        except Exception:
                            pass
                    if not rows(result):
                        fb = self._get_cms_fallback().homeContent(True)
                        fb_items = [dict(r, vod_id='maccms:' + str(r.get('vod_id', ''))) for r in rows(fb) if isinstance(r, dict)]
                        result = {'class': result.get('class') or fb.get('class') or [], 'list': fb_items}
                return result
            if operation == 'category':
                tid = str(args.get('categoryId', ''))
                pg = str(args.get('page', 1))
                try:
                    res = decoded(spider.categoryContent(tid, pg, True, args.get('filters') or {}))
                except Exception:
                    if not self._is_tvbox_spider:
                        raise
                    res = {}
                if self._is_tvbox_spider and not rows(res):
                    fb_tid = tid if tid.isdigit() else '1'
                    fb = self._get_cms_fallback().categoryContent(fb_tid, pg, True, {})
                    res = {'list': [dict(r, vod_id='maccms:' + str(r.get('vod_id', ''))) for r in rows(fb) if isinstance(r, dict)], 'page': int(pg)}
                return res
            if operation == 'search':
                fn = spider.searchContent
                arity = getattr(self, '_search_arity', None)
                if arity is None or getattr(self, '_search_fn', None) is not fn:
                    try:
                        arity = len(inspect.signature(fn).parameters)
                    except (TypeError, ValueError):
                        arity = 2
                    self._search_fn = fn
                    self._search_arity = arity
                try:
                    if arity >= 3:
                        res = decoded(fn(str(args.get('keyword', '')), False, str(args.get('page', 1))))
                    else:
                        res = decoded(fn(str(args.get('keyword', '')), False))
                except Exception:
                    if not self._is_tvbox_spider:
                        raise
                    res = {}
                if self._is_tvbox_spider and not rows(res):
                    fb = self._get_cms_fallback().searchContent(str(args.get('keyword', '')), False, str(args.get('page', 1)))
                    res = {'list': [dict(r, vod_id='maccms:' + str(r.get('vod_id', ''))) for r in rows(fb) if isinstance(r, dict)]}
                return res
            if operation == 'detail':
                vid = str(args.get('id', ''))
                if self._is_tvbox_spider and vid.startswith('maccms:'):
                    res = self._get_cms_fallback().detailContent([vid[7:]])
                else:
                    try:
                        res = decoded(spider.detailContent([vid]))
                    except Exception:
                        if not self._is_tvbox_spider:
                            raise
                        res = {}
                    if self._is_tvbox_spider and not rows(res):
                        res = self._get_cms_fallback().detailContent([vid])
                if self._is_tvbox_spider:
                    self._record_detail_episodes(res)
                return res
            if operation == 'play':
                line_id = str(args.get('lineId', ''))
                ep_id = str(args.get('id', ''))
                try:
                    result = decoded(spider.playerContent(line_id, ep_id, []))
                except Exception:
                    if not self._is_tvbox_spider:
                        raise
                    result = {'parse': 1, 'url': ep_id}
                if self._is_tvbox_spider:
                    result = self._upgrade_tvbox_play_result(result, ep_id)
                # Some spiders return the episode HTML page with parse=0 when
                # extraction fails. Never label that page as decoded media.
                if isinstance(result, dict):
                    address = result.get('url')
                    path = urllib.parse.urlsplit(address).path.lower() if isinstance(address, str) else ''
                    episode_page = (address == str(args.get('id', '')) and
                                    re.fullmatch(r'/[0-9]+/[0-9]+/[0-9]+/?', path) is not None and
                                    str(result.get('format', '')).lower() == 'mp4')
                    if path.endswith(('.html', '.htm')) or episode_page:
                        result = dict(result, parse=1, requiresWebPlayback=True)
                        result.pop('format', None)
                        result.pop('contentType', None)
                return result
            if operation == 'proxy':
                return spider.localProxy(args)
            raise MediaError('UNSUPPORTED', '此来源不支持该操作')
        finally:
            self._capture_plugin_loopback_servers()
            self.lock.release()


    def _get_cms_fallback(self):
        if self._cms_fallback is None:
            csp_adapter = _load_csp_adapter()
            self._cms_fallback = csp_adapter.AppVideoEngine('csp_AppRJ', '')
        return self._cms_fallback

    def _record_detail_episodes(self, raw_detail):
        try:
            items = rows(raw_detail)
            item = items[0] if items and isinstance(items[0], dict) else (raw_detail if isinstance(raw_detail, dict) else {})
            title = str(item.get('vod_name') or item.get('name') or '').strip()
            if title:
                self._last_detail_title = title
            play_url = item.get('vod_play_url')
            groups = play_url if isinstance(play_url, list) else str(play_url or '').split('$$$')
            for g in groups:
                for idx, ep in enumerate(str(g).split('#')):
                    if not ep:
                        continue
                    label, sep, eid = ep.partition('$')
                    ep_id = (eid if sep else label).strip()
                    ep_name = (label if sep else f'第{idx+1}集').strip()
                    if ep_id:
                        self._episode_map[ep_id] = (title or self._last_detail_title, idx, ep_name)
        except Exception:
            pass

    def _upgrade_tvbox_play_result(self, result, ep_id):
        try:
            csp_adapter = _load_csp_adapter()
            url = ''
            if isinstance(result, dict):
                url = str(media_choice_address(result) or '').strip()
            elif isinstance(result, str):
                url = result.strip()
            if not url and ep_id.startswith(('http://', 'https://')):
                url = ep_id
            low = url.lower()
            parsed = urllib.parse.urlsplit(url) if url else None
            path_low = parsed.path.lower() if parsed else ''
            query_low = parsed.query.lower() if parsed else ''
            is_dead_cdn = any(dead in low for dead in ('lzcdn', 'lzfile', 'lfthirtytwo'))
            is_wrapper = 'url=http' in query_low or 'v=http' in query_low or 'xmflv.com' in low
            is_direct = (
                not is_dead_cdn and not is_wrapper and
                any(tok in path_low for tok in ('.m3u8', '.mp4', '.flv', '.mpd'))
            )
            if ('127.0.0.1' in low or 'localhost' in low) and not is_direct:
                try:
                    import requests
                    probe = requests.get(url, timeout=2.5, stream=True)
                    probe_ok = 200 <= probe.status_code < 400
                    probe.close()
                    if probe_ok:
                        return result
                except Exception:
                    pass
                # Rescue broken loopback HGTV proxy (e.g. 127.0.0.1:9990/?vid=... returning 502)
                try:
                    qs = urllib.parse.parse_qs(parsed.query if parsed else '')
                    hg_vid = (qs.get('vid') or [''])[0] or (re.findall(r'/play/(\d{15,24})', path_low) or [''])[0]
                    if not hg_vid and re.fullmatch(r'\d{15,24}', str(ep_id).split('~')[-1]):
                        hg_vid = str(ep_id).split('~')[-1]
                    if hg_vid and re.fullmatch(r'\d{15,24}', str(hg_vid)):
                        builtin_hg = Path(__file__).resolve().parent.parent / 'Resources/BuiltinMedia/hongguo-python.py'
                        if builtin_hg.is_file():
                            spec = importlib.util.spec_from_file_location('_cctvhost_builtin_hg_rescue', str(builtin_hg))
                            mod = importlib.util.module_from_spec(spec)
                            spec.loader.exec_module(mod)
                            dec_url, ref, _ = mod.resolve_signed('', str(hg_vid), False, host_proxy=False)
                            if dec_url:
                                return {'parse': 0, 'jx': 0, 'url': dec_url, 'format': 'mp4', 'contentType': 'video/mp4',
                                        'header': {'User-Agent': 'Mozilla/5.0', 'Referer': ref or 'https://hongguoduanju.com/'}}
                except Exception:
                    pass
            if is_direct:
                return result
            vip_domains = ('mgtv.com', 'qq.com', 'iqiyi.com', 'youku.com', 'bilibili.com', 'sohu.com', 'le.com', 'xmflv.com')
            if url.startswith(('http://', 'https://')) and not any(d in low for d in vip_domains) and '127.0.0.1' not in low and not is_dead_cdn:
                try:
                    import requests
                    resp = requests.get(url, headers={'User-Agent': 'Mozilla/5.0'}, timeout=5)
                    sniffed = csp_adapter._extract_stream_from_html(resp.text, base_url=url)
                    if sniffed and not any(dead in sniffed.lower() for dead in ('lzcdn', 'lzfile', 'lfthirtytwo')):
                        return {'parse': 0, 'jx': 0, 'url': sniffed, 'header': {'User-Agent': 'Mozilla/5.0'}}
                except Exception:
                    pass
            title, ep_idx, ep_name = self._episode_map.get(ep_id, (self._last_detail_title, 0, ''))
            if title:
                resolved = csp_adapter.resolve_maccms_stream_by_title(title, episode_index=ep_idx, episode_name=ep_name)
                if resolved:
                    return {'parse': 0, 'jx': 0, 'url': resolved, 'header': {'User-Agent': 'Mozilla/5.0'}}
        except Exception:
            pass
        return result

    def close(self):
        with self.lock:
            try:
                callback = getattr(self.spider, 'destroy', None)
                if callable(callback):
                    callback()
            finally:
                self._capture_plugin_loopback_servers()
                self._stop_plugin_loopback_servers()
                self._remove_package_modules()
                if self.added_path and self.root in sys.path:
                    sys.path.remove(self.root)


def _install_python_spider_compatibility():
    """Adapt common Android-TVBox Python parser imports to bundled pure Python."""
    try:
        import bs4
    except ImportError:
        return
    current = bs4.BeautifulSoup
    if getattr(current, '_cctvhost_lxml_alias', False):
        return

    class CompatibleBeautifulSoup(current):
        _cctvhost_lxml_alias = True

        def __init__(self, markup="", features=None, *args, **kwargs):
            if features in ('lxml', 'lxml-html'):
                features = 'html.parser'
            elif features == 'lxml-xml':
                features = 'xml'
            if features is None:
                features = 'html.parser'
            super().__init__(markup, features, *args, **kwargs)

    CompatibleBeautifulSoup.__name__ = current.__name__
    CompatibleBeautifulSoup.__qualname__ = current.__qualname__
    bs4.BeautifulSoup = CompatibleBeautifulSoup


class NativeJS:
    def __init__(self, root, manifest, node=False, bridge=None):
        self.bridge = bridge or getattr(builtins, '_cctvhost_node_call' if node else '_cctvhost_js_call', None)
        if not self.bridge:
            raise MediaError('RUNTIME_MISSING', '此版本未包含所需的本机 JS 运行时')
        self.session = uuid.uuid4().hex
        owner = getattr(threading.current_thread(), '_host_session', None)
        self.service_identifier = getattr(owner, 'identifier', '')
        try:
            self.metadata = self._call('start', packageRoot=os.path.realpath(root), **manifest)
        except BaseException:
            try:
                self._call('stop')
            except Exception:
                pass
            raise

    def _call(self, operation, **args):
        payload = dict(args, session=self.session)
        if self.service_identifier:
            payload['serviceID'] = self.service_identifier
        reply = decoded(self.bridge(operation, json.dumps(payload, ensure_ascii=False)))
        if not isinstance(reply, dict) or not reply.get('ok'):
            raise MediaError('PLUGIN_ERROR', str(reply.get('error', 'JS 执行失败')) if isinstance(reply, dict) else '无效 JS 桥接结果')
        return reply.get('result')

    def capabilities(self):
        return self.metadata

    def call(self, operation, args):
        return self._call(operation, **args)

    def close(self):
        return self._call('stop')


class _MediaFlight:
    def __init__(self):
        self.ready = threading.Event()
        self.value = None
        self.error = None


class MediaRuntime:
    def __init__(self, engine=None):
        self.engine = engine
        self.stopping = threading.Event()
        self._state_lock = threading.RLock()
        self._state = 'ready' if engine is not None else 'starting'
        self._startup_error = ''
        self._startup_thread = None
        self.cache = collections.OrderedDict()
        self.cache_lock = threading.Lock()
        self.inflight = {}
        self.cache_bytes = 0
        self.cache_generation = 0
        self.closed = False
        self._last_detail_title = ''
        self._episode_map = {}

    def start_initialization(self, factory, on_failure=None):
        """Prepare a plugin away from the listener thread so health stays responsive."""
        with self._state_lock:
            if self._state != 'starting' or self._startup_thread is not None:
                raise RuntimeError('media runtime initialization already started')
            # The embedded host associates threads with a service session. Keep
            # that association so nested plugin workers and JS bridge logs remain
            # scoped to the service that owns this media listener.
            owner = getattr(threading.current_thread(), '_host_session', None)

            def prepare():
                worker = threading.current_thread()
                if owner is not None:
                    worker._host_session = owner
                try:
                    try:
                        engine = factory()
                    except BaseException as error:
                        with self._state_lock:
                            stopped = self.stopping.is_set()
                            if not stopped:
                                self._state = 'failed'
                                self._startup_error = type(error).__name__
                        if not stopped and on_failure:
                            try:
                                on_failure(error)
                            except Exception:
                                pass
                        return
                    with self._state_lock:
                        if self.stopping.is_set():
                            close_engine = True
                        else:
                            self.engine = engine
                            self._state = 'ready'
                            close_engine = False
                    if close_engine:
                        try:
                            engine.close()
                        except Exception:
                            pass
                finally:
                    if owner is not None:
                        worker._host_session = None

            self._startup_thread = threading.Thread(target=prepare, name='media-runtime-prepare', daemon=True)
            self._startup_thread.start()

    def health_status(self):
        with self._state_lock:
            return {'runtime_ready': self._state == 'ready',
                    'runtime_state': self._state,
                    'startup_error': self._startup_error}

    def call(self, operation, args=None):
        if self.stopping.is_set():
            raise MediaError('STOPPING', '资源正在停止')
        with self._state_lock:
            state, engine, startup_error = self._state, self.engine, self._startup_error
        if state == 'failed':
            raise MediaError('STARTUP_FAILED',
                             '影视资源初始化失败（%s），请查看此资源日志' % (startup_error or '未知错误'))
        if state == 'starting' or engine is None:
            raise MediaError('BUSY', '影视资源脚本正在准备，请稍候', True)
        args = args or {}
        if operation == 'invalidate':
            with self.cache_lock:
                self.cache_generation += 1
                self.cache.clear()
                self.cache_bytes = 0
                flights = list(self.inflight.values())
                self.inflight.clear()
                for pending in flights:
                    pending.error = ('REFRESHED', '资源配置已变更，请重新加载', True)
                    pending.ready.set()
            return {'invalidated': True}
        if operation == 'capabilities':
            return engine.capabilities()
        key = json.dumps([operation, args], sort_keys=True, ensure_ascii=False)
        ttl = {'home': 120, 'category': 30, 'search': 20, 'detail': 120, 'catalog': 60}.get(operation, 0)
        flight = None
        owner = False
        if ttl:
            with self.cache_lock:
                cache_generation = self.cache_generation
                entry = self.cache.get(key)
                if entry and entry[0] > time.monotonic():
                    self.cache.move_to_end(key)
                    return json.loads(entry[1])
                flight = self.inflight.get(key)
                if flight is None:
                    flight = _MediaFlight()
                    self.inflight[key] = flight
                    owner = True
            if not owner:
                if not flight.ready.wait(45):
                    raise MediaError('BUSY', '相同资源请求仍在处理中，请稍后重试', True)
                if flight.error:
                    code, message, retryable = flight.error
                    raise MediaError(code, message, retryable)
                if flight.value is None:
                    raise MediaError('STOPPING', '资源正在停止')
                return json.loads(flight.value)
        try:
            raw = engine.call(operation, args)
            if operation in ('proxy', 'route'):
                return raw
            if operation == 'home':
                value = home(raw)
            elif operation in ('search', 'category'):
                value = listing(raw, args.get('page', 1))
            elif operation == 'detail':
                value = detail(raw, args.get('id', ''))
                try:
                    t = str(value.get('name') or '').strip()
                    if t:
                        self._last_detail_title = t
                    for ln in value.get('lines') or []:
                        if not isinstance(ln, dict):
                            continue
                        for idx, ep in enumerate(ln.get('episodes') or []):
                            if isinstance(ep, dict) and ep.get('id'):
                                self._episode_map[str(ep['id'])] = (t or self._last_detail_title, idx, str(ep.get('name') or ''))
                except Exception:
                    pass
            elif operation == 'play':
                try:
                    value = playback(raw)
                    play_u = str(value.get('url') or '').lower() if isinstance(value, dict) else ''
                    if play_u and any(d in play_u for d in ('youku.com', 'qq.com', 'iqiyi.com', 'mgtv.com', 'bilibili.com', 'xmflv.com', 'lzcdn', 'lzfile', 'lfthirtytwo')):
                        ep_key = str(args.get('id') or '')
                        title, ep_idx, ep_name = self._episode_map.get(ep_key, (self._last_detail_title, 0, ''))
                        if title:
                            csp_adapter = _load_csp_adapter()
                            rescued = csp_adapter.resolve_maccms_stream_by_title(title, episode_index=ep_idx, episode_name=ep_name)
                            if rescued:
                                value = playback({'parse': 0, 'jx': 0, 'url': rescued, 'header': {'User-Agent': 'Mozilla/5.0'}})
                except MediaError as error:
                    if error.code == 'NO_MEDIA':
                        fallback = direct_episode_media_fallback(raw, args.get('id', ''))
                        if fallback is not None:
                            context = getattr(threading.current_thread(), '_host_media_request_context', {})
                            trace = str(context.get('correlation_id') or context.get('request_id') or '')
                            if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', trace): trace = uuid.uuid4().hex
                            try:
                                print('[CCTVHostMediaResult] ' + json.dumps({
                                    'event': 'media_play_direct_episode_fallback',
                                    'request_id': trace,
                                    'stage': 'play_result_validation',
                                    'result_type': media_result_shape(raw)['result_type'],
                                    'address_type': 'direct_media_episode_id',
                                    'validation_reason': 'empty_spider_result',
                                    'media_extension': urllib.parse.urlsplit(fallback['url']).path.rsplit('.', 1)[-1].lower()[:8],
                                }, separators=(',', ':')))
                            except Exception:
                                pass
                            value = fallback
                        else:
                            context = getattr(threading.current_thread(), '_host_media_request_context', {})
                            trace = str(context.get('correlation_id') or context.get('request_id') or '')
                            if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', trace): trace = uuid.uuid4().hex
                            print('[CCTVHostMediaResult] ' + json.dumps(dict(
                                media_result_shape(raw), event='media_play_result_rejected',
                                request_id=trace, stage='play_result_validation'), separators=(',', ':')))
                            raise
                    else:
                        raise
            elif operation == 'providers':
                value = [{'id': str(row.get('id', row.get('key', ''))), 'name': str(row.get('name', row.get('title', ''))),
                          **({'searchable': row['searchable']} if isinstance(row.get('searchable'), bool) else {})}
                         for row in rows(raw) if isinstance(row, dict) and row.get('id', row.get('key')) is not None]
            elif operation == 'catalog':
                value = []
                for row in rows(raw):
                    if not isinstance(row, dict):
                        continue
                    identifier = row.get('id', row.get('ref'))
                    if identifier is None:
                        continue
                    value.append(dict(row, id=str(identifier), ref=str(row.get('ref', identifier)),
                                      name=str(row.get('name', identifier)), logo=str(row.get('logo') or ''), group=str(row.get('group') or '本机插件')))
            else:
                value = raw
            encoded = json.dumps(value, ensure_ascii=False).encode()
            if len(encoded) > 2 * 1024 * 1024:
                raise MediaError('RESULT_TOO_LARGE', '来源响应超过 2 MB')
            if self.stopping.is_set():
                raise MediaError('STOPPING', '资源正在停止')
        except BaseException as error:
            if owner:
                with self.cache_lock:
                    if self.inflight.get(key) is flight:
                        self.inflight.pop(key, None)
                    if not flight.ready.is_set():
                        flight.error = (error.code, str(error), error.retryable) if isinstance(error, MediaError) else ('PLUGIN_ERROR', str(error), False)
                        flight.ready.set()
            raise
        if ttl:
            with self.cache_lock:
                if self.cache_generation != cache_generation:
                    raise MediaError('REFRESHED', '资源配置已变更，请重新加载', True)
                if not self.stopping.is_set():
                    old = self.cache.pop(key, None)
                    if old:
                        self.cache_bytes -= len(old[1])
                    self.cache[key] = (time.monotonic() + ttl, encoded)
                    self.cache_bytes += len(encoded)
                    while len(self.cache) > 32 or self.cache_bytes > 8 * 1024 * 1024:
                        _, old = self.cache.popitem(last=False)
                        self.cache_bytes -= len(old[1])
                if self.inflight.get(key) is flight:
                    self.inflight.pop(key, None)
                if not flight.ready.is_set():
                    flight.value = encoded
                    flight.ready.set()
        return value

    def close(self):
        self.stopping.set()
        with self._state_lock:
            if self._state != 'failed':
                self._state = 'stopping'
            engine = self.engine
        with self.cache_lock:
            self.cache.clear()
            self.cache_bytes = 0
            flights = list(self.inflight.values())
            self.inflight.clear()
            for flight in flights:
                if not flight.ready.is_set():
                    flight.error = ('STOPPING', '资源正在停止', True)
                    flight.ready.set()
        if not self.closed:
            self.closed = True
            if engine is not None:
                engine.close()
