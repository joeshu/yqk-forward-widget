import pathlib
import socket
import struct
import sys
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGINS_DIR = ROOT / "Plugins"
SOURCES_DIR = ROOT / "Sources"
if str(PLUGINS_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGINS_DIR))

import host_dash
import host_media_servers
import host_smb2


def _build_file_id_both_dir_entry(name: str, is_dir: bool, size: int, is_last: bool) -> bytes:
    name_u16 = name.encode("utf-16le")
    raw_len = 104 + len(name_u16)
    padded_len = (raw_len + 7) & ~7
    next_off = 0 if is_last else padded_len
    attrs = host_smb2.FILE_ATTRIBUTE_DIRECTORY if is_dir else 0x80
    buf = bytearray(padded_len)
    struct.pack_into("<I", buf, 0, next_off)
    struct.pack_into("<Q", buf, 40, size)
    struct.pack_into("<I", buf, 56, attrs)
    struct.pack_into("<I", buf, 60, len(name_u16))
    buf[104:104 + len(name_u16)] = name_u16
    return bytes(buf)


def _start_mock_smb2_server(dir_payload: bytes):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(2)
    port = srv.getsockname()[1]

    def _serve():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                break
            with conn:
                while True:
                    hdr = b""
                    while len(hdr) < 4:
                        chunk = conn.recv(4 - len(hdr))
                        if not chunk:
                            break
                        hdr += chunk
                    if len(hdr) < 4:
                        break
                    pkt_len = struct.unpack(">I", hdr)[0] & 0xFFFFFF
                    pkt = b""
                    while len(pkt) < pkt_len:
                        chunk = conn.recv(pkt_len - len(pkt))
                        if not chunk:
                            break
                        pkt += chunk
                    req = host_smb2.parse_smb2_header(pkt)
                    cmd = req["command"]
                    mid = req["message_id"]
                    if cmd == host_smb2.CMD_NEGOTIATE:
                        body = struct.pack("<HHH", 65, 1, 0x0300) + b"\x00" * 58
                        resp = host_smb2.pack_smb2_header(cmd, mid) + body
                    elif cmd == host_smb2.CMD_SESSION_SETUP:
                        body = struct.pack("<HHHH", 9, 0, 72, 0)
                        resp = host_smb2.pack_smb2_header(cmd, mid, session_id=0x11223344) + body
                    elif cmd == host_smb2.CMD_TREE_CONNECT:
                        body = struct.pack("<HBBIII", 16, 1, 0, 0, 0, 0)
                        resp = host_smb2.pack_smb2_header(cmd, mid, session_id=req["session_id"], tree_id=7) + body
                    elif cmd == host_smb2.CMD_CREATE:
                        body = bytearray(88)
                        struct.pack_into("<H", body, 0, 89)
                        body[64:80] = b"\x01" * 16
                        resp = host_smb2.pack_smb2_header(cmd, mid, session_id=req["session_id"], tree_id=req["tree_id"]) + bytes(body)
                    elif cmd == host_smb2.CMD_QUERY_DIRECTORY:
                        out_off = host_smb2.SMB2_HEADER_LEN + 8
                        body = struct.pack("<HHII", 9, out_off, len(dir_payload), 0)[:8] + dir_payload
                        resp = host_smb2.pack_smb2_header(cmd, mid, session_id=req["session_id"], tree_id=req["tree_id"]) + body
                    else:
                        body = struct.pack("<HH", 60, 0) + b"\x00" * 56
                        resp = host_smb2.pack_smb2_header(cmd, mid, session_id=req["session_id"], tree_id=req["tree_id"]) + body
                    conn.sendall(struct.pack(">I", len(resp)) + resp)

    t = threading.Thread(target=_serve, daemon=True)
    t.start()
    return srv, port


class Round46ProtocolAndArchCompletionTests(unittest.TestCase):
    def test_dash_clearkey_content_protection_bridge(self):
        mpd = """<?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT8S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <ContentProtection schemeIdUri="urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e"
                                 cenc:default_KID="00112233-4455-6677-8899-aabbccddeeff"/>
              <Representation id="v1" bandwidth="2000000" codecs="avc1.640028">
                <SegmentTemplate timescale="1000" duration="4000" startNumber="1"
                                 initialization="https://cdn.example.com/init.mp4"
                                 media="https://cdn.example.com/seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        # Without ClearKey keys, still strictly rejected as dash_requires_license
        with self.assertRaises(host_dash.DashError) as ctx:
            host_dash.parse_mpd(mpd.encode("utf-8"), "https://cdn.example.com/manifest.mpd")
        self.assertEqual(str(ctx.exception), "dash_requires_license")

        # With explicit ClearKey keys, parsed cleanly with clearkey metadata attached
        keys = {"00112233445566778899aabbccddeeff": "fedcba9876543210fedcba9876543210"}
        parsed = host_dash.parse_mpd(mpd.encode("utf-8"), "https://cdn.example.com/manifest.mpd", clearkey_keys=keys)
        self.assertTrue(parsed["clearkey"]["enabled"])
        self.assertEqual(parsed["clearkey"]["default_kid"], "00112233445566778899aabbccddeeff")
        self.assertEqual(parsed["clearkey"]["keys"], keys)

    def test_smb2_pure_python_client_and_server_spider_integration(self):
        dir_payload = (
            _build_file_id_both_dir_entry("Movies", is_dir=True, size=0, is_last=False)
            + _build_file_id_both_dir_entry("BladeRunner.4K.mkv", is_dir=False, size=4096, is_last=False)
            + _build_file_id_both_dir_entry("BladeRunner.4K.srt", is_dir=False, size=512, is_last=True)
        )
        srv, port = _start_mock_smb2_server(dir_payload)
        try:
            spider = host_media_servers.ServerSpider()
            spider.init({"type": "smb", "url": f"smb://127.0.0.1:{port}/media"})
            home = spider.homeContent()
            self.assertEqual(home["class"][0]["type_name"], "media")

            cat = spider.categoryContent("/", 1)
            self.assertEqual(len(cat["list"]), 2)
            folder = next(x for x in cat["list"] if x.get("directory"))
            movie = next(x for x in cat["list"] if not x.get("directory"))
            self.assertEqual(folder["name"], "Movies")
            self.assertEqual(movie["vod_name"], "BladeRunner.4K.mkv")

            play = spider.playerContent("smb", movie["vod_id"])
            self.assertTrue(play["url"].startswith(f"smb://127.0.0.1:{port}/media/BladeRunner.4K.mkv"))
            self.assertEqual(len(play.get("subtitles", [])), 1)
            self.assertTrue(play["subtitles"][0]["url"].endswith("BladeRunner.4K.srt"))

            search = spider.searchContent("Blade")
            self.assertEqual(len(search["list"]), 1)
        finally:
            srv.close()

    def test_unified_playback_protocol_mpv_pip_and_coordinators(self):
        proto_h = (SOURCES_DIR / "CCTVPlaybackEngineProtocol.h").read_text(encoding="utf-8")
        self.assertIn("@protocol CCTVPlaybackEngine <NSObject>", proto_h)
        self.assertIn("startPictureInPicture", proto_h)

        mpv_h = (SOURCES_DIR / "MediaPlaybackMPVAdapter.h").read_text(encoding="utf-8")
        mpv_m = (SOURCES_DIR / "MediaPlaybackMPVAdapter.m").read_text(encoding="utf-8")
        self.assertIn("<CCTVPlaybackEngine>", mpv_h)
        self.assertIn("AVPictureInPictureSampleBufferPlaybackDelegate", mpv_m)
        self.assertIn("AVSampleBufferDisplayLayer", mpv_m)
        self.assertIn("AVPictureInPictureControllerContentSource", mpv_m)

        coord_h = (SOURCES_DIR / "HostPlaybackAndResourceCoordinators.h").read_text(encoding="utf-8")
        coord_m = (SOURCES_DIR / "HostPlaybackAndResourceCoordinators.m").read_text(encoding="utf-8")
        for cls in ("HostLivePlayerCoordinator", "HostSubscriptionSyncCoordinator", "HostResourceBackupCoordinator"):
            self.assertIn(f"@interface {cls}", coord_h)
            self.assertIn(f"@implementation {cls}", coord_m)


if __name__ == "__main__":
    unittest.main()
