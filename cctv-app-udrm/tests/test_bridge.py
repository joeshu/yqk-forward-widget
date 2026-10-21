"""Offline regression checks; fixtures contain synthetic PSI/PES, no TV footage."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('standalone',ROOT/'cctv-app-udrm.py')
standalone=importlib.util.module_from_spec(spec);spec.loader.exec_module(standalone)
service=standalone.load_modules()
from ts_validator import mpeg_crc32, _packets, TSFormatError
from ts_mapper import plan_ts, transform_plan, following_proves_complete
from sdk_client import SDKClient, SDKError


def section(kind,body):
    n=len(body)+4;b=bytes([kind,0xb0|(n>>8),n&255])+body
    return b+mpeg_crc32(b).to_bytes(4,'big')

class Builder:
    def __init__(self):self.cc={}
    def packets(self,pid,payload):
        result=[]
        for n in range(0,len(payload),176):
            part=payload[n:n+176];cc=self.cc.get(pid,0);self.cc[pid]=(cc+1)%16
            size=183-len(part)
            result.append(bytes([71,(64 if n==0 else 0)|(pid>>8),pid&255,0x30|cc,size,0])+b'\xff'*(size-1)+part)
        return result
    def tables(self):
        pat=section(0,b'\x00\x01\xc1\x00\x00\x00\x01\xef\xff')
        pmt=section(2,b'\x00\x01\xc1\x00\x00\xe1\x00\xf0\x00\x1b\xe1\x00\xf0\x00\x0f\xe1\x01\xf0\x00')
        return self.packets(0,b'\x00'+pat)+self.packets(4095,b'\x00'+pmt)
    def video(self,bounded=True):
        es=b'\x00\x00\x00\x01\x65'+b'VIDEO'*100
        optional=b'\x80\x80\x05\x21\x00\x01\x00\x01'
        pes=b'\x00\x00\x01\xe0'+((len(es)+len(optional)) if bounded else 0).to_bytes(2,'big')+optional+es
        return self.packets(256,pes)
    def stream(self,bounded=True):
        return b''.join(self.tables()+self.video(bounded)+self.packets(257,b'AUDIO'*70))


class MappingTests(unittest.TestCase):
    def test_identity_and_only_video_es_can_change(self):
        source=Builder().stream();plan=plan_ts(source)
        self.assertEqual(transform_plan(plan,lambda b:b),source)
        output=transform_plan(plan,lambda b:b[:5]+b'X'*(len(b)-5))
        allowed={pos for frame in plan.frames for off,size in frame.spans for pos in range(off,off+size)}
        self.assertTrue(any(a!=b for a,b in zip(source,output)))
        for pos,(a,b) in enumerate(zip(source,output)):
            if pos not in allowed:self.assertEqual(a,b)
    def test_duplicate_video_stays_duplicate(self):
        b=Builder();tables=b.tables();video=b.video()
        source=b''.join(tables+video[:1]+video[:1]+video[1:])
        plan=plan_ts(source)
        self.assertEqual(len(plan.duplicates),1)
        output=transform_plan(plan,lambda x:x[:5]+b'Z'*(len(x)-5))
        off=len(tables)*188
        self.assertEqual(output[off:off+188],output[off+188:off+376]);_packets(output)
    def test_truncated_bounded_pes_and_size_change_rejected(self):
        b=Builder();source=b''.join(b.tables()+b.video()[:-1])
        with self.assertRaises(TSFormatError):plan_ts(source)
        with self.assertRaises(TSFormatError):transform_plan(plan_ts(Builder().stream()),lambda x:x[:-1])
    def test_unbounded_requires_real_adjacent_boundary(self):
        b=Builder();source=b.stream(False);following=b.stream(False)
        with self.assertRaises(TSFormatError):plan_ts(source)
        self.assertTrue(following_proves_complete(source,following))
        self.assertEqual(len(plan_ts(source,final_pes_complete=True).frames),1)
        bad=bytearray(following)
        video=next(p for p in _packets(following) if p.pid==256)
        off=(video.payload_offset//188)*188
        bad[off+1]&=~0x40
        self.assertFalse(following_proves_complete(source,bytes(bad)))
        bad[off+3]=(bad[off+3]&240)|((bad[off+3]+2)&15)
        with self.assertRaises(TSFormatError):following_proves_complete(source,bytes(bad))


FAKE='''import sys,json,time
print('UDRM_RPC '+json.dumps({'id':None,'code':0,'data':'','event':'ready'}),flush=True)
for line in sys.stdin:
 o=json.loads(line)
 if sys.argv[1]=='timeout':time.sleep(5)
 r={'id':o['id'] if sys.argv[1]!='wrong' else -999,'code':0,'data':o.get('data','')}
 if o.get('op')=='reset':r['event']='reset'
 print('UDRM_RPC '+json.dumps(r),flush=True)
'''
class SDKProtocolTests(unittest.TestCase):
    def client(self,directory,mode):
        path=Path(directory)/'fake.py';path.write_text(FAKE)
        return SDKClient([sys.executable,'-u',str(path),mode],workdir=directory,
            request_timeout=0.4,write_timeout=0.4,startup_timeout=2)
    def test_ready_process_reset_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.client(tmp,'good') as client:
                data=b'\x00\x00\x01\x65MEDIA'
                self.assertEqual(client.process('test',data),data);client.reset('test')
            self.assertFalse(client.healthy)
    def test_out_of_order_or_timeout_never_returns_media(self):
        for mode in ('wrong','timeout'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                with self.client(tmp,mode) as client:
                    with self.assertRaises(SDKError):client.process('test',b'\x00\x00\x01\x65MEDIA')
                    self.assertFalse(client.healthy)


class PlaylistHTTPTests(unittest.TestCase):
    def test_relative_variant_resolution_and_unsupported_key(self):
        bodies={'https://example.test/a/master.m3u8':b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n../b/media.m3u8\n',
            'https://example.test/b/media.m3u8':b'#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\npart.ts?q=1\n'}
        with patch.object(service,'fetch',side_effect=lambda u,*a:(bodies[u],u)):
            p=service.read_playlist('https://example.test/a/master.m3u8',2000000)
        self.assertEqual(p.entries[0].url,'https://example.test/b/part.ts?q=1')
        with patch.object(service,'fetch',return_value=(b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\na.ts\n','https://example.test/a')):
            with self.assertRaises(service.LiveError):service.read_playlist('https://example.test/a',2000000)
    def test_head_does_not_start_sdk_and_ranges_are_exact(self):
        channel=service.Channel('test','Test','https://example.test/live.m3u8')
        channel.cache['0'*32]=b'0123456789'
        live=service.LiveService({}, {'test':channel})
        live.stopping.set()
        http=service.ThreadingHTTPServer(('127.0.0.1',0),service.make_handler(live))
        thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
        base='http://127.0.0.1:'+str(http.server_port)
        try:
            with urlopen(Request(base+'/live/test.m3u8',method='HEAD')) as r:self.assertEqual(r.status,200)
            self.assertEqual(live.sdk.sessions,0)
            channel.playlist=service.Playlist((service.Entry(1,4,'https://example.test/a.ts'),),4,0,False)
            channel.updated=service.time.monotonic()
            # An in-progress background update holds the channel lock; cached
            # playlists/segments must still be served by the HTTP worker.
            with channel.lock:
                with urlopen(base+'/live/test.m3u8',timeout=0.5) as r:
                    self.assertIn(b'#EXTINF:4.000',r.read())
                with urlopen(base+'/segments/test/'+'0'*32+'.ts',timeout=0.5) as r:
                    self.assertEqual(r.read(),b'0123456789')
            with urlopen(Request(base+'/segments/test/'+'0'*32+'.ts',headers={'Range':'bytes=2-5'})) as r:
                self.assertEqual(r.status,206);self.assertEqual(r.headers['Content-Range'],'bytes 2-5/10');self.assertEqual(r.read(),b'2345')
        finally:
            http.shutdown();http.server_close();thread.join();live.close()

if __name__=='__main__':unittest.main()
