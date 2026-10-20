"""Bounded daemon workers: cancelled queues never keep an embedded app alive."""
from concurrent.futures import Future
from queue import Queue, LifoQueue, Empty, Full
import threading


class BoundedExecutor:
    def __init__(self, max_workers, thread_name_prefix='migu', max_pending=8, lifo=False):
        self.max_workers, self.prefix = max_workers, thread_name_prefix
        self.queue, self.lock = (LifoQueue if lifo else Queue)(max(max_pending,max_workers)), threading.Lock()
        self.threads, self.closed = [], False

    def submit(self, function, *args, **kwargs):
        future = Future()
        with self.lock:
            if self.closed:
                raise RuntimeError('Executor already stopped')
            try:
                self.queue.put_nowait((future, function, args, kwargs))
            except Full:
                raise RuntimeError('Executor queue full') from None
            if len(self.threads) < self.max_workers:
                thread = threading.Thread(target=self._run, daemon=True, name=f'{self.prefix}-{len(self.threads)+1}')
                self.threads.append(thread)
                try:
                    thread.start()
                except BaseException:
                    self.threads.remove(thread)
                    self.closed = True
                    while True:
                        try:
                            queued = self.queue.get_nowait()
                            if queued is not None: queued[0].cancel()
                        except Empty: break
                    for _ in self.threads:
                        self.queue.put_nowait(None)
                    raise
        return future

    def _run(self):
        while True:
            item = self.queue.get()
            if item is None:
                return
            future, function, args, kwargs = item
            item = None
            if self.closed:
                future.cancel()
            elif future.set_running_or_notify_cancel():
                try:
                    result = function(*args, **kwargs)
                except BaseException as failure:
                    future.set_exception(failure)
                else:
                    future.set_result(result)
            # Release arguments/results before waiting for another task.
            future = function = args = kwargs = result = None
            if self.closed:
                return

    def shutdown(self, wait=False, cancel_futures=True):
        with self.lock:
            self.closed = True
            while True:
                try:
                    queued = self.queue.get_nowait()
                    if queued is not None: queued[0].cancel()
                except Empty:
                    break
            for _ in self.threads:
                self.queue.put_nowait(None)
        if wait:
            for thread in self.threads:
                if thread is not threading.current_thread():
                    thread.join()
