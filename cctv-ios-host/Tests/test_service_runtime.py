import builtins
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location('host_service_runtime', Path(__file__).resolve().parents[1] / 'Scripts/host_service_runtime.py')
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class ServiceRuntimeTests(unittest.TestCase):
    def setUp(self):
        import os
        self.saved_environment = {key: os.environ.get(key) for key in ('YSP_DATA_DIR', 'CCTVHOST_DATA_DIR', 'CCTVHOST_PORT')}
        self.temp = tempfile.TemporaryDirectory()
        self.workers = []
        self.errors = []
        self.release = threading.Event()
        builtins._host_test_release = self.release

    def tearDown(self):
        self.release.set()
        runtime.stop_session(2)
        for thread in self.workers:
            thread.join(2)
        import os
        for key, value in self.saved_environment.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value
        self.temp.cleanup()
        vars(builtins).pop('_host_test_release', None)
        self.assertTrue(runtime.is_idle(), runtime.last_error())

    def launch(self, source):
        path = Path(self.temp.name) / ('plugin%d.py' % len(self.workers))
        path.write_text(source)
        def run():
            try:
                runtime.run_script(str(path))
            except BaseException as error:
                self.errors.append(error)
        thread = threading.Thread(target=run, daemon=True)
        self.workers.append(thread)
        thread.start()
        return thread

    def wait(self, check):
        end = time.monotonic() + 2
        while not check() and time.monotonic() < end:
            time.sleep(.005)
        self.assertTrue(check(), self.errors)

    def server_source(self, port=0, background=False):
        return ("from http.server import HTTPServer, BaseHTTPRequestHandler\n"
                "import builtins, threading\n"
                "class Handler(BaseHTTPRequestHandler):\n"
                " def do_GET(self):\n"
                "  self.send_response(200); self.end_headers(); self.wfile.write(b'ok')\n"
                " def log_message(self, *args): pass\n"
                f"server = HTTPServer(('127.0.0.1', {port}), Handler)\n"
                "builtins._host_test_server = server\n" +
                ("threading.Thread(target=server.serve_forever, daemon=True).start()\n" if background else "server.serve_forever()\n"))

    def test_plain_http_without_callback_stops_and_same_port_restarts(self):
        first = self.launch(self.server_source())
        self.wait(lambda: bool(runtime._session and runtime._session.servers and runtime._session.servers[0]._host_serving.is_set()))
        port = runtime._session.servers[0].server_address[1]
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        first.join(1)
        self.assertTrue(runtime.is_idle())
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', port), timeout=.25)
        second = self.launch(self.server_source(port))
        self.wait(lambda: bool(runtime._session.servers and runtime._session.servers[0]._host_serving.is_set()))
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        second.join(1)
        self.assertEqual(self.errors, [])

    def test_configured_service_port_overrides_hardcoded_primary_http_port(self):
        def free_port():
            probe = socket.socket()
            try:
                probe.bind(('127.0.0.1', 0))
                return probe.getsockname()[1]
            finally:
                probe.close()

        legacy_port = free_port()
        configured_port = free_port()
        while configured_port == legacy_port:
            configured_port = free_port()
        auxiliary_port = free_port()
        while auxiliary_port in (legacy_port, configured_port):
            auxiliary_port = free_port()
        path = Path(self.temp.name) / 'legacy_port_service.py'
        source = self.server_source(legacy_port).replace(
            'server.serve_forever()\n',
            "auxiliary = HTTPServer(('127.0.0.1', %d), Handler)\n" % auxiliary_port
            + "threading.Thread(target=auxiliary.serve_forever, daemon=True).start()\n"
            + 'server.serve_forever()\n')
        path.write_text(source)

        def run():
            try:
                runtime.run_script(str(path), 'port-override', self.temp.name,
                                   configured_port, [])
            except BaseException as error:
                self.errors.append(error)

        worker = threading.Thread(target=run, daemon=True)
        self.workers.append(worker)
        worker.start()
        try:
            self.wait(lambda: bool(runtime._sessions.get('port-override')
                                   and runtime._sessions['port-override'].servers
                                   and runtime._sessions['port-override'].servers[0]._host_serving.is_set()))
            servers = runtime._sessions['port-override'].servers
            server = servers[0]
            self.assertEqual(server.server_address[1], configured_port)
            self.assertEqual(servers[1].server_address[1], auxiliary_port,
                             'port override must leave auxiliary listeners unchanged')
            with urllib.request.urlopen('http://127.0.0.1:%d/' % configured_port, timeout=1) as response:
                self.assertEqual(response.read(), b'ok')
            with self.assertRaises(OSError):
                socket.create_connection(('127.0.0.1', legacy_port), timeout=.25)
        finally:
            self.assertTrue(runtime.stop_session('port-override', 2),
                            runtime.last_error('port-override'))
            worker.join(1)
        self.assertEqual(self.errors, [])

    def test_two_service_ids_run_concurrently_and_stop_independently(self):
        def source(label):
            return ("from http.server import HTTPServer, BaseHTTPRequestHandler\nimport os\n"
                    "class Handler(BaseHTTPRequestHandler):\n"
                    " def do_GET(self):\n"
                    "  self.send_response(200); self.end_headers(); self.wfile.write((" + repr(label + '|') + "+os.environ['CCTVHOST_DATA_DIR']).encode())\n"
                    " def log_message(self, *args): pass\n"
                    "server = HTTPServer(('127.0.0.1', 0), Handler)\n"
                    "server.serve_forever()\n")
        paths = {}
        workers = {}
        for identifier in ('service-a', 'service-b'):
            path = Path(self.temp.name) / (identifier + '.py')
            path.write_text(source(identifier))
            paths[identifier] = path
            def run(service_id=identifier, script=path):
                try:
                    runtime.run_script(str(script), service_id, str(Path(self.temp.name) / service_id), 0, [])
                except BaseException as error:
                    self.errors.append(error)
            workers[identifier] = threading.Thread(target=run, daemon=True)
            workers[identifier].start()
            self.wait(lambda service_id=identifier: bool(runtime._sessions.get(service_id) and runtime._sessions[service_id].servers and runtime._sessions[service_id].servers[0]._host_serving.is_set()))
        ports = {identifier: runtime._sessions[identifier].servers[0].server_address[1] for identifier in workers}
        self.assertNotEqual(ports['service-a'], ports['service-b'])
        for identifier, port in ports.items():
            with urllib.request.urlopen('http://127.0.0.1:%d/' % port, timeout=1) as response:
                self.assertEqual(response.read(), (identifier + '|' + str(Path(self.temp.name) / identifier)).encode())
        self.assertTrue(runtime.stop_session('service-a', 2), runtime.last_error('service-a'))
        workers['service-a'].join(1)
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', ports['service-a']), timeout=.25)
        with urllib.request.urlopen('http://127.0.0.1:%d/' % ports['service-b'], timeout=1) as response:
            self.assertEqual(response.read(), ('service-b|' + str(Path(self.temp.name) / 'service-b')).encode())
        self.assertTrue(runtime.stop_session('service-b', 2), runtime.last_error('service-b'))
        workers['service-b'].join(1)
        self.assertEqual(self.errors, [])

    def test_stop_while_waiting_for_serialized_startup_prevents_late_service_start(self):
        import builtins
        gate = threading.Event()
        builtins._host_test_startup_gate = gate
        paths = {}
        for identifier, source in (
                ('startup-a', 'import builtins\nbuiltins._host_test_startup_gate.wait()\n'),
                ('startup-b', "from http.server import HTTPServer, BaseHTTPRequestHandler\n"
                              "class Handler(BaseHTTPRequestHandler): pass\n"
                              "HTTPServer(('127.0.0.1', 0), Handler).serve_forever()\n")):
            path = Path(self.temp.name) / (identifier + '.py')
            path.write_text(source)
            paths[identifier] = path

        first = threading.Thread(target=lambda: runtime.run_script(str(paths['startup-a']), 'startup-a'), daemon=True)
        second = threading.Thread(target=lambda: runtime.run_script(str(paths['startup-b']), 'startup-b'), daemon=True)
        first.start()
        self.wait(lambda: runtime._sessions.get('startup-a') is not None
                  and runtime._sessions['startup-a'].script_started)
        second.start()
        self.wait(lambda: runtime._sessions.get('startup-b') is not None)
        self.assertFalse(runtime.stop_session('startup-b', .1))
        gate.set()
        first.join(1)
        second.join(1)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertTrue(runtime.is_idle('startup-a'))
        self.assertTrue(runtime.is_idle('startup-b'))
        self.assertNotIn('startup-b', runtime._sessions)
        vars(builtins).pop('_host_test_startup_gate', None)

    def test_plugin_worker_threads_are_bounded(self):
        worker = self.launch("import builtins, threading\n"
                             "for _ in range(49):\n"
                             " threading.Thread(target=builtins._host_test_release.wait, daemon=True).start()\n")
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(self.errors), 1)
        self.assertRegex(str(self.errors[0]), 'worker thread limit')
        self.assertLessEqual(sum(thread.is_alive() for thread in runtime._session.threads), 48)
        self.release.set()
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        self.assertTrue(runtime.is_idle())

    def test_uncaught_worker_exception_is_reported_with_service_and_source_context(self):
        reports = []
        previous = vars(builtins).get('_cctvhost_python_exception')
        builtins._cctvhost_python_exception = lambda *args: reports.append(args)
        try:
            worker = self.launch("import threading, time\n"
                                 "def fail():\n"
                                 " raise ValueError('worker diagnostic fixture')\n"
                                 "threading.Thread(target=fail, name='fixture-worker', daemon=True).start()\n"
                                 "time.sleep(.05)\n")
            worker.join(1)
            self.wait(lambda: bool(reports))
            service_id, thread_name, exception_type, source_file, line, message, formatted = reports[0]
            self.assertEqual(service_id, 'default')
            self.assertEqual(thread_name, 'fixture-worker')
            self.assertEqual(exception_type, 'ValueError')
            self.assertEqual(source_file, 'plugin0.py')
            self.assertGreater(line, 0)
            self.assertEqual(message, 'worker diagnostic fixture')
            self.assertIn('ValueError: worker diagnostic fixture', formatted)
        finally:
            if previous is None:
                vars(builtins).pop('_cctvhost_python_exception', None)
            else:
                builtins._cctvhost_python_exception = previous

    def test_urllib_response_body_limit_rejects_large_payload_with_service_context(self):
        payload = b'012345678'

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        reports = []
        previous_callback = vars(builtins).get('_cctvhost_python_resource_limit')
        previous_limit = runtime._max_http_response_bytes
        runtime._max_http_response_bytes = 8
        builtins._cctvhost_python_resource_limit = lambda *args: reports.append(args)
        try:
            url = 'http://127.0.0.1:%d/large' % server.server_port
            worker = self.launch("import builtins, urllib.request\n"
                                 "try:\n"
                                 " with urllib.request.urlopen(%r, timeout=2) as response:\n"
                                 "  response.read()\n"
                                 "except Exception as error:\n"
                                 " builtins._host_test_response_error = (type(error).__name__, str(error))\n" % url)
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(builtins._host_test_response_error[0], 'HTTPResponseTooLarge')
            self.assertIn('per-response limit (8 bytes)', builtins._host_test_response_error[1])
            self.assertEqual(reports[0], ('default', 'declared_body_too_large', 9, 8))
        finally:
            runtime._max_http_response_bytes = previous_limit
            if previous_callback is None:
                vars(builtins).pop('_cctvhost_python_resource_limit', None)
            else:
                builtins._cctvhost_python_resource_limit = previous_callback
            vars(builtins).pop('_host_test_response_error', None)
            server.shutdown()
            serving.join(1)
            server.server_close()

    def test_python_http_handlers_are_bounded_per_service_and_host(self):
        worker = self.launch(self.server_source(background=True))
        self.wait(lambda: bool(runtime._session and runtime._session.servers
                               and runtime._session.servers[0]._host_serving.is_set()))
        server = runtime._session.servers[0]
        self.assertIs(server._host_workers, runtime._session.http_worker_slots)
        self.assertEqual(server._host_workers._initial_value, 4)
        self.assertEqual(runtime._global_http_workers._initial_value, 12)
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        worker.join(1)

    def test_http_handler_limit_rejections_are_logged_without_leaking_slots(self):
        reports = []
        previous_callback = vars(builtins).get('_cctvhost_python_http_worker_rejected')
        previous_global_slots = runtime._global_http_workers

        class Request:
            closed = False

        class Server:
            _host_owner = type('Owner', (), {'identifier': 'worker-test'})()

            def __init__(self, slots):
                self._host_workers = slots

            def shutdown_request(self, request):
                request.closed = True

        builtins._cctvhost_python_http_worker_rejected = lambda *args: reports.append(args)
        try:
            service_slots = threading.BoundedSemaphore(1)
            service_slots.acquire()
            service_request = Request()
            runtime._process(Server(service_slots), service_request, ('127.0.0.1', 1))
            self.assertTrue(service_request.closed)
            self.assertEqual(reports.pop(), ('worker-test', 'per_service_handler_limit'))
            service_slots.release()

            runtime._global_http_workers = threading.BoundedSemaphore(0)
            host_request = Request()
            host_slots = threading.BoundedSemaphore(1)
            runtime._process(Server(host_slots), host_request, ('127.0.0.1', 1))
            self.assertTrue(host_request.closed)
            self.assertEqual(reports, [('worker-test', 'host_handler_limit')])
            self.assertEqual(host_slots._value, 1)
        finally:
            runtime._global_http_workers = previous_global_slots
            if previous_callback is None:
                vars(builtins).pop('_cctvhost_python_http_worker_rejected', None)
            else:
                builtins._cctvhost_python_http_worker_rejected = previous_callback

    def test_returned_main_with_background_server_is_still_running(self):
        worker = self.launch(self.server_source(background=True))
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertFalse(runtime.is_idle())
        script_path = os.path.realpath(self.temp.name)  # macOS exposes /var paths as /private/var in sys.path.
        self.assertIn(script_path, sys.path)  # Background handlers can still import local helpers.
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        self.assertTrue(runtime.is_idle())
        self.assertNotIn(script_path, sys.path)  # The next service cannot import stale helpers.

    def test_cooperative_stop_hook_accepts_none_and_waits_for_workers(self):
        worker = self.launch("import builtins, threading\n"
            "stop = threading.Event()\n"
            "builtins._cctvhost_stop_service = stop.set\n"
            "threading.Thread(target=stop.wait, daemon=True).start()\n"
            "stop.wait()\n")
        self.wait(lambda: hasattr(builtins, '_cctvhost_stop_service'))
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        worker.join(1)
        self.assertEqual(self.errors, [])

    def test_uncooperative_worker_prevents_replacement_and_can_finish_later(self):
        worker = self.launch("import builtins, threading\n"
            "threading.Thread(target=builtins._host_test_release.wait, name='pending-plugin-work', daemon=True).start()\n")
        worker.join(2)
        started = time.monotonic()
        self.assertFalse(runtime.stop_session(.1))
        self.assertLess(time.monotonic() - started, .5)
        self.assertIn('pending-plugin-work', runtime.last_error())
        with self.assertRaisesRegex(RuntimeError, 'previous service'):
            runtime.run_script('/unused.py')
        self.release.set()
        self.assertTrue(runtime.stop_session(2), runtime.last_error())

    def test_unstarted_listener_closes_without_shutdown_deadlock(self):
        worker = self.launch(self.server_source().replace('server.serve_forever()\n', ''))
        worker.join(2)
        server = runtime._session.servers[0]
        self.assertTrue(runtime.stop_session(1), runtime.last_error())
        self.assertEqual(server.fileno(), -1)

    def test_stale_callback_is_not_reused_for_new_script(self):
        stale = Mock()
        builtins._ysp_stop_server = stale
        worker = self.launch('answer = 42\n')
        worker.join(2)
        self.assertTrue(runtime.stop_session(1))
        stale.assert_not_called()
        self.assertEqual(self.errors, [])

    def test_blocked_stop_callback_is_bounded_and_not_started_twice(self):
        worker = self.launch("import builtins\n"
            "def stop():\n"
            " builtins._host_test_release.wait()\n"
            "builtins._cctvhost_stop_service = stop\n"
            "builtins._host_test_release.wait()\n")
        self.wait(lambda: hasattr(builtins, '_cctvhost_stop_service'))
        self.assertFalse(runtime.stop_session(.1))
        helpers = list(runtime._session.helpers)
        self.assertEqual(len(helpers), 1)
        self.assertFalse(runtime.stop_session(.1))
        self.assertEqual(runtime._session.helpers, helpers)
        self.release.set()
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        worker.join(1)

    def test_environment_updates_when_reusing_interpreter(self):
        import os
        runtime.configure_environment(self.temp.name, 18769)
        self.assertEqual(os.environ['YSP_DATA_DIR'], self.temp.name)
        self.assertEqual(os.environ['CCTVHOST_PORT'], '18769')
        runtime.configure_environment(self.temp.name + '/second', 18768)
        self.assertEqual(os.environ['YSP_DATA_DIR'], self.temp.name + '/second')
        self.assertEqual(os.environ['CCTVHOST_PORT'], '18768')

    def test_incomplete_http_headers_do_not_prevent_service_stop(self):
        worker = self.launch(self.server_source())
        self.wait(lambda: bool(runtime._session and runtime._session.servers and runtime._session.servers[0]._host_serving.is_set()))
        server = runtime._session.servers[0]
        client = socket.create_connection(server.server_address, timeout=1)
        try:
            client.sendall(b'GET / HTTP/1.0\r\n')
            self.wait(lambda: len(server._host_clients) == 1)
            self.assertTrue(runtime.stop_session(1), runtime.last_error())
        finally:
            client.close()
        worker.join(1)

    def test_managed_http_startup_never_waits_for_reverse_dns(self):
        with patch.object(socket, 'getfqdn', side_effect=RuntimeError('reverse DNS must not be used')):
            worker = self.launch(self.server_source())
            self.wait(lambda: bool(runtime._session and runtime._session.servers and runtime._session.servers[0]._host_serving.is_set()))
            self.assertEqual(self.errors, [])
            self.assertTrue(runtime.stop_session(1), runtime.last_error())
            worker.join(1)

    def test_script_system_exit_is_contained_and_next_service_can_run(self):
        worker = self.launch('import sys\nsys.exit(2)\n')
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.errors, [])
        self.assertTrue(runtime.is_idle())
        next_worker = self.launch('answer = 42\n')
        next_worker.join(1)
        self.assertEqual(self.errors, [])
        self.assertTrue(runtime.is_idle())
