import base64
import http.server
import json
from pathlib import Path
import sys
import threading

root=Path(__file__).resolve().parents[1]/'JARFixture'
log_lock=threading.Lock()

def log_record(value):
    with log_lock:
        sys.stdout.write(json.dumps(value,separators=(',',':'))+'\n')
        sys.stdout.flush()

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/fixture.jar':
            if self.headers.get('X-Jar-Fixture')!='jar-only':self.send_error(403);return
            data=base64.b64decode((root/'fixture.jar.b64').read_bytes());mime='application/java-archive'
        elif self.path=='/video.mp4':
            if self.headers.get('X-Media-Fixture')!='media-only' or self.headers.get('X-Jar-Fixture'):self.send_error(403);return
            data=base64.b64decode((root/'video.mp4.b64').read_bytes());mime='video/mp4'
        else:self.send_error(404);return
        start,end=0,len(data)-1;status=200
        requested=self.headers.get('Range','')
        if requested.startswith('bytes=') and ',' not in requested:
            first,last=requested[6:].split('-',1)
            if first:start=int(first);end=min(end,int(last)) if last else end
            else:start=max(0,len(data)-int(last))
            if start> end:self.send_error(416);return
            status=206
        self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(end-start+1))
        if status==206:self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
        self.end_headers();self.wfile.write(data[start:end+1])
        log_record({'path':self.path,'status':status,'jar_header':bool(self.headers.get('X-Jar-Fixture')),'media_header':bool(self.headers.get('X-Media-Fixture'))})
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
Path(sys.argv[1]).write_text(str(server.server_port));server.serve_forever()
