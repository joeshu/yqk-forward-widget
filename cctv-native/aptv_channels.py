"""On-demand website channels with bounded native VM concurrency on iPhone."""
from types import SimpleNamespace

# Selected only after official play permission, playlists and real media checks.
PUBLISHED_IDS = ('cctv1', 'cctv2', 'cctv4', 'cctv7', 'cctvjilu', 'cctv10',
                 'cctv11', 'cctv12', 'cctv13', 'cctvchild', 'cctv15', 'cctv17',
                 'cctveurope', 'cctvamerica')
PUBLISHED_CHANNELS = {cid: name for cid,name in WEBSITE_CHANNELS if cid in PUBLISHED_IDS}


class ManagedChannel(Channel):
    def __init__(self, args, slots):
        super().__init__(args)
        self.slots = slots

    def run(self):
        # SDKs are created/released only in their owner thread. Fast switching
        # cannot accumulate an unbounded number of native contexts.
        while not self.stop.is_set():
            if self.slots.acquire(timeout=.2):
                try:
                    if not self.stop.is_set():
                        super().run()
                finally:
                    self.slots.release()
                return


class ChannelManager:
    def __init__(self, args):
        self.args = args
        self.lock = threading.RLock()
        self.slots = threading.BoundedSemaphore(2)
        self.channels = {}
        self.current = None
        self.closed = False

    def activate(self, cid):
        if cid not in PUBLISHED_CHANNELS:
            raise NativeError('unknown-channel')
        with self.lock:
            if self.closed:
                raise NativeError('service-stopping')
            if self.current == cid:
                return self.channels[cid]
            if self.current:
                previous = self.channels[self.current]
                previous.stop.set()
                with previous.condition:
                    previous.condition.notify_all()
            args = SimpleNamespace(**vars(self.args))
            args.channel_id = cid
            channel = ManagedChannel(args, self.slots)
            self.channels[cid] = channel
            self.current = cid
            return channel

    def lookup(self, cid):
        with self.lock:
            return self.channels.get(cid)

    def snapshot(self):
        with self.lock:
            current = self.channels.get(self.current)
            result = current.snapshot() if current else {'state':'idle','media_ready':False}
            result.update(current_channel=self.current, channel_count=len(PUBLISHED_CHANNELS),
                          channels=[{'id':cid,'name':name} for cid,name in PUBLISHED_CHANNELS.items()],
                          native_context_limit=2,
                          source_api_tls=('TLSv1.2-legacy-server' if _API_LEGACY_ENABLED and _API_LEGACY_PREFERRED else
                                          'TLSv1.2' if _API_TLS12_PREFERRED else 'default'))
            return result

    def close(self):
        with self.lock:
            self.closed = True
            for channel in self.channels.values():
                channel.stop.set()
                with channel.condition:
                    channel.condition.notify_all()
        # No cross-thread JSC calls and no HTTP thread blocked on VM teardown.


class RequestServerView:
    def __init__(self, server, channel):
        self.original, self.channel = server, channel

    def __getattr__(self, name):
        return getattr(self.original, name)


class MultiChannelHandler(Handler):
    def send(self, status, body='', mime='text/plain; charset=utf-8'):
        cid = getattr(self, 'routed_channel', None)
        if cid and status == 200 and mime == 'application/vnd.apple.mpegurl' and isinstance(body,str):
            body = body.replace('\nmedia/', '\nmedia/'+cid+'/')
        return super().send(status, body, mime)

    def do_GET(self):
        server = self.server
        manager = server.manager
        path = urlsplit(self.path).path
        if path in ('/', '/all.m3u'):
            host = self.headers.get('Host','')
            if not re.fullmatch(r'(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::\d{1,5})?',host):
                return self.send(400,'invalid-host')
            try:
                port = urlsplit('//'+host).port
                if port is not None and not 1 <= port <= 65535:
                    return self.send(400,'invalid-host')
            except ValueError:
                return self.send(400,'invalid-host')
            lines = ['#EXTM3U']
            for cid,name in PUBLISHED_CHANNELS.items():
                lines.extend([f'#EXTINF:-1 tvg-id="{cid}" group-title="央视网页",{name}',
                              f'http://{host}/{cid}.m3u8'])
            if self.command == 'GET' and server.args.warmup:
                # Refreshing the list never interrupts a channel already playing.
                with manager.lock:
                    if manager.current is None:
                        manager.activate('cctv2').demand()
            return self.send(200,'\n'.join(lines)+'\n','audio/x-mpegurl; charset=utf-8')
        if path == '/status':
            return self.send(200,json.dumps(manager.snapshot(),ensure_ascii=False),'application/json; charset=utf-8')
        match = re.fullmatch(r'/([a-z0-9]+)\.m3u8',path)
        if match:
            cid = match[1]
            if cid not in PUBLISHED_CHANNELS:
                return self.send(404,'channel-not-in-validated-list')
            if self.command == 'HEAD':
                return self.send(200,mime='application/vnd.apple.mpegurl')
            try:
                channel = manager.activate(cid)
            except NativeError:
                return self.send(503,'service-stopping')
            mapped = '/cctv2.m3u8'
        else:
            match = re.fullmatch(r'/media/([a-z0-9]+)/([0-9a-f]{32})/(\d+)\.ts',path)
            if not match or match[1] not in PUBLISHED_CHANNELS:
                return self.send(404,'not-found')
            cid = match[1]
            channel = manager.lookup(cid)
            if channel is None:
                return self.send(410,'expired-media')
            mapped = '/media/'+match[2]+'/'+match[3]+'.ts'
        # A request-local view prevents concurrent clients from sharing or
        # overwriting a server.channel pointer during channel changes.
        self.server = RequestServerView(server, channel)
        old_path = self.path
        self.path, self.routed_channel = mapped,cid
        try:
            return super().do_GET()
        finally:
            self.path, self.server = old_path,server
