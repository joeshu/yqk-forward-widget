"""Real JSC transfer checks using unequal binary buffers."""
import os,unittest
from test_bridge import standalone
from jsc_host import JSCHost
class MediaPartsTests(unittest.TestCase):
 def test_binary_parts_roundtrip_and_bounds(self):
  host=JSCHost(os.environ.get('CCTV_JSC_LIBRARY', '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'))
  try:
   parts=[b'\0\xffa',bytes(range(256))*100,b'last\0']
   host.put_media_parts(parts);host.evaluate('globalThis.__mediaOutput=__mediaInput.slice(0,'+str(sum(map(len,parts)))+');void 0')
   self.assertEqual(host.read_media_parts(list(map(len,parts))),parts)
   with self.assertRaises(RuntimeError):host.read_media_parts([1])
   with self.assertRaises(ValueError):host.read_media_parts([0])
   with self.assertRaises(ValueError):host.put_media_parts([b'x'*(4*1024*1024+1)])
  finally:host.close()
