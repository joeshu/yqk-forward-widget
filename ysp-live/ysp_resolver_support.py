"""Small, standard-library-only concurrency and persistence helpers."""
from concurrent.futures import Future
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
import json
import os
import tempfile
import threading
import time


class ThreadPoolExecutor:
    """Bounded daemon pool implementing the service's Executor API.

    A system network call cannot be killed safely. Daemon workers deliberately
    avoid the standard thread pool's interpreter-exit join, while Future states
    and cancellation retain the usual running/pending distinction.
    """
    def __init__(self, max_workers=None, thread_name_prefix='', *, max_queue=128):
        if max_workers is None:
            max_workers =min(32, (os.cpu_count() or 1) +4)
        if not isinstance(max_workers, int) or max_workers <=0:
            raise ValueError('max_workers must be a positive integer')
        self._max_workers =max_workers
        self._max_queue =max(1, min(128, int(max_queue)))
        self._prefix =thread_name_prefix or 'ysp-worker'
        self._condition =threading.Condition()
        self._tasks =deque()
        self._threads =[]
        self._active =0
        self._shutdown =False

    def submit(self, fn, /, *args, **kwargs):
        with self._condition:
            if self._shutdown:
                raise RuntimeError('cannot schedule new futures after shutdown')
            if len(self._tasks) >=self._max_queue:
                raise RuntimeError('worker queue capacity exhausted')
            future =Future()
            task =(future, fn, args, kwargs)
            self._tasks.append(task)
            desired =min(self._max_workers, self._active +len(self._tasks))
            try:
                while len(self._threads) <desired:
                    worker =threading.Thread(target=self._worker, daemon=True,
                                            name=f'{self._prefix}_{len(self._threads)}')
                    worker.start()
                    self._threads.append(worker)
            except Exception as error:
                # Workers cannot take this task while we hold the condition.
                # Keep previously started workers and their accepted tasks.
                self._tasks.remove(task)
                future.cancel()
                self._condition.notify_all()
                raise RuntimeError('cannot start worker thread') from error
            self._condition.notify()
            return future

    def _worker(self):
        while True:
            with self._condition:
                while not self._tasks:
                    if self._shutdown:
                        return
                    self._condition.wait()
                future, fn, args, kwargs =self._tasks.popleft()
                self._active +=1
            try:
                if future.set_running_or_notify_cancel():
                    try:
                        result =fn(*args, **kwargs)
                    except BaseException as error:
                        future.set_exception(error)
                    else:
                        future.set_result(result)
            finally:
                with self._condition:
                    self._active -=1
                    self._condition.notify_all()

    def shutdown(self, wait=True, *, cancel_futures=False):
        cancelled =[]
        with self._condition:
            self._shutdown =True
            if cancel_futures:
                while self._tasks:
                    cancelled.append(self._tasks.popleft()[0])
            workers =list(self._threads)
            self._condition.notify_all()
        # Future callbacks may acquire application locks or call back into this
        # executor, so run them after releasing the queue condition.
        for future in cancelled:
            future.cancel()
        if wait:
            for worker in workers:
                if worker is not threading.current_thread():
                    worker.join()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.shutdown(wait=True)
        return False


@dataclass
class RawPlaylist:
    source_key: tuple
    body: str
    content_type: str
    cached_at: float
    expires_at: float
    stale_until: float


_path_locks = {}
_path_locks_lock = threading.Lock()
_persistence_errors = {}


@contextmanager
def persistence_lock(path):
    path = os.path.abspath(path)
    with _path_locks_lock:
        lock = _path_locks.setdefault(path, threading.RLock())
    with lock:
        yield


def persistence_error(path, error):
    with _path_locks_lock:
        _persistence_errors[os.path.abspath(path)] = {
            "error": str(error), "at": time.time()
        }


def persistence_status():
    with _path_locks_lock:
        return {path: dict(value) for path, value in _persistence_errors.items()}


def atomic_json_write(path, payload):
    """Serialize concurrent writers, use a unique inode, and atomically publish."""
    path = os.path.abspath(path)
    with persistence_lock(path):
        parent = os.path.dirname(path)
        os.makedirs(parent, exist_ok=True)
        temporary = None
        try:
            descriptor, temporary = tempfile.mkstemp(
                prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=parent
            )
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, indent=2, ensure_ascii=False, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            temporary = None
            # Directory fsync is supported on POSIX, but not all deployment OSes.
            if hasattr(os, "O_DIRECTORY"):
                directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        except Exception as error:
            persistence_error(path, error)
            raise
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
