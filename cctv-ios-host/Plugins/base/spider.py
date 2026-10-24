"""Small host base for conventional Python Spider packages.

Requests and BeautifulSoup are optional adapters; imported modules continue to
use their original Python code. Cache state belongs to each Spider instance.
"""
import json
import threading
import time
import urllib.parse
import urllib.request


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

    def init(self, extend=''):
        pass

    def getName(self):
        return type(self).__name__

    def getDependence(self):
        return []

    def getProxyUrl(self):
        return getattr(self, '_cctvhost_proxy_url', '')

    def getCache(self, key):
        cache = getattr(self, '_host_cache', {})
        value = cache.get(key)
        if value and value[0] > time.monotonic():
            return value[1]
        cache.pop(key, None)
        return None

    def setCache(self, key, value, expire=3600):
        if not hasattr(self, '_host_cache'):
            self._host_cache = {}
        if len(self._host_cache) >= 128:
            self._host_cache.pop(next(iter(self._host_cache)))
        self._host_cache[key] = (time.monotonic() + max(0, float(expire)), value)
        return 'ok'

    def delCache(self, key):
        getattr(self, '_host_cache', {}).pop(key, None)
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
