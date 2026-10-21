"""Bounded, network-only preparation of previously watched CCTV channels."""

class PrefetchCancelled(Exception):
    pass


class RecentPrefetch:
    def __init__(self, manager, limit):
        self.manager, self.limit = manager, limit
        self.stop = threading.Event()
        self.thread = None
        self.attempts, self.sources = {}, {}
        self.download_bytes = self.reused_segments = self.completed = self.failures = 0
        self.active = None
        self.last_error = ''

    def start(self):
        if self.limit:
            self.thread = threading.Thread(target=self.run, name='cctv-recent-prefetch', daemon=True)
            self.thread.start()

    def close(self):
        self.stop.set()

    def snapshot(self):
        return {'limit':self.limit, 'active_channel':self.active, 'last_error':self.last_error,
                'completed':self.completed,'failures':self.failures,
                'download_bytes':self.download_bytes,'reused_segments':self.reused_segments}

    def run(self):
        while not self.stop.is_set():
            self.cycle()
            self.stop.wait(.5)

    def cycle(self):
        self.manager.enforce_budget()
        targets = self.manager.prefetch_targets()
        for channel in targets:
            cid = channel.channel_id
            with channel.condition:
                epoch = channel.prefetch_epoch
                previous = channel.recent_preparation
            attempt = self.attempts.get(cid)
            if attempt and attempt[:2] == (channel,epoch) and time.monotonic() < attempt[2]:
                continue
            delay = 4
            def eligible():
                if (self.stop.is_set() or channel.stop.is_set() or not channel.parked_at
                        or channel.prefetch_epoch != epoch or channel not in self.manager.prefetch_targets()):
                    raise PrefetchCancelled()
            self.active = cid
            try:
                eligible()
                source = self.sources.get(cid)
                if source is None or source[0] is not channel or time.monotonic()-source[2] >= 30:
                    url = source_url(cid, timeout=4)
                    source = (channel,url,time.monotonic())
                    self.sources[cid] = source
                eligible()
                entries, final = media_playlist(source[1], timeout=4)
                self.sources[cid] = (channel,final,source[2])
                prepared_at = time.monotonic()
                wanted = entries[:2]
                if len(wanted) < 2 or wanted[1]['seq'] != wanted[0]['seq']+1 or wanted[1]['discontinuity']:
                    raise NativeError('source-boundary-not-proven')
                old = {}
                if previous is not None:
                    for entry in previous[0]:
                        task = previous[2].get(entry['seq'])
                        if task is not None and task.done() and task.exception() is None:
                            old[(entry['seq'],entry['url'])] = task.result()
                downloads, size = {}, 0
                for entry in wanted:
                    eligible()
                    result = old.get((entry['seq'],entry['url']))
                    if result is None:
                        raw, target = get(entry['url'], limit=8*1024*1024, timeout=4)
                        self.download_bytes += len(raw)
                        if not raw or len(raw)%188 or raw[0] != 0x47:
                            raise NativeError('prefetch-invalid-media')
                        result = (raw,target,None)
                    else:
                        self.reused_segments += 1
                    size += len(result[0])
                    task = Future();task.set_result(result);downloads[entry['seq']] = task
                eligible()
                if time.monotonic()-prepared_at > 6 or size > self.manager.cache_bytes:
                    delay = 10
                    continue
                # No native VM calls, TS transforms or publish calls here.
                prepared = (wanted,final,downloads,source[2],prepared_at)
                with channel.condition:
                    if channel.prefetch_epoch != epoch or not channel.parked_at or channel.stop.is_set():
                        raise PrefetchCancelled()
                    channel.recent_preparation = prepared
                    channel.recent_preparation_bytes = size
                self.manager.enforce_budget()
                self.completed += 1
                self.last_error = ''
                if channel.recent_preparation is None:
                    delay = 10
            except PrefetchCancelled:
                pass
            except Exception as error:
                self.last_error = str(error) if isinstance(error, NativeError) else transport_error_code(error)
                self.failures += 1
                self.sources.pop(cid,None)
                delay = 30
                with channel.condition:
                    if channel.prefetch_epoch == epoch:
                        channel.recent_preparation = None;channel.recent_preparation_bytes = 0
            finally:
                self.active = None
                self.attempts[cid] = (channel,epoch,time.monotonic()+delay)
