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
    @staticmethod
    def upstream(link):
        return packaging.NATIVE_START + '\n' + packaging.NATIVE_END + '\n' + link + '\n'

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
            script.write_text(self.upstream(packaging.ORIGINAL_LINK))
            packaging.configure(script)
            once = script.read_text()
            packaging.configure(script)
            self.assertEqual(script.read_text(), once)
            self.assertIn('--strip-debug --compress=zip-0', once)
            script.write_text('different upstream\n')
            with self.assertRaises(ValueError):
                packaging.configure(script)

    def test_known_v1_packaging_cache_upgrades_to_compiler_metadata_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'package.sh'
            script.write_text(self.upstream(packaging.V1_LINK))
            packaging.configure(script)
            expected = '\n'.join((packaging.NATIVE_GUARD, packaging.NATIVE_START,
                                  packaging.NATIVE_END, 'fi', packaging.OPTIMIZED_LINK, ''))
            self.assertEqual(script.read_text(), expected)
            self.assertIn("--exclude-resources='glob:/*/_the.*'", script.read_text())

    def test_changed_native_packaging_is_rejected_without_partial_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'package.sh'
            original = packaging.ORIGINAL_LINK + '\nunknown native setup\n'
            script.write_text(original)
            with self.assertRaises(ValueError):
                packaging.configure(script)
            self.assertEqual(script.read_text(), original)

    def test_module_filter_only_allows_exact_compiler_bookkeeping_names(self):
        original = ['Module: java.base', 'java/lang/Object.class', '_the.java.base_batch.filelist',
                    '_the.unrecognized', 'data/_the.java.base_batch.filelist',
                    'Module: java.xml', 'module-info.class', '_the.java.xml_internalapi',
                    'jdk/xml/internal/catalog.xml']
        kept, removed = packaging.retained_image_entries(original)
        self.assertEqual(removed, ['/java.base/_the.java.base_batch.filelist', '/java.xml/_the.java.xml_internalapi'])
        self.assertEqual(kept, [v for v in original if v not in ('_the.java.base_batch.filelist', '_the.java.xml_internalapi')])

    def test_compile_metadata_plan_removes_no_jvm_classes_or_services(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for name in packaging.COMPILE_METADATA_JARS:
                with zipfile.ZipFile(folder / name, 'w') as z:
                    z.writestr('META-INF/MANIFEST.MF', b'Manifest-Version: 1.0\n')
                    z.writestr('package/Declaration.kotlin_metadata', b'compiler metadata')
            plan = packaging.metadata_archive_plan(folder)
            self.assertEqual(set(plan), set(packaging.COMPILE_METADATA_JARS))
            self.assertTrue(all((folder / name).exists() for name in plan))
            for unexpected in ('package/Actual.class', 'META-INF/services/example.Provider', 'runtime/config.json'):
                with self.subTest(entry=unexpected):
                    path = folder / packaging.COMPILE_METADATA_JARS[0]
                    with zipfile.ZipFile(path, 'w') as z:
                        z.writestr(unexpected, b'actual runtime data')
                    before = path.read_bytes()
                    with self.assertRaises(ValueError):
                        packaging.metadata_archive_plan(folder)
                    self.assertEqual(path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
