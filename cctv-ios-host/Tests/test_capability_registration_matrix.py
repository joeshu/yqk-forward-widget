"""T11 能力注册矩阵：门禁按引擎区分 + build-specific 能力快照。

行为模型复刻 Sources/MediaPlaybackDecodeRouter.m 的入口门禁：
  webOnly 容器 → 不支持编码 → 不支持传输；容器与编码门禁只在"能实际
  走 MPV 的路径"才旁路（点播 + MPV 已启用）。直播不走 MPV，同一结果在
  直播下仍拒绝——这是 T11 关掉的旧漏洞：旧代码无条件拒绝 vp9/av1 等
  编码（与 MPV 候选链矛盾），而直播 .avi 在 MPV 开启时曾绕过容器门禁
  拿到 Cicada 候选（Cicada 根本解不了 avi）。
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
PLUGINS = ROOT / "Plugins"
SCRIPTS = ROOT / "Scripts"

MPV_ONLY_CODECS = {"vp8", "vp9", "av1", "h263", "wmv", "rv"}
MPV_ONLY_CONTAINERS = {"avi", "wmv", "asf", "rm", "rmvb"}
NETWORK_TRANSPORTS = {"http", "https", "rtmp", "rtmps"}


def read(path):
    return path.read_text(encoding="utf-8")


def gate_model(result, for_live, mpv_enabled):
    """Mirror of MediaPlaybackDecodeRouteRejectionReasonForResult:forLive:."""
    fmt = (result.get("format") or "").lower()
    ext = (result.get("extension") or "").lower()
    if not (not for_live and mpv_enabled):
        if fmt in MPV_ONLY_CONTAINERS or ext in MPV_ONLY_CONTAINERS:
            return "unsupported_container"
    codec = (result.get("videoCodec") or "").lower()
    if codec in MPV_ONLY_CODECS and (for_live or not mpv_enabled):
        return "unsupported_video_codec"
    scheme = (result.get("scheme") or "").lower()
    if scheme not in NETWORK_TRANSPORTS and scheme != "file":
        return "unsupported_transport"
    return None


class GateBehaviorTests(unittest.TestCase):
    def test_vod_mpv_enabled_vp9_allowed(self):
        self.assertIsNone(gate_model(
            {"scheme": "http", "format": "mp4", "videoCodec": "vp9"}, False, True))

    def test_vod_mpv_disabled_vp9_rejected(self):
        self.assertEqual(gate_model(
            {"scheme": "http", "format": "mp4", "videoCodec": "vp9"}, False, False),
            "unsupported_video_codec")

    def test_live_mpv_enabled_vp9_still_rejected(self):
        # 直播不走 MPV：无可用引擎，仍拒绝，而不是把 vp9 丢给 Cicada。
        self.assertEqual(gate_model(
            {"scheme": "http", "format": "mp4", "videoCodec": "vp9"}, True, True),
            "unsupported_video_codec")

    def test_each_mpv_only_codec_follows_mpv_enabled(self):
        for codec in sorted(MPV_ONLY_CODECS):
            result = {"scheme": "http", "format": "mp4", "videoCodec": codec}
            self.assertIsNone(gate_model(result, False, True), codec)
            self.assertEqual(gate_model(result, False, False), "unsupported_video_codec", codec)
            self.assertEqual(gate_model(result, True, True), "unsupported_video_codec", codec)

    def test_vod_mpv_enabled_avi_allowed(self):
        self.assertIsNone(gate_model(
            {"scheme": "http", "format": "avi", "extension": "avi"}, False, True))

    def test_vod_mpv_disabled_avi_rejected(self):
        self.assertEqual(gate_model(
            {"scheme": "http", "format": "avi", "extension": "avi"}, False, False),
            "unsupported_container")

    def test_live_mpv_enabled_avi_still_rejected(self):
        # T11 关掉的旧漏洞：直播 .avi 曾绕过容器门禁拿到 Cicada 候选。
        self.assertEqual(gate_model(
            {"scheme": "http", "format": "avi", "extension": "avi"}, True, True),
            "unsupported_container")

    def test_each_legacy_container_follows_mpv_enabled(self):
        for container in sorted(MPV_ONLY_CONTAINERS):
            result = {"scheme": "http", "format": container, "extension": container}
            self.assertIsNone(gate_model(result, False, True), container)
            self.assertEqual(gate_model(result, False, False), "unsupported_container", container)
            self.assertEqual(gate_model(result, True, True), "unsupported_container", container)

    def test_rtsp_rejected_regardless_of_mpv_or_live(self):
        for for_live in (False, True):
            for mpv in (False, True):
                self.assertEqual(gate_model(
                    {"scheme": "rtsp", "format": "", "extension": ""}, for_live, mpv),
                    "unsupported_transport")

    def test_hls_and_mp4_always_allowed(self):
        for result in ({"scheme": "http", "format": "hls"},
                       {"scheme": "https", "format": "mp4", "videoCodec": "h264"}):
            for for_live in (False, True):
                for mpv in (False, True):
                    self.assertIsNone(gate_model(result, for_live, mpv))

    def test_file_url_allowed(self):
        self.assertIsNone(gate_model(
            {"scheme": "file", "format": "mp4"}, False, False))

    def test_cenc_proxy_checks_url_not_original_url(self):
        # 红果 cenc：originalURL 是 cenc://，可播地址在 url 字段里；门禁只看 url。
        self.assertIsNone(gate_model(
            {"scheme": "http", "format": "mp4"}, False, False))


class GateWiringContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.router_m = read(SOURCES / "MediaPlaybackDecodeRouter.m")
        cls.router_h = read(SOURCES / "MediaPlaybackDecodeRouter.h")
        cls.descriptor_m = read(SOURCES / "MediaDescriptor.m")
        cls.registry_h = read(SOURCES / "MediaCapabilityRegistry.h")

    def test_for_live_variant_declared_and_implemented(self):
        self.assertIn("MediaPlaybackDecodeRouteRejectionReasonForResult(NSDictionary * _Nullable result, BOOL forLive)",
                      self.router_h)
        self.assertRegex(self.router_m,
                         r"MediaPlaybackDecodeRouteRejectionReasonForResult\(NSDictionary \*result, BOOL forLive\)")

    def test_vod_wrapper_delegates_to_for_live_variant(self):
        self.assertIn("return MediaPlaybackDecodeRouteRejectionReasonForResult(result, NO);",
                      self.router_m)

    def test_codec_gate_uses_mpv_only_list_not_flat_list(self):
        body = self.router_m[self.router_m.index("forLive) {"):self.router_m.index("return nil;\n}", self.router_m.index("forLive) {"))]
        self.assertIn("MediaCapabilityMPVOnlyVideoCodecs()", body)
        self.assertNotIn("MediaCapabilityUnsupportedVideoCodecs()", body)
        self.assertIn("forLive || !MediaPlaybackMPVRouteEnabled()", body)

    def test_container_helper_has_mpv_bypass_flag(self):
        self.assertIn("MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(NSDictionary *result, BOOL mpvBypassAllowed)",
                      self.router_m)
        self.assertIn("return MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(result, YES);",
                      self.router_m)
        self.assertIn("MediaPlaybackResultRequiresWebViewOnlyWithMPVBypass(result, !forLive)",
                      self.router_m)

    def test_candidate_function_uses_for_live_gate(self):
        self.assertIn("MediaPlaybackDecodeRouteRejectionReasonForResult(result, forLive)",
                      self.router_m)

    def test_descriptor_still_uses_vod_wrapper(self):
        self.assertIn("MediaPlaybackDecodeRouteRejectionReasonForResult(_result)",
                      self.descriptor_m)
        self.assertNotIn("forLive", self.descriptor_m)

    def test_registry_has_per_engine_accessors(self):
        self.assertIn("MediaCapabilityMPVOnlyVideoCodecs(void)", self.registry_h)
        self.assertIn("MediaCapabilityMPVOnlyContainers(void)", self.registry_h)

    def test_registry_generator_check_passes(self):
        proc = subprocess.run([sys.executable, str(SCRIPTS / "generate_media_capabilities.py"), "--check"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)


class SnapshotGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot_py = SCRIPTS / "generate_capability_snapshot.py"
        cls.registry = json.loads(read(PLUGINS / "media-capabilities.json"))

    def _run(self, *args):
        return subprocess.run([sys.executable, str(self.snapshot_py), *args],
                              capture_output=True, text=True)

    def test_check_passes(self):
        proc = self._run("--check")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("capability snapshot OK", proc.stdout)

    def test_snapshot_has_eight_groups_and_no_device_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "snap.json"
            proc = self._run("--version", "1.73", "--build", "631", "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            snap = json.loads(out.read_text())
            self.assertEqual(len(snap["groups"]), 8)
            self.assertEqual([g["id"] for g in snap["groups"]],
                             ["core-vod", "unconnected-transports", "legacy-codecs",
                              "cenc-drm", "encrypted-mp4", "hdr", "pip", "airplay"])
            self.assertEqual(snap["build"]["version"], "1.73")
            self.assertEqual(snap["build"]["build"], "631")
            self.assertEqual(snap["build"]["version_source"], "cli")
            self.assertEqual(snap["protocol_capabilities"], self.registry["protocolCapabilities"])
            for group in snap["groups"]:
                self.assertEqual(group["device_verification"]["status"], "pending_device_verification")
                for engine in group["engines"].values():
                    self.assertFalse(engine["device_verified"],
                                     "%s claims device_verified without evidence" % group["id"])

    def test_no_overclaim_in_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "snap.json"
            self._run("--out", str(out))
            snap = json.loads(out.read_text())
            by_id = {g["id"]: g for g in snap["groups"]}
            transports = by_id["unconnected-transports"]["engines"]
            for engine in transports.values():
                self.assertFalse(engine["creatable"])
                self.assertFalse(engine["presentable"])
            self.assertFalse(by_id["pip"]["engines"]["mpv"]["presentable"])
            self.assertFalse(by_id["pip"]["engines"]["cicada"]["creatable"])
            self.assertFalse(by_id["airplay"]["engines"]["mpv"]["presentable"])
            self.assertIn("不宣称", by_id["hdr"]["engines"]["av"]["note"])

    def test_device_evidence_flips_only_the_matching_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "snap.json"
            self._run("--version", "1.73", "--build", "631", "--out", str(out))
            snap = json.loads(out.read_text())
            evidence = {"groups": {"core-vod": {
                "version": "1.73", "build": "631", "commit": snap["build"]["commit"],
                "device": "iPhone 12", "media": "受控 LAN fixture", "date": "2026-11-26",
                "engines": {"av": True, "mpv": True}}}}
            ev_path = pathlib.Path(tmp) / "ev.json"
            ev_path.write_text(json.dumps(evidence))
            out2 = pathlib.Path(tmp) / "snap2.json"
            proc = self._run("--version", "1.73", "--build", "631",
                             "--device-evidence", str(ev_path), "--out", str(out2))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            snap2 = json.loads(out2.read_text())
            by_id = {g["id"]: g for g in snap2["groups"]}
            self.assertEqual(by_id["core-vod"]["device_verification"]["status"], "verified")
            self.assertTrue(by_id["core-vod"]["engines"]["av"]["device_verified"])
            self.assertTrue(by_id["core-vod"]["engines"]["mpv"]["device_verified"])
            self.assertFalse(by_id["core-vod"]["engines"]["cicada"]["device_verified"])
            for gid, group in by_id.items():
                if gid != "core-vod":
                    self.assertEqual(group["device_verification"]["status"], "pending_device_verification")

    def test_mismatched_build_evidence_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            evidence = {"groups": {"core-vod": {
                "version": "9.99", "build": "999", "commit": "deadbee",
                "device": "iPhone 12", "media": "fixture", "date": "2026-11-26",
                "engines": {"av": True}}}}
            ev_path = pathlib.Path(tmp) / "ev.json"
            ev_path.write_text(json.dumps(evidence))
            proc = self._run("--version", "1.73", "--build", "631",
                             "--device-evidence", str(ev_path), "--check")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no group matched", proc.stderr)

    def test_evidence_missing_fields_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "snap.json"
            self._run("--version", "1.73", "--build", "631", "--out", str(out))
            snap = json.loads(out.read_text())
            evidence = {"groups": {"core-vod": {
                "version": "1.73", "build": "631", "commit": snap["build"]["commit"],
                "device": "iPhone 12"}}}
            ev_path = pathlib.Path(tmp) / "ev.json"
            ev_path.write_text(json.dumps(evidence))
            proc = self._run("--version", "1.73", "--build", "631",
                             "--device-evidence", str(ev_path), "--check")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("lacks", proc.stderr)


if __name__ == "__main__":
    unittest.main()
