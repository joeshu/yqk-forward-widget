import importlib.util,json,threading,unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import urlopen,Request
p=Path(__file__).resolve().parents[1]/'diagnostics/cctv-ios-native-probe-v0.1.0.py'
spec=importlib.util.spec_from_file_location('native_probe',p);probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
class Function:
 def __init__(self,fn):self.fn=fn
 def __call__(self,*a):return self.fn(*a)
class Process:
 def __init__(self,names):
  self.names=names;self._dyld_image_count=Function(lambda:len(names));self._dyld_get_image_name=Function(lambda i:names[i])
class NativeProbeTests(unittest.TestCase):
 def test_non_apple_host_does_not_lookup_native_symbols(self):
  with patch.object(probe.sys,'platform','linux'),patch.object(probe.ctypes,'CDLL') as cdll:
   data=probe.collect();cdll.assert_not_called();self.assertFalse(data['official_ios_sdk_verified']);self.assertEqual(data['integration_state'],'unverified')
 def test_ios_filters_private_paths_and_does_not_infer_sdk_compatibility(self):
  process=Process([b'/private/var/containers/ABC/Frameworks/KooPlayer.framework/KooPlayer',b'/System/Library/Frameworks/AVFoundation.framework/AVFoundation',b'/private/PersonalSecret.dylib'])
  with patch.object(probe.sys,'platform','ios'),patch.object(probe.ctypes,'CDLL',return_value=process) as cdll:
   data=probe.collect();cdll.assert_called_once_with(None)
  self.assertEqual(data['matching_loaded_components']['vendor_candidates'],['KooPlayer'])
  self.assertFalse(data['official_ios_sdk_verified']);self.assertFalse(data['aptv_plugin_api_verified'])
  text=json.dumps(data);self.assertNotIn('/private/',text);self.assertNotIn('PersonalSecret',text);self.assertTrue(data['loaded_images_supported'])
 def test_scan_is_bounded_and_marks_incomplete_coverage(self):
  process=Process([b'/System/JavaScriptCore',b'/private/Unicorn',b'/private/KooPlayer'])
  names,count,truncated=probe._loaded_images(process,limit=2)
  self.assertEqual(names,['JavaScriptCore','Unicorn']);self.assertEqual(count,3);self.assertTrue(truncated)
 def test_native_exports_are_only_candidate_evidence(self):
  process=Process([])
  for symbol in probe.PUBLIC_SYMBOLS['unicorn_c_api']:setattr(process,symbol,Function(lambda:None))
  with patch.object(probe.sys,'platform','darwin'),patch.object(probe.ctypes,'CDLL',return_value=process):data=probe.collect()
  self.assertTrue(data['native_unicorn_api_observed']);self.assertFalse(data['official_ios_sdk_verified']);self.assertEqual(data['integration_state'],'native_emulator_api_candidate_requires_validation')
 def test_missing_loaded_image_api_keeps_symbol_observations(self):
  with patch.object(probe.sys,'platform','ios'),patch.object(probe.ctypes,'CDLL',return_value=object()):data=probe.collect()
  self.assertFalse(data['loaded_images_supported']);self.assertIn('public_symbols',data);self.assertFalse(data['official_ios_sdk_verified'])
 def test_local_http_report_and_head_have_no_sdk_startup(self):
  server=probe.ProbeServer(('127.0.0.1',0),probe.Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();base='http://127.0.0.1:'+str(server.server_port)
  try:
   with urlopen(base+'/status') as response:
    data=json.load(response);self.assertEqual(response.status,200);self.assertTrue(data['no_sdk_download']);self.assertTrue(data['no_license_requests'])
   with urlopen(Request(base+'/status',method='HEAD')) as response:self.assertEqual(response.status,200);self.assertEqual(response.read(),b'')
  finally:server.shutdown();server.server_close();thread.join()

 def test_host_context_lists_only_capability_names_without_invoking_values(self):
  secret='do-not-report-this-token'
  context={'native_bridge':lambda:1,'sdk_token':secret,'password':secret,'unrelated':secret}
  result=probe.host_context(context)
  self.assertEqual(result['capability_names'],['native_bridge','sdk_token']);self.assertNotIn(secret,json.dumps(result));self.assertTrue(result['present'])
