"""Bounded, opt-in adapters for user-owned media servers. No import-time I/O."""
import base64
import json
import posixpath
import time
import urllib.parse
try:
    from defusedxml import ElementTree as ET
    _HAS_DEFUSEDXML = True
except ImportError:
    from xml.etree import ElementTree as ET
    _HAS_DEFUSEDXML = False

_MEDIA = ('.mp4', '.m4v', '.mov', '.mkv', '.webm', '.flv', '.m3u8', '.mp3', '.m4a', '.aac', '.ts', '.avi', '.wmv', '.rmvb')
_SUBTITLES = ('.srt', '.ass', '.ssa', '.vtt')
WEBDAV_ROOT_ID = '__webdav_root__'
ALIST_ROOT_ID = '/'


class ServerSpider:
    PAGE_SIZE = 60

    def init(self, extend=''):
        self.config = json.loads(extend) if isinstance(extend, str) and extend else dict(extend or {})
        self.kind = self.config.get('type')
        if self.kind not in ('emby', 'jellyfin', 'xtream', 'webdav', 'alist', 'plex', 'smb'):
            raise ValueError('Unsupported media server type')
        self.base = str(self.config.get('url', '')).rstrip('/') + '/'
        parts = urllib.parse.urlsplit(self.base)
        allowed_schemes = ('smb',) if self.kind == 'smb' else ('http', 'https')
        if parts.scheme not in allowed_schemes or not parts.hostname or parts.username or parts.password:
            raise ValueError('Media server requires a valid URL without embedded credentials')
        if parts.query or parts.fragment:
            raise ValueError('Configure the server base URL without query or fragment')
        self.origin = (parts.scheme.lower(), parts.netloc.lower())
        self.supported_operations = ('home', 'category', 'detail', 'play', 'search')
        self.user_id = str(self.config.get('userId', ''))
        self.token = str(self.config.get('apiKey', ''))
        self.smb_host = parts.hostname or ''
        self.smb_port = parts.port or 445
        path_parts = [p for p in urllib.parse.unquote(parts.path).split('/') if p]
        self.smb_share = path_parts[0] if path_parts else ''
        self.smb_root_subdir = '/'.join(path_parts[1:]) if len(path_parts) > 1 else ''
        self.closed = False

    def getName(self):
        return str(self.config.get('name') or self.kind)

    def _headers(self):
        headers = {'User-Agent': 'CCTVHost/1', 'Accept': 'application/json'}
        if self.kind in ('emby', 'jellyfin'):
            headers['X-Emby-Authorization'] = 'MediaBrowser Client="CCTVHost", Device="iPhone", DeviceId="cctvhost", Version="1"'
            if self.token:
                headers['X-Emby-Token'] = self.token
        elif self.kind == 'plex':
            if self.token:
                headers['X-Plex-Token'] = self.token
            headers['X-Plex-Client-Identifier'] = 'cctvhost-ios'
        elif self.kind == 'alist':
            if self.token:
                headers['Authorization'] = self.token
        elif self.kind == 'webdav' and self.config.get('username'):
            pair = '%s:%s' % (self.config['username'], self.config.get('password', ''))
            headers['Authorization'] = 'Basic ' + base64.b64encode(pair.encode()).decode()
        return headers

    def _url(self, path='', query=None):
        if self.kind == 'smb' and not str(path).startswith('smb://'):
            url = self.base + str(path).lstrip('/')
        else:
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
        if self.kind == 'alist' and not self.token and self.config.get('username'):
            res = self._request('api/auth/login', method='POST', body={
                'username': self.config.get('username', ''), 'password': self.config.get('password', '')})
            self.token = str(((res.get('data') or {}).get('token')) or '')

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

    def _plex_item(self, item):
        key = str(item.get('ratingKey') or '')
        thumb = str(item.get('thumb') or '').lstrip('/')
        return {'vod_id': self._id({'id': key, 'type': str(item.get('type') or 'movie')}),
                'vod_name': str(item.get('title') or key),
                'vod_remarks': str(item.get('year') or ''),
                'vod_pic': self._url(thumb) if thumb else '',
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
        try:
            if _HAS_DEFUSEDXML:
                xml_root = ET.fromstring(content, forbid_dtd=True, forbid_entities=True, forbid_external=True)
            else:
                # 无 defusedxml 时的兜底：先去掉 NUL 字节再查 DOCTYPE/ENTITY——
                # UTF-16 编码下 ASCII 字符之间夹着 \x00，直接按字节查不到。
                flat = content.upper().replace(b'\x00', b'')
                if b'<!DOCTYPE' in flat or b'<!ENTITY' in flat:
                    raise ValueError('Unsafe WebDAV XML response')
                xml_root = ET.fromstring(content)
        except Exception as error:
            raise ValueError('Invalid or unsafe WebDAV XML response') from error
        result = []
        current = urllib.parse.unquote(urllib.parse.urlsplit(self._url(path)).path).rstrip('/')
        root_path = urllib.parse.unquote(urllib.parse.urlsplit(self.base).path).rstrip('/') + '/'
        for response in xml_root.findall('{DAV:}response'):
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

    def _smb_list(self, rel_path=''):
        from host_smb2 import SMB2Client
        if not self.smb_share:
            raise ValueError('SMB URL must include share name (smb://host/share)')
        target = posixpath.normpath('/'.join(p for p in (self.smb_root_subdir, rel_path.strip('/')) if p)).lstrip('/')
        if target == '.':
            target = ''
        client = SMB2Client(self.smb_host, self.smb_port, timeout=6.0)
        try:
            client.connect()
            client.negotiate()
            client.session_setup(self.config.get('username', ''), self.config.get('password', ''))
            client.tree_connect(self.smb_share)
            return client.list_directory(target)
        finally:
            client.close()

    def homeContent(self, filter=True):
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate()
            views = self._request('Users/%s/Views' % urllib.parse.quote(self.user_id, safe=''))
            classes = [{'type_id': str(x['Id']), 'type_name': x.get('Name', 'Library')} for x in views.get('Items', [])]
        elif self.kind == 'plex':
            data = self._request('library/sections')
            dirs = (data.get('MediaContainer') or {}).get('Directory') or []
            classes = [{'type_id': str(d['key']), 'type_name': str(d.get('title') or d['key'])} for d in dirs]
        elif self.kind == 'alist':
            self._authenticate()
            classes = [{'type_id': ALIST_ROOT_ID, 'type_name': '网盘根目录'}]
        elif self.kind == 'smb':
            classes = [{'type_id': ALIST_ROOT_ID, 'type_name': self.smb_share or 'SMB 共享'}]
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
        elif self.kind == 'plex':
            data = self._request('library/sections/%s/all' % urllib.parse.quote(str(tid), safe=''), {
                'X-Plex-Container-Start': offset, 'X-Plex-Container-Size': self.PAGE_SIZE})
            mc = data.get('MediaContainer') or {}
            rows = mc.get('Metadata') or []
            items = [self._plex_item(x) for x in rows]
            total = int(mc.get('totalSize') or len(items))
        elif self.kind == 'smb':
            rel = '' if tid in (ALIST_ROOT_ID, '', None) else str(tid).strip('/')
            rows = self._smb_list(rel)
            sub_by_stem = {}
            for entry in rows:
                ename = str(entry.get('name') or '')
                if not entry.get('directory') and ename.lower().endswith(_SUBTITLES):
                    stem = ename.rsplit('.', 1)[0].lower()
                    sub_rel = posixpath.join(rel, ename) if rel else ename
                    sub_by_stem.setdefault(stem, []).append(self._url(urllib.parse.quote(sub_rel, safe='/')))
            items = []
            for entry in rows:
                ename = str(entry.get('name') or '')
                child_rel = posixpath.join(rel, ename) if rel else ename
                if entry.get('directory'):
                    items.append({'id': child_rel, 'name': ename, 'directory': True, 'remarks': '文件夹'})
                elif ename.lower().endswith(_MEDIA):
                    stem = ename.rsplit('.', 1)[0].lower()
                    smb_url = self._url(urllib.parse.quote(child_rel, safe='/'))
                    items.append({'vod_id': self._id({'url': smb_url, 'name': ename, 'subtitles': sub_by_stem.get(stem, [])}),
                                  'vod_name': ename, 'directory': False})
            total = len(items)
            parent_rel = posixpath.dirname(rel) if rel else ''
            return {'list': items[offset:offset + self.PAGE_SIZE], 'page': page,
                    'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE),
                    'total': total, 'limit': self.PAGE_SIZE,
                    'categoryName': posixpath.basename(rel) if rel else (self.smb_share or 'SMB 共享'),
                    'parentID': '' if not rel else (parent_rel or ALIST_ROOT_ID),
                    'parentName': '' if not rel else (posixpath.basename(parent_rel) if parent_rel else (self.smb_share or 'SMB 共享'))}
        elif self.kind == 'alist':
            self._authenticate()
            path = str(tid or ALIST_ROOT_ID)
            res = self._request('api/fs/list', method='POST', body={
                'path': path, 'password': self.config.get('password', ''), 'page': page, 'per_page': self.PAGE_SIZE, 'refresh': False})
            data = res.get('data') or {}
            content = data.get('content') or []
            total = int(data.get('total') or len(content))
            sub_by_stem = {}
            for entry in content:
                ename = str(entry.get('name') or '')
                if not entry.get('is_dir') and ename.lower().endswith(_SUBTITLES):
                    stem = ename.rsplit('.', 1)[0].lower()
                    sub_by_stem.setdefault(stem, []).append(posixpath.join(path, ename))
            items = []
            for entry in content:
                ename = str(entry.get('name') or '')
                full_path = posixpath.join(path, ename)
                if entry.get('is_dir'):
                    items.append({'id': full_path, 'name': ename, 'directory': True, 'remarks': '文件夹'})
                elif ename.lower().endswith(_MEDIA):
                    stem = ename.rsplit('.', 1)[0].lower()
                    items.append({'vod_id': self._id({'path': full_path, 'name': ename, 'subtitles': sub_by_stem.get(stem, [])}),
                                  'vod_name': ename, 'vod_pic': str(entry.get('thumb') or ''), 'directory': False})
            parent_path = posixpath.dirname(path.rstrip('/')) or ALIST_ROOT_ID
            return {'list': items, 'page': page, 'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE),
                    'total': total, 'limit': self.PAGE_SIZE,
                    'categoryName': '网盘根目录' if path == ALIST_ROOT_ID else posixpath.basename(path.rstrip('/')),
                    'parentID': '' if path == ALIST_ROOT_ID else parent_path,
                    'parentName': '' if path == ALIST_ROOT_ID else ('网盘根目录' if parent_path == ALIST_ROOT_ID else posixpath.basename(parent_path))}
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
        page = max(1, int(pg))
        needle = str(key or '').strip().lower()
        if not needle:
            return {'list': [], 'page': 1, 'pagecount': 1}
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate()
            data = self._request('Users/%s/Items' % urllib.parse.quote(self.user_id, safe=''), {
                'SearchTerm': key, 'Recursive': 'true', 'IncludeItemTypes': 'Movie,Series,Video',
                'StartIndex': (page - 1) * self.PAGE_SIZE, 'Limit': self.PAGE_SIZE})
            total = int(data.get('TotalRecordCount', 0))
            return {'list': [self._emby_item(x) for x in data.get('Items', [])], 'page': page,
                    'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE)}
        if self.kind == 'plex':
            data = self._request('search', {'query': key})
            rows = (data.get('MediaContainer') or {}).get('Metadata') or []
            return {'list': [self._plex_item(x) for x in rows if x.get('type') in ('movie', 'show', 'episode')][:self.PAGE_SIZE],
                    'page': 1, 'pagecount': 1}
        if self.kind == 'alist':
            self._authenticate()
            res = self._request('api/fs/search', method='POST', body={
                'parent': ALIST_ROOT_ID, 'keywords': key, 'scope': 0, 'page': page, 'per_page': self.PAGE_SIZE})
            data = res.get('data') or {}
            content = data.get('content') or []
            total = int(data.get('total') or len(content))
            items = []
            for entry in content:
                ename = str(entry.get('name') or '')
                if entry.get('is_dir') or not ename.lower().endswith(_MEDIA):
                    continue
                parent = str(entry.get('parent') or ALIST_ROOT_ID)
                items.append({'vod_id': self._id({'path': posixpath.join(parent, ename), 'name': ename}), 'vod_name': ename})
            return {'list': items, 'page': page, 'pagecount': max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE)}
        if self.kind == 'xtream':
            matched = []
            for mode, action in (('vod', 'get_vod_streams'), ('series', 'get_series')):
                rows = self._xtream(action)
                if not isinstance(rows, list):
                    continue
                for x in rows:
                    name = str(x.get('name') or '')
                    if needle in name.lower():
                        ident = x.get('series_id') if mode == 'series' else x.get('stream_id')
                        matched.append({'vod_id': self._id({'id': str(ident), 'type': mode, 'ext': x.get('container_extension') or 'mp4'}),
                                        'vod_name': name, 'vod_pic': x.get('cover') or x.get('stream_icon') or ''})
                        if len(matched) >= self.PAGE_SIZE:
                            break
            return {'list': matched[:self.PAGE_SIZE], 'page': 1, 'pagecount': 1}
        if self.kind == 'smb':
            matched = []
            for row in self._smb_list(''):
                ename = str(row.get('name') or '')
                if not row.get('directory') and ename.lower().endswith(_MEDIA) and needle in ename.lower():
                    matched.append({'vod_id': self._id({'url': self._url(urllib.parse.quote(ename, safe='/')), 'name': ename}), 'vod_name': ename})
            return {'list': matched[:self.PAGE_SIZE], 'page': 1, 'pagecount': 1}
        if self.kind == 'webdav':
            matched = []
            for row in self._dav(''):
                if not row['directory'] and needle in str(row.get('name') or '').lower():
                    matched.append({'vod_id': self._id(row), 'vod_name': row['name']})
            return {'list': matched[:self.PAGE_SIZE], 'page': 1, 'pagecount': 1}
        return {'list': [], 'page': 1, 'pagecount': 1}

    def detailContent(self, ids):
        item = self._decode(str(ids[0]));episodes=[];title=str(item.get('name') or item.get('id') or '媒体')
        if self.kind in ('emby', 'jellyfin'):
            self._authenticate();identifier=urllib.parse.quote(str(item['id']),safe='')
            data=self._request('Users/%s/Items/%s' % (urllib.parse.quote(self.user_id,safe=''),identifier));title=data.get('Name',title)
            rows=self._request('Shows/%s/Episodes' % identifier,{'UserId':self.user_id}).get('Items',[]) if item.get('type')=='Series' else [data]
            for row in rows:
                sources = row.get('MediaSources') or []
                if len(sources) > 1:
                    for src in sources:
                        label = '%s (%s)' % (row.get('Name', '播放'), src.get('Name') or src.get('Container') or '版本')
                        episodes.append((label, self._id({'id': str(row['Id']), 'mediaSourceId': str(src.get('Id') or ''), 'type': 'play'})))
                else:
                    src_id = str(sources[0].get('Id') or '') if sources else ''
                    episodes.append((row.get('Name','播放'),self._id({'id':str(row['Id']),'mediaSourceId':src_id,'type':'play'})))
        elif self.kind == 'plex':
            identifier = urllib.parse.quote(str(item['id']), safe='')
            if item.get('type') == 'show':
                data = self._request('library/metadata/%s/allLeaves' % identifier)
                rows = (data.get('MediaContainer') or {}).get('Metadata') or []
                for row in rows:
                    episodes.append((str(row.get('title') or '播放'), self._id({'id': str(row['ratingKey']), 'type': 'episode'})))
            else:
                data = self._request('library/metadata/%s' % identifier)
                rows = (data.get('MediaContainer') or {}).get('Metadata') or []
                if rows:
                    title = str(rows[0].get('title') or title)
                episodes.append(('播放', str(ids[0])))
        elif self.kind=='xtream' and item['type']=='series':
            data=self._xtream('get_series_info',series_id=item['id']);title=(data.get('info') or {}).get('name',title)
            for season in (data.get('episodes') or {}).values():
                for episode in season:episodes.append((episode.get('title','播放'),self._id({'id':str(episode['id']),'type':'seriesplay','ext':episode.get('container_extension','mp4')})))
        else:episodes=[('播放',str(ids[0]))]
        safe=lambda value:str(value).replace('$',' ').replace('#',' ').replace('$$$',' ')
        return {'list':[{'vod_id':str(ids[0]),'vod_name':title,'vod_play_from':self.getName(),
                         'vod_play_url':'#'.join(safe(name)+'$'+identifier for name,identifier in episodes)}]}

    def report_playback_progress(self, item_id, position_seconds, is_paused=False):
        """Report Emby/Jellyfin playback progress to /Sessions/Playing/Progress."""
        if self.kind not in ('emby', 'jellyfin') or not item_id:
            return False
        self._authenticate()
        ticks = max(0, int(float(position_seconds) * 10_000_000))
        self._request('Sessions/Playing/Progress', method='POST', body={
            'ItemId': str(item_id), 'PositionTicks': ticks, 'IsPaused': bool(is_paused)})
        return True

    def playerContent(self, flag, identifier, vipFlags=None):
        item=self._decode(identifier)
        subtitles = []
        if self.kind in ('emby','jellyfin'):
            self._authenticate()
            qid = urllib.parse.quote(str(item['id']), safe='')
            params = {'static': 'true', 'UserId': self.user_id}
            if item.get('mediaSourceId'):
                params['MediaSourceId'] = item['mediaSourceId']
            url = self._url('Videos/%s/stream' % qid, params)
            try:
                info = self._request('Items/%s/PlaybackInfo' % qid, {'UserId': self.user_id})
                for ms in (info.get('MediaSources') or [])[:1]:
                    for st in (ms.get('MediaStreams') or []):
                        if st.get('Type') == 'Subtitle' and st.get('DeliveryUrl'):
                            subtitles.append({'name': st.get('DisplayTitle') or st.get('Language') or '字幕',
                                              'url': self._url(str(st['DeliveryUrl']).lstrip('/'))})
            except Exception:
                pass
        elif self.kind == 'plex':
            data = self._request('library/metadata/%s' % urllib.parse.quote(str(item['id']), safe=''))
            rows = (data.get('MediaContainer') or {}).get('Metadata') or []
            part_key = ''
            if rows:
                medias = rows[0].get('Media') or []
                parts = (medias[0].get('Part') or []) if medias else []
                part_key = str(parts[0].get('key') or '').lstrip('/') if parts else ''
            if not part_key:
                raise ValueError('Plex item has no playable media part')
            url = self._url(part_key, {'X-Plex-Token': self.token} if self.token else None)
        elif self.kind == 'alist':
            self._authenticate()
            res = self._request('api/fs/get', method='POST', body={'path': item['path'], 'password': self.config.get('password', '')})
            raw_url = str(((res.get('data') or {}).get('raw_url')) or '')
            if not raw_url:
                raise ValueError('Alist item has no playable raw_url')
            url = raw_url
            for sub_path in (item.get('subtitles') or [])[:4]:
                try:
                    sub_res = self._request('api/fs/get', method='POST', body={'path': sub_path, 'password': self.config.get('password', '')})
                    sub_raw = str(((sub_res.get('data') or {}).get('raw_url')) or '')
                    if sub_raw:
                        subtitles.append({'name': posixpath.basename(sub_path), 'url': sub_raw})
                except Exception:
                    pass
            out = {'url': url, 'header': {'User-Agent': 'CCTVHost/1'}, 'parse': 0, 'jx': 0}
            if subtitles:
                out['subtitles'] = subtitles
            return out
        elif self.kind=='xtream':
            mode={'live':'live','vod':'movie','seriesplay':'series'}.get(item.get('type'))
            if not mode:raise ValueError('Select a playable Xtream episode')
            quote=lambda x:urllib.parse.quote(str(x),safe='')
            url=self._url('/'.join((mode,quote(self.config.get('username','')),quote(self.config.get('password','')),quote(item['id'])+'.'+quote(item.get('ext','mp4')))))
        elif self.kind == 'smb':
            url = self._url(item['url'])
            for sub_url in (item.get('subtitles') or [])[:4]:
                subtitles.append({'name': posixpath.basename(urllib.parse.unquote(sub_url)), 'url': sub_url})
        else:url=self._url(item['url'])
        out = {'url':url,'header':self._headers(),'parse':0,'jx':0}
        if subtitles:
            out['subtitles'] = subtitles
        return out

    def destroy(self):
        self.closed=True;self.token=''

