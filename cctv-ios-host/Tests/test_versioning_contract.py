import pathlib
import plistlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class VersioningContractTests(unittest.TestCase):
    def test_app_bundle_has_valid_marketing_and_fallback_build_versions(self):
        with (ROOT / "Resources" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertRegex(info["CFBundleShortVersionString"], r"^\d+\.\d+(?:\.\d+)?$")
        self.assertRegex(info["CFBundleVersion"], r"^\d+(?:\.\d+){0,2}$")

    def test_ci_increments_marketing_version_per_build(self):
        build = (ROOT / "Scripts" / "ci-build.sh").read_text()
        workflow = (ROOT.parent / ".github" / "workflows" / "cctv-ios-host.yml").read_text()
        # Workflow reads the highest released version and bumps its last component.
        self.assertIn("gh release list", workflow)
        self.assertIn("CCTV_NEXT_VERSION", workflow)
        # ci-build.sh stamps the computed version into the built app when provided.
        self.assertIn("CCTV_NEXT_VERSION", build)
        self.assertIn("Set :CFBundleShortVersionString ${CCTV_NEXT_VERSION}", build)
        # Increment rule: last component +1 (1.1 -> 1.2, 1.9 -> 1.10).
        def bump(last):
            parts = last.split(".")
            parts[-1] = str(int(parts[-1]) + 1)
            return ".".join(parts)
        self.assertEqual(bump("1.1"), "1.2")
        self.assertEqual(bump("1.9"), "1.10")
        self.assertEqual(bump("1.1.0"), "1.1.1")

    def test_ui_reads_version_from_app_bundle(self):
        source = (ROOT / "Sources" / "RootViewController.m").read_text()
        self.assertIn('objectForInfoDictionaryKey:@"CFBundleShortVersionString"', source)
        self.assertNotRegex(source, r'kBuildTag\s*=\s*@"\d')

    def test_ci_build_stamps_incrementing_run_number_and_release_displays_it(self):
        build = (ROOT / "Scripts" / "ci-build.sh").read_text()
        workflow = (ROOT.parent / ".github" / "workflows" / "cctv-ios-host.yml").read_text()
        self.assertIn('GITHUB_RUN_NUMBER', build)
        self.assertIn('Set :CFBundleVersion ${GITHUB_RUN_NUMBER}', build)
        self.assertIn('Print :CFBundleShortVersionString', workflow)
        self.assertIn('--title "CCTVHost ${version} (${build})"', workflow)

    def test_slow_live_media_matrix_is_opt_in_for_release_runs(self):
        workflow = (ROOT.parent / ".github" / "workflows" / "cctv-ios-host.yml").read_text()
        self.assertIn("run_media_compat:", workflow)
        self.assertIn("default: false", workflow)
        self.assertIn("inputs.run_media_compat == true", workflow)


if __name__ == "__main__":
    unittest.main()
