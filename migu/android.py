"""Android-client playurl adapter, mirroring akiralereal/iptv extractors/migu.

The remote project is a client-compatibility layer: it asks Migu's playurl API for a
channel, then adds the client-side playback parameters the player expects.  This
module reproduces that behaviour in the standard library.  The upstream server still
decides region, account and membership rights; refusals are surfaced as-is and never
retried with changed region, account or entitlement fields.
"""
from __future__ import annotations

from collections import OrderedDict, deque
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError
from dataclasses import dataclass
import hashlib
import json
import math
import os
import random
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit

from migu import core as m
from migu.native import BUILTIN_CHANNELS, MiguApiError, api_status
from migu.workers import BoundedExecutor

ANDROID_KEYS = "cdabyzwxkl"
ANDROID_SUFFIX = "&sv=10004&ct=android"
LEGACY_APP_VERSION = "2600034600"
LEGACY_SUFFIX = "2cac4f2c6c3346a5b34e085725ef7e33migu"
MODERN_APP_VERSION = "2600037000"
MODERN_SUFFIX = "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123"
MODERN_SALT = "1230024"
FLV_DISABLED_PIDS = ("641886683", "641886773")
PLAYURL = "https://play.miguvideo.com/playurl/v1/play/playurl"
CACHE_SUCCESS = 5 * 60
CACHE_FAILURE = 60
CACHE_TRANSIENT = 3
TRANSIENT_FAILURES = {"NETWORK_ERROR", "FETCH_BUDGET_EXCEEDED", "MIGU_API_ERROR", "HTTP_408", "HTTP_429", "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504"}
BURST_WINDOW = 60.0
BURST_LIMIT = 30

RID_MESSAGES = {
    "COPYRIGHT_AREA_INVALID": "MIGU_REGION_RESTRICTED",
    "COPYRIGHT_SHIELD_INVALID": "MIGU_COPYRIGHT_SHIELD",
    "TIPS_NEED_MEMBER": "MIGU_MEMBERSHIP_REQUIRED",
    "TIPS_NEED_LOGIN": "MIGU_LOGIN_REQUIRED",
    "BLACK_APP_OR_TERMINAL": "MIGU_TERMINAL_BLOCKED",
    "WUDALIANSAI_FUFEI_VERSION_UPGRADE": "MIGU_CLIENT_VERSION_UPGRADE_REQUIRED",
}


class MiguRateLimitError(m.FetchError):
    def __init__(self, retry_after):
        super().__init__("MIGU_RESOLVE_BURST_LIMIT")
        self.retry_after = max(1, min(60, int(retry_after)))


def _md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def _date_string():
    return m.utcnow().astimezone(m.CHINA).strftime("%Y%m%d")


def _at(text, index):
    return text[index] if 0 <= index < len(text) else ""


def dd_calcu(pu_data, program_id, rate_type, user_id="", *, legacy=False, timestamp=None):
    """Build ddCalcu exactly as the reference implementation does.

    ``legacy`` selects the older 720p variant (fixed words, date digit 3).
    """
    if not pu_data or not program_id:
        return ""
    words = ["v", "a", "0", "a"]
    date = timestamp[:8] if timestamp and re.fullmatch(r"[0-9]{14}", timestamp) else _date_string()
    if legacy:
        words[0] = "v"
        date_index = 2
        program_index = 6
    else:
        if user_id:
            words[0] = _at(ANDROID_KEYS, int(user_id[7]) if len(user_id) > 7 and user_id[7].isdigit() else -1) or words[0]
        if str(rate_type) == "2":
            words[0] = "v"
        if 3 < len(user_id) <= 8:
            words[0] = "e"
        date_index = 0
        program_index = 6
    out = []
    i = 0
    while i < len(pu_data) // 2:
        out.append(pu_data[len(pu_data) - i - 1])
        out.append(pu_data[i])
        if i == 1:
            out.append(words[0])
        elif i == 2:
            out.append(_at(ANDROID_KEYS, int(date[date_index]) if date[date_index].isdigit() else -1))
        elif i == 3:
            program_char = _at(program_id, program_index)
            out.append(_at(ANDROID_KEYS, int(program_char)) if program_char.isdigit() else "")
        elif i == 4:
            out.append(words[3])
        i += 1
    if len(pu_data) % 2:
        out.append(pu_data[len(pu_data)//2])
    return "".join(out)


def _headers(pid, *, legacy, user_id, token, rate_type, settings=None):
    app_version = LEGACY_APP_VERSION if legacy else (settings.app_version if settings else MODERN_APP_VERSION)
    channel = (f"{app_version}-99000-201600010010028" if legacy
               else (settings.client_channel_id if settings else "2600037000-99000-200300220100002"))
    headers = {"AppVersion": app_version, "TerminalId": "android", "X-UP-CLIENT-CHANNEL-ID": channel,
               "User-Agent": "node-fetch", "Accept": "*/*"}
    if pid not in FLV_DISABLED_PIDS:
        headers["appCode"] = settings.app_code if settings else "miguvideo_default_android"
    # Reference: 标清 (rateType 2) always asks as a guest.
    if not legacy and str(rate_type) != "2" and token and user_id:
        headers["UserId"], headers["UserToken"] = user_id, token
    return headers


def playurl_request(pid, rate_type, user_id="", token="", *, legacy=False, hdr=True, h265=True, settings=None):
    """Return (url, headers) for one playurl call, preserving the reference query order."""
    timestamp = str(int(time.time() * 1000))
    if legacy:
        digest = _md5(timestamp + pid + LEGACY_APP_VERSION[:8])
        salt = str(random.randint(0, 999999)).zfill(6) + "25"
        sign = _md5(digest + LEGACY_SUFFIX + salt[:4])
        rate_type = 3
    else:
        digest = _md5(timestamp + pid + (settings.app_version if settings else MODERN_APP_VERSION)[:8])
        salt = MODERN_SALT
        sign = _md5(digest + MODERN_SUFFIX)
    query = (f"?sign={sign}&rateType={rate_type}&contId={pid}&timestamp={timestamp}"
             f"&salt={salt}&flvEnable=true&super4k=true")
    if h265:
        query += "&h265N=true"
    if hdr:
        query += "&4kvivid=true&2Kvivid=true&vivid=2"
    return PLAYURL + query, _headers(pid, legacy=legacy, user_id=user_id, token=token,
                                      rate_type=rate_type, settings=settings)


ANDROID_OPTIONS = {
    "user_id": "", "token": "", "rate_type": 3,
    "hdr": True, "h265": True, "client_dispatch": True,
    "app_version": "2600037000", "app_code": "miguvideo_default_android",
    "client_channel_id": "2600037000-99000-200300220100002",
}


@dataclass(frozen=True, repr=False)
class AndroidSettings:
    user_id: str = ANDROID_OPTIONS["user_id"]
    token: str = ANDROID_OPTIONS["token"]
    rate_type: int = ANDROID_OPTIONS["rate_type"]
    hdr: bool = ANDROID_OPTIONS["hdr"]
    h265: bool = ANDROID_OPTIONS["h265"]
    client_dispatch: bool = ANDROID_OPTIONS["client_dispatch"]
    # Compatibility knobs.  Set these to the values of your own installed,
    # officially released client.  They are not a licence to impersonate another
    # terminal: the upstream server still decides whether that client is allowed.
    app_version: str = ANDROID_OPTIONS["app_version"]
    app_code: str = ANDROID_OPTIONS["app_code"]
    client_channel_id: str = ANDROID_OPTIONS["client_channel_id"]

    @classmethod
    def load(cls, environ=None):
        environ = os.environ if environ is None else environ
        user_id = environ.get("MIGU_USER_ID", ANDROID_OPTIONS["user_id"]).strip()
        token = environ.get("MIGU_USER_TOKEN", ANDROID_OPTIONS["token"]).strip()
        if bool(user_id) != bool(token):
            raise m.UpdateError("MIGU_CREDENTIALS_INCOMPLETE")
        for value in (user_id, token):
            if len(value) > 4096 or any(not 33 <= ord(ch) <= 126 for ch in value):
                raise m.UpdateError("MIGU_CREDENTIALS_INVALID")
        try:
            rate_type = int(environ.get("MIGU_RATE_TYPE", str(ANDROID_OPTIONS["rate_type"])))
        except ValueError:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID") from None
        if rate_type not in {2, 3, 4, 7, 8, 9}:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID")
        app_version = environ.get("MIGU_APP_VERSION", ANDROID_OPTIONS["app_version"]).strip()
        if re.fullmatch(r"[0-9]{6,12}", app_version) is None:
            raise m.UpdateError("MIGU_APP_VERSION_INVALID")
        if app_version == "26000370":
            app_version = "2600037000"
        if app_version[:8] in {"26000009", "26000346"}:
            raise m.UpdateError("MIGU_PROTOCOL_PROFILE_MISMATCH")
        app_code = environ.get("MIGU_APP_CODE", ANDROID_OPTIONS["app_code"]).strip()
        if re.fullmatch(r"[A-Za-z0-9_]{1,64}", app_code) is None:
            raise m.UpdateError("MIGU_APP_CODE_INVALID")
        channel_id = environ.get("MIGU_CLIENT_CHANNEL_ID", ANDROID_OPTIONS["client_channel_id"]).strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{8,64}", channel_id) is None:
            raise m.UpdateError("MIGU_CLIENT_CHANNEL_ID_INVALID")
        if environ.get("MIGU_CLIENT_DISPATCH", "1" if ANDROID_OPTIONS["client_dispatch"] else "0") == "0":
            raise m.UpdateError("MIGU_SERVER_DISPATCH_UNSUPPORTED")
        return cls(user_id=user_id, token=token, rate_type=rate_type,
                   hdr=environ.get("MIGU_HDR", "1" if ANDROID_OPTIONS["hdr"] else "0") != "0",
                   h265=environ.get("MIGU_H265", "1" if ANDROID_OPTIONS["h265"] else "0") != "0",
                   client_dispatch=environ.get("MIGU_CLIENT_DISPATCH", "1" if ANDROID_OPTIONS["client_dispatch"] else "0") != "0",
                   app_version=app_version, app_code=app_code, client_channel_id=channel_id)


def _fetch_json(client, url, headers):
    raw, _ = client.get(url, headers=headers, limit=256 * 1024)
    if raw is None:
        raise MiguApiError("MIGU_UNEXPECTED_304")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED") from None
    if not isinstance(payload, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    if payload.get("rid") is not None and not isinstance(payload["rid"], str):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    body = payload.get("body")
    if body is not None:
        if not isinstance(body, dict) or any(body.get(key) is not None and not isinstance(body[key], dict) for key in ("urlInfo", "content", "auth")):
            raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    return payload


def android_play_url(pid, settings, client_factory=m.HttpClient, observer=None):
    """Resolve one channel, mirroring the reference flow including tier fallback."""
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise MiguApiError("MIGU_UNKNOWN_CHANNEL")
    client = client_factory("api", attempts=1, timeout=8, budget=12)
    legacy = settings.rate_type >= 3 and not (settings.user_id and settings.token)
    sends_account = bool(not legacy and settings.rate_type != 2 and settings.user_id and settings.token)
    deadline = time.monotonic() + 12
    attempted = set()

    def call(rate):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise m.FetchError("FETCH_BUDGET_EXCEEDED")
        client.budget = remaining
        attempted.add(rate)
        url, headers = playurl_request(pid, rate, settings.user_id if sends_account else "",
                                       settings.token if sends_account else "",
                                       legacy=legacy, hdr=settings.hdr, h265=settings.h265,
                                       settings=settings)
        m.validate_url(url, "api")
        return _fetch_json(client, url, headers)

    payload = call(3 if legacy else settings.rate_type)
    # Only request a genuinely lower supported tier. Never repeat or upgrade on denial.
    for _ in range(2):
        if payload.get("rid") != "TIPS_NEED_MEMBER":
            break
        info = (payload.get("body") or {}).get("urlInfo") or {}
        try:
            offered = int(info.get("rateType", 0))
        except (TypeError, ValueError):
            offered = 0
        current = min(attempted)
        fallback = 4 if offered >= 4 and current > 4 else 3
        if fallback >= current or fallback in attempted:
            break
        payload = call(fallback)

    details = api_status(payload, pid)
    if observer is not None:
        info = (payload.get("body") or {}).get("urlInfo") or {}
        def number(key, maximum):
            value = info.get(key)
            try:
                parsed = int(value) if type(value) is int or (isinstance(value, str) and value.isascii() and value.isdigit()) else -1
            except ValueError:
                return None
            return parsed if 0 <= parsed <= maximum else None
        observer({**details, "account_sent": sends_account,
                  "requested_quality": 3 if legacy else settings.rate_type,
                  "actual_quality": number("rateType", 9),
                  "trial_seconds": number("trySeeDuration", 86400)})
    rid = payload.get("rid")
    if rid != "SUCCESS":
        raise MiguApiError(RID_MESSAGES.get(rid, "MIGU_API_REJECTED"),
                           details)
    code = payload.get("code")
    if code is not None and str(code) != "200":
        raise MiguApiError("MIGU_API_REJECTED", details)
    body = payload.get("body") or {}
    info = body.get("urlInfo") or {}
    if not isinstance(body, dict) or not isinstance(info, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    url = info.get("url")
    if not isinstance(url, str) or not url:
        raise MiguApiError("MIGU_PLAY_URL_MISSING", details)
    m.validate_url(url, "stream")
    query = parse_qs(urlsplit(url).query, keep_blank_values=True)
    content = body.get("content") or {}
    if not isinstance(content, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    program_id = str(content.get("contId") or pid)
    if program_id != pid or ("ProgramID" in query and query["ProgramID"] != [pid]):
        raise MiguApiError("MIGU_CHANNEL_MISMATCH")
    if "ddCalcu" in query:
        if len(query["ddCalcu"]) != 1 or not query["ddCalcu"][0]:
            raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
        return url
    seeds = query.get("puData", [])
    stamps = query.get("timestamp", [])
    if len(seeds) != 1 or re.fullmatch(r"[0-9a-fA-F]{6,128}", seeds[0]) is None or len(stamps) != 1 or re.fullmatch(r"[0-9]{14}", stamps[0]) is None:
        raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
    try:
        returned_rate = int(info.get("rateType", 3 if legacy else settings.rate_type))
    except (TypeError, ValueError):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED") from None
    if returned_rate not in {2,3,4,7,8,9}:
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    # The public client signs using its requested mode before replacing rateType
    # with the server's actual quality. Account -> guest downgrades depend on this.
    proof = dd_calcu(seeds[0], pid, 3 if legacy else settings.rate_type, settings.user_id if sends_account else "", legacy=legacy, timestamp=stamps[0])
    suffix = "&ddCalcu=" + proof
    for key, value in (("sv", "10004"), ("ct", "android")):
        if key in query and query[key] != [value]:
            raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
        if key not in query:
            suffix += "&" + key + "=" + value
    return url + suffix


@dataclass(frozen=True)
class AndroidSnapshot:
    playlist: object
    channels: object


class AndroidStore:
    """On-demand resolution with the reference cache windows and scan protection."""
    provider = "migu-android"

    def __init__(self, settings=None, resolver=android_play_url, clock=time.monotonic):
        self.settings = settings or AndroidSettings.load()
        self.resolver = (lambda pid: android_play_url(pid, self.settings, observer=self._observe)) if resolver is android_play_url else resolver
        self.clock = clock
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-android", max_pending=8, lifo=True)
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.waiters, self.active = {}, 0
        self.closed, self.last_error, self.fetches, self.cache_hits = False, None, 0, 0
        self.last_upstream, self.recent = None, deque()
        self.upstream_observation = None
        self.resolve_samples = deque(maxlen=32)
        self.credential_state = "unchecked" if self.settings.user_id else "unconfigured"
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = AndroidSnapshot(None, MappingProxyType(channels))

    def _observe(self, observation):
        # Only this store's configured account can change its account state.
        # No additional network request is made for diagnostics.
        with self.lock:
            if self.closed:
                return
            self.upstream_observation = dict(observation)
            if observation['account_sent']:
                logged_in = observation['logged_in']
                if logged_in is True:
                    self.credential_state = "accepted"
                elif logged_in is False:
                    self.credential_state = "not_recognized"
                elif self.credential_state in {"unchecked", "unknown"}:
                    self.credential_state = "unknown"
            elif self.settings.user_id:
                self.credential_state = "not_sent"

    def _retry_after(self):
        now = self.clock()
        while self.recent and now - self.recent[0] >= BURST_WINDOW:
            self.recent.popleft()
        if len(self.recent) < BURST_LIMIT:
            return 0
        return max(1, min(60, math.ceil(BURST_WINDOW - (now - self.recent[0]))))

    def _burst_ok(self):
        if self._retry_after():
            return False
        self.recent.append(self.clock())
        return True

    def _run_resolver(self, pid):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if not self._burst_ok():
                raise MiguRateLimitError(self._retry_after())
            self.fetches += 1
            self.active += 1
        try:
            return self.resolver(pid)
        finally:
            with self.lock:
                self.active -= 1

    def _finish(self, key, future):
        cancelled, local_limit = future.cancelled(), False
        try:
            url, error = future.result(), None
        except Exception as failure:
            local_limit = isinstance(failure, MiguRateLimitError)
            url = ""
            error = ((str(failure), dict(getattr(failure, "details", {})))
                     if isinstance(failure, m.UpdateError) else ("MIGU_API_ERROR", {}))
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            if cancelled:
                return
            self.last_error = error[0] if error else None
            self.last_upstream = error[1] if error else None
            if local_limit:
                return  # Local queue/rate rejection must never poison a channel cache.
            ttl = CACHE_TRANSIENT if error and error[0] in TRANSIENT_FAILURES else CACHE_FAILURE if error else CACHE_SUCCESS
            self.entries[key] = (self.clock() + ttl, url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def resolve(self, key, wait=9):
        started, result = time.perf_counter(), "OK"
        try:
            return self._resolve(key, wait)
        except Exception as error:
            text = str(error)
            result = text if isinstance(error, m.UpdateError) and re.fullmatch(r"[A-Z0-9_]{1,80}", text) else "MIGU_API_ERROR"
            raise
        finally:
            elapsed = min(120000, max(0, round((time.perf_counter()-started)*1000)))
            sample = None
            with self.lock:
                if not self.closed and key in self.snapshot.channels:
                    sample = {"channel_id": key[1:], "elapsed_ms": elapsed, "result": result}
                    self.resolve_samples.append(sample)
            if sample and elapsed >= 1000:
                try:
                    print(f"[{m.iso(m.utcnow())}] MIGU_SLOW_RESOLVE 本地取源等待（不含播放器缓冲） " + json.dumps(sample, sort_keys=True), flush=True)
                except (OSError, ValueError):
                    pass

    def _resolve(self, key, wait=9):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if key not in self.snapshot.channels:
                raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
            cached = self.entries.get(key)
            if cached and cached[0] > self.clock():
                self.entries.move_to_end(key)
                self.cache_hits += 1
                if cached[2]:
                    raise MiguApiError(cached[2][0], cached[2][1])
                return cached[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 16:
                    raise m.FetchError("MIGU_API_CAPACITY")
                if self._retry_after():
                    raise MiguRateLimitError(self._retry_after())
                try:
                    future = self.pool.submit(self._run_resolver, key[1:])
                except RuntimeError:
                    raise m.FetchError("MIGU_API_CAPACITY") from None
                self.flights[key] = future
                future.add_done_callback(lambda done: self._finish(key, done))
            self.waiters[future] = self.waiters.get(future, 0) + 1
        try:
            return future.result(timeout=wait)
        except FutureTimeout:
            raise m.FetchError("MIGU_API_LOADING") from None
        except CancelledError:
            raise m.FetchError("MIGU_API_LOADING") from None
        except m.UpdateError:
            raise
        except Exception:
            raise m.FetchError("MIGU_API_ERROR") from None
        finally:
            with self.lock:
                remaining = self.waiters.get(future, 1) - 1
                if remaining:
                    self.waiters[future] = remaining
                else:
                    self.waiters.pop(future, None)
                    self.pool.cancel(future)  # Also release the cancelled queue slot immediately.

    def status(self):
        with self.lock:
            return {"provider": self.provider, "catalogue_ready": True, "channels": len(self.snapshot.channels),
                    "source_transport": "https", "last_error": self.last_error, "last_upstream": self.last_upstream,
                    "api_requests": self.fetches, "cache_hits": self.cache_hits,
                    "playback_verified": False, "quality": self.settings.rate_type, "storage": "memory",
                    "authorization": "configured-account" if self.settings.user_id else "anonymous",
                    "external_playlist": False, "client": "android",
                    "hdr": self.settings.hdr, "h265": self.settings.h265,
                    "client_dispatch": self.settings.client_dispatch,
                    "request_profile": "legacy720p" if self.settings.rate_type >= 3 and not self.settings.user_id else "modern",
                    "cache_success_seconds": CACHE_SUCCESS,
                    "transient_failure_seconds": CACHE_TRANSIENT,
                    "active_resolves": self.active,
                    "pending_resolves": max(0, len(self.flights)-self.active),
                    "credential_state": self.credential_state,
                    "rate_limit_retry_after_seconds": self._retry_after(),
                    "recent_resolves": list(self.resolve_samples),
                    "upstream_observation": dict(self.upstream_observation) if self.upstream_observation else None}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)
