import json
from pathlib import Path
import platform
import stat
import subprocess
import tempfile
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


if __name__ == '__main__':
    unittest.main()
