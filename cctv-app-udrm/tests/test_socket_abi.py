"""Linux guest ABI must not inherit Darwin host numeric constants."""
import base64
import errno
import socket
import struct
import unittest
from unittest.mock import Mock,patch
from test_bridge import standalone
import wasm_sdk as w

class SocketABITests(unittest.TestCase):
 def test_darwin_nonblocking_errno_is_linux_einprogress(self):
  transport=w.LoopbackSockets();sock=Mock();sock.connect_ex.return_value=36;transport.sockets[1000]=sock
  raw=struct.pack('<H',2)+struct.pack('>H',12345)+socket.inet_aton('127.0.0.1')+b'\0'*8
  with patch.dict(errno.errorcode,{36:'EINPROGRESS'}):
   reply=transport.handle({'name':'connect','args':[1000,0,len(raw)],'data':base64.b64encode(raw).decode()})
  self.assertEqual(reply['result'],-1);self.assertEqual(reply['errno'],115)
 def test_sol_socket_and_so_error_are_translated(self):
  transport=w.LoopbackSockets();sock=Mock();sock.getsockopt.return_value=54;transport.sockets[1000]=sock
  with patch.object(socket,'SOL_SOCKET',65535),patch.object(socket,'SO_ERROR',4103),patch.dict(errno.errorcode,{54:'ECONNRESET'}):
   reply=transport.handle({'name':'getsockopt','args':[1000,1,4,123,456],'length':4})
  sock.getsockopt.assert_called_once_with(65535,4103)
  self.assertEqual(struct.unpack('<i',base64.b64decode(reply['writes'][0]['data']))[0],104)
 def test_send_flags_use_host_values(self):
  with patch.object(socket,'MSG_NOSIGNAL',524288,create=True):self.assertEqual(w.host_message_flags(16384),524288)
  with self.assertRaises(OSError):w.host_message_flags(0x10000000)
 def test_guest_socket_option_mapping(self):
  with patch.object(socket,'SOL_SOCKET',65535),patch.object(socket,'SO_RCVTIMEO',4102):
   self.assertEqual(w.host_sockopt(1,20),(65535,4102))
  with self.assertRaises(OSError):w.host_sockopt(1,99999)
 def test_host_error_is_converted_to_linux_errno(self):
  transport=w.LoopbackSockets();sock=Mock();transport.sockets[1000]=sock
  sock.recv.side_effect=BlockingIOError(35,'would block')
  with patch.dict(errno.errorcode,{35:'EAGAIN'}):
   reply=transport.handle({'name':'recv','args':[1000,123,64,0]})
  self.assertEqual(reply['errno'],11)

if __name__=='__main__':unittest.main()
