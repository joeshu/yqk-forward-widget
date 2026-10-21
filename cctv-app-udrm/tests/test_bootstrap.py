"""Synthetic range transport and capability preflight checks; no official SDK fixture."""
import hashlib
import io
import unittest
import zlib
from unittest.mock import patch
from test_bridge import standalone
# Other test modules may also load the embedded entry; retain this module reference.
import bootstrap_nojdk as boot

class Response(io.BytesIO):
    status=206
    def geturl(self):return boot.APK_URL

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.data=b'synthetic SDK fixture'*4096
        encoder=zlib.compressobj(wbits=-15)
        self.packed=encoder.compress(self.data)+encoder.flush()
        values=dict(SDK_OFFSET=19,SDK_COMPRESSED_SIZE=len(self.packed),APK_SIZE=999999,
                    SDK_SIZE=len(self.data),SDK_CRC=zlib.crc32(self.data),SDK_SHA256=hashlib.sha256(self.data).hexdigest())
        self.constants=patch.multiple(boot,**values);self.constants.start();self.addCleanup(self.constants.stop)
    def response(self,data=None):
        r=Response(self.packed if data is None else data)
        r.headers={'Content-Range':f'bytes 19-{18+len(self.packed)}/999999','Content-Length':str(len(self.packed))}
        return r
    def test_range_decodes_and_verifies_exact_sdk(self):
        with patch.object(boot,'urlopen',return_value=self.response()) as request:
            self.assertEqual(boot._get_sdk_range(lambda _:None),self.data)
            self.assertEqual(request.call_args.args[0].get_header('Range'),f'bytes=19-{18+len(self.packed)}')
    def test_ignored_range_closes_without_reading_archive(self):
        r=self.response();r.status=200
        with patch.object(r,'read',side_effect=AssertionError('must not consume archive')),patch.object(boot,'urlopen',return_value=r):
            with self.assertRaises(boot.RangeUnavailable):boot._get_sdk_range(lambda _:None)
        self.assertTrue(r.closed)
    def test_bad_range_truncation_and_corruption_fail_closed(self):
        wrong=self.response();wrong.headers['Content-Range']='bytes 0-1/2'
        for r in [wrong,self.response(self.packed[:-1]),self.response(bytes([self.packed[0]^255])+self.packed[1:])]:
            with self.subTest(headers=r.headers),patch.object(boot,'urlopen',return_value=r):
                with self.assertRaises(boot.BootstrapError):boot._get_sdk_range(lambda _:None)
    def test_valid_deflate_with_wrong_digest_is_rejected(self):
        with patch.object(boot,'urlopen',return_value=self.response()),patch.object(boot,'SDK_SHA256','0'*64):
            with self.assertRaises(boot.BootstrapError):boot._get_sdk_range(lambda _:None)
    def test_capability_failure_happens_before_any_download(self):
        with patch.object(boot,'_preflight',side_effect=boot.BootstrapError('unsupported')),patch.object(boot,'urlopen',side_effect=AssertionError('download forbidden')):
            with self.assertRaisesRegex(boot.BootstrapError,'unsupported'):boot.prepare('')

if __name__=='__main__':unittest.main()
