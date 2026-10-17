"""Shared DNS lookups with bounded daemon workers and monotonic TTLs.

System getaddrinfo cannot be cancelled safely. A caller deadline therefore ends
only that caller's wait; the existing lookup remains shared until it finishes.
"""
from collections import OrderedDict
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
import ipaddress
import math
import queue
import socket
import threading
import time


class DNSLookupError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status =status


class DNSResolver:
    def __init__(self, max_workers=4, max_queue=16, max_records=512,
                 success_ttl=60.0, failure_ttl=2.0, lookup=None, clock=None):
        self.max_workers =max(1, min(4, int(max_workers)))
        self.max_queue =max(1, min(16, int(max_queue)))
        self.max_records =max(1, min(512, int(max_records)))
        self.success_ttl =max(0.0, min(60.0, float(success_ttl)))
        self.failure_ttl =max(0.0, min(2.0, float(failure_ttl)))
        self._lookup =lookup or socket.getaddrinfo
        self._clock =clock or time.monotonic
        self._lock =threading.Lock()
        self._queue =queue.Queue(maxsize=self.max_queue)
        self._stop =threading.Event()
        self._workers =[]
        self._inflight ={}
        self._cache =OrderedDict()
        self._active =0
        self._counts ={
            'submitted': 0, 'shared': 0, 'cache_hits': 0, 'timeouts': 0,
            'rejected': 0, 'completed': 0, 'failed': 0,
        }

    def resolve(self, host, port, timeout=3.0):
        timeout =float(timeout)
        if not math.isfinite(timeout) or timeout <0:
            raise ValueError('DNS timeout must be finite and nonnegative')
        deadline =self._clock() +timeout
        if not isinstance(host, str) or not host or '\x00' in host:
            raise DNSLookupError('invalid DNS hostname')
        # URL parsers normally remove IPv6 brackets. Accept them here as well.
        literal =host[1:-1] if host.startswith('[') and host.endswith(']') else host
        try:
            return [str(ipaddress.ip_address(literal))]
        except ValueError:
            pass
        try:
            normalized =host.rstrip('.').encode('idna').decode('ascii').lower()
            port =int(port)
            if not normalized or len(normalized) >253 or not 1 <=port <=65535:
                raise ValueError('invalid DNS query')
        except (UnicodeError, TypeError, ValueError) as error:
            raise DNSLookupError('invalid DNS query') from error
        key =(normalized, port)
        with self._lock:
            if self._stop.is_set():
                raise DNSLookupError('DNS resolver is closed', status=503)
            now =self._clock()
            cached =self._cache.get(key)
            if cached is not None:
                expires, addresses, error =cached
                if now <expires:
                    self._cache.move_to_end(key)
                    self._counts['cache_hits'] +=1
                    if error is not None:
                        raise DNSLookupError(str(error), status=error.status)
                    return list(addresses)
                self._cache.pop(key, None)
            future =self._inflight.get(key)
            if future is not None:
                self._counts['shared'] +=1
            else:
                future =Future()
                self._inflight[key] =future
                # Workers are daemon threads and created only for outstanding
                # demand. They may remain stuck in libc without blocking exit.
                try:
                    self._start_workers_locked()
                    self._queue.put_nowait((key, future))
                except queue.Full:
                    self._inflight.pop(key, None)
                    future.cancel()
                    self._counts['rejected'] +=1
                    raise DNSLookupError('DNS lookup capacity exhausted', status=503)
                except Exception as error:
                    self._inflight.pop(key, None)
                    future.cancel()
                    self._counts['rejected'] +=1
                    raise DNSLookupError('cannot start DNS worker', status=503) from error
                self._counts['submitted'] +=1
        try:
            return list(future.result(timeout=max(0.0, deadline -self._clock())))
        except FutureTimeoutError as error:
            with self._lock:
                self._counts['timeouts'] +=1
            raise DNSLookupError('DNS lookup timed out', status=504) from error
        except DNSLookupError as error:
            # Do not reuse traceback-bearing exception instances between callers.
            raise DNSLookupError(str(error), status=error.status) from error

    def _start_workers_locked(self):
        desired =min(self.max_workers, len(self._inflight))
        while len(self._workers) <desired:
            worker =threading.Thread(target=self._worker, daemon=True,
                                    name=f'ysp-dns-{id(self):x}-{len(self._workers) +1}')
            worker.start()
            self._workers.append(worker)

    def _worker(self):
        while not self._stop.is_set():
            try:
                key, future =self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            with self._lock:
                skip =self._stop.is_set() or future.done()
                if not skip:
                    self._active +=1
            if skip:
                self._queue.task_done()
                continue
            addresses, failure =None, None
            try:
                records =self._lookup(key[0], key[1], type=socket.SOCK_STREAM)
                addresses =tuple(dict.fromkeys(str(ipaddress.ip_address(record[4][0])) for record in records))
                if not addresses:
                    raise DNSLookupError('DNS response contained no addresses')
            except Exception as error:
                failure =error if isinstance(error, DNSLookupError) else DNSLookupError('DNS lookup failed')
            finally:
                with self._lock:
                    self._active -=1
                    if self._inflight.get(key) is future:
                        self._inflight.pop(key, None)
                    if not self._stop.is_set():
                        ttl =self.failure_ttl if failure is not None else self.success_ttl
                        if ttl >0.0:
                            self._cache[key] =(self._clock() +ttl, addresses, failure)
                            self._cache.move_to_end(key)
                            self._trim_cache_locked()
                        self._counts['completed'] +=1
                        if failure is not None:
                            self._counts['failed'] +=1
                    if not future.done():
                        if failure is not None:
                            future.set_exception(failure)
                        else:
                            future.set_result(addresses)
                self._queue.task_done()

    def _trim_cache_locked(self):
        now =self._clock()
        for key, cached in list(self._cache.items()):
            if cached[0] <=now:
                self._cache.pop(key, None)
        while len(self._cache) >self.max_records:
            self._cache.popitem(last=False)

    def clear_cache(self):
        with self._lock:
            self._cache.clear()

    def stats(self):
        with self._lock:
            return dict(self._counts, active=self._active,
                        queued=self._queue.qsize(), inflight=len(self._inflight),
                        cached=len(self._cache), workers=len(self._workers),
                        closed=self._stop.is_set())

    def close(self):
        """Wake callers immediately; blocked libc calls stay on daemon threads."""
        with self._lock:
            self._stop.set()
            self._cache.clear()
            for future in self._inflight.values():
                if not future.done():
                    future.set_exception(DNSLookupError('DNS resolver is closed', status=503))
            self._inflight.clear()
            while True:
                try:
                    self._queue.get_nowait()
                    self._queue.task_done()
                except queue.Empty:
                    break


_default_resolver =None
_default_lock =threading.Lock()


def bounded_dns_addresses(host, port, timeout=3.0):
    global _default_resolver
    with _default_lock:
        if _default_resolver is None:
            _default_resolver =DNSResolver()
        resolver =_default_resolver
    return resolver.resolve(host, port, timeout=timeout)
