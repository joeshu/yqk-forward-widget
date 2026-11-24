"""Pure-Python minimal SMB2/3 client for LAN directory browsing (zero C dependencies).

Implements NetBIOS framing + SMB2 Negotiate / Session Setup (Anonymous/Guest) /
Tree Connect / Create / Query Directory (FileIdBothDirectoryInformation) / Close
over TCP 445 so iOS embedded Python 3.13 can browse LAN NAS shares natively.
"""
import socket
import struct

SMB2_MAGIC = b'\xfeSMB'
SMB2_HEADER_LEN = 64

CMD_NEGOTIATE = 0x0000
CMD_SESSION_SETUP = 0x0001
CMD_TREE_CONNECT = 0x0003
CMD_CREATE = 0x0005
CMD_CLOSE = 0x0006
CMD_QUERY_DIRECTORY = 0x000E

STATUS_SUCCESS = 0x00000000
STATUS_MORE_PROCESSING_REQUIRED = 0xC0000016
STATUS_NO_MORE_FILES = 0x80000006

FILE_ATTRIBUTE_DIRECTORY = 0x00000010


class SMB2Error(RuntimeError):
    pass


def pack_smb2_header(command: int, message_id: int, session_id: int = 0, tree_id: int = 0, credits_req: int = 1) -> bytes:
    return struct.pack(
        '<4sHHIHHIIQIIQ16s',
        SMB2_MAGIC,
        SMB2_HEADER_LEN,
        0,              # CreditCharge
        0,              # Status
        command,
        credits_req,
        0,              # Flags
        0,              # NextCommand
        message_id,
        0,              # Reserved / ProcessId
        tree_id,
        session_id,
        b'\x00' * 16,   # Signature
    )


def parse_smb2_header(packet: bytes) -> dict:
    if len(packet) < SMB2_HEADER_LEN or packet[:4] != SMB2_MAGIC:
        raise SMB2Error('Invalid SMB2 header')
    (_, struct_size, _, status, command, _, flags, _, msg_id, _, tree_id, session_id, _) = struct.unpack_from(
        '<4sHHIHHIIQIIQ16s', packet, 0
    )
    if struct_size != SMB2_HEADER_LEN:
        raise SMB2Error('Unexpected SMB2 header size')
    return {
        'status': status,
        'command': command,
        'flags': flags,
        'message_id': msg_id,
        'tree_id': tree_id,
        'session_id': session_id,
        'body': packet[SMB2_HEADER_LEN:],
    }


def parse_file_id_both_dir_info(buf: bytes) -> list[dict]:
    """Parse SMB2 FileIdBothDirectoryInformation (level 0x25) entries."""
    entries: list[dict] = []
    pos = 0
    while pos + 104 <= len(buf):
        next_offset = struct.unpack_from('<I', buf, pos)[0]
        end_of_file = struct.unpack_from('<Q', buf, pos + 40)[0]
        file_attrs = struct.unpack_from('<I', buf, pos + 56)[0]
        name_len = struct.unpack_from('<I', buf, pos + 60)[0]
        name_start = pos + 104
        name_end = name_start + name_len
        if name_end <= len(buf):
            name = buf[name_start:name_end].decode('utf-16le', errors='replace')
            if name not in ('.', '..'):
                entries.append({
                    'name': name,
                    'directory': bool(file_attrs & FILE_ATTRIBUTE_DIRECTORY),
                    'size': end_of_file,
                })
        if next_offset == 0:
            break
        pos += next_offset
    return entries


class SMB2Client:
    def __init__(self, host: str, port: int = 445, timeout: float = 6.0):
        self.host = host
        self.port = int(port or 445)
        self.timeout = float(timeout)
        self.sock: socket.socket | None = None
        self.message_id = 0
        self.session_id = 0
        self.tree_id = 0

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _recv_exact(self, length: int) -> bytes:
        assert self.sock is not None
        buf = bytearray()
        while len(buf) < length:
            chunk = self.sock.recv(length - len(buf))
            if not chunk:
                raise SMB2Error('SMB2 connection closed prematurely')
            buf.extend(chunk)
        return bytes(buf)

    def _transact(self, command: int, body: bytes) -> dict:
        if self.sock is None:
            raise SMB2Error('SMB2 socket not connected')
        mid = self.message_id
        self.message_id += 1
        payload = pack_smb2_header(command, mid, session_id=self.session_id, tree_id=self.tree_id) + body
        if len(payload) > 0xFFFFFF:
            raise SMB2Error('SMB2 request exceeds NetBIOS frame limit')
        frame = struct.pack('>I', len(payload)) + payload
        self.sock.sendall(frame)
        hdr = self._recv_exact(4)
        resp_len = struct.unpack('>I', hdr)[0] & 0xFFFFFF
        if resp_len < SMB2_HEADER_LEN or resp_len > 16 * 1024 * 1024:
            raise SMB2Error(f'Invalid SMB2 response length: {resp_len}')
        return parse_smb2_header(self._recv_exact(resp_len))

    def negotiate(self) -> int:
        dialects = (0x0202, 0x0210, 0x0300, 0x0302)
        body = struct.pack('<HHHHI16sQ', 36, len(dialects), 1, 0, 0, b'\x00' * 16, 0)
        body += b''.join(struct.pack('<H', d) for d in dialects)
        resp = self._transact(CMD_NEGOTIATE, body)
        if resp['status'] != STATUS_SUCCESS:
            raise SMB2Error(f'SMB2 negotiate failed: 0x{resp["status"]:08x}')
        if len(resp['body']) >= 6:
            return struct.unpack_from('<H', resp['body'], 4)[0]
        return 0x0202

    def session_setup(self, username: str = '', password: str = '') -> int:
        # Anonymous/Guest NTLMSSP negotiate blob (minimal SPNEGO/NTLMSSP Type 1)
        ntlm_neg = b'NTLMSSP\x00' + struct.pack('<IIHHIIHHI', 1, 0x00008205, 0, 0, 0, 0, 0, 0, 0)
        sec_offset = SMB2_HEADER_LEN + 24
        body = struct.pack('<HBBIIHHQ', 25, 0, 1, 0, 0, sec_offset, len(ntlm_neg), 0) + ntlm_neg
        resp = self._transact(CMD_SESSION_SETUP, body)
        if resp['status'] not in (STATUS_SUCCESS, STATUS_MORE_PROCESSING_REQUIRED):
            raise SMB2Error(f'SMB2 session setup failed: 0x{resp["status"]:08x}')
        self.session_id = resp['session_id']
        if resp['status'] == STATUS_MORE_PROCESSING_REQUIRED:
            # Send minimal NTLMSSP Type 3 auth blob (guest / anonymous)
            user_u16 = (username or '').encode('utf-16le')
            ntlm_auth = b'NTLMSSP\x00' + struct.pack('<I', 3)
            # LM, NT, Domain, User, Workstation, SessionKey descriptors (6 * 8 = 48 bytes) + Flags (4)
            base_off = 12 + 48 + 4
            ntlm_auth += struct.pack('<HHI', 0, 0, base_off)       # LM
            ntlm_auth += struct.pack('<HHI', 0, 0, base_off)       # NT
            ntlm_auth += struct.pack('<HHI', 0, 0, base_off)       # Domain
            ntlm_auth += struct.pack('<HHI', len(user_u16), len(user_u16), base_off)  # User
            ntlm_auth += struct.pack('<HHI', 0, 0, base_off + len(user_u16))          # Workstation
            ntlm_auth += struct.pack('<HHI', 0, 0, base_off + len(user_u16))          # SessionKey
            ntlm_auth += struct.pack('<I', 0x00008205) + user_u16
            body2 = struct.pack('<HBBIIHHQ', 25, 0, 1, 0, 0, sec_offset, len(ntlm_auth), 0) + ntlm_auth
            resp2 = self._transact(CMD_SESSION_SETUP, body2)
            if resp2['status'] != STATUS_SUCCESS:
                raise SMB2Error(f'SMB2 session auth failed: 0x{resp2["status"]:08x}')
            self.session_id = resp2['session_id']
        return self.session_id

    def tree_connect(self, share: str) -> int:
        unc = f'\\\\{self.host}\\{share.strip("/")}'.encode('utf-16le')
        path_offset = SMB2_HEADER_LEN + 8
        body = struct.pack('<HHHH', 9, 0, path_offset, len(unc)) + unc
        resp = self._transact(CMD_TREE_CONNECT, body)
        if resp['status'] != STATUS_SUCCESS:
            raise SMB2Error(f'SMB2 tree connect failed: 0x{resp["status"]:08x}')
        self.tree_id = resp['tree_id']
        return self.tree_id

    def list_directory(self, rel_path: str = '') -> list[dict]:
        clean = rel_path.strip('/').replace('/', '\\')
        name_u16 = clean.encode('utf-16le')
        name_offset = SMB2_HEADER_LEN + 56
        # SMB2 CREATE request (57 bytes fixed + name)
        create_body = struct.pack(
            '<HBBIIQQIIIIIIHHII',
            57, 0, 0, 0, 2, 0, 0,
            0x00100081,  # FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE
            FILE_ATTRIBUTE_DIRECTORY,
            0x00000007,  # FILE_SHARE_READ | WRITE | DELETE
            1,           # FILE_OPEN
            0x00000001,  # FILE_DIRECTORY_FILE
            name_offset, len(name_u16),
            0, 0,
            0,
        )[:56] + (name_u16 if name_u16 else b'\x00\x00')
        c_resp = self._transact(CMD_CREATE, create_body)
        if c_resp['status'] != STATUS_SUCCESS or len(c_resp['body']) < 80:
            raise SMB2Error(f'SMB2 open directory failed: 0x{c_resp["status"]:08x}')
        file_id = c_resp['body'][64:80]

        pattern = '*'.encode('utf-16le')
        pat_offset = SMB2_HEADER_LEN + 32
        entries: list[dict] = []
        try:
            q_body = struct.pack('<HBBII16sHHI', 33, 0x25, 0x01, 0, 0, file_id, pat_offset, len(pattern), 65536)[:32] + pattern
            q_resp = self._transact(CMD_QUERY_DIRECTORY, q_body)
            if q_resp['status'] == STATUS_SUCCESS and len(q_resp['body']) >= 8:
                out_off, out_len = struct.unpack_from('<HH', q_resp['body'], 2)
                rel_off = max(0, out_off - SMB2_HEADER_LEN)
                entries = parse_file_id_both_dir_info(q_resp['body'][rel_off:rel_off + out_len])
            elif q_resp['status'] != STATUS_NO_MORE_FILES:
                raise SMB2Error(f'SMB2 query directory failed: 0x{q_resp["status"]:08x}')
        finally:
            close_body = struct.pack('<HHI16s', 24, 0, 0, file_id)
            try:
                self._transact(CMD_CLOSE, close_body)
            except Exception:
                pass
        return entries
