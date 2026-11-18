"""Regression tests for the 2026-11-18 Principal Architect Full-Project Audit & Fixes."""
import http.client
import importlib.util
import json
from pathlib import Path
import ssl
import sys
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SOURCES = ROOT / "Sources"
PLUGINS = ROOT / "Plugins"
SCRIPTS = ROOT / "Scripts"
for _p in (PLUGINS, SCRIPTS):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import host_media_relay
import host_media_runtime


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Round17FullAuditFixesTests(unittest.TestCase):
    def test_p0_01_serve_host_fetch_enforces_tls_strips_cross_origin_credentials_and_never_uses_public_proxies(self):
        transport = _load_module("media_service_r17", PLUGINS / "media-service.py")
        ms_src = (PLUGINS / "media-service.py").read_text(encoding="utf-8")
        self.assertNotIn("_create_unverified_context", ms_src)
        self.assertNotIn("api.codetabs.com", ms_src)
        self.assertNotIn("api.allorigins.win", ms_src)

        runtime = host_media_runtime.MediaRuntime()
        server = transport.Server(("127.0.0.1", 0), runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        token = server.host_fetch_token

        observed_requests = []

        class RedirectResponse:
            def __init__(self, code, location, url):
                self.url = url
                self._code = code
                self.reason = "Moved"
                import email.message
                self.headers = email.message.Message()
                self.headers.add_header("Location", location)

            def getcode(self):
                return self._code

            def read(self, limit=None):
                return b""

            def close(self):
                pass

        class FinalResponse:
            def __init__(self, url):
                self.url = url
                self.reason = "OK"
                import email.message
                self.headers = email.message.Message()
                self.headers.add_header("Content-Type", "application/json")

            def getcode(self):
                return 200

            def read(self, limit=None):
                return b'{"ok":true}'

            def close(self):
                pass

        class FakeOpener:
            def open(self, req, timeout=None):
                hdrs = {k.lower(): v for k, v in req.header_items()}
                observed_requests.append((req.full_url, hdrs))
                if len(observed_requests) == 1:
                    return RedirectResponse(302, "https://cdn.other-origin.example/final.json", req.full_url)
                return FinalResponse(req.full_url)

        try:
            payload = json.dumps({
                "url": "https://origin.example/start.json",
                "method": "GET",
                "followRedirects": True,
                "headers": {
                    "Cookie": "session=secret123",
                    "Authorization": "Bearer secret-token",
                    "User-Agent": "CCTVHostTest/1.0",
                },
            }).encode("utf-8")
            with mock.patch.object(transport.urllib.request, "build_opener", return_value=FakeOpener()):
                conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
                conn.request(
                    "POST",
                    "/_cctvhost/host-fetch",
                    payload,
                    {"X-CCTVHost-Host-Fetch": token, "Content-Type": "application/json"},
                )
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                self.assertEqual(resp.status, 200)
                self.assertEqual(body, b'{"ok":true}')
                self.assertEqual(len(observed_requests), 2)
                self.assertIn("cookie", observed_requests[0][1])
                self.assertIn("authorization", observed_requests[0][1])
                # Cross-origin redirect must strip Cookie and Authorization
                self.assertNotIn("cookie", observed_requests[1][1])
                self.assertNotIn("authorization", observed_requests[1][1])
                self.assertEqual(observed_requests[1][1].get("user-agent"), "CCTVHostTest/1.0")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)
            runtime.close()

    def test_p0_02_aia_resolver_never_trusts_unverified_leaf_cert_or_partial_chain_and_ysp_live_uses_cert_required(self):
        relay_src = (PLUGINS / "host_media_relay.py").read_text(encoding="utf-8")
        aia_fn = relay_src.split("def _resolve_aia_opener_for_host(", 1)[1].split("\ndef _tune_response_socket(", 1)[0]
        self.assertIn("if not pem_blocks:\n        return None", aia_fn)
        self.assertNotIn("pem_blocks.append(ssl.DER_cert_to_PEM_cert(der_cert))", aia_fn)
        self.assertNotIn("VERIFY_X509_PARTIAL_CHAIN", aia_fn)

        ysp_src = (PLUGINS / "ysp-live.py").read_text(encoding="utf-8")
        self.assertNotIn("_create_unverified_context", ysp_src)
        self.assertIn("self ._ctx .verify_mode =ssl .CERT_REQUIRED", ysp_src)

    def test_p1_01_source_audit_scans_cctv_app_udrm_and_detects_unverified_ssl_contexts(self):
        source_audit = _load_module("source_audit_r17", SCRIPTS / "source_audit.py")
        self.assertIsNotNone(source_audit.RISK.search("ssl._create_unverified_context()"))
        audit_src = (SCRIPTS / "source_audit.py").read_text(encoding="utf-8")
        self.assertIn("'cctv-ios-host','cctv-app-udrm'", audit_src)

    def test_p1_02_media_jar_runtime_guarantees_completion_on_180s_operation_timeout(self):
        jar_src = (SOURCES / "MediaJARRuntime.m").read_text(encoding="utf-8")
        self.assertIn("- (BOOL)claimCompletion", jar_src)
        self.assertIn("BOOL shouldNotifyTimeout=[ticket claimCompletion];", jar_src)
        self.assertIn('JARError(14,@"JAR 请求执行超过 3 分钟，已超时取消")', jar_src)

    def test_p1_03_playback_sdk_retry_bumps_session_and_auth_failed_checks_active_native_player(self):
        play_src = (SOURCES / "RootViewController+Playback.m").read_text(encoding="utf-8")
        sdk_body = play_src.split("- (void)playViaSDK:(NSString *)cid title:(NSString *)title {", 1)[1].split(
            "\n- (void)recordStartupStage:", 1
        )[0]
        self.assertGreaterEqual(sdk_body.count("[self beginNativeSession]"), 2)

        auth_body = play_src.split("- (void)authFailed:(NSError *)error {", 1)[1].split(
            "\n- (void)showPlaybackInfo", 1
        )[0]
        self.assertIn("if (!self.currentPlayer || self.avPlayer) return;", auth_body)

    def test_p1_04_image_loader_disk_cache_cleanup_and_settings_cache_accounting(self):
        hil_h = (SOURCES / "HostImageLoader.h").read_text(encoding="utf-8")
        hil_m = (SOURCES / "HostImageLoader.m").read_text(encoding="utf-8")
        settings_m = (SOURCES / "SettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("- (void)clearDiskCache;", hil_h)
        self.assertIn("- (void)clearDiskCache {", hil_m)
        self.assertIn("SettingsImageThumbnailCacheBytes()", settings_m)
        self.assertGreaterEqual(settings_m.count("[HostImageLoader.shared clearDiskCache];"), 2)

    def test_p2_01_xmltv_store_synchronizes_tasks_and_callbacks_and_guards_nil_request_url(self):
        xml_m = (SOURCES / "XMLTVStore.m").read_text(encoding="utf-8")
        self.assertGreaterEqual(xml_m.count("@synchronized(self)"), 9)
        self.assertIn("NSURL *requestURL=[NSURL URLWithString:source];", xml_m)
        self.assertIn("if(!requestURL){[self complete:source cache:cached error:", xml_m)

    def test_p2_02_and_p2_03_catalog_channel_removal_persistence_and_mute_icon_accessibility_sync(self):
        cat_m = (SOURCES / "RootViewController+Catalog.m").read_text(encoding="utf-8")
        self.assertNotIn("objc_getAssociatedObject(g.view, @selector(onChannelCardTap:))", cat_m)
        self.assertIn("else if (g.view == self.channelGrid)", cat_m)
        self.assertIn('[ProfileStore update:subSource values:@{@"cachedChannels":updated,@"count":@(updated.count)}];', cat_m)

        rvc_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        sync_body = rvc_m.split("- (void)syncPlayPauseButtonIcon {", 1)[1].split(
            "\n- (void)updatePlaybackControlAccessibility", 1
        )[0]
        self.assertIn("speaker.slash.fill", sync_body)
        self.assertIn("self.muteBtn.accessibilityLabel = muteTitle;", sync_body)

    def test_zero_undeclared_forward_objc_calls_or_missing_selectors_across_all_translation_units(self):
        import re

        smoke_dir = ROOT / "Tests" / "UISmoke"
        all_m_files = sorted(list(SOURCES.glob("*.m")) + list(smoke_dir.glob("*.m")))
        all_h_files = {
            p.name: p
            for p in list(SOURCES.glob("*.h"))
            + list((SOURCES / "Include").glob("*.h"))
            + list(smoke_dir.glob("*.h"))
        }
        uikit_protocol_sels = {
            "initWithFrame:collectionViewLayout:",
            "tableView:didSelectRowAtIndexPath:",
            "tableView:commitEditingStyle:forRowAtIndexPath:",
            "tableView:titleForFooterInSection:",
            "numberOfSectionsInTableView:",
            "scrollViewDidScroll:",
            "textViewDidChange:",
            "updateSearchResultsForSearchController:",
            "play",
        }

        def strip_comments(raw: str) -> str:
            def repl(m):
                if m.group(1):
                    return m.group(1)
                return "".join("\n" if c == "\n" else " " for c in m.group(0))
            return re.sub(r'(@?"(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/', repl, raw, flags=re.S)

        def extract_selector(sig_body: str) -> str:
            s = sig_body.strip()
            if s.startswith("("):
                depth = 0
                for i, ch in enumerate(s):
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            s = s[i + 1 :].strip()
                            break
            if ":" not in s:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", s)
                return m.group(1) if m else ""
            parts = []
            i = 0
            n = len(s)
            while i < n:
                m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", s[i:])
                if not m:
                    break
                parts.append(m.group(1) + ":")
                i += m.end()
                while i < n and s[i].isspace():
                    i += 1
                if i < n and s[i] == "(":
                    depth = 0
                    while i < n:
                        if s[i] == "(":
                            depth += 1
                        elif s[i] == ")":
                            depth -= 1
                            if depth == 0:
                                i += 1
                                break
                        i += 1
                while i < n and s[i].isspace():
                    i += 1
                m_param = re.match(r"[A-Za-z_][A-Za-z0-9_]*", s[i:])
                if m_param:
                    i += m_param.end()
            return "".join(parts)

        def scan_methods(block_text: str):
            results = []
            for m in re.finditer(r"(?:^|(?<=[;\}]))\s*([+-])\s*\(", block_text, flags=re.M):
                kind = m.group(1)
                pos = m.start(1)
                i = m.end() - 1
                n = len(block_text)
                paren_depth = 0
                while i < n:
                    ch = block_text[i]
                    if ch == "(":
                        paren_depth += 1
                    elif ch == ")":
                        paren_depth = max(0, paren_depth - 1)
                    elif paren_depth == 0 and ch in "{;":
                        sig = block_text[m.start(1) + 1 : i].strip()
                        sig_clean = " ".join(sig.split())
                        sig_for_sel = re.sub(r"\bAPI_AVAILABLE\s*\([^)]*\)", "", sig_clean).strip()
                        sel = extract_selector(sig_for_sel)
                        if sel:
                            results.append((kind, sel, pos, f"{kind} {sig_clean};"))
                        break
                    i += 1
            return results

        def resolve_imports(p: Path, seen=None):
            if seen is None:
                seen = set()
            if p in seen:
                return []
            seen.add(p)
            res = []
            for m in re.finditer(r'^\s*#(?:import|include)\s+"([^"]+)"', p.read_text(encoding="utf-8"), re.M):
                inc_name = Path(m.group(1)).name
                if inc_name in all_h_files:
                    hp = all_h_files[inc_name]
                    res.extend(resolve_imports(hp, seen))
                    res.append(hp)
            return res

        def parse_call_selector(expr_inside_brackets: str):
            s = re.sub(r'@?"(?:\\.|[^"\\])*"', '""', expr_inside_brackets)
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s+(.*)$", s, flags=re.S)
            if not m:
                return None, None
            recv, rest = m.group(1), m.group(2).strip()
            depth_p = depth_b = depth_c = 0
            ternary_depth = 0
            cur = []
            for ch in rest:
                if ch in "([{":
                    if ch == "(":
                        depth_p += 1
                    elif ch == "[":
                        depth_b += 1
                    elif ch == "{":
                        depth_c += 1
                    cur.append(" ")
                elif ch in ")]}":
                    if ch == ")":
                        depth_p = max(0, depth_p - 1)
                    elif ch == "]":
                        depth_b = max(0, depth_b - 1)
                    elif ch == "}":
                        depth_c = max(0, depth_c - 1)
                    cur.append(" ")
                elif depth_p == 0 and depth_b == 0 and depth_c == 0:
                    if ch == "?":
                        ternary_depth += 1
                        cur.append(" ")
                    elif ch == ":" and ternary_depth > 0:
                        ternary_depth -= 1
                        cur.append(" ")
                    else:
                        cur.append(ch)
                else:
                    cur.append(" ")
            flat = "".join(cur).strip()
            if ":" not in flat:
                m_u = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)$", flat)
                return (recv, m_u.group(1)) if m_u else (recv, None)
            parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", flat)
            return (recv, "".join(p + ":" for p in parts)) if parts else (recv, None)

        undeclared_forward = []
        for mfile in all_m_files:
            imported_headers = resolve_imports(mfile)
            declared_per_class = {}
            for hp in imported_headers + [mfile]:
                txt_nc = strip_comments(hp.read_text(encoding="utf-8"))
                for m_if in re.finditer(r"@interface\s+([A-Za-z_][A-Za-z0-9_]*).*?@end", txt_nc, flags=re.S):
                    cls = m_if.group(1)
                    body = m_if.group(0)
                    declared_per_class.setdefault(cls, set())
                    for m_prop in re.finditer(r"@property\s*(?:\([^)]*\))?\s*[^;]+;", body, flags=re.S):
                        pstr = m_prop.group(0)
                        m_b = re.search(r"\(\s*\^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\([^;]*\)\s*;", pstr)
                        prop = m_b.group(1) if m_b else (re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*;", pstr).group(1) if re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*;", pstr) else None)
                        if prop:
                            declared_per_class[cls].add(prop)
                            declared_per_class[cls].add("set" + prop[0].upper() + prop[1:] + ":")
                    for _, sel, _, _ in scan_methods(body):
                        declared_per_class[cls].add(sel)

            raw_txt = mfile.read_text(encoding="utf-8")
            txt_nc = strip_comments(raw_txt)
            for m_imp in re.finditer(r"@implementation\s+([A-Za-z_][A-Za-z0-9_]*).*?@end", txt_nc, flags=re.S):
                cls = m_imp.group(1)
                imp_body = m_imp.group(0)
                meth_defs = {}
                for _, sel, pos, decl_str in scan_methods(imp_body):
                    if sel not in meth_defs:
                        meth_defs[sel] = (pos, decl_str)
                imp_masked = re.sub(r'@?"(?:\\.|[^"\\])*"', lambda m: '"' + (" " * (len(m.group(0)) - 2)) + '"', imp_body)
                stack = []
                for idx, ch in enumerate(imp_masked):
                    if ch == "[" and (idx == 0 or imp_masked[idx - 1] != "@"):
                        stack.append(idx)
                    elif ch == "]" and stack:
                        start = stack.pop()
                        inner = imp_masked[start + 1 : idx]
                        recv, sel = parse_call_selector(inner)
                        if not sel or sel in uikit_protocol_sels:
                            continue
                        if recv not in ("self", "weakSelf", "owner", "w", "s", cls):
                            continue
                        if sel in meth_defs and sel not in declared_per_class.get(cls, set()):
                            def_offset, decl_str = meth_defs[sel]
                            if start < def_offset:
                                undeclared_forward.append((mfile.name, cls, recv, sel, decl_str))

        self.assertEqual(undeclared_forward, [])
        rvc_int = all_h_files["RootViewController_Internal.h"].read_text(encoding="utf-8")
        self.assertIn("- (void)loadDeferredMetadataForVisibleTableRows;", rvc_int)


if __name__ == "__main__":
    unittest.main()
