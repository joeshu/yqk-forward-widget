import importlib.util
import json
from pathlib import Path
import sys
import threading
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
PLUGINS=Path(__file__).resolve().parents[1]/'Plugins'
sys.path.insert(0,str(PLUGINS))
from host_media_servers import ServerSpider
from host_media_relay import ll_hls_upstream_url
from host_media_runtime import playback

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def send(self,value,status=200,headers=None):
        data=value if isinstance(value,bytes) else json.dumps(value).encode();self.send_response(status)
        for k,v in (headers or {}).items():self.send_header(k,v)
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        self.server.seen.append((self.path,dict(self.headers)));path=urlsplit(self.path).path
        if path.endswith('/Views'):return self.send({'Items':[{'Id':'movies','Name':'电影'}]})
        if path=='/Users':return self.send([{'Id':'user'}])
        if path.endswith('/Items/movie'):return self.send({'Id':'movie','Name':'影片','Type':'Movie'})
        if path.endswith('/Items'):return self.send({'Items':[{'Id':'movie','Name':'影片','Type':'Movie'}],'TotalRecordCount':61})
        if path=='/player_api.php':
            action=parse_qs(urlsplit(self.path).query).get('action',[''])[0]
            if not action:return self.send({'user_info':{'auth':1}})
            if action.endswith('_categories'):return self.send([{'category_id':'1','category_name':'频道'}])
            if action=='get_vod_streams':return self.send([{'stream_id':i,'name':'影片'+str(i),'container_extension':'mp4'} for i in range(65)])
            return self.send([])
        if path=='/redirect':return self.send(b'',302,{'Location':'http://example.invalid/private'})
        if path=='/denied':return self.send(b'',401)
        return self.send({},404)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)));self.send({'AccessToken':'session-token','User':{'Id':'user'}})
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        self.send(b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/a%20movie.mp4</d:href><d:propstat><d:prop><d:displayname>A Movie</d:displayname><d:resourcetype/></d:prop></d:propstat></d:response></d:multistatus>',207)

class MediaServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);cls.server.seen=[];cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start();cls.base='http://127.0.0.1:%d/'%cls.server.server_port
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def spider(self,kind='emby',**options):
        value=ServerSpider();value.init(dict(type=kind,url=self.base,**options));return value
    def test_emby_login_browse_detail_play(self):
        spider=self.spider(username='alice',password='password');self.assertEqual(spider.homeContent()['class'][0]['type_id'],'movies')
        page=spider.categoryContent('movies','2');self.assertEqual(page['pagecount'],2);self.assertTrue(any('StartIndex=60' in url for url,_ in self.server.seen))
        detail=spider.detailContent([page['list'][0]['vod_id']])['list'][0];episode=detail['vod_play_url'].split('$',1)[1];result=playback(spider.playerContent('',episode))
        self.assertIn('/Videos/movie/stream?',result['url']);self.assertEqual(result['headers']['X-Emby-Token'],'session-token')
    def test_jellyfin_api_key_search(self):
        result=self.spider('jellyfin',apiKey='key',userId='user').searchContent('影片');self.assertEqual(len(result['list']),1);self.assertEqual(self.server.seen[-1][1]['X-Emby-Token'],'key')
    def test_xtream_pagination_play(self):
        spider=self.spider('xtream',username='a user',password='p/word');self.assertEqual(len(spider.homeContent()['class']),3)
        page=spider.categoryContent('vod:1','2');self.assertEqual(len(page['list']),5);self.assertIn('/movie/a%20user/p%2Fword/60.mp4',spider.playerContent('',page['list'][0]['vod_id'])['url'])
    def test_webdav_listing_play(self):
        spider=self.spider('webdav',username='u',password='p');spider.base=self.base+'dav/';page=spider.categoryContent('','1');self.assertEqual(len(page['list']),1)
        result=spider.playerContent('',page['list'][0]['vod_id']);self.assertTrue(result['url'].endswith('/dav/a%20movie.mp4'));self.assertEqual(result['header']['Authorization'],'Basic dTpw')
    def test_rejects_cross_origin_redirect(self):
        with self.assertRaises(ValueError):self.spider()._request('redirect')
    def test_authentication_error(self):
        with self.assertRaisesRegex(ValueError,'authentication'):self.spider()._request('denied')
    def test_stopped_session(self):
        spider=self.spider();spider.destroy()
        with self.assertRaises(RuntimeError):spider._request('Users')
    def test_rejects_embedded_credentials(self):
        with self.assertRaises(ValueError):ServerSpider().init({'type':'webdav','url':'https://u:p@example.invalid'})
    def test_rejects_unknown_protocol(self):
        with self.assertRaises(ValueError):self.spider('ftp')
    def test_ll_hls_signed_bytes(self):
        original='https://cdn.test/a.m3u8?sig=a%2Bb+z&token=one';actual=ll_hls_upstream_url(original,'/media/key?_HLS_msn=12&_HLS_part=3&_HLS_skip=v2&evil=x');self.assertEqual(actual,original+'&_HLS_msn=12&_HLS_part=3&_HLS_skip=v2')
    def test_ll_hls_invalid_controls(self):
        for query in ('_HLS_msn=-1','_HLS_skip=no','_HLS_part=1&_HLS_part=2'):
            with self.subTest(query=query),self.assertRaises(ValueError):ll_hls_upstream_url('https://cdn.test/a.m3u8','/?'+query)
    def test_ll_hls_replaces_stale_controls(self):self.assertEqual(ll_hls_upstream_url('https://cdn.test/a?_HLS_msn=1&sig=%2B','/?_HLS_msn=2'),'https://cdn.test/a?sig=%2B&_HLS_msn=2')
    def test_rtmp_normalization(self):
        for scheme in ('rtmp','rtmps'):
            result=playback({'url':scheme+'://stream.test/live/key'});self.assertEqual(result['playbackEngine'],'cicada');self.assertFalse(result['requiresWebPlayback'])
    def test_unsupported_containers(self):
        for extension in ('avi','wmv','asf','rmvb'):
            result=playback({'url':'https://stream.test/video.'+extension});self.assertEqual(result['capabilityStatus'],'unsupported');self.assertNotEqual(result.get('playbackEngine'),'cicada')
    def test_python_runtime_pipeline(self):
        from host_media_runtime import PythonSpider, MediaRuntime
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,'server.py').write_text('from host_media_servers import ServerSpider\nclass Spider(ServerSpider):\n    pass\n')
            engine=PythonSpider(directory,'server.py',{'type':'emby','url':self.base,'apiKey':'key','userId':'user'})
            runtime=MediaRuntime(engine)
            try:
                home=runtime.call('home',{})
                self.assertEqual(home['categories'][0]['id'],'movies')
                listing=runtime.call('category',{'categoryId':'movies','page':1})
                detail=runtime.call('detail',{'id':listing['items'][0]['id']})
                episode=detail['lines'][0]['episodes'][0]
                result=runtime.call('play',{'id':episode['id'],'lineId':detail['lines'][0]['id']})
                self.assertEqual(result['headers']['X-Emby-Token'],'key')
            finally:runtime.close()
    def test_webdav_cannot_escape_collection(self):
        spider=self.spider('webdav');spider.base=self.base+'dav/'
        for address in ('../admin','/private/video.mp4','/dav/%2e%2e/private/video.mp4'):
            with self.subTest(address=address),self.assertRaises(ValueError):spider._url(address)
    def test_search_capabilities_are_truthful(self):
        self.assertIn('search',self.spider('emby').supported_operations)
        self.assertNotIn('search',self.spider('webdav').supported_operations)
    def test_page_credentials_strip_sensitive_custom_headers(self):
        from host_media_runtime import strip_media_credentials
        self.assertEqual(strip_media_credentials({'Cookie':'private','Authorization':'private','X-API-Key':'private','X-Session':'private','User-Agent':'agent'}),{'User-Agent':'agent'})
    def test_http_only_metadata_urls_remain_http_only(self):
        from host_media_runtime import valid_media_url
        self.assertFalse(valid_media_url('rtmp://stream.test/live/key'))
        self.assertTrue(valid_media_url('https://stream.test/subtitle.vtt'))
    def test_ll_hls_controls_do_not_leak_to_segments(self):
        from host_media_relay import MediaRelay
        relay=MediaRelay()
        try:
            relay.rewrite('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\npart.ts\n','https://cdn.test/live.m3u8?sig=a%2Bb&_HLS_msn=5&_HLS_part=1',{},('https','cdn.test'),'http://127.0.0.1:1234')
            urls=[record[0][0] for record in relay.segments.values()]
            self.assertTrue(any('part.ts?sig=a%2Bb' in url for url in urls))
            self.assertFalse(any('_HLS_' in url for url in urls))
        finally:relay.close()
    def test_redirect_strips_custom_credentials(self):
        from host_media_relay import ScopedRedirect
        from urllib.request import Request
        request=Request('https://one.test/video',headers={'Authorization':'private','X-API-Key':'private','X-Session':'private','User-Agent':'agent'})
        redirected=ScopedRedirect().redirect_request(request,None,302,'redirect',{},'https://two.test/video')
        headers={key.lower():value for key,value in redirected.header_items()}
        self.assertNotIn('authorization',headers);self.assertNotIn('x-api-key',headers);self.assertNotIn('x-session',headers);self.assertEqual(headers['user-agent'],'agent')
    def test_generated_registry(self):
        spec=importlib.util.spec_from_file_location('generator',PLUGINS.parent/'Scripts/generate_media_capabilities.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);self.assertEqual((PLUGINS.parent/'Sources/MediaCapabilityRegistry.h').read_text(),module.render())
