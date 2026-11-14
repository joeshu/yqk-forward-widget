"""Bounded, opt-in adapters for user-owned media servers. No import-time I/O."""
import base64
import json
import posixpath
import time
import urllib.parse
import xml.etree.ElementTree as ET

_MEDIA = ('.mp4', '.m4v', '.mov', '.mkv', '.webm', '.flv', '.m3u8', '.mp3', '.m4a', '.aac', '.ts')
WEBDAV_ROOT_ID = '__webdav_root__'


class ServerSpider:
    PAGE_SIZE = 60

    def init(self, extend=''):
        self.config = json.loads(extend) if isinstance(extend, str) and extend else dict(extend or {})
        self.kind = self.config.get('type')
        if self.kind not in ('emby', 'jellyfin', 'xtream', 'webdav'):
            raise ValueError('Unsupported media server type')
        self.base = str(self.config.get('url', '')).rstrip('/') + '/'
        parts = urllib.parse.urlsplit(self.base)
        if parts.scheme not in ('http', 'https') or not parts.hostname or parts.username or parts.password:
            raise ValueError('Media server requires a valid HTTP(S) URL without embedded credentials')
        if parts.query or parts.fragment:
            raise ValueError('Configure the server base URL without query or fragment')
        self.origin = (parts.scheme.lower(), parts.netloc.lower())
        self.supported_operations = ('home', 'category', 'detail', 'play') + (('search',) if self.kind in ('emby', 'jellyfin') else ())
        self.user_id = str(self.config.get('userId', ''))
        self.token = str(self.config.get('apiKey', ''))
        self.closed = False

    def getName(self):
        return str(self.config.get('name') or self.kind)

    def _headers(self):
        headers = {'User-Agent': 'CCTVHost/1', 'Accept': 'application/json'}
        if self.kind in ('emby', 'jellyfin'):
            headers['X-Emby-Authorization'] = 'MediaBrowser Client="CCTVHost", Device="iPhone", DeviceId="cctvhost", Version="1"'
            if self.token:
                headers['X-Emby-Token'] = self.token
        if self.kind == 'webdav' and self.config.get('username'):
            pair = '%s:%s' % (self.config['username'], self.config.get('password', ''))
            headers['Authorization'] = 'Basic ' + base64.b64encode(pair.encode()).decode()
        return headers

    def _url(self, path='', query=None):
        url = urllib.parse.urljoin(self.base, path)
        parts = urllib.parse.urlsplit(url)
        if (parts.scheme.lower(), parts.netloc.lower()) != self.origin:
            raise ValueError('Media server response attempted to leave its origin')
        if self.kind == 'webdav':
            root = posixpath.normpath(urllib.parse.unquote(urllib.parse.urlsplit(self.base).path))
            target = posixpath.normpath(urllib.parse.unquote(parts.path))
            if root != '/' and target != root and not target.startswith(root + '/'):
                raise ValueError('WebDAV path leaves the configured collection')
        if query:
            url += ('&' if parts.query else '?') + urllib.parse.urlencode(query)
        return url

    def _request(self, path='', query=None, method='GET', body=None, xml=False):
        import requests
        if self.closed:
            raise RuntimeError('Media server stopped')
        headers = self._headers()
        if xml:
            headers.update({'Depth': '1', 'Content-Type': 'application/xml', 'Accept': 'application/xml'})
        url = self._url(path, query)
        deadline = time.monotonic() + 15
        for hop in range(6):
            response = requests.request(method, url, headers=headers, json=None if xml else body,
                                        data=body if xml else None, stream=True, timeout=(5, 5), allow_redirects=False)
            try:
                if response.status_code in (301, 302, 303, 307, 308):
                    if hop == 5:
                        raise ValueError('Too many media server redirects')
                    url = self._url(urllib.parse.urljoin(response.url, response.headers.get('Location', '')))
                    continue
                if response.status_code in (401, 403):
                    raise ValueError('Media server authentication failed')
                if not 200 <= response.status_code < 300:
                    raise ValueError('Media server HTTP error %s' % response.status_code)
                content = bytearray()
                for chunk in response.iter_content(32768):
                    if self.closed or time.monotonic() > deadline:
                        raise TimeoutError('Media server request timed out or stopped')
                    content.extend(chunk)
                    if len(content) > 8 * 1024 * 1024:
                        raise ValueError('Media server response exceeds 8 MiB')
                return bytes(content) if xml else json.loads(content)
            finally:
                response.close()
        raise ValueError('Media server redirect failed')

    def _authenticate(self):
        if self.kind in ('emby', 'jellyfin') and not self.token:
            result = self._request('Users/AuthenticateByName', method='POST', body={
                'Username': self.config.get('username', ''), 'Pw': self.config.get('password', '')})
            self.token = str(result.get('AccessToken') or '')
            self.user_id = str((result.get('User') or {}).get('Id') or '')
            if not self.token:
                raise ValueError('Media server did not provide an access token')
        if self.kind in ('emby', 'jellyfin') and not self.user_id:
            users = self._request('Users')
            if not isinstance(users, list) or len(users) != 1:
                raise ValueError('Configure userId for this media server')
            self.user_id = str(users[0]['Id'])

    @staticmethod
    def _id(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).decode()

    @staticmethod
    def _decode(value):
        if len(value) > 16384:
            raise ValueError('Invalid server item')
        return json.loads(base64.urlsafe_b64decode(value))

    def _emby_item(self, item):
        identifier = str(item['Id'])
        return {'vod_id': self._id({'id': identifier, 'type': item.get('Type', 'Movie')}),
                'vod_name': item.get('Name', identifier), 'vod_remarks': str(item.get('ProductionYear') or ''),
                'vod_pic': self._url('Items/%s/Images/Primary' % urllib.parse.quote(identifier, safe='')),
                'posterHeaders': self._headers()}

    def _xtream(self, action=None, **query):
        args = {'username': self.config.get('username', ''), 'password': self.config.get('password', '')}
        if action:
            args['action'] = action
        args.update(query)
        return self._request('player_api.php', args)

    def _dav(self, path=''):
        content = self._request(path, method='PROPFIND', xml=True,
            body=b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>')
        if b'<!DOCTYPE' in content.upper() or b'<!ENTITY' in content.upper():
            raise ValueError('Unsupported WebDAV XML declaration')
        result = []
        current = urllib.parse.unquote(urllib.parse.urlsplit(self._url(path)).path).rstrip('/')
        root_path = urllib.parse.unquote(urllib.parse.urlsplit(self.base).path).rstrip('/') + '/'
        for response in ET.fromstring(content).findall('{DAV:}response'):
            href = response.findtext('{DAV:}href') or ''
            url = self._url(href)
            decoded = urllib.parse.unquote(urllib.parse.urlsplit(url).path)
            if decoded.rstrip('/') == current or not decoded.startswith(root_path):
                continue
            prop = response.find('{DAV:}propstat/{DAV:}prop')
            if prop is None:
                continue
            directory = prop.find('{DAV:}resourcetype/{DAV:}collection') is not None
            if not directory and not decoded.lower().endswith(_MEDIA):
                continue
            result.append({'url': url, 'directory': directory,
                           'name': prop.findtext('{DAV:}displayname') or decoded.rstrip('/').rsplit('/', 1)[-1]})
        return result[:5000]

    def homeContent(self, filter=True):
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate()
            views = self._request('Users/%s/Views' % urllib.parse.quote(self.user_id, safe=''))
            classes = [{'type_id': str(x['Id']), 'type_name': x.get('Name', 'Library')} for x in views.get('Items', [])]
        elif self.kind == 'xtream':
            auth = self._xtream()
            if str((auth.get('user_info') or {}).get('auth')) != '1':
                raise ValueError('Xtream authentication failed')
            classes = []
            for mode in ('live', 'vod', 'series'):
                for row in self._xtream('get_%s_categories' % mode):
                    classes.append({'type_id': mode + ':' + str(row['category_id']), 'type_name': row.get('category_name', mode)})
        else:
            classes = [{'type_id': WEBDAV_ROOT_ID, 'type_name': '根目录'}]
        return {'class': classes, 'list': []}

    def categoryContent(self, tid, pg, filter=True, extend=None):
        page = max(1, int(pg)); offset = (page - 1) * self.PAGE_SIZE
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate()
            data = self._request('Users/%s/Items' % urllib.parse.quote(self.user_id, safe=''), {
                'ParentId': tid, 'StartIndex': offset, 'Limit': self.PAGE_SIZE, 'Recursive': 'true',
                'IncludeItemTypes': 'Movie,Series,Video', 'Fields': 'Overview', 'SortBy': 'SortName'})
            items = [self._emby_item(x) for x in data.get('Items', [])]; total = int(data.get('TotalRecordCount', len(items)))
        elif self.kind == 'xtream':
            mode, category = tid.split(':', 1)
            if mode not in ('live', 'vod', 'series'):
                raise ValueError('Invalid Xtream category')
            action = 'get_series' if mode == 'series' else 'get_%s_streams' % mode
            rows = self._xtream(action, category_id=category)
            if not isinstance(rows, list):
                raise ValueError('Invalid Xtream listing')
            total = len(rows);items = []
            for x in rows[offset:offset + self.PAGE_SIZE]:
                ident = x.get('series_id') if mode == 'series' else x.get('stream_id')
                items.append({'vod_id': self._id({'id': str(ident), 'type': mode, 'ext': x.get('container_extension') or ('m3u8' if mode == 'live' else 'mp4')}),
                              'vod_name': x.get('name', str(ident)), 'vod_pic': x.get('cover') or x.get('stream_icon') or ''})
        else:
            path = '' if tid == WEBDAV_ROOT_ID else tid
            rows = self._dav(path);total = len(rows);items = []
            for row in rows[offset:offset + self.PAGE_SIZE]:
                if row['directory']:
                    items.append({'id': row['url'], 'name': row['name'], 'directory': True,
                                  'remarks': '文件夹'})
                else:
                    items.append({'vod_id': self._id(row), 'vod_name': row['name'],
                                  'directory': False})
            current = urllib.parse.urlsplit(self._url(path)).path
            base_path = urllib.parse.urlsplit(self.base).path.rstrip('/') or '/'
            parent_path = posixpath.dirname(current.rstrip('/')) or '/'
            if tid == WEBDAV_ROOT_ID:
                parent_id = '';parent_name = ''
            elif parent_path == base_path or parent_path.rstrip('/') == base_path.rstrip('/'):
                parent_id = WEBDAV_ROOT_ID;parent_name = '根目录'
            else:
                parent_id = urllib.parse.urlunsplit((self.origin[0], self.origin[1], parent_path.rstrip('/') + '/', '', ''))
                parent_name = urllib.parse.unquote(parent_path.rstrip('/').rsplit('/', 1)[-1])
            folder_name = '根目录' if tid == WEBDAV_ROOT_ID else urllib.parse.unquote(current.rstrip('/').rsplit('/', 1)[-1])
            return {'list': items, 'page': page, 'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE),
                    'total': total, 'limit': self.PAGE_SIZE, 'categoryName': folder_name,
                    'parentID': parent_id, 'parentName': parent_name}
        return {'list': items, 'page': page, 'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE), 'total': total, 'limit': self.PAGE_SIZE}

    def searchContent(self, key, quick=False, pg='1'):
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate();page=max(1,int(pg))
            data=self._request('Users/%s/Items' % urllib.parse.quote(self.user_id,safe=''),{
                'SearchTerm':key,'Recursive':'true','IncludeItemTypes':'Movie,Series,Video','StartIndex':(page-1)*self.PAGE_SIZE,'Limit':self.PAGE_SIZE})
            total=int(data.get('TotalRecordCount',0))
            return {'list':[self._emby_item(x) for x in data.get('Items',[])], 'page':page,'pagecount':max(1,(total+self.PAGE_SIZE-1)//self.PAGE_SIZE)}
        # These protocols have no standard paginated server-side search API.
        return {'list': [], 'page': 1, 'pagecount': 1, 'message': '此协议暂不提供全库搜索，请按分类浏览'}

    def detailContent(self, ids):
        item = self._decode(str(ids[0]));episodes=[];title=str(item.get('name') or item.get('id') or '媒体')
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate();identifier=urllib.parse.quote(str(item['id']),safe='')
            data=self._request('Users/%s/Items/%s' % (urllib.parse.quote(self.user_id,safe=''),identifier));title=data.get('Name',title)
            rows=self._request('Shows/%s/Episodes' % identifier,{'UserId':self.user_id}).get('Items',[]) if item.get('type')=='Series' else [data]
            for row in rows:episodes.append((row.get('Name','播放'),self._id({'id':str(row['Id']),'type':'play'})))
        elif self.kind=='xtream' and item['type']=='series':
            data=self._xtream('get_series_info',series_id=item['id']);title=(data.get('info') or {}).get('name',title)
            for season in (data.get('episodes') or {}).values():
                for episode in season:episodes.append((episode.get('title','播放'),self._id({'id':str(episode['id']),'type':'seriesplay','ext':episode.get('container_extension','mp4')})))
        else:episodes=[('播放',str(ids[0]))]
        safe=lambda value:str(value).replace('$',' ').replace('#',' ').replace('$$$',' ')
        return {'list':[{'vod_id':str(ids[0]),'vod_name':title,'vod_play_from':self.getName(),
                         'vod_play_url':'#'.join(safe(name)+'$'+identifier for name,identifier in episodes)}]}

    def playerContent(self, flag, identifier, vipFlags=None):
        item=self._decode(identifier)
        if self.kind in ('emby','jellyfin'):
            self._authenticate();url=self._url('Videos/%s/stream' % urllib.parse.quote(str(item['id']),safe=''),{'static':'true','UserId':self.user_id})
        elif self.kind=='xtream':
            mode={'live':'live','vod':'movie','seriesplay':'series'}.get(item.get('type'))
            if not mode:raise ValueError('Select a playable Xtream episode')
            quote=lambda x:urllib.parse.quote(str(x),safe='')
            url=self._url('/'.join((mode,quote(self.config.get('username','')),quote(self.config.get('password','')),quote(item['id'])+'.'+quote(item.get('ext','mp4')))))
        else:url=self._url(item['url'])
        return {'url':url,'header':self._headers(),'parse':0,'jx':0}

    def destroy(self):
        self.closed=True;self.token=''
