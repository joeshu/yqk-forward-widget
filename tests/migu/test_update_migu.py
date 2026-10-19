import argparse
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from email.message import Message
import io
import json
import os
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from urllib.request import Request

import update_migu as m


NOW = datetime(2026, 10, 19, 12, 0, tzinfo=timezone.utc)
URL = "http://gslbmgsplive.miguvideo.com/live/cctv1/index.m3u8?timestamp=20261019190000&blank=&token=a%2Bb%3D&client_ip=2409:1::1"


def catalogue(count=1, timestamp="20261019190000"):
    lines = ["#EXTM3U"]
    for number in range(count):
        lines += [f'#EXTINF:-1 svg-id="频道{number}" svg-name="频道{number}" group-title="测试",频道{number}', URL.replace("cctv1", f"ch{number}").replace("20261019190000", timestamp)]
    return ("\n".join(lines) + "\n").encode()


def options(output, source=None):
    return argparse.Namespace(output=output, status=None, source=m.DEFAULT_SOURCE, input=source, min_channels=1, allow_channel_drop=False, max_age_hours=12)


class Response(io.BytesIO):
    def __init__(self, raw, headers=None):
        super().__init__(raw)
        self.status = 200
        self.headers = headers or {}

    def geturl(self):
        return m.DEFAULT_SOURCE


class ParserTests(unittest.TestCase):
    def test_real_catalogue_preserves_every_signed_url_and_display_name(self):
        raw = Path("migu.m3u8").read_bytes()
        parsed = m.parse_playlist(raw)
        self.assertEqual([c.url for c in parsed.channels], [line for line in raw.decode().splitlines() if line.startswith("http")])
        self.assertEqual([c.display for c in parsed.channels], [line.rsplit(",", 1)[-1] for line in raw.decode().splitlines() if line.startswith("#EXTINF:")])
        self.assertEqual(m.normalize(parsed.render())[0], parsed.render())

    def test_bom_crlf_and_exact_authentication_parameters(self):
        raw = b"\xef\xbb\xbf" + catalogue().replace(b"\n", b"\r\n")
        result = m.parse_playlist(raw)
        self.assertEqual(result.channels[0].url, URL.replace("cctv1", "ch0"))
        self.assertNotIn(b"\r", result.render())

    def test_epg_alias_only_changes_the_id(self):
        raw = catalogue().decode().replace("频道0", "上视新闻综合").encode()
        result = m.parse_playlist(raw).channels[0]
        self.assertEqual(result.id, "上海新闻综合")
        self.assertEqual(result.display, "上视新闻综合")

    def test_commas_inside_attributes_and_display_name(self):
        raw = catalogue().decode().replace('group-title="测试"', 'group-title="新闻,财经"').replace(",频道0\n", ",频道0,直播\n").encode()
        result = m.parse_playlist(raw)
        self.assertEqual(result.channels[0].group, "新闻,财经")
        self.assertEqual(result.channels[0].display, "频道0,直播")
        self.assertEqual(m.parse_playlist(result.render()), result)

    def test_only_exact_duplicates_are_removed(self):
        raw = catalogue()
        body = raw.split(b"\n", 1)[1]
        self.assertEqual(m.parse_playlist(raw + body).duplicates_removed, 1)
        self.assertEqual(len(m.parse_playlist(raw + body.replace(b"a%2Bb%3D", b"other")).channels), 2)

    def test_rejects_injected_directives_and_controls(self):
        for injected in (b"#EXTVLCOPT:http-referrer=secret\n", b"#KODIPROP:inputstream=x\n", b"#EXTHTTP:{secret}\n", b"\x00", b"\r", "\u202e".encode()):
            with self.subTest(injected=injected):
                with self.assertRaises(m.UpdateError):
                    m.parse_playlist(catalogue() + injected)

    def test_rejects_truncation_and_ambiguous_metadata(self):
        raw = catalogue()
        candidates = [raw.rsplit(b"\n", 2)[0] + b"\n", raw.replace(b'svg-id="', b'svg-id="a" svg-id="'), raw.replace(b'group-title="', b'bad-option="'), raw.replace(b'group-title="', b'tvg-id="conflict" group-title="'), b"<html>error</html>", b"#EXTM3U\n"]
        for bad in candidates:
            with self.subTest(sample=bad[:40]):
                with self.assertRaises(m.UpdateError):
                    m.parse_playlist(bad)

    def test_rejects_untrusted_and_header_injecting_urls(self):
        for url in ("file:///etc/passwd", "http://127.0.0.1/x.m3u8", "https://miguvideo.com.evil.test/x.m3u8", "https://evil.miguvideo.com@evil.test/x.m3u8", URL + "|User-Agent=x", URL + "%0d%0aX-Test:bad", URL + "#fragment", URL.replace("&token", "&timestamp=20261019190000&token")):
            with self.subTest(url=url):
                with self.assertRaises(m.UpdateError):
                    m.parse_playlist(catalogue().replace(URL.replace("cctv1", "ch0").encode(), url.encode()))

    def test_epg_proxy_is_not_forwarded(self):
        raw = catalogue().replace(b"#EXTM3U", b'#EXTM3U x-tvg-url="https://evil.test/epg.xml"', 1)
        rendered = m.parse_playlist(raw).render()
        self.assertNotIn(b"evil.test", rendered)
        self.assertIn(m.EPG_URLS[0].encode(), rendered)


class PublicationTests(unittest.TestCase):
    def test_freshness_policy_and_future_signatures(self):
        for timestamp, error in (("20261018010000", "SOURCE_SNAPSHOT_TOO_OLD"), ("20261019210000", "SIGNATURE_FROM_FUTURE")):
            with self.assertRaisesRegex(m.UpdateError, error):
                m.validate_candidate(m.parse_playlist(catalogue(timestamp=timestamp)), now=NOW, min_channels=1)

    def test_rejects_large_drop_and_identity_replacement(self):
        previous = m.parse_playlist(catalogue(120))
        for raw in (catalogue(100), catalogue(120).replace("频道".encode(), "新台".encode())):
            with self.assertRaisesRegex(m.UpdateError, "CHANNEL_RETENTION_TOO_LOW"):
                m.validate_candidate(m.parse_playlist(raw), previous, now=NOW)

    def test_rejects_per_channel_signature_rollback(self):
        previous = m.parse_playlist(catalogue())
        candidate = m.parse_playlist(catalogue(timestamp="20261019185959"))
        with self.assertRaisesRegex(m.UpdateError, "SOURCE_SIGNATURE_ROLLBACK"):
            m.validate_candidate(candidate, previous, now=NOW, min_channels=1)

    def test_explicit_drop_override_does_not_disable_rollback_or_age_checks(self):
        with self.assertRaisesRegex(m.UpdateError, "SOURCE_SIGNATURE_ROLLBACK"):
            m.validate_candidate(m.parse_playlist(catalogue(1, "20261019185959")), m.parse_playlist(catalogue(120)), now=NOW, min_channels=1, min_retention=0)

    def test_invalid_candidate_never_overwrites_previous_output_or_status(self):
        with tempfile.TemporaryDirectory() as directory:
            output, source = Path(directory) / "migu.m3u8", Path(directory) / "source.txt"
            output.write_bytes(m.normalize(catalogue())[0])
            status = output.with_name("migu-status.json")
            status.write_bytes(b"{}")
            original = output.read_bytes()
            source.write_bytes(b"<html>502</html>")
            with self.assertRaises(m.UpdateError):
                m.refresh(options(output, source))
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual(status.read_bytes(), b"{}")

    def test_unchanged_data_does_not_rewrite_playlist_or_report(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, "utcnow", return_value=NOW), redirect_stdout(io.StringIO()):
            output, source = Path(directory) / "migu.m3u8", Path(directory) / "source.txt"
            source.write_bytes(catalogue())
            m.refresh(options(output, source))
            status = output.with_name("migu-status.json")
            before = (output.stat().st_mtime_ns, status.stat().st_mtime_ns)
            self.assertFalse(m.refresh(options(output, source)))
            self.assertEqual(before, (output.stat().st_mtime_ns, status.stat().st_mtime_ns))
            self.assertFalse(json.loads(status.read_text())["playback_verified"])

    def test_failed_atomic_replace_keeps_previous_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "migu.m3u8"
            output.write_bytes(b"old")
            with patch.object(m.os, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    m.atomic_write(output, b"new")
            self.assertEqual(output.read_bytes(), b"old")
            self.assertEqual(list(Path(directory).iterdir()), [output])

    @unittest.skipIf(os.name == "nt", "Unix advisory-lock integration")
    def test_parallel_writers_are_rejected_and_symlinks_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "migu.m3u8"
            with m.output_lock(output):
                with self.assertRaisesRegex(m.UpdateError, "UPDATE_ALREADY_RUNNING"):
                    with m.output_lock(output):
                        pass
            target = Path(directory) / "private"
            target.write_bytes(b"private")
            output.symlink_to(target)
            with self.assertRaises(m.UpdateError):
                m.atomic_write(output, b"new")
            self.assertEqual(target.read_bytes(), b"private")

    def test_304_is_bound_to_local_digest_and_cannot_hide_stale_data(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, "utcnow", return_value=NOW), redirect_stdout(io.StringIO()):
            output = Path(directory) / "migu.m3u8"
            args = options(output)
            with patch.object(m.HttpClient, "get", return_value=(catalogue(), {"ETag": '"version1"'})):
                m.refresh(args)
            with patch.object(m.HttpClient, "get", return_value=(None, {})) as get:
                self.assertFalse(m.refresh(args))
                self.assertEqual(get.call_args.kwargs["headers"], {"If-None-Match": '"version1"'})
            with patch.object(m, "utcnow", return_value=NOW + timedelta(days=2)), patch.object(m.HttpClient, "get", return_value=(None, {})):
                with self.assertRaisesRegex(m.UpdateError, "SOURCE_SNAPSHOT_TOO_OLD"):
                    m.refresh(args)
            output.write_bytes(output.read_bytes().replace(b"token=", b"auth="))
            with patch.object(m.HttpClient, "get", return_value=(None, {})) as get:
                with self.assertRaisesRegex(m.UpdateError, "UNEXPECTED_NOT_MODIFIED"):
                    m.refresh(args)
                self.assertEqual(get.call_args.kwargs["headers"], {})


class TransportTests(unittest.TestCase):
    def client(self, effects):
        client = m.HttpClient()
        client.opener = Mock()
        client.opener.open.side_effect = effects
        return client

    def error(self, code, after=None):
        headers = Message()
        if after:
            headers["Retry-After"] = after
        return HTTPError(m.DEFAULT_SOURCE, code, "secret-token", headers, io.BytesIO(b"secret-body"))

    def test_retry_transient_503_then_success(self):
        client = self.client([self.error(503), Response(b"ok")])
        with patch.object(m.time, "sleep") as sleep:
            self.assertEqual(client.get(m.DEFAULT_SOURCE)[0], b"ok")
            sleep.assert_called_once_with(1)

    def test_does_not_retry_661_auth_errors_or_long_rate_limit(self):
        for code, after in ((661, None), (403, None), (429, "120")):
            client = self.client([self.error(code, after)])
            with patch.object(m.time, "sleep") as sleep:
                with self.assertRaisesRegex(m.FetchError, f"HTTP_{code}"):
                    client.get(m.DEFAULT_SOURCE)
                sleep.assert_not_called()
                self.assertEqual(client.opener.open.call_count, 1)

    def test_tls_failure_is_not_downgraded_or_retried(self):
        client = self.client([URLError(ssl.SSLError("secret detail"))])
        with self.assertRaisesRegex(m.FetchError, "TLS_ERROR"):
            client.get(m.DEFAULT_SOURCE)
        self.assertEqual(client.opener.open.call_count, 1)

    def test_oversized_html_and_truncated_responses_are_rejected(self):
        cases = [(Response(b"12345"), 4), (Response(b"", {"Content-Length": "100"}), 4), (Response(b"html", {"Content-Type": "text/html"}), 100), (Response(b"x", {"Content-Length": "5"}), 100), (Response(b"x", {"Content-Encoding": "gzip"}), 100)]
        for response, limit in cases:
            client = self.client([response])
            client.attempts = 1
            with self.assertRaises(m.FetchError):
                client.get(m.DEFAULT_SOURCE, limit=limit)

    def test_redirects_reject_external_hosts_and_https_downgrades(self):
        handler = m.RestrictedRedirect("media")
        request = Request("https://hlszymgsplive.miguvideo.com/live/index.m3u8")
        for target in ("https://127.0.0.1/private", "https://miguvideo.com.evil.test/a", "http://hlszymgsplive.miguvideo.com/live/index.m3u8"):
            with self.subTest(target=target):
                with self.assertRaises(m.UpdateError):
                    handler.redirect_request(request, None, 302, "", {}, target)

    def test_cross_host_redirect_does_not_forward_cache_validators(self):
        request = Request("https://develop202.github.io/migu_video/interface.txt", headers={"If-None-Match": '"old"'})
        result = m.RestrictedRedirect("source").redirect_request(request, None, 302, "", {}, "https://raw.githubusercontent.com/develop202/migu_video/main/interface.txt")
        self.assertIsNone(result.get_header("If-none-match"))

    def test_redirect_body_is_not_drained_and_deadline_limits_next_request(self):
        handler = m.RestrictedRedirect("source")
        handler.parent = Mock()
        handler.deadline = 105
        request = Request(m.DEFAULT_SOURCE)
        request.timeout = 10
        response = Mock()
        with patch.object(m.time, "monotonic", return_value=103):
            handler.http_error_302(request, response, 302, "", {"Location": "https://develop202.github.io/migu_video/interface.txt"})
        response.read.assert_not_called()
        response.close.assert_called_once()
        self.assertEqual(handler.parent.open.call_args.kwargs["timeout"], 2)

    def test_expired_redirect_budget_closes_response_without_opening_a_connection(self):
        handler = m.RestrictedRedirect("source")
        handler.parent = Mock()
        handler.deadline = 100
        request = Request(m.DEFAULT_SOURCE)
        request.timeout = 10
        response = Mock()
        with patch.object(m.time, "monotonic", return_value=101):
            with self.assertRaisesRegex(m.FetchError, "FETCH_BUDGET_EXCEEDED"):
                handler.http_error_302(request, response, 302, "", {"Location": "https://develop202.github.io/migu_video/interface.txt"})
        handler.parent.open.assert_not_called()
        response.close.assert_called_once()

    def test_source_url_cannot_be_an_arbitrary_fetch_proxy(self):
        for url in ("file:///etc/passwd", "http://www.52top.com.cn/other", "https://localhost/list", "https://evil.test/list", "https://raw.githubusercontent.com:8080/list"):
            with self.assertRaises(m.UpdateError):
                m.validate_url(url, "source")

    def test_observed_migu_cdn_8080_is_allowed_only_for_media(self):
        url = "http://hlszymgsplive.miguvideo.com:8080/live/index.m3u8"
        m.validate_url(url, "media")
        for candidate, role in ((url, "source"), (url, "stream"), (url.replace(":8080", ":8081"), "media"), (url.replace("miguvideo.com", "miguvideo.com.evil.test"), "media")):
            with self.assertRaises(m.UpdateError):
                m.validate_url(candidate, role)

    def test_errors_do_not_log_response_bodies_urls_or_secrets(self):
        error = m.FetchError("HTTP_403")
        with patch.object(m, "refresh", side_effect=error), redirect_stderr(io.StringIO()) as stream:
            self.assertEqual(m.main([]), 1)
        self.assertNotIn("http://", stream.getvalue())
        self.assertNotIn("token", stream.getvalue())

    def test_budget_stops_before_network(self):
        client = self.client([])
        client.budget = -1
        with self.assertRaisesRegex(m.FetchError, "FETCH_BUDGET_EXCEEDED"):
            client.get(m.DEFAULT_SOURCE)
        client.opener.open.assert_not_called()


if __name__ == "__main__":
    unittest.main()
