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
        self.slot_held = False
        self.parked_at = 0
        self.resume_pending = False
        self.resume_reset_sequence = False
        self.cache_hits = 0
        self.cache_buffer_hits = 0
        self.resumed_at = 0
        self.resume_ready_seconds = None
        self.cache_ttl = getattr(args, 'recent_channel_seconds', 15)

    def retire(self):
        with self.condition:
            self.stop.set()
            self.parked_at = 0
            self.condition.notify_all()

    def park(self):
        with self.condition:
            if (not self.cache_ttl or self.stop.is_set() or self.state != 'ready'
                    or not self.thread or not self.thread.is_alive()):
                self.retire()
                return
            # Keep only two latest validated outputs while the VM is parked.
            while len(self.ring) > 2:
                _, old = self.ring.popitem(last=False)
                self.size -= len(old[0])
                self.discarded_discontinuities += bool(old[2])
            self.parked_at = time.monotonic()
            self.condition.notify_all()

    def resume(self):
        with self.condition:
            now = time.monotonic()
            if (not self.parked_at or self.stop.is_set() or not self.thread or not self.thread.is_alive()
                    or now-self.parked_at >= self.cache_ttl or self.state != 'ready'):
                return False
            durations = sum(item[1] for item in self.ring.values())
            fresh = (len(self.ring) >= 2 and self.last_published_at > 0
                     and now-self.last_published_at <= min(8, durations))
            self.parked_at = 0
            self.resume_pending = True
            self.resume_reset_sequence = not fresh
            self.last_request = now
            self.resumed_at = now
            self.resume_ready_seconds = 0.0 if fresh else None
            self.cache_hits += 1
            self.cache_buffer_hits += bool(fresh)
            if not fresh:
                # Never expose a frozen live window as a fast cache hit.
                self.ring.clear()
                self.size = self.counter = self.discarded_discontinuities = 0
                self.generation = uuid.uuid4().hex
                self.state = 'source'
            print('[cctv-native] cache-resume channel='+self.channel_id+
                  ' fresh_buffer='+str(fresh).lower(), flush=True)
            self.condition.notify_all()
            return True

    def checkpoint(self):
        with self.condition:
            while self.parked_at and not self.stop.is_set():
                remaining = self.cache_ttl-(time.monotonic()-self.parked_at)
                if remaining <= 0:
                    self.stop.set()
                    self.parked_at = 0
                    break
                self.condition.wait(min(.25, remaining))
            if self.stop.is_set():
                return False
            if self.resume_pending:
                self.resume_pending = False
                raise ResumePreparation(self.resume_reset_sequence)
            return True

    def publish(self, body, entry, discontinuity):
        # Selection can change between the owner's pre-publish check and lock.
        # Make the final check atomic with exposing a new cached segment.
        with self.condition:
            if self.checkpoint():
                super().publish(body, entry, discontinuity)
                if self.resumed_at and self.resume_ready_seconds is None and self.state == 'ready':
                    self.resume_ready_seconds = round(time.monotonic()-self.resumed_at,3)
                    print('[cctv-native] cache-media-ready seconds='+str(self.resume_ready_seconds)+
                          ' channel='+self.channel_id, flush=True)

    def snapshot(self):
        result = super().snapshot()
        with self.condition:
            result.update(parked=bool(self.parked_at), cache_hits=self.cache_hits,
                          cache_buffer_hits=self.cache_buffer_hits,
                          resume_ready_seconds=self.resume_ready_seconds,
                          buffer_age_seconds=round(time.monotonic()-self.last_published_at,3)
                          if self.last_published_at else None)
        return result

    def native_context_closed(self):
        if self.slot_held:
            self.slot_held = False
            self.slots.release()

    def run(self):
        # Only the owner closes JSC. Release its slot before waiting on any
        # already-running HTTP reads; eviction cannot hold a new VM hostage.
        while not self.stop.is_set():
            if self.slots.acquire(timeout=.2):
                self.slot_held = True
                try:
                    if not self.stop.is_set():
                        super().run()
                finally:
                    self.native_context_closed()
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
            previous = self.channels.get(self.current)
            target = self.channels.get(cid)
            # At most current + one most recent parked channel. Retire the
            # older VM before creating a third candidate; semaphore stays 2.
            for other in self.channels.values():
                if other is not previous and other is not target:
                    other.retire()
            if previous:
                previous.park()
            if target is not None and target.resume():
                self.current = cid
                return target
            if target:
                target.retire()
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
                          native_context_limit=2, http_connections=_HTTP_POOL.snapshot(),
                          recent_channel_seconds=getattr(self.args,'recent_channel_seconds',15),
                          recent_channels=[c.channel_id for c in self.channels.values()
                                           if c.parked_at and not c.stop.is_set()],
                          source_api_tls=('TLSv1.2-legacy-server' if _API_LEGACY_ENABLED and _API_LEGACY_PREFERRED else
                                          'TLSv1.2' if _API_TLS12_PREFERRED else 'default'))
            return result

    def close(self):
        with self.lock:
            self.closed = True
            for channel in self.channels.values():
                channel.retire()
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
