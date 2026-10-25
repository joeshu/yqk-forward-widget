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
                       'remarks': str(row.get('remarks', row.get('vod_remarks', '')) or ''),
                       **({'posterHeaders': media_headers(row['posterHeaders'])} if isinstance(row.get('posterHeaders'), dict) else {})})
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
    if isinstance(value, dict) and ('list' in value or 'items' in value) and not raw:
        raise MediaError('NO_DETAIL', '此站点没有返回影片详情，请重试或更换站点')
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
    result = {'id': str(item.get('id', item.get('vod_id', identifier))),
              'name': str(item.get('name', item.get('vod_name', identifier))),
              'poster': str(item.get('poster', item.get('vod_pic', '')) or ''),
              'description': str(item.get('description', item.get('vod_content', '')) or ''),
              'actor': str(item.get('actor', item.get('vod_actor', '')) or ''),
              'year': str(item.get('year', item.get('vod_year', '')) or ''), 'lines': lines}
    if isinstance(item.get('posterHeaders'), dict):
        result['posterHeaders'] = media_headers(item['posterHeaders'])
    # Preserve optional provider metadata when present so the native detail page
    # can show accurate credits and classification without inventing values.
    for key, aliases in {
        'area': ('area', 'vod_area'), 'lang': ('lang', 'vod_lang'),
        'type': ('type', 'vod_class'), 'director': ('director', 'vod_director'),
        'remarks': ('remarks', 'vod_remarks'), 'banner': ('banner', 'backdrop'),
    }.items():
        value = next((item[name] for name in aliases if item.get(name)), None)
        if value is not None:
            result[key] = str(value)[:4096]
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


def playback(value):
    value = decoded(value)
    if isinstance(value, str):
        value = {'url': value}
    if not isinstance(value, dict):
        raise MediaError('NO_MEDIA', '来源未返回播放结果')
    try:
        parse = 1 if int(value.get('parse') or 0) > 0 else 0
    except (ValueError, TypeError):
        parse = 1 if value.get('parse') is True else 0
    try:
        jx = 1 if int(value.get('jx') or 0) > 0 else 0
    except (ValueError, TypeError):
        jx = 1 if value.get('jx') is True else 0
    headers = value.get('headers', value.get('header', {})) or {}
    url = value.get('url')
    alternates = value.get('alternates', [])
    if isinstance(url, dict):
        nested_headers = url.get('headers') or url.get('header') or {}
        headers = {**media_headers(headers), **media_headers(nested_headers)}
        choices = url.get('values') or url.get('list')
        if isinstance(choices, list):
            url = choices
        else:
            url = url.get('url') or url.get('value')
    if isinstance(url, list):
        if url and all(isinstance(item, dict) for item in url):
            alternates = [{'name': str(item.get('name') or item.get('n') or item.get('quality') or f'线路 {index + 1}'),
                           'url': str(item.get('url') or item.get('value') or item.get('v') or '')}
                          for index, item in enumerate(url) if item.get('url') or item.get('value') or item.get('v')]
        else:
            alternates = [{'name': str(url[i]), 'url': str(url[i + 1])} for i in range(0, len(url) - 1, 2)]
        url = alternates[0]['url'] if alternates else ''
    if not url and isinstance(value.get('playUrl'), str) and value['playUrl'].startswith(('http://', 'https://')):
        url = value['playUrl']
    if not valid_media_url(url):
        raise MediaError('NO_MEDIA', '来源未返回有效 HTTP/HTTPS 媒体地址')
    safe_alternates = []
    if isinstance(alternates, list):
        for index, item in enumerate(alternates[:32]):
            if not isinstance(item, dict):
                continue
            candidate = item.get('url', item.get('value', item.get('v', '')))
            if valid_media_url(candidate):
                safe_alternates.append({'name': str(item.get('name') or item.get('n') or item.get('quality') or f'线路 {index + 1}')[:128], 'url': candidate})
    return {'url': url, 'headers': media_headers(headers), 'alternates': safe_alternates,
            'parse': parse, 'jx': jx, 'playUrl': value.get('playUrl', '') if isinstance(value.get('playUrl', ''), str) else ''}


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
                self._remove_package_modules()
                if self.added_path and self.root in sys.path:
                    sys.path.remove(self.root)


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
