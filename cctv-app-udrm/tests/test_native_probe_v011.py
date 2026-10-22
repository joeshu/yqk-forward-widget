import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

path=Path(__file__).resolve().parents[1]/'diagnostics/cctv-ios-native-probe-v0.1.1.py'
spec=importlib.util.spec_from_file_location('native_probe_v011',path)
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)

class Function:
    def __init__(self,fn):self.fn=fn
    def __call__(self,*args):return self.fn(*args)

class Process:
    def __init__(self,names=(),classes=()):
        self.lookups=[]
        self._dyld_image_count=Function(lambda:len(names))
        self._dyld_get_image_name=Function(lambda i:names[i])
        def lookup(name):
            self.lookups.append(name)
            return 0x12345678 if name.decode('ascii') in classes else None
        self.objc_lookUpClass=Function(lookup)

class ProbeV011Tests(unittest.TestCase):
    def collect(self,process):
        with patch.object(probe.sys,'platform','ios'),patch.object(probe.ctypes,'CDLL',return_value=process) as cdll:
            data=probe.collect();cdll.assert_called_once_with(None)
        return data

    def test_known_frameworks_are_distinguished_from_generic_player(self):
        process=Process([b'/private/App/Frameworks/CNPlayerSDK.framework/CNPlayerSDK',
                         b'/private/App/Frameworks/CicadaPlayerSDK.framework/CicadaPlayerSDK',
                         b'/private/App/Frameworks/xnet.framework/xnet'])
        data=self.collect(process)
        self.assertEqual(data['matching_loaded_components']['vendor_candidates'],['CNPlayerSDK'])
        self.assertEqual(data['matching_loaded_components']['generic_player_candidates'],['CicadaPlayerSDK'])
        self.assertEqual(data['matching_loaded_components']['media_network_helpers'],['xnet'])
        self.assertNotIn('/private/',json.dumps(data));self.assertFalse(data['official_ios_sdk_verified'])

    def test_static_registered_class_is_candidate_without_image_or_pointer_disclosure(self):
        process=Process(classes=('CNPlayer',))
        data=self.collect(process)
        self.assertTrue(data['registered_objc_classes']['CNPlayer'])
        self.assertTrue(data['objc_class_lookup_supported'])
        self.assertEqual(data['integration_state'],'vendor_component_candidate_requires_official_api')
        self.assertEqual(process.lookups,[name.encode('ascii') for name in probe.OBJC_CLASSES])
        self.assertNotIn(str(0x12345678),json.dumps(data));self.assertFalse(data['aptv_plugin_api_verified'])

    def test_generic_cicada_class_does_not_prove_cctv_compatibility(self):
        data=self.collect(Process(classes=('CicadaPlayer',)))
        self.assertEqual(data['integration_state'],'generic_player_candidate_requires_cctv_extension')
        self.assertFalse(data['registered_objc_classes']['CNPlayer'])
        self.assertFalse(data['official_ios_sdk_verified'])

    def test_missing_runtime_lookup_is_reported_without_loading_frameworks(self):
        data=self.collect(object())
        self.assertFalse(data['objc_class_lookup_supported'])
        self.assertFalse(any(data['registered_objc_classes'].values()))
        self.assertIn('this invocation',str(data['limits']))

    def test_non_apple_host_never_looks_up_runtime(self):
        with patch.object(probe.sys,'platform','linux'),patch.object(probe.ctypes,'CDLL') as cdll:
            data=probe.collect()
        cdll.assert_not_called();self.assertFalse(data['objc_class_lookup_supported'])

if __name__=='__main__':unittest.main()
