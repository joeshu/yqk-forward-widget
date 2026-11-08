import http.client
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(ROOT / "Plugins") not in sys.path:
    sys.path.insert(0, str(ROOT / "Plugins"))

from host_media_relay import MediaRelay

HOST = ROOT / "Plugins" / "node-plugin-host.cjs"


class WeBoxAndYqkAdaptationTests(unittest.TestCase):
    def test_01_builtin_webox_scripts_and_index_exist_and_parse(self):
        builtin_dir = ROOT / "Resources" / "BuiltinMedia"
        index_path = builtin_dir / "webox-index.json"
        self.assertTrue(index_path.is_file())
        index_data = json.loads(index_path.read_text(encoding="utf-8"))
        self.assertEqual(len(index_data["sites"]), 5)
        self.assertEqual(len(index_data["sources"]), 5)
        for fname in ("webox-4kvm.js", "webox-hstream.js", "webox-guazi.js", "webox-rou.js", "webox-one.js"):
            p = builtin_dir / fname
            self.assertTrue(p.is_file(), f"Missing {fname}")
            text = p.read_text(encoding="utf-8")
            self.assertIn("WeBox.define(", text)

    @unittest.skipUnless(shutil.which("node"), "requires Node")
    def test_02_4kvm_pure_js_wasm_fallback_matches_wasm_and_works_in_jitless(self):
        script_path = ROOT / "Resources" / "BuiltinMedia" / "webox-4kvm.js"
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("generatePlayUrlPureJS", text)

        fn_start = text.index("async function kvmBuildRequest(")
        fn_end = text.index("// Bundled public module:")
        fn_code = text[fn_start:fn_end]
        node = shutil.which("node")
        harness = f"""
const fn = {fn_code};
(async () => {{
  Date.now = () => 1762570005432;
  const out = await fn({{
    dataid: "98765",
    episodeId: "ep_abc123",
    quality: "1080",
    playKey: "user_link_secret_xyz",
    serverTime: "1762570000",
    loadedAt: String(1762570005432 - 3200),
  }}, {{}});
  console.log("URL:" + out.url);
}})().catch(e => {{ console.error(e); process.exit(1); }});
"""
        proc = subprocess.run([node, "--jitless", "-e", harness], capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(
            "URL:/video/play?p=98765&v=ep_abc123&q=1080&s=7278dd320e995123de307f217f9c11cc&t=1762573200&k=GxEIHSkFDFxbbUcWBhEXESsTHAM=",
            proc.stdout,
        )

    @unittest.skipUnless(shutil.which("node"), "requires Node")
    def test_03_all_five_webox_plugins_load_in_node_host_jitless(self):
        builtin_dir = ROOT / "Resources" / "BuiltinMedia"
        node = shutil.which("node")
        with tempfile.TemporaryDirectory(dir=str(ROOT.parent)) as tmp:
            root = pathlib.Path(tmp)
            packages = root / "Services"
            packages.mkdir()
            data_dir = packages / "data"
            data_dir.mkdir()
            info_path = root / "control.json"
            token = "test-token-" + os.urandom(8).hex()
            env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
            proc = subprocess.Popen(
                [node, "--jitless", str(HOST), str(info_path), token, str(packages)],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                deadline = time.monotonic() + 8
                while not info_path.exists() and time.monotonic() < deadline:
                    if proc.poll() is not None:
                        self.fail("Node host exited: " + proc.stderr.read().decode())
                    time.sleep(0.02)
                self.assertTrue(info_path.exists())
                port = json.loads(info_path.read_text(encoding="utf-8"))["port"]

                def call(op, session, **kwargs):
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    try:
                        body = json.dumps({"operation": op, "payload": dict(kwargs, session=session)})
                        conn.request("POST", "/control", body, {"X-CCTVHost-Token": token, "Content-Type": "application/json"})
                        resp = conn.getresponse()
                        return json.loads(resp.read())
                    finally:
                        conn.close()

                for idx, fname in enumerate(("webox-4kvm.js", "webox-hstream.js", "webox-guazi.js", "webox-rou.js", "webox-one.js")):
                    with self.subTest(script=fname):
                        pkg_dir = packages / f"pkg_{idx}"
                        pkg_dir.mkdir(exist_ok=True)
                        (pkg_dir / "index.js").write_text((builtin_dir / fname).read_text(encoding="utf-8"), encoding="utf-8")
                        sess = f"s_{idx}"
                        started = call(
                            "start",
                            sess,
                            packageRoot=str(pkg_dir),
                            dataDirectory=str(data_dir),
                            entry="index.js",
                            protocol="cctvhost.media/1",
                            moduleType="script",
                            options={},
                        )
                        self.assertTrue(started.get("ok"), f"{fname} start failed: {started}")
                        caps = call("capabilities", sess)
                        self.assertTrue(caps.get("ok"), f"{fname} capabilities failed: {caps}")
                        for expected_cap in ("home", "category", "search", "detail", "play"):
                            self.assertIn(expected_cap, caps.get("result", {}).get("capabilities", []))
                        call("stop", sess)
            finally:
                proc.terminate()
                proc.communicate(timeout=5)

    def test_04_rou_png_segment_unwrapping_and_inline_manifest(self):
        relay = MediaRelay()
        try:
            manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nhttps://v.r168.net/seg0.png\n#EXT-X-ENDLIST\n"
            token = relay.register_inline_manifest(
                manifest,
                base_url="https://rou.video/v/test",
                headers={"Referer": "https://rou.video/"},
                diagnostic_id="rou-inline-test",
            )
            self.assertIn(token, relay.inline_manifests)

            # Build synthetic PNG with roUd chunk (1-byte flags=1 + zlib compressed TS packet)
            ts_payload = b"\x47" + b"\x11" * 187 + b"\x47" + b"\x22" * 187
            compressed = zlib.compress(ts_payload)
            roud_data = b"\x01" + compressed
            roud_chunk = struct.pack(">I", len(roud_data)) + b"roUd" + roud_data + b"\x00\x00\x00\x00"
            iend_chunk = struct.pack(">I", 0) + b"IEND" + b"\xae\x42\x60\x82"
            png_bytes = b"\x89PNG\r\n\x1a\n" + roud_chunk + iend_chunk

            unwrapped = MediaRelay._unwrap_rou_png_bytes(png_bytes)
            self.assertEqual(unwrapped, ts_payload)
        finally:
            relay.close()

    def test_05_resource_page_icon_removed_and_drag_reorder_contracts(self):
        cc = (ROOT / "Sources" / "ConfigCenterViewController.m").read_text(encoding="utf-8")
        self.assertIn("self.iconBadgeContainer.hidden=YES;", cc)
        self.assertIn("UITableViewDragDelegate, UITableViewDropDelegate", cc)
        self.assertIn("self.tableView.dragInteractionEnabled = YES;", cc)
        self.assertIn("itemsForBeginningDragSession", cc)
        self.assertIn("performDropWithCoordinator", cc)
        self.assertIn("moveRowAtIndexPath", cc)
        self.assertIn('@"resourceUnifiedOrder"', cc)

    def test_06_yqk_and_resource_import_workflow_contracts(self):
        entry_mjs = (ROOT / "JSPlugins" / "generic" / "entry.mjs").read_text(encoding="utf-8")
        self.assertIn("patchLegacyPluginSource", entry_mjs)
        self.assertIn("createWeBoxPlugin", entry_mjs)
        downloader = (ROOT / "Sources" / "MediaPackageDownloader.m").read_text(encoding="utf-8")
        self.assertIn("PackageApplyYqkPlaybackFixes", downloader)
        self.assertIn("PackageBundledWeBoxScriptForURL", downloader)
        wf = (ROOT / "Sources" / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        self.assertIn("pasteAndRecognizeButton", wf)
        self.assertIn("ResourceImportNormalizedURL", wf)
        self.assertIn("discardUncommittedCandidatesForFreshRecognition", wf)



    def test_unified_immersive_top_chrome_and_zero_jump_media_detail_transition(self):
        theme = (ROOT / "Sources/HostTheme.h").read_text(encoding="utf-8")
        browser = (ROOT / "Sources/MediaBrowserViewController.m").read_text(encoding="utf-8")
        root = (ROOT / "Sources/RootViewController.m").read_text(encoding="utf-8")
        config = (ROOT / "Sources/ConfigCenterViewController.m").read_text(encoding="utf-8")
        settings = (ROOT / "Sources/SettingsViewController.m").read_text(encoding="utf-8")

        self.assertIn("HostStatusBarSafeTop", theme)
        self.assertIn("HostUpdateImmersiveTopScrim", theme)
        self.assertIn("syncStableTopHeaderLayout", browser)
        self.assertIn("prepareForNavigationTransition", browser)
        self.assertIn("refreshHeaderAfterNavigationTransition", browser)
        self.assertIn("else if(viewController==self&&navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:animated];", root)
        self.assertIn("catalogTopImmersiveScrim", root)
        self.assertIn("HostStatusBarSafeTop", config)
        self.assertIn("settingsTopImmersiveScrim", settings)


if __name__ == "__main__":
    unittest.main()
