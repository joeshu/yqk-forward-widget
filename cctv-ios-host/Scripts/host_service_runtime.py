"""One persistent CPython interpreter, one verified, cooperative service session.

Standard socketserver services need no custom stop hook. Arbitrary plugin loops
are never killed with async exceptions, pthread_cancel, or interpreter teardown.
A replacement may run only after all tracked servers, workers and main have quit.
"""
import atexit
import builtins
import importlib.util
import http.server
import os
import runpy
import socket
import socketserver
import sys
import threading
import time
import traceback
import weakref
from collections.abc import MutableMapping

_session = None  # Backwards-compatible alias used by older diagnostics/tests.
_sessions = {}
_lock = threading.RLock()
_stop_locks = {}
_startup_lock = threading.Lock()
_thread_start = threading.Thread.start
_server_init = socketserver.BaseServer.__init__
_serve_forever = socketserver.BaseServer.serve_forever
_server_close = socketserver.TCPServer.server_close
_handle_error = socketserver.BaseServer.handle_error
_tcp_init = socketserver.TCPServer.__init__
_http_bind = http.server.HTTPServer.server_bind
_get_request = socketserver.TCPServer.get_request
_process_request = socketserver.ThreadingMixIn.process_request
_process_thread = socketserver.ThreadingMixIn.process_request_thread
_hooks = ('_cctvhost_stop_service', '_ysp_stop_server')
_atexit_register = atexit.register
_max_threads_per_service = 48
_max_threads_for_host = 128
_last_error = ''
_last_errors = {}
_base_environment = os.environ
_original_thread_excepthook = threading.excepthook


def _thread_excepthook(args):
    """Keep unhandled plugin worker failures tied to the owning service."""
    owner = getattr(threading.current_thread(), '_host_session', None)
    if owner is None or issubclass(args.exc_type, SystemExit):
        return _original_thread_excepthook(args)
    cursor = args.exc_traceback
    last = None
    while cursor is not None:
        last = cursor
        cursor = cursor.tb_next
    source_file = os.path.basename(last.tb_frame.f_code.co_filename) if last else 'unknown'
    line_number = last.tb_lineno if last else 0
    try:
        formatted = ''.join(traceback.format_exception(args.exc_type, args.exc_value,
                                                       args.exc_traceback))[-16000:]
        callback = vars(builtins).get('_cctvhost_python_exception')
        if callable(callback):
            callback(owner.identifier, threading.current_thread().name,
                     args.exc_type.__name__, source_file, line_number,
                     str(args.exc_value), formatted)
            return
    except BaseException:
        pass
    return _original_thread_excepthook(args)


class _SessionEnvironment(MutableMapping):
    """Give plugin threads a session-local os.environ view."""
    def _mapping(self):
        owner = getattr(threading.current_thread(), '_host_session', None)
        return owner.environment if owner is not None else _base_environment

    def __getitem__(self, key): return self._mapping()[key]
    def __setitem__(self, key, value): self._mapping()[key] = str(value)
    def __delitem__(self, key): del self._mapping()[key]
    def __iter__(self): return iter(self._mapping())
    def __len__(self): return len(self._mapping())


os.environ = _SessionEnvironment()


class Session:
    def __init__(self, identifier):
        self.identifier = str(identifier)
        self.threads = weakref.WeakSet()
        self.servers = []
        self.helpers = []
        self.done = threading.Event()
        self.stopping = threading.Event()
        self.callback_started = False
        self.script_started = False
        self.exit_callbacks = []
        self.inserted_path = None
        self.restored = False
        self.startup_lock_held = False
        self.saved_argv = None
        self.saved_environment = None
        self.stop_hook = None
        self.primary_http_server_claimed = False
        self.namespace = None
        self.package_prefix = None
        self.package_root = None
        self.plugin_builtins = None
        self.previous_hooks = {}
        self.environment = dict(_base_environment)

    def load_local_module(self, name):
        qualified = self.package_prefix + '.' + name
        if qualified in sys.modules:
            return qualified
        parent_name = name.rpartition('.')[0]
        if parent_name and not self.load_local_module(parent_name):
            parent_dir = os.path.realpath(os.path.join(self.package_root, parent_name.replace('.', os.sep)))
            if os.path.commonpath([self.package_root, parent_dir]) != self.package_root or not os.path.isdir(parent_dir):
                return None
            parent_qualified = self.package_prefix + '.' + parent_name
            parent = type(sys)(parent_qualified)
            parent.__path__ = [parent_dir]
            parent.__package__ = parent_qualified
            parent.__builtins__ = self.plugin_builtins
            sys.modules[parent_qualified] = parent
        relative = name.replace('.', os.sep)
        source = os.path.realpath(os.path.join(self.package_root, relative + '.py'))
        init = os.path.realpath(os.path.join(self.package_root, relative, '__init__.py'))
        if os.path.commonpath([self.package_root, source]) == self.package_root and os.path.isfile(source):
            selected, is_package = source, False
        elif os.path.commonpath([self.package_root, init]) == self.package_root and os.path.isfile(init):
            selected, is_package = init, True
        else:
            return None
        spec = importlib.util.spec_from_file_location(qualified, selected,
                    submodule_search_locations=[os.path.dirname(selected)] if is_package else None)
        if not spec or not spec.loader:
            return None
        module = importlib.util.module_from_spec(spec)
        module.__dict__['__builtins__'] = self.plugin_builtins
        sys.modules[qualified] = module
        parent = sys.modules.get(qualified.rpartition('.')[0])
        if parent is not None:
            setattr(parent, qualified.rpartition('.')[2], module)
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(qualified, None)
            raise
        return qualified

    def clean(self):
        with _lock:
            return (self.done.is_set()
                    and not any(t.is_alive() for t in self.threads)
                    and not any(t.is_alive() for t in self.helpers)
                    and not any(not s._host_closed for s in self.servers))


def _start(thread, *args, **kwargs):
    owner = getattr(threading.current_thread(), '_host_session', None)
    if owner is not None:
        with _lock:
            if owner.stopping.is_set():
                raise RuntimeError('service is stopping; new workers are disabled')
            service_threads = sum(worker.is_alive() for worker in owner.threads)
            host_threads = sum(worker.is_alive()
                               for session in _sessions.values()
                               for worker in session.threads)
            if service_threads >= _max_threads_per_service:
                raise RuntimeError('service worker thread limit (%d) reached' % _max_threads_per_service)
            if host_threads >= _max_threads_for_host:
                raise RuntimeError('host worker thread limit (%d) reached' % _max_threads_for_host)
            thread._host_session = owner
            owner.threads.add(thread)
            # Reserve and start atomically against stop/clean checks.
            return _thread_start(thread, *args, **kwargs)
    return _thread_start(thread, *args, **kwargs)


def _init(server, *args, **kwargs):
    _server_init(server, *args, **kwargs)
    owner = getattr(threading.current_thread(), '_host_session', None)
    if owner is not None:
        with _lock:
            server._host_owner = owner
            server._host_serving = threading.Event()
            server._host_closed = False
            server._host_clients = weakref.WeakSet()
            server._host_workers = threading.BoundedSemaphore(12)
            owner.servers.append(server)


def _serve(server, poll_interval=.5):
    owner = getattr(server, '_host_owner', None)
    if owner is None:
        return _serve_forever(server, poll_interval)
    with _lock:
        if owner.stopping.is_set() or server._host_closed:
            return
        server._host_serving.set()
    _capture_stop_hook(owner)
    _release_startup(owner)
    try:
        return _serve_forever(server, min(poll_interval, .1))
    finally:
        server._host_serving.clear()


def _close(server):
    try:
        return _server_close(server)
    finally:
        if hasattr(server, '_host_closed'):
            server._host_closed = True


def _bind_http(server):
    if getattr(server, '_host_owner', None) is None:
        return _http_bind(server)
    # HTTPServer normally reverse-resolves its own bind address with getfqdn.
    # A local proxy needs no DNS name; macOS/iOS DNS stalls must not delay listen.
    socketserver.TCPServer.server_bind(server)
    server.server_name = server.server_address[0]
    server.server_port = server.server_address[1]


def _bound(server, *args, **kwargs):
    owner = getattr(threading.current_thread(), '_host_session', None)
    expected_text = owner.environment.get('CCTVHOST_PORT', '') if owner is not None else ''
    try:
        expected = int(expected_text)
    except (TypeError, ValueError):
        expected = 0

    requested = None
    if args:
        requested = args[0]
    elif 'server_address' in kwargs:
        requested = kwargs['server_address']
    redirected = False
    # The service editor's port is authoritative for the main HTTP listener.
    # Many imported Python services hard-code their original default port and
    # do not read CCTVHOST_PORT. Redirect only the first fixed-port HTTPServer
    # in this session; preserve ephemeral listeners and any auxiliary servers.
    if (owner is not None and isinstance(server, http.server.HTTPServer)
            and not owner.primary_http_server_claimed
            and 1 <= expected <= 65535
            and isinstance(requested, tuple) and len(requested) >= 2):
        try:
            requested_port = int(requested[1])
        except (TypeError, ValueError):
            requested_port = 0
        if requested_port > 0 and requested_port != expected:
            address = list(requested)
            address[1] = expected
            replacement = tuple(address)
            if args:
                args = (replacement,) + tuple(args[1:])
            else:
                kwargs['server_address'] = replacement
            redirected = True

    _tcp_init(server, *args, **kwargs)
    bound_owner = getattr(server, '_host_owner', None)
    if bound_owner is not None:
        address = server.server_address
        actual = str(address[1]) if isinstance(address, tuple) and len(address) > 1 else ''
        was_primary_http_server = (isinstance(server, http.server.HTTPServer)
                                   and not bound_owner.primary_http_server_claimed)
        if was_primary_http_server and actual and actual != '0':
            bound_owner.primary_http_server_claimed = True
        if redirected:
            print('[宿主] 服务设置端口已应用：脚本请求 %s，实际监听 %s' % (requested, address))
        else:
            expected_mismatch = (1 <= expected <= 65535 and actual
                                 and actual != str(expected))
            auxiliary_http_listener = (isinstance(server, http.server.HTTPServer)
                                       and not was_primary_http_server and expected_mismatch)
            note = ('；辅助 HTTP 监听保留脚本端口 %s' % actual
                    if auxiliary_http_listener else
                    ('；与配置端口 %s 不一致，请检查脚本参数' % expected
                     if expected_mismatch else ''))
            print('[宿主] 已接管服务监听 %s%s' % (address, note))


def _error(server, request, address):
    owner = getattr(server, '_host_owner', None)
    if owner is not None and owner.stopping.is_set() and isinstance(sys.exc_info()[1], OSError):
        return  # An interrupted socket during an explicit stop is expected.
    return _handle_error(server, request, address)


def _accept(server):
    request, address = _get_request(server)
    owner = getattr(server, '_host_owner', None)
    if owner is not None:
        with _lock:
            if owner.stopping.is_set():
                request.close()
                raise OSError('service stopping')
            if request.gettimeout() is None:
                request.settimeout(10.0)
            server._host_clients.add(request)
    return request, address


def _process(server, request, address):
    slots = getattr(server, '_host_workers', None)
    if slots is None:
        return _process_request(server, request, address)
    if not slots.acquire(blocking=False):
        server.shutdown_request(request)
        return
    try:
        return _process_request(server, request, address)
    except BaseException:
        slots.release()
        raise


def _process_worker(server, request, address):
    try:
        return _process_thread(server, request, address)
    finally:
        slots = getattr(server, '_host_workers', None)
        if slots is not None:
            slots.release()


threading.Thread.start = _start
threading.excepthook = _thread_excepthook
socketserver.BaseServer.__init__ = _init
socketserver.BaseServer.serve_forever = _serve
socketserver.TCPServer.server_close = _close
socketserver.TCPServer.get_request = _accept
socketserver.TCPServer.__init__ = _bound
socketserver.BaseServer.handle_error = _error
http.server.HTTPServer.server_bind = _bind_http
socketserver.ThreadingMixIn.process_request = _process
socketserver.ThreadingMixIn.process_request_thread = _process_worker


def _register_exit(function, *args, **kwargs):
    owner = getattr(threading.current_thread(), '_host_session', None)
    if owner is not None:
        with _lock:
            owner.exit_callbacks.append(function)
    return _atexit_register(function, *args, **kwargs)


atexit.register = _register_exit


def configure_environment(data_dir, port):
    # Legacy callers configure the host's base environment. Per-service values
    # are passed directly to run_script and stay in that session's mapping.
    _base_environment['YSP_DATA_DIR'] = data_dir
    _base_environment['CCTVHOST_DATA_DIR'] = data_dir
    _base_environment['CCTVHOST_PORT'] = str(port)


def _release_startup(session):
    """Restore interpreter-wide startup values before another script enters."""
    if not session.startup_lock_held:
        return
    with _lock:
        if not session.startup_lock_held:
            return
        if session.saved_argv is not None:
            sys.argv = session.saved_argv
            session.saved_argv = None
        session.startup_lock_held = False
        _startup_lock.release()


def _capture_stop_hook(session):
    """Capture this script's hook without overwriting another live plugin."""
    with _lock:
        for hook in _hooks:
            current = vars(builtins).get(hook)
            previous = session.previous_hooks.get(hook)
            if callable(current) and current is not previous:
                session.stop_hook = current
                if previous is None:
                    vars(builtins).pop(hook, None)
                else:
                    vars(builtins)[hook] = previous


def _restore(session):
    with _lock:
        if session.restored:
            return
        _release_startup(session)
        if session.inserted_path and session.inserted_path in sys.path:
            sys.path.remove(session.inserted_path)
        for callback in session.exit_callbacks:
            atexit.unregister(callback)
        session.exit_callbacks.clear()
        if session.package_prefix:
            for module_name in list(sys.modules):
                if module_name == session.package_prefix or module_name.startswith(session.package_prefix + '.'):
                    sys.modules.pop(module_name, None)
        session.namespace = None
        session.package_prefix = None
        session.package_root = None
        session.plugin_builtins = None
        session.threads.clear()
        session.helpers.clear()
        session.servers.clear()
        session.environment.clear()
        session.inserted_path = None
        session.restored = True
        if _sessions.get(session.identifier) is session:
            del _sessions[session.identifier]


def run_script(path, identifier='default', data_dir=None, port=None, arguments=None):
    global _session, _last_error
    identifier = str(identifier or 'default')
    with _lock:
        previous = _sessions.get(identifier)
        if previous is not None and not previous.clean():
            raise RuntimeError('previous service %s still owns live resources' % identifier)
        if previous is not None:
            _restore(previous)
        session = Session(identifier)
        _sessions[identifier] = session
        _session = session
        _last_error = ''
        _last_errors[identifier] = ''
        session.previous_hooks = {hook: vars(builtins).get(hook) for hook in _hooks}
    # Python plugins share one interpreter. Serialize only their top-level
    # initialization so argv/environment and import-path setup cannot race.
    # A managed blocking HTTP server releases this gate as soon as it is serving.
    _startup_lock.acquire()
    thread = threading.current_thread()
    with _lock:
        session.startup_lock_held = True
        thread._host_session = session
    try:
        with _lock:
            # A stop may arrive while this service waits behind another
            # plugin's serialized import/startup. Never start it afterwards.
            if session.stopping.is_set():
                return {}
            session.saved_argv = sys.argv
            if data_dir is not None:
                session.environment['YSP_DATA_DIR'] = str(data_dir)
                session.environment['CCTVHOST_DATA_DIR'] = str(data_dir)
            if port is not None:
                session.environment['CCTVHOST_PORT'] = str(port)
            if arguments is not None:
                sys.argv = [path] + list(arguments)
            session.package_root = os.path.realpath(os.path.dirname(path))
            session.inserted_path = session.package_root
            sys.path.insert(0, session.inserted_path)
            session.package_prefix = '_cctvhost_service_%x' % id(session)
            package = type(sys)(session.package_prefix)
            package.__path__ = [session.package_root]
            package.__package__ = session.package_prefix
            sys.modules[session.package_prefix] = package
            session.plugin_builtins = dict(vars(builtins))
            original_import = builtins.__import__

            def import_local(name, globals=None, locals=None, fromlist=(), level=0):
                if level == 0 and isinstance(name, str) and name:
                    local_name = session.load_local_module(name)
                    if local_name:
                        module = sys.modules[local_name]
                        if fromlist:
                            for child in fromlist:
                                if child != '*' and not hasattr(module, child):
                                    session.load_local_module(name + '.' + child)
                            return module
                        return sys.modules[session.package_prefix]
                return original_import(name, globals, locals, fromlist, level)

            session.plugin_builtins['__import__'] = import_local
            session.script_started = True
        session.namespace = runpy.run_path(path, run_name='__main__', init_globals={'__builtins__': session.plugin_builtins})
        return session.namespace
    except SystemExit as error:
        # argparse/sys.exit belongs to this service, never the embedding App.
        print('[宿主] Python 脚本已退出，退出码：%s' % error.code)
        return {}
    finally:
        if session.script_started:
            _capture_stop_hook(session)
        _release_startup(session)
        thread._host_session = None
        session.done.set()
        if session.clean():
            _restore(session)


def is_idle(identifier=None):
    with _lock:
        if identifier is not None:
            session = _sessions.get(str(identifier))
            return session is None or session.clean()
        return all(session.clean() for session in _sessions.values())


def last_error(identifier=None):
    return _last_errors.get(str(identifier), _last_error) if identifier is not None else _last_error


def session_status(identifier):
    with _lock:
        session = _sessions.get(str(identifier))
        if session is None:
            return {'running': False, 'stopping': False, 'threads': [], 'servers': []}
        return {'running': not session.clean(), 'stopping': session.stopping.is_set(),
                'threads': [t.name for t in list(session.threads) + session.helpers if t.is_alive()],
                'servers': [str(s.server_address) for s in session.servers if not s._host_closed]}


def _helper(session, target, name):
    def guarded():
        try:
            target()
        except Exception as error:
            print('[宿主] %s: %s' % (name, error))
    worker = threading.Thread(target=guarded, name=name, daemon=True)
    worker._host_session = session
    with _lock:
        session.helpers.append(worker)
        _thread_start(worker)  # Host-owned cleanup, allowed after stop request.
    return worker


def stop_session(identifier='default', timeout=5.0):
    global _last_error
    # Preserve the original stop_session(timeout) calling convention.
    if isinstance(identifier, (int, float)):
        timeout, identifier = identifier, 'default'
    identifier = str(identifier or 'default')
    with _lock:
        stop_lock = _stop_locks.setdefault(identifier, threading.Lock())
    if not stop_lock.acquire(blocking=False):
        _last_errors[identifier] = _last_error = '服务正在停止，请稍后再试。'
        return False
    try:
        with _lock:
            session = _sessions.get(identifier)
        if session is None:
            return True
        if session.clean():
            _restore(session)
            return True
        deadline = time.monotonic() + max(0, timeout)
        with _lock:
            session.stopping.set()
            if not session.callback_started:
                session.callback_started = True
                callback = session.stop_hook
                # A script that is still executing top-level code owns the
                # startup gate, so no second plugin can have replaced this
                # callback yet.
                if callback is None and session.startup_lock_held:
                    callback = next((getattr(builtins, h, None) for h in _hooks
                                     if callable(getattr(builtins, h, None))), None)
                if callback:
                    _helper(session, callback, 'plugin-stop-callback')
        # Shutdown only servers currently in serve_forever; shutdown() on an
        # unstarted server deadlocks. Closing/joining is bounded in helper threads.
        for server in list(session.servers):
            with _lock:
                if server._host_closed or getattr(server, '_host_cleanup_started', False):
                    continue
                server._host_cleanup_started = True
            def cleanup(server=server):
                # Interrupt a client stuck reading headers/body before waiting
                # for serve_forever or ThreadingMixIn workers to join.
                for client in list(server._host_clients):
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                if server._host_serving.is_set():
                    server.shutdown()
                server.server_close()
            _helper(session, cleanup, 'http-service-stop')
        while time.monotonic() < deadline:
            if session.clean():
                _restore(session)
                _last_errors[identifier] = _last_error = ''
                return True
            time.sleep(.02)
        with _lock:
            names = [t.name for t in list(session.threads) + session.helpers if t.is_alive()]
        _last_errors[identifier] = _last_error = ('服务尚有任务未退出（%s）。已阻止新任务；稍后可再次停止。'
                       '不支持协作停止的脚本仍需重开 App。') % (', '.join(names[:4]) or '服务主线程/监听端口')
        return False
    finally:
        stop_lock.release()
