"""SDK libc wait semantics, including host yielding and interruption."""
import errno
import time
import unittest
from unittest.mock import patch
from test_bridge import standalone
import wasm_sdk

class SleepTests(unittest.TestCase):
    def test_microseconds_are_waited_without_socket_access(self):
        host=wasm_sdk.LoopbackSockets()
        with patch.object(wasm_sdk.time,'sleep') as wait:
            reply=host.handle({'name':'usleep','args':[25000]})
        wait.assert_called_once_with(0.025)
        self.assertEqual(reply,{'result':0,'writes':[]})
        self.assertFalse(host.sockets)
    def test_zero_yields_and_long_wait_is_rejected(self):
        host=wasm_sdk.LoopbackSockets()
        with patch.object(wasm_sdk.time,'sleep') as wait:
            self.assertEqual(host.handle({'name':'usleep','args':[0]})['result'],0)
            wait.assert_called_once_with(0)
            for n in [-1,30000001]:
                reply=host.handle({'name':'usleep','args':[n]})
                self.assertEqual(reply['result'],-1);self.assertEqual(reply['errno'],errno.EINVAL)
    def test_interruption_returns_errno_without_success(self):
        with patch.object(wasm_sdk.time,'sleep',side_effect=InterruptedError(errno.EINTR,'interrupted')):
            reply=wasm_sdk.LoopbackSockets().handle({'name':'usleep','args':[10000]})
        self.assertEqual(reply['result'],-1);self.assertEqual(reply['errno'],errno.EINTR)
    def test_wait_has_real_elapsed_time(self):
        start=time.monotonic()
        reply=wasm_sdk.LoopbackSockets().handle({'name':'usleep','args':[20000]})
        self.assertEqual(reply['result'],0);self.assertGreaterEqual(time.monotonic()-start,0.018)

if __name__=='__main__':unittest.main()
