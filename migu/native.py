"""Configurable Migu API adapter with built-in channels.

Channel metadata is from Migu's public tv-data API (2026-10-19).
Protocol field names were checked against develop202/migu_video; no remote code runs.
"""
from collections import OrderedDict
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
import hashlib
import json
import os
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit, urlencode

from migu import core as m
from migu.workers import BoundedExecutor

BUILTIN_CHANNELS = (
    ('608807420', 'CCTV1综合', '央视'),
    ('631780532', 'CCTV2财经', '央视'),
    ('624878271', 'CCTV3综艺', '央视'),
    ('631780421', 'CCTV4中文国际', '央视'),
    ('641886683', 'CCTV5体育', '央视'),
    ('641886773', 'CCTV5+体育赛事', '央视'),
    ('624878396', 'CCTV6电影', '央视'),
    ('673168121', 'CCTV7国防军事', '央视'),
    ('624878356', 'CCTV8电视剧', '央视'),
    ('673168140', 'CCTV9纪录', '央视'),
    ('624878405', 'CCTV10科教', '央视'),
    ('667987558', 'CCTV11戏曲', '央视'),
    ('673168185', 'CCTV12社会与法', '央视'),
    ('608807423', 'CCTV13新闻', '央视'),
    ('624878440', 'CCTV14少儿', '央视'),
    ('673168223', 'CCTV15音乐', '央视'),
    ('673168256', 'CCTV17农业农村', '央视'),
    ('608807419', 'CCTV4欧洲', '央视'),
    ('608807416', 'CCTV4美洲', '央视'),
    ('609006487', 'CGTN外语纪录', '央视'),
    ('609154345', 'CGTN阿拉伯语', '央视'),
    ('609006450', 'CGTN西班牙语', '央视'),
    ('609006476', 'CGTN法语', '央视'),
    ('609006446', 'CGTN俄语', '央视'),
    ('884121956', '老故事', '央视'),
    ('624878970', '发现之旅', '央视'),
    ('708869532', '中学生', '央视'),
    ('609017205', 'CGTN', '央视'),
    ('646596895', '赛事最经典', '体育'),
    ('629943305', '体坛名栏汇', '体育'),
    ('637444975', '四海钓鱼', '体育'),
    ('956909356', '陕西体育休闲频道', '体育'),
    ('915512915', '24小时城市联赛轮播台', '体育'),
    ('958475359', '武术世界', '体育'),
    ('961930263', '快乐垂钓', '体育'),
    ('651632648', '东方卫视', '卫视'),
    ('623899368', '江苏卫视', '卫视'),
    ('608831231', '广东卫视', '卫视'),
    ('630287636', '北京卫视', '卫视'),
    ('630291707', '辽宁卫视', '卫视'),
    ('962042070', '河北卫视', '卫视'),
    ('783847495', '江西卫视', '卫视'),
    ('790187291', '河南卫视', '卫视'),
    ('738910838', '陕西卫视', '卫视'),
    ('608917627', '大湾区卫视', '卫视'),
    ('947472496', '湖北卫视', '卫视'),
    ('947472500', '吉林卫视', '卫视'),
    ('947472506', '青海卫视', '卫视'),
    ('849116810', '东南卫视', '卫视'),
    ('947472502', '海南卫视', '卫视'),
    ('849119120', '海峡卫视', '卫视'),
    ('956904896', '中国农林卫视', '卫视'),
    ('956923145', '兵团卫视', '卫视'),
    ('738910535', '宁夏卫视', '卫视'),
    ('738910914', '重庆卫视', '卫视'),
    ('961023778', '三沙卫视', '卫视'),
    ('738906901', '黑龙江卫视', '卫视'),
    ('651632657', '上视新闻综合', '地方'),
    ('617290047', '上视东方影视', '地方'),
    ('608780988', '上海第一财经', '地方'),
    ('838109047', '南京新闻综合频道', '地方'),
    ('838153729', '南京教科频道', '地方'),
    ('838151753', '南京十八频道', '地方'),
    ('626064707', '体育休闲频道', '地方'),
    ('626064714', '江苏城市频道', '地方'),
    ('626064674', '江苏国际', '地方'),
    ('628008321', '江苏教育', '地方'),
    ('626064697', '江苏影视频道', '地方'),
    ('626065193', '江苏综艺频道', '地方'),
    ('626064693', '公共新闻频道', '地方'),
    ('639731825', '盐城新闻综合', '地方'),
    ('639731826', '淮安新闻综合', '地方'),
    ('639731818', '泰州新闻综合', '地方'),
    ('639731715', '连云港新闻综合', '地方'),
    ('639731832', '宿迁新闻综合', '地方'),
    ('639731747', '徐州新闻综合', '地方'),
    ('626064703', '优漫卡通频道', '地方'),
    ('955227985', '南通新闻综合', '地方'),
    ('955227996', '宜兴新闻综合', '地方'),
    ('639737327', '溧水新闻综合', '地方'),
    ('956909362', '陕西银龄频道', '地方'),
    ('956909358', '陕西都市青春频道', '地方'),
    ('956909303', '陕西秦腔频道', '地方'),
    ('956909289', '陕西新闻资讯频道', '地方'),
    ('956923159', '财富天下', '地方'),
    ('639731783', '镇江新闻综合', '地方'),
    ('962067517', '海南广播电视总台新闻频道', '地方'),
    ('962045226', '海南广播电视总台自贸频道', '地方'),
    ('962045223', '海南广播电视总台社会与法频道', '地方'),
    ('962067526', '海南广播电视总台文旅频道', '地方'),
    ('962067523', '海南广播电视总台少儿频道', '地方'),
    ('639731952', '广东珠江频道', '地方'),
    ('713600957', '建党105周年巡礼', '影视'),
    ('625703337', '经典香港电影', '影视'),
    ('619495952', '新片放映厅', '影视'),
    ('952383261', 'CHC影迷电影', '影视'),
    ('644368714', 'CHC动作电影', '影视'),
    ('644368373', 'CHC家庭影院', '影视'),
    ('713591450', '和美乡途轮播台', '影视'),
    ('614961829', '南方影视', '影视'),
    ('959986621', '中国天气', '新闻'),
    ('923287154', 'CETV1', '教育'),
    ('923287211', 'CETV2', '教育'),
    ('923287339', 'CETV4', '教育'),
    ('609154353', '山东教育', '教育'),
    ('609158151', '熊猫频道01高清', '熊猫'),
    ('608933610', '熊猫频道1', '熊猫'),
    ('608933640', '熊猫频道2', '熊猫'),
    ('608934619', '熊猫频道3', '熊猫'),
    ('608934721', '熊猫频道4', '熊猫'),
    ('608935104', '熊猫频道5', '熊猫'),
    ('608935797', '熊猫频道6', '熊猫'),
    ('609169286', '熊猫频道7', '熊猫'),
    ('609169287', '熊猫频道8', '熊猫'),
    ('609169226', '熊猫频道9', '熊猫'),
    ('609169285', '熊猫频道10', '熊猫'),
    ('629942228', '最强综艺趴', '综艺'),
    ('614952364', '嘉佳卡通', '少儿'),
    ('629942219', '经典动画大集合', '少儿'),
    ('713589837', '新动力量创一流', '纪实'),
    ('959986618', '中华特产', '纪实'),
    ('958475356', '环球旅游', '纪实'),
    ('961930369', '梨园频道', '纪实'),
)


class MiguApiError(m.FetchError):
    def __init__(self, code, details=None):
        super().__init__(code)
        self.details = {key: value for key, value in (details or {}).items()
            if key in {'channel_id','api_code','rid','auth_result','logged_in','has_play_url','returned_quality'}
            and (type(value) is bool or value is None or (isinstance(value,str) and re.fullmatch(r'[A-Z0-9_]{1,80}', value)))}


def api_status(data, pid):
    body = data.get('body') or {}
    auth, info = body.get('auth') or {}, body.get('urlInfo') or {}
    def tag(value):
        value = str(value) if value is not None else ''
        return value if re.fullmatch(r'[A-Z0-9_]{1,80}', value) else 'UNKNOWN'
    return {'channel_id': pid, 'api_code': tag(data.get('code')), 'rid': tag(data.get('rid')),
            'auth_result': tag(auth.get('authResult')), 'logged_in': auth.get('logined') if type(auth.get('logined')) is bool else None,
            'has_play_url': isinstance(info.get('url'), str) and bool(info.get('url')), 'returned_quality': tag(info.get('rateType'))}


# Editable settings are at the top of the generated single-file release.
# Protocol constants are not account entitlements. Never commit real credentials.
NATIVE_SETTINGS = {
    "app_version": "2600000900",
    "client_channel": "2600037000-99000-200300220100002",
    "sign_salt": "66666601",
    "sign_suffix": "770fafdf5ba04d279a59ef1600baae98migu6666",
    "rate_type": 3,
    "user_id": "",       # Or environment MIGU_USER_ID
    "user_token": "",    # Or environment MIGU_USER_TOKEN
    "dd_keys": "0123456789",
    "dd_anonymous_word": "e",
    "dd_timestamp_index": 6,
    "dd_program_index": 2,
    "dd_tail": "0",
    "dd_suffix": "",
    "app_code": "",
}


@dataclass(frozen=True, repr=False)
class NativeAuth:
    app_version: str
    client_channel: str
    sign_salt: str
    sign_suffix: str
    rate_type: int
    user_id: str = field(repr=False)
    user_token: str = field(repr=False)
    dd_keys: str
    dd_anonymous_word: str
    dd_timestamp_index: int
    dd_program_index: int
    dd_tail: str
    dd_suffix: str
    app_code: str

    @classmethod
    def load(cls, settings=None, environ=None):
        values = dict(NATIVE_SETTINGS if settings is None else settings)
        env = os.environ if environ is None else environ
        for key, name in (("user_id", "MIGU_USER_ID"), ("user_token", "MIGU_USER_TOKEN"),
                          ("app_version", "MIGU_APP_VERSION"),
                          ("client_channel", "MIGU_CLIENT_CHANNEL_ID"),
                          ("app_code", "MIGU_APP_CODE")):
            if name in env:
                values[key] = env[name]
        if set(values) != set(cls.__dataclass_fields__):
            raise ValueError("MIGU_CONFIG_FIELDS_INVALID")
        for key, value in values.items():
            if key in {"rate_type", "dd_timestamp_index", "dd_program_index"}:
                if type(value) is not int:
                    raise ValueError("MIGU_CONFIG_NUMBER_INVALID")
            elif not isinstance(value, str) or len(value) > 4096 or any(not 33 <= ord(c) <= 126 for c in value):
                raise ValueError("MIGU_CONFIG_TEXT_INVALID")
        if not re.fullmatch(r"[0-9]{8,12}", values['app_version']) or not re.fullmatch(r"[0-9]{1,16}", values['sign_salt']):
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        if not values['client_channel'] or not values['sign_suffix'] or values['rate_type'] not in {2,3,4}:
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        if not 0 <= values['dd_timestamp_index'] <= 13 or not 0 <= values['dd_program_index'] <= 8:
            raise ValueError("MIGU_CONFIG_PROOF_INVALID")
        if len(values['dd_keys']) != 10 or len(values['dd_anonymous_word']) != 1 or len(values['dd_tail']) != 1:
            raise ValueError("MIGU_CONFIG_PROOF_INVALID")
        if bool(values['user_id']) != bool(values['user_token']):
            raise ValueError("MIGU_CREDENTIAL_PAIR_REQUIRED")
        if values['user_id'] and not re.fullmatch(r"[0-9]{4,32}", values['user_id']):
            raise ValueError("MIGU_USER_ID_INVALID")
        if values['dd_suffix'] not in {"", "&sv=10004&ct=android"} or values['app_code'] not in {"", "miguvideo_default_android", "miguvideo_android"}:
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        return cls(**values)


def native_request(pid, auth, timestamp):
    payload = hashlib.md5((timestamp + pid + auth.app_version[:8]).encode()).hexdigest()
    signature = hashlib.md5((payload + auth.sign_suffix).encode()).hexdigest()
    endpoint = "https://play.miguvideo.com/playurl/v1/play/playurl?" + urlencode({
        "contId": pid, "rateType": 2 if pid == "608831231" and auth.app_version == "2600000900" else auth.rate_type, "timestamp": timestamp,
        "salt": auth.sign_salt, "sign": signature})
    headers = {"AppVersion": auth.app_version, "TerminalId": "android",
               "X-UP-CLIENT-CHANNEL-ID": auth.client_channel}
    if auth.app_code and pid not in {"641886683", "641886773"}:
        headers["appCode"] = auth.app_code
    if auth.user_id:
        headers.update(UserId=auth.user_id, UserToken=auth.user_token)
    return endpoint, headers


def native_proof(seed, pid, timestamp, auth, rate_type):
    if len(pid) <= auth.dd_program_index or not re.fullmatch(r"[0-9]{14}", timestamp):
        raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
    word = auth.dd_anonymous_word
    if auth.dd_keys != "0123456789" and rate_type != 2 and auth.user_id:
        word = "e" if len(auth.user_id) <= 8 else auth.dd_keys[int(auth.user_id[7])]
    extra = {1: word, 2: auth.dd_keys[int(timestamp[auth.dd_timestamp_index])],
             3: auth.dd_keys[int(pid[auth.dd_program_index])], 4: auth.dd_tail}
    proof = "".join(seed[-i-1] + seed[i] + extra.get(i, "") for i in range(len(seed)//2))
    return proof + (seed[len(seed)//2] if len(seed) % 2 else "")


def native_play_url(pid, client_factory=m.HttpClient, auth=None):
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
    auth = auth or NativeAuth.load()
    endpoint, headers = native_request(pid, auth, str(int(time.time() * 1000)))
    raw, _ = client_factory("api", attempts=1, timeout=8, budget=10).get(endpoint, headers=headers, limit=256 * 1024)
    try:
        data = json.loads(raw)
        body = data.get("body") or {}
        info = body.get("urlInfo") or {}
        reason = data.get("rid", "")
        details = api_status(data, pid)
        if reason == "COPYRIGHT_AREA_INVALID":
            raise MiguApiError("MIGU_REGION_RESTRICTED", details)
        if reason == "TIPS_NEED_MEMBER":
            raise MiguApiError("MIGU_MEMBERSHIP_REQUIRED", details)
        if reason in {"NEED_LOGIN", "USER_NOT_LOGIN"}:
            raise MiguApiError("MIGU_LOGIN_REQUIRED", details)
        auth_result = (body.get("auth") or {}).get("authResult")
        if str(data.get("code")) != "200":
            raise MiguApiError("MIGU_API_REJECTED", details)
        url = info.get("url")
        if not isinstance(url, str) or not url:
            # No address and a failed authorization: report the real cause.
            if auth_result == "FAIL":
                raise MiguApiError("MIGU_AUTHORIZATION_REJECTED", details)
            raise MiguApiError("MIGU_PLAY_URL_MISSING", details)
        m.validate_url(url, "stream")
        content_pid = str((body.get("content") or {}).get("contId", pid))
        if content_pid != pid:
            raise m.FetchError("MIGU_CHANNEL_MISMATCH")
        query = parse_qs(urlsplit(url).query)
        # Already complete URLs are preserved byte for byte.
        if "ddCalcu" in query:
            return url
        seed = query.get("puData", [""])
        if len(seed) != 1 or re.fullmatch(r"[0-9a-fA-F]{16,128}", seed[0]) is None:
            raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
        seed = seed[0]
        try:
            returned_rate = int(info.get("rateType", auth.rate_type))
        except (TypeError, ValueError):
            raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None
        if returned_rate not in {2,3,4}:
            raise m.FetchError("MIGU_API_FORMAT_CHANGED")
        timestamps = query.get("timestamp", [])
        if len(timestamps) != 1:
            raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
        proof = native_proof(seed, pid, timestamps[0], auth, returned_rate)
        return url + "&ddCalcu=" + proof + auth.dd_suffix
    except (TypeError, AttributeError, IndexError, json.JSONDecodeError):
        raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None


@dataclass(frozen=True)
class NativeSnapshot:
    playlist: object
    channels: object


class NativeStore:
    """Built-in metadata; bounded, coalesced on-demand resolution, memory only."""
    provider = "migu"

    def __init__(self, resolver=native_play_url, clock=time.monotonic, auth=None):
        self.auth = auth or NativeAuth.load()
        self.resolver = (lambda pid: native_play_url(pid, auth=self.auth)) if resolver is native_play_url else resolver
        self.clock = clock
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-api")
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.last_error, self.fetches = False, None, 0
        self.last_upstream = None
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = NativeSnapshot(None, MappingProxyType(channels))

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def _finish(self, key, future):
        try:
            url, error = future.result(), None
        except Exception as failure:
            url, error = "", (str(failure), dict(getattr(failure, "details", {}))) if isinstance(failure, m.UpdateError) else ("MIGU_API_ERROR", {})
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            self.last_error = error[0] if error else None
            self.last_upstream = error[1] if error else None
            self.entries[key] = (self.clock() + (5 if error else 30), url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def resolve(self, key, wait=9):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if key not in self.snapshot.channels:
                raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
            cached = self.entries.get(key)
            if cached and cached[0] > self.clock():
                self.entries.move_to_end(key)
                if cached[2]:
                    raise MiguApiError(cached[2][0], cached[2][1])
                return cached[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 8:
                    raise m.FetchError("MIGU_API_CAPACITY")
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
                    "source_transport": "https", "last_error": self.last_error, "last_upstream": self.last_upstream, "api_requests": self.fetches,
                    "playback_verified": False, "quality": self.auth.rate_type, "storage": "memory",
                    "authorization": "configured-account" if self.auth.user_id else "anonymous",
                    "external_playlist": False, "client_version": self.auth.app_version}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)
