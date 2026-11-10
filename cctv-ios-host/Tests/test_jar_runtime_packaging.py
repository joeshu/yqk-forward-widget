import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('jar_packaging', ROOT / 'Scripts/optimize_jar_runtime.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class RuntimePackagingTests(unittest.TestCase):
    def test_sdk_pruning_preserves_classes_assets_services_and_unknown_resources(self):
        entries = {
            'android/app/Activity.class': b'\xca\xfe\xba\xbe Activity',
            'android/content/res/Resources.class': b'\xca\xfe\xba\xbe Resources',
            'assets/compatibility.txt': b'asset must survive',
            'META-INF/services/example.Provider': b'example.Implementation',
            'unknown/runtime.dat': b'unknown resources must survive',
            'res/drawable/wallpaper.png': b'wallpaper' * 1000,
            'resources.arsc': b'framework resource table',
            'AndroidManifest.xml': b'framework manifest',
        }
        with tempfile.TemporaryDirectory() as tmp:
            jar = Path(tmp) / packaging.SDK_JAR
            with zipfile.ZipFile(jar, 'w') as z:
                for key, value in entries.items():
                    z.writestr(key, value)
            report = packaging.optimize_sdk(jar)
            with zipfile.ZipFile(jar) as z:
                actual = {n: z.read(n) for n in z.namelist()}
            self.assertEqual(actual, {k: v for k, v in entries.items() if not k.startswith('res/') and k not in ('resources.arsc', 'AndroidManifest.xml')})
            self.assertEqual(report['preserved_classes'], 2)
            self.assertEqual(report['removed_entries'], 3)
            self.assertLess(report['after']['bytes'], report['before']['bytes'])
            self.assertEqual(packaging.optimize_sdk(jar)['removed_entries'], 0)

    def test_signed_or_unexpected_sdk_fails_without_replacing_original(self):
        for entries in ({'not-sdk.class': b'x'}, {
            'android/app/Activity.class': b'a', 'android/content/res/Resources.class': b'r',
            'META-INF/CERT.SF': b'signed', 'res/picture': b'p',
        }):
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as tmp:
                jar = Path(tmp) / packaging.SDK_JAR
                with zipfile.ZipFile(jar, 'w') as z:
                    for k, v in entries.items():
                        z.writestr(k, v)
                before = jar.read_bytes()
                with self.assertRaises(ValueError):
                    packaging.optimize_sdk(jar)
                self.assertEqual(jar.read_bytes(), before)

    def test_pinned_jlink_patch_is_idempotent_and_rejects_unknown_upstream(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'package.sh'
            script.write_text(packaging.ORIGINAL_LINK + '\n')
            packaging.configure(script)
            once = script.read_text()
            packaging.configure(script)
            self.assertEqual(script.read_text(), once)
            self.assertIn('--strip-debug --compress=zip-0', once)
            script.write_text('different upstream\n')
            with self.assertRaises(ValueError):
                packaging.configure(script)


if __name__ == '__main__':
    unittest.main()
