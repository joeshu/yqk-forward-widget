"""One persistent CPython interpreter, one verified, cooperative service session.

Standard socketserver services need no custom stop hook. Arbitrary plugin loops
are never killed with async exceptions, pthread_cancel, or interpreter teardown.
A replacement may run only after all tracked servers, workers and main have quit.
"""
import atexit
import builtins
import os
import runpy
import socket
import socketserver
import sys
import threading
import time
import weakref

_session = None
_lock = threading.RLock()
_stop_lock = threading.Lock()
_thread_start = threading.Thread.start
_server_init = socketserver.BaseServer.__init__
_serve_forever = socketserver.BaseServer.serve_forever
_server_close = socketserver.TCPServer.server_close
_handle_error = socketserver.BaseServer.handle_error
_tcp_init = socketserver.TCPServer.__init__
_get_request = socketserver.TCPServer.get_request
_process_request = socketserver.ThreadingMixIn.process_request
_process_thread = socketserver.ThreadingMixIn.process_request_thread
_hooks = ('_cctvhost_stop_service', '_ysp_stop_server')
_atexit_register = atexit.register
_last_error = ''


class Session:
    def __init__(self):
        self.threads = weakref.WeakSet()
        self.servers = []
        self.helpers = []
        self.done = threading.Event()
        self.stopping = threading.Event()
        self.callback_started = False
        self.exit_callbacks = []
        self.saved_path = list(sys.path)
        self.restored = False

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


def _bound(server, *args, **kwargs):
    _tcp_init(server, *args, **kwargs)
    if getattr(server, '_host_owner', None) is not None:
        address = server.server_address
        expected = os.environ.get('CCTVHOST_PORT', '')
        actual = str(address[1]) if isinstance(address, tuple) and len(address) > 1 else ''
        print('[宿主] 已接管服务监听 %s%s' % (address,
              '；与配置端口 %s 不一致，请检查脚本参数' % expected
              if expected and actual and expected != actual else ''))


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
socketserver.BaseServer.__init__ = _init
socketserver.BaseServer.serve_forever = _serve
socketserver.TCPServer.server_close = _close
socketserver.TCPServer.get_request = _accept
socketserver.TCPServer.__init__ = _bound
socketserver.BaseServer.handle_error = _error
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
    # os.environ is a Python mapping; C setenv alone does not update it on reuse.
    os.environ['YSP_DATA_DIR'] = data_dir
    os.environ['CCTVHOST_DATA_DIR'] = data_dir
    os.environ['CCTVHOST_PORT'] = str(port)


def _restore(session):
    with _lock:
        if session.restored:
            return
        sys.path[:] = session.saved_path
        for callback in session.exit_callbacks:
            atexit.unregister(callback)
        session.exit_callbacks.clear()
        for hook in _hooks:
            vars(builtins).pop(hook, None)
        session.restored = True


def run_script(path):
    global _session, _last_error
    with _lock:
        if _session is not None and not _session.clean():
            raise RuntimeError('previous service still owns live resources')
        if _session is not None:
            _restore(_session)
        session = Session()
        _session = session
        _last_error = ''
        for hook in _hooks:
            vars(builtins).pop(hook, None)
    thread = threading.current_thread()
    thread._host_session = session
    sys.path.insert(0, os.path.dirname(path))
    try:
        return runpy.run_path(path, run_name='__main__')
    finally:
        thread._host_session = None
        session.done.set()
        if session.clean():
            _restore(session)


def is_idle():
    with _lock:
        return _session is None or _session.clean()


def last_error():
    return _last_error


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


def stop_session(timeout=5.0):
    global _last_error
    if not _stop_lock.acquire(blocking=False):
        _last_error = '服务正在停止，请稍后再试。'
        return False
    try:
        session = _session
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
                _last_error = ''
                return True
            time.sleep(.02)
        with _lock:
            names = [t.name for t in list(session.threads) + session.helpers if t.is_alive()]
        _last_error = ('服务尚有任务未退出（%s）。已阻止新任务；稍后可再次停止。'
                       '不支持协作停止的脚本仍需重开 App。') % (', '.join(names[:4]) or '服务主线程/监听端口')
        return False
    finally:
        _stop_lock.release()
