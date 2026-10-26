"""Small host base for conventional Python Spider packages.

Requests and BeautifulSoup are optional adapters; imported modules continue to
use their original Python code. Cache state is service-scoped and bounded.
"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request


_CACHE_LIMIT = 128
_PERSISTENT_CACHE_LIMIT = 32
_PERSISTENT_CACHE_BYTES = 64 * 1024
_PERSISTENT_CACHE_NAME = 'spider-cache.json'


def _persistent_url_key(key):
    """Persist only conventional, non-secret site base URL cache entries."""
    name = str(key or '').strip().lower()
    return (len(name) <= 128 and
            name.endswith(('_site_url', '_base_url', '_home_url', '_host_url')))


def _safe_base_url(value):
    if not isinstance(value, str) or not value or len(value) > 2048:
        return False
    try:
        parsed = urllib.parse.urlsplit(value.strip())
        parsed.port
        return (parsed.scheme.lower() in ('http', 'https') and bool(parsed.hostname)
                and not parsed.username and not parsed.password
                and not parsed.query and not parsed.fragment
                and '?' not in value and '#' not in value
                and not any(ord(char) <= 32 or ord(char) == 127 for char in value))
    except ValueError:
        return False


class _Response:
    def __init__(self, response):
        self.content = response.read(4 * 1024 * 1024 + 1)
        if len(self.content) > 4 * 1024 * 1024:
            raise ValueError('Spider 请求响应超过 4 MB')
        self.headers = dict(response.headers)
        self.status_code = response.status
        self.url = response.geturl()
        self.encoding = response.headers.get_content_charset() or 'utf-8'

    @property
    def text(self):
        return self.content.decode(self.encoding, errors='replace')

    def json(self):
        return json.loads(self.text)


class Spider:
    def __init__(self):
        self._host_cache = {}
        self._host_cache_lock = threading.Lock()
        self._host_persistent_cache = {}
        self._host_persistent_cache_loaded = False

    def _persistent_cache_path(self):
        data_dir = os.environ.get('CCTVHOST_DATA_DIR') or os.environ.get('YSP_DATA_DIR')
        if not data_dir:
            return None
        root = os.path.realpath(data_dir)
        if not os.path.isdir(root):
            return None
        return os.path.join(root, _PERSISTENT_CACHE_NAME)

    def _load_persistent_cache(self):
        if self._host_persistent_cache_loaded:
            return
        self._host_persistent_cache_loaded = True
        path = self._persistent_cache_path()
        if not path:
            return
        try:
            if os.path.getsize(path) > _PERSISTENT_CACHE_BYTES:
                return
            with open(path, 'r', encoding='utf-8') as handle:
                payload = json.load(handle)
            if not isinstance(payload, dict) or payload.get('version') != 1:
                return
            entries = payload.get('entries')
            if not isinstance(entries, dict):
                return
            now = time.time()
            monotonic_now = time.monotonic()
            for key, row in list(entries.items())[:_PERSISTENT_CACHE_LIMIT]:
                if not _persistent_url_key(key) or not isinstance(row, dict):
                    continue
                value = row.get('value')
                try:
                    expires_at = float(row.get('expires_at', 0))
                    remaining = expires_at - now
                except (TypeError, ValueError):
                    continue
                if remaining <= 0 or not _safe_base_url(value):
                    continue
                self._host_persistent_cache[key] = (expires_at, value)
                self._host_cache[key] = (monotonic_now + remaining, value)
        except (OSError, UnicodeError, ValueError, TypeError):
            return

    def _save_persistent_cache(self):
        path = self._persistent_cache_path()
        if not path:
            return
        now = time.time()
        self._host_persistent_cache = {
            key: row for key, row in self._host_persistent_cache.items()
            if (now < row[0] and _persistent_url_key(key)
                and _safe_base_url(row[1]))
        }
        if not self._host_persistent_cache:
            try:
                os.remove(path)
            except OSError:
                pass
            return
        while len(self._host_persistent_cache) > _PERSISTENT_CACHE_LIMIT:
            self._host_persistent_cache.pop(next(iter(self._host_persistent_cache)))
        entries = dict(list(self._host_persistent_cache.items())[-_PERSISTENT_CACHE_LIMIT:])
        payload = {'version': 1, 'entries': {
            key: {'expires_at': expiry, 'value': value}
            for key, (expiry, value) in entries.items()
        }}
        try:
            encoded = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            if len(encoded) > _PERSISTENT_CACHE_BYTES:
                return
            temporary = path + '.tmp'
            with open(temporary, 'wb') as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        except (OSError, TypeError, ValueError):
            try:
                os.remove(path + '.tmp')
            except OSError:
                pass

    def init(self, extend=''):
        pass

    def getName(self):
        return type(self).__name__

    def getDependence(self):
        return []

    def getProxyUrl(self):
        return getattr(self, '_cctvhost_proxy_url', '')

    def getCache(self, key):
        key = str(key)
        with self._host_cache_lock:
            self._load_persistent_cache()
            cache = getattr(self, '_host_cache', {})
            value = cache.get(key)
            if value and value[0] > time.monotonic():
                return value[1]
            cache.pop(key, None)
            if key in self._host_persistent_cache:
                self._host_persistent_cache.pop(key, None)
                self._save_persistent_cache()
            return None

    def setCache(self, key, value, expire=3600):
        key = str(key)
        duration = max(0, float(expire))
        with self._host_cache_lock:
            self._load_persistent_cache()
            if key not in self._host_cache and len(self._host_cache) >= _CACHE_LIMIT:
                self._host_cache.pop(next(iter(self._host_cache)))
            if duration:
                self._host_cache[key] = (time.monotonic() + duration, value)
            else:
                self._host_cache.pop(key, None)
            if _persistent_url_key(key) and duration and _safe_base_url(value):
                self._host_persistent_cache[key] = (time.time() + duration, value)
            else:
                self._host_persistent_cache.pop(key, None)
            self._save_persistent_cache()
        return 'ok'

    def delCache(self, key):
        key = str(key)
        with self._host_cache_lock:
            getattr(self, '_host_cache', {}).pop(key, None)
            self._host_persistent_cache.pop(key, None)
            self._save_persistent_cache()
        return 'ok'

    def fetch(self, url, headers=None, cookies=None, timeout=12, **kwargs):
        if urllib.parse.urlsplit(url).scheme.lower() not in ('http', 'https'):
            raise ValueError('Spider 仅支持 HTTP/HTTPS 网络请求')
        try:
            import requests
        except ImportError:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=min(float(timeout), 30)) as response:
                return _Response(response)
        return requests.get(url, headers=headers, cookies=cookies, timeout=min(float(timeout), 30), **kwargs)

    def post(self, url, data=None, headers=None, timeout=12, **kwargs):
        try:
            import requests
        except ImportError:
            body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
            if isinstance(body, str):
                body = body.encode()
            with urllib.request.urlopen(urllib.request.Request(url, data=body or b'', headers=headers or {}, method='POST'), timeout=min(float(timeout), 30)) as response:
                return _Response(response)
        return requests.post(url, data=data, headers=headers, timeout=min(float(timeout), 30), **kwargs)

    def destroy(self):
        getattr(self, '_host_cache', {}).clear()
