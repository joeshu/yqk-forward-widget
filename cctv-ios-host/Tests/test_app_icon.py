import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1] / 'Resources/Assets.xcassets/AppIcon.appiconset'

class AppIconTests(unittest.TestCase):
    def test_asset_catalog_has_marketing_and_device_sizes(self):
        data=json.loads((ROOT/'Contents.json').read_text())
        images=data['images']
        self.assertTrue(any(i['idiom']=='ios-marketing' and i['size']=='1024x1024' for i in images))
        self.assertTrue(any(i['idiom']=='iphone' and i['size']=='60x60' and i['scale']=='3x' for i in images))
        self.assertTrue(any(i['idiom']=='ipad' and i['size']=='83.5x83.5' and i['scale']=='2x' for i in images))
        for i in images:
            p=ROOT/i['filename']
            self.assertTrue(p.is_file(),p)
            w,h=struct.unpack('>II',p.read_bytes()[16:24])
            size=float(i['size'].split('x')[0]); scale=float(i['scale'][:-1])
            self.assertEqual((w,h),(round(size*scale),round(size*scale)))

if __name__=='__main__': unittest.main()
