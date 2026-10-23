import builtins
import importlib.util
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
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
        second = self.launch(self.server_source(port))
        self.wait(lambda: bool(runtime._session.servers and runtime._session.servers[0]._host_serving.is_set()))
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        second.join(1)
        self.assertEqual(self.errors, [])

    def test_returned_main_with_background_server_is_still_running(self):
        worker = self.launch(self.server_source(background=True))
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertFalse(runtime.is_idle())
        self.assertIn(self.temp.name, sys.path)  # Background handlers can still import local helpers.
        self.assertTrue(runtime.stop_session(2), runtime.last_error())
        self.assertTrue(runtime.is_idle())
        self.assertNotIn(self.temp.name, sys.path)  # The next service cannot import stale helpers.

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
