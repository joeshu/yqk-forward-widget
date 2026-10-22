import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "Scripts" / "python_bootstrap.py"
spec = importlib.util.spec_from_file_location("python_bootstrap", MODULE)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        home = Path(temp.name) / "python"
        stdlib = home / "lib/python3.13"
        dyn = stdlib / "lib-dynload"
        dyn.mkdir(parents=True)
        for name in bootstrap.REQUIRED_EXTENSIONS:
            (dyn / f"{name}.cpython-313-iphoneos.so").touch()
        (home / "ssl").mkdir()
        (home / "ssl/cert.pem").write_text("test CA placeholder")
        return temp, home, stdlib, dyn

    def test_paths_validate_device_extensions(self):
        temp, home, stdlib, dyn = self.fixture()
        with temp:
            self.assertEqual(bootstrap.runtime_paths(home), (stdlib, dyn))

    def test_missing_extension_fails_loudly(self):
        temp, home, _, dyn = self.fixture()
        with temp:
            next(dyn.glob("_ssl.*.so")).unlink()
            with self.assertRaisesRegex(RuntimeError, "_ssl"):
                bootstrap.runtime_paths(home)

    def test_configure_sets_paths_argv_and_ca(self):
        temp, home, stdlib, dyn = self.fixture()
        with temp:
            script = Path(temp.name) / "plugin.py"
            script.touch()
            data = Path(temp.name) / "data"
            bootstrap.configure(home, script, 9001, data)
            self.assertEqual(sys.path, [str(script.resolve().parent), str(stdlib), str(dyn)])
            self.assertEqual(sys.argv[0:2], [str(script.resolve()), "9001"])
            self.assertEqual(os.environ["SSL_CERT_FILE"], str(home / "ssl/cert.pem"))
            self.assertEqual(os.environ["YSP_DATA_DIR"], str(data))

    def test_missing_ca_fails_loudly(self):
        temp, home, _, _ = self.fixture()
        with temp:
            (home / "ssl/cert.pem").unlink()
            with self.assertRaisesRegex(RuntimeError, "CA bundle"):
                bootstrap.configure(home, Path(temp.name) / "p.py", 0, temp.name)


if __name__ == "__main__":
    unittest.main()
