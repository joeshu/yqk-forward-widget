import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
SOURCES = ROOT / "Sources"


class LivePluginsAndSubscriptionPagePerfTests(unittest.TestCase):
    def test_01_subscription_resource_vc_uses_cached_profile_cell_reuse_and_in_place_switch_feedback(self):
        sub_m = (SOURCES / "SubscriptionResourceViewController.m").read_text(encoding="utf-8")
        root_m = "\n".join((p.read_text(encoding="utf-8").split("\n- (BOOL)sessionHasContent;", 1)[0] if p.name.endswith(".h") else p.read_text(encoding="utf-8")) for p in ([SOURCES / "RootViewController_Internal.h", *sorted(SOURCES.glob("RootViewController*.m"))]))
        service_m = (SOURCES / "ServiceStore.m").read_text(encoding="utf-8")
        profile_m = (SOURCES / "ProfileStore.m").read_text(encoding="utf-8")
        settings_m = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")

        # 1. SubscriptionResourceViewController caches profile per reload and reuses table cells
        self.assertIn("@property(nonatomic,copy) NSDictionary *cachedProfile;", sub_m)
        self.assertIn("- (void)refreshCachedProfile", sub_m)
        self.assertIn("dequeueReusableCellWithIdentifier:reuseID", sub_m)
        self.assertIn("- (void)applyInPlaceSwitchFeedbackForRow:", sub_m)
        self.assertIn("self.suppressMetadataReload=YES;", sub_m)
        self.assertNotIn(
            "NSDictionary *profile=self.profileProvider?self.profileProvider():@{};",
            sub_m,
            "cellForRowAtIndexPath: must read cachedProfile instead of invoking profileProvider on every row",
        )

        # 2. RootViewController provides O(1) configurationProfileForSource: and native source refresh support
        self.assertIn("- (NSDictionary *)configurationProfileForSource:(NSString *)source", root_m)
        self.assertIn("[owner configurationProfileForSource:current]", root_m)
        self.assertIn("[weakSelf refreshSubscriptionForProfile:weakPage.source?:source]", root_m)
        self.assertIn('@"内置官方 · 节目单已同步"', root_m)
        self.assertIn('@"内置官方 · 健康检测通过"', root_m)

        # 3. ServiceStore caches file-level code analysis via NSCache
        self.assertIn("ServiceEntryAnalysisCache(void)", service_m)
        self.assertIn("+ (NSDictionary *)cachedCodeAnalysisForEntryPath:(NSString *)entry", service_m)

        # 4. All 4 resource switches default to OFF (NO) and can be manually enabled
        for enabled_key in (
            "enabledChannelLogoSources",
            "enabledPlayerCornerLogoSources",
            "enabledChannelPreviewSources",
            "enabledChannelTelemetrySources",
        ):
            self.assertIn(enabled_key, profile_m)
        self.assertIn("// 默认全部关闭，需由用户手动开启\n    return NO;", profile_m)
        self.assertIn('@"key":@"nativeChannelLogoEnabled", @"icon":@"sparkles.tv", @"default":@NO', settings_m)
        self.assertIn('@"key":@"nativeChannelPreviewEnabled", @"icon":@"photo.tv", @"default":@NO', settings_m)
        self.assertIn('@"key":@"nativeChannelTelemetryEnabled", @"icon":@"speedometer", @"default":@NO', settings_m)

        # 5. Channel preview captures real video frames via AVAssetImageGenerator on channel list refresh (no fake procedural card)
        self.assertIn("- (void)refreshChannelPreviewSnapshotsForChannels:(NSArray<NSDictionary *> *)channels force:(BOOL)force", root_m)
        self.assertIn("- (void)detectRealPreviewFrameForChannel:(NSDictionary *)channel force:(BOOL)force", root_m)
        self.assertIn("AVAssetImageGenerator *generator=[AVAssetImageGenerator assetImageGeneratorWithAsset:asset];", root_m)
        self.assertIn("generateCGImagesAsynchronouslyForTimes:", root_m)
        self.assertNotIn("bezierPathWithOvalInRect:CGRectMake(-20,-20,140,95)", root_m)

    def test_02_ysp_and_cbox_live_plugins_run_and_stop_cleanly_in_cctvhost_runtime(self):
        ysp_path = REPO_ROOT / "ysp_live_plugin.py"
        cbox_path = REPO_ROOT / "cbox_live_plugin.py"
        self.assertTrue(ysp_path.is_file(), f"Missing {ysp_path}")
        self.assertTrue(cbox_path.is_file(), f"Missing {cbox_path}")

        ysp_src = ysp_path.read_text(encoding="utf-8")
        self.assertIn("__version__ = '2.2.0'", ysp_src)
        self.assertIn("CCTVHOST_PORT", ysp_src)
        self.assertIn("CCTVHOST_DATA_DIR", ysp_src)
        self.assertIn("_host_media_stream_read = True", ysp_src)
        self.assertIn('catchup="default" catchup-days="7" catchup-source="%s/live/%s.m3u8?start=${start}&end=${end}%s"', ysp_src)
        self.assertNotIn("garysclub.sharewithyou.dpdns.org", ysp_src)

        cbox_src = cbox_path.read_text(encoding="utf-8")
        self.assertIn("__version__ = '1.2.0'", cbox_src)
        self.assertIn("CCTVHOST_PORT", cbox_src)
        self.assertIn("CCTVHOST_DATA_DIR", cbox_src)
        self.assertIn("_host_media_stream_read = True", cbox_src)
        self.assertIn("_build_builtin_catalog", cbox_src)

        code = r'''
import http.client, json, pathlib, shutil, socket, sys, tempfile, threading, time
root = pathlib.Path(sys.argv[1])
repo_root = root.parent
sys.path.insert(0, str(root / 'Scripts'))
import host_service_runtime as runtime

for name, expected_ver in [('ysp_live_plugin.py', '2.2.0'), ('cbox_live_plugin.py', '1.2.0')]:
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        script = work / name
        shutil.copyfile(repo_root / name, script)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        sid = 'verify-' + name
        argv = ['--port', str(port), '--bind', '127.0.0.1', '--no-4k', '--data-dir', str(work), '--cache-mb', '16', '--serve']
        errors = []
        def _run(p=script, i=sid, w=work, pt=port, a=argv):
            try:
                runtime.run_script(str(p), i, str(w), pt, a)
            except BaseException as exc:
                errors.append(repr(exc))
        th = threading.Thread(target=_run, daemon=True)
        th.start()
        deadline = time.monotonic() + 6.0
        while time.monotonic() < deadline:
            state = runtime._sessions.get(sid)
            if state and state.servers and state.servers[0]._host_serving.is_set():
                break
            time.sleep(0.02)
        assert state and state.servers and state.servers[0]._host_serving.is_set(), f"{name} failed: {errors}"
        c = http.client.HTTPConnection('127.0.0.1', port, timeout=2.0)
        c.request('GET', '/health')
        r = c.getresponse()
        h = json.loads(r.read().decode())
        assert r.status == 200 and h['ok'] and h['version'] == expected_ver, h
        c.request('GET', '/all.m3u')
        r = c.getresponse()
        m3u = r.read().decode()
        assert r.status == 200 and m3u.startswith('#EXTM3U') and 'https://app.cctv.com/special/appchannellogo/square/l/cctv1.png?q=75' in m3u
        if name == 'ysp_live_plugin.py':
            assert 'catchup="default" catchup-days="7"' in m3u
            ns = state.servers[0].RequestHandlerClass.do_GET.__globals__
            sample_pl = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg001.ts\n'
            direct_out = ns['rewrite'](sample_pl, 'https://cdn.example.com/live/cctv1/index.m3u8', f'http://127.0.0.1:{port}', {'User-Agent': 'qqlive'}, 'cctv1')
            assert 'https://cdn.example.com/live/cctv1/seg001.ts' in direct_out, direct_out
            signed_out = ns['rewrite'](sample_pl, 'https://cdn.example.com/live/cctv4k/index.m3u8', f'http://127.0.0.1:{port}', {'APPSIGN': 'sig123', 'UID': 'u1'}, 'cctv4k')
            assert f'http://127.0.0.1:{port}/seg/' in signed_out, signed_out
        c.close()
        t0 = time.monotonic()
        assert runtime.stop_session(sid, 4.0), runtime.last_error(sid)
        dt = time.monotonic() - t0
        th.join(1.0)
        assert not th.is_alive() and runtime.is_idle(sid) and dt < 1.5 and not errors, (dt, errors)
print('LIVE_PLUGINS_RUNTIME_OK')
'''
        res = subprocess.run([sys.executable, "-c", code, str(ROOT)], capture_output=True, text=True, timeout=25)
        self.assertEqual(res.returncode, 0, res.stdout[-2000:] + res.stderr[-2000:])
        self.assertIn("LIVE_PLUGINS_RUNTIME_OK", res.stdout)


if __name__ == "__main__":
    unittest.main()
