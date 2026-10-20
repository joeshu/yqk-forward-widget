import json
import time
import unittest
from unittest.mock import Mock
from urllib.parse import parse_qs, urlsplit

from migu import android as a, core as m


class ProofTests(unittest.TestCase):
    def test_android_proof_matches_reference_layout(self):
        self.assertEqual(a.dd_calcu("abcdef", "631780532", 3), "faebvdca")
        self.assertEqual(a.dd_calcu("abcdef", "631780532", 2), "faebvdca")

    def test_account_lengths_change_first_word(self):
        # id[7] -> keys index, then 3 < len <= 8 overwrites with 'e'.
        self.assertEqual(a.dd_calcu("abcdef", "631780532", 3, "12345678")[4], "e")
        # Longer id only uses id[7]; '8' -> keys[8] == 'k'.
        self.assertEqual(a.dd_calcu("abcdef", "631780532", 3, "123456789")[4], "k")

    def test_empty_inputs_never_fabricate_a_proof(self):
        self.assertEqual(a.dd_calcu("", "631780532", 3), "")
        self.assertEqual(a.dd_calcu("abcdef", "", 3), "")


class RequestTests(unittest.TestCase):
    def test_query_order_and_headers_match_reference(self):
        url, headers = a.playurl_request("631780532", 3, "12345678", "tok", hdr=True, h265=True)
        self.assertTrue(url.startswith(a.PLAYURL + "?sign="))
        self.assertIn("&rateType=3&contId=631780532&timestamp=", url)
        self.assertIn("&salt=1230024&flvEnable=true&super4k=true&h265N=true&4kvivid=true", url)
        self.assertEqual(headers["AppVersion"], "26000370")
        self.assertEqual(headers["X-UP-CLIENT-CHANNEL-ID"], "2600037000-99000-200300220100002")
        self.assertEqual(headers["UserId"], "12345678")

    def test_legacy_720p_uses_its_own_version_and_random_salt(self):
        url, headers = a.playurl_request("631780532", 3, legacy=True, hdr=False, h265=False)
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(len(query["salt"][0]), 8)
        self.assertTrue(query["salt"][0].endswith("25"))
        self.assertEqual(headers["AppVersion"], "2600034600")
        self.assertNotIn("h265N", url)

    def test_account_headers_only_when_rate_is_not_two(self):
        _, headers = a.playurl_request("631780532", 2, "12345678", "tok")
        self.assertNotIn("UserId", headers)

    def test_flv_disabled_channels_omit_appcode(self):
        _, headers = a.playurl_request("641886683", 3)
        self.assertNotIn("appCode", headers)
        _, normal = a.playurl_request("631780532", 3)
        self.assertEqual(normal["appCode"], "miguvideo_default_android")


class SettingsTests(unittest.TestCase):
    def test_partial_or_dirty_credentials_fail_before_network(self):
        for environ in ({"MIGU_USER_ID": "1"}, {"MIGU_USER_TOKEN": "t"},
                        {"MIGU_USER_ID": "1", "MIGU_USER_TOKEN": "a\r\nb"},
                        {"MIGU_RATE_TYPE": "5"}, {"MIGU_RATE_TYPE": "x"}):
            with self.subTest(environ=environ):
                with self.assertRaises(m.UpdateError):
                    a.AndroidSettings.load(environ)

    def test_client_identity_is_validated_before_use(self):
        self.assertEqual(a.AndroidSettings.load({"MIGU_APP_VERSION": "2600000900"}).app_version, "2600000900")
        for environ in ({"MIGU_APP_VERSION": "abc"}, {"MIGU_APP_CODE": "bad code"},
                        {"MIGU_CLIENT_CHANNEL_ID": "x"}):
            with self.subTest(environ=environ):
                with self.assertRaises(m.UpdateError):
                    a.AndroidSettings.load(environ)

    def test_configured_version_reaches_header_and_signature_input(self):
        settings = a.AndroidSettings.load({"MIGU_APP_VERSION": "2600000900"})
        url, headers = a.playurl_request("631780532", 3, settings=settings)
        self.assertEqual(headers["AppVersion"], "2600000900")
        self.assertIn("sign=", url)

    def test_defaults_are_guest_720p_with_scan_protection(self):
        settings = a.AndroidSettings.load({})
        self.assertEqual((settings.rate_type, settings.user_id, settings.client_dispatch), (3, "", True))


class ResolveTests(unittest.TestCase):
    def payload(self, rid="SUCCESS", url="http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064125&puData=abcdef&rateType=3"):
        body = {"urlInfo": {"url": url, "rateType": 3}, "content": {"contId": "631780532"}}
        return json.dumps({"rid": rid, "body": body}).encode()

    def test_success_appends_proof_and_client_suffix(self):
        client = Mock()
        client.get.return_value = (self.payload(), {})
        url = a.android_play_url("631780532", a.AndroidSettings(), client_factory=Mock(return_value=client))
        self.assertTrue(url.endswith("&ddCalcu=faebvdca&sv=10004&ct=android"))

    def test_region_and_copyright_refusals_are_reported_not_retried(self):
        for rid, code in (("COPYRIGHT_AREA_INVALID", "MIGU_REGION_RESTRICTED"),
                          ("COPYRIGHT_SHIELD_INVALID", "MIGU_COPYRIGHT_SHIELD")):
            client = Mock()
            client.get.return_value = (json.dumps({"rid": rid, "message": "no"}).encode(), {})
            factory = Mock(return_value=client)
            with self.assertRaises(a.MiguApiError) as caught:
                a.android_play_url("631780532", a.AndroidSettings(), client_factory=factory)
            self.assertEqual(str(caught.exception), code)
            self.assertEqual(factory.call_count, 1)

    def test_membership_refusal_degrades_to_a_lower_tier_once(self):
        refused = json.dumps({"rid": "TIPS_NEED_MEMBER", "body": {"urlInfo": {"rateType": 3}}}).encode()
        client = Mock()
        client.get.side_effect = [(refused, {}), (self.payload(), {})]
        url = a.android_play_url("631780532", a.AndroidSettings(rate_type=4), client_factory=Mock(return_value=client))
        self.assertIn("ddCalcu=", url)
        self.assertEqual(client.get.call_count, 2)
        self.assertIn("rateType=3", client.get.call_args_list[1].args[0])

    def test_untrusted_returned_host_is_rejected(self):
        client = Mock()
        client.get.return_value = (self.payload(url="http://127.0.0.1/live/index.m3u8?puData=abcdef"), {})
        with self.assertRaises(m.UpdateError):
            a.android_play_url("631780532", a.AndroidSettings(), client_factory=Mock(return_value=client))


class StoreTests(unittest.TestCase):
    def test_cache_windows_burst_limit_and_failure_reuse(self):
        now = [0.0]
        calls = []

        def resolver(pid):
            calls.append(pid)
            if pid == "624878271":
                raise a.MiguApiError("MIGU_REGION_RESTRICTED")
            return "http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=1"

        store = a.AndroidStore(settings=a.AndroidSettings(), resolver=resolver, clock=lambda: now[0])
        self.addCleanup(store.close)
        self.assertTrue(store.resolve("p631780532").startswith("http://gslb"))
        self.assertEqual(store.resolve("p631780532").count("gslb"), 1)
        self.assertEqual(len(calls), 1)
        now[0] = 3 * 60 * 60 + 1
        store.resolve("p631780532")
        self.assertEqual(len(calls), 2)

        with self.assertRaises(a.MiguApiError):
            store.resolve("p624878271")
        now[0] += 30
        with self.assertRaises(a.MiguApiError):
            store.resolve("p624878271")
        self.assertEqual(len(calls), 3)

        with self.assertRaises(m.FetchError) as caught:
            for pid in [item[0] for item in a.BUILTIN_CHANNELS][:40]:
                try:
                    store.resolve("p" + pid)
                except a.MiguApiError:
                    pass
        self.assertIn(str(caught.exception), {"MIGU_RESOLVE_BURST_LIMIT", "MIGU_API_CAPACITY"})


if __name__ == "__main__":
    unittest.main()
