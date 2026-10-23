import json
import hashlib
import http.server
from pathlib import Path
import platform
import stat
import subprocess
import tempfile
import threading
import unittest
import zipfile


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.tmp.name)
        root = Path(__file__).resolve().parents[1]
        cls.executable = cls.folder / 'package-test'
        build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-lz', '-I', str(root / 'Sources'),
                                str(root / 'Tests/native_package_tests.m'), str(root / 'Sources/MediaPackageImporter.m'),
                                str(root / 'Sources/MediaPackageDownloader.m'),
                                str(root / 'Sources/ServiceStore.m'), '-o', str(cls.executable)], capture_output=True, text=True)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def inspect(self, file):
        result = subprocess.run([str(self.executable), str(file)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def archive(self, entries):
        file = self.folder / 'fixture.zip'
        with zipfile.ZipFile(file, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, content in entries.items():
                archive.writestr(name, content)
        return file

    def test_zip_manifest_esm_dependencies_and_original_archive_are_preserved(self):
        file = self.archive({'wrapped/cctvhost.json': json.dumps({'schemaVersion': 1, 'name': '中文影视', 'entry': 'src/index.mjs', 'runtime': 'javascript', 'protocol': 'cctvhost.media/1'}),
                             'wrapped/src/index.mjs': 'import value from "./value.js";export default {search(){return []}}',
                             'wrapped/src/value.js': 'export default 1'})
        result = self.inspect(file)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['name'], result['engine'], result['manifest']['moduleType']), ('中文影视', 'javascript', 'esm'))
        self.assertTrue(result['entryExists'])
        self.assertTrue(result['archiveExists'])

    def test_commonjs_node_require_is_routed_to_node_unless_manifest_overrides(self):
        source = "const fs=require('fs');module.exports={search(){return {list:[]}}}"
        inferred = self.inspect(self.archive({'index.js': source}))
        self.assertTrue(inferred['ok'], inferred)
        self.assertEqual((inferred['engine'], inferred['manifest']['moduleType']), ('node', 'commonjs'))

        explicit = self.inspect(self.archive({'index.js': source,
            'cctvhost.json': json.dumps({'entry': 'index.js', 'runtime': 'javascript',
                                         'protocol': 'cctvhost.media/1'})}))
        self.assertTrue(explicit['ok'], explicit)
        self.assertEqual(explicit['engine'], 'javascript')

    def test_package_dependencies_default_to_node_for_esm(self):
        result = self.inspect(self.archive({'package.json': json.dumps({'type': 'module',
                                                                       'dependencies': {'example': '^1.0.0'}}),
                                           'index.js': 'export default {search(){return {list:[]}}}'}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['manifest']['moduleType']), ('node', 'esm'))

    def test_python_spider_is_recognized_without_executing_user_code(self):
        marker = self.folder / 'must-not-run'
        file = self.folder / '看剧.py'
        file.write_text(f'from pathlib import Path\nPath({str(marker)!r}).write_text("bad")\nclass Spider: pass\n')
        result = self.inspect(file)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('python', 'python-spider'))
        self.assertFalse(marker.exists())

    def test_traversal_symlink_duplicate_and_bad_crc_are_rejected(self):
        for path in ('../escaped.py', '/absolute.py', 'directory/../../escaped.py', 'C:/escaped.py'):
            self.assertFalse(self.inspect(self.archive({path: 'class Spider: pass'}))['ok'], path)
        file = self.folder / 'link.zip'
        with zipfile.ZipFile(file, 'w') as archive:
            entry = zipfile.ZipInfo('index.py')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, '../outside')
        self.assertFalse(self.inspect(file)['ok'])
        self.assertFalse(self.inspect(self.archive({'Index.js': 'var plugin={}', 'index.js': 'var plugin={}'}))['ok'])
        file = self.archive({'index.js': 'export default {search(){return []}}'})
        data = bytearray(file.read_bytes())
        data[30 + len('index.js')] ^= 0x10
        file.write_bytes(data)
        self.assertFalse(self.inspect(file)['ok'])

    def test_invalid_manifest_types_and_unknown_runtime_do_not_crash(self):
        for manifest in ({'entry': 42}, {'entry': '../outside.py'}, {'entry': 'index.js', 'runtime': 'java'},
                         {'entry': 'index.js', 'capabilities': [None]}, {'entry': 'index.js', 'moduleType': 'native'},
                         {'entry': 'index.js', 'schemaVersion': 99}):
            result = self.inspect(self.archive({'index.js': 'export default {search(){return []}}', 'cctvhost.json': json.dumps(manifest)}))
            self.assertFalse(result['ok'], manifest)

    def test_single_file_size_and_expansion_limits(self):
        file = self.archive({'index.js': b'x' * (8 * 1024 * 1024 + 1)})
        self.assertFalse(self.inspect(file)['ok'])

    def test_md5_pair_downloads_original_code_and_rejects_mismatch_and_limits(self):
        source = b'module.exports={search(){return {list:[]}}}'
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                body = source
                if self.path.endswith('.md5'):
                    body = (hashlib.md5(source).hexdigest() if self.path == '/index.cjs.md5' else '0' * 32).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(25 * 1024 * 1024 if self.path == '/oversize.js' else len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            result = self.inspect(base + '/index.cjs.md5')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['manifest']['moduleType'], 'commonjs')
            self.assertFalse(self.inspect(base + '/mismatch.js.md5')['ok'])
            self.assertFalse(self.inspect(base + '/oversize.js')['ok'])
            self.assertFalse(self.inspect(base + '/unsupported.txt')['ok'])
        finally:
            server.shutdown();server.server_close();thread.join(2)


if __name__ == '__main__':
    unittest.main()
