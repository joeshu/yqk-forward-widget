from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('cc') and hasattr(signal, 'SIGPIPE'), 'requires POSIX C compiler')
class BrokenPipeProtection(unittest.TestCase):
    def test_closed_socket_default_and_protected_processes_and_custom_handler(self):
        root = Path(__file__).resolve().parents[1]
        source = r'''#include "HostBrokenPipeProtection.h"
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
static void custom(int value) {(void)value;}
int main(int argc,char **argv) {
  struct sigaction initial={0};initial.sa_handler=SIG_DFL;sigemptyset(&initial.sa_mask);
  if(sigaction(SIGPIPE,&initial,0)!=0) return 10;
  if(argc>1 && strcmp(argv[1],"custom")==0) {
    initial.sa_handler=custom;sigaction(SIGPIPE,&initial,0);
    if(HostProtectDefaultBrokenPipe()!=2) return 11;
    sigaction(SIGPIPE,0,&initial);
    return initial.sa_handler==custom?0:12;
  }
  if(argc>1 && strcmp(argv[1],"protected")==0) {
    if(HostProtectDefaultBrokenPipe()!=1) return 13;
    if(HostProtectDefaultBrokenPipe()!=0) return 14;
  }
  int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair)!=0) return 15;
  close(pair[1]);int result=(int)send(pair[0],"x",1,0);int code=errno;close(pair[0]);
  return result==-1 && code==EPIPE?0:16;
}'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'protection.c').write_text(source)
            built = subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L',
                                    '-I', str(root / 'Sources'), str(path / 'protection.c'),
                                    '-o', str(path / 'protection')], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            default = subprocess.run([str(path / 'protection'), 'default'], capture_output=True)
            self.assertEqual(default.returncode, -signal.SIGPIPE)
            for mode in ('protected', 'custom'):
                result = subprocess.run([str(path / 'protection'), mode], capture_output=True)
                self.assertEqual(result.returncode, 0, mode)
