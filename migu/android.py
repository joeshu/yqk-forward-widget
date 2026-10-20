"""Android-client playurl adapter, mirroring akiralereal/iptv extractors/migu.

The remote project is a client-compatibility layer: it asks Migu's playurl API for a
channel, then adds the client-side playback parameters the player expects.  This
module reproduces that behaviour in the standard library.  The upstream server still
decides region, account and membership rights; refusals are surfaced as-is and never
retried with changed region, account or entitlement fields.
"""
from __future__ import annotations

from collections import OrderedDict, deque
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass
import hashlib
import json
import os
import random
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit

from migu import core as m
from migu.native import BUILTIN_CHANNELS, MiguApiError
from migu.workers import BoundedExecutor

ANDROID_KEYS = "cdabyzwxkl"
ANDROID_SUFFIX = "&sv=10004&ct=android"
LEGACY_APP_VERSION = "2600034600"
LEGACY_SUFFIX = "2cac4f2c6c3346a5b34e085725ef7e33migu"
MODERN_APP_VERSION = "26000370"
MODERN_SUFFIX = "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123"
MODERN_SALT = "1230024"
FLV_DISABLED_PIDS = ("641886683", "641886773")
PLAYURL = "https://play.miguvideo.com/playurl/v1/play/playurl"
CACHE_SUCCESS = 3 * 60 * 60
CACHE_FAILURE = 60
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


def _md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def _date_string():
    return m.utcnow().astimezone(m.CHINA).strftime("%Y%m%d")


def _at(text, index):
    return text[index] if 0 <= index < len(text) else ""


def dd_calcu(pu_data, program_id, rate_type, user_id="", *, legacy=False):
    """Build ddCalcu exactly as the reference implementation does.

    ``legacy`` selects the older 720p variant (fixed words, date digit 3).
    """
    if not pu_data or not program_id:
        return ""
    words = ["v", "a", "0", "a"]
    date = _date_string()
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
    while i * 2 < len(pu_data):
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
    return "".join(out)


def _headers(pid, *, legacy, user_id, token, rate_type, settings=None):
    app_version = LEGACY_APP_VERSION if legacy else (settings.app_version if settings else MODERN_APP_VERSION)
    channel = (f"{app_version}-99000-201600010010028" if legacy
               else (settings.client_channel_id if settings else "2600037000-99000-200300220100002"))
    headers = {"AppVersion": app_version, "TerminalId": "android", "X-UP-CLIENT-CHANNEL-ID": channel}
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
        digest = _md5(timestamp + pid + (settings.app_version if settings else MODERN_APP_VERSION))
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


@dataclass(frozen=True)
class AndroidSettings:
    user_id: str = ""
    token: str = ""
    rate_type: int = 3
    hdr: bool = True
    h265: bool = True
    client_dispatch: bool = True
    # Compatibility knobs.  Set these to the values of your own installed,
    # officially released client.  They are not a licence to impersonate another
    # terminal: the upstream server still decides whether that client is allowed.
    app_version: str = MODERN_APP_VERSION
    app_code: str = "miguvideo_default_android"
    client_channel_id: str = "2600037000-99000-200300220100002"

    @classmethod
    def load(cls, environ=None):
        environ = os.environ if environ is None else environ
        user_id = environ.get("MIGU_USER_ID", "").strip()
        token = environ.get("MIGU_USER_TOKEN", "").strip()
        if bool(user_id) != bool(token):
            raise m.UpdateError("MIGU_CREDENTIALS_INCOMPLETE")
        for value in (user_id, token):
            if any(ch in value for ch in "\r\n\t") or not m.clean_text(value):
                raise m.UpdateError("MIGU_CREDENTIALS_INVALID")
        try:
            rate_type = int(environ.get("MIGU_RATE_TYPE", "3"))
        except ValueError:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID") from None
        if rate_type not in {2, 3, 4, 7, 8, 9}:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID")
        app_version = environ.get("MIGU_APP_VERSION", MODERN_APP_VERSION).strip()
        if re.fullmatch(r"[0-9]{6,12}", app_version) is None:
            raise m.UpdateError("MIGU_APP_VERSION_INVALID")
        app_code = environ.get("MIGU_APP_CODE", "miguvideo_default_android").strip()
        if re.fullmatch(r"[A-Za-z0-9_]{1,64}", app_code) is None:
            raise m.UpdateError("MIGU_APP_CODE_INVALID")
        channel_id = environ.get("MIGU_CLIENT_CHANNEL_ID", "2600037000-99000-200300220100002").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{8,64}", channel_id) is None:
            raise m.UpdateError("MIGU_CLIENT_CHANNEL_ID_INVALID")
        return cls(user_id=user_id, token=token, rate_type=rate_type,
                   hdr=environ.get("MIGU_HDR", "1") != "0",
                   h265=environ.get("MIGU_H265", "1") != "0",
                   client_dispatch=environ.get("MIGU_CLIENT_DISPATCH", "1") != "0",
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
    return payload


def android_play_url(pid, settings, client_factory=m.HttpClient):
    """Resolve one channel, mirroring the reference flow including tier fallback."""
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise MiguApiError("MIGU_UNKNOWN_CHANNEL")
    client = client_factory("api", attempts=1, timeout=8, budget=12)
    legacy = settings.rate_type == 2
    sends_account = (not legacy and settings.user_id and settings.token)

    def call(rate):
        url, headers = playurl_request(pid, rate, settings.user_id if sends_account else "",
                                       settings.token if sends_account else "",
                                       legacy=legacy, hdr=settings.hdr, h265=settings.h265,
                                       settings=settings)
        m.validate_url(url, "api")
        return _fetch_json(client, url, headers)

    payload = call(settings.rate_type)
    if payload.get("rid") == "TIPS_NEED_MEMBER":
        info = (payload.get("body") or {}).get("urlInfo") or {}
        try:
            offered = int(info.get("rateType", 0))
        except (TypeError, ValueError):
            offered = 0
        fallback = 4 if offered >= 4 else 3
        payload = call(fallback)
        if payload.get("rid") == "TIPS_NEED_MEMBER" and fallback != 3:
            payload = call(3)

    rid = payload.get("rid")
    if rid != "SUCCESS":
        raise MiguApiError(RID_MESSAGES.get(rid, "MIGU_API_REJECTED"),
                           {"api_code": str(rid or "")[:80], "channel_id": pid})
    body = payload.get("body") or {}
    info = body.get("urlInfo") or {}
    url = info.get("url")
    if not url:
        raise MiguApiError("MIGU_PLAY_URL_MISSING", {"api_code": str(rid)[:80], "channel_id": pid})
    m.validate_url(url, "stream")
    query = parse_qs(urlsplit(url).query, keep_blank_values=True)
    pu_data = query.get("puData", [""])[0]
    program_id = ((body.get("content") or {}).get("contId")) or pid
    proof = dd_calcu(pu_data, program_id, info.get("rateType", settings.rate_type), settings.user_id, legacy=legacy)
    if not proof:
        raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
    return url + "&ddCalcu=" + proof + ANDROID_SUFFIX


@dataclass(frozen=True)
class AndroidSnapshot:
    playlist: object
    channels: object


class AndroidStore:
    """On-demand resolution with the reference cache windows and scan protection."""
    provider = "migu-android"

    def __init__(self, settings=None, resolver=android_play_url, clock=time.monotonic):
        self.settings = settings or AndroidSettings.load()
        self.resolver = (lambda pid: android_play_url(pid, self.settings)) if resolver is android_play_url else resolver
        self.clock = clock
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-android")
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.last_error, self.fetches, self.cache_hits = False, None, 0, 0
        self.last_upstream, self.recent = None, deque()
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = AndroidSnapshot(None, MappingProxyType(channels))

    def _burst_ok(self):
        now = self.clock()
        while self.recent and now - self.recent[0] > BURST_WINDOW:
            self.recent.popleft()
        if len(self.recent) >= BURST_LIMIT:
            return False
        self.recent.append(now)
        return True

    def _finish(self, key, future):
        try:
            url, error = future.result(), None
        except Exception as failure:
            url = ""
            error = ((str(failure), dict(getattr(failure, "details", {})))
                     if isinstance(failure, m.UpdateError) else ("MIGU_API_ERROR", {}))
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            self.last_error = error[0] if error else None
            self.last_upstream = error[1] if error else None
            self.entries[key] = (self.clock() + (CACHE_FAILURE if error else CACHE_SUCCESS), url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def resolve(self, key, wait=9):
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
                if len(self.flights) >= 8:
                    raise m.FetchError("MIGU_API_CAPACITY")
                if not self._burst_ok():
                    raise m.FetchError("MIGU_RESOLVE_BURST_LIMIT")
                future = self.pool.submit(self.resolver, key[1:])
                self.flights[key] = future
                self.fetches += 1
                future.add_done_callback(lambda done: self._finish(key, done))
        try:
            return future.result(timeout=wait)
        except FutureTimeout:
            raise m.FetchError("MIGU_API_LOADING") from None
        except m.UpdateError:
            raise
        except Exception:
            raise m.FetchError("MIGU_API_ERROR") from None

    def status(self):
        with self.lock:
            return {"provider": self.provider, "catalogue_ready": True, "channels": len(self.snapshot.channels),
                    "source_transport": "https", "last_error": self.last_error, "last_upstream": self.last_upstream,
                    "api_requests": self.fetches, "cache_hits": self.cache_hits,
                    "playback_verified": False, "quality": self.settings.rate_type, "storage": "memory",
                    "authorization": "configured-account" if self.settings.user_id else "anonymous",
                    "external_playlist": False, "client": "android",
                    "hdr": self.settings.hdr, "h265": self.settings.h265,
                    "client_dispatch": self.settings.client_dispatch}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)
