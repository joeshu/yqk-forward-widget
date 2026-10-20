import unittest

from migu import verify_url as v

PU = "e48b17dee262b373edf8b13550e52780"
DD = "0e84e7822b8510e70d5e5e3216b28bf3d7e3"


def url(pu=PU, dd=DD, family="0116_2600000900-99000-201600010010027"):
    return ("http://gslbmgsplive.miguvideo.com/wd_r2/cctv/cctv1hd/600/index.m3u8"
            "?msisdn=20261020104125aa&timestamp=20261020104125"
            f"&Channel_ID={family}&ProgramID=608807420&sid=2201057821"
            "&appCode=miguvideo_android&bean=mgspad&tid=android"
            f"&puData={pu}&ddCalcu={dd}")


class VerifyTests(unittest.TestCase):
    def test_identifies_legacy_rule_and_client_family(self):
        row = v.analyse(url())
        self.assertTrue(row["legacy_match"])
        self.assertFalse(row["modern_match"])
        self.assertEqual(row["client_id_family"], "0116_2600000900")
        self.assertEqual(row["app_code"], "miguvideo_android")
        self.assertEqual((row["pu_data_len"], row["dd_calcu_len"]), (32, 36))

    def test_does_not_echo_signature_or_session_values(self):
        text = repr(v.analyse(url()))
        for secret in (PU, DD, "20261020104125aa", "2201057821"):
            self.assertNotIn(secret, text)

    def test_tampered_proof_is_reported_as_no_match(self):
        row = v.analyse(url(dd="0" * 36))
        self.assertFalse(row["legacy_match"])
        self.assertFalse(row["modern_match"])

    def test_missing_proof_fields_do_not_crash(self):
        row = v.analyse("http://gslbmgsplive.miguvideo.com/live/index.m3u8?ProgramID=1")
        self.assertIsNone(row["legacy_match"])
        self.assertEqual(row["pu_data_len"], 0)


if __name__ == "__main__":
    unittest.main()
