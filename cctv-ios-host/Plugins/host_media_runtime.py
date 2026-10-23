"""Local media protocol adapters. User JS stays JS; Python spiders stay Python.

Only explicitly enabled packages are loaded. This module never resolves a stream
by executing a plugin during import/inspection of an archive.
"""
import builtins
import collections
import importlib.util
import inspect
import json
import os
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


def decoded(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            pass
    return value


def rows(value):
    value = decoded(value)
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return value.get('list', value.get('items', [])) or []
    return []


def cards(value):
    result = []
    for row in rows(value):
        if not isinstance(row, dict):
            continue
        identifier = row.get('id', row.get('vod_id'))
        name = row.get('name', row.get('vod_name'))
        if identifier is None or not name:
            continue
        result.append({'id': str(identifier), 'name': str(name),
                       'poster': str(row.get('poster', row.get('vod_pic', '')) or ''),
                       'remarks': str(row.get('remarks', row.get('vod_remarks', '')) or '')})
    return result


def listing(value, page=1):
    value = decoded(value)
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
    value = decoded(value)
    value = value if isinstance(value, dict) else {}
    categories = value.get('categories', value.get('class', [])) or []
    return {'categories': [{'id': str(row.get('id', row.get('type_id', ''))),
                            'name': str(row.get('name', row.get('type_name', '')))}
                           for row in categories if isinstance(row, dict)],
            'filters': value.get('filters', {}), 'items': cards(value)}


def detail(value, identifier):
    value = decoded(value)
    raw = rows(value)
    item = raw[0] if raw else value
    if not isinstance(item, dict):
        raise MediaError('NO_DETAIL', '来源未返回影片详情')
    lines = []
    if isinstance(item.get('lines'), list):
        for index, line in enumerate(item['lines']):
            if not isinstance(line, dict) or not isinstance(line.get('episodes'), list):
                continue
            episodes = [{'id': str(row['id']), 'name': str(row.get('name', row['id']))}
                        for row in line['episodes'] if isinstance(row, dict) and row.get('id') is not None]
            lines.append({'id': str(line.get('id', index)), 'name': str(line.get('name') or f'线路 {index + 1}'), 'episodes': episodes})
    elif 'vod_play_url' in item:
        flags = str(item.get('vod_play_from') or '').split('$$$')
        groups = str(item.get('vod_play_url') or '').split('$$$')
        for line_index, group in enumerate(groups):
            flag = flags[line_index] if line_index < len(flags) else ''
            episodes = []
            for index, episode in enumerate(group.split('#')):
                if not episode:
                    continue
                label, separator, play_id = episode.partition('$')
                episodes.append({'id': play_id if separator else label,
                                 'name': label if separator else str(index + 1)})
            if episodes:
                lines.append({'id': flag, 'name': flag or f'线路 {line_index + 1}', 'episodes': episodes})
    elif isinstance(item.get('episodes'), list):
        lines = [{'id': '', 'name': '播放', 'episodes': item['episodes']}]
    return {'id': str(item.get('id', item.get('vod_id', identifier))),
            'name': str(item.get('name', item.get('vod_name', identifier))),
            'poster': str(item.get('poster', item.get('vod_pic', '')) or ''),
            'description': str(item.get('description', item.get('vod_content', '')) or ''),
            'actor': str(item.get('actor', item.get('vod_actor', '')) or ''),
            'year': str(item.get('year', item.get('vod_year', '')) or ''), 'lines': lines}


def playback(value):
    value = decoded(value)
    if isinstance(value, str):
        value = {'url': value}
    if not isinstance(value, dict):
        raise MediaError('NO_MEDIA', '来源未返回播放结果')
    parse = 1 if int(value.get('parse') or 0) > 0 else 0
    url = value.get('url')
    alternates = value.get('alternates', [])
    if isinstance(url, list):
        alternates = [{'name': str(url[i]), 'url': str(url[i + 1])} for i in range(0, len(url) - 1, 2)]
        url = alternates[0]['url'] if alternates else ''
    if not isinstance(url, str) or urllib.parse.urlsplit(url).scheme.lower() not in ('http', 'https'):
        raise MediaError('NO_MEDIA', '来源未返回有效 HTTP/HTTPS 媒体地址')
    headers = value.get('headers', value.get('header', {})) or {}
    if not isinstance(headers, dict):
        headers = {}
    headers = {str(k): str(v) for k, v in headers.items()
               if '\r' not in str(k) + str(v) and '\n' not in str(k) + str(v)
               and len(str(v)) <= 16384
               and str(k).lower() not in ('host', 'content-length', 'connection', 'transfer-encoding')}
    return {'url': url, 'headers': headers, 'alternates': alternates, 'parse': parse}


class PythonSpider:
    def __init__(self, root, entry, options=None, proxy_url=''):
        self.root = os.path.realpath(root)
        path = os.path.realpath(os.path.join(self.root, entry))
        if os.path.commonpath([self.root, path]) != self.root or not path.endswith('.py'):
            raise MediaError('INVALID_ENTRY', 'Python 入口超出资源目录或不是 .py 文件')
        self.added_path = self.root not in sys.path
        if self.added_path:
            sys.path.insert(0, self.root)
        self.namespace = '_cctvhost_spider_' + uuid.uuid4().hex
        namespace = types.ModuleType(self.namespace)
        namespace.__path__ = [self.root]
        sys.modules[self.namespace] = namespace
        relative = os.path.relpath(path, self.root)[:-3].replace(os.sep, '.')
        name = self.namespace + '.' + relative
        spec = importlib.util.spec_from_file_location(name, path)
        if not spec or not spec.loader:
            raise MediaError('INVALID_ENTRY', '无法加载 Python Spider')
        self.module_name = name
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
            cls = getattr(module, 'Spider', None)
            if not callable(cls):
                raise MediaError('INVALID_PROTOCOL', '文件未提供 Spider 类；HTTP 服务脚本请按服务方式运行')
            self.spider = cls()
            self.spider._cctvhost_proxy_url = proxy_url
            self.lock = threading.Lock()
            if callable(getattr(self.spider, 'init', None)):
                self.spider.init(options if isinstance(options, str) else json.dumps(options or {}, ensure_ascii=False))
        except BaseException:
            sys.modules.pop(name, None)
            sys.modules.pop(self.namespace, None)
            if self.added_path and self.root in sys.path:
                sys.path.remove(self.root)
            raise

    def capabilities(self):
        methods = {'home': 'homeContent', 'category': 'categoryContent', 'search': 'searchContent',
                   'detail': 'detailContent', 'play': 'playerContent', 'proxy': 'localProxy'}
        return {'engine': 'CPython', 'protocol': 'python-spider',
                'capabilities': [key for key, method in methods.items() if callable(getattr(self.spider, method, None))]}

    def call(self, operation, args):
        if not self.lock.acquire(timeout=.1):
            raise MediaError('BUSY', '来源正在处理其他请求，请稍后重试', True)
        try:
            spider = self.spider
            if operation == 'home':
                result = decoded(spider.homeContent(True))
                if not isinstance(result, dict):
                    result = {}
                if not rows(result) and callable(getattr(spider, 'homeVideoContent', None)):
                    result = dict(result, list=rows(spider.homeVideoContent()))
                return result
            if operation == 'category':
                return spider.categoryContent(str(args.get('categoryId', '')), str(args.get('page', 1)), True, args.get('filters') or {})
            if operation == 'search':
                fn = spider.searchContent
                if len(inspect.signature(fn).parameters) >= 3:
                    return fn(str(args.get('keyword', '')), False, str(args.get('page', 1)))
                return fn(str(args.get('keyword', '')), False)
            if operation == 'detail':
                return spider.detailContent([str(args.get('id', ''))])
            if operation == 'play':
                return spider.playerContent(str(args.get('lineId', '')), str(args.get('id', '')), [])
            if operation == 'proxy':
                return spider.localProxy(args)
            raise MediaError('UNSUPPORTED', '此来源不支持该操作')
        finally:
            self.lock.release()

    def close(self):
        with self.lock:
            try:
                callback = getattr(self.spider, 'destroy', None)
                if callable(callback):
                    callback()
            finally:
                for name, module in list(sys.modules.items()):
                    path = getattr(module, '__file__', '') or ''
                    if name == self.namespace or name.startswith(self.namespace + '.') or (path and os.path.realpath(path).startswith(self.root + os.sep)):
                        sys.modules.pop(name, None)
                if self.added_path and self.root in sys.path:
                    sys.path.remove(self.root)


class NativeJS:
    def __init__(self, root, manifest, node=False, bridge=None):
        self.bridge = bridge or getattr(builtins, '_cctvhost_node_call' if node else '_cctvhost_js_call', None)
        if not self.bridge:
            raise MediaError('RUNTIME_MISSING', '此版本未包含所需的本机 JS 运行时')
        self.session = uuid.uuid4().hex
        try:
            self.metadata = self._call('start', packageRoot=os.path.realpath(root), **manifest)
        except BaseException:
            try:
                self._call('stop')
            except Exception:
                pass
            raise

    def _call(self, operation, **args):
        reply = decoded(self.bridge(operation, json.dumps(dict(args, session=self.session), ensure_ascii=False)))
        if not isinstance(reply, dict) or not reply.get('ok'):
            raise MediaError('PLUGIN_ERROR', str(reply.get('error', 'JS 执行失败')) if isinstance(reply, dict) else '无效 JS 桥接结果')
        return reply.get('result')

    def capabilities(self):
        return self.metadata

    def call(self, operation, args):
        return self._call(operation, **args)

    def close(self):
        return self._call('stop')


class MediaRuntime:
    def __init__(self, engine):
        self.engine = engine
        self.stopping = threading.Event()
        self.cache = collections.OrderedDict()
        self.cache_lock = threading.Lock()
        self.cache_bytes = 0
        self.closed = False

    def call(self, operation, args=None):
        if self.stopping.is_set():
            raise MediaError('STOPPING', '资源正在停止')
        args = args or {}
        if operation == 'capabilities':
            return self.engine.capabilities()
        key = json.dumps([operation, args], sort_keys=True, ensure_ascii=False)
        ttl = {'home': 120, 'category': 30, 'search': 20, 'detail': 120, 'catalog': 60}.get(operation, 0)
        with self.cache_lock:
            entry = self.cache.get(key)
            if entry and entry[0] > time.monotonic():
                self.cache.move_to_end(key)
                return json.loads(entry[1])
        raw = self.engine.call(operation, args)
        if operation in ('proxy', 'route'):
            return raw
        if operation == 'home':
            value = home(raw)
        elif operation in ('search', 'category'):
            value = listing(raw, args.get('page', 1))
        elif operation == 'detail':
            value = detail(raw, args.get('id', ''))
        elif operation == 'play':
            value = playback(raw)
        elif operation == 'providers':
            value = [{'id': str(row.get('id', row.get('key', ''))), 'name': str(row.get('name', row.get('title', '')))}
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
        if ttl and not self.stopping.is_set():
            with self.cache_lock:
                old = self.cache.pop(key, None)
                if old:
                    self.cache_bytes -= len(old[1])
                self.cache[key] = (time.monotonic() + ttl, encoded)
                self.cache_bytes += len(encoded)
                while len(self.cache) > 32 or self.cache_bytes > 8 * 1024 * 1024:
                    _, old = self.cache.popitem(last=False)
                    self.cache_bytes -= len(old[1])
        return value

    def close(self):
        self.stopping.set()
        with self.cache_lock:
            self.cache.clear()
            self.cache_bytes = 0
        if not self.closed:
            self.closed = True
            self.engine.close()
