from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('cc'), 'requires a C compiler')
class ImageDecodePolicy(unittest.TestCase):
    def test_compressed_image_dimension_budget(self):
        root = Path(__file__).resolve().parents[1]
        source = '''#include "HostImageDecodePolicy.h"
int main(void) {
  if(!HostImageDimensionsAllowed(640, 960)) return 1;
  if(!HostImageDimensionsAllowed(4096, 4096)) return 2;
  if(HostImageDimensionsAllowed(7680, 4320)) return 3;
  if(HostImageDimensionsAllowed(100000, 100000)) return 4;
  if(HostImageDimensionsAllowed(16385, 1)) return 5;
  if(HostImageDimensionsAllowed(0, 100)) return 6;
  if(HostImageDimensionsAllowed(-1, 100)) return 7;
  if(HostImageDimensionsAllowed(NAN, 100)) return 8;
  if(HostImageDimensionsAllowed(100, INFINITY)) return 9;
  return 0;
}'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'policy.c').write_text(source)
            built = subprocess.run(['cc', '-std=c11', '-I', str(root / 'Sources'),
                                    str(path / 'policy.c'), '-o', str(path / 'policy')],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(path / 'policy')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
