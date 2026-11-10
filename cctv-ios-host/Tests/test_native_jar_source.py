from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativeJARSourceTests(unittest.TestCase):
    def test_import_and_request_preserve_class_ext_and_opaque_identifiers(self):
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe=str(Path(tmp)/'jar-source')
            build=subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-lz','-I',str(root/'Sources'),str(root/'Tests/native_jar_source_tests.m'),str(root/'Sources/TVBoxCatalogStore.m'),'-o',exe],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([exe],capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
