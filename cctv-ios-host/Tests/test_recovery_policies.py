from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('cc'), 'requires C compiler')
class RecoveryPolicies(unittest.TestCase):
    def test_listener_release_and_progress_evidence_and_image_backoff(self):
        root = Path(__file__).resolve().parents[1]
        source = r'''
#include "HostLocalPort.h"
#include "HostPlaybackProgress.h"
#include "HostImageFailurePolicy.h"
#include <stdlib.h>
int main(int argc,char **argv) {
 if(argc==3)return HostLocalPortState(atoi(argv[1]))==atoi(argv[2])?0:1;
 if(HostLocalPortState(0)!=-1||HostLocalPortState(65536)!=-1)return 2;
 if(HostImageFailureBackoff(404)!=120||HostImageFailureBackoff(429)!=60||HostImageFailureBackoff(492)!=60||HostImageFailureBackoff(500)!=30)return 3;
 HostPlaybackProgress p={0};HostPlaybackProgressSample(&p,0,0,1,0);
 for(int i=1;i<=8;i++)HostPlaybackProgressSample(&p,i,i,1,1);
 if(p.observed!=8||p.samples!=8)return 4;
 HostPlaybackProgressSample(&p,9,100,1,1);
 HostPlaybackProgressSample(&p,10,101,1,1);
 HostPlaybackProgressSample(&p,11,101,0,0);
 HostPlaybackProgressSample(&p,111,201,1,1);
 HostPlaybackProgressSample(&p,112,150,1,1);
 if(p.observed!=9)return 5;
 HostPlaybackProgressSample(&p,113,152,2,1);
 if(p.observed!=10)return 6;
 HostPlaybackProgressSample(&p,NAN,0,1,1);
 if(p.initialized)return 7;
 return 0;
}'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'policy.c').write_text(source)
            command = ['cc', '-std=c11', '-I', str(root / 'Sources'), str(path / 'policy.c'), '-lm', '-o', str(path / 'policy')]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            def run(*args):
                result = subprocess.run([str(path / 'policy'), *map(str, args)], capture_output=True)
                self.assertEqual(result.returncode, 0, (args, result.stderr))
            run()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
                run(port, 0)
                listener.listen(4)
                run(port, 1)
            run(port, 0)
